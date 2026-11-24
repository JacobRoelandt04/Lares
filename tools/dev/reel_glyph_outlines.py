#!/usr/bin/env python3
"""reel_glyph_outlines.py -- the reels' glyph outlines, from the font, as the JS literals ReelFlourish.js (the power reel) and
IdleFlourish.js (the idle reel) carry.

    python3 tools/dev/reel_glyph_outlines.py            prints ReelFlourish.js's `var OUTLINES = {...};` (font units, y up, the pen at 0,0)
    python3 tools/dev/reel_glyph_outlines.py --idle     prints IdleFlourish.js's
    python3 tools/dev/reel_glyph_outlines.py --check    exits 1 when either file's copy differs from the font's

The flourishes draw the moving parts of a glyph as vector shapes (modules/bar/reel/ReelFlourish.js): at rest the reel draws
the font's own Text, so the shapes must be the font's outlines exactly. A TrueType contour's run of off-curve points is
split at the implied on-curve midpoints, so every command is M, L, Q or Z.
"""
import json, re, sys
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen

FONT = "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf"
GLYPHS = {"sleep": 0xF0904, "poweroff": 0xF0425, "reboot": 0xF0709, "hibernate": 0xF0717, "logout": 0xF0343, "lock": 0xF033E}
# the idle reel's (modules/shell/ReelItems.js IDLE): md-sleep, md-weather_sunset_down, md-coffee, md-infinity
IDLE_GLYPHS = {"zzz": 0xF04B2, "sunset": 0xF059B, "mug": 0xF0176, "infinity": 0xF06E4}
FILES = {"power": ("modules/bar/reel/ReelFlourish.js", GLYPHS), "idle": ("modules/bar/reel/IdleFlourish.js", IDLE_GLYPHS)}


class Cmds(BasePen):
    def __init__(self, gs):
        super().__init__(gs)
        self.out = []

    def _moveTo(self, p):
        self.out.append(["M", p[0], p[1]])

    def _lineTo(self, p):
        self.out.append(["L", p[0], p[1]])

    def _qCurveToOne(self, p1, p2):
        self.out.append(["Q", p1[0], p1[1], p2[0], p2[1]])

    def _curveToOne(self, p1, p2, p3):
        raise SystemExit("cubic curve in a TrueType glyph?")

    def _closePath(self):
        self.out.append(["Z"])


def outlines(glyphs):
    f = TTFont(FONT)
    gs, cmap = f.getGlyphSet(), f.getBestCmap()
    res = {"upm": f["head"].unitsPerEm}
    for name, cp in glyphs.items():
        pen = Cmds(gs)
        gs[cmap[cp]].draw(pen)
        cmds = [[c[0]] + [round(v, 2) for v in c[1:]] for c in pen.out]
        res[name] = {"advance": gs[cmap[cp]].width, "cmds": cmds}
    return res


def literal(glyphs):
    return "var OUTLINES = " + json.dumps(outlines(glyphs), separators=(",", ":")) + ";"


if __name__ == "__main__":
    if "--check" in sys.argv:
        bad = []
        for which, (rel, glyphs) in FILES.items():
            js = (Path(__file__).resolve().parents[2] / rel).read_text()
            m = re.search(r"^var OUTLINES = .*;$", js, re.M)
            if m is None or m.group(0) != literal(glyphs):
                bad.append(rel)
        print("REEL_OUTLINES RESULT " + ("PASS" if not bad else "FAIL (" + ", ".join(bad) + ": OUTLINES differ from the font's: rerun this tool)"))
        sys.exit(0 if not bad else 1)
    print(literal(IDLE_GLYPHS if "--idle" in sys.argv else GLYPHS))
