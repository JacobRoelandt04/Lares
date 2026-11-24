#!/usr/bin/env bash
# The LLM model picker's empty list says why (LlmModelPicker, commits 0110d6c9 / 2cb3bb6f): the REAL picker in a window (tools/dev/qml/llm_picker_empty_probe.qml),
# no ollama, no service: "Loading models…" while busy, "Ollama is not running" when offline, "No models installed" online with none, and none of them with a model listed.
#
#   tools/dev/llm_picker_empty_probe.sh               last line: LLM_PICKER_EMPTY RESULT PASS|FAIL
#   ARM=<name> tools/dev/llm_picker_empty_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/llm_picker_empty_probe.sh       every ARM; LLM_PICKER_EMPTY ARMS PASS when each failed on ITS check
#
#     nooffline    the empty word ignores `offline` (the old "no models")   -> offline FAILS
#     alwaysoff    any empty list says Ollama is not running                -> none.online FAILS
#     nobusy       busy no longer wins                                      -> busy FAILS
#     alwaysshown  the empty line is drawn with models listed               -> healthy FAILS
#
# Nothing here touches the machine: no ollama, no network; private XDG dirs.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=LLM_PICKER_EMPTY
declare -A NEEDLE=([nooffline]='offline' [alwaysoff]='none.online' [nobusy]='busy' [alwaysshown]='healthy')
if [ "${ARM:-}" = all ] && [ -z "${LPE_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nooffline alwaysoff nobusy alwaysshown}; do
        sb="/tmp/lares-sbx-lpe-arm-$a"
        # each arm in a FRESH copy of the tree this stands in -- also inside a gate's box copy, which has no .git, so the runner would
        # not re-exec and every arm would patch the same copy (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen LPE_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/llm_picker_empty_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "LPE FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'LPE FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'LPE FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${LPE_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-lpe}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen LPE_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/llm_picker_empty_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/lpe.XXXXXX")
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
    P=modules/bar/llm/components/LlmModelPicker.qml
    case "$ARM" in
        nooffline) arm $P ': root.offline ? "Ollama is not running" : "No models installed"' ': "No models installed"' ;;
        alwaysoff) arm $P ': root.offline ? "Ollama is not running" : "No models installed"' ': "Ollama is not running"' ;;
        nobusy) arm $P 'text: root.busy ? "Loading models…"' 'text: false ? "Loading models…"' ;;
        alwaysshown) arm $P 'visible: !root.models || root.models.length === 0' 'visible: true' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" LPE_RUN=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-120} quickshell -n -p "$(pwd)/tools/dev/qml/llm_picker_empty_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: LPE .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: LPE DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: LPE DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: LPE ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "LPE warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/lpe_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
