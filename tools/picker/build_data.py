#!/usr/bin/env python3
"""build_data.py -- writes modules/picker/data/picker_data.json, the picker's data asset.

    tools/picker/build_data.py [--rofimoji <dir>] [--out <file>] [--oem cp437] [--ansi cp1252] [--check]

The asset is COMMITTED, so the shell never needs rofimoji at run time; this tool runs only when the data is to be refreshed.

Sources:
  * rofimoji's data directory (default: the installed package, /usr/lib/python3*/site-packages/picker): the emoji files
    (`emojis_*.csv`: `<char> <name> <small>(<kw>, ...)</small>`), their extra keywords (`data/additional/`), the skin-tone base
    set (`emoji_data.py`), `kaomoji.csv` and the symbol blocks the Symbols tab offers (math, arrows, currency, Greek).
  * Python's codecs for the Alt-code tables: Alt+nnn is the OEM code page (cp437 by default: the user's decision; a Dutch Windows
    uses cp850, `--oem cp850` rebuilds it), Alt+0nnn the ANSI one (cp1252). Alt+1..31 and Alt+127 are the IBM graphic symbols
    (no Python codec has them), written out here.

A row with a character no installed font covers is DROPPED (a kaomoji whose U+FF65 nothing draws shows as `|ω )`): the count per set is printed
and recorded in `source`; `--keep-uncovered` keeps them (install noto-fonts-cjk and rebuild to get the CJK ones back).

Output (one JSON object, compact):
  version, source{rofimoji, unicode, oem, ansi}, tones[{mod, name}] (the five Fitzpatrick modifiers),
  emoji{cats[{id,label,glyph}], rows[[char, name, keywords, cat, tonable]]},
  symbols{sets[{id,label,glyph,tile,rows}]}  rows are [char, name] (alt: [char, name, [codes]]; kaomoji: [char, keyword]).

`--check` reads the existing asset and exits 1 when it differs from what would be written (nothing is written).
It fails with a clear message when rofimoji's data is not there.
"""
import argparse
import ast
import glob
import json
import os
import re
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "..", "modules", "picker", "data", "picker_data.json")

EMOJI_FILES = [
    ("smileys", "Smileys & emotion", "\U0001F600", "emojis_smileys_emotion"),
    ("people", "People & body", "\U0001F9D1", "emojis_people_body"),
    ("animals", "Animals & nature", "\U0001F43B", "emojis_animals_nature"),
    ("food", "Food & drink", "\U0001F354", "emojis_food_drink"),
    ("travel", "Travel & places", "✈️", "emojis_travel_places"),
    ("activities", "Activities", "⚽", "emojis_activities"),
    ("objects", "Objects", "\U0001F4A1", "emojis_objects"),
    ("symbols", "Symbols", "\U0001F523", "emojis_symbols"),
    ("flags", "Flags", "\U0001F3C1", "emojis_flags"),
]

# Symbol sets: (id, label, glyph, tile profile, files, extra characters taken from other files).
SYMBOL_SETS = [
    ("math", "Math", "∑", "symbol",
     ["mathematical_operators", "miscellaneous_mathematical_symbols-a", "superscripts_and_subscripts", "number_forms"],
     "±×÷¬¼½¾²³¹µ°"),
    ("arrows", "Arrows", "→", "symbol", ["arrows", "supplemental_arrows-a", "supplemental_arrows-b"], ""),
    ("currency", "Currency", "€", "symbol", ["currency_symbols"], "$¢£¤¥"),
    ("greek", "Greek", "Ω", "symbol", ["greek_and_coptic"], ""),
]

# Alt+1..31 and Alt+127 in an OEM console: the IBM graphic set (code page 437's control-position glyphs).
IBM_GRAPHIC = "☺☻♥♦♣♠•◘○◙♂♀♪♫☼" \
              "►◄↕‼¶§▬↨↑↓→←∟↔▲▼"

FITZPATRICK = [("\U0001F3FB", "light skin"), ("\U0001F3FC", "medium-light skin"), ("\U0001F3FD", "moderate skin"),
               ("\U0001F3FE", "dark brown skin"), ("\U0001F3FF", "black skin")]
VS16 = "️"
ZWJ = "‍"


def die(msg):
    sys.stderr.write("build_data.py: %s\n" % msg)
    sys.exit(2)


def find_rofimoji(arg):
    cands = [arg] if arg else sorted(glob.glob("/usr/lib/python3*/site-packages/picker"))
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "emoji_data.py")) and os.path.isdir(os.path.join(c, "data")):
            return os.path.abspath(c)
    die("rofimoji's data is not there (looked in %s). Install rofimoji, or pass --rofimoji <the package's `picker` directory>."
        % (", ".join(c for c in cands if c) or "/usr/lib/python3*/site-packages/picker"))


def rofimoji_version(pkg):
    for d in glob.glob(os.path.join(os.path.dirname(pkg), "rofimoji-*.dist-info")):
        try:
            for line in open(os.path.join(d, "METADATA"), encoding="utf-8"):
                if line.startswith("Version:"):
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return "unknown"


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return [l for l in f.read().strip("\n").split("\n") if l.strip() != ""]


def skin_bases(pkg):
    """The Emoji_Modifier_Base set rofimoji ships (emoji_data.py), read without importing the package."""
    tree = ast.parse(open(os.path.join(pkg, "emoji_data.py"), encoding="utf-8").read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "skin_tone_selectable_emojis":
            return set(ast.literal_eval(node.value))
    die("emoji_data.py has no skin_tone_selectable_emojis")


def strip_vs(s):
    return s.replace(VS16, "")


def tonable(ch, bases):
    """A base person/hand, or base + ZWJ + non-person elements only (profession, gender sign, hair, a direction).
    Not families / couples (a single tone is no valid sequence there)."""
    parts = ch.split(ZWJ)
    first = strip_vs(parts[0])
    # U+1F46A FAMILY is an Emoji_Modifier_Base with no RGI toned sequence: a modifier after it draws as a separate swatch.
    if len(first) != 1 or first not in bases or first == "\U0001F46A":
        return False
    if len(parts) == 1:
        return True
    return all(len(strip_vs(p)) == 1 and strip_vs(p) not in bases for p in parts[1:])


def words(s):
    return [w for w in re.split(r"[\s,]+", s.lower()) if w]


def build_emoji(pkg, bases):
    cats, rows, seen = [], [], {}
    for ci, (cid, label, glyph, stem) in enumerate(EMOJI_FILES):
        cats.append({"id": cid, "label": label, "glyph": glyph})
        extra = {}
        add = os.path.join(pkg, "data", "additional", stem + ".csv")
        if os.path.isfile(add):
            for line in read_lines(add):
                ch, _, kw = line.partition(" ")
                extra.setdefault(ch, []).extend(words(kw))
        for line in read_lines(os.path.join(pkg, "data", stem + ".csv")):
            m = re.match(r"^(\S+) (.*?)(?: <small>\((.*)\)</small>)?$", line)
            if not m:
                continue
            ch, name, kw = m.group(1), m.group(2).strip(), m.group(3) or ""
            toks = []
            for w in words(kw) + extra.get(ch, []):
                if w not in toks and w not in words(name):
                    toks.append(w)
            if ch in seen:
                rows[seen[ch]][2] = " ".join(dict.fromkeys(rows[seen[ch]][2].split() + toks))
                continue
            seen[ch] = len(rows)
            rows.append([ch, name, " ".join(toks), ci, 1 if tonable(ch, bases) else 0])
    return {"cats": cats, "rows": rows}


def printable(ch):
    cat = unicodedata.category(ch[0])
    return not (cat in ("Zs", "Zl", "Zp", "Cc", "Cf", "Cn", "Co", "Cs", "Mn", "Me", "Mc") or ch.isspace())


def build_symbol_set(pkg, sid, label, glyph, tile, files, extra_chars):
    rows, seen = [], set()
    names = {}
    # the extra characters come first (the ones people reach for), named from the Latin files
    for f in ("latin-1_supplement", "basic_latin"):
        for line in read_lines(os.path.join(pkg, "data", f + ".csv")):
            ch, _, nm = line.partition(" ")
            names[ch] = nm
    for ch in extra_chars:
        if ch in names and ch not in seen and printable(ch):
            seen.add(ch)
            rows.append([ch, names[ch].lower()])
    for f in files:
        for line in read_lines(os.path.join(pkg, "data", f + ".csv")):
            ch, _, nm = line.partition(" ")
            if ch in seen or not printable(ch):
                continue
            seen.add(ch)
            rows.append([ch, nm.lower()])
    return {"id": sid, "label": label, "glyph": glyph, "tile": tile, "rows": rows}


def build_alt(oem, ansi):
    """One row per character: [char, name, [codes]]. Alt+nnn (OEM) codes first, then Alt+0nnn (ANSI); ASCII is typable and left out."""
    by_char, order = {}, []

    def put(ch, code):
        if ch not in by_char:
            by_char[ch] = []
            order.append(ch)
        by_char[ch].append(code)

    for n in range(1, 32):
        put(IBM_GRAPHIC[n - 1], "%d" % n)
    put("⌂", "127")
    for n in range(128, 256):
        try:
            ch = bytes([n]).decode(oem)
        except UnicodeDecodeError:
            continue
        if printable(ch):
            put(ch, "%d" % n)
    for n in range(128, 256):
        try:
            ch = bytes([n]).decode(ansi)
        except UnicodeDecodeError:
            continue
        if printable(ch):
            put(ch, "0%d" % n)
    rows = []
    for ch in order:
        try:
            nm = unicodedata.name(ch).lower()
        except ValueError:
            nm = ""
        rows.append([ch, nm, by_char[ch]])
    return {"id": "alt", "label": "Alt codes", "glyph": "⌨", "tile": "alt", "rows": rows}


def build_kaomoji(pkg):
    rows, seen = [], set()
    for line in read_lines(os.path.join(pkg, "data", "kaomoji.csv")):
        ch, _, kw = line.partition(" ")
        if ch in seen:
            continue
        seen.add(ch)
        rows.append([ch, kw.strip()])
    return {"id": "kaomoji", "label": "Kaomoji", "glyph": "ツ", "tile": "wide", "rows": rows}


# Code points that join or select and are drawn by no glyph of their own: never judged on their own.
JOINERS = {0xFE0F, 0xFE0E, 0x200D, 0x20E3}


def covered_codepoints():
    """Every code point an installed font covers, from fontconfig (`fc-list --format %{charset}`: ranges in hex)."""
    try:
        out = subprocess.run(["fc-list", "--format", "%{charset}\\n"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        die("fontconfig is not answering (%s): pass --keep-uncovered to build without the coverage check" % e)
    have = set()
    for line in out.splitlines():
        for tok in line.split():
            lo, _, hi = tok.partition("-")
            have.update(range(int(lo, 16), int(hi or lo, 16) + 1))
    if not have:
        die("fontconfig lists no fonts: pass --keep-uncovered to build without the coverage check")
    return have


def drop_uncovered(rows, have):
    """Rows whose text has a code point no installed font draws (a tile would show a box, or lose the character)."""
    kept = [r for r in rows if all(ord(c) in have or ord(c) in JOINERS for c in r[0])]
    return kept, len(rows) - len(kept)


def build(args):
    pkg = find_rofimoji(args.rofimoji)
    bases = skin_bases(pkg)
    sets = [build_alt(args.oem, args.ansi)]
    for sid, label, glyph, tile, files, extra in SYMBOL_SETS:
        sets.append(build_symbol_set(pkg, sid, label, glyph, tile, files, extra))
    sets.append(build_kaomoji(pkg))
    emoji = build_emoji(pkg, bases)
    dropped = {}
    if not args.keep_uncovered:
        have = covered_codepoints()
        emoji["rows"], n = drop_uncovered(emoji["rows"], have)
        dropped["emoji"] = n
        for st in sets:
            st["rows"], n = drop_uncovered(st["rows"], have)
            dropped[st["id"]] = n
        sys.stderr.write("dropped (a character no installed font covers): %s\n" % ", ".join("%s %d" % kv for kv in dropped.items()))
    source = {"rofimoji": rofimoji_version(pkg), "unicode": unicodedata.unidata_version, "oem": args.oem, "ansi": args.ansi,
              "coverage": "kept" if args.keep_uncovered else "a row with a code point no installed font covers (fontconfig charsets) is dropped",
              "dropped": dropped}
    return {
        "version": 1,
        "source": source,
        "tones": [{"mod": m, "name": n} for m, n in FITZPATRICK],
        "emoji": emoji,
        "symbols": {"sets": sets},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rofimoji", help="rofimoji's `picker` package directory (default: the installed one)")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--oem", default="cp437", help="the Alt+nnn code page (cp437; cp850 on a Western European Windows)")
    ap.add_argument("--ansi", default="cp1252", help="the Alt+0nnn code page")
    ap.add_argument("--keep-uncovered", action="store_true", help="keep rows whose characters no installed font covers (they draw as a box or lose characters)")
    ap.add_argument("--check", action="store_true", help="exit 1 when the asset on disk differs; write nothing")
    args = ap.parse_args()
    text = json.dumps(build(args), ensure_ascii=False, separators=(",", ":")) + "\n"
    out = os.path.abspath(args.out)
    if args.check:
        same = os.path.isfile(out) and open(out, encoding="utf-8").read() == text
        print("picker_data.json %s" % ("is current" if same else "DIFFERS from what rofimoji's data builds"))
        sys.exit(0 if same else 1)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    d = json.loads(text)
    print("wrote %s (%d KB): %d emoji, %s" % (out, len(text) // 1024, len(d["emoji"]["rows"]),
          ", ".join("%s %d" % (s["id"], len(s["rows"])) for s in d["symbols"]["sets"])))


if __name__ == "__main__":
    main()
