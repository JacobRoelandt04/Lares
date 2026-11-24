#!/usr/bin/env bash
# fade_edges_probe.sh -- every list's edge fade covers what its clip lets through, to the device pixel
# (feedback/stocks.md "bottom fadout in list misaligned": the holdings list's foot fade stood one device pixel short of the
# list's clip, and rows showed through that line; the weather strip's right end had shown the same).
#
#   tools/dev/fade_edges_probe.sh [outdir]          FADE_EDGES RESULT PASS | FAIL (<n> band ends leaking of <n>)
#   SITES="stocks weather"                          the sites (tools/dev/qml/fade_edges_probe.qml; default: all of them)
#   PHASES=<n>                                      the sweep: n device-pixel phases k/n (x and y together), default 64
#                                                   (the weather popup: WEATHER_PHASES, 32: each cell is a whole popup)
#   SCALE=<s>                                       the frame scale (1.25, the user's `scale.global`); the window's ratio is
#                                                   1.25 on top (QT_SCALE_FACTOR offscreen, the nested screen's scale in ENV)
#   ENV=1                                           a real window in a nested Hyprland (tools/dev/lock_env.sh, LOCK_ENV
#                                                   fadeedge, LOCK-1 at scale 1.25), read by grim; default: offscreen, a grab
#   TREE=<dir>                                      another tree (a `git archive` of an old revision): the same sweep with this
#                                                   harness and judge copied in -- the before of a before/after
#   REST=1 [REST_BASE=<dir>]                       the sites at rest, nothing armed, plain-raster text (QML_DISABLE_DISTANCEFIELD):
#                                                   the pictures only; with REST_BASE (another REST=1 run, of the old tree) every
#                                                   differing pixel must lie on a dressing's edge line, where a seal can land
#                                                   (tools/dev/fade_edges_rest.py) -- the frames the fix must not touch
#   ARM=noseal                                      the bands' seal is 0 again (ScrollDressing + CarvedListDressing, in the
#                                                   sandbox copy): the sweep must go red on its own needle (a LEAK line);
#                                                   prints "ARM noseal: failed as it must" and exits 0, or DID NOT FAIL, 1
#   ARM=flush                                       the picker's viewport is the whole box again (`_rim` 0 in PickerGrid, in the sandbox
#                                                   copy: the cut band's outline IS the clip, so its feather and inset leave the first
#                                                   rows bare): the `picker` site must go red on its own LEAK lines (feedback/picker.md:
#                                                   a slit of glyphs under the box's border)
#
# WHAT IT MEASURES. Each site's dressings get a magenta sheet over their whole content and are scrolled so both bands are fully on;
# the site stands under the frame's scale at n device-pixel phases. A pixel past a band's opaque end that is more than 30 %
# magenta is content the clip let through (tools/dev/fade_edges.py). THE CAUSE (ScrollDressing's header): the clip is a scissor
# the renderer rounds on the CPU, a band a quad the GPU rasterises by pixel centres; where an edge passes exactly through a row of
# pixel centres the two can round opposite ways, which way depending on the render path and float noise. A sweep of 64 phases
# puts every edge on such a tie several times. Offscreen (a grab renders into a texture, like a layer) is where the old code
# leaked in this sweep; ENV=1 is the window path the user's desktop draws in.
#
# The verdict is the last line (tools/dev/result_lib.sh): a site that did not load, found no dressing or wrote no picture FAILS.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/fade_edges}")"
mkdir -p "$OUT"
SITES="${SITES:-synthetic synthetic-h synthetic-lead synthetic-cut carved picker stocks weather}"
N="${PHASES:-64}"
NW="${WEATHER_PHASES:-32}"
SCALE="${SCALE:-1.25}"
TREE="${TREE:-}"
SB="${SANDBOX:-/tmp/lares-sandbox-fade-edges}"

phases() { python3 -c "import sys; n=int(sys.argv[1]); print(','.join('%g:%g' % (k / n, k / n) for k in range(n)))" "$1"; }

# The tree that runs: this one, or another with this harness and judge in it.
SRC="$ROOT"
if [ -n "$TREE" ]; then
    SRC="$(realpath "$TREE")"
    mkdir -p "$SRC/tools/dev/qml"
    cp tools/dev/qml/fade_edges_probe.qml "$SRC/tools/dev/qml/"
    cp tools/dev/fade_edges.py "$SRC/tools/dev/"
    SB="$SB-tree"
fi

ARMCMD=""
case "${ARM:-}" in
    "") ;;
    noseal) ARMCMD="sed -i 's|readonly property real _seal: 1 / 64 / Math.max(0.25, deviceScale.value)|readonly property real _seal: 0|' modules/common/components/ScrollDressing.qml modules/common/components/CarvedListDressing.qml && [ \$(grep -c 'readonly property real _seal: 0\$' modules/common/components/ScrollDressing.qml modules/common/components/CarvedListDressing.qml | grep -c ':1\$') -eq 2 ] || { echo 'ARM noseal: the anchor is gone'; exit 3; }" ;;
    flush) ARMCMD="sed -i 's|readonly property real _rim: 3|readonly property real _rim: 0|' modules/picker/PickerGrid.qml && grep -q 'readonly property real _rim: 0' modules/picker/PickerGrid.qml || { echo 'ARM flush: the anchor is gone'; exit 3; }" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

mkdir -p "$OUT/cfg/theme" "$OUT/state"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE_THEME:-light}" > "$OUT/cfg/theme/state.json"

rc=0
noload=""      # the first site whose picture never came: its log, for the no-result verdict
if [ "${ENV:-}" != 1 ]; then
    # ---- offscreen: one sandbox call, every site inside it, the arm patched into the copy it stands in ------------------
    run='set -u; '"${ARMCMD:+$ARMCMD; }"'
    for site in '"$SITES"'; do
        n='"$N"'; [ "$site" = weather ] && n='"$NW"'
        cols=8; [ "$site" = weather ] && cols=6
        P=$(python3 -c "import sys; n=int(sys.argv[1]); print(\",\".join(\"%g:%g\" % (k / n, k / n) for k in range(n)))" $n)
        rm -f "'"$OUT"'/$site.png"
        env SITE=$site PHASES=$P COLS=$cols SCALE='"$SCALE"' MODE=grab OUT="'"$OUT"'/$site.png" QT_SCALE_FACTOR=1.25 \
            REST='"${REST:-}"' ${REST:+QML_DISABLE_DISTANCEFIELD=1} \
            XDG_CONFIG_HOME="'"$OUT"'/cfg" XDG_STATE_HOME="'"$OUT"'/state" QT_QUICK_BACKEND=rhi \
            timeout 240 quickshell -p tools/dev/qml/fade_edges_probe.qml > "'"$OUT"'/$site.log" 2>&1
        echo "ran $site"
    done'
    (cd "$SRC" && QT_QPA_PLATFORM=offscreen SANDBOX="$SB" tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen bash -c "$run") > "$OUT/run.log" 2>&1
    if grep -q "ARM noseal: the anchor is gone" "$OUT/run.log"; then cat "$OUT/run.log"; echo "FADE_EDGES RESULT FAIL (the arm's anchor is gone)"; exit 1; fi
    if [ -n "${REST:-}" ]; then
        for site in $SITES; do rl_clean "$OUT/$site.log" > "$OUT/$site.clean.log"; done
        if [ -z "${REST_BASE:-}" ]; then ls "$OUT"/*.png; echo "FADE_EDGES REST pictures in $OUT"; exit 0; fi
        python3 tools/dev/fade_edges_rest.py "$(realpath "$REST_BASE")" "$OUT" $SITES
        exit $?
    fi
    for site in $SITES; do
        rl_clean "$OUT/$site.log" > "$OUT/$site.clean.log"
        if [ ! -s "$OUT/$site.png" ]; then
            rl_clean "$OUT/$site.log" | grep -a -E "ERROR|caused by|Unsupported" | head -4
            echo "FADE_EDGES $site FAIL (no picture: $OUT/$site.log)"; rc=1; [ -n "$noload" ] || noload="$OUT/$site.log"; continue
        fi
        python3 tools/dev/fade_edges.py "$OUT/$site.png" "$OUT/$site.clean.log" --label "$site" > "$OUT/$site.judge" 2>&1 || rc=1
        grep -E "^(LEAK|FAIL|TABLE [a-z])" "$OUT/$site.judge"
        tail -1 "$OUT/$site.judge"
    done
else
    # ---- a real window in a nested Hyprland: the copy made once, patched, then every window started on it --------------
    E="$ROOT/tools/dev/lock_env.sh"
    export LOCK_ENV="${LOCK_ENV:-fadeedge}"
    (cd "$SRC" && SANDBOX="$SB" tools/dev/sandbox.sh true) > /dev/null || { echo "FADE_EDGES RESULT FAIL (no sandbox)"; exit 1; }
    if [ -n "$ARMCMD" ]; then (cd "$SB" && bash -c "$ARMCMD") || { echo "FADE_EDGES RESULT FAIL (the arm's anchor is gone)"; exit 1; }; fi
    up=0
    if ! "$E" status | grep -q " up:"; then "$E" up > "$OUT/env.log" 2>&1 || { cat "$OUT/env.log"; echo "FADE_EDGES RESULT FAIL (the nested env did not come up)"; exit 1; }; up=1; fi
    # A large headless screen at the user's scale, so a chunk of cells fits in one window: 4608 x 2592 logical.
    "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", mode = "5760x3240@60", position = "0x0", scale = 1.25 })' > /dev/null
    for site in $SITES; do
        n=$N; [ "$site" = weather ] && n=$NW
        read -r cw ch < <(python3 -c "
s={'weather':(740,960),'stocks':(480,310),'picker':(580,400)}.get('$site',(300,260)); print(s[0],s[1])")
        cols=$(python3 -c "print(max(1, int((4608 - 80) // ($cw * $SCALE))))")
        per=$(python3 -c "print(max(1, $cols * int((2592 - 120) // ($ch * $SCALE))))")
        all=$(phases "$n")
        IFS=, read -r -a ph <<< "$all"
        k=0; part=0
        : > "$OUT/$site.judge"
        while [ $k -lt ${#ph[@]} ]; do
            chunk=$(IFS=,; echo "${ph[*]:$k:$per}")
            log="$OUT/$site.$part.log"; png="$OUT/$site.$part.png"
            "$E" run env SITE="$site" PHASES="$chunk" COLS="$cols" SCALE="$SCALE" MODE=hold \
                XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" quickshell -p "$SB/tools/dev/qml/fade_edges_probe.qml" > "$log" 2>&1 &
            pid=$!
            for _ in $(seq 1 300); do rl_has "$log" "READY" && break; kill -0 $pid 2> /dev/null || break; sleep 0.2; done
            if rl_has "$log" "READY"; then
                sleep 0.6      # the READY frame is presented
                "$E" shot "$png"
            fi
            kill $pid 2> /dev/null; wait $pid 2> /dev/null
            rl_clean "$log" > "$log.clean"
            if [ ! -s "$png" ]; then echo "FADE_EDGES $site FAIL (no picture: $log)"; rc=1; [ -n "$noload" ] || noload="$log"; k=$((k + per)); part=$((part + 1)); continue; fi
            # The window's origin: the corner marker (8 x 8 logical, green), whose top-left corner the window's rounding may hide.
            origin=$(python3 - "$png" <<'PY'
import sys
from PIL import Image
import numpy as np
Image.MAX_IMAGE_PIXELS = None
a = np.array(Image.open(sys.argv[1]).convert("RGB").crop((0, 0, 400, 400))).astype(int)
g = np.argwhere((a[:, :, 1] > 200) & (a[:, :, 0] < 80) & (a[:, :, 2] < 80))
y1, x1 = g.max(axis=0)
print("%d,%d" % (x1 + 1 - 10, y1 + 1 - 10))
PY
)
            python3 tools/dev/fade_edges.py "$png" "$log.clean" --origin "$origin" --label "$site.$part" >> "$OUT/$site.judge" 2>&1 || rc=1
            k=$((k + per)); part=$((part + 1))
        done
        grep -E "^(LEAK|FAIL)" "$OUT/$site.judge"
        grep -E "^FADE_EDGES" "$OUT/$site.judge"
    done
    [ "$up" = 1 ] && [ -z "${KEEP:-}" ] && "$E" down > /dev/null 2>&1
fi

leaking=$(cat "$OUT"/*.judge 2> /dev/null | grep -c "^LEAK")
judged=$(cat "$OUT"/*.judge 2> /dev/null | grep -o "([0-9]* band ends judged" | grep -o "[0-9]*" | paste -sd+ | bc 2> /dev/null)
if [ -n "${ARM:-}" ]; then
    if [ "$ARM" = flush ] && [ "$leaking" -gt 0 ]; then
        grep -q "^LEAK picker" "$OUT"/*.judge 2> /dev/null || { echo "ARM flush: DID NOT FAIL on the picker -- no LEAK line for it"; exit 1; }
    fi
    if [ "$leaking" -gt 0 ]; then echo "ARM $ARM: failed as it must ($leaking band ends leaking)"; exit 0; fi
    if [ -n "$noload" ] || [ "${judged:-0}" -eq 0 ]; then echo "ARM $ARM: the armed copy did not load -- it proves nothing (${noload:-nothing judged})"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- no LEAK line, the probe cannot see it"; exit 1
fi
# A site that drew no picture is a run without a result (tools/dev/result_lib.sh): its log's load errors, then the verdict.
if [ -n "$noload" ]; then
    rl_noresult FADE_EDGES "$noload"
    exit 1
fi
if [ "$rc" -eq 0 ] && [ "${judged:-0}" -gt 0 ]; then
    echo "FADE_EDGES RESULT PASS (${judged} band ends judged, 0 leaking)"
    exit 0
fi
echo "FADE_EDGES RESULT FAIL (${leaking} band ends leaking of ${judged:-0}; $OUT)"
exit 1
