#!/usr/bin/env python3
"""frame_split.py -- read Qt's own per-frame timing (QSG_RENDER_TIMING=1, quickshell --log-times) out of a shell log and print, per
scenario of tools/dev/perf/frame_split.sh, what the frames cost and where.

    frame_split.py <shell.log> <marks.tsv> <outdir>

The two lines Qt prints per frame of the threaded render loop:
    [window W][gui thread] Frame prepared, polish=P ms, lock=L ms, blockedForSync=B ms, animations=A ms
    [window W][render thread T] syncAndRender: frame rendered in N ms, sync=S, render=R, swap=W
`gui` below is P + L + B + A: what the GUI thread spent on the frame (advancing animations and the bindings they move, polish =
text layout / Shape tessellation / Canvas paints, and the wait for the render thread). A stretch is a run of frames of ONE window
with no gap over 100 ms. Times are whole milliseconds (Qt's own resolution here), so a median of 0 means "under a millisecond".
"""
import datetime
import re
import statistics
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})")
GUI = re.compile(r"\[window (0x[0-9a-f]+)\]\[gui thread\] Frame prepared, polish=(\d+) ms, lock=(\d+) ms, blockedForSync=(\d+) ms, animations=(\d+) ms")
REN = re.compile(r"\[window (0x[0-9a-f]+)\]\[render thread [^\]]+\] syncAndRender: frame rendered in (\d+) ?ms, sync=(\d+), render=(\d+), swap=(\d+)")
SAID = re.compile(r"qml\S*: (LARES \S+.*|FS \S+.*)$")
STRETCH_GAP_MS = 100


def parse(log):
    gui, ren, said = [], [], []
    for raw in open(log, errors="replace"):
        line = ANSI.sub("", raw)
        m = TS.match(line)
        if not m:
            continue
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
        g = GUI.search(line)
        if g:
            gui.append((t, g.group(1), int(g.group(2)), int(g.group(3)), int(g.group(4)), int(g.group(5))))
            continue
        r = REN.search(line)
        if r:
            ren.append((t, r.group(1), int(r.group(2)), int(r.group(3)), int(r.group(4)), int(r.group(5))))
            continue
        s = SAID.search(line)
        if s:
            said.append((t, s.group(1).strip()))
    return gui, ren, said


def med(xs):
    return statistics.median(xs) if xs else 0


def p95(xs):
    if not xs:
        return 0
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * 0.95))]


def stretches(frames):
    out, cur = [], []
    for f in frames:
        if cur and (f[0] - cur[-1][0]) * 1000 > STRETCH_GAP_MS:
            out.append(cur)
            cur = []
        cur.append(f)
    if cur:
        out.append(cur)
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    log, marks, outdir = sys.argv[1:]
    gui, ren, said = parse(log)
    if not ren:
        print(f"FRAME_SPLIT RESULT FAIL (no frame timing in {log}: is QSG_RENDER_TIMING on?)")
        return 1
    spans, begin = [], {}
    settled = None
    for l in open(marks):
        t, _, what = l.rstrip("\n").partition("\t")
        t = float(t)
        if what == "settled":
            settled = t
        elif what.startswith("begin "):
            begin[what[6:]] = t
        elif what.startswith("end ") and what[4:] in begin:
            spans.append((what[4:], begin.pop(what[4:]), t))
    wins = sorted({r[1] for r in ren})
    print(f"FRAME_SPLIT {len(ren)} frames rendered, {len(gui)} prepared, {len(wins)} window(s); log {log}")
    total = 0
    for name, t0, t1 in spans:
        safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", name)
        rows = []
        print(f"FRAME_SPLIT == {name}  ({t1 - t0:.1f} s)")
        for w in wins:
            rf = [r for r in ren if r[1] == w and t0 <= r[0] <= t1]
            gf = [g for g in gui if g[1] == w and t0 <= g[0] <= t1]
            if not rf:
                continue
            total += len(rf)
            for st in stretches(rf):
                a, b = st[0][0], st[-1][0]
                gs = [g for g in gf if a - 0.05 <= g[0] <= b + 0.01]
                gaps = [round((st[i][0] - st[i - 1][0]) * 1000) for i in range(1, len(st))]
                guis = [g[2] + g[3] + g[4] + g[5] for g in gs]
                pol, blk, ani = [g[2] for g in gs], [g[4] for g in gs], [g[5] for g in gs]
                syn, rnd, swp = [r[3] for r in st], [r[4] for r in st], [r[5] for r in st]
                said_here = "; ".join(s for ts, s in said if a - 0.3 <= ts <= b + 0.1)[:120]
                print(f"    win {w[-5:]} +{a - t0:6.2f} s  {len(st):4d} frames in {round((b - a) * 1000):5d} ms  gap med {med(gaps):4.0f} p95 {p95(gaps):3.0f} worst {max(gaps) if gaps else 0:3d}"
                      f" | gui med {med(guis):3.0f} worst {max(guis) if guis else 0:3d} (polish {med(pol):2.0f}/{max(pol) if pol else 0:2d} anim {med(ani):2.0f}/{max(ani) if ani else 0:2d} blocked {med(blk):2.0f}/{max(blk) if blk else 0:2d})"
                      f" | sync {med(syn):2.0f}/{max(syn):2d} render {med(rnd):2.0f}/{max(rnd):2d} swap {med(swp):2.0f}/{max(swp):2d}"
                      + (f"   [{said_here}]" if said_here else ""))
            gi = 0
            for r in rf:
                while gi + 1 < len(gf) and gf[gi + 1][0] <= r[0]:
                    gi += 1
                g = gf[gi] if gf and gf[gi][0] <= r[0] else (0, w, -1, -1, -1, -1)
                rows.append(f"{r[0] - t0:.3f}\t{w}\t{g[2]}\t{g[3]}\t{g[4]}\t{g[5]}\t{r[3]}\t{r[4]}\t{r[5]}\t{r[2]}")
        with open(f"{outdir}/{safe}.frames.tsv", "w") as f:
            f.write("t_s\twindow\tpolish\tlock\tblockedForSync\tanimations\tsync\trender\tswap\trendered_in\n" + "\n".join(rows) + "\n")
        if not rows:
            print("    (no frame in this span)")
    if settled is not None:
        late = [s for s in said if s[0] > settled and "FS " in s[1]]
        for ts, s in late[:40]:
            print(f"FRAME_SPLIT said +{ts - settled:.2f} s  {s}")
    if not spans:
        print("FRAME_SPLIT RESULT FAIL (no scenario span in the marks)")
        return 1
    print(f"FRAME_SPLIT RESULT PASS ({len(spans)} scenario(s), {total} frames in them)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
