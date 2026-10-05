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
    LUNGE_VISION_COST = 0.10, -- taken off `vision` (0-1) per lunge
}
