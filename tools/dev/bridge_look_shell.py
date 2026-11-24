#!/usr/bin/env python3
"""bridge_look_shell.py -- the second phase of tools/dev/bridge_look_env_probe.sh: the REAL shell.qml on its mock services in the env's
nested Hyprland (LOCK_ENV from the caller), the bridge popup opened by a click on its glyph, the pointer moved onto the phone, Alt held
by a keyboard of its own while the pointer moves, then let go. It only DRIVES (lines `DRV ...`); the runner judges the shell's
`qt.quick.hover.cursor` log. ARGV: <tree> <shell.qml>. A mock shell never moves the pointer (BridgeBarOwner warps for a live service
only), so where the pointer ends is not judged here: the first phase does that."""
import json
import os
import subprocess
import sys
import time

TREE, SHELL_QML = sys.argv[1:3]
E = os.path.join(TREE, "tools/dev/lock_env.sh")
OUT = "LOCK-1"


def sh(*a, timeout=30):
    r = subprocess.run(list(a), cwd=TREE, capture_output=True, text=True, timeout=timeout)
    return (r.stdout or "") + (r.stderr or "")


def probe():
    t = ""
    for _ in range(8):
        t = sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", "shell", "probe").strip()
        try:
            return json.loads(t)
        except ValueError:
            time.sleep(0.3)
    raise RuntimeError("no probe answer: " + t[:200])


def pt(x, y):
    return f"abs {int(round(x))} {int(round(y))} 2880 1620"


s = probe()["screens"][OUT]
bar = [b for b in s["bars"] if b["id"] in ("topR", "top")][0]
p = s["placed"]["bridge"]
gx, gy = bar["rawPos"] + p["x"] + p["width"] / 2, 20
pp = s.get("popup") or {}
if pp.get("open") and pp.get("owner") == "bridge":
    # the second drive in one shell (the probe's third phase): the popup is out, only the glyph is hovered
    sh(E, "point", pt(gx - 3, gy), "sleep 80", pt(gx, gy), "sleep 120")
else:
    sh(E, "point", pt(gx - 3, gy), "sleep 80", pt(gx, gy), "sleep 120", "click")
pp = {}
for _ in range(60):
    pp = probe()["screens"][OUT]["popup"]
    if pp["open"] and pp["owner"] == "bridge" and pp["phase"] == "open":
        break
    time.sleep(0.3)
print("DRV popup " + json.dumps(pp), flush=True)
if not (pp.get("open") and pp.get("owner") == "bridge"):
    sys.exit(1)
x, y, w, h = pp["box"]
cx, cy = x + w / 2, y + h / 2
time.sleep(1.5)
# onto the phone (over a tile of its home screen), in steps; then a motion of its own (the keys come to a layer surface with one)
sh(E, "point", pt(cx - 12, cy - 8), "sleep 120", pt(cx - 6, cy - 4), "sleep 120", pt(cx, cy))
time.sleep(0.6)
sh(E, "point", pt(cx + 1, cy), "sleep 60", pt(cx, cy))
time.sleep(0.5)
wt = subprocess.Popen([E, "run", "wtype", "-M", "alt", "-P", "Alt_L", "-s", "4000", "-p", "Alt_L", "-m", "alt"], cwd=TREE)
time.sleep(0.8)
for _ in range(30):
    sh(E, "point", "rel 10 0", "sleep 20")
wt.wait()
time.sleep(1.0)
# the mock shell left the pointer where the hand took it (no put-back): bring it onto the phone again, as the real put-back does
sh(E, "point", pt(cx - 3, cy), "sleep 80", pt(cx, cy))
time.sleep(0.5)
print("DRV done", flush=True)
