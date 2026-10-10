-- Headless tests for the snake's body path and the head that follows it. Run
-- with `rive . --test`.
local Sim = require('sim')
local BodyPath = require('bodypath')

local TILE = 40 -- keep in step with main.luau
local HEAD_FACE_ARC = 12 -- ...and HEAD_FACE_ARC there: the head faces along the path this far back
local FPS = 60
local PI = math.pi

-- A walled w x h room with the snake's start (S) at tile (sx, sy).
local function room(w: number, h: number, sx: number, sy: number): { string }
    local rows: { string } = {}
    for y = 0, h - 1 do
        if y == 0 or y == h - 1 then
            rows[y + 1] = string.rep('#', w)
        else
            local cells = '#' .. string.rep('.', w - 2) .. '#'
            if y == sy then
                cells = string.sub(cells, 1, sx) .. 'S' .. string.sub(cells, sx + 2)
            end
            rows[y + 1] = cells
        end
    end
    return rows
end

-- The mid-tick fraction main.luau draws a playing snake at.
local function alphaOf(sim: Sim.Sim): number
    return math.clamp(sim.snakeAcc / Sim.TICK, 0, 1)
end

-- The signed difference between two angles, the short way round.
local function angleDiff(a: number, b: number): number
    return (b - a + PI) % (2 * PI) - PI
end

type Frame = {
    step: number, -- snake steps taken so far: which tick this frame is in
    x: number, -- where the head is drawn
    y: number,
    face: number, -- the way it points
    face20: number, -- the way the body runs 20 px behind the neck
    length: number, -- the path's length
    jx: { number }, -- the joints the path is rounded from
    jy: { number },
}

-- 60 fps of the snake running right, turning down at 3.5 s and carrying on. The
-- frames, and the step the turn happened at.
local function simulate(): ({ Frame }, number)
    local sim = Sim.new(room(40, 40, 5, 3), 1)
    Sim.start(sim)
    local frames: { Frame } = {}
    local steps = 0
    local turnStep = -1
    for f = 0, 8 * FPS - 1 do
        if f == math.floor(3.5 * FPS) then
            Sim.queueTurn(sim, Sim.DOWN)
        end
        local headBefore = sim.cur[1]
        local dirBefore = sim.dir
        Sim.update(sim, 1 / FPS)
        if sim.cur[1].x ~= headBefore.x or sim.cur[1].y ~= headBefore.y then
            steps += 1
            if sim.dir.x ~= dirBefore.x or sim.dir.y ~= dirBefore.y then
                turnStep = steps
            end
        end
        local alpha = alphaOf(sim)
        local path = BodyPath.build(sim.prev, sim.cur, alpha, TILE)
        local jx, jy = BodyPath.joints(sim.prev, sim.cur, alpha, TILE)
        frames[#frames + 1] = {
            step = steps,
            x = path.x[1],
            y = path.y[1],
            face = BodyPath.facing(path, HEAD_FACE_ARC),
            face20 = BodyPath.facing(path, 20),
            length = path.length,
            jx = jx,
            jy = jy,
        }
    end
    return frames, turnStep
end

return function(): Tests
    return function(test: Tester)
        test.group('head follows the body path', function()
            local cache: { Frame }? = nil
            local cachedTurn = -1
            local function data(): ({ Frame }, number)
                if cache == nil then
                    cache, cachedTurn = simulate()
                end
                return cache :: { Frame }, cachedTurn
            end

            -- Runs of consecutive frames on a straight: after the first step (the
            -- snake stands for its first tick) and before the turn, and after the
            -- turn's own tick.
            local function straights(): { { Frame } }
                local frames, turnStep = data()
                local before: { Frame } = {}
                local after: { Frame } = {}
                for _, fr in frames do
                    if fr.step >= 1 and fr.step < turnStep then
                        table.insert(before, fr)
                    elseif fr.step > turnStep then
                        table.insert(after, fr)
                    end
                end
                return { before, after }
            end

            test.case('the turn happens, with more than 3 s straight either side', function(expect)
                local frames, turnStep = data()
                local runs = straights()
                expect(turnStep).greaterThan(0)
                expect(#runs[1]).greaterThan(3 * FPS)
                expect(#runs[2]).greaterThan(3 * FPS)
                expect(#frames).is(8 * FPS)
            end)

            test.case('on a straight run the drawn angle never moves', function(expect)
                local runs = straights()
                local headings = { 0, PI / 2 } -- right, then down
                for r, run in runs do
                    local worst = 0.0
                    for i, fr in run do
                        if i > 1 then
                            worst = math.max(worst, math.abs(angleDiff(run[i - 1].face, fr.face)))
                        end
                        -- It is the heading itself, not merely steady, and so is the
                        -- body's direction 20 px behind the neck.
                        expect(math.abs(angleDiff(headings[r], fr.face))).lessThan(0.001)
                        expect(math.abs(angleDiff(fr.face, fr.face20))).lessThan(0.001)
                    end
                    expect(worst).lessThan(0.001)
                end
            end)

            test.case('the head advances by the same step every frame, tick edges included', function(expect)
                local runs = straights()
                local want = TILE / (Sim.TICK * FPS) -- px per frame
                for _, run in runs do
                    for i = 2, #run do
                        local step = math.sqrt((run[i].x - run[i - 1].x) ^ 2 + (run[i].y - run[i - 1].y) ^ 2)
                        expect(math.abs(step - want)).lessThan(0.001)
                    end
                end
            end)

            test.case('the path is as long all tick, turning tick included', function(expect)
                local frames = data()
                local want = 4 * TILE -- five cells, four segments
                for _, fr in frames do
                    if fr.step >= 1 then
                        expect(math.abs(fr.length - want)).lessThan(0.000001)
                    end
                end
            end)

            test.case('every joint but the head and tail is a cell centre that stays put all tick', function(expect)
                local frames = data()
                for i, fr in frames do
                    for j = 2, #fr.jx - 1 do
                        -- A cell centre: (k + 0.5) tiles.
                        expect(math.abs((fr.jx[j] / TILE - 0.5) % 1)).lessThan(0.000001)
                        expect(math.abs((fr.jy[j] / TILE - 0.5) % 1)).lessThan(0.000001)
                    end
                    local before = frames[i - 1]
                    if i > 1 and before.step == fr.step then
                        for j = 2, #fr.jx - 1 do
                            expect(fr.jx[j]).is(before.jx[j])
                            expect(fr.jy[j]).is(before.jy[j])
                        end
                    end
                end
            end)

            test.case('through the turn the head swings with the neck, never snapping', function(expect)
                local frames, turnStep = data()
                local first: Frame? = nil
                local last: Frame? = nil
                local worst = 0.0
                local previous: Frame? = nil
                for _, fr in frames do
                    if fr.step == turnStep then
                        first = first or fr
                        last = fr
                        if previous ~= nil then
                            local turn = angleDiff(previous.face, fr.face)
                            expect(turn).greaterThanOrEqual(-0.000001) -- one way round only
                            worst = math.max(worst, turn)
                        end
                    end
                    previous = fr
                end
                expect(first :: Frame).never.is(nil)
                expect(math.abs(angleDiff(0, (first :: Frame).face))).lessThan(0.05) -- starts the tick still straight
                expect(math.abs(angleDiff(PI / 2, (last :: Frame).face))).lessThan(0.001) -- and has come round by its end
                expect(worst).lessThan(0.6) -- a snap would be 1.57
            end)
        end)

        test.group('growing', function()
            test.case('eating makes the path a tile longer without anything jumping', function(expect)
                local sim = Sim.new({
                    '#############',
                    '#....SP.....#',
                    '#############',
                }, 2)
                Sim.start(sim)
                local before = BodyPath.build(sim.prev, sim.cur, 1, TILE)
                local grown0 = #sim.cur
                Sim.stepSnake(sim) -- the head enters the guest's tile
                expect(sim.eaten).is(1)
                expect(#sim.cur).is(grown0 + 1)

                -- The moment after the meal is the moment before it.
                local start = BodyPath.build(sim.prev, sim.cur, 0, TILE)
                expect(start.n).is(before.n)
                for i = 1, before.n do
                    expect(math.abs(start.x[i] - before.x[i])).lessThan(0.000001)
                    expect(math.abs(start.y[i] - before.y[i])).lessThan(0.000001)
                end

                -- Then only the head end grows: the tail and every joint stay where
                -- they were, and the length rises smoothly by one tile.
                local jx0, jy0 = BodyPath.joints(sim.prev, sim.cur, 0, TILE)
                local lastLength = start.length
                for k = 1, 10 do
                    local alpha = k / 10
                    local path = BodyPath.build(sim.prev, sim.cur, alpha, TILE)
                    local jx, jy = BodyPath.joints(sim.prev, sim.cur, alpha, TILE)
                    for j = 2, #jx do
                        expect(jx[j]).is(jx0[j])
                        expect(jy[j]).is(jy0[j])
                    end
                    expect(math.abs(path.x[path.n] - start.x[start.n])).lessThan(0.000001)
                    expect(math.abs(path.y[path.n] - start.y[start.n])).lessThan(0.000001)
                    expect(math.abs(path.length - (start.length + alpha * TILE))).lessThan(0.000001)
                    expect(path.length).greaterThan(lastLength)
                    lastLength = path.length
                end
            end)
        end)
    end
end
