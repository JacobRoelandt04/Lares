#!/usr/bin/env bash
# break_budget.sh -- the break nudge's paints and wake-ups per hour of use (tools/dev/qml/break_budget.qml), this tree or an older one.
#
#   tools/dev/break_budget.sh              the tree this script is in (the NEW model: a simulated hour on a 600x clock + one real beat)
#   tools/dev/break_budget.sh <tree>       another tree that holds tools/dev/sandbox.sh (an old revision from `git archive`): the OLD
#                                          model, 20 s in real time scaled to its 50 minutes. The harness is copied into it.
#
# Offscreen in the tree's sandbox copy. Prints one BREAKBUDGET line.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TREE="${1:-$HERE}"
[ "$TREE" = "$HERE" ] || cp "$HERE/tools/dev/qml/break_budget.qml" "$TREE/tools/dev/qml/break_budget.qml"
cd "$TREE" || exit 1
LOG="$(mktemp "${SCRATCH:-/tmp}/brkb.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
tools/dev/sandbox.sh bash -c "env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 90 quickshell -p tools/dev/qml/break_budget.qml" > "$LOG" 2>&1
grep -a -o 'BREAKBUDGET .*' "$LOG" || { echo "BREAKBUDGET FAIL (no line: $LOG)"; cp "$LOG" "${SCRATCH:-/tmp}/brkb.last"; exit 1; }
