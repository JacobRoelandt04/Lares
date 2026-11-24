#!/usr/bin/env bash
# viewfinder_open_probe.sh -- the player's scrub bar (modules/bar/player/components/PlayerViewfinder.qml) when the popup opens on a playing
# track: the corrections the open makes to the player's stale position (the clock's catch-up, the status read's seat) are not seeks, so no
# spark flies in the first second; a seek after the grace still sparks.
#
#   tools/dev/viewfinder_open_probe.sh                     VIEWFINDEROPEN RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nograce tools/dev/viewfinder_open_probe.sh         the open has no grace (the old rail): the "no sparks" check goes red
#
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh); an ARM runs in the sandbox copy and must fail on its own needle.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/vfo.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F=modules/bar/player/components/PlayerViewfinder.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nograce) ARMCMD="sed -i 's|^    Component.onCompleted: rail._openGrace()|    Component.onCompleted: rail._grace = false|; s|^            rail._openGrace();|            rail._grace = false;|' $F"; NEEDLE='VFO FAIL .*no sparks in the first second' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 120 quickshell -p tools/dev/qml/viewfinder_open_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-viewfinder-open}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'VFO .*' | grep -a -v 'VFO RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'VFO RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result VIEWFINDEROPEN "$D/log" 'VFO RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi    # the log the verdict names must outlive the run
printf '%s\n' "$res" | sed 's/^VFO RESULT/VIEWFINDEROPEN RESULT/'
exit $rc
