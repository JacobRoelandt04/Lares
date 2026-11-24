#!/usr/bin/env bash
# bridge_popup_probe.sh -- the bridge's popup (modules/bridge/BridgePopup.qml and screen/, back/; docs/contracts/bridge.md) on the REAL
# popup and the REAL BridgeService (not live: nothing runs, the mock scenarios' lines go through the real parser, every action is recorded
# in `calls`), in an offscreen window, driven with real synthetic input through the window (QtTest, diagonal wheels). Nothing touches a
# phone, adb, KDE Connect or a daemon: the service is not live, the session bus is a private one, the state / config / cache homes are
# private, the compositor is none.
#
#   tools/dev/bridge_popup_probe.sh             BRIDGE_POPUP RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/bridge_popup_probe.sh  fails on the arm's own check (prints `ARM <name>: failed as it must`)
#   ARM=all tools/dev/bridge_popup_probe.sh     every arm; `BRIDGE_POPUP ARMS PASS | FAIL`
#
# The checks are in tools/dev/qml/bridge_popup_probe.qml (A scenarios, B tiles, C the Mirror page, D the swipe's role, E Escape, F input
# after the turns, G the body's keys, H a drop, K the details behind the device menu, L the light the pointer leads, M free look). The log is held to NO warning that names a bridge file, a binding loop or an assignment of
# undefined. ARMs (each patches the sandbox COPY; the named check must fail, and nothing else is a pass):
#   tworeaders  a second wheel reader that turns the phone while a page scrubs (and the stage allowed to turn)  -> "D2: the stage does not turn while a page scrubs"
#   escboth     Escape goes back AND returns false (the popup then closes under the going back)                -> "E2: Escape on a page goes back and the popup stays"
#   noblock     the reader is not blocked while a committed back plays out: a second back starts under it     -> "E4: a committed back is not taken over by the fingers that carry on"
#   noconfirm   Ring rings on the first click again (no arming, no hold)                                          -> "R1: a click on Ring only arms it"
#   lightjump   the pointer's light never chases: it jumps to a pointer that comes in at another side           -> "L1: a pointer that comes in far from the light does not take the light there at once"
#   escfield    Escape on the Details page skips the open PIN field (goes back over it)                             -> "P2: Escape closes the field first"
#   recordwindow  Mirror with Record on goes to scrcpy's window again (the page's old exclusion)                     -> "C5: with Record on, Start on Mirror casts in the popup"
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BPP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-popup}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-bridge-popup}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi BPP_INNER=1 ARM="${ARM:-}" bash tools/dev/bridge_popup_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="BRIDGE_POPUP"
P=modules/bridge/BridgePopup.qml

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

run_once() {
    local tree log out rc
    tree=$(mktemp -d "$SCRATCH/bpp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        tworeaders)
            # the second reader sits above the real one and turns the phone on every sideways wheel; the stage may turn
            arm "$tree/$P" '        canFlip: !screenFace.pageOpen && !screenFace.morphing' '        canFlip: true' || return 3
            arm "$tree/$P" '    // ---- what floats over everything' '    MouseArea {
        anchors.fill: parent
        z: 890
        acceptedButtons: Qt.NoButton
        propagateComposedEvents: true
        onWheel: wheel => {
            if (wheel.angleDelta.x !== 0)
                stage.scrubTo(0.5);
            wheel.accepted = false;
        }
    }

    // ---- what floats over everything' || return 3 ;;
        escboth)
            arm "$tree/$P" '            screenFace.goBack();
            return true;' '            screenFace.goBack();
            return false;' || return 3 ;;
        noblock)
            arm "$tree/$P" '        blocked: !swipe.active && (stage.flipping || screenFace.backCommitted)' '        blocked: false' || return 3 ;;
        noconfirm)
            arm "$tree/modules/bridge/screen/HomeScreen.qml" '            if (info.ok && !home._ringArmed) {
                home._ringArmed = true;
                ringDisarm.restart();
            }' '            if (info.ok)
                svc.ring(dev.key);' || return 3 ;;
        lightjump)
            arm "$tree/modules/bridge/body/PhoneStage.qml" '> stage.relightJump) {' '> 1.0e9) {' || return 3 ;;
        escfield) arm "$tree/modules/bridge/BridgePopup.qml" '        if (screenFace.cancelEdit())
            return true;
' '' || return 3 ;;
        nokeys)
            # the popup never asks for the keyboard off the cast page: no modifier would reach it on the desktop
            arm "$tree/$P" 'screenFace.keysWanted || popup._keysAsked ? "onDemand"' 'screenFace.keysWanted ? "onDemand"' || return 3 ;;
        lookclicks)
            # the cover that makes the faces deaf does not count a look as a motion
            arm "$tree/modules/bridge/body/PhoneStage.qml" '            visible: stage._moving
            acceptedButtons: Qt.AllButtons' '            visible: stage._turning || stage._pinned
            acceptedButtons: Qt.AllButtons' || return 3 ;;
        noreset)
            # let go, the phone stays where the look left it
            arm "$tree/modules/bridge/body/PhoneStage.qml" '            stage.lookStrayed();
        lookBackRun.restart();' '            stage.lookStrayed();' || return 3 ;;
        longway)
            # the way back unwinds the whole turn instead of going on to the nearest whole one
            arm "$tree/modules/bridge/body/PhoneStage.qml" '(Math.round(stage._lookYaw0) - stage._lookYaw0) * stage._lookT' '(0 - stage._lookYaw0) * stage._lookT' || return 3 ;;
        altonly)
            # bridge.jsonc lookKey ignored: Alt holds the look whatever the file says
            arm "$tree/$P" 'readonly property string lookKey: popup.service && popup.service.settings.lookKey ? popup.service.settings.lookKey : "alt"' 'readonly property string lookKey: "alt"' || return 3 ;;
        recordwindow)
            arm "$tree/modules/bridge/screen/MirrorPage.qml" '    readonly property bool _castMode: page._mode === "mirror" || page._mode === "desktop"' '    readonly property bool _castMode: (page._mode === "mirror" || page._mode === "desktop") && wish.value("record") !== true' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/xdg/cache" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    log="$tree/run.log"
    ( cd "$tree" && env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" \
        tools/dev/notifications_bus.sh timeout -k 2 140 quickshell -n -p tools/dev/qml/bridge_popup_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "BRIDGE_POPUP RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | rl_platform_noise | grep -a "BP FAIL" | head -12
    [ -n "${BPP_VERBOSE:-}" ] && rl_clean "$log" | rl_platform_noise | grep -a -E "BP |WARN|ERROR"
    # (h) a warning that names this module, a binding loop, or an assignment of undefined is a failure of its own
    bad=$(rl_clean "$log" | rl_platform_noise | grep -a -E "WARN|ERROR" \
        | grep -a -E "modules/bridge|bridge_popup_probe|TileButton|MorphCard|MorphClock|SwipeScrub|Binding loop|Unable to assign|non-existent|is not a type|ReferenceError|TypeError|Cannot (read|assign|call)" \
        | grep -a -v -E "a line was refused|the tool is missing|the previous settings are kept" | head -6)
    if [ -n "$bad" ]; then
        echo "BP FAIL h: the log holds a warning that names the bridge (or a loop / an undefined):"
        printf '%s\n' "$bad" | sed 's/^/    /'
        rc=1
    fi
    rl_isnoresult "$out" || rm -rf "$tree"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([tworeaders]="D2" [escboth]="E2" [noblock]="E4" [lightjump]="L1" [noconfirm]="R1" [escfield]="P2" [nokeys]="M1" [lookclicks]="M5" [noreset]="M7" [longway]="M8" [altonly]="M11" [recordwindow]="C5")
    for a in ${ONLY_ARMS:-tworeaders escboth noblock lightjump noconfirm escfield nokeys lookclicks noreset longway altonly recordwindow}; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aqE "BP FAIL ${NEED[$a]}:"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check (${NEED[$a]}): $(printf '%s\n' "$o" | grep -a 'BP FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
if rl_isnoresult "$out"; then
    printf '%s\n' "$out"
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
# the probe's own count, the runner's verdict (the log scan may fail a run whose checks all passed)
cnt=$(printf '%s\n' "$out" | grep -a -o '([0-9]*/[0-9]* checks)' | tail -1)
printf '%s\n' "$out" | grep -a -v "RESULT"
if [ -n "${ARM:-}" ]; then
    need=""
    case "$ARM" in tworeaders) need="D2" ;; escboth) need="E2" ;; noblock) need="E4" ;; lightjump) need="L1" ;; esac
    if printf '%s\n' "$out" | grep -aqE "BP FAIL $need:"; then echo "ARM $ARM: failed as it must ($need)"; exit 0; fi
    echo "ARM $ARM: did not fail at $need -- the probe cannot see it"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL) $cnt"
exit $rc
}
