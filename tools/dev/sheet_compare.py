#!/usr/bin/env python3
"""sheet_compare.py -- the three judges of tools/dev/sheet_check.sh. Each prints one line per finding and exits 1 when there is one.

    sheet_compare.py sheet <base> <new> [--expect <file>]     the pictures: composited on black, a pixel is moved when ANY channel moved
    sheet_compare.py logs  <base> <new>                       the logs: no new warning line, none of the kinds that always fail
    sheet_compare.py map   <map.json> [--step cN]             no reference to a moved or deleted name left (<map.json>: {old: new | null}, or a stage's
                                                              {"deleted": [...], "moved": {old: new}, "map_exclusions": {...}} record, or C2's {"deleted_files": [...],
                                                              "deleted_properties": {file: [prop, ...]}, ...})

THE PICTURES. <base>/png and <new>/png hold one PNG per state. There is no tolerance: one level in one channel of one pixel is a moved
pixel. A state's `mask` rows (tools/dev/sheet_states.txt) are left out of both. `--expect` names what a step changes on purpose, one line
per state or family: `<regex> <reason>`; a state it covers is reported as `stated` and does not fail, one it covers that did not
move is reported, so that a stale line is seen. <new>/report.txt has every state's count, <new>/moved.txt the states that moved and no line covers, <new>/diff/<state>.png
shows where (tools/dev/sheet_check.sh renders those again before it believes them).

THE LOGS. A line of interest is a WARN or ERROR line or one of the kinds below, with its colour codes, numbers, addresses and scratch
paths normalised, so that the same warning from another pointer is the same line. A line that was not in the baseline fails; the
kinds in ALWAYS fail in any log, baseline or not. <new>/warnings.txt is the whole table (state count, line, first state).

THE MAP. {"old/path": "new/path" | null, ...}; a key that ends in / is a directory. Searched: modules shell.qml tools helpers lock mockups
themes assets (those that exist). A hit in code fails. A hit in a comment is listed in <out>/map_comment_hits.txt and fails only from
step c7 on: C7 is the step that rewrites comments, and until then a comment naming a deleted gate is a known leftover, not a fault.
A moved file is looked for by its path; a deleted one also by its own name (`Foo.qml`, and `Foo` as a word for a QML or JS type).
A deleted property is looked for as a word in its own file, and in every other file (mockups/, tools/dev/ and mockup_profiles/ too: panel
specs and profiles name properties by string) that does not declare a property of that name itself.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "dev"))
INTEREST = re.compile(r"^\s*(WARN|ERROR)\b|Unable to assign|is not a type|[Bb]inding loop|No such file|Cannot open|Failed to load|Cannot assign|non-existent property|TypeError|ReferenceError|Cannot read property|is not defined|file not found", re.I)
ALWAYS = re.compile(r"Unable to assign|is not a type|[Bb]inding loop|No such file|Cannot open|Failed to load|file not found", re.I)
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def load(path):
    import numpy as np
    from PIL import Image
    im = Image.open(path).convert("RGBA")
    ground = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return np.asarray(Image.alpha_composite(ground, im).convert("RGB"), dtype=np.int16)


def read_expect(path):
    rows = []
    if path:
        for raw in open(path, encoding="utf-8"):
            line = raw.strip()
            if line and not line.startswith("#"):
                rx, _, why = line.partition(" ")
                rows.append((re.compile(rx), why.strip() or "(no reason given)"))
    return rows


def sheet(base, new, expect):
    import numpy as np
    from PIL import Image
    import sheet_render
    masks = {s["name"]: s["masks"] for s in sheet_render.parse_rows()}
    rows = read_expect(expect)
    names_b = {f[:-4] for f in os.listdir(os.path.join(base, "png")) if f.endswith(".png")}
    pn = os.path.join(new, "png")                    # a render that made nothing (every state asked for is gone) has no png dir:
    names_n = {f[:-4] for f in os.listdir(pn) if f.endswith(".png")} if os.path.isdir(pn) else set()   # all gone, not a crash
    only = os.environ.get("ONLY")
    if only:
        names_b = {n for n in names_b if re.search(only, n)}
    moved, stated, gone, fresh, still = [], [], [], [], 0
    report = []
    used = set()
    os.makedirs(os.path.join(new, "diff"), exist_ok=True)

    def covered(n):
        for i, (rx, why) in enumerate(rows):
            if rx.search(n):
                used.add(i)
                return why
        return None
    for n in sorted(names_b | names_n):
        why = covered(n)
        if n not in names_n:
            (stated if why else gone).append((n, "no picture", why))
            continue
        if n not in names_b:
            (stated if why else fresh).append((n, "no baseline", why))
            continue
        a, b = load(f"{base}/png/{n}.png"), load(f"{new}/png/{n}.png")
        if a.shape != b.shape:
            (stated if why else moved).append((n, f"size {a.shape[1]}x{a.shape[0]} -> {b.shape[1]}x{b.shape[0]}", why))
            continue
        d = (a != b).any(axis=2)
        for m in masks.get(n, []):
            if m.get("scale") and not n.endswith("." + m["scale"] + "x"):
                continue                    # a mask names a fault of one scale and leaves the other states whole
            x, y, w, h = m["rect"]
            d[y:y + h, x:x + w] = False
        px = int(d.sum())
        report.append(f"{px:8d}  {n}")
        if px == 0:
            still += 1
            if why:
                print(f"NOTE {n}: stated ({why}) and did not move")
            continue
        ys, xs = np.where(d)
        level = int(np.abs(a - b).max(axis=2)[d].max())
        words = f"{px} px, box {xs.min()},{ys.min()} {xs.max() - xs.min() + 1}x{ys.max() - ys.min() + 1}, up to {level} levels"
        if why:
            stated.append((n, words, why))
            continue
        moved.append((n, words, None))
        Image.fromarray((d * 255).astype("uint8")).save(f"{new}/diff/{n}.png")
    for n, words, why in stated:
        print(f"STATED {n}: {words} ({why})")
    for i, (rx, why) in enumerate(rows):
        if i not in used:
            print(f"NOTE the expect line {rx.pattern!r} covers no state")
    for n, words, _ in moved:
        print(f"MOVED {n}: {words}")
    for n, words, _ in gone:
        print(f"GONE {n}: {words}")
    for n, words, _ in fresh:
        print(f"NEW {n}: {words}")
    with open(os.path.join(new, "report.txt"), "w") as f:          # every state compared: its moved pixels
        f.write("\n".join(report) + "\n")
    with open(os.path.join(new, "moved.txt"), "w") as f:
        for n, _, _ in moved + gone:
            f.write(n + "\n")
    bad = len(moved) + len(gone) + len(fresh)
    print(f"SHEET {still} states still, {len(moved)} moved, {len(gone)} gone, {len(fresh)} new, {len(stated)} stated")
    return 1 if bad else 0


def normal(line):
    s = ANSI.sub("", line).strip()
    s = re.sub(r"(file://)?/tmp/[^ :\"')]*?(/lares-sandbox[^/ ]*|/sheet-\d+)(/)", r"<tree>/", s)
    s = re.sub(r"/tmp/[^ :\"')]+", "<tmp>", s)
    s = re.sub(r"0x[0-9a-fA-F]+", "0xN", s)
    s = re.sub(r"\d+(\.\d+)?", "N", s)
    return s


def table(d):
    seen = {}
    logs = os.path.join(d, "logs")
    for f in sorted(os.listdir(logs)):
        if not f.endswith(".log"):
            continue
        state = f[:-4]
        for raw in open(os.path.join(logs, f), errors="replace"):
            if INTEREST.search(ANSI.sub("", raw)):
                seen.setdefault(normal(raw), []).append(state)
    return seen


def logs(base, new):
    a, b = table(base), table(new)
    with open(os.path.join(new, "warnings.txt"), "w") as f:
        for line, states in sorted(b.items()):
            f.write(f"{len(states):4d}  {line}  [{states[0]}]\n")
    bad = 0
    for line, states in sorted(b.items()):
        if ALWAYS.search(line):
            print(f"LOG always fails: {line} ({len(states)} logs, first {states[0]})")
            bad += 1
        elif line not in a:
            print(f"LOG new line: {line} ({len(states)} logs, first {states[0]})")
            bad += 1
    print(f"LOGS {len(b)} distinct lines, {bad} findings")
    return 1 if bad else 0


TEXT = (".qml", ".js", ".mjs", ".sh", ".py", ".json", ".jsonc", ".md", ".txt", ".frag", ".vert", ".glsl", ".c", ".cpp", ".h", ".hpp", ".rs", ".toml", ".conf", ".lua", ".css", ".svg", ".desktop", ".service", "")
CSTYLE = (".qml", ".js", ".mjs", ".frag", ".vert", ".glsl", ".c", ".cpp", ".h", ".hpp", ".rs", ".jsonc", ".css")
HASH = (".sh", ".py", ".toml", ".conf", "")


def comment_from(ext, line, in_block):
    """(column where this line's comment starts or None, still in a block comment at its end). Column 0 with in_block means the whole line."""
    if ext not in CSTYLE and ext not in HASH:
        return None, False
    i, q = 0, None
    if ext in CSTYLE and in_block:
        end = line.find("*/")
        if end < 0:
            return 0, True
        i = end + 2
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\":
                i += 1
            elif c == q:
                q = None
        elif c in "\"'`":
            q = c
        elif ext in HASH:
            if c == "#" and (i == 0 or line[i - 1] in " \t;"):
                return i, False
        elif line.startswith("//", i):
            return i, False
        elif line.startswith("/*", i):
            end = line.find("*/", i + 2)
            if end < 0:
                return i, True
            i = end + 1
        i += 1
    return None, False


def patterns(mapping):
    """-> (pats, lits): pattern -> the old name it reports, and pattern -> the literal text it cannot match without."""
    pats, lits = {}, {}

    def add(key, old, lit):
        if key not in pats:
            pats[key] = old
            lits[key] = lit
    for old, new in mapping.items():
        parts = old.rstrip("/").split("/")
        add(re.escape(old) + (r"" if old.endswith("/") else r"(?![\w-])"), old, old)
        if len(parts) >= 3:
            tail = "/".join(parts[1:]) + ("/" if old.endswith("/") else "")
            add(re.escape(tail) + (r"" if old.endswith("/") else r"(?![\w-])"), old, tail)
        if new is None and not old.endswith("/"):
            base = parts[-1]
            add(re.escape(base) + r"(?![\w-])", old, base)
            stem, ext = os.path.splitext(base)
            if ext in (".qml", ".js") and stem[:1].isupper():
                add(r"\b" + re.escape(stem) + r"\b", old, stem)
    return pats, lits


def propcheck(props, wheres):
    """{file: [prop, ...]}: each deleted property is gone from its file's code, and no file reads the name unless it declares a
    property of that name itself (another type's own). -> (code hits, comment hits)."""
    names = {n for ps in props.values() for n in ps}
    if not names:
        return [], []
    rx = re.compile(r"\b(" + "|".join(sorted(map(re.escape, names), key=len, reverse=True)) + r")\b")
    decl = re.compile(r"^\s*(?:(?:readonly|required|default)\s+)*property\s+\S+\s+(\w+)", re.M)
    files = []
    for w in wheres + ["tools/dev", "mockup_profiles"]:
        top = os.path.join(ROOT, w)
        if os.path.isfile(top):
            files.append(top)
        for dp, dn, fn in os.walk(top):
            dn[:] = [d for d in dn if d not in ("target", ".git", "node_modules", "__pycache__", "fixtures")]
            files += [os.path.join(dp, f) for f in fn]
    code, comment = [], []
    for f in sorted(set(files)):
        rel = os.path.relpath(f, ROOT)
        ext = os.path.splitext(f)[1]
        if ext not in TEXT or os.path.islink(f) or rel.startswith("tools/dev/sheet_"):
            continue
        try:
            text = open(f, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        own = set(decl.findall(text))
        block = False
        for n, line in enumerate(text.split("\n"), 1):
            col, after = comment_from(ext, line, block)
            whole_block = block and col == 0
            block = after
            for m in rx.finditer(line):
                name = m.group(1)
                mine = name in props.get(rel, [])
                if not mine and name in own:
                    continue                # a property of that name the file declares and keeps: its own
                hit = f"{rel}:{n}: property {name}{' (deleted here)' if mine else ''}: {line.strip()[:110]}"
                (comment if (whole_block or (col is not None and m.start() >= col)) else code).append(hit)
    return code, comment


def mapcheck(path, step, out):
    mapping = json.load(open(path, encoding="utf-8"))
    props = {f: list(v) for f, v in (mapping.get("deleted_properties") or {}).items()}
    for f, v in (mapping.get("deleted_functions") or {}).items():           # a function is looked for the same way
        props.setdefault(f, []).extend(v)
    if isinstance(mapping.get("deleted_files"), list):
        # C2's record: {"deleted_files": [...], "deleted_properties": {file: [prop, ...]}, "kept": {...}, "map_exclusions": {...}}
        mapping = dict(mapping, deleted=mapping["deleted_files"])
    if isinstance(mapping.get("deleted"), list):
        # a stage's own record: {"deleted": [path, ...], "kept": {...}, "map_exclusions": {name: why}}. Every deleted path is a name that must
        # not be referenced any more, except those whose basename is a generic word other files use for themselves (README.md, compare.py)
        # or that a capture tool names as its OWN output; the exclusions say which and why.
        # A directory that is gone altogether is named by its path (one key, no basename of a stub called `systemctl` to find in the code).
        names = {}
        for p in mapping["deleted"]:
            if p in mapping.get("map_exclusions", {}):
                continue
            parts = p.split("/")
            gone = next(("/".join(parts[:i]) + "/" for i in range(1, len(parts)) if not os.path.isdir(os.path.join(ROOT, *parts[:i]))), None)
            names[gone or p] = None
        # a record that also moved files ({"moved": {old: new}, "deleted": [...], ...}): those old names must be gone too
        for old, new in (mapping.get("moved") or {}).items():
            names.setdefault(old, new)
        mapping = names
    pats, lits = patterns(mapping)
    if not pats and not props:
        print("MAP empty")
        return 0
    keys = list(pats)
    news = {os.path.normpath(v) for v in mapping.values() if v}
    # A tail (`fixtures/x/` of `<old>/fixtures/x/`) can also end a NEW path (mockups/fixtures/x/): a hit that stands right after such a new
    # path's head (`mockups/`) is that new path, not the old one.
    heads = {k: [v[:-len(lits[k])] for v in mapping.values() if v and len(v) > len(lits[k]) and v.endswith(lits[k])] for k in keys}
    wheres = [w for w in "modules shell.qml tools helpers lock mockups themes assets".split() if os.path.exists(os.path.join(ROOT, w))]
    code, comment = [], []
    strict = step is not None and int(step[1:]) >= 7
    for w in wheres:
        top = os.path.join(ROOT, w)
        files = [top] if os.path.isfile(top) else []
        for dp, dn, fn in os.walk(top):
            dn[:] = [d for d in dn if d not in ("target", ".git", "node_modules", "__pycache__")]
            files += [os.path.join(dp, f) for f in fn]
        for f in files:
            rel = os.path.relpath(f, ROOT)
            ext = os.path.splitext(f)[1]
            if ext not in TEXT or os.path.islink(f) or rel in news:
                continue
            try:
                text = open(f, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            # only the patterns whose literal the file holds can match in it (same hits, same order of alternatives, a regex of a few instead
            # of thousands: a map of 1600 names took minutes per scan)
            here = [k for k in keys if lits[k] in text]
            if not here:
                continue
            rx = re.compile(r"(?<![\w.-])(?:" + "|".join(f"({k})" for k in here) + ")")
            block = False
            for n, line in enumerate(text.split("\n"), 1):
                col, after = comment_from(ext, line, block)
                whole_block = block and col == 0
                block = after
                for m in rx.finditer(line):
                    if any(line[:m.start()].endswith(h) for h in heads[here[m.lastindex - 1]]):
                        continue
                    old = pats[here[m.lastindex - 1]]
                    hit = f"{rel}:{n}: {old}: {line.strip()[:120]}"
                    (comment if (whole_block or (col is not None and m.start() >= col)) else code).append(hit)
    pcode, pcomment = propcheck(props, wheres)
    code += pcode
    comment += pcomment
    with open(os.path.join(out, "map_comment_hits.txt"), "w") as f:
        f.write("\n".join(comment) + ("\n" if comment else ""))
    for h in code:
        print("MAP code: " + h)
    if strict:
        for h in comment:
            print("MAP comment: " + h)
    nprops = sum(len(v) for v in props.values())
    print(f"MAP {len(mapping)} names{f' + {nprops} properties' if nprops else ''}, {len(code)} hits in code, {len(comment)} in comments ({os.path.join(out, 'map_comment_hits.txt')})")
    return 1 if code or (strict and comment) else 0


def main():
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == "sheet":
        return sheet(a[1], a[2], a[4] if len(a) > 4 and a[3] == "--expect" else None)
    if len(a) == 3 and a[0] == "logs":
        return logs(a[1], a[2])
    if len(a) >= 2 and a[0] == "map":
        step = a[a.index("--step") + 1] if "--step" in a else None
        out = a[a.index("--out") + 1] if "--out" in a else "."
        return mapcheck(a[1], step, out)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
