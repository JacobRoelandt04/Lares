#!/usr/bin/env bash
# config_watch_probe.sh -- JsonConfig (modules/common/config: a config read through its spec) and ConfigWatch (a mistake is said).
#
#   tools/dev/config_watch_probe.sh             CONFIG_WATCH RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=late ...       the first settings are the defaults until the event loop has run: "from the first turn" goes red
#   ARM=drop ...       a file that does not parse becomes the defaults: "keeps the previous settings" goes red
#   ARM=nowithdraw ... the toast of a fixed file stays: "the fixed files are read" goes red
#   ARM=notell ...     a ConfigFile tells nobody what it read: "the mistakes are told" goes red
#   ARM=anydir ...     a file outside config/ counts: "outside the directory" goes red
#   ARM=nostart ...    a key read at the start follows the file: "keeps its value" goes red
#   ARM=all            every one of them: CONFIG_WATCH ARMS RESULT PASS | FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    bad=""
    for a in late drop nowithdraw notell anydir nostart; do
        out=$(ARM=$a "$0" 2>&1); rc=$?
        echo "$out" | tail -1
        [ "$rc" -eq 0 ] || bad="$bad $a"
    done
    [ -z "$bad" ] && { echo "CONFIG_WATCH ARMS RESULT PASS"; exit 0; }
    echo "CONFIG_WATCH ARMS RESULT FAIL ($bad)"; exit 1
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/cw.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/config" "$D/elsewhere"
printf '// breaks\n{ "durationMin": 42 }\n' > "$D/config/breaks.jsonc"
printf '{ "items": ["lock", "sleep"], "rest": "sleep" }' > "$D/config/power.jsonc"
printf '// osd\n{\n  "dismisMs": 3000,\n  "queueCap": 900\n}\n' > "$D/config/osd.jsonc"
printf '{ "nonsense": 1 }' > "$D/elsewhere/osd.jsonc"
printf '{ "nonsense": 1 }' > "$D/config/zebra.jsonc"
printf '{ "dayStartHour": 40 }' > "$D/config/screentime.jsonc"
cat > "$D/arm.py" <<'ARMPY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    print("ARM anchor gone (%d): %r" % (s.count(a), a[:80])); sys.exit(1)
open(p, "w").write(s.replace(a, b))
ARMPY
ARMCMD="" NEEDLE=""
J=modules/common/config/JsonConfig.qml W=modules/common/config/ConfigWatch.qml F=modules/common/components/ConfigFile.qml
arm() { ARMCMD="python3 $D/arm.py $1 $(printf '%q' "$2") $(printf '%q' "$3")"; NEEDLE=$4; }
case "${ARM:-}" in
    "") ;;
    late) arm $J 'const t = root.live && v.path !== "" ? v.text() : "";' 'const t = "";' 'from the first turn' ;;
    drop) arm $J '        if (!r)
            return;' '        if (!r) { root._take(Check.read(root.spec, {})); return; }' 'keeps the previous settings' ;;
    nowithdraw) arm $W '            root.notifier.withdraw(name);' '' 'the fixed files are read' ;;
    notell) arm $F '            ConfigTell.saw(root.jsoncPath, root.text());' '            return;' 'the mistakes are told' ;;
    anydir) arm $W '            if (dir === "" || path.indexOf(dir) !== 0)
                continue;
            const rest = path.substring(dir.length);' '            const rest = path.substring(path.lastIndexOf("/") + 1);' 'outside the directory' ;;
    nostart) arm $J '        Check.keepStart(root.spec, root._start, r.settings);' '' 'keeps its value, the same object' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CACHE_HOME='"$D"'/cache XDG_STATE_HOME='"$D"'/state CW_DIR='"$D"' timeout 60 quickshell -p tools/dev/qml/config_watch_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'CW FAIL.*'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a 'CW FAIL' | grep -a -q -e "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'CW RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result CONFIG_WATCH "$D/log" 'CW RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
[ "$rc" -eq 0 ] || KEEP_D=1
printf '%s\n' "$res" | sed 's/^CW RESULT/CONFIG_WATCH RESULT/'
exit $rc
