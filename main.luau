-- Anaconda: a top-down snake game. The rules live in sim.luau; this script
-- draws the playfield, instances one Person artboard per guest and drives each
-- one through its own view model, and mirrors the numbers into the Game view
-- model that the RML HUD is bound to.

local Sim = require('sim')
local Config = require('config')
local LEVEL = require('level')

type Cell = Sim.Cell

type PersonRec = {
    instance: Artboard<Data.Person>,
    state: Sim.GuestState,
}

type Game = {
    person: Input<Artboard<Data.Person>>,
    sim: Sim.Sim,
    people: { [number]: PersonRec },
    floorPath: Path,
    wallPath: Path,
    exitPath: Path,
    floorPaint: Paint,
    wallPaint: Paint,
    exitPaint: Paint,
    bodyPaint: Paint,
    headPaint: Paint,
    flashPaint: Paint,
    size: Vector,

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
}

local TILE = 40
local BODY_WIDTH = 24
local HEAD_RADIUS = 16
local KAPPA = 0.5522847498
local PERSON_SIZE = 32

-- GLFW key codes -> direction.
local KEY_DIRS: { [number]: Cell } = {
    [262] = Sim.RIGHT, [68] = Sim.RIGHT, -- right arrow, D
    [263] = Sim.LEFT, [65] = Sim.LEFT, -- left arrow, A
    [264] = Sim.DOWN, [83] = Sim.DOWN, -- down arrow, S
    [265] = Sim.UP, [87] = Sim.UP, -- up arrow, W
}
local KEY_SPACE = 32
local KEY_SHIFTS: { [number]: boolean } = { [340] = true, [344] = true } -- left, right
local SHAKE_AMPLITUDE = 5 -- px at the moment of impact

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

local function restart(self: Game)
    self.people = {}
    Sim.reset(self.sim, 'playing')
end

function init(self: Game, context: Context): boolean
    -- init runs twice and the view model is absent on the first call.
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
    publish(self)
    return true
end

function resize(self: Game, size: Vector, scale: number)
    self.size = size
end

function keyboardEvent(self: Game, event: KeyboardEvent): boolean
    if event.phase ~= 'down' then
        return false
    end
    local sim = self.sim
    if event.key == KEY_SPACE then
        if sim.state == 'ready' then
            Sim.start(sim)
            return true
        elseif sim.state == 'won' or sim.state == 'lost' then
            restart(self)
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

-- A click or tap starts a game that is waiting, same as Space, and lunges
-- during play. Focus for the keys is requested by the state machine's pointer
-- listener in scene.rml.
function pointerDown(self: Game, event: PointerEvent)
    local sim = self.sim
    if sim.state == 'ready' then
        Sim.start(sim)
        event:hit()
    elseif sim.state == 'playing' then
        Sim.lunge(sim)
        event:hit()
    end
end

function advance(self: Game, seconds: number): boolean
    Sim.update(self.sim, seconds)
    syncPeople(self, seconds)
    publish(self)
    return true
end

local function lerpCell(a: Cell, b: Cell, t: number): Vector
    return Vector.xy(
        ((a.x + (b.x - a.x) * t) + 0.5) * TILE,
        ((a.y + (b.y - a.y) * t) + 0.5) * TILE
    )
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

    renderer:save()
    renderer:transform(Mat2D.withScaleAndTranslation(s, s, ox, oy))

    renderer:drawPath(self.floorPath, self.floorPaint)
    renderer:drawPath(self.wallPath, self.wallPaint)
    renderer:drawPath(self.exitPath, self.exitPaint)

    -- Between ticks everything slides from its previous cell to its current one.
    -- When the game is not running they rest on their last cell.
    local playing = sim.state == 'playing'
    local snakeAlpha = 1.0
    local guestAlpha = 1.0
    if playing then
        snakeAlpha = math.clamp(sim.snakeAcc / Sim.TICK, 0, 1)
        guestAlpha = math.clamp(sim.guestAcc / Sim.GUEST_TICK, 0, 1)
    end

    for _, g in sim.guests do
        local rec = self.people[g.id]
        if rec ~= nil then
            local p = lerpCell(g.prev, g.cell, guestAlpha)
            renderer:save()
            renderer:transform(Mat2D.withTranslation(p.x - PERSON_SIZE / 2, p.y - PERSON_SIZE / 2 - 6))
            rec.instance:draw(renderer)
            renderer:restore()
        end
    end

    -- Fresh paths every frame: a drawn Path must never be mutated.
    -- After a hit the head blinks and shakes, fading out over HIT_FX_TIME.
    local sinceHit = sim.time - sim.hitTime
    local fx = 0.0
    if sim.hitTime >= 0 and sinceHit < Config.HIT_FX_TIME then
        fx = 1 - sinceHit / Config.HIT_FX_TIME
    end

    local body = Path.new()
    local head = Path.new()
    for i = 1, #sim.cur do
        local p = lerpCell(sim.prev[i], sim.cur[i], snakeAlpha)
        if i == 1 then
            body:moveTo(p)
            local hx = p.x + math.sin(sinceHit * 90) * SHAKE_AMPLITUDE * fx
            local hy = p.y + math.cos(sinceHit * 110) * SHAKE_AMPLITUDE * fx
            addCircle(head, hx, hy, HEAD_RADIUS)
        else
            body:lineTo(p)
        end
    end
    renderer:drawPath(body, self.bodyPaint)
    local blink = fx > 0 and math.floor(sinceHit * 24) % 2 == 0
    renderer:drawPath(head, if blink then self.flashPaint else self.headPaint)

    renderer:restore()
end

return function(context: Context): Layout<Game>
    local sim = Sim.new(LEVEL, 20240607)

    -- Static level geometry: built once here, drawn every frame, never mutated.
    local floorPath = Path.new()
    local wallPath = Path.new()
    local exitPath = Path.new()
    local world = TILE * sim.cols
    floorPath:moveTo(Vector.xy(0, 0))
    floorPath:lineTo(Vector.xy(world, 0))
    floorPath:lineTo(Vector.xy(world, world))
    floorPath:lineTo(Vector.xy(0, world))
    floorPath:close()
    for y = 0, sim.rows - 1 do
        for x = 0, sim.cols - 1 do
            if sim.walls[y + 1][x + 1] then
                addRect(wallPath, x * TILE, y * TILE)
            elseif sim.exitTile[y + 1][x + 1] then
                addRect(exitPath, x * TILE, y * TILE)
            end
        end
    end

    return {
        person = late(),
        sim = sim,
        people = {},
        floorPath = floorPath,
        wallPath = wallPath,
        exitPath = exitPath,
        floorPaint = Paint.with({ style = 'fill', color = Color.rgb(27, 31, 38) }),
        wallPaint = Paint.with({ style = 'fill', color = Color.rgb(110, 116, 124) }),
        exitPaint = Paint.with({ style = 'fill', color = Color.rgb(229, 57, 53) }),
        bodyPaint = Paint.with({
            style = 'stroke',
            thickness = BODY_WIDTH,
            cap = 'round',
            join = 'round',
            color = Color.rgb(67, 160, 71),
        }),
        headPaint = Paint.with({ style = 'fill', color = Color.rgb(102, 204, 106) }),
        flashPaint = Paint.with({ style = 'fill', color = Color.rgb(255, 235, 230) }),
        size = Vector.xy(0, 0),

        score = nil,
        length = nil,
        peopleLeft = nil,
        escaped = nil,
        health = nil,
        vision = nil,
        boostReady = nil,
        boostCooldown = nil,
        gameState = nil,

        init = init,
        resize = resize,
        keyboardEvent = keyboardEvent,
        pointerDown = pointerDown,
        advance = advance,
        draw = draw,
    }
end
