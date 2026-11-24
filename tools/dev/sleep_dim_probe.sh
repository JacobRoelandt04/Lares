#!/usr/bin/env bash
# sleep_dim_probe.sh -- an idle SUSPEND after SoftIdle's dimming gives back the brightness the panel had BEFORE the dimming
# (tools/dev/qml/sleep_dim_probe.qml: SoftIdle and SleepFade, live, in the shell's wiring, on a stub `brightnessctl` over a FAKE backlight
# directory and a stub brightness script; the panel is read from the fake after every step). Nothing of the machine is touched: no real
# backlight, no hypridle, no logind (PrepareForSleep is a fake signal), no desktop.
#
#   tools/dev/sleep_dim_probe.sh                 SLEEP_DIM RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/sleep_dim_probe.sh      the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     oldsaved    the climb returns to the level the panel READ at the sleep (the deep value), as before   -> "the climb lands on"
#     nosync      SoftIdle is not told the panel was given back (IdleService's wiring)                      -> "IdleService wires"
#     nostatefile SoftIdle forgets its level but leaves the state file                                      -> "SoftIdle agrees"
#     barectl     SoftRules' brightnessctl calls name no device (the first backlight it finds)                  -> "SoftRules names the panel"
#     keyloses    the climb does not look at the panel before its writes (a key is overwritten)              -> "a key during the climb wins"
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/sdim.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
# each ARM is a literal replacement in the sandbox copy (python, so nothing is quoted twice); it aborts the run when its anchor is gone
arm() { ARMCMD="${ARMCMD:+$ARMCMD; }python3 -c 'import sys; p, o, n = sys.argv[1:4]; s = open(p).read(); sys.exit(\"ARM anchor gone: \" + o) if s.count(o) != 1 else open(p, \"w\").write(s.replace(o, n))' $(printf '%q ' "$@")"; }
case "${ARM:-}" in
    "") ;;
    oldsaved)    NEEDLE="the climb lands on"
                 arm modules/idle/sleep/SleepFade.qml 'root._keep : l.given)' 'root._keep : l.saved)' ;;
    nosync)      NEEDLE="IdleService wires"
                 arm modules/idle/IdleService.qml 'onGaveBack: softEngine.panelGivenBack()' 'onGaveBack: {}' ;;
    nostatefile) NEEDLE="SoftIdle agrees"
                 arm modules/idle/SoftIdle.qml 'forget.command = ["rm", "-f", root.settings.stateFile];' 'forget.command = ["true"];' ;;
    barectl)     NEEDLE="SoftRules names the panel"
                 arm modules/idle/SoftRules.js "'g=\$(\"\$2\" -c backlight -d \"\$3\" g 2> /dev/null) || exit 3'" "'g=\$(\"\$2\" g 2> /dev/null) || exit 3'"
                 arm modules/idle/SoftRules.js "'m=\$(\"\$2\" -c backlight -d \"\$3\" m 2> /dev/null) || exit 4'" "'m=\$(\"\$2\" m 2> /dev/null) || exit 4'" ;;
    keyloses)    NEEDLE="a key during the climb wins"
                 arm modules/idle/sleep/SleepFade.qml $'[ \\"$cur\\" = \\"$last\\" ] || { rm -f \\"$rec\\"; echo \\"kept $cur\\"; exit 0; }\\n"\n                + "  { [ $skip' $'true\\n"\n                + "  { [ $skip' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# the stubs: a brightnessctl over a fake backlight, and the user's brightness script reduced to what soft calls (--resume)
mkdir -p "$D/stubs" "$D/fake"
: > "$D/fake/devices"
# the machine in dGPU-only mode: nvidia_0 drives the eDP (max 100 in the real one; the stub ignores the figures) -- PanelBacklight names it
mkdir -p "$D/sysroot/class/backlight/nvidia_0" "$D/sysroot/class/drm/card1" "$D/sysroot/pci/dev0" "$D/sysroot/bus/pci/drivers/nvidia"
echo 100 > "$D/sysroot/class/backlight/nvidia_0/max_brightness"; echo 100 > "$D/sysroot/class/backlight/nvidia_0/brightness"
ln -s "$D/sysroot/bus/pci/drivers/nvidia" "$D/sysroot/pci/dev0/driver"; ln -s "$D/sysroot/pci/dev0" "$D/sysroot/class/drm/card1/device"
ln -s "$D/sysroot/class/drm/card1" "$D/sysroot/class/drm/card1-eDP-1"
echo 400 > "$D/fake/brightness"; echo 400 > "$D/fake/max_brightness"
cat > "$D/stubs/brightnessctl" <<'STUB'
#!/usr/bin/env bash
# brightnessctl [-c class] [-d device] g | m | set N   (over $FAKE; a percent or a relative value is not used by the shell's steps)
# THE SHELL NAMES THE PANEL'S DEVICE: a call without -d is the first backlight brightnessctl finds (nvidia_0 in dGPU mode) -- logged, refused
dev=""
while [ "${1:-}" = -c ] || [ "${1:-}" = -d ]; do [ "$1" = -d ] && dev="$2"; shift 2; done
echo "dev=${dev:-BARE} $*" >> "$FAKE/devices"
[ -n "$dev" ] || exit 9
case "${1:-}" in
    g) cat "$FAKE/brightness" ;;
    m) cat "$FAKE/max_brightness" ;;
    set) echo "$2" > "$FAKE/brightness"; echo "set $2" >> "$FAKE/calls" ;;
    *) exit 2 ;;
esac
STUB
cat > "$D/stubs/brightness.sh" <<'STUB'
#!/usr/bin/env bash
# the user's ~/.config/hypr/scripts/brightness.sh, --resume only
[ "${1:-}" = --resume ] || exit 2
value=$(cat "$STATE") || exit 1
# (the real script calls brightnessctl bare -- the first backlight, which in dGPU-only mode IS nvidia_0; the stub refuses a bare call, so it says so)
"$STUBS/brightnessctl" -c backlight -d nvidia_0 set "$value"
rm "$STATE"
STUB
chmod +x "$D/stubs/brightnessctl" "$D/stubs/brightness.sh"

run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi LARES_SLEEP_MONITOR=off LARES_SYSFS_ROOT='"$D/sysroot"' FAKE='"$D/fake"' STATE='"$D/state"' STUBS='"$D/stubs"' timeout 120 quickshell -p tools/dev/qml/sleep_dim_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-sleep-dim}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'SDIM \(ok\|FAIL\) ' | sed 's/^.*SDIM /SDIM /'
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'SDIM RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'SDIM FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result SLEEP_DIM "$D/log" 'SDIM RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
printf '%s\n' "$res" | sed 's/^SDIM RESULT/SLEEP_DIM RESULT/'
exit $rc
