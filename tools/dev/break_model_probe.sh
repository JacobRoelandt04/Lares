#!/usr/bin/env bash
# break_model_probe.sh -- the break nudge's rules (modules/bar/workspaces/BreakModel.qml) on a 6000x clock, and the rail's draw order.
#
#   tools/dev/break_model_probe.sh                BREAKS RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/break_model_probe.sh     a fault in the sandbox copy, one check goes red: overtimers (draw order), noease, easeunbounded
#                                                 (paint budget), nograce, linear (curve), nohidden, onlyidle (overlap), nosleep, lockreset, nobeat,
#                                                 reburst (the burst's hysteresis)
#
# Offscreen, in the sandbox copy (the arm patches the copy). The verdict is the probe's own RESULT line.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
M=modules/bar/workspaces/BreakModel.qml
W=modules/bar/workspaces/Workspaces.qml
case "${ARM:-}" in
    "") P="" ;;
    overtimers) P="sed -i 's|z: fillCanvas.index === root.breakTone ? 0.9 : 1|z: 1|' $W" ;;
    noease) P="sed -i 's|(f.ease === \"outCubic\" ? 1 - Math.pow(1 - u, 3) : u)|u|' $W" ;;
    easeunbounded) P="sed -i 's|property int fillEaseMaxHz: 30|property int fillEaseMaxHz: 1000|' $W" ;;
    nograce) P="sed -i 's|root.nowMs() - root.graceS \* 1000|root.nowMs()|' $M" ;;
    linear) P="sed -i 's|return Math.pow(x, root.rewindPower);|return x;|' $M" ;;
    nohidden) P="sed -i 's|c >= root.hiddenS \&\& c > 0|c > 0|' $M" ;;
    onlyidle) P="sed -i 's|if (root.idle \|\| root.locked \|\| root._sleeping) {|if (root.idle) {|' $M" ;;
    nosleep) P="sed -i 's|        root._sleeping = true;\n        root._spanSync(root.nowMs());||; s|function sleepBegan(): void {|function sleepBegan(): void { return;|; s|function resume(): void {|function resume(): void { return;|' $M" ;;
    lockreset) P="sed -i 's|onLockedChanged: root._spanSync(root.nowMs())|onLockedChanged: { root._spanSync(root.nowMs()); if (root.locked) root._credit = 0; }|' $M" ;;
    nobeat) P="sed -i 's|Math.min(root.stepS, root.durationS|Math.min(1, root.durationS|' $M" ;;
    reburst) P="sed -i 's|if (target >= 1 \&\& !root._announced)|if (target >= 1)|; s|if (target < root.refullBelow) {|if (target < 1) {|' $M" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
LOG="$(mktemp "${SCRATCH:-/tmp}/brk.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
tools/dev/sandbox.sh bash -c "set -e; ${P:+$P; }env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 60 quickshell -p tools/dev/qml/break_model_probe.qml" > "$LOG" 2>&1
rl_clean "$LOG" | grep -a -o 'BREAKS .*' | grep -a -v 'RESULT'
if rl_has "$LOG" 'BREAKS RESULT'; then rl_clean "$LOG" | grep -a -o 'BREAKS RESULT.*' | tail -1; rl_clean "$LOG" | grep -a -q 'BREAKS RESULT PASS' && exit 0 || exit 1; fi
rl_noresult BREAKS "$LOG"
