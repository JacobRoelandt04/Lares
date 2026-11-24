#!/usr/bin/env python3
"""wheel_readers_check.py -- every wheel in the product is read by the ONE reader (modules/common/scroll/WheelArea.qml), static.

    python3 tools/dev/wheel_readers_check.py        WHEEL_READERS RESULT PASS | FAIL
    ARM=reader ...   a file with a bare `onWheel`          -> must be found
    ARM=handler ...  a WheelHandler                        -> must be found

WHY. On Qt 6.12 a mouse's notch carries a pixel delta (120 and 15, no phase): a reader that takes "pixels" for fingers reads every mouse wrong, and no
side-button swipe reaches a reader that is not a WheelArea (docs/contracts/gestures.md). Allowed: WheelArea itself, and an `onWheel` that only says
`wheel.accepted = false` (a deaf cover that lets wheels through).
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
OWN = "modules/common/scroll/WheelArea.qml"
PASS_ON = re.compile(r"onWheel:\s*wheel\s*=>\s*wheel\.accepted\s*=\s*false\s*$")

def mask(text):
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return "\n".join(re.sub(r"//.*$", "", l) for l in text.split("\n"))

def findings(path, text):
    out = []
    for i, l in enumerate(mask(text).split("\n"), 1):
        if re.search(r"\bWheelHandler\s*\{", l):
            out.append("%s:%d  a WheelHandler (it hears no sideways motion and no lift, and no side-button swipe)" % (path, i))
        if re.search(r"\bonWheel\s*:", l) and path != OWN and not PASS_ON.search(l.strip()):
            out.append("%s:%d  a bare onWheel: make it a WheelArea (`turned: ev => ...`)" % (path, i))
    return out

arm = os.environ.get("ARM", "")
if arm:
    text = {"reader": "MouseArea {\n    onWheel: wheel => root.go(wheel.angleDelta)\n}\n", "handler": "WheelHandler {\n}\n"}.get(arm)
    if text is None:
        print("unknown ARM=%s" % arm); sys.exit(2)
    ok = bool(findings("modules/armed.qml", text))
    print("WHEEL_READERS RESULT %s (ARM %s: %s)" % ("PASS" if ok else "FAIL", arm, "found as it must be" if ok else "NOT FOUND -- the check cannot see it"))
    sys.exit(0 if ok else 1)
bad, n = [], 0
for p in sorted(glob.glob("modules/**/*.qml", recursive=True)) + ["shell.qml", "lock/shell.qml", "lock/warm.qml"]:
    n += 1
    bad += findings(p, open(p, encoding="utf-8").read())
for b in bad:
    print("BAD", b)
print("WHEEL_READERS RESULT %s (%d files, %d bad)" % ("FAIL" if bad else "PASS", n, len(bad)))
sys.exit(1 if bad else 0)
