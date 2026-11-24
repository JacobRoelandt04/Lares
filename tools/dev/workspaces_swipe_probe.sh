#!/usr/bin/env bash
# workspaces_swipe_probe.sh -- the workspaces ball through a two-finger swipe (modules/bar/workspaces/Workspaces.qml): the step across
# the clock (slots 2 <-> 3) carries on from where the fingers leaned the ball, and never steps it back to the slot it left.
#
#   tools/dev/workspaces_swipe_probe.sh                    WORKSPACESSWIPE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=droplean tools/dev/workspaces_swipe_probe.sh       the crossing trip starts at the slot again (the old code): "never steps back" goes red
#
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh); an ARM runs in the sandbox copy and must fail on its own needle.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/wsw.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F=modules/bar/workspaces/Workspaces.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    droplean) ARMCMD="sed -i 's|const waypoints = \[from + lean\];|const waypoints = [from];|' $F"; NEEDLE='WSW FAIL .*never steps back' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 90 quickshell -p tools/dev/qml/workspaces_swipe_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-workspaces-swipe}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'WSW .*' | grep -a -v 'WSW RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'WSW RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result WORKSPACESSWIPE "$D/log" 'WSW RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi    # the log the verdict names must outlive the run
printf '%s\n' "$res" | sed 's/^WSW RESULT/WORKSPACESSWIPE RESULT/'
exit $rc
