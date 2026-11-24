#!/usr/bin/env bash
# weather_offline_probe.sh -- the weather popup's header note (modules/weather/WeatherPopup.qml `header.note`): "offline, retrying" in
# warn when there is no cache and the fetch failed, "offline, from <time>" in warn with one, "updated <time>" faint when healthy, nothing
# while the first fetch is out. The real popup on WeatherMock with its facts written by hand.
#
#   tools/dev/weather_offline_probe.sh              WXOFFLINE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/weather_offline_probe.sh   one fault in the sandbox copy; must fail on its own check:
#   ARM=all ...  every arm in turn: WXOFFLINE ARMS RESULT PASS when each failed on its own check
#     noretry   no-cache offline says nothing again     -> "WO FAIL nocache:"
#     nowarn    the offline note is the faint ink       -> "WO FAIL cached:"
#     always    the note says offline whatever is true  -> "WO FAIL healthy:"
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then   # every arm, each in a fresh sandbox sync; PASS only when each failed on its own needle
    rc=0
    for a in noretry nowarn always; do
        out=$(ARM="$a" bash "$0" 2>&1); printf '%s\n' "$out" | grep -a '^ARM ' | tail -1
        printf '%s\n' "$out" | grep -aq "^ARM $a: failed as it must" || rc=1
    done
    [ "$rc" -eq 0 ] && echo "WXOFFLINE ARMS RESULT PASS" || echo "WXOFFLINE ARMS RESULT FAIL"
    exit "$rc"
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/wo.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
P=modules/weather/WeatherPopup.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    noretry) ARMCMD="grep -q 'if (root.offline && !root.model)' $P && sed -i 's|if (root.offline \&\& !root.model)|if (false)|' $P"
            NEEDLE='WO FAIL nocache:' ;;
    nowarn) ARMCMD="grep -q 'color: root.offline ? Theme.warn : Theme.textFaint' $P && sed -i 's|color: root.offline ? Theme.warn : Theme.textFaint|color: Theme.textFaint|' $P"
            NEEDLE='WO FAIL cached:' ;;
    always) ARMCMD="grep -q 'readonly property bool offline: root.service ? !!root.service.offline : false' $P && sed -i 's|readonly property bool offline: root.service ? !!root.service.offline : false|readonly property bool offline: true|' $P"
            NEEDLE='WO FAIL healthy:' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PROBE=1 XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' timeout 90 quickshell -p tools/dev/qml/weather_offline_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-wxoffline}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'WO .*' | grep -a -v 'WO RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'WO RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; echo "$D/log"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result WXOFFLINE "$D/log" 'WO RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^WO RESULT/WXOFFLINE RESULT/'
exit $rc
