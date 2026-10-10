"""
ANACONDA — snake skin + head textures
=====================================

Generates the two images the game maps onto the snake, painted procedurally
(scales, saddle blotches, top-down lighting), so they can be re-made with
different colours or sizes in seconds.

    python make_snake_art.py            (needs numpy + Pillow)

Outputs (next to this script):
    snake_skin.png   1280x272. The body seen from straight above, 4 tiles long.
                     x = along the body (0 = neck end, tiling seamlessly every
                     1280 px), y = across it (top edge = snake's left).
                     Covers BODY_WIDTH + outline (34 game px) at 8 px per game px.
    snake_head.png   352x336. The head seen from above, facing +x, at 8 px per game px.
                     Covers head-local x -6..38, y -21..21 (game px), i.e. the
                     SnakeHead Rig's local space. Rig (0,0) = pixel (48, 168).
                     Eyes go at (22, +-11.5), nostrils at (35, +-3.6).

The look is a yellow-anaconda / python palette: sandy tan with dark-rimmed brown
saddles, pale halos, small overlapping scales, lit from straight above.
"""

import math
import os

import numpy as np
from PIL import Image

S = 8                      # texture px per game px
# ---------------------------------------------------------------- palette
TAN = np.array([0.74, 0.64, 0.42])       # base scales
TAN_DARK = np.array([0.55, 0.46, 0.28])  # mottling on the base
HALO = np.array([0.88, 0.81, 0.60])      # pale ring round each saddle
RIM = np.array([0.15, 0.09, 0.045])      # near-black saddle edge
BLOTCH = np.array([0.38, 0.25, 0.13])    # saddle interior
BLOTCH_LIGHT = np.array([0.52, 0.37, 0.20])
INK = np.array([0.08, 0.055, 0.03])      # outline, matches the floor's ink weight
GROOVE = 0.55                            # brightness of the gaps between scales

# ---------------------------------------------------------------- body geometry
TILE = 40.0
LENGTH_TILES = 4
L = TILE * LENGTH_TILES    # 160 game px of skin before it repeats
R = 15.0                   # visible body half-width (BODY_WIDTH / 2)
OUTLINE = 2.0              # ink band outside R (OUTLINE_GROW / 2)
HALF = R + OUTLINE         # 17 game px

SCALE_A = 2.0              # scale pitch along the body (must divide L)
SCALE_B = 1.8              # scale pitch across (in surface units)


def periodic_noise(x, y, period, seed, octaves=3):
    """Smooth noise that repeats every `period` in x. y is not periodic."""
    rng = np.random.default_rng(seed)
    out = np.zeros_like(x)
    amp = 1.0
    norm = 0.0
    for o in range(octaves):
        for _ in range(4):
            kx = rng.integers(1, 4) * (2 ** o)
            ky = rng.uniform(0.15, 0.4) * (2 ** o)
            ph1, ph2 = rng.uniform(0, 2 * math.pi, 2)
            out += amp * np.sin(2 * math.pi * kx * x / period + ph1) * np.sin(ky * y + ph2)
            norm += amp
        amp *= 0.5
    return out / norm * 2.0


def scale_cells(x, s, a, b, period_cells=None):
    """Staggered scale lattice. Returns (centre x, centre s, f1, f2, cell id)."""
    j0 = np.round(s / b)
    best = None
    cands = []
    for dj in (-1, 0, 1):
        j = j0 + dj
        off = np.where(np.mod(j, 2) == 1, a / 2, 0.0)
        i0 = np.round((x - off) / a)
        for di in (-1, 0, 1):
            i = i0 + di
            cx = i * a + off
            cs = j * b
            # scales are a little longer than wide; metric favours that shape
            d = (np.abs((x - cx) / (a * 0.62)) ** 1.5 + np.abs((s - cs) / (b * 0.62)) ** 1.5) ** (1 / 1.5)
            cands.append((d, cx, cs, i, j))
    ds = np.stack([c[0] for c in cands])
    order = np.argsort(ds, axis=0)
    f1 = np.take_along_axis(ds, order[:1], 0)[0]
    f2 = np.take_along_axis(ds, order[1:2], 0)[0]
    pick = order[0]
    cx = np.choose(pick, [c[1] for c in cands])
    cs = np.choose(pick, [c[2] for c in cands])
    ci = np.choose(pick, [c[3] for c in cands])
    cj = np.choose(pick, [c[4] for c in cands])
    if period_cells:
        ci = np.mod(ci, period_cells)
    cell_id = (ci * 7919 + cj * 104729).astype(np.int64)
    return cx, cs, f1, f2, cell_id


def hash01(n, seed=0):
    n = (n.astype(np.uint64) * np.uint64(2654435761) + np.uint64(seed * 97 + 13)) & np.uint64(0xFFFFFFFF)
    n ^= n >> np.uint64(15)
    n = (n * np.uint64(2246822519)) & np.uint64(0xFFFFFFFF)
    n ^= n >> np.uint64(13)
    return (n & np.uint64(0xFFFF)).astype(np.float64) / 65535.0


def superellipse(dx, ds, ax, a_s, p=2.6):
    return (np.abs(dx / ax) ** p + np.abs(ds / a_s) ** p) ** (1.0 / p)


def ringed(e, interior_mottle, halo_w=0.30, rim_w=0.27):
    """Colour for a saddle given its normalised distance e (1 = outer edge of rim)."""
    inside = np.clip((1.0 - rim_w - e) / 0.06, 0, 1)
    rim = np.clip((1.0 - e) / 0.05, 0, 1) * (1 - inside)
    halo = np.clip((1.0 + halo_w - e) / 0.08, 0, 1) * np.clip((e - 1.0) / 0.03 + 1, 0, 1) * (1 - rim - inside)
    halo = np.clip(halo, 0, 1)
    centre = np.clip(1.0 - e / (1.0 - rim_w), 0, 1) ** 0.7
    m = np.clip(0.55 * centre + 0.45 * interior_mottle, 0, 1)
    interior = BLOTCH[None, None, :] * (1 - m[..., None]) + BLOTCH_LIGHT[None, None, :] * m[..., None]
    return inside, rim, halo, interior


def paint_body():
    W, H = int(L * S), int(2 * HALF * S)
    px = (np.arange(W) + 0.5) / S
    py = (np.arange(H) + 0.5) / S - HALF
    x, v = np.meshgrid(px, py)

    vv = np.clip(v / R, -1, 1)
    theta = np.arcsin(vv)
    s = theta * R                       # distance over the surface from the spine
    nz = np.cos(theta)

    cx, cs, f1, f2, cid = scale_cells(x, s, SCALE_A, SCALE_B, period_cells=int(L / SCALE_A))
    jitter = hash01(cid, 1) - 0.5

    # ---- pattern, sampled at each scale's centre so blotch edges follow scales
    def pattern(px_, ps_):
        mot = (periodic_noise(px_, ps_, L, 3) * 0.5 + 0.5)
        col = TAN[None, None, :] * (1 - 0.45 * mot[..., None]) + TAN_DARK[None, None, :] * (0.45 * mot[..., None])
        variants = [(1.00, 1.00, 0.0), (1.08, 0.92, 1.2), (0.94, 1.08, -1.0), (1.04, 0.98, 0.6)]
        for k in range(LENGTH_TILES):
            sx, ss, so = variants[k]
            # dorsal saddle, wrapped so the texture tiles
            dx = np.mod(px_ - (k * TILE + TILE / 2) + L / 2, L) - L / 2
            wx = periodic_noise(px_, ps_, L, 31 + k, 2) * 2.2
            ws = periodic_noise(px_, ps_, L, 41 + k, 2) * 2.2
            e = superellipse(dx + wx, ps_ - so + ws, 11.5 * sx, 11.0 * ss, 2.1)
            imot = periodic_noise(px_, ps_, L, 11 + k, 2) * 0.5 + 0.5
            inside, rim, halo, interior = ringed(e, np.clip(imot * 0.8, 0, 1))
            col = col * (1 - halo[..., None]) + HALO[None, None, :] * halo[..., None]
            col = col * (1 - rim[..., None]) + RIM[None, None, :] * rim[..., None]
            col = col * (1 - inside[..., None]) + interior * inside[..., None]
            # lateral blotches, between the saddles, half over the side
            for side in (-1, 1):
                dx2 = np.mod(px_ - (k * TILE) + L / 2, L) - L / 2
                e2 = superellipse(dx2 + wx * 0.6, ps_ - side * 19.5 + ws * 0.5, 7.0 * sx, 5.0, 2.0)
                inside2, rim2, halo2, interior2 = ringed(e2, np.clip(imot * 0.6, 0, 1), 0.28, 0.3)
                col = col * (1 - halo2[..., None]) + HALO[None, None, :] * halo2[..., None]
                col = col * (1 - rim2[..., None]) + RIM[None, None, :] * rim2[..., None]
                col = col * (1 - inside2[..., None]) + interior2 * inside2[..., None]
        return col

    col_c = pattern(cx, cs)
    col_p = pattern(x, s)
    col = col_c * 0.8 + col_p * 0.2

    # odd dark scales scattered on the tan
    speck = (hash01(cid, 7) > 0.94).astype(float)
    col = col * (1 - 0.35 * speck[..., None])
    col = col * (1 + 0.10 * jitter[..., None])

    # ---- scale relief: grooves between scales, each scale lit a touch at its free edge
    edge = np.clip((f2 - f1) / 0.22, 0, 1)
    groove = GROOVE + (1 - GROOVE) * edge
    along = np.clip((x - cx) / (SCALE_A * 0.6), -1, 1)   # +1 toward the tail
    relief = groove * (1.0 + 0.08 * along)

    # ---- lighting from straight above
    diffuse = 0.30 + 0.70 * nz ** 0.9
    sheen = 0.22 * np.exp(-(theta / 0.38) ** 2) * (1 - f1.clip(0, 1)) * edge
    rgb = col * (diffuse * relief)[..., None] + sheen[..., None]

    # ---- outline band and soft outer edge
    av = np.abs(v)
    ink = np.clip((av - R + 0.6) / 0.8, 0, 1)
    rgb = rgb * (1 - ink[..., None]) + INK[None, None, :] * ink[..., None]
    alpha = np.clip((HALF - av) / 0.6, 0, 1)

    return np.dstack([np.clip(rgb, 0, 1), alpha])


# ---------------------------------------------------------------- head
NECK_HALF = 11.0          # half-width of the neck where the head meets it (body is 17); the game tapers the body to match
HX0, HX1 = -6.0, 38.0
HY = 21.0


def head_halfwidth(x):
    """Half-width of the head silhouette at head-local x (game px)."""
    n = NECK_HALF
    xs = np.array([-6, -2, 2, 6, 10, 15, 20, 25, 29, 32.5, 35.5, 37.3, 38.0])
    ws = np.array([n, n + (18.6 - n) * 0.3, n + (20.0 - n) * 0.78, 20.0, 20.2, 19.2, 17.0, 14.2, 11.4, 8.6, 5.6, 2.8, 0.0])
    return np.interp(x, xs, ws)


def paint_head():
    W, H = int((HX1 - HX0) * S), int(2 * HY * S)
    px = (np.arange(W) + 0.5) / S + HX0
    py = (np.arange(H) + 0.5) / S - HY
    x, y = np.meshgrid(px, py)

    w = head_halfwidth(x)
    wn = np.where(w > 0.01, y / np.maximum(w, 0.01), 9.0)
    an = np.abs(wn)
    # flat-topped dome
    nz = np.sqrt(np.clip(1 - np.clip(an, 0, 1) ** 2.6, 0, 1))
    # nose rounds over toward the tip
    nz = nz * np.clip(1 - np.clip((x - 29) / 10, 0, 1) ** 2 * 0.35, 0, 1)

    s = np.arcsin(np.clip(wn, -1, 1)) * w
    cx, cs, f1, f2, cid = scale_cells(x, s, 1.7, 1.6)
    jitter = hash01(cid, 5) - 0.5

    mot = periodic_noise(cx, cs, 400.0, 21) * 0.5 + 0.5
    col = TAN[None, None, :] * (1 - 0.4 * mot[..., None]) + TAN_DARK[None, None, :] * (0.4 * mot[..., None])

    # dark crown: covers most of the top, rounded toward the snout
    crown_e = superellipse((cx - 12) / 17.0, cs / (head_halfwidth(cx) * 0.98 + 1e-3), 1.0, 1.0, 3.0)
    crown = np.clip((1.0 - crown_e) / 0.05, 0, 1)
    cmot = periodic_noise(cx * 1.7, cs * 1.7, 400.0, 23) * 0.5 + 0.5
    cspk = (hash01(cid, 9) > 0.8).astype(float)
    crown_col = (BLOTCH[None, None, :] * (0.75 + 0.35 * cmot[..., None])) * (1 - 0.4 * cspk[..., None])
    col = col * (1 - crown[..., None]) + crown_col * crown[..., None]
    # darker spear mark down the middle of the crown, pointing forward
    spear_w = np.clip((27 - cx) / 22.0, 0, 1) * 6.0
    spear = np.clip((spear_w - np.abs(cs)) / 1.2, 0, 1) * (cx > 0) * (cx < 27)
    col = col * (1 - 0.55 * spear[..., None]) + RIM[None, None, :] * (0.55 * spear[..., None])

    # stripe from the eye back to the jaw angle, dark over a pale lip line
    for side in (-1, 1):
        t = np.clip((22 - cx) / 22.0, 0, 1)
        sy = side * (12.0 + 8.5 * t)
        band = np.clip((1.9 - np.abs(cs - sy)) / 0.6, 0, 1) * (cx < 23) * (cx > -2)
        col = col * (1 - band[..., None]) + RIM[None, None, :] * band[..., None]
        lip = np.clip((1.5 - np.abs(cs - (sy + side * 2.8))) / 0.5, 0, 1) * (cx < 34) * (cx > -2)
        col = col * (1 - lip[..., None]) + HALO[None, None, :] * lip[..., None]

    # paler, mottled snout edge (labial scales)
    lab = np.clip((an - 0.78) / 0.12, 0, 1) * np.clip((x - 21) / 6, 0, 1)
    col = col * (1 - 0.6 * lab[..., None]) + HALO[None, None, :] * (0.6 * lab[..., None])

    col = col * (1 + 0.12 * jitter[..., None])
    edge = np.clip((f2 - f1) / 0.22, 0, 1)
    relief = GROOVE + (1 - GROOVE) * edge

    # eye sockets (the vector eyes sit in these) and nostrils
    for side in (-1, 1):
        de = np.sqrt(((x - 22) / 3.6) ** 2 + ((y - side * 11.5) / 3.2) ** 2)
        sock = np.clip((1.05 - de) / 0.1, 0, 1)
        col = col * (1 - 0.7 * sock[..., None]) + RIM[None, None, :] * (0.7 * sock[..., None])
        brow = np.clip(1 - np.abs(de - 1.25) / 0.18, 0, 1) * (np.abs(y) < 12)
        relief = relief * (1 + 0.25 * brow)
        dn = np.sqrt(((x - 35.0) / 1.0) ** 2 + ((y - side * 3.6) / 0.6) ** 2)
        nos = np.clip((1.0 - dn) / 0.3, 0, 1)
        col = col * (1 - nos[..., None]) + INK[None, None, :] * nos[..., None]

    diffuse = 0.32 + 0.68 * nz ** 0.9
    sheen = 0.20 * np.exp(-(wn / 0.35) ** 2) * edge * np.clip((x + 2) / 6, 0, 1)
    rgb = col * (diffuse * relief)[..., None] + sheen[..., None]

    # outline round the silhouette (not across the back, which sits on the body)
    dist_out = (an - 1.0) * w                 # game px outside the edge (+) / inside (-)
    tip = x - (HX1 - 0.0)
    ink = np.clip((dist_out + 1.2) / 0.5, 0, 1)
    rgb = rgb * (1 - ink[..., None]) + INK[None, None, :] * ink[..., None]
    alpha = np.clip((0.2 - dist_out) / 0.5, 0, 1) * (w > 0.01)
    # fade into the body at the back
    alpha = alpha * np.clip((x - HX0) / 5.0, 0, 1)
    _ = tip
    return np.dstack([np.clip(rgb, 0, 1), alpha])


def save(arr, path):
    Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGBA").save(path)
    print("wrote", path)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    save(paint_body(), os.path.join(here, "snake_skin.png"))
    save(paint_head(), os.path.join(here, "snake_head.png"))
