-- Headless tests for the Anaconda rules. Run with `rive . --test`.
local Sim = require('sim')
local Config = require('config')
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

-- Steps the simulation a whole number of 60 fps frames (no float rounding of a
-- seconds count).
local function frames(sim: Sim.Sim, n: number)
    for _ = 1, n do
        Sim.update(sim, 1 / 60)
    end
end

-- A playing sim in an empty walled room with the snake placed head-first on
-- `cells` and facing `dir`. Interior is x 1..w-2, y 1..h-2.
local function arena(w: number, h: number, cells: { Sim.Cell }, dir: Sim.Cell): Sim.Sim
    local sim = Sim.new(room(w, h, { { x = 1, y = 1, ch = 'S' } }), 1)
    Sim.start(sim)
    sim.cur = cells
    sim.prev = table.clone(cells)
    sim.dir = dir
    return sim
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
                local sim = play({ [90] = Sim.DOWN }, 160)
                expect(sim.eaten).is(1)
                expect(sim.score).is(100)
                expect(#sim.cur).is(6)
                expect(Sim.peopleLeft(sim)).is(5)
                expect(sim.state).is('playing')
                print(`real-level eat: eaten {sim.eaten}, score {sim.score}, length {#sim.cur}, peopleLeft {Sim.peopleLeft(sim)}`)
            end)

            test.case('a guest outruns the snake to the exit and escapes', function(expect)
                -- Same start, but the snake turns away along row 12 and then up.
                local sim = play({ [77] = Sim.DOWN, [134] = Sim.LEFT, [259] = Sim.UP }, 314)
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

            test.case('on an eating tick the tail does not advance, so the tail cell is a hit', function(expect)
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
                expect(sim.state).is('playing')
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.eaten).is(0)
                expect(sim.cur[1].x).is(2) -- stayed put
                expect(sim.cur[1].y).is(1)
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

        -- Unless a test says otherwise, arena(12, 9, ...) is the room these use:
        -- interior x 1..10, y 1..7, walls at x 0 and 11 and at y 0 and 8.
        test.group('pace', function()
            test.case('base tick rate is 5 moves per second', function(expect)
                expect(Config.TICK_RATE).is(5)
                expect(Sim.TICK).is(1 / 5)
            end)

            test.case('the snake makes five moves in one second', function(expect)
                local sim = arena(40, 5, { { x = 2, y = 2 }, { x = 1, y = 2 } }, Sim.RIGHT)
                frames(sim, 62) -- the sixth move is due at 72 frames
                expect(sim.cur[1].x).is(7)
            end)
        end)

        test.group('health', function()
            test.case('hitting a wall no longer ends the game', function(expect)
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 } }, Sim.RIGHT)
                Sim.stepSnake(sim)
                expect(sim.state).is('playing')
                expect(sim.hp).is(Config.MAX_HP - 1)
                -- Did not enter the wall.
                expect(sim.cur[1].x).is(10)
                expect(sim.cur[1].y).is(4)
                -- Impact recorded: the wall tile, and when.
                expect(sim.hitCell).never.is(nil)
                expect((sim.hitCell :: Sim.Cell).x).is(11)
                expect((sim.hitCell :: Sim.Cell).y).is(4)
                expect(sim.hitTime).is(sim.time)
            end)

            test.case('the impact time follows the clock', function(expect)
                local sim = arena(40, 5, { { x = 2, y = 2 }, { x = 1, y = 2 } }, Sim.RIGHT)
                sim.cur = { { x = 37, y = 2 }, { x = 36, y = 2 } }
                sim.prev = table.clone(sim.cur)
                frames(sim, 60) -- ~1s: 2 steps to the wall at x 39, then the hit
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.hitTime).greaterThan(0.3)
                expect(sim.hitTime).lessThan(0.5)
            end)

            test.case('colliding with its own body is a hit too', function(expect)
                -- Head (3,3) heading down into body segment (3,4); the tail is
                -- elsewhere, so the segment is solid.
                local sim = arena(12, 9, {
                    { x = 3, y = 3 },
                    { x = 2, y = 3 },
                    { x = 2, y = 4 },
                    { x = 3, y = 4 },
                    { x = 4, y = 4 },
                }, Sim.DOWN)
                Sim.stepSnake(sim)
                expect(sim.state).is('playing')
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.cur[1].x).is(3)
                expect(sim.cur[1].y).is(3)
            end)

            test.case('a hit grants an invulnerability window', function(expect)
                local function ram(sim: Sim.Sim)
                    sim.cur = { { x = 10, y = 4 }, { x = 9, y = 4 } }
                    sim.prev = table.clone(sim.cur)
                    sim.dir = Sim.RIGHT
                    Sim.stepSnake(sim)
                end
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 } }, Sim.RIGHT)
                ram(sim)
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.invulnLeft).is(Config.INVULN_TIME)
                local firstHit = sim.hitTime

                -- A second crash right away costs nothing and is not recorded...
                ram(sim)
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.hitTime).is(firstHit)
                -- ...but the snake still bounces off it.
                expect(sim.dir.x).is(0)

                -- Still protected just before the window closes.
                frames(sim, math.floor((Config.INVULN_TIME - 0.1) * 60))
                ram(sim)
                expect(sim.hp).is(Config.MAX_HP - 1)

                -- Past it, the next crash costs 1 HP again.
                frames(sim, 12)
                expect(sim.invulnLeft).is(0)
                ram(sim)
                expect(sim.hp).is(Config.MAX_HP - 2)
            end)

            test.case('a bounce chain cannot drain several HP', function(expect)
                -- A room three tiles tall: hit the east wall, bounce south, hit
                -- the south wall one step later, bounce west. Two impacts, 1 HP.
                local sim = arena(12, 5, { { x = 10, y = 2 }, { x = 9, y = 2 } }, Sim.RIGHT)
                Sim.stepSnake(sim) -- east wall, turns south
                expect(sim.hp).is(Config.MAX_HP - 1)
                Sim.stepSnake(sim) -- (10, 3)
                expect(sim.cur[1].y).is(3)
                Sim.stepSnake(sim) -- south wall, inside the window
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.dir.x).is(-1) -- turned west
                -- The recorded impact is still the first one.
                expect((sim.hitCell :: Sim.Cell).x).is(11)
            end)

            test.case('eating a guest heals 1 HP', function(expect)
                local sim = Sim.new({
                    '#############',
                    '#....SP.....#',
                    '#############',
                }, 2)
                Sim.start(sim)
                sim.hp = 3
                Sim.stepSnake(sim)
                expect(sim.eaten).is(1)
                expect(sim.hp).is(4)
            end)

            test.case('healing is capped at max HP', function(expect)
                local sim = Sim.new({
                    '#############',
                    '#....SP.....#',
                    '#############',
                }, 2)
                Sim.start(sim)
                expect(sim.hp).is(Config.MAX_HP)
                Sim.stepSnake(sim)
                expect(sim.eaten).is(1)
                expect(sim.hp).is(Config.MAX_HP)
            end)

            test.case('reaching 0 HP loses the game', function(expect)
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 } }, Sim.RIGHT)
                for i = 1, Config.MAX_HP do
                    expect(sim.state).is('playing')
                    sim.cur = { { x = 10, y = 4 }, { x = 9, y = 4 } }
                    sim.prev = table.clone(sim.cur)
                    sim.dir = Sim.RIGHT
                    sim.invulnLeft = 0 -- skip the window between crashes
                    Sim.stepSnake(sim)
                    expect(sim.hp).is(Config.MAX_HP - i)
                end
                expect(sim.hp).is(0)
                expect(sim.state).is('lost')
            end)

            test.case('three escapes still lose, at full health', function(expect)
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
                expect(sim.hp).is(Config.MAX_HP)
                expect(sim.state).is('lost')
            end)
        end)

        test.group('bounce', function()
            test.case('turns toward the side with the longer free run', function(expect)
                -- Head against the east wall; 1 free tile north, 5 south.
                local south = arena(12, 9, { { x = 10, y = 2 }, { x = 9, y = 2 } }, Sim.RIGHT)
                Sim.stepSnake(south)
                expect(south.dir.x).is(0)
                expect(south.dir.y).is(1)

                -- Mirrored: 5 free tiles north, 1 south.
                local north = arena(12, 9, { { x = 10, y = 6 }, { x = 9, y = 6 } }, Sim.RIGHT)
                Sim.stepSnake(north)
                expect(north.dir.x).is(0)
                expect(north.dir.y).is(-1)
            end)

            test.case('equal runs turn right', function(expect)
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 } }, Sim.RIGHT)
                Sim.stepSnake(sim)
                expect(sim.dir.x).is(0)
                expect(sim.dir.y).is(1) -- down is a right turn when heading east
            end)

            test.case('takes the only free side', function(expect)
                -- Head in the north-east corner: north is wall, only south is free.
                local sim = arena(12, 9, { { x = 10, y = 1 }, { x = 9, y = 1 } }, Sim.RIGHT)
                Sim.stepSnake(sim)
                expect(sim.dir.x).is(0)
                expect(sim.dir.y).is(1)

                -- Body below the head blocks south: only north is free.
                local body = arena(12, 9, {
                    { x = 10, y = 4 },
                    { x = 10, y = 5 },
                    { x = 9, y = 5 },
                    { x = 8, y = 5 },
                }, Sim.RIGHT)
                Sim.stepSnake(body)
                expect(body.dir.x).is(0)
                expect(body.dir.y).is(-1)
            end)

            test.case('a bounce keeps the snake moving the next tick', function(expect)
                local sim = arena(12, 9, { { x = 10, y = 2 }, { x = 9, y = 2 } }, Sim.RIGHT)
                Sim.stepSnake(sim) -- hit, turn south
                Sim.stepSnake(sim) -- and go
                expect(sim.cur[1].x).is(10)
                expect(sim.cur[1].y).is(3)
                expect(sim.hp).is(Config.MAX_HP - 1)
            end)

            test.case('a hit clears queued turns', function(expect)
                -- Heading up; RIGHT is queued into the east wall, then UP.
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 10, y = 5 } }, Sim.UP)
                Sim.queueTurn(sim, Sim.RIGHT)
                Sim.queueTurn(sim, Sim.UP)
                expect(#sim.turns).is(2)
                Sim.stepSnake(sim) -- RIGHT runs into the wall
                expect(#sim.turns).is(0)
            end)

            test.case('a key held into the wall cannot undo the bounce', function(expect)
                -- A held arrow key arrives as a stream of presses. Here RIGHT is
                -- pressed on every frame while the snake runs into the east wall.
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 }, { x = 8, y = 4 } }, Sim.RIGHT)
                for _ = 1, 40 do -- 0.67s: inside the invulnerability window
                    Sim.queueTurn(sim, Sim.RIGHT)
                    Sim.update(sim, 1 / 60)
                end
                expect(sim.hp).is(Config.MAX_HP - 1) -- one hit, not a stream of them
                expect(sim.dir.x).is(0) -- bounced
                -- Without the guard the snake keeps being steered back into the wall
                -- and sits at y 4. With it, it has made its two moves south.
                expect(sim.cur[1].y).greaterThanOrEqual(6)
            end)

            test.case('during the window, input into the blocked direction is ignored', function(expect)
                local sim = arena(12, 9, { { x = 10, y = 4 }, { x = 9, y = 4 } }, Sim.RIGHT)
                Sim.stepSnake(sim) -- east wall: bounces south
                expect(sim.dir.y).is(1)
                Sim.queueTurn(sim, Sim.RIGHT) -- into the wall just hit
                expect(#sim.turns).is(0)
                Sim.queueTurn(sim, Sim.LEFT) -- any other legal turn still works
                expect(#sim.turns).is(1)

                -- Once the window closes the same input is accepted again.
                sim.turns = {}
                sim.invulnLeft = 0
                Sim.queueTurn(sim, Sim.RIGHT)
                expect(#sim.turns).is(1)
            end)

            test.case('boxed in at a dead end: swaps ends and carries on', function(expect)
                -- Wall ahead, walls above and below, body behind: nowhere to turn.
                local sim = Sim.new({
                    '#########',
                    '#.......#',
                    '#########',
                }, 3)
                Sim.start(sim)
                sim.cur = { { x = 7, y = 1 }, { x = 6, y = 1 }, { x = 5, y = 1 } }
                sim.prev = table.clone(sim.cur)
                sim.dir = Sim.RIGHT
                Sim.stepSnake(sim)
                -- The tail is the head now and the snake faces west.
                expect(sim.cur[1].x).is(5)
                expect(sim.cur[3].x).is(7)
                expect(#sim.cur).is(3)
                expect(sim.dir.x).is(-1)
                expect(sim.dir.y).is(0)
                -- The swap itself cost nothing: only the hit that caused it did.
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.state).is('playing')

                -- And it moves off immediately.
                Sim.stepSnake(sim)
                Sim.stepSnake(sim)
                expect(sim.cur[1].x).is(3)
                expect(sim.hp).is(Config.MAX_HP - 1)
            end)

            test.case('swapping ends follows the way the tail was facing', function(expect)
                -- Head at the bottom of a dead-end shaft heading down; the tail
                -- segment points west along the top corridor.
                local sim = Sim.new({
                    '######',
                    '#....#',
                    '####.#',
                    '####.#',
                    '######',
                }, 3)
                Sim.start(sim)
                sim.cur = { { x = 4, y = 3 }, { x = 4, y = 2 }, { x = 4, y = 1 }, { x = 3, y = 1 } }
                sim.prev = table.clone(sim.cur)
                sim.dir = Sim.DOWN
                Sim.stepSnake(sim)
                expect(sim.cur[1].x).is(3)
                expect(sim.cur[1].y).is(1)
                expect(sim.cur[4].x).is(4)
                expect(sim.cur[4].y).is(3)
                expect(sim.dir.x).is(-1) -- west, not "up" (the reverse of the old heading)
                expect(sim.dir.y).is(0)
                Sim.stepSnake(sim)
                expect(sim.cur[1].x).is(2)
                expect(sim.hp).is(Config.MAX_HP - 1)
            end)
        end)

        test.group('lunge', function()
            test.case('moves three steps at triple rate, then slows back down', function(expect)
                local sim = arena(40, 5, { { x = 4, y = 2 }, { x = 3, y = 2 }, { x = 2, y = 2 } }, Sim.RIGHT)
                expect(Sim.lunge(sim)).is(true)
                expect(sim.lungeLeft).is(Config.LUNGE_STEPS)
                -- 3 steps at 3x = one base tick = 12 frames, plus 1 frame.
                frames(sim, 13)
                expect(sim.cur[1].x).is(4 + Config.LUNGE_STEPS)
                expect(sim.lungeLeft).is(0)
                -- Normal pace afterwards: no step for the rest of the base tick.
                frames(sim, 8)
                expect(sim.cur[1].x).is(4 + Config.LUNGE_STEPS)
                frames(sim, 12)
                expect(sim.cur[1].x).is(4 + Config.LUNGE_STEPS + 1)
            end)

            test.case('costs vision and starts the cooldown', function(expect)
                local sim = arena(40, 5, { { x = 4, y = 2 }, { x = 3, y = 2 } }, Sim.RIGHT)
                expect(sim.vision).is(1)
                expect(Sim.boostReady(sim)).is(true)
                expect(Sim.boostCooldown(sim)).is(0)
                Sim.lunge(sim)
                expect(sim.vision).greaterThan(1 - Config.LUNGE_VISION_COST - 0.0001)
                expect(sim.vision).lessThan(1 - Config.LUNGE_VISION_COST + 0.0001)
                expect(Sim.boostReady(sim)).is(false)
                expect(Sim.boostCooldown(sim)).is(1)
                frames(sim, 90) -- half the cooldown
                expect(Sim.boostCooldown(sim)).greaterThan(0.48)
                expect(Sim.boostCooldown(sim)).lessThan(0.52)
            end)

            test.case('hitting a wall mid-lunge is a normal hit and ends the lunge', function(expect)
                -- The wall at x 11 is 2 steps ahead of x 9... head at 9: step to 10, then hit.
                local sim = arena(12, 9, { { x = 9, y = 4 }, { x = 8, y = 4 }, { x = 7, y = 4 } }, Sim.RIGHT)
                Sim.lunge(sim)
                frames(sim, 13)
                expect(sim.hp).is(Config.MAX_HP - 1)
                expect(sim.state).is('playing')
                expect(sim.lungeLeft).is(0)
                -- It advanced one step (to the tile before the wall) and no further.
                expect(sim.cur[1].x).is(10)
                expect((sim.hitCell :: Sim.Cell).x).is(11)
                -- And bounced instead of carrying on east.
                expect(sim.dir.x).is(0)
            end)

            test.case('the cooldown blocks a second lunge until it runs out', function(expect)
                local sim = arena(80, 5, { { x = 4, y = 2 }, { x = 3, y = 2 } }, Sim.RIGHT)
                expect(Sim.lunge(sim)).is(true)
                frames(sim, 30) -- lunge over, cooldown still running
                local vision = sim.vision
                expect(Sim.lunge(sim)).is(false)
                expect(sim.lungeLeft).is(0)
                expect(sim.vision).is(vision) -- a refused lunge costs nothing

                frames(sim, math.floor(Config.LUNGE_COOLDOWN * 60) - 30 + 2)
                expect(Sim.boostReady(sim)).is(true)
                expect(Sim.lunge(sim)).is(true)
                expect(sim.vision).lessThan(vision)
            end)

            test.case('only works during play', function(expect)
                local sim = Sim.new(room(12, 9, { { x = 5, y = 4, ch = 'S' } }), 1)
                expect(Sim.lunge(sim)).is(false) -- still on the title screen
                expect(sim.vision).is(1)
            end)
        end)
    end
end
