#!/usr/bin/env bash
# A toast's countdown drain (tools/dev/qml/toast_drain_probe.qml): the size of every step in device px against the distance the shade's
# boundary really travels, and the frames a count costs. Sandbox, offscreen.
#
#   tools/dev/toast_drain_probe.sh [outdir]        MODE=steps (default) | truth | count      SCALE (default 1.25)  TOTAL_MS  TOASTS
#   BEFORE=<rev>   run the same harness on that revision's tree (git archive) instead: the old drain, for a back-to-back comparison
#   ARM=step4      drainStepPx back to 4: the steps are not 1 px, the probe must fail
#   ARM=oldsweep   the step counted against the card's width alone (the old distance): the steps are not whole px, the probe must fail
# Last line: TOAST_DRAIN RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/toast_drain}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/toast_drain_probe.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
MODE="${MODE:-steps}"
GITDIR="${MOCKUP_REPO:-$HERE}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/toastdrain.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/cfg/theme" "$WORK/state"
printf '{"theme":"eva","mode":"light"}\n' > "$WORK/cfg/theme/state.json"
TREE="$HERE"
if [ -n "${BEFORE:-}" ]; then
    mkdir -p "$WORK/tree"
    git -C "$GITDIR" archive "$BEFORE" | tar -x -C "$WORK/tree" || { echo "TOAST_DRAIN RESULT FAIL (no tree for $BEFORE)"; exit 1; }
    cp tools/dev/qml/toast_drain_probe.qml "$WORK/tree/tools/dev/qml/"
    TREE="$WORK/tree"
fi

arm_patch() {    # <py> : run a patch against $TREE
    (cd "$TREE" && python3 - "$@") || { echo "TOAST_DRAIN RESULT FAIL (ARM ${ARM}: anchor gone)"; exit 1; }
}
case "${ARM:-}" in
step4)
    arm_patch <<'PY'
p = "modules/notifications/parts/NotificationStyle.qml"
s = open(p).read()
a = "property real drainStepPx: 1"
assert a in s
open(p, "w").write(s.replace(a, "property real drainStepPx: 4"))
PY
    ;;
oldsweep)
    arm_patch <<'PY'
p = "modules/notifications/toast/ToastEntry.qml"
s = open(p).read()
a = "(entry.width + 2 * entry._featherPx) * (entry.style ? entry.style.renderScale : 1)"
assert a in s
open(p, "w").write(s.replace(a, "entry.width * (entry.style ? entry.style.renderScale : 1)"))
PY
    ;;
esac

log="$OUT/${MODE}.log"
if [ "$MODE" = count ]; then
    # the process's CPU (utime + stime, ticks) across the counted window: the probe prints countstart and the count line
    cd "$TREE" || exit 1
    XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" OUT_DIR="$OUT" MODE="$MODE" TOTAL_MS="${TOTAL_MS:-30000}" \
        quickshell -p tools/dev/qml/toast_drain_probe.qml > "$log" 2>&1 &
    qpid=$!
    ( sleep 90; kill "$qpid" 2> /dev/null ) &
    wd=$!
    ticks() { awk '{print $14 + $15}' "/proc/$qpid/stat" 2> /dev/null; }
    t0=""; t1=""
    for _ in $(seq 1 900); do
        kill -0 "$qpid" 2> /dev/null || break
        if [ -z "$t0" ] && grep -aq "DRAIN countstart" "$log"; then t0=$(ticks); fi
        if [ -z "$t1" ] && grep -aq "DRAIN count toasts" "$log"; then t1=$(ticks); break; fi
        sleep 0.1
    done
    wait "$qpid" 2> /dev/null
    kill "$wd" 2> /dev/null
    cd "$HERE" || exit 1
    secs=$(rl_clean "$log" | grep -a -o "seconds=[0-9.]*" | tail -1 | cut -d= -f2)
    if [ -n "$t0" ] && [ -n "$t1" ] && [ -n "$secs" ]; then
        awk -v a="$t0" -v b="$t1" -v s="$secs" 'BEGIN { printf "DRAIN cpu %.1f %% of a core over %.2f s (%d ticks)\n", (b - a) / 100 / s * 100, s, b - a }'
    fi
else
(cd "$TREE" && XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" OUT_DIR="$OUT" MODE="$MODE" \
    timeout -k 5 150 quickshell -p tools/dev/qml/toast_drain_probe.qml > "$log" 2>&1)
fi
rl_clean "$log" | grep -a "DRAIN" | grep -v RESULT | sed 's/^ *DEBUG qml: //'
# a run that did not load has no DRAIN RESULT line: the runner's own no-result verdict (tools/dev/result_lib.sh)
if ! rl_has "$log" 'DRAIN RESULT'; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult TOAST_DRAIN "$log"; exit 1
fi
res=$(rl_result DRAIN "$log"); rc=$?
rl_clean "$log" | grep -a -E "WARN|ERROR" | rl_platform_noise | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" | sort -u | head -5
if [ "$MODE" = truth ]; then
    python3 -B -W ignore - "$OUT" "${SCALE:-1.25}" "$rc" <<'PY'
import glob, sys
from PIL import Image
out, zoom, rc = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
W, F = 360, 12.0
plan = [0.2, 0.35, 0.5, 0.65, 0.8]
bad = 0
for i, p in enumerate(plan):
    im = Image.open("%s/truth_%d.png" % (out, i)).convert("RGB")
    px = im.load()
    h = im.size[1]
    # a row a little inside the top edge (the shade lives in the carve), across the straight part of the card
    y = int(round(2.2 * zoom))
    x0, x1 = int(24 * zoom), int((W - 24) * zoom)
    vals = [px[x, y][2] - px[x, y][0] for x in range(x0, x1)]   # blue minus red: the tint (accent) against the grey carve
    hi, lo = sorted(vals)[-8:], sorted(vals)[:8]
    top, bot = sum(hi) / len(hi), sum(lo) / len(lo)
    mid = (top + bot) / 2
    xb = None
    for k in range(len(vals) - 1):
        if vals[k] >= mid > vals[k + 1]:
            xb = x0 + k + (vals[k] - mid) / max(1e-6, vals[k] - vals[k + 1])
            break
    expect = (-F + p * (W + 2 * F)) * zoom
    off = (xb - expect) if xb is not None else None
    print("DRAIN truth p=%.2f boundary %s expect %.1f off %s" % (p, "%.1f" % xb if xb is not None else "none", expect, "%.2f" % off if off is not None else "?"))
    if off is None or abs(off) > 1.5 * zoom:
        bad = 1
print("TOAST_DRAIN RESULT " + ("PASS" if not bad and rc == 0 else "FAIL"))
sys.exit(bad or rc)
PY
    exit $?
fi
echo "${res:-no result}" | sed 's/^/DRAIN: /'
if [ $rc -eq 0 ]; then echo "TOAST_DRAIN RESULT PASS"; else echo "TOAST_DRAIN RESULT FAIL"; exit 1; fi
