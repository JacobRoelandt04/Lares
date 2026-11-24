#!/usr/bin/env bash
# The Bluetooth battery stripe's rules on fixtures (tools/dev/qml/bt_battery_probe.qml): lowest of several, the lower bud (never the
# case), none -> collapsed, charging, the level edges; then the pill: presence, icons that never move, theme-token colours.
#
#   tools/dev/bt_battery_probe.sh      (re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#   ARM=highest   the stripe shows the HIGHEST charge, not the lowest (the "several devices" rule): the probe must FAIL
#
# The last line is BT_BATTERY RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARM="${ARM:-}" tools/dev/bt_battery_probe.sh
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
HERE=$(pwd)
if [ "${ARM:-}" = highest ]; then
    sed -i 's/if (!low || f.pct < low.pct)/if (!low || f.pct > low.pct)/' modules/aerial/bar/BtBattery.js
    grep -q 'f.pct > low.pct' modules/aerial/bar/BtBattery.js || { echo "BT_BATTERY RESULT FAIL (arm anchor gone)"; exit 1; }
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/btbatprobe.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$WORK/cfg/theme/state.json"
log="${KEEPLOG:-$WORK/run.log}"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
    timeout -k 5 90 quickshell -n -p "$HERE/tools/dev/qml/bt_battery_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a "BT_BATTERY FAIL" | head -20
rl_clean "$log" | grep -a -E "Unable to assign|binding loop|Cannot assign|is not a type" | sort -u | head -5
rl_result BT_BATTERY "$log" "BT_BATTERY RESULT .*"
