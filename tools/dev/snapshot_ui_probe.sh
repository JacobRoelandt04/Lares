#!/usr/bin/env bash
# The snapshots page and the SnapshotService (docs/contracts/snapshots.md section 11) against STUBS: tools/dev/qml/snapshot_ui_probe.qml with a
# root tool, pkexec, pkcheck, systemd-run and `lares-snapshot undo-plan` that print the contract's JSON and log their argv. Nothing here reaches
# restic, polkit, systemd or the machine; offscreen, private XDG dirs, a private runtime dir (sandbox.sh).
#
#   tools/dev/snapshot_ui_probe.sh               last line: SNAPSHOT_UI RESULT PASS|FAIL
#   ARM=<name> tools/dev/snapshot_ui_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/snapshot_ui_probe.sh       every ARM; SNAPSHOT_UI ARMS PASS when each failed on ITS check
#
#     notestx     the root tool is never looked for first: a missing tool is run             -> P1.missing FAILS
#     nopkcheck   a refusal of pkcheck is ignored: pkexec runs                              -> P5.refused FAILS
#     nostate     a change of state.json is not heard                                       -> P6.statewatch FAILS
#     rebuild     a refresh rebuilds every card (the model is cleared first)                -> P6.identity FAILS
#     twoopen     every card follows the open one                                           -> P3.oneOpen FAILS
#     undorun     Undo stays live while an update runs                                      -> P4.runoff FAILS
#     deletekept  Delete is offered on a kept card                                          -> P5.hiddenKept FAILS
#     offrun      a copy may start during a run                                             -> P7.norun FAILS
#     offdaily    the day's limit forgets the copy it started                               -> P7.once FAILS
#     offmock     a mock shell may start the copy                                           -> P7.mock FAILS
#     offstale    a "running" left standing by a machine that went down is never asked again -> P7.rule FAILS
#     noplug      the charger going in is not heard                                         -> P7.plug FAILS
#     stalewords  what it waits for is the file's old word                                  -> P7.words FAILS
#     gapcut      a long list is cut wherever the height ends                               -> P8.cut FAILS
#     aheadheight the page asks for the cards' animated height, not their target            -> P8.target FAILS
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SNAPSHOT_UI
declare -A NEEDLE=([notestx]='P1.missing' [nopkcheck]='P5.refused' [nostate]='P6.statewatch' [rebuild]='P6.identity' [twoopen]='P3.oneOpen'
                   [undorun]='P4.runoff' [deletekept]='P5.hiddenKept' [offrun]='P7.norun' [offdaily]='P7.once' [offmock]='P7.mock' [offstale]='P7.rule' [aheadheight]='P8.target' [noplug]='P7.plug' [stalewords]='P7.words' [gapcut]='P8.cut')
if [ "${ARM:-}" = all ] && [ -z "${SUP_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-notestx nopkcheck nostate rebuild twoopen undorun deletekept offrun offdaily offmock offstale aheadheight noplug stalewords gapcut}; do
        sb="/tmp/lares-sbx-sup-arm-$a"
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SUP_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/snapshot_ui_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "SUP FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'SUP FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'SUP FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${SUP_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-sup}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SUP_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/snapshot_ui_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/sup.XXXXXX")
KEEP_W=0
trap '[ "$KEEP_W" = 1 ] || rm -rf "$WORK"' EXIT
if [ -n "$ARM" ]; then
    [ -e .git ] && { echo "refusing to arm the real tree"; exit 2; }
    arm() { python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: anchor not found exactly once in $1"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
    }
    D=modules/bar/system_update/snapshots
    case "$ARM" in
        notestx) arm $D/SnapshotService.qml 'if (code !== 0) {
                root._finishRead("missing", {}, null);' 'if (false) {
                root._finishRead("missing", {}, null);' ;;
        nopkcheck) arm $D/SnapshotService.qml 'if (code !== 0 && code !== 2) {' 'if (false) {' ;;
        nostate) arm $D/SnapshotService.qml 'onFileChanged: root.refresh()' 'onFileChanged: {}' ;;
        rebuild) arm $D/SnapshotService.qml '        const want = rows.map(r => r.short);' '        rowModel.clear();
        const want = rows.map(r => r.short);' ;;
        twoopen) arm $D/SnapshotsPage.qml 'open: root.openShort === card.short' 'open: root.openShort !== ""' ;;
        undorun) arm $D/SnapshotRow.qml 'enabled: !card.runActive && !card.busy && Words.undoable(card.plan)' 'enabled: !card.busy && Words.undoable(card.plan)' ;;
        deletekept) arm $D/SnapshotRow.qml 'visible: card._has && !card.row.keep
                    text: "Delete"' 'visible: true
                    text: "Delete"' ;;
        offrun) arm $D/SnapshotWords.js 'o.runActive || o.busy) return ""' 'o.busy) return ""' ;;
        offstale) arm $D/SnapshotWords.js 'return since >= 10800000 ? "retry" : ""' 'return ""' ;;
        offdaily) arm $D/SnapshotWords.js 'Math.max(o.lastOkMs || 0, o.lastTriggerMs || 0)' '(o.lastOkMs || 0)' ;;
        offmock) arm $D/SnapshotWords.js '!o.enabled || !o.live ||' '!o.enabled ||' ;;
        noplug) arm $D/SnapshotService.qml 'onOnBatteryChanged: if (!root.onBattery && root._offsiteEnabled && root.live) plugTimer.restart()' 'onOnBatteryChanged: {}' ;;
        stalewords) arm $D/SnapshotWords.js 'if (o.cause === "battery")
            return' 'if (false)
            return' ;;
        gapcut) arm $D/SnapshotsPage.qml 'return best > 0 ? best : room;' 'return room;' ;;
        aheadheight) arm $D/SnapshotRow.qml 'readonly property real targetHeight: card.headH + (card.open ? card.bodyH + (card.listOpen ? card.listH : 0) : 0)' 'readonly property real targetHeight: card.height' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi

# ---- the stubs --------------------------------------------------------------------------------------------------
ST="$WORK/stub"
mkdir -p "$ST/cfgA/config" "$ST/cfgO/config" "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
NOW=$(date +%s)
python3 - "$ST" "$NOW" <<'PY'
import json, sys
st, now = sys.argv[1], int(sys.argv[2])
def rec(short, ago, reason, count, crit, changed, keep=False, added=1.2e9, state="done"):
    return {"version": 1, "id": short * 8, "short": short, "time": now - ago, "reason": reason, "run": None, "count": count, "critical": crit,
            "targets": [], "changed": changed, "state": state, "keep": keep, "note": "", "added": added, "addedPacked": added, "files": 1, "bytes": 1,
            "seconds": 5, "paths": [], "excludes": [], "kernel": "7.3.5-arch1-1"}
ch = lambda n, a, b: {"name": n, "from": a, "to": b}
a = rec("aaaa1111", 3600 * 20, "update", 112, ["linux", "mesa"], [ch("linux", "7.3.4.arch1-1", "7.3.5.arch1-1"), ch("mesa", "26.2.1-1", "26.2.2-1"), ch("zlib", "1.3-1", "1.3.1-1")])
b = rec("bbbb2222", 86400 * 4, "update", 179, ["systemd"], [ch("systemd", "259.1-1", "259.2-1")], keep=True)
c = rec("cccc3333", 86400 * 6, "manual", 0, [], [])
d = rec("dddd4444", 60, "manual", 0, [], [])
e = rec("eeee5555", 5, "manual", 0, [], [])
status = {"version": 1, "installed": True, "repo": True, "off": False, "enabled": True, "restic": "0.19.1", "count": 3, "newest": "aaaa1111",
          "repoBytes": 18e9, "freeBytes": 1e11, "busy": "", "check": None, "rescue": None, "settings": {}, "problems": []}
w = lambda n, o: open(f"{st}/{n}", "w").write(json.dumps(o))
w("status.json", status)
w("list.json", {"records": [a, b, c]})
w("list2.json", {"records": [d, a, b, c]})
w("list3.json", {"records": [e, d, a, b, c]})
w("plan.json", {"ok": True, "short": "aaaa1111", "files": [ {"name": "linux", "now": "7.3.5", "to": "7.3.4", "source": "pacman", "path": "/x"}, {"name": "mesa", "now": "1", "to": "0", "source": "pacman", "path": "/y"} ],
   "missing": [ {"name": "zlib", "now": "1.3.1", "to": "1.3"} ], "newSince": [], "removedSince": []})
w("plan_cccc3333.json", {"ok": True, "short": "cccc3333", "files": [], "missing": [ {"name": "a", "now": "1", "to": "0"} ], "newSince": [], "removedSince": []})
w("offsite.json", {"state": "idle", "reason": "", "lastOk": now - 7200, "pending": {"files": 0, "bytes": 0}, "done": {"files": 0, "bytes": 0}, "snapshots": ["aaaa1111"], "pid": 0})
w("offsiteP.json", {"state": "waiting", "cause": "battery", "reason": "The machine is on battery; the copy waits for the charger.", "lastOk": now - 3600, "pending": {"files": 2, "bytes": 9}, "done": {"files": 0, "bytes": 0}, "snapshots": [], "pid": 0})
w("offsiteO.json", {"state": "idle", "reason": "", "lastOk": now - 3 * 86400, "pending": {"files": 0, "bytes": 0}, "done": {"files": 0, "bytes": 0}, "snapshots": [], "pid": 0})
open(f"{st}/cfgA/config/snapshots.jsonc", "w").write('// off site off\n{ "offsite": { "enabled": false } }\n')
open(f"{st}/cfgO/config/snapshots.jsonc", "w").write('// off site on\n{ "offsite": { "enabled": true, "folder": "/x" } }\n')
open(f"{st}/pkcheck.code", "w").write("0")
PY
cat > "$ST/root" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$ST/root.log"
case "\$1" in
    status) cat "$ST/status.json" ;;
    list) cat "$ST/list.json" ;;
    create) echo "lares-snapshot: progress 20"; sleep 0.1; echo "lares-snapshot: progress 60"; echo '{"ok": true, "short": "dddd4444"}' ;;
    keep|delete) echo '{"ok": true}' ;;
    *) exit 2 ;;
esac
STUB
cat > "$ST/pkcheck" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$ST/pkcheck.log"
exit \$(cat "$ST/pkcheck.code")
STUB
cat > "$ST/pkexec" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$ST/pkexec.log"
exec "\$@"
STUB
cat > "$ST/systemd-run" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$ST/sysrun.log"
exit 0
STUB
cat > "$ST/usertool.py" <<STUB
import sys, os
open("$ST/usertool.log", "a").write(" ".join(sys.argv[1:]) + "\n")
short = sys.argv[2]
p = "$ST/plan_" + short + ".json"
sys.stdout.write(open(p if os.path.exists(p) else "$ST/plan.json").read())
STUB
chmod +x "$ST/root" "$ST/pkcheck" "$ST/pkexec" "$ST/systemd-run"
: > "$ST/pkexec.log"; : > "$ST/pkcheck.log"; : > "$ST/sysrun.log"; : > "$ST/root.log"; : > "$ST/usertool.log"

log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" SUP_RUN=1 SUP_STUB="$ST" \
    SUP_LIST2="$(cat "$ST/list2.json")" SUP_LIST3="$(cat "$ST/list3.json")" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-120} quickshell -n -p "$(pwd)/tools/dev/qml/snapshot_ui_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: SUP .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: SUP DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: SUP DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: SUP ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "SUP warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/sup_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
