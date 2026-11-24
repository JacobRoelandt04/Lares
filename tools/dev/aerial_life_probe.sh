#!/usr/bin/env bash
# aerial_life_probe.sh -- the popup's life judged: every part opens its panel and a second click closes it, Escape closes the panel first and then the popup, the password flow with
# real synthetic keys, the pairing prompt opening itself, the speed test's two-click confirm and what the displays say, the idle ladder reaching still with 0 frames, the power-on
# ending at the facts' pose, the moments the sounds follow.
#
#   tools/dev/aerial_life_probe.sh [outdir]
#   ARM=calmrests the scene rests at the ladder's MIDDLE rung -- must FAIL (the-middle-rung-changes-nothing)
#   ARM=noease    the halt stops the motion at once (no ease to rest) -- must FAIL (the-halt-eases-to-rest)
#   ARM=norest    the scene never comes to rest -- must FAIL (the-halt-eases-to-rest / ladder-still)
#   ARM=escstep   the popup puts its panel away on Escape itself (the old stepped Escape, whatever shell.jsonc says) -- must FAIL (esc-leaves-the-panel-to-the-engine)
#   ARM=onecheck  a click on the rates display asks AND runs the test -- must FAIL (one-click-asks-only)
#   ARM=nofocus   the popup never asks the keyboard for a panel's field -- must FAIL (popup-asks-for-the-keyboard)
#   ARM=tagback   an error tag is drawn again in the popup -- must FAIL (no-error-tag-ever)
#   ARM=escskip   Escape closes the saved panel with a search typed, without clearing it first -- must FAIL (esc-clears-the-search-first)
#   ARM=offscreen the panel's side is never judged against the screen: a popup at the screen's left end puts its detail off the screen -- must FAIL (left.*.inside-the-screen)
#   ARM=grabkeys  a mouse-opened saved panel asks for the keys at once -- must FAIL (mouse-opened-saved-takes-no-keys)
#   ARM=hoverfade the hover hull (a fill on the part under the pointer) is drawn again -- must FAIL (no-hover-fade)
#   ARM=noengrave the speed test's question is not engraved (the board keeps its plain RATE label) -- must FAIL (the-question-is-engraved)
#   ARM=badword   the display logic engraves a word the board has no variant for -- must FAIL (engraving-words-are-baked-variants)
#   ARM=noshakekey a failed intent's cue does not name the cloud's tag (`shakeKey`) -- must FAIL (cue-net-tag-shakes, cue-device-shakes)
#   ARM=nolabelcue a connected device's cue (it lives on the label, not in the air) shakes nothing -- must FAIL (cue-connected-device-shakes-the-label)
#   ROUND 3 re-aim: the power-on is one clock (`cloudP` replaced `domeP` / `ringsP`); the idle ladder, the escapes and the panels stand; the cues name tags of the cloud
#   (`cue("net:<key>")` / `cue("bt:<address>")` -> `cloudLayer.shakeKey`, a connected device's cue shakes the label); the speed test's engraving is read from the scene's
#   `ratesVariant` / `usageVariant` through AerialGeometry SILK_VARIANTS (the board's lettering is a texture now: no Text carries it) and every word SpeedDisplay can engrave is checked to be a baked variant.
#   ends in AERIAL_LIFE RESULT PASS|FAIL; a second run (tools/dev/qml/aerial_side_probe.qml, `AS` lines) judges where the detail lands in the real engine
#
# OFFSCREEN ONLY: it starts itself inside a sandbox copy (tools/dev/sandbox.sh), the platform forced on the launch, a private config / cache / state home. The arms patch the COPY.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${ALP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-life}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen ALP_INNER=1 ALP_OUTARG="${1:-}" bash tools/dev/aerial_life_probe.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_LIFE
OUT="${ALP_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-life}}"
mkdir -p "$OUT/cfg/theme" "$OUT/cache" "$OUT/state"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$OUT/cfg/theme/state.json"

patch() {  # <file> <old> <new>: exactly one anchor, or the arm does not exist
    python3 - "$1" "$2" "$3" <<'PY' || { echo "$NAME RESULT FAIL (arm anchor: $1)"; exit 2; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("anchor %r: %d" % (a, s.count(a)))
open(p, "w").write(s.replace(a, b))
PY
}
if [ -n "${ARM:-}" ]; then
    [ -e .git ] && { echo "$NAME RESULT FAIL (ARM in a git tree)"; exit 2; }
    case "$ARM" in
        escstep)
            patch modules/aerial/popup/AerialPopup.qml "            if (sec && sec.handleEscape())
                return true;
        }
        return false;" "            if (sec && sec.handleEscape())
                return true;
            root.closeSecondary();
            return true;
        }
        return false;" ;;
        onecheck)
            patch modules/aerial/popup/AerialPopup.qml "        s.armSpeedTest();
        armTimer.restart();" "        s.armSpeedTest();
        s.runSpeedTest();
        armTimer.restart();" ;;
        nofocus)
            patch modules/aerial/popup/AerialPopup.qml 'root._secKeys && root.secondaryOpen ? "onDemand" : "none"' '"none"' ;;
        tagback)
            patch modules/aerial/popup/AerialPopup.qml "    Timer {
        // the question is forgotten if the second click does not come" "    ErrorTag {
        text: \"armed\"
        overlayItem: root
    }
    Timer {
        // the question is forgotten if the second click does not come" ;;
        escskip)
            patch modules/aerial/popup/AerialPopup.qml "if (sec && sec.handleEscape())" "if (false)" ;;
        offscreen)
            patch modules/aerial/popup/AerialPopup.qml "root._sideNow = root._fitSide(root.sidePreference);" "root._sideNow = root.sidePreference;" ;;
        grabkeys)
            patch modules/aerial/popup/AerialPopup.qml "(!sec.optionalKeys || root._byKey || sec._moved)" "true" ;;
        hoverfade)
            patch modules/aerial/popup/AerialPopup.qml "    // ---- the input, by arithmetic ----" "    Shape {
        anchors.fill: boardScene
        opacity: root.hoverIntent !== \"\" ? 1 : 0
        ShapePath {
            fillColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.20)
            strokeColor: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
            strokeWidth: 1
        }
    }
    // ---- the input, by arithmetic ----" ;;
        noengrave)
            patch modules/aerial/popup/AerialPopup.qml 'silkTexts: root._engraving !== "" ? ({ rates: root._engraving }) : ({})' 'silkTexts: ({})' ;;
        badword)
            patch modules/aerial/popup/SpeedDisplay.js 'return "SURE? - MB";' 'return "SURE? 200 MB";' ;;
        noshakekey)
            patch modules/aerial/popup/AerialPopup.qml 'shakeKey: root._shakeWho.indexOf("net:") === 0 ? root._shakeWho.slice(4) : root._shakeWho.indexOf("bt:") === 0 ? root._shakeWho.slice(3) : ""' 'shakeKey: ""' ;;
        nolabelcue)
            patch modules/aerial/popup/AerialPopup.qml 'root._shake(cloudLayer.tagOf(part.slice(part.indexOf(":") + 1)) ? part : "label", 3);' 'root._shake(cloudLayer.tagOf(part.slice(part.indexOf(":") + 1)) ? part : "", 3);' ;;
        calmrests)
            patch modules/aerial/popup/AerialPopup.qml '        resting: root._halt' '        resting: ladder.level !== "alive"' ;;
        noease)
            patch modules/aerial/scene/AerialScene.qml '    property real restSeconds: 1.0' '    property real restSeconds: 0.0001' ;;
        norest)
            patch modules/aerial/scene/AerialScene.qml '    readonly property bool atRest: root.resting && (root._p <= 0 || !root._wants)' '    readonly property bool atRest: false' ;;
        *) echo "unknown ARM=$ARM (escstep|onecheck|nofocus|tagback|escskip|offscreen|grabkeys|hoverfade|noengrave|badword|noshakekey|nolabelcue|calmrests|noease|norest)"; exit 2 ;;
    esac
fi

LOG="$OUT/probe.log"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
    OUT="$OUT" timeout 280 quickshell -n -p tools/dev/qml/aerial_life_probe.qml > "$LOG" 2>&1
# the second run: the detail's place in the real engine (one quickshell at a time: a second entry file next to a running one starts a re-link storm)
LOG2="$OUT/side.log"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
    OUT="$OUT" timeout 200 quickshell -n -p tools/dev/qml/aerial_side_probe.qml > "$LOG2" 2>&1
rl_clean "$LOG2" | grep -a "^AS \|AS " | sed 's/^.*AS /AS /' | grep -a -v "^AS RESULT" | grep -a "FAIL\|tallest"
rl_clean "$LOG" | grep -a "AL " | sed 's/^.*AL /AL /' | grep -a -v "^AL RESULT"
# the QML's own warnings are failures: a binding loop or an undefined assignment hides the next real one
warns=$({ rl_clean "$LOG"; rl_clean "$LOG2"; } | rl_platform_noise | grep -a -i "WARN\|binding loop\|Unable to assign\|TypeError\|ReferenceError" | grep -a -v "AL \|AS " | sort -u | head -8)
if ! rl_clean "$LOG" | grep -a -q "AL RESULT"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"
    rl_noresult "$NAME" "$LOG"; exit 1
fi
probe=$(rl_clean "$LOG" | grep -a "AL RESULT" | tail -1)
if ! rl_clean "$LOG2" | grep -a -q "AS RESULT"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG2)"
    rl_noresult "$NAME" "$LOG2"; exit 1
fi
side=$(rl_clean "$LOG2" | grep -a "AS RESULT" | tail -1)
[ -n "$warns" ] && { echo "WARNINGS:"; echo "$warns"; }
case "$probe" in *"RESULT PASS"*) pp=1 ;; *) pp=0 ;; esac
case "$side" in *"RESULT PASS"*) ;; *) pp=0; probe="$probe / $side" ;; esac
if [ $pp = 1 ] && [ -z "$warns" ]; then
    echo "$NAME RESULT PASS (${ARM:+ARM $ARM: }parts, escape, password, prompt, speed test, ladder, power-on, sounds)"
    exit 0
fi
echo "$NAME RESULT FAIL ($probe${warns:+; QML warnings})"
exit 1
