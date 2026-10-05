-- Headless tests for the Anaconda rules. Run with `rive . --test`.
local Sim = require('sim')
local Level = require('level')

type Mark = { x: number, y: number, ch: string }

-- A walled w x h room, with marks (S, P, E, ...) stamped over it. E marks sit
-- in the wall row.
local function room(w: number, h: number, marks: { Mark }): { string }
    local grid: { { string } } = {}
    for y = 1, h do
        local row: { string } = {}
        for x = 1, w do
            local border = x == 1 or x == w or y == 1 or y == h
            row[x] = if border then '#' else '.'
        end
        grid[y] = row
    end
    for _, m in marks do
        grid[m.y + 1][m.x + 1] = m.ch
    end
    local rows: { string } = {}
    for y = 1, h do
        rows[y] = table.concat(grid[y])
    end
    return rows
end

-- Runs the whole simulation at 60 fps until `done` or the time limit.
local function run(sim: Sim.Sim, seconds: number, done: (() -> boolean)?, perFrame: (() -> ())?)
    local dt = 1 / 60
    local frames = math.floor(seconds / dt)
    for _ = 1, frames do
        Sim.update(sim, dt)
        if perFrame ~= nil then
            perFrame()
        end
        if done ~= nil and done() then
            return
        end
    end
end

local function snakeHas(sim: Sim.Sim, x: number, y: number): boolean
    for _, c in sim.cur do
        if c.x == x and c.y == y then
            return true
        end
    end
    return false
end

return function(): Tests
    return function(test: Tester)
        test.group('real level, scripted input', function()
            -- Plays the shipped map at 60 fps. `keys` maps a frame number to the
            -- turn pressed just before that frame is simulated.
            local function play(keys: { [number]: Sim.Cell }, frames: number): Sim.Sim
                local sim = Sim.new(Level, 20240607)
                Sim.start(sim)
                for f = 0, frames - 1 do
                    local k = keys[f]
                    if k ~= nil then
                        Sim.queueTurn(sim, k)
                    end
                    Sim.update(sim, 1 / 60)
                end
                return sim
            end

            test.case('snake chases a guest down a corridor and eats it', function(expect)
                -- Right along the top corridor, then down column 11 after the guest.
                local sim = play({ [48] = Sim.DOWN }, 150)
                expect(sim.eaten).is(1)
                expect(sim.score).is(100)
                expect(#sim.cur).is(6)
                expect(Sim.peopleLeft(sim)).is(5)
                expect(sim.state).is('playing')
                print(`real-level eat: eaten {sim.eaten}, score {sim.score}, length {#sim.cur}, peopleLeft {Sim.peopleLeft(sim)}`)
            end)

            test.case('a guest outruns the snake to the exit and escapes', function(expect)
                -- Same start, but the snake turns away along row 12 and then up.
                local sim = play({ [48] = Sim.DOWN, [84] = Sim.LEFT, [162] = Sim.UP }, 196)
                expect(sim.escaped).greaterThanOrEqual(1)
                expect(sim.state).is('playing') -- fewer than 3 escaped, snake still alive
                -- Every guest is either still around, eaten, or escaped.
                expect(Sim.peopleLeft(sim) + sim.eaten + sim.escaped).is(6)
                print(`real-level escape: escaped {sim.escaped}, eaten {sim.eaten}, peopleLeft {Sim.peopleLeft(sim)}, state {sim.state}`)
            end)
        end)

        test.group('chase and eat', function()
            test.case('snake chases a cornered guest and eats it', function(expect)
                -- One-row corridor, guest in a dead end 6 tiles ahead.
                local sim = Sim.new({
                    '##############',
                    '#....S.....P.#',
                    '##############',
                }, 1)
                Sim.start(sim)
                local guest = sim.guests[1]
                local sawAlert = false
                local sawFlee = false
                local frames = 0
                run(sim, 6, function()
                    return sim.state ~= 'playing'
                end, function()
                    frames += 1
                    if guest.state == 'alert' then
                        sawAlert = true
                    elseif guest.state == 'flee' then
                        sawFlee = true
                    end
                end)

                expect(sawAlert).is(true)
                expect(sawFlee).is(true)
                expect(sim.eaten).is(1)
                expect(sim.score).is(100)
                expect(#sim.cur).is(6) -- grew by one
                expect(Sim.peopleLeft(sim)).is(0)
                expect(guest.state).is('caught')
                expect(sim.state).is('won') -- every guest eaten

                -- The caught guest finishes its animation, then is removed.
                run(sim, Sim.CAUGHT_TIME + 0.1)
                expect(guest.gone).is(true)
                print(`eat test: caught after {frames} frames, score {sim.score}, length {#sim.cur}`)
            end)

            test.case('eating grows the snake from the tail end', function(expect)
                local sim = Sim.new({
                    '#############',
                    '#....SP.....#',
                    '#############',
                }, 2)
                Sim.start(sim)
                local before = table.clone(sim.cur)
                Sim.stepSnake(sim) -- head enters the guest's tile
                expect(sim.eaten).is(1)
                expect(#sim.cur).is(#before + 1)
                -- The old tail cell is still occupied: the tail did not advance.
                local tail = before[#before]
                expect(sim.cur[#sim.cur].x).is(tail.x)
                expect(sim.cur[#sim.cur].y).is(tail.y)
            end)

            test.case('guests move at 75% of snake speed', function(expect)
                expect(Sim.GUEST_TICK / Sim.TICK).greaterThan(1.33)
                expect(Sim.GUEST_TICK / Sim.TICK).lessThan(1.34)
            end)
        end)

        test.group('escape', function()
            test.case('a fleeing guest runs for the exit and escapes', function(expect)
                local sim = Sim.new(
                    room(28, 7, {
                        { x = 14, y = 3, ch = 'S' },
                        { x = 20, y = 3, ch = 'P' },
                        { x = 20, y = 6, ch = 'E' },
                    }),
                    3
                )
                Sim.start(sim)
                -- Steer the snake up and away to the west so it stays alive.
                Sim.queueTurn(sim, Sim.UP)
                Sim.queueTurn(sim, Sim.LEFT)
                local guest = sim.guests[1]
                local alertFrames = 0
                local sawFlee = false
                run(sim, 4, function()
                    return guest.gone or sim.state ~= 'playing'
                end, function()
                    if guest.state == 'alert' then
                        alertFrames += 1
                    elseif guest.state == 'flee' then
                        sawFlee = true
                    end
                end)

                expect(sim.escaped).is(1)
                expect(guest.gone).is(true)
                expect(Sim.peopleLeft(sim)).is(0)
                expect(sim.eaten).is(0)
                expect(sim.state).is('playing') -- one escape is not a loss
                expect(sawFlee).is(true)
                -- Alert lasts half a second (30 frames at 60 fps).
                expect(alertFrames).greaterThanOrEqual(28)
                expect(alertFrames).lessThanOrEqual(33)
                print(`escape test: alert {alertFrames} frames, escaped {sim.escaped}, snake head ({sim.cur[1].x},{sim.cur[1].y})`)
            end)

            test.case('a snake segment on an E tile seals the exit', function(expect)
                local level = room(9, 5, {
                    { x = 1, y = 1, ch = 'S' },
                    { x = 4, y = 3, ch = 'P' },
                    { x = 4, y = 4, ch = 'E' },
                })
                -- Control: nobody near the exit, the guest escapes.
                local open = Sim.new(level, 4)
                Sim.start(open)
                open.guests[1].state = 'flee'
                for _ = 1, 10 do
                    Sim.stepGuests(open)
                end
                expect(open.escaped).is(1)

                -- Snake sitting on the E tile: the same guest cannot get out.
                local sealed = Sim.new(level, 4)
                Sim.start(sealed)
                sealed.cur = { { x = 4, y = 4 } }
                sealed.prev = table.clone(sealed.cur)
                sealed.guests[1].state = 'flee'
                for _ = 1, 30 do
                    Sim.stepGuests(sealed)
                end
                expect(sealed.escaped).is(0)
                expect(sealed.guests[1].gone).is(false)
            end)

            test.case('three escapes lose the game', function(expect)
                local sim = Sim.new(
                    room(12, 3, {
                        { x = 9, y = 1, ch = 'S' },
                        { x = 1, y = 1, ch = 'P' },
                        { x = 2, y = 1, ch = 'P' },
                        { x = 3, y = 1, ch = 'P' },
                        { x = 1, y = 2, ch = 'E' },
                        { x = 2, y = 2, ch = 'E' },
                        { x = 3, y = 2, ch = 'E' },
                    }),
                    5
                )
                Sim.start(sim)
                for _, g in sim.guests do
                    g.state = 'flee'
                end
                Sim.stepGuests(sim)
                expect(sim.escaped).is(3)
                expect(sim.state).is('lost')
            end)
        end)

        test.group('snake is an obstacle', function()
            test.case('guests never step onto a snake segment', function(expect)
                local sim = Sim.new(
                    room(9, 3, {
                        { x = 5, y = 1, ch = 'S' },
                        { x = 6, y = 1, ch = 'P' },
                    }),
                    6
                )
                Sim.start(sim)
                sim.guests[1].state = 'flee'
                for _ = 1, 40 do
                    Sim.stepGuests(sim)
                    local c = sim.guests[1].cell
                    expect(snakeHas(sim, c.x, c.y)).is(false)
                end
                -- Stuck on the far side of the body from the exit side: never passed it.
                expect(sim.guests[1].cell.x).greaterThan(5)
            end)

            test.case('a guest beside the body flees along the floor, not through the body', function(expect)
                local sim = Sim.new(
                    room(9, 4, {
                        { x = 3, y = 1, ch = 'P' },
                        { x = 7, y = 2, ch = 'S' },
                    }),
                    12
                )
                Sim.start(sim)
                -- Head (5,1), body wraps under the guest: (5,2) (4,2) (3,2).
                sim.cur = { { x = 5, y = 1 }, { x = 5, y = 2 }, { x = 4, y = 2 }, { x = 3, y = 2 } }
                sim.prev = table.clone(sim.cur)
                local guest = sim.guests[1]
                guest.state = 'flee'
                -- (3,2) is body, so unreachable from the head; it must not look like
                -- the "farthest" tile. The only way away is west along row 1.
                Sim.stepGuests(sim)
                expect(guest.cell.x).is(2)
                expect(guest.cell.y).is(1)
                expect(snakeHas(sim, guest.cell.x, guest.cell.y)).is(false)
            end)

            test.case('a body segment in the way breaks line of sight', function(expect)
                local level = room(11, 3, { { x = 1, y = 1, ch = 'P' }, { x = 5, y = 1, ch = 'S' } })
                -- Control: clear corridor, the guest at the far end sees the head.
                local clear = Sim.new(level, 7)
                Sim.start(clear)
                clear.cur = { { x = 6, y = 1 } }
                clear.prev = table.clone(clear.cur)
                Sim.stepGuests(clear)
                expect(clear.guests[1].state).is('alert')

                -- A segment between them blocks the view.
                local blocked = Sim.new(level, 7)
                Sim.start(blocked)
                blocked.cur = { { x = 6, y = 1 }, { x = 5, y = 1 }, { x = 4, y = 1 } }
                blocked.prev = table.clone(blocked.cur)
                for _ = 1, 12 do
                    Sim.stepGuests(blocked)
                    expect(blocked.guests[1].state).never.is('alert')
                end
            end)

            test.case('guests beyond 7 tiles are not noticed', function(expect)
                local sim = Sim.new(room(20, 3, { { x = 1, y = 1, ch = 'P' }, { x = 17, y = 1, ch = 'S' } }), 8)
                Sim.start(sim)
                sim.cur = { { x = 12, y = 1 } } -- 11 tiles away
                sim.prev = table.clone(sim.cur)
                Sim.stepGuests(sim)
                expect(sim.guests[1].state).never.is('alert')
            end)
        end)

        test.group('collisions', function()
            local box = {
                '#####',
                '#...#',
                '#...#',
                '#####',
            }
            local function coil(): Sim.Sim
                local sim = Sim.new(box, 9)
                Sim.start(sim)
                -- Head (2,1) heading down at the tail (2,2) of a 2x2 coil.
                sim.cur = { { x = 2, y = 1 }, { x = 1, y = 1 }, { x = 1, y = 2 }, { x = 2, y = 2 } }
                sim.prev = table.clone(sim.cur)
                sim.dir = Sim.DOWN
                return sim
            end

            test.case('moving into the tail cell is fine when nothing is eaten', function(expect)
                local sim = coil()
                Sim.stepSnake(sim)
                expect(sim.state).is('playing')
                expect(#sim.cur).is(4)
            end)

            test.case('on an eating tick the tail does not advance, so the tail cell is a collision', function(expect)
                local sim = Sim.new({
                    '#####',
                    '#..P#',
                    '#...#',
                    '#####',
                }, 9)
                Sim.start(sim)
                sim.cur = { { x = 2, y = 1 }, { x = 1, y = 1 }, { x = 1, y = 2 }, { x = 2, y = 2 } }
                sim.prev = table.clone(sim.cur)
                sim.dir = Sim.DOWN
                -- A guest sits on the tail cell, so this tick would both eat and enter the tail.
                sim.guests[1].cell = { x = 2, y = 2 }
                sim.guests[1].prev = sim.guests[1].cell
                Sim.stepSnake(sim)
                expect(sim.state).is('lost')
                expect(sim.eaten).is(0)
            end)

            test.case('walls lose', function(expect)
                local sim = Sim.new({
                    '########',
                    '#.S....#',
                    '########',
                }, 10)
                -- Not enough room for the 5-segment snake: shorten it for the test.
                Sim.start(sim)
                sim.cur = { { x = 6, y = 1 }, { x = 5, y = 1 } }
                sim.prev = table.clone(sim.cur)
                sim.dir = Sim.RIGHT
                Sim.stepSnake(sim)
                expect(sim.state).is('lost')
            end)

            test.case('queued turns cannot reverse the snake', function(expect)
                local sim = Sim.new(room(12, 5, { { x = 7, y = 2, ch = 'S' } }), 11)
                Sim.start(sim)
                Sim.queueTurn(sim, Sim.LEFT) -- straight back into itself: ignored
                expect(#sim.turns).is(0)
                Sim.queueTurn(sim, Sim.UP)
                Sim.queueTurn(sim, Sim.LEFT) -- legal relative to the queued UP
                Sim.queueTurn(sim, Sim.DOWN) -- buffer is full
                expect(#sim.turns).is(2)
            end)
        end)
    end
end
