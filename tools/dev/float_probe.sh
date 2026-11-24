#!/usr/bin/env bash
# float_probe.sh -- the card float (modules/common/float) where it is mounted: the notes tiles and the weather popup
# (tools/dev/qml/float_probe.qml says what each subject checks).
#
#   tools/dev/float_probe.sh                          FLOAT RESULT PASS | FAIL (<n>/<n> checks), notes then weather
#   SUBJECT=notes|weather tools/dev/float_probe.sh     one of them
#   STRIP=<dir> [MODE=light|dark] tools/dev/float_probe.sh   no checks: the held-clock strips, <dir>/<subject>/<t>ms.png
#   MEASURE=1 [SUBJECT=...] [FLOAT_OFF=1] tools/dev/float_probe.sh   no checks: the rest beat's counts and the JS cost of a tick (FM lines), with
#                                                   Qt's per-frame timing (QSG_RENDER_TIMING) summarised over the 3 s at rest. A MEASUREMENT, offscreen and
#                                                   relative: run it on a quiet machine and compare A with B in the same session.
#   ARM=<name> tools/dev/float_probe.sh               one fault in the sandbox copy; the check it names must go red:
#     cellhit    notes: a press is taken by the tile's CELL again (the resting rect): the lifted corner past it opens nothing
#     nocalm     notes: the grid never asks for calm: the sway runs on under a drag
#     nohold     the clock ignores the theme crossfade: the tiles move under it
#     alwaysfast the clock runs every frame at rest too: the slow beat is gone
#     tilelayer  weather: the tiles' host is a layer while they float (it would be drawn again every tick)
#     nobeat     weather: the backdrop's beat is not handed in: the sway ticks on a timer of its own beside it
#     restinput  weather: a tile's pointer area is on its resting rect, not on the card: a click on the lifted corner misses
#     nofacelayer notes: the faces are never held as textures (each tick redraws every tile's text and boxes)
#
# Runs in a sandbox copy (tools/dev/sandbox.sh) with a private config (the theme state seeded: the crossfade check switches the mode),
# state, cache and a copy of mockups/fixtures/notes. The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/fp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
GRID=modules/notes/browse/NotesGrid.qml
CLOCK=modules/common/float/FloatClock.qml
WPOP=modules/weather/WeatherPopup.qml
WTILE=modules/weather/WeatherTile.qml
ARMCMD="" NEEDLE="" ARMSUBJ=""
case "${ARM:-}" in
    "") ;;
    cellhit) ARMSUBJ=notes; ARMCMD="sed -i 's|const p = c.mapFromItem(flick.contentItem, cx, cy);|const p = (c === plusCard ? c : c.parent).mapFromItem(flick.contentItem, cx, cy);|' $GRID && grep -q 'c.parent).mapFromItem' $GRID"
             NEEDLE='FP FAIL hit: a press on the drawn corner' ;;
    nocalm) ARMSUBJ=notes; ARMCMD="sed -i 's|readonly property bool floatCalm: .*|readonly property bool floatCalm: false|' $GRID && grep -q 'floatCalm: false' $GRID"
            NEEDLE='FP FAIL calm: the sway eased to rest' ;;
    nohold) ARMSUBJ=notes; ARMCMD="sed -i 's|readonly property bool _on: clock.live \&\& .*|readonly property bool _on: clock.live|' $CLOCK && grep -q '_on: clock.live\$' $CLOCK"
            NEEDLE='FP FAIL crossfade: the tiles stand still' ;;
    alwaysfast) ARMSUBJ=notes; ARMCMD="sed -i 's|running: clock._on \&\& !clock._idle \&\& (clock.restHz <= 0 [|][|] clock._fast)|running: clock._on \&\& !clock._idle|' $CLOCK && grep -q 'running: clock._on && !clock._idle\$' $CLOCK"
            NEEDLE='FP FAIL beat: at rest the sway ticks on the slow beat' ;;
    tilelayer) ARMSUBJ=weather; ARMCMD="sed -i 's|layer.enabled: root._layered \&\& !root.cardFloat|layer.enabled: root._layered|' $WPOP && ! grep -q '!root.cardFloat' $WPOP"
               NEEDLE="FP FAIL layers: the tiles' host is not" ;;
    nobeat) ARMSUBJ=weather; ARMCMD="sed -i 's|^            cardClock.beat();|            void 0;|' $WPOP && ! grep -q 'cardClock.beat()' $WPOP"
            NEEDLE="FP FAIL beat: the rest ticks are the backdrop's" ;;
    restinput) ARMSUBJ=weather; ARMCMD="sed -i 's|^\\( *\\)id: area\$|&\\n\\1parent: tile|' $WTILE && grep -q 'parent: tile' $WTILE"
               NEEDLE='FP FAIL hit: a click on the drawn corner' ;;
    nofacelayer) ARMSUBJ=notes; ARMCMD="sed -i 's|^    onLiveChanged: Qt.callLater(() => clock.layers = clock.live)|    onLiveChanged: void 0|' $CLOCK && grep -q 'onLiveChanged: void 0' $CLOCK"
                 NEEDLE="FP FAIL layers: a floating tile's face is one held texture" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
SUBJECTS="${SUBJECT:-${ARMSUBJ:-notes weather}}"
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/cfg/theme/state.json"
rc=0 total="" lines=""
for s in $SUBJECTS; do
    strip=""
    if [ -n "${STRIP:-}" ]; then strip="$STRIP/$s"; mkdir -p "$strip"; fi
    run='set -e; '"${ARMCMD:+$ARMCMD; }"'rm -rf '"$D"'/notes; cp -a mockups/fixtures/notes '"$D"'/notes; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache FLOAT_SUBJECT='"$s"' FLOAT_NOTES='"$D"'/notes FLOAT_STRIP='"$strip"' FLOAT_MEASURE='"${MEASURE:-}"' FLOAT_OFF='"${FLOAT_OFF:-}"' '"${MEASURE:+QSG_RENDER_TIMING=1 }"'timeout -k 5 120 quickshell -p tools/dev/qml/float_probe.qml'
    SANDBOX="${SANDBOX:-/tmp/lares-sandbox-float-probe}" tools/dev/sandbox.sh bash -c "$run" > "$D/$s.log" 2>&1
    if [ -n "$strip" ]; then
        echo "$s: $(ls "$strip" | wc -l) frames in $strip"
        continue
    fi
    if [ -n "${MEASURE:-}" ]; then
        rl_clean "$D/$s.log" | grep -a -o 'FM .*' | grep -a -v 'FM rest begins\|FM rest ends'
        # Qt's own timing of the frames drawn at rest (QSG_RENDER_TIMING: whole ms, so a mean of many)
        rl_clean "$D/$s.log" | sed -n '/FM rest begins/,/FM rest ends/p' | grep -a -o 'frame rendered in .*' | python3 -c '
import re, sys
rows = [[int(x) for x in re.findall(r"(\d+)", l)[:4]] for l in sys.stdin]
if not rows:
    print("FM qt: no frame timing at rest"); sys.exit()
n = len(rows)
print("FM qt: %d frames drawn at rest; mean ms: frame %.2f, sync %.2f, render %.2f, swap %.2f (whole-ms readings)" % ((n,) + tuple(sum(r[i] for r in rows) / n for i in range(4))))
'
        continue
    fi
    rl_clean "$D/$s.log" | grep -a -o 'FP .*' | grep -a -v 'FP RESULT' | sed "s/^FP /FP $s /"
    if [ -n "${ARM:-}" ]; then
        if rl_clean "$D/$s.log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
        if ! rl_has "$D/$s.log" 'FP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; exit 1; fi
        echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
    fi
    res=$(rl_result FLOAT "$D/$s.log" 'FP RESULT .*'); r=$?
    if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
    [ $r = 0 ] || rc=1
    lines="$lines $s:$(printf '%s' "$res" | grep -o '([0-9]*/[0-9]* checks)')"
done
[ -n "${STRIP:-}${MEASURE:-}" ] && exit 0
if [ $rc = 0 ]; then echo "FLOAT RESULT PASS ($lines )"; else echo "FLOAT RESULT FAIL ($lines )"; fi
exit $rc
