// Vision and dread. Takes the floor plan, walls, exits and guests rendered to
// an offscreen canvas and darkens everything outside a forward cone from the
// snake's head. The snake and HUD are drawn over the result in the normal
// renderer. main.luau fills the uniforms each frame; fog.luau holds the same
// cone shape for the CPU-side "can the player see this guest" test, so keep
// the two in step.
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
    _pad: f32,             // 76
};

@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var sceneTex: texture_2d<f32>;
@group(0) @binding(2) var sceneSamp: sampler;

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

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let scene = textureSample(sceneTex, sceneSamp, in.uv);
    var col = scene.rgb;

    let px = in.uv * u.resolution;
    let t = (px - u.mapOrigin) / u.pxPerTile;
    let time = u.time;
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
    let cone = coneLength * coneWidth;

    // A faint disc of about a tile always stays lit around the head.
    let near = (1.0 - smoothstep(0.5, 1.5, dist0)) * 0.35;

    // Candle flicker on everything the head lights.
    let flicker = 1.0 + 0.05 * sin(time * 11.0) + 0.08 * (vnoise(vec2<f32>(time * 7.0, 3.1)) - 0.5);
    var light = max(cone, near) * flicker;

    // Eating: the darkness lifts across the whole map and falls back.
    light = max(light, smoothstep(0.0, 1.0, u.reveal) * 0.9);

    // Wall impact: a soft glow at the struck tile that fades over one second,
    // lighting the walls around it.
    let ig = clamp(1.0 - u.impactAge, 0.0, 1.0);
    let glow = ig * ig * (1.0 - smoothstep(0.3, 2.0, distance(t, u.impactPos)));
    light = max(light, glow * 0.95);
    col = mix(col, col * vec3<f32>(1.35, 0.95, 0.6), glow * 0.7);

    // Soft band along the cone's edge, where the fog and red tint sit.
    let edge = clamp(4.0 * cone * (1.0 - cone), 0.0, 1.0);

    // Red creeps into that band as health drops.
    let redAmt = edge * hurt;
    col = mix(col, col * vec3<f32>(1.5, 0.5, 0.45), redAmt * 0.8);

    let ambient = 0.025;
    col = col * (ambient + (1.0 - ambient) * clamp(light, 0.0, 1.0));

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
