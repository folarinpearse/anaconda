"""
ANACONDA — guest costume textures
=================================

Paints the party guests seen from straight above, in Halloween costumes, in the
same style as the snake (make_snake_art.py): lit from straight above, soft
rounded shading, ink outlines, 8 texture px per game px.

    python make_guest_art.py            (needs numpy, scipy, Pillow)

Every part is drawn in GUEST-LOCAL space (game px): the guest faces +x,
+y is the guest's RIGHT side, origin = the guest's centre between the shoulders.
Each PNG's "pivot" below is the pixel that sits on the part's origin in Rive.

Costumes (index = the `costume` number in the Person view model):
    0 witch   1 pumpkin   2 devil   3 skeleton   4 cat   5 vampire

Outputs (into OUT_DIR, default: next to this script's parent folder):
  per costume <c>:
    guest_<c>_torso.png  x -13..10, y -15..15   184x240  pivot (104,120) = guest centre
    guest_<c>_head.png   x -12..12, y -12..12   192x192  pivot (96,96)   = guest centre
                         (the head image already sits 0.6 px forward of the centre)
    guest_<c>_arm.png    x -3..13,  y -4..4     128x64   pivot (24,32)   = the shoulder
                         points along +x; hand centre at local (10.3, 0)
    guest_<c>_item.png   x -12..12, y -12..12   192x192  pivot (96,96)   dropped costume piece
  shared:
    guest_shoe.png       x -4..4,   y -2.5..2.5  64x40   pivot (32,20)   toe toward +x
    guest_cup.png        x -3..3,   y -3..3      48x48   pivot (24,24)   party cup from above
    guest_cup_tipped.png x -4.5..4.5, y -3.5..3.5 72x56  pivot (36,28)   cup on its side, mouth toward +x
    guest_spill.png      x -9..9,   y -7..7     144x112  pivot (72,56)   spilled punch (semi-transparent)
  tools/guest_contact_sheet.png   every costume assembled, for checking (not used by the game)

Rest-pose rig (what the contact sheet shows and the Person artboard uses):
    shoulders       Arm L at (0.3, -9.8), Arm R at (0.3, 9.8)
    arms at rest    rotation 0.15 rad outward (L -0.15, R +0.15), scaleX 0.55
    shoes           (2.0, -4.0) and (2.0, 4.0), rotation 0
    cup             in the right hand: Arm R local (10.3, 0)
"""

import math
import os

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

S = 8                                     # texture px per game px
INK = np.array([0.08, 0.055, 0.04])       # matches the snake's outline

COSTUMES = ["witch", "pumpkin", "devil", "skeleton", "cat", "vampire"]


# =====================================================================
# canvas + shape helpers
# =====================================================================

class Canvas:
    def __init__(self, x0, x1, y0, y1):
        self.W, self.H = int(round((x1 - x0) * S)), int(round((y1 - y0) * S))
        px = (np.arange(self.W) + 0.5) / S + x0
        py = (np.arange(self.H) + 0.5) / S + y0
        self.x, self.y = np.meshgrid(px, py)
        self.rgb = np.zeros((self.H, self.W, 3))
        self.a = np.zeros((self.H, self.W))
        self.d = np.full((self.H, self.W), 99.0)   # union signed distance (game px)

    def noise(self, scale, seed):
        """Smooth noise 0..1 with features about `scale` game px across."""
        rng = np.random.default_rng(seed)
        n = gaussian_filter(rng.standard_normal((self.H, self.W)), scale * S * 0.5, mode="wrap")
        n = (n - n.mean()) / (n.std() + 1e-9)
        return np.clip(0.5 + 0.18 * n, 0, 1)

    def layer(self, d, color, bevel=1.5, gloss=0.0, ao=0.35, line=0.55, shade=None, alpha=1.0):
        """Paint a shape with signed distance d (game px, <0 inside).

        bevel: how far in (game px) the rounded edge reaches; big = dome.
        gloss: specular on the flattest, most upward-facing part.
        ao:    soft contact shadow cast onto what is already painted.
        line:  ink line along this shape's edge (0..1).
        shade: optional extra multiplier (H,W) for directional/fold shading.
        """
        cov = np.clip(0.5 - d * S, 0, 1) * alpha
        if ao > 0:
            out = np.clip(d, 0, None)
            occ = 1 - ao * np.exp(-out / 1.1) * (d > 0)
            self.rgb *= occ[..., None]
        t = np.clip(-d / bevel, 0, 1)
        nz = np.sqrt(np.clip(1 - (1 - t) ** 2, 0, 1))
        lum = 0.38 + 0.62 * nz ** 0.85
        if shade is not None:
            lum = lum * shade
        col = np.broadcast_to(np.asarray(color, dtype=float), self.rgb.shape) if np.ndim(color) == 1 else color
        rgb = col * lum[..., None]
        if gloss:
            rgb = rgb + gloss * (nz ** 24)[..., None]
        if line:
            ln = np.clip(1 - np.abs(d + 0.28) / 0.28, 0, 1) * line
            rgb = rgb * (1 - ln[..., None]) + INK * ln[..., None]
        self.rgb = self.rgb * (1 - cov[..., None]) + rgb * cov[..., None]
        self.a = self.a + cov * (1 - self.a)
        self.d = np.minimum(self.d, d)
        return cov

    def mark(self, mask, color, amount=1.0):
        """Paint flat detail (print, sutures, stripes) onto what is there, keeping its shading."""
        m = np.clip(mask, 0, 1) * amount * (self.a > 0.01)
        lum = self.rgb.max(axis=2, keepdims=True)
        rgb = np.asarray(color) * np.clip(lum * 1.35, 0.3, 1.0)
        self.rgb = self.rgb * (1 - m[..., None]) + rgb * m[..., None]

    def finish(self, outline=1.0):
        """Ink outline round the whole silhouette, and alpha."""
        ink = np.clip((self.d + 0.9) / 0.35, 0, 1) * (self.d < 0.3) * outline
        rgb = self.rgb * (1 - ink[..., None]) + INK * ink[..., None]
        a = np.clip(0.5 - self.d * S, 0, 1)
        a = np.maximum(a, self.a)
        out = np.clip(rgb / np.maximum(self.a, 1e-4)[..., None], 0, 1) * (self.a > 1e-4)[..., None]
        out = np.where((ink > 0)[..., None], rgb, out)
        return np.dstack([np.clip(out, 0, 1), np.clip(a, 0, 1)])


def circle(cv, cx, cy, r):
    return np.hypot(cv.x - cx, cv.y - cy) - r


def ellipse(cv, cx, cy, rx, ry, rot=0.0):
    dx, dy = cv.x - cx, cv.y - cy
    c, s = math.cos(rot), math.sin(rot)
    lx, ly = c * dx + s * dy, -s * dx + c * dy
    return (np.hypot(lx / rx, ly / ry) - 1) * min(rx, ry)


def superellipse(cv, cx, cy, rx, ry, p=2.5, rot=0.0):
    dx, dy = cv.x - cx, cv.y - cy
    c, s = math.cos(rot), math.sin(rot)
    lx, ly = c * dx + s * dy, -s * dx + c * dy
    e = (np.abs(lx / rx) ** p + np.abs(ly / ry) ** p) ** (1 / p)
    return (e - 1) * min(rx, ry)


def capsule(cv, ax, ay, bx, by, ra, rb=None):
    """Tapered capsule from a (radius ra) to b (radius rb)."""
    rb = ra if rb is None else rb
    px, py = cv.x - ax, cv.y - ay
    vx, vy = bx - ax, by - ay
    L2 = vx * vx + vy * vy
    t = np.clip((px * vx + py * vy) / L2, 0, 1)
    dist = np.hypot(px - t * vx, py - t * vy)
    return dist - (ra + (rb - ra) * t)


def bezier_tube(cv, pts, r0, r1, n=40):
    """Tube along a quadratic bezier (p0, p1, p2), radius r0 -> r1."""
    (x0, y0), (x1, y1), (x2, y2) = pts
    d = np.full(cv.x.shape, 99.0)
    prev = None
    for i in range(n + 1):
        t = i / n
        bx = (1 - t) ** 2 * x0 + 2 * (1 - t) * t * x1 + t * t * x2
        by = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * y1 + t * t * y2
        if prev is not None:
            ra = r0 + (r1 - r0) * (i - 1) / n
            rb = r0 + (r1 - r0) * i / n
            d = np.minimum(d, capsule(cv, prev[0], prev[1], bx, by, ra, rb))
        prev = (bx, by)
    return d


def polygon(cv, pts):
    pts = np.asarray(pts, dtype=float)
    d = np.full(cv.x.shape, 1e9)
    inside = np.zeros(cv.x.shape, dtype=bool)
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        vx, vy = bx - ax, by - ay
        px, py = cv.x - ax, cv.y - ay
        t = np.clip((px * vx + py * vy) / (vx * vx + vy * vy), 0, 1)
        d = np.minimum(d, np.hypot(px - t * vx, py - t * vy))
        cond = ((ay > cv.y) != (by > cv.y)) & (cv.x < ax + (cv.y - ay) * vx / (vy + 1e-12))
        inside ^= cond
    return np.where(inside, -d, d)


def union(*ds):
    return np.minimum.reduce(ds)


def cut(a, b):
    """a minus b."""
    return np.maximum(a, -b)


def line_mask(d, width):
    return np.clip(1 - np.abs(d) / width, 0, 1)


def polar(cv, cx, cy):
    return np.hypot(cv.x - cx, cv.y - cy), np.arctan2(cv.y - cy, cv.x - cx)


def mix(a, b, t):
    a, b = np.asarray(a, float), np.asarray(b, float)
    t = np.asarray(t, float)
    if t.ndim:
        t = t[..., None]
    return a * (1 - t) + b * t


def fabric(cv, base, seed, amt=0.18, scale=1.2):
    n = cv.noise(scale, seed)
    return mix(np.asarray(base) * (1 - amt), np.asarray(base) * (1 + amt * 0.6), n)


# head centre (game px), shared by every costume
HX, HR = 0.6, 5.4


def hair_strands(cv, cx, cy, seed, freq=46):
    """Strands radiating from a crown whorl: 0..1."""
    r, th = polar(cv, cx, cy)
    n = cv.noise(1.5, seed)
    return 0.5 + 0.5 * np.sin(th * freq + n * 9 + r * 0.6)


# =====================================================================
# torsos
# =====================================================================

def shoulders(cv, color, seed, rx=5.2, ry=11.5):
    d = superellipse(cv, -0.4, 0, rx, ry, 2.6)
    cv.layer(d, fabric(cv, color, seed), bevel=3.2)
    return d


def torso_witch(cv):
    # long red hair down the back, under the shawl's collar
    n = cv.noise(0.8, 11)
    hair = union(ellipse(cv, -4.5, 0, 5.6, 5.2), ellipse(cv, -8.0, 0, 3.0, 4.4))
    hair = hair + (n - 0.5) * 1.6 * np.clip((-cv.x - 6) / 3, 0, 1)
    strands = 0.5 + 0.5 * np.sin(cv.y * 5.0 + n * 8)
    hcol = mix([0.50, 0.14, 0.05], [0.80, 0.30, 0.10], strands * 0.8)
    # shawl with a ragged hem
    shawl = superellipse(cv, -0.3, 0, 5.8, 12.3, 2.5)
    jag = 0.55 * np.abs(np.sin(np.arctan2(cv.y, cv.x + 0.3) * 22)) + (cv.noise(0.6, 12) - 0.5)
    shawl = shawl + jag * np.clip(shawl + 2.0, 0, 1)
    cv.layer(shawl, fabric(cv, [0.30, 0.12, 0.34], 13, 0.25), bevel=3.0)
    cv.layer(hair, hcol, bevel=2.2, gloss=0.08)


def torso_pumpkin(cv):
    shoulders(cv, [0.14, 0.12, 0.14], 21)
    # leaf collar round the neck
    for k in range(8):
        a = 2 * math.pi * k / 8 + 0.2
        cx, cy = HX + 6.0 * math.cos(a), 6.0 * math.sin(a)
        d = ellipse(cv, cx, cy, 2.6, 1.4, a + math.pi / 2)
        g = [0.16 + 0.04 * (k % 2), 0.40 + 0.06 * (k % 3), 0.12]
        cv.layer(d, fabric(cv, g, 22 + k, 0.15, 0.6), bevel=1.0, ao=0.3)
        vein = line_mask((cv.x - cx) * math.sin(a + math.pi / 2) - (cv.y - cy) * math.cos(a + math.pi / 2), 0.12)
        cv.mark(vein * (d < -0.3), [0.08, 0.22, 0.06], 0.7)


def torso_devil(cv):
    # pointed tail lying behind
    tail = bezier_tube(cv, [(-4.0, 2.5), (-11.0, 6.0), (-11.5, -3.0)], 0.75, 0.45)
    spade = polygon(cv, [(-11.3, -2.6), (-13.0, -4.2), (-11.6, -6.6), (-10.0, -4.4)])
    cv.layer(union(tail, spade), [0.62, 0.06, 0.05], bevel=0.7, gloss=0.18)
    d = shoulders(cv, [0.62, 0.07, 0.06], 31)
    # black waistcoat lapels down the front
    lap = polygon(cv, [(4.9, -3.6), (2.0, -1.8), (2.0, 1.8), (4.9, 3.6), (5.3, 0)])
    cv.mark(np.clip(-lap * S, 0, 1) * (d < -0.4), [0.07, 0.05, 0.05], 0.95)


def torso_skeleton(cv):
    d = shoulders(cv, [0.14, 0.13, 0.15], 41)
    # bone print: collarbones, shoulder joints, shoulder blades, spine
    bone = [0.88, 0.86, 0.80]
    for side in (-1, 1):
        cl = bezier_tube(cv, [(3.4, side * 1.4), (3.9, side * 5.5), (1.5, side * 9.0)], 0.42, 0.42)
        cv.mark(np.clip(-cl * S, 0, 1), bone)
        jt = circle(cv, 0.3, side * 9.6, 1.2)
        cv.mark(np.clip(-jt * S, 0, 1), bone)
        sc = polygon(cv, [(-1.0, side * 2.6), (-1.6, side * 8.4), (-4.4, side * 3.4)])
        cv.mark(line_mask(sc, 0.3), bone)
    sp = capsule(cv, -2.2, 0, -5.4, 0, 0.5)
    cv.mark(np.clip(-sp * S, 0, 1) * (np.sin(cv.x * 6) > -0.3), bone)
    # hood bunched behind the neck
    hood = ellipse(cv, -4.2, 0, 2.8, 5.2)
    cv.layer(hood, fabric(cv, [0.12, 0.11, 0.12], 42), bevel=2.0, ao=0.45)
    inner = ellipse(cv, -3.6, 0, 1.4, 3.4)
    cv.mark(np.clip(-inner * S, 0, 1), [0.03, 0.03, 0.035], 0.9)


def torso_cat(cv):
    tail = bezier_tube(cv, [(-4.0, -1.5), (-12.5, -2.5), (-11.0, 5.5)], 1.25, 0.85)
    fur = cv.noise(0.35, 51)
    cv.layer(tail + (fur - 0.5) * 0.5, fabric(cv, [0.07, 0.06, 0.07], 52, 0.3, 0.4), bevel=1.2, gloss=0.08)
    shoulders(cv, [0.40, 0.38, 0.42], 53)
    # red collar with a gold bell at the front
    r, th = polar(cv, HX, 0)
    ring = line_mask(r - 5.9, 0.55) * (np.cos(th) > -0.2)
    cv.mark(ring, [0.75, 0.08, 0.10])
    bell = circle(cv, HX + 6.4, 0, 1.15)
    cv.layer(bell, [0.95, 0.72, 0.22], bevel=1.15, gloss=0.5, ao=0.4)
    cv.mark(line_mask(cv.x - (HX + 6.4), 0.12) * (bell < -0.2), [0.3, 0.2, 0.05], 0.8)


def torso_vampire(cv):
    # long cape, wider than the shoulders, hanging down the back
    n = cv.noise(1.0, 61)
    cape = superellipse(cv, -2.6, 0, 8.2, 13.6, 2.3) + (n - 0.5) * 0.8
    folds = 0.82 + 0.18 * np.sin(cv.y * 1.6 + n * 4) * np.clip(-cv.x / 6, 0, 1)
    edge = np.clip((cape + 1.3) / 0.6, 0, 1) * (cv.x < -1.0)
    cv.layer(cape, mix([0.10, 0.08, 0.11], [0.55, 0.04, 0.07], edge), bevel=3.5, shade=folds, gloss=0.05)
    # shoulders under the cape
    d = superellipse(cv, -0.2, 0, 5.0, 11.2, 2.6)
    cv.layer(d, fabric(cv, [0.09, 0.08, 0.10], 62), bevel=3.0)
    # high collar standing round the back of the head: red lining faces the head
    r, th = polar(cv, HX, 0)
    behind = np.cos(th) < 0.15
    collar = np.where(behind, np.abs(r - 7.1) - 1.3, 99.0)
    collar = np.maximum(collar, (np.cos(th) - 0.15) * 6)
    lining = np.clip((7.7 - r) / 0.6, 0, 1)
    ccol = mix([0.08, 0.06, 0.08], [0.62, 0.04, 0.07], lining)
    cv.layer(collar, ccol, bevel=0.8, gloss=0.12, ao=0.5)


TORSOS = dict(witch=torso_witch, pumpkin=torso_pumpkin, devil=torso_devil,
              skeleton=torso_skeleton, cat=torso_cat, vampire=torso_vampire)


# =====================================================================
# heads
# =====================================================================

def hair_dome(cv, color, seed, freq=46, cx=HX - 1.6, gloss=0.12, rx=HR + 0.3, ry=HR):
    d = ellipse(cv, HX, 0, rx, ry)
    st = hair_strands(cv, cx, 0, seed, freq)
    col = mix(np.asarray(color) * 0.7, np.asarray(color) * 1.25, st)
    cv.layer(d, col, bevel=HR, gloss=gloss)
    return d


def head_witch(cv):
    # hair spilling from under the brim
    hair = ellipse(cv, HX - 0.8, 0, 6.6, 6.2)
    cv.layer(hair + (cv.noise(0.5, 71) - 0.5) * 1.5, [0.70, 0.24, 0.08], bevel=2.0)
    # wide floppy brim, curled up at the edge
    r, th = polar(cv, HX - 0.4, 0)
    wob = 0.45 * np.sin(th * 3 + 0.7) + 0.25 * np.sin(th * 5 + 2.0)
    brim = r - (11.0 + wob)
    curl = 0.75 + 0.35 * np.exp(-((r - 10.4 - wob) / 0.9) ** 2)
    felt = fabric(cv, [0.24, 0.15, 0.30], 72, 0.22, 0.7)
    cv.layer(brim, felt, bevel=1.0, shade=curl, ao=0.5)
    # band and buckle
    band = np.abs(r - 5.1) - 0.75
    cv.layer(band, [0.86, 0.48, 0.10], bevel=0.6, ao=0.3)
    buckle = superellipse(cv, HX - 0.4 + 5.1, 0, 0.9, 1.1, 4)
    cv.layer(buckle, [0.90, 0.72, 0.25], bevel=0.5, gloss=0.4, ao=0.2)
    cv.mark(np.clip(-superellipse(cv, HX - 0.4 + 5.1, 0, 0.45, 0.6, 4) * S, 0, 1), [0.86, 0.48, 0.10])
    # the cone: apex bent back and to one side, lit as facets round the apex
    ax, ay = HX - 2.6, 1.0
    rc, thc = polar(cv, HX - 0.4, 0)
    cone = rc - 4.4
    ra, tha = polar(cv, ax, ay)
    facet = 0.70 + 0.45 * np.cos(tha - 2.4) + 0.10 * np.cos(tha * 7)
    apex = 1.0 + 0.5 * np.exp(-(ra / 0.9) ** 2)
    crinkle = 0.9 + 0.2 * cv.noise(0.5, 73)
    cv.layer(cone, felt * 1.35, bevel=0.6, shade=facet * apex * crinkle, ao=0.45)
    cv.mark(line_mask(np.hypot(cv.x - ax, cv.y - ay) - 0.25, 0.25), INK, 0.6)


def head_pumpkin(cv):
    r, th = polar(cv, HX, 0)
    R = 7.0 * (1 + 0.035 * np.cos(8 * th))
    d = (r - R)
    groove = np.exp(-((np.cos(8 * th) + 1) / 0.25) ** 2) * np.clip(r / 3.0, 0, 1)
    col = mix([0.96, 0.50, 0.07], [0.80, 0.33, 0.04], cv.noise(1.0, 81) * 0.6 + groove * 0.6)
    cv.layer(d, col, bevel=7.0, gloss=0.18, shade=1 - 0.35 * groove)
    # stem curling forward
    stem = bezier_tube(cv, [(HX, 0), (HX + 1.0, -0.3), (HX + 2.0, 0.8)], 1.0, 0.65)
    cv.layer(stem, [0.36, 0.30, 0.12], bevel=0.7, ao=0.5)
    cv.mark(line_mask(stem + 0.5, 0.12), [0.2, 0.17, 0.06], 0.6)


def head_devil(cv):
    hair_dome(cv, [0.20, 0.12, 0.08], 91)
    for side in (-1, 1):
        horn = bezier_tube(cv, [(HX + 0.4, side * 3.0), (HX + 2.0, side * 6.4), (HX + 5.2, side * 6.6)], 1.35, 0.12)
        sh = 0.85 + 0.25 * np.sin((cv.x - HX) * 3.0)
        hc = mix([0.80, 0.10, 0.07], [1.0, 0.55, 0.35], np.clip((cv.x - HX - 3.0) / 2.5, 0, 1))
        cv.layer(horn, hc, bevel=0.9, gloss=0.35, shade=sh, ao=0.45)


def head_skeleton(cv):
    d = ellipse(cv, HX, 0, 6.0, 5.3)
    cv.layer(d, fabric(cv, [0.90, 0.88, 0.81], 101, 0.06), bevel=5.3, gloss=0.2)
    # sutures
    sag = line_mask(cv.y - 0.25 * np.sin(cv.x * 4.0), 0.11) * (cv.x < HX + 1.6) * (cv.x > HX - 5.4)
    cor = line_mask(cv.x - (HX + 1.6) - 0.25 * np.sin(cv.y * 4.0), 0.11) * (np.abs(cv.y) < 4.6)
    cv.mark(sag + cor, [0.35, 0.30, 0.25], 0.8)
    # brow and eye sockets just visible over the front of the dome
    for side in (-1, 1):
        sock = ellipse(cv, HX + 5.7, side * 2.3, 1.2, 1.5)
        cv.mark(np.clip(-sock * S, 0, 1) * (d < 0), [0.06, 0.05, 0.05], 0.95)
    # black hood elastic round the back
    r, th = polar(cv, HX, 0)
    cv.mark(line_mask(r - 5.0, 0.25) * (np.cos(th) < -0.3), [0.1, 0.09, 0.1], 0.9)


def head_cat(cv):
    hair_dome(cv, [0.10, 0.09, 0.10], 111, gloss=0.18)
    for side in (-1, 1):
        ear = polygon(cv, [(HX + 3.4, side * 2.4), (HX - 0.8, side * 4.2), (HX + 2.4, side * 8.6)])
        cv.layer(ear, [0.10, 0.09, 0.10], bevel=0.8, gloss=0.1, ao=0.45)
        inner = polygon(cv, [(HX + 2.8, side * 3.2), (HX + 0.4, side * 4.4), (HX + 2.3, side * 7.2)])
        cv.mark(np.clip(-inner * S, 0, 1), [0.92, 0.52, 0.62], 0.95)
    # the band between the ears
    r, th = polar(cv, HX, 0)
    cv.mark(line_mask(cv.x - (HX + 2.2) + 0.1 * cv.y ** 2 * 0.0, 0.35) * (np.abs(cv.y) < 5.0) * (r < HR), [0.03, 0.03, 0.03], 0.7)


def head_vampire(cv):
    d = ellipse(cv, HX, 0, HR + 0.3, HR)
    # combed straight back: streaks along x, sheen down the middle
    n = cv.noise(1.2, 121)
    streak = 0.5 + 0.5 * np.sin(cv.y * 9.0 + n * 3)
    col = mix([0.06, 0.05, 0.06], [0.15, 0.13, 0.15], streak * 0.7)
    sheen = 1 + 0.9 * np.exp(-(cv.y / 1.6) ** 2) * np.clip((cv.x - HX + 3) / 4, 0, 1) * np.clip((HX + 4 - cv.x) / 2, 0, 1)
    cv.layer(d, col, bevel=HR, gloss=0.15, shade=sheen)
    # pale forehead in front of a widow's peak
    peak = (cv.x - HX) - (3.6 + 1.3 * np.clip(np.abs(cv.y) / 3.0, 0, 1) - 0.0)
    skin = np.clip(peak * S, 0, 1) * (d < 0)
    cv.mark(skin, [0.92, 0.88, 0.86])


HEADS = dict(witch=head_witch, pumpkin=head_pumpkin, devil=head_devil,
             skeleton=head_skeleton, cat=head_cat, vampire=head_vampire)


# =====================================================================
# arms (pivot = shoulder, pointing +x)
# =====================================================================

ARMS = {
    #           sleeve                cuff                    hand
    "witch":    ([0.16, 0.12, 0.18], [0.30, 0.12, 0.34], [0.45, 0.66, 0.30]),
    "pumpkin":  ([0.92, 0.46, 0.06], [0.10, 0.09, 0.10], [0.48, 0.31, 0.19]),
    "devil":    ([0.62, 0.07, 0.06], [0.07, 0.05, 0.05], [0.36, 0.22, 0.14]),
    "skeleton": ([0.14, 0.13, 0.15], [0.14, 0.13, 0.15], [0.90, 0.88, 0.81]),
    "cat":      ([0.40, 0.38, 0.42], [0.92, 0.90, 0.88], [0.66, 0.46, 0.32]),
    "vampire":  ([0.08, 0.07, 0.09], [0.93, 0.91, 0.88], [0.92, 0.88, 0.86]),
}
HAND_X = 10.3


def paint_arm(name):
    cv = Canvas(-3, 13, -4, 4)
    sleeve, cuff, hand = ARMS[name]
    sl = capsule(cv, 0, 0, 8.4, 0, 2.6, 2.1)
    col = fabric(cv, sleeve, 130 + COSTUMES.index(name), 0.15)
    cv.layer(sl, col, bevel=2.3)
    if name == "pumpkin":
        cv.mark((np.sin(cv.x * 1.9) > 0.35) * (sl < 0), [0.10, 0.09, 0.10], 0.95)
    if name == "skeleton":
        b = capsule(cv, 1.2, 0, 7.0, 0, 0.45)
        cv.mark(np.clip(-b * S, 0, 1), [0.88, 0.86, 0.80])
        cv.mark(np.clip(-circle(cv, 1.2, 0, 0.8) * S, 0, 1), [0.88, 0.86, 0.80])
        cv.mark(np.clip(-circle(cv, 7.0, 0, 0.75) * S, 0, 1), [0.88, 0.86, 0.80])
    if name == "witch":
        jag = np.clip(-(capsule(cv, 7.6, 0, 8.6, 0, 2.6) + 0.3 * np.abs(np.sin(cv.y * 6))) * S, 0, 1)
        cv.mark(jag, cuff)
    elif name in ("pumpkin", "devil", "vampire"):
        c = capsule(cv, 7.6, 0, 8.6, 0, 2.3)
        if name == "vampire":
            c = c + 0.35 * np.abs(np.sin(cv.y * 5))
        cv.layer(c, cuff, bevel=1.0, ao=0.2)
    h = circle(cv, HAND_X, 0, 2.05)
    cv.layer(h, hand, bevel=2.0, gloss=0.08, ao=0.35)
    if name == "skeleton":
        for k in (-0.9, 0.0, 0.9):
            cv.mark(line_mask(cv.y - k, 0.12) * (cv.x > HAND_X + 0.2) * (h < -0.2), [0.30, 0.27, 0.24], 0.8)
    return cv.finish()


# =====================================================================
# dropped costume pieces (left on the floor when a guest is caught)
# =====================================================================

def item_witch(cv):
    rot = -0.35
    c, s = math.cos(rot), math.sin(rot)
    # brim seen almost edge-on (hat lying on its side), cone pointing +x
    brim = ellipse(cv, -5.2, 0.5, 2.4, 10.5, rot)
    felt = fabric(cv, [0.24, 0.15, 0.30], 141, 0.22, 0.7)
    cv.layer(brim, felt, bevel=1.2)
    bx, by = -5.2, 0.5
    tip = (bx + 13.0 * c + 2.0 * s, by - 13.0 * s + 2.0 * c)
    cone = polygon(cv, [(bx - 4.6 * s * -1 * 0 + 4.8 * s, by + 4.8 * c), tip, (bx - 4.8 * s, by - 4.8 * c)])
    side = 0.7 + 0.3 * np.clip(((cv.x - bx) * s + (cv.y - by) * c) / 5 + 0.5, 0, 1)
    cv.layer(cone - 0.2, felt, bevel=1.6, shade=side)
    band = polygon(cv, [(bx + 4.8 * s + 1.0 * c, by + 4.8 * c - 1.0 * s), (bx + 4.4 * s + 2.4 * c, by + 4.4 * c - 2.4 * s),
                        (bx - 4.4 * s + 2.4 * c, by - 4.4 * c - 2.4 * s), (bx - 4.8 * s + 1.0 * c, by - 4.8 * c - 1.0 * s)])
    cv.mark(np.clip(-band * S, 0, 1) * (cone < 0), [0.86, 0.48, 0.10])


def item_pumpkin(cv):
    # the pumpkin head rolled face-up: carved face showing
    d = ellipse(cv, 0, 0.6, 9.2, 8.0)
    R = 9.2
    groove = np.zeros_like(cv.x)
    for phi in (-1.0, -0.5, 0.0, 0.5, 1.0):
        xr = math.sin(phi) * np.sqrt(np.clip(1 - ((cv.y - 0.6) / 8.0) ** 2, 0, 1)) * R
        groove = np.maximum(groove, np.exp(-((cv.x - xr) / 0.45) ** 2))
    col = mix([0.96, 0.50, 0.07], [0.78, 0.32, 0.04], cv.noise(1.0, 151) * 0.5 + groove * 0.6)
    cv.layer(d, col, bevel=8.0, gloss=0.15, shade=1 - 0.3 * groove)
    stem = capsule(cv, 0, -7.2, 0.6, -9.4, 0.9, 0.7)
    cv.layer(stem, [0.36, 0.30, 0.12], bevel=0.7, ao=0.4)
    glow = [0.55, 0.20, 0.03]
    holes = union(
        polygon(cv, [(-4.6, -0.6), (-1.6, -0.6), (-3.1, -3.4)]),
        polygon(cv, [(1.6, -0.6), (4.6, -0.6), (3.1, -3.4)]),
        polygon(cv, [(-0.8, 1.6), (0.8, 1.6), (0, 0.2)]),
        polygon(cv, [(-5.2, 3.0), (-3.6, 4.0), (-2.2, 3.2), (-0.8, 4.2), (0.8, 3.2), (2.2, 4.2), (3.6, 3.2), (5.2, 3.0),
                     (4.4, 5.8), (2.4, 6.4), (1.2, 5.4), (0, 6.6), (-1.2, 5.4), (-2.4, 6.4), (-4.4, 5.8)]),
    )
    cv.mark(np.clip(-holes * S, 0, 1), glow)
    cv.mark(np.clip(-(holes + 0.45) * S, 0, 1), [0.10, 0.03, 0.01], 0.85)


def headband(cv, color):
    r, th = polar(cv, 0, 0.8)
    band = np.where(np.sin(th) < 0.75, np.abs(r - 5.6) - 0.45, 99.0)
    cv.layer(band, color, bevel=0.45, gloss=0.2)


def item_devil(cv):
    headband(cv, [0.07, 0.05, 0.05])
    for side in (-1, 1):
        a = -math.pi / 2 + side * 0.85
        bx, by = 5.6 * math.cos(a), 0.8 + 5.6 * math.sin(a)
        horn = bezier_tube(cv, [(bx, by), (bx + side * 1.6, by - 2.6), (bx + side * 3.8, by - 3.2)], 1.2, 0.12)
        cv.layer(horn, [0.72, 0.08, 0.06], bevel=0.9, gloss=0.35, ao=0.45)


def item_skeleton(cv):
    skull = union(circle(cv, 0, -1.4, 6.6), superellipse(cv, 0, 4.0, 4.0, 3.2, 3))
    cv.layer(skull, fabric(cv, [0.90, 0.88, 0.81], 161, 0.06), bevel=3.0, gloss=0.15)
    holes = union(ellipse(cv, -2.6, -0.6, 1.8, 2.1), ellipse(cv, 2.6, -0.6, 1.8, 2.1),
                  polygon(cv, [(-0.8, 2.6), (0.8, 2.6), (0, 1.2)]))
    cv.mark(np.clip(-holes * S, 0, 1), [0.06, 0.05, 0.05])
    teeth = (np.abs(cv.y - 5.2) < 0.9) * (np.abs(cv.x) < 3.0)
    cv.mark(line_mask(np.sin(cv.x * 2.6), 0.25) * teeth + line_mask(cv.y - 5.2, 0.1) * (np.abs(cv.x) < 3.0), [0.30, 0.27, 0.24], 0.8)
    r, th = polar(cv, 0, 0)
    strap = bezier_tube(cv, [(-6.4, 0.2), (-9.5, 4.0), (-6.0, 8.5)], 0.35, 0.35)
    cv.layer(strap, [0.08, 0.07, 0.08], bevel=0.3, ao=0.2)


def item_cat(cv):
    headband(cv, [0.08, 0.07, 0.08])
    for side in (-1, 1):
        a = -math.pi / 2 + side * 0.8
        bx, by = 5.6 * math.cos(a), 0.8 + 5.6 * math.sin(a)
        ox, oy = math.cos(a), math.sin(a)
        tx, ty = -oy, ox
        ear = polygon(cv, [(bx - tx * 2.0, by - ty * 2.0), (bx + ox * 3.6, by + oy * 3.6), (bx + tx * 2.0, by + ty * 2.0)])
        cv.layer(ear, [0.07, 0.06, 0.07], bevel=0.8, gloss=0.1, ao=0.4)
        inner = polygon(cv, [(bx - tx * 1.1 + ox * 0.5, by - ty * 1.1 + oy * 0.5), (bx + ox * 2.6, by + oy * 2.6),
                             (bx + tx * 1.1 + ox * 0.5, by + ty * 1.1 + oy * 0.5)])
        cv.mark(np.clip(-inner * S, 0, 1), [0.88, 0.50, 0.60], 0.9)


def item_vampire(cv):
    n = cv.noise(2.2, 171)
    n2 = cv.noise(1.8, 172)
    blob = superellipse(cv, 0, 0, 10.8, 8.8, 2.2, 0.3) + (n - 0.5) * 6.0 + (n2 - 0.5) * 1.2
    lining = np.clip((n2 - 0.6) / 0.03, 0, 1) * np.clip(-blob / 2.5, 0, 1)
    folds = 0.78 + 0.3 * np.sin(n2 * 14)
    col = mix([0.07, 0.06, 0.08], [0.58, 0.04, 0.07], lining)
    cv.layer(blob, col, bevel=2.5, shade=folds, gloss=0.08)


ITEMS = dict(witch=item_witch, pumpkin=item_pumpkin, devil=item_devil,
             skeleton=item_skeleton, cat=item_cat, vampire=item_vampire)


# =====================================================================
# shared props
# =====================================================================

PUNCH = np.array([0.30, 0.78, 0.18])    # glowing green Halloween punch
CUP_RED = np.array([0.80, 0.07, 0.08])


def paint_shoe():
    cv = Canvas(-4, 4, -2.5, 2.5)
    d = superellipse(cv, 0, 0, 3.4, 1.8, 2.2)
    cv.layer(d, [0.13, 0.10, 0.09], bevel=1.6, gloss=0.18)
    cv.mark(line_mask(cv.y, 0.12) * (cv.x > -0.6) * (cv.x < 1.6), [0.45, 0.42, 0.40], 0.6)
    return cv.finish()


def paint_cup():
    cv = Canvas(-3, 3, -3, 3)
    cv.layer(circle(cv, 0, 0, 2.7), CUP_RED, bevel=0.6, line=0.4)
    cv.mark(line_mask(np.hypot(cv.x, cv.y) - 2.4, 0.28), [0.95, 0.93, 0.90])
    drink = circle(cv, 0, 0, 1.55)
    cv.layer(cut(circle(cv, 0, 0, 2.1), drink), CUP_RED * 0.6, bevel=0.4, ao=0.0, line=0.0)
    cv.layer(drink, PUNCH * 0.8, bevel=0.3, gloss=0.0, ao=0.0, line=0.3,
             shade=0.85 + 0.3 * np.exp(-((cv.x + 0.7) ** 2 + (cv.y + 0.7) ** 2) / 0.4))
    return cv.finish(0.8)


def paint_cup_tipped():
    cv = Canvas(-4.5, 4.5, -3.5, 3.5)
    body = polygon(cv, [(-3.4, -1.9), (2.9, -2.7), (2.9, 2.7), (-3.4, 1.9)])
    shade = 0.75 + 0.35 * np.exp(-((cv.y + 0.6) / 1.2) ** 2)
    cv.layer(body, CUP_RED, bevel=1.4, shade=shade, gloss=0.15)
    cv.mark((np.abs(np.sin(cv.x * 4)) < 0.15) * (cv.x < -1.8) * (body < -0.3), [0.55, 0.04, 0.05], 0.5)
    rim = ellipse(cv, 2.9, 0, 0.85, 2.75)
    cv.layer(rim, [0.95, 0.93, 0.90], bevel=0.4, ao=0.2)
    cv.mark(np.clip(-ellipse(cv, 2.95, 0, 0.55, 2.35) * S, 0, 1), [0.10, 0.03, 0.03])
    return cv.finish()


def paint_spill():
    cv = Canvas(-9, 9, -7, 7)
    n = cv.noise(2.0, 181)
    n2 = cv.noise(0.7, 182)
    d = superellipse(cv, -0.5, 0, 7.6, 5.4, 2.0) + (n - 0.5) * 5.0 + (n2 - 0.5) * 0.8
    for k, (cx, cy, r) in enumerate([(6.8, -3.6, 0.8), (7.6, 2.4, 0.55), (-7.4, 4.2, 0.6), (4.8, 5.4, 0.45)]):
        d = np.minimum(d, circle(cv, cx, cy, r))
    depth = np.clip(-d / 2.5, 0, 1)
    col = mix(PUNCH * 0.55, PUNCH * 0.9, depth)
    gl = 0.25 * np.exp(-((cv.x + 1.5) ** 2 / 6 + (cv.y + 1.2) ** 2 / 1.2))
    cv.layer(d, col, bevel=0.5, shade=1 + gl * 3, line=0.25, ao=0.0)
    img = cv.finish(0.0)
    img[..., 3] *= 0.78
    return img


# =====================================================================
# output + contact sheet
# =====================================================================

def save(arr, path):
    Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(path)


def paint_part(fn, box):
    cv = Canvas(*box)
    fn(cv)
    return cv.finish()


TORSO_BOX = (-13, 10, -15, 15)
HEAD_BOX = (-12, 12, -12, 12)
ITEM_BOX = (-12, 12, -12, 12)


def place(sheet, img, box, cx, cy, rot=0.0, sx=1.0, sy=1.0, scale=1.0):
    """Composite a part onto the sheet. (cx, cy) = sheet px of the part's origin; rot in rad."""
    from PIL import Image as I
    im = I.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA")
    x0, x1, y0, y1 = box
    ox, oy = -x0 * S, -y0 * S                       # origin pixel in the part image
    w, h = im.size
    im = im.resize((max(1, int(w * sx * scale)), max(1, int(h * sy * scale))), I.BICUBIC)
    ox, oy = ox * sx * scale, oy * sy * scale
    # rotate about the origin by padding so the origin is centred
    W, H = im.size
    R = int(math.hypot(max(ox, W - ox), max(oy, H - oy))) + 2
    pad = I.new("RGBA", (2 * R, 2 * R), (0, 0, 0, 0))
    pad.paste(im, (int(R - ox), int(R - oy)))
    pad = pad.rotate(-math.degrees(rot), resample=I.BICUBIC)
    sheet.alpha_composite(pad, (int(cx - R), int(cy - R)))


def contact_sheet(parts, shared, out):
    from PIL import Image as I, ImageDraw
    k = 0.5                                     # sheet scale vs texture (4 sheet px per game px)
    cell = int(32 * S * k)
    sheet = I.new("RGBA", (cell * 6, int(cell * 2.3) + int(14 * S * k)), (58, 52, 50, 255))
    g = S * k
    for i, name in enumerate(COSTUMES):
        p = parts[name]
        cx, cy = cell * i + cell // 2, cell // 2
        for side in (-1, 1):
            place(sheet, shared["shoe"], (-4, 4, -2.5, 2.5), cx + 2.0 * g, cy + side * 4.0 * g, scale=k)
        place(sheet, p["torso"], TORSO_BOX, cx, cy, scale=k)
        for side in (-1, 1):
            ang = side * 0.15
            place(sheet, p["arm"], (-3, 13, -4, 4), cx + 0.3 * g, cy + side * 9.8 * g, rot=ang, sx=0.55, scale=k)
        hx = cx + (0.3 + HAND_X * 0.55 * math.cos(0.15)) * g
        hy = cy + (9.8 + HAND_X * 0.55 * math.sin(0.15)) * g
        place(sheet, shared["cup"], (-3, 3, -3, 3), hx, hy, scale=k)
        place(sheet, p["head"], HEAD_BOX, cx, cy, scale=k)
        # second row: running pose (arms up and out) + the dropped item
        cy2 = int(cell * 1.55)
        place(sheet, p["item"], ITEM_BOX, cx - 7 * g, cy2 + 4 * g, scale=k * 0.7)
        for side in (-1, 1):
            place(sheet, shared["shoe"], (-4, 4, -2.5, 2.5), cx + 4 * g + side * 3 * g, cy2 - 6 * g + side * 4.0 * g, scale=k * 0.8)
        cx2 = cx + 4 * g
        place(sheet, p["torso"], TORSO_BOX, cx2, cy2 - 6 * g, rot=0.12, scale=k * 0.8)
        for side in (-1, 1):
            place(sheet, p["arm"], (-3, 13, -4, 4), cx2, cy2 - 6 * g + side * 7.8 * g, rot=side * 0.9, scale=k * 0.8)
        place(sheet, p["head"], HEAD_BOX, cx2 + 2.4 * g, cy2 - 6 * g, scale=k * 0.8)
        d = ImageDraw.Draw(sheet)
        d.text((cell * i + 6, 4), f"{i} {name}", fill=(230, 220, 200, 255))
    y = int(cell * 2.3)
    xs = 20
    for key, box in (("cup", (-3, 3, -3, 3)), ("cup_tipped", (-4.5, 4.5, -3.5, 3.5)), ("spill", (-9, 9, -7, 7)),
                     ("shoe", (-4, 4, -2.5, 2.5))):
        w = (box[1] - box[0]) * g
        place(sheet, shared[key], box, xs - box[0] * g, y + 7 * g, scale=k)
        xs += int(w) + 30
    sheet.save(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.environ.get("OUT_DIR") or os.path.dirname(here)
    os.makedirs(out, exist_ok=True)
    parts = {}
    for name in COSTUMES:
        p = {
            "torso": paint_part(TORSOS[name], TORSO_BOX),
            "head": paint_part(HEADS[name], HEAD_BOX),
            "arm": paint_arm(name),
            "item": paint_part(ITEMS[name], ITEM_BOX),
        }
        for k, v in p.items():
            save(v, os.path.join(out, f"guest_{name}_{k}.png"))
        parts[name] = p
        print("painted", name)
    shared = {"shoe": paint_shoe(), "cup": paint_cup(), "cup_tipped": paint_cup_tipped(), "spill": paint_spill()}
    for k, v in shared.items():
        save(v, os.path.join(out, f"guest_{k}.png"))
    contact_sheet(parts, shared, os.path.join(here, "guest_contact_sheet.png"))
    print("wrote", out)


if __name__ == "__main__":
    main()
