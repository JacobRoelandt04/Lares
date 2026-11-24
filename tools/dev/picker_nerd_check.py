#!/usr/bin/env python3
"""picker_nerd_check.py -- the unit check of tools/picker/nerd_fetch.py (run by tools/dev/picker_probe.sh; `NC ok|FAIL <what>`, then `NC RESULT`).

  * the coverage filter: a code point the font lacks is dropped, one it draws is kept (a made-up cmap), names that share a character are one row
    (the first group's name wins, the others are searchable `other names`), a `nf-` prefix on a key is tolerated;
  * the version is read from the name table the way a Nerd Font writes it ("Version 001.000;Nerd Fonts 3.5.1") and a font with no Nerd Fonts
    version is refused, not guessed;
  * the real thing: the list for 3.5.1 (tools/dev/fixtures/glyphnames-3.5.1.json, byte-for-byte what raw.githubusercontent.com answered)
    against the INSTALLED font's cmap: the kept count is exactly the list's distinct characters the font draws, and the count is printed.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(HERE, "..", "picker"))
import nerd_fetch as nf  # noqa: E402

fails = 0
checks = 0


def check(ok, what):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
    print("NC %s %s" % ("ok " if ok else "FAIL", what))


class Rec:
    def __init__(self, nid, s):
        self.nameID, self.platformID, self._s = nid, 3, s

    def toUnicode(self):
        return self._s


def fake_font(*recs):
    class F(dict):
        pass
    f = F()
    f["name"] = type("N", (), {"names": [Rec(i, s) for i, s in recs]})()
    return f


# ---- the filter, on a made-up font ---------------------------------------------------------------------------------------
raw = {
    "METADATA": {"version": "9.9.9"},
    "md-home": {"char": "\U000f02dc", "code": "f02dc"},
    "md-lightbulb_on": {"char": "\U000f06e8", "code": "f06e8"},
    "fa-home": {"char": "\U000f02dc", "code": "f02dc"},       # the same character under another group
    "custom-home": {"char": "", "code": "e5fd"},
    "md-lacking": {"char": "一", "code": "4e00"},          # a character the made-up font does not draw
    "nf-oct-rocket": {"char": "", "code": "f427"},       # a key that already has the prefix
}
cmap = {0xF02DC, 0xF06E8, 0xE5FD, 0xF427}
a = nf.build_asset(raw, cmap, "9.9.9", "Made Up", {"path": "x", "size": 1, "mtime": 1})
names = {r[1]: r for r in a["rows"]}
check("nf-md-lacking" not in names and all(r[0] != "一" for r in a["rows"]), "a code point the font lacks is dropped")
check(a["dropped"] == 1, "the drop is counted (%d)" % a["dropped"])
check(all(ord(r[0]) in cmap for r in a["rows"]) and len(a["rows"]) == 4, "every kept row is a character the font draws (%d rows)" % len(a["rows"]))
check("nf-md-home" in names and "nf-fa-home" not in names and "nf-fa-home" in names["nf-md-home"][4].split(), "names sharing a character are one row: the first group's name, the other searchable")
check("nf-oct-rocket" in names and names["nf-oct-rocket"][1] == "nf-oct-rocket", "a key with the nf- prefix is not doubled")
check(len(set(r[2] for r in a["rows"])) == len(a["sets"]) and all(0 <= r[2] < len(a["sets"]) for r in a["rows"]), "every set has rows and every row a set")

# ---- the version ---------------------------------------------------------------------------------------------------------
v, where = nf.read_version(fake_font((5, "Version 001.000;Nerd Fonts 3.5.1"), (1, "Symbols Nerd Font")))
check(v == "3.5.1", "the version is read from the name table's version string (%s)" % v)
v, where = nf.read_version(fake_font((3, "Symbols Nerd Font 3.2.0"), (1, "Symbols Nerd Font")))
check(v == "3.2.0", "else from the unique name (%s)" % v)
v, where = nf.read_version(fake_font((5, "Version 2.137;Arial"), (1, "Arial")))
check(v is None, "a font with no Nerd Fonts version is refused, never guessed (%s)" % where)

# ---- the real font against the real list ----------------------------------------------------------------------------------
font_path = nf.find_font("")
if font_path is None:
    check(False, "no Nerd Font is installed here, so the real list cannot be judged")
else:
    font = nf.load_ttfont(font_path)
    cm = set(font.getBestCmap().keys())
    version, read = nf.read_version(font)
    check(version is not None, "the installed font says its version: %s (%s)" % (version, read))
    with open(os.path.join(HERE, "fixtures", "glyphnames-3.5.1.json"), encoding="utf-8") as f:
        real = json.load(f)
    entries = [(k, v["char"]) for k, v in real.items() if k != "METADATA"]
    chars = set(c for _, c in entries)
    want = len([c for c in chars if len(c) == 1 and ord(c) in cm])
    out = nf.build_asset(real, cm, "3.5.1", "x", {})
    check(len(entries) == 10995, "the list for 3.5.1 has 10995 names (%d)" % len(entries))
    check(len(out["rows"]) == want, "the rows are exactly the list's distinct characters the font draws: %d of %d (%d names dropped, %d characters the font lacks)"
          % (len(out["rows"]), len(chars), out["dropped"], len(chars) - want))
    check(all(ord(r[0]) in cm for r in out["rows"]), "no row is a character the font lacks")
    check(len(out["rows"]) == len(set(r[0] for r in out["rows"])), "no character is in the asset twice")

print("NC RESULT %s (%d/%d checks)" % ("PASS" if fails == 0 and checks > 0 else "FAIL", checks - fails, checks))
sys.exit(1 if fails else 0)
