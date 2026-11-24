#!/usr/bin/env python3
"""reel_ring_compose.py -- the labelled before/after sheet of tools/dev/reel_ring_sheet.sh renders.

  reel_ring_compose.py <out.png> [--crop x0,y0,x1,y1] [--crops <cell>=x0:y0:x1:y1,..] [--scale k] [--cells a,b,..] <label>=<dir> ...
  reel_ring_compose.py --film <out.png> <prefix> [--crop x0,y0,x1,y1] [--scale k] [--max n] <label>=<dir> ...

One row per cell, one column per <label>=<dir> (a directory of <cell>.png); each PNG is composited on a mid-grey ground (the grabs carry
alpha) and cropped (--crops: a crop of its own for a cell). Labels are drawn on every cell. Also prints, per cell, the number of pixels
that differ between the first two directories (any channel, inside the crop), so "0 moved" is a measured fact.

--film: one row per <label>=<dir>, one column per frame <prefix>_f<i>.png of that directory in order (tools/dev/reel_shell_sheet.sh's
films), at most --max of them, evenly taken.
"""
import sys, os
from PIL import Image, ImageDraw, ImageChops

CELLS = ["%s_%s" % (pop, c) for pop in ("pop", "list", "none")
         for c in ("idle_rest", "idle_merge", "power_rest", "power_merge", "tray_rest", "tray_merge", "label_rest", "menu_rest")] + ["poke_tray_rest"]
GROUND = (122, 122, 134, 255)

def load(path):
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, GROUND)
    return Image.alpha_composite(bg, im).convert("RGB")

def film(argv):
    out, prefix = argv[0], argv[1]
    crop, scale, most, rows = None, 1, 12, []
    i = 2
    while i < len(argv):
        a = argv[i]
        if a == "--crop":
            crop = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        elif a == "--scale":
            scale = int(argv[i + 1]); i += 2
        elif a == "--max":
            most = int(argv[i + 1]); i += 2
        else:
            lab, d = a.split("=", 1); rows.append((lab, d)); i += 1
    strips = []
    for lab, d in rows:
        n = 0
        while os.path.exists(os.path.join(d, "%s_f%d.png" % (prefix, n))):
            n += 1
        take = list(range(n)) if n <= most else sorted({round(k * (n - 1) / (most - 1)) for k in range(most)})
        frames = []
        for k in take:
            im = load(os.path.join(d, "%s_f%d.png" % (prefix, k)))
            if crop:
                im = im.crop(crop)
            if scale != 1:
                im = im.resize((im.size[0] * scale, im.size[1] * scale), Image.NEAREST)
            frames.append((k, im))
        strips.append((lab, frames))
        print("FILM %s [%s]: %d frames, %d shown" % (prefix, lab, n, len(frames)))
    w = max(im.size[0] for _, fr in strips for _, im in fr)
    h = max(im.size[1] for _, fr in strips for _, im in fr)
    cols_n = max(len(fr) for _, fr in strips)
    pad, head = 4, 16
    sheet = Image.new("RGB", (cols_n * (w + pad) + pad, len(strips) * (h + head + pad) + pad), (40, 40, 44))
    dr = ImageDraw.Draw(sheet)
    for r, (lab, frames) in enumerate(strips):
        for c, (k, im) in enumerate(frames):
            x, y = pad + c * (w + pad), pad + r * (h + head + pad)
            dr.text((x + 2, y + 2), "%s f%d [%s]" % (prefix, k, lab), fill=(255, 255, 255))
            sheet.paste(im, (x, y + head))
    sheet.save(out)
    print("SHEET", out, sheet.size)


def main(argv):
    if argv and argv[0] == "--film":
        return film(argv[1:])
    out = argv[0]
    crop, scale, cells, cols = None, 1, CELLS, []
    crops = {}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--crop":
            crop = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        elif a == "--scale":
            scale = int(argv[i + 1]); i += 2
        elif a == "--cells":
            cells = argv[i + 1].split(","); i += 2
        elif a == "--crops":
            for e in argv[i + 1].split(","):
                n, v = e.split("=", 1)
                crops[n] = tuple(int(q) for q in v.split(":"))
            i += 2
        else:
            lab, d = a.split("=", 1); cols.append((lab, d)); i += 1
    tiles = {}
    for c in cells:
        for lab, d in cols:
            p = os.path.join(d, c + ".png")
            if os.path.exists(p):
                im = load(p)
                if crops.get(c) or crop:
                    im = im.crop(crops.get(c) or crop)
                tiles[(c, lab)] = im
    for c in cells:
        if len(cols) >= 2 and (c, cols[0][0]) in tiles and (c, cols[1][0]) in tiles:
            a, b = tiles[(c, cols[0][0])], tiles[(c, cols[1][0])]
            diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v else 0)
            print("DIFF %-22s %6d px differ (%s vs %s)" % (c, diff.histogram()[255], cols[0][0], cols[1][0]))
    w = max(t.size[0] for t in tiles.values()) * scale
    h = max(t.size[1] for t in tiles.values()) * scale
    pad, head = 6, 16
    sheet = Image.new("RGB", (len(cols) * (w + pad) + pad, len(cells) * (h + head + pad) + pad), (40, 40, 44))
    dr = ImageDraw.Draw(sheet)
    for r, c in enumerate(cells):
        for k, (lab, d) in enumerate(cols):
            t = tiles.get((c, lab))
            x, y = pad + k * (w + pad), pad + r * (h + head + pad)
            dr.text((x + 2, y + 2), "%s  [%s]" % (c, lab), fill=(255, 255, 255))
            if t is not None:
                if scale != 1:
                    t = t.resize((t.size[0] * scale, t.size[1] * scale), Image.NEAREST)
                sheet.paste(t, (x, y + head))
    sheet.save(out)
    print("SHEET", out, sheet.size)

if __name__ == "__main__":
    main(sys.argv[1:])
