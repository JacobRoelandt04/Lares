#!/usr/bin/env bash
# aerial_holo_probe.sh -- aerial's CLOUD judged on the real popup (round 3, the signal fan; the gate row keeps its name `aerial_holo`): the placer's node cases (`aerial_holo_cases.js`), then the
# interactions -- a tag opens only after the pointer RESTS, a click is not a drag, a network dragged onto the label's Wi-Fi zone connects (the label's `hint`), a secured stranger
# hovers held, a tag let go on nothing STAYS, the docked network / the hotspot pulled off, a device dragged onto the label pairs / connects, a connected device's row pulled off disconnects
# (`carriedBt`), the globe's clicks and drags, every tag floats, 0 frames when halted. The probe is tools/dev/qml/aerial_cloud_probe.qml (it was aerial_holo_probe.qml: the dome and the
# rings it judged are gone -- its header says what went and what took each check's place).
#
#   tools/dev/aerial_holo_probe.sh [outdir]
#   ARM=norest       a tag opens at once (restMs 0) -- must FAIL (a-pass-over-the-cloud-opens-nothing)
#   ARM=clickdrag    a click starts a drag (dragSlop 0) -- must FAIL (click-is-not-a-drag)
#   ARM=cachedholo   the scene's beat feeds the cached board's light (a hologram inside the cached layer) -- must FAIL (holo-not-in-cached-layer)
#   ARM=snapback     a tag let go where there is no target springs back to its seed (the cloud keeps no offset) -- must FAIL (dropped-elsewhere-stays)
#   ARM=nohint       the label is never told what is carried (`hint`) -- must FAIL (label-hint-is-wifi-while-a-network-is-carried, the bt drops)
#   ARM=nocarriedbt  the label is never told which connected device is in the hand (`carriedBt`) -- must FAIL (carried-bt-is-set-while-a-row-is-pulled)
#   ARM=nopullbt     a connected device's row let go off the label does nothing -- must FAIL (pull-connected-device-disconnects)
#   ARM=pairalways   a stranger dropped on the label is "connected", not paired -- must FAIL (stranger-dropped-on-the-label-pairs)
#   ARM=reflight     the docking flight is begun again by every publication of the service (round 5's fault) -- must FAIL (one-flight-under-republication)
#   ARM=hoverforever a drop whose attempt failed is told nothing (the service's cue is not heard) -- must FAIL (failed-drop-drifts-back)
#   ARM=fastestname  the "fastest" light is sent as a country's name -- must FAIL (fastest-light-connects-with-no-country)
#   ARM=ownfront     a scan's front leaves the moment the scan lands, off the beat (round 5) -- must FAIL (scan-front-leaves-on-the-beat)
#   ARM=hotspotalways the hotspot's tag shows with no cable to share (round 5) -- must FAIL (hotspot-tag-hidden-without-a-cable)
#   ARM=nopending    a light's click asks the service and shows nothing until it answers (round 5) -- must FAIL (asked-light-pulses-at-once)
#   ARM=fastestagain a click on the lit "fastest" light looks for another fastest server (round 5's fault) -- must FAIL (fastest-light-again-takes-the-tunnel-down)
#   ARM=countrypanel a country's light opens the VPN panel instead of connecting -- must FAIL (country-click-connects-and-opens-no-panel)
#   ARM=nofloat      the tags' float clock does not run -- must FAIL (every-tag-floats)
#   ARM=stillticks   the cloud's clock ignores the idle ladder's still (halted) -- must FAIL (still-no-frames)
#   ARM=threshold    the globe's swipe rotates in 40 px steps (a threshold) -- must FAIL (rotate-follows-the-first-event)
#   ARM=tiltwhilerot the globe tilts on every finger delta, also in a horizontal gesture -- must FAIL (no-tilt-while-rotating)
#   ARM=bigglobe     the globe is sized against today's zoom, not round 1's -- must FAIL (globe-rest-1.3x-of-round-1, globe-rest-clear-of-card-coax-label)
#   ARM=hugegrown    the grown globe is 3.2 x its rest size -- must FAIL (globe-grown-inside-the-popup)
#   (the placer's own arms -- norelax, noseed, nobudget, wrongarc -- are aerial_holo_cases.js's: `ARM=<name> node tools/dev/aerial_holo_cases.js`)
#   ends in AERIAL_HOLO RESULT PASS|FAIL
#
# OFFSCREEN ONLY: it starts itself inside a sandbox copy (tools/dev/sandbox.sh), the platform forced on the launch, a private config / cache / state home. The arms patch the COPY.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${AHP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-holo}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen AHP_INNER=1 AHP_OUTARG="${1:-}" bash tools/dev/aerial_holo_probe.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_HOLO
OUT="${AHP_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-holo}}"
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
        norest)
            patch modules/aerial/popup/DragController.qml "property int restMs: 110" "property int restMs: 0" ;;
        clickdrag)
            patch modules/aerial/popup/DragController.qml "property real dragSlop: 5" "property real dragSlop: 0" ;;
        cachedholo)
            patch modules/aerial/scene/AerialScene.qml "property real lightAngle: 128" "property real lightAngle: 128 + root.time * 0.01" ;;
        snapback)
            patch modules/aerial/popup/DragController.qml "            root.cloud.setOffset(c.key, x + c.grab[0], y + c.grab[1]);" "            root.cloud.setOffset(c.key, c.home[0], c.home[1]);" ;;
        nohint)
            patch modules/aerial/popup/DragController.qml '        return c.kind === "bt" ? "bt" : (c.kind === "net" || c.kind === "hotspot" || c.kind === "country") ? "wifi" : "";' '        return "";' ;;
        nocarriedbt)
            patch modules/aerial/popup/DragController.qml 'readonly property string carriedBt: root._carried && root._carried.kind === "btdock" ? root._carried.key : ""' 'readonly property string carriedBt: ""' ;;
        nopullbt)
            patch modules/aerial/popup/DragController.qml '                root._send("btDisconnect", [c.key]);' '                void 0;' ;;
        pairalways)
            patch modules/aerial/popup/DragController.qml 'root._send(c.entry.paired ? "btConnect" : "btPair", [c.key]);' 'root._send("btConnect", [c.key]);' ;;
        reflight)
            patch modules/aerial/popup/DragController.qml '        if (!h || !s || !root._carried || root._phase !== "held")' '        if (!h || !s || !root._carried)' ;;
        hoverforever)
            patch modules/aerial/popup/DragController.qml '            } else if (h.kind === "net" && part === "net:" + h.key) {' '            } else if (false) {' ;;
        fastestname)
            patch modules/aerial/scene/GlobeLayer.qml '        return code === "fastest" || code === "" ? ({}) : ({ country: code });' '        return ({ country: code });' ;;
        ownfront)
            patch modules/aerial/scene/CloudHolo.qml "    onScanStampChanged: if (root.scanStamp > 0) root._boostNext = true" "    onScanStampChanged: if (root.scanStamp > 0) root.boost = true" ;;
        hotspotalways)
            patch modules/aerial/scene/CloudHolo.qml 'h.available === true && h.uplink === "cable" &&' 'h.available === true &&' ;;
        nopending)
            patch modules/aerial/scene/GlobeLayer.qml "        root.pending = code;" "        root.pending = \"\";" ;;
        fastestagain)
            patch modules/aerial/popup/AerialPopup.qml '            if (code === "fastest" && s && p && p.state === "up" && p.fastest === true) {' '            if (false) {' ;;
        countrypanel)
            patch modules/aerial/popup/AerialPopup.qml 'if (!(p && p.state === "up" && p.server && p.server.country === code)) {' 'if (false) {' ;;
        nofloat)
            patch modules/aerial/scene/CloudHolo.qml "        running: root.open && !root.halted && root.power > 0.01" "        running: false" ;;
        stillticks)
            patch modules/aerial/popup/AerialPopup.qml "        halted: root._still || !root._live || !root.animate
        scanStamp:" "        halted: false
        scanStamp:" ;;
        threshold)
            patch modules/aerial/scene/GlobeGesture.qml "engine.touch(-dx * engine.speed);" "engine.touch(-Math.round(dx / 40) * 40 * engine.speed);" ;;
        tiltwhilerot)
            patch modules/aerial/scene/GlobeGesture.qml "    function _fingers(dx: real, dy: real): void {" "    function _fingers(dx: real, dy: real): void {
        if (root.globe) root.globe.tiltLive(root.globe.tilt - dy / root.tiltRange);" ;;
        bigglobe)
            patch modules/aerial/scene/GlobeMath.js "var ROUND1_PX_PER_MM = 4.58," "var ROUND1_PX_PER_MM = 8.0," ;;
        hugegrown)
            patch modules/aerial/scene/GlobeMath.js "GROWN_OVER_REST = 2.0;" "GROWN_OVER_REST = 3.2;" ;;
        *) echo "unknown ARM=$ARM (ownfront|hotspotalways|nopending|fastestagain|reflight|hoverforever|norest|clickdrag|cachedholo|snapback|nohint|nocarriedbt|nopullbt|pairalways|countrypanel|fastestname|nofloat|stillticks|threshold|tiltwhilerot|bigglobe|hugegrown)"; exit 2 ;;
    esac
fi

LOG="$OUT/probe.log"
node=$(env -u ARM node tools/dev/aerial_holo_cases.js 2>&1); nrc=$?
echo "$node" | grep -a "^AH \|AERIAL_HOLO_CASES"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
    OUT="$OUT" timeout 240 quickshell -n -p tools/dev/qml/aerial_cloud_probe.qml > "$LOG" 2>&1
rl_clean "$LOG" | grep -a "AH " | sed 's/^.*AH /AH /' | grep -a -v "^AH RESULT"
# the QML's own warnings are failures: a binding loop or an undefined assignment hides the next real one
warns=$(rl_clean "$LOG" | rl_platform_noise | grep -a -i "WARN\|binding loop\|Unable to assign\|TypeError\|ReferenceError" | grep -a -v "AH " | sort -u | head -8)
if ! rl_clean "$LOG" | grep -a -q "AH RESULT"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"
    rl_noresult "$NAME" "$LOG"; exit 1
fi
probe=$(rl_clean "$LOG" | grep -a "AH RESULT" | tail -1)
hues="n/a"
if [ -z "${ARM:-}" ]; then
    hues=$(tools/dev/bar_hues_table.sh 2>&1 | tail -1)
    echo "  $hues"
fi
[ -n "$warns" ] && { echo "WARNINGS:"; echo "$warns"; }
case "$probe" in *"RESULT PASS"*) pp=1 ;; *) pp=0 ;; esac
case "$hues" in *PASS*|n/a) hp=1 ;; *) hp=0 ;; esac
if [ $pp = 1 ] && [ $nrc = 0 ] && [ $hp = 1 ] && [ -z "$warns" ]; then
    echo "$NAME RESULT PASS (${ARM:+ARM $ARM: }placement, rest, drags, bluetooth, globe, float, frames; hue roles on every theme)"
    exit 0
fi
echo "$NAME RESULT FAIL ($probe; node cases rc=$nrc; hues: $hues${warns:+; QML warnings})"
exit 1
