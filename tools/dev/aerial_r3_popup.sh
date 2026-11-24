#!/usr/bin/env bash
# aerial_r3_popup.sh -- the whole popup (the board, the label, the cloud, the globe) rendered offscreen in a sandbox copy: round 3's look (not a gate).
#   tools/dev/aerial_r3_popup.sh <outdir>      SCENS="home crowd" FAMILIES="0 1" MODES="light dark" SCALES="1" STATES="rest" PHASE= SWEEP= TILT= PTR=<x>,<y> TAG=<suffix>
# Writes <outdir>/<scen>_f<family>_<mode>_s<scale>_<state>.png (tools/dev/qml/aerial_r3_cloud.qml says what a STATE is); ends in AERIAL_R3_POPUP RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${1:?outdir}
if [ -e .git ] && [ -z "${ARP_INNER:-}" ]; then
    mkdir -p "$OUT"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-r3}" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARP_INNER=1 SCENS="${SCENS:-}" FAMILIES="${FAMILIES:-}" MODES="${MODES:-}" \
        SCALES="${SCALES:-}" STATES="${STATES:-}" PHASE="${PHASE:-}" SWEEP="${SWEEP:-}" TILT="${TILT:-}" PTR="${PTR:-}" TAG="${TAG:-}" bash tools/dev/aerial_r3_popup.sh "$@"
fi
mkdir -p "$OUT/cache" "$OUT/state"; bad=0
for mode in ${MODES:-light dark}; do
    cfg="$OUT/cfg-$mode"; mkdir -p "$cfg/theme"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
    for fam in ${FAMILIES:-0 1}; do for sc in ${SCENS:-home crowd}; do for k in ${SCALES:-1}; do for st in ${STATES:-rest}; do
        png="$OUT/${sc}_f${fam}_${mode}_s${k}_${st}${TAG:+_$TAG}.png"; rm -f "$png"
        env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
            SCEN="$sc" FAMILY="$fam" SCALE="$k" STATE="$st" PHASE="${PHASE:-}" SWEEP="${SWEEP:-}" TILT="${TILT:-}" PTR="${PTR:-}" PNG="$png" timeout 90 quickshell -n -p tools/dev/qml/aerial_r3_cloud.qml > "${png%.png}.log" 2>&1
        [ -s "$png" ] || { echo "no picture: $png"; bad=1; }
        grep -E 'WARN|ERROR|rror:|Cannot|Unable|binding loop' "${png%.png}.log" | grep -v 'qt.qpa\|Could not attach' | head -5 | sed 's/^/  log: /'
    done; done; done; done
done
[ $bad = 0 ] && { echo "AERIAL_R3_POPUP RESULT PASS (pictures in $OUT)"; exit 0; }
echo "AERIAL_R3_POPUP RESULT FAIL"; exit 1
