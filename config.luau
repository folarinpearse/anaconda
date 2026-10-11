-- Gameplay tunables. sim.luau and main.luau read every number from here.
-- If MAX_HP changes, also change the HP bar's converter in scene.rml
-- (DataConverterRangeMapper "HP To Width", maxInput).
return {
    -- Pace
    TICK_RATE = 5, -- snake moves per second
    GUEST_SPEED = 0.75, -- guest speed as a fraction of snake speed

    -- Health
    MAX_HP = 5,
    INVULN_TIME = 0.6, -- seconds after a hit during which bumps cost nothing
    HEAL_PER_GUEST = 1, -- HP restored by eating a guest
    HIT_FX_TIME = 0.3, -- seconds the head flashes and shakes after a hit

    -- Lunge (boost)
    LUNGE_STEPS = 3, -- moves made at the boosted rate
    LUNGE_MULTIPLIER = 3, -- tick rate multiplier while lunging
    LUNGE_COOLDOWN = 3, -- seconds from one lunge to the next
    LUNGE_VISION_COST = 0.10, -- taken off `vision` per lunge (never below the floor)

    -- Vision. `vision` runs from 1 down to VISION_FLOOR without eating; eating
    -- sets it back to 1 and fires a reveal.
    VISION_DECAY_TIME = 25, -- seconds to fall from 1 to the floor
    VISION_FLOOR = 0.15,
    REVEAL_TIME = 1.5, -- seconds for the reveal to fade from 1 to 0

    -- Endings
    WIN_HOLD_TIME = 1.0, -- seconds the reveal is held full after the last guest is eaten, before "won"
    OVERLAY_FADE_IN = 0.35, -- seconds for a screen overlay to fade in
    OVERLAY_FADE_OUT = 0.2, -- ...and out
    RESTART_LOCKOUT = 0.5, -- seconds after the game ends before a click or Space can restart it

    -- Cone shape in tiles / radians, from the floor's end to full vision.
    -- (Interpolated on `vision` itself, so the floor value sits a little above
    -- the minimum.)
    CONE_LENGTH_MIN = 2.8,
    CONE_LENGTH_MAX = 11,
    CONE_ANGLE_MIN = 0.28,
    CONE_ANGLE_MAX = 0.80,
    NEAR_LIGHT = 0.35, -- brightness of the ever-present disc around the head
    AMBIENT = 0.004, -- light level outside the cone, 0 (black) to 1 (unlit scene)

    -- Wall occlusion: rays from a point toward the head, this far apart, at
    -- most this many, and how many tiles of wall a ray may cross and still count
    -- as seeing a wall face. vision.wgsl repeats all three (RAY_STEP, MAX_STEPS,
    -- WALL_DEPTH) and fog.luau reads these: keep them in step.
    OCCLUSION_STEP = 0.25, -- tiles
    OCCLUSION_MAX_STEPS = 48,
    OCCLUSION_DEPTH = 0.4, -- tiles
    VISIBLE_LIGHT = 0.2, -- light above this counts as "in view" for sound rings

    -- Dread
    HEARTBEAT_SLOW = 1.0, -- beats per second at full vision
    HEARTBEAT_FAST = 2.6, -- beats per second at the vision floor

    -- Sound rings from unseen alerted or fleeing guests
    RING_INTERVAL = 1.0, -- seconds between rings from one guest
    RING_LIFETIME = 1.4, -- seconds a ring lasts
    RING_MAX_RADIUS = 2.4, -- tiles

    -- Lights. Every room's lights fail in their own way (flicker.luau). A range
    -- is { min, max } seconds unless it says otherwise; a gap is the time between
    -- one event and the next.
    FLICKER_ENABLED = true, -- false: every group stays at 1.0
    LIGHTS_QUIET_TIME = 3, -- no events in the first seconds of a run
    -- Safe flashing: no more than 3 deep flashes a second. A group's level may
    -- only start a drop below SAFE_FLASH_FLOOR if its last such drop began at
    -- least SAFE_FLASH_INTERVAL ago, and sits at the floor until then; faster
    -- flicker keeps its rhythm above it. The strike flash is limited too.
    SAFE_FLASHING = true,
    SAFE_FLASH_FLOOR = 0.6,
    SAFE_FLASH_INTERVAL = 0.333, -- seconds
    SAFE_STRIKE_INTERVAL = 0.5, -- seconds between strike flashes
    ENTRY_DELAY = { 0.15, 0.5 }, -- a room fires its event this long after the head enters

    -- dj_room "party": base pulses to the beat, events are strobe bursts
    PARTY_BPM = 120,
    PARTY_BASE_LOW = 0.6, -- base = low + (1 - low) * exp(-decay * beat phase)
    PARTY_BASE_DECAY = 6,
    PARTY_GAP = { 3, 7 },
    PARTY_STROBE_SEGMENTS = { 10, 16 }, -- a count, not seconds
    PARTY_STROBE_SEGMENT = 0.045,
    PARTY_STROBE_LOW = 0.05,

    -- lounge "dimmer": slow swell, events are a fade down and back
    LOUNGE_BASE_MID = 0.82,
    LOUNGE_BASE_SWING = 0.18,
    LOUNGE_BASE_PERIOD = 4,
    LOUNGE_GAP = { 6, 12 },
    LOUNGE_FADE_TO = 0.2,
    LOUNGE_FADE_TIME = 0.6, -- down, and again back up
    LOUNGE_HOLD = 0.3,

    -- bar "neon": base jitters, events are a cut-out
    NEON_JITTER = 0.12, -- base = 1 - jitter * random
    NEON_JITTER_INTERVAL = { 0.02, 0.06 },
    NEON_GAP = { 2, 6 },
    NEON_OFF_LEVEL = 0.05,
    NEON_CUT_FIRST = 0.08,
    NEON_CUT_ON = 0.04,
    NEON_CUT_SECOND = { 0.1, 0.3 },

    -- kitchen, corridors and bathroom, the tubes: a faint hum, events are a
    -- stutter or a blackout (a stutter, off, a stutter)
    TUBE_HUM = 0.015, -- +- share of the base level
    TUBE_STUTTER_SEGMENTS = { 4, 8 }, -- a count, not seconds
    TUBE_STUTTER_SEGMENT = { 0.03, 0.09 },
    TUBE_STUTTER_LOW = { 0.03, 0.2 }, -- levels, not seconds
    TUBE_STUTTER_HIGH = { 0.8, 1 },
    TUBE_OFF_LEVEL = 0.03,
    KITCHEN_GAP = { 5, 12 },
    KITCHEN_BLACKOUT_SHARE = 0.4, -- of events
    KITCHEN_BLACKOUT_TIME = { 1.5, 3 },
    CORRIDORS_GAP = { 8, 20 },
    CORRIDORS_BLACKOUT_SHARE = 0.4,
    CORRIDORS_BLACKOUT_TIME = { 1, 1.5 }, -- never longer than 1.5
    BATHROOM_GAP = { 2, 6 }, -- the dying tube
    BATHROOM_BLACKOUT_SHARE = 0.5,
    BATHROOM_BLACKOUT_TIME = { 1.5, 3.5 },

    -- main_hall "brownout": events are a sag
    HALL_GAP = { 8, 16 },
    HALL_SAG_TO = 0.45,
    HALL_SAG_TIME = 0.25,
    HALL_HOLD = 0.2,
    HALL_RECOVER = 0.4,

    -- games "glitch": tiny jitter, events are a double blink
    GLITCH_JITTER = 0.02,
    GLITCH_JITTER_INTERVAL = { 0.04, 0.1 },
    GLITCH_GAP = { 3, 8 },
    GLITCH_LOW_LEVEL = 0.1,
    GLITCH_LOW_TIME = 0.05, -- twice
    GLITCH_ON_TIME = 0.06,

    -- foyer "sag": events are a slow sag
    FOYER_GAP = { 8, 16 },
    FOYER_SAG_TO = 0.5,
    FOYER_SAG_TIME = 0.8,
    FOYER_HOLD = 1.0,
    FOYER_RECOVER = 0.6,

    -- red_room "heartbeat": base follows the dread heartbeat, events are a drop
    RED_BASE_LOW = 0.55, -- base = low + (1 - low) * Fog.heartbeat(beat phase)
    RED_GAP = { 9, 15 },
    RED_DROP_TO = 0.3,
    RED_DROP_TIME = 0.15,

    -- Chase tension 0-1: how hard the lights are failing because guests are
    -- running or the snake is lunging.
    CHASE_RANGE = 7, -- tiles from the head to a fleeing or alerted guest
    CHASE_FLEE = 1.0, -- target while a guest in range flees
    CHASE_LUNGE = 0.8, -- target while lunging
    CHASE_ALERT = 0.6, -- target while a guest in range is alerted
    CHASE_RISE = 0.3, -- seconds, time constant
    CHASE_FALL = 2.0,
    CHASE_GAP_SPEEDUP = 4, -- gaps are divided by 1 + this * tension
    CHASE_JITTER_RANGE = 8, -- tiles from the head to a room that gets erratic
    CHASE_JITTER_INTERVAL = { 0.03, 0.08 },
    CHASE_JITTER_DEPTH = 0.35, -- intensity *= 1 - depth * tension * random
    CHASE_BLACKOUT_MAX = 1.5, -- a blackout in the snake's own room is cut to this
    CHASE_ACTIVE = 0.1, -- tension above this counts as a chase

    -- Seeing the room you are in. vision.wgsl repeats ROOM_SIGHT_GAIN, ROOM_SIGHT_FLOOR
    -- and ROOM_FLASH_GAIN: keep them in step.
    ROOM_SIGHT_RISE = 0.4, -- seconds to ease in after entering
    ROOM_SIGHT_FALL = 0.6, -- ...and out after leaving
    ROOM_SIGHT_GAIN = 0.8, -- light = gain * sight * (floor + (1 - floor) * intensity)
    ROOM_SIGHT_FLOOR = 0.25,
    ROOM_FLASH_GAIN = 0.3,
    ROOM_FLASH_TIME = 0.15, -- seconds for the strike flash to decay

    -- The snake
    HEAD_LIGHT_TIME = 0.12, -- seconds, time constant of the head's light

    -- Guests (guestfx.luau): how the Person artboard is brought to life. Visuals
    -- only; none of this touches the sim.
    GUEST_FX_ENABLED = true, -- false: guests are drawn as before (no turning, shadows, drops or items)
    GUEST_SCALE = 0.9, -- the Size node's scale in person.rml: keep in step

    -- Heading. Travel direction comes from a smoothed velocity; a guest counts
    -- as moving above GUEST_MOVE_SPEED, so frame jitter never turns it.
    GUEST_VELOCITY_TIME = 0.1, -- seconds, time constant of the smoothed velocity
    GUEST_MOVE_SPEED = 8, -- px/s
    GUEST_TURN_RATE = 10, -- rad/s, walking and standing
    GUEST_FLEE_TURN_RATE = 18, -- rad/s, fleeing
    GUEST_BIG_TURN = 1.2, -- rad: past this angle to the target...
    GUEST_BIG_TURN_BOOST = 3, -- ...the turn rate is multiplied by this
    GUEST_CHAT_RANGE = 3, -- tiles: a standing guest faces the nearest standing guest this close
    GUEST_DANCE_COLS = { 10, 13 }, -- the dance floor, first and last tile
    GUEST_DANCE_ROWS = { 11, 14 },
    GUEST_HEADING_CHECK_TIME = 5, -- seconds of a run in which the heading error is logged...
    GUEST_HEADING_CHECK_AFTER = 0.15, -- ...for guests moving at least this long...
    GUEST_HEADING_TOLERANCE = 0.5, -- ...and the most it may be off, rad

    -- Head turn (lookAngle, relative to the heading)
    GUEST_LOOK_LIMIT = 1.2, -- rad
    GUEST_LOOK_TIME = 0.1, -- seconds, time constant
    GUEST_CHAT_GLANCE = 0.5, -- rad: idle and chatting guests glance up to this far...
    GUEST_CHAT_GLANCE_GAP = { 2, 4 }, -- ...this many seconds apart
    GUEST_FLEE_GLANCE_TIME = 0.25, -- seconds a fleeing guest looks back at the snake...
    GUEST_FLEE_GLANCE_GAP = { 0.8, 1.4 }, -- ...this many seconds apart

    -- Animation
    GUEST_DESYNC = 4, -- seconds: a new instance is advanced by 0 to this much
    GUEST_STEP_MIN = 0.6, -- walk and run cycles run at actual / nominal speed, clamped
    GUEST_STEP_MAX = 1.6,
    GUEST_CAUGHT_ANIM = 0.5, -- seconds the Caught animation takes (30 frames)

    -- Light and shadow
    GUEST_LIGHT_TIME = 0.12, -- seconds, time constant of a guest's light
    GUEST_SHADOW_SIZE = { 22, 26 }, -- px along x across, at Size scale 1
    GUEST_SHADOW_FADE = 0.5, -- seconds, from the catch, for the shadow to go out

    -- Flee reactions
    GUEST_ALERT_DROP_CHANCE = 0.5, -- a guest holding a drink drops it on alert with this odds
    GUEST_HAND = { 6, 10 }, -- px, in the guest's own frame at Size scale 1
    GUEST_CUP_SPEED = { 40, 70 }, -- px/s at the throw
    GUEST_CUP_TIME = 0.35, -- seconds to come to rest
    GUEST_CUP_SPIN = { 6, 10 }, -- rad/s at the throw, decaying with the speed
    GUEST_SPILL_OFFSET = 7, -- px from the resting cup, along its mouth, to the spill's centre
    GUEST_SPILL_FROM = 0.2, -- spill scale at first...
    GUEST_SPILL_GROW = 0.4, -- ...to 1 over this many seconds
    GUEST_ITEM_DELAY = 0.35, -- seconds after a catch before the costume is left behind
    GUEST_ITEM_PUSH = 6, -- px away from the snake's head
    GUEST_ITEM_FROM = 0.8, -- item scale at first...
    GUEST_ITEM_POP = 0.15, -- ...to 1 over this many seconds
    GUEST_MAX_SPILLS = 40, -- cups and spills together
    GUEST_MAX_ITEMS = 12,
    GUEST_DECAL_FADE = 0.5, -- seconds the oldest decal takes to go when over the cap
    GUEST_DEBUG_HIDE = 2, -- debug K: seconds past its stand-in that the real guest stays out of sight
}
