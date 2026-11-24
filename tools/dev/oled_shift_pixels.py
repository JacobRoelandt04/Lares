#!/usr/bin/env python3
"""oled_shift_pixels.py -- the OLED shift's islands judged by their pictures (tools/dev/oled_shift_probe.sh runs it).

The probe (tools/dev/qml/oled_shift_probe.qml, OLEDSHIFT_GRABS=<dir>) saves the window at places of the orbit -- p0 (0,0), p1 (1,0),
p5 (-1,0), and p9: (0,0) again after the ring -- over an opaque ground, and logs `OLEDSHIFT geom <json>`: the islands' ends at the
centre, in window px (a device px here). Every free end steps with the content, so:

  voids   the band round each void between two islands -- the left island's right end to the centre island's left end, the centre
          island's right end to the right island's left end, 16 px into each island (the ink of the modules is 22 x scale away) and from
          the screen's top to 24 px under the islands:
          - EVEN  p5 is p1 moved by exactly -2 px: no pixel more than one level off (bit-exact at scale 1, measured)
          - ODD   p1 / p5 are p0 moved by exactly the step, but for the one antialiased pixel per end where the sky fillet meets the
                  end's face: the field takes its antialiasing width from derivatives of a composed distance, which run over 2 x 2
                  pixel quads fixed to the screen, so an odd move pairs that pixel with another neighbour and it comes out a few levels
                  off (CLAUDE.md "A SHADER THAT TAKES ITS PIXEL SIZE FROM dFdx/dFdy OF A COMPOSED DISTANCE RE-RASTERISES WHEN THE ITEM
                  MOVES ONE PIXEL"; measured 2026-11-10: 2 levels in night-owl dark, 4 in eva light, one pixel per end, and an even move
                  is exact -- which is what proves the cause). So at most one pixel per end (two per void) more than two levels off,
                  none more than 16; an end that does not follow leaves hundreds of pixels 50-100 levels off.
  joints  the corners where the outer islands meet the slim bars (72 px square under the islands) are the centre's picture, unmoved
  rest    p9 (the centre again, after the ring) is p0: no pixel more than one level off anywhere in the bands

    oled_shift_pixels.py judge --log <log> --grabs <dir> --scale <s>     OLEDSHIFT ok|FAIL pixels ... lines; exit 0 when all pass
    oled_shift_pixels.py sheet --before <dir> --after <dir> --scales "1 1.25" --out <png>
                                                                         a before/after sheet per scale (<png> -> <stem>-<scale>.png): the two
                                                                         ends round the left void at three places, zoomed, labelled

Each <dir> holds the s<scale>-p<k>.png grabs and geom-<scale>.json (the judge writes it from the log; the sheet reads it).
"""
import argparse
import json
import os
import re
import sys

from PIL import Image, ImageChops, ImageDraw

PLACES = {0: (0, 0), 1: (1, 0), 5: (-1, 0), 9: (0, 0)}


def geom_from_log(log, scale):
    g = None
    with open(log, errors="replace") as fh:
        for line in fh:
            m = re.search(r"OLEDSHIFT geom (\{.*\})", line)
            if m:
                g = json.loads(m.group(1))
    if g is None or abs(float(g.get("scale", -1)) - float(scale)) > 1e-6:
        return None
    return g


def load(d, scale, k):
    p = os.path.join(d, "s%s-p%d.png" % (scale, k))
    if not os.path.exists(p):
        return None
    # the ground is opaque; composite on black anyway so alpha never hides a difference (PIL's getbbox on RGBA reads alpha)
    im = Image.open(p).convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, im).convert("RGB")


def bands(g):
    import math
    top = int(math.ceil(g["top"]))
    w = int(g["w"])
    vb = (0, top + 24)
    out = {
        "void left": ("move", int(math.floor(g["topL"][1])) - 16, int(math.ceil(g["topC"][0])) + 16, vb),
        "void right": ("move", int(math.floor(g["topC"][1])) - 16, int(math.ceil(g["topR"][0])) + 16, vb),
        "joint left": ("still", 0, 72, (top + 2, top + 74)),
        "joint right": ("still", w - 72, w, (top + 2, top + 74)),
    }
    return out


def diff(a, b, level):
    """(pixels more than `level` levels off in any channel, the largest level difference) of two same-size RGB images"""
    d = ImageChops.difference(a, b)
    hist = d.split()
    worst = max(ch.getextrema()[1] for ch in hist)
    mask = None
    for ch in hist:
        m = ch.point(lambda v: 255 if v > level else 0)
        mask = m if mask is None else ImageChops.lighter(mask, m)
    return mask.histogram()[255], worst


# THE ODD STEP's allowance (the docstring): one re-rasterised pixel per free end, at most this many levels off
ODD_PER_END = 1
ODD_WORST = 16


def judge(a):
    g = geom_from_log(a.log, a.scale)
    lines = []
    if g is None:
        print("OLEDSHIFT FAIL pixels: no geom line for scale %s in %s" % (a.scale, a.log))
        return 1
    with open(os.path.join(a.grabs, "geom-%s.json" % a.scale), "w") as fh:
        json.dump(g, fh)
    pic = {k: load(a.grabs, a.scale, k) for k in PLACES}
    for k, im in pic.items():
        if im is None:
            lines.append((False, "scale %s place %d: no picture" % (a.scale, k)))
    if any(im is None for im in pic.values()):
        for good, text in lines:
            print("OLEDSHIFT %s pixels: %s" % ("ok  " if good else "FAIL", text))
        return 1
    B = bands(g)

    def cmp(img, ref, kind, c0, c1, r0, r1, s, level):
        return diff(img.crop((c0 + s, r0, c1 + s, r1)), ref.crop((c0, r0, c1, r1)), level)

    for k in (1, 5):
        dx = PLACES[k][0]
        for name, (kind, c0, c1, (r0, r1)) in B.items():
            if kind == "move":
                n, worst = cmp(pic[k], pic[0], kind, c0, c1, r0, r1, dx, 2)
                good = n <= 2 * ODD_PER_END and worst <= ODD_WORST
                lines.append((good, "scale %s place %d (%+d,0): the %s band [%d..%d x %d..%d] is the centre's moved %+d px (%d px more than two "
                              "levels off -- at most %d, one per end --, worst %d of at most %d)"
                              % (a.scale, k, dx, name, c0, c1, r0, r1, dx, n, 2 * ODD_PER_END, worst, ODD_WORST)))
            else:
                n, worst = cmp(pic[k], pic[0], kind, c0, c1, r0, r1, 0, 2)
                lines.append((n == 0, "scale %s place %d (%+d,0): the %s band [%d..%d x %d..%d] is the centre's, unmoved (%d px more than two "
                              "levels off, worst %d)" % (a.scale, k, dx, name, c0, c1, r0, r1, n, worst)))
    for name, (kind, c0, c1, (r0, r1)) in B.items():
        if kind != "move":
            continue
        n, worst = cmp(pic[5], pic[1], kind, c0, c1, r0, r1, -2, 1)
        lines.append((n == 0, "scale %s: the %s band at (-1,0) is the one at (1,0) moved -2 px, an even step (%d px more than one level off, worst %d)"
                      % (a.scale, name, n, worst)))
    for name, (kind, c0, c1, (r0, r1)) in B.items():
        n, worst = cmp(pic[9], pic[0], kind, c0, c1, r0, r1, 0, 1)
        lines.append((n == 0, "scale %s: the %s band back at the centre after the ring is the first one (%d px more than one level off, worst %d)"
                      % (a.scale, name, n, worst)))
    ok = True
    for good, text in lines:
        ok = ok and good
        print("OLEDSHIFT %s pixels: %s" % ("ok  " if good else "FAIL", text))
    return 0 if ok else 1


def sheet(a):
    """One sheet per scale (<out> with -<scale> before .png): rows the left island's right end and the centre island's left end, before
    and after; columns the places (0,0) (1,0) (-1,0); each cell 36 px either side of the end, zoomed 6x, with a magenta line where the
    end stands at the centre. Before, the content moves off the line and the end stays on it (the margin changes); after, both move."""
    import math
    zoom, half = 6, 36
    stem, ext = os.path.splitext(a.out)
    for sc in a.scales.split():
        g = None
        for side in ("after", "before"):
            p = os.path.join(getattr(a, side), "geom-%s.json" % sc)
            if os.path.exists(p):
                g = json.load(open(p))
                break
        if g is None:
            print("no geom for scale %s" % sc, file=sys.stderr)
            return 1
        r1 = int(math.ceil(g["top"])) + 12
        ends = [("left island's right end", g["topL"][1]), ("centre island's left end", g["topC"][0])]
        rows = []
        for name, x in ends:
            c0 = int(math.floor(x)) - half
            for side in ("before", "after"):
                row = []
                for k in (0, 1, 5):
                    im = load(getattr(a, side), sc, k)
                    if im is None:
                        row.append(None)
                        continue
                    crop = im.crop((c0, 0, c0 + 2 * half, r1)).resize((2 * half * zoom, r1 * zoom), Image.NEAREST)
                    row.append(("%s: %s, scale %s, place %s" % (side, name, sc, PLACES[k]), crop, (x - c0) * zoom))
                rows.append(row)
        cw, ch = 2 * half * zoom, r1 * zoom
        head, gap = 22, 14
        out = Image.new("RGB", (3 * (cw + gap) + gap, len(rows) * (ch + head + gap) + gap), (24, 24, 28))
        dr = ImageDraw.Draw(out)
        for ri, r in enumerate(rows):
            for ci, c in enumerate(r):
                x0 = gap + ci * (cw + gap)
                y0 = gap + ri * (ch + head + gap)
                if not c:
                    dr.text((x0, y0), "missing", fill=(255, 80, 80))
                    continue
                label, crop, tick = c
                dr.text((x0, y0), label, fill=(230, 230, 230))
                out.paste(crop, (x0, y0 + head))
                tx = x0 + int(round(tick))
                dr.line([(tx, y0 + head - 6), (tx, y0 + head + ch - 1)], fill=(255, 0, 255), width=1)
        path = "%s-%s%s" % (stem, sc, ext or ".png")
        out.save(path)
        print(path)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--log", required=True)
    j.add_argument("--grabs", required=True)
    j.add_argument("--scale", required=True)
    s = sub.add_parser("sheet")
    s.add_argument("--before", required=True)
    s.add_argument("--after", required=True)
    s.add_argument("--scales", default="1 1.25")
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    return judge(a) if a.cmd == "judge" else sheet(a)


if __name__ == "__main__":
    sys.exit(main())
