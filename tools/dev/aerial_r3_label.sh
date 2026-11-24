#!/usr/bin/env bash
# aerial_r3_label.sh -- round 3's label for the eye: the label alone (flat), the wipe's filmstrip, and the board scene on the mock's facts.
#   tools/dev/aerial_r3_label.sh <outdir>      WHAT="flat film scene"  MODES="light dark"  SCENS="home vpn earbuds"  SCALES="1 1.35"  FAMILIES="0 1"
# Writes <outdir>/flat_<mode>.png, film_<mode>.png, scene_<scen>_<family>_<scale>_<mode>.png. OFFSCREEN ONLY, in a sandbox copy; ends in AERIAL_R3_LABEL RESULT PASS|FAIL
# (a picture missing or a log that warns is a FAIL: it is a sheet, but a sheet of a QML that did not load is no sheet).
#   WHAT=probe   the label's own laws (tools/dev/qml/aerial_r3_label_probe.qml): rows by count, a row's identity through a reorganisation, the leaver's fade, the drag's
#                answers, the name's cut, the wipe's clock. Its verdict is the probe's AERIAL_R3_LABEL_PROBE RESULT line.
#   ARM=noident  (rows are rebuilt at every change, never moved)   ARM=nocarry (a carried row stays drawn)   ARM=jumpwipe (the chrome snaps): each must FAIL, by its own check.
#   An arm patches the SANDBOX COPY it runs in (never this tree); an anchor that is gone fails the run.
{
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
OUT=${1:?outdir}
mkdir -p "$OUT/cache" "$OUT/state"
if [ -e .git ] && [ -z "${ARL_INNER:-}" ]; then
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-r3-label}" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARL_INNER=1 ARM="${ARM:-}" WHAT="${WHAT:-}" MODES="${MODES:-}" SCENS="${SCENS:-}" \
        SCALES="${SCALES:-}" FAMILIES="${FAMILIES:-}" bash tools/dev/aerial_r3_label.sh "$@"
fi
bad=0
arm() {     # arm <file> <exact old> <new>: patch the copy, fail when the anchor is gone
    python3 -B - "$1" "$2" "$3" <<'PY' || { echo "AERIAL_R3_LABEL RESULT FAIL (arm ${ARM}: its anchor is gone)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
}
if [ -n "${ARM:-}" ]; then
    [ -e .git ] && { echo "AERIAL_R3_LABEL RESULT FAIL (an arm never patches the tree)"; exit 1; }
    L=modules/aerial/scene/AerialLabel.qml
    case "$ARM" in
        noident) arm $L 'if (w && !used[r.key]) {' 'if (false) {' ;;
        nocarry) arm $L 'opacity: row.key === root.carriedBt && row.key !== "" ? 0 : row.pres' 'opacity: row.pres' ;;
        jumpwipe) arm $L 'if (!root.animate || !root._built) {
            chromeAnim.stop();' 'if (true) {
            chromeAnim.stop();' ;;
        *) echo "AERIAL_R3_LABEL RESULT FAIL (no arm $ARM)"; exit 1 ;;
    esac
fi
shot() {    # shot <png> <log> NAME=VALUE...
    local png=$1 log=$2; shift 2
    rm -f "$png"
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" PNG="$png" "$@" \
        timeout 90 quickshell -n -p tools/dev/qml/aerial_r3_label.qml > "$log" 2>&1
    [ -s "$png" ] || { echo "no picture: $png (log $log)"; bad=1; }
    if grep -E 'WARN|ERROR|Cannot assign|Unable to assign|Binding loop|is not a type|ReferenceError|TypeError' "$log" | grep -v 'qt.qpa\|Failed to initialize graphics' | head -5 | grep . ; then
        echo "the log warns: $log"; bad=1
    fi
}
for mode in ${MODES:-light dark}; do
    cfg="$OUT/cfg-$mode"; mkdir -p "$cfg/theme"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
    for what in ${WHAT:-flat film scene}; do
        if [ "$what" = probe ]; then
            [ "$mode" = "$(set -- ${MODES:-light dark}; echo "$1")" ] || continue        # once, in the first mode
            log="$OUT/probe.log"
            env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
                timeout 120 quickshell -n -p tools/dev/qml/aerial_r3_label_probe.qml > "$log" 2>&1
            grep -o 'LABELPROBE FAIL.*' "$log"
            res=$(grep -o 'AERIAL_R3_LABEL_PROBE RESULT.*' "$log" | tail -1)
            case "$res" in *PASS*) ;; "") echo "no result: $log"; bad=1 ;; *) echo "$res"; bad=1 ;; esac
            if grep -E 'WARN|ERROR|Cannot assign|Unable to assign|Binding loop|is not a type|ReferenceError|TypeError' "$log" | grep -v 'qt.qpa\|Failed to initialize graphics' | head -5 | grep . ; then
                echo "the log warns: $log"; bad=1
            fi
        elif [ "$what" = scene ]; then
            for sc in ${SCENS:-home vpn earbuds}; do for fam in ${FAMILIES:-0 1}; do for scale in ${SCALES:-1 1.35}; do
                shot "$OUT/scene_${sc}_${fam}_${scale}_${mode}.png" "$OUT/scene_${sc}_${fam}_${scale}_${mode}.log" MODE=scene SCEN="$sc" FAMILY="$fam" SCALE="$scale"
            done; done; done
        else
            shot "$OUT/${what}_${mode}.png" "$OUT/${what}_${mode}.log" MODE="$what"
        fi
    done
done
[ $bad = 0 ] && { echo "AERIAL_R3_LABEL RESULT PASS (pictures in $OUT)"; exit 0; }
echo "AERIAL_R3_LABEL RESULT FAIL"; exit 1
}
