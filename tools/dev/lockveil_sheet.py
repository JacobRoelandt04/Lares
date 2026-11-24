#!/usr/bin/env python3
"""lockveil_sheet.py -- labelled sheets and pixel diffs of tools/dev/lockveil_render.sh's grabs.

  lockveil_sheet.py sheet OUT.png [--cols N] [--cell W] [--crop x,y,w,h] LABEL=PNG ...
      one cell per image, scaled to W px wide (after the optional crop, in the image's own px), its label above it
  lockveil_sheet.py diff A_DIR B_DIR [NAME ...]
      for every PNG of that name in both dirs (all shared names when none are given): the pixels where ANY channel
      differs, composited on black first (a grab's alpha is not a picture); one line each, then
      LOCKVEIL_DIFF RESULT PASS (every one 0 px) | DIFFER (n image(s) moved)
"""
import os
import sys

import numpy
from PIL import Image, ImageChops, ImageDraw


def flat(path):
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, im).convert("RGB")


def sheet(args):
    out = args[0]
    cols, cell, crop, cells = 2, 960, None, []
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--cols":
            cols = int(args[i + 1]); i += 2; continue
        if a == "--cell":
            cell = int(args[i + 1]); i += 2; continue
        if a == "--crop":
            crop = tuple(int(v) for v in args[i + 1].split(",")); i += 2; continue
        label, _, path = a.rpartition("=")
        cells.append((label, path))
        i += 1
    ims = []
    for label, path in cells:
        im = flat(path)
        if crop:
            x, y, w, h = crop
            im = im.crop((x, y, x + w, y + h))
        im = im.resize((cell, round(cell * im.height / im.width)), Image.LANCZOS)
        ims.append((label, im))
    ch = max(im.height for _, im in ims)
    rows = (len(ims) + cols - 1) // cols
    sh = Image.new("RGB", (cols * cell + (cols - 1) * 8, rows * (ch + 26)), (255, 255, 255))
    dr = ImageDraw.Draw(sh)
    for k, (label, im) in enumerate(ims):
        x, y = (k % cols) * (cell + 8), (k // cols) * (ch + 26)
        sh.paste(im, (x, y + 26))
        dr.text((x + 6, y + 7), label, fill=(0, 0, 0))
    sh.save(out)
    print("LOCKVEIL_SHEET", out, "%dx%d" % sh.size)


def diff(args):
    a_dir, b_dir, names = args[0], args[1], args[2:]
    if not names:
        names = sorted(n for n in os.listdir(a_dir) if n.endswith(".png") and os.path.exists(os.path.join(b_dir, n)))
    moved = 0
    for n in names:
        if not n.endswith(".png"):
            n += ".png"
        a, b = flat(os.path.join(a_dir, n)), flat(os.path.join(b_dir, n))
        if a.size != b.size:
            print("  %-40s size %s vs %s" % (n, a.size, b.size)); moved += 1; continue
        d = ImageChops.difference(a, b)
        arr = numpy.asarray(d)
        px = int((arr.max(axis=2) > 0).sum())
        mx = int(arr.max())
        bbox = d.getbbox()
        print("  %-40s %8d px moved (max %d levels)%s" % (n, px, mx, ("  bbox %s" % (bbox,)) if bbox else ""))
        if px:
            moved += 1
    print("LOCKVEIL_DIFF RESULT %s" % ("PASS (%d image(s), 0 px moved)" % len(names) if moved == 0 else "DIFFER (%d of %d image(s) moved)" % (moved, len(names))))
    return 0 if moved == 0 else 1


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("sheet", "diff"):
        print(__doc__)
        sys.exit(2)
    if sys.argv[1] == "sheet":
        sheet(sys.argv[2:])
    else:
        sys.exit(diff(sys.argv[2:]))
