#!/usr/bin/env bash
# The snapshot hook and the undo run in the system update popup (docs/contracts/snapshots.md sections 7, 10, 11): the REAL parser, run progress and
# popup, fed the transcripts of pacman's pre-transaction hook block through a stand-in backend (tools/dev/qml/su_snapshot_probe.qml): a done
# snapshot, a small one skipped, `skip run`, a failure (one error, the card's words and buttons), two transactions of one run, an undo run, the
# idle companion line, and no service at all. Nothing touches the machine: no yay, no pacman, no restic; private XDG dirs.
#
#   tools/dev/su_snapshot_probe.sh               last line: SU_SNAPSHOT RESULT PASS|FAIL
#   SSP_GRAB=<dir> tools/dev/su_snapshot_probe.sh    also saves the popup at the interesting moments (PNG)
#   ARM=<name> tools/dev/su_snapshot_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/su_snapshot_probe.sh       every ARM; SU_SNAPSHOT ARMS PASS when each failed on ITS check
#
#     noskipkeep    a second transaction's `skip run` takes a done snapshot back          -> S5.kept FAILS
#     doubleerror   pacman's "failed to run transaction hooks" adds a second, vaguer error -> S4.oneError FAILS
#     outsidehooks  the hook's lines are read anywhere in the run                          -> S6.outside FAILS
#     latenotch     the rule is not asked: the notch comes when the hook speaks            -> S1.rail FAILS (re-spaced under the ball)
#     nosnapraw     the ball passes the notch at the verification                          -> S1.atSnapshot FAILS
#     figback       the whole-run figure follows the plan back when a step is added        -> S10.figureUp FAILS
#     nocatch       the undo reads pacman's table rows as AUR packages                     -> S7.official FAILS
#     norefresh     the service refreshes the waiting list after an update only          -> S11.undoRefresh FAILS
#     norefresh     the service refreshes the waiting list after an update only          -> S11.undoRefresh FAILS
#     nonull        a popup with no service still draws the line                           -> S9.noline FAILS
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SU_SNAPSHOT
declare -A NEEDLE=([noskipkeep]='S5.kept' [doubleerror]='S4.oneError' [outsidehooks]='S6.outside' [latenotch]='S1.rail'
                   [nosnapraw]='S1.atSnapshot' [figback]='S10.figureUp' [nocatch]='S7.official' [nonull]='S9.noline' [norefresh]='S11.undoRefresh')
if [ "${ARM:-}" = all ] && [ -z "${SSP_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-noskipkeep doubleerror outsidehooks latenotch nosnapraw figback nocatch nonull norefresh}; do
        sb="/tmp/lares-sbx-ssp-arm-$a"
        # each arm in a FRESH copy of the tree this stands in (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SSP_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/su_snapshot_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "SSP FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'SSP FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'SSP FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${SSP_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-ssp}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SSP_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" SSP_GRAB="${SSP_GRAB:-}" bash tools/dev/su_snapshot_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/ssp.XXXXXX")
KEEP_W=0   # a run with no result keeps its log: the verdict names it (CLAUDE.md, "A RUNNER WHOSE WORK DIR HOLDS ITS LOG")
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
    Q=modules/bar/system_update/components/SystemUpdatePopup.qml
    P=modules/bar/system_update/components/PackageUpdateParser.qml
    G=modules/bar/system_update/components/SystemUpdateProgress.js
    R=modules/bar/system_update/SystemUpdateRunProgress.qml
    case "$ARM" in
        noskipkeep) arm $P 'if (root.snapshotState === "done") return;' '' ;;
        doubleerror) arm $P 'if (root.snapshotState === "failed" && /failed to run transaction hooks/.test(m[1])) return;' '' ;;
        outsidehooks) arm $P 'if (line.indexOf("lares-snapshot: ") === 0 && root.subPhase === "L4_PREHOOKS"' 'if (line.indexOf("lares-snapshot: ") === 0' ;;
        latenotch) arm $Q 'const listRead = root._runKind === "undo" || (' 'const listRead = false && (' ;;
        nosnapraw) arm $Q '&& (p.subPhase === "L3_INTEGRITY" || p.subPhase === "L4_PREHOOKS"))
            return "snapshot";' '&& false)
            return "snapshot";' ;;
        figback) arm $G 'if (f > state.fraction)' 'if (true)' ;;
        nocatch) arm $P 'isAur: root.runKind !== "undo" && (repo === "" || repo === "aur"),' 'isAur: (repo === "" || repo === "aur"),' ;;
        norefresh) arm modules/bar/system_update/SystemUpdateService.qml 'if (root.refreshAfterRun)
                availableUpdates.refresh();' 'if (root.refreshAfterRun && root.runKind !== "undo")
                availableUpdates.refresh();' ;;
        nonull) arm $Q 'readonly property bool _snapLineOn: root._idle && root._snapReady && !root._snapFailed' 'readonly property bool _snapLineOn: root._idle && !root._snapFailed' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
[ -n "${SSP_GRAB:-}" ] && mkdir -p "$SSP_GRAB"
log="$WORK/run.log"
# the REAL terminal captures (tools/dev/snapshot_vm, real pacman at 200 columns) as the lines the parser gets: escapes out, a carriage return
# keeps what was written last on the row (what TerminalBackend's screen model leaves)
python3 -B - "$WORK/fixtures.json" <<'PY' || { echo "the fixtures could not be read"; exit 1; }
import json, re, sys
out = {}
for name in ("snapshot-done", "snapshot-skip", "snapshot-failed", "undo", "undo-week", "undo-conflict", "undo-big-update"):
    raw = open("tools/system_update/fixtures/%s.log" % name, encoding="utf-8", errors="replace", newline="").read()
    code = re.search(r'COMMAND_EXIT_CODE="(\d+)"', raw)
    raw = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", raw)
    raw = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
    lines = []
    for row in raw.replace("\r\n", "\n").split("\n"):
        row = row.rstrip("\r").split("\r")[-1].rstrip()
        if row and not row.startswith("Script "):
            lines.append(row)
    out[name] = {"code": int(code.group(1)) if code else -1, "lines": lines}
json.dump(out, open(sys.argv[1], "w"))
PY
env -u WAYLAND_DISPLAY SSP_FIX="$WORK/fixtures.json" XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" SSP_RUN=1 SSP_GRAB="${SSP_GRAB:-}" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-150} quickshell -n -p "$(pwd)/tools/dev/qml/su_snapshot_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: SSP .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: SSP DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: SSP DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: SSP ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "SSP warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/ssp_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
