#!/usr/bin/env bash
# bridge_body_sheet.sh -- the bridge's phone at a row of poses, as one PNG to look at (not a gate: it judges nothing).
#
#   tools/dev/bridge_body_sheet.sh [outdir]      offscreen, in a sandbox copy; prints the PNG's path
#   POSES="-1 0.1 0.25 0.4 0.5"  SKIN=generic  SCALE=1.25  MODE=dark  CELLS_BACK=1  BUSY=1  TILT=-90  NAME=<file stem>
#
# -1 is the body at rest (its cached layer); any other pose is that many turns, drawn live. Each face carries a
# text-heavy stand-in with a 1 px outline, so a face that does not sit on its glass shows.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BBS_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-body}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen BBS_INNER=1 BBS_OUTARG="${1:-}" bash tools/dev/bridge_body_sheet.sh "$@"
fi
OUT="${BBS_OUTARG:-${1:-${SCRATCH:-/tmp}/bridge-body}}"
mkdir -p "$OUT/cfg/theme" "$OUT/state" "$OUT/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$OUT/cfg/theme/state.json"
stem="${NAME:-sheet-${MODE:-light}-${SCALE:-1}}"
png="$OUT/$stem.png"
log="$OUT/$stem.log"
rm -f "$png"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
    XDG_CACHE_HOME="$OUT/cache" OUT="$png" POSES="${POSES:-}" SKIN="${SKIN:-}" SCALE="${SCALE:-1}" CELLS_BACK="${CELLS_BACK:-}" BUSY="${BUSY:-}" TILT="${TILT:-0}" \
    timeout 120 quickshell -n -p tools/dev/qml/bridge_body_sheet.qml > "$log" 2>&1 &
pid=$!
wait "$pid"
grep -a -E "BBS |WARN|ERROR|rror:|Failed|ShaderEffect" "$log" | head -20
[ -f "$png" ] && echo "PNG $png" || { echo "no picture: $log"; exit 1; }
