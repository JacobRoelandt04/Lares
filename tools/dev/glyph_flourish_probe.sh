#!/usr/bin/env bash
# glyph_flourish_probe.sh -- the bar glyphs' flourish contract (GlyphFlourish) on the real buttons, live clocks: nothing plays and no
# clock runs at rest, one play per pointer ENTRY and only on a motion after it, a slid-under button plays nothing, a burst of
# notifications is one run with a kick each (its clock never goes back), an undo's record is no news, the bell rings under
# do-not-disturb, the box plays idle only, the vinyl plays on hover, each glyph of silicon's pill (the profile's, the GPU mode's) plays for a
# pointer on IT and the GPU mode's four poses are the font's outline at both ends, a play holds through a theme
# crossfade (tools/dev/qml/glyph_flourish_probe.qml). Then THE PILLS (tools/dev/qml/pill_flourish_probe.qml): the audio pill's
# and the networking pill's flourishes -- every pose the font's outline at both ends and still its picture just inside them,
# the Wi-Fi fan's level and the speaker's waves never misstated at any sample, no sound thrown while off or muted (a speaker
# that makes none lets out a puff -- one cloud, never a wave, never loose discs), the microphone's toss, the headphones' burst,
# the rune's line pulled round and back whole (switched off: the very same play), the plane's run and its wind, the wire's bulges, the pointer's rule per half of the one shared area, the
# OLED care's names.
#
#   tools/dev/glyph_flourish_probe.sh             GLYPH_FLOURISH RESULT PASS | FAIL
#   ARM=still     an entry plays at once, motion or not          -> entry_still goes red
#   ARM=latch     an entry is never spent: every motion replays   -> once_per_entry goes red
#   ARM=undo      the bell rings for any record that comes back   -> undo_quiet and real_undo_quiet go red
#   ARM=restart   a notification mid-ring starts the ring over    -> burst_continuous goes red
#   ARM=tick      the flourish clock runs at rest                 -> rest goes red (an animation running with nothing playing)
#   ARM=nohold    the clock runs on through a theme crossfade      -> theme_hold goes red
#   ARM=restblock the note's next sheet is there from the first instant (a block at rest) -> notes_rest goes red
#   ARM=quarter   the star's quarter turn is not counted off: it ends a quarter turn round, its corners renamed -> sparkle_end goes red
#   ARM=swatchlate the swatch's run ends when its front card lands, the cards behind still on their way -> swatch_end goes red
#   ARM=overfront a card stopped under the swatch's front card is drawn whole over it (its rivet's hole filled in) -> swatch_front goes red
#   ARM=darkoutline the theme button wears the outlined swatch in dark mode again -> swatch_dark goes red
#   ARM=silicongroup the whole silicon pill is the profile glyph's zone again -> silicon_figure goes red (it plays on the figure)
#   ARM=flatscales the scales' beam drops 5 degrees under the weight, not 14 -> scales_tip goes red ("I can barely see the scales tip")
#   ARM=noweight  nothing is thrown from pan to pan                -> scales_weight goes red
#   ARM=nocharge  the bolt's charge does not come in from above: the bolt is simply back at the landing -> bolt_strikes goes red
#   ARM=boltring  the landing's swell and bob are not spent by the run's end -> profile_near goes red (a jump at the swap back to the Text)
#   ARM=gpurest   the fire's sway does not die away by the run's end -> gpu_near goes red (a jump at the swap back to the Text)
#   ARM=bridgerest the bridge's rest is computed (two leaves) instead of returned -> bridge_rest goes red
#   ARM=bridgechain the cable stays over a raised leaf (a chain and its suspenders) -> bridge_strokes goes red
#   ARM=bridgepop  the cable is let go of at once, not folded                     -> bridge_morph goes red
#   ARM=bridgeunfold a raised bridge's salute unfolds its cable                   -> bridge_held goes red
#   ARM=bridgeseed the first line a service delivers moves the leaves             -> bridge_seed goes red (the shell's start lowers the bridge)
#   ARM=saluteopens the salute is four times as far                               -> bridge_salute goes red (it reaches the other state)
#   ARM=throughpier the salute's bounces go through the pier, not off it            -> bridge_salute goes red (a leaf swings through the deck)
#   ARM=hovercar  a hover puts a car on the deck                                  -> bridge_salute_down goes red (a car is a fact)
#   ARM=wrongway  a car to the phone drives from it                               -> bridge_cars goes red
#   ARM=smoothcast the cast's car moves every frame, not a device pixel a step    -> bridge_longstep goes red (a cast would cost a frame a tick)
#   ARM=castink   a cast's cars take the bridge's ink                             -> bridge_cast goes red
#   ARM=panobox   a pane is taller than the monitor's screen                     -> pano_inbox goes red (ink past the box)
#   ARM=panorest  the run's end is not the rest picture (100 ms of the deal left)    -> pano_rest goes red
#   ARM=panolife  the run's length is a constant that ends before the last tile lands -> pano_life goes red
#   ARM=panosolid the screens are solid at rest (no windows until the deal)        -> pano_tiles goes red
#   ARM=panostay  the windows never go: the rings stay open before the deal        -> pano_tiles goes red
#   ARM=panoorder the stack's upper window is dealt before the lower one           -> pano_holes goes red (rings over each other: ink)
#   ARM=panomark  a mark comes into a screen whose rings are still open            -> pano_holes goes red
#   ARM=panopop   the master's column is there or not by a threshold                -> pano_morph goes red (the windows are swapped)
#   ARM=panodip   a mark does not move in the deal                                  -> pano_life goes red (a mirrored lone screen plays nothing)
#   ARM=stocksclosedarrow the stocks button's closed face throws the arrow too -> stocks_arrow goes red
#   ARM=stockswrongway a loss's lump bulges up like a gain's                     -> stocks_direction goes red
#   ARM=stocksrestwarp the live line's warp stays bound at rest                    -> stocks_rest goes red
#   ARM=stocksmodelive the lump follows the live sign, not the one the play began on -> stocks_modehold goes red
#
# The note's pixels: the glyph posed at its first instant and at its last must be the SAME picture (0 px), and each within
# REST_TOL levels (default 40) of the plain Text at no more than REST_PX pixels over 12 (default 0): the curve renderer's edges
# are not the distance field's, so the swap is judged against that bound, the two posed ends against each other exactly.
#   ARM=fullbars  the Wi-Fi fan draws full bars mid-flourish       -> pill_wifi_level goes red
#   ARM=mutedwave a muted speaker throws its wave all the same     -> pill_speaker goes red (a WAVE from a speaker that makes no sound)
#   ARM=soundpuff a speaker that sounds lets out the puff          -> pill_speaker goes red (a puff from a speaker that sounds)
#   ARM=puffloose the puff's lobes wander apart as they go         -> pill_speaker goes red (loose pieces: bubbles, not one cloud)
#   ARM=mutedmark a muted microphone's catch throws the marks      -> pill_mic goes red
#   ARM=mutedburst muted headphones fire their waves               -> pill_phones goes red
#   ARM=runeshort the rune's line comes in 600 units short         -> pill_rune goes red (not the whole rune just inside the end)
#   ARM=offrune   the switched-off rune has a shorter play of its own -> pill_rune goes red (off is not the on rune's play)
#   ARM=windtouch a streak of the plane's wind starts on its wing  -> pill_plane goes red
#   ARM=deadlink  a wire with no link delivers to the lower box    -> pill_lan goes red
#   ARM=bothhalves the pointer on one half plays the other too     -> pill_half_motion goes red
#
# Runs in a sandbox copy (tools/dev/sandbox.sh), offscreen; an arm patches that copy only.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/flourishprobe.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
# arm <file> <exact old text> <new text> <needle the arm must turn red>
arm() {
    ARMFILE=$1; ARMOLD=$2; ARMNEW=$3; NEEDLE=$4
}
case "${ARM:-}" in
    "") ;;
    still) arm modules/common/components/GlyphFlourish.qml '            fl._entered = a.containsMouse;' \
               '            fl._entered = a.containsMouse; if (a.containsMouse && fl.hoverPlays && !fl._on) fl.play("hover");' 'FLOURISH_PROBE entry_still FAIL' ;;
    latch) arm modules/common/components/GlyphFlourish.qml '            fl._entered = false;' '            fl._entered = true;' 'FLOURISH_PROBE once_per_entry FAIL' ;;
    undo) arm modules/notifications/NotificationsBarButton.qml 'Date.now() - Number(rec.arrivedMs || 0) < 250' 'true' 'FLOURISH_PROBE real_undo_quiet FAIL' ;;
    restart) arm modules/notifications/NotificationsBarButton.qml '        overlap: "extend"' '        overlap: "restart"' 'FLOURISH_PROBE burst_continuous FAIL' ;;
    tick) arm modules/common/components/GlyphFlourish.qml '        easing.type: Easing.Linear
        onFinished: {' '        easing.type: Easing.Linear
        running: true
        loops: Animation.Infinite
        from: 0
        to: 0.001
        duration: 500
        onFinished: {' 'FLOURISH_PROBE rest FAIL' ;;
    nohold) arm modules/common/components/GlyphFlourish.qml '        if (fl._run.running && Theme.crossfading && !fl._run.paused)' '        if (false)' 'FLOURISH_PROBE theme_hold FAIL' ;;
    restblock) arm modules/notes/parts/NotePeelPose.js '    st.under = l.shade * O.smooth(0, l.inkMs, x);' '    st.under = l.shade;' 'FLOURISH_PROBE notes_rest FAIL' ;;
    quarter) arm modules/bar/llm/parts/SparklePose.js '    if (deg > 45)
        deg -= 90;' '' 'FLOURISH_PROBE sparkle_end FAIL' ;;
    swatchlate) arm modules/shell/parts/SwatchPose.js '    return l.windMs + l.spinMs + 2 * l.lagMs + l.restMs;' '    return l.windMs + l.spinMs;' 'FLOURISH_PROBE swatch_end_filled FAIL' ;;
    overfront) arm modules/shell/parts/SwatchPose.js '    const mid = cut(_through(g.midCard.card, mm), fa, fb, g.midCard.side);' \
               '    const mid = cut(_through(g.midCard.card, mm), fa, fb, st.openMid > 0.2 ? g.midCard.side : -g.midCard.side);' 'FLOURISH_PROBE swatch_front_filled FAIL' ;;
    darkoutline) arm modules/shell/ThemeBarButton.qml '    readonly property string glyphKey: "f08b5"' \
               '    readonly property string glyphKey: Theme.mode === "dark" ? "f135c" : "f08b5"' 'FLOURISH_PROBE swatch_dark FAIL' ;;
    silicongroup) arm modules/silicon/SiliconBarButton.qml '        const zone = inside ? faceItem.zoneAt(f.x, f.y) : -1;' \
               '        const zone = inside ? 0 : -1;' 'FLOURISH_PROBE silicon_figure FAIL' ;;
    flatscales) arm modules/silicon/bar/SiliconGlyphPose.js 'land: 0.46, tip: 14,' 'land: 0.46, tip: 5,' 'FLOURISH_PROBE scales_tip FAIL' ;;
    noweight) arm modules/silicon/bar/SiliconGlyphPose.js '    if (u <= 0 || u >= S.melt1)
        return 0;' '    return 0;' 'FLOURISH_PROBE scales_weight FAIL' ;;
    nocharge) arm modules/silicon/bar/SiliconGlyphPose.js 'b: span * st,' 'b: u >= B.hit ? span : 0,' 'FLOURISH_PROBE bolt_strikes FAIL' ;;
    boltring) arm modules/silicon/bar/SiliconGlyphPose.js 'Math.cos(2 * Math.PI * B.cycles * v) * (1 - v);' 'Math.cos(2 * Math.PI * B.cycles * v) * 3;' 'FLOURISH_PROBE profile_near FAIL' ;;
    gpurest) arm modules/silicon/bar/SiliconGpuPose.js 'env: O.smooth(0, 0.1, v) * Math.pow(1 - v, l.damp) };' \
               'env: O.smooth(0, 0.1, v) };' 'FLOURISH_PROBE gpu_near FAIL' ;;
    bridgerest) arm modules/bridge/bar/BridgePose.js '    if (upL === 0 && upR === 0)' '    if (upL === 7 && upR === 7)' 'FLOURISH_PROBE bridge_rest FAIL' ;;
    bridgechain) arm modules/bridge/bar/BridgePose.js '    foldTo: 0.9, ' '    foldTo: 9, ' 'FLOURISH_PROBE bridge_strokes FAIL' ;;
    bridgepop) arm modules/bridge/bar/BridgePose.js '    return O.smooth(l.foldFrom, l.foldTo, Math.max(up, held === undefined ? up : held));' \
               '    return Math.max(up, held === undefined ? up : held) >= l.foldTo ? 1 : 0;' 'FLOURISH_PROBE bridge_morph FAIL' ;;
    bridgeunfold) arm modules/bridge/bar/BridgePose.js 'Math.max(up, held === undefined ? up : held));' 'up);' 'FLOURISH_PROBE bridge_held FAIL' ;;
    bridgeseed) arm modules/bridge/BridgeBarButton.qml '        btn._seeded = false;' '        btn._seeded = true;' 'FLOURISH_PROBE bridge_seed FAIL' ;;
    saluteopens) arm modules/bridge/bar/BridgePose.js '    return raised ? -l.bowUp * amount : l.bowDown * amount;' '    return raised ? -l.bowUp * amount * 4 : l.bowDown * amount * 4;' 'FLOURISH_PROBE bridge_salute FAIL' ;;
    throughpier) arm modules/bridge/bar/BridgePose.js '            return h * (1 - u * u);' '            return -h * (1 - u * u);' 'FLOURISH_PROBE bridge_salute FAIL' ;;
    hovercar) arm modules/bridge/BridgeBarButton.qml '        hoverArea: btn.area' '        hoverArea: btn.area
        onPlayed: btn.car(1)' 'FLOURISH_PROBE bridge_salute_down FAIL' ;;
    wrongway) arm modules/bridge/bar/BridgeTraffic.js '    const p = O.inOutQuad(age / CROSS_MS) * 0.35 + (age / CROSS_MS) * 0.65;
    return dir > 0' '    const p = O.inOutQuad(age / CROSS_MS) * 0.35 + (age / CROSS_MS) * 0.65;
    return dir < 0' 'FLOURISH_PROBE bridge_cars FAIL' ;;
    smoothcast) arm modules/bridge/BridgeBarButton.qml '        interval: Math.round(1700 / btn._castSteps)' '        interval: 16' 'FLOURISH_PROBE bridge_longstep FAIL' ;;
    castink) arm modules/bridge/BridgeBarButton.qml '? Theme.accent : btn.glyphItem.color)' '? btn.glyphItem.color : btn.glyphItem.color)' 'FLOURISH_PROBE bridge_cast FAIL' ;;
    fullbars) arm modules/aerial/bar/parts/NetPose.js '    const out = [O.emit(g.parts[0], grow, k, ox, oy)];' \
               '    const out = [O.emit((t > 100 && t < 300 ? P.G["f0928"] : g).parts[0], grow, k, ox, oy)];' 'FLOURISH_PROBE pill_wifi_level FAIL' ;;
    mutedwave) arm modules/bar/audio/parts/AudioPose.js '    const sounding = live && waves > 0;' '    const sounding = waves > 0;' \
               'FLOURISH_PROBE pill_speaker FAIL.*a WAVE from a speaker that makes no sound' ;;
    soundpuff) arm modules/bar/audio/parts/AudioPose.js '    const sounding = live && waves > 0;' '    const sounding = false;' \
               'FLOURISH_PROBE pill_speaker FAIL.*a puff from a speaker that sounds' ;;
    puffloose) arm modules/bar/audio/parts/AudioPose.js '        const near = l.puffR * spread * Math.min(1, swell) * (1 - l.puffGather * going) * left;' \
               '        const near = l.puffR * spread * Math.min(1, swell) * (1 + going);' 'FLOURISH_PROBE pill_speaker FAIL.*loose pieces' ;;
    mutedmark) arm modules/bar/audio/parts/AudioPose.js '    if (live) {
        const x = markShare(t, l)' '    if (true) {
        const x = markShare(t, l)' 'FLOURISH_PROBE pill_mic FAIL.*a mark from a MUTED microphone' ;;
    mutedburst) arm modules/bar/audio/parts/AudioPose.js '    if (live) {
        // a burst is its left' '    if (true) {
        // a burst is its left' 'FLOURISH_PROBE pill_phones FAIL.*a wave from MUTED headphones' ;;
    runeshort) arm modules/aerial/bar/parts/NetPose.js '    return [a, a - gap];' '    return [a, a - gap - 600];' \
               'FLOURISH_PROBE pill_rune FAIL.*not the whole rune' ;;
    offrune) arm modules/aerial/bar/parts/NetPose.js '    // the plane, and the rune (the same play on or off)
    return 780;' '    return g.kind === "plane" || live ? 780 : 480;' 'FLOURISH_PROBE pill_rune FAIL.*off is not the on rune' ;;
    windtouch) arm modules/aerial/bar/parts/NetPose.js 'var STREAKS = [[610, 500, 940]' 'var STREAKS = [[610, 1500, 940]' \
               'FLOURISH_PROBE pill_plane FAIL.*the wind touches the plane' ;;
    deadlink) arm modules/aerial/bar/parts/NetPose.js '        if (live)
            down = Math.max(' '        if (true)
            down = Math.max(' 'FLOURISH_PROBE pill_lan FAIL.*the lower box moved' ;;
    bothhalves) arm modules/bar/audio/AudioBarButton.qml '        inHalf.flourish.pointerAt(index === 1, p.x, p.y);' \
               '        inHalf.flourish.pointerAt(index >= 0, p.x, p.y);' 'FLOURISH_PROBE pill_half_motion_audio FAIL' ;;
    panobox) arm modules/panorama/bar/PanoramaPanes.js '        panes.push({ x0: x + gap, x1: x + gap + wi, y0: SY0, y1: SY1,' '        panes.push({ x0: x + gap, x1: x + gap + wi, y0: SY0, y1: SY1 + 200,' 'FLOURISH_PROBE pano_inbox FAIL' ;;
    panorest) arm modules/panorama/bar/PanoramaPanes.js '    const x = run ? t * _total(l) / Math.max(1, life) : 0;' '    const x = run ? t * _total(l) / Math.max(1, life) : (t >= life ? 100 : 0);' 'FLOURISH_PROBE pano_rest FAIL' ;;
    panolife) arm modules/panorama/bar/PanoramaPanes.js 'var LIFE = _total(DEFAULTS);' 'var LIFE = _total(DEFAULTS) - 200;' 'FLOURISH_PROBE pano_life FAIL' ;;
    panosolid) arm modules/panorama/bar/PanoramaPanes.js '    const share = dealt ? open : open * (1 - O.smooth(0, l.meltMs, x));' '    const share = dealt ? open : (x > 0 ? open * (1 - O.smooth(0, l.meltMs, x)) : 0);' 'FLOURISH_PROBE pano_tiles FAIL.*rests with' ;;
    panostay) arm modules/panorama/bar/PanoramaPanes.js '    const share = dealt ? open : open * (1 - O.smooth(0, l.meltMs, x));' '    const share = open;' 'FLOURISH_PROBE pano_tiles FAIL.*is not clear' ;;
    panoorder) arm modules/panorama/bar/PanoramaPanes.js '    const out = [{ r: [sx, y0, x1, my - b / 2], k: m }, { r: [sx, my + b / 2, x1, y1], k: m + 1 }];' '    const out = [{ r: [sx, y0, x1, my - b / 2], k: m + 1 }, { r: [sx, my + b / 2, x1, y1], k: m }];' 'FLOURISH_PROBE pano_holes FAIL.*overlap' ;;
    panomark) arm modules/panorama/bar/PanoramaPanes.js '            windows: windows(c, i, x, 1 - O.seg(m, 0, MARK_AT), l)' '            windows: windows(c, i, x, 1 - O.seg(m, 0, 1), l)' 'FLOURISH_PROBE pano_holes FAIL.*beside a mark' ;;
    panopop) arm modules/panorama/bar/PanoramaPanes.js '    const m = O.smooth(MASTER_FROM, MASTER_FULL, w), mw' '    const m = w > 1300 ? 1 : 0, mw' 'FLOURISH_PROBE pano_morph FAIL' ;;
    panodip) arm modules/panorama/bar/PanoramaPanes.js 'var MARK_AT = 0.4, MARK_DIP = 0.4;' 'var MARK_AT = 0.4, MARK_DIP = 0;' 'FLOURISH_PROBE pano_life FAIL.*1m moves' ;;
    stocksclosedarrow) arm modules/stocks/parts/StocksPose.js '    return mode !== "closed" && style !== "ripple";' '    return style !== "ripple";' 'FLOURISH_PROBE stocks_arrow FAIL' ;;
    stockswrongway) arm modules/stocks/parts/StocksPose.js '    return (mode === "loss" ? 1 : -1) * l.amp * v;' '    return -l.amp * v;' 'FLOURISH_PROBE stocks_direction FAIL' ;;
    stocksrestwarp) arm modules/stocks/StocksBarButton.qml '                warp: stkFlourish.playing && btn._mode !== "closed" ? btn._warp : null' '                warp: btn._warp' 'FLOURISH_PROBE stocks_rest FAIL' ;;
    stocksmodelive) arm modules/stocks/StocksBarButton.qml '        return P.dy(x, w, t, btn._mode, btn._style, btn._look);' '        return P.dy(x, w, t, btn.live ? (btn._loss ? "loss" : "gain") : "closed", btn._style, btn._look);' 'FLOURISH_PROBE stocks_modehold FAIL' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
ARMCMD=""
if [ -n "${ARM:-}" ]; then
    # the patch: exact text, exactly once, or the arm says its anchor is gone
    ARMCMD="python3 -c 'import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    print(\"FLOURISH ARM anchor gone\"); sys.exit(3)
open(p, \"w\").write(s.replace(a, b))' $(printf '%q %q %q' "$ARMFILE" "$ARMOLD" "$ARMNEW")"
fi
# a world of its own: the theme state seeded (a test never writes the user's), the state dir private
mkdir -p "$D/cfg/theme" "$D/state" "$D/bin" "$D/grabs"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
# the probe builds a REAL NotificationService (its post / clear / undo): a private bus with no services
# (tools/dev/notifications_bus.sh) and a pw-play that plays nothing
printf '#!/bin/sh\nexit 0\n' > "$D/bin/pw-play"; chmod +x "$D/bin/pw-play"
# the two harnesses one after the other in the one (armed) copy; the second runs whatever the first said
QS='env -u WAYLAND_DISPLAY PATH='"$D/bin"':$PATH QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' OUT_DIR='"$D/grabs"' tools/dev/notifications_bus.sh timeout 90 quickshell -p'
run='set -e; '"${ARMCMD:+$ARMCMD; }"'set +e; '"$QS"' tools/dev/qml/glyph_flourish_probe.qml; '"$QS"' tools/dev/qml/pill_flourish_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'FLOURISH_PROBE .*' | grep -a -v 'FLOURISH_PROBE RESULT'
rl_clean "$D/log" | grep -a -o 'PILL_PROBE RESULT .*'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'FLOURISH ARM anchor gone'; then echo "ARM $ARM: the anchor is gone -- re-aim the arm"; exit 1; fi
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'FLOURISH_PROBE RESULT' || ! rl_has "$D/log" 'PILL_PROBE RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
rl_clean "$D/log" | grep -E "WARN|ERROR|rror" | rl_platform_noise \
    | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks\|org.freedesktop.portal" \
    | sort -u | head -8 | sed 's/^/    /'
res=$(rl_result GLYPH_FLOURISH "$D/log" 'FLOURISH_PROBE RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
# the pills' half: its own result line, or the run has none
if ! rl_has "$D/log" 'PILL_PROBE RESULT'; then KEEP_D=1; rl_noresult GLYPH_FLOURISH "$D/log"; exit 1; fi
if ! rl_has "$D/log" 'PILL_PROBE RESULT PASS'; then res="FLOURISH_PROBE RESULT FAIL (the pills: $(rl_clean "$D/log" | grep -a -o 'PILL_PROBE RESULT .*' | tail -1))"; rc=1; fi
# the note's ends, by pixels (header)
pix=$(python3 - "$D/grabs" "${REST_TOL:-40}" "${REST_PX:-0}" <<'PY'
import sys, os
from PIL import Image, ImageChops
d, tol, npx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def load(n):
    im = Image.open(os.path.join(d, n + ".png")).convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, im).convert("RGB")
try:
    text, first, last = load("notes_text"), load("notes_first"), load("notes_last")
except Exception as e:
    print("FLOURISH_PROBE notes_pixels FAIL no grabs (%s)" % e); sys.exit(1)
ink = sum(1 for p in ImageChops.difference(first, Image.new("RGB", first.size, first.getpixel((0, 0)))).get_flattened_data() if max(p) > 30)
ends = sum(1 for p in ImageChops.difference(first, last).get_flattened_data() if max(p) > 0)
sw = [max(p) for p in ImageChops.difference(text, first).get_flattened_data()]
over, off = sum(1 for v in sw if v > tol), sum(1 for v in sw if v > 12)
ok = ink > 60 and ends == 0 and over == 0 and off <= max(npx, ink)
print("FLOURISH_PROBE notes_pixels %s ink %d px, first vs last %d px, text vs posed: worst %d levels, %d px over 12, %d over %d"
      % ("ok" if ok else "FAIL", ink, ends, max(sw), off, over, tol))
sys.exit(0 if ok else 1)
PY
); prc=$?
printf '%s\n' "$pix"
if [ "$prc" != 0 ] && [ "$rc" = 0 ]; then echo "GLYPH_FLOURISH RESULT FAIL (the note's rest pixels)"; exit 1; fi
printf '%s\n' "$res" | sed 's/^FLOURISH_PROBE RESULT/GLYPH_FLOURISH RESULT/'
exit $rc
