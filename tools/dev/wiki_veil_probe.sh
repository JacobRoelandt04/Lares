#!/usr/bin/env bash
# wiki_veil_probe.sh -- the wiki veils (modules/wiki/WikiVeil.qml: what an article with no picture shows) held to what they
# promise: the same article is the same picture and another article another one; each of the five patterns draws, moves, and
# never jumps between two frames; a logo's plate is flat; the family's hue reaches the deepest shade; the clock stops when
# the veil is hidden, under a theme crossfade and for an idle shell; a thumbnail is still; a photograph builds no veil and a
# lost one shows it; node and QV4 pick alike. Offscreen, in the sandbox, private homes.
#
#   tools/dev/wiki_veil_probe.sh               WIKI_VEIL RESULT PASS | FAIL
#   ARM=<name> tools/dev/wiki_veil_probe.sh    one fault in the sandbox copy; must fail on its own check:
#   ARM=all ...  every arm in turn: WIKI_VEIL ARMS RESULT PASS when each failed on its own check
#     nohold      a hidden veil keeps ticking                    -> "WVP FAIL clock: hidden"
#     nocross     a veil ticks through a theme crossfade         -> "WVP FAIL clock: under a theme crossfade"
#     thumbruns   the thumbnail's veil runs                      -> "WVP FAIL thumb: the thumbnail's veil is still"
#     noidle      an idle shell does not stop the card's veil    -> "WVP FAIL card: an idle shell"
#     photoveil   a veil is built under every photograph         -> "WVP FAIL card: a photograph builds no veil"
#     nofallback  a photograph whose file is gone shows nothing  -> "WVP FAIL card: a photograph whose file is gone"
#     onepattern  every article gets the first pattern           -> "WVP FAIL pick: each of the five"
#     snap        a maze wall snaps to its new place (rebaked)   -> "WVJ FAIL maze: nothing jumps"
#     noplate     the pattern runs under the logo (rebaked)      -> "WVJ FAIL contours: the plate is flat"
#     nohue       the family's hue is not mixed in               -> "WVJ FAIL contours: the hue reaches"
#     windowdither the dither is the window's, not the item's (rebaked) -> "WVJ FAIL .*: the same article is the same picture"
#     frozen      the shader's time stands still                 -> "WVJ FAIL contours: it moves"
#   KEEP=1 keeps the work dir (the pictures).
{
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
ARMS="nohold nocross thumbruns noidle photoveil nofallback onepattern snap noplate nohue windowdither frozen"
if [ "${ARM:-}" = all ]; then   # every arm, each in a fresh sandbox sync; PASS only when each failed on its own needle
    rc=0
    for a in ${ONLY_ARMS:-$ARMS}; do
        out=$(ARM="$a" bash "$0" 2>&1); printf '%s\n' "$out" | grep -a '^ARM ' | tail -1
        printf '%s\n' "$out" | grep -aq "^ARM $a: failed as it must" || rc=1
    done
    [ "$rc" -eq 0 ] && echo "WIKI_VEIL ARMS RESULT PASS" || echo "WIKI_VEIL ARMS RESULT FAIL"
    exit "$rc"
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/wvp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
V=modules/wiki/WikiVeil.qml
G=modules/wiki/shaders/wiki_veil.glsl
BAKE="tools/dev/bake_shaders.sh wiki_veil > /dev/null"
ARMCMD="" NEEDLE=""
# arm <file> <exact text> <replacement>: the text must be there (an anchor that is gone fails the arm, never passes it)
arm() { ARMCMD="python3 -B -c 'import sys; f, a, b = sys.argv[1:4]; s = open(f).read(); sys.exit(\"ARM anchor gone: \" + a) if s.count(a) != 1 else open(f, \"w\").write(s.replace(a, b))' $(printf '%q ' "$@")${4:+}"; }
case "${ARM:-}" in
    "") ;;
    nohold) arm $V 'root.running && root.visible && root.width > 0' 'root.running && root.width > 0'; NEEDLE='WVP FAIL clock: hidden' ;;
    nocross) arm $V ' && !Theme.crossfading' ''; NEEDLE='WVP FAIL clock: under a theme crossfade' ;;
    thumbruns) arm modules/wiki/WikiCompactCard.qml 'groundColor: face.well
                            running: false' 'groundColor: face.well
                            running: true'; NEEDLE="WVP FAIL thumb: the thumbnail's veil is still" ;;
    noidle) arm modules/wiki/WikiPopup.qml 'veilRunning: root.windowActive' 'veilRunning: true'; NEEDLE='WVP FAIL card: an idle shell' ;;
    photoveil) arm modules/wiki/WikiCarousel.qml 'active: pic._veiled' 'active: true'; NEEDLE='WVP FAIL card: a photograph builds no veil' ;;
    nofallback) arm modules/wiki/WikiCarousel.qml 'pic._kind !== "photo" || photo.status === Image.Error' 'pic._kind !== "photo"'; NEEDLE='WVP FAIL card: a photograph whose file is gone' ;;
    onepattern) arm modules/wiki/WikiVeilPick.js 'NAMES[Math.min(NAMES.length - 1, Math.floor(next() * NAMES.length))]' 'NAMES[Math.min(0, Math.floor(next() * NAMES.length))]'; NEEDLE='WVP FAIL pick: each of the five' ;;
    snap) arm modules/wiki/shaders/wiki_veil_maze.frag 'float e = u * u * (3.0 - 2.0 * u);' 'float e = step(0.5, u);'; ARMCMD="$ARMCMD && $BAKE"; NEEDLE='WVJ FAIL maze: nothing jumps' ;;
    noplate) arm $G 'return smoothstep(clearing.z, clearing.z + clearing.w, length(ip - clearing.xy));' 'return 1.0;'; ARMCMD="$ARMCMD && $BAKE"; NEEDLE='WVJ FAIL contours: the plate is flat' ;;
    nohue) arm $V 'Mix.c(Theme.shadowDeep, root.hue, root.style.hueShare)' 'Mix.c(Theme.shadowDeep, root.hue, 0)'; NEEDLE='WVJ FAIL contours: the hue reaches' ;;
    windowdither) arm $G 'dot(floor(ip / veilPx), vec2(0.06711056, 0.00583715))' 'dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))'; ARMCMD="$ARMCMD && $BAKE"; NEEDLE='WVJ FAIL .*: the same article is the same picture' ;;
    frozen) arm $V 'property real time: root.time' 'property real time: root.pick.t0'; NEEDLE='WVJ FAIL contours: it moves' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache" "$D/data" "$D/home" "$D/out"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
# In the copy: the arm, the probe (its pictures into $D/out), node's picks, the judge. The names are the judge's rows.
run='set -e; '"${ARMCMD:+$ARMCMD; }"'node tools/dev/wiki_veil_cases.js > '"$D"'/node.txt; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PROBE=1 WVP_OUT='"$D/out"' HOME='"$D/home"' XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' XDG_DATA_HOME='"$D/data"' timeout 240 quickshell -p tools/dev/qml/wiki_veil_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-wikiveil}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'WVP \(ok\|FAIL\).*'
extra=0
if rl_has "$D/log" 'WVP RESULT'; then
    # node and QV4 pick alike
    rl_clean "$D/log" | grep -a -o 'WVP PICK .*' | sed 's/^WVP //' > "$D/qml.txt"
    if [ -s "$D/node.txt" ] && cmp -s "$D/node.txt" "$D/qml.txt"; then echo "WVP ok   pick: node and QV4 agree on $(wc -l < "$D/qml.txt") keys"
    else echo "WVP FAIL pick: node and QV4 agree  [$(diff "$D/node.txt" "$D/qml.txt" | head -2 | tr '\n' ' ')]"; extra=1; fi
    python3 -B tools/dev/wiki_veil_judge.py "$D/out" contours links ripples maze cells > "$D/judge" 2>&1 || extra=1
    grep -a '^WVJ \(ok\|FAIL\)' "$D/judge" || { echo "WVJ FAIL the judge ran  [$(tail -1 "$D/judge")]"; extra=1; }
    # the probe's own noise: the lost photograph's file is meant to be missing
    w=$(rl_clean "$D/log" | rl_platform_noise | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError|is not a type" | grep -a -v "wiki-veil-probe.jpg" | sort | uniq -c | head -8)
    if [ -n "$w" ]; then printf '%s\n' "$w"; echo "WVP FAIL the log is clean"; extra=1; fi
fi
if [ -n "${ARM:-}" ]; then
    if { rl_clean "$D/log"; cat "$D/judge" 2>/dev/null; } | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if grep -a -q 'ARM anchor gone' "$D/log"; then echo "ARM $ARM: its anchor is gone ($(grep -a -o 'ARM anchor gone.*' "$D/log" | head -1))"; exit 1; fi
    if ! rl_has "$D/log" 'WVP RESULT'; then KEEP=1; cp "$D/log" "${D%/*}/wvp-arm-$ARM.log"; echo "ARM $ARM: the armed copy did not load -- it proves nothing (${D%/*}/wvp-arm-$ARM.log)"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result WIKI_VEIL "$D/log" 'WVP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
[ "$extra" = 0 ] || { rc=1; res="WVP RESULT FAIL (the judge, the picks or the log)"; }
printf '%s\n' "$res" | sed 's/^WVP RESULT/WIKI_VEIL RESULT/'
exit $rc
}
