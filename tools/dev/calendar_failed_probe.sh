#!/usr/bin/env bash
# calendar_failed_probe.sh -- a calendar feed that fails says so in the appointment list (modules/clock/calendar/AppointmentList.qml,
# CalendarService.failedFeeds): the real service on two file:// feeds, a vanished feed, an empty one, a recovered one; the healthy
# case shows nothing.
#
#   tools/dev/calendar_failed_probe.sh              CALFAILED RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/calendar_failed_probe.sh   one fault in the sandbox copy; must fail on its own check:
#   ARM=all ...  every arm in turn: CALFAILED ARMS RESULT PASS when each failed on its own check
#     nopublish  the service publishes no failed feed        -> "CF FAIL gone: the words appear"
#     hidden     the list never shows the words              -> "CF FAIL gone: the words appear"
#     always     the list shows the words with no failed feed -> "CF FAIL healthy: no 'Could not load'"
#     nowarn     the words are not in the warn colour        -> "CF FAIL gone: the words are the theme's warn"
#     noconn     a curl failure reads as an unreadable feed  -> "CF FAIL gone: 'Could not load Work (no connection)'"
#     stuck      a cleared failure is never unpublished      -> "CF FAIL recovered: the words go"
#
# Starts quickshell offscreen in the sandbox copy, on a private config/state/cache home; the feeds are curl file:// URLs.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then   # every arm, each in a fresh sandbox sync; PASS only when each failed on its own needle
    rc=0
    for a in nopublish hidden always nowarn noconn stuck; do
        out=$(ARM="$a" bash "$0" 2>&1); printf '%s\n' "$out" | grep -a '^ARM ' | tail -1
        printf '%s\n' "$out" | grep -aq "^ARM $a: failed as it must" || rc=1
    done
    [ "$rc" -eq 0 ] && echo "CALFAILED ARMS RESULT PASS" || echo "CALFAILED ARMS RESULT FAIL"
    exit "$rc"
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/cf.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
L=modules/clock/calendar/AppointmentList.qml
S=modules/clock/data/CalendarService.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nopublish) ARMCMD="grep -q 'if (f && f.lastError)' $S && sed -i 's|if (f \&\& f.lastError)|if (false)|' $S"
          NEEDLE='CF FAIL gone: the words appear' ;;
    hidden) ARMCMD="grep -q 'visible: failedLine._failed.length > 0' $L && sed -i 's|visible: failedLine._failed.length > 0|visible: false|' $L"
          NEEDLE='CF FAIL gone: the words appear' ;;
    always) ARMCMD="grep -q 'visible: failedLine._failed.length > 0' $L && sed -i 's|visible: failedLine._failed.length > 0|visible: true|' $L"
          NEEDLE="CF FAIL healthy: no 'Could not load'" ;;
    nowarn) ARMCMD="grep -q 'color: Theme.warn' $L && sed -i '/readonly property var _failed/,/font.pixelSize/ s|color: Theme.warn|color: Theme.textFaint|' $L"
          NEEDLE='CF FAIL gone: the words are the theme.s warn' ;;
    noconn) ARMCMD="grep -q '/curl exit/.test' $L && sed -i 's|/curl exit/.test|/zzzz/.test|' $L"
          NEEDLE="CF FAIL gone: 'Could not load Work (no connection)'" ;;
    stuck) ARMCMD="grep -q 'if (JSON.stringify(failed) !== JSON.stringify(root.failedFeeds))' $S && sed -i 's|if (JSON.stringify(failed) !== JSON.stringify(root.failedFeeds))|if (failed.length > 0 \&\& JSON.stringify(failed) !== JSON.stringify(root.failedFeeds))|' $S"
          NEEDLE='CF FAIL recovered: the words go' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache" "$D/feeds"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
day=$(date +%Y%m%d)
ics() {    # <uid> <title>
    printf 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//probe//EN\r\nBEGIN:VEVENT\r\nUID:%s@probe\r\nDTSTAMP:%sT080000Z\r\nDTSTART:%sT120000\r\nDTEND:%sT130000\r\nSUMMARY:%s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n' "$1" "$day" "$day" "$day" "$2"
}
ics home "Home dentist" > "$D/feeds/home.ics"
ics work "Work standup" > "$D/feeds/work.ics"
cp "$D/feeds/work.ics" "$D/feeds/work.good"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' CAL_FEEDS='"$D/feeds"' timeout 90 quickshell -p tools/dev/qml/calendar_failed_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-calfailed}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'CF .*' | grep -a -v 'CF RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'CF RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; echo "$D/log"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result CALFAILED "$D/log" 'CF RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^CF RESULT/CALFAILED RESULT/'
exit $rc
