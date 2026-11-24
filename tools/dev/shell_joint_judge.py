#!/usr/bin/env python3
"""The seam between the shell's joint and a tiled window's corner, read off two screenshots (tools/dev/shell_joint_probe.sh).

  shell_joint_judge.py <black.png> <white.png> --box "X Y W H" --hs <s> --rounding <r> --border <b> [--label <text>]
                       [--seam-arc <px>] [--seam-straight <px>] [--cover-share <f>] [--cover-min <px>] [--json]

THE TWO SHOTS are one state over a black and over a white compositor background. Per pixel, (white - black) / 255 is the share of the
background that shows there -- exact whatever is drawn over it, antialiasing included --, and in the black one what is left of R after the
shell's own (grey) share is taken out is the share of Hyprland's border (the probe makes it pure red; the window is pure green).

THE GEOMETRY is Hyprland's own (CHyprBorderDecoration): the window's box `X Y W H` (hyprctl's `at` / `size`, layout px) scaled by the output's
scale `hs` and ROUNDED to whole device px, the border round(b x hs) device px outside it, the corner an arc of (r + b) x hs about a centre that
far inside the border's outer corner.

WHAT IS READ, per corner, on rays from the arc's centre through 1 .. 89 degrees (and across each straight edge at 24 places):
  seam     the background along the ray from the border's middle outward: device px of wallpaper between the border and the shell
  border   the border along the ray: device px of it that show (round(b x hs) on a straight; Hyprland's own arc reads ~0.1 thinner)
A joint that fits has no seam (the two antialiased arcs never leave the background between them) and the border whole (the shell's ring,
which is above the window, does not lie over it). The tolerances are device px along one ray, the worst ray of the four corners.

Prints one line `<label> PASS|FAIL (...)`; exit 0 / 1. A picture with no border found where Hyprland says it is fails as that.
"""
import argparse
import json
import math
import sys

import numpy as np
from PIL import Image


def bil(a, x, y):
    """`a` sampled at the points (x, y), pixel centres at index + 0.5."""
    x = np.clip(x - 0.5, 0, a.shape[1] - 1.001)
    y = np.clip(y - 0.5, 0, a.shape[0] - 1.001)
    i = np.floor(x).astype(int)
    j = np.floor(y).astype(int)
    fx = x - i
    fy = y - j
    return a[j, i] * (1 - fx) * (1 - fy) + a[j, i + 1] * fx * (1 - fy) + a[j + 1, i] * (1 - fx) * fy + a[j + 1, i + 1] * fx * fy


def maps(black, white):
    """(the background's share, the border's share) per pixel."""
    b = np.asarray(Image.open(black).convert("RGB"), float)
    w = np.asarray(Image.open(white).convert("RGB"), float)
    if b.shape != w.shape:
        raise SystemExit("the two shots are not one size")
    t = np.clip((w - b).mean(axis=2) / 255.0, 0, 1)
    # the shell's greys carry R ~ 0.955 B (eva light: surface EAEDF5, ring CED1D7; dark: the same within a level), the window's green none
    red = np.clip((b[..., 0] - 0.955 * b[..., 2]) / 255.0, 0, 1)
    return t, red


def measure(black, white, box, hs, rounding, border):
    t, red = maps(black, white)
    bx, by, bw, bh = box
    rnd = lambda v: math.floor(v + 0.5)             # std::round, not Python's half-to-even (2.5 -> 3)
    bd = rnd(border * hs)
    # Hyprland's rounded surface box, and the border's outer box round it
    left, top = rnd(bx * hs) - bd, rnd(by * hs) - bd
    right, bottom = rnd((bx + bw) * hs) + bd, rnd((by + bh) * hs) + bd
    ro = (rounding + border) * hs
    step = 0.05
    out = {"bd": bd, "ro": ro, "box": [left, top, right, bottom], "arcs": {}, "straights": {}}
    corners = {"tl": (left + ro, top + ro, -1, -1), "tr": (right - ro, top + ro, 1, -1), "bl": (left + ro, bottom - ro, -1, 1), "br": (right - ro, bottom - ro, 1, 1)}
    reach = ro * math.sqrt(2) + 4 * max(1.0, hs) if rounding < 1 else ro + 6 * max(1.0, hs)
    for name, (cx, cy, sx, sy) in corners.items():
        seams, reds, angs = [], [], []
        for deg in np.arange(1.0, 89.01, 1.0):
            th = math.radians(deg)
            rs = np.arange(max(0.0, ro - bd - 3), reach, step)
            x = cx + sx * rs * math.cos(th)
            y = cy + sy * rs * math.sin(th)
            ok = (x > 1) & (y > 1) & (x < t.shape[1] - 1) & (y < t.shape[0] - 1)
            tv = bil(t, x, y) * ok
            rv = bil(red, x, y) * ok
            seams.append(float((tv * (rs > ro - bd / 2.0)).sum() * step))
            reds.append(float(rv.sum() * step))
            angs.append(float(deg))
        i, j = int(np.argmax(seams)), int(np.argmin(reds))
        out["arcs"][name] = {"seam_max": seams[i], "seam_at": angs[i], "seam_mean": float(np.mean(seams)), "red_min": reds[j], "red_at": angs[j],
                             "red_mean": float(np.mean(reds))}
    # the straights: 24 places along each edge, clear of the corners
    pad = ro + 12 * hs
    sides = {"top": (None, top, 0, -1), "bottom": (None, bottom, 0, 1), "left": (left, None, -1, 0), "right": (right, None, 1, 0)}
    for name, (ex, ey, nx, ny) in sides.items():
        seams, reds = [], []
        for f in np.linspace(0.0, 1.0, 24):
            ds = np.arange(-bd - 3.0, 8.0 * max(1.0, hs), step)        # along the outward normal, 0 at the border's outer edge
            if ex is None:
                # (the top is read under the islands only, 100 px at each end: between them the window stands under open wallpaper)
                span = min(100.0 * hs, (right - left - 2 * pad) / 2.0)
                along = f * 2 * span if f <= 0.5 else (right - left - 2 * pad) - (1 - f) * 2 * span
                x = np.full_like(ds, left + pad + (along if name == "top" else f * (right - left - 2 * pad))) + 0.37
                y = ey + ny * ds
            else:
                x = ex + nx * ds
                y = np.full_like(ds, top + pad + f * (bottom - top - 2 * pad)) + 0.37
            ok = (x > 1) & (y > 1) & (x < t.shape[1] - 1) & (y < t.shape[0] - 1)
            seams.append(float((bil(t, x, y) * ok * (ds > -bd / 2.0)).sum() * step))
            reds.append(float((bil(red, x, y) * ok).sum() * step))
        out["straights"][name] = {"seam_max": max(seams), "red_min": min(reds)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("black")
    ap.add_argument("white")
    ap.add_argument("--box", required=True)
    ap.add_argument("--hs", type=float, default=1.0)
    ap.add_argument("--rounding", type=float, required=True)
    ap.add_argument("--border", type=float, required=True)
    ap.add_argument("--label", default="joint")
    ap.add_argument("--seam-arc", type=float, default=0.15)
    ap.add_argument("--seam-straight", type=float, default=0.08)
    ap.add_argument("--cover-share", type=float, default=0.27)
    ap.add_argument("--cover-min", type=float, default=0.6)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    res = measure(a.black, a.white, [float(v) for v in a.box.split()], a.hs, a.rounding, a.border)
    if a.json:
        print(json.dumps(res))
        return 0
    bd = res["bd"]
    bad, parts = [], []
    for side, v in res["straights"].items():
        if v["red_min"] < bd - 0.6:
            bad.append(f"border FAIL ({side}: {v['red_min']:.2f} px of the border's {bd} show on the straight -- no border where Hyprland puts it, or the ring over it)")
        if v["seam_max"] > a.seam_straight:
            bad.append(f"seam FAIL ({side}: {v['seam_max']:.2f} px of background between the ring and the border on the straight, want under {a.seam_straight:g})")
    # Hyprland's own arc reads up to 0.11 px thinner than its straights (measured on a window with no shell: 3.89 of 4); the ring may take
    # a share of the border's width (the overlap is compositor px, so its cover in device px grows with the scale as the border does: 21 % at
    # every scale measured), and for a thin border what two antialiased edges on one pixel take anyway
    floor = bd - 0.15 - max(a.cover_min, a.cover_share * bd)
    for c, v in res["arcs"].items():
        parts.append(f"{c} seam {v['seam_max']:.2f}@{v['seam_at']:.0f} border {v['red_min']:.2f}@{v['red_at']:.0f}")
        if v["seam_max"] > a.seam_arc:
            bad.append(f"seam FAIL (arc {c}: {v['seam_max']:.2f} px of background at {v['seam_at']:.0f} deg, want under {a.seam_arc:g}; mean {v['seam_mean']:.2f})")
        if a.rounding >= 1 and v["red_min"] < floor:
            bad.append(f"border FAIL (arc {c}: {v['red_min']:.2f} px of the border's {bd} show at {v['red_at']:.0f} deg, want {floor:.2f} -- the ring lies over it)")
    if bad:
        print(f"    {a.label} " + "; ".join(bad))
        return 1
    print(f"    {a.label} PASS (device px, worst ray per corner: " + "; ".join(parts) + f"; border {bd} px)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
