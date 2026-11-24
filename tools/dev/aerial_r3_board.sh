#!/usr/bin/env bash
# aerial_r3_board.sh -- the board alone, rendered offscreen in a sandbox copy (round 3's look at the parts; not a gate).
#   tools/dev/aerial_r3_board.sh <outdir>      SCENS="home" FAMILIES="0 1" MODES="light dark" SCALES="1" AIR= AIRT= ASK=
# Writes <outdir>/<scen>_f<family>_<mode>_s<scale>[_air].png; ends in AERIAL_R3_BOARD RESULT PASS|FAIL (a picture per cell, a clean log).
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${1:?outdir}
if [ -e .git ] && [ -z "${ARB_INNER:-}" ]; then
    mkdir -p "$OUT"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-r3}" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARB_INNER=1 SCENS="${SCENS:-}" FAMILIES="${FAMILIES:-}" MODES="${MODES:-}" \
        SCALES="${SCALES:-}" AIR="${AIR:-}" AIRT="${AIRT:-}" ASK="${ASK:-}" bash tools/dev/aerial_r3_board.sh "$@"
fi
mkdir -p "$OUT/cache" "$OUT/state"; bad=0
for mode in ${MODES:-light dark}; do
    cfg="$OUT/cfg-$mode"; mkdir -p "$cfg/theme"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
    for fam in ${FAMILIES:-0 1}; do for sc in ${SCENS:-home}; do for k in ${SCALES:-1}; do
        png="$OUT/${sc}_f${fam}_${mode}_s${k}${AIR:+_air}${AIRT:+_t$AIRT}.png"; rm -f "$png"
        env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
            SCEN="$sc" FAMILY="$fam" SCALE="$k" AIR="${AIR:-}" AIRT="${AIRT:-}" ASK="${ASK:-}" PNG="$png" timeout 90 quickshell -n -p tools/dev/qml/aerial_r3_board.qml > "${png%.png}.log" 2>&1
        [ -s "$png" ] || { echo "no picture: $png"; bad=1; }
        grep -E 'WARN|ERROR|rror:|Cannot|Unable|binding loop' "${png%.png}.log" | grep -v 'qt.qpa\|Could not attach' | head -5 | sed 's/^/  log: /'
    done; done; done
done
[ $bad = 0 ] && { echo "AERIAL_R3_BOARD RESULT PASS (pictures in $OUT)"; exit 0; }
echo "AERIAL_R3_BOARD RESULT FAIL"; exit 1
