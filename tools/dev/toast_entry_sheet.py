#!/usr/bin/env python3
"""A strip of the toast stack's frames, labelled (tools/dev/toast_handover_probe.sh FILM=1 FILM_EVERY=1 writes them).

  toast_entry_sheet.py <out.png> <label>=<film dir> [<label>=<film dir> ...] --scenario a,b --frames 0-11 [--crop x0,y0,x1,y1] [--scale 1]

One block per scenario, one row per film dir (the old tree, then the new), one cell per frame; each cell is composited on the
surface colour so a transparent frame reads as the desktop (black stays black: only alpha is composited). A frame is a 16 ms
step of the offscreen clock, so cell k is k x 16 ms after the action.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

def main(argv):
    out = argv[0]
    dirs, scen, frames, crop, scale = [], [], list(range(12)), (516, 36, 900, 236), 1.0
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--scenario":
            scen = argv[i + 1].split(","); i += 2
        elif a == "--frames":
            lo, hi = argv[i + 1].split("-"); frames = list(range(int(lo), int(hi) + 1)); i += 2
        elif a == "--crop":
            crop = tuple(int(v) for v in argv[i + 1].split(",")); i += 2
        elif a == "--scale":
            scale = float(argv[i + 1]); i += 2
        else:
            k, v = a.split("=", 1); dirs.append((k, v)); i += 1
    font = ImageFont.load_default()
    cw, ch = int((crop[2] - crop[0]) * scale), int((crop[3] - crop[1]) * scale)
    pad, lab = 4, 14
    blocks = []
    for sc in scen:
        w = len(frames) * (cw + pad) + pad
        h = (len(dirs) * (ch + lab + pad)) + lab + pad
        blk = Image.new("RGB", (w, h), (30, 30, 34))
        d = ImageDraw.Draw(blk)
        d.text((pad, 1), sc, fill=(255, 255, 255), font=font)
        for r, (lbl, path) in enumerate(dirs):
            y = lab + pad + r * (ch + lab + pad)
            for c, f in enumerate(frames):
                fn = "%s/%s_%03d.png" % (path, sc, f)
                x = pad + c * (cw + pad)
                try:
                    im = Image.open(fn).convert("RGBA").crop(crop)
                except FileNotFoundError:
                    continue
                bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
                bg.alpha_composite(im)
                im = bg.convert("RGB")
                if scale != 1.0:
                    im = im.resize((cw, ch), Image.LANCZOS)
                blk.paste(im, (x, y + lab - 2))
                d.text((x, y), "%s  %d (%d ms)" % (lbl, f, f * 16), fill=(255, 255, 160), font=font)
        blocks.append(blk)
    W = max(b.width for b in blocks)
    H = sum(b.height for b in blocks)
    sheet = Image.new("RGB", (W, H), (30, 30, 34))
    y = 0
    for b in blocks:
        sheet.paste(b, (0, y)); y += b.height
    sheet.save(out)
    print("%s %dx%d" % (out, W, H))

if __name__ == "__main__":
    main(sys.argv[1:])
