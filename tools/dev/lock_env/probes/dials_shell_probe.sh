#!/usr/bin/env bash
# dials_shell_probe.sh -- the DIALS veil and the shell's place (feedback: the dials veil centred its rings on a guessed popup
# before the shell existed, the same kind of fault as paper's "T"), offscreen, from a copy of a tree: a boot (the veil
# alone, the shell's bar, then its popup opening out of the bar's foot one shell frame at a time), a regular lock (the bar
# there from the start, the popup opening later) and a lock whose popup is there from the start, rendered by
# dials_shell.qml on a held clock at the user's eDP-1 (2304 x 1296: 2880 x 1620 at scale 1.25). Two readings: the frame
# record of what the veil drew (centre, hub, tick hubs, re-cuts) every 1/120 s, and a film of the veil alone (no shell drawn
# over it) at 60 fps, read ring by ring: each ring's tick count is MEASURED from its pixels (the strongest of the counts a
# ring can have -- whole numeral wheels, 50 ticks each -- along a circle through its minor ticks) with how strongly it shows.
#
#   tools/dev/lock_env/probes/dials_shell_probe.sh [OUTDIR]          this tree
#   TREE=<dir> tools/dev/lock_env/probes/dials_shell_probe.sh ...    another tree's veil (an old revision: the base)
#   ARM=guess|noease|nocut ...                                        one fault put into the copy (below)
#
# Checks:
#   noshell   with no rect from the shell the rings centre on the top centre round a hub of hubMargin alone (the record),
#             no featureless disc wider than a ring holds the screen (a flat hub where no popup is: the old veil's guessed
#             560 x 660 stone left one of ~430 px), and at every presence of the boot's rise the floor is whole (no black)
#   arrive    as the bar and then the popup arrive the drawn centre and hub move at most 30 px (at 1620 high) per 1/120 s
#             -- no jump -- and land exactly on the live place once the ease is over; the bar alone centres on its foot
#   recut     no ring's tick count changes between two film frames while the ring shows its ticks in both (at least 35 %
#             of its settled strength): a ring is re-ticked only under a re-cut that has taken its engraving away; and the
#             arrival ends with every ring at the count of a dial whose popup was there from the start (the same frame)
#   there     a popup there from the veil's first moments is followed as it is: no ease, no re-cut, the live tick hub
# Ends in DIALS_SHELL_PROBE RESULT PASS|FAIL (what failed).
# ARMs (each fails on its own check): guess = the old guessed stone back for no shell (noshell); noease = the dial jumps to
# the live place (arrive); nocut = the tick counts follow the live hub in place, no re-cut (recut).
# Base revision c78b1ea4 (TREE=<a copy>): fails noshell, arrive and recut.
set -u
HERE="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
TREE="$(realpath "${TREE:-$HERE}")"
OUT="${1:-${SCRATCH:-/tmp}/dials_shell}"
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
W=$(mktemp -d /tmp/lrds.XXXXXX) || exit 1
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/t/h" "$W/rt" "$W/cfg/theme" "$W/state" "$W/cache" "$OUT/film"
rm -f "$OUT"/film/*.jpg
chmod 700 "$W/rt"
rsync -a --exclude '.qmlls.ini' "$TREE/modules" "$TREE/themes" "$W/t/" || { echo "DIALS_SHELL_PROBE RESULT FAIL (copy)"; exit 1; }
FIX="$TREE/mockups/fixtures/lockscreen/desktop_light_blur.png"
[ -f "$FIX" ] || FIX="$TREE/tests/fixtures/lockscreen/desktop_light_blur.png"
cp "$HERE/tools/dev/lock_env/probes/dials_shell.qml" "$W/t/h/shell.qml"
ln -s ../modules "$W/t/h/modules"
printf '{"theme":"eva","mode":"light"}\n' > "$W/cfg/theme/state.json"

arm() {  # file old new
    python3 - "$W/t/$1" "$2" "$3" <<'PY' || { echo "DIALS_SHELL_PROBE RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
}
V=modules/lockscreen/veil/VeilDials.qml
case "${ARM:-}" in
    "") ;;
    guess) arm $V '            s = Qt.rect(w / 2, 0, 0, 0);' '            s = Qt.rect((w - 560) / 2, 24, 560, 660);'
           arm $V '        } else if (br.width > 0 && br.height > 0) {' '        } else if (false) {' ;;
    noease) arm $V '        if (!a || t < a.at)
            return live;' '        if (true)
            return live;' ;;
    nocut) arm $V '    readonly property vector4d _recut: Qt.vector4d(' '    readonly property vector4d _recut: Qt.vector4d(0, 0, 1e6, 1e6); readonly property vector4d _recutArmed: Qt.vector4d(' ;;
    *) echo "DIALS_SHELL_PROBE RESULT FAIL (unknown ARM=$ARM)"; exit 1 ;;
esac
[ -n "${ARM:-}" ] && echo "  ARMED $ARM"

python3 - "$W/ops.json" <<'PY'
import json, sys
SW, SH = 2304, 1296
BAR = [802, 6, 700, 40]                   # the middle island
POP = [860, 46, 584, 520]                 # the lock popup, hanging from the island's foot
def popup_at(t, at, ms=400.0):            # the engine's open: OutBack, overshoot 1.2, one rect per shell frame (60 Hz)
    k = int((t - at) * 60 + 1e-6)
    x = max(0.0, min(1.0, k / 60.0 * 1000 / ms)); u = x - 1; s = 1.2
    e = u * u * ((s + 1) * u + s) + 1
    h = round(POP[3] * e, 2)
    return POP[:3] + [h] if h >= 0.5 else None    # the lock sends no popup of no height
ops = []
def timeline(boot, events, recs, grabs, presence=1.0):
    """events: [(t, {bar?/popup?})]; popup opening is an event ('open', at) expanded per shell frame"""
    ops.append({"op": "reset", "boot": boot, "presence": presence})
    ev = []
    for t, what in events:
        if what == "open":
            last = None
            for k in range(0, 40):
                tt = round(t + k / 60.0, 6); r = popup_at(tt, t)
                if r != last:
                    ev.append((tt, 0, {"op": "rects", "popup": r})); last = r
        else:
            ev.append((t, 0, dict(op="rects", **what)))
    for t, tag in recs:
        ev.append((t, 1, {"op": "rec", "tag": tag}))
    for t, name in grabs:
        ev.append((t, 2, {"op": "grab", "name": name, "file": name + ".jpg", "half": True}))
    ev.sort(key=lambda e: (e[0], e[1]))
    for t, _, o in ev:
        ops.append({"op": "seek", "t": t}); ops.append(o)
# noshell: the boot veil rising, no shell (full-size grabs)
for p in (0.05, 0.3, 0.7, 1.0):
    ops.append({"op": "reset", "boot": True, "presence": p}); ops.append({"op": "seek", "t": 1.0})
    ops.append({"op": "grab", "name": "noshell_p%03d" % round(p * 100), "file": "noshell_p%03d.png" % round(p * 100)})
# boot: the bar at 3.0, the popup opening out of it at 3.4
recs = [(round(2.9 + i / 120, 6), "boot") for i in range(int(4.8 * 120))]
grabs = [(round(3.35 + i / 60, 6), "film/boot_%03d" % i) for i in range(int(3.3 * 60))]
timeline(True, [(0.0, {"bar": None, "popup": None}), (3.0, {"bar": BAR}), (3.4, "open")], recs, grabs)
# regular: the bar there from the start, the popup opening at 2.0
recs = [(round(1.9 + i / 120, 6), "reg") for i in range(int(4.6 * 120))]
grabs = [(round(1.95 + i / 60, 6), "film/reg_%03d" % i) for i in range(int(3.0 * 60))]
timeline(False, [(0.0, {"bar": BAR}), (2.0, "open")], recs, grabs)
# the bar alone, arriving at 3.0
timeline(True, [(3.0, {"bar": BAR})], [(round(2.9 + i / 120, 6), "bar") for i in range(int(2.0 * 120))], [])
# there: the popup open from the start (a regular lock)
timeline(False, [(0.0, {"bar": BAR, "popup": POP})], [(t, "there") for t in (0.05, 0.1, 0.5, 2.0, 6.5)],
         [(6.5, "film/there_end")])
json.dump({"ops": ops, "bar": BAR, "pop": POP, "sw": SW, "sh": SH}, open(sys.argv[1], "w"))
PY
python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['ops'], open(sys.argv[2],'w'))" "$W/ops.json" "$W/ops.list.json"

LOG="$OUT/render.log"
(cd "$W/t/h" && env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$W/rt" XDG_CONFIG_HOME="$W/cfg" XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QS_DISABLE_CRASH_HANDLER=1 \
    OPS="$W/ops.list.json" OUT="$OUT" FIXTURE="$FIX" W=2304 H=1296 \
    timeout -k 5 900 quickshell -n -p "$W/t/h/shell.qml" > "$LOG" 2>&1)
r=$(rl_clean "$LOG" | grep -ao "DIALS_SHELL RESULT.*" | tail -1)
[ -n "$r" ] || { rl_noresult DIALS_SHELL_PROBE "$LOG"; exit 1; }
case "$r" in *PASS*) ;; *) echo "DIALS_SHELL_PROBE RESULT FAIL (render: $r)"; exit 1 ;; esac
noise=$(rl_clean "$LOG" | grep -a "Binding loop\|Cannot assign\|Unable to assign\|ReferenceError\|TypeError" | head -5)
[ -n "$noise" ] && { echo "$noise"; echo "DIALS_SHELL_PROBE RESULT FAIL (warnings in the render log)"; exit 1; }
rl_clean "$LOG" | grep -ao 'DIALS_REC .*' | sed 's/^DIALS_REC //' > "$OUT/records.jsonl"

python3 - "$OUT" "$W/ops.json" <<'PY'
import json, math, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage
out, spec = sys.argv[1], json.load(open(sys.argv[2]))
SW, SH, BAR, POP = spec["sw"], spec["sh"], spec["bar"], spec["pop"]
recs = [json.loads(l) for l in open(os.path.join(out, "records.jsonl"))]
by = {}
for r in recs:
    by.setdefault(r["tag"].split("/")[-1].rsplit("_", 1)[0] if r["tag"].startswith("film/") else r["tag"], []).append(r)
bad, lines = [], []
u = SH / 1620.0
def lum(a):
    return a[..., :3] @ np.array([0.2126, 0.7152, 0.0722])

# ---- noshell ----------------------------------------------------------------------------------------------------------
for p in ("005", "030", "070", "100"):
    name = "noshell_p" + p
    r = [x for x in recs if x["tag"] == name][0]
    a = np.asarray(Image.open(os.path.join(out, name + ".png")).convert("RGB")).astype(np.float64)
    L = lum(a)
    blk = (a.max(axis=2) < 14).mean()
    g = ndimage.gaussian_filter(L, 1.0)
    gy, gx = np.gradient(g)
    feat = np.hypot(gx, gy) > 0.6
    feat[0, :] = feat[-1, :] = feat[:, 0] = feat[:, -1] = True
    edt = ndimage.distance_transform_edt(~feat)
    flat = float(edt.max()); fy, fx = np.unravel_index(int(edt.argmax()), edt.shape)
    lines.append("  %-13s centre (%.1f, %.1f) hub %.1f  largest featureless disc r %.0f px at (%d, %d)  black %.3f %%"
                 % (name, r["cx"], r["cy"], r["hub"], flat, fx, fy, 100 * blk))
    if abs(r["cx"] - SW / 2) > 0.5 or abs(r["cy"]) > 0.5 or r["hub"] > r["margin"] * u + 0.5:
        bad.append("noshell: %s centres the rings at (%.0f, %.0f) round a hub of %.0f px with no shell (a guessed popup)"
                   % (name, r["cx"], r["cy"], r["hub"]))
    if flat > 92 * u:
        bad.append("noshell: %s holds a flat hub of r %.0f px at (%d, %d) where no popup is" % (name, flat, fx, fy))
    if blk > 0.0005:
        bad.append("noshell: %s's floor is not whole (%.2f %% black)" % (name, 100 * blk))

# ---- arrive --------------------------------------------------------------------------------------------------------------
JUMP = 30 * u
def arrive(tag, flips):
    rs = sorted(by[tag], key=lambda x: x["t"])
    worst = (0, None)
    for a, b in zip(rs, rs[1:]):
        d = max(math.hypot(b["cx"] - a["cx"], b["cy"] - a["cy"]), abs(b["hub"] - a["hub"]))
        if d > worst[0]:
            worst = (d, b["t"])
    lines.append("  %-6s largest step of the drawn centre / hub per 1/120 s: %.1f px at %.3f s (bound %.0f)" % (tag, worst[0], worst[1] or 0, JUMP))
    if worst[0] > JUMP:
        bad.append("arrive: %s's dial jumps %.0f px in 1/120 s at %.3f s" % (tag, worst[0], worst[1]))
    end = [x for x in rs if x["t"] >= flips + 1.25]
    if end and end[0]["live"]:
        off = max(max(abs(x["cx"] - x["live"][0]), abs(x["cy"] - x["live"][1]), abs(x["hub"] - x["live"][2])) for x in end)
        lines.append("  %-6s off the live place after the ease: %.4f px" % (tag, off))
        if off > 0.01:
            bad.append("arrive: %s's dial is %.2f px off the shell's place after the ease" % (tag, off))
    return rs
arrive("boot", 3.4 + 0.4)
arrive("reg", 2.0 + 0.4)
rb = arrive("bar", 3.0)
foot = (BAR[0] + BAR[2] / 2, BAR[1] + BAR[3])
last = rb[-1]
lines.append("  bar    centre at the end (%.1f, %.1f), the bar's foot (%.1f, %.1f)" % (last["cx"], last["cy"], foot[0], foot[1]))
if abs(last["cx"] - foot[0]) > 0.5 or abs(last["cy"] - foot[1]) > 0.5:
    bad.append("arrive: the bar alone does not centre the rings on its foot (%.0f, %.0f)" % (last["cx"], last["cy"]))

# ---- there -------------------------------------------------------------------------------------------------------------
for x in by["there"]:
    if x["live"] and (abs(x["cx"] - x["live"][0]) > 1e-6 or abs(x["hub"] - x["live"][2]) > 1e-6 or abs(x["tick"] - x["live"][2]) > 1e-6
                      or (x["recut"] and x["recut"][3] < 1e5)):
        bad.append("there: a popup there from the start is eased or re-cut at %.2f s" % x["t"])

# ---- recut: each ring's tick count, measured --------------------------------------------------------------------------
def ring_reading(L, r, k):
    p = r["pitch"] * r["unit"]; gw = 0.5 * r["groove"] * r["unit"]
    band = p - 2 * gw * 0.9; ml = band * r["minor"]
    typ = k % 3
    rem = (p - gw * 0.9 - 0.5 * ml) if typ == 0 else (gw * 0.9 + 0.5 * ml if typ == 1 else 0.5 * p)
    rad = (r["hub"] + k * p + rem) / 2.0                   # half-size frames
    cx, cy = r["cx"] / 2.0, r["cy"] / 2.0
    n = int(2 * math.pi * rad)
    th = np.linspace(0, 2 * math.pi, n, endpoint=False)
    xs, ys = cx + rad * np.cos(th), cy + rad * np.sin(th)
    H, W = L.shape
    ok = (xs > 2) & (xs < W - 3) & (ys > 2) & (ys < H - 3)
    if ok.sum() < 400:                                     # too short an arc to tell one count from the next
        return None
    th, xs, ys = th[ok], xs[ok], ys[ok]
    s = ndimage.map_coordinates(L, [ys, xs], order=1)
    s = s - ndimage.gaussian_filter1d(s, 25)
    expect = 2 * math.pi * rad * 2 / (r["tickPitch"] * r["unit"])
    cands = np.arange(50, 50 * max(4, int(expect * 3 / 50) + 2) + 1, 50)
    cands = cands[cands * len(th) / (2 * math.pi * rad) >= 6]  # at least six periods along the arc on screen
    amp = np.abs(np.exp(-1j * np.outer(cands, th)) @ s) / len(s)
    top = amp.max()
    N = int(cands[np.argmax(amp >= 0.6 * top)])          # the fundamental: harmonics of the tick train come above it
    return N, float(amp[cands == N][0])
def film(tag, nframes):
    fr = sorted([x for x in recs if x["tag"].startswith("film/" + tag + "_")], key=lambda x: x["t"])
    seq = []
    for x in fr:
        L = lum(np.asarray(Image.open(os.path.join(out, x["tag"] + ".jpg")).convert("RGB")).astype(np.float64))
        K = int((max(SW, SH) * 1.3 - x["hub"]) / (x["pitch"] * x["unit"])) + 1
        seq.append((x, [ring_reading(L, x, k) for k in range(K)]))
    K = max(len(v) for _, v in seq)
    pops, ghosts = [], 0
    for k in range(K):
        rest = [v[k][1] for _, v in seq[-12:] if k < len(v) and v[k]]
        if not rest:
            continue
        ref = float(np.median(rest))
        for (xa, va), (xb, vb) in zip(seq, seq[1:]):
            a = va[k] if k < len(va) else None
            b = vb[k] if k < len(vb) else None
            if a and b and a[0] != b[0] and min(a[1], b[1]) >= 0.35 * ref:
                pops.append((xb["t"], k, a[0], b[0], min(a[1], b[1]) / ref))
    lines.append("  %-6s film %d frames: %d ring re-tick(s) in view" % (tag, len(seq), len(pops))
                 + ("".join("\n           %.3f s ring %d %d -> %d ticks at %.0f %% strength" % (p[:4] + (100 * p[4],)) for p in pops[:6])))
    if pops:
        bad.append("recut: %s re-ticks %d ring(s) in view (first at %.3f s, ring %d: %d -> %d ticks)" % ((tag, len(pops)) + pops[0][:4]))
    return seq
sb = film("boot", 0)
film("reg", 0)
# the arrival ends as a dial that had its popup from the start: the same counts, ring by ring
there = [x for x in recs if x["tag"] == "film/there_end"]
if there:
    L = lum(np.asarray(Image.open(os.path.join(out, "film/there_end.jpg")).convert("RGB")).astype(np.float64))
    endx, endv = sb[-1]
    if abs(endx["hub"] - there[0]["hub"]) > 0.01 or abs(endx["cy"] - there[0]["cy"]) > 0.01:
        bad.append("recut: the boot's dial ends at hub %.1f, the popup's is %.1f" % (endx["hub"], there[0]["hub"]))
    else:
        tv = [ring_reading(L, there[0], k) for k in range(len(endv))]
        diff = [k for k in range(len(endv)) if endv[k] and tv[k] and endv[k][0] != tv[k][0]]
        lines.append("  end    rings counted differently from a popup there from the start: %s" % (diff or "none"))
        if diff:
            bad.append("recut: after the arrival ring(s) %s keep another count than a dial whose popup was there from the start" % diff)
print("\n".join(lines))
print("DIALS_SHELL_PROBE RESULT " + ("PASS" if not bad else "FAIL (" + "; ".join(bad[:6]) + (" ..." if len(bad) > 6 else "") + ")"))
sys.exit(0 if not bad else 1)
PY
