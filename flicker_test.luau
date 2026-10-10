-- Headless tests for the lights. Run with `rive . --test`.
local Config = require('config')
local Fog = require('fog')
local Flicker = require('flicker')
local Lighting = require('lighting')

local DT = 1 / 60

-- A playing context with the head at tile (x, y) and nobody about.
local function ctx(x: number, y: number): Flicker.Context
    return {
        playing = true,
        headX = x + 0.5,
        headY = y + 0.5,
        lunging = false,
        guests = {},
        beatPhase = 0.5,
        forceEvents = false,
        forceChase = false,
    }
end

local function run(state: Flicker.State, seconds: number, c: Flicker.Context, perFrame: (() -> ())?)
    for _ = 1, math.floor(seconds / DT + 0.5) do
        Flicker.update(state, DT, c)
        if perFrame ~= nil then
            perFrame()
        end
    end
end

-- The corridor start, a doorway-free spot between rooms.
local CORRIDOR = { x = 5, y = 7 }

return function(): Tests
    return function(test: Tester)
        test.group('flicker controllers', function()
            test.case('every group is on while the game is not being played', function(expect)
                local state = Flicker.new(1)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                run(state, 20, c, nil)
                c.playing = false
                Flicker.update(state, DT, c)
                for g = 1, Flicker.GROUP_COUNT do
                    expect(state.intensity[g]).is(1)
                end
                local t = state.elapsed
                Flicker.update(state, 1, c)
                expect(state.elapsed).is(t)
            end)

            test.case('intensities stay between 0 and 1', function(expect)
                local state = Flicker.new(2)
                local c = ctx(3, 12)
                c.forceEvents = true
                c.forceChase = true
                local lowest, highest = 1.0, 0.0
                run(state, 60, c, function()
                    for g = 1, Flicker.GROUP_COUNT do
                        lowest = math.min(lowest, state.intensity[g])
                        highest = math.max(highest, state.intensity[g])
                    end
                end)
                expect(lowest).greaterThanOrEqual(0)
                expect(highest).lessThanOrEqual(1)
            end)

            test.case('no events in the quiet time at the start of a run', function(expect)
                local state = Flicker.new(3)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                c.forceEvents = true -- even this waits for the quiet time to pass
                local sagged = false
                run(state, Config.LIGHTS_QUIET_TIME - 0.1, c, function()
                    if state.intensity[5] < 1 or state.intensity[8] < 1 then
                        sagged = true
                    end
                end)
                expect(sagged).is(false)
                run(state, 1, c, nil)
                expect(math.min(state.intensity[5], state.intensity[8])).lessThan(1)
            end)

            test.case('a steady group runs its own event now and then', function(expect)
                local state = Flicker.new(4)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                local lowest = 1.0
                run(state, 60, c, function()
                    lowest = math.min(lowest, state.intensity[5])
                end)
                expect(lowest).lessThan(0.5)
                expect(lowest).greaterThanOrEqual(Config.HALL_SAG_TO - 0.001)
            end)

            test.case('a room fires its event shortly after the head enters it', function(expect)
                local state = Flicker.new(5)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                run(state, 4, c, nil) -- past the quiet time, before any gap has run out
                expect(state.intensity[5]).is(1)
                local hall = ctx(10, 12) -- main_hall
                local lowest = 1.0
                run(state, 1.2, hall, function()
                    lowest = math.min(lowest, state.intensity[5])
                end)
                expect(Flicker.ROOMS[state.room :: number].name).is('main_hall')
                expect(lowest).lessThan(0.6)
            end)

            test.case('the groups are in the order of the mask atlas', function(expect)
                local state = Flicker.new(6)
                local names = {}
                for i, g in state.groups do
                    names[i] = g.name
                end
                expect(table.concat(names, ',')).is(
                    'dj_room,lounge,bar,kitchen,main_hall,games,bathroom,foyer,red_room,corridors'
                )
                for i, room in Flicker.ROOMS do
                    expect(state.groups[room.group].name).is(room.name)
                    expect(i).is(room.group)
                end
            end)

            test.case('rooms are found by tile, corridors and doorways are none', function(expect)
                expect(Flicker.roomAt(1, 1)).is(1)
                expect(Flicker.roomAt(6, 5)).is(1)
                expect(Flicker.roomAt(7, 3)).is(nil) -- the wall between
                expect(Flicker.roomAt(3, 6)).is(nil) -- the doorway below
                expect(Flicker.roomAt(5, 7)).is(nil) -- the corridor
                expect(Flicker.roomAt(12, 21)).is(8) -- foyer
                expect(Flicker.roomAt(22, 22)).is(9) -- red_room
            end)
        end)

        test.group('chase tension', function()
            local function guest(state: string, x: number, y: number): any
                return { gone = false, state = state, cell = { x = x, y = y } }
            end

            test.case('rises while a guest in range flees and falls slowly after', function(expect)
                local state = Flicker.new(7)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                c.guests = { guest('flee', CORRIDOR.x + 3, CORRIDOR.y) }
                run(state, 2, c, nil)
                expect(state.tension).greaterThan(0.95)
                c.guests = {}
                run(state, 0.5, c, nil)
                expect(state.tension).greaterThan(0.6)
                run(state, 10, c, nil)
                expect(state.tension).lessThan(0.05)
            end)

            test.case('an alerted guest counts for less, a far one for nothing', function(expect)
                local state = Flicker.new(8)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                c.guests = { guest('alert', CORRIDOR.x + 2, CORRIDOR.y), guest('flee', CORRIDOR.x + 12, CORRIDOR.y) }
                run(state, 4, c, nil)
                expect(state.tension).greaterThan(Config.CHASE_ALERT - 0.02)
                expect(state.tension).lessThan(Config.CHASE_ALERT + 0.001)
            end)

            test.case('a lunge is a chase', function(expect)
                local state = Flicker.new(9)
                local c = ctx(CORRIDOR.x, CORRIDOR.y)
                c.lunging = true
                run(state, 3, c, nil)
                expect(state.tension).greaterThan(Config.CHASE_LUNGE - 0.02)
                expect(state.tension).lessThan(Config.CHASE_LUNGE + 0.001)
            end)

            test.case('a chase only jitters the groups near the head', function(expect)
                local calm = Flicker.new(10)
                local chased = Flicker.new(10)
                local a = ctx(3, 3) -- dj_room, far from the games and the red room
                local b = ctx(3, 3)
                b.forceChase = true
                run(calm, 2.5, a, nil)
                run(chased, 2.5, b, nil)
                for _, far in { 6, 9 } do
                    expect(chased.intensity[far]).is(calm.intensity[far])
                end
                -- ...and only ever to make them dimmer
                local dimmerEver = false
                local brighterEver = false
                local calm2 = Flicker.new(10)
                local chased2 = Flicker.new(10)
                for _ = 1, 150 do
                    Flicker.update(calm2, DT, a)
                    Flicker.update(chased2, DT, b)
                    if chased2.intensity[1] < calm2.intensity[1] - 0.001 then
                        dimmerEver = true
                    elseif chased2.intensity[1] > calm2.intensity[1] + 0.001 then
                        brighterEver = true
                    end
                end
                expect(dimmerEver).is(true)
                expect(brighterEver).is(false)
            end)

            test.case('a blackout in the room the snake is in is cut short in a chase', function(expect)
                -- Longest unbroken stretch the kitchen spends dark, over a few seeds.
                local function longestDark(chase: boolean): number
                    local longest = 0.0
                    for seed = 1, 8 do
                        local state = Flicker.new(seed)
                        local c = ctx(3, 12) -- kitchen
                        c.forceEvents = true
                        c.forceChase = chase
                        local dark = 0.0
                        run(state, 90, c, function()
                            if state.intensity[4] < 0.1 then
                                dark += DT
                                longest = math.max(longest, dark)
                            else
                                dark = 0
                            end
                        end)
                    end
                    return longest
                end
                -- With the chase's own jitter the level can also dip, so the bound
                -- is on stretches below 0.1 and allows a few frames of slack.
                expect(longestDark(false)).greaterThan(Config.CHASE_BLACKOUT_MAX + 0.1)
                expect(longestDark(true)).lessThan(Config.CHASE_BLACKOUT_MAX + 0.1)
            end)
        end)

        test.group('safe flashing', function()
            local FLOOR = Config.SAFE_FLASH_FLOOR

            -- Times at which each group's level began a drop below the floor, and
            -- how often it sat exactly on the floor (a drop the limiter cut short).
            local function drops(seed: number, seconds: number, chase: boolean): ({ { number } }, number, number)
                local state = Flicker.new(seed)
                local c = ctx(3, 12) -- kitchen: the dj_room is within range, so chase jitter runs there
                c.forceEvents = true
                c.forceChase = chase
                local starts: { { number } } = {}
                local previous: { number } = {}
                for g = 1, Flicker.GROUP_COUNT do
                    starts[g] = {}
                    previous[g] = 1
                end
                local clamped = 0
                local highs = 0
                run(state, seconds, c, function()
                    for g = 1, Flicker.GROUP_COUNT do
                        local level = state.intensity[g]
                        if level < FLOOR and previous[g] >= FLOOR then
                            table.insert(starts[g], state.elapsed)
                        end
                        if g == 1 then
                            if math.abs(level - FLOOR) < 1e-9 then
                                clamped += 1
                            elseif level > 0.9 then
                                highs += 1
                            end
                        end
                        previous[g] = level
                    end
                end)
                return starts, clamped, highs
            end

            local function spacingOk(starts: { { number } }): boolean
                for _, list in starts do
                    for i = 2, #list do
                        -- a frame of slack: levels are sampled at 60 fps
                        if list[i] - list[i - 1] < Config.SAFE_FLASH_INTERVAL - DT then
                            return false
                        end
                    end
                end
                return true
            end

            test.case('no group starts a deep drop more than every third of a second', function(expect)
                for seed = 1, 4 do
                    local starts = drops(seed, 60, false)
                    expect(spacingOk(starts)).is(true)
                    expect(#starts[1]).greaterThan(10) -- the strobe still gets its drops through
                end
            end)

            test.case('the same in a chase, with its jitter on top', function(expect)
                for seed = 1, 4 do
                    expect(spacingOk((drops(seed, 60, true)))).is(true)
                end
            end)

            test.case('the strobe keeps its rhythm: it flips between the floor and near full', function(expect)
                local _, clamped, highs = drops(1, 60, false)
                expect(clamped).greaterThan(20) -- frames held at the floor
                expect(highs).greaterThan(20) -- and frames near full
            end)

            test.case('with it off the strobe drops as often as it likes', function(expect)
                Config.SAFE_FLASHING = false
                local starts = drops(1, 60, false)
                Config.SAFE_FLASHING = true
                expect(spacingOk(starts)).is(false)
            end)

            test.case('a long blackout is one drop and goes all the way down', function(expect)
                local state = Flicker.new(1)
                local c = ctx(3, 12)
                c.forceEvents = true
                local lowest = 1.0
                run(state, 60, c, function()
                    lowest = math.min(lowest, state.intensity[4])
                end)
                expect(lowest).lessThan(0.1)
            end)

            test.case('the strike flash fires at most once every half second', function(expect)
                local state = Flicker.new(1)
                expect(Flicker.tryFlash(state)).is(true)
                expect(Flicker.tryFlash(state)).is(false)
                Flicker.update(state, 0.49, ctx(CORRIDOR.x, CORRIDOR.y))
                expect(Flicker.tryFlash(state)).is(false)
                Flicker.update(state, 0.02, ctx(CORRIDOR.x, CORRIDOR.y))
                expect(Flicker.tryFlash(state)).is(true)
                Config.SAFE_FLASHING = false
                expect(Flicker.tryFlash(state)).is(true)
                expect(Flicker.tryFlash(state)).is(true)
                Config.SAFE_FLASHING = true
            end)
        end)

        test.group('lighting', function()
            -- The data files are hex strings decoded into buffers at load. These
            -- are what the old number tables gave at the same points (x, y, then the
            -- base light's r, g, b, then the flicker multiplier with the groups at
            -- the intensities below), worked out independently of the decoder.
            test.case('the decoded light and flicker data sample as the old tables did', function(expect)
                local refs = {
                { 3.5, 10.25, 0.292156863, 0.417647059, 0.231372549, 0.229843743 },
                { 12, 12.5, 1.000000000, 0.815686275, 0.323529412, 0.955971584 },
                { 12, 8, 0.462745098, 0.356862745, 0.524509804, 0.592517566 },
                { 19.5, 12.5, 0.493137255, 0.851960784, 1.000000000, 0.655266633 },
                { 7.3, 7.9, 0.164313725, 0.174901961, 0.242745098, 0.982847059 },
                { -3, -3, 0.160784314, 0.160784314, 0.200000000, 1.000000000 },
                { 23.9, 23.9, 0.160784314, 0.160784314, 0.200000000, 1.000000000 },
                { 0.2, 23.9, 0.160784314, 0.160784314, 0.200000000, 1.000000000 },
                { 12, 3, 0.942156863, 0.765686275, 1.000000000, 0.869720539 },
                }
                Lighting.setIntensities({ 1, 0.7, 1, 0.2, 1, 0.5, 1, 1, 0.9, 0.4 })
                for _, ref in refs do
                    local r, g, b = Lighting.baseLight(ref[1], ref[2])
                    expect(math.abs(r - ref[3])).lessThan(0.000001)
                    expect(math.abs(g - ref[4])).lessThan(0.000001)
                    expect(math.abs(b - ref[5])).lessThan(0.000001)
                    expect(math.abs(Lighting.flickerMult(ref[1], ref[2]) - ref[6])).lessThan(0.000001)
                end
                Lighting.setIntensities({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
            end)

            test.case('all lights on leaves the flicker multiplier at 1', function(expect)
                Lighting.setIntensities({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
                expect(Lighting.flickerMult(3.5, 12.5)).is(1)
                expect(Lighting.flickerMult(0.2, 23.9)).is(1)
            end)

            test.case('a dead group darkens its own room and leaves the others be', function(expect)
                Lighting.setIntensities({ 1, 1, 1, 0, 1, 1, 1, 1, 1, 1 }) -- the kitchen is out
                expect(Lighting.flickerMult(3.5, 10.25)).lessThan(0.2) -- at the kitchen's lights
                expect(Lighting.flickerMult(19.5, 12.5)).greaterThan(0.95) -- the games room
                expect(Lighting.flickerMult(12, 3)).greaterThan(0.95) -- the lounge
                Lighting.setIntensities({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
            end)

            test.case('the multiplier is the product over the groups', function(expect)
                Lighting.setIntensities({ 1, 1, 1, 0.5, 1, 1, 1, 1, 1, 1 })
                local half = Lighting.flickerMult(3.5, 10.25)
                Lighting.setIntensities({ 1, 1, 1, 0, 1, 1, 1, 1, 1, 1 })
                local dead = Lighting.flickerMult(3.5, 10.25)
                -- 1 - share * (1 - I) is linear in I
                expect(math.abs((1 - half) * 2 - (1 - dead)) < 0.001).is(true)
                Lighting.setIntensities({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
            end)

            test.case('the room light and the corridor light differ', function(expect)
                local hr, hg, hb = Lighting.lightRgb(12, 12.5) -- main hall, warm
                local cr, _, cb = Lighting.lightRgb(12, 8) -- corridor, cool
                expect(hr - hb).greaterThan(cr - cb)
                expect(hr + hg + hb).greaterThan(0.4)
            end)

            test.case('points off the map clamp to the nearest sample', function(expect)
                local r, g, b = Lighting.lightRgb(-3, -3)
                local r2, g2, b2 = Lighting.lightRgb(0.25, 0.25)
                expect(r).is(r2)
                expect(g).is(g2)
                expect(b).is(b2)
            end)
        end)

        test.group('room sight', function()
            test.case('lit rooms are seen, dark ones squinted at', function(expect)
                expect(Fog.roomSeen(1, 1)).is(true)
                expect(Fog.roomSeen(1, 0)).is(false) -- 0.8 * 0.25 = 0.2: not above the threshold
                expect(Fog.roomSeen(0.2, 1)).is(false) -- just came in
                expect(Fog.roomSeen(0, 1)).is(false)
                expect(Fog.roomLight(1, 1)).is(Config.ROOM_SIGHT_GAIN)
            end)
        end)
    end
end
