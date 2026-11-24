#!/usr/bin/env python3
"""veil_perf.py -- read a tools/dev/perf/veil_perf.sh run: the harness's phase marks (tools/dev/qml/veil_perf.qml, with
quickshell's --log-times stamps), Qt's per-frame lines (QSG_RENDER_TIMING=1) and the preload's GPU time per frame
(tools/dev/perf/veil_gputime.c), and print one line per veil.

    veil_perf.py <log> <gpu.tsv> [--clock CLK.csv] [--json OUT]

    gpu ms     the median of the veil's frames' GPU time over every round, [the lowest .. the highest per-round median]
    own        that less the floor's ("none": the stand-in still and silhouette alone) -- what the veil itself costs a frame
    MHz        the GPU's median graphics clock over the veil's windows (nvidia-smi, every 100 ms; the driver picks it by load)
    own Mcyc   `own` in millions of GPU cycles (ms x MHz / 1000, per frame at the window's clock): what does not move with
               the clock the driver picked, so veils measured at different clocks compare
    render     the render thread's frame (sync + render + swap issue: the CPU side of drawing), median
    gui        the GUI thread's prepare per frame (polish + the wait for the sync + animations), median
    tick       the bindings one seek re-runs on the GUI thread (GUI_N seeks back to back, per seek)
    first      setSource to the first frame drawn with the veil: round 0 (an empty shader cache: the cold compile) / later rounds
               (warm in the process)
    frames     frames read in the measured windows (a phase at FPS for PHASE_MS)
    still      frames drawn at rest (STILL_MS): the veil's own clock eased to still, beyond the floor's ("none": the harness's own
               Timer start draws one or two)
Exit 1 when a phase read no GPU frames or a veil drew at rest.
"""
import datetime
import json
import re
import statistics
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})")
GUI = re.compile(r"\[gui thread\] Frame prepared, polish=(\d+) ms, lock=(\d+) ms, blockedForSync=(\d+) ms, animations=(\d+) ms")
REN = re.compile(r"\[render thread [^\]]+\] syncAndRender: frame rendered in (\d+) ?ms, sync=(\d+), render=(\d+), swap=(\d+)")
VP = re.compile(r"qml\S*: (VP .*)$")


def stamp(line):
    m = TS.match(line)
    if not m:
        return None
    return datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000.0


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def main():
    args = sys.argv[1:]
    jout = clk = None
    if "--json" in args:
        i = args.index("--json")
        jout = args[i + 1]
        del args[i:i + 2]
    if "--clock" in args:
        i = args.index("--clock")
        clk = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    log, gpu = args
    windows = []           # (veil, round, t0, t1)
    open_at = {}
    gui_tick = {}          # veil -> [ms per seek]
    first = {}             # veil -> {round: ms}
    still = {}
    ren, guif = [], []
    for raw in open(log, errors="replace"):
        line = ANSI.sub("", raw)
        t = stamp(line)
        if t is None:
            continue
        m = VP.search(line)
        if m:
            w = m.group(1).split()
            if w[1] == "phase" and w[4] == "measure":
                open_at[(w[2], int(w[3]))] = t
            elif w[1] == "phase" and w[4] == "end":
                k = (w[2], int(w[3]))
                if k in open_at:
                    windows.append((k[0], k[1], open_at.pop(k), t))
            elif w[1] == "gui":
                kv = dict(x.split("=") for x in w[4:])
                gui_tick.setdefault(w[2], []).append(float(kv["ms"]) / max(1, int(kv["n"])))
            elif w[1] == "first":
                kv = dict(x.split("=") for x in w[4:])
                first.setdefault(w[2], {})[int(w[3])] = float(kv["frameMs"])
            elif w[1] == "still":
                kv = dict(x.split("=") for x in w[3:])
                still[w[2]] = (int(kv["frames"]), kv.get("resting"))
            continue
        r = REN.search(line)
        if r:
            ren.append((t, int(r.group(1))))
            continue
        g = GUI.search(line)
        if g:
            guif.append((t, int(g.group(1)) + int(g.group(2)) + int(g.group(3)) + int(g.group(4))))
    frames = []
    for ln in open(gpu):
        p = ln.split()
        if len(p) >= 2:
            frames.append((float(p[0]), float(p[1])))

    clocks = []
    if clk:
        for ln in open(clk, errors="replace"):
            p = [x.strip() for x in ln.split(",")]
            try:
                t = datetime.datetime.strptime(p[0], "%Y/%m/%d %H:%M:%S.%f").timestamp() * 1000.0
                clocks.append((t, float(p[1].split()[0])))
            except (ValueError, IndexError):
                pass

    def inside(series, t0, t1):
        return [v for (t, v) in series if t0 <= t <= t1]

    def cycles(t0, t1, series):
        # each frame's time x the clock read nearest it
        out = []
        for (t, v) in series:
            if t0 <= t <= t1 and clocks:
                c = min(clocks, key=lambda c: abs(c[0] - t))[1]
                out.append(v * c / 1000.0)
        return out

    order = []
    for v, _, _, _ in windows:
        if v not in order:
            order.append(v)
    res = {}
    bad = []
    for v in order:
        ws = [w for w in windows if w[0] == v]
        allg, per_round, allr, allgui, allc, allmhz, cyc_round = [], [], [], [], [], [], []
        rounds = {}
        for _, rd, t0, t1 in ws:
            g = inside(frames, t0, t1)
            if not g:
                bad.append("%s round %d read no GPU frames" % (v, rd))
                continue
            allg += g
            per_round.append(med(g))
            c = cycles(t0, t1, frames)
            allc += c
            if c:
                cyc_round.append(med(c))
            rounds[rd] = {"gpu": med(g), "cyc": med(c) if c else float("nan")}
            allmhz += inside(clocks, t0, t1)
            allr += inside(ren, t0, t1)
            allgui += inside(guif, t0, t1)
        f = first.get(v, {})
        res[v] = {
            "gpu": med(allg), "lo": min(per_round) if per_round else float("nan"), "hi": max(per_round) if per_round else float("nan"),
            "p90": sorted(allg)[int(len(allg) * 0.9)] if allg else float("nan"),
            "render": med(allr), "gui": med(allgui), "tick": med(gui_tick.get(v, [])) * 1000.0,
            "cold": f.get(0, float("nan")), "warm": med([x for r, x in f.items() if r > 0]), "frames": len(allg),
            "mhz": med(allmhz), "cyc": med(allc), "clo": min(cyc_round) if cyc_round else float("nan"),
            "chi": max(cyc_round) if cyc_round else float("nan"), "rounds": rounds,
        }
    floor = res.get("none", {}).get("gpu", 0.0)
    cfloor = res.get("none", {}).get("cyc", 0.0)
    print("  %-8s %8s %17s %7s %7s %6s %9s %17s %7s %7s %8s %13s %6s" % ("veil", "gpu ms", "[round medians]", "p90", "own", "MHz",
          "own Mcyc", "[round Mcyc]", "render", "gui", "tick us", "first c/w ms", "frames"))
    for v in order:
        r = res[v]
        own = r["gpu"] - floor if v != "none" else 0.0
        r["own"] = own
        r["ownc"] = r["cyc"] - cfloor if v != "none" else 0.0
        print("  %-8s %8.3f   [%6.3f %6.3f] %7.3f %7.3f %6.0f %9.3f   [%6.3f %6.3f] %7.1f %7.1f %8.0f %6.0f/%-6.0f %6d" % (
            v, r["gpu"], r["lo"], r["hi"], r["p90"], own, r["mhz"], r["ownc"], r["clo"], r["chi"], r["render"], r["gui"], r["tick"],
            r["cold"], r["warm"], r["frames"]))
    # A/B (--ab): each round's own share of A and of B (each less that round's floor), paired by round, so the GPU's clock
    # state and the machine's load of that round are the same for both
    nr = res.get("none", {}).get("rounds", {})
    for v in order:
        if v.startswith("b:") or ("b:" + v) not in res:
            continue
        a, b = res[v]["rounds"], res["b:" + v]["rounds"]
        common = sorted(set(a) & set(b) & set(nr))
        if not common:
            continue
        oa = [a[r]["gpu"] - nr[r]["gpu"] for r in common]
        ob = [b[r]["gpu"] - nr[r]["gpu"] for r in common]
        ca = [a[r]["cyc"] - nr[r]["cyc"] for r in common]
        cb = [b[r]["cyc"] - nr[r]["cyc"] for r in common]
        dm = [y - x for x, y in zip(oa, ob)]
        dc = [y - x for x, y in zip(ca, cb)]
        ma, mc = med(oa), med(ca)
        print("  A/B %-8s own A %.3f ms  B %.3f ms  B-A %+.3f ms [%+.3f %+.3f] (%+.0f %%)   Mcyc A %.3f B %.3f B-A %+.3f (%+.0f %%)   tick %.0f / %.0f us   cold %.0f / %.0f ms   %d rounds" % (
            v, ma, med(ob), med(dm), min(dm), max(dm), 100.0 * med(dm) / ma if ma > 0 else 0, mc, med(cb), med(dc),
            100.0 * med(dc) / mc if mc > 0 else 0, res[v]["tick"], res["b:" + v]["tick"], res[v]["cold"], res["b:" + v]["cold"], len(common)))
        res[v]["ab"] = {"ownA": ma, "ownB": med(ob), "diff": med(dm), "dlo": min(dm), "dhi": max(dm), "cycA": mc, "cycB": med(cb), "dcyc": med(dc)}
    # The window's own Timer start draws a frame or two (Qt wakes the render loop when an animation-driven Timer starts):
    # "none" -- no veil -- draws them too, so a veil's count is read against it.
    sfloor = still.get("none", (0, None))[0]
    for v, (n, resting) in still.items():
        over = n - sfloor if v != "none" else 0
        print("  still %-8s frames=%d (the harness's own: %d) resting=%s%s" % (v, n, sfloor, resting, "" if over <= 0 else "   <-- DRAWS AT REST"))
        res.setdefault(v, {})["still"] = over
        if over > 0:
            bad.append("%s drew %d frames at rest" % (v, over))
    if jout:
        json.dump(res, open(jout, "w"), indent=1)
    if bad:
        print("  " + "; ".join(bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
