#!/usr/bin/env python3
"""wview_stat.py -- the weather popup's view switches of a `frame_split.sh <out> wview:<n>` run, one line per kind of switch:
the frames of the motion (from the first frame that cost GUI time to the last, at most 600 ms), their GUI time (polish + blocked +
animations, ms: median / worst / sum), the frame gap (median / worst) and how many gaps were over 12 ms (a missed 120 Hz frame).

    wview_stat.py <outdir> [<outdir> ...]
"""
import glob
import os
import statistics
import sys


def switch(path):
    rows = [l.rstrip("\n").split("\t") for l in open(path)][1:]
    fr = [(float(r[0]), int(r[2]) + int(r[4]) + int(r[5]), int(r[7])) for r in rows if float(r[0]) < 0.75]
    busy = [i for i, f in enumerate(fr) if f[1] >= 2]
    if not busy:
        return None
    a, b = busy[0], busy[-1]
    span = fr[a:b + 1]
    gaps = [(span[i][0] - span[i - 1][0]) * 1000 for i in range(1, len(span))]
    return {"n": len(span), "ms": (span[-1][0] - span[0][0]) * 1000, "gui": [f[1] for f in span], "ren": [f[2] for f in span], "gaps": gaps}


def main():
    for out in sys.argv[1:]:
        kinds = {}
        order = []
        for p in sorted(glob.glob(os.path.join(out, "to-*.frames.tsv"))):
            name = os.path.basename(p).split(".")[0]
            kind, n = name.rsplit("_", 1)
            order.append((int(n), kind, p))
        seq = {}
        for n, kind, p in sorted(order):
            # to-normal comes twice a round: from mini (first) and from detailed (second); the file names collide per round,
            # so the split is by GUI cost order inside frame_split's own naming: keep them as one kind
            s = switch(p)
            if s:
                kinds.setdefault(kind, []).append(s)
        print(f"WVIEW {out}")
        for kind, ss in kinds.items():
            gui = [g for s in ss for g in s["gui"]]
            gaps = [g for s in ss for g in s["gaps"]]
            ren = [g for s in ss for g in s["ren"]]
            late = sum(1 for g in gaps if g > 12)
            print(f"  {kind:12s} x{len(ss)}  frames {sum(s['n'] for s in ss) / len(ss):5.1f} in {sum(s['ms'] for s in ss) / len(ss):4.0f} ms"
                  f" | gui med {statistics.median(gui):4.1f} worst {max(gui):3d} sum {sum(gui) / len(ss):5.0f}"
                  f" | render med {statistics.median(ren):3.1f} | gap med {statistics.median(gaps):4.1f} worst {max(gaps):3.0f}"
                  f" | late {late / len(ss):4.1f} of {len(gaps) / len(ss):4.1f}")


main()
