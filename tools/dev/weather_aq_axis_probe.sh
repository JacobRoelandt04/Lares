#!/usr/bin/env bash
# weather_aq_axis_probe.sh -- the air-quality chart's axis rule (modules/weather/data/WeatherSeries.js, "RELIEF"): the Poor floor holds only
# while the data reaches 5 % of it; below that the axis fits the data with a minimum span. Pure JS (node): no quickshell starts.
#
#   tools/dev/weather_aq_axis_probe.sh                 WEATHERAQ RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nofloorrule tools/dev/weather_aq_axis_probe.sh the rule is gone (the floor always holds): the SO2 cases go red
#   ARM=alwaysdrop tools/dev/weather_aq_axis_probe.sh  the share is 100 %: the usual PM2.5 / CO cases go red
#
# The armed copy is a private directory of the weather data files; the tree is never patched.
set -u
cd "$(dirname "$0")/../.." || exit 1
D="$(mktemp -d "${SCRATCH:-/tmp}/waq.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
cp modules/weather/data/{WeatherSeries,WeatherScales,WeatherModel,Astro}.js "$D/"
NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nofloorrule) sed -i 's|aqTop < AXIS.aqReliefShare \* spec.yMaxFloor|false|' "$D/WeatherSeries.js"; NEEDLE='WAQ FAIL SO2' ;;
    alwaysdrop)  sed -i 's|aqReliefShare: 0.05,|aqReliefShare: 100,|' "$D/WeatherSeries.js"; NEEDLE='WAQ FAIL (PM2.5|CO|SO2 at 11|SO2 just over)' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
if [ -n "${ARM:-}" ] && ! cmp -s modules/weather/data/WeatherSeries.js "$D/WeatherSeries.js" 2>/dev/null; then :; elif [ -n "${ARM:-}" ]; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
node tools/dev/weather_aq_axis_probe.js "$D" > "$D/log" 2>&1
cat "$D/log" | grep -a '^WAQ ' | grep -a -v 'WAQ RESULT'
if [ -n "${ARM:-}" ]; then
    if grep -a -E -q "$NEEDLE" "$D/log"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(grep -a 'WAQ RESULT' "$D/log" | tail -1)
[ -n "$res" ] || { cat "$D/log"; echo "WEATHERAQ RESULT FAIL (no result: $D/log)"; KEEP=1; exit 1; }
echo "$res" | sed 's/^WAQ RESULT/WEATHERAQ RESULT/'
case "$res" in *PASS*) exit 0 ;; *) exit 1 ;; esac
