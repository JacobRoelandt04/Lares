#!/usr/bin/env bash
# panorama_castglyph_probe.sh -- the panorama button while a cast is being made (modules/panorama/bar/PanoramaBarButton.qml `working`,
# PanoramaBarOwner's binding, CastKeeper.working): the hover hue and whole turns of the flourish until it is over
# (tools/dev/qml/panorama_castglyph_probe.qml has the checks). Offscreen, in a sandbox copy, private homes.
#
#   tools/dev/panorama_castglyph_probe.sh           ends in PANORAMA_CASTGLYPH RESULT PASS|FAIL
#   tools/dev/panorama_castglyph_probe.sh film <outdir>   the filmstrip of two turns (MODE=light|dark): film_<mode>.png
#   ARM=<name>   the fault in the copy; the run must FAIL on its own check:
#     once         one turn and no more                                            -> "loop: turn after turn"
#     nobreath     no rest between two turns                                       -> "loop: the glyph rests"
#     cut          the stream's coming cuts the turn in the air                     -> "up: that turn ended whole"
#     forever      the turns go on after the stream is up                           -> "up: that turn ended whole"
#     inkcut       the hue goes back once the stream is up                          -> "up: the hover hue stays while the cast is up"
#     inkforever   the hue never goes back                                          -> "ends: the cast over"
#     hoverplays   a pointer, demo() and deal() play in the rest                    -> "alone: in the rest"
#     offleak      the bar shows a cast with casting off                            -> "off:"
#     keeperonly   only the keeper's own casts are shown                            -> "ends: a cast that something else"
#     lostquiet    a lost link is not told until the retry                          -> "lost: a lost link"
#     oneowner     the owner does not hand the word over                            -> "loop: from the first moment"
#   ARM=all      every arm, each in its own copy: PANORAMA_CASTGLYPH ARMS PASS|FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-cg}"
NAME=PANORAMA_CASTGLYPH
B=modules/panorama/bar/PanoramaBarButton.qml
patch=""; need=""
case "${ARM:-}" in
    ""|all) ;;
    once)       patch="$B@@        if (btn.working)
            breath.restart();@@        void 0;"; need='loop: turn after turn' ;;
    nobreath)   patch="$B@@        interval: btn.breathMs@@        interval: 0"; need='loop: the glyph rests' ;;
    cut)        patch="$B@@    onWorkingChanged: btn._turn()@@    onWorkingChanged: btn.working ? btn._turn() : blink.stop()"; need='up: that turn ended whole' ;;
    forever)    patch="$B@@        if (btn.working)
            breath.restart();@@        breath.restart();
====
$B@@        if (btn.working && !breath.running)@@        if (!breath.running)"; need='up: that turn ended whole' ;;
    inkcut)     patch="$B@@    readonly property bool _inked: btn.working || btn.casting || (blink.playing && blink.why === \"cast\")@@    readonly property bool _inked: btn.working || (blink.playing && blink.why === \"cast\")"; need='up: the hover hue stays while the cast is up' ;;
    inkforever) patch="modules/panorama/PanoramaBarOwner.qml@@            owner.anchorItem.casting = owner._castActive;@@            owner.anchorItem.casting = owner._castActive || owner.anchorItem.casting;"; need='ends: the cast over' ;;
    hoverplays) patch="$B@@        hoverPlays: !btn.working@@        hoverPlays: true"; need='alone: in the rest' ;;
    offleak)    patch="modules/panorama/data/PanoramaMock.qml@@    readonly property bool castWorking: root.castEnabled && castKeeper.working@@    readonly property bool castWorking: castKeeper.working"; need='off:' ;;
    keeperonly) patch="modules/panorama/data/CastKeeper.qml@@                                    || (root.cast !== null && (root.cast.state === \"connecting\" || root.cast.state === \"negotiating\"))@@"; need='ends: a cast that something else' ;;
    lostquiet)  patch="modules/panorama/data/CastParse.js@@    case \"lost\":                    // a stream@@    case \"lost-armed\":              // a stream"; need='lost: a lost link' ;;
    oneowner)   patch="modules/panorama/PanoramaBarOwner.qml@@            owner.anchorItem.working = owner._castWorking;@@            void 0;"; need='loop: from the first moment' ;;
    *) echo "$NAME RESULT FAIL (unknown ARM $ARM)"; exit 2 ;;
esac
if [ "${ARM:-}" = all ]; then
    bad=0
    for a in once nobreath cut forever inkcut inkforever hoverplays offleak keeperonly lostquiet oneowner; do
        out=$(ARM=$a "$0" 2>&1)
        case "$out" in *"failed as it must"*) echo "ARM $a: failed as it must" ;; *) echo "ARM $a: $(printf '%s\n' "$out" | tail -1)"; bad=1 ;; esac
    done
    [ $bad = 0 ] && echo "$NAME ARMS PASS" || echo "$NAME ARMS FAIL"
    exit $bad
fi
LOG=$(mktemp "${SCRATCH:-/tmp}/panocg.XXXXXX"); keep=0
trap '[ "$keep" = 1 ] || rm -f "$LOG"' EXIT
armpy='import sys
for one in sys.argv[1].split("\n====\n"):
    f,a,b=one.split("@@",2); s=open(f).read()
    if s.count(a)!=1: print("ARM anchor gone: "+a); sys.exit(1)
    open(f,"w").write(s.replace(a,b))'
FILMDIR=""
if [ "${1:-}" = film ]; then FILMDIR=$(realpath -m "${2:?film needs an outdir}"); mkdir -p "$FILMDIR/frames"; rm -f "$FILMDIR"/frames/*.png; fi
run='set -e; PRIV=$(mktemp -d /tmp/panocg-env.XXXXXX); mkdir -p $PRIV/config/theme $PRIV/state $PRIV/cache; printf "{\"theme\":\"eva\",\"mode\":\"'"${MODE:-light}"'\"}\n" > $PRIV/config/theme/state.json; '
[ -n "$patch" ] && run="$run python3 -c '$armpy' $(printf '%q' "$patch"); "
run="$run"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 PANORAMA_CASTGLYPH=1 FILM="'"${FILMDIR:+$FILMDIR/frames}"'" XDG_CONFIG_HOME=$PRIV/config XDG_STATE_HOME=$PRIV/state XDG_CACHE_HOME=$PRIV/cache tools/dev/notifications_bus.sh timeout -k 2 120 quickshell -p tools/dev/qml/panorama_castglyph_probe.qml; rm -rf $PRIV'
tools/dev/sandbox.sh bash -c "$run" > "$LOG" 2>&1
rl_clean "$LOG" | grep -a -E 'PG (ok|FAIL)' | sed 's/^.*PG /PG /'
if [ -n "${ARM:-}" ]; then
    rl_has "$LOG" 'ARM anchor gone' && { echo "$NAME RESULT FAIL (ARM $ARM: its anchor is gone)"; exit 1; }
    if rl_clean "$LOG" | grep -a -q "PG FAIL $need"; then echo "ARM $ARM: failed as it must"; echo "$NAME RESULT FAIL (armed $ARM)"; exit 1; fi
    rl_has "$LOG" 'PG RESULT' || { keep=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"; exit 1; }
    echo "ARM $ARM: DID NOT BITE on \"$need\""; exit 1
fi
res=$(rl_result "$NAME" "$LOG" 'PG RESULT .*'); rc=$?
if rl_isnoresult "$res"; then keep=1; printf '%s\n' "$res"; exit 1; fi
if rl_clean "$LOG" | rl_platform_noise | grep -a -E 'panorama/|panorama_castglyph' | grep -a -i -E 'warn|error|unable|cannot|binding loop|TypeError|ReferenceError'; then
    keep=1; echo "$NAME RESULT FAIL (warnings in the log: $LOG)"; exit 1
fi
if [ -n "$FILMDIR" ]; then
    python3 - "$FILMDIR" "${MODE:-light}" <<'PY'
import glob, os, sys
from PIL import Image, ImageDraw
d, mode = sys.argv[1:]
fr = sorted(glob.glob(d + "/frames/f_*.png"))
cols, w, h = 12, 240, 120
sheet = Image.new("RGB", (cols * (w + 2), ((len(fr) + cols - 1) // cols) * (h + 16)), (128, 128, 128))
dr = ImageDraw.Draw(sheet)
for i, p in enumerate(fr):
    x, y = (i % cols) * (w + 2), (i // cols) * (h + 16)
    dr.text((x + 2, y + 2), "%d ms" % (int(os.path.basename(p)[2:-4]) - 10000), fill=(255, 255, 255))
    sheet.paste(Image.open(p).convert("RGB").resize((w, h)), (x, y + 14))
sheet.save(os.path.join(d, "film_%s.png" % mode))
print(os.path.join(d, "film_%s.png" % mode))
PY
fi
printf '%s\n' "$res" | sed "s/^PG RESULT/$NAME RESULT/"
exit $rc
