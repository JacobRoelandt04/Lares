#!/usr/bin/env python3
"""weather_ink_parts.py -- draws the ink weather icon set and writes its outlines.

  modules/common/components/WeatherInkParts.js      (GENERATED: PARTS, COMPS, UNITS)

The set is drawn here, not taken from a font: every icon is composed on Material Design's 24-unit grid from a few primitives
(sun, crescent, cloud, drop, streak, flake, stone, bolt, bar, curl, sparkle, dart), each a signed distance in numpy. A part
that lies BEHIND another is cut by the front part grown by GAP (the gap Material's filled icons leave between overlapping
shapes), which in distances is one line: max(d_part, GAP - d_front). The outline of each cut part is then traced at d = 0
(contourpy, on a grid of 1/STEP unit) and thinned to line segments within TOL of the traced line.

No boolean path library is needed (none is installed here), and a part stays its own contour list, in GlyphOutline.js's
format (y up, origin at the box's bottom-left, ["M",x,y] / ["L",x,y]), so a flourish can pose it.

  COMPS[key] = [[partId, role, type, anchors, frames], ...]
                                         role "ink" or the theme token of the icon's ONE accent ("weatherDrop", ...);
                                         type / anchors / frames are for the part's flourish (class L, BAKED FRAMES below)
  PARTS[partId] = contours               shared between compositions (the same cloud is stored once)
  FRAMES[name] = [from, step, [partId, ...]]

Keys: "clear|d" "clear|n" "partly|d" "partly|n" "cloudy" "cloud" "fog" "wind" "arrow" "dot", and for precipitation
"<kind>|<intensity 0..2>|<sky>" with kind rain / sleet / snow / hail / thunder and sky plain / sun / moon / heavy
(WeatherInkCompose.js picks the key).

  python3 tools/dev/weather_ink_parts.py            write the file
  python3 tools/dev/weather_ink_parts.py --check    compare only (exit 1 when stale)
  python3 tools/dev/weather_ink_parts.py --sheet <png>   draw every composition without a shell (writes nothing else)
"""
import hashlib
import math
import os
import sys

import numpy as np
from contourpy import contour_generator

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "modules/common/components/WeatherInkParts.js")

UNITS = 24
STEP = 40          # grid cells per unit
PAD = 1.0          # units of grid outside the box
TOL = 0.012        # units a thinned outline may leave the traced one
FRAME_TOL = 0.03   # the same for a baked frame, seen only in motion (at 24 px: a fortieth of a pixel)
GAP = 1.25         # units between a part and the part in front of it

_n = int((UNITS + 2 * PAD) * STEP) + 1
_ax = np.linspace(-PAD, UNITS + PAD, _n)
X, Y = np.meshgrid(_ax, _ax)        # y DOWN while drawing; flipped at the output


# ---- distances (negative inside) ---------------------------------------------------------------------------------------
def circle(cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def capsule(ax, ay, bx, by, r):
    px, py, dx, dy = X - ax, Y - ay, bx - ax, by - ay
    h = np.clip((px * dx + py * dy) / (dx * dx + dy * dy), 0, 1)
    return np.hypot(px - dx * h, py - dy * h) - r


def polygon(pts, r=0.0):
    """a simple polygon, its corners rounded OUT by r (draw it r smaller)"""
    d = np.full(X.shape, np.inf)
    inside = np.zeros(X.shape, bool)
    n = len(pts)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        px, py, dx, dy = X - ax, Y - ay, bx - ax, by - ay
        h = np.clip((px * dx + py * dy) / (dx * dx + dy * dy), 0, 1)
        d = np.minimum(d, np.hypot(px - dx * h, py - dy * h))
        cond = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / (by - ay + 1e-12) + ax)
        inside ^= cond
    return np.where(inside, -d, d) - r


def union(*ds):
    out = ds[0]
    for d in ds[1:]:
        out = np.minimum(out, d)
    return out


def smooth_union(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)


def cut(d, front, gap=GAP):
    return np.maximum(d, gap - front)


def arc(cx, cy, R, a0, a1, r):
    """a round-capped arc of radius R from angle a0 to a1 (degrees, y down, a1 > a0), r thick each side"""
    am, half = math.radians((a0 + a1) / 2), math.radians((a1 - a0) / 2)
    px, py = X - cx, Y - cy
    # into the arc's own frame: its middle on +x
    qx = px * math.cos(am) + py * math.sin(am)
    qy = np.abs(-px * math.sin(am) + py * math.cos(am))
    ang = np.arctan2(qy, qx)
    ex, ey = R * math.cos(half), R * math.sin(half)
    return np.where(ang <= half, np.abs(np.hypot(qx, qy) - R), np.hypot(qx - ex, qy - ey)) - r


# ---- layers -------------------------------------------------------------------------------------------------------------
class L:
    """one part of an icon: its role (ink / the accent's token), its distance, and what a flourish needs to move it --
    `t` its type, `a` the type's anchors (grid units, y UP as the outlines are), `frames` its baked frames (below)"""

    def __init__(self, role, d, t="still", a=(), frames=None, quarter=None):
        self.role, self.d, self.t, self.a, self.frames, self.quarter = role, d, t, list(a), frames, quarter


def up(y):
    return UNITS - y


# BAKED FRAMES. A part that lies behind another is cut by it, so it cannot simply be moved: the cut would move with it. Its
# flourish is baked here instead -- the part drawn at each step of ONE parameter and cut afresh -- and WeatherInkPose.js picks
# the frame: (from, step, [distance per frame]). The sun's turn (degrees, one ray step: the sun repeats every 45), a
# moon's dip behind its cloud (units down), a back cloud's slide (units right) -- and a storm cloud, which is cut round the
# bolt that comes out of it: the bolt is in front and moves freely, so it is the CLOUD that is baked, along the bolt's size.
N_ROT = 18
SHIFT_STEP = 0.16
BOLT_SIZES = (0.40, 1.08, 0.04)     # the bolt's scale about its top: from, to, step


# ---- primitives ---------------------------------------------------------------------------------------------------------
def cloud(cx, base, w):
    """the flat-footed cloud: `base` is the foot bar's middle line, w the whole width"""
    rb = 0.21 * w
    foot = capsule(cx - 0.5 * w + rb, base, cx + 0.5 * w - rb, base, rb)
    big = circle(cx + 0.09 * w, base - 0.20 * w, 0.30 * w)
    small = circle(cx - 0.21 * w, base - 0.07 * w, 0.215 * w)
    return smooth_union(smooth_union(foot, big, 0.05 * w), small, 0.05 * w)


def sun(cx, cy, r_disc, r0, r1, t, rot=0.0):
    rays = []
    for i in range(8):
        a = math.radians(45 * i + rot)
        c, s = math.cos(a), math.sin(a)
        rays.append(capsule(cx + r0 * c, cy + r0 * s, cx + r1 * c, cy + r1 * s, t))
    return union(circle(cx, cy, r_disc), *rays)


def crescent(cx, cy, r, side=1):
    """a fat crescent, its horns to the upper right (side 1) or upper left (-1)"""
    bite = circle(cx + side * 0.48 * r, cy - 0.42 * r, 0.86 * r)
    return np.maximum(circle(cx, cy, r), -bite)


def sparkle(cx, cy, r):
    """a four-pointed star with hollow sides"""
    pts = []
    for i in range(8):
        a = math.radians(45 * i - 90)
        rr = r if i % 2 == 0 else 0.34 * r
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return polygon(pts, 0.12 * r)


DROP_LEAN = 0.32


def drop(cx, cy, r, lean=DROP_LEAN):
    """a teardrop: a round belly at (cx, cy), its point up and leaning with the rain"""
    ax, ay = cx + lean * 2.1 * r, cy - 2.1 * r
    d = np.inf
    for i in range(1, 9):
        f = i / 8
        d = np.minimum(d, circle(cx + (ax - cx) * f, cy + (ay - cy) * f, r * (1 - f) + 0.16 * r * f))
    return np.minimum(d, circle(cx, cy, r))


def streak(cx, cy, length, r, lean=DROP_LEAN):
    dx, dy = lean * length / 2, length / 2
    return capsule(cx + dx, cy - dy, cx - dx, cy + dy, r)


def flake(cx, cy, r, t):
    arms = []
    for i in range(3):
        a = math.radians(60 * i + 90)
        c, s = math.cos(a), math.sin(a)
        arms.append(capsule(cx - r * c, cy - r * s, cx + r * c, cy + r * s, t))
    return union(*arms)


def bolt(cx, top, h):
    """a zigzag bolt, `top` its upper edge, h tall"""
    w = 0.62 * h
    pts = [(0.30, 0.0), (0.92, 0.0), (0.60, 0.40), (1.0, 0.40), (0.24, 1.0), (0.46, 0.55), (0.0, 0.55)]
    return polygon([(cx - w / 2 + x * w, top + y * h) for x, y in pts], 0.045 * h)


def dart():
    """the wind arrow, pointing UP about the box's centre (the item turns it)"""
    return polygon([(12, 3.4), (18.2, 19.6), (12, 15.6), (5.8, 19.6)], 0.9)


def curl(x0, x1, y, R, sweep, r=0.95):
    """a wind line from x0 to x1 that hooks back over its end: up (R < 0) or down (R > 0), `sweep` degrees round"""
    if R < 0:
        hook = arc(x1, y + R, -R, 90 - sweep, 90, r)
    else:
        hook = arc(x1, y + R, R, -90, -90 + sweep, r)
    return union(capsule(x0, y, x1, y, r), hook)


# ---- the layers of each kind of part (a distance, plus what its flourish is told) ---------------------------------------
def l_sun(role, cx, cy, rd, r0, r1, t, front=None):
    if front is None:
        # its flourish ends a quarter turn on: the outline is made the same under that turn, point for point
        return L(role, sun(cx, cy, rd, r0, r1, t), "sun", [cx, up(cy), rd], quarter=(cx, up(cy)))
    ds = [cut(sun(cx, cy, rd, r0, r1, t, 45.0 * i / N_ROT), front) for i in range(N_ROT)]
    return L(role, ds[0], "sunCut", [cx, up(cy)], (0.0, 45.0 / N_ROT, ds))


def l_moon_cut(role, cx, cy, r, front, dip):
    n0, n1 = 4, int(round(dip / SHIFT_STEP))
    ds = [cut(crescent(cx, cy + i * SHIFT_STEP, r, -1), front) for i in range(-n0, n1 + 1)]
    return L(role, ds[n0], "moonCut", [dip], (-n0 * SHIFT_STEP, SHIFT_STEP, ds))


def l_cloud_back(cx, base, w, front, lo, hi, t):
    n0, n1 = int(round(-lo / SHIFT_STEP)), int(round(hi / SHIFT_STEP))
    ds = [cut(cloud(cx + i * SHIFT_STEP, base, w), front) for i in range(-n0, n1 + 1)]
    return L("ink", ds[n0], t, [lo, hi], (-n0 * SHIFT_STEP, SHIFT_STEP, ds))


def l_bolt(role, cx, top, h):
    # its flourish scales it about (cx, top): the same bolt drawn h * s tall (bolt_cloud bakes the cloud to match)
    L_ = L(role, bolt(cx, top, h), "bolt", [cx, up(top)])
    L_.spec = (cx, top, h)
    return L_


_bolt_clouds = {}


def bolt_cloud(c, spec):
    """the storm cloud cut round its bolt, at every size the bolt's flourish gives it"""
    if (id(c), spec) not in _bolt_clouds:
        _bolt_clouds[(id(c), spec)] = _bolt_cloud(c, spec)
    return _bolt_clouds[(id(c), spec)]


def _bolt_cloud(c, spec):
    cx, top, h = spec
    lo, hi, step = BOLT_SIZES
    n = int(round((hi - lo) / step))
    rest = cut(c, bolt(cx, top, h), 1.0)
    ds = []
    for i in range(n + 1):
        s = lo + i * step
        ds.append(rest if abs(s - 1) < 1e-9 else cut(c, bolt(cx, top, h * s), 1.0))
    return L("ink", rest, "cloudBolt", [], (lo, step, ds))


def l_drop(role, cx, cy, r, order):
    return L(role, drop(cx, cy, r), "drop", [cx + DROP_LEAN * 2.1 * r, up(cy - 2.1 * r), cx, up(cy), order])


def l_streak(role, cx, cy, length, r, order):
    return L(role, streak(cx, cy, length, r), "drop", [cx + DROP_LEAN * length / 2, up(cy - length / 2), cx, up(cy), order])


def l_flake(role, cx, cy, r, order):
    # (its arms part 1.73 half-widths from the middle: inside that the six are one hub)
    return L(role, flake(cx, cy, r, 0.6), "flake", [cx, up(cy), order, 1.73 * 0.6])


def l_stone(role, cx, cy, r, order):
    return L(role, circle(cx, cy, r), "stone", [cx, up(cy), r, order])


# ---- skies: the parts above the precipitation --------------------------------------------------------------------------
# Every precipitation icon stands under one of four skies; the cloud and what it hides are the same in each, so a
# composition is a sky plus what falls. (cx is the cloud's middle: what falls is centred under it.)
_skies = {}


def sky(kind):
    if kind in _skies:
        return _skies[kind]
    if kind == "plain":
        s = {"cx": 12.0, "cloud": cloud(12.0, 10.6, 18.5), "behind": None}
    else:
        c = cloud(9.8, 12.0, 15.2)
        # ONE accent an icon: under a sky that rains, what falls is the subject and the sun or moon behind is ink
        if kind == "sun":
            b = l_sun("ink", 17.0, 7.0, 3.0, 4.65, 5.5, 0.85, c)
        elif kind == "moon":
            b = l_moon_cut("ink", 16.6, 6.8, 5.0, c, 4.64)
        else:   # heavy: a second cloud behind the shoulder
            b = l_cloud_back(16.4, 7.3, 11.4, c, -0.64, 1.28, "cloudBack")
        s = {"cx": 10.4, "cloud": c, "behind": b}
    _skies[kind] = s
    return s


FALL_TOP = 16.3     # nothing that falls starts above this line (the cloud's foot plus the gap)


def falls(kind, n, cx):
    """what falls under the cloud"""
    out = []
    if kind == "rain":
        if n >= 2:
            for i, (dx, dy) in enumerate(((-5.0, 0.0), (0.0, 0.3), (5.0, 0.0))):
                out.append(l_streak("weatherDrop", cx + dx, 19.4 + dy, 4.4, 1.0, i))
        else:
            spots = ((-2.7, 19.6), (2.9, 20.4)) if n == 0 else ((-5.2, 19.6), (0.2, 20.6), (5.6, 19.6))
            for i, (dx, y) in enumerate(spots):
                out.append(l_drop("weatherDrop", cx + dx, y, 1.6, i))
    elif kind == "snow":
        spots = (((0.0, 19.6, 2.9),), ((-3.4, 19.3, 2.5), (3.4, 20.0, 2.5)),
                 ((-5.6, 19.0, 2.2), (0.0, 20.3, 2.2), (5.6, 19.0, 2.2)))[n]
        for i, (dx, y, r) in enumerate(spots):
            out.append(l_flake("weatherFlake", cx + dx, y, r, i))
    elif kind == "sleet":
        if n == 0:
            out.append(l_flake("ink", cx - 3.3, 19.5, 2.5, 0))
            out.append(l_drop("weatherDrop", cx + 3.0, 20.3, 1.6, 1))
        elif n == 1:
            out.append(l_drop("weatherDrop", cx - 5.4, 20.0, 1.4, 0))
            out.append(l_flake("ink", cx + 0.1, 19.6, 2.3, 1))
            out.append(l_drop("weatherDrop", cx + 5.6, 20.0, 1.4, 2))
        else:
            out.append(l_flake("ink", cx - 5.5, 19.2, 2.2, 0))
            out.append(l_streak("weatherDrop", cx, 19.6, 4.4, 1.0, 1))
            out.append(l_flake("ink", cx + 5.5, 19.2, 2.2, 2))
    elif kind == "hail":
        if n >= 2:
            # hail in a storm: the bolt, and a stone each side of it
            out.append(l_bolt("ink", cx + 0.2, 12.4, 10.2))
            out.append(l_stone("weatherFlake", cx - 5.6, 19.4, 1.55, 0))
            out.append(l_stone("weatherFlake", cx + 5.9, 20.2, 1.55, 1))
        else:
            spots = ((-2.9, 18.8), (2.9, 20.6)) if n == 0 else ((-5.3, 18.6), (0.0, 20.7), (5.3, 18.6))
            for i, (dx, y) in enumerate(spots):
                out.append(l_stone("weatherFlake", cx + dx, y, 1.55, i))
    elif kind == "thunder":
        out.append(l_bolt("weatherBolt", cx + 0.2, 12.4, 10.2))
        if n == 1:
            out.append(l_drop("ink", cx - 5.8, 20.0, 1.35, 0))
            out.append(l_drop("ink", cx + 6.2, 20.6, 1.35, 1))
        elif n >= 2:
            out.append(l_streak("ink", cx - 5.9, 19.5, 4.4, 0.95, 0))
            out.append(l_streak("ink", cx + 5.9, 19.5, 4.4, 0.95, 1))
    return out


def precipitation(kind, n, sky_kind):
    s = sky(sky_kind)
    parts = falls(kind, n, s["cx"])
    c = s["cloud"]
    out = [s["behind"]] if s["behind"] else []
    # a bolt comes out of the cloud: it is in front, the cloud is cut round it
    bolts = [p for p in parts if p.t == "bolt"]
    out.append(bolt_cloud(c, bolts[0].spec) if bolts else L("ink", c))
    return out + parts


def compositions():
    comps = {}
    comps["clear|d"] = [l_sun("weatherSunDisc", 12, 12, 4.5, 7.1, 9.5, 1.0)]
    comps["clear|n"] = [L("weatherMoon", crescent(10.6, 13.2, 7.6, 1), "moon", [10.6, up(13.2)]),
                        L("ink", sparkle(18.3, 5.6, 3.1), "sparkle", [18.3, up(5.6), 0]),
                        L("ink", sparkle(20.2, 13.4, 1.9), "sparkle", [20.2, up(13.4), 1])]
    front = cloud(10.2, 16.4, 16.4)
    comps["partly|d"] = [l_sun("weatherSunDisc", 15.4, 8.6, 3.5, 5.55, 7.1, 0.9, front), L("ink", front)]
    comps["partly|n"] = [l_moon_cut("weatherMoon", 15.0, 8.4, 6.0, front, 5.6), L("ink", front)]
    # two clouds part: the back one slides right as the front one slides left (the frames are their distance apart)
    front = cloud(10.2, 16.0, 16.8)
    comps["cloudy"] = [l_cloud_back(16.2, 9.0, 12.2, front, -0.96, 2.4, "cloudPart"), L("ink", front, "cloudFront")]
    comps["cloud"] = [L("ink", cloud(12, 15.3, 19.4), "cloudFree", [12, up(15.3 + 0.21 * 19.4)])]
    bars = ((6.4, 17.4, 0), (3.4, 13.2, 1), (17.0, 20.6, 1), (3.6, 7.0, 2), (10.8, 20.6, 2), (6.6, 17.6, 3))
    comps["fog"] = [L("ink", capsule(x0, 5.6 + 4.3 * row, x1, 5.6 + 4.3 * row, 1.15), "bar", [row]) for x0, x1, row in bars]
    # the carved set's wind: a short line, a long one whose hook stands clear of the first, a third hooking down
    # (anchors: the line's two ends, its height and half-width, its turn: the two upper lines move together, or their
    # hooks would meet)
    comps["wind"] = [L("ink", curl(3.6, 10.1, 7.8, -2.05, 240), "curl", [3.6, 10.1, up(7.8), 0.95, 0]),
                     L("ink", curl(1.6, 18.8, 12.2, -3.0, 240), "curl", [1.6, 18.8, up(12.2), 0.95, 0]),
                     L("ink", curl(6.7, 14.2, 16.5, 2.5, 240), "curl", [6.7, 14.2, up(16.5), 0.95, 1])]
    comps["arrow"] = [L("ink", dart())]
    comps["dot"] = [L("ink", circle(12, 12, 2.6))]
    for kind in ("rain", "sleet", "snow", "hail", "thunder"):
        for n in range(3):
            for sk in ("plain", "sun", "moon", "heavy"):
                comps["%s|%d|%s" % (kind, n, sk)] = precipitation(kind, n, sk)
    return comps


# ---- tracing ------------------------------------------------------------------------------------------------------------
def thin(pts, tol):
    """Douglas-Peucker on an open run of points"""
    keep = np.zeros(len(pts), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        seg = pts[b] - pts[a]
        rel = pts[a + 1:b] - pts[a]
        ln = math.hypot(seg[0], seg[1])
        dist = np.hypot(rel[:, 0], rel[:, 1]) if ln < 1e-12 else np.abs(seg[0] * rel[:, 1] - seg[1] * rel[:, 0]) / ln
        i = int(np.argmax(dist))
        if dist[i] > tol:
            m = a + 1 + i
            keep[m] = True
            stack += [(a, m), (m, b)]
    return pts[keep]


def trace(d, tol=TOL):
    """the outline of d < 0 as contours [["M",x,y], ["L",x,y], ...], y UP"""
    out = []
    for line in contour_generator(_ax, _ax, d).lines(0.0):
        if len(line) < 8:
            continue
        closed = np.allclose(line[0], line[-1])
        pts = line[:-1] if closed else line
        # thin as two open halves, so a closed ring keeps two fixed points
        h = len(pts) // 2
        a = thin(pts[:h + 1], tol)
        b = thin(np.vstack([pts[h:], pts[:1]]), tol)
        ring = np.vstack([a[:-1], b[:-1]])
        if len(ring) < 3:
            continue
        c = []
        for i, (x, y) in enumerate(ring):
            c.append(["M" if i == 0 else "L", round(float(x), 2), round(UNITS - float(y), 2)])
        out.append(c)
    return out


def quartered(contours, cx, cy):
    """a sun's traced outline made EXACTLY the same under a quarter turn about (cx, cy): the disc's first quadrant and the
    two rays in it, each turned to the other three (the tracer thins every ray a little differently)"""
    def turn(pt, k):
        x, y = pt[1] - cx, pt[2] - cy
        for _ in range(k):
            x, y = -y, x
        return [pt[0], round(cx + x, 2), round(cy + y, 2)]

    def mid(c):
        return (sum(p[1] for p in c) / len(c), sum(p[2] for p in c) / len(c))

    disc = min(contours, key=lambda c: math.hypot(mid(c)[0] - cx, mid(c)[1] - cy))
    out = []
    arc = sorted((p for p in disc if p[1] - cx > 1e-9 and p[2] - cy >= 0),
                 key=lambda p: math.atan2(p[2] - cy, p[1] - cx))
    ring = [turn(p, k) for k in range(4) for p in arc]
    out.append([["M" if i == 0 else "L", p[1], p[2]] for i, p in enumerate(ring)])
    for c in contours:
        if c is disc:
            continue
        a = math.degrees(math.atan2(mid(c)[1] - cy, mid(c)[0] - cx))
        if -22.5 <= a < 67.5:
            out += [[turn(p, k) for p in c] for k in range(4)]
    if len(out) != len(contours):
        raise SystemExit("FAIL quartered: %d contours from %d" % (len(out), len(contours)))
    return out


def build():
    parts, comps, frames, seen, bad = {}, {}, {}, {}, []
    traced = {}

    def part_id(key, role, d, boxed=True, quarter=None):
        """the id of d's outline ("" for nothing drawn), traced once per distance array. `boxed`: it must stay inside the
        box -- a part at rest; a baked frame is drawn where its flourish puts it (weather_ink_probe.sh watches those)"""
        if d is None:
            return ""
        if id(d) in traced:
            return traced[id(d)][0]
        contours = trace(d, TOL if boxed else FRAME_TOL)
        if quarter and contours:
            contours = quartered(contours, quarter[0], quarter[1])
        inside = d < 0
        if not contours or not inside.any():
            pid = ""
        else:
            if boxed and (X[inside].min() < 0.6 or X[inside].max() > UNITS - 0.6 or Y[inside].min() < 0.6 or Y[inside].max() > UNITS - 0.6):
                bad.append("FAIL %s: a %s part leaves the box (x %.2f..%.2f, y %.2f..%.2f)"
                           % (key, role, X[inside].min(), X[inside].max(), Y[inside].min(), Y[inside].max()))
            h = hashlib.sha1(repr(contours).encode()).hexdigest()
            if h not in seen:
                seen[h] = "p%d" % len(seen)
                parts[seen[h]] = contours
            pid = seen[h]
        traced[id(d)] = (pid, d)      # the array is kept, so its id is not reused
        return pid

    for key, layers in compositions().items():
        row = []
        accents = {l.role for l in layers if l.role != "ink"}
        if len(accents) > 1:
            raise SystemExit("FAIL %s has %d accents: %s" % (key, len(accents), sorted(accents)))
        for l in layers:
            pid = part_id(key, l.role, l.d, True, l.quarter)
            if pid == "":
                raise SystemExit("FAIL %s has an empty part (%s)" % (key, l.role))
            fname = ""
            if l.frames:
                start, step, ds = l.frames
                ids = [part_id(key + " frame %d" % i, l.role, d, False) for i, d in enumerate(ds)]
                h = hashlib.sha1(repr((start, step, ids)).encode()).hexdigest()
                if h not in seen:
                    seen[h] = "f%d" % len(frames)
                    frames[seen[h]] = [round(start, 4), round(step, 4), ids]
                fname = seen[h]
            row.append([pid, l.role, l.t, [round(float(v), 3) for v in l.a], fname])
        comps[key] = row
    if bad:
        raise SystemExit("\n".join(bad))
    return parts, comps, frames


def render(parts, comps, frames):
    def js(v):
        if isinstance(v, str):
            return '"%s"' % v
        if isinstance(v, (int, float)):
            return ("%.4f" % v).rstrip("0").rstrip(".")
        return "[" + ",".join(js(x) for x in v) + "]"

    lines = [".pragma library", "",
             "// GENERATED by tools/dev/weather_ink_parts.py -- do not edit; the set is drawn there.",
             "// The ink weather icons on a %d-unit grid (y up, origin bottom-left, GlyphOutline.js's contour format):" % UNITS,
             "//   PARTS[id]    contours",
             "//   COMPS[key]   [[partId, role, type, anchors, frames], ...] back to front: role \"ink\" or the accent's theme token;",
             "//                type and anchors are what the part's flourish moves it by (WeatherInkPose.js)",
             "//   FRAMES[name] [from, step, [partId per frame]]: a part that is cut by the one in front, baked along its flourish",
             "", "var UNITS = %d;" % UNITS, "", "var PARTS = {"]
    for pid, contours in parts.items():
        lines.append("    %s: %s," % (pid, js(contours)))
    lines += ["};", "", "var FRAMES = {"]
    for name, f in frames.items():
        lines.append("    %s: %s," % (name, js(f)))
    lines += ["};", "", "var COMPS = {"]
    for key, row in comps.items():
        lines.append('    "%s": %s,' % (key, js(row)))
    lines += ["};", ""]
    return "\n".join(lines)


ACCENTS = {"weatherSunDisc": "#FFC634", "weatherMoon": "#F5AE3A", "weatherDrop": "#3D8FF2", "weatherFlake": "#36BCE6",
           "weatherBolt": "#FFAA1F"}


def sheet(parts, comps, path):
    """a quick look without a shell: every composition at 18 / 24 / 48 / 88 px on eva light's surface (PIL, 8x supersampled)"""
    from PIL import Image, ImageDraw
    sizes, ss, cols = (18, 24, 48, 88), 8, 6
    cw, ch = sum(sizes) + 14 * (len(sizes) + 1), 88 + 34
    keys = list(comps)
    rows = (len(keys) + cols - 1) // cols
    img = Image.new("RGB", (cols * cw, rows * ch), "#EAEDF5")
    for i, key in enumerate(keys):
        ox, oy = (i % cols) * cw + 14, (i // cols) * ch + 6
        ImageDraw.Draw(img).text((ox, oy + 92), key, fill="#5D5D5F")
        for size in sizes:
            big = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
            k = size * ss / UNITS
            for pid, role in [(e[0], e[1]) for e in comps[key]]:
                layer = Image.new("L", big.size, 0)
                dr = ImageDraw.Draw(layer)
                # contours of one part: outlines add, holes (wound the other way) take away
                polys = []
                for c in parts[pid]:
                    pts = [(x * k, (UNITS - y) * k) for _, x, y in c]
                    area = sum(pts[j][0] * pts[(j + 1) % len(pts)][1] - pts[(j + 1) % len(pts)][0] * pts[j][1]
                               for j in range(len(pts)))
                    polys.append((area, pts))
                outer = max(polys, key=lambda q: abs(q[0]))[0]
                for area, pts in sorted(polys, key=lambda q: -abs(q[0])):
                    dr.polygon(pts, fill=255 if area * outer > 0 else 0)
                big.paste(Image.new("RGBA", big.size, "#6F6F72" if role == "ink" else ACCENTS[role]), (0, 0), layer)
            small = big.resize((size, size), Image.LANCZOS)
            img.paste(small, (ox, oy + (88 - size) // 2), small)
            ox += size + 14
    img.save(path)
    print("sheet %s" % path)


def main():
    parts, comps, frames = build()
    text = render(parts, comps, frames)
    if "--sheet" in sys.argv:
        sheet(parts, comps, sys.argv[sys.argv.index("--sheet") + 1])
        return 0
    if "--check" in sys.argv:
        old = open(OUT).read() if os.path.exists(OUT) else ""
        if old != text:
            print("WEATHER_INK_PARTS RESULT FAIL (stale: %s)" % OUT)
            return 1
        print("WEATHER_INK_PARTS RESULT PASS (%d compositions, %d parts, %d frame sets)" % (len(comps), len(parts), len(frames)))
        return 0
    with open(OUT, "w") as f:
        f.write(text)
    npts = sum(len(c) for cs in parts.values() for c in cs)
    print("wrote %s: %d compositions, %d parts, %d frame sets, %d points, %d bytes"
          % (OUT, len(comps), len(parts), len(frames), npts, len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
