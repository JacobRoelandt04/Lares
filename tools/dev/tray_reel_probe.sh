#!/usr/bin/env bash
# tray_reel_probe.sh -- the tray's strip in the engine's reel slot (tools/dev/qml/tray_reel_probe.qml: a real GooeyEngine, the idle reel
# and its ReelFollow over a mock IdleService, the window title + tray over the mock tray, a regular popup; offscreen, a sandbox copy).
# The checks are the harness's header (T1..T12); the pixels (T2's ground -- the reel pass's fill --, T9's ring and halo, T10's half-faded ring) are read here, from
# the grabs: a point of the strip over the popup's red must be the surface, a point 2 px off its side the border colour, ...
#
#   tools/dev/tray_reel_probe.sh                    TRAY_REEL RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/tray_reel_probe.sh         the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     asprimary    the strip opens as thePopup again (engine.open)            -> "T1 the popup under it stayed out"
#     noground     the reel pass's fill is clear (no ground over the popup)    -> "T2 the strip's ground covers the popup's red"
#     noescape     Escape goes to the popup under the menu                    -> "T3 Escape (the engine's"
#     noautowait   the cinematic does not wait for the slot                   -> "T6 the auto switch waits"
#     notraywait   the strip does not wait for the cinematic                  -> "T7 the strip did not open while the cinematic"
#     nolockclose  a lock leaves the strip out                                -> "T8 a lock takes the strip away"
#     noreelring   the engine gives the reel pass no plan (no fill, ring or halo over the popup) -> "T9 the strip has its ring over the popup"
#     noreelfade   the pass's ink ignores the strip's fade                        -> "T10 the ring fades with the merge"
#     swapblink    the pass's ink follows the content's fade always (a swap too)   -> "T4 the ring stays through the travel"
#     showpassive  a passive item stays a row when its status changes             -> "T12 a passive item is hidden"
#     nowarm       the engine's prewarm does not warm the pass                    -> "T11 the engine's prewarm draws the reel pass's effect"
# Nothing touches the desktop: offscreen, a private copy of this config, nothing live.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/trayreel.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
# an anchor that matches nothing makes the arm toothless: the patch must change the file
arm() { printf 'cp %s %s.orig && %s && ! cmp -s %s %s.orig || { echo "TRAYREEL ARM anchor gone"; exit 3; }' "$2" "$2" "$1" "$2" "$2"; }
case "${ARM:-}" in
    "") ;;
    asprimary)  NEEDLE="T1 the popup under it stayed out"
                ARMCMD=$(arm "sed -i 's|root.engine.openReel(root.ownerId, root.barId, centre, null, null, stripComp, root.reelStyle.popupWidthFrom);|root.engine.open(root.ownerId, root.barId, centre, null, null, false, stripComp, root.reelStyle.popupWidthFrom);|' modules/windowtray/WindowTrayOwner.qml" modules/windowtray/WindowTrayOwner.qml) ;;
    noground)   NEEDLE="T2 the strip's ground covers the popup's red"
                ARMCMD=$(arm "sed -i 's|        property color fieldColor: cast.field.color\$|        property color fieldColor: \"transparent\"|' modules/bar/gooey/ReelCast.qml" modules/bar/gooey/ReelCast.qml) ;;
    noescape)   NEEDLE="T3 Escape (the engine's"
                ARMCMD=$(arm "sed -i 's|        const rit = R.live \&\& engine.reelKeyboard !== \"none\" ? R.contentItem : null;|        const rit = null;|' modules/bar/gooey/GooeyEngine.qml" modules/bar/gooey/GooeyEngine.qml) ;;
    noautowait) NEEDLE="T6 the auto switch waits"
                ARMCMD=$(arm "sed -i 's|        if (!follow.module.slotTaken()) {|        if (true) {|' modules/bar/reel/ReelFollow.qml" modules/bar/reel/ReelFollow.qml) ;;
    notraywait) NEEDLE="T7 the strip did not open while the cinematic"
                ARMCMD=$(arm "sed -i 's|        if (root.reelBusy) {|        if (false) {|' modules/windowtray/WindowTrayOwner.qml" modules/windowtray/WindowTrayOwner.qml) ;;
    nolockclose) NEEDLE="T8 a lock takes the strip away"
                ARMCMD=$(arm "sed -i 's|^    on_LockedChanged: {\$|    function _noLockClose() {|' modules/windowtray/WindowTrayOwner.qml" modules/windowtray/WindowTrayOwner.qml) ;;
    noreelring) NEEDLE="T9 the strip has its ring over the popup"
                ARMCMD=$(arm "sed -i 's#            reelCastLayer.plan = group.some(i => i >= 0) [&][&] pops.length > 0\$#            reelCastLayer.plan = false#' modules/bar/gooey/GooeyEngine.qml" modules/bar/gooey/GooeyEngine.qml) ;;
    noreelfade) NEEDLE="T10 the ring fades with the merge"
                ARMCMD=$(arm "sed -i 's/        return S.phase === \"opening\" || S.phase === \"closing\" ? S.contentOpacity : 1;/        return 1;/' modules/bar/gooey/ReelCast.qml" modules/bar/gooey/ReelCast.qml) ;;
    showpassive) NEEDLE="T12 a passive item is hidden"
                ARMCMD=$(arm "sed -i 's|rec.statusChanged.connect(root._statusChanged);|rec.statusChanged.connect(root._attentionDirty);|' modules/windowtray/data/TrayModel.qml" modules/windowtray/data/TrayModel.qml) ;;
    nowarm)     NEEDLE="T11 the engine's prewarm draws the reel pass's effect"
                ARMCMD=$(arm "sed -i 's/^        reelCastLayer.warm();\$/        return;/' modules/bar/gooey/GooeyEngine.qml" modules/bar/gooey/GooeyEngine.qml) ;;
    swapblink)  NEEDLE="T4 the ring stays through the travel"
                ARMCMD=$(arm "sed -i 's/        return S.phase === \"opening\" || S.phase === \"closing\" ? S.contentOpacity : 1;/        return S.contentOpacity;/' modules/bar/gooey/ReelCast.qml" modules/bar/gooey/ReelCast.qml) ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache" "$D/grab"
printf '{"theme":"%s","mode":"%s"}\n' "${THEME:-eva}" "${MODE:-light}" > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="'"$D/cfg"'" XDG_STATE_HOME="'"$D/state"'" XDG_CACHE_HOME="'"$D/cache"'" GRAB_DIR="'"$D/grab"'" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 150 quickshell -p tools/dev/qml/tray_reel_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-trayreel}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
# T2's pixel: the surface (the theme's), never the popup's red
g=$(rl_clean "$D/log" | grep -a 'TRAYREEL ground ' | tail -1 | sed 's/^.*TRAYREEL ground //')
if [ -n "$g" ]; then
    set -- $g
    v=$(python3 - "$3" "$1" "$2" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGBA")
x, y = int(sys.argv[2]), int(sys.argv[3])
r, gg, b, a = im.getpixel((x, y))
print("red" if r > 200 and gg < 80 and b < 80 else "surface", (r, gg, b, a))
PY
)
    case "$v" in
        surface*) echo "TRAYREEL ok   T2 the strip's ground covers the popup's red at ($1,$2): $v" >> "$D/log" ;;
        *)        echo "TRAYREEL FAIL T2 the strip's ground covers the popup's red at ($1,$2)  ($v)" >> "$D/log" ;;
    esac
elif [ -z "${ARM:-}" ]; then
    echo "TRAYREEL FAIL T2 the strip's ground covers the popup's red  (no grab)" >> "$D/log"
fi
# T9 / T10's pixels: the ring is the border colour 2 px off the strip's side, the halo darkens the popup's red, and at half the fade the ring
# is about half (the popup's red has no green, the border has plenty: the green channel reads the ring)
while read -r name png a b c d e f g; do
    [ "$png" = FAILED ] && { echo "TRAYREEL FAIL T9 the strip has its ring over the popup  (no grab of $name)" >> "$D/log"; continue; }
    out=$(python3 - "$name" "$png" "$a" "$b" "$c" "$d" "$e" "$f" "$g" <<'PY'
import sys
from PIL import Image
name, png = sys.argv[1], sys.argv[2]
v = sys.argv[3:]
im = Image.open(png).convert("RGBA")
def px(x, y): return im.getpixel((int(x), int(y)))[:3]
def hexrgb(h):
    h = h.lstrip("#")
    if len(h) == 8: h = h[2:]
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
if name == "ring":
    ring, halo, far, bc = px(v[0], v[1]), px(v[2], v[3]), px(v[4], v[5]), hexrgb(v[6])
    ok_ring = all(abs(ring[i] - bc[i]) <= 14 for i in range(3))
    ok_halo = far[0] > 240 and halo[0] < far[0] - 4
    print("ok" if ok_ring and ok_halo else "FAIL", "T9 the strip has its ring over the popup: %s, %s (the border %s), and its halo: %s darker than %s far off" %
          ("the ring pixel" if ok_ring else "NOT the ring pixel", ring, bc, halo, far))
else:
    ring, bc = px(v[0], v[1]), hexrgb(v[2])
    lo, hi = 0.25 * bc[1], 0.75 * bc[1]
    ok = lo < ring[1] < hi
    print("ok" if ok else "FAIL", "T10 a frame held at half the fade shows the ring at about half (green %d, between %d and %d)" % (ring[1], lo, hi))
PY
)
    st=${out%% *}; msg=${out#* }
    [ "$st" = ok ] && echo "TRAYREEL ok   $msg" >> "$D/log" || echo "TRAYREEL FAIL $msg" >> "$D/log"
done < <(rl_clean "$D/log" | grep -a 'TRAYREEL shot ' | sed 's/^.*TRAYREEL shot //')
if [ -z "${ARM:-}" ] && ! rl_has "$D/log" 'TRAYREEL shot ring'; then echo "TRAYREEL FAIL T9 the strip has its ring over the popup  (no grab)" >> "$D/log"; fi
rl_clean "$D/log" | grep -a 'TRAYREEL \(ok\|FAIL\) ' | sed 's/^.*TRAYREEL /TRAYREEL /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'TRAYREEL ARM anchor gone'; then KEEP_D=1; echo "ARM $ARM: its anchor is gone -- the arm proves nothing ($D/log)"; exit 1; fi
    if ! rl_has "$D/log" 'TRAYREEL RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'TRAYREEL FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
fails=$(rl_clean "$D/log" | grep -ac 'TRAYREEL FAIL ')
res=$(rl_result TRAY_REEL "$D/log" 'TRAYREEL RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
[ "$rc" = 0 ] && [ "$fails" -gt 0 ] && { res="TRAY_REEL RESULT FAIL ($fails failed checks: $D/log)"; rc=1; KEEP_D=1; }
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="TRAY_REEL RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res" | sed 's/^TRAYREEL RESULT/TRAY_REEL RESULT/'
exit "$rc"
