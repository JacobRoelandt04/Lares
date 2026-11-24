#!/usr/bin/env bash
# shell_rest_sampler.sh -- "CPU spikes every ~10-20 s" (feedback/general.md, tested at 1a182218): per-thread CPU at 100 ms from /proc, the
# spikes in it, their period, the threads that carry them. The analysis is tools/dev/perf/shell_rest_sampler.py (read its header); this runs it.
#
#   tools/dev/perf/shell_rest_sampler.sh <pid> <seconds>           any process, read-only
#   tools/dev/perf/shell_rest_sampler.sh --trial <seconds>         the user's trial shell: its pid from $XDG_RUNTIME_DIR/lares/pid -- a pid
#                                                              file the tool wrote, never found by name -- checked to be a quickshell that
#                                                              runs shell.qml; /proc only, nothing is sent to it
#   tools/dev/perf/shell_rest_sampler.sh --private <seconds>       a PRIVATE shell: shell.qml with mock services in tools/dev/lock_env.sh's nested
#                                                              Hyprland (two outputs, a copy of the tree); it waits until the start's
#                                                              shader compiles and first reads are over (<= 3 % of a core for 5 s running,
#                                                              SETTLE=150 s at most, and says what the start cost), then samples; the
#                                                              nested session goes down after. PLAYER=play makes the mock player play
#                                                              (default: idle). Nothing of the desktop is touched.
#   SPIKE_PCT=20 MERGE_MS=300 INTERVAL_MS=100 JSON=<file> MAX_BURSTS=0 (list every burst; --json holds all) HYPR_EVENTS=1 (name the compositor's events around each burst, read only) SETTLE=150 are the sampler's knobs
#
# It is a MEASUREMENT: `REST_SAMPLER RESULT PASS` says it sampled (enough samples, the process alive throughout), not that anything is fine.
# Run it with the machine as quiet as you can get it and read the load lines it prints beside the figures (a build or a test sweep
# on the same machine is spiky by itself). An idle shell asks for no frame and burns no CPU: a spike at rest has a timer, a poll or a
# service behind it, and the thread names say where to look.
#
# The sampler itself is proved against a stand-in process with known spike trains: tools/dev/perf/shell_rest_sampler_selftest.sh (quick tier `rest_sampler`).
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
SAMPLER="$HERE/tools/dev/perf/shell_rest_sampler.py"
SPIKE_PCT="${SPIKE_PCT:-20}"; MERGE_MS="${MERGE_MS:-300}"; INTERVAL_MS="${INTERVAL_MS:-100}"
extra=(--spike-pct "$SPIKE_PCT" --merge-ms "$MERGE_MS" --interval-ms "$INTERVAL_MS")
[ -n "${JSON:-}" ] && extra+=(--json "$JSON")
[ -n "${MAX_BURSTS:-}" ] && extra+=(--max-bursts "$MAX_BURSTS")
[ -n "${HYPR_EVENTS:-}" ] && extra+=(--hypr-events)

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

mode=${1:-}
case $mode in
    --trial)
        secs=${2:-}; [ -n "$secs" ] || usage
        RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
        pidfile=$RT/lares/pid
        if ! read -r pid 2> /dev/null < "$pidfile" || ! [[ $pid =~ ^[0-9]+$ ]]; then
            echo "REST_SAMPLER RESULT FAIL (no running shell: $pidfile is not there -- lares start)"; exit 3
        fi
        comm=$(cat "/proc/$pid/comm" 2> /dev/null)
        args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null)
        if [ "$comm" != quickshell ] || [[ $args != *shell.qml* ]]; then
            echo "REST_SAMPLER RESULT FAIL (pid $pid in $pidfile is no quickshell running shell.qml: comm '$comm')"; exit 3
        fi
        exec python3 "$SAMPLER" "$pid" "$secs" --name "the user's trial shell" "${extra[@]}" ;;
    --private) ;;
    ""|-h|--help) usage ;;
    *) pid=$mode; secs=${2:-}; [ -n "$secs" ] || usage
       exec python3 "$SAMPLER" "$pid" "$secs" "${extra[@]}" ;;
esac

# ---- --private -----------------------------------------------------------------------------------------------------------------
secs=${2:-}; [ -n "$secs" ] || usage
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox-rest}"
if [ -z "${REST_INNER:-}" ]; then
    # inside a sandbox copy (a quickshell started in the tree would rewrite its .qmlls.ini), the offscreen words first so the copy gets its
    # private runtime dir; lock_env's own session carries its own
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi REST_INNER=1 \
        bash tools/dev/perf/shell_rest_sampler.sh --private "$secs"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-rest0}"
SETTLE="${SETTLE:-150}"
LOG="$SCRATCH/shell_rest.log"
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

"$E" down > /dev/null 2>&1
OUTPUTS=2 "$E" up > /dev/null || { echo "REST_SAMPLER RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.config({ general = { gaps_out = 6 } })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
sleep 1
# the same environment as tools/dev/perf/shell_idle.sh's phase C (mock services, the compositor's focus), the player idle unless PLAYER=play
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live ${PLAYER:+SHELL_PLAYER=$PLAYER} MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$HERE/shell.qml" > "$LOG" 2>&1 &
QPID=$!
for _ in $(seq 1 300); do
    grep -aqE "LARES ready" "$LOG" 2> /dev/null && break
    kill -0 "$QPID" 2> /dev/null || break
    sleep 0.3
done
grep -aqE "LARES ready" "$LOG" || { rl_noresult REST_SAMPLER "$LOG"; exit 1; }
echo "REST_SAMPLER the private shell is up (pid $QPID, mock services${PLAYER:+, player $PLAYER}); waiting for its start to settle (shaders, the services' first reads, the prewarm)"
kill -0 "$QPID" 2> /dev/null || { echo "REST_SAMPLER RESULT FAIL (the private shell died at the start: $LOG)"; exit 1; }
python3 "$SAMPLER" "$QPID" "$secs" --settle "$SETTLE" --name "a private shell (mock services)" "${extra[@]}"
rc=$?
grep -aE "WARN|ERROR" "$LOG" | sed -r 's/\x1b\[[0-9;]*m//g' | grep -av "quickshell.tooling" | sort | uniq -c | sort -rn | head -5 | sed 's/^/REST_SAMPLER log: /'
exit "$rc"
