-- The snake's body as a smooth path, and which way its head faces along it.
-- Pure geometry (no drawing), so main.luau draws it and bodypath_test.luau
-- checks the very same numbers.
--
-- The path is built from the trail, not from per-cell lerps. Every frame its
-- joints are
--
--   head = lerp(prev[1], cur[1], alpha), prev[1], prev[2] .. prev[n-1],
--   tail = lerp(prev[n], cur[n], alpha)
--
-- so every interior joint is a real cell centre that does not move during the
-- tick; only the head segment grows (0 to a tile) and the tail segment shrinks
-- (a tile to 0). When the snake has just eaten, `prev` repeats its tail cell,
-- the tail segment is empty all tick and the path simply gets a tile longer.

local BodyPath = {}

export type Cell = { x: number, y: number }

export type Path = {
    x: { number }, -- samples down the rounded path, head first
    y: { number },
    a: { number }, -- distance along the trail from the head, px (see `fillet`)
    tx: { number }, -- unit tangent, pointing head to tail
    ty: { number },
    nx: { number }, -- unit normal pointing to the snake's left
    ny: { number },
    n: number,
    length: number, -- a[n]: the trail's length
}

local FILLET_STEPS = 8
local RUN_STEP = 10 -- px between samples on a straight run
local MIN_SEGMENT = 0.01 -- px: joints closer than this are one joint

BodyPath.FILLET_STEPS = FILLET_STEPS

-- The joints, in px, head first, for the tick `alpha` (0-1) of the way from
-- `prev` to `cur`. Cells are tile coordinates; the joint is the tile's centre.
function BodyPath.joints(prev: { Cell }, cur: { Cell }, alpha: number, tile: number): ({ number }, { number })
    local n = math.min(#prev, #cur)
    local xs: { number } = {}
    local ys: { number } = {}
    local head0, head1 = prev[1], cur[1]
    xs[1] = (head0.x + (head1.x - head0.x) * alpha + 0.5) * tile
    ys[1] = (head0.y + (head1.y - head0.y) * alpha + 0.5) * tile
    for i = 1, n - 1 do
        xs[i + 1] = (prev[i].x + 0.5) * tile
        ys[i + 1] = (prev[i].y + 0.5) * tile
    end
    local tail0, tail1 = prev[n], cur[n]
    xs[n + 1] = (tail0.x + (tail1.x - tail0.x) * alpha + 0.5) * tile
    ys[n + 1] = (tail0.y + (tail1.y - tail0.y) * alpha + 0.5) * tile
    return xs, ys
end

-- Rounds the joints into samples. Each interior corner becomes a quadratic
-- fillet, the joint as its control point, from r px before the joint to r px
-- after it, with r = min(tile / 2, half of each adjoining segment's length), so
-- a corner grows in smoothly from nothing as its segment lengthens.
--
-- `a` is the distance along the *trail*: a fillet is given the 2r of trail it
-- stands in for, not its own (shorter) length. That keeps `a`, and everything
-- measured by it (the skin's texture coordinate, the neck and tail tapers),
-- from shifting while a corner's radius changes, and makes `length` the same
-- all tick whatever the shape of the snake.
function BodyPath.fillet(pointsX: { number }, pointsY: { number }, tile: number): Path
    -- Joints that sit on the one before have no direction: leave them out.
    local jx: { number } = {}
    local jy: { number } = {}
    local m = 0
    for i = 1, #pointsX do
        if m == 0 or (pointsX[i] - jx[m]) ^ 2 + (pointsY[i] - jy[m]) ^ 2 > MIN_SEGMENT * MIN_SEGMENT then
            m += 1
            jx[m] = pointsX[i]
            jy[m] = pointsY[i]
        end
    end

    -- Each segment's length and unit direction, and the trail distance to each joint.
    local len: { number } = {}
    local dx: { number } = {}
    local dy: { number } = {}
    local at: { number } = { 0 }
    for k = 1, m - 1 do
        local sx = jx[k + 1] - jx[k]
        local sy = jy[k + 1] - jy[k]
        len[k] = math.sqrt(sx * sx + sy * sy)
        dx[k] = sx / len[k]
        dy[k] = sy / len[k]
        at[k + 1] = at[k] + len[k]
    end

    -- Samples, with the path's exact direction at each (head to tail): a run's
    -- own direction, or a fillet's, which is the blend of the two segments it
    -- joins (the derivative of the quadratic), so that it meets the straight
    -- on either side without a kink. The snake's left is that direction turned
    -- a quarter.
    local x: { number } = {}
    local y: { number } = {}
    local a: { number } = {}
    local tx: { number } = {}
    local ty: { number } = {}
    local n = 0
    local function emit(px: number, py: number, trail: number, ux: number, uy: number)
        n += 1
        x[n] = px
        y[n] = py
        a[n] = trail
        tx[n] = ux
        ty[n] = uy
    end
    -- A straight run from the last sample to (toX, toY), a sample every RUN_STEP,
    -- along segment k.
    local function run(toX: number, toY: number, toTrail: number, k: number)
        local fromX, fromY, fromTrail = x[n], y[n], a[n]
        local length = math.sqrt((toX - fromX) ^ 2 + (toY - fromY) ^ 2)
        if length < MIN_SEGMENT then
            return
        end
        local steps = math.ceil(length / RUN_STEP)
        for s = 1, steps do
            local f = s / steps
            emit(
                fromX + (toX - fromX) * f,
                fromY + (toY - fromY) * f,
                fromTrail + (toTrail - fromTrail) * f,
                dx[k],
                dy[k]
            )
        end
    end

    if m >= 2 then
        emit(jx[1], jy[1], 0, dx[1], dy[1])
    else
        emit(jx[1], jy[1], 0, 1, 0)
    end
    for k = 2, m do
        local r = 0.0
        if k < m then
            local cross = dx[k - 1] * dy[k] - dy[k - 1] * dx[k]
            local dot = dx[k - 1] * dx[k] + dy[k - 1] * dy[k]
            if math.abs(cross) > 0.001 or dot < 0 then
                r = math.min(tile / 2, len[k - 1] / 2, len[k] / 2)
            end
        end
        if r > MIN_SEGMENT then
            local ax, ay = jx[k] - dx[k - 1] * r, jy[k] - dy[k - 1] * r
            local bx, by = jx[k] + dx[k] * r, jy[k] + dy[k] * r
            run(ax, ay, at[k] - r, k - 1)
            for s = 1, FILLET_STEPS do
                local t = s / FILLET_STEPS
                local u = 1 - t
                local ux = u * dx[k - 1] + t * dx[k]
                local uy = u * dy[k - 1] + t * dy[k]
                local ul = math.sqrt(ux * ux + uy * uy)
                if ul < 0.0001 then
                    ux, uy, ul = dx[k - 1], dy[k - 1], 1
                end
                emit(
                    u * u * ax + 2 * u * t * jx[k] + t * t * bx,
                    u * u * ay + 2 * u * t * jy[k] + t * t * by,
                    at[k] - r + 2 * r * t,
                    ux / ul,
                    uy / ul
                )
            end
        else
            run(jx[k], jy[k], at[k], k - 1)
        end
    end

    local nx: { number } = {}
    local ny: { number } = {}
    for i = 1, n do
        nx[i], ny[i] = -ty[i], tx[i]
    end
    return { x = x, y = y, a = a, tx = tx, ty = ty, nx = nx, ny = ny, n = n, length = a[n] }
end

-- The path for the snake as it is `alpha` of the way through a tick.
function BodyPath.build(prev: { Cell }, cur: { Cell }, alpha: number, tile: number): Path
    local xs, ys = BodyPath.joints(prev, cur, alpha, tile)
    return BodyPath.fillet(xs, ys, tile)
end

-- The direction the head faces, radians, if it lies along the path where it is
-- `arc` px along the trail from the head: the tangent there, turned about to
-- point out of the head rather than down the body. Blends smoothly between the
-- samples, so it turns with the path rather than in steps.
function BodyPath.facing(path: Path, arc: number): number
    local n = path.n
    local i = 1
    while i < n - 1 and path.a[i + 1] < arc do
        i += 1
    end
    local tx, ty = path.tx[i], path.ty[i]
    if n >= 2 then
        local span = path.a[i + 1] - path.a[i]
        local f = if span > 0.0001 then math.clamp((arc - path.a[i]) / span, 0, 1) else 0
        tx += (path.tx[i + 1] - tx) * f
        ty += (path.ty[i + 1] - ty) * f
    end
    return math.atan2(-ty, -tx)
end

return BodyPath
