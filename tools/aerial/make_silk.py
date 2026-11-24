#!/usr/bin/env python3
"""make_silk.py -- aerial's silkscreen as a SIGNED-DISTANCE texture the board shader samples (silicon's method: tools/silicon/make_silkscreen.py).

    tools/aerial/make_silk.py            writes modules/aerial/scene/assets/silk.png and silk.json
    tools/aerial/make_silk.py --check    the same in memory: fails when the files are stale or a name stands where a part can cover it

WHY (round 3, the user's "outline layering issue"): the names and the courtyards were QML laid OVER the board's picture, so they showed through whatever stood in front of
them (BT SCAN through the RJ45). Baked here they are part of the board's own surface: the shader carves them (Material) or inks them (Blueprint), a part in front hides
them, a shadow falls on them.

THE TEXTURE, 20 texels per mm, one channel per family in that family's lettering (R Material: Audiowide, G Blueprint: Bahnschrift), each a distance field (0.5 = an
edge, +-RANGE_MM either side: the shader's SILK_RANGE):
  - the BOARD, at the top: u along x, v along z from AerialGeometry BOARD's corner -- every fixed name (LABELS without `unit`), the courtyards (COURTYARDS), the marks;
  - the ATLAS under it: one cell per engraved VARIANT of the two unit labels (SILK_VARIANTS: "RATE - Mb/s", "RUN? - MB" ...; the shader's `silkVar` uniform picks one)
    and one per EMBLEM of the radio latches (EMBLEMS: the Wi-Fi fan, the Bluetooth rune -- the same glyph in both channels).
silk.json says where each cell is (the generator writes it into the shader: tools/dev/board_gen/scenes/aerial.js) and every name's real ink box (board mm).
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GEOM = os.path.join(ROOT, "modules/aerial/scene/AerialGeometry.js")
OUT = os.path.join(ROOT, "modules/aerial/scene/assets/silk.png")
META = os.path.join(ROOT, "modules/aerial/scene/assets/silk.json")
# 20 texels per mm (round 4; it was silicon's 8). Silicon's board is ~230 mm across and drawn at ~4.5 px per mm with letters 2.8 - 4.2 mm tall: its 8 texels a mm are
# MINIFIED on screen. Aerial's board is 61 mm across, drawn at 9.2 px per mm times the shell's scale (14.4 device px on the user's panel) with letters 1.25 mm tall: at 8
# texels a mm a letter was 10 texels tall with strokes of 1.4 and was magnified 1.8 x -- it read as low resolution. A stroke is 3.5 texels now and the field is never magnified.
PX_PER_MM = 20
HI = 3
RANGE_MM = 1.0
CELL = (21.0, 3.2)        # a variant's cell, mm: the text starts PAD_X in and is centred on the cell's middle line
PAD_X = 0.6
EMBLEM_CELL = 4.4         # an emblem's square cell, mm: the glyph centred in it
GAP = 1.2                 # mm between cells (a mip level never reads a neighbour)
LINE = 0.2                # a courtyard's stroke, mm

FONTS = {   # channel -> (fontconfig pattern, font size per mm of label, variation axes)
    "r": ("Audiowide", 1.30, None),
    "g": ("Bahnschrift", 1.34, {"wght": 420, "wdth": 100}),
}
ICON_FONT = "Symbols Nerd Font"


def font_file(pattern):
    out = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit("make_silk: no font for " + pattern)
    return out


def load_font(path, size, axes):
    font = ImageFont.truetype(path, size)
    if axes:
        try:
            names = [a["name"].decode() if isinstance(a["name"], bytes) else a["name"] for a in font.get_variation_axes()]
            font.set_variation_by_axes([axes.get(n, a["default"]) for n, a in zip(names, font.get_variation_axes())])
        except Exception:
            pass
    return font


def geometry():
    js = "const fs=require('fs');const s=fs.readFileSync(process.argv[1],'utf8').replace(/^\\.pragma.*$/m,'');" \
         "process.stdout.write(new Function(s+';return json();')());"
    return json.loads(subprocess.check_output(["node", "-e", js, GEOM]))


class Sheet:
    """A hi-res binary canvas in texture millimetres (the board at the origin, the atlas under it) for one channel."""

    def __init__(self, w_mm, h_mm):
        self.W = int(round(w_mm * PX_PER_MM)) * HI
        self.H = int(round(h_mm * PX_PER_MM)) * HI
        self.img = Image.new("L", (self.W, self.H), 0)
        self.d = ImageDraw.Draw(self.img)
        self.k = PX_PER_MM * HI

    def tile(self, font, text):
        box = font.getbbox(text)
        t = Image.new("L", (box[2] - box[0] + 16, box[3] - box[1] + 16), 0)
        ImageDraw.Draw(t).text((8 - box[0], 8 - box[1]), text, fill=255, font=font)
        bb = t.getbbox()
        return t.crop(bb)

    def text(self, path, axes, size_per_mm, text, x, z, size, anchor):
        """Text whose INK starts (left), ends (right) or is centred at x, its ink's middle line on z. Returns the ink box (mm)."""
        font = load_font(path, max(8, int(round(size * size_per_mm * self.k))), axes)
        t = self.tile(font, text)
        w, h = t.width / self.k, t.height / self.k
        x0 = x if anchor == "left" else (x - w if anchor == "right" else x - w / 2)
        self.img.paste(255, (int(round(x0 * self.k)), int(round((z - h / 2) * self.k))), t)
        return (x0, z - h / 2, x0 + w, z + h / 2)

    def glyph(self, path, ch, cx, cz, size):
        """An icon glyph, its ink box `size` mm on its longer side, centred on (cx, cz)."""
        font = ImageFont.truetype(path, int(round(size * self.k * 1.4)))
        t = self.tile(font, ch)
        s = size * self.k / max(t.width, t.height)
        t = t.resize((max(1, int(round(t.width * s))), max(1, int(round(t.height * s)))), Image.LANCZOS).point(lambda v: 255 if v > 127 else 0)
        self.img.paste(255, (int(round(cx * self.k - t.width / 2)), int(round(cz * self.k - t.height / 2))), t)

    def rrect(self, x0, z0, x1, z1, r, w):
        self.d.rounded_rectangle([x0 * self.k, z0 * self.k, x1 * self.k, z1 * self.k], radius=r * self.k, outline=255, width=max(1, int(round(w * self.k))))

    def ring(self, x, z, r, w):
        rr = r * self.k
        self.d.ellipse([x * self.k - rr, z * self.k - rr, x * self.k + rr, z * self.k + rr], outline=255, width=max(1, int(round(w * self.k))))

    def line(self, pts, w):
        self.d.line([(x * self.k, z * self.k) for (x, z) in pts], fill=255, width=max(1, int(round(w * self.k))), joint="curve")

    def field(self):
        m = np.asarray(self.img) > 127
        d_in = ndimage.distance_transform_edt(m)
        d_out = ndimage.distance_transform_edt(~m)
        sd = np.where(m, d_in - 0.5, -(d_out - 0.5)) / self.k
        sd = np.clip(sd, -RANGE_MM, RANGE_MM)
        h, w = sd.shape
        sd = sd.reshape(h // HI, HI, w // HI, HI).mean(axis=(1, 3))
        return np.clip(np.round((0.5 + sd / (2 * RANGE_MM)) * 255), 0, 255).astype(np.uint8)


def layout(G):
    """The atlas: where each variant's and each emblem's cell is (texture mm)."""
    B = G["BOARD"]
    bw, bh = B["x1"] - B["x0"], B["z1"] - B["z0"]
    cells = {"rates": [], "usage": [], "emblem": {}}
    x, z = GAP, bh + GAP
    for key in ("rates", "usage"):
        for _ in G["SILK_VARIANTS"][key]:
            if x + CELL[0] + GAP > bw:
                x, z = GAP, z + CELL[1] + GAP
            cells[key].append([round(x, 3), round(z, 3)])
            x += CELL[0] + GAP
    x, z = GAP, z + CELL[1] + GAP
    for name in sorted(G["EMBLEMS"].keys()):
        cells["emblem"][name] = [round(x, 3), round(z, 3)]
        x += EMBLEM_CELL + GAP
    return bw, z + EMBLEM_CELL + GAP, cells


def build(G):
    B = G["BOARD"]
    tw, th, cells = layout(G)
    th = int(np.ceil(th))
    icon = font_file(ICON_FONT)
    chans, boxes = {}, {}
    for ch, (pattern, k, axes) in FONTS.items():
        S = Sheet(tw, th)
        path = font_file(pattern)
        ox, oz = -B["x0"], -B["z0"]
        for i, L in enumerate(G["LABELS"]):
            if L.get("unit"):
                # the room the widest variant takes: its box, for the layout check (nothing is drawn on the board here)
                T = Sheet(CELL[0] + 2, CELL[1] + 2)
                b = T.text(path, axes, k, L["text"], 0.0, 1.5, L["size"], "left")
                box = (L["x"], L["z"] - (b[3] - b[1]) / 2, L["x"] + (b[2] - b[0]), L["z"] + (b[3] - b[1]) / 2)
            else:
                b = S.text(path, axes, k, L["text"], L["x"] + ox, L["z"] + oz, L["size"], L.get("anchor", "centre"))
                box = (b[0] - ox, b[1] - oz, b[2] - ox, b[3] - oz)
            p = boxes.get(i, box)
            boxes[i] = (min(p[0], box[0]), min(p[1], box[1]), max(p[2], box[2]), max(p[3], box[3]))
        for c in G["COURTYARDS"]:
            if "c" in c:
                S.ring(c["c"][0] + ox, c["c"][1] + oz, c["c"][2], LINE)
            else:
                r = c["r"]
                S.rrect(r[0] + ox, r[1] + oz, r[2] + ox, r[3] + oz, r[4], LINE)
        if ch == "g":
            # Blueprint is a drawing sheet: a border frame with ruler ticks (silicon's sheet)
            m = 1.2
            x0, z0, x1, z1 = m, m, tw - m, (B["z1"] - B["z0"]) - m
            S.rrect(x0, z0, x1, z1, 0.01, 0.3)
            for t in range(1, 6):
                tx = x0 + (x1 - x0) * t / 6.0
                S.line([(tx, z0), (tx, z0 + 1.0)], 0.18)
            for t in range(1, 5):
                tz = z0 + (z1 - z0) * t / 5.0
                S.line([(x1, tz), (x1 - 1.0, tz)], 0.18)
        # the atlas
        for key in ("rates", "usage"):
            size = next(L["size"] for L in G["LABELS"] if L.get("unit") == key)
            for text, (cx, cz) in zip(G["SILK_VARIANTS"][key], cells[key]):
                b = S.text(path, axes, k, text, cx + PAD_X, cz + CELL[1] / 2, size, "left")
                if b[2] > cx + CELL[0] - 0.2:
                    sys.exit("make_silk: variant %r is wider than its cell (%.1f mm)" % (text, b[2] - b[0]))
        for name, (cx, cz) in cells["emblem"].items():
            E = G["EMBLEMS"][name]
            S.glyph(icon, E["glyph"], cx + EMBLEM_CELL / 2, cz + EMBLEM_CELL / 2, E["size"])
        chans[ch] = S.field()
    img = np.dstack([chans["r"], chans["g"], np.zeros_like(chans["r"])])
    meta = {
        "texMm": [tw, th], "texelsPerMm": PX_PER_MM, "rangeMm": RANGE_MM, "cell": [CELL[0], CELL[1]], "padX": PAD_X, "emblemCell": EMBLEM_CELL,
        "cells": cells,
        "labels": [{"text": L["text"], "unit": L.get("unit", ""), "x0": round(boxes[i][0], 2), "z0": round(boxes[i][1], 2), "x1": round(boxes[i][2], 2), "z1": round(boxes[i][3], 2)}
                   for i, L in enumerate(G["LABELS"])],
    }
    return img, meta


def covered(G, meta):
    """Every name must stand on open board: its ink box clear of every part's footprint (grown by what a taller part hides behind it on screen: a part h mm tall covers the
    board up to h mm behind it along -x and -z, the camera's diagonal), of every courtyard's line and of the board's edge."""
    bad = []
    B = G["BOARD"]
    for L in meta["labels"]:
        x0, z0, x1, z1 = L["x0"], L["z0"], L["x1"], L["z1"]
        if x0 < B["x0"] + 0.8 or x1 > B["x1"] - 0.8 or z0 < B["z0"] + 0.8 or z1 > B["z1"] - 0.8:
            bad.append("%s: off the board (%.1f %.1f %.1f %.1f)" % (L["text"], x0, z0, x1, z1))
        for p in G["PARTS"]:
            if p["name"] == "board" or p["group"] not in ("board", "dipw", "dipb", "btn"):
                continue
            h = p["max"][1]
            # the part's footprint, and the board it hides: the footprint slid h along (-1, -1)
            px0, pz0, px1, pz1 = p["min"][0] - h, p["min"][2] - h, p["max"][0], p["max"][2]
            if x0 < px1 + 0.25 and x1 > px0 - 0.25 and z0 < pz1 + 0.25 and z1 > pz0 - 0.25:
                # inside the slid hull only where the diagonal really passes: test the box's corners against the swept footprint
                hit = False
                for (cx, cz) in ((x0, z0), (x1, z0), (x1, z1), (x0, z1), ((x0 + x1) / 2, (z0 + z1) / 2)):
                    for t in np.linspace(0.0, h, 9):
                        if p["min"][0] - 0.25 <= cx + t <= p["max"][0] + 0.25 and p["min"][2] - 0.25 <= cz + t <= p["max"][2] + 0.25:
                            hit = True
                if hit:
                    bad.append("%s: under or behind %s" % (L["text"], p["name"]))
        for c in G["COURTYARDS"]:
            if "c" in c:
                cx, cz, r = c["c"]
                nx, nz = min(max(cx, x0), x1), min(max(cz, z0), z1)
                far = max(np.hypot(cx - x0, cz - z0), np.hypot(cx - x1, cz - z0), np.hypot(cx - x1, cz - z1), np.hypot(cx - x0, cz - z1))
                if np.hypot(cx - nx, cz - nz) < r + 0.3 and far > r - 0.3:
                    bad.append("%s: on a courtyard's ring" % L["text"])
            else:
                r = c["r"]
                if x0 < r[2] + 0.3 and x1 > r[0] - 0.3 and z0 < r[3] + 0.3 and z1 > r[1] - 0.3:
                    bad.append("%s: on a courtyard" % L["text"])
        for T in G["TRACES"]:
            pts = T["pts"]
            for a, b in zip(pts, pts[1:]):
                tx0, tx1 = min(a[0], b[0]) - T["width"] / 2 - 0.3, max(a[0], b[0]) + T["width"] / 2 + 0.3
                tz0, tz1 = min(a[1], b[1]) - T["width"] / 2 - 0.3, max(a[1], b[1]) + T["width"] / 2 + 0.3
                if a[0] == b[0] or a[1] == b[1]:
                    if x0 < tx1 and x1 > tx0 and z0 < tz1 and z1 > tz0:
                        bad.append("%s: on the trace %s" % (L["text"], T["name"]))
    return sorted(set(bad))


def main():
    check = "--check" in sys.argv
    G = geometry()
    img, meta = build(G)
    bad = covered(G, meta)
    text = json.dumps(meta, indent=1) + "\n"
    if check:
        ok = True
        if not os.path.exists(OUT) or not os.path.exists(META):
            ok = False
            print("AERIAL_SILK FAIL missing", OUT)
        else:
            if open(META).read() != text:
                ok = False
                print("AERIAL_SILK FAIL stale", META)
            old = np.asarray(Image.open(OUT).convert("RGB"))
            if old.shape != img.shape or int(np.abs(old.astype(int) - img.astype(int)).max()) > 0:
                ok = False
                print("AERIAL_SILK FAIL stale", OUT)
        for b in bad:
            ok = False
            print("AERIAL_SILK FAIL covered:", b)
        print("AERIAL_SILK RESULT", "PASS" if ok else "FAIL")
        sys.exit(0 if ok else 1)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(img, "RGB").save(OUT, optimize=True)
    with open(META, "w") as fh:
        fh.write(text)
    print("wrote", OUT, "%dx%d" % (img.shape[1], img.shape[0]), "labels", len(G["LABELS"]))
    for b in bad:
        print("  COVERED:", b)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
