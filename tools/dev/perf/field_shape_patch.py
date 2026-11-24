#!/usr/bin/env python3
"""field_shape_patch.py -- the recorder of the field-shape differential, patched into a SANDBOX COPY only.

    field_shape_patch.py <tree>

Makes GooeyField._update hand its call of GooeyGeometry.fieldShape() through `_fsRecord`, which prints the call's exact inputs as
one line before it makes the call:

    FSREC {"f": <field id>, "q": <call number>, "t": <Date.now()>, "dt": <dtMs>, "params": {...}, "src": [...], "state": {...}}

`state` is there only when the state handed in is NOT the one the last call returned (the first call's `{}`, or a state somebody
replaced): a replay carries the state from call to call and takes the recorded one where there is one. Numbers JSON cannot carry
(-0, NaN, +-Infinity) are written as {"$n": "-0" | "NaN" | "Inf" | "-Inf"} (field_shape_lib.js `decode`). The call itself is made
exactly as before, with the same objects.

And the mock hooks (modules/shell/ShellMain.qml, shell.qml's body) get `fsjs` (below). tools/dev/perf/field_shape_record.sh runs it on its own copy; a tree that is a git
work tree is refused.
"""
import os
import sys

FIELD = "modules/bar/gooey/GooeyField.qml"
PATCHES = [
    (FIELD, "        const out = Geo.fieldShape(src.slice(0, field.maxBodies), {\n",
     "        const out = field._fsRecord(src.slice(0, field.maxBodies), {\n"),
    (FIELD, "    function _update() {\n",
     "    property var _fsRec: ({ seq: 0, last: null, id: String(Math.random()).slice(2, 10) })\n"
     "    function _fsRecord(s, p, st, d) {\n"
     "        const enc = (k, v) => (typeof v !== \"number\" || (v === v && v !== Infinity && v !== -Infinity && !(v === 0 && 1 / v < 0))) ? v\n"
     "            : { \"$n\": v !== v ? \"NaN\" : (v === 0 ? \"-0\" : (v > 0 ? \"Inf\" : \"-Inf\")) };\n"
     "        const R = field._fsRec;\n"
     "        const rec = { f: R.id, q: R.seq++, t: Date.now(), dt: d, params: p, src: s };\n"
     "        if (st !== R.last)\n"
     "            rec.state = st;\n"
     "        console.log(\"FSREC \" + JSON.stringify(rec, enc));\n"
     "        const out = Geo.fieldShape(s, p, st, d);\n"
     "        R.last = out.state;\n"
     "        return out;\n"
     "    }\n"
     "    function _update() {\n"),
    # A hook of the copy's own, beside frame_split_ablate.py's `toggle`: `hook fsjs "<owner key>|<js>"` runs <js> with `owner` and
    # `content` (the owner's popup content on show) -- how a scenario opens a secondary without a pointer.
    ("modules/shell/ShellMain.qml", '            case "secret":',
     '            case "fsjs": {\n'
     '                const fsBar = arg.indexOf("|");\n'
     '                const fsO = shellServices.focusedOwner(arg.slice(0, fsBar));\n'
     '                if (!fsO)\n'
     '                    return "none";\n'
     '                const fsC = fsO.engine && fsO.engine.thePopup ? fsO.engine.thePopup.contentItem : null;\n'
     '                try {\n'
     '                    return String(new Function("owner", "content", arg.slice(fsBar + 1))(fsO, fsC));\n'
     '                } catch (e) {\n'
     '                    return "error " + e;\n'
     '                }\n'
     '            }\n'
     '            case "secret":'),
]


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    tree = sys.argv[1]
    if os.path.exists(os.path.join(tree, ".git")):
        print(f"FS_PATCH FAIL {tree} is a git work tree: the recorder goes into a sandbox copy only")
        return 1
    texts = {}
    for path, old, new in PATCHES:
        text = texts.get(path)
        if text is None:
            text = open(os.path.join(tree, path)).read()
        if text.count(old) != 1:
            print(f"FS_PATCH FAIL the anchor {old.strip()[:60]!r} matches {text.count(old)} times in {path}")
            return 1
        texts[path] = text.replace(old, new)
    for path, text in texts.items():
        open(os.path.join(tree, path), "w").write(text)
        print(f"FS_PATCH ok {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
