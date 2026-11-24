#!/usr/bin/env bash
# aerial_scene_probe.sh -- aerial's board scene, judged: the pick of every part (at rest and with the card tilted and the screw out), the renders of every scenario in both families, the
# live label (QML on the shield plane, the real MACs in the Bluetooth zone, whole device pixels), the coax arches ending on their grommets, the lights outside the cached layer, the patch
# scheme, 0 frames when still -- and, round 3, the BOARD'S OWN pixels (tools/dev/aerial_scene_pixels.py): the names carved by the shader, the unit labels following their variants, the latches'
# emblems lit by the radio, the glow's pulses hidden by the lifted card. Also run first: aerial_facts_cases.js and `make_silk.py --check` (no name stands where a part can cover it).
#
# ROUND 3 re-aim (what went and why): the old "label-is-baked / label-name" checks stand (the label is still QML); the old coax checks (a notch, `COAX.end`, the connectors' projection) became "each
# cable's arch ends on its grommet / leaves its connector's back" (the notch is gone); `ARM=endcut` etc. keep their anchors; the checks that restated the round-2 label (a small print of
# 12 lines at a fixed place, the name between 30 and 48 px) follow the new label (three bands; the name 30..60 px).
#
#   tools/dev/aerial_scene_probe.sh [outdir]
#   SCENARIOS="home airplane"   only these scenarios' renders;   RS=1.25   the renderScale the label check runs at
#   ARM=wrongpick    the pick ignores the groups' frames (a tilted card / a lifted screw is picked where it stood) -- must FAIL (pick-*-tilted)
#   ARM=bakedlabel   the label baked into the board (no QML label) -- must FAIL (label-is-qml)
#   ARM=cachedlight  an LED feeds the cached board's uniforms (a light inside the cached layer) -- must FAIL (light-not-cached)
#   ARM=endcut       the label's name is cut at its END (Text.ElideRight), not in the middle -- must FAIL (label-name-*: the suffix is lost)
#   ARM=dipbox       the DIP's enclosure picks again (an intent for dipBody) -- must FAIL (dip-enclosure-picks-nothing-*, pick-none-*)
#   ARM=stairs       the cable is sampled in 4 steps (a staircase, not a curve) -- must FAIL (coax-is-a-smooth-curve)
#   ARM=coaxbox      a coax box is a part again -- must FAIL (coax-not-boxes)
#   ARM=fatcoax      the cable is drawn 3 x as thick -- must FAIL (coax-thin)
#   ARM=stilt        the cable's start ignores the card's tilt -- must FAIL (coax-follows-the-card)
#   ARM=offgrommet   the cable's far end lands 3 mm from its grommet -- must FAIL (coax-ends-on-its-grommet)
#   ARM=nogroove     only the lever itself picks, not its groove (round 5) -- must FAIL (dip-groove-picks-its-latch-*)
#   ARM=noocclude    the card hides none of the cables (round 5's look) -- must FAIL (coax-bend-hidden-by-the-lifted-card)
#   ARM=noink        the board layers invisible: the ink check reads zero -- must FAIL (ink)
#   ARM=nosilk       the board has no silkscreen texture (a name is not the shader's) -- must FAIL (PX names-on-the-board)
#   ARM=novariant    the unit labels ignore their variants -- must FAIL (variant-*, PX unit-*)
#   ARM=emblemalways the latches' emblems are lit in the radio's hue whether or not the radio is on -- must FAIL (PX emblem-*, the off case)
#   ARM=noemblemhue  the emblems never take the radio's hue -- must FAIL (PX emblem-*, the on case)
#   ARM=nocardmask   the glow does not mask what the card covers -- must FAIL (PX glow-card-masks). In round 3's layout NO copper runs under the card (it stands in the back corner), so the
#                    arm also lays one pulsing trace under it (geometry regenerated and baked in the copy); without that the unmasked glow shows nothing either way
#   ARM=undertrace   CONTROL, must PASS: the same trace under the card with the mask in place (the check sees the trace's light elsewhere and none through the card)
#   ARM=macsgone     the Bluetooth zone's small print is not drawn (no MACs) -- must FAIL (label-macs-in-the-bluetooth-zone)
#   ARM=flatlabel    the label stands on the board, not on the (tilted) shield's plane -- must FAIL (label-on-the-shield-plane-tilted)
#   ARM=noturn       the screw lifts without turning (the slot keeps the rest angle; shaders generated again and baked in the copy) -- must FAIL (PX screw-turns)
#   ends in AERIAL_SCENE_PROBE RESULT PASS|FAIL
#
# OFFSCREEN ONLY: the run starts itself inside a sandbox copy (tools/dev/sandbox.sh), with the platform forced on the launch (CLAUDE.md "A RUNNER WHOSE OFFSCREEN LIVES IN ITS
# OUTER HALF REACHES THE DESKTOP"), a private config home and cache home. The arms patch the COPY, never the tree.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${ASP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-scene}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen ASP_INNER=1 ASP_OUTARG="${1:-}" bash tools/dev/aerial_scene_probe.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_SCENE_PROBE
OUT="${ASP_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-scene}}"
mkdir -p "$OUT/cfg/theme" "$OUT/cache"
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
        wrongpick)
            patch modules/aerial/scene/AerialScene.qml "return Cam.pickPart(root.geo, root.cam, x, y, root.pickState());" \
                  "return Cam.pickPart(root.geo, root.cam, x, y, ({ tilt: 0, screwLift: 0, dipW: 0, dipB: 0, btnDown: 0, plugIn: 1 }));" ;;
        bakedlabel)
            patch modules/aerial/scene/AerialScene.qml "property bool labelBaked: false" "property bool labelBaked: true" ;;
        cachedlight)
            patch modules/aerial/scene/AerialScene.qml "        hueBt: root.style.btHueV
    }

    // ---- the live patch over what moves ----" "        hueBt: root.style.btHueV
        cardAbsent: root._s.led.colour[3] > 1.5
    }

    // ---- the live patch over what moves ----" ;;
        endcut)
            patch modules/aerial/scene/AerialLabel.qml "elide: Text.ElideMiddle
        elideWidth: root.nameAvail" "elide: Text.ElideRight
        elideWidth: root.nameAvail" ;;
        nogroove)
            patch modules/aerial/scene/AerialCamera.js "    if (part === \"dipBody\") {" "    if (false) {" ;;
        noocclude)
            patch modules/aerial/scene/CoaxLayer.qml "        return p[1] >= -0.05 && !root.hidden(p);" "        return p[1] >= -0.05;" ;;
        dipbox)
            patch modules/aerial/scene/AerialGeometry.js 'screw: "screw", dipWifi: "dip.wifi",' 'screw: "screw", dipBody: "dip.wifi", dipWifi: "dip.wifi",' ;;
        stairs)
            patch modules/aerial/scene/CoaxLayer.qml "readonly property int _n: 30" "readonly property int _n: 4" ;;
        coaxbox)
            patch modules/aerial/scene/AerialGeometry.js "    // the screw: head on the notch's copper ring, the shaft down into the standoff" "    out.push(B(\"coaxMainA\", MAT.COAX_MAIN, \"card\", [0, 0, -20], [1, 1, -18]));
    // the screw: head on the notch's copper ring, the shaft down into the standoff" ;;
        fatcoax)
            patch modules/aerial/scene/CoaxLayer.qml "Math.max(2, 2 * root.geo.COAX.r * root.cam.s)" "Math.max(2, 6 * root.geo.COAX.r * root.cam.s)" ;;
        stilt)
            patch modules/aerial/scene/CoaxLayer.qml "C.z0 + cx[1] - G.MHF.body / 2 + 0.2], root.cardTilt);" "C.z0 + cx[1] - G.MHF.body / 2 + 0.2], 0);" ;;
        offgrommet)
            patch modules/aerial/scene/CoaxLayer.qml "const p3 = [h[0], -0.6, h[1]];" "const p3 = [h[0] + 3, -0.6, h[1]];" ;;
        noink)
            patch modules/aerial/scene/BoardLayer.qml "    id: fx
" "    id: fx
    opacity: 0
" ;;
        nosilk)
            patch modules/aerial/scene/BoardLayer.qml 'source: Qt.resolvedUrl("assets/silk.png")' 'source: Qt.resolvedUrl("assets/gone.png")' ;;
        novariant)
            patch modules/aerial/scene/AerialScene.qml "        return i >= 0 ? i : 0;" "        return 0;" ;;
        emblemalways)
            patch modules/aerial/shaders/aerial_board.frag "            bool wf = s.part == PART_DIPWIFI;
            float on = clamp(wf ? parts.x : parts.y, 0.0, 1.0);
            vec3 hue = wf ? hueWifi.rgb : hueBt.rgb;
            col = mix(col, hue, on * (e.dk ? 0.16 : 0.10));" "            bool wf = s.part == PART_DIPWIFI;
            float on = 1.0;
            vec3 hue = wf ? hueWifi.rgb : hueBt.rgb;
            col = mix(col, hue, on * (e.dk ? 0.16 : 0.10));"
            tools/dev/bake_shaders.sh aerial_board > /dev/null || { echo "$NAME RESULT FAIL (ARM emblemalways: the bake failed)"; exit 1; } ;;
        noemblemhue)
            patch modules/aerial/scene/BoardLayer.qml "property vector4d hueWifi: Qt.vector4d(0.3, 0.7, 0.4, 1)" "property vector4d hueWifi: Qt.vector4d(0.4, 0.4, 0.4, 1)"
            patch modules/aerial/scene/BoardLayer.qml "property vector4d hueBt: Qt.vector4d(0.27, 0.5, 0.96, 1)" "property vector4d hueBt: Qt.vector4d(0.4, 0.4, 0.4, 1)"
            patch modules/aerial/scene/AerialScene.qml "        hueWifi: root.style.wifiHueV
        hueBt: root.style.btHueV
    }

    // ---- the live patch over what moves ----" "    }

    // ---- the live patch over what moves ----" ;;
        nocardmask|undertrace)
            # a pulsing trace under the card (x -8, from the slot's back edge toward the card's notch): the geometry's shaders are generated again and baked in the copy
            patch modules/aerial/scene/AerialGeometry.js '    out.push(T("padLine", "signal", 0.8, [[PADS.x, bz], [PADS.x, PADS.zs[4] + PADS.d / 2]], { blend: "bus", blendK: 0.6 }));' '    out.push(T("padLine", "signal", 0.8, [[PADS.x, bz], [PADS.x, PADS.zs[4] + PADS.d / 2]], { blend: "bus", blendK: 0.6 }));
    out.push(T("underCard", "signal", 0.8, [[-8, 2.6], [-8, -16]], { pulse: 1 }));'
            if [ "$ARM" = nocardmask ]; then
                patch modules/aerial/shaders/src/aerial_glow.frag.in "        if (slabHit(tiltBy(ro, -gCardTilt), 1.0 / tiltDirBy(rd, -gCardTilt), CARD_BOX_MIN, CARD_BOX_MAX)) {" "        if (false && slabHit(tiltBy(ro, -gCardTilt), 1.0 / tiltDirBy(rd, -gCardTilt), CARD_BOX_MIN, CARD_BOX_MAX)) {"
            fi
            node tools/dev/board_gen/gen.js aerial > /dev/null || { echo "$NAME RESULT FAIL (ARM $ARM: the shader generator failed)"; exit 1; }
            tools/dev/bake_shaders.sh aerial_ > /dev/null || { echo "$NAME RESULT FAIL (ARM $ARM: the bake failed)"; exit 1; } ;;
        noturn)
            patch modules/aerial/shaders/src/aerial_materials.glsl "    float a = -6.2831853 * fract(SCREW_TURNS * (1.0 - (1.0 - u) * (1.0 - u)));" "    float a = 0.0 * u;"
            node tools/dev/board_gen/gen.js aerial > /dev/null || { echo "$NAME RESULT FAIL (ARM $ARM: the shader generator failed)"; exit 1; }
            tools/dev/bake_shaders.sh aerial_board > /dev/null || { echo "$NAME RESULT FAIL (ARM $ARM: the bake failed)"; exit 1; } ;;
        macsgone)
            patch modules/aerial/scene/AerialLabel.qml 'Line { mx: root.padX - root.btZone[0]; my: 2.70; msize: 0.82; text: "WFM: " + root.wfm }' 'Line { mx: root.padX - root.btZone[0]; my: 2.70; msize: 0.82; text: "" }' ;;
        flatlabel)
            patch modules/aerial/scene/AerialScene.qml "readonly property var labelMap: Cam.labelMap(root.geo, root.cam, root.cardTilt)" "readonly property var labelMap: Cam.labelMap(root.geo, root.cam, 0)" ;;
        *) echo "unknown ARM=$ARM (wrongpick|bakedlabel|cachedlight|endcut|dipbox|stairs|coaxbox|fatcoax|stilt|offgrommet|noink|nosilk|novariant|emblemalways|noemblemhue|nocardmask|undertrace|macsgone|flatlabel)"; exit 2 ;;
    esac
fi

# the displays' units first (pure JS: the engraved unit follows the figures)
if ! env -u ARM node tools/dev/aerial_facts_cases.js > "$OUT/facts.log" 2>&1; then
    cat "$OUT/facts.log"; echo "$NAME RESULT FAIL (aerial_facts_cases)"; exit 1
fi
# the silkscreen's own law: no name stands where a part can cover it (and the baked texture is the one the geometry asks for)
if ! env -u ARM python3 -B tools/aerial/make_silk.py --check > "$OUT/silk.log" 2>&1; then
    cat "$OUT/silk.log"; echo "$NAME RESULT FAIL (make_silk --check)"; exit 1
fi
LOG="$OUT/probe.log"
rm -f "$OUT"/*_0.png "$OUT"/*_1.png "$OUT"/px_*.png
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
    QML_XHR_ALLOW_FILE_READ=1 OUT="$OUT" SCENARIOS="${SCENARIOS:-}" RS="${RS:-1.25}" timeout 240 quickshell -n -p tools/dev/qml/aerial_scene_probe.qml > "$LOG" 2>&1
rl_clean "$LOG" | grep -a "^AP \|AP " | sed -E 's/^.*qml: AP /AP /' | grep -a -v "^AP RESULT" 
if ! rl_clean "$LOG" | grep -a -q "AP RESULT"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"
    rl_noresult "$NAME" "$LOG"; exit 1
fi
probe=$(rl_clean "$LOG" | grep -a "AP RESULT" | tail -1)

# the board's own pixels (the pictures the probe wrote beside the renders)
python3 -B tools/dev/aerial_scene_pixels.py "$OUT" "$LOG" > "$OUT/pixels.log" 2>&1
pxrc=$?
cat "$OUT/pixels.log" | grep -a -v "^PX RESULT"
pxres=$(grep -a "^PX RESULT" "$OUT/pixels.log" | tail -1)
[ -n "$pxres" ] || { pxres="PX RESULT FAIL (no result: $OUT/pixels.log)"; pxrc=1; }

# the renders: every picture must show the board (ink = the share of pixels that are not the magenta ground)
ink=$(python3 -B - "$OUT" <<'PY'
import glob, os, sys
from PIL import Image
out = sys.argv[1]
GROUND = (255, 0, 255)
bad = []
files = sorted(glob.glob(os.path.join(out, "*_[01].png")))
for p in files:
    im = Image.open(p).convert("RGBA")
    bg = Image.new("RGBA", im.size, GROUND + (255,))
    im = Image.alpha_composite(bg, im).convert("RGB")
    px = im.load(); w, h = im.size; n = 0; tot = 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            tot += 1
            if abs(r - GROUND[0]) + abs(g - GROUND[1]) + abs(b - GROUND[2]) > 12:
                n += 1
    share = n / max(1, tot)
    print("  ink %-22s %.3f %s" % (os.path.basename(p), share, "draws" if share >= 0.25 else "EMPTY"))
    if share < 0.25:
        bad.append(os.path.basename(p))
if not files:
    bad.append("no pictures")
print("INK " + ("FAIL (" + " ".join(bad) + ")" if bad else "PASS (%d pictures)" % len(files)))
PY
)
echo "$ink" | grep -v "^INK "
inkres=$(echo "$ink" | grep "^INK ")
echo "  $inkres"
case "$probe" in *"RESULT PASS"*) pp=1 ;; *) pp=0 ;; esac
case "$inkres" in *PASS*) ip=1 ;; *) ip=0 ;; esac
[ $pxrc = 0 ] && xp=1 || xp=0
if [ $pp = 1 ] && [ $ip = 1 ] && [ $xp = 1 ]; then
    echo "$NAME RESULT PASS (${ARM:+ARM $ARM: }$(echo "$ink" | grep -c 'draws') renders drawn, every check passed)"
    exit 0
fi
echo "$NAME RESULT FAIL ($probe; $inkres; $pxres)"
exit 1
