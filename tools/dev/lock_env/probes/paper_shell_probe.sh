#!/usr/bin/env bash
# paper_shell_probe.sh -- the PAPER veil and the shell's silhouette (feedback: the "T" at boot), offscreen, from a copy of a
# tree: the frames the user filmed at a boot -- the veil alone, then the shell's bar, then its popup opening out of the bar
# -- and a regular lock with the bar there from the start, rendered by paper_shell.qml on a held clock, each frame twice
# (the second with the veil's stoneShadow at 0, so the two differ by the shell's shadow alone).
#
#   tools/dev/lock_env/probes/paper_shell_probe.sh [OUTDIR]          this tree
#   TREE=<dir> tools/dev/lock_env/probes/paper_shell_probe.sh ...    another tree's veil (an old revision: the ARM)
#
# Checks (each frame at 2880 x 1620; the island 720 x 40 at the top centre, the popup 440 x 560 out of its foot):
#   noshell   with no rect from the shell (a boot before the shell has started) no frame holds a shadow of a shell, and
#             at every presence of the rise the floor is whole (no black)            -- the old veil: the T (a guessed
#             560 x 660 stone and a 1600 px bar) as the bed's origin and as a shadow on the top sheet
#   arrive    when the bar's rect comes, its shadow comes in on one clock, never falling back, nothing at its first frame and
#             whole by attachSeconds (0.6 veil s)
#   attached  every pixel the shadow darkens lies within the shadow's reach of the boxes the shell has at THAT frame (the bar
#             alone before the popup, then the bar and the popup as it opens): no shadow of a popup that is not there, never
#             one detached from the bar
#   there     a regular lock whose bar is there from the veil's first moments casts its whole shadow at once
# Ends in PAPER_SHELL_PROBE RESULT PASS|FAIL (what failed).
# ARM: TREE=<a copy of 14c91971> (the veil before this round) fails noshell and attached.
set -u
HERE="$(cd "$(dirname "$0")/../../../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
TREE="$(realpath "${TREE:-$HERE}")"
OUT="${1:-${SCRATCH:-/tmp}/paper_shell}"
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
W=$(mktemp -d /tmp/lrps.XXXXXX) || exit 1
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/t/h" "$W/rt" "$W/cfg/theme" "$W/state" "$W/cache"
chmod 700 "$W/rt"
rsync -a --exclude '.qmlls.ini' "$TREE/modules" "$TREE/themes" "$W/t/" || { echo "PAPER_SHELL_PROBE RESULT FAIL (copy)"; exit 1; }
FIX="$TREE/mockups/fixtures/lockscreen/desktop_light_blur.png"
[ -f "$FIX" ] || FIX="$TREE/tests/fixtures/lockscreen/desktop_light_blur.png"
cp "$HERE/tools/dev/lock_env/probes/paper_shell.qml" "$W/t/h/shell.qml"
ln -s ../modules "$W/t/h/modules"
printf '{"theme":"eva","mode":"light"}\n' > "$W/cfg/theme/state.json"

python3 - "$W/jobs.json" <<'PY'
import json, sys
BAR = [1080, 8, 720, 40]
def popup(t, at=3.4, ms=400.0, h=560):
    x = max(0.0, min(1.0, (t - at) * 1000 / ms)); u = x - 1; s = 1.2
    e = u * u * ((s + 1) * u + s) + 1                   # the engine's open: OutBack, overshoot 1.2
    return [1220, 48, 440, max(0.0, round(h * e, 2))]
jobs = []
def pair(name, **j):
    jobs.append(dict(name=name, **j)); jobs.append(dict(name=name + "_ns", noShadow=True, **j))
for p in (0.05, 0.3, 0.7, 1.0):                        # the veil alone, rising (boot)
    pair("pre_p%03d" % round(p * 100), t=1.0, presence=p, steps=[])
for t in (3.0, 3.15, 3.3, 3.45, 3.6, 4.0):             # the bar arrives at 3.0
    pair("bar_t%03d" % round(t * 100), t=t, steps=[{"t": 3.0, "bar": BAR}])
for t in (3.45, 3.5, 3.6, 3.8, 4.0, 5.0):              # the popup opens out of it at 3.4
    pair("pop_t%03d" % round(t * 100), t=t, steps=[{"t": 3.0, "bar": BAR}, {"t": 3.4, "popup": popup(3.4)}, {"t": t, "popup": popup(t)}])
for t in (0.1, 0.5):                                   # a regular lock: the bar there from the start
    pair("reg_t%03d" % round(t * 100), t=t, boot=False, steps=[{"t": 0, "bar": BAR}])
for t in (0.85, 0.9, 1.0, 1.2):                        # ...and its popup opening at 0.8
    pair("regpop_t%03d" % round(t * 100), t=t, boot=False, steps=[{"t": 0, "bar": BAR}, {"t": 0.8, "popup": popup(0.8, 0.8)}, {"t": t, "popup": popup(t, 0.8)}])
json.dump({"jobs": jobs, "bar": BAR}, open(sys.argv[1], "w"))
PY
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); json.dump(d['jobs'], open(sys.argv[2],'w'))" "$W/jobs.json" "$W/jobs.list.json"

LOG="$OUT/render.log"
(cd "$W/t/h" && env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE XDG_RUNTIME_DIR="$W/rt" XDG_CONFIG_HOME="$W/cfg" XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QS_DISABLE_CRASH_HANDLER=1 \
    JOBS="$W/jobs.list.json" OUT="$OUT" FIXTURE="$FIX" \
    timeout -k 5 300 quickshell -n -p "$W/t/h/shell.qml" > "$LOG" 2>&1)
r=$(rl_clean "$LOG" | grep -ao "PAPER_SHELL RESULT.*" | tail -1)
[ -n "$r" ] || { rl_noresult PAPER_SHELL_PROBE "$LOG"; exit 1; }
case "$r" in *PASS*) ;; *) echo "PAPER_SHELL_PROBE RESULT FAIL (render: $r)"; exit 1 ;; esac
rl_clean "$LOG" | grep -a "Binding loop\|Cannot assign\|Unable to assign\|ReferenceError\|TypeError" | head -5

python3 - "$OUT" "$W/jobs.json" <<'PY'
import json, math, os, sys
import numpy as np
from PIL import Image
out, spec = sys.argv[1], json.load(open(sys.argv[2]))
BAR = spec["bar"]
REACH = 190          # the shell's shadow reaches no farther (VeilPaper/veil_paper.frag: shReach at the defaults, 1620 high)
def load(n):
    a = np.asarray(Image.open(os.path.join(out, n + ".png")).convert("RGB")).astype(np.float64)
    return a
def lum(a):
    return a @ np.array([0.2126, 0.7152, 0.0722])
jobs = {j["name"]: j for j in spec["jobs"]}
def shell_at(name):
    j = jobs[name]; bar = None; pop = None
    for s in j["steps"]:
        if "bar" in s: bar = s["bar"]
        if "popup" in s: pop = s["popup"]
    return bar, pop
def dist_map(shape, boxes):
    H, W = shape
    ys, xs = np.mgrid[0:H, 0:W] + 0.5
    d = np.full(shape, 1e9)
    for b in boxes:
        if not b or b[2] <= 0 or b[3] <= 0:
            continue
        dx = np.maximum(np.maximum(b[0] - xs, 0), xs - b[0] - b[2])
        dy = np.maximum(np.maximum(b[1] - ys, 0), ys - b[1] - b[3])
        d = np.minimum(d, np.hypot(dx, dy))
    return d
bad, lines = [], []
def drop(name):
    a, b = load(name), load(name + "_ns")
    return lum(b) - lum(a), a           # > 0 where the shell's shadow darkens the frame
# noshell
for n in sorted(k for k in jobs if k.startswith("pre_") and not k.endswith("_ns")):
    d, a = drop(n)
    blk = (a.max(axis=2) < 14).mean()
    lines.append("  %-14s shadow px %6d  max %.1f  black %.3f %%" % (n, (np.abs(d) > 1).sum(), np.abs(d).max(), 100 * blk))
    if (np.abs(d) > 1).sum() > 0:
        bad.append("noshell: %s holds a shadow of a shell that is not there (%d px, max %.0f levels)" % (n, (np.abs(d) > 1).sum(), np.abs(d).max()))
    if blk > 0.0005:
        bad.append("noshell: %s's floor is not whole (%.2f %% black)" % (n, 100 * blk))
# attached (+ the strengths for arrive / there)
S = {}
for n in sorted(k for k in jobs if not k.endswith("_ns") and not k.startswith("pre_")):
    d, a = drop(n)
    bar, pop = shell_at(n)
    dm = dist_map(d.shape, [bar, pop])
    S[n] = float(np.clip(d, 0, None).sum())
    far = (d > 3) & (dm > REACH)
    lines.append("  %-14s shadow %10.0f  px darker > 3 beyond the reach of the live boxes: %d" % (n, S[n], far.sum()))
    if far.sum() > 0:
        ys, xs = np.nonzero(far)
        bad.append("attached: %s darkens %d px farther than %d px from the shell it has (bbox x %d..%d y %d..%d)"
                   % (n, far.sum(), REACH, xs.min(), xs.max(), ys.min(), ys.max()))
# arrive
seq = [S["bar_t%03d" % k] for k in (300, 315, 330, 345, 360, 400)]
full = seq[-1]
lines.append("  arrive: " + " ".join("%.3f" % (v / full if full else 0) for v in seq) + " of the whole shadow at 3.00 3.15 3.30 3.45 3.60 4.00")
if full <= 0:
    bad.append("arrive: the bar casts no shadow at all")
else:
    if seq[0] > 0.02 * full:
        bad.append("arrive: %.0f %% of the shadow already in the bar's first frame (it pops in)" % (100 * seq[0] / full))
    if any(b < a - 0.01 * full for a, b in zip(seq, seq[1:])):
        bad.append("arrive: the shadow falls back while it comes in")
    if seq[4] < 0.97 * full:
        bad.append("arrive: only %.0f %% of the shadow by attachSeconds" % (100 * seq[4] / full))
# there
if S["reg_t050"] > 0 and S["reg_t010"] < 0.97 * S["reg_t050"]:
    bad.append("there: a bar there from the start casts %.0f %% of its shadow at 0.1 s (it fades in)" % (100 * S["reg_t010"] / S["reg_t050"]))
print("\n".join(lines))
print("PAPER_SHELL_PROBE RESULT " + ("PASS" if not bad else "FAIL (" + "; ".join(bad[:6]) + (" ..." if len(bad) > 6 else "") + ")"))
sys.exit(0 if not bad else 1)
PY
