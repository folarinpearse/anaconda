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

    -- Cone shape in tiles / radians, from the floor's end to full vision.
    -- (Interpolated on `vision` itself, so the floor value sits a little above
    -- the minimum.)
    CONE_LENGTH_MIN = 2.8,
    CONE_LENGTH_MAX = 11,
    CONE_ANGLE_MIN = 0.28,
    CONE_ANGLE_MAX = 0.80,
    NEAR_LIGHT = 0.35, -- brightness of the ever-present disc around the head
    VISIBLE_LIGHT = 0.2, -- light above this counts as "in view" for sound rings

    -- Dread
    HEARTBEAT_SLOW = 1.0, -- beats per second at full vision
    HEARTBEAT_FAST = 2.6, -- beats per second at the vision floor

    -- Sound rings from unseen alerted or fleeing guests
    RING_INTERVAL = 1.0, -- seconds between rings from one guest
    RING_LIFETIME = 1.4, -- seconds a ring lasts
    RING_MAX_RADIUS = 2.4, -- tiles
}
