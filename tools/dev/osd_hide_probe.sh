#!/usr/bin/env bash
# osd_hide_probe.sh -- a card the user hides (the caption's hide button: tucked into its bar, the pill's ball) and the pill's window
# (every kind fits it): tools/dev/qml/osd_hide_probe.qml, offscreen (QT_QUICK_BACKEND=rhi), in a sandbox copy, a private
# XDG_CONFIG_HOME seeded with the theme, the pointer through QtTest. Then the pixels of the caption pill and the parked ball in their
# frame at k 1 and 1.25: the capsule's two rounded ends inside the frame (a window cuts what is past its edge, straight).
#
#   tools/dev/osd_hide_probe.sh [OUT_DIR]          OSDHIDE RESULT PASS | FAIL   (OUT_DIR keeps the four grabs; default: a temp dir)
#   MODE=dark ...                                  the theme's mode (default light)
#   ARM=oldextent    the window counts every kind but the caption (as it did): "every kind's pill fits" and the pixels' "ends inside" red
#   ARM=nozone       the hover zone is the sliver alone: "the pointer moving on the slim bar beside the sliver" red
#   ARM=nomotion     the bar's arm takes a hover with no motion: "a pointer resting on the zone as it tucks" red
#   ARM=notuck       the engine ignores `tucked`: "tucked: osdTuckPx out of the bar" red
#   ARM=nozonemask   the OSD's input rect is the sliver alone (the outlet beside it takes no input): "the input region holds the zone" red
#   LIVE=1           + the pill's REAL window in a nested Hyprland (tools/dev/lock_env.sh, LOCK_ENV=osdhide; tools/dev/qml/
#                    osd_pill_live_probe.qml): a press inside its rect but off its zones reaches the window below, the hide button
#                    is pressed through the window's input region, the ball parks under a resting pointer without coming back,
#                    and a pointer moving on it brings it back
#   LIVE=1 ARM=nomask  the window's region without the hide button: "live: the hide button is pressed through the region" red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/ohp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
OUT="${1:-$D/grabs}"
mkdir -p "$OUT" "$D/config/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/config/theme/state.json"

ARMCMD="" NEEDLE="" F=""
case "${ARM:-}" in
    "") ;;
    oldextent) F=modules/osd/OsdStyle.qml
               ARMCMD="sed -i 's|for (const k of Kinds.kindIds()) {|for (const k of Kinds.kindIds().filter(x => x !== \"caption\")) {|' $F"
               NEEDLE="OHP FAIL every kind's pill fits the pill's window" ;;
    nozone)    F=modules/bar/gooey/GooeyEngine.qml
               ARMCMD="sed -i 's|if (!(thickness <= engine.osdTuckEdgeMax))|if (true)|' $F"
               NEEDLE="OHP FAIL the pointer moving on the slim bar beside the sliver brings it back out" ;;
    nomotion)  F=modules/osd/OsdOwner.qml
               ARMCMD="sed -i 's|        id: tuckArm|        id: tuckArm\n        requireMotion: false|' $F"
               NEEDLE="OHP FAIL a pointer resting on the zone as it tucks does not bring it back" ;;
    notuck)    F=modules/bar/gooey/GooeyEngine.qml
               ARMCMD="sed -i 's|engine._osdTucked = req.tucked === true;|engine._osdTucked = false;|' $F"
               NEEDLE="OHP FAIL tucked: osdTuckPx out of the bar" ;;
    nozonemask) F=modules/bar/gooey/GooeyEngine.qml
               ARMCMD="sed -i 's|maskRects.push(zone ? {|maskRects.push(false ? {|' $F"
               NEEDLE="OHP FAIL the input region holds the zone" ;;
    nomask)    F=modules/osd/OsdPillWindow.qml
               ARMCMD="sed -i '/Region { item: frame.hideZone }/d' $F"
               NEEDLE="OHP FAIL live: the hide button is pressed through the window's region"
               [ "${LIVE:-}" = 1 ] || { echo "ARM nomask needs LIVE=1"; exit 2; } ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-osd-hide}"
# the arm is applied INSIDE the sandbox copy, by the same call that starts quickshell (the copy is re-synced on every call)
cat > "$D/run.sh" <<RUN_EOF
${F:+cp $F $D/orig.qml}
${ARMCMD:-true}
if [ -n "${ARM:-}" ] && cmp -s $F $D/orig.qml; then echo ARMLOST; exit 3; fi
env XDG_CONFIG_HOME=$D/config XDG_STATE_HOME=$D/state XDG_CACHE_HOME=$D/cache QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
    WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off OUT_DIR=$OUT timeout 120 quickshell -p tools/dev/qml/osd_hide_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'OHP .*' | grep -a -v 'OHP RESULT'

# THE LIVE HALF: the real window on a real compositor, the env's virtual pointer (whole layout px, LOCK-1 is 2880 x 1620 at 0,0)
: > "$D/live.res"
if [ "${LIVE:-}" = 1 ]; then
    export LOCK_ENV="${LOCK_ENV:-osdhide}"
    OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "OSDHIDE RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
    LL="$D/live.log"
    cat > "$D/live.sh" <<LIVE_EOF
${F:+cp $F $D/orig.qml}
${ARMCMD:-true}
tools/dev/lock_env.sh run quickshell -p tools/dev/qml/osd_pill_live_probe.qml > $LL 2>&1 &
QP=\$!
pt() { tools/dev/lock_env.sh point "\$@"; }
waitfor() { for i in \$(seq 1 \$2); do grep -aq "\$1" $LL && return 0; sleep 0.1; done; return 1; }
waitfor "OHL out" 300 || { kill \$QP; exit 0; }
read zx zy zw zh wx wy ww wh <<< "\$(grep -a -o 'OHL out .*' $LL | head -1 | sed 's/OHL out //; s/ window / /')"
# a press in the window's rect, off its zones
pt "abs \$((wx + 40)) 47 2880 1620" "abs \$((wx + 43)) 50 2880 1620" click
waitfor "OHL under" 30
# the hide button, then the pointer to where the ball will park, resting
hx=\$((wx + zx + zw / 2)); hy=\$((wy + zy + zh / 2)); bx=\$((wx + ww / 2))
pt "abs \$((hx - 3)) \$hy 2880 1620" "abs \$hx \$hy 2880 1620" click "abs \$bx 6 2880 1620"
waitfor "OHL parked" 60
sleep 1.2
grep -ac 'OHL revealed' $LL > $D/rested.count
# a hand moving on the ball (two steps: the first is where the enter lands)
pt "abs \$((bx + 2)) 7 2880 1620"
sleep 0.2
pt "abs \$((bx + 4)) 5 2880 1620"
waitfor "OHL revealed" 30
sleep 0.3
kill \$QP; wait \$QP 2> /dev/null; true
LIVE_EOF
    tools/dev/sandbox.sh bash "$D/live.sh" > "$D/live.run" 2>&1
    tools/dev/lock_env.sh down > /dev/null 2>&1
    rl_clean "$LL" | grep -a -o 'OHL .*'
    lv() { if [ "$2" = 1 ]; then echo "OHP ok   live: $1"; else echo "OHP FAIL live: $1"; fi; }
    {
        lv "the pill came out in its window" "$(rl_has "$LL" 'OHL out' && echo 1 || echo 0)"
        lv "a press in the window's rect off its zones reaches the window below" "$(rl_has "$LL" 'OHL under' && echo 1 || echo 0)"
        lv "the hide button is pressed through the window's region" "$(rl_has "$LL" 'OHL hidden' && echo 1 || echo 0)"
        lv "the ball parks" "$(rl_has "$LL" 'OHL parked' && echo 1 || echo 0)"
        rested=$(cat "$D/rested.count" 2> /dev/null || echo x)
        lv "a pointer resting where the ball parks does not bring it back" "$([ "$rested" = 0 ] && rl_has "$LL" 'OHL parked' && echo 1 || echo 0)"
        lv "a pointer moving on the ball brings the pill back" "$([ "$rested" = 0 ] && [ "$(grep -ac 'OHL revealed' "$LL")" -gt 0 ] && echo 1 || echo 0)"
        w=$(rl_clean "$LL" | rl_platform_noise | grep -a -E 'WARN|ERROR|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | grep -v 'quickshell.tooling\|outside of the config folder' | head -3)
        lv "no warnings in the live log${w:+ ($w)}" "$([ -z "$w" ] && echo 1 || echo 0)"
    } > "$D/live.res"
    cat "$D/live.res"
fi

# the pixels: in each grab the capsule's middle row starts and ends on the ground inside the frame
PIX=$(python3 - "$OUT" <<'PY'
import os, sys
from PIL import Image
out = sys.argv[1]
ground = (0x00, 0xA0, 0x40)
bad = 0
for name in ("pill_k1", "pill_k125", "ball_k1", "ball_k125"):
    p = os.path.join(out, name + ".png")
    if not os.path.exists(p):
        print("OHP FAIL pixels: no grab " + name); bad += 1; continue
    im = Image.open(p).convert("RGB"); W, H = im.size; px = im.load()
    far = lambda c: max(abs(a - b) for a, b in zip(c, ground)) > 40
    if name.startswith("pill"):
        # the capsule's middle row: the first and last columns are ground (its rounded ends are inside), and it has surface
        rows = [y for y in range(H) if sum(1 for x in range(W) if far(px[x, y])) > W // 3]
        if not rows:
            print("OHP FAIL pixels %s: no capsule drawn" % name); bad += 1; continue
        y = rows[len(rows) // 2]
        ends = far(px[0, y]) or far(px[W - 1, y])
        inked = [x for x in range(W) if far(px[x, y])]
        ok = not ends and inked[0] > 2 and inked[-1] < W - 3
        print("OHP %s pixels %s: the capsule's ends are inside its window (row %d: ink %d..%d of %d)" % ("ok  " if ok else "FAIL", name, y, inked[0], inked[-1], W))
        bad += 0 if ok else 1
    else:
        # the parked ball: ink in the frame's top rows only, cut by its top edge (under half the ball on screen)
        inked = [(x, y) for y in range(H) for x in range(W) if far(px[x, y])]
        top = min(y for _, y in inked) if inked else -1
        bottom = max(y for _, y in inked) if inked else -1
        ok = bool(inked) and top == 0 and bottom < 0.5 * H
        print("OHP %s pixels %s: the ball is cut by the screen's top (ink rows %d..%d of %d)" % ("ok  " if ok else "FAIL", name, top, bottom, H))
        bad += 0 if ok else 1
print("OHP pixels bad=%d" % bad)
PY
)
printf '%s\n' "$PIX" | grep -v 'pixels bad='
pixbad=$(printf '%s\n' "$PIX" | sed -n 's/^OHP pixels bad=//p')
warn=$(rl_clean "$D/log" | rl_platform_noise | grep -a -E 'WARN|ERROR|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | grep -v 'quickshell.tooling\|outside of the config folder\|does not support setting window masks' | head -5)
[ -z "$warn" ] || echo "OHP FAIL warnings: $warn"

if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if { rl_clean "$D/log"; printf '%s\n' "$PIX"; cat "$D/live.res"; } | grep -a -q -F "$NEEDLE"; then echo "ARM $ARM: failed as it must ($NEEDLE)"; exit 0; fi
    rl_has "$D/log" 'OHP RESULT' || { KEEP=1; echo "ARM $ARM: the armed copy did not load ($D/log) -- it proves nothing"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result OSDHIDE "$D/log" 'OHP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
livebad=$(grep -c '^OHP FAIL' "$D/live.res")
if [ "$rc" = 0 ] && [ "${pixbad:-1}" = 0 ] && [ -z "$warn" ] && [ "$livebad" = 0 ]; then
    echo "$res" | sed 's/^OHP RESULT/OSDHIDE RESULT/'; exit 0
fi
echo "OSDHIDE RESULT FAIL ($(echo "$res" | sed 's/^OHP RESULT //'); pixels bad ${pixbad:-?}; live bad $livebad${warn:+; warnings})"
exit 1
