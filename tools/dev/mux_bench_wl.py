#!/usr/bin/env python3
"""mux_bench_wl.py -- reads a client's WAYLAND_DEBUG log for tools/dev/mux_bench.sh.

  mux_bench_wl.py typing <log> <from line> <label>      per key press: key -> the client's next surface commit (its own work),
                                                        that commit -> the compositor's next frame callback (the compositor's turn),
                                                        and key -> glass where the client asks wp_presentation (Chromium does)
  mux_bench_wl.py burst <log> <from line> <to line>     the frames (commits) a burst took, from its first commit to the first 300 ms quiet

Prints one line: `<label padded> {json}`. Stamps are libwayland's: [HH:MM:SS.micro] (wall clock) or [ms.micro] (older builds, as the
one Electron carries); both are read in ms.
"""
import json
import re
import sys


def ts(s):
    m = re.match(r"\[(\d+):(\d+):(\d+\.\d+)\]", s)
    if m:
        return (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))) * 1000
    m = re.match(r"\[\s*([0-9.]+)\]", s)
    return float(m.group(1)) if m else None


def events(lines):
    ev = []
    for s in lines:
        t = ts(s)
        if t is None:
            continue
        if re.search(r"wl_keyboard#\d+\.key\(\d+, \d+, \d+, 1\)", s):
            ev.append((t, "key"))
        elif re.search(r"-> wl_surface#\d+\.commit\(\)", s):
            ev.append((t, "commit"))
        elif re.search(r"wl_callback#\d+\.done\(", s):
            ev.append((t, "done"))
    return ev


def q(a, p):
    return round(sorted(a)[min(len(a) - 1, int(p * len(a)))], 1) if a else -1


def typing(lines, label):
    ev = events(lines)
    k2c, c2d = [], []
    for i, e in enumerate(ev):
        if e[1] != "key":
            continue
        j = next((j for j in range(i + 1, len(ev)) if ev[j][1] == "commit"), None)
        if j is None:
            continue
        k2c.append(ev[j][0] - e[0])
        d = next((x for x in ev[j + 1:] if x[1] == "done"), None)
        if d:
            c2d.append(d[0] - ev[j][0])
    return {"keys": len(k2c), "key_to_commit_p50": q(k2c, .5), "key_to_commit_p95": q(k2c, .95), "key_to_commit_max": q(k2c, 1),
            "commit_to_frame_p50": q(c2d, .5), "commit_to_frame_p95": q(c2d, .95)}


def glass(lines, start):
    """key -> glass per key press from `start` on: the first frame REQUESTED after the key (wp_presentation.feedback) and the time the
    compositor says it was shown. The log's clock and the presentation clock differ by a constant: the earliest delivery of a
    `presented` event bounds it (an event is logged after the frame it tells of). Feedback ids are reused, so a `presented` closes
    the OLDEST open request of its id. None when the client asks for no feedback (kitty asks none)."""
    req, pres, keys = {}, [], []
    for i, s in enumerate(lines):
        t = ts(s)
        if t is None:
            continue
        m = re.search(r"wp_presentation#\d+\.feedback\(wl_surface#\d+, new id wp_presentation_feedback#(\d+)\)", s)
        if m:
            req.setdefault(m.group(1), []).append(t)
            continue
        m = re.search(r"wp_presentation_feedback#(\d+)\.presented\((\d+), (\d+), (\d+)", s)
        if m:
            opened = req.get(m.group(1)) or []
            shown = ((int(m.group(2)) << 32) | int(m.group(3))) * 1000 + int(m.group(4)) / 1e6
            pres.append((opened.pop(0) if opened else None, t, shown))
            continue
        m = re.search(r"wp_presentation_feedback#(\d+)\.discarded\(", s)
        if m:
            opened = req.get(m.group(1)) or []
            if opened:
                opened.pop(0)
            continue
        if i >= start and re.search(r"wl_keyboard#\d+\.key\(\d+, \d+, \d+, 1\)", s):
            keys.append(t)
    if not pres or not keys:
        return None
    off = min(t - p for _, t, p in pres)
    frames = sorted((r, p + off) for r, t, p in pres if r is not None)
    out = []
    for k in keys:
        f = next((x for x in frames if x[0] > k), None)
        if f:
            out.append(f[1] - k)
    return out or None


def burst(lines):
    evb = [x for x in events(lines) if x[1] == "commit"]
    for i in range(1, len(evb)):
        if evb[i][0] - evb[i - 1][0] > 300:
            evb = evb[:i]
            break
    return {"frames": len(evb), "first_to_last_ms": round(evb[-1][0] - evb[0][0], 1) if len(evb) > 1 else 0}


def main():
    mode, path = sys.argv[1], sys.argv[2]
    lines = open(path, errors="replace").read().splitlines()
    if mode == "typing":
        out = typing(lines[int(sys.argv[3]):], sys.argv[4])
        g = glass(lines, int(sys.argv[3]))
        if g:
            out.update({"key_to_glass_p50": q(g, .5), "key_to_glass_p95": q(g, .95), "key_to_glass_max": q(g, 1)})
        print("%-9s %s" % (sys.argv[4], json.dumps(out)))
    else:
        out = burst(lines[int(sys.argv[3]):int(sys.argv[4])])
        print("%-9s %s" % ("burst", json.dumps(out)))


if __name__ == "__main__":
    main()
