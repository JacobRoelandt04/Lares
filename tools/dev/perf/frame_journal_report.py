#!/usr/bin/env python3
"""frame_journal_report.py -- what the shell's FrameJournal holds, grouped by what was going on and ranked.

    frame_journal_report.py [FILE ...] [--hours H] [--session SID|last] [--top N] [--json OUT] [--since-ms T] [--until-ms T]

--since-ms / --until-ms (wall ms) cut the journal to a span (the perf tour's marks); the frame counts of the span are the difference of the
cumulative summaries at its two ends.

Reads the journal the shell writes (modules/shell/perf/FrameJournal.qml): by default
$XDG_STATE_HOME/lares/perf/frame-journal.1.jsonl (the rotated file, older) and frame-journal.jsonl, in that order.
Every line is one JSON object; `k` says what it is:

  stutter   a frame missed while the window was rendering continuously: `gap` ms between two presented frames (`worst` the
            longest when a slow stretch merged several, `gaps` the later ones), `miss` the vsyncs missed, `ref` the display
            period, `cls` the shape (gui / gui-tick / wait / free / late-a), `ctx` the popups' state at the late frame, `tr` the
            transitions of the two seconds before it, `ev`/`after` the window's raw frame events around it, `load`/`psi` the
            machine at the flush
  latency   a transition (a popup opening, the theme fading, ...) whose first frame came late: `lat` ms after `what`
  sum       one window's counters since the shell started (`frames`, `runs`, `stutters`, `missed`, `idle`, `idleGap`,
            `idleWait`, ...): the denominators; the last one of each (session, window) is used

WHAT IT PRINTS. The span and the sessions; per window the frames drawn, the misses and the rate per thousand frames; then the
stutters GROUPED BY CONTEXT (the popup and its phase, the theme fade, the islands, "no known motion" with the last transition)
and RANKED by missed frames: count, missed, worst and median gap, the classes, the machine's pressure; the slow first frames
by transition; the rests' histograms (how long the first frame after a rest takes to present: a compositor that holds the
first frame shows here); and the worst single records with their raw events.

THE CLASSES (FrameJournalHook.qml has the mechanics):
  gui       the GUI thread was busy in the gap (a handler, a build, a layout, a GC) -- or could not get a CPU (`psi` high)
  gui-tick  the GUI thread polished on time, then was busy before the next frame (the animation tick, a handler)
  wait      the GUI thread polished on time and then waited: the render thread (a first draw linking a pipeline, an upload, a
            heavy sync) or the compositor's frame callback
  free      the GUI thread was free and nothing was polished: the compositor held the frame callback (recorded only while a
            motion the window knows of spanned the gap)
A class is a reading of timing, not a profile: phase 2 reproduces a group's scenario under QSG_RENDER_TIMING to name the cost.
"""
import argparse
import json
import os
import statistics
import sys
import time
from collections import defaultdict

MOVING = ("opening", "closing", "moving")


def default_files():
    home = os.environ.get("HOME", "")
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state")
    base = os.path.join(state, "lares", "perf", "frame-journal")
    return [base + ".1.jsonl", base + ".jsonl"]


def read(files):
    recs, bad, seen = [], 0, []
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                seen.append(f)
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        o = json.loads(line)
                    except ValueError:
                        bad += 1
                        continue
                    if isinstance(o, dict):
                        recs.append(o)
                    else:
                        bad += 1
        except OSError:
            pass
    return recs, bad, seen


def when(t):
    return time.strftime("%m-%d %H:%M:%S", time.localtime(t / 1000.0)) if t else "?"


def context(e):
    """One label for what was going on at a record: the motion the window knew of, or the last transition before it."""
    c = e.get("ctx") or {}
    parts = []
    if c.get("fade"):
        parts.append("theme crossfade")
    slots = c.get("slots") or []
    moving = [s for s in slots if len(s) >= 3 and s[2] in MOVING]
    resting = [s for s in slots if len(s) >= 3 and s[2] not in MOVING]
    for s in moving:
        parts.append("%s %s %s" % (s[1] or "?", s[2], "(" + s[0] + ")" if s[0] != "pri" else ""))
    if c.get("islands") is not None:
        parts.append("islands moving")
    elif c.get("title"):
        parts.append("title morph")
    if c.get("bars") is not None:
        parts.append("bars toggle")
    if c.get("prewarm"):
        parts.append("prewarm")
    if not parts:
        if resting:
            parts.append("%s open, resting" % (resting[0][1] or "?"))
        else:
            tr = e.get("tr") or []
            last = tr[-1][0] if tr else ""
            parts.append("no known motion" + (" (after %s)" % last.split(":")[0] if last else ""))
    return "; ".join(p.strip() for p in parts)


def at_startup(e):
    """The shell's first minute (its prewarm builds and draws every popup once, compiling what the cache lacks): a world apart."""
    c = e.get("ctx") or {}
    return c.get("up", 1e9) < 60 or bool(c.get("prewarm"))


def reclass(e):
    """The record's class, re-read from its raw events where the runtime could not (a "wait" followed by two swaps at once on a
    paced platform is already "gui-tick")."""
    cls = e.get("cls", "?")
    psi = e.get("psi")
    if cls == "gui" and psi and psi[0] >= 20:
        return "gui (starved?)"
    return cls


def is_rest(e):
    """A record that is a window at rest, not frames missed: a gap of a minute or more (a frozen / covered / locked window: the first
    journal's 37-minute "miss"), or seconds in which the GUI thread was free."""
    g = e.get("worst", e.get("gap", 0))
    return g >= 60000 or (g >= 5000 and e.get("cls") == "free")


def right_after_load(e):
    """The first 30 s of a shell, apart from what its prewarm builds."""
    c = e.get("ctx") or {}
    return c.get("up", 1e9) < 30 and not c.get("prewarm")


def med(v):
    return statistics.median(v) if v else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--hours", type=float, default=0, help="only the last H hours")
    ap.add_argument("--session", default="", help="one session id, or 'last'")
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--json", default="")
    ap.add_argument("--since-ms", type=float, default=0)
    ap.add_argument("--until-ms", type=float, default=0)
    a = ap.parse_args()

    files = a.files or default_files()
    recs, bad, seen = read(files)
    if not seen:
        print("FRAME_JOURNAL no journal at %s" % " / ".join(files))
        return 2
    if a.hours > 0:
        cut = time.time() * 1000 - a.hours * 3600 * 1000
        recs = [r for r in recs if (r.get("t") or 0) >= cut]
    sids = []
    for r in recs:
        s = r.get("sid")
        if s and s not in sids:
            sids.append(s)
    allrecs = recs
    if a.since_ms or a.until_ms:
        lo, hi = a.since_ms or 0, a.until_ms or 1e18
        recs = [r for r in recs if lo <= (r.get("t") or 0) <= hi]
        sids = []
        for r in recs:
            s_ = r.get("sid")
            if s_ and s_ not in sids:
                sids.append(s_)
    if a.session:
        want = sids[-1] if a.session == "last" and sids else a.session
        recs = [r for r in recs if r.get("sid") == want]
        sids = [want]

    span_unknown = False
    st_all = [r for r in recs if r.get("k") == "stutter"]
    st = [r for r in st_all if not is_rest(r)]
    rests = [r for r in st_all if is_rest(r)]
    lat_all = [r for r in recs if r.get("k") == "latency"]
    lat = [r for r in lat_all if r.get("lat", 0) < 5000]       # a first frame "8 s late" is a frozen window's, not a frame's
    sums = {}
    for r in allrecs:
        if r.get("k") == "sum":
            key = (r.get("sid"), r.get("w"), r.get("scr"))
            t_ = r.get("t") or 0
            if a.until_ms and t_ > a.until_ms:
                continue
            sums[key] = r                                        # the last one wins: the counters are cumulative
    base = {}
    if a.since_ms:
        for r in allrecs:
            if r.get("k") == "sum" and (r.get("t") or 0) < a.since_ms:
                base[(r.get("sid"), r.get("w"), r.get("scr"))] = r
    if a.since_ms or a.until_ms:      # the span's own counts: the summary at its end less the one before its start
        cut = {}
        for key, s_ in sums.items():
            b = base.get(key)
            if b is None and a.since_ms and (s_.get("t") or 0) < a.since_ms:
                continue
            if a.since_ms and (b is None or b is s_):
                continue        # no summary on both sides of the span's start: this window's frame totals in the span are unknown
            d = dict(s_)
            if b:
                for f in ("frames", "runs", "stutters", "missed"):
                    d[f] = max(0, s_.get(f, 0) - b.get(f, 0))
            cut[key] = d
        if a.since_ms and not cut:
            span_unknown = True
        sums = cut
    for key, s_ in sums.items():                                 # the windows' misses less the rests the record merged into them
        ex = sum(r.get("miss", 0) for r in rests if (r.get("sid"), r.get("w"), r.get("scr")) == key)
        if ex and not (a.since_ms or a.until_ms):
            s_["missed"] = max(0, s_.get("missed", 0) - ex)
            s_["stutters"] = max(0, s_.get("stutters", 0) - sum(1 for r in rests if (r.get("sid"), r.get("w"), r.get("scr")) == key))
            s_["worst"] = max([r.get("worst", r.get("gap", 0)) for r in st if (r.get("sid"), r.get("w"), r.get("scr")) == key] or [0])
    ts = [r.get("t") for r in recs if r.get("t")]

    print("FRAME_JOURNAL %s" % ", ".join(seen))
    if a.since_ms or a.until_ms:
        print("FRAME_JOURNAL span %s .. %s" % (when(a.since_ms), when(a.until_ms)))
    print("FRAME_JOURNAL %d lines (%d not JSON), %s .. %s, %d session(s)" % (len(recs), bad, when(min(ts) if ts else 0),
                                                                          when(max(ts) if ts else 0), len(sids)))
    out = {"files": seen, "sessions": sids, "windows": [], "groups": [], "latency": [], "worst": []}

    # ---- the windows: denominators ----
    print("\nWINDOWS (since each shell start; the last summary of each)")
    tot_frames = tot_missed = 0
    for (sid, w, scr), s in sorted(sums.items(), key=lambda kv: str(kv[0])):
        fr, mi = s.get("frames", 0), s.get("missed", 0)
        tot_frames += fr
        tot_missed += mi
        rate = 1000.0 * mi / fr if fr else 0
        print("  %-12s %-8s session %-18s %8d frames in %6d runs, %4d stutters / %5d frames missed (%.1f per 1000), worst %d ms, "
              "period %.2f ms%s" % (w, scr, sid, fr, s.get("runs", 0), s.get("stutters", 0), mi, rate, s.get("worst", 0),
                                     s.get("ref", 0) or 0, "" if s.get("paced") else " (not vsync-paced)"))
        out["windows"].append({"sid": sid, "w": w, "scr": scr, "frames": fr, "missed": mi, "per1000": rate, "sum": s})
    if span_unknown:
        print("  (no summary on both sides of the span: its frame totals are unknown -- %d frames missed in it; a shell with `shell perfSum` "
              "brackets the tour)" % sum(r.get("miss", 0) for r in st))
    if tot_frames:
        print("  all windows: %d frames, %d missed (%.2f per 1000 frames)" % (tot_frames, tot_missed, 1000.0 * tot_missed / tot_frames))

    # ---- stutters by context: in use first, the start-ups apart ----
    groups = defaultdict(list)
    for e in st:
        groups[("start-up: " if at_startup(e) else "") + context(e)].append(e)
    if rests:
        print("\nNOT COUNTED: %d record(s) of a window at rest (a gap of 60 s or more, or 5 s with the GUI thread free: frozen / covered / "
              "locked), %d frames \"missed\" on paper" % (len(rests), sum(r.get("miss", 0) for r in rests)))
    if len(lat) != len(lat_all):
        print("NOT COUNTED: %d slow-first-frame record(s) of 5 s or more (a window frozen or remapped under a pending note)" % (len(lat_all) - len(lat)))
    ranked = sorted(groups.items(), key=lambda kv: (kv[0].startswith("start-up: "), -sum(x.get("miss", 1) for x in kv[1]), -len(kv[1])))
    n_use = sum(1 for e in st if not at_startup(e))
    print("\nSTUTTERS BY WHAT WAS GOING ON (%d in use, %d in a shell's first minute; ranked by frames missed)" % (n_use, len(st) - n_use))
    for label, es in ranked:
        gaps = [x.get("worst", x.get("gap", 0)) for x in es]
        missed = sum(x.get("miss", 1) for x in es)
        classes = defaultdict(int)
        for x in es:
            classes[reclass(x)] += 1
        psi = [x["psi"][0] for x in es if x.get("psi")]
        load = [x["load"][0] for x in es if x.get("load")]
        cls = ", ".join("%s %d" % kv for kv in sorted(classes.items(), key=lambda kv: -kv[1]))
        print("  %4d x %-58s missed %5d  gap median %4d worst %5d ms  [%s]%s" % (
            len(es), label[:58], missed, med(gaps), max(gaps), cls,
            ("  psi %.0f load %.1f" % (med(psi), med(load))) if psi else ""))
        out["groups"].append({"context": label, "count": len(es), "missed": missed, "gapMedian": med(gaps), "gapWorst": max(gaps),
                              "classes": dict(classes), "psiMedian": med(psi), "loadMedian": med(load),
                              "times": [x.get("t") for x in es][:50]})

    # ---- right after load ----
    ral = [e for e in st if right_after_load(e)]
    ral_lat = [e for e in lat if right_after_load(e)]
    if ral or ral_lat:
        print("\nRIGHT AFTER LOAD (the first 30 s of a shell, its prewarm apart: what the user meets when he starts working at once)")
        g2 = defaultdict(list)
        for e in ral:
            g2[context(e)].append(e)
        for label, es in sorted(g2.items(), key=lambda kv: -sum(x.get("miss", 1) for x in kv[1])):
            gaps = [x.get("worst", x.get("gap", 0)) for x in es]
            print("  %4d x %-58s missed %5d  gap median %4d worst %5d ms" % (len(es), label[:58], sum(x.get("miss", 1) for x in es), med(gaps), max(gaps)))
        for e in sorted(ral_lat, key=lambda x: -x.get("lat", 0))[:6]:
            print("  slow first frame: %-30s %5d ms after its note" % (e.get("what", "?")[:30], e.get("lat", 0)))
        out["afterLoad"] = [{"context": context(e), "miss": e.get("miss", 0), "gap": e.get("gap", 0)} for e in ral]

    # ---- slow first frames ----
    if lat:
        print("\nSLOW FIRST FRAMES (a transition whose first frame came late)")
        lg = defaultdict(list)
        for e in lat:
            what = e.get("what", "?") + (" (start-up)" if at_startup(e) else "")
            lg[what].append(e.get("lat", 0))
        for what, v in sorted(lg.items(), key=lambda kv: -sum(kv[1])):
            print("  %4d x %-40s median %4d ms, worst %5d ms" % (len(v), what[:40], med(v), max(v)))
            out["latency"].append({"what": what, "count": len(v), "median": med(v), "worst": max(v)})

    # ---- the rests ----
    restg = [0] * 7
    restw = [0] * 7
    for s in sums.values():
        for i, n in enumerate(s.get("idleGap") or []):
            if i < 7:
                restg[i] += n
        for i, n in enumerate(s.get("idleWait") or []):
            if i < 7:
                restw[i] += n
    if sum(restg):
        print("\nRESTS (a new run after the window had stopped drawing; not stutters)")
        print("  rest length      <50 %d, <100 %d, <250 %d, <500 %d, <1 s %d, <5 s %d, longer %d" % tuple(restg))
        print("  first frame's polish -> present: <2 ms %d, <4 %d, <8 %d, <16 %d, <32 %d, <64 %d, longer %d" % tuple(restw))
        slow = sum(restw[4:])
        if slow and slow >= 0.1 * sum(restw):
            print("  NOTE %d of %d first frames after a rest took >= 32 ms to present after their polish: the render thread waited "
                  "(a frame callback the compositor held, or a first draw)" % (slow, sum(restw)))
        out["rests"] = {"length": restg, "firstFrame": restw}

    # ---- the worst records ----
    worst = sorted([e for e in st if not at_startup(e)], key=lambda x: -x.get("worst", x.get("gap", 0)))[:a.top]
    if worst:
        print("\nTHE WORST %d IN USE" % len(worst))
        for e in worst:
            tr = ", ".join("%s@%d" % (x[0], x[1]) for x in (e.get("tr") or [])[-4:])
            print("  %s %-10s gap %4d (%d missed) %-14s %s" % (when(e.get("t")), e.get("w", "?"), e.get("worst", e.get("gap", 0)),
                                                              e.get("miss", 0), reclass(e), context(e)))
            print("      events [%s] | after [%s]%s" % (e.get("ev", ""), e.get("after", ""), ("  transitions: " + tr) if tr else ""))
            out["worst"].append(e)

    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    print("\nFRAME_JOURNAL REPORT %d stutters in %d groups, %d slow first frames" % (len(st), len(groups), len(lat)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
