-- Guest visuals: how each guest looks and moves on screen, none of what it does.
-- sim.luau owns the rules and the cells; this module reads the sim and keeps a
-- visual for every guest on top of it: the Person artboard instance, a heading
-- worked out from where the guest actually goes, the head turn, the light it
-- stands in, a contact shadow, and the little things guests leave on the floor
-- (a dropped cup and its spill, the costume of a guest that was caught).
-- Nothing here writes to the sim. Every number is in config.luau ("Guests").

local Sim = require('sim')
local Config = require('config')
local Lighting = require('lighting')

type Cell = Sim.Cell

-- The Person artboard (person.rml) is 48x56 and rigged on its `Size` node, which
-- sits here. Keep in step.
local RIG_X = 16
local RIG_Y = 29
local TEXELS = 8 -- texture px per game px in the decal art
local COSTUMES = 6 -- witch, pumpkin, devil, skeleton, cat, vampire: the `costume` order
local SEED = 40961 -- this module's own random numbers; never the sim's
local PI = math.pi
local KAPPA = 0.5522847498

-- Where each image is pinned, in texture px.
local CUP_PIVOT_X, CUP_PIVOT_Y = 36, 28
local SPILL_PIVOT_X, SPILL_PIVOT_Y = 72, 56
local ITEM_PIVOT = 96

export type Shadow = { dx: number, dy: number, alpha: number, feather: number }

-- One thing lying on the floor. A cup flies for GUEST_CUP_TIME and then rests; a
-- spill grows; an item pops in. `fade` is -1 until the decal is over the cap.
type Decal = {
    kind: string, -- 'cup' | 'spill' | 'item'
    serial: number, -- when it was made, to find the oldest
    x: number,
    y: number,
    angle: number,
    age: number,
    fade: number,
    costume: number, -- items
    flying: boolean, -- cups
    x0: number,
    y0: number,
    dx: number,
    dy: number,
    speed: number,
    spin: number,
    angle0: number,
}

export type Visual = {
    id: number,
    instance: Artboard<Data.Person>,
    state: Sim.GuestState, -- what it is showing
    cell: Cell,
    placed: boolean, -- x, y hold a real position
    x: number, -- px, where the Rig stands
    y: number,
    vx: number, -- smoothed velocity, px/s
    vy: number,
    moving: boolean,
    movingFor: number, -- seconds it has been moving without a pause
    moved: boolean, -- has moved at least once
    fresh: boolean, -- has not had its first heading yet
    heading: number, -- radians, 0 = +x
    costume: number,
    hasDrink: boolean,
    alertRolled: boolean, -- the alert drop has been decided
    chatting: boolean,
    forced: boolean, -- debug: showing flee while the sim says otherwise
    look: number, -- head turn relative to the heading, eased
    lookTarget: number,
    glanceTimer: number, -- seconds to the next glance
    glanceLeft: number, -- a fleeing guest's look-back has this long to run
    light: { number },
    lightSet: boolean,
    caughtAge: number, -- seconds in the caught state; -1 if not caught
    itemLeft: number, -- seconds to the costume it leaves behind; -1 if none due
    hideLeft: number, -- debug K: the real guest is out of sight while its stand-in plays
    standIn: boolean,
}

export type Fx = {
    tile: number,
    shadow: Shadow,
    seed: number,
    bag: { number },
    bagLeft: number,
    list: { Visual }, -- in the sim's order
    byId: { [number]: Visual },
    standIns: { Visual },
    cups: { Decal },
    spills: { Decal },
    items: { Decal },
    serial: number,
    cupImage: Image?,
    spillImage: Image?,
    itemImages: { [number]: Image },
    sampler: ImageSampler,
    holdFlee: boolean, -- debug G
    headX: number, -- px
    headY: number,
    checkWorst: number,
    checkWho: number,
    checkSamples: number,
    checkDone: boolean,
}

local GuestFx = {}

local function rand(fx: Fx): number
    fx.seed = (fx.seed * 1664525 + 1013904223) % 4294967296
    return fx.seed / 4294967296
end

local function between(fx: Fx, range: { number }): number
    return range[1] + (range[2] - range[1]) * rand(fx)
end

local function wrap(a: number): number
    return (a + PI) % (2 * PI) - PI
end

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

-- An oval at (cx, cy) with half-axes `along` x `across`, its long axis turned to
-- the unit direction (tx, ty).
local function addOval(path: Path, cx: number, cy: number, tx: number, ty: number, along: number, across: number)
    local ux, uy = tx * along, ty * along
    local vx, vy = -ty * across, tx * across
    local function at(a: number, b: number): Vector
        return Vector.xy(cx + ux * a + vx * b, cy + uy * a + vy * b)
    end
    path:moveTo(at(1, 0))
    path:cubicTo(at(1, KAPPA), at(KAPPA, 1), at(0, 1))
    path:cubicTo(at(-KAPPA, 1), at(-1, KAPPA), at(-1, 0))
    path:cubicTo(at(-1, -KAPPA), at(-KAPPA, -1), at(0, -1))
    path:cubicTo(at(KAPPA, -1), at(1, -KAPPA), at(1, 0))
    path:close()
end

function GuestFx.new(tile: number, shadow: Shadow): Fx
    return {
        tile = tile,
        shadow = shadow,
        seed = SEED,
        bag = {},
        bagLeft = 0,
        list = {},
        byId = {},
        standIns = {},
        cups = {},
        spills = {},
        items = {},
        serial = 0,
        cupImage = nil,
        spillImage = nil,
        itemImages = {},
        sampler = ImageSampler('clamp', 'clamp', 'bilinear'),
        holdFlee = false,
        headX = 0,
        headY = 0,
        checkWorst = 0,
        checkWho = 0,
        checkSamples = 0,
        checkDone = false,
    }
end

-- Looked up by name, which nothing validates: a typo is nil, not a build error.
function GuestFx.load(fx: Fx, context: Context)
    fx.cupImage = context:image('guest_cup_tipped')
    fx.spillImage = context:image('guest_spill')
    local names = { 'witch', 'pumpkin', 'devil', 'skeleton', 'cat', 'vampire' }
    local missing = fx.cupImage == nil or fx.spillImage == nil
    for i, name in names do
        local image = context:image(`guest_{name}_item`)
        if image ~= nil then
            fx.itemImages[i] = image
        else
            missing = true
        end
    end
    if missing then
        print('guest art not found: guest_cup_tipped / guest_spill / guest_<costume>_item')
    end
end

-- A new run: no visuals, no decals, a fresh costume cycle.
function GuestFx.reset(fx: Fx)
    fx.list = {}
    fx.byId = {}
    fx.standIns = {}
    fx.cups = {}
    fx.spills = {}
    fx.items = {}
    fx.bagLeft = 0
    fx.checkWorst = 0
    fx.checkWho = 0
    fx.checkSamples = 0
    fx.checkDone = false
end

function GuestFx.setHoldFlee(fx: Fx, held: boolean)
    fx.holdFlee = held
end

-- Costumes come from a shuffled cycle of all six, so none repeats before every
-- one has been used.
local function nextCostume(fx: Fx): number
    if fx.bagLeft <= 0 then
        for i = 1, COSTUMES do
            fx.bag[i] = i - 1
        end
        for i = COSTUMES, 2, -1 do
            local j = 1 + math.floor(rand(fx) * i)
            fx.bag[i], fx.bag[j] = fx.bag[j], fx.bag[i]
        end
        fx.bagLeft = COSTUMES
    end
    local costume = fx.bag[COSTUMES - fx.bagLeft + 1]
    fx.bagLeft -= 1
    return costume
end

local function onDanceFloor(cell: Cell): boolean
    return cell.x >= Config.GUEST_DANCE_COLS[1]
        and cell.x <= Config.GUEST_DANCE_COLS[2]
        and cell.y >= Config.GUEST_DANCE_ROWS[1]
        and cell.y <= Config.GUEST_DANCE_ROWS[2]
end

-- Floor decals --------------------------------------------------------------

local function newDecal(fx: Fx, kind: string, x: number, y: number, angle: number): Decal
    fx.serial += 1
    return {
        kind = kind,
        serial = fx.serial,
        x = x,
        y = y,
        angle = angle,
        age = 0,
        fade = -1,
        costume = 0,
        flying = false,
        x0 = x,
        y0 = y,
        dx = 0,
        dy = 0,
        speed = 0,
        spin = 0,
        angle0 = angle,
    }
end

-- Over the cap, the oldest decal that is not already going starts to fade.
local function enforceCap(list: { Decal }, other: { Decal }?, cap: number)
    while true do
        local count = 0
        local oldest: Decal? = nil
        for _, d in list do
            if d.fade < 0 then
                count += 1
                if oldest == nil or d.serial < oldest.serial then
                    oldest = d
                end
            end
        end
        if other ~= nil then
            for _, d in other do
                if d.fade < 0 then
                    count += 1
                    if oldest == nil or d.serial < oldest.serial then
                        oldest = d
                    end
                end
            end
        end
        if oldest == nil or count <= cap then
            return
        end
        local over: Decal = oldest
        over.fade = 0
    end
end

local function stepDecals(fx: Fx, dt: number)
    local fadeTime = Config.GUEST_DECAL_FADE
    for _, list in { fx.cups, fx.spills, fx.items } do
        for i = #list, 1, -1 do
            local d = list[i]
            d.age += dt
            if d.fade >= 0 then
                d.fade += dt
            end
            if d.kind == 'cup' and d.flying then
                local total = Config.GUEST_CUP_TIME
                local t = math.min(d.age, total)
                -- Linear slowdown to rest: the distance covered is v * (t - t^2 / 2T).
                local travelled = d.speed * (t - t * t / (2 * total))
                d.x = d.x0 + d.dx * travelled
                d.y = d.y0 + d.dy * travelled
                d.angle = d.angle0 + d.spin * (t - t * t / (2 * total))
                if d.age >= total then
                    d.flying = false
                    -- The spill lies just past the cup's mouth, so the mouth points into it.
                    local spill = newDecal(
                        fx,
                        'spill',
                        d.x + math.cos(d.angle) * Config.GUEST_SPILL_OFFSET,
                        d.y + math.sin(d.angle) * Config.GUEST_SPILL_OFFSET,
                        rand(fx) * 2 * PI
                    )
                    table.insert(fx.spills, spill)
                    enforceCap(fx.cups, fx.spills, Config.GUEST_MAX_SPILLS)
                end
            end
            if d.fade >= fadeTime then
                table.remove(list, i)
            end
        end
    end
end

local function dropCup(fx: Fx, v: Visual, towardX: number, towardY: number)
    v.hasDrink = false
    v.instance.data.hasDrink.value = false
    local s = Config.GUEST_SCALE
    local hx, hy = Config.GUEST_HAND[1] * s, Config.GUEST_HAND[2] * s
    local c, sn = math.cos(v.heading), math.sin(v.heading)
    local cup = newDecal(fx, 'cup', v.x + hx * c - hy * sn, v.y + hx * sn + hy * c, v.heading)
    cup.flying = true
    cup.dx, cup.dy = towardX, towardY
    cup.speed = between(fx, Config.GUEST_CUP_SPEED)
    cup.spin = between(fx, Config.GUEST_CUP_SPIN) * (if rand(fx) < 0.5 then -1 else 1)
    table.insert(fx.cups, cup)
    enforceCap(fx.cups, fx.spills, Config.GUEST_MAX_SPILLS)
end

-- The unit direction from the snake's head to a point; (heading) if they coincide.
local function awayFromHead(fx: Fx, x: number, y: number, fallback: number): (number, number)
    local dx, dy = x - fx.headX, y - fx.headY
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then
        return math.cos(fallback), math.sin(fallback)
    end
    return dx / len, dy / len
end

local function leaveCostume(fx: Fx, v: Visual)
    local dx, dy = awayFromHead(fx, v.x, v.y, v.heading)
    local push = Config.GUEST_ITEM_PUSH
    local item = newDecal(fx, 'item', v.x + dx * push, v.y + dy * push, rand(fx) * 2 * PI)
    item.costume = v.costume
    table.insert(fx.items, item)
    enforceCap(fx.items, nil, Config.GUEST_MAX_ITEMS)
end

-- Visuals -------------------------------------------------------------------

-- The state a guest is shown in: the sim's, unless the debug flee is held.
local function shownState(fx: Fx, g: Sim.Guest): Sim.GuestState
    if fx.holdFlee and g.state ~= 'caught' then
        return 'flee'
    end
    return g.state
end

local function newVisual(fx: Fx, person: Input<Artboard<Data.Person>>, g: Sim.Guest, state: Sim.GuestState): Visual
    local instance = person:instance(Data.Person.new())
    local costume = nextCostume(fx)
    local dancing = state == 'idle' and onDanceFloor(g.cell)
    instance.data.state.value = state
    instance.data.costume.value = costume
    instance.data.hasDrink.value = true
    instance.data.dancing.value = dancing
    instance.data.lookAngle.value = 0
    local heading = math.atan2(g.heading.y, g.heading.x)
    instance.data.upright.value = -heading
    instance:advance(0)
    -- Nobody breathes or dances in step with anybody else.
    instance:advance(rand(fx) * Config.GUEST_DESYNC)
    return {
        id = g.id,
        instance = instance,
        state = state,
        cell = g.cell,
        placed = false,
        x = 0,
        y = 0,
        vx = 0,
        vy = 0,
        moving = false,
        movingFor = 0,
        moved = false,
        fresh = true,
        heading = heading,
        costume = costume,
        hasDrink = true,
        alertRolled = false,
        chatting = false,
        forced = false,
        look = 0,
        lookTarget = 0,
        glanceTimer = between(fx, Config.GUEST_CHAT_GLANCE_GAP),
        glanceLeft = 0,
        light = { 1, 1, 1 },
        lightSet = false,
        caughtAge = -1,
        itemLeft = -1,
        hideLeft = 0,
        standIn = false,
    }
end

-- Moves the heading toward `target` the short way round at `rate` rad/s, three
-- times that while it is far off.
local function turnToward(heading: number, target: number, rate: number, dt: number): number
    local diff = wrap(target - heading)
    local speed = rate
    if math.abs(diff) > Config.GUEST_BIG_TURN then
        speed *= Config.GUEST_BIG_TURN_BOOST
    end
    local step = speed * dt
    if math.abs(diff) <= step then
        return wrap(target)
    end
    return wrap(heading + (if diff > 0 then step else -step))
end

-- What a standing guest faces: the dance floor's centre if it is dancing, else
-- the nearest other standing guest within chatting range.
local function standingTarget(fx: Fx, v: Visual, dancing: boolean): (number?, number?)
    if dancing then
        local cols, rows = Config.GUEST_DANCE_COLS, Config.GUEST_DANCE_ROWS
        return (cols[1] + cols[2] + 1) / 2 * fx.tile, (rows[1] + rows[2] + 1) / 2 * fx.tile
    end
    local range = Config.GUEST_CHAT_RANGE * fx.tile
    local best: Visual? = nil
    local bestD = range * range
    for _, o in fx.list do
        if o ~= v and o.state == 'idle' and not o.moving and o.hideLeft <= 0 then
            local dx, dy = o.x - v.x, o.y - v.y
            local d = dx * dx + dy * dy
            if d <= bestD then
                bestD = d
                best = o
            end
        end
    end
    if best ~= nil then
        return best.x, best.y
    end
    return nil, nil
end

-- The reactions to a guest changing what it shows.
local function enterState(fx: Fx, v: Visual, state: Sim.GuestState)
    v.state = state
    v.instance.data.state.value = state
    if state == 'flee' then
        v.glanceTimer = between(fx, Config.GUEST_FLEE_GLANCE_GAP)
        v.glanceLeft = 0
        if v.hasDrink then
            local speed = math.sqrt(v.vx * v.vx + v.vy * v.vy)
            local dx: number, dy: number
            if v.moving and speed > 1e-3 then
                dx, dy = v.vx / speed, v.vy / speed
            else
                dx, dy = awayFromHead(fx, v.x, v.y, v.heading)
            end
            dropCup(fx, v, dx, dy)
        end
    elseif state == 'alert' then
        if v.hasDrink and not v.alertRolled then
            v.alertRolled = true
            if rand(fx) < Config.GUEST_ALERT_DROP_CHANCE then
                local dx, dy = awayFromHead(fx, v.x, v.y, v.heading)
                dropCup(fx, v, dx, dy)
            end
        end
    elseif state == 'idle' then
        v.glanceTimer = between(fx, Config.GUEST_CHAT_GLANCE_GAP)
    elseif state == 'caught' then
        v.caughtAge = 0
        v.itemLeft = Config.GUEST_ITEM_DELAY
    end
end

-- Where the head points relative to the heading, before easing.
local function lookTargetOf(fx: Fx, v: Visual, dt: number, dancing: boolean): number
    local limit = Config.GUEST_LOOK_LIMIT
    local towardSnake = math.clamp(wrap(math.atan2(fx.headY - v.y, fx.headX - v.x) - v.heading), -limit, limit)
    if v.state == 'alert' then
        return towardSnake
    elseif v.state == 'flee' then
        if v.glanceLeft > 0 then
            v.glanceLeft -= dt
            return towardSnake
        end
        v.glanceTimer -= dt
        if v.glanceTimer <= 0 then
            v.glanceLeft = Config.GUEST_FLEE_GLANCE_TIME
            v.glanceTimer = between(fx, Config.GUEST_FLEE_GLANCE_GAP)
        end
        return 0
    elseif v.state == 'idle' and v.chatting and not dancing then
        v.glanceTimer -= dt
        if v.glanceTimer <= 0 then
            v.lookTarget = (rand(fx) * 2 - 1) * Config.GUEST_CHAT_GLANCE
            v.glanceTimer = between(fx, Config.GUEST_CHAT_GLANCE_GAP)
        end
        return v.lookTarget
    end
    return 0
end

local function shadowFactor(v: Visual): number
    if v.caughtAge < 0 then
        return 1
    end
    return math.clamp(1 - v.caughtAge / Config.GUEST_SHADOW_FADE, 0, 1)
end

-- Everything a visual does that is the same for a live guest and a stand-in:
-- the caught clock, the costume it leaves behind, its light.
local function stepCommon(fx: Fx, v: Visual, dt: number)
    if v.caughtAge >= 0 then
        v.caughtAge += dt
    end
    if v.itemLeft >= 0 then
        v.itemLeft -= dt
        if v.itemLeft <= 0 then
            v.itemLeft = -1
            leaveCostume(fx, v)
        end
    end
    local r, g, b = Lighting.lightRgb(v.x / fx.tile, v.y / fx.tile)
    local light = v.light
    if not v.lightSet then
        v.lightSet = true
        light[1], light[2], light[3] = r, g, b
    elseif dt > 0 then
        local k = 1 - math.exp(-dt / Config.GUEST_LIGHT_TIME)
        light[1] += (r - light[1]) * k
        light[2] += (g - light[2]) * k
        light[3] += (b - light[3]) * k
    end
end

local function writeUpright(v: Visual)
    local data = v.instance.data
    if data.upright.value ~= -v.heading then
        data.upright.value = -v.heading
    end
    if data.lookAngle.value ~= v.look then
        data.lookAngle.value = v.look
    end
end

-- Syncs the visuals with the sim's guests and moves them on by `dt` (0 while the
-- game is frozen). guestAlpha is how far through its tick the guests' slide is;
-- (headX, headY) is the snake's head in px.
function GuestFx.update(
    fx: Fx,
    sim: Sim.Sim,
    person: Input<Artboard<Data.Person>>,
    dt: number,
    guestAlpha: number,
    headX: number,
    headY: number
)
    local tile = fx.tile
    fx.headX, fx.headY = headX, headY
    local walkSpeed = tile * Config.TICK_RATE * Config.GUEST_SPEED -- the sim's step: a cell a guest tick
    local runSpeed = walkSpeed

    -- 1. Who is there, where, and how fast they are going.
    for _, g in sim.guests do
        local v = fx.byId[g.id]
        if g.gone then
            if v ~= nil then
                fx.byId[g.id] = nil
                local at = table.find(fx.list, v)
                if at ~= nil then
                    table.remove(fx.list, at)
                end
                -- A caught guest is removed by the sim before its animation has
                -- finished: the same instance stays on, frozen in place, until it has.
                if g.state == 'caught' then
                    if v.state ~= 'caught' then
                        enterState(fx, v, 'caught')
                    end
                    v.standIn = true
                    table.insert(fx.standIns, v)
                end
            end
        else
            if v == nil then
                v = newVisual(fx, person, g, shownState(fx, g))
                fx.byId[g.id] = v
                table.insert(fx.list, v)
            end
            v.cell = g.cell
            local x = ((g.prev.x + (g.cell.x - g.prev.x) * guestAlpha) + 0.5) * tile
            local y = ((g.prev.y + (g.cell.y - g.prev.y) * guestAlpha) + 0.5) * tile
            if not v.placed then
                v.placed = true
            elseif dt > 0 then
                local k = 1 - math.exp(-dt / Config.GUEST_VELOCITY_TIME)
                v.vx += ((x - v.x) / dt - v.vx) * k
                v.vy += ((y - v.y) / dt - v.vy) * k
            end
            v.x, v.y = x, y
            v.moving = math.sqrt(v.vx * v.vx + v.vy * v.vy) > Config.GUEST_MOVE_SPEED
            v.movingFor = if v.moving then v.movingFor + dt else 0
            v.forced = fx.holdFlee and g.state ~= 'caught' and g.state ~= 'flee'
        end
    end

    -- 2. What each one shows and does.
    for _, g in sim.guests do
        local v = fx.byId[g.id]
        if v ~= nil then
            local want = shownState(fx, g)
            if want ~= v.state then
                enterState(fx, v, want)
            end
            if v.hideLeft > 0 then
                v.hideLeft = math.max(0, v.hideLeft - dt)
            end

            local dancing = v.state == 'idle' and onDanceFloor(v.cell)
            if v.instance.data.dancing.value ~= dancing then
                v.instance.data.dancing.value = dancing
            end

            -- Heading: the way it is going, or, standing, the company it keeps.
            local speed = math.sqrt(v.vx * v.vx + v.vy * v.vy)
            local rate = if v.state == 'flee' then Config.GUEST_FLEE_TURN_RATE else Config.GUEST_TURN_RATE
            v.chatting = false
            if v.moving then
                local target = math.atan2(v.vy, v.vx)
                if not v.moved then
                    v.moved = true
                    v.heading = target -- no turning on the spot at the first step
                else
                    v.heading = turnToward(v.heading, target, rate, dt)
                end
            elseif v.state == 'idle' then
                local tx, ty = standingTarget(fx, v, dancing)
                if tx ~= nil and ty ~= nil then
                    v.chatting = not dancing
                    local target = math.atan2(ty - v.y, tx - v.x)
                    v.heading = if v.fresh then target else turnToward(v.heading, target, rate, dt)
                end
            elseif v.forced and v.state == 'flee' then
                -- Debug only: a guest made to flee on the spot turns its back on the snake.
                local dx, dy = awayFromHead(fx, v.x, v.y, v.heading)
                v.heading = turnToward(v.heading, math.atan2(dy, dx), rate, dt)
            end
            v.fresh = false

            -- Head turn, eased.
            local target = math.clamp(lookTargetOf(fx, v, dt, dancing), -Config.GUEST_LOOK_LIMIT, Config.GUEST_LOOK_LIMIT)
            if dt > 0 then
                v.look += (target - v.look) * (1 - math.exp(-dt / Config.GUEST_LOOK_TIME))
            end
            writeUpright(v)
            stepCommon(fx, v, dt)

            -- Feet keep pace with the ground they cover.
            local step = dt
            if v.state == 'wander' or v.state == 'flee' then
                local nominal = if v.state == 'flee' then runSpeed else walkSpeed
                step = dt * math.clamp(speed / nominal, Config.GUEST_STEP_MIN, Config.GUEST_STEP_MAX)
            end
            v.instance:advance(step)

            -- The heading check: after the first moments of a step, a moving guest
            -- should already be facing the way it goes.
            if sim.state == 'playing' and sim.playTime <= Config.GUEST_HEADING_CHECK_TIME and v.moving then
                if v.movingFor >= Config.GUEST_HEADING_CHECK_AFTER then
                    local err = math.abs(wrap(v.heading - math.atan2(v.vy, v.vx)))
                    fx.checkSamples += 1
                    if err > fx.checkWorst then
                        fx.checkWorst = err
                        fx.checkWho = v.id
                    end
                end
            end
        end
    end

    if not fx.checkDone and sim.state == 'playing' and sim.playTime > Config.GUEST_HEADING_CHECK_TIME then
        fx.checkDone = true
        print(
            string.format(
                'guestfx: heading check, first %ds of the run: worst error %.3f rad (guest %d, %d samples) -> %s',
                Config.GUEST_HEADING_CHECK_TIME,
                fx.checkWorst,
                fx.checkWho,
                fx.checkSamples,
                if fx.checkWorst <= Config.GUEST_HEADING_TOLERANCE then 'ok' else 'OVER the tolerance'
            )
        )
    end

    -- 3. Stand-ins finish their animation, then go.
    for i = #fx.standIns, 1, -1 do
        local v = fx.standIns[i]
        stepCommon(fx, v, dt)
        writeUpright(v)
        v.instance:advance(dt)
        if v.caughtAge >= Config.GUEST_CAUGHT_ANIM then
            if v.itemLeft >= 0 then
                v.itemLeft = -1
                leaveCostume(fx, v)
            end
            table.remove(fx.standIns, i)
        end
    end

    -- 4. The floor.
    stepDecals(fx, dt)
end

-- Debug K: the guest nearest the head is caught, as far as the eye can tell. The
-- sim knows nothing of it: a stand-in plays the whole sequence (and leaves the
-- costume) while the real guest steps out of sight, for the stand-in's run and a
-- little longer so the costume can be seen where it fell.
function GuestFx.catchNearest(fx: Fx, person: Input<Artboard<Data.Person>>)
    local headX, headY = fx.headX, fx.headY
    local best: Visual? = nil
    local bestD = math.huge
    for _, v in fx.list do
        if v.state ~= 'caught' and v.hideLeft <= 0 then
            local dx, dy = v.x - headX, v.y - headY
            local d = dx * dx + dy * dy
            if d < bestD then
                bestD = d
                best = v
            end
        end
    end
    if best == nil then
        return
    end
    local instance = person:instance(Data.Person.new())
    instance.data.costume.value = best.costume
    instance.data.hasDrink.value = best.hasDrink
    instance.data.lookAngle.value = best.look
    instance.data.upright.value = -best.heading
    instance.data.state.value = 'caught'
    instance:advance(0)
    local light = { best.light[1], best.light[2], best.light[3] }
    local stand: Visual = {
        id = best.id,
        instance = instance,
        state = 'caught',
        cell = best.cell,
        placed = true,
        x = best.x,
        y = best.y,
        vx = 0,
        vy = 0,
        moving = false,
        movingFor = 0,
        moved = true,
        fresh = false,
        heading = best.heading,
        costume = best.costume,
        hasDrink = best.hasDrink,
        alertRolled = true,
        chatting = false,
        forced = false,
        look = best.look,
        lookTarget = 0,
        glanceTimer = 0,
        glanceLeft = 0,
        light = light,
        lightSet = true,
        caughtAge = 0,
        itemLeft = Config.GUEST_ITEM_DELAY,
        hideLeft = 0,
        standIn = true,
    }
    table.insert(fx.standIns, stand)
    best.hideLeft = Config.GUEST_CAUGHT_ANIM + Config.GUEST_DEBUG_HIDE
end

-- Drawing -------------------------------------------------------------------

local function drawSprite(fx: Fx, r: Renderer, image: Image, x: number, y: number, angle: number, scale: number, pivotX: number, pivotY: number, opacity: number)
    r:save()
    r:modulateColor(Lighting.lightAt(x / fx.tile, y / fx.tile))
    r:transform(Mat2D.withTranslation(x, y))
    r:transform(Mat2D.withRotation(angle))
    r:transform(Mat2D.withScale(scale / TEXELS, scale / TEXELS))
    r:transform(Mat2D.withTranslation(-pivotX, -pivotY))
    r:drawImage(image, fx.sampler, 'srcOver', opacity)
    r:restore()
end

local function fadeOf(d: Decal): number
    if d.fade < 0 then
        return 1
    end
    return math.clamp(1 - d.fade / Config.GUEST_DECAL_FADE, 0, 1)
end

-- The floor decals, for the scene canvas right after the floor: they take the
-- light of the spot they lie on, like the floor itself.
function GuestFx.drawDecals(fx: Fx, r: Renderer)
    local spillImage = fx.spillImage
    if spillImage ~= nil then
        for _, d in fx.spills do
            local grow = math.clamp(d.age / Config.GUEST_SPILL_GROW, 0, 1)
            local scale = lerp(Config.GUEST_SPILL_FROM, 1, grow)
            drawSprite(fx, r, spillImage, d.x, d.y, d.angle, scale, SPILL_PIVOT_X, SPILL_PIVOT_Y, fadeOf(d))
        end
    end
    local itemImages = fx.itemImages
    for _, d in fx.items do
        local image = itemImages[d.costume + 1]
        if image ~= nil then
            local pop = math.clamp(d.age / Config.GUEST_ITEM_POP, 0, 1)
            local scale = lerp(Config.GUEST_ITEM_FROM, 1, pop)
            drawSprite(fx, r, image, d.x, d.y, d.angle, scale, ITEM_PIVOT, ITEM_PIVOT, fadeOf(d))
        end
    end
    local cupImage = fx.cupImage
    if cupImage ~= nil then
        for _, d in fx.cups do
            drawSprite(fx, r, cupImage, d.x, d.y, d.angle, 1, CUP_PIVOT_X, CUP_PIVOT_Y, fadeOf(d))
        end
    end
end

local function drawShadow(fx: Fx, r: Renderer, v: Visual)
    local factor = shadowFactor(v)
    if factor <= 0 then
        return
    end
    local shadow = fx.shadow
    local s = Config.GUEST_SCALE
    local path = Path.new() -- a drawn Path is never mutated: a fresh one each time
    addOval(
        path,
        v.x,
        v.y,
        math.cos(v.heading),
        math.sin(v.heading),
        Config.GUEST_SHADOW_SIZE[1] / 2 * s,
        Config.GUEST_SHADOW_SIZE[2] / 2 * s
    )
    r:save()
    r:transform(Mat2D.withTranslation(shadow.dx, shadow.dy))
    r:drawPath(
        path,
        Paint.with({
            style = 'fill',
            color = Color.rgba(0, 0, 0, math.floor(shadow.alpha * factor)),
            feather = shadow.feather,
        })
    )
    r:restore()
end

local function drawBody(r: Renderer, v: Visual)
    r:save()
    r:transform(Mat2D.withTranslation(v.x, v.y))
    r:transform(Mat2D.withRotation(v.heading))
    r:transform(Mat2D.withTranslation(-RIG_X, -RIG_Y))
    local light = v.light
    r:modulateColor(Lighting.color(light[1], light[2], light[3]))
    v.instance:draw(r)
    r:restore()
end

-- Every guest, Rig on its position and turned to its heading: all the shadows
-- first, then the people over them.
function GuestFx.drawGuests(fx: Fx, r: Renderer)
    for _, v in fx.standIns do
        drawShadow(fx, r, v)
    end
    for _, v in fx.list do
        if v.hideLeft <= 0 then
            drawShadow(fx, r, v)
        end
    end
    for _, v in fx.standIns do
        drawBody(r, v)
    end
    for _, v in fx.list do
        if v.hideLeft <= 0 then
            drawBody(r, v)
        end
    end
end

return GuestFx
