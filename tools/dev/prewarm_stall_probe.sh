#!/usr/bin/env bash
# prewarm_stall_probe.sh -- A POPUP USED DURING THE START-UP WARM-UP DOES NOT STOP IT, in tools/dev/lock_env.sh's nested Hyprland.
#
# The engine's warm-up (GooeyEngine.prewarm) builds an entry only at rest, and "at rest" counted ANY parked content as a click about to
# come. A recyclable content (weather, aerial, silicon, panorama, the clock) stays parked for good once its popup has closed (no timer
# retires it: THE PARKED CONTENT), so a popup opened and closed while the warm-up ran stopped it for ever, and `LARES settled` never
# came. A parked content now holds the warm-up only while it is FRESH (`parkLingerMs` after it was parked).
#
# The scene: the REAL shell.qml (mock services) in the env, the mock-only `hook toggle` (tools/dev/perf/frame_split_ablate.py) opening
# the weather popup as soon as the warm-up has started (`LARES prewarm start`) and closing it 1.5 s later. Checks:
#   used      the popup opened and closed while the warm-up ran (the scenario happened)
#   finish    `LARES prewarm end` and `LARES settled` follow within SETTLE_S (default 60) of the close
# One line per check, then PREWARM_STALL RESULT PASS|FAIL.
#
#   ARM=parked   the old rule (any parked content holds the warm-up)       finish: "never ended"
#   ARM=all      every arm above, each must fail on its needle: PREWARM_STALL ARMS RESULT PASS|FAIL
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "${ARM:-}" = all ]; then
    out=$(ARM=parked "$0" 2>&1); echo "$out" | sed 's/^/  parked: /'
    if echo "$out" | grep -q '^finish    FAIL (the warm-up never ended'; then echo "PREWARM_STALL ARMS RESULT PASS (parked failed as it must)"
    else echo "PREWARM_STALL ARMS RESULT FAIL (parked did not fail on its needle)"; exit 1; fi
    exit 0
fi
. "$ROOT/tools/dev/lock_a1_lib.sh"
SETTLE_S="${SETTLE_S:-60}"
A1_ENV_PREFIX="" a1_init "${PS_ENV:-enps}"
SHPID=""
cleanup() {
    [ -n "$SHPID" ] && kill "$SHPID" 2> /dev/null
    a1_down > /dev/null 2>&1
    rm -rf "$T"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
OUT="${OUT:-${SCRATCH:-/tmp}/prewarm_stall}"
mkdir -p "$OUT"
fail() { echo "PREWARM_STALL RESULT FAIL ($1)"; exit 1; }

rm -rf "$T"; mkdir -p "$T"
rsync -a --exclude '.git' --exclude '.qmlls.ini' --exclude '.claude' --exclude 'screenshots' "$ROOT/" "$T/" || fail "copy"
python3 "$T/tools/dev/perf/frame_split_ablate.py" "$T" hooktoggle > /dev/null || fail "the hook's anchor is gone"
case "${ARM:-}" in
    "") ;;
    parked) a1_patch modules/bar/gooey/GooeyEngine.qml '        if (engine._parked && Date.now() - engine._parked.at < engine.parkLingerMs)' \
        '        if (engine._parked)' || fail "arm anchor" ;;
    *) fail "unknown ARM=$ARM" ;;
esac
[ -n "${ARM:-}" ] && echo "  ARMED $ARM"

"$E" down > /dev/null 2>&1
env MODE=light "$E" up > /dev/null || fail "env up"
log="$OUT/shell.log"
"$E" run env SHELL_SERVICES=mock QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$T/shell.qml" > "$log" 2>&1 &
SHPID=$!
clean() { rl_clean "$log"; }
toggle() { "$E" run quickshell ipc --path "$T/shell.qml" call shell hook toggle weather 2> /dev/null; }
for _ in $(seq 1 1200); do clean | grep -aq 'LARES prewarm start\|Failed to load' && break; kill -0 "$SHPID" 2> /dev/null || break; sleep 0.1; done
clean | grep -aq 'LARES prewarm start' || { rl_noresult PREWARM_STALL "$log"; exit 1; }
sleep 0.3
r1=$(toggle); sleep 1.5; r2=$(toggle)
closed=$(date +%s)
fails=0
if [ "$r1" = open ] && [ "$r2" = shut ] && ! clean | grep -aq 'LARES prewarm end'; then
    echo "used      PASS (weather opened and closed while the warm-up ran)"
else
    echo "used      FAIL (the toggle answered '$r1' then '$r2', or the warm-up had already ended: the scenario did not happen)"; fails=1
fi
until clean | grep -aq 'LARES settled'; do
    [ $(( $(date +%s) - closed )) -lt "$SETTLE_S" ] || break
    sleep 0.5
done
if clean | grep -aq 'LARES settled'; then
    echo "finish    PASS ($(clean | grep -a 'LARES prewarm end' | tail -1 | sed 's/.*LARES //'); settled $(( $(date +%s) - closed )) s after the close)"
else
    echo "finish    FAIL (the warm-up never ended within ${SETTLE_S} s of the close: $(clean | grep -a 'LARES prewarm wait' | tail -1 | sed 's/.*LARES //'))"; fails=1
fi
[ "$fails" = 0 ] && echo "PREWARM_STALL RESULT PASS" && exit 0
echo "PREWARM_STALL RESULT FAIL (log: $log)"; exit 1
