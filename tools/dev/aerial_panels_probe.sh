#!/usr/bin/env bash
# aerial's detail panels, clicked like a person, headless, in the sandbox (tools/dev/qml/aerial_panels_probe.qml): real synthetic clicks on every
# button / switch / choice of every panel over AerialMock through a recording tap -> the data layer receives the right intent with the right
# arguments; the password field takes focus when it should, Enter / Escape; the secret is not kept after the panel closes.
#
#   tools/dev/aerial_panels_probe.sh               last line: AERIAL_PANELS RESULT PASS|FAIL
#   ARM=<name> tools/dev/aerial_panels_probe.sh    a fault put into the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/aerial_panels_probe.sh       every ARM below; AERIAL_PANELS ARMS PASS when each one failed on ITS check
#
#     nofocus       the password field is not given the keys                    -> net.pw.focus FAILS
#     keepsecret    the panel writes a revealed secret away as it closes        -> net.share.close.keeps.nothing FAILS
#     wrongintent   Disconnect calls another intent (disconnectWired)           -> net.disconnect FAILS
#     forgetnow     Forget acts on the first click (no arm), saved AND Bluetooth -> saved.forget.arm + bt.forget.arm FAIL
#     forgetstays   a Forget arm never falls back                                -> saved.forget.fallback + bt.forget.fallback FAIL
#
# Nothing here touches the machine: the mock has no process, file or bus; private XDG dirs; `echo` / `true` stand in for the file picker and
# nm-connection-editor.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_PANELS
declare -A NEEDLE=([nofocus]='net.pw.focus' [keepsecret]='net.share.close.keeps.nothing' [wrongintent]='net.disconnect' [nosearchesc]='saved.search.esc.clears' [forgetnow]='saved.forget.arm bt.forget.arm' [forgetstays]='saved.forget.fallback bt.forget.fallback')
if [ "${ARM:-}" = all ] && [ -z "${AP_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nofocus keepsecret wrongintent nosearchesc forgetnow forgetstays}; do
        sb="/tmp/lares-sbx-aerial-p-arm-$a"
        # each arm in a FRESH copy of the tree this stands in -- also inside a gate's box copy, which has no .git, so the runner would
        # not re-exec and every arm would patch the same copy (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AP_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_panels_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        else
            miss=""
            for n in ${NEEDLE[$a]}; do printf '%s\n' "$res" | grep -q "AP FAIL $n:" || miss="$miss $n"; done
            if [ -n "$miss" ]; then echo "  ARM $a: failed, but NOT on$miss: $(printf '%s\n' "$res" | grep 'AP FAIL' | head -3 | tr '\n' ';')"; bad=1
            else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'AP FAIL') red, incl. ${NEEDLE[$a]})"; fi
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${AP_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-p}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AP_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_panels_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/aerial_panels.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [ -n "$ARM" ]; then
    [ -e .git ] && { echo "refusing to arm the real tree"; exit 2; }
    arm() { python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: anchor not found exactly once in $1"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
    }
    N=modules/aerial/secondary/NetworkPanel.qml
    case "$ARM" in
        nofocus) arm $N '            else if (panel.needsPassword)
                pwBlock.field.forceFocus();' '            else if (panel.needsPassword)
                void 0;' ;;
        keepsecret) arm $N '    Component.onDestruction: panel.secretText = ""' '    Component.onDestruction: {
        if (panel.vm)
            panel.vm.leaked = panel.secretText;
        panel.secretText = "";
    }' ;;
        wrongintent) arm $N 'onClicked: if (panel.vm) panel.vm.disconnect()' 'onClicked: if (panel.vm) panel.vm.disconnectWired("x")' ;;
        nosearchesc) arm modules/aerial/secondary/SavedPanel.qml '        if (searchField.text !== "") {
            searchField.clear();
            return true;
        }' '        if (false) {
            return true;
        }' ;;
        forgetnow) arm modules/aerial/secondary/ForgetButton.qml '        if (!btn.armed) {' '        if (false) {' ;;
        forgetstays) arm modules/aerial/secondary/ForgetButton.qml '        onTriggered: btn.armed = false' '        onTriggered: void 0' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-240} quickshell -n -p "$(pwd)/tools/dev/qml/aerial_panels_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: AP .*' | sed 's/^qml: //'
rl_has "$log" 'qml: AP DONE (PASS|FAIL)' || { cp "$log" "$SCR/aerial_panels_last.log" 2> /dev/null; rl_noresult "$NAME" "$log"; exit 1; }
fail=0
rl_has "$log" 'qml: AP DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: AP ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "AP warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/aerial_panels_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
