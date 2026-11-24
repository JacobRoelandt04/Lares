#!/usr/bin/env bash
# config_loaders_probe.sh -- every QML config loader (shell, osd, notifications, windowtray, stocks, wiki, silicon, calendars,
# weather, launcher, locale, idle, llm) reads `<name>.jsonc` first and `<name>.json` after it, comments allowed.
#
#   tools/dev/config_loaders_probe.sh               CONFIG_LOADERS RESULT PASS | FAIL (<n>/<n>)
#   ARM=nojsonc tools/dev/config_loaders_probe.sh   ConfigFile never looks at the .jsonc (the old behaviour): scenarios A and B go red
#   ARM=nostrip tools/dev/config_loaders_probe.sh   the calendars loader parses without the comment strip (its old line): A and C go red
#
# Four directories hold each loader's file: A a .jsonc with comments beside a garbage .json, B a garbage .jsonc beside a good
# .json, C only a .json with comments, D neither. The lockscreen's and the system update's loaders read fixed paths / sit in a
# service: tools/dev/lock_env/probes/b_targets_probe.sh covers them.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/cl.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT     # KEEP=1, or a run with no result, keeps the dir (the verdict names a log in it)
mkdir -p "$D/A" "$D/B" "$D/C" "$D/D"
GARBAGE='{ "broken": '
NAMES="osd shell notifications windowtray stocks wiki silicon calendars weather launcher locale idle llm"
valid() {   # valid <name>: the file of that loader, with comments in it
    case "$1" in
        calendars) printf '// calendars, with a comment\n{ /* block */ "calendars": [ { "id": "a", "url": "https://example.invalid//feed.ics" } ] // tail\n}\n' ;;
        locale) printf '// locale\n{ "timeFormat": "H:mm" /* block */ }\n' ;;
        *) printf '// %s, with a comment\n{ /* nothing set: the defaults */ }\n' "$1" ;;
    esac
}
for n in $NAMES; do
    valid "$n" > "$D/A/$n.jsonc";  printf '%s\n' "$GARBAGE" > "$D/A/$n.json"
    printf '%s\n' "$GARBAGE" > "$D/B/$n.jsonc"; valid "$n" > "$D/B/$n.json"
    valid "$n" > "$D/C/$n.json"
done
ARMCMD=""
case "${ARM:-}" in
    "") ;;
    nojsonc) ARMCMD="sed -i 's|^    readonly property string active: .*|    readonly property string active: root._hasJson ? \"json\" : \"\"|' modules/common/components/ConfigFile.qml" ;;
    nostrip) ARMCMD="sed -i 's|JSON.parse(JsonComments.strip(txt))|JSON.parse(txt)|' modules/clock/data/CalendarConfig.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CACHE_HOME='"$D"'/cache XDG_STATE_HOME='"$D"'/state CL_ROOT='"$D"' timeout 90 quickshell -p tools/dev/qml/config_loaders_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a '^ *DEBUG qml: CL \|^CL ' | grep -a -v 'CL RESULT' | grep -a 'FAIL'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'CL FAIL'; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'CL RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; rl_clean "$D/log" | grep -a 'ERROR' | head -5; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result CONFIG_LOADERS "$D/log" 'CL RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing"; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^CL RESULT/CONFIG_LOADERS RESULT/'
exit $rc
