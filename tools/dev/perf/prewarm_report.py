#!/usr/bin/env python3
"""prewarm_report.py -- the start-up warm-up of one run, read from a shell log written with `--log-times` (frame_split.sh's
<outdir>/shell.log, or any nested run): when the bar was shown, when the warm-up started and ended, one row per entry (GooeyEngine's
`LARES prewarm entry` lines: build / block / plain / clip / destroy), and when the shell said `LARES settled`.

    prewarm_report.py <shell.log> [...]

`block` is the largest lateness of the engine's 16 ms heartbeat while the entry was in hand (its build, its first frames, its
deletion): the longest the GUI thread could not answer. One summary line per log: `PREWARM shown=<s> start=<s> end=<s>
settled=<s> maxblock=<ms> entries=<n>` (seconds after `Launching config`).
"""
import re
import sys
from datetime import datetime

TS = re.compile(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def stamp(line):
    m = TS.search(line)
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() if m else None


def report(path):
    t0 = shown = start = end = settled = None
    rows, other = [], []
    with open(path, errors="replace") as fh:
        for raw in fh:
            line = ANSI.sub("", raw.rstrip("\n"))
            t = stamp(line)
            if t is None:
                continue
            if "Launching config" in line and t0 is None:
                t0 = t
            if t0 is None:
                continue
            rel = t - t0
            if "LARES shown" in line and shown is None:
                shown = rel
            elif "LARES settled" in line:
                settled = rel
            elif "LARES prewarm start" in line:
                start = rel if start is None else start
                other.append((rel, line.split("LARES ", 1)[1]))
            elif "LARES prewarm end" in line:
                end = rel
                other.append((rel, line.split("LARES ", 1)[1]))
            elif "LARES prewarm entry" in line:
                kv = dict(re.findall(r"(\w+)=(-?\w+)", line))
                rows.append((rel, line.split("LARES prewarm entry ", 1)[1].split(" ")[0], kv))
            elif "LARES prewarm" in line:
                other.append((rel, line.split("LARES ", 1)[1]))
    print(f"== {path}")
    for rel, txt in other:
        print(f"  {rel:7.2f}s  {txt}")
    print(f"  {'at':>7}  {'entry':<16}{'build':>7}{'block':>7}{'plain':>7}{'clip':>7}  destroy")
    for rel, oid, kv in rows:
        print(f"  {rel:7.2f}s  {oid:<16}{kv.get('build', '?'):>7}{kv.get('block', '?'):>7}{kv.get('plain', '?'):>7}{kv.get('clip', '?'):>7}  {kv.get('destroy', '-')}")
    mb = max((int(kv.get("block", 0)) for _, _, kv in rows), default=0)
    f = lambda v: "none" if v is None else f"{v:.2f}"
    print(f"PREWARM shown={f(shown)} start={f(start)} end={f(end)} settled={f(settled)} maxblock={mb} entries={len(rows)}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    for p in sys.argv[1:]:
        report(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
