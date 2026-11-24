#!/usr/bin/env bash
# A dead network helper is said on the popup's label and warns on the bar pill (AerialFacts / AerialPill / AerialBarButton / AerialPopup, commit eef271f7): the REAL popup and
# the REAL bar button over one AerialMock (scenario airplane), its helper fact played failed and healthy again (tools/dev/qml/aerial_helper_dead_probe.qml); the label's Text and the
# pill's fault / warn fraction are read from properties. (The pure halves are held by tools/dev/aerial_facts_cases.js.)
#
#   tools/dev/aerial_helper_dead_probe.sh               last line: AERIAL_HELPER_DEAD RESULT PASS|FAIL
#   ARM=<name> tools/dev/aerial_helper_dead_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/aerial_helper_dead_probe.sh       every ARM; AERIAL_HELPER_DEAD ARMS PASS when each failed on ITS check
#
#     nolabel      the facts never name the dead helper                          -> label FAILS
#     nopopupfeed  the popup does not hand the helper fact to the label          -> label FAILS
#     nopillfault  the pill's fault ignores the helper                           -> pill.fault FAILS
#     nobuttonfeed the bar button does not read the helper fact                  -> pill.fault FAILS
#     noglyphwarn  the glyph's warn fraction ignores a dead helper               -> pill.glyph FAILS
#
# Nothing here touches the machine: no helper, no NetworkManager, no bus; private XDG dirs.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_HELPER_DEAD
declare -A NEEDLE=([nolabel]='label' [nopopupfeed]='label' [nopillfault]='pill.fault' [nobuttonfeed]='pill.fault' [noglyphwarn]='pill.glyph')
if [ "${ARM:-}" = all ] && [ -z "${AHD_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nolabel nopopupfeed nopillfault nobuttonfeed noglyphwarn}; do
        sb="/tmp/lares-sbx-ahd-arm-$a"
        # each arm in a FRESH copy of the tree this stands in -- also inside a gate's box copy, which has no .git, so the runner would
        # not re-exec and every arm would patch the same copy (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AHD_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_helper_dead_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "AHD FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'AHD FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'AHD FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${AHD_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-ahd}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AHD_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_helper_dead_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/ahd.XXXXXX")
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
    FACTS=modules/aerial/scene/AerialFacts.js
    case "$ARM" in
        nolabel) arm $FACTS 'helperWord !== "" ? helperWord :' 'false ? helperWord :' ;;
        nopopupfeed) arm modules/aerial/popup/AerialPopup.qml 'airplane: s.airplane, helper: s.helper, config' 'airplane: s.airplane, config' ;;
        nopillfault) arm modules/aerial/bar/AerialPill.js 'fault: helperFailed ? "warn" : netOn ? worst : "",' 'fault: netOn ? worst : "",' ;;
        nobuttonfeed) arm modules/aerial/bar/AerialBarButton.qml 'rates: s.rates, helper: s.helper }' 'rates: s.rates }' ;;
        noglyphwarn) arm modules/aerial/bar/AerialBarButton.qml '(root.netOn || root.pill.helperFailed) && root.pill.fault' 'root.netOn && root.pill.fault' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" AHD_RUN=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-120} quickshell -n -p "$(pwd)/tools/dev/qml/aerial_helper_dead_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: AHD .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: AHD DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: AHD DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: AHD ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "AHD warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/ahd_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
