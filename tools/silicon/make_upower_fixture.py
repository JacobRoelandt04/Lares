#!/usr/bin/env python3
"""make_upower_fixture.py -- a SYNTHETIC week of UPower charge history, in the bytes the real gdbus prints.

    tools/silicon/make_upower_fixture.py             writes tools/dev/fixtures/silicon/upower/charge_*.txt + charge_week.anchors.json
    tools/silicon/make_upower_fixture.py --out DIR   writes them to DIR instead
    tools/silicon/make_upower_fixture.py --check     fails when the committed files are not what this makes

WHY. The REAL captures of this laptop's battery (a week of timestamps of when it was plugged in and full) are the user's
own, and live in a gitignored folder (tools/dev/fixtures/silicon/upower_local/). The gates replay THIS week always and the
real one too when the local folder has it. The bytes follow what the real answers were (UpowerParse.js has the facts):

  * `([(uint32 T, P.0, uint32 S), (T, P.0, S), ...],)` -- only the FIRST tuple carries the `uint32` annotations;
  * a time span is answered NEWEST first, a span of 0 ("all") OLDEST first and reaches further back than a week;
  * the empty answer is `(@a(udu) [],)`;
  * asked for too few points UPower merges neighbours (percentages averaged, long floats) and the NEWEST point's state
    reads 0 -- charge_fewpoints.txt;
  * the states: 0 unknown, 1 charging, 2 discharging, 4 fully-charged, 5 pending-charge (held at a limit, or a plug-in that
    has not started charging); an upowerd start leaves a (0.0, state 0) item at the instant of another point.

DETERMINISTIC: a fixed linear congruential generator jitters the spacing of the points; there is no clock and no random
module, so the same call writes the same bytes on every machine. charge_week.anchors.json says where the interesting moments
are (the newest full point, the stretch before it, the 77 % plug-in ...) so the cases do not repeat them as literals.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT_DEFAULT = os.path.join(ROOT, "tools", "dev", "fixtures", "silicon", "upower")

T_END = 1791000000          # the newest point of the week: the pack is full
WEEK_S = 604800
DAY = 86400

# episodes, oldest first: (kind, from %, to %, seconds the episode takes). `full` is ONE point (UPower writes a point on a change),
# `held` is ONE pending-charge point at the limit, `plugin` is the pending-charge point of a plug-in that has not started charging.
# (`dwell`: the pack sits there, nothing changes, no point is written.) The first six are older than a week: only the "all" answer has them.
EPISODES = [
    ("discharge", 99, 30, 36 * 3600),
    ("charge", 30, 100, 4 * 3600), ("full",), ("dwell", 10 * 3600),
    ("discharge", 99, 60, 20 * 3600),
    ("charge", 60, 100, 3 * 3600), ("full",), ("dwell", 6 * 3600),
    ("discharge", 99, 71, 20 * 3600),
    ("charge", 71, 100, 3 * 3600), ("full",), ("dwell", 20 * 3600),
    ("discharge", 99, 38, 26 * 3600),
    ("charge", 38, 100, 4 * 3600), ("full",), ("dwell", 14 * 3600),
    ("discharge", 99, 77, 9 * 3600),
    ("plugin", 77),                                     # the pack at 77 %, mains in, charging not yet started
    ("charge", 78, 100, 2 * 3600), ("full",), ("dwell", 18 * 3600),
    ("marker",),                                        # upowerd restarted while full
    ("discharge", 99, 52, 17 * 3600),
    ("charge", 52, 80, 2 * 3600), ("held",),            # a day at the 80 % limit
    ("discharge", 79, 64, 8 * 3600),
    ("charge", 64, 100, 3 * 3600), ("full",),
    ("discharge", 99, 88, 3 * 3600),
    ("charge", 88, 99, 1800), ("full",),                # the newest full point: T_END
]


class Lcg:
    def __init__(self, seed):
        self.s = seed

    def next(self):                                     # 0..1
        self.s = (self.s * 1103515245 + 12345) & 0x7FFFFFFF
        return self.s / 0x7FFFFFFF


def build():
    """-> (points oldest first [(t, pct, state)], anchors)"""
    rng = Lcg(20261009)
    pts = []
    t = 0.0
    names = []                                          # (index of the point, name) for the anchors
    for ep in EPISODES:
        k = ep[0]
        if k in ("discharge", "charge"):
            a, b, dur = ep[1], ep[2], ep[3]
            n = abs(b - a) + 1
            step = 1 if b >= a else -1
            state = 1 if k == "charge" else 2
            # spacing: jitter around dur / n, the last point at the episode's end
            w = [0.6 + 0.8 * rng.next() for _ in range(n)]
            tot = sum(w)
            for i in range(n):
                t += dur * w[i] / tot
                pts.append((round(t), float(a + step * i), state))
        elif k == "full":
            t += 90 + 40 * rng.next()
            pts.append((round(t), 100.0, 4))
            names.append((len(pts) - 1, "full"))
            t += 600 + 300 * rng.next()
        elif k == "held":
            t += 60
            pts.append((round(t), 80.0, 5))
            t += 5 * 3600
        elif k == "plugin":
            t += 120
            pts.append((round(t), float(ep[1]), 5))
            names.append((len(pts) - 1, "plugin"))
            t += 72                                     # charging starts 72 s later
        elif k == "dwell":
            t += ep[1]
        elif k == "marker":
            t += 3600
            pts.append((round(t), 100.0, 4))
            names.append((len(pts) - 1, "full"))
            pts.append((round(t), 0.0, 0))              # the upowerd start item, at the instant of the other point
            t += 900
    shift = T_END - pts[-1][0]
    pts = [(p[0] + shift, p[1], p[2]) for p in pts]
    # the anchors: found by reading the points back, as a reader would, not by remembering which episode made them
    fulls = [i for i, p in enumerate(pts) if p[2] == 4]
    last_full = pts[fulls[-1]][0]
    prev_full = pts[fulls[-2]][0]
    left = min(p[0] for p in pts if p[0] > prev_full and p[2] != 0)
    plug = [i for i, p in enumerate(pts) if p[2] == 5 and p[1] == 77.0][0]
    before_plug = [p for p in pts[:plug] if p[2] == 4][-1][0]
    return pts, {"newestFullMs": last_full * 1000, "prevFullMs": prev_full * 1000, "prevLeftMs": left * 1000,
                 "plugin77Ms": pts[plug][0] * 1000, "fullBeforePluginMs": before_plug * 1000}


def fmt_pct(p):
    return "%.1f" % p if float(p).is_integer() else repr(p)


def render(points):
    """points in the order to print -> gdbus's text (only the first tuple carries the `uint32` annotations)"""
    parts = []
    for i, (t, p, s) in enumerate(points):
        parts.append("(uint32 %d, %s, uint32 %d)" % (t, fmt_pct(p), s) if i == 0 else "(%d, %s, %d)" % (t, fmt_pct(p), s))
    return "([" + ", ".join(parts) + "],)\n"


def fewpoints(week_newest_first, n):
    """UPower asked for too few points: neighbours merged (charge averaged, a long float), and the NEWEST point loses its state"""
    per = len(week_newest_first) / float(n)
    out = []
    for k in range(n):
        chunk = week_newest_first[int(k * per):int((k + 1) * per)] or week_newest_first[-1:]
        t = chunk[0][0]
        p = sum(c[1] for c in chunk) / len(chunk)
        s = chunk[0][2]
        out.append((t, p, 0 if k == 0 else s))
    return out


def files():
    pts, anchors = build()
    cut = T_END - WEEK_S
    week = [p for p in pts if p[0] >= cut]
    week_new = list(reversed(week))
    anchors.update({"count": len(week), "oldestMs": week[0][0] * 1000, "states": sorted(set(p[2] for p in week)),
                    "allCount": len(pts), "allOldestMs": pts[0][0] * 1000})
    return {
        "charge_week.txt": render(week_new),                         # a time span: newest first
        "charge_all_oldest_first.txt": render(pts),                  # span 0: oldest first, and further back than a week
        "charge_empty.txt": "(@a(udu) [],)\n",
        "charge_fewpoints.txt": render(fewpoints(week_new, 24)),
        "charge_week.anchors.json": json.dumps(anchors, indent=2, sort_keys=True) + "\n",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    fs = files()
    if a.check:
        bad = 0
        for name, text in fs.items():
            p = os.path.join(a.out, name)
            have = open(p, encoding="utf-8").read() if os.path.exists(p) else None
            if have != text:
                print("STALE %s" % p)
                bad = 1
        print("make_upower_fixture --check: " + ("STALE" if bad else "up to date"))
        return bad
    os.makedirs(a.out, exist_ok=True)
    for name, text in fs.items():
        with open(os.path.join(a.out, name), "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote %s (%d bytes)" % (os.path.join(a.out, name), len(text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
