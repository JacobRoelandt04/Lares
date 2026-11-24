#!/usr/bin/env bash
# oled_shift_probe.sh -- the OLED care: the bars' content steps a whole device pixel through nine places and the islands' free ends step
# with it (the corners, the thickness, the slim bars and the reserve stay), waits for what is out, keeps the reel's strip level with its
# cell, survives a restart (tools/dev/qml/oled_shift_probe.qml, on the MOCK shell, offscreen), and the pictures of the islands' voids and
# joints at three places are the centre's moved by exactly the step / unmoved (tools/dev/oled_shift_pixels.py).
#
#   tools/dev/oled_shift_probe.sh                 OLED_SHIFT RESULT PASS | FAIL, at scale 1 and at 1.25
#   SCALES="1.5" tools/dev/oled_shift_probe.sh    other scales
#   GRABS_OUT=<dir> tools/dev/oled_shift_probe.sh keep the pictures and geom-<scale>.json there (the sheet: oled_shift_pixels.py sheet)
#   SHELL_JSONC=<file>                            the mock's shell.jsonc (default: the shell's edge as the user has it: a halo and the ring)
#   ARM=<name> tools/dev/oled_shift_probe.sh      one fault in a SANDBOX copy; it must FAIL on its check's own needle
#   ARM=all                                       every arm (ONLY_ARMS="a b" narrows it)
#     nodefer    OledShift takes a step whatever is out              -> "defer: with a popup out the step waits"
#     nostrip    ShellFrame does not hold for the reel's strip        -> "strip: a step asked while the strip is out waits"
#     halfpixel  the step is half a device pixel                      -> "stands at (1,0) device px"
#     moveisland the left island's corner end moves with the content -> "(corner) end moved"
#     nofollow   the islands' free ends do not follow the step         -> "(free) end moved"
#     rowtwice   the centre and right rows take the step on top of their island's -> "the room between each free end and its module"
#     nohold     a step in a lengths move leaves the held input rect   -> "hold: a step taken while the island lengths move"
#     nopersist  the state is never written                           -> "a second OledShift on the same file starts where the first stood"
#     noshiftkey shell.jsonc's oled.shift is ignored -> "shift: its own switch"
#     noconfig   shell.jsonc's oled.enabled is ignored (OledShift stays on) -> "off: the config switch puts the content back at the centre"
#
# Private XDG dirs (the mock keeps its state under $XDG_STATE_HOME), the theme state seeded so nothing of the user's desktop moves.
# A run that printed no RESULT (a QML that did not load) stops there, keeps its work dir and names the log that holds the error
# (tools/dev/runner_noload_check.sh); KEEP=1 keeps it always.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh

if [ -e .git ] && [ -z "${OLEDSHIFT_INNER:-}" ]; then
    export OLEDSHIFT_INNER=1
    exec tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen OLEDSHIFT_INNER=1 ARM="${ARM:-}" ONLY_ARMS="${ONLY_ARMS:-}" SCALES="${SCALES:-}" KEEP="${KEEP:-}" GRABS_OUT="${GRABS_OUT:-}" SHELL_JSONC="${SHELL_JSONC:-}" bash tools/dev/oled_shift_probe.sh "$@"
fi

SCALES="${SCALES:-1 1.25}"
D="$(mktemp -d "${SCRATCH:-/tmp}/oledshift.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT

arm_needle() {
    case $1 in
        nodefer) echo "defer: with a popup out the step waits" ;;
        nostrip) echo "strip: a step asked while the strip is out waits" ;;
        halfpixel) echo "stands at (1,0) device px" ;;
        moveisland) echo "(corner) end moved" ;;
        nofollow) echo "(free) end moved" ;;
        rowtwice) echo "the room between each free end and its module" ;;
        nohold) echo "hold: a step taken while the island lengths move" ;;
        nopersist) echo "a second OledShift on the same file starts where the first stood" ;;
        noshiftkey) echo "shift: its own switch" ;;
        noconfig) echo "off: the config switch puts the content back at the centre" ;;
    esac
}
patch() {   # patch <file> <old> <new>: exactly one match, or the run says so
    python3 - "$1" "$2" "$3" << 'PY' || { echo "OLEDSHIFT ARM anchor gone: $1"; exit 3; }
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1:
    sys.exit(1)
open(f, "w").write(s.replace(old, new))
PY
}
arm_apply() {
    case $1 in
        nodefer) patch modules/shell/OledShift.qml 'if (root._heldCount > 0 || !root._isPending())' 'if (!root._isPending())' ;;
        nostrip) patch modules/shell/ShellFrame.qml 'e.childPopups[2], e.theReel].concat(e.reelChildPopups)' 'e.childPopups[2]].concat(e.reelChildPopups)' ;;
        halfpixel) patch modules/shell/ShellFrame.qml 'frame.services.oled.dx / Math.max(0.01, frame.renderScale)' 'frame.services.oled.dx * 0.5 / Math.max(0.01, frame.renderScale)'
                   patch modules/shell/ShellFrame.qml 'frame.services.oled.dy / Math.max(0.01, frame.renderScale)' 'frame.services.oled.dy * 0.5 / Math.max(0.01, frame.renderScale)' ;;
        moveisland) patch modules/shell/ShellFrame.qml 'barId: "topL"
            edge: "top"
            visible: !!s
            rawPos: s ? s.rawPos : 0' 'barId: "topL"
            edge: "top"
            visible: !!s
            rawPos: (s ? s.rawPos : 0) + frame.services.oled.dx' ;;
        nofollow) patch modules/shell/ShellFrame.qml 'frame.slim, frame.barRatio, frame.oledX) : []' 'frame.slim, frame.barRatio, 0) : []' ;;
        rowtwice) patch modules/shell/ShellFrame.qml ': (row.zone === "left" ? frame.oledX : 0)' ': frame.oledX' ;;
        nohold) patch modules/shell/ShellFrame.qml '        if (frame.lenT < 1 && frame.maskHold)
            frame.maskHold = Layout.maskUnion(' '        if (false)
            frame.maskHold = Layout.maskUnion(' ;;
        nopersist) patch modules/shell/OledShift.qml 'if (root.statePath !== "")
            stateFile.setText(' 'if (false)
            stateFile.setText(' ;;
        noshiftkey) patch modules/shell/ShellConfig.qml 'root.oledEnabled && root.checked.oled.shift' 'root.oledEnabled' ;;
        noconfig) patch modules/shell/ShellServices.qml 'on: shellConfigItem.oledShift' 'on: true' ;;
    esac
}

run_one() {   # run_one <scale> <log> <grabs dir>
    local sc=$1 log=$2 grabs=$3 priv
    priv=$(mktemp -d "$D/w.XXXXXX")
    mkdir -p "$priv/config/theme" "$priv/state/lares-shell-mock/config" "$grabs"
    cp "${XDG_CONFIG_HOME:-$HOME/.config}/theme/state.json" "$priv/config/theme/state.json" 2> /dev/null || printf '{"theme":"eva","mode":"light"}\n' > "$priv/config/theme/state.json"
    # the mock's shell.jsonc (ShellServices.configDir): the shell's edge the user has (a halo, the ring), written here, not read from home
    if [ -n "${SHELL_JSONC:-}" ]; then
        cp "$SHELL_JSONC" "$priv/state/lares-shell-mock/config/shell.jsonc"
    else
        printf '{ "shadow": { "mode": "halo" }, "border": true }\n' > "$priv/state/lares-shell-mock/config/shell.jsonc"
    fi
    env -u WAYLAND_DISPLAY XDG_STATE_HOME="$priv/state" XDG_CONFIG_HOME="$priv/config" SHELL_SERVICES=mock QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        SCALE="$sc" OLEDSHIFT_GRABS="$grabs" timeout 240 quickshell -p tools/dev/qml/oled_shift_probe.qml > "$log" 2>&1
}
# the pictures (oled_shift_pixels.py judge), their lines into the log so an arm's needle and the verdict see them; kept when GRABS_OUT asks
pixels() {   # pixels <scale> <log> <grabs dir>
    local rc=0
    python3 tools/dev/oled_shift_pixels.py judge --log "$2" --grabs "$3" --scale "$1" >> "$2" 2>&1 || rc=1
    if [ -n "${GRABS_OUT:-}" ]; then mkdir -p "$GRABS_OUT" && cp "$3"/* "$GRABS_OUT"/ 2> /dev/null; fi
    return $rc
}

judge() {   # judge <arm|""> <scales...>
    local arm=$1 sc rc=0 log needle n
    shift
    if [ -n "$arm" ]; then arm_apply "$arm" || return 3; fi
    for sc in "$@"; do
        log="$D/log.$sc"
        run_one "$sc" "$log" "$D/grabs.$sc"
        pix=0
        if rl_has "$log" 'OLEDSHIFT RESULT'; then pixels "$sc" "$log" "$D/grabs.$sc" || pix=1; fi
        rl_clean "$log" | grep -a -o 'OLEDSHIFT .*' | grep -a -v 'OLEDSHIFT RESULT' | grep -a -E "$([ -n "${VERBOSE:-}" ] && echo . || echo '^OLEDSHIFT FAIL|ARM')" || true
        if [ -n "$arm" ]; then
            needle=$(arm_needle "$arm")
            if rl_clean "$log" | grep -a -q 'OLEDSHIFT ARM anchor gone'; then echo "ARM $arm: the anchor is gone"; return 1; fi
            if ! rl_has "$log" 'OLEDSHIFT RESULT'; then KEEP_D=1; echo "ARM $arm: the armed copy did not load -- it proves nothing ($log)"; return 1; fi
            if rl_clean "$log" | grep -a "OLEDSHIFT FAIL" | grep -aqF -- "$needle"; then echo "ARM $arm (scale $sc): failed as it must ('$needle')"; return 0; fi
            echo "ARM $arm (scale $sc): DID NOT FAIL on '$needle'"; rl_clean "$log" | grep -a "OLEDSHIFT FAIL" | head -3; return 1
        fi
        res=$(rl_result OLED_SHIFT "$log" 'OLEDSHIFT RESULT .*') || rc=1
        # the pictures' verdict joins the probe's: a PASS with a red picture is a FAIL
        if [ "$pix" = 1 ] && printf '%s' "$res" | grep -q 'RESULT PASS'; then res="OLED_SHIFT RESULT FAIL (the pictures: $(rl_clean "$log" | grep -a -c 'OLEDSHIFT FAIL pixels') bands off; scale $sc)"; rc=1; fi
        printf '%s\n' "$res" | sed 's/^OLEDSHIFT RESULT/OLED_SHIFT RESULT/'
        # no RESULT: the copy did not load, and the next scale would only say so again over the log that names why
        if rl_isnoresult "$res"; then KEEP_D=1; return 1; fi
    done
    return $rc
}

if [ -n "${ARM:-}" ]; then
    if [ "$ARM" = all ]; then
        # one fault at a time: every arm starts from the copy as it came (an arm patches in place, and the next one must not carry it)
        bad=0
        armed="modules/shell/ShellFrame.qml modules/shell/OledShift.qml modules/shell/ShellServices.qml"
        mkdir -p "$D/pristine"
        for f in $armed; do cp "$f" "$D/pristine/$(basename "$f")"; done
        for a in ${ONLY_ARMS:-nodefer nostrip halfpixel moveisland nofollow rowtwice nohold nopersist noshiftkey noconfig}; do
            for f in $armed; do cp "$D/pristine/$(basename "$f")" "$f"; done
            ( cd "$(pwd)" && ARM=$a OLEDSHIFT_INNER=1 bash tools/dev/oled_shift_probe.sh ) || bad=1
        done
        for f in $armed; do cp "$D/pristine/$(basename "$f")" "$f"; done
        exit $bad
    fi
    judge "$ARM" ${SCALES%% *}
    exit $?
fi
judge "" $SCALES
