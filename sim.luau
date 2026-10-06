-- Anaconda rules: snake, health, bounce, lunge, guests, AI, eating, escaping,
-- win/lose.
-- Pure Luau with no Rive API, so the headless tests (sim_test.luau) can drive
-- it directly. main.luau renders it and mirrors the numbers into the view model.

local Config = require('config')

export type Cell = { x: number, y: number }

export type GuestState = 'idle' | 'wander' | 'alert' | 'flee' | 'caught'

export type Guest = {
    id: number,
    cell: Cell,
    prev: Cell, -- cell before the last guest tick, for interpolation
    state: GuestState,
    alertLeft: number,
    caughtLeft: number,
    walking: boolean,
    modeLeft: number,
    heading: Cell,
    gone: boolean, -- eaten and finished shrinking, or escaped
}

export type Sim = {
    cols: number,
    rows: number,
    walls: { { boolean } },
    exitTile: { { boolean } },
    exits: { Cell },
    start: Cell,
    spawns: { Cell },

    -- snake, head first. prev/cur are the cells before/after the last tick.
    prev: { Cell },
    cur: { Cell },
    dir: Cell,
    turns: { Cell },
    snakeAcc: number, -- progress to the next step, in base-tick units
    guestAcc: number,
    bumpDir: Cell?, -- direction of the last wall/self bump, damaging or not

    -- health
    hp: number,
    invulnLeft: number,
    hitCell: Cell?, -- tile of the last damaging hit
    hitTime: number, -- sim.time of that hit; negative if none yet
    time: number, -- seconds since reset, for effects keyed to the clock

    -- lunge
    lungeLeft: number, -- boosted moves still to make
    cooldownLeft: number,
    vision: number, -- VISION_FLOOR to 1: decays without eating, a lunge costs some
    reveal: number, -- 1 to 0 after eating: lifts the darkness map-wide

    guests: { Guest },
    state: string, -- ready | playing | won | lost
    score: number,
    eaten: number,
    escaped: number,
    total: number,
    seed: number,
}

local Sim = {}

local TICK = 1 / Config.TICK_RATE
local GUEST_TICK = TICK / Config.GUEST_SPEED
local SIGHT = 7
local ALERT_TIME = 0.5
local CAUGHT_TIME = 0.4
local SCORE_PER_GUEST = 100
local ESCAPE_LIMIT = 3
local START_LENGTH = 5
-- At most this many turns wait in the queue: the one the next tick applies,
-- plus one buffered behind it, so two quick presses inside a tick both land.
local MAX_QUEUED_TURNS = 2

local RIGHT: Cell = { x = 1, y = 0 }
local LEFT: Cell = { x = -1, y = 0 }
local DOWN: Cell = { x = 0, y = 1 }
local UP: Cell = { x = 0, y = -1 }
local DIRS: { Cell } = { RIGHT, LEFT, DOWN, UP }

Sim.TICK = TICK
Sim.GUEST_TICK = GUEST_TICK
Sim.SIGHT = SIGHT
Sim.ALERT_TIME = ALERT_TIME
Sim.CAUGHT_TIME = CAUGHT_TIME
Sim.SCORE_PER_GUEST = SCORE_PER_GUEST
Sim.ESCAPE_LIMIT = ESCAPE_LIMIT
Sim.RIGHT = RIGHT
Sim.LEFT = LEFT
Sim.DOWN = DOWN
Sim.UP = UP

local function idx(sim: Sim, x: number, y: number): number
    return y * sim.cols + x + 1
end

local function isWall(sim: Sim, x: number, y: number): boolean
    if x < 0 or y < 0 or x >= sim.cols or y >= sim.rows then
        return true
    end
    return sim.walls[y + 1][x + 1]
end
Sim.isWall = isWall

local function isExit(sim: Sim, x: number, y: number): boolean
    if x < 0 or y < 0 or x >= sim.cols or y >= sim.rows then
        return false
    end
    return sim.exitTile[y + 1][x + 1]
end

-- Deterministic LCG so headless runs repeat.
local function rand(sim: Sim): number
    sim.seed = (sim.seed * 1664525 + 1013904223) % 4294967296
    return sim.seed / 4294967296
end

local function pick(sim: Sim, list: { Cell }): Cell
    return list[1 + math.floor(rand(sim) * #list)]
end

local function isActive(g: Guest): boolean
    return not g.gone and g.state ~= 'caught'
end

-- Every snake segment, head included, is a wall to the guests.
local function snakeBlocked(sim: Sim): { [number]: boolean }
    local blocked: { [number]: boolean } = {}
    for _, c in sim.cur do
        blocked[idx(sim, c.x, c.y)] = true
    end
    return blocked
end

local function activeGuestAt(sim: Sim, x: number, y: number): Guest?
    for _, g in sim.guests do
        if isActive(g) and g.cell.x == x and g.cell.y == y then
            return g
        end
    end
    return nil
end

-- Whether the snake's head cannot enter (x, y) on the next step, and the guest
-- standing there if it can. The tail cell is free unless a guest is eaten on
-- the same step: then the tail does not advance and still counts.
local function moveBlocked(sim: Sim, x: number, y: number): (boolean, Guest?)
    if isWall(sim, x, y) then
        return true, nil
    end
    local prey = activeGuestAt(sim, x, y)
    local n = #sim.cur
    local solid = if prey ~= nil then n else n - 1
    for i = 1, solid do
        local seg = sim.cur[i]
        if seg.x == x and seg.y == y then
            return true, nil
        end
    end
    return false, prey
end

-- Free tiles in a straight line from the head along `dir`. A body segment stops
-- mattering once the tail has had time to pull clear of it: segment i is gone by
-- the time the head makes its (n - i + 1)th step.
local function freeRun(sim: Sim, dir: Cell): number
    local head = sim.cur[1]
    local n = #sim.cur
    local run = 0
    for k = 1, sim.cols + sim.rows do
        local x = head.x + dir.x * k
        local y = head.y + dir.y * k
        if isWall(sim, x, y) then
            break
        end
        local inBody = false
        for i = 1, n - k do
            local seg = sim.cur[i]
            if seg.x == x and seg.y == y then
                inBody = true
                break
            end
        end
        if inBody then
            break
        end
        run = k
    end
    return run
end

-- The 90 degree turn a bounce takes: the only free side, else the side with the
-- longer free run (a tie turns right, clockwise on screen), else nil.
local function chooseBounce(sim: Sim, dir: Cell): Cell?
    local head = sim.cur[1]
    local right: Cell = { x = -dir.y, y = dir.x }
    local left: Cell = { x = dir.y, y = -dir.x }
    local rightFree = not moveBlocked(sim, head.x + right.x, head.y + right.y)
    local leftFree = not moveBlocked(sim, head.x + left.x, head.y + left.y)
    if rightFree and leftFree then
        if freeRun(sim, left) > freeRun(sim, right) then
            return left
        end
        return right
    elseif rightFree then
        return right
    elseif leftFree then
        return left
    end
    return nil
end

-- Breadth-first distances from the sources through cells that are not walls
-- and not in `blocked`. Unreached cells are absent from the result.
local function bfs(sim: Sim, sources: { Cell }, blocked: { [number]: boolean }): { [number]: number }
    local dist: { [number]: number } = {}
    local queue: { Cell } = {}
    for _, s in sources do
        local k = idx(sim, s.x, s.y)
        if dist[k] == nil then
            dist[k] = 0
            table.insert(queue, s)
        end
    end
    local head = 1
    while head <= #queue do
        local c = queue[head]
        head += 1
        local d = dist[idx(sim, c.x, c.y)] :: number
        for _, dir in DIRS do
            local nx = c.x + dir.x
            local ny = c.y + dir.y
            if not isWall(sim, nx, ny) then
                local k = idx(sim, nx, ny)
                if dist[k] == nil and not blocked[k] then
                    dist[k] = d + 1
                    table.insert(queue, { x = nx, y = ny })
                end
            end
        end
    end
    return dist
end

-- Walks the centre-to-centre segment; any wall or snake segment strictly
-- between the two cells breaks the line.
local function lineOfSight(sim: Sim, a: Cell, b: Cell, blocked: { [number]: boolean }): boolean
    local dx = b.x - a.x
    local dy = b.y - a.y
    local steps = math.max(math.abs(dx), math.abs(dy)) * 4
    for i = 1, steps - 1 do
        local t = i / steps
        local tx = math.floor(a.x + 0.5 + dx * t)
        local ty = math.floor(a.y + 0.5 + dy * t)
        local atA = tx == a.x and ty == a.y
        local atB = tx == b.x and ty == b.y
        if not atA and not atB then
            if isWall(sim, tx, ty) or blocked[idx(sim, tx, ty)] then
                return false
            end
        end
    end
    return true
end

local function sees(sim: Sim, g: Guest, blocked: { [number]: boolean }): boolean
    local head = sim.cur[1]
    local dx = head.x - g.cell.x
    local dy = head.y - g.cell.y
    if dx * dx + dy * dy > SIGHT * SIGHT then
        return false
    end
    return lineOfSight(sim, g.cell, head, blocked)
end

-- Neighbouring cells a guest may step onto: floor, not snake, not another guest.
local function openNeighbors(sim: Sim, g: Guest, blocked: { [number]: boolean }, allowExit: boolean): { Cell }
    local out: { Cell } = {}
    for _, d in DIRS do
        local nx = g.cell.x + d.x
        local ny = g.cell.y + d.y
        if
            not isWall(sim, nx, ny)
            and not blocked[idx(sim, nx, ny)]
            and (allowExit or not isExit(sim, nx, ny))
            and activeGuestAt(sim, nx, ny) == nil
        then
            table.insert(out, { x = nx, y = ny })
        end
    end
    return out
end

local function checkWinLose(sim: Sim)
    if sim.state ~= 'playing' then
        return
    end
    if sim.escaped >= ESCAPE_LIMIT then
        sim.state = 'lost'
    elseif sim.total > 0 and sim.eaten >= sim.total then
        sim.state = 'won'
    end
end

local function escape(sim: Sim, g: Guest)
    g.gone = true
    sim.escaped += 1
    checkWinLose(sim)
end

local function eat(sim: Sim, g: Guest)
    g.state = 'caught'
    g.caughtLeft = CAUGHT_TIME
    sim.eaten += 1
    sim.score += SCORE_PER_GUEST
    sim.hp = math.min(Config.MAX_HP, sim.hp + Config.HEAL_PER_GUEST)
    sim.vision = 1
    sim.reveal = 1
    checkWinLose(sim)
end

local function moveGuest(g: Guest, to: Cell)
    g.heading = { x = to.x - g.cell.x, y = to.y - g.cell.y }
    g.cell = to
end

-- Run for the exit if there is an open path to a free E tile, otherwise to the
-- neighbour farthest (by BFS) from the snake head. A cornered guest stays put.
local function fleeStep(
    sim: Sim,
    g: Guest,
    blocked: { [number]: boolean },
    headDist: { [number]: number },
    exitDist: { [number]: number }
)
    local options = openNeighbors(sim, g, blocked, true)
    if #options == 0 then
        return
    end
    local here = idx(sim, g.cell.x, g.cell.y)
    local best: { Cell } = {}
    if exitDist[here] ~= nil then
        local bestD = math.huge
        for _, c in options do
            local d = exitDist[idx(sim, c.x, c.y)]
            if d ~= nil then
                if d < bestD then
                    bestD = d
                    best = { c }
                elseif d == bestD then
                    table.insert(best, c)
                end
            end
        end
    else
        local hereD = headDist[here]
        if hereD == nil then
            return -- sealed off from the snake: already safe
        end
        local bestD = -1.0
        for _, c in options do
            local d = headDist[idx(sim, c.x, c.y)] or math.huge
            if d > bestD then
                bestD = d
                best = { c }
            elseif d == bestD then
                table.insert(best, c)
            end
        end
        if bestD < hereD then
            return -- every step gets closer: stay
        end
    end
    if #best == 0 then
        return
    end
    local to = pick(sim, best)
    moveGuest(g, to)
    if isExit(sim, to.x, to.y) then
        escape(sim, g)
    end
end

-- Idle for a while, then amble randomly for a while.
local function wanderStep(sim: Sim, g: Guest, blocked: { [number]: boolean })
    g.modeLeft -= GUEST_TICK
    if g.modeLeft <= 0 then
        if rand(sim) < 0.4 then
            g.walking = false
            g.modeLeft = 0.8 + rand(sim) * 1.7
        else
            g.walking = true
            g.modeLeft = 1.0 + rand(sim) * 2.0
        end
    end
    if not g.walking then
        g.state = 'idle'
        return
    end
    local options = openNeighbors(sim, g, blocked, false)
    if #options == 0 then
        g.state = 'idle'
        return
    end
    local to = pick(sim, options)
    if rand(sim) < 0.6 then
        for _, c in options do
            if c.x - g.cell.x == g.heading.x and c.y - g.cell.y == g.heading.y then
                to = c
            end
        end
    end
    moveGuest(g, to)
    g.state = 'wander'
end

local function newGuest(sim: Sim, id: number, cell: Cell): Guest
    return {
        id = id,
        cell = cell,
        prev = cell,
        state = 'idle',
        alertLeft = 0,
        caughtLeft = 0,
        walking = false,
        modeLeft = 0.3 + rand(sim) * 1.2,
        heading = RIGHT,
        gone = false,
    }
end

-- Snake starts on S facing right with four segments trailing left.
function Sim.reset(sim: Sim, state: string)
    local cells: { Cell } = {}
    for i = 0, START_LENGTH - 1 do
        table.insert(cells, { x = sim.start.x - i, y = sim.start.y })
    end
    sim.cur = cells
    sim.prev = table.clone(cells)
    sim.dir = RIGHT
    sim.turns = {}
    sim.snakeAcc = 0
    sim.guestAcc = 0
    sim.bumpDir = nil
    sim.hp = Config.MAX_HP
    sim.invulnLeft = 0
    sim.hitCell = nil
    sim.hitTime = -1
    sim.time = 0
    sim.lungeLeft = 0
    sim.cooldownLeft = 0
    sim.vision = 1
    sim.reveal = 0
    sim.guests = {}
    for i, s in sim.spawns do
        table.insert(sim.guests, newGuest(sim, i, { x = s.x, y = s.y }))
    end
    sim.total = #sim.spawns
    sim.score = 0
    sim.eaten = 0
    sim.escaped = 0
    sim.state = state
end

function Sim.new(level: { string }, seed: number): Sim
    local rows = #level
    local cols = #level[1]
    local walls: { { boolean } } = {}
    local exitTile: { { boolean } } = {}
    local exits: { Cell } = {}
    local spawns: { Cell } = {}
    local start: Cell = { x = 0, y = 0 }
    for row = 1, rows do
        local wallRow: { boolean } = {}
        local exitRow: { boolean } = {}
        for col = 1, cols do
            local ch = string.sub(level[row], col, col)
            local x = col - 1
            local y = row - 1
            wallRow[col] = ch == '#'
            exitRow[col] = ch == 'E'
            if ch == 'S' then
                start = { x = x, y = y }
            elseif ch == 'P' then
                table.insert(spawns, { x = x, y = y })
            elseif ch == 'E' then
                table.insert(exits, { x = x, y = y })
            end
        end
        walls[row] = wallRow
        exitTile[row] = exitRow
    end
    local sim: Sim = {
        cols = cols,
        rows = rows,
        walls = walls,
        exitTile = exitTile,
        exits = exits,
        start = start,
        spawns = spawns,
        prev = {},
        cur = {},
        dir = RIGHT,
        turns = {},
        snakeAcc = 0,
        guestAcc = 0,
        bumpDir = nil,
        hp = Config.MAX_HP,
        invulnLeft = 0,
        hitCell = nil,
        hitTime = -1,
        time = 0,
        lungeLeft = 0,
        cooldownLeft = 0,
        vision = 1,
        reveal = 0,
        guests = {},
        state = 'ready',
        score = 0,
        eaten = 0,
        escaped = 0,
        total = 0,
        seed = seed,
    }
    Sim.reset(sim, 'ready')
    return sim
end

function Sim.start(sim: Sim)
    sim.state = 'playing'
end

function Sim.peopleLeft(sim: Sim): number
    local n = 0
    for _, g in sim.guests do
        if isActive(g) then
            n += 1
        end
    end
    return n
end

function Sim.queueTurn(sim: Sim, dir: Cell)
    if #sim.turns >= MAX_QUEUED_TURNS then
        return
    end
    -- Right after a bump, steering back into the blocked direction is ignored,
    -- so a key held down into the wall cannot undo the bounce.
    local bump = sim.bumpDir
    if sim.invulnLeft > 0 and bump ~= nil and bump.x == dir.x and bump.y == dir.y then
        return
    end
    -- Judge the turn against the direction the snake will be heading by then.
    local heading = sim.dir
    if #sim.turns > 0 then
        heading = sim.turns[#sim.turns]
    end
    local same = heading.x == dir.x and heading.y == dir.y
    local reverse = heading.x == -dir.x and heading.y == -dir.y
    if same or reverse then
        return
    end
    table.insert(sim.turns, dir)
end

-- Boxed in: the tail becomes the head and the snake carries on the way the tail
-- segment was facing (from the segment before it, out to the tail).
local function swapEnds(sim: Sim)
    local n = #sim.cur
    local tail = sim.cur[n]
    local facing: Cell = { x = -sim.dir.x, y = -sim.dir.y }
    if n >= 2 then
        local before = sim.cur[n - 1]
        facing = { x = tail.x - before.x, y = tail.y - before.y }
    end
    local reversed: { Cell } = {}
    for i = n, 1, -1 do
        table.insert(reversed, sim.cur[i])
    end
    sim.cur = reversed
    sim.prev = table.clone(reversed)
    sim.dir = facing
end

-- A wall or self collision. The snake stays where it is, queued turns and any
-- lunge are dropped, and it bounces: turns 90 degrees toward free space, or
-- swaps ends if there is none. Outside the invulnerability window the hit also
-- costs 1 HP and is recorded; at 0 HP the game is lost. Swapping ends is free.
local function hit(sim: Sim, x: number, y: number)
    sim.turns = {}
    sim.lungeLeft = 0
    sim.bumpDir = { x = sim.dir.x, y = sim.dir.y }
    sim.prev = table.clone(sim.cur) -- nothing slides this tick
    if sim.invulnLeft <= 0 then
        sim.hp = math.max(0, sim.hp - 1)
        sim.invulnLeft = Config.INVULN_TIME
        sim.hitCell = { x = x, y = y }
        sim.hitTime = sim.time
        if sim.hp <= 0 then
            sim.state = 'lost'
            return
        end
    end
    local turn = chooseBounce(sim, sim.dir)
    if turn ~= nil then
        sim.dir = turn
    else
        swapEnds(sim)
    end
end

-- One snake step. A blocked tile is a hit (see `hit`) and the snake does not
-- move. Entering a guest's tile eats it: the tail does not advance that tick,
-- so the snake grows by one, and the whole old body (tail included) still counts
-- for self-collision.
function Sim.stepSnake(sim: Sim)
    if #sim.turns > 0 then
        sim.dir = table.remove(sim.turns, 1) :: Cell
    end
    local head = sim.cur[1]
    local nx = head.x + sim.dir.x
    local ny = head.y + sim.dir.y
    local blocked, prey = moveBlocked(sim, nx, ny)
    if blocked then
        hit(sim, nx, ny)
        return
    end

    local n = #sim.cur
    local solid = if prey ~= nil then n else n - 1
    local nextCells: { Cell } = { { x = nx, y = ny } }
    for i = 1, solid do
        table.insert(nextCells, sim.cur[i])
    end
    local prevCells = table.clone(sim.cur)
    if prey ~= nil then
        table.insert(prevCells, sim.cur[n]) -- new tail segment starts at the old tail
    end
    sim.prev = prevCells
    sim.cur = nextCells
    if sim.lungeLeft > 0 then
        sim.lungeLeft -= 1
    end

    if prey ~= nil then
        eat(sim, prey)
    end
end

-- Starts a lunge: the next LUNGE_STEPS moves run at LUNGE_MULTIPLIER x the tick
-- rate. Refused outside play or during the cooldown.
function Sim.lunge(sim: Sim): boolean
    if sim.state ~= 'playing' or sim.cooldownLeft > 0 then
        return false
    end
    sim.lungeLeft = Config.LUNGE_STEPS
    sim.cooldownLeft = Config.LUNGE_COOLDOWN
    sim.vision = math.max(Config.VISION_FLOOR, sim.vision - Config.LUNGE_VISION_COST)
    return true
end

function Sim.boostReady(sim: Sim): boolean
    return sim.cooldownLeft <= 0
end

-- 1 right after a lunge, falling to 0 as the cooldown runs out.
function Sim.boostCooldown(sim: Sim): number
    return math.clamp(sim.cooldownLeft / Config.LUNGE_COOLDOWN, 0, 1)
end

-- One guest step (guests run at 75% of snake speed).
function Sim.stepGuests(sim: Sim)
    local blocked = snakeBlocked(sim)
    local head = sim.cur[1]
    local headDist = bfs(sim, { head }, blocked)
    -- A snake segment sitting on an E tile seals that exit.
    local freeExits: { Cell } = {}
    for _, e in sim.exits do
        if not blocked[idx(sim, e.x, e.y)] then
            table.insert(freeExits, e)
        end
    end
    local exitDist = bfs(sim, freeExits, blocked)

    for _, g in sim.guests do
        g.prev = g.cell
    end
    for _, g in sim.guests do
        if sim.state ~= 'playing' then
            break
        end
        if isActive(g) then
            if g.state == 'flee' then
                fleeStep(sim, g, blocked, headDist, exitDist)
            elseif g.state == 'alert' then
                -- holds still until the alert timer runs out
            elseif sees(sim, g, blocked) then
                g.state = 'alert'
                g.alertLeft = ALERT_TIME
            else
                wanderStep(sim, g, blocked)
            end
        end
    end
end

function Sim.update(sim: Sim, dt: number)
    for _, g in sim.guests do
        if g.state == 'caught' and not g.gone then
            g.caughtLeft -= dt
            if g.caughtLeft <= 0 then
                g.gone = true
            end
        end
    end
    sim.reveal = math.max(0, sim.reveal - dt / Config.REVEAL_TIME)
    if sim.state ~= 'playing' then
        sim.time += dt -- hit effects keep running on the end screen
        return
    end
    -- Hunger: vision drains toward the floor until the next meal.
    sim.vision = math.max(Config.VISION_FLOOR, sim.vision - dt * (1 - Config.VISION_FLOOR) / Config.VISION_DECAY_TIME)
    for _, g in sim.guests do
        if g.state == 'alert' and not g.gone then
            g.alertLeft -= dt
            if g.alertLeft <= 0 then
                g.state = 'flee'
            end
        end
    end

    -- The snake advances in slices, one per step, so a lunge's faster rate
    -- starts and stops on the exact step and the timers see the true time.
    -- snakeAcc counts in base-tick units: a lunge fills it LUNGE_MULTIPLIER
    -- times faster.
    local function pass(d: number)
        sim.time += d
        sim.invulnLeft = math.max(0, sim.invulnLeft - d)
        sim.cooldownLeft = math.max(0, sim.cooldownLeft - d)
    end
    local remaining = dt
    while remaining > 0 and sim.state == 'playing' do
        local rate = if sim.lungeLeft > 0 then Config.LUNGE_MULTIPLIER else 1
        local need = math.max(0, TICK - sim.snakeAcc) / rate
        if remaining >= need then
            pass(need)
            remaining -= need
            sim.snakeAcc = 0
            Sim.stepSnake(sim)
        else
            pass(remaining)
            sim.snakeAcc += remaining * rate
            remaining = 0
        end
    end
    if remaining > 0 then
        sim.time += remaining
    end

    sim.guestAcc += dt
    while sim.guestAcc >= GUEST_TICK and sim.state == 'playing' do
        sim.guestAcc -= GUEST_TICK
        Sim.stepGuests(sim)
    end
end

return Sim
