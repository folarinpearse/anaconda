-- Every room's lights fail in their own way. One controller per light group,
-- each with its own seeded RNG (never the sim's) and driven by elapsed time:
-- a continuous base level, and now and then an event (a stutter, a sag, a
-- strobe...) that multiplies it. The result is an intensity per group, 0 (off)
-- to 1 (on), which main.luau hands to vision.wgsl (the floor, walls and guests
-- go dark together) and to lighting.luau (the snake dims with its room).
--
-- Pure Luau with no Rive API so the headless tests can drive it. Group order
-- matches flicker_mask.png / flicker_mask.luau: 1 dj_room, 2 lounge, 3 bar,
-- 4 kitchen, 5 main_hall, 6 games, 7 bathroom, 8 foyer, 9 red_room, 10 corridors.
-- Positions are in tile units, cell (x, y) spanning [x, x + 1) x [y, y + 1).

local Config = require('config')
local Fog = require('fog')

export type Room = { name: string, group: number, x0: number, y0: number, x1: number, y1: number }

-- One event is a run of segments; the level moves in a straight line from
-- `from` to `to` over `dur` seconds. `off` marks the dark stretch of a blackout.
export type Segment = { dur: number, from: number, to: number, off: boolean }

export type Group = {
    index: number,
    name: string,
    kind: string,
    seed: number,
    gap: { number },
    wait: number, -- seconds, at normal speed, until the next event
    segs: { Segment }?, -- the event now running
    segIndex: number,
    segTime: number,
    pendingAt: number?, -- elapsed time at which the room-entry event fires
    jitter: number, -- the base level's current random draw, 0-1
    jitterLeft: number,
    chase: number, -- the chase jitter's current random draw, 0-1
    chaseLeft: number,
    below: boolean, -- the level is in a drop below the safe-flashing floor
    dropAt: number, -- elapsed time at which the last such drop began
}

export type State = {
    groups: { Group },
    intensity: { number }, -- by group index
    elapsed: number, -- seconds of play since the last reset
    tension: number, -- chase tension, 0-1
    room: number?, -- index into ROOMS of the room the head is in
    sinceFlash: number, -- seconds since the last strike flash was allowed
}

export type Context = {
    playing: boolean,
    headX: number, -- tiles
    headY: number,
    lunging: boolean,
    guests: { any }, -- Sim.Guest
    beatPhase: number, -- 0-1 through the dread heartbeat
    forceEvents: boolean, -- debug: every group runs an event back to back
    forceChase: boolean, -- debug: tension stuck at 1
}

local Flicker = {}

-- Inclusive tile columns and rows, row 0 at the top. The corridors are not a
-- room: they are group 10 and have no rect.
local ROOMS: { Room } = {
    { name = 'dj_room', group = 1, x0 = 1, y0 = 1, x1 = 6, y1 = 5 },
    { name = 'lounge', group = 2, x0 = 8, y0 = 1, x1 = 15, y1 = 5 },
    { name = 'bar', group = 3, x0 = 17, y0 = 1, x1 = 22, y1 = 5 },
    { name = 'kitchen', group = 4, x0 = 1, y0 = 10, x1 = 6, y1 = 15 },
    { name = 'main_hall', group = 5, x0 = 8, y0 = 10, x1 = 15, y1 = 15 },
    { name = 'games', group = 6, x0 = 17, y0 = 10, x1 = 22, y1 = 15 },
    { name = 'bathroom', group = 7, x0 = 1, y0 = 20, x1 = 6, y1 = 22 },
    { name = 'foyer', group = 8, x0 = 8, y0 = 19, x1 = 15, y1 = 23 },
    { name = 'red_room', group = 9, x0 = 17, y0 = 20, x1 = 22, y1 = 22 },
}
local CORRIDORS = 10
local GROUP_COUNT = 10

Flicker.ROOMS = ROOMS
Flicker.CORRIDORS = CORRIDORS
Flicker.GROUP_COUNT = GROUP_COUNT

-- The room whose rect contains tile (tx, ty), if any: corridors and doorways
-- are no room.
function Flicker.roomAt(tx: number, ty: number): number?
    for i, r in ROOMS do
        if tx >= r.x0 and tx <= r.x1 and ty >= r.y0 and ty <= r.y1 then
            return i
        end
    end
    return nil
end

-- Tiles from the point (x, y) to the room's rect; 0 inside it.
local function distanceToRoom(r: Room, x: number, y: number): number
    local dx = math.max(r.x0 - x, 0, x - (r.x1 + 1))
    local dy = math.max(r.y0 - y, 0, y - (r.y1 + 1))
    return math.sqrt(dx * dx + dy * dy)
end

-- Deterministic LCG, one stream per group.
local function rand(g: Group): number
    g.seed = (g.seed * 1664525 + 1013904223) % 4294967296
    return g.seed / 4294967296
end

local function range(g: Group, r: { number }): number
    return r[1] + (r[2] - r[1]) * rand(g)
end

-- A whole number from r[1] to r[2], both included.
local function count(g: Group, r: { number }): number
    return math.floor(r[1] + (r[2] - r[1] + 1) * rand(g))
end

local function seg(dur: number, from: number, to: number?): Segment
    return { dur = dur, from = from, to = to or from, off = false }
end

-- ---------------------------------------------------------------- events

-- The tube settles after a few flickers: low and high levels alternating,
-- always ending on a high one.
local function stutter(g: Group, segs: { Segment })
    local n = count(g, Config.TUBE_STUTTER_SEGMENTS)
    for i = 1, n do
        local level = if i % 2 == 1 then range(g, Config.TUBE_STUTTER_LOW) else range(g, Config.TUBE_STUTTER_HIGH)
        table.insert(segs, seg(range(g, Config.TUBE_STUTTER_SEGMENT), level))
    end
    if n % 2 == 1 then
        table.insert(segs, seg(range(g, Config.TUBE_STUTTER_SEGMENT), range(g, Config.TUBE_STUTTER_HIGH)))
    end
end

local function tubeEvent(g: Group, share: number, blackoutTime: { number }): { Segment }
    local segs: { Segment } = {}
    stutter(g, segs)
    if rand(g) < share then
        local off = seg(range(g, blackoutTime), Config.TUBE_OFF_LEVEL)
        off.off = true
        table.insert(segs, off)
        stutter(g, segs)
    end
    return segs
end

local function sagEvent(to: number, down: number, hold: number, up: number): { Segment }
    return { seg(down, 1, to), seg(hold, to), seg(up, to, 1) }
end

local function buildEvent(g: Group): { Segment }
    local kind = g.kind
    if kind == 'party' then
        local segs: { Segment } = {}
        for i = 1, count(g, Config.PARTY_STROBE_SEGMENTS) do
            table.insert(segs, seg(Config.PARTY_STROBE_SEGMENT, if i % 2 == 1 then Config.PARTY_STROBE_LOW else 1))
        end
        return segs
    elseif kind == 'dimmer' then
        return sagEvent(Config.LOUNGE_FADE_TO, Config.LOUNGE_FADE_TIME, Config.LOUNGE_HOLD, Config.LOUNGE_FADE_TIME)
    elseif kind == 'neon' then
        return {
            seg(Config.NEON_CUT_FIRST, Config.NEON_OFF_LEVEL),
            seg(Config.NEON_CUT_ON, 1),
            seg(range(g, Config.NEON_CUT_SECOND), Config.NEON_OFF_LEVEL),
        }
    elseif kind == 'kitchen' then
        return tubeEvent(g, Config.KITCHEN_BLACKOUT_SHARE, Config.KITCHEN_BLACKOUT_TIME)
    elseif kind == 'corridors' then
        return tubeEvent(g, Config.CORRIDORS_BLACKOUT_SHARE, Config.CORRIDORS_BLACKOUT_TIME)
    elseif kind == 'bathroom' then
        return tubeEvent(g, Config.BATHROOM_BLACKOUT_SHARE, Config.BATHROOM_BLACKOUT_TIME)
    elseif kind == 'brownout' then
        return sagEvent(Config.HALL_SAG_TO, Config.HALL_SAG_TIME, Config.HALL_HOLD, Config.HALL_RECOVER)
    elseif kind == 'glitch' then
        return {
            seg(Config.GLITCH_LOW_TIME, Config.GLITCH_LOW_LEVEL),
            seg(Config.GLITCH_ON_TIME, 1),
            seg(Config.GLITCH_LOW_TIME, Config.GLITCH_LOW_LEVEL),
        }
    elseif kind == 'sag' then
        return sagEvent(Config.FOYER_SAG_TO, Config.FOYER_SAG_TIME, Config.FOYER_HOLD, Config.FOYER_RECOVER)
    end
    -- heartbeat: a short drop
    return { seg(Config.RED_DROP_TIME, Config.RED_DROP_TO) }
end

-- ------------------------------------------------------------ base levels

-- The tubes' hum: a few unrelated sines, so it never settles into a pattern.
local function hum(g: Group, t: number): number
    local p = g.index * 1.7
    local wobble = 0.5 * math.sin(2 * math.pi * 7.3 * t + p)
        + 0.3 * math.sin(2 * math.pi * 13.1 * t + 2 * p)
        + 0.2 * math.sin(2 * math.pi * 3.7 * t + 3 * p)
    return 1 + Config.TUBE_HUM * wobble
end

local function baseLevel(g: Group, t: number, dt: number, ctx: Context): number
    local kind = g.kind
    if kind == 'party' then
        local phase = (t * Config.PARTY_BPM / 60) % 1
        return Config.PARTY_BASE_LOW + (1 - Config.PARTY_BASE_LOW) * math.exp(-Config.PARTY_BASE_DECAY * phase)
    elseif kind == 'dimmer' then
        return Config.LOUNGE_BASE_MID + Config.LOUNGE_BASE_SWING * math.sin(2 * math.pi * t / Config.LOUNGE_BASE_PERIOD)
    elseif kind == 'neon' or kind == 'glitch' then
        local amount = if kind == 'neon' then Config.NEON_JITTER else Config.GLITCH_JITTER
        local interval = if kind == 'neon' then Config.NEON_JITTER_INTERVAL else Config.GLITCH_JITTER_INTERVAL
        g.jitterLeft -= dt
        if g.jitterLeft <= 0 then
            g.jitter = rand(g)
            g.jitterLeft = range(g, interval)
        end
        return 1 - amount * g.jitter
    elseif kind == 'kitchen' or kind == 'corridors' or kind == 'bathroom' then
        return hum(g, t)
    elseif kind == 'heartbeat' then
        return Config.RED_BASE_LOW + (1 - Config.RED_BASE_LOW) * Fog.heartbeat(ctx.beatPhase)
    end
    return 1 -- brownout, sag: steady
end

-- ------------------------------------------------------------------ groups

local DEFS: { { name: string, kind: string, gap: { number } } } = {
    { name = 'dj_room', kind = 'party', gap = Config.PARTY_GAP },
    { name = 'lounge', kind = 'dimmer', gap = Config.LOUNGE_GAP },
    { name = 'bar', kind = 'neon', gap = Config.NEON_GAP },
    { name = 'kitchen', kind = 'kitchen', gap = Config.KITCHEN_GAP },
    { name = 'main_hall', kind = 'brownout', gap = Config.HALL_GAP },
    { name = 'games', kind = 'glitch', gap = Config.GLITCH_GAP },
    { name = 'bathroom', kind = 'bathroom', gap = Config.BATHROOM_GAP },
    { name = 'foyer', kind = 'sag', gap = Config.FOYER_GAP },
    { name = 'red_room', kind = 'heartbeat', gap = Config.RED_GAP },
    { name = 'corridors', kind = 'corridors', gap = Config.CORRIDORS_GAP },
}

local function startEvent(g: Group)
    g.segs = buildEvent(g)
    g.segIndex = 1
    g.segTime = 0
    g.pendingAt = nil
    g.wait = range(g, g.gap)
end

local function resetGroup(g: Group)
    g.segs = nil
    g.segIndex = 1
    g.segTime = 0
    g.pendingAt = nil
    g.wait = range(g, g.gap)
    g.jitter = 0
    g.jitterLeft = 0
    g.chase = 0
    g.chaseLeft = 0
    g.below = false
    g.dropAt = -math.huge
end

function Flicker.new(seed: number): State
    local groups: { Group } = {}
    local intensity: { number } = {}
    for i, def in DEFS do
        local g: Group = {
            index = i,
            name = def.name,
            kind = def.kind,
            seed = (seed + i * 7919) % 4294967296,
            gap = def.gap,
            wait = 0,
            segs = nil,
            segIndex = 1,
            segTime = 0,
            pendingAt = nil,
            jitter = 0,
            jitterLeft = 0,
            chase = 0,
            chaseLeft = 0,
            below = false,
            dropAt = -math.huge,
        }
        resetGroup(g)
        groups[i] = g
        intensity[i] = 1
    end
    return { groups = groups, intensity = intensity, elapsed = 0, tension = 0, room = nil, sinceFlash = math.huge }
end

-- A fresh run: every group on, no event running, the quiet time starts over.
-- The RNG streams carry on, so each run flickers differently.
function Flicker.reset(state: State)
    for i, g in state.groups do
        resetGroup(g)
        state.intensity[i] = 1
    end
    state.elapsed = 0
    state.tension = 0
    state.room = nil
    state.sinceFlash = math.huge
end

-- Chase tension: 1 while a guest within range flees, CHASE_LUNGE while lunging,
-- CHASE_ALERT while one in range is alerted, else 0. Rises fast, falls slowly.
local function stepTension(state: State, dt: number, ctx: Context)
    if ctx.forceChase then
        state.tension = 1
        return
    end
    local target = 0.0
    if ctx.lunging then
        target = Config.CHASE_LUNGE
    end
    for _, g in ctx.guests do
        if not g.gone and (g.state == 'flee' or g.state == 'alert') then
            local dx = g.cell.x + 0.5 - ctx.headX
            local dy = g.cell.y + 0.5 - ctx.headY
            if math.sqrt(dx * dx + dy * dy) <= Config.CHASE_RANGE then
                target = math.max(target, if g.state == 'flee' then Config.CHASE_FLEE else Config.CHASE_ALERT)
            end
        end
    end
    local tau = if target > state.tension then Config.CHASE_RISE else Config.CHASE_FALL
    state.tension += (target - state.tension) * (1 - math.exp(-dt / tau))
end

-- Safe flashing, the last word on a group's level. A drop below the floor may
-- only begin if the previous one began at least SAFE_FLASH_INTERVAL ago; until
-- then the level stops at the floor. Faster flicker (strobe, stutter, chase
-- jitter) keeps its rhythm and its highs, it just can't go deep, so at most 3
-- deep flashes a second get through. A drop already under way is left to finish.
local function limitFlashing(g: Group, level: number, t: number): number
    local floor = Config.SAFE_FLASH_FLOOR
    if level >= floor then
        g.below = false
        return level
    end
    if g.below then
        return level
    end
    if t - g.dropAt >= Config.SAFE_FLASH_INTERVAL then
        g.below = true
        g.dropAt = t
        return level
    end
    return floor
end

-- Whether the current room's strike flash may fire now: once per
-- SAFE_STRIKE_INTERVAL when safe flashing is on.
function Flicker.tryFlash(state: State): boolean
    if Config.SAFE_FLASHING and state.sinceFlash < Config.SAFE_STRIKE_INTERVAL then
        return false
    end
    state.sinceFlash = 0
    return true
end

local function stepGroup(state: State, g: Group, dt: number, ctx: Context, ownGroup: number)
    local t = state.elapsed
    local tension = state.tension
    local chasing = tension > Config.CHASE_ACTIVE

    -- Room entry: the room notices the snake a moment after it comes in.
    local canStart = t >= Config.LIGHTS_QUIET_TIME
    local pending = g.pendingAt
    if canStart and pending ~= nil and t >= pending then
        startEvent(g)
    end

    -- The running event.
    local segs = g.segs
    if segs ~= nil then
        g.segTime += dt
        while g.segs ~= nil do
            local s = segs[g.segIndex]
            -- In a chase the room the snake is in never stays dark for long.
            if s.off and chasing and g.index == ownGroup and s.dur > Config.CHASE_BLACKOUT_MAX then
                s.dur = Config.CHASE_BLACKOUT_MAX
            end
            if g.segTime < s.dur then
                break
            end
            g.segTime -= s.dur
            g.segIndex += 1
            if g.segIndex > #segs then
                g.segs = nil
            end
        end
    elseif canStart then
        if ctx.forceEvents then
            startEvent(g)
        else
            g.wait -= dt * (1 + Config.CHASE_GAP_SPEEDUP * tension)
            if g.wait <= 0 then
                startEvent(g)
            end
        end
    end

    local level = 1.0
    local running = g.segs
    if running ~= nil then
        local s = running[g.segIndex]
        level = s.from + (s.to - s.from) * math.clamp(g.segTime / math.max(s.dur, 0.0001), 0, 1)
    end
    level *= baseLevel(g, t, dt, ctx)

    -- Erratic jitter, only in rooms near the snake; the corridors reach everywhere.
    if tension > 0.001 then
        local near = true
        if g.index ~= CORRIDORS then
            near = distanceToRoom(ROOMS[g.index], ctx.headX, ctx.headY) <= Config.CHASE_JITTER_RANGE
        end
        if near then
            g.chaseLeft -= dt
            if g.chaseLeft <= 0 then
                g.chase = rand(g)
                g.chaseLeft = range(g, Config.CHASE_JITTER_INTERVAL)
            end
            level *= 1 - Config.CHASE_JITTER_DEPTH * tension * g.chase
        end
    end

    level = math.clamp(level, 0, 1)
    if Config.SAFE_FLASHING then
        level = limitFlashing(g, level, t)
    end
    state.intensity[g.index] = level
end

-- Advances every group by `dt`. Off the play screen (ready, won, lost) every
-- group sits at 1.0 and the clock stands still.
function Flicker.update(state: State, dt: number, ctx: Context)
    state.sinceFlash += dt
    if not ctx.playing or not Config.FLICKER_ENABLED then
        for i = 1, GROUP_COUNT do
            state.intensity[i] = 1
        end
        state.tension = 0
        return
    end
    state.elapsed += dt
    stepTension(state, dt, ctx)

    local room = Flicker.roomAt(math.floor(ctx.headX), math.floor(ctx.headY))
    if room ~= state.room then
        state.room = room
        if room ~= nil then
            local g = state.groups[ROOMS[room].group]
            g.pendingAt = state.elapsed + range(g, Config.ENTRY_DELAY)
        end
    end
    local ownGroup = if room ~= nil then ROOMS[room].group else CORRIDORS

    for _, g in state.groups do
        stepGroup(state, g, dt, ctx, ownGroup)
    end
end

return Flicker
