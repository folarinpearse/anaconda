-- Anaconda: a top-down snake game. The rules live in sim.luau; this script
-- draws the playfield, instances one Person artboard per guest and drives each
-- one through its own view model, and mirrors the numbers into the Game view
-- model that the RML HUD is bound to. The floor plan, walls, exits and guests are
-- rendered to an offscreen canvas and darkened by vision.wgsl; the snake, the
-- sound rings and the HUD are drawn over that, so the snake is always visible.

local Sim = require('sim')
local Config = require('config')
local Fog = require('fog')
local Lighting = require('lighting')
local Flicker = require('flicker')
local LEVEL = require('level')

type Cell = Sim.Cell

type PersonRec = {
    instance: Artboard<Data.Person>,
    state: Sim.GuestState,
}

-- The values of the SnakeHead artboard's `state` enum (snakehead.rml).
type HeadState = 'idle' | 'lunge' | 'eat' | 'hit'

-- The body as samples down its smoothed path, neck first: where it is, how far
-- along, which way is the snake's left, and how wide.
type Body = {
    x: { number },
    y: { number },
    a: { number }, -- arc length from the neck, px
    nx: { number }, -- unit normal pointing to the snake's left
    ny: { number },
    hw: { number }, -- half-width
    n: number,
}

type Game = {
    person: Input<Artboard<Data.Person>>,
    snakeHead: Input<Artboard<Data.SnakeHead>>,
    sim: Sim.Sim,
    people: { [number]: PersonRec },
    head: Artboard<Data.SnakeHead>?, -- the one SnakeHead instance, made on the first advance
    headState: HeadState, -- the state last written to it
    floorImage: Image?, -- art/floor_base.png: the floor plan with walls and lighting baked in
    wallsImage: Image?, -- art/walls_overlay.png: the walls alone, drawn above the guests
    skinImage: Image?, -- snake_skin.png: the body's scales, 160 px long, tiling along it
    lightImage: Image?, -- snake_light.png: the room lighting over the whole level, to multiply the body by
    flickerImage: Image?, -- flicker_mask.png: each light group's share of the light, for the shader
    exitPath: Path,
    exitPaint: Paint,
    shadowPaint: Paint,
    skinSampler: ImageSampler, -- repeats along the body
    lightSampler: ImageSampler,
    size: Vector,
    scale: number,
    context: Context?,

    -- presentation clocks and state
    sinceEnd: number, -- seconds on an end screen: restart is locked out at first
    fades: { [string]: number }, -- 0-1 opacity of each screen overlay, by SCREENS name
    elapsed: number,
    beatPhase: number, -- 0-1 through the current heartbeat
    dirAngle: number, -- smoothed facing of the vision cone, radians
    faceAngle: number, -- where the drawn head points, radians: swings round across a tick
    turnFrom: number, -- the facing the current swing started from
    turnTo: number, -- ...and the heading it is swinging to
    lastDir: Cell, -- the sim.dir last looked at, to spot a turn
    seenEaten: number, -- the sim.eaten last looked at, to spot a meal
    eatUntil: number, -- sim.time until which the head shows its eat animation
    seenBump: number, -- the sim.bumpTime last looked at, to spot a new bump
    nudgeDistance: number, -- px the head leans on the current bump; 0 = no nudge
    rings: Fog.Rings,
    shadowLift: number, -- 0-1: the head's shadow swelling while it lunges or eats

    -- lights: flicker.luau's controllers, and what the vision pass and the snake make of them
    lights: Flicker.State,
    holdF: boolean, -- debug: F held, every group runs its event back to back
    holdC: boolean, -- debug: C held, chase tension stuck at 1
    sight: number, -- 0-1: how far the room the head is in has been taken in
    sightRoom: number?, -- index into Flicker.ROOMS of that room; kept while it fades out
    flash: number, -- 1 to 0: the strike flash when that room's lights come back
    sightIntensity: number, -- that room's intensity last frame, to spot the strike
    headLight: { number }, -- r, g, b the head is lit by, eased
    headLightSet: boolean, -- headLight has been seeded

    -- the vision pass: scene -> vision.wgsl -> gpu canvas -> drawImage
    scene: Canvas?,
    gpu: GPUCanvas?,
    pipeline: GPUPipeline?,
    ubo: GPUBuffer?,
    bind: GPUBindGroup?,
    gpuSampler: GPUSampler?,
    mask: Canvas?, -- one pixel per tile, white = wall: what the shader ray-marches through
    maskPath: Path,
    maskPaint: Paint,
    maskDirty: boolean, -- the mask needs drawing (again)
    flickerCanvas: Canvas?, -- flicker_mask.png drawn into a canvas, which the shader can sample
    flickerDirty: boolean, -- ...and it needs drawing (again)
    imageSampler: ImageSampler,
    uniforms: buffer,
    gpuDirty: boolean, -- canvases need (re)building for the current size
    gpuFailed: boolean, -- the vision pass is unavailable; draw plainly

    -- view model handles, cached on the second init call
    score: Property<number>?,
    length: Property<number>?,
    peopleLeft: Property<number>?,
    escaped: Property<number>?,
    health: Property<number>?,
    vision: Property<number>?,
    boostReady: Property<boolean>?,
    boostCooldown: Property<number>?,
    gameState: PropertyEnum?,
    endReason: PropertyEnum?,
    eaten: Property<number>?,
    elapsedTime: Property<number>?,
    timeText: Property<string>?, -- elapsedTime as m:ss, for the end screens
    fadeProps: { [string]: Property<number> }, -- by SCREENS name, plus 'end' and 'dim'
}

local TILE = 40
local WORLD = TILE * #LEVEL[1] -- px across the (square) level
local KAPPA = 0.5522847498
local PERSON_SIZE = 32

-- The SnakeHead artboard is 48x48, faces +x and is rigged at the neck joint;
-- keep these in step with the `Rig` node in snakehead.rml.
local HEAD_NECK_X = 12
local HEAD_NECK_Y = 24
local EAT_TIME = 0.5 -- seconds the head shows its eat animation after a meal (30 frames)
local TURN_FRACTION = 0.6 -- share of a tick the head takes to swing round to a new heading

-- The body is one textured strip down the smoothed path of the joints. It is
-- BODY_HALF_WIDTH to either side at full width, narrows to NECK_HALF just behind
-- the head (the head art's back edge) and widens to full over NECK_GROW, and
-- tapers to a point over the last TAIL_SEGMENTS segments.
local BODY_HALF_WIDTH = 17
local NECK_HALF = 11
local NECK_GROW_FROM = 6 -- arc length from the neck where it starts to widen,
local NECK_GROW_TO = 46 -- and where it is full width: about a tile back
local TAIL_SEGMENTS = 3
local SKIN_LENGTH = 160 -- game px of snake_skin.png before it repeats
local FILLET = TILE / 2 -- radius of every rounded corner
local FILLET_STEPS = 8
local RUN_STEP = 10 -- px between samples on a straight run
local LIGHT_CHUNK = TILE -- the light pass is cut into pieces about this long

-- The body is lit from straight above and casts a shadow, which the head's
-- lunge and eat swell and blur.
local SHADOW_DX = 3
local SHADOW_DY = 4
local SHADOW_LIFT_DX = 6
local SHADOW_LIFT_DY = 8
local SHADOW_ALPHA = 89 -- 35% of 255
local SHADOW_FEATHER = 3 -- px of blur on the shadow's edge
local SHADOW_LIFT_FEATHER = 6
local SHADOW_LIFT_TIME = 0.08 -- seconds to swell, and again to settle
local HEAD_SHADOW_AHEAD = 16 -- px from the neck to the head's shadow
local HEAD_SHADOW_ALONG = 22 -- its half-length along the heading,
local HEAD_SHADOW_ACROSS = 20 -- and across it
local HEAD_LIGHT_AHEAD = 16 -- px from the neck to where the head's light is read

-- GLFW key codes -> direction.
local KEY_DIRS: { [number]: Cell } = {
    [262] = Sim.RIGHT, [68] = Sim.RIGHT, -- right arrow, D
    [263] = Sim.LEFT, [65] = Sim.LEFT, -- left arrow, A
    [264] = Sim.DOWN, [83] = Sim.DOWN, -- down arrow, S
    [265] = Sim.UP, [87] = Sim.UP, -- up arrow, W
}
local KEY_SPACE = 32
local KEY_F = 70 -- debug: held, every light group runs its event back to back
local KEY_C = 67 -- debug: held, chase tension is 1
local KEY_SHIFTS: { [number]: boolean } = { [340] = true, [344] = true } -- left, right
local SHAKE_AMPLITUDE = 5 -- px at the moment of impact
-- px the drawn head leans into a bump, at its peak. Interior wall art sits back
-- from the tile edge, so it gets the long lean; the outer walls are flush.
local NUDGE_INTERIOR = 10 -- interior walls and the snake's own body
local NUDGE_BORDER = 1 -- outer border tiles
local NUDGE_OUT_TIME = 0.06 -- seconds to ease out to the peak
local NUDGE_BACK_TIME = 0.2 -- seconds to spring back
local BACKGROUND = Color.rgb(20, 23, 28) -- the artboard fill, behind the letterbox
local UNIFORM_SIZE = 176 -- bytes; the Uniforms struct in vision.wgsl
local TURN_SPEED = 14 -- how fast the cone swings round to a new heading, per second
local PI = math.pi

-- The screen overlays in scene.rml. Each is shown while the game is not playing,
-- the first for `ready` and the rest for the end reasons of the same name.
local SCREENS = { 'ready', 'cleared', 'walls', 'escaped' }
-- The view model's number property for each overlay's opacity. 'end' is the
-- shared stats block under the three end screens, 'dim' the scrim over the board.
local FADE_PROPS: { [string]: string } = {
    ready = 'readyAlpha',
    cleared = 'clearedAlpha',
    walls = 'wallsAlpha',
    escaped = 'escapedAlpha',
    ['end'] = 'endAlpha',
    dim = 'dimAlpha',
}

local function addRect(path: Path, x: number, y: number)
    -- Same winding for every rect so they can share one path.
    path:moveTo(Vector.xy(x, y))
    path:lineTo(Vector.xy(x + TILE, y))
    path:lineTo(Vector.xy(x + TILE, y + TILE))
    path:lineTo(Vector.xy(x, y + TILE))
    path:close()
end

local function addCircle(path: Path, cx: number, cy: number, r: number)
    local k = r * KAPPA
    path:moveTo(Vector.xy(cx + r, cy))
    path:cubicTo(Vector.xy(cx + r, cy + k), Vector.xy(cx + k, cy + r), Vector.xy(cx, cy + r))
    path:cubicTo(Vector.xy(cx - k, cy + r), Vector.xy(cx - r, cy + k), Vector.xy(cx - r, cy))
    path:cubicTo(Vector.xy(cx - r, cy - k), Vector.xy(cx - k, cy - r), Vector.xy(cx, cy - r))
    path:cubicTo(Vector.xy(cx + k, cy - r), Vector.xy(cx + r, cy - k), Vector.xy(cx + r, cy))
    path:close()
end

-- An oval at (cx, cy) with half-axes `along` x `across`, its long axis turned
-- to the unit direction (tx, ty). Wound the same way as addCircle, so several
-- can share one path.
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

local function smoothstep(t: number): number
    return t * t * (3 - 2 * t)
end

-- Rotates from angle a toward b by fraction t, the short way round.
local function lerpAngle(a: number, b: number, t: number): number
    local diff = (b - a + PI) % (2 * PI) - PI
    return a + diff * t
end

-- Pushes the sim's numbers into the Game view model; the HUD binds to it.
local function publish(self: Game)
    local sim = self.sim
    local score = self.score
    if score ~= nil and score.value ~= sim.score then
        score.value = sim.score
    end
    local length = self.length
    if length ~= nil and length.value ~= #sim.cur then
        length.value = #sim.cur
    end
    local peopleLeft = self.peopleLeft
    local left = Sim.peopleLeft(sim)
    if peopleLeft ~= nil and peopleLeft.value ~= left then
        peopleLeft.value = left
    end
    local escaped = self.escaped
    if escaped ~= nil and escaped.value ~= sim.escaped then
        escaped.value = sim.escaped
    end
    local health = self.health
    if health ~= nil and health.value ~= sim.hp then
        health.value = sim.hp
    end
    local vision = self.vision
    if vision ~= nil and vision.value ~= sim.vision then
        vision.value = sim.vision
    end
    local boostReady = self.boostReady
    local ready = Sim.boostReady(sim)
    if boostReady ~= nil and boostReady.value ~= ready then
        boostReady.value = ready
    end
    local boostCooldown = self.boostCooldown
    local cooldown = Sim.boostCooldown(sim)
    if boostCooldown ~= nil and boostCooldown.value ~= cooldown then
        boostCooldown.value = cooldown
    end
    local gameState = self.gameState
    if gameState ~= nil and gameState.value ~= sim.state then
        gameState.value = sim.state
    end
    local endReason = self.endReason
    if endReason ~= nil and endReason.value ~= sim.endReason then
        endReason.value = sim.endReason
    end
    local eaten = self.eaten
    if eaten ~= nil and eaten.value ~= sim.eaten then
        eaten.value = sim.eaten
    end
    local elapsedTime = self.elapsedTime
    if elapsedTime ~= nil and elapsedTime.value ~= sim.playTime then
        elapsedTime.value = sim.playTime
    end
    local timeText = self.timeText
    if timeText ~= nil then
        local seconds = math.floor(sim.playTime)
        local text = string.format('%d:%02d', seconds // 60, seconds % 60)
        if timeText.value ~= text then
            timeText.value = text
        end
    end
end

-- Which overlay the game is showing, if any.
local function screenOf(sim: Sim.Sim): string?
    if sim.state == 'ready' then
        return 'ready'
    elseif (sim.state == 'won' or sim.state == 'lost') and sim.endReason ~= 'none' then
        return sim.endReason
    end
    return nil
end

-- Fades each overlay toward 1 (the one on show) or 0 (the rest), and mirrors the
-- opacities into the view model for scene.rml to bind to.
local function stepFades(self: Game, seconds: number)
    local active = screenOf(self.sim)
    local shown = 0.0
    local ending = 0.0
    for _, name in SCREENS do
        local v = self.fades[name]
        if name == active then
            v = math.min(1, v + seconds / Config.OVERLAY_FADE_IN)
        else
            v = math.max(0, v - seconds / Config.OVERLAY_FADE_OUT)
        end
        self.fades[name] = v
        shown = math.max(shown, v)
        if name ~= 'ready' then
            ending = math.max(ending, v)
        end
    end
    self.fades['end'] = ending
    self.fades.dim = shown
    for name, prop in self.fadeProps do
        if prop.value ~= self.fades[name] then
            prop.value = self.fades[name]
        end
    end
end

-- One Person artboard instance per live guest, each with its own view model.
local function syncPeople(self: Game, seconds: number)
    for _, g in self.sim.guests do
        local rec = self.people[g.id]
        if g.gone then
            self.people[g.id] = nil
        else
            if rec == nil then
                local instance = self.person:instance(Data.Person.new())
                instance.data.state.value = g.state
                instance:advance(0)
                rec = { instance = instance, state = g.state }
                self.people[g.id] = rec
            elseif rec.state ~= g.state then
                rec.instance.data.state.value = g.state
                rec.state = g.state
            end
            rec.instance:advance(seconds)
        end
    end
end

-- A fresh game, straight into play. The sim resets the score, health, clock
-- and ending; this clears what main keeps on top of that.
local function restart(self: Game)
    self.people = {}
    Sim.reset(self.sim, 'playing')
    self.rings = Fog.newRings()
    Flicker.reset(self.lights)
    self.sight = 0
    self.sightRoom = nil
    self.flash = 0
    self.sightIntensity = 1
    self.dirAngle = 0 -- the snake starts facing right
    local dir = self.sim.dir
    local facing = math.atan2(dir.y, dir.x)
    self.lastDir = { x = dir.x, y = dir.y }
    self.faceAngle = facing
    self.turnFrom = facing
    self.turnTo = facing
    self.seenEaten = 0
    self.shadowLift = 0
    self.eatUntil = -1
    self.beatPhase = 0
    self.sinceEnd = 0
    publish(self)
end

-- A click or Space on an end screen starts the next game, but not in the first
-- moments after the game ends: a press meant for the last lunge must not skip
-- the result.
local function restartIfAllowed(self: Game)
    if self.sinceEnd >= Config.RESTART_LOCKOUT then
        restart(self)
    end
end

function init(self: Game, context: Context): boolean
    -- init runs twice and the view model is absent on the first call.
    self.context = context
    -- Looked up by name, which nothing validates: a typo is nil, not a build error.
    self.floorImage = context:image('floor_base')
    self.wallsImage = context:image('walls_overlay')
    if self.floorImage == nil or self.wallsImage == nil then
        print('playfield art not found: floor_base / walls_overlay')
    end
    self.skinImage = context:image('snake_skin')
    self.lightImage = context:image('snake_light')
    self.flickerImage = context:image('flicker_mask')
    if self.skinImage == nil or self.lightImage == nil or self.flickerImage == nil then
        print('lighting art not found: snake_skin / snake_light / flicker_mask')
    end
    local vm = context:viewModel()
    if vm == nil then
        return true
    end
    self.score = vm:getNumber('score')
    self.length = vm:getNumber('length')
    self.peopleLeft = vm:getNumber('peopleLeft')
    self.escaped = vm:getNumber('escaped')
    self.health = vm:getNumber('health')
    self.vision = vm:getNumber('vision')
    self.boostReady = vm:getBoolean('boostReady')
    self.boostCooldown = vm:getNumber('boostCooldown')
    self.gameState = vm:getEnum('gameState')
    self.endReason = vm:getEnum('endReason')
    self.eaten = vm:getNumber('eaten')
    self.elapsedTime = vm:getNumber('elapsedTime')
    self.timeText = vm:getString('timeText')
    for name, key in FADE_PROPS do
        local prop = vm:getNumber(key)
        if prop ~= nil then
            self.fadeProps[name] = prop
        end
    end
    publish(self)
    return true
end

-- The canvases are sized in device pixels (points x scale), not points, or the
-- scene would be upscaled on a high-DPI display. They are built lazily in draw,
-- where GPU work happens.
function resize(self: Game, size: Vector, scale: number)
    self.size = size
    self.scale = scale
    self.gpuDirty = true
end

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
    if event.key == KEY_F or event.key == KEY_C then
        local held = event.phase ~= 'up'
        if event.key == KEY_F then
            self.holdF = held
        else
            self.holdC = held
        end
        return true
    end
    if event.phase ~= 'down' then
        return false
    end
    local sim = self.sim
    if event.key == KEY_SPACE then
        if sim.state == 'ready' then
            Sim.start(sim)
            return true
        elseif sim.state == 'won' or sim.state == 'lost' then
            restartIfAllowed(self)
            return true
        end
        Sim.lunge(sim) -- during play, Space is the boost
        return true
    end
    if KEY_SHIFTS[event.key] then
        return Sim.lunge(sim)
    end
    local dir = KEY_DIRS[event.key]
    if dir ~= nil and sim.state == 'playing' then
        Sim.queueTurn(sim, dir)
        return true
    end
    return false
end

-- A click or tap starts a game that is waiting, same as Space, lunges during
-- play and starts a new game from an end screen. Focus for the keys is
-- requested by the state machine's pointer listener in scene.rml.
function pointerDown(self: Game, event: PointerEvent)
    local sim = self.sim
    if sim.state == 'ready' then
        Sim.start(sim)
        event:hit()
    elseif sim.state == 'playing' then
        Sim.lunge(sim)
        event:hit()
    elseif sim.state == 'won' or sim.state == 'lost' then
        restartIfAllowed(self)
        event:hit()
    end
end

-- Between ticks everything slides from its previous cell to its current one.
-- When the game is not running it rests on its last cell.
local function snakeAlphaOf(sim: Sim.Sim): number
    if sim.state == 'playing' then
        return math.clamp(sim.snakeAcc / Sim.TICK, 0, 1)
    end
    return 1.0
end

local function guestAlphaOf(sim: Sim.Sim): number
    if sim.state == 'playing' then
        return math.clamp(sim.guestAcc / Sim.GUEST_TICK, 0, 1)
    end
    return 1.0
end

-- How far the drawn head leans toward the wall, 0-1: eases out to 1, then
-- springs back to 0. Plays on every bump, damaging or not.
local function nudgeOf(sim: Sim.Sim): number
    if sim.bumpTime < 0 then
        return 0
    end
    local age = sim.time - sim.bumpTime
    if age < NUDGE_OUT_TIME then
        local rest = 1 - age / NUDGE_OUT_TIME
        return 1 - rest * rest
    elseif age < NUDGE_OUT_TIME + NUDGE_BACK_TIME then
        local rest = 1 - (age - NUDGE_OUT_TIME) / NUDGE_BACK_TIME
        return rest * rest
    end
    return 0
end

-- How far the head should lean on the bump that just happened: none if the bump
-- was resolved by swapping ends (the head and tail traded cells, so the old
-- bump direction means nothing to the new head); otherwise by the tile that was
-- hit, head cell + bumpDir. Only the outer border is flush with the art.
local function nudgeDistanceFor(sim: Sim.Sim, oldHead: Cell, oldTail: Cell): number
    local bump = sim.bumpDir
    local n = #sim.cur
    if bump == nil then
        return 0
    end
    local head = sim.cur[1]
    local tail = sim.cur[n]
    if n >= 2 and head.x == oldTail.x and head.y == oldTail.y and tail.x == oldHead.x and tail.y == oldHead.y then
        return 0
    end
    local tx = head.x + bump.x
    local ty = head.y + bump.y
    if tx == 0 or ty == 0 or tx == sim.cols - 1 or ty == sim.rows - 1 then
        return NUDGE_BORDER
    end
    return NUDGE_INTERIOR
end

-- The head centre in tile units, mid-slide between ticks.
local function headTile(sim: Sim.Sim): (number, number)
    local a = sim.prev[1]
    local b = sim.cur[1]
    local t = snakeAlphaOf(sim)
    return a.x + (b.x - a.x) * t + 0.5, a.y + (b.y - a.y) * t + 0.5
end

-- What the head should be doing now: a hit outranks a meal, which outranks a lunge.
local function headStateOf(sim: Sim.Sim, eatUntil: number): HeadState
    if sim.hitTime >= 0 and sim.time - sim.hitTime < Config.HIT_FX_TIME then
        return 'hit'
    elseif sim.time < eatUntil then
        return 'eat'
    elseif sim.lungeLeft > 0 then
        return 'lunge'
    end
    return 'idle'
end

-- Drives the SnakeHead instance: its state and hunger through its view model, and
-- where it points. The facing swings from the previous heading to the new one
-- over the first part of the tick the turn happens in, so it is tied to the same
-- clock as the slide and never snaps.
local function headOf(self: Game): Artboard<Data.SnakeHead>
    local existing = self.head
    if existing ~= nil then
        return existing
    end
    local made = self.snakeHead:instance(Data.SnakeHead.new())
    made:advance(0)
    self.head = made
    return made
end

local function syncHead(self: Game, seconds: number)
    local sim = self.sim
    local head = headOf(self)

    if sim.eaten > self.seenEaten then
        self.eatUntil = sim.time + EAT_TIME
    end
    self.seenEaten = sim.eaten
    local state = headStateOf(sim, self.eatUntil)
    if state ~= self.headState then
        head.data.state.value = state
        self.headState = state
    end
    local hunger = math.clamp((1 - sim.vision) / (1 - Config.VISION_FLOOR), 0, 1)
    if head.data.hunger.value ~= hunger then
        head.data.hunger.value = hunger
    end
    head:advance(seconds)

    local dir = sim.dir
    if dir.x ~= self.lastDir.x or dir.y ~= self.lastDir.y then
        self.lastDir = { x = dir.x, y = dir.y }
        self.turnFrom = self.faceAngle -- from wherever it is pointing now, so a reversal mid-swing stays smooth
        self.turnTo = math.atan2(dir.y, dir.x)
    end
    local swing = math.clamp(snakeAlphaOf(sim) / TURN_FRACTION, 0, 1)
    self.faceAngle = lerpAngle(self.turnFrom, self.turnTo, smoothstep(swing))
end

-- The head's shadow swells and blurs while it lunges or eats, and settles after.
local function stepShadowLift(self: Game, seconds: number)
    local swelling = self.headState == 'lunge' or self.headState == 'eat'
    local target = if swelling then 1 else 0
    local step = seconds / SHADOW_LIFT_TIME
    if self.shadowLift < target then
        self.shadowLift = math.min(target, self.shadowLift + step)
    else
        self.shadowLift = math.max(target, self.shadowLift - step)
    end
end

-- The room the head is in comes into view over ROOM_SIGHT_RISE and goes again
-- over ROOM_SIGHT_FALL after the head leaves it; the room's rect is kept while
-- it fades. When that room's lights come back from out to on, it flashes.
local function stepRoomSight(self: Game, seconds: number)
    local room = self.lights.room
    local shown = self.sightRoom
    if room ~= nil and (shown == nil or shown == room) then
        self.sightRoom = room
        self.sight = math.min(1, self.sight + seconds / Config.ROOM_SIGHT_RISE)
    else
        self.sight = math.max(0, self.sight - seconds / Config.ROOM_SIGHT_FALL)
        if self.sight <= 0 then
            self.sightRoom = nil
        end
    end

    self.flash = math.max(0, self.flash - seconds / Config.ROOM_FLASH_TIME)
    local now = self.sightRoom
    local intensity = if now ~= nil then self.lights.intensity[Flicker.ROOMS[now].group] else 1
    if now ~= nil and now == room then
        if self.sightIntensity < 0.2 and intensity > 0.8 and Flicker.tryFlash(self.lights) then
            self.flash = 1
        end
    else
        self.flash = 0 -- only the room you are in ever flashes
    end
    self.sightIntensity = intensity
end

-- The head is lit by the room's light 16 px ahead of the neck, eased so a
-- room's lights failing dims it over a moment rather than in one frame.
local function stepHeadLight(self: Game, seconds: number)
    local hx, hy = headTile(self.sim)
    local x = hx + math.cos(self.faceAngle) * HEAD_LIGHT_AHEAD / TILE
    local y = hy + math.sin(self.faceAngle) * HEAD_LIGHT_AHEAD / TILE
    local r, g, b = Lighting.lightRgb(x, y)
    local light = self.headLight
    if not self.headLightSet then
        self.headLightSet = true
        light[1], light[2], light[3] = r, g, b
        return
    end
    local k = 1 - math.exp(-seconds / Config.HEAD_LIGHT_TIME)
    light[1] += (r - light[1]) * k
    light[2] += (g - light[2]) * k
    light[3] += (b - light[3]) * k
end

function advance(self: Game, seconds: number): boolean
    local sim = self.sim
    local oldHead = { x = sim.cur[1].x, y = sim.cur[1].y }
    local oldTail = { x = sim.cur[#sim.cur].x, y = sim.cur[#sim.cur].y }
    Sim.update(sim, seconds)
    if sim.bumpTime ~= self.seenBump then
        self.seenBump = sim.bumpTime
        if sim.bumpTime >= 0 then
            self.nudgeDistance = nudgeDistanceFor(sim, oldHead, oldTail)
        end
    end

    -- Under a screen overlay the game is frozen: the guests stop mid-pose and the
    -- clocks that drive the shader and heartbeat stand still. (The win hold is
    -- still the game: the last guest finishes being eaten and the floor lights up.)
    local live = sim.state == 'playing'
    local liveSeconds = if live then seconds else 0
    syncPeople(self, liveSeconds)
    syncHead(self, liveSeconds)
    stepShadowLift(self, seconds)
    publish(self)

    if sim.state == 'won' or sim.state == 'lost' then
        self.sinceEnd += seconds
    else
        self.sinceEnd = 0
    end
    stepFades(self, seconds)

    -- Presentation clocks.
    self.elapsed += liveSeconds
    self.beatPhase = (self.beatPhase + liveSeconds * Fog.beatRate(sim.vision)) % 1

    -- The lights: every group's intensity, the room in view, the head's light.
    local lx, ly = headTile(sim)
    Flicker.update(self.lights, liveSeconds, {
        playing = live,
        headX = lx,
        headY = ly,
        lunging = sim.lungeLeft > 0,
        guests = sim.guests,
        beatPhase = self.beatPhase,
        forceEvents = self.holdF,
        forceChase = self.holdC,
    })
    Lighting.setIntensities(self.lights.intensity)
    stepRoomSight(self, seconds)
    stepHeadLight(self, seconds)

    -- Swing the cone round to the new heading rather than snapping.
    local target = math.atan2(sim.dir.y, sim.dir.x)
    local diff = (target - self.dirAngle + PI) % (2 * PI) - PI
    self.dirAngle += diff * math.min(1, seconds * TURN_SPEED)

    -- Sound rings from guests the player cannot see.
    if sim.state == 'playing' then
        local hx, hy = headTile(sim)
        local dx = math.cos(self.dirAngle)
        local dy = math.sin(self.dirAngle)
        local function isWall(tx: number, ty: number): boolean
            return Sim.isWall(sim, tx, ty)
        end
        Fog.stepRings(self.rings, sim.guests, function(g: any)
            local guest = g :: Sim.Guest
            if Fog.inView(hx, hy, dx, dy, sim.vision, sim.reveal, guest.cell.x + 0.5, guest.cell.y + 0.5, isWall) then
                return true
            end
            -- A guest in the room the snake is in is seen while the room is lit.
            local shown = self.sightRoom
            if shown ~= nil then
                local room = Flicker.ROOMS[shown]
                local inside = guest.cell.x >= room.x0
                    and guest.cell.x <= room.x1
                    and guest.cell.y >= room.y0
                    and guest.cell.y <= room.y1
                return inside and Fog.roomSeen(smoothstep(self.sight), self.lights.intensity[room.group])
            end
            return false
        end, seconds)
    else
        self.rings = Fog.newRings()
    end
    return true
end

local function lerpCell(a: Cell, b: Cell, t: number): Vector
    return Vector.xy(
        ((a.x + (b.x - a.x) * t) + 0.5) * TILE,
        ((a.y + (b.y - a.y) * t) + 0.5) * TILE
    )
end

-- (Re)builds the offscreen scene canvas, the GPU canvas the shader draws into
-- and the bind group that wires the scene in as a texture.
local function buildGpu(self: Game)
    local context = self.context
    if context == nil then
        return
    end
    local w = math.max(1, math.floor(self.size.x * self.scale))
    local h = math.max(1, math.floor(self.size.y * self.scale))
    local scene: Canvas
    local gpu: GPUCanvas
    local pipeline: GPUPipeline
    local existingScene = self.scene
    local existingGpu = self.gpu
    local existingPipeline = self.pipeline
    if existingScene ~= nil and existingGpu ~= nil and existingPipeline ~= nil then
        scene = existingScene
        gpu = existingGpu
        pipeline = existingPipeline
        scene:resize(w, h)
        gpu:resize(w, h)
    else
        local shader = context:shader('vision')
        if shader == nil then
            error('shader "vision" not found')
        end
        scene = context:canvas({ width = w, height = h })
        gpu = context:gpuCanvas({ width = w, height = h })
        pipeline = GPUPipeline.new({
            vertex = shader,
            fragment = shader,
            vertexLayout = {},
            colorTargets = { { format = gpu.format } },
        })
        self.scene = scene
        self.gpu = gpu
        self.pipeline = pipeline
        self.ubo = GPUBuffer.new({ size = UNIFORM_SIZE, usage = 'uniform' })
        self.gpuSampler = GPUSampler.new({ min = 'linear', mag = 'linear' })
    end
    -- The wall mask is one pixel per tile whatever the screen size, so it is
    -- made once and only drawn again if it is (re)created.
    local mask: Canvas
    local existingMask = self.mask
    if existingMask ~= nil then
        mask = existingMask
    else
        mask = context:canvas({ width = self.sim.cols, height = self.sim.rows })
        self.mask = mask
        self.maskDirty = true
    end
    -- A view taken straight from an image asset samples as zeros, so the light
    -- groups' mask goes through a canvas too. Black (no group provides any of the
    -- light) until it is drawn, which leaves every room unaffected.
    local flickerCanvas: Canvas
    local existingFlicker = self.flickerCanvas
    if existingFlicker ~= nil then
        flickerCanvas = existingFlicker
    else
        local image = self.flickerImage
        flickerCanvas = context:canvas({
            width = if image ~= nil then image.width else 768,
            height = if image ~= nil then image.height else 192,
        })
        self.flickerCanvas = flickerCanvas
        self.flickerDirty = true
    end
    self.bind = GPUBindGroup.new({
        layout = pipeline:getBindGroupLayout(0),
        ubos = { { slot = 0, buffer = self.ubo :: GPUBuffer } },
        textures = {
            { slot = 1, view = scene.image:view() },
            { slot = 3, view = mask.image:view() },
            { slot = 4, view = flickerCanvas.image:view() },
        },
        samplers = { { slot = 2, sampler = self.gpuSampler :: GPUSampler } },
    })
    self.gpuDirty = false
end

-- White wall tiles on black, from the level data (not the wall artwork, so it
-- survives the art pass).
local function drawMask(self: Game)
    local mask = self.mask :: Canvas
    local r = mask:beginFrame({ clearColor = Color.rgb(0, 0, 0) })
    r:save()
    r:transform(Mat2D.withScale(mask.width / (TILE * self.sim.cols), mask.height / (TILE * self.sim.rows)))
    r:drawPath(self.maskPath, self.maskPaint)
    r:restore()
    mask:endFrame()
    self.maskDirty = false
end

local function drawFlickerMask(self: Game)
    local canvas = self.flickerCanvas :: Canvas
    local r = canvas:beginFrame({ clearColor = Color.rgb(0, 0, 0) })
    local image = self.flickerImage
    if image ~= nil then
        r:drawImage(image, self.imageSampler, 'srcOver', 1)
    end
    canvas:endFrame()
    self.flickerDirty = false
end

-- Fills the shader's Uniforms struct (layout in vision.wgsl).
local function writeUniforms(self: Game, ox: number, oy: number, pxPerTile: number, k: number)
    local sim = self.sim
    local b = self.uniforms
    local hx, hy = headTile(sim)
    local impactX, impactY, impactAge = -100.0, -100.0, 99.0
    local hitCell = sim.hitCell
    if hitCell ~= nil then
        impactX = hitCell.x + 0.5
        impactY = hitCell.y + 0.5
        impactAge = sim.time - sim.hitTime
    end
    local gpu = self.gpu :: GPUCanvas
    buffer.writef32(b, 0, hx)
    buffer.writef32(b, 4, hy)
    buffer.writef32(b, 8, math.cos(self.dirAngle))
    buffer.writef32(b, 12, math.sin(self.dirAngle))
    buffer.writef32(b, 16, impactX)
    buffer.writef32(b, 20, impactY)
    buffer.writef32(b, 24, gpu.width)
    buffer.writef32(b, 28, gpu.height)
    buffer.writef32(b, 32, ox * k)
    buffer.writef32(b, 36, oy * k)
    buffer.writef32(b, 40, pxPerTile)
    buffer.writef32(b, 44, sim.vision)
    buffer.writef32(b, 48, sim.reveal)
    buffer.writef32(b, 52, self.elapsed)
    buffer.writef32(b, 56, Fog.heartbeat(self.beatPhase))
    buffer.writef32(b, 60, sim.hp / Config.MAX_HP)
    buffer.writef32(b, 64, impactAge)
    buffer.writef32(b, 68, Fog.coneLength(sim.vision))
    buffer.writef32(b, 72, Fog.coneHalfAngle(sim.vision))
    buffer.writef32(b, 76, Config.AMBIENT)
    buffer.writef32(b, 80, sim.cols)
    buffer.writef32(b, 84, sim.rows)
    buffer.writef32(b, 88, 0)
    buffer.writef32(b, 92, 0)

    -- Light group intensities, in the order of the mask atlas.
    local intensity = self.lights.intensity
    for g = 1, Flicker.GROUP_COUNT do
        buffer.writef32(b, 96 + (g - 1) * 4, intensity[g])
    end
    buffer.writef32(b, 136, 0)
    buffer.writef32(b, 140, 0)

    -- The room in view: its rect in tiles, half a tile wider all round so its
    -- own walls are in, and how far it has been taken in. It keeps the last room's
    -- rect while that fades out.
    local shown = self.sightRoom
    if shown ~= nil then
        local room = Flicker.ROOMS[shown]
        buffer.writef32(b, 144, room.x0 - 0.5)
        buffer.writef32(b, 148, room.y0 - 0.5)
        buffer.writef32(b, 152, room.x1 + 1.5)
        buffer.writef32(b, 156, room.y1 + 1.5)
        buffer.writef32(b, 160, smoothstep(self.sight))
        buffer.writef32(b, 164, self.flash)
        buffer.writef32(b, 168, intensity[room.group])
    else
        for off = 144, 156, 4 do
            buffer.writef32(b, off, 0)
        end
        buffer.writef32(b, 160, 0)
        buffer.writef32(b, 164, 0)
        buffer.writef32(b, 168, 0)
    end
    buffer.writef32(b, 172, 0)
    ;(self.ubo :: GPUBuffer):write(b)
end

-- The part of the world the shader darkens: floor plan, exits, guests, then the
-- walls over them. Both images are one pixel per world unit (960 = 24 x TILE), so
-- drawn at the origin they line up with the tiles. The art is for looks only:
-- collision and vision occlusion still come from the level data.
local function drawWorld(self: Game, r: Renderer)
    local sim = self.sim
    local floorImage = self.floorImage
    if floorImage ~= nil then
        r:drawImage(floorImage, self.imageSampler, 'srcOver', 1)
    end
    r:drawPath(self.exitPath, self.exitPaint)

    local guestAlpha = guestAlphaOf(sim)
    for _, g in sim.guests do
        local rec = self.people[g.id]
        if rec ~= nil then
            local p = lerpCell(g.prev, g.cell, guestAlpha)
            r:save()
            r:transform(Mat2D.withTranslation(p.x - PERSON_SIZE / 2, p.y - PERSON_SIZE / 2 - 6))
            rec.instance:draw(r)
            r:restore()
        end
    end

    local wallsImage = self.wallsImage
    if wallsImage ~= nil then
        r:drawImage(wallsImage, self.imageSampler, 'srcOver', 1)
    end
end

-- A faint expanding ring where an unseen guest is making noise: a rough
-- location, not the guest.
local function drawRings(self: Game, renderer: Renderer)
    for _, ring in self.rings.list do
        local t = ring.age / Config.RING_LIFETIME
        local eased = 1 - (1 - t) * (1 - t)
        local radius = (0.25 + (Config.RING_MAX_RADIUS - 0.25) * eased) * TILE
        local alpha = math.floor(150 * (1 - t) * (1 - t))
        local color = if ring.flee then Color.rgba(255, 96, 64, alpha) else Color.rgba(255, 214, 96, alpha)
        local path = Path.new()
        addCircle(path, ring.x * TILE, ring.y * TILE, radius)
        renderer:drawPath(path, Paint.with({ style = 'stroke', thickness = 3, color = color }))
    end
end

-- GLSL smoothstep: 0 below edge0, 1 above edge1, smooth between.
local function smoothBetween(edge0: number, edge1: number, x: number): number
    return smoothstep(math.clamp((x - edge0) / (edge1 - edge0), 0, 1))
end

-- Samples down the body's path, neck first, with the corners rounded. `pts` are
-- the joints, head first. Every corner becomes a quadratic fillet from FILLET px
-- before the joint to FILLET px after it, the joint as its control point, in
-- FILLET_STEPS steps (less where the segments are shorter than twice that, so
-- neighbouring fillets never overlap); straight runs get a sample every
-- RUN_STEP px. `taperJoint` is the joint where the tail starts to narrow.
local function buildBody(pts: { Vector }, taperJoint: number): Body
    -- Joints that sit on the one before have no direction: leave them out.
    local jx: { number } = {}
    local jy: { number } = {}
    local joint: { number } = {} -- for each of `pts`, its place in jx / jy
    local m = 0
    for i, p in pts do
        if m == 0 or (p.x - jx[m]) ^ 2 + (p.y - jy[m]) ^ 2 > 0.01 then
            m += 1
            jx[m] = p.x
            jy[m] = p.y
        end
        joint[i] = m
    end

    -- Each segment's length and unit direction.
    local len: { number } = {}
    local dx: { number } = {}
    local dy: { number } = {}
    for k = 1, m - 1 do
        local sx = jx[k + 1] - jx[k]
        local sy = jy[k + 1] - jy[k]
        len[k] = math.sqrt(sx * sx + sy * sy)
        dx[k] = sx / len[k]
        dy[k] = sy / len[k]
    end

    local x: { number } = {}
    local y: { number } = {}
    local at: { number } = {} -- sample index at each joint (the middle of a fillet)
    local n = 0
    local lastX, lastY = jx[1], jy[1]
    local function emit(px: number, py: number)
        n += 1
        x[n] = px
        y[n] = py
        lastX, lastY = px, py
    end
    local function run(toX: number, toY: number)
        local fromX, fromY = lastX, lastY
        local length = math.sqrt((toX - fromX) ^ 2 + (toY - fromY) ^ 2)
        if length < 0.01 then
            return
        end
        local steps = math.ceil(length / RUN_STEP)
        for s = 1, steps do
            emit(fromX + (toX - fromX) * s / steps, fromY + (toY - fromY) * s / steps)
        end
    end

    emit(jx[1], jy[1])
    at[1] = 1
    for k = 2, m do
        local cornerR = 0.0
        if k < m then
            local cross = dx[k - 1] * dy[k] - dy[k - 1] * dx[k]
            local dot = dx[k - 1] * dx[k] + dy[k - 1] * dy[k]
            if math.abs(cross) > 0.001 or dot < 0 then
                cornerR = math.min(FILLET, len[k - 1] / 2, len[k] / 2)
            end
        end
        if cornerR > 0.01 then
            local ax, ay = jx[k] - dx[k - 1] * cornerR, jy[k] - dy[k - 1] * cornerR
            local bx, by = jx[k] + dx[k] * cornerR, jy[k] + dy[k] * cornerR
            run(ax, ay)
            for s = 1, FILLET_STEPS do
                local t = s / FILLET_STEPS
                local u = 1 - t
                emit(u * u * ax + 2 * u * t * jx[k] + t * t * bx, u * u * ay + 2 * u * t * jy[k] + t * t * by)
                if s == FILLET_STEPS // 2 then
                    at[k] = n
                end
            end
        else
            run(jx[k], jy[k])
            at[k] = n
        end
    end

    -- Arc length from the neck, and which way each sample faces. The path runs
    -- neck to tail, so the snake's left is the tangent turned the other way.
    local a: { number } = { 0 }
    for i = 2, n do
        a[i] = a[i - 1] + math.sqrt((x[i] - x[i - 1]) ^ 2 + (y[i] - y[i - 1]) ^ 2)
    end
    local nx: { number } = {}
    local ny: { number } = {}
    for i = 1, n do
        local tx = x[math.min(i + 1, n)] - x[math.max(i - 1, 1)]
        local ty = y[math.min(i + 1, n)] - y[math.max(i - 1, 1)]
        local tl = math.sqrt(tx * tx + ty * ty)
        if tl < 0.0001 then
            nx[i], ny[i] = 0, -1
        else
            nx[i], ny[i] = -ty / tl, tx / tl
        end
    end

    -- Half-width: full, narrowed behind the head, and tapered to a point at the tip.
    local taperFrom = a[at[joint[taperJoint]]]
    local span = math.max(0.001, a[n] - taperFrom)
    local hw: { number } = {}
    for i = 1, n do
        local neck = NECK_HALF + (BODY_HALF_WIDTH - NECK_HALF) * smoothBetween(NECK_GROW_FROM, NECK_GROW_TO, a[i])
        local tail = if a[i] <= taperFrom then 1 else math.max(0, 1 - (a[i] - taperFrom) / span)
        hw[i] = neck * tail
    end
    return { x = x, y = y, a = a, nx = nx, ny = ny, hw = hw, n = n }
end

-- The strip over samples i0..i1 as mesh buffers: two vertices per sample, the
-- snake's left (v = 0) and right (v = 1). Texture coordinates run along the skin
-- by arc length from the neck, so every scale keeps its distance from the head
-- as the body slides along its path, or, for the light pass, are the vertex's
-- place in the level.
local function stripMesh(body: Body, i0: number, i1: number, onSkin: boolean): (VertexBuffer, VertexBuffer, TriangleBuffer)
    local vertices = VertexBuffer()
    local uvs = VertexBuffer()
    local triangles = TriangleBuffer()
    for i = i0, i1 do
        local ox = body.nx[i] * body.hw[i]
        local oy = body.ny[i] * body.hw[i]
        local lx, ly = body.x[i] + ox, body.y[i] + oy
        local rx, ry = body.x[i] - ox, body.y[i] - oy
        vertices:add(Vector.xy(lx, ly), Vector.xy(rx, ry))
        if onSkin then
            local u = body.a[i] / SKIN_LENGTH
            uvs:add(Vector.xy(u, 0), Vector.xy(u, 1))
        else
            uvs:add(Vector.xy(lx / WORLD, ly / WORLD), Vector.xy(rx / WORLD, ry / WORLD))
        end
        if i > i0 then
            local k = (i - i0) * 2 -- the vertices before this pair
            triangles:add(k - 1, k, k + 1)
            triangles:add(k, k + 2, k + 1)
        end
    end
    return vertices, uvs, triangles
end

-- The body's outline as one filled shape, left edge down and right edge back.
-- Wound clockwise like addOval, so the head's oval unions with it.
local function bodyOutline(body: Body): Path
    local path = Path.new()
    for i = 1, body.n do
        local p = Vector.xy(body.x[i] + body.nx[i] * body.hw[i], body.y[i] + body.ny[i] * body.hw[i])
        if i == 1 then
            path:moveTo(p)
        else
            path:lineTo(p)
        end
    end
    for i = body.n, 1, -1 do
        path:lineTo(Vector.xy(body.x[i] - body.nx[i] * body.hw[i], body.y[i] - body.ny[i] * body.hw[i]))
    end
    path:close()
    return path
end

-- The light pass: the strip drawn again with snake_light.png, multiplied in. The
-- image is the room lighting over the whole level, so the body picks up the
-- colour of whichever room it is in. Where lights are failing, it is cut into
-- pieces about a tile long, each dimmed by what its spot of the level has left.
local function drawLight(self: Game, renderer: Renderer, body: Body)
    local light = self.lightImage
    if light == nil then
        return
    end
    local chunks: { { number } } = {}
    local first = 1
    for i = 2, body.n do
        if body.a[i] - body.a[first] >= LIGHT_CHUNK or i == body.n then
            if i == body.n and body.a[i] - body.a[first] < LIGHT_CHUNK / 2 and #chunks > 0 then
                chunks[#chunks][2] = i -- a stub at the tip rides with the piece before
            else
                table.insert(chunks, { first, i })
            end
            first = i
        end
    end

    local mults: { number } = {}
    local flickering = false
    for c, chunk in chunks do
        local mid = (chunk[1] + chunk[2]) // 2
        mults[c] = Lighting.flickerMult(body.x[mid] / TILE, body.y[mid] / TILE)
        if mults[c] < 0.996 then
            flickering = true
        end
    end

    if not flickering then
        local vertices, uvs, triangles = stripMesh(body, 1, body.n, false)
        renderer:drawImageMesh(light, self.lightSampler, vertices, uvs, triangles, 'multiply', 1)
        return
    end
    for c, chunk in chunks do
        local vertices, uvs, triangles = stripMesh(body, chunk[1], chunk[2], false)
        renderer:save()
        renderer:modulateColor(Lighting.color(mults[c], mults[c], mults[c]))
        renderer:drawImageMesh(light, self.lightSampler, vertices, uvs, triangles, 'multiply', 1)
        renderer:restore()
    end
end

-- Shadow, then the skin, then the room light over it.
local function drawBody(self: Game, renderer: Renderer, pts: { Vector })
    local n = #pts
    local tail = math.max(1, math.min(TAIL_SEGMENTS, n - 2))
    local body = buildBody(pts, n - tail)

    -- The shadow is one filled silhouette, so its 35% black is laid down once
    -- however much the pieces overlap. The head's own shadow is part of it.
    local lift = smoothstep(self.shadowLift)
    local face = self.faceAngle
    local ahead = Vector.xy(pts[1].x + math.cos(face) * HEAD_SHADOW_AHEAD, pts[1].y + math.sin(face) * HEAD_SHADOW_AHEAD)
    local shadow = bodyOutline(body)
    addOval(shadow, ahead.x, ahead.y, math.cos(face), math.sin(face), HEAD_SHADOW_ALONG, HEAD_SHADOW_ACROSS)
    self.shadowPaint.feather = SHADOW_FEATHER + (SHADOW_LIFT_FEATHER - SHADOW_FEATHER) * lift
    renderer:save()
    renderer:transform(
        Mat2D.withTranslation(
            SHADOW_DX + (SHADOW_LIFT_DX - SHADOW_DX) * lift,
            SHADOW_DY + (SHADOW_LIFT_DY - SHADOW_DY) * lift
        )
    )
    renderer:drawPath(shadow, self.shadowPaint)
    renderer:restore()

    local skin = self.skinImage
    if skin ~= nil then
        local vertices, uvs, triangles = stripMesh(body, 1, body.n, true)
        renderer:drawImageMesh(skin, self.skinSampler, vertices, uvs, triangles, 'srcOver', 1)
    end
    drawLight(self, renderer, body)
end

function draw(self: Game, renderer: Renderer)
    if self.size.x <= 0 or self.size.y <= 0 then
        return
    end
    local sim = self.sim
    local world = TILE * sim.cols
    local s = math.min(self.size.x, self.size.y) / world
    local ox = (self.size.x - world * s) / 2
    local oy = (self.size.y - world * s) / 2

    if self.gpuDirty and not self.gpuFailed then
        local ok, err = pcall(buildGpu, self)
        if not ok then
            self.gpuFailed = true
            print(`vision pass unavailable, drawing plainly: {err}`)
        end
    end

    local shaded = not self.gpuFailed and self.scene ~= nil and self.gpu ~= nil and self.bind ~= nil
    if shaded then
        local scene = self.scene :: Canvas
        local gpu = self.gpu :: GPUCanvas
        -- Canvas pixels per point, so the scene lines up with the artboard.
        local k = scene.width / self.size.x

        if self.maskDirty then
            drawMask(self)
        end
        if self.flickerDirty then
            drawFlickerMask(self)
        end

        -- 1. Only the floor plan, walls, exits and guests go to the offscreen canvas.
        local sr = scene:beginFrame({ clearColor = BACKGROUND })
        sr:save()
        sr:transform(Mat2D.withScaleAndTranslation(s * k, s * k, ox * k, oy * k))
        drawWorld(self, sr)
        sr:restore()
        scene:endFrame()

        -- 2. The shader samples it and writes the darkened result to the GPU canvas.
        writeUniforms(self, ox, oy, TILE * s * k, k)
        local pass = gpu:beginRenderPass({
            color = { { loadOp = 'clear', storeOp = 'store', clearColor = { 0, 0, 0, 1 } } },
        })
        pass:setPipeline(self.pipeline :: GPUPipeline)
        pass:setBindGroup(0, self.bind :: GPUBindGroup)
        pass:draw(3)
        pass:finish()

        -- 3. Back into the normal renderer, in points.
        renderer:save()
        renderer:transform(Mat2D.withScale(self.size.x / gpu.width, self.size.y / gpu.height))
        renderer:drawImage(gpu.image, self.imageSampler, 'srcOver', 1)
        renderer:restore()
    end

    renderer:save()
    renderer:transform(Mat2D.withScaleAndTranslation(s, s, ox, oy))

    if shaded then
        drawRings(self, renderer)
    else
        drawWorld(self, renderer)
    end

    local snakeAlpha = snakeAlphaOf(sim)

    -- Fresh paths every frame: a drawn Path must never be mutated.
    -- After a hit the head shakes, fading out over HIT_FX_TIME (its blink is the
    -- SnakeHead's own `hit` state).
    local sinceHit = sim.time - sim.hitTime
    local fx = 0.0
    if sim.hitTime >= 0 and sinceHit < Config.HIT_FX_TIME then
        fx = 1 - sinceHit / Config.HIT_FX_TIME
    end

    -- The bump nudge moves the drawn head only, on top of the shake.
    local nudge = nudgeOf(sim) * self.nudgeDistance
    local bump = sim.bumpDir
    local nudgeX = if bump ~= nil then bump.x * nudge else 0
    local nudgeY = if bump ~= nil then bump.y * nudge else 0

    local pts: { Vector } = {}
    for i = 1, #sim.cur do
        pts[i] = lerpCell(sim.prev[i], sim.cur[i], snakeAlpha)
    end

    drawBody(self, renderer, pts)

    -- The head sits on top, its neck on the head point, turned to face the way
    -- the snake is going.
    local head = self.head
    if head ~= nil then
        local hx = pts[1].x + nudgeX + math.sin(sinceHit * 90) * SHAKE_AMPLITUDE * fx
        local hy = pts[1].y + nudgeY + math.cos(sinceHit * 110) * SHAKE_AMPLITUDE * fx
        renderer:save()
        renderer:transform(Mat2D.withTranslation(hx, hy))
        renderer:transform(Mat2D.withRotation(self.faceAngle))
        renderer:transform(Mat2D.withTranslation(-HEAD_NECK_X, -HEAD_NECK_Y))
        local light = self.headLight
        renderer:modulateColor(Lighting.color(light[1], light[2], light[3]))
        head:draw(renderer)
        renderer:restore()
    end

    renderer:restore()
end

return function(context: Context): Layout<Game>
    local sim = Sim.new(LEVEL, 20240607)

    -- Static level geometry: built once here, drawn every frame, never mutated.
    local maskPath = Path.new() -- wall tiles, from the level data alone: see drawMask
    local exitPath = Path.new()
    for y = 0, sim.rows - 1 do
        for x = 0, sim.cols - 1 do
            if sim.walls[y + 1][x + 1] then
                addRect(maskPath, x * TILE, y * TILE)
            elseif sim.exitTile[y + 1][x + 1] then
                addRect(exitPath, x * TILE, y * TILE)
            end
        end
    end

    return {
        person = late(),
        snakeHead = late(),
        sim = sim,
        people = {},
        head = nil,
        headState = 'idle',
        floorImage = nil,
        wallsImage = nil,
        maskPath = maskPath,
        maskPaint = Paint.with({ style = 'fill', color = Color.rgb(255, 255, 255) }),
        exitPath = exitPath,
        exitPaint = Paint.with({ style = 'fill', color = Color.rgb(229, 57, 53) }),
        skinImage = nil,
        lightImage = nil,
        flickerImage = nil,
        shadowPaint = Paint.with({ style = 'fill', color = Color.rgba(0, 0, 0, SHADOW_ALPHA), feather = SHADOW_FEATHER }),
        skinSampler = ImageSampler('repeat', 'clamp', 'bilinear'),
        lightSampler = ImageSampler('clamp', 'clamp', 'bilinear'),
        size = Vector.xy(0, 0),
        scale = 1,
        context = nil,

        sinceEnd = 0,
        fades = { ready = 0, cleared = 0, walls = 0, escaped = 0, ['end'] = 0, dim = 0 },
        elapsed = 0,
        beatPhase = 0,
        dirAngle = 0, -- the snake starts facing right
        faceAngle = 0,
        turnFrom = 0,
        turnTo = 0,
        lastDir = { x = 1, y = 0 },
        seenEaten = 0,
        eatUntil = -1,
        seenBump = -1,
        nudgeDistance = 0,
        rings = Fog.newRings(),
        shadowLift = 0,

        lights = Flicker.new(20240607),
        holdF = false,
        holdC = false,
        sight = 0,
        sightRoom = nil,
        flash = 0,
        sightIntensity = 1,
        headLight = { 1, 1, 1 },
        headLightSet = false,

        scene = nil,
        gpu = nil,
        pipeline = nil,
        ubo = nil,
        bind = nil,
        gpuSampler = nil,
        mask = nil,
        maskDirty = true,
        flickerCanvas = nil,
        flickerDirty = true,
        imageSampler = ImageSampler('clamp', 'clamp', 'bilinear'),
        uniforms = buffer.create(UNIFORM_SIZE),
        gpuDirty = true,
        gpuFailed = false,

        score = nil,
        length = nil,
        peopleLeft = nil,
        escaped = nil,
        health = nil,
        vision = nil,
        boostReady = nil,
        boostCooldown = nil,
        gameState = nil,
        endReason = nil,
        eaten = nil,
        elapsedTime = nil,
        timeText = nil,
        fadeProps = {},

        init = init,
        resize = resize,
        keyboardEvent = keyboardEvent,
        pointerDown = pointerDown,
        advance = advance,
        draw = draw,
    }
end
