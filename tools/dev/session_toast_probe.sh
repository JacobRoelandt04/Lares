#!/usr/bin/env bash
# session_toast_probe.sh -- session restore's three toasts on the REAL lane (tools/dev/qml/session_toast_probe.qml): the real
# SessionService on a stub of tools/session/lares-session, the real NotificationService, the real engine lane and toast stack.
# Offscreen in a sandbox copy. The stub prints the real tool's stdout line by line, a `sleep` between (the restore of 2026-11-15:
# ten windows in ~4.5 s).
#
#   tools/dev/session_toast_probe.sh        SESSION_TOAST RESULT PASS | FAIL
#   ONLY=<scenario>   one scenario (clean, tell, stall)
#   ARM=<name> ...    ARM=all ...           SESSION_TOAST ARMS PASS | FAIL
#
# ARMs (each puts a fault back in the sandbox copy; the check named must fail; each runs the scenario `clean` only):
#   noconfirm      a restore with nothing for the user to do ends in silence      -> "clean: ONE row is left, the confirmation"
#   progressstays  the progress toast is not withdrawn with the result            -> "clean: ONE row is left, the confirmation"
#   stickyconfirm  the plain confirmation never goes by itself                     -> "clean: the confirmation went by itself"
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${STP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-session-toast}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi STP_INNER=1 ARM="${ARM:-}" ONLY="${ONLY:-}" bash tools/dev/session_toast_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="SESSION_TOAST"

arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

stub() {  # stub <dir> <begin json> <restore script>
    mkdir -p "$1"
    printf '{ "enabled": true }\n' > "$1/session.jsonc"
    printf '%s\n' "$2" > "$1/begin.json"
    printf '%s\n' "$3" > "$1/restore.txt"
    cat > "$1/lares-session" <<'PY'
#!/usr/bin/env python3
import os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "begin":
    print(open(os.path.join(d, "begin.json")).read().strip())
elif cmd == "restore":
    for line in open(os.path.join(d, "restore.txt")).read().splitlines():
        if line.startswith("sleep "):
            time.sleep(float(line.split()[1]))
        elif line.strip():
            print(line, flush=True)
elif cmd == "watch":
    time.sleep(600)
PY
    chmod +x "$1/lares-session"
}

# the tool's lines for a restore of ten windows: `win <n> <waiting...>` is a progress line
script() {  # script <result json> [stall]
    local res="$1" stall="${2:-}"
    printf 'sleep 0.25\n{"event": "start", "total": 10}\n'
    local names=("kitty" "kitty" "kitty" "kitty" "kitty" "kitty" "Zen Browser" "Visual Studio Code" "Visual Studio Code" "kitty")
    for n in 1 2 3 4 5 6 7 8 9; do
        local w='["Zen Browser", "Visual Studio Code"]'
        [ "$n" -ge 7 ] && w='["Visual Studio Code"]'
        printf 'sleep 0.3\n{"event": "progress", "done": %s, "total": 10, "waiting": %s}\n' "$n" "$w"
        if [ "$n" = 6 ] && [ -n "$stall" ]; then printf 'sleep 3.0\n'; fi
    done
    printf 'sleep 0.3\n{"event": "progress", "done": 10, "total": 10, "waiting": []}\n'
    printf 'sleep 0.2\n{"event": "reveal"}\n'
    printf 'sleep 0.6\n%s\n' "$res"
}

run_once() {
    local tree log out rc S=modules/session/SessionService.qml
    tree=$(mktemp -d "$SCRATCH/stp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        noconfirm)     arm "$tree/$S" '        root._tell = needs !== "" ? needs : root.confirmWords(r);' '        root._tell = needs;' || return 3 ;;
        progressstays) arm "$tree/$S" '        if (root._progressUp && root.notifier)
            root.notifier.withdraw("progress");' '' || return 3 ;;
        stickyconfirm) arm "$tree/$S" '        root._tellMs = needs !== "" ? 12000 : 6000;' '        root._tellMs = 0;' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/xdg/cache" "$tree/home" "$tree/work"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    local ask='{"decision": "ask", "cause": "Logged out at 20:42", "clean": true, "snapshot": "x", "summary": "10 windows: kitty x7, Visual Studio Code x2, Zen Browser"}'
    local nothing='{"event": "result", "restored": 10, "planned": 10, "skipped": [], "failed": [], "later": [], "ran": 0, "typed": 0, "waiting": [], "unclaimed": 0, "refocus": false, "ms": 4518}'
    local typed='{"event": "result", "restored": 10, "planned": 10, "skipped": [], "failed": [], "later": [], "ran": 0, "typed": 4, "waiting": [], "unclaimed": 0, "refocus": false, "ms": 4518}'
    stub "$tree/work/clean" "$ask" "$(script "$nothing")"
    stub "$tree/work/tell"  "$ask" "$(script "$typed")"
    stub "$tree/work/stall" "$ask" "$(script "$nothing" stall)"
    stub "$tree/work/prewarm" "$ask" "$(script "$nothing")"
    log="$tree/run.log"
    ( cd "$tree" && env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" \
        STP_WORK="$tree/work" ONLY="${ONLY:-}" \
        tools/dev/notifications_bus.sh timeout -k 2 150 quickshell -n -p tools/dev/qml/session_toast_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "SESSION_TOAST RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "STP .*FAIL" | head -8
    [ -n "${STP_TIMELINE:-}" ] && rl_clean "$log" | grep -a -A60 "STP timeline" | head -${STP_TIMELINE_LINES:-200}
    if rl_clean "$log" | grep -a -E "WARN|ERROR" | rl_platform_noise | grep -a -E "SessionService|session_toast_probe|Toast|Notification|Binding loop|Unable to assign" | head -5 | grep -a .; then rc=1; fi
    cp "$log" "${STP_KEEPLOG:-/dev/null}" 2> /dev/null
    rl_isnoresult "$out" || rm -rf "$tree"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([noconfirm]="clean: ONE row is left, the confirmation" [progressstays]="clean: ONE row is left, the confirmation" [stickyconfirm]="clean: the confirmation went by itself")
    for a in ${ONLY_ARMS:-noconfirm progressstays stickyconfirm}; do
        o=$(ONLY=clean run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aF "STP ${NEED[$a]}" | grep -aq "FAIL"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check (${NEED[$a]}): $(printf '%s\n' "$o" | grep -a 'STP .*FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
}
