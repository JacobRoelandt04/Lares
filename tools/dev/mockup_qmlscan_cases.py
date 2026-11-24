#!/usr/bin/env python3
"""Cases for tools/dev/mockup_qmlscan.py -- the tolerant QML structure scanner under the settings pipeline.

    python3 tools/dev/mockup_qmlscan_cases.py           ends in  MOCKUP_QMLSCAN_CASES RESULT PASS|FAIL
    python3 tools/dev/mockup_qmlscan_cases.py --tree    also scans every .qml of the tree (a few seconds)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mockup_qmlscan as q                      # noqa: E402

results = []


def case(cid, what, ok, detail=""):
    results.append(bool(ok))
    print("CASE %s %s %s%s" % ("PASS" if ok else "FAIL", cid, what, (" -- " + str(detail)) if (detail and not ok) else ""))


SRC = '''import QtQuick
// a comment with a { brace and "quotes
Item {
    id: root
    property real a: 3.5 // trailing { comment
    readonly property string s: "x { y } // z"   /* block } */
    property int n: -1
    property color c: Theme.accent
    property var v: ({ k: [1, 2, { z: 3 }] })
    readonly property alias inner: box
    property Style style: Style {
        tick: 8
    }
    property real long: root.a > 2
        ? 10
        : 20
    signal done(int x)
    function f(x) {
        if (x) { return /[(]/.test("a") ? 1 : 2 }
        else { return 0 }
    }
    component Chip: Rectangle {
        id: chip
        radius: 4
    }
    Rectangle { id: box; radius: 2; color: "#112233" }
    Behavior on a { NumberAnimation { duration: 100 } }
    font { pixelSize: 12 }
    Chip { id: c1 }
    onAChanged: if (root.a > 1)
        root.n = 2
    Component.onCompleted: { root.n = 1 }
}
'''


def main():
    f = q.Qml("x.qml", SRC)
    m = f.mask
    case("S01", "the mask keeps every offset and blanks comments, strings and regexes",
         len(m) == len(SRC) and "comment" not in m and "x { y }" not in m and "[(]" not in m and "Theme.accent" in m)
    case("S02", "brackets inside strings and comments do not pair", all(SRC[o] == "{" or SRC[o] in "([" for o in f.pairs if SRC[o] in "{(["))
    objs = f.objects()
    types = [(o.type, o.id) for o in objs]
    case("S03", "objects: types and ids, a `Type on prop {` is a Behavior, an inline component is flagged",
         ("Item", "root") in types and ("Rectangle", "box") in types and ("Behavior", None) in types and ("Style", None) in types
         and f.by_id("chip").component and f.by_id("c1").type == "Chip", types)
    case("S04", "by_id prefers an object outside an inline component", f.by_id("box").type == "Rectangle" and not f.in_component(f.by_id("box")))
    root = f.root()
    st = {s.name: s for s in root.stmts() if s.name}
    case("S05", "statement kinds", st["a"].kind == "decl" and st["inner"].kind == "alias" and st["done"].kind == "signal"
         and st["f"].kind == "function" and st["Chip"].kind == "component" and st["onAChanged"].kind == "assign"
         and st["root"].kind == "id" if "root" in st else st["id"].kind == "id", {k: v.kind for k, v in st.items()})
    case("S06", "a value ends at the end of its comment-free line; the continuation lines belong to it",
         f.value_text(st["a"]) == "3.5" and " ".join(f.value_text(st["long"]).split()) == "root.a > 2 ? 10 : 20", (f.value_text(st["a"]), f.value_text(st["long"])))
    case("S07", "a multi-line handler (`if (..)\\n  stmt`) does not break the statements after it", "Component.onCompleted" in st)
    case("S08", "a group property block (`font { }`) is a group object, a Behavior is an object statement",
         any(o.group and o.type == "font" for o in objs) and any(s.kind == "object" and s.name == "Behavior" for s in root.stmts()))
    case("S09", "a typed property holds its own object", f.object_in_value(st["style"]) is not None and f.object_in_value(st["style"]).type == "Style")
    case("S10", "inline_component(name)", f.inline_component("Chip") is not None and f.inline_component("Chip").type == "Rectangle")
    # literals
    L = q.literal
    case("L01", "literal(): numbers, bools, strings, colours, tokens, expressions",
         L("3.5")[:2] == ("num", 3.5) and L("-1")[:2] == ("num", -1) and L("true")[:2] == ("bool", True) and L('"hi"')[:2] == ("str", "hi")
         and L('"#4480f4"')[:2] == ("color", "#4480f4") and L("Theme.accent")[:2] == ("token", "accent") and L("a + 1")[0] == "expr"
         and L("(12)")[:2] == ("num", 12) and L("'it\\'s'")[1] == "it's")
    case("L02", "format_number: ints bare, reals trimmed", q.format_number(12.0) == "12" and q.format_number(0.35) == "0.35" and q.format_number(7) == "7"
         and q.format_number(0.30000000000000004) == "0.3")
    # the JS reader
    v, e = q.parse_js_value('[{ label: "a", tip: "one " + "two", val: 5, from: 0, c: [1, 2,], d: win.x ? 1 : 2 }, {}]')
    case("J01", "parse_js_value: unquoted keys, a folded +, trailing commas, other expressions kept whole",
         v[0]["tip"] == "one two" and v[0]["val"] == 5 and v[0]["c"] == [1, 2] and isinstance(v[0]["d"], q.Expr) and v[0]["d"] == "win.x ? 1 : 2" and v[1] == {}, v)
    v, e = q.parse_js_value('({ a: { b: ["x", \'y\'] } })')
    case("J02", "parse_js_value: a parenthesised object", v == {"a": {"b": ["x", "y"]}})
    # insertion points are the planner's: here only that value spans are exact
    s, e2 = f.value_span(st["a"])
    case("S11", "value_span is the literal alone (the comment is left out)", SRC[s:e2] == "3.5", SRC[s:e2])
    if "--tree" in sys.argv:
        root_dir = os.path.dirname(os.path.dirname(HERE))
        bad, n = [], 0
        for d, dirs, files in os.walk(root_dir):
            dirs[:] = [x for x in dirs if not x.startswith(".") and x not in ("screenshots", "old", "node_modules")]
            for fn in files:
                if fn.endswith(".qml"):
                    n += 1
                    try:
                        ff = q.Qml(os.path.join(d, fn))
                        ff.root()
                        for ob in ff.objects():
                            ob.stmts()
                    except Exception as ex:           # noqa: BLE001
                        bad.append((fn, repr(ex)))
        case("T01", "every .qml of the tree (%d files) scans without an exception" % n, not bad, bad[:3])
    nfail = results.count(False)
    print("MOCKUP_QMLSCAN_CASES %d cases, %d failed" % (len(results), nfail))
    print("MOCKUP_QMLSCAN_CASES RESULT %s" % ("FAIL" if nfail else "PASS"))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
