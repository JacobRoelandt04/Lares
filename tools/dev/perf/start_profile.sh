#!/usr/bin/env bash
# start_profile.sh -- Qt's QML profiler over the shell's START: the mock shell (shell.qml, mock services) in tools/dev/lock_env.sh's
# nested Hyprland, started with `--debug <port> --waitfordebug`, /usr/lib/qt6/bin/qmlprofiler attached and recording BEFORE the
# configuration runs, until `LARES ready` (+ READY_TAIL_S, default 1). The trace (<outdir>/start.qtd) is read by
# tools/dev/perf/qml_profile.py: creating / compiling / binding / handlingsignal / javascript ranges by self and total time, and per file.
#
#   tools/dev/perf/start_profile.sh <outdir>          SHELL_JSONC_FILE=<the shell's config to copy>  SCALE=1.25
#
# READ SHARES, NOT TIMES: the debugger turns Qt's QML disk cache OFF (every unit is compiled, as on a cold start) and the profiler
# slows call-heavy code; the object creation's shares are what this is for. Timings: tools/dev/perf/start_split.sh.
# Ends in `START_PROFILE RESULT PASS|FAIL` (PASS: a trace was written).
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-perf-sp}"
if [ -z "${SP_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SP_INNER=1 \
        SCALE="${SCALE:-1}" REFRESH="${REFRESH:-120}" SHELL_JSONC_FILE="${SHELL_JSONC_FILE:-}" READY_TAIL_S="${READY_TAIL_S:-1}" \
        SP_PATCH="${SP_PATCH:-}" bash tools/dev/perf/start_profile.sh "$OUT"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-stpr}"
QPID="" PPID_PROF=""
cleanup() {
    [ -n "$PPID_PROF" ] && kill "$PPID_PROF" 2> /dev/null
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
# SP_PATCH: a script run in the copy before the start (an ablation: one module off, a mark added)
if [ -n "${SP_PATCH:-}" ]; then bash "$SP_PATCH" || { echo "START_PROFILE RESULT FAIL (SP_PATCH failed)"; exit 1; }; fi

"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH="${REFRESH:-120}" "$E" up > /dev/null || { echo "START_PROFILE RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
if [ -n "${SHELL_JSONC_FILE:-}" ]; then
    cfgdir="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
    mkdir -p "$cfgdir" && cp "$SHELL_JSONC_FILE" "$cfgdir/shell.jsonc" || { echo "START_PROFILE RESULT FAIL (SHELL_JSONC_FILE)"; exit 1; }
fi
PORT=$(( 39000 + $$ % 2000 ))
LOG="$OUT/shell.log"
"$E" run env SHELL_SERVICES=mock MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell --log-times --debug "$PORT" --waitfordebug -n -p "$HERE/shell.qml" > "$LOG" 2>&1 &
QPID=$!
sleep 1.5
FIFO="$OUT/prof.fifo"; rm -f "$FIFO"; mkfifo "$FIFO"
/usr/lib/qt6/bin/qmlprofiler -a 127.0.0.1 -p "$PORT" --interactive --record on \
    --include javascript,binding,handlingsignal,creating,compiling < "$FIFO" > "$OUT/prof.log" 2>&1 &
PPID_PROF=$!
exec 7> "$FIFO"
deadline=$(( $(date +%s) + 240 ))
until grep -aq "LARES ready" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { rl_noresult START_PROFILE "$LOG"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "START_PROFILE RESULT FAIL (no LARES ready: $LOG)"; exit 1; }
    sleep 0.2
done
sleep "${READY_TAIL_S:-1}"
echo record >&7; sleep 1
echo "output $OUT/start.qtd" >&7; sleep 4
echo quit >&7; exec 7>&-
sleep 0.5
[ -s "$OUT/start.qtd" ] || { echo "START_PROFILE RESULT FAIL (no trace: $OUT/prof.log)"; exit 1; }
python3 tools/dev/perf/qml_profile.py "$OUT/start.qtd" --top "${PROFILE_TOP:-30}" --strip "$HERE/" --by-file > "$OUT/table.txt" 2>&1
echo "START_PROFILE trace $OUT/start.qtd, table $OUT/table.txt"
echo "START_PROFILE RESULT PASS"
