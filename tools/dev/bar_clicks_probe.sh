#!/usr/bin/env bash
# bar_clicks_probe.sh -- shell.jsonc "clicks": a right or middle click on a bar button (modules/shell/BarClicks.qml, ModuleSlot's catcher).
#
#   tools/dev/bar_clicks_probe.sh             BAR_CLICKS RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nocatch ...   the catcher takes no button: "does nothing" goes red
#   ARM=eatleft ...   it takes the left click too: "the left click is the button's" goes red
#   ARM=wholeslot ... it lies over the whole slot: "only the button's own box" goes red
#   ARM=locked ...    it works while the session is locked: "locked" goes red
#   ARM=word ...      a word of the spec is not handled: the table check goes red
#   ARM=all           every one of them: BAR_CLICKS ARMS RESULT PASS | FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    bad=""
    for a in nocatch eatleft wholeslot locked word; do
        out=$(ARM=$a "$0" 2>&1); rc=$?
        echo "$out" | tail -1
        [ "$rc" -eq 0 ] || bad="$bad $a"
    done
    [ -z "$bad" ] && { echo "BAR_CLICKS ARMS RESULT PASS"; exit 0; }
    echo "BAR_CLICKS ARMS RESULT FAIL ($bad)"; exit 1
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/bck.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
cat > "$D/arm.py" <<'ARMPY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    print("ARM anchor gone (%d): %r" % (s.count(a), a[:80])); sys.exit(1)
open(p, "w").write(s.replace(a, b))
ARMPY
ARMCMD="" NEEDLE=""
S=modules/shell/ModuleSlot.qml C=modules/shell/BarClicks.qml
arm() { ARMCMD="python3 $D/arm.py $1 $(printf '%q' "$2") $(printf '%q' "$3")"; NEEDLE=$4; }
case "${ARM:-}" in
    "") ;;
    nocatch) arm $S 'acceptedButtons: slot.host.barClicks.buttonsOf(slot.moduleId)' 'acceptedButtons: Qt.NoButton' 'does nothing' ;;
    eatleft) arm $S 'acceptedButtons: slot.host.barClicks.buttonsOf(slot.moduleId)' 'acceptedButtons: slot.host.barClicks.buttonsOf(slot.moduleId) | Qt.LeftButton' "the left click is the button's" ;;
    wholeslot) arm $S 'readonly property bool inBox: slot.clickBox !== slot' 'readonly property bool inBox: false' "only the button's own box" ;;
    locked) arm $C '        if (a === undefined || a === "none" || root.services.lock.locked)' '        if (a === undefined || a === "none")' 'locked: nothing runs' ;;
    word) ARMCMD="python3 $D/arm.py $C 'case \"stocks.refresh\":' 'case \"stocks.refrsh\":'"; NEEDLE='stocks.refresh' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
# every word the spec knows is one BarClicks handles, and the other way round
cat > "$D/words.js" <<'JS'
const C = require(process.argv[2] + "/tools/dev/config_node.js"), fs = require("fs");
const src = fs.readFileSync("modules/shell/BarClicks.qml", "utf8"), T = C.specs.shell.clicks;
const want = [].concat(...Object.keys(T).map(id => T[id][2].right[2][2].filter(w => w !== "none" && w !== "popup").map(w => id + "." + w)));
const have = [...src.matchAll(/case "([a-z]+\.[A-Za-z]+)"/g)].map(m => m[1]);
const bad = want.filter(w => !have.includes(w)).map(w => w + " is not handled").concat(have.filter(w => !want.includes(w)).map(w => w + " is no word of the spec"));
console.log("BARCLICK " + (bad.length ? "FAIL the words: " + bad.join(", ") : "ok   the words (" + want.length + ")"));
JS
run='set -e; '"${ARMCMD:+$ARMCMD; }"'node '"$D/words.js"' "$PWD"; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CACHE_HOME='"$D"'/cache XDG_STATE_HOME='"$D"'/state timeout 60 quickshell -p tools/dev/qml/bar_clicks_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'BARCLICK FAIL.*'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a 'BARCLICK FAIL' | grep -a -q -e "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'BARCLICK RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result BAR_CLICKS "$D/log" 'BARCLICK RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; printf '%s\n' "$res"; exit 1; fi
if rl_has "$D/log" 'BARCLICK FAIL the words'; then rc=1; res="BARCLICK RESULT FAIL (the words)"; fi
[ "$rc" -eq 0 ] || KEEP_D=1
printf '%s\n' "$res" | sed 's/^BARCLICK RESULT/BAR_CLICKS RESULT/'
exit $rc
