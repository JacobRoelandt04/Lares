#!/usr/bin/env python3
"""field_shape_extract.py -- the FSREC lines of a recorded shell log (tools/dev/perf/field_shape_patch.py) as a corpus.

    field_shape_extract.py <shell.log> <marks.tsv> <corpus.jsonl>

One call a line, in the order the shell made them, each with "cls": the scenario its time fell in (marks.tsv's `begin <sc>` /
`end <sc>`), "other" outside every scenario. The JSON of each call is copied byte for byte after that key: nothing is re-encoded.
Prints a count per scenario; exits 1 when there was no call at all.
"""
import sys


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    log, marks, out = sys.argv[1:]
    spans = []
    opened = {}
    for line in open(marks):
        t, _, what = line.rstrip("\n").partition("\t")
        if what.startswith("begin "):
            opened[what[6:]] = float(t) * 1000
        elif what.startswith("end ") and what[4:] in opened:
            spans.append((opened.pop(what[4:]), float(t) * 1000, what[4:]))
    counts = {}
    n = 0
    with open(out, "w") as w:
        for raw in open(log, "rb"):
            k = raw.find(b"FSREC {")
            if k < 0:
                continue
            body = raw[k + 6:].decode("utf-8").rstrip("\n")
            # "t" is the record's third key: {"f":"..","q":N,"t":T,...
            ti = body.index('"t":') + 4
            te = ti
            while body[te] not in ",}":
                te += 1
            t = float(body[ti:te])
            cls = "other"
            for a, b, name in spans:
                if a <= t <= b:
                    cls = name
                    break
            counts[cls] = counts.get(cls, 0) + 1
            w.write('{"cls":"' + cls + '",' + body[1:] + "\n")
            n += 1
    for name in sorted(counts):
        print(f"FS_EXTRACT {name}: {counts[name]} calls")
    print(f"FS_EXTRACT total {n} calls -> {out}")
    return 0 if n > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
