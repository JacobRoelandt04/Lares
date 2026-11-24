#!/usr/bin/env python3
"""aerial_scene_pixels.py -- the pixel half of aerial_scene_probe.sh (round 3): judges the pictures tools/dev/qml/aerial_scene_probe.qml wrote ($OUT/px_*.png) by the rectangles it printed
(`AP RECT <picture> <what> x0 y0 x1 y1`, `AP POLY <picture> <what> x,y ...`, `AP HUE ...`, read from the probe's log).

    aerial_scene_pixels.py <outdir> <probe.log>      prints `PX <check> PASS|FAIL <why>` lines and `PX RESULT PASS|FAIL`

  names-on-the-board     the board layer alone against the SAME board with its silkscreen texture taken away: every carved name's box differs (the shader draws it), and nothing differs
                         outside the names' boxes, the courtyards' outlines, the unit cells and the latches' faces (no other ink is the silk's)
  unit-<which>           the engraved unit follows `ratesVariant` / `usageVariant`: the picture changes inside that label's cell and nowhere else (a whole text; the facts' units)
  emblem-<radio>         a latch's emblem is lit in its radio's hue only while that radio is on (hue pixels on the latch's face: some on, none off, none of the other radio's hue)
  glow-card-masks        in airplane the card is up and the pulse trains stay hidden under its projected box: no light inside it, light elsewhere (so the check can see)
  screw-turns            the screw's slot turns with the lift: on the head's top (blueprint ink) the slot a whole turn on is mirror-symmetric about the head's vertical, as
                         at rest, and 22.5 degrees past a quarter it is not (its asymmetry several times the rest's)
"""
import colorsys
import glob
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFilter

out, logp = sys.argv[1], sys.argv[2]
log = open(logp, errors="replace").read()
rects, polys, hues = {}, {}, {}
for m in re.finditer(r"AP RECT (\S+) (\S+) ([-\d.]+) ([-\d.]+) ([-\d.]+) ([-\d.]+)", log):
    rects.setdefault(m.group(1), {})[m.group(2)] = [float(m.group(i)) for i in range(3, 7)]
for m in re.finditer(r"AP POLY (\S+) (\S+) ([-\d.,\s]+)", log):
    polys.setdefault(m.group(1), {})[m.group(2)] = [tuple(float(v) for v in p.split(",")) for p in m.group(3).split()]
m = re.search(r"AP HUE wifi ([\d. ]+) bt ([\d. ]+)", log)
if m:
    hues = {"wifi": [float(v) for v in m.group(1).split()], "bt": [float(v) for v in m.group(2).split()]}

bad = []


def check(name, ok, why=""):
    print("PX %s %s %s" % (name, "PASS" if ok else "FAIL", why))
    if not ok:
        bad.append(name)


def load(name):
    p = os.path.join(out, "px_%s.png" % name)
    if not os.path.exists(p):
        return None
    bg = Image.new("RGBA", Image.open(p).size, (255, 255, 255, 255))
    return Image.alpha_composite(bg, Image.open(p).convert("RGBA")).convert("RGB")


def diffmask(a, b, tol=2):
    """the pixels where two pictures of one size differ by more than tol in any channel"""
    w, h = a.size
    pa, pb = a.load(), b.load()
    return {(x, y) for y in range(h) for x in range(w) if max(abs(pa[x, y][k] - pb[x, y][k]) for k in range(3)) > tol}


def inside(pts, r):
    return {p for p in pts if r[0] <= p[0] <= r[2] and r[1] <= p[1] <= r[3]}


# ---- the names ----
A, B = load("names_a"), load("names_b")
if A is None or B is None or A.size != B.size:
    check("names-on-the-board", False, "no pictures")
else:
    d = diffmask(A, B)
    R = rects.get("names", {})
    names = {k: v for k, v in R.items() if k.startswith("name:")}
    allow = [v for k, v in R.items() if k.startswith("allow:")] + list(names.values())
    thin = {k: len(inside(d, v)) for k, v in names.items()}
    weak = [k + "=" + str(n) for k, n in thin.items() if n < 12]
    outside = {p for p in d if not any(r[0] - 1 <= p[0] <= r[2] + 1 and r[1] - 1 <= p[1] <= r[3] + 1 for r in allow)}
    check("names-on-the-board", len(names) >= 10 and not weak and len(outside) <= 2,
          "%d names, %d differing px; names with under 12 px: %s; px outside every allowed box: %d %s" % (len(names), len(d), weak or "none", len(outside), sorted(outside)[:3]))

# ---- the units ----
base = load("names_a")
for pic, want in (("unit_rates", {"cell:rates"}), ("unit_usage", {"cell:usage"}), ("unit_facts", {"cell:rates", "cell:usage"})):
    img = load(pic)
    R = rects.get(pic, {})
    if img is None or base is None or not R:
        check("unit-" + pic[5:], False, "no picture / rectangles")
        continue
    d = diffmask(base, img)
    cells = {k: v for k, v in R.items() if k.startswith("cell:")}
    in_want = sum(len(inside(d, v)) for k, v in cells.items() if k in want)
    in_each = [k + "=" + str(len(inside(d, v))) for k, v in cells.items() if k in want]
    anywhere = [p for p in d if not any(r[0] - 1 <= p[0] <= r[2] + 1 and r[1] - 1 <= p[1] <= r[3] + 1 for k, r in cells.items() if k in want)]
    check("unit-" + pic[5:], all(int(e.split("=")[1]) >= 10 for e in in_each) and not anywhere,
          "changed px in the cell(s) %s; elsewhere %d %s" % (in_each, len(anywhere), anywhere[:3]))

# ---- the emblems ----


def hue_px(img, rect, rgb):
    """pixels of the rect whose hue is the radio's (within 22 degrees, saturated, not dark)"""
    h0 = colorsys.rgb_to_hsv(*rgb)[0]
    n = 0
    px = img.load()
    x0, y0, x1, y1 = [int(round(v)) for v in rect]
    for y in range(max(0, y0), min(img.size[1], y1 + 1)):
        for x in range(max(0, x0), min(img.size[0], x1 + 1)):
            r, g, b = [c / 255.0 for c in px[x, y]]
            h, s, v = colorsys.rgb_to_hsv(r, g, b)
            dh = min(abs(h - h0), 1 - abs(h - h0))
            if dh < 0.06 and s >= 0.25 and v >= 0.3:
                n += 1
    return n


state = {"wifi": (1, 0), "bt": (0, 1), "off": (0, 0), "both": (1, 1)}
cnt = {}
for st in state:
    img = load("emblem_" + st)
    R = rects.get("emblem_" + st, {})
    if img is None or not R or not hues:
        cnt = None
        break
    for radio, lever in (("wifi", "dipWifi"), ("bt", "dipBt")):
        for hue in ("wifi", "bt"):
            cnt[(st, radio, hue)] = hue_px(img, R[lever], hues[hue])
if cnt is None:
    check("emblem-hue", False, "no pictures / hues")
else:
    for radio in ("wifi", "bt"):
        on = [cnt[(st, radio, radio)] for st in state if state[st][0 if radio == "wifi" else 1]]
        off = [cnt[(st, radio, radio)] for st in state if not state[st][0 if radio == "wifi" else 1]]
        other = "bt" if radio == "wifi" else "wifi"
        cross = [cnt[(st, radio, other)] for st in state]
        check("emblem-" + radio, min(on) >= 8 and max(off) == 0 and max(cross) == 0,
              "%s-hue px on its latch: radio on %s, radio off %s; the other radio's hue on it: %s" % (radio, on, off, cross))

# ---- the glow under the lifted card ----
tot_in, tot_out, n_pics = 0, 0, 0
for i in range(8):
    p = os.path.join(out, "px_glowt%d.png" % i)
    P = polys.get("glow_%d" % i, {}).get("card")
    if not os.path.exists(p) or not P:
        continue
    im = Image.open(p).convert("RGBA")
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).polygon(P, fill=255)
    mask = mask.filter(ImageFilter.MinFilter(5))
    al = im.getchannel("A")
    ap, mp = al.load(), mask.load()
    w, h = im.size
    n_in = sum(1 for y in range(h) for x in range(w) if mp[x, y] and ap[x, y] >= 12)
    n_out = sum(1 for y in range(h) for x in range(w) if not mp[x, y] and ap[x, y] >= 12)
    tot_in += n_in
    tot_out += n_out
    n_pics += 1
check("glow-card-masks", n_pics == 4 and tot_in == 0 and tot_out >= 400, "%d pictures; lit px inside the card's projected box %d (want 0), elsewhere %d (the light is there)" % (n_pics, tot_in, tot_out))

# ---- the screw's turn ----
def head_asym(name):
    im = load(name)
    r = rects.get(name, {}).get("head")
    if im is None or not r:
        return None
    x0, y0, x1, y1 = r
    # the head's top face: the upper part of the head cylinder's box (its sides and the shaft are below), cut to whole pixels about the middle
    cx = (x0 + x1) / 2.0
    half = int((x1 - x0) / 2.0) - 1
    top = im.crop((int(round(cx)) - half, int(y0), int(round(cx)) + half, int(y0 + (x1 - x0) * 0.48))).convert("L")
    mir = top.transpose(Image.FLIP_LEFT_RIGHT)
    a, b = top.load(), mir.load()
    w, h = top.size
    d = [abs(a[x, y] - b[x, y]) for y in range(h) for x in range(w)]
    return sum(d) / float(len(d)), sum(1 for v in d if v > 40)


rest, turn = head_asym("screw_rest"), head_asym("screw_turn")
if rest is None or turn is None:
    check("screw-turns", False, "missing picture or head rect (rest %s, turn %s)" % (rest, turn))
else:
    check("screw-turns", turn[0] > 2.5 * max(rest[0], 0.5) and turn[1] >= 12,
          "mean |head - mirror| at a whole turn %.2f (%d px > 40), 22.5 degrees past a quarter %.2f (%d px > 40): want the turned one > 2.5 x" % (rest[0], rest[1], turn[0], turn[1]))

print("PX RESULT " + ("FAIL (%s)" % ", ".join(bad) if bad else "PASS"))
sys.exit(1 if bad else 0)
