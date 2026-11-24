#!/usr/bin/env bash
# curtain_repaint_env_probe.sh -- the theme curtain's repaint of the hidden windows, END TO END: the real shell.qml (mock services)
# in the nested Hyprland of lock_env.sh on two outputs, real kitty / Qt / GTK 4 windows on shown and hidden workspaces, a special
# workspace and groups, a right click on the theme button with the virtual pointer.
#
#   tools/dev/curtain_repaint_env_probe.sh       ends in CURTAIN_REPAINT RESULT PASS|FAIL
#   ARM=<name> tools/dev/...                     a fault in the sandbox copy:
#       norepaint    the curtain's repaint never starts            -> "no stale frame" fails (the film sees the old pictures)
#       nohold       the bars' focus is not held during the run    -> "the bars' focus held still" fails
#       triggers     the repaint's own events fast-forward the run -> "no fast-forward" fails
#       late         the repaint starts when the curtain has gone  -> "nothing shows through the curtain" fails
#                    (1250 ms into a hold of 400 + a reveal of 800: mid-reveal the middle column may still be covered, a coin toss)
#   ARM=all tools/dev/...                        CURTAIN_REPAINT ARMS RESULT PASS | FAIL
#   CR_MODE=debug tools/dev/...                  shell.jsonc "curtainRepaintDebug": true: the click switches with NO curtain, then
#                                                the repaint runs slowed and named, the bar not held
#   CR_MODE=long tools/dev/...                   "curtainRepaintFrames": 60: a run of ~5 s, past the 4 s the shell once cut every
#                                                run at; ARM=fixedwatch (with CR_MODE=long) drops the watchdog's re-arm from the
#                                                tool's plan -> "the tool said ok" fails
# The default run's shell.jsonc gives one kitty class (K3B, in upper case) 30 frames: the table reaches the tool through the shell.
#   CR_KEEP=1                                    keep the nested env and the logs
#
# The driver (curtain_repaint_env_probe.py) has the checks; tools/dev/hidden_repaint_env_probe.sh proves the tool alone.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
NAME=CURTAIN_REPAINT
. "$ROOT/tools/dev/result_lib.sh"
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-currep}"
SANDBOX="${SANDBOX:-${SCRATCH:-/tmp}/lares-sbx-currep}"
SCR="${SCRATCH:-/tmp}/currep-$LOCK_ENV"

if [ "${ARM:-}" = all ]; then
    rc=0
    declare -A NEED=([norepaint]="no stale frame" [nohold]="the bars' focus held still" [triggers]="no fast-forward" [late]="nothing shows through the curtain")
    for a in norepaint nohold triggers late; do
        out=$(ARM="$a" CR_KEEP= SANDBOX="$SANDBOX-$a" LOCK_ENV="cr${a:0:6}" bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "anchor check failed"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif rl_isnoresult "$out"; then
            echo "ARM $a: NOT PROVEN (no result)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL" && printf '%s\n' "$out" | grep -aqF "  FAIL ${NEED[$a]}"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aF "  FAIL ${NEED[$a]}" | head -1 | cut -c3-140))"
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS CHECK: $(printf '%s\n' "$out" | grep -a '^  FAIL' | head -1 | cut -c1-140)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi

SPID=""; _cleaned=0; _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    [ -n "${CR_KEEP:-}" ] || "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX"
    [ "$_ok" = 1 ] && [ -z "${CR_KEEP:-}" ] && rm -rf "$SCR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
rm -rf "$SCR"; mkdir -p "$SCR"
SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "$NAME RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
arm() {  # file count from to
    python3 - "$@" <<'PY' || { echo "ARM ${ARM:-}: anchor check failed"; exit 2; }
import sys
p, n, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(p, encoding="utf-8").read()
if s.count(a) != n:
    print(f"FAIL  anchor found {s.count(a)} times in {p}, expected {n}: {a[:70]!r}")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
    "") ;;
    norepaint) arm "$SB/modules/shell/ThemeControl.qml" 1 '        if (root.repaintWanted && !root._ff)
            repaintDelay.restart();' '' ;;
    nohold) arm "$SB/modules/shell/ShellServices.qml" 1 '    Binding { target: focusItem; property: "held"; value: themeControlItem.repaintHeld }' '' ;;
    triggers) arm "$SB/modules/shell/ThemeControl.qml" 1 '            if (root.repaintHeld)
                return;
            if (root.curtainTriggers' '            if (root.curtainTriggers' ;;
    fixedwatch) arm "$SB/modules/shell/ThemeControl.qml" 1 '                        repaintWatch.interval = Number(plan[1]) + root.curtainRepaintTimeoutMs;
                        repaintWatch.restart();' '' ;;
    late) arm "$SB/modules/shell/ThemeControl.qml" 1 '            if (root._repaintBusy || repaintDelay.running)
                return;
' ''
          arm "$SB/modules/shell/ThemeControl.qml" 1 '    property int curtainRepaintDelayMs: 120' '    property int curtainRepaintDelayMs: 1250'
          arm "$SB/modules/shell/ThemeControl.qml" 1 '            if (root._cs !== "holding" || root._ff)
                return;
            root.repaintRuns++;' '            root.repaintRuns++;' ;;
    *) echo "$NAME RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
esac

"$E" down > /dev/null 2>&1
OUTPUTS=2 "$E" up > "$SCR/up.log" 2>&1 || { cat "$SCR/up.log"; echo "$NAME RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
D="$("$E" dir)"
mkdir -p "$D/state/lares-shell-mock/config"
if [ "${CR_MODE:-}" = debug ]; then
    printf '{ "theme": { "curtain": true, "curtainLive": true, "curtainRepaintDebug": true, "curtainRepaintDebugMs": 300 } }\n' > "$D/state/lares-shell-mock/config/shell.jsonc"
elif [ "${CR_MODE:-}" = long ]; then
    printf '{ "theme": { "curtain": true, "curtainLive": true, "curtainRepaintFrames": 60 } }\n' > "$D/state/lares-shell-mock/config/shell.jsonc"
else
    printf '{ "theme": { "curtain": true, "curtainLive": true, "curtainRepaintClassFrames": { "K3B": 30 } } }\n' > "$D/state/lares-shell-mock/config/shell.jsonc"
fi
SLOG="$SCR/shell.log"
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live SHELL_REPAINT=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do
    grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
grep -aq "LARES settled" "$SLOG" || { rl_noresult "$NAME" "$SLOG"; exit 1; }

LOG="$SCR/checks.log"
timeout 500 "$E" run env CR_MODE="${CR_MODE:-}" python3 "$ROOT/tools/dev/curtain_repaint_env_probe.py" "$SB" 2>&1 | tee "$LOG"
rl_clean "$SLOG" | grep -a "LARESCURTAIN" | sed 's/.*LARESCURTAIN ctl [0-9]* /    curtain: /' | tail -14
if ! rl_has "$LOG" "^$NAME RESULT "; then rl_noresult "$NAME" "$LOG"; exit 1; fi
fail=0
rl_has "$LOG" "^$NAME RESULT PASS" || fail=1
kill -0 "$SPID" 2> /dev/null || { echo "    FAIL the shell died during the run (see $SLOG)"; fail=1; }
warns=$(rl_clean "$SLOG" | rl_platform_noise | grep -aE "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property" \
    | grep -avE "quickshell.tooling|--- WARNING ---|actually running wayland|does not support setting window masks|Failed to register with host portal|Could not load icon")
if [ -n "$warns" ] && [ -z "${ARM:-}" ]; then
    echo "    FAIL the shell's log complains:"; printf '%s\n' "$warns" | sed 's/^ *//' | sort | uniq -c | sort -rn | head -8 | sed 's/^/        /'
    fail=1
fi
if [ "$fail" = 0 ]; then _ok=1; exit 0; fi
[ "$(tail -1 "$LOG" | grep -c 'RESULT PASS')" = 1 ] && echo "$NAME RESULT FAIL (the shell's log; kept: $SCR)"
exit 1
