#!/usr/bin/env python3
"""
check_glyphs.py -- every glyph the wiki names is in the font it names.

    tools/wiki/check_glyphs.py [--families FILE]

modules/wiki/data/families.json names one codepoint per family (the title row's
glyph: the 13 Discover families, the computing guest, the Deepen families) and
one per mark (generated, edited, more, less, ...), all in the font `font.file`
says. A codepoint the font lacks draws as an empty box. Exits 0 with one `ok`
line, 1 with the missing ones listed. Nothing is written.

(The families' glyphs were once baked into carved textures for the picture well
of an article with no picture; that well now shows the article's veil --
modules/wiki/WikiVeil.qml -- and the textures are gone.)
"""

import argparse
import json
import os
import sys

from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def load_families(path):
    with open(path, encoding="utf-8") as fh:
        fam = json.load(fh)
    entries = []
    for e in fam.get("discover", []):
        entries.append((e["id"], e["glyph"]))
    if fam.get("guest"):
        entries.append((fam["guest"]["id"], fam["guest"]["glyph"]))
    for e in fam.get("deepen", []):
        entries.append((e["id"], e["glyph"]))
    return fam, entries


def missing(font_path, fam, entries):
    """The codepoints the JSON names that the font does not have."""
    cmap = TTFont(font_path, lazy=True).getBestCmap()
    bad = []
    for fid, hx in entries:
        if int(hx, 16) not in cmap:
            bad.append(f"family {fid}: U+{hx.upper()}")
    for name, hx in (fam.get("marks") or {}).items():
        if int(hx, 16) not in cmap:
            bad.append(f"mark {name}: U+{hx.upper()}")
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--families", default=os.path.join(ROOT, "modules/wiki/data/families.json"))
    a = ap.parse_args()

    fam, entries = load_families(a.families)
    font_path = fam["font"]["file"]
    if not os.path.exists(font_path):
        raise SystemExit(f"font not found: {font_path}")
    bad = missing(font_path, fam, entries)
    if bad:
        print("codepoints missing from " + font_path + ":", file=sys.stderr)
        for line in bad:
            print("  " + line, file=sys.stderr)
        return 1
    print(f"ok: {len(entries)} family glyphs and {len(fam.get('marks') or {})} marks are in {os.path.basename(font_path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
