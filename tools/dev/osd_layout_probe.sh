#!/usr/bin/env bash
# osd_layout_probe.sh -- the layout OSD (modules/osd/data/sources/LayoutSource.qml): plugging a keyboard (a USB headset's HID keys,
# a virtual keyboard) never shows the layout card; a real layout switch always does.
#
#   tools/dev/osd_layout_probe.sh                 the SIM half: the user's device list and the payloads in plug / switch / unplug order
#   LIVE=1 tools/dev/osd_layout_probe.sh          + the LIVE half: a real Hyprland (tools/dev/lock_env.sh, LOCK_ENV=osdlayout), a virtual
#                                                 keyboard added mid-run (Hyprland makes it `main`, as it does a headset's keys)
#   ARM=followmain tools/dev/osd_layout_probe.sh the old rule (the primary follows the seat's `main`): "plug: no card" goes red
#                                                 (with LIVE=1 the live half shows a card too)
#   ARM=noseed tools/dev/osd_layout_probe.sh      the layout in force is not read at the first list: "start: ..." goes red
#
# Verdict: OSDLAYOUT RESULT PASS | FAIL (tools/dev/result_lib.sh). Offscreen; the live half is nested in lock_env, never on the desktop.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/olp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
F=modules/osd/data/sources/LayoutSource.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    followmain) ARMCMD="sed -i 's|if (root._main === \"\" \|\| known\[root._main\] !== true)|if (true)|' $F"; NEEDLE='OLP FAIL (plug|a real switch|a second plug)' ;;
    noseed)     ARMCMD="sed -i 's|if (root._layout === \"\" \&\& now|if (false \&\& now|' $F"; NEEDLE='OLP FAIL start' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-osd-layout}"
# the arm, applied INSIDE the sandbox copy (the tree is never patched); ARMLOST when its anchor matched nothing
cat > "$D/arm.sh" <<ARM_EOF
cp $F $D/orig.qml
${ARMCMD:-true}
if [ -n "${ARM:-}" ] && cmp -s $F $D/orig.qml; then echo ARMLOST; exit 3; fi
ARM_EOF
cat > "$D/sim.sh" <<SIM_EOF
bash $D/arm.sh || exit \$?
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi OLP_MODE=sim timeout 60 quickshell -p tools/dev/qml/osd_layout_probe.qml
SIM_EOF
tools/dev/sandbox.sh bash "$D/sim.sh" > "$D/sim.log" 2>&1
rl_clean "$D/sim.log" | grep -a -o 'OLP .*' | grep -a -v 'OLP RESULT'
LIVE_OK=1
if [ "${LIVE:-}" = 1 ]; then
    export LOCK_ENV="${LOCK_ENV:-osdlayout}"
    OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { cat "$D/up.log"; echo "OSDLAYOUT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
    cat > "$D/live.sh" <<LIVE_EOF
bash $D/arm.sh || exit \$?
LOG=$D/live.log; : > \$LOG
tools/dev/lock_env.sh run env OLP_MODE=live quickshell -p tools/dev/qml/osd_layout_probe.qml > \$LOG 2>&1 &
QP=\$!
for i in \$(seq 1 60); do grep -q "OLP ready" \$LOG && break; sleep 0.2; done
tools/dev/lock_env.sh run wtype -s 2500 -k a -k b &
WT=\$!
wait \$WT; sleep 0.8
kill \$QP; wait \$QP 2>/dev/null; true
LIVE_EOF
    tools/dev/sandbox.sh bash "$D/live.sh" > "$D/live.run" 2>&1
    tools/dev/lock_env.sh down > /dev/null 2>&1
    rl_clean "$D/live.log" | grep -a -o 'OLP \(raw\|card\|ready\).*'
    if ! rl_has "$D/live.log" 'OLP raw activelayout>>hl-virtual-keyboard-wtype-1'; then LIVE_OK=0; echo "OLP FAIL live: the virtual keyboard's own events never arrived (the env did not add one)"; fi
    if rl_has "$D/live.log" 'OLP card'; then LIVE_OK=0; echo "OLP FAIL live: a keyboard being added showed the layout card"; else echo "OLP ok   live: a keyboard being added shows no card"; fi
fi
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/sim.log" 'ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if { rl_clean "$D/sim.log"; [ "${LIVE:-}" = 1 ] && echo "OLP FAIL live"; } | grep -a -E -q "$NEEDLE" || { [ "$ARM" = followmain ] && [ "$LIVE_OK" = 0 ]; }; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/sim.log" 'OLP RESULT' || { echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result OSDLAYOUT "$D/sim.log" 'OLP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi    # the log the verdict names must outlive the run
res=$(printf '%s\n' "$res" | sed 's/^OLP RESULT/OSDLAYOUT RESULT/')
if [ "$LIVE_OK" = 0 ]; then res="OSDLAYOUT RESULT FAIL (the live half is red)"; rc=1; fi
printf '%s\n' "$res"
exit $rc
