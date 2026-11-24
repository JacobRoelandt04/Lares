#!/usr/bin/env python3
"""fade_edges.py -- judge tools/dev/qml/fade_edges_probe.qml's picture: does every band hide what its clip lets through?

    tools/dev/fade_edges.py <png> <log> [--origin X,Y] [--label TEXT]

The probe put a MAGENTA sheet over every site's whole content and scrolled it so both bands are fully on; its CELL lines say
where each dressing stands in the window's DEVICE px. Around each band's OUTER edge (the clip's edge, where the band is opaque) a
pixel that is more than LEAK_SHARE magenta is content the clip let through and the band did not cover. `--origin` is where the
window's (0, 0) is in the PNG (a screenshot of a real window: tools/dev/fade_edges_probe.sh finds the window's corner marker).

Prints one line per band end that was on (`ok` / `LEAK`), a table per site, and `FADE_EDGES <label> PASS|FAIL`; exits 1 on a leak or
when nothing was judged.
"""
import json
import math
import re
import sys

import numpy as np
from PIL import Image

LEAK_SHARE = 0.30       # a band's last device row is >= 96 % ground; a leaked row is the sheet itself
SIDE_MARGIN = 20        # device px kept off each end of a band's length (the box's corners, the re-cut rings)
REACH_IN = 2            # device rows read inside the edge ...
REACH_OUT = 3           # ... and outside it


def magenta_share(px, ground):
    """How much of the magenta sheet a pixel holds, against the band's ground: (min(R,B) - G), normalised."""
    g = float(min(ground[0], ground[2]) - ground[1])
    v = np.minimum(px[..., 0], px[..., 2]) - px[..., 1]
    return (v - g) / max(1.0, 255.0 - g)


def parse_color(s):
    m = re.match(r"#([0-9a-fA-F]{2})?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$", s.strip())
    if not m:
        return (230, 233, 240)
    return (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))


def main():
    args = sys.argv[1:]
    png, log = args[0], args[1]
    ox = oy = 0
    label = ""
    if "--origin" in args:
        ox, oy = (int(v) for v in args[args.index("--origin") + 1].split(","))
    if "--label" in args:
        label = args[args.index("--label") + 1]
    Image.MAX_IMAGE_PIXELS = None       # a sweep of 64 popups is one large picture; it is read a band's patch at a time
    img = Image.open(png).convert("RGB")
    W, H = img.size

    def patch_of(x0, y0, x1, y1):
        return np.array(img.crop((x0, y0, x1, y1))).astype(float)
    cells = []
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.search(r"CELL (\{.*\})", line)
        if m:
            cells.append(json.loads(m.group(1)))
    judged = leaks = 0
    table = {}
    for c in cells:
        if "error" in c:
            print("FAIL cell %d (%s): %s" % (c["i"], c["site"], c["error"]))
            leaks += 1
            continue
        ground = parse_color(c["ground"])
        x0, y0, x1, y1 = c["x0"] + ox, c["y0"] + oy, c["x1"] + ox, c["y1"] + oy
        ends = (("head", c["head"]), ("foot", c["foot"]))
        for name, on in ends:
            if on < 0.999:
                print("skip %-14s %-4s phase %.3f:%.3f (band at %.2f, not fully on)" % (c["site"], name, c["fx"], c["fy"], on))
                continue
            if c["horiz"]:
                edge = x0 if name == "head" else x1
                lo, hi = int(math.floor(y0)) + SIDE_MARGIN, int(math.ceil(y1)) - SIDE_MARGIN
                cols = range(int(math.floor(edge)) - REACH_OUT, int(math.floor(edge)) + REACH_IN) if name == "head" \
                    else range(int(math.ceil(edge)) - REACH_IN, int(math.ceil(edge)) + REACH_OUT)
                cols = [x for x in cols if 0 <= x < W]
                patch = patch_of(cols[0], max(0, lo), cols[-1] + 1, min(H, hi))
                share = magenta_share(patch, ground)
                bad = np.argwhere(share > LEAK_SHARE)
                where = sorted({int(cols[0] + b[1]) for b in bad})
                axis = "cols"
            else:
                edge = y0 if name == "head" else y1
                lo, hi = int(math.floor(x0)) + SIDE_MARGIN, int(math.ceil(x1)) - SIDE_MARGIN
                rows = range(int(math.floor(edge)) - REACH_OUT, int(math.floor(edge)) + REACH_IN) if name == "head" \
                    else range(int(math.ceil(edge)) - REACH_IN, int(math.ceil(edge)) + REACH_OUT)
                rows = [y for y in rows if 0 <= y < H]
                patch = patch_of(max(0, lo), rows[0], min(W, hi), rows[-1] + 1)
                share = magenta_share(patch, ground)
                bad = np.argwhere(share > LEAK_SHARE)
                where = sorted({int(rows[0] + b[0]) for b in bad})
                axis = "rows"
            judged += 1
            key = (c["site"], name)
            t = table.setdefault(key, [0, 0, 0])
            t[0] += 1
            if len(bad):
                leaks += 1
                t[1] += 1
                t[2] += len(bad)
                print("LEAK %-14s %-4s phase %.3f:%.3f edge %.3f dev px: %d px of content past the band, %s %s"
                      % (c["site"], name, c["fx"], c["fy"], edge - (ox if c["horiz"] else oy), len(bad), axis,
                         [w - (ox if c["horiz"] else oy) for w in where]))
            else:
                print("ok   %-14s %-4s phase %.3f:%.3f edge %.3f dev px" % (c["site"], name, c["fx"], c["fy"], edge - (ox if c["horiz"] else oy)))
    print("TABLE site end phases leaking/judged px")
    for (site, name), (n, nb, px) in sorted(table.items()):
        print("TABLE %-14s %-4s %d/%d %d" % (site, name, nb, n, px))
    ok = judged > 0 and leaks == 0
    print("FADE_EDGES %s%s (%d band ends judged, %d leaking)" % (label + " " if label else "", "PASS" if ok else "FAIL", judged, leaks))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
