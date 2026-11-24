#!/usr/bin/env python3
"""Judge of osd_pill_open_probe.sh: reads OUT/opo.log (one `OPO f <kind> <ms> <boxW> <boxH> <contentOpacity> <pillT>` per frame, design
px) and OUT/ink_<kind>_{content,bare}.png (the pill at rest with and without its content; K device px per design px).

  content readable   contentOpacity >= 0.5 within 260 ms of present(), >= 0.99 within 360 ms
  one motion         between pillT 0.4 and 1.6 no frame's step of pillT falls under 0.004 (OutCubic ending at speed 0 and the next
                     starting: the old open stood still)
  covers the ink     on EVERY frame with contentOpacity > 0 every ink pixel of the kind (the diff of the two pngs) lies inside the
                     capsule (the frame's boxW x boxH, a stadium) with >= 2 design px to spare
"""
import math, os, sys
from PIL import Image, ImageChops

out, k, arm = sys.argv[1], float(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else ""
# p: 0 OPO 1 f 2 kind 3 ms 4 boxW 5 boxH 6 cf 7 pillT  -> len 8
frames = {}
for line in open(os.path.join(out, "opo.log")):
    p = line.split()
    if len(p) == 8 and p[1] == "f":
        frames.setdefault(p[2], []).append(dict(ms=float(p[3]), w=float(p[4]), h=float(p[5]), cf=float(p[6]), t=float(p[7])))

fails = 0
def say(ok, name, detail=""):
    global fails
    if not ok:
        fails += 1
    print("OPJ %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [" + detail + "]"))

def ink_of(kind):
    a = Image.open(os.path.join(out, "ink_%s_content.png" % kind)).convert("RGB")
    b = Image.open(os.path.join(out, "ink_%s_bare.png" % kind)).convert("RGB")
    d = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
    bb = d.getbbox()
    return d, bb

def margin(x, y, bw, bh):
    """design-px distance an ink pixel centre (x right of the pill's centre, y below its middle) lies inside the stadium."""
    r = min(bw, bh) / 2
    dx = max(abs(x) - (bw / 2 - r), 0)
    dy = max(abs(y) - (bh / 2 - r), 0)
    return r - math.hypot(dx, dy)

worst_fade = {}
for kind, fr in frames.items():
    fr.sort(key=lambda f: f["ms"])
    t50 = next((f["ms"] for f in fr if f["cf"] >= 0.5), None)
    t99 = next((f["ms"] for f in fr if f["cf"] >= 0.99), None)
    say(t50 is not None and t50 <= 260 + 16, "%s: content readable (>= 0.5) by 260 ms" % kind, "at %s" % t50)
    say(t99 is not None and t99 <= 360 + 16, "%s: content in (>= 0.99) by 360 ms" % kind, "at %s" % t99)
    steps = [(b["t"] - a["t"]) for a, b in zip(fr, fr[1:]) if 0.4 < a["t"] < 1.6 and a["ms"] > 0]
    say(not steps or min(steps) >= 0.004, "%s: the open is one motion (smallest step of pillT between 0.4 and 1.6)" % kind,
        "%.5f" % (min(steps) if steps else 0))
    d, bb = ink_of(kind)
    if bb is None:
        say(False, "%s: ink found" % kind, "the pose with and without content are the same picture")
        continue
    W, H = d.size
    px = d.load()
    # the pill's centre: the middle of the final frame's box at the stage's place (x centred, y = 12 + H/2)
    last = fr[-1]
    cx = W / k / 2
    cy = 12 + last["h"] / 2
    pts = []
    for y in range(bb[1], bb[3]):
        xs = [x for x in range(bb[0], bb[2]) if px[x, y]]
        if xs:
            for x in (xs[0], xs[-1] + 1):
                pts.append(((x / k - cx) * (1 if x / k >= cx else 1), (y + 0.5) / k - cy))
    # the nearest ink to the edge, for each frame with any content showing
    worst = 1e9
    wms = None
    for f in fr:
        if f["cf"] <= 0:
            continue
        m = min(margin(x, y, f["w"], f["h"]) for x, y in pts)
        if m < worst:
            worst, wms = m, f["ms"]
    # the least share of the widening that covers the ink (the style's pillFadeAt must be at or past the largest of these)
    lo, hi = 0.0, 1.0
    for _ in range(24):
        m = (lo + hi) / 2
        if min(margin(x, y, 14 + (last["w"] - 14) * m, last["h"]) for x, y in pts) >= 2:
            hi = m
        else:
            lo = m
    print("OPJ info %s: the ink needs the widening %.3f done" % (kind, hi))
    say(worst >= 2 - 0.05, "%s: the capsule covers the ink with >= 2 px on every frame the content shows" % kind,
        "worst %.2f px at %s ms" % (worst, wms))
print("OSDPILLOPEN RESULT %s (%d fails)" % ("FAIL" if fails else "PASS", fails))
sys.exit(1 if fails else 0)
