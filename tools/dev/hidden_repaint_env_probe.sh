#!/usr/bin/env bash
# hidden_repaint_env_probe.sh -- tools/theme/hidden_repaint.py against the REAL Hyprland, nested (lock_env.sh, two outputs), with real
# kitty / Qt / GTK 4 windows on shown and hidden workspaces, a special workspace and groups with hidden tabs.
#
#   tools/dev/hidden_repaint_env_probe.sh        ends in HIDDEN_REPAINT RESULT PASS|FAIL
#   ARM=norun tools/dev/...                      the tool is not run: the film must show stale frames (else the film proves nothing)
#   ARM=<name> tools/dev/...                     a fault put into a COPY of the tool (tools/dev/hidden_repaint_arm.py lists them)
#   ARM=all tools/dev/...                        every arm in turn: HIDDEN_REPAINT ARMS RESULT PASS | FAIL
#   HR_MODE=interrupt tools/dev/...              the user changes workspace under the run: it stops, nothing is yanked back
#   HR_MODE=debug tools/dev/...                  the slowed, named run a person watches (--debug-ms)
#   HR_MODE=vscode tools/dev/...                 a REAL VS Code (a private profile) as a hidden tab: it comes back in the new colours,
#                                                which takes its class's own frames (ARM noclassframes: HR_VSCODE_FRAMES= -> stale)
#   HR_FRAMES=<n>                                frames a step stays (default 3)
#   HR_KEEP=1                                    keep the nested env up at the end
#
# WHY. After a theme switch a window that is hidden (another workspace, a group's hidden tab) shows its old colours for a frame or
# two when it comes back: Hyprland marks it suspended and kitty and Qt draw nothing then. Only showing it cures that, so the tool
# shows every hidden workspace and tab for a few frames under the theme curtain and puts the session back. The driver
# (hidden_repaint_env_probe.py) has the checks: the session is exactly where it was, and a film of every hidden thing shown
# afterwards holds no stale frame.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=HIDDEN_REPAINT
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-hidrep}"
# shellcheck source=tools/dev/result_lib.sh
. "$ROOT/tools/dev/result_lib.sh"

if [ "${ARM:-}" = all ]; then
    rc=0
    for a in $(python3 "$ROOT/tools/dev/hidden_repaint_arm.py" --list); do
        out=$(ARM="$a" HR_MODE="$(python3 "$ROOT/tools/dev/hidden_repaint_arm.py" --mode "$a")" HR_KEEP= \
              HR_VSCODE_FRAMES="$([ "$a" = noclassframes ] || echo 16)" bash "$0" 2>&1)
        needle=$(python3 "$ROOT/tools/dev/hidden_repaint_arm.py" --needle "$a")
        if printf '%s\n' "$out" | grep -aq "its anchor is gone"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif rl_isnoresult "$out"; then
            echo "ARM $a: NO RESULT"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL" && printf '%s\n' "$out" | grep -aqE "^  FAIL $needle"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aE "^  FAIL $needle" | head -1 | cut -c3-150))"
        elif printf '%s\n' "$out" | grep -aq "^$NAME RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS CHECK: $(printf '%s\n' "$out" | grep -a '^  FAIL' | head -1 | cut -c1-150)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/hidrep.XXXXXX")"
LOG="$W/run.log"
cleanup() {
    [ -n "${HR_KEEP:-}" ] || "$E" down > /dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT

TOOL="$ROOT/tools/theme/hidden_repaint.py"
if [ -n "${ARM:-}" ] && [ "$ARM" != norun ] && [ "$ARM" != noclassframes ]; then
    cp "$TOOL" "$W/hidden_repaint.py"
    python3 "$ROOT/tools/dev/hidden_repaint_arm.py" "$ARM" "$W/hidden_repaint.py" || { echo "$NAME RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
    TOOL="$W/hidden_repaint.py"
fi

"$E" down > /dev/null 2>&1
OUTPUTS=2 "$E" up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "$NAME RESULT FAIL (the nested env did not come up)"; exit 1; }
HR_TOOL="$TOOL" timeout 400 "$E" run env HR_TOOL="$TOOL" ARM="${ARM:-}" HR_FRAMES="${HR_FRAMES:-3}" HR_MODE="${HR_MODE:-}" HR_VSCODE_FRAMES="${HR_VSCODE_FRAMES-16}" \
    python3 "$ROOT/tools/dev/hidden_repaint_env_probe.py" 2>&1 | tee "$LOG"
if ! rl_has "$LOG" "^$NAME RESULT "; then
    cp "$LOG" "${TMPDIR:-/tmp}/hidden_repaint_last.log" 2> /dev/null
    rl_noresult "$NAME" "${TMPDIR:-/tmp}/hidden_repaint_last.log"
    exit 1
fi
rl_has "$LOG" "^$NAME RESULT PASS"
