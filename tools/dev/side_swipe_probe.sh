#!/usr/bin/env bash
# side_swipe_probe.sh -- one reading of every wheel event (WheelHub.read, WheelArea) and the mouse's side buttons as a two-finger swipe (SideSwipe),
# with the shared readers under them (TabSelector, SwipeScrub, ScrollDressing, CardViewCycler, WheelStepper): tools/dev/qml/side_swipe_probe.qml,
# offscreen, real presses and wheels through the window; the recorded events of a real mouse and of fingers through WheelHub.read.
#
#   tools/dev/side_swipe_probe.sh              SIDESWIPE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/side_swipe_probe.sh   the fault patched into the sandbox copy; passes when the check it aims at FAILS (ARM=all: every one):
#     pixels      a pixel delta means fingers, as it did before Qt 6.12         -> "a mouse's notch"
#     nopieces    a high-resolution wheel's pieces are not added up             -> "add up to whole notches"
#     order       the chain is the lowest reader first                          -> "topmost first"
#     noclip      a clip cuts nothing off                                       -> "a clip cuts"
#     nolift      the release sends no end                                      -> "the release is the lift"
#     droplean    the event of the jump home is dropped                         -> "what it is off its start"
#     noanchor    the pointer is kept at the press whatever the edge            -> "its anchor is the window"
#     clicktwice  a press that turned the wheel is a click as well              -> "neither a click nor a drag"
#     cooldown    a notch waits out the fingers' cooldown                       -> "four quick notches"
#     tabslean    a tab's notch is fed to the detent as fingers are             -> "one tab, at once"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in pixels nopieces order noclip nolift droplean noanchor clicktwice cooldown tabslean; do o=$(ARM=$a "$0" | tail -1); echo "$o"; case "$o" in *"failed as it must") ;; *) rc=1 ;; esac; done
    [ $rc = 0 ] && echo "SIDESWIPE ARMS PASS" || echo "SIDESWIPE ARMS FAIL"; exit $rc
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/ssp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
H=modules/common/scroll/WheelHub.qml S=modules/common/scroll/SideSwipe.qml
F="" A="" B="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    pixels)     F=$H; A='            : pd.x !== 0 || pd.y !== 0 ? !hub._continuous(ad.x, pd.x) && !hub._continuous(ad.y, pd.y) && (ad.x !== 0 || ad.y !== 0)'; B='            : pd.x !== 0 || pd.y !== 0 ? false'; NEEDLE="a mouse's notch" ;;
    nopieces)   F=$H; A='        s.y += ad.y;'; B='        s.y = ad.y;'; NEEDLE="add up to whole notches" ;;
    order)      F=$H; A='        out.sort((m, n) => hub._above(m.path, n.path) ? -1 : 1);'; B='        out.sort((m, n) => hub._above(m.path, n.path) ? 1 : -1);'; NEEDLE="topmost first" ;;
    noclip)     F=$H; A='if (p !== root && p.clip &&'; B='if (false &&'; NEEDLE="a clip cuts" ;;
    nolift)     F=$S; A='            ss._feed(0, 0, Qt.ScrollEnd);'; B='            ;'; NEEDLE="the release is the lift" ;;
    droplean)   F=$S; A='            ss._way(m.x - ax, m.y - ay);'; B='            ;'; NEEDLE="what it is off its start" ;;
    noanchor)   F=$S; A='        ss._anchor = near ? '; B='        ss._anchor = false ? '; NEEDLE="its anchor is the window" ;;
    clicktwice) F=$S; A=' && !ss._moved && !WheelHub.sideTurned)'; B=')'; NEEDLE="neither a click nor a drag" ;;
    cooldown)   F=modules/common/components/WheelStepper.qml; A='        if (fromPixels && now < stepper._coolUntil) {'; B='        if (now < stepper._coolUntil) {'; NEEDLE="four quick notches" ;;
    tabslean)   F=modules/common/components/TabSelector.qml; A='                    swipe.notch(wheel.steps);'; B='                    swipe.feed(120 * wheel.steps);'; NEEDLE="one tab, at once" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-side-swipe}"
printf '%s' "$A" > "$D/a"; printf '%s' "$B" > "$D/b"
if [ "${ARM:-}" = cooldown ]; then EXTRA='s = s.replace("            if (fromPixels && stepper.stepCooldownMs > 0) {", "            if (stepper.stepCooldownMs > 0) {")'; else EXTRA=pass; fi
cat > "$D/run.sh" <<RUN_EOF
if [ -n "${ARM:-}" ]; then
python3 - <<'PY' || exit 3
a, b = open("$D/a").read(), open("$D/b").read()
s = open("$F").read()
if s.count(a) != 1:
    print("ARMLOST"); raise SystemExit(1)
s = s.replace(a, b)
$EXTRA
open("$F", "w").write(s)
PY
fi
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 60 quickshell -p tools/dev/qml/side_swipe_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'SSP .*' | grep -a -v 'SSP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'SSP FAIL' | grep -a -q -F -- "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/log" 'SSP RESULT' || { echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result SIDESWIPE "$D/log" 'SSP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
if rl_clean "$D/log" | grep -a -E -q 'TypeError|ReferenceError|Binding loop|Unable to assign|Cannot assign'; then rl_clean "$D/log" | grep -a -E 'TypeError|ReferenceError|Binding loop|Unable to assign|Cannot assign' | head -5; echo "SIDESWIPE RESULT FAIL (warnings)"; exit 1; fi
printf '%s\n' "$res" | sed 's/^SSP RESULT/SIDESWIPE RESULT/'
exit $rc
