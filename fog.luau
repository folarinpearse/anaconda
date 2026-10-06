-- Vision, dread and sound-ring maths. Pure Luau with no Rive API so the
-- headless tests can drive it. main.luau feeds the results to vision.wgsl as
-- uniforms and uses `light`/`inView` to decide which guests are hidden.
-- Positions are in tile units where cell (x, y) has its centre at (x + 0.5,
-- y + 0.5). `v` is the vision value, VISION_FLOOR to 1.

local Config = require('config')

export type Ring = { x: number, y: number, age: number, flee: boolean }

export type Rings = {
    list: { Ring },
    timers: { [number]: number }, -- per guest id: seconds until its next ring
}

local Fog = {}

local function clamp01(x: number): number
    return math.clamp(x, 0, 1)
end

-- GLSL/WGSL smoothstep; edge0 must be below edge1 (WGSL leaves it undefined
-- otherwise, and vision.wgsl uses the same orientation).
local function smoothstep(edge0: number, edge1: number, x: number): number
    local t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

-- 0 at the vision floor, 1 at full vision.
function Fog.normalized(v: number): number
    return clamp01((v - Config.VISION_FLOOR) / (1 - Config.VISION_FLOOR))
end

-- Cone length in tiles and half-angle in radians. Vision drives both.
function Fog.coneLength(v: number): number
    return Config.CONE_LENGTH_MIN + (Config.CONE_LENGTH_MAX - Config.CONE_LENGTH_MIN) * clamp01(v)
end

function Fog.coneHalfAngle(v: number): number
    return Config.CONE_ANGLE_MIN + (Config.CONE_ANGLE_MAX - Config.CONE_ANGLE_MIN) * clamp01(v)
end

-- How lit the point (x, y) is for a head at (hx, hy) facing the unit vector
-- (dx, dy): the forward cone, or a faint disc of about a tile around the head
-- that stays even at minimum vision. The same shape as vision.wgsl, without
-- its noise and flicker: keep the two in step.
function Fog.light(hx: number, hy: number, dx: number, dy: number, v: number, x: number, y: number): number
    local ox = x - hx
    local oy = y - hy
    local dist = math.sqrt(ox * ox + oy * oy)
    local along = ox * dx + oy * dy
    local cross = math.abs(ox * dy - oy * dx)
    local angle = math.atan2(cross, along)
    local length = Fog.coneLength(v)
    local half = Fog.coneHalfAngle(v)
    local cone = (1 - smoothstep(length * 0.55, length, dist)) * (1 - smoothstep(half * 0.55, half, angle))
    local near = (1 - smoothstep(0.5, 1.5, dist)) * Config.NEAR_LIGHT
    return math.max(cone, near)
end

-- Whether a point counts as inside the visible area. A reveal shows it all.
function Fog.inView(
    hx: number,
    hy: number,
    dx: number,
    dy: number,
    v: number,
    reveal: number,
    x: number,
    y: number
): boolean
    if reveal > 0.05 then
        return true
    end
    return Fog.light(hx, hy, dx, dy, v, x, y) > Config.VISIBLE_LIGHT
end

-- Beats per second: slow at full vision, fast at the floor.
function Fog.beatRate(v: number): number
    local n = Fog.normalized(v)
    return Config.HEARTBEAT_FAST + (Config.HEARTBEAT_SLOW - Config.HEARTBEAT_FAST) * n
end

local function pulse(p: number, centre: number, width: number): number
    local d = (p - centre) / width
    return math.exp(-d * d)
end

-- A lub-dub envelope, 0-1, over one beat as `phase` runs 0 to 1.
function Fog.heartbeat(phase: number): number
    return clamp01(pulse(phase, 0.05, 0.05) + 0.7 * pulse(phase, 0.3, 0.06))
end

function Fog.newRings(): Rings
    return { list = {}, timers = {} }
end

-- Ages the rings, drops expired ones and starts a new ring from every guest
-- that is alerted or fleeing and cannot be seen, about once per RING_INTERVAL.
-- `visible` says whether a guest is inside the lit area.
function Fog.stepRings(rings: Rings, guests: { any }, visible: (any) -> boolean, dt: number)
    local kept: { Ring } = {}
    for _, r in rings.list do
        r.age += dt
        if r.age < Config.RING_LIFETIME then
            table.insert(kept, r)
        end
    end
    rings.list = kept

    for _, g in guests do
        local loud = not g.gone and (g.state == 'alert' or g.state == 'flee')
        if loud and not visible(g) then
            local left = (rings.timers[g.id] or 0) - dt
            if left <= 0 then
                table.insert(rings.list, { x = g.cell.x + 0.5, y = g.cell.y + 0.5, age = 0, flee = g.state == 'flee' })
                left = Config.RING_INTERVAL
            end
            rings.timers[g.id] = left
        else
            rings.timers[g.id] = nil -- quiet or in view: the next call rings at once
        end
    end
end

return Fog
