#!/usr/bin/env bash
# bt_battery_motion_probe.sh -- the Bluetooth battery stripe's MOTION (modules/aerial/bar/AerialBarButton.qml): it grows up from its
# foot, shrinks down to it, yields fast to the traffic figures (whose fade waits for the room: their inks never overlap above 0.3
# presence), and grows back only after regrowDelayMs with no traffic. tools/dev/qml/bt_battery_motion_probe.qml offscreen, judged per
# frame by tools/dev/bt_battery_motion_judge.py.
#
#   tools/dev/bt_battery_motion_probe.sh [OUT_DIR]          BT_BATTERY_MOTION RESULT PASS | FAIL
#   FILM=1 K=1.25 ...   also grab every frame to OUT_DIR/film/<n>.png (the judge still runs)
#   ARM=fade        the stripe fades (opacity) and keeps its length: "grows from its foot" red
#   ARM=nowait      the figures do not wait for the stripe (_present follows trafficShown): "no overlap" red
#   ARM=nodelay     the stripe regrows at once when the traffic ends (_batHold never set): "waits" red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
mkdir -p "${SCRATCH:-/tmp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/bbm.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
OUT="${1:-$D/out}"
mkdir -p "$OUT/film" "$D/config/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/config/theme/state.json"
F=modules/aerial/bar/AerialBarButton.qml
case "${ARM:-}" in
    "") ARMCMD=true ;;
    fade)    ARMCMD="sed -i 's|        height: root._batDrawn|        height: root.batteryLength\n        opacity: root.batteryPresence|' $F" ;;
    nowait)  ARMCMD="sed -i 's|root.trafficShown \&\& root._batDrawn <= root.figuresAfterLen ? 1 : 0|root.trafficShown ? 1 : 0|' $F" ;;
    nodelay) ARMCMD="sed -i 's|            root._batHold = true;|            root._batHold = false;|' $F" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-bbm}"
cat > "$D/run.sh" <<RUN_EOF
cp $F $D/orig.qml
$ARMCMD
if [ -n "${ARM:-}" ] && cmp -s $F $D/orig.qml; then echo ARMLOST; exit 3; fi
env XDG_CONFIG_HOME=$D/config XDG_STATE_HOME=$D/state XDG_CACHE_HOME=$D/cache QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
    QML_DISABLE_DISTANCEFIELD=1 WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off OUT_DIR=$OUT K=${K:-1} FILM=${FILM:-0} \
    timeout 150 quickshell -p tools/dev/qml/bt_battery_motion_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'BBM .*' > "$OUT/bbm.log"
if ! grep -aq 'BBM done' "$OUT/bbm.log"; then
    cp "$D/log" "$OUT/raw.log"; echo "BT_BATTERY_MOTION RESULT FAIL (no result: $OUT/raw.log)"; exit 1
fi
w=$(rl_clean "$D/log" | rl_platform_noise | grep -a -E 'WARN|ERROR|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | grep -v 'quickshell.tooling\|outside of the config folder\|setting window masks' | head -3)
[ -z "$w" ] || echo "BBM warnings: $w"
python3 tools/dev/bt_battery_motion_judge.py "$OUT/bbm.log" "${w:+warn}"
