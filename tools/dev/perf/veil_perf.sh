#!/usr/bin/env bash
# veil_perf.sh -- what one frame of each lock veil costs: the GPU's time per frame, the render thread's and the GUI thread's
# per frame, the GUI thread's share of a tick (the bindings a seek re-runs), and the time from a veil's load to its first
# frame, as a client of tools/dev/lock_env.sh's nested Hyprland (vsync-paced, the lock's own GL path: NVIDIA's GLES on the
# desktop, Mesa's GL elsewhere), from a private copy of a tree (tools/dev/qml/veil_perf.qml has the phases).
#
#   tools/dev/perf/veil_perf.sh OUTDIR [--tree DIR] [--ab DIR] [--mode light|dark]
#   --ab DIR   B beside A in ONE process: DIR's veils and veil shaders become modules/lockscreen/veil_b + shaders_b of the copy,
#              and a VEILS name "b:<veil>" draws that veil from B (the reader pairs A and B round by round). Two runs of two trees
#              do not compare here: the driver moves the GPU's clock 524-1837 MHz between them with other sessions' load.
#   RES="3440x1440 2880x1620" (the desktop, the laptop's panel)   VEILS=none,relief,...   ROUNDS=3   PHASE_MS=4000   FPS=60
#   BOOT=1 (opaque, no still)   POPUP=0   PULSES=1 (typing)   GUI_N=400   STILL_MS=3000 (frames at rest, must be 0)
#   ENVX="NAME=VALUE ..." extra environment for the quickshell (an ablation's switch)   LOCK_ENV=pfv1 (kept up if it was up)
#   REFRESH=120 (LOCK-1's)
#
# THE GPU's TIME is tools/dev/perf/veil_gputime.c (an LD_PRELOAD: a GL_TIME_ELAPSED query from a frame's first clear or draw
# to its swap). Qt's own `GPU frame time` reads nothing here (QSG_RHI_PROFILE=1: the offscreen context reports GL 2.0, NVIDIA's
# Wayland context is GLES 3.2, and Qt takes timestamps on neither), and a frame's own timing reads 0 offscreen.
#
# --tree measures ANOTHER tree's veils (a copy with one term turned off, an old revision) with THIS tree's harness and reader,
# so A and B are the same phases. Two trees are compared by running this alternately (A B A B), never at once: two frame-time
# runs at once measure neither. Every run starts with an empty shader cache (a private cache home): round 0's `first` is the
# cold compile, later rounds are warm in the process.
#
# Prints per resolution one line per veil: the median of its frames' GPU time with the spread of the per-round medians, the
# veil's own share (less the floor "none"), the render thread's frame, the GUI thread's prepare, the binding share of a tick
# and the first frame (cold, warm). Raw: OUTDIR/<res>-<mode>.{log,gpu.tsv}. Ends in VEIL_PERF RESULT PASS|FAIL: PASS says
# every phase ran and frames were read, not that anything is fast.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
OUT="" TREE="$HERE" MODE=light AB=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tree) TREE="$(realpath "$2")"; shift 2 ;;
        --ab) AB="$(realpath "$2")"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *) OUT="$1"; shift ;;
    esac
done
[ -n "$OUT" ] || { sed -n '2,24p' "$0"; exit 2; }
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
export LOCK_ENV="${LOCK_ENV:-pfv1}"
case "$LOCK_ENV" in pfv*) ;; *) echo "VEIL_PERF RESULT FAIL (LOCK_ENV must start with pfv)"; exit 1 ;; esac
E="$HERE/tools/dev/lock_env.sh"
W=$(mktemp -d /tmp/lrvp.XXXXXX) || exit 1
QPID="" started=0
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    [ "$started" = 1 ] && [ -z "${KEEP_ENV:-}" ] && "$E" down > /dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
mkdir -p "$W/t/tools/dev/qml" "$W/t/mockups" "$W/cfg/theme"
rsync -a --exclude '.qmlls.ini' "$TREE/modules" "$TREE/themes" "$W/t/" || { echo "VEIL_PERF RESULT FAIL (copy)"; exit 1; }
rsync -a "$TREE/mockups/fixtures" "$W/t/mockups/" 2> /dev/null
cp "$HERE/tools/dev/qml/veil_perf.qml" "$W/t/tools/dev/qml/"
ln -s ../../../modules "$W/t/tools/dev/qml/modules"
if [ -n "$AB" ]; then
    rsync -a "$AB/modules/lockscreen/veil/" "$W/t/modules/lockscreen/veil_b/" && rsync -a "$AB/modules/lockscreen/shaders/" "$W/t/modules/lockscreen/shaders_b/" \
        || { echo "VEIL_PERF RESULT FAIL (copy of B)"; exit 1; }
    sed -i 's|"\.\./shaders/|"../shaders_b/|g' "$W/t/modules/lockscreen/veil_b/"*.qml
    grep -q '"\.\./shaders/' "$W/t/modules/lockscreen/veil_b/"*.qml && { echo "VEIL_PERF RESULT FAIL (B still names A's shaders)"; exit 1; }
    # B's stage, loaded by URL from the harness: a file of the scanned root that imports veil_b, so its types resolve
    printf 'import "modules/lockscreen/veil_b"\nVeilStage {}\n' > "$W/t/tools/dev/qml/VeilPerfB.qml"
fi
printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$W/cfg/theme/state.json"
cc -O2 -shared -fPIC -o "$W/veil_gputime.so" "$HERE/tools/dev/perf/veil_gputime.c" -ldl || { echo "VEIL_PERF RESULT FAIL (cc veil_gputime.c)"; exit 1; }
if ! "$E" status 2> /dev/null | grep -q " up:"; then
    LOCK_REFRESH="${REFRESH:-120}" "$E" up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "VEIL_PERF RESULT FAIL (lock_env up)"; exit 1; }
    started=1
fi
rc=0
for res in ${RES:-3440x1440 2880x1620}; do
    "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", mode = "'"$res"'@'"${REFRESH:-120}"'", position = "0x0", scale = 1 })' > /dev/null
    sleep 1
    got=$("$E" hyprctl -j monitors | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["name"]=="LOCK-1"][0]; print("%dx%d" % (m["width"], m["height"]))')
    [ "$got" = "$res" ] || { echo "VEIL_PERF RESULT FAIL (LOCK-1 is $got, not $res)"; exit 1; }
    LOG="$OUT/$res-$MODE.log" GPU="$OUT/$res-$MODE.gpu.tsv"
    rm -rf "$W/cache"; mkdir -p "$W/cache" "$W/state"
    rm -f "$GPU"
    # shellcheck disable=SC2086
    "$E" run env XDG_CONFIG_HOME="$W/cfg" XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache" QS_DISABLE_CRASH_HANDLER=1 \
        QSG_RENDER_TIMING=1 VEIL_HOUR="${VEIL_HOUR:-10.5}" LD_PRELOAD="$W/veil_gputime.so" VEIL_GPUTIME_OUT="$GPU" \
        VEILS="${VEILS:-none,relief,gooey,dimples,paper,louvres,keycaps,dials}" ROUNDS="${ROUNDS:-3}" PHASE_MS="${PHASE_MS:-4000}" \
        WARM_MS="${WARM_MS:-800}" FPS="${FPS:-60}" BOOT="${BOOT:-0}" POPUP="${POPUP:-1}" PULSES="${PULSES:-0}" GUI_N="${GUI_N:-400}" \
        STILL_MS="${STILL_MS:-0}" ${AB:+AB=1} ${ENVX:-} \
        timeout -k 5 "${VP_TMO:-900}" quickshell --log-times --log-rules "qt.scenegraph.time.renderloop.debug=true" \
        -n -p "$W/t/tools/dev/qml/veil_perf.qml" > "$LOG" 2>&1 &
    QPID=$!
    # the GPU's clock beside it (read-only): a frame's time follows the clock the driver picked, the cycles do not
    CLK="$OUT/$res-$MODE.clk.csv" SPID=""
    : > "$CLK"
    if command -v nvidia-smi > /dev/null 2>&1; then
        nvidia-smi --query-gpu=timestamp,clocks.gr,clocks.mem,utilization.gpu --format=csv,noheader -lms 100 > "$CLK" 2> /dev/null &
        SPID=$!
    fi
    wait "$QPID"
    QPID=""
    [ -n "$SPID" ] && { kill "$SPID" 2> /dev/null; wait "$SPID" 2> /dev/null; }
    grep -aq "VP done" "$LOG" || { rl_noresult VEIL_PERF "$LOG"; exit 1; }
    echo "== $res $MODE (tree $TREE)"
    python3 -B "$HERE/tools/dev/perf/veil_perf.py" "$LOG" "$GPU" --clock "$CLK" --json "$OUT/$res-$MODE.json" || rc=1
done
echo "VEIL_PERF RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit "$rc"
