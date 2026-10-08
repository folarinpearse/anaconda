-- Anaconda: a top-down snake game. The rules live in sim.luau; this script
-- draws the playfield, instances one Person artboard per guest and drives each
-- one through its own view model, and mirrors the numbers into the Game view
-- model that the RML HUD is bound to. The floor plan, walls, exits and guests are
-- rendered to an offscreen canvas and darkened by vision.wgsl; the snake, the
-- sound rings and the HUD are drawn over that, so the snake is always visible.

local Sim = require('sim')
local Config = require('config')
local Fog = require('fog')
local LEVEL = require('level')

type Cell = Sim.Cell

type PersonRec = {
    instance: Artboard<Data.Person>,
    state: Sim.GuestState,
}

-- The values of the SnakeHead artboard's `state` enum (snakehead.rml).
type HeadState = 'idle' | 'lunge' | 'eat' | 'hit'

-- One coat of the body: the stroke that runs down the straight part and the
-- fill that draws the tapered tail in the same colour.
type BodyLayer = {
    stroke: Paint,
    fill: Paint,
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
    exitPath: Path,
    exitPaint: Paint,
    shadowPaint: Paint,
    outlineLayer: BodyLayer,
    bodyLayer: BodyLayer,
    spineLayer: BodyLayer,
    spotPaint: Paint,
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
local BODY_WIDTH = 30
local KAPPA = 0.5522847498
local PERSON_SIZE = 32

-- The SnakeHead artboard is 48x48, faces +x and is rigged at the neck joint;
-- keep these in step with the `Rig` node in snakehead.rml.
local HEAD_NECK_X = 12
local HEAD_NECK_Y = 24
local EAT_TIME = 0.25 -- seconds the head shows its eat animation after a meal
local TURN_FRACTION = 0.6 -- share of a tick the head takes to swing round to a new heading

-- The body: lit from straight above, so every coat runs down the middle.
local SHADOW_DX = 3
local SHADOW_DY = 4
local SHADOW_ALPHA = 89 -- 35% of 255
local SHADOW_FEATHER = 3 -- px of blur on the shadow's edge
local OUTLINE_GROW = 4 -- the outline stroke is this much wider than the body
local SPINE_FRACTION = 0.35 -- the highlight's width as a share of the body's
local TAIL_SEGMENTS = 3 -- how many segments at the end taper to a point
local SPOT_SPACING = TILE -- arc length between spots; must divide TILE so the pattern rides the body
local SPOT_FIRST = 24 -- arc length from the neck to the first spot at the start of a tick
local SPOT_ALONG = 7 -- half the spot's length, along the body
local SPOT_ACROSS = 9 -- half its width, across the body
local SPOT_GROW_FROM = 8 -- spots swell from nothing between these two arc lengths from the neck,
local SPOT_GROW_LEN = 14 -- so they appear from under the head instead of popping in

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
-- px the drawn head leans into a bump, at its peak. Interior wall art sits back
-- from the tile edge, so it gets the long lean; the outer walls are flush.
local NUDGE_INTERIOR = 10 -- interior walls and the snake's own body
local NUDGE_BORDER = 1 -- outer border tiles
local NUDGE_OUT_TIME = 0.06 -- seconds to ease out to the peak
local NUDGE_BACK_TIME = 0.2 -- seconds to spring back
local BACKGROUND = Color.rgb(20, 23, 28) -- the artboard fill, behind the letterbox
local UNIFORM_SIZE = 96 -- bytes; the Uniforms struct in vision.wgsl
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
    self.dirAngle = 0 -- the snake starts facing right
    local dir = self.sim.dir
    local facing = math.atan2(dir.y, dir.x)
    self.lastDir = { x = dir.x, y = dir.y }
    self.faceAngle = facing
    self.turnFrom = facing
    self.turnTo = facing
    self.seenEaten = 0
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
            return Fog.inView(hx, hy, dx, dy, sim.vision, sim.reveal, guest.cell.x + 0.5, guest.cell.y + 0.5, isWall)
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
    self.bind = GPUBindGroup.new({
        layout = pipeline:getBindGroupLayout(0),
        ubos = { { slot = 0, buffer = self.ubo :: GPUBuffer } },
        textures = { { slot = 1, view = scene.image:view() }, { slot = 3, view = mask.image:view() } },
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

-- The straight part of the body: a polyline through points 1..last.
local function polyline(pts: { Vector }, last: number): Path
    local path = Path.new()
    path:moveTo(pts[1])
    for i = 2, last do
        path:lineTo(pts[i])
    end
    return path
end

-- A tapered run of the body, joints first..last: a disc at every joint and a
-- quad down every segment, `radii[j] * scale + grow` wide at joint j. Every
-- contour winds clockwise, so overlaps union instead of cancelling.
local function addTapered(path: Path, pts: { Vector }, radii: { number }, first: number, last: number, scale: number, grow: number)
    for j = first, last do
        local r = radii[j] * scale + grow
        if r > 0.05 then
            addCircle(path, pts[j].x, pts[j].y, r)
        end
        if j < last then
            local a = pts[j]
            local b = pts[j + 1]
            local dx = b.x - a.x
            local dy = b.y - a.y
            local len = math.sqrt(dx * dx + dy * dy)
            local rb = radii[j + 1] * scale + grow
            if len > 0.001 and (r > 0.05 or rb > 0.05) then
                local nx = -dy / len
                local ny = dx / len
                path:moveTo(Vector.xy(a.x - nx * r, a.y - ny * r))
                path:lineTo(Vector.xy(b.x - nx * rb, b.y - ny * rb))
                path:lineTo(Vector.xy(b.x + nx * rb, b.y + ny * rb))
                path:lineTo(Vector.xy(a.x + nx * r, a.y + ny * r))
                path:close()
            end
        end
    end
end

-- Dark ovals at even arc lengths down the body, turned to follow it. They are
-- placed by distance from the neck, shifted by `phase` (how far the head has
-- slid this tick) so the pattern rides along with the skin instead of sitting
-- still while the snake moves under it.
local function buildSpots(pts: { Vector }, cum: { number }, taperFrom: number, phase: number): Path
    local spots = Path.new()
    local n = #pts
    local total = cum[n]
    local taperStart = cum[taperFrom]
    local center = polyline(pts, n):measure()
    local d = SPOT_FIRST - SPOT_SPACING + phase
    while d < total do
        local grow = math.clamp((d - SPOT_GROW_FROM) / SPOT_GROW_LEN, 0, 1)
        local taper = if d <= taperStart then 1 else 1 - (d - taperStart) / math.max(0.001, total - taperStart)
        local size = grow * taper
        if size > 0.25 then
            local p, t = center:positionAndTangent(d)
            addOval(spots, p.x, p.y, t.x, t.y, SPOT_ALONG * size, SPOT_ACROSS * size)
        end
        d += SPOT_SPACING
    end
    return spots
end

-- Shadow, outline, olive, spine highlight, spots: each coat is a stroke down the
-- straight part of the body and a filled taper for the last TAIL_SEGMENTS.
local function drawBody(self: Game, renderer: Renderer, pts: { Vector }, phase: number)
    local n = #pts
    local tail = math.min(TAIL_SEGMENTS, n - 2)
    local taperFrom = n - tail -- the joint where the taper begins

    -- Arc length from the neck to each joint, and the half-width at each: full
    -- down to the taper, then falling in a straight line to a point.
    local cum: { number } = { 0 }
    for i = 2, n do
        local dx = pts[i].x - pts[i - 1].x
        local dy = pts[i].y - pts[i - 1].y
        cum[i] = cum[i - 1] + math.sqrt(dx * dx + dy * dy)
    end
    local radii: { number } = {}
    local span = math.max(0.001, cum[n] - cum[taperFrom])
    for i = 1, n do
        radii[i] = if i <= taperFrom then BODY_WIDTH / 2 else (BODY_WIDTH / 2) * (1 - (cum[i] - cum[taperFrom]) / span)
    end

    -- The shadow is one filled silhouette, as wide as the outlined body, so its
    -- 35% black is laid down once however much the pieces overlap; a stroke plus
    -- a tail would double up where they meet. The head's own shadow is part of it.
    local shadow = Path.new()
    addTapered(shadow, pts, radii, 1, n, 1, OUTLINE_GROW / 2)
    local face = self.faceAngle
    addOval(shadow, pts[1].x + math.cos(face) * 8, pts[1].y + math.sin(face) * 8, math.cos(face), math.sin(face), 17, 16)
    renderer:save()
    renderer:transform(Mat2D.withTranslation(SHADOW_DX, SHADOW_DY))
    renderer:drawPath(shadow, self.shadowPaint)
    renderer:restore()

    local coats: { { layer: BodyLayer, scale: number, grow: number } } = {
        { layer = self.outlineLayer, scale = 1, grow = OUTLINE_GROW / 2 },
        { layer = self.bodyLayer, scale = 1, grow = 0 },
        { layer = self.spineLayer, scale = SPINE_FRACTION, grow = 0 },
    }
    for _, coat in coats do
        renderer:drawPath(polyline(pts, taperFrom), coat.layer.stroke)
        if tail > 0 then
            local taper = Path.new()
            addTapered(taper, pts, radii, taperFrom, n, coat.scale, coat.grow)
            renderer:drawPath(taper, coat.layer.fill)
        end
    end

    renderer:drawPath(buildSpots(pts, cum, taperFrom, phase), self.spotPaint)
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

    -- How far the skin has slid since the tick began: the head covers one tile a
    -- tick, and only on a tick where it actually moved (not into a wall).
    local first = sim.prev[1]
    local second = sim.cur[1]
    local moved = first.x ~= second.x or first.y ~= second.y
    local phase = if moved then (snakeAlpha * TILE) % SPOT_SPACING else 0

    drawBody(self, renderer, pts, phase)

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

    local function bodyLayer(thickness: number, color: Color): BodyLayer
        return {
            stroke = Paint.with({ style = 'stroke', thickness = thickness, cap = 'round', join = 'round', color = color }),
            fill = Paint.with({ style = 'fill', color = color }),
        }
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
        shadowPaint = Paint.with({ style = 'fill', color = Color.rgba(0, 0, 0, SHADOW_ALPHA), feather = SHADOW_FEATHER }),
        outlineLayer = bodyLayer(BODY_WIDTH + OUTLINE_GROW, Color.rgb(34, 42, 18)),
        bodyLayer = bodyLayer(BODY_WIDTH, Color.rgb(104, 122, 48)),
        spineLayer = bodyLayer(BODY_WIDTH * SPINE_FRACTION, Color.rgb(152, 172, 86)),
        spotPaint = Paint.with({ style = 'fill', color = Color.rgb(50, 62, 26) }),
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

        scene = nil,
        gpu = nil,
        pipeline = nil,
        ubo = nil,
        bind = nil,
        gpuSampler = nil,
        mask = nil,
        maskDirty = true,
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
