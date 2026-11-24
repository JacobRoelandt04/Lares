#!/usr/bin/env python3
"""visible_ink_judge.py -- the judge of tools/dev/visible_ink_probe.sh: every grabbed picture of the bar window against the visible
region its frame was drawn under.

    visible_ink_judge.py <shell.log> <grab dir> <ratio> [--consume] [--summary]

The shell's InkProbe (modules/shell/perf/InkProbe.qml) writes the region to the log whenever it changes, stamped with the frame it goes
out with (`INKP R <frame> whole|empty|[rects]`), names the tour's steps (`INKP M <frame> <name>`), draws each frame's number into the
frame (16 cells of 3 x 3 window px, bottom right, white = 1) and saves grabs of the whole window (<dir>/g<n>.png). For each grab: its
frame from the cells, the region in force at that frame (the last record stamped at or before it), and every pixel with alpha > 0
outside the region's rects (window px x <ratio>, rounded outward) -- ink the compositor would cut. The cells' own box is left out.
A frame under `whole` is not judged (the whole surface is visible); under `empty` every inked pixel counts.

--consume judges only pictures older than 2 s and deletes each one judged (the runner calls it while the tour runs, so the disk holds
a few seconds of pictures); results are appended to <dir>/verdicts.tsv. --summary reads verdicts.tsv and prints the per-step table and
`VISIBLE_INK RESULT PASS|FAIL`.
"""
import json
import os
import re
import sys
import time

import numpy as np
from PIL import Image

REC = re.compile(r"INKP ([RM]) (\d+) (.*)$")


def records(log):
    regions, marks = [], []
    with open(log, "rb") as f:
        for raw in f:
            line = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode("utf-8", "replace")).rstrip("\n")
            m = REC.search(line)
            if not m:
                continue
            kind, frame, rest = m.group(1), int(m.group(2)), m.group(3).strip()
            if kind == "R":
                regions.append((frame, rest if rest in ("whole", "empty") else json.loads(rest)))
            else:
                marks.append((frame, rest))
    return regions, marks


def unwrap(seq):
    """16-bit frame stamps -> monotone numbers (the log is in order)."""
    out, base, last = [], 0, None
    for f, v in seq:
        if last is not None and f + base < last - 30000:
            base += 65536
        last = f + base
        out.append((f + base, v))
    return out


def at(seq, frame, default):
    v = default
    for f, x in seq:
        if f <= frame:
            v = x
        else:
            break
    return v


def frame_of(alpha_rgb, ratio):
    rgb, a = alpha_rgb
    h, w = a.shape
    wl, hl = w / ratio, h / ratio
    n = 0
    for i in range(16):
        x = int((wl - 48 + 3 * i + 1.5) * ratio)
        y = int((hl - 1.5) * ratio)
        if a[y, x] < 200:
            return None
        if rgb[y, x].mean() > 127:
            n |= 1 << i
    return n


def judge(path, regions, ratio):
    img = Image.open(path).convert("RGBA")
    arr = np.asarray(img)
    a = arr[:, :, 3]
    f16 = frame_of((arr[:, :, :3], a), ratio)
    if f16 is None:
        return None
    h, w = a.shape
    # the newest record with this 16-bit number at or below the newest stamp
    full = f16
    if regions:
        top = regions[-1][0]
        full = f16 + (top // 65536) * 65536
        if full > top + 4000:
            full -= 65536
    reg = at(regions, full, "whole")
    mask = a > 0
    # the cells' box
    wl, hl = w / ratio, h / ratio
    mask[int((hl - 5) * ratio):, int((wl - 50) * ratio):] = False
    if reg == "whole":
        return (full, "whole", 0, None)
    if reg != "empty":
        for r in reg:
            x0, y0 = int(np.floor(r["x"] * ratio)), int(np.floor(r["y"] * ratio))
            x1, y1 = int(np.ceil((r["x"] + r["w"]) * ratio)), int(np.ceil((r["y"] + r["h"]) * ratio))
            mask[max(0, y0):max(0, y1), max(0, x0):max(0, x1)] = False
    n = int(mask.sum())
    box = None
    if n:
        ys, xs = np.nonzero(mask)
        box = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
    return (full, "empty" if reg == "empty" else "rects", n, box)


def run(log, d, ratio, consume):
    regions, marks = records(log)
    regions = unwrap(regions)
    marks = unwrap(marks)
    out = open(os.path.join(d, "verdicts.tsv"), "a")
    now = time.time()
    for name in sorted(os.listdir(d)):
        if not (name.startswith("g") and name.endswith(".png")):
            continue
        p = os.path.join(d, name)
        if consume and now - os.path.getmtime(p) < 2:
            continue
        try:
            v = judge(p, regions, ratio)
        except Exception as e:      # a picture still being written
            if consume:
                continue
            v = None
            print(f"VISIBLE_INK unreadable {name}: {e}")
        if v is None:
            out.write(f"{name}\t-1\tnocells\t0\t-\t-\n")
        else:
            full, mode, n, box = v
            step = at(marks, full, "start")
            out.write(f"{name}\t{full}\t{mode}\t{n}\t{box}\t{step}\n")
            if n:
                os.makedirs(os.path.join(d, "bad"), exist_ok=True)
                kept = len(os.listdir(os.path.join(d, "bad")))
                if kept < 6:
                    os.replace(p, os.path.join(d, "bad", name))
                    continue
        os.remove(p)
    out.close()


def summary(d):
    rows = []
    with open(os.path.join(d, "verdicts.tsv")) as f:
        for line in f:
            name, full, mode, n, box, step = line.rstrip("\n").split("\t")
            rows.append((name, int(full), mode, int(n), box, step))
    steps = {}
    order = []
    for name, full, mode, n, box, step in rows:
        if step not in steps:
            steps[step] = {"grabs": 0, "judged": 0, "whole": 0, "bad": 0, "px": 0, "first": None}
            order.append(step)
        s = steps[step]
        s["grabs"] += 1
        if mode == "whole":
            s["whole"] += 1
        elif mode in ("rects", "empty"):
            s["judged"] += 1
            if n:
                s["bad"] += 1
                s["px"] += n
                if s["first"] is None:
                    s["first"] = f"frame {full} {name} box {box}"
    nocells = sum(1 for r in rows if r[2] == "nocells")
    print(f"{'step':28s} {'grabs':>6s} {'judged':>6s} {'whole':>6s} {'cut':>5s} {'px':>8s}")
    bad = 0
    for st in order:
        s = steps[st]
        print(f"{st:28s} {s['grabs']:6d} {s['judged']:6d} {s['whole']:6d} {s['bad']:5d} {s['px']:8d}" + (f"   first: {s['first']}" if s["first"] else ""))
        bad += s["bad"]
    judged = sum(s["judged"] for s in steps.values())
    print(f"VISIBLE_INK {len(rows)} grabs, {judged} judged against a region, {nocells} without readable cells")
    if bad:
        worst = max(order, key=lambda k: steps[k]["px"])
        print(f"VISIBLE_INK RESULT FAIL ({bad} grabs with ink outside the region; worst step {worst}: {steps[worst]['first']})")
        return 1
    if judged < 20:
        print(f"VISIBLE_INK RESULT FAIL (starved: only {judged} grabs judged against a region)")
        return 1
    print("VISIBLE_INK RESULT PASS")
    return 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--summary" in sys.argv:
        return summary(args[0])
    if len(args) < 3:
        print(__doc__)
        return 2
    run(args[0], args[1], float(args[2]), "--consume" in sys.argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
