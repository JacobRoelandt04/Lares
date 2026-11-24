#!/usr/bin/env python3
"""Helpers of tools/dev/themectl_resolver_parity.sh: make the fixture (the hand-written theme plus a seeded sweep of recipes over many
colours) and compare what themectl (Python) and Theme.qml's ThemeResolve.js (QML) made of it.

    themectl_resolver_parity.py gen OUT.json
    themectl_resolver_parity.py compare PY_LIGHT.json PY_DARK.json QML.json
"""
import json
import os
import sys
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
AMOUNTS = ["0.01", "0.05", "0.1", "0.25", "0.5", "0.99"]
EDGES = ["#000000", "#FFFFFF", "#808080", "#7F7F7F", "#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#00FFFF", "#FF00FF", "#010101",
         "#FEFEFE", "#7F7F80", "#EAEDF5", "#2C3037", "#4480F4", "#598DEF", "#FF6D12", "#00BEC4", "#C838C6", "#80000000", "#80FFFFFF"]


def colours(seed, n):
    out, x = list(EDGES), seed
    for _ in range(n):
        x = (x * 1103515245 + 12345) % (2 ** 31)
        out.append("#%06X" % ((x >> 7) & 0xFFFFFF))
    return out


def sweep(seed, n):
    block = {}
    for i, c in enumerate(colours(seed, n)):
        block["zzB%d" % i] = c
        for op in ("lighten", "darken"):
            for a in AMOUNTS:
                block["zzR%d_%s_%s" % (i, op, a)] = "@zzB%d %s %s" % (i, op, a)
    return block


def gen(out):
    doc = json.load(open(os.path.join(HERE, "fixtures/themectl/parity.json")))
    doc["light"].update(sweep(1, 140))
    doc["dark"].update(sweep(2, 140))
    json.dump(doc, open(out, "w"), indent=1)


def compare(py_light, py_dark, qml):
    py = {"light": json.load(open(py_light)), "dark": json.load(open(py_dark))}
    q = json.load(open(qml))
    bad = 0

    def check(cid, ok, detail=""):
        nonlocal bad
        if not ok:
            bad += 1
        print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)) if (detail and not ok) else ""))
    check("P1.l0-is-the-same-in-both", py["light"]["l0"] == q["l0"] and len(q["l0"]) >= 168,
          [k for k in set(py["light"]["l0"]) | set(q["l0"]) if py["light"]["l0"].get(k) != q["l0"].get(k)][:5])
    for mode in ("light", "dark"):
        a, b = py[mode]["values"], q["lib_" + mode]["values"]
        check("P2.%s.same-keys" % mode, set(a) == set(b), (sorted(set(a) ^ set(b))[:5]))
        diff = [(k, a[k], b.get(k)) for k in sorted(a) if k in b and a[k] != b[k]]
        check("P2.%s.every-value-equal (%d keys)" % (mode, len(a)), not diff, diff[:5])
        ea, eb = set(py[mode]["errors"]), set(q["lib_" + mode]["errors"])
        check("P3.%s.the-same-keys-error (%d)" % (mode, len(ea)), ea == eb, sorted(ea ^ eb)[:5])
        th = q["theme_" + mode]
        diff = [(k, th[k], b.get(k)) for k in sorted(th) if th[k] != b.get(k)]
        check("P4.%s.Theme-qml-answers-as-the-library (%d tokens)" % (mode, len(th)), len(th) >= 168 and not diff, diff[:5])
    # the fixture really exercises what it claims (a resolver that ignored the bad inputs would otherwise pass trivially)
    L = py["light"]["values"]
    LE = py["light"]["errors"]
    gold = {"accentHover": [97, 148, 246, 255], "zzGrey": [192, 192, 192, 255], "zzBlackUp": [128, 128, 128, 255], "buttonBevel": [170, 187, 204, 255],
            "buttonShadow": [170, 187, 204, 128], "bevel": [18, 52, 86, 255], "border": [1, 2, 3, 255], "zzAlpha0": [68, 128, 244, 0], "zzAlpha1": [68, 128, 244, 255],
            "zzTo0": [0, 0, 0, 255], "zzTo1": [255, 255, 255, 255], "zzCommonAlias": [51, 170, 51, 255], "netLampLink": [51, 170, 51, 255]}
    wrong = {k: (L.get(k), v) for k, v in gold.items() if L.get(k) != v}
    check("P5.goldens", not wrong, wrong)
    check("P5.alpha-half-is-3", L["errorTint"][3] == 3, L["errorTint"])
    erring = ["ansiRed", "ansiGreen", "ansiBlue", "ansiMagenta", "ansiCyan", "ansiWhite", "catCore", "catExtra", "catMultilib", "catAur", "catFlatpak", "llmCode",
              "llmSystem", "llmExplain", "llmWrite", "llmData", "llmOther", "spill", "weatherSun", "zzCaseOp", "zzSpaces", "zzAliasNothing", "zzRecipeOnNumber"]
    # zzSpaces is legal ("@  accent   darken   0.2  " splits on any whitespace); zzAliasNothing is a legal alias to a null
    erring = [k for k in erring if k not in ("zzSpaces", "zzAliasNothing")]
    missing = [k for k in erring if k not in LE]
    check("P5.the-bad-inputs-are-errors", not missing, missing)
    check("P5.the-legal-odd-ones-are-not", "zzSpaces" not in LE and "zzAliasNothing" not in LE and "zzAmountDot" not in LE and "zzAmountTrail" not in LE, [k for k in LE if k in ("zzSpaces", "zzAliasNothing")])
    check("P5.a-failed-token-falls-back-to-l0", L["ansiRed"] == [0xF1, 0x4C, 0x4C, 255] and L["ansiGreen"] == [0x48, 0xD1, 0x48, 255], (L["ansiRed"], L["ansiGreen"]))
    check("P5.dark-modes-are-isolated", "zzUsesLightOnly" in py["dark"]["errors"] and "zzUsesLightOnly" not in py["light"]["values"], "")
    check("P5.dark-cycle-is-an-error", all(k in py["dark"]["errors"] for k in ("zzCycleA", "zzCycleB", "zzCycleC")), "")
    check("P6.the-sweep-is-in (>1500 recipe keys)", sum(1 for k in L if k.startswith("zzR")) > 1500, sum(1 for k in L if k.startswith("zzR")))
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(sys.argv[2])
    elif sys.argv[1] == "compare":
        sys.exit(compare(*sys.argv[2:5]))
