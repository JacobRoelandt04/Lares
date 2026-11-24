#!/usr/bin/env python3
"""make_silkscreen.py -- silicon's silkscreen as a board-space SIGNED-DISTANCE mask the board shader samples.

    tools/silicon/make_silkscreen.py            writes modules/silicon/assets/silkscreen.png

One texel per 1/8 mm of the board (SceneGeometry.js BOARD rect): u along x, v along z, so text drawn
upright in the image reads with its top toward -z on the board. One channel per family, each in that
family's lettering (the shader picks its channel): R Material, G Blueprint (B is empty).

Every channel is a distance field, not a coverage mask: 0.5 is a glyph's edge, and the value rises
inside by 1/255 per 2/255 mm (RANGE_MM = 1.0 either side of the edge). board_materials.glsl decodes
`sd_mm = (texel - 0.5) * 2 * SILK_RANGE` (positive inside) and shapes the ink from it, so a letter is
crisp at any zoom and an engraving's bevel / inner shadow is a distance, not a blurred copy.

The labels (text, place, size, turn) come from SceneGeometry.js LABELS and nowhere else. The marks
below (the drawing sheet's frame, ticks and title block) are decoration with no meaning: they live in
board space here because the silkscreen is the one place the board carries them, and they keep clear
of the CPU zone, where the package lifts and turns.
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GEOM = os.path.join(ROOT, "modules/silicon/scene/SceneGeometry.js")
OUT = os.path.join(ROOT, "modules/silicon/assets/silkscreen.png")
BOXES = os.path.join(ROOT, "modules/silicon/assets/silkscreen_labels.json")
PX_PER_MM = 8          # texels per mm of the written mask
HI = 3                 # supersampling of the field's source (the distance is taken on this grid)
RANGE_MM = 1.0         # the field covers +-RANGE_MM around the edge (the shader's SILK_RANGE)

FONTS = {   # channel -> (fontconfig pattern, font size per mm of label, variation axes or None, '+' / minus stroke per mm of size)
    "r": ("Audiowide", 1.30, None, 0.17),
    "g": ("Bahnschrift", 1.34, {"wght": 420, "wdth": 100}, 0.10),
}


def font_file(pattern):
    out = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit("make_silkscreen: no font for " + pattern)
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
    """A hi-res binary canvas in board millimetres for one channel."""

    def __init__(self, B):
        self.x0, self.z0 = B["x0"], B["z0"]
        self.W = int(round((B["x1"] - B["x0"]) * PX_PER_MM)) * HI
        self.H = int(round((B["z1"] - B["z0"]) * PX_PER_MM)) * HI
        self.img = Image.new("L", (self.W, self.H), 0)
        self.d = ImageDraw.Draw(self.img)
        self.k = PX_PER_MM * HI
        self.boxes = {}          # label index -> (x0, z0, x1, z1) of its ink, board mm

    def px(self, x, z):
        return ((x - self.x0) * self.k, (z - self.z0) * self.k)

    def sign(self, L, weight):
        """'+' and the minus sign as geometry: not every face has a minus glyph (Bahnschrift draws a box)."""
        cx, cz = L["x"], L["z"]
        h = L["size"] * 0.42
        w = L["size"] * weight
        if "i" in L:
            hz = (h if L["text"] == "+" else 0) + w / 2
            self.boxes[L["i"]] = (cx - h - w / 2, cz - hz, cx + h + w / 2, cz + hz)
        self.line([(cx - h, cz), (cx + h, cz)], w)
        if L["text"] == "+":
            self.line([(cx, cz - h), (cx, cz + h)], w)

    def text(self, path, axes, size_per_mm, L, weight=0.16):
        if L["text"] in ("+", "\u2212"):
            self.sign(L, weight)
            return
        size = max(8, int(round(L["size"] * size_per_mm * self.k)))
        font = load_font(path, size, axes)
        box = font.getbbox(L["text"])
        tw, th = box[2] - box[0], box[3] - box[1]
        tile = Image.new("L", (tw + 16, th + 16), 0)
        if L.get("face") == "figures" and L.get("plain_zero") and "0" in L["text"]:
            # the board's printed figures' face (make_glyphs.py): Material's Audiowide has a SLASHED zero, which at a small size reads as another
            # digit, so every zero is the letter O cut to the width and height of the face's eight -- and the whole board's figures share one face
            ox, oy = 8 - box[0], 8 - box[1]
            # every run of other glyphs is drawn where it stands in the REAL text: a space stands in for a zero with its own, narrower advance,
            # so drawing the text with its zeros blanked would shift every glyph after a zero ("RTX 4060" would read "RTX 4[6 over 0]   0")
            d, j = ImageDraw.Draw(tile), 0
            for run in L["text"].split("0"):
                if run:
                    d.text((ox + font.getlength(L["text"][:j]), oy), run, fill=255, font=font)
                j += len(run) + 1
            e0 = font.getbbox("8")
            otile = Image.new("L", (font.getbbox("O")[2] + 16, font.getbbox("O")[3] + 16), 0)
            ImageDraw.Draw(otile).text((8, 8), "O", fill=255, font=font)
            otile = otile.crop(otile.getbbox()).resize((e0[2] - e0[0], e0[3] - e0[1]), Image.LANCZOS)
            for j, c in enumerate(L["text"]):
                if c == "0":
                    tile.paste(255, (int(round(ox + font.getlength(L["text"][:j]) + e0[0])), int(round(oy + e0[1]))), otile)
        else:
            ImageDraw.Draw(tile).text((8 - box[0], 8 - box[1]), L["text"], fill=255, font=font)
        if L.get("rot", 0):
            tile = tile.rotate(L["rot"], expand=True, resample=Image.BICUBIC)
        bb = tile.getbbox()
        hw, hh = (bb[2] - bb[0]) / self.k / 2, (bb[3] - bb[1]) / self.k / 2                # the ink's real half extents: the tile is centred on the label
        # `anchor`: the label's x is where its ink ENDS ("right") or STARTS ("left") instead of its centre -- a figure's label lines up with the figure
        x = L["x"] - hw if L.get("anchor") == "right" else (L["x"] + hw if L.get("anchor") == "left" else L["x"])
        if "i" in L:
            self.boxes[L["i"]] = (x - hw, L["z"] - hh, x + hw, L["z"] + hh)
        cx, cy = self.px(x, L["z"])
        self.img.paste(255, (int(round(cx - tile.width / 2)), int(round(cy - tile.height / 2))), tile)

    # primitives, board mm (the line weight w is the stroke width in mm)
    def line(self, pts, w):
        p = [self.px(*q) for q in pts]
        self.d.line(p, fill=255, width=max(1, int(round(w * self.k))), joint="curve")

    def rect(self, x0, z0, x1, z1, w=None):
        a, b = self.px(x0, z0), self.px(x1, z1)
        if w is None:
            self.d.rectangle([a, b], fill=255)
        else:
            self.d.rectangle([a, b], outline=255, width=max(1, int(round(w * self.k))))

    def disc(self, x, z, r, ring=None):
        cx, cy = self.px(x, z)
        rr = r * self.k
        if ring is None:
            self.d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=255)
        else:
            self.d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=255, width=max(1, int(round(ring * self.k))))

    def poly(self, pts):
        self.d.polygon([self.px(*q) for q in pts], fill=255)

    def dashed(self, a, b, dash, gap, w):
        (ax, az), (bx, bz) = a, b
        n = np.hypot(bx - ax, bz - az)
        ux, uz = (bx - ax) / n, (bz - az) / n
        t = 0.0
        while t < n:
            e = min(n, t + dash)
            self.line([(ax + ux * t, az + uz * t), (ax + ux * e, az + uz * e)], w)
            t += dash + gap

    def field(self):
        """The signed distance (mm, positive inside) of the drawing, written at PX_PER_MM."""
        m = np.asarray(self.img) > 127
        d_in = ndimage.distance_transform_edt(m)
        d_out = ndimage.distance_transform_edt(~m)
        sd = np.where(m, d_in - 0.5, -(d_out - 0.5)) / self.k              # mm
        sd = np.clip(sd, -RANGE_MM, RANGE_MM)
        h, w = sd.shape
        sd = sd.reshape(h // HI, HI, w // HI, HI).mean(axis=(1, 3))
        return np.clip(np.round((0.5 + sd / (2 * RANGE_MM)) * 255), 0, 255).astype(np.uint8)


def corners(S, x0, z0, x1, z1, w, arm):
    """Four L-shaped corner marks of a rectangle (a courtyard drawn in brackets)."""
    for (cx, cz, sx, sz) in ((x0, z0, 1, 1), (x1, z0, -1, 1), (x1, z1, -1, -1), (x0, z1, 1, -1)):
        S.line([(cx + sx * arm, cz), (cx, cz), (cx, cz + sz * arm)], w)


def tag(S, path, axes, text, x, z, size, k, rot=0):
    S.text(path, axes, k, {"text": text, "x": x, "z": z, "size": size, "rot": rot})


def marks(ch, S, G, path, axes, k):
    """Decoration per channel (board mm). Kept clear of the CPU zone."""
    B, P, D, J, SL = G["BOARD"], G["PACK"], G["DIP"], G["JACK"], G["SLOT"]
    if ch == "g":
        # a drawing sheet: a border frame with corner ticks, a title block, centre marks
        w = 0.34
        m = 1.5
        x0, z0, x1, z1 = B["x0"] + m, B["z0"] + m, B["x1"] - m, B["z1"] - m
        S.rect(x0, z0, x1, z1, w)
        for t in range(1, 6):                                                          # ruler ticks along the top edge
            tx = x0 + (x1 - x0) * t / 6.0
            S.line([(tx, z0), (tx, z0 + 1.1)], 0.18)
        for t in range(1, 5):
            tz = z0 + (z1 - z0) * t / 5.0
            S.line([(x1, tz), (x1 - 1.1, tz)], 0.18)
        bx0, bz0, bx1, bz1 = 22.0, z1 - 6.4, x1 - 0.1, z1 - 0.1                          # title block
        S.rect(bx0, bz0, bx1, bz1, w)
        S.line([(bx0 + 17.0, bz0), (bx0 + 17.0, bz1)], 0.2)
        S.line([(bx0, (bz0 + bz1) / 2), (bx1, (bz0 + bz1) / 2)], 0.2)
        tag(S, path, axes, "SILICON", bx0 + 8.5, bz0 + 1.7, 2.6, k)
        tag(S, path, axes, "N6506MV", bx0 + 8.5, bz1 - 1.5, 1.7, k)
        tag(S, path, axes, "SHEET 1/1", bx0 + 27.0, bz0 + 1.6, 1.7, k)
        tag(S, path, axes, "SCALE 1:1", bx0 + 27.0, bz1 - 1.5, 1.7, k)


def main():
    G = geometry()
    B = G["BOARD"]
    chans = {}
    boxes = {}
    for ch, (pattern, k, axes, sign) in FONTS.items():
        S = Sheet(B)
        path = font_file(pattern)
        for i, L in enumerate(G["LABELS"]):
            S.text(path, axes, k, dict(L, i=i, plain_zero=(ch == "r")), sign)
        for i, b in S.boxes.items():                                   # the union of the two faces: a label's box is what the board may not put anything on
            p = boxes.get(i, b)
            boxes[i] = (min(p[0], b[0]), min(p[1], b[1]), max(p[2], b[2]), max(p[3], b[3]))
        marks(ch, S, G, path, axes, k)
        chans[ch] = S.field()
    W, H = chans["r"].shape[1], chans["r"].shape[0]
    out = np.dstack([chans["r"], chans["g"], np.zeros_like(chans["r"])])
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    Image.fromarray(out, "RGB").save(OUT, optimize=True)
    # every label's real ink box (board mm): parts and traces are kept off it
    with open(BOXES, "w") as fh:
        json.dump([{"text": L["text"], "x0": round(boxes[i][0], 2), "z0": round(boxes[i][1], 2), "x1": round(boxes[i][2], 2), "z1": round(boxes[i][3], 2)}
                   for i, L in enumerate(G["LABELS"])], fh, indent=1)
        fh.write("\n")
    print("wrote", OUT, f"{W}x{H}", "labels", len(G["LABELS"]), "sdf range +-%.1f mm" % RANGE_MM)


if __name__ == "__main__":
    main()
