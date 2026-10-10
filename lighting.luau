-- Everything about light at a point of the level, for the things drawn in
-- the normal renderer (the snake). The floor, walls and guests get the same
-- treatment from vision.wgsl. Points are in tile units, cell (x, y) spanning
-- [x, x + 1) x [y, y + 1).
--
--   lightAt(x, y)     the room's lighting there: lightmap.luau (all lights on)
--                     times flickerMult
--   flickerMult(x, y) how much of the light at that point is left, from the
--                     intensities flicker.luau decided on:
--                         product over groups g of (1 - share_g * (1 - I_g))
--                     where share_g, from flicker_mask.luau, is the part of
--                     that point's light that group g provides.

local LightMap = require('lightmap')
local FlickerMask = require('flicker_mask')

local Lighting = {}

local GROUPS = #FlickerMask.groups
local ON = 0.999 -- an intensity above this is as good as on

-- The intensity of each light group, 0-1; main.luau sets it every frame from
-- flicker.luau. All on until then.
local intensity: { number } = {}
for g = 1, GROUPS do
    intensity[g] = 1
end

function Lighting.setIntensities(list: { number })
    for g = 1, GROUPS do
        intensity[g] = list[g] or 1
    end
end

-- Where the four texels of a bilinear lookup are and how much each counts.
-- The samples sit at (i + 0.5) / perTile tiles; the edges clamp.
local function footprint(size: number, perTile: number, x: number, y: number): (number, number, number, number, number, number)
    local gx = x * perTile - 0.5
    local gy = y * perTile - 0.5
    local x0 = math.floor(gx)
    local y0 = math.floor(gy)
    local fx = gx - x0
    local fy = gy - y0
    local last = size - 1
    return math.clamp(x0, 0, last), math.clamp(x0 + 1, 0, last), math.clamp(y0, 0, last), math.clamp(y0 + 1, 0, last), fx, fy
end

local function bilinear(data: { number }, size: number, stride: number, channel: number, c0: number, c1: number, r0: number, r1: number, fx: number, fy: number): number
    local a = data[(r0 * size + c0) * stride + channel]
    local b = data[(r0 * size + c1) * stride + channel]
    local c = data[(r1 * size + c0) * stride + channel]
    local d = data[(r1 * size + c1) * stride + channel]
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
end

function Lighting.flickerMult(x: number, y: number): number
    local size = FlickerMask.size
    local c0, c1, r0, r1, fx, fy = footprint(size, FlickerMask.perTile, x, y)
    local mult = 1.0
    for g = 1, GROUPS do
        local i = intensity[g]
        if i < ON then
            local share = bilinear(FlickerMask.loss, size, GROUPS, g, c0, c1, r0, r1, fx, fy) / 255
            mult *= 1 - share * (1 - i)
        end
    end
    return mult
end

-- The room lighting at a point, all lights on and before any flicker, as 0-1
-- channels. (The lightmap already carries the ambient floor.)
function Lighting.baseLight(x: number, y: number): (number, number, number)
    local size = LightMap.size
    local c0, c1, r0, r1, fx, fy = footprint(size, LightMap.perTile, x, y)
    local rgb = LightMap.rgb
    return bilinear(rgb, size, 3, 1, c0, c1, r0, r1, fx, fy) / 255,
        bilinear(rgb, size, 3, 2, c0, c1, r0, r1, fx, fy) / 255,
        bilinear(rgb, size, 3, 3, c0, c1, r0, r1, fx, fy) / 255
end

-- lightAt as 0-1 channels, for callers that blend it over time.
function Lighting.lightRgb(x: number, y: number): (number, number, number)
    local r, g, b = Lighting.baseLight(x, y)
    local m = Lighting.flickerMult(x, y)
    return r * m, g * m, b * m
end

-- A 0-1 channel triple as a Color.
function Lighting.color(r: number, g: number, b: number): Color
    return Color.rgb(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function Lighting.lightAt(x: number, y: number): Color
    return Lighting.color(Lighting.lightRgb(x, y))
end

return Lighting
