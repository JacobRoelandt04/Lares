#!/usr/bin/env bash
# The player's empty library names a dead daemon (PlayerLibrary, commit 7bf8040a): the REAL library over a plain mock player (no mpd) whose health is built
# by the real MpdHealth.diagnose, headless, in the sandbox (tools/dev/qml/player_library_empty_probe.qml): mpd-* kinds put the health title on the empty line,
# a healthy player / a non-mpd sound fault / a banner not shown leave "Nothing here" / "No playlists".
#
#   tools/dev/player_library_empty_probe.sh               last line: PLAYER_LIBRARY_EMPTY RESULT PASS|FAIL
#   ARM=<name> tools/dev/player_library_empty_probe.sh    a fault in the SANDBOX copy; the run must end FAIL with the named check red
#   ARM=all tools/dev/player_library_empty_probe.sh       every ARM; PLAYER_LIBRARY_EMPTY ARMS PASS when each failed on ITS check
#
#     nomentpd     the empty line never names the daemon                  -> mpd-down FAILS
#     anyfault     any shown fault (not only mpd-*) names itself          -> sound-fault FAILS
#     ignoreshown  the title is read though the banner is not shown       -> hidden-banner FAILS
#     nameonly     only mpd-down is named, the others keep "Nothing here" -> mpd-unreachable FAILS
#
# Nothing here touches the machine: no mpd, no PipeWire, no process; private XDG dirs.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=PLAYER_LIBRARY_EMPTY
declare -A NEEDLE=([nomentpd]='mpd-down' [anyfault]='sound-fault' [ignoreshown]='hidden-banner' [nameonly]='mpd-unreachable')
if [ "${ARM:-}" = all ] && [ -z "${PLE_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nomentpd anyfault ignoreshown nameonly}; do
        sb="/tmp/lares-sbx-ple-arm-$a"
        # each arm in a FRESH copy of the tree this stands in -- also inside a gate's box copy, which has no .git, so the runner would
        # not re-exec and every arm would patch the same copy (CLAUDE.md: an ARM=all loop in one copy carries every earlier arm's patch)
        res=$(SANDBOX="$sb" tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen PLE_INNER=1 ARM=$a SCRATCH="${SCRATCH:-}" bash tools/dev/player_library_empty_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "PLE FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}: $(printf '%s\n' "$res" | grep 'PLE FAIL' | head -3 | tr '\n' ';')"; bad=1
        else echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c 'PLE FAIL') red, incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -e .git ] && [ -z "${PLE_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-ple}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen PLE_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/player_library_empty_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
WORK=$(mktemp -d "$SCR/ple.XXXXXX")
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
    Q=modules/bar/player/components/PlayerLibrary.qml
    case "$ARM" in
        nomentpd) arm $Q 'text: emptyLabel._mpdFault !== "" ? emptyLabel._mpdFault' 'text: false ? emptyLabel._mpdFault' ;;
        anyfault) arm $Q '&& String(root.player.health.kind || "").indexOf("mpd-") === 0 ?' '&& String(root.player.health.kind || "") !== "ok" ?' ;;
        ignoreshown) arm $Q 'root.player && root.player.health && root.player.health.shown === true' 'root.player && root.player.health' ;;
        nameonly) arm $Q 'indexOf("mpd-") === 0 ?' 'indexOf("mpd-down") === 0 ?' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi
mkdir -p "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
echo '{"theme":"eva","mode":"light"}' > "$WORK/cfg/theme/state.json"
log="$WORK/run.log"
env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" PLE_RUN=1 \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= timeout -k 5 ${DEADLINE:-120} quickshell -n -p "$(pwd)/tools/dev/qml/player_library_empty_probe.qml" > "$log" 2>&1
rl_clean "$log" | grep -a -oE 'qml: PLE .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: PLE DONE (PASS|FAIL)'; then
    KEEP_W=1
    [ -n "$ARM" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult "$NAME" "$log"; exit 1
fi
fail=0
rl_has "$log" 'qml: PLE DONE PASS' || fail=1
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: PLE ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "PLE warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || { cp "$log" "$SCR/ple_last.log" 2> /dev/null; echo "$NAME RESULT FAIL"; }
exit "$fail"
