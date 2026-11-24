#!/usr/bin/env python3
"""qml_profile.py -- a Qt QML profiler trace (.qtd, written by /usr/lib/qt6/bin/qmlprofiler) as a table: which JS functions, bindings
and signal handlers the GUI thread spent its time in, by SELF time (a range's duration less the ranges nested in it).

    qml_profile.py <trace.qtd> [--top N] [--strip PREFIX] [--file SUBSTR] [--by-file] [--window T0:T1]

  --top N        rows per table (default 25)
  --strip P      cut this path prefix from file names (the sandbox copy's root)
  --file S       only events whose file name contains S (self times are still computed over everything)
  --by-file      one more table: self time summed per file
  --window A:B   only ranges that START within A..B seconds of the trace's start

A trace holds ranges of one thread, properly nested, so self time is exact as far as the profiler's own cost allows: recording slows
call-heavy code (a function called 10 000 times a frame looks dearer than it is), so read shares here and take times from a run
without the profiler (tools/dev/perf/frame_split.sh without PROFILE). `calls` is the number of ranges, `self` and `total` are ms over
the whole recording, `max` is the longest single range's self time.
"""
import argparse
import re
import sys
from collections import defaultdict

EVENT = re.compile(r'<event index="(\d+)">(.*?)</event>', re.S)
FIELD = re.compile(r"<(displayname|type|filename|line|details)>(.*?)</\1>", re.S)
RANGE = re.compile(r'<range startTime="(\d+)" duration="(\d+)" eventIndex="(\d+)"')
UNESC = {"&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": '"', "&apos;": "'"}


def unesc(s):
    for k, v in UNESC.items():
        s = s.replace(k, v)
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--strip", default="")
    ap.add_argument("--file", default="")
    ap.add_argument("--by-file", action="store_true")
    ap.add_argument("--window", default="")
    a = ap.parse_args()
    text = open(a.trace, errors="replace").read()
    m = re.search(r'traceStart="(\d+)" traceEnd="(\d+)"', text)
    t_start, t_end = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    events = {}
    for em in EVENT.finditer(text):
        f = {k: unesc(v.strip()) for k, v in FIELD.findall(em.group(2))}
        fn = f.get("filename", "")
        fn = re.sub(r"^qs:@/qs/", "", fn)
        fn = re.sub(r"^file://", "", fn)
        if a.strip and fn.startswith(a.strip):
            fn = fn[len(a.strip):]
        events[int(em.group(1))] = (f.get("type", "?"), fn, f.get("line", "0"), f.get("details", f.get("displayname", "")))
    ranges = [(int(s), int(d), int(i)) for s, d, i in RANGE.findall(text) if int(d) > 0 or True]
    if not ranges:
        print(f"QML_PROFILE {a.trace}: no range in the trace")
        return 1
    ranges.sort(key=lambda r: (r[0], -r[1]))
    w0, w1 = None, None
    if a.window:
        x, y = a.window.split(":")
        w0, w1 = t_start + float(x) * 1e9, t_start + float(y) * 1e9
    self_ns, total_ns, calls, max_self = defaultdict(int), defaultdict(int), defaultdict(int), defaultdict(int)
    by_type = defaultdict(int)
    stack = []   # [end, index, child_ns, start, dur, on_stack_count_of_same_index]
    depth_of = defaultdict(int)
    top_level = 0

    def close(e):
        end, idx, child, start, dur = e
        s = max(0, dur - child)
        depth_of[idx] -= 1
        if w0 is None or w0 <= start <= w1:
            self_ns[idx] += s
            calls[idx] += 1
            max_self[idx] = max(max_self[idx], s)
            by_type[events.get(idx, ("?",))[0]] += s
            if depth_of[idx] == 0:      # a recursive call's total is its outermost range's
                total_ns[idx] += dur

    for start, dur, idx in ranges:
        while stack and stack[-1][0] <= start:
            close(stack.pop())
        if stack:
            stack[-1][2] += dur
        elif w0 is None or w0 <= start <= w1:
            top_level += dur
        depth_of[idx] += 1
        stack.append([start + dur, idx, 0, start, dur])
    while stack:
        close(stack.pop())

    span = (t_end - t_start) / 1e9
    all_self = sum(self_ns.values())
    print(f"QML_PROFILE {a.trace}")
    print(f"QML_PROFILE {len(ranges)} ranges, {len(events)} distinct events, {span:.1f} s recorded; {top_level / 1e6:.0f} ms inside QML/JS"
          f" ({100 * top_level / max(1, t_end - t_start):.1f} % of the recording)")
    print("QML_PROFILE by kind: " + ", ".join(f"{k} {v / 1e6:.0f} ms" for k, v in sorted(by_type.items(), key=lambda kv: -kv[1])))
    keys = [k for k in self_ns if not a.file or a.file in events.get(k, ("", ""))[1]]
    print(f"QML_PROFILE top {a.top} by SELF time{' in files matching ' + a.file if a.file else ''}:")
    print(f"    {'self ms':>8} {'%':>5} {'total ms':>9} {'calls':>8} {'max ms':>7}  kind        where")
    for k in sorted(keys, key=lambda k: -self_ns[k])[:a.top]:
        typ, fn, line, det = events.get(k, ("?", "?", "0", ""))
        print(f"    {self_ns[k] / 1e6:8.1f} {100 * self_ns[k] / max(1, all_self):5.1f} {total_ns[k] / 1e6:9.1f} {calls[k]:8d} {max_self[k] / 1e6:7.2f}  {typ[:10]:10}  {fn}:{line}  {det[:70]}")
    print(f"QML_PROFILE top {min(a.top, 12)} by TOTAL time (what one call from the outside costs, callees included):")
    for k in sorted(keys, key=lambda k: -total_ns[k])[:min(a.top, 12)]:
        typ, fn, line, det = events.get(k, ("?", "?", "0", ""))
        print(f"    {total_ns[k] / 1e6:8.1f} ms {calls[k]:8d} calls  {typ[:10]:10}  {fn}:{line}  {det[:70]}")
    if a.by_file:
        per = defaultdict(int)
        for k, v in self_ns.items():
            per[events.get(k, ("", "?"))[1]] += v
        print("QML_PROFILE self time per file:")
        for fn, v in sorted(per.items(), key=lambda kv: -kv[1])[:a.top]:
            print(f"    {v / 1e6:8.1f} ms {100 * v / max(1, all_self):5.1f} %  {fn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
