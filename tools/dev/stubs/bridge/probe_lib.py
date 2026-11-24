#!/usr/bin/env python3
"""Helpers of tools/dev/bridge_tool_probe.sh (never run by hand on a real session).

    probe_lib.py stamp <file>              stdin -> <file>, each line as `<epoch>\\t<line>` (the watch output, timestamped)
    probe_lib.py wait <file> <s> <expr>    exit 0 as soon as <expr> is true over the file's JSON lines (L: the last, ALL: every one, T: times),
                                           1 at the deadline (the last line is printed)
    probe_lib.py ev <expr>                 exit 0 when <expr> is true over the JSON on stdin (J)
    probe_lib.py count <file> <expr>       how many lines satisfy <expr> (L)
    probe_lib.py world <file> <json>       write the world file whole
"""
import json
import sys
import time


def lines(path):
    out, ts = [], []
    try:
        with open(path) as f:
            for raw in f:
                t, _, body = raw.partition("\t")
                try:
                    out.append(json.loads(body))
                    ts.append(float(t))
                except ValueError:
                    pass
    except OSError:
        pass
    return out, ts


def main():
    a = sys.argv[1:]
    if a[0] == "stamp":
        with open(a[1], "a") as f:
            for l in sys.stdin:
                f.write("%.3f\t%s" % (time.time(), l))
                f.flush()
    elif a[0] == "wait":
        end = time.time() + float(a[2])
        while True:
            all_, ts = lines(a[1])
            if all_:
                try:
                    if eval(a[3], {}, {"L": all_[-1], "ALL": all_, "T": ts}):
                        return 0
                except (KeyError, IndexError, TypeError, ValueError, StopIteration):
                    pass
            if time.time() > end:
                print(json.dumps(all_[-1])[:600] if all_ else "(no line)")
                return 1
            time.sleep(0.05)
    elif a[0] == "ev":
        try:
            return 0 if eval(a[1], {}, {"J": json.loads(sys.stdin.read())}) else 1
        except (KeyError, IndexError, TypeError, ValueError, StopIteration):
            return 1
    elif a[0] == "count":
        all_, ts = lines(a[1])
        n = 0
        for l, t in zip(all_, ts):
            try:
                if eval(a[2], {}, {"L": l, "T": t}):
                    n += 1
            except (KeyError, IndexError, TypeError, ValueError):
                pass
        print(n)
    elif a[0] == "world":
        with open(a[1], "w") as f:
            f.write(a[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
