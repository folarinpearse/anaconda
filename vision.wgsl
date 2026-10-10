// Vision and dread. Takes the floor plan, walls, exits and guests rendered to
// an offscreen canvas and darkens everything outside a forward cone from the
// snake's head. The snake and HUD are drawn over the result in the normal
// renderer. main.luau fills the uniforms each frame; fog.luau holds the same
// cone shape for the CPU-side "can the player see this guest" test, so keep
// the two in step.
//
// Two more things come from the lights. Every room's lights can dip or die
// (flicker.luau): the scene is multiplied by what is left of its light at each
// point, before any of the darkening below, so floor, walls and guests go dark
// together. And the room the head is in is partly visible: lit rooms are seen
// almost whole, dead ones only as moonlight.
//
// Positions are in tile units: cell (x, y) has its centre at (x + 0.5, y + 0.5).

struct Uniforms {
    headPos: vec2<f32>,    //  0  head centre, tiles
    headDir: vec2<f32>,    //  8  unit vector the snake is facing
    impactPos: vec2<f32>,  // 16  centre of the last damaging hit's tile
    resolution: vec2<f32>, // 24  canvas size, px
    mapOrigin: vec2<f32>,  // 32  px position of tile (0, 0)
    pxPerTile: f32,        // 40
    vision: f32,           // 44  0-1, drives cone length and width
    reveal: f32,           // 48  1 to 0 after eating: lifts the darkness
    time: f32,             // 52  seconds
    heartbeat: f32,        // 56  0-1 pulse envelope
    health: f32,           // 60  0-1
    impactAge: f32,        // 64  seconds since that hit
    coneLen: f32,          // 68  tiles, from vision
    coneHalf: f32,         // 72  radians, from vision
    ambient: f32,          // 76  light outside the cone, 0-1
    gridSize: vec2<f32>,   // 80  level size, tiles (and wall mask size, px)
    _pad0: f32,            // 88
    _pad1: f32,            // 92
    intensities0: vec4<f32>, //  96 light groups 1-4 (dj_room, lounge, bar, kitchen): 0 off, 1 on
    intensities1: vec4<f32>, // 112 groups 5-8 (main_hall, games, bathroom, foyer)
    intensities2: vec4<f32>, // 128 groups 9, 10 (red_room, corridors), 0, 0
    roomRect: vec4<f32>,   // 144 the room the head is in: x0, y0, x1, y1 in tiles, 0.5 tile wider all round
    roomSight: vec4<f32>,  // 160 sight 0-1, strike flash 0-1, that room's intensity, 0
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var sceneTex: texture_2d<f32>;
@group(0) @binding(2) var sceneSamp: sampler;
@group(0) @binding(3) var maskTex: texture_2d<f32>; // one texel per tile, 1 = wall
@group(0) @binding(4) var flickerTex: texture_2d<f32>; // flicker_mask.png: four 192 x 192 panels side by side

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOutput {
    // One oversized triangle covering the whole target.
    var corners = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(3.0, -1.0),
        vec2<f32>(-1.0, 3.0)
    );
    let c = corners[idx];
    var out: VertexOutput;
    out.position = vec4<f32>(c, 0.0, 1.0);
    out.uv = vec2<f32>(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    return out;
}

fn hash21(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(123.34, 456.21));
    q = q + dot(q, q + 45.32);
    return fract(q.x * q.y);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let w = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    var sum = 0.0;
    var amp = 0.5;
    var q = p;
    for (var k = 0; k < 4; k = k + 1) {
        sum = sum + amp * vnoise(q);
        q = q * 2.03 + vec2<f32>(17.1, 9.7);
        amp = amp * 0.5;
    }
    return sum;
}

// Wall occlusion. RAY_STEP, MAX_STEPS and WALL_DEPTH equal OCCLUSION_STEP,
// OCCLUSION_MAX_STEPS and OCCLUSION_DEPTH in config.luau; fog.luau's
// lineOfSight is the CPU twin of `visibility` below, with hard tile edges
// where this one is feathered. Keep them in step.
const RAY_STEP: f32 = 0.25;
const MAX_STEPS: i32 = 48;
const WALL_DEPTH: f32 = 0.4;

// How solid the level is at a point in tile units. The mask is sampled with
// linear filtering, so it is soft across tile edges; the smoothstep keeps
// that softness to the edge and makes tile centres fully solid.
fn wallness(p: vec2<f32>) -> f32 {
    let m = textureSampleLevel(maskTex, sceneSamp, p / u.gridSize, 0.0).r;
    return smoothstep(0.55, 0.95, m);
}

// 1 where `p` can see `src`, falling to 0 where walls are in the way. March
// from `p` toward `src` and add up how far the ray runs inside walls. A ray
// that has only just left a wall face (the point sits at most about WALL_DEPTH
// inside the first wall it meets) stays lit, so the faces the head looks at
// are visible; a ray that has to cross a wall's body is shadowed, so nothing
// behind it is. Corner clips are short, which keeps the shadow edge soft. The
// tile `src` is in never counts (the impact glow's source is a wall tile).
fn visibility(src: vec2<f32>, p: vec2<f32>) -> f32 {
    let toSrc = src - p;
    let len = length(toSrc);
    if (len < 0.001) {
        return 1.0;
    }
    let dir = toSrc / len;
    let step = max(RAY_STEP, len / f32(MAX_STEPS));
    let srcTile = floor(src);
    var inside = 0.0;
    for (var i = 1; i <= MAX_STEPS; i = i + 1) {
        let s = (f32(i) - 0.5) * step;
        if (s >= len) {
            break;
        }
        let q = p + dir * s;
        if (all(floor(q) == srcTile)) {
            continue;
        }
        inside = inside + wallness(q) * step;
    }
    return 1.0 - smoothstep(WALL_DEPTH * 0.5, WALL_DEPTH * 1.5, inside);
}

// How much of the light at tile position p is left with the lights as they are.
// Each channel of each panel is the share of the light there that one group
// provides (0 unaffected, 1 all of it); panel p, channel c is group 3p + c + 1.
// A group at intensity I takes share * (1 - I) of it away. lighting.luau's
// flickerMult is the CPU twin, on a coarser copy of the same data.
const MASK_PX: f32 = 192.0;

fn flickerMult(p: vec2<f32>) -> f32 {
    // Stay half a texel inside the panel so the filter never reaches the next one.
    let inset = 0.5 / MASK_PX;
    let uv = clamp(p / u.gridSize, vec2<f32>(inset), vec2<f32>(1.0 - inset));
    let s0 = textureSampleLevel(flickerTex, sceneSamp, vec2<f32>((0.0 + uv.x) / 4.0, uv.y), 0.0).rgb;
    let s1 = textureSampleLevel(flickerTex, sceneSamp, vec2<f32>((1.0 + uv.x) / 4.0, uv.y), 0.0).rgb;
    let s2 = textureSampleLevel(flickerTex, sceneSamp, vec2<f32>((2.0 + uv.x) / 4.0, uv.y), 0.0).rgb;
    let s3 = textureSampleLevel(flickerTex, sceneSamp, vec2<f32>((3.0 + uv.x) / 4.0, uv.y), 0.0).r; // panel 3: group 10 only
    let i0 = u.intensities0;
    let i1 = u.intensities1;
    let i2 = u.intensities2;
    var m = 1.0;
    m = m * (1.0 - s0.r * (1.0 - i0.x)) * (1.0 - s0.g * (1.0 - i0.y)) * (1.0 - s0.b * (1.0 - i0.z));
    m = m * (1.0 - s1.r * (1.0 - i0.w)) * (1.0 - s1.g * (1.0 - i1.x)) * (1.0 - s1.b * (1.0 - i1.y));
    m = m * (1.0 - s2.r * (1.0 - i1.z)) * (1.0 - s2.g * (1.0 - i1.w)) * (1.0 - s2.b * (1.0 - i2.x));
    m = m * (1.0 - s3 * (1.0 - i2.y));
    return m;
}

// ROOM_SIGHT_GAIN, ROOM_SIGHT_FLOOR and ROOM_FLASH_GAIN in config.luau.
const ROOM_SIGHT_GAIN: f32 = 0.8;
const ROOM_SIGHT_FLOOR: f32 = 0.25;
const ROOM_FLASH_GAIN: f32 = 0.3;
const ROOM_EDGE: f32 = 0.25; // tiles of soft edge on the room's box

// 1 inside the room the head is in, falling off over ROOM_EDGE tiles at its sides.
fn inRoom(p: vec2<f32>) -> f32 {
    let lo = u.roomRect.xy;
    let hi = u.roomRect.zw;
    let x = smoothstep(lo.x, lo.x + ROOM_EDGE, p.x) * (1.0 - smoothstep(hi.x - ROOM_EDGE, hi.x, p.x));
    let y = smoothstep(lo.y, lo.y + ROOM_EDGE, p.y) * (1.0 - smoothstep(hi.y - ROOM_EDGE, hi.y, p.y));
    return x * y;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let scene = textureSample(sceneTex, sceneSamp, in.uv);

    let px = in.uv * u.resolution;
    let t = (px - u.mapOrigin) / u.pxPerTile;
    let time = u.time;

    // Whatever the lights are doing, to everything the scene shows.
    var col = scene.rgb * flickerMult(t);

    // The room the head is in: a lit room is seen almost whole, a dead one is
    // moonlight. The strike flash lifts the room as its lights come back.
    let sight = u.roomSight.x;
    let flash = u.roomSight.y;
    let inside = inRoom(t);
    col = col * (1.0 + ROOM_FLASH_GAIN * flash * inside);
    let starve = 1.0 - u.vision; // 0 at full vision, 0.85 at the floor
    let hurt = 1.0 - u.health;

    // --- The cone. Animated noise wobbles its length and width, which is what
    // makes the edge read as drifting fog rather than a clean cut.
    let d = t - u.headPos;
    let dist0 = length(d);
    let n1 = fbm(t * 0.55 + vec2<f32>(time * 0.18, -time * 0.11));
    let n2 = fbm(t * 0.9 + vec2<f32>(-time * 0.07, time * 0.15) + 7.3);
    let dist = dist0 + (n1 - 0.5) * 2.2;
    let along = dot(d, u.headDir);
    let cross = abs(d.x * u.headDir.y - d.y * u.headDir.x);
    let ang = atan2(cross, along) + (n2 - 0.5) * 0.35;
    let coneLength = 1.0 - smoothstep(u.coneLen * 0.55, u.coneLen, dist);
    let coneWidth = 1.0 - smoothstep(u.coneHalf * 0.55, u.coneHalf, ang);
    var cone = coneLength * coneWidth;

    // A faint disc of about a tile always stays lit around the head.
    var near = (1.0 - smoothstep(0.5, 1.5, dist0)) * 0.35;

    // Walls block the cone and the disc. (A reveal, below, ignores them.)
    if (max(cone, near) > 0.002) {
        let seen = visibility(u.headPos, t);
        cone = cone * seen;
        near = near * seen;
    }

    // Candle flicker on everything the head lights.
    let flicker = 1.0 + 0.05 * sin(time * 11.0) + 0.08 * (vnoise(vec2<f32>(time * 7.0, 3.1)) - 0.5);
    var light = max(cone, near) * flicker;

    // Eating: the darkness lifts across the whole map and falls back.
    light = max(light, smoothstep(0.0, 1.0, u.reveal) * 0.9);

    // Only the room the head is in, and only while it has taken it in.
    light = max(light, ROOM_SIGHT_GAIN * sight * (ROOM_SIGHT_FLOOR + (1.0 - ROOM_SIGHT_FLOOR) * u.roomSight.z) * inside);

    // Wall impact: a soft glow at the struck tile that fades over one second,
    // lighting the walls around it.
    let ig = clamp(1.0 - u.impactAge, 0.0, 1.0);
    var glow = ig * ig * (1.0 - smoothstep(0.3, 2.0, distance(t, u.impactPos)));
    if (glow > 0.002) {
        glow = glow * visibility(u.impactPos, t); // the glow does not pass walls either
    }
    light = max(light, glow * 0.95);
    col = mix(col, col * vec3<f32>(1.35, 0.95, 0.6), glow * 0.7);

    // Soft band along the cone's edge, where the fog and red tint sit.
    let edge = clamp(4.0 * cone * (1.0 - cone), 0.0, 1.0);

    // Red creeps into that band as health drops.
    let redAmt = edge * hurt;
    col = mix(col, col * vec3<f32>(1.5, 0.5, 0.45), redAmt * 0.8);

    col = col * (u.ambient + (1.0 - u.ambient) * clamp(light, 0.0, 1.0));

    // Fog and blood-glow light up the dark side of the edge.
    let fog = edge * (0.3 + 0.7 * n1);
    col = col + vec3<f32>(0.5, 0.55, 0.62) * fog * 0.10;
    col = col + vec3<f32>(0.55, 0.04, 0.03) * fog * hurt * 0.30;

    // Hunger drains the colour.
    let grey = dot(col, vec3<f32>(0.299, 0.587, 0.114));
    col = mix(col, vec3<f32>(grey), starve * 0.7);

    // Heartbeat: the vignette closes in a little on every beat, and sits
    // tighter the lower the vision.
    let r = length(in.uv - vec2<f32>(0.5, 0.5)) * 1.4142;
    let inner = 0.80 - 0.30 * starve - 0.07 * u.heartbeat;
    let vig = smoothstep(inner, inner + 0.45, r);
    col = col * (1.0 - vig * (0.35 + 0.45 * starve));

    // Film grain, heavier as vision falls.
    let grain = hash21(px + fract(time) * vec2<f32>(311.0, 173.0)) - 0.5;
    col = col + grain * (0.015 + 0.08 * starve);

    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
