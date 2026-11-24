#!/usr/bin/env python3
"""bar_boot_judge.py DIR -- the judge of tools/dev/bar_boot_film.sh (the checks are listed there).

DIR holds film.mkv (the top band, device px) or frames/ + pts.txt from an earlier read, shell.log (the shell's BARBOOT record)
and marks (epoch ms of the recording's start and of the unlock). Prints one line per check; exit 1 when any failed.
"""
import os
import re
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

DPR = 1.25            # LOCK-1's scale: device px per logical px
ROWS = (8, 40)        # device rows inside the 50 px bar, clear of its edge and ring
INSET = 30            # device px kept clear of an island's ends (its corner, its joint)
LEVEL = 8             # a pixel moved: any channel by more than this (the relief veil is within ~20 levels of the light surface)
# The most a frame of a bar at rest differs from itself LATER_S on, inside one island: what a data arrival moves (an icon's
# recolour, a figure) -- a hole of the reel cells is thousands of px, an island growing under its title too, a title's morph ~2500.
ISLAND_MAX = 1200
# How far on the first frame is compared. A bar built in the open settles over ~0.6 s, and a nested compositor can show no
# frame for 0.5 s of it, so a frame 0.4 s on can still be the half-built bar (the firstframe ARM passed `first` that way,
# 2026-11-08; it had bitten only when a dawn re-light of the veil was taken for the first frame). A minute's flip of the clock
# in that span moves a few hundred px, under ISLAND_MAX.
LATER_S = 1.0

d = sys.argv[1]
fr = os.path.join(d, "frames")
os.makedirs(fr, exist_ok=True)
pts = []
if os.path.exists(os.path.join(d, "film.mkv")):
    p = subprocess.run(["ffmpeg", "-v", "info", "-i", os.path.join(d, "film.mkv"), "-vf", "showinfo",
                        "-fps_mode", "passthrough", os.path.join(fr, "%06d.png")], capture_output=True, text=True)
    pts = [float(m.group(1)) for m in re.finditer(r"pts_time:([0-9.]+)", p.stderr)]
    with open(os.path.join(d, "pts.txt"), "w") as f:
        f.write("\n".join("%.4f" % t for t in pts))
elif os.path.exists(os.path.join(d, "pts.txt")):
    pts = [float(x) for x in open(os.path.join(d, "pts.txt")).read().split()]
files = sorted(f for f in os.listdir(fr) if f.endswith(".png"))
if not files or len(pts) < len(files):
    print("BAR_BOOT_FILM film FAIL (no frames: %d, %d stamps)" % (len(files), len(pts)))
    sys.exit(1)
cache = {}
def load(i):
    if i not in cache:
        cache[i] = np.asarray(Image.open(os.path.join(fr, files[i])).convert("RGB")).astype(np.int16)
    return cache[i]

# ---- the shell's record -------------------------------------------------------------------------------------------------
states = []
for ln in open(os.path.join(d, "shell.log"), errors="replace"):
    m = re.search(r'BARBOOT state t=(\d+) presented=(\w+) locked=(\w+) boot=(\w+) title="(.*)" left=([\d.]+) bars=(\S*)', ln)
    if m:
        bars = {}
        for b in m.group(7).split(","):
            if b.count(":") == 2:
                k, x0, x1 = b.split(":")
                bars[k] = (int(x0), int(x1))
        states.append(dict(t=int(m.group(1)), presented=m.group(2) == "true", locked=m.group(3) == "true",
                           boot=m.group(4) == "true", title=m.group(5), left=float(m.group(6)), bars=bars))
shown = [ln.strip() for ln in open(os.path.join(d, "shell.log"), errors="replace") if "LARES shown" in ln]
for s in shown[:2]:
    print("  " + re.sub(r".*qml: ", "", s))
marks = {}
if os.path.exists(os.path.join(d, "marks")):
    for ln in open(os.path.join(d, "marks")):
        k, v = ln.split()
        marks[k] = int(v)
bad = []
def verdict(name, why):
    print("BAR_BOOT_FILM %s %s" % (name, "PASS" if not why else "FAIL (%s)" % why))
    if why:
        bad.append(name)

if not states:
    verdict("record", "no BARBOOT line in the shell's log")
    sys.exit(1)
P = next((i for i, s in enumerate(states) if s["presented"]), None)
L = next((i for i, s in enumerate(states) if s["locked"]), None)
U = next((i for i in range(L, len(states)) if not states[i]["locked"]), None) if L is not None else None
rest = states[U - 1] if U else states[-1]          # the bar at rest under the boot lock: its islands' rects
if not rest["bars"]:
    verdict("record", "no island rects in the record")
    sys.exit(1)

# ---- the pixels -----------------------------------------------------------------------------------------------------------
veil = next((i for i in range(len(files)) if load(i).mean() > 6), 0)
start = next((i for i in range(veil, len(files)) if pts[i] - pts[veil] >= 2.0), len(files) - 1)
first, prev = None, load(start - 1)
for i in range(start, len(files)):
    a = load(i)
    if (np.abs(a - prev).max(axis=2) > 8).sum() > 15000:
        first = i
        break
    prev = a
if first is None:
    verdict("first", "the bar never showed (%d frames)" % len(files))
    sys.exit(1)
later = next((i for i in range(first, len(files)) if pts[i] - pts[first] >= LATER_S), len(files) - 1)
print("  the bar's first frame #%d at %.3f s; compared with #%d at %.3f s" % (first, pts[first], later, pts[later]))
def island_diff(a, b, x0, x1):
    X0, X1 = int(x0 * DPR) + INSET, int(x1 * DPR) - INSET
    if X1 <= X0:
        return 0
    sa, sb = a[ROWS[0]:ROWS[1], X0:X1], b[ROWS[0]:ROWS[1], X0:X1]
    return int((np.abs(sa - sb).max(axis=2) > LEVEL).sum())
names = {"topL": "left", "topC": "middle", "topR": "right"}
moved = []
for k in ("topL", "topC", "topR"):
    if k in rest["bars"]:
        n = island_diff(load(first), load(later), *rest["bars"][k])
        print("  %s island: %d px moved between the first frame and %g s later" % (names[k], n, LATER_S))
        if n > ISLAND_MAX:
            moved.append("%s island %d px" % (names[k], n))
verdict("first", "the first frame differs from the bar at rest: " + ", ".join(moved) if moved else "")

# the left island from the first frame to the last before the unlock
n_left = 0
if "unlock" in marks and "rec" in marks and "topL" in rest["bars"]:
    # (the recording started 1.5 s before `rec`: the film's clock)
    tu = (marks["unlock"] - marks["rec"]) / 1000.0 + 1.5 - 0.3
    last = max((i for i in range(first, len(files)) if pts[i] <= tu), default=first)
    n_left = island_diff(load(first), load(last), *rest["bars"]["topL"])
    print("  left island: %d px moved between the first frame and #%d at %.3f s (the last before the unlock)" % (n_left, last, pts[last]))

# a sheet of the first frames, and the one before them
pick = sorted(set(i for i in [first - 1, first, first + 1, first + 2, first + 4, later] if 0 <= i < len(files)))
ims = [Image.open(os.path.join(fr, files[i])).convert("RGB") for i in pick]
W, H = ims[0].size
sheet = Image.new("RGB", (W, (H + 16) * len(ims)), "white")
dr = ImageDraw.Draw(sheet)
for k, (i, im) in enumerate(zip(pick, ims)):
    sheet.paste(im, (0, k * (H + 16) + 16))
    dr.text((4, k * (H + 16) + 2), "#%d %.3f s%s" % (i, pts[i], "  (first)" if i == first else ""), fill="red")
sheet.save(os.path.join(d, "first_frames.png"))

# ---- the record ------------------------------------------------------------------------------------------------------------
if P is None:
    verdict("boottitle", "the bar was never shown")
else:
    s = states[P]
    verdict("boottitle", "" if s["locked"] and s["boot"] and s["title"] == "New session"
            else "the first frame shown says \"%s\" (locked=%s boot=%s), not New session" % (s["title"], s["locked"], s["boot"]))
    seen = states[P:U] if U and U > P else states[P:]
    changes = []
    for x in seen:
        c = (x["left"], x["title"])
        if not changes or changes[-1] != c:
            changes.append(c)
    why = ""
    if len(changes) > 1:
        why = "the left island changed before the unlock: " + " -> ".join("%g \"%s\"" % c for c in changes)
    elif n_left > ISLAND_MAX:
        why = "the left island's pixels changed before the unlock (%d px)" % n_left
    verdict("bootlength", why)
if U is None:
    verdict("relock", "no unlock in the record")
else:
    R = next((i for i in range(U, len(states)) if states[i]["locked"]), None)
    if R is None:
        verdict("relock", "the ordinary lock was never heard")
    else:
        E = next((i for i in range(R, len(states)) if not states[i]["locked"]), len(states))
        s = states[E - 1]
        verdict("relock", "" if s["title"] == "Mock is away" and not s["boot"]
                else "an ordinary lock says \"%s\" (boot=%s)" % (s["title"], s["boot"]))
sys.exit(1 if bad else 0)
