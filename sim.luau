-- Anaconda rules: snake, guests, AI, eating, escaping, win/lose.
-- Pure Luau with no Rive API, so the headless tests (sim_test.luau) can drive
-- it directly. main.luau renders it and mirrors the numbers into the view model.

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
    snakeAcc: number,
    guestAcc: number,

    guests: { Guest },
    state: string, -- ready | playing | won | lost
    score: number,
    eaten: number,
    escaped: number,
    total: number,
    seed: number,
}

local Sim = {}

local TICK = 1 / 8
local GUEST_SPEED = 0.75 -- of snake speed
local GUEST_TICK = TICK / GUEST_SPEED
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

-- One snake step. Wall or self collision loses. Entering a guest's tile eats
-- it: the tail does not advance that tick, so the snake grows by one, and the
-- whole old body (tail included) still counts for self-collision.
function Sim.stepSnake(sim: Sim)
    if #sim.turns > 0 then
        sim.dir = table.remove(sim.turns, 1) :: Cell
    end
    local head = sim.cur[1]
    local nx = head.x + sim.dir.x
    local ny = head.y + sim.dir.y
    if isWall(sim, nx, ny) then
        sim.state = 'lost'
        return
    end

    local prey = activeGuestAt(sim, nx, ny)
    local n = #sim.cur
    local solid = if prey ~= nil then n else n - 1
    for i = 1, solid do
        local seg = sim.cur[i]
        if seg.x == nx and seg.y == ny then
            sim.state = 'lost'
            return
        end
    end

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

    if prey ~= nil then
        eat(sim, prey)
    end
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
    if sim.state ~= 'playing' then
        return
    end
    for _, g in sim.guests do
        if g.state == 'alert' and not g.gone then
            g.alertLeft -= dt
            if g.alertLeft <= 0 then
                g.state = 'flee'
            end
        end
    end
    sim.snakeAcc += dt
    while sim.snakeAcc >= TICK and sim.state == 'playing' do
        sim.snakeAcc -= TICK
        Sim.stepSnake(sim)
    end
    sim.guestAcc += dt
    while sim.guestAcc >= GUEST_TICK and sim.state == 'playing' do
        sim.guestAcc -= GUEST_TICK
        Sim.stepGuests(sim)
    end
end

return Sim
