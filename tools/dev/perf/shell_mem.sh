#!/usr/bin/env bash
# shell_mem.sh -- what the shell's resident memory is made of, by ablation: the mock shell (shell.qml, mock services) in
# tools/dev/lock_env.sh's nested Hyprland, started once per VARIANT, read from /proc/<pid>/smaps_rollup once it has said `LARES settled`
# and a rest has passed. A variant is one thing changed against `base`:
#
#   tools/dev/perf/shell_mem.sh <outdir> [variant ...]
#       base              the shell as it is
#       off:<module>      shell.jsonc `"modules": { "<module>": false }` (ShellLayout.MODULES) -- what a module holds
#       env:<VAR=VALUE>   one more environment variable for the shell (MALLOC_ARENA_MAX=2, QV4_GC_...)
#       nothp             transparent huge pages off for the shell's process (prctl PR_SET_THP_DISABLE before the exec)
#       noprewarm         the engine's start-up prewarm ablated (frame_split_ablate.py `noprewarm`)
#       abl:<name>        any other ablation of frame_split_ablate.py
#   REST_S=8 seconds between `settled` and the reading.   REFRESH=120 SCALE=1.
#
# Prints one line per variant: Rss, Pss, anonymous, the anonymous part in huge pages, file-backed, and the difference to `base`
# (run `base` first; twice shows how far two starts of one tree differ, which is the noise every difference is read against).
# Memory is not a timing: this needs no quiet machine. Ends in `SHELL_MEM RESULT PASS|FAIL`.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
[ $# -gt 0 ] || set -- base
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-perf-mem}"
if [ -z "${SM_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    res="$OUT/mem.tsv"; : > "$res"
    fail=0
    for v in "$@"; do
        # one sandbox call per variant: the copy is re-synced on every call, so an ablation never leaks into the next variant
        SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SM_INNER=1 \
            REFRESH="${REFRESH:-120}" SCALE="${SCALE:-1}" REST_S="${REST_S:-8}" SM_RES="$res" \
            bash tools/dev/perf/shell_mem.sh "$OUT" "$v" || fail=1
    done
    python3 - "$res" <<'PYEOF_SHELL_MEM'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
base = next((r for r in rows if r[0] == "base"), None)
print("SHELL_MEM %-26s %8s %8s %8s %8s %8s   %s" % ("variant", "Rss", "Pss", "anon", "anonTHP", "file", "Rss / anon against the first base (MiB)"))
for r in rows:
    v = [int(x) / 1024 for x in r[1:6]]
    d = "" if base is None or r is base else "%+7.1f / %+7.1f" % (v[0] - int(base[1]) / 1024, v[2] - int(base[3]) / 1024)
    print("SHELL_MEM %-26s %8.1f %8.1f %8.1f %8.1f %8.1f   %s" % (r[0], *v, d))
PYEOF_SHELL_MEM
    [ "$fail" = 0 ] && [ -s "$res" ] && { echo "SHELL_MEM RESULT PASS ($(wc -l < "$res") variant(s) read)"; exit 0; }
    echo "SHELL_MEM RESULT FAIL (a variant did not come up: $OUT)"; exit 1
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-pfm0}"
v=$1
safe=$(printf '%s' "$v" | tr -c 'A-Za-z0-9_.-' '_')
LOG="$OUT/$safe.log"
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

extra_env=(); pre=(); modules=""
case $v in
    base) ;;
    off:*) modules="{ \"${v#off:}\": false }" ;;
    env:*) extra_env+=("${v#env:}") ;;
    nothp) pre=(python3 -c 'import ctypes, os, sys; ctypes.CDLL(None, use_errno=True).prctl(41, 1, 0, 0, 0); os.execvp(sys.argv[1], sys.argv[1:])') ;;
    noprewarm) python3 tools/dev/perf/frame_split_ablate.py "$HERE" noprewarm || exit 1 ;;
    abl:*) python3 tools/dev/perf/frame_split_ablate.py "$HERE" "${v#abl:}" || exit 1 ;;
    *) echo "SHELL_MEM unknown variant: $v"; exit 1 ;;
esac

"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH="${REFRESH:-120}" "$E" up > /dev/null || { echo "SHELL_MEM $v: the nested Hyprland did not come up"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
if [ -n "$modules" ]; then
    cfg="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
    mkdir -p "$cfg" && printf '{ "modules": %s }\n' "$modules" > "$cfg/shell.jsonc"
fi
sleep 1
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 "${extra_env[@]}" \
    "${pre[@]}" quickshell -n -p "$HERE/shell.qml" > "$LOG" 2>&1 &
QPID=$!
deadline=$(( $(date +%s) + 240 ))
until grep -aq "LARES settled" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { echo "SHELL_MEM $v: the shell died at the start ($LOG)"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "SHELL_MEM $v: never said settled ($LOG)"; exit 1; }
    sleep 0.5
done
sleep "${REST_S:-8}"
# the quickshell itself: the process named quickshell that carries THIS nested session's LOCK_ENV_DIR (never found by a command line)
pid=""
for p in $(pgrep -x quickshell 2> /dev/null); do
    grep -qz "LOCK_ENV_DIR=/tmp/lrlk-$LOCK_ENV\$" "/proc/$p/environ" 2> /dev/null && pid=$p
done
[ -n "$pid" ] || { echo "SHELL_MEM $v: the shell's pid was not found"; exit 1; }
awk -v name="$v" '
    $1 == "Rss:" { rss = $2 } $1 == "Pss:" { pss = $2 } $1 == "Anonymous:" { anon = $2 } $1 == "AnonHugePages:" { thp = $2 } $1 == "Pss_File:" { file = $2 }
    END { printf "%s\t%d\t%d\t%d\t%d\t%d\n", name, rss, pss, anon, thp, file }' "/proc/$pid/smaps_rollup" >> "$SM_RES"
tail -1 "$SM_RES" | awk -F'\t' '{ printf "SHELL_MEM read %s: Rss %.1f MiB, anonymous %.1f MiB\n", $1, $2 / 1024, $4 / 1024 }'
exit 0
