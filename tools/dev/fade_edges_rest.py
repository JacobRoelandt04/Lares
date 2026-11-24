#!/usr/bin/env python3
"""fade_edges_rest.py -- the seal moves nothing but the pixels it is for: a before/after of the fade sites AT REST.

    tools/dev/fade_edges_rest.py <base dir>[,<base dir 2>...] <new dir> <site> ...

Both dirs are `REST=1 tools/dev/fade_edges_probe.sh` runs (nothing armed, plain-raster text): <site>.png and <site>.clean.log
with the CELL lines. A pixel that differs (any channel, on opaque ground) is allowed only on a dressing's EDGE LINE -- the device
row or column an outer edge or a side passes through, where an edge on a tie lets a seal cover one more pixel. Anything else is a
change the fix had no business making. Prints the counts per site and `FADE_EDGES_REST RESULT PASS|FAIL`.

The stocks rows place a figure's glyph a column apart from one process to the next (run-to-run, the same tree): with several
base runs a pixel differs only where the new picture differs from EVERY base -- the base's own noise is not a change.
"""
import json
import math
import re
import sys

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def cells(log):
    out = []
    for line in open(log, encoding="utf-8", errors="replace"):
        m = re.search(r"CELL (\{.*\})", line)
        if m:
            c = json.loads(m.group(1))
            if "error" not in c:
                out.append(c)
    return out


def main():
    bases, new, sites = sys.argv[1].split(","), sys.argv[2], sys.argv[3:]
    bad_total = 0
    for site in sites:
        b = np.array(Image.open("%s/%s.png" % (new, site)).convert("RGB")).astype(int)
        diff = None
        for base in bases:
            a = np.array(Image.open("%s/%s.png" % (base, site)).convert("RGB")).astype(int)
            if a.shape != b.shape:
                print("FAIL %s: the pictures differ in size %s %s" % (site, a.shape, b.shape))
                diff = None
                break
            d = np.abs(a - b).max(axis=2) > 0
            diff = d if diff is None else (diff & d)
        if diff is None:
            bad_total += 1
            continue
        allowed = np.zeros(diff.shape, dtype=bool)
        H, W = diff.shape
        cs = cells("%s/%s.clean.log" % (new, site))
        for c in cs:
            x0, y0, x1, y1 = c["x0"], c["y0"], c["x1"], c["y1"]
            # the device rows / columns each edge line passes through (a tie is a pixel centre ON the line: that pixel, and its
            # neighbour for float noise), along the edge's whole length and a pixel past each end
            for e in (y0, y1):
                r0, r1 = max(0, int(math.floor(e - 0.51))), min(H, int(math.floor(e + 0.51)) + 1)
                allowed[r0:r1, max(0, int(x0) - 1):min(W, int(math.ceil(x1)) + 2)] = True
            for e in (x0, x1):
                k0, k1 = max(0, int(math.floor(e - 0.51))), min(W, int(math.floor(e + 0.51)) + 1)
                allowed[max(0, int(y0) - 1):min(H, int(math.ceil(y1)) + 2), k0:k1] = True
        n_diff = int(diff.sum())
        n_off = int((diff & ~allowed).sum())
        n_on = n_diff - n_off
        print("%s %-14s %d px differ: %d on a dressing's edge line, %d elsewhere (%d dressings x phases)"
              % ("ok  " if n_off == 0 else "FAIL", site, n_diff, n_on, n_off, len(cs)))
        if n_off:
            ys, xs = np.nonzero(diff & ~allowed)
            print("     first off-line pixels (x, y): %s" % list(zip(xs[:8].tolist(), ys[:8].tolist())))
            bad_total += 1
    print("FADE_EDGES_REST RESULT %s" % ("PASS" if bad_total == 0 else "FAIL"))
    sys.exit(0 if bad_total == 0 else 1)


if __name__ == "__main__":
    main()
