#!/usr/bin/env python3
"""Judge of bt_battery_motion_probe.sh: `BBM f <n> <step> <presence> <height> <foot> <figures> <traffic>` per frame (design px)."""
import sys
rows = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 9 and p[1] == "f":
        rows.append(dict(n=int(p[2]), step=p[3], pres=float(p[4]), h=float(p[5]), foot=float(p[6]), fig=float(p[7]), tr=int(p[8])))
warn = len(sys.argv) > 2 and sys.argv[2] == "warn"
fails = 0
def say(ok, name, detail=""):
    global fails
    if not ok:
        fails += 1
    print("BBJ %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [" + detail + "]"))
def of(step):
    return [r for r in rows if r["step"] == step]

say(not warn, "no warnings in the log")
A = of("A_appear")
full = [r for r in A if r["h"] >= 13.999]
foot = full[-1]["foot"] if full else None
say(foot is not None, "A: the stripe reaches its full 14 px")
if foot is not None:
    grown = [r for r in A if r["h"] > 0.001]
    say(all(abs(r["foot"] - foot) < 0.01 for r in grown), "A: it grows from its foot (the foot never moves)",
        "feet " + str(sorted(set(round(r["foot"], 2) for r in grown))[:5]))
    say(all(b["h"] >= a["h"] - 1e-6 for a, b in zip(A, A[1:])), "A: the length only grows")
    say(grown and grown[0]["h"] < 4, "A: it starts from nothing", "first drawn %.2f" % (grown[0]["h"] if grown else -1))
    ms = (len(grown) - len([r for r in grown if r["h"] >= 13.999])) * 16
    say(200 <= ms + 32 <= 420, "A: the growth takes about 300 ms", "%d ms" % ms)
B = of("B_traffic")
t0 = next((i for i, r in enumerate(B) if r["tr"]), None)
say(t0 is not None, "B: the traffic figures come up")
if t0 is not None:
    gone = next((i for i, r in enumerate(B) if i >= t0 and r["h"] < 0.001), None)
    say(gone is not None and gone - t0 <= 12, "B: the stripe has yielded within 12 frames (~190 ms) of the traffic", "frames %s" % (None if gone is None else gone - t0))
    say(all(abs(r["foot"] - foot) < 0.01 for r in B if r["h"] > 0.001), "B: it shrinks down to its foot")
    say(all(not (r["fig"] > 0.3 and r["h"] > 0.01) for r in rows), "no frame has the figures above 0.3 presence over a drawn stripe",
        str([(r["n"], r["fig"], r["h"]) for r in rows if r["fig"] > 0.3 and r["h"] > 0.01][:3]))
    say(all(r["fig"] <= 0.0001 or r["h"] <= 3.0 + 0.5 for r in B), "B: the figures' fade starts only once the stripe is <= 3 px")
    say(B[-1]["fig"] > 0.99, "B: the figures are fully in")
C = of("C_leave")
l0 = next((i for i, r in enumerate(C) if not r["tr"]), None)
if l0 is not None:
    grow0 = next((i for i, r in enumerate(C) if r["h"] > 0.001), None)
    say(grow0 is not None and grow0 - l0 >= 10, "C: after the traffic the stripe waits before it grows back", "waited %s frames" % (None if grow0 is None else grow0 - l0))
    say(C[-1]["h"] >= 13.999, "C: and grows back to full")
else:
    say(False, "C: the traffic ended")
Dl = of("D_leave")
Db = of("D_back")
say(bool(Dl) and bool(Db) and all(r["h"] < 0.001 for r in Dl + Db), "D: traffic returning inside the wait cancels the regrow (the stripe never grew)")
say(bool(Db) and Db[-1]["fig"] > 0.99, "D: the figures come back")
E = of("E_leave")
say(bool(E) and E[-1]["h"] >= 13.999, "E: the stripe grows back once the traffic is gone for good")
Fm = of("F_gone")
sh = [r for r in Fm if r["h"] > 0.001]
say(bool(sh) and all(abs(r["foot"] - foot) < 0.01 for r in sh), "F: a device that goes shrinks down to its foot")
say(bool(Fm) and Fm[-1]["h"] < 0.001 and all(b["h"] <= a["h"] + 1e-6 for a, b in zip(Fm, Fm[1:])), "F: the length only shrinks, to nothing")
print("BT_BATTERY_MOTION RESULT %s (%d fails)" % ("FAIL" if fails else "PASS", fails))
sys.exit(1 if fails else 0)
