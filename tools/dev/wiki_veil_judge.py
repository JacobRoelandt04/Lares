#!/usr/bin/env python3
"""wiki_veil_judge.py DIR -- the pictures tools/dev/qml/wiki_veil_probe.qml wrote, judged. One WVJ line per check.

grid.png     rows = the patterns (argv 2.., in order), columns 240 x 136:
             0, 1 the same article twice; 2 another article; 3 the first with a plate of radius 40;
             4 the first in another hue; 5, 6 the other hue and the first, both with no hue share
seq_NNN.png  the patterns side by side, one frame per 1/24 s

  draws     the picture is not the bare floor (a shader that did not load draws nothing, and nothing equals nothing)
  same      the same article is the same picture wherever it stands (8 pixels may sit a level apart: rounding ties)
  other     another article is another picture
  plate     inside the plate the floor is flat; outside it the pattern is there
  hue       the family's hue reaches the picture, and with no hue share it does not
  moves     the last frame is not the first
  jumps     nothing appears or goes from one frame to the next: every pixel that carries ink was within 3 px of ink a
            frame before (and the other way round), give or take 8 levels (a line that swings, drifts or fades passes;
            a wall that snaps to its new place does not)
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

CW, CH = 240, 136
fails = 0


def check(name, ok, detail=""):
    global fails
    if not ok:
        fails += 1
    print("WVJ %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [%s]" % detail))


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def ink(img, ground):
    return np.abs(img - ground).max(axis=2)


def alike(a, b):
    """(ok, detail): the same picture. Two copies at two places in a window get their coordinates interpolated from
    other corners, so a pixel on a rounding tie can come out a level apart: at most 8 such pixels, none further."""
    d = np.abs(a - b).max(axis=2)
    ties, far = int((d == 1).sum()), int((d > 1).sum())
    return far == 0 and ties <= 8, "%d pixels differ by more than a level, %d by one" % (far, ties)


def spread(a, r=3):
    """max filter of radius r (a square: enough for 'near')"""
    out = a.copy()
    h, w = a.shape
    pad = np.pad(a, r, mode="edge")
    for dy in range(2 * r + 1):
        for dx in range(2 * r + 1):
            np.maximum(out, pad[dy:dy + h, dx:dx + w], out=out)
    return out


def main():
    d = sys.argv[1]
    names = sys.argv[2:]
    grid = load(os.path.join(d, "grid.png"))
    if grid.shape[0] != CH * len(names) or grid.shape[1] != CW * 7:
        check("grid: %d x %d cells of %d x %d" % (7, len(names), CW, CH), False, "the picture is %d x %d" % (grid.shape[1], grid.shape[0]))
        return 1
    yy, xx = np.mgrid[0:CH, 0:CW]
    rr = np.hypot(xx - (CW - 1) / 2.0, yy - (CH - 1) / 2.0)
    grounds = []
    for r, name in enumerate(names):
        cell = [grid[r * CH:(r + 1) * CH, c * CW:(c + 1) * CW] for c in range(7)]
        ground = cell[3][CH // 2, CW // 2].copy()
        grounds.append(ground)
        k = ink(cell[0], ground)
        share = float((k > 3).mean())
        check("%s: draws" % name, share > 0.02 and k.max() >= 6, "%.1f %% of the pixels are off the floor, at most %d levels" % (100 * share, k.max()))
        check("%s: the same article is the same picture" % name, *alike(cell[0], cell[1]))
        other = float((np.abs(cell[0] - cell[2]).max(axis=2) > 3).mean())
        check("%s: another article is another picture" % name, other > 0.02, "%.2f %% of the pixels differ" % (100 * other))
        kp = ink(cell[3], ground)
        inside = int(kp[rr < 35].max())
        outside = float((kp[rr > 78] > 3).mean())
        check("%s: the plate is flat" % name, inside <= 1, "%d levels off the floor inside the plate" % inside)
        check("%s: the pattern is there round the plate" % name, outside > 0.01, "%.2f %% of the pixels outside carry ink" % (100 * outside))
        hued = int((np.abs(cell[0] - cell[4]).max(axis=2) >= 1).sum())
        check("%s: the hue reaches the picture" % name, hued >= 40, "%d pixels differ between two hues" % hued)
        check("%s: with no hue share there is no hue" % name, *alike(cell[5], cell[6]))

    frames = sorted(glob.glob(os.path.join(d, "seq_*.png")))
    if len(frames) < 24:
        check("sequence: at least 24 frames", False, "%d frames" % len(frames))
        return 1
    seq = [load(f) for f in frames]
    for r, name in enumerate(names):
        ks = [ink(f[:, r * CW:(r + 1) * CW], grounds[r]) for f in seq]
        moved = float(np.abs(ks[-1] - ks[0]).mean())
        check("%s: it moves" % name, moved > 0.02, "the last frame is %.3f levels a pixel from the first" % moved)
        worst, at = 0, 0
        for i in range(1, len(ks)):
            came = int((ks[i] > spread(ks[i - 1]) + 8).sum())
            went = int((ks[i - 1] > spread(ks[i]) + 8).sum())
            if max(came, went) > worst:
                worst, at = max(came, went), i
        check("%s: nothing jumps" % name, worst <= 12, "%d pixels of ink with none near them a frame before, at frame %d" % (worst, at))
    print("WVJ RESULT %s" % ("FAIL" if fails else "PASS"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
