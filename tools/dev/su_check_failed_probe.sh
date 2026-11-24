#!/usr/bin/env bash
# A failed update check says why in words, a partial list says which source was not checked (SystemUpdatePopup + AvailableUpdatesService, commit c90d8ce1):
# the REAL popup over the real service in mock mode (no yay / pacman / network), sources staged failing through the service's own _finishSource
# (tools/dev/qml/su_check_failed_probe.qml), the card's Texts read: the plain-words reasons, the "<source> not checked" line, and nothing of either on a clean check.
#
#   tools/dev/su_check_failed_probe.sh               last line: SU_CHECK_FAILED RESULT PASS|FAIL
#   ARM=<name> tools/dev/su_check_failed_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/su_check_failed_probe.sh       every ARM; SU_CHECK_FAILED ARMS PASS when each failed on ITS check
#
#     nowords       the line shows the tool's raw text again              -> net FAILS
#     nopartial     a partial list says nothing                           -> partial FAILS
#     partialalways the "not checked" line comes with any list            -> healthy.quiet FAILS
#     nomirror      the official-only failure loses its mirror words      -> official FAILS
#     nosome        two failed sources lose the common words              -> both FAILS
#
# Nothing here touches the machine: no yay, no pacman, no network, no cache file; private XDG dirs.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=SU_CHECK_FAILED
declare -A NEEDLE=([nowords]='net' [nopartial]='partial' [partialalways]='healthy.quiet' [nomirror]='official' [nosome]='both')
if [ "${ARM:-}" = all ] && [ -z "${SCF_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nowords nopartial partialalways nomirror nosome}; do
        sb="/tmp/lares-sbx-scf-arm-$a"
        # each arm in a FRESH copy of the tree this stands in -- also inside a gate's box copy, which has no .git, so the runner would
        # not re-exec and every arm would patch the same copy (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SCF_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/su_check_failed_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "SCF FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'SCF FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'SCF FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${SCF_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-scf}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SCF_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/su_check_failed_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/scf.XXXXXX")
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
    case "$ARM" in
        nowords) arm $Q 'case "error":   return root._failWords(a.lastError, a.failedSourceList);' 'case "error":   return a.lastError;' ;;
        nopartial) arm $Q 'if (a.totalCount > 0 && a.failedSourceList.length > 0) return "partial";' 'if (false) return "partial";' ;;
        partialalways) arm $Q 'if (a.totalCount > 0 && a.failedSourceList.length > 0) return "partial";' 'if (a.totalCount > 0) return "partial";' ;;
        nomirror) arm $Q 'if (failed.length === 1 && failed[0] === "official") return "A mirror failed to answer";' '' ;;
        nosome) arm $Q 'return "Some sources did not answer";' 'return root._sourceNames(failed) + " did not answer";' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" SCF_RUN=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-120} quickshell -n -p "$(pwd)/tools/dev/qml/su_check_failed_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: SCF .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: SCF DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: SCF DONE PASS' || fail=1
# the tool's raw text goes to the log, not the card (console.warn "AvailableUpdates: <source> check failed: <raw>")
if [ -z "$ARM" ] && ! rl_has "$log" 'AvailableUpdates: aur check failed: error: Could not resolve host'; then
    echo "SCF log FAIL  the raw failure text did not reach the log"; fail=1
fi
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: SCF ' | grep -v 'AvailableUpdates: .* check failed:' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "SCF warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/scf_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
