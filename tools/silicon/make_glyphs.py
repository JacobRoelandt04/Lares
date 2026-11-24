#!/usr/bin/env python3
"""make_glyphs.py -- the glyph atlas for the figures PRINTED on the board and the time display's three labels.

    tools/silicon/make_glyphs.py            writes modules/silicon/assets/silk_glyphs.png

The layout comes from SceneGeometry.js (GLYPHS, MODE_LABEL, MODE_LABELS) and nowhere else; board_materials.glsl reads the same
numbers (silicon_shader_gen.js emits GLYPH_*). Row 0 holds the characters of GLYPHS.chars, one GLYPHS.cell mm cell each; the labels
follow, one MODE_LABEL cell each, left aligned. GLYPHS.texels texels per mm. One channel per family, each in that family's lettering
exactly as make_silkscreen.py draws the static labels (R Material: Audiowide, G Blueprint: Bahnschrift), and in the silkscreen's
encoding: a signed distance, 0.5 the edge, +-RANGE_MM either side, so a figure is crisp at any zoom and an engraving's bevel is a distance.

A digit is centred in its cell by its own ink, so a slot reads the same whatever it holds, and is DIGIT_H tall. Audiowide's zero is
SLASHED (it reads like a 2 at the size of a printed figure), so the Material channel's zero is the letter O cut to the width of the face's
eight; the minus is a bar of the same stroke the board's own `+` and minus signs use.
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_silkscreen as ms  # noqa: E402

OUT = os.path.join(ms.ROOT, "modules/silicon/assets/silk_glyphs.png")
BOXES = os.path.join(ms.ROOT, "modules/silicon/assets/silk_glyphs.json")
HI = 3                  # supersampling
RANGE = ms.RANGE_MM


def field(img, texels):
    """The signed distance (mm, + inside) of a binary image drawn at texels * HI per mm, written at `texels` per mm."""
    m = np.asarray(img) > 127
    d_in = ndimage.distance_transform_edt(m)
    d_out = ndimage.distance_transform_edt(~m)
    sd = np.where(m, d_in - 0.5, -(d_out - 0.5)) / (texels * HI)
    sd = np.clip(sd, -RANGE, RANGE)
    h, w = sd.shape
    sd = sd.reshape(h // HI, HI, w // HI, HI).mean(axis=(1, 3))
    return np.clip(np.round((0.5 + sd / (2 * RANGE)) * 255), 0, 255).astype(np.uint8)


def ink_tile(font, text):
    b = font.getbbox(text)
    tile = Image.new("L", (b[2] - b[0] + 8, b[3] - b[1] + 8), 0)
    ImageDraw.Draw(tile).text((4 - b[0], 4 - b[1]), text, fill=255, font=font)
    return tile.crop(tile.getbbox())


def digit_cell(G, path, axes, ch, ch_zero_from_o):
    k = G["GLYPHS"]["texels"] * HI
    cw, chh = G["GLYPHS"]["cell"]
    w, h = int(round(cw * G["GLYPHS"]["texels"])) * HI, int(round(chh * G["GLYPHS"]["texels"])) * HI
    img = Image.new("L", (w, h), 0)
    cx, cy = w / 2, h / 2
    if ch == "-":
        t = 0.62 * k
        half = 1.15 * k
        ImageDraw.Draw(img).rectangle([cx - half, cy - t / 2, cx + half, cy + t / 2], fill=255)
        return img
    # size the font so a digit is DIGIT_H tall
    probe = ms.load_font(path, 200, axes)
    b = probe.getbbox("8")
    size = max(8, int(round(200 * G["GLYPHS"]["digitH"] * k / (b[3] - b[1]))))
    font = ms.load_font(path, size, axes)
    tile = ink_tile(font, ch)
    if ch == "0" and ch_zero_from_o:
        # the letter O, resized to the eight's ink box: a plain zero
        eight = ink_tile(font, "8")
        tile = ink_tile(font, "O").resize(eight.size, Image.LANCZOS)
    img.paste(255, (int(round(cx - tile.width / 2)), int(round(cy - tile.height / 2))), tile)
    return img


def label_cell(G, path, axes, size_per_mm, text, sign):
    k = G["GLYPHS"]["texels"] * HI
    lw, lh = G["MODE_LABEL"]["w"], G["MODE_LABEL"]["h"]
    w, h = int(round(lw * G["GLYPHS"]["texels"])) * HI, int(round(lh * G["GLYPHS"]["texels"])) * HI
    img = Image.new("L", (w, h), 0)
    px = max(8, int(round(G["MODE_LABEL"]["size"] * size_per_mm * k)))
    font = ms.load_font(path, px, axes)
    b = font.getbbox(text)
    tile = Image.new("L", (b[2] - b[0] + 8, b[3] - b[1] + 8), 0)
    ImageDraw.Draw(tile).text((4 - b[0], 4 - b[1]), text, fill=255, font=font)
    img.paste(255, (int(round((w - tile.width) / 2)), int(round((h - tile.height) / 2))), tile)
    return img, (b[2] - b[0]) / k, (b[3] - b[1]) / k


def main():
    G = ms.geometry()
    Gl, M = G["GLYPHS"], G["MODE_LABEL"]
    t = Gl["texels"]
    cw, chh = int(round(Gl["cell"][0] * t)), int(round(Gl["cell"][1] * t))
    lw, lh = int(round(M["w"] * t)), int(round(M["h"] * t))
    atlas_w = len(Gl["chars"]) * cw
    atlas_h = chh + len(G["MODE_LABELS"]) * lh
    chans = {}
    mode = [[0.0, 0.0] for _ in G["MODE_LABELS"]]
    for ch, (pattern, k, axes, sign) in ms.FONTS.items():
        path = ms.font_file(pattern)
        plane = np.zeros((atlas_h, atlas_w), np.uint8)
        # outside every cell the field is "far outside" (0.0): a sample beyond a glyph's cell reads as no ink
        for i, c in enumerate(Gl["chars"]):
            plane[0:chh, i * cw:(i + 1) * cw] = field(digit_cell(G, path, axes, c, ch == "r"), t)[:chh, :cw]
        for j, text in enumerate(G["MODE_LABELS"]):
            cell, iw, ih = label_cell(G, path, axes, k, text, sign)
            plane[chh + j * lh:chh + (j + 1) * lh, 0:lw] = field(cell, t)[:lh, :lw]
            mode[j] = [max(mode[j][0], iw), max(mode[j][1], ih)]
        chans[ch] = plane
    out = np.dstack([chans["r"], chans["g"], np.zeros_like(chans["r"])])
    Image.fromarray(out, "RGB").save(OUT, optimize=True)
    # the labels' real ink size (the larger of the two faces), centred in the label's rect: the boxes parts and traces are kept off
    with open(BOXES, "w") as fh:
        json.dump([{"text": t, "w": round(mode[j][0], 3), "h": round(mode[j][1], 3)} for j, t in enumerate(G["MODE_LABELS"])], fh, indent=1)
        fh.write("\n")
    print("wrote", OUT, f"{atlas_w}x{atlas_h}", "chars", Gl["chars"], "labels", G["MODE_LABELS"])


if __name__ == "__main__":
    main()
