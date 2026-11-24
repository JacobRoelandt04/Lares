#!/usr/bin/env bash
# panel_backlight_probe.sh -- the panel's backlight is ONE answer and every consumer takes it (round 12; feedback "MUX mode uses different
# brightness"). tools/dev/qml/panel_backlight_probe.qml once per FIXTURE sysfs tree (LARES_SYSFS_ROOT), with a stub brightnessctl over the
# same tree that fails any call without -d. Nothing of the machine is read or written: no real backlight, no daemon, no desktop.
#
#   tools/dev/panel_backlight_probe.sh             PANEL_BACKLIGHT RESULT PASS | FAIL
#   ARM=<name> tools/dev/panel_backlight_probe.sh  the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     hybridstray  the rule ignores which GPU drives the eDP and takes the last backlight (nvidia_0 in Hybrid)     -> "PanelBacklight answers"
#     firstedp     the first eDP connector with a driver decides, connected or not (the NVIDIA card's own, in Hybrid) -> "PanelBacklight answers"
#     barectl      SoftRules' brightnessctl calls carry no -c backlight -d <device> (the first backlight it finds) -> "SoftRules' read step"
#     nohold       LidDim never asks the veil to hold the panel black where 0 is lit                           -> "0 is NOT black here"
# Trees: hybrid (intel only), stray (Hybrid with nvidia_0 registered), nvidia (dGPU-only), nothing, nodrvstray (the eDP's driver unreadable,
# both backlights), nodrvnv (unreadable, nvidia_0 alone).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-panelbl}"
D="$(mktemp -d "${SCRATCH:-/tmp}/pbl.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
armadd() { ARMCMD="${ARMCMD:+$ARMCMD; }python3 -c 'import sys; p, o, n = sys.argv[1:4]; s = open(p).read(); sys.exit(\"ARM anchor gone: \" + o) if s.count(o) != 1 else open(p, \"w\").write(s.replace(o, n))' $(printf '%q ' "$@")"; }
case "${ARM:-}" in
    "") ;;
    hybridstray) NEEDLE="PanelBacklight answers"
                 armadd modules/common/system/PanelBacklightRules.js 'own ? own.test(list[k].name) : !isNvidia(list[k].name)' 'true'
                 armadd modules/common/system/PanelBacklightRules.js 'return _pick(cands[0], driver, overrides);' 'return _pick(cands[cands.length - 1], driver, overrides);' ;;
    nohold)      NEEDLE="0 is NOT black here"
                 armadd modules/idle/LidDim.qml 'root.veil && !root.zeroIsBlack)' 'false)' ;;
    firstedp)    NEEDLE="PanelBacklight answers"
                 armadd modules/common/system/PanelBacklightRules.js '(pass === 1 || edp[i].connected === true)' 'true' ;;
    barectl)     NEEDLE="SoftRules' read step"
                 armadd modules/idle/SoftRules.js "'g=\$(\"\$2\" -c backlight -d \"\$3\" g 2> /dev/null) || exit 3'" "'g=\$(\"\$2\" g 2> /dev/null) || exit 3'"
                 armadd modules/idle/SoftRules.js "'m=\$(\"\$2\" -c backlight -d \"\$3\" m 2> /dev/null) || exit 4'" "'m=\$(\"\$2\" m 2> /dev/null) || exit 4'" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# a fixture tree: tree <dir> <driver|-> <name:max:type>...   (the eDP connector card1-eDP-1 -> card1 -> pci device -> driver)
tree() {
    local t="$1" drv="$2"; shift 2
    mkdir -p "$t/class/backlight" "$t/class/drm/card1" "$t/pci/dev0" "$t/bus/pci/drivers"
    local b
    for b in "$@"; do
        IFS=: read -r n m ty <<< "$b"
        mkdir -p "$t/class/backlight/$n"; echo "$m" > "$t/class/backlight/$n/brightness"; echo "$m" > "$t/class/backlight/$n/max_brightness"; echo "$ty" > "$t/class/backlight/$n/type"
    done
    if [ "$drv" != - ]; then
        mkdir -p "$t/bus/pci/drivers/$drv"
        ln -s "$t/bus/pci/drivers/$drv" "$t/pci/dev0/driver"
        ln -s "$t/pci/dev0" "$t/class/drm/card1/device"
        ln -s "$t/class/drm/card1" "$t/class/drm/card1-eDP-1"
    fi
}
tree "$D/hybrid"     i915   intel_backlight:400:raw
tree "$D/stray"      i915   intel_backlight:400:raw nvidia_0:100:raw
tree "$D/nvidia"     nvidia nvidia_0:100:raw
tree "$D/nothing"    i915
tree "$D/nodrvstray" -      intel_backlight:400:raw nvidia_0:100:raw
tree "$D/nodrvnv"    -      nvidia_0:100:raw
# Hybrid as the kernel lists it since 7.3.5: the NVIDIA card's own eDP (card0-eDP-2, disconnected) sorts BEFORE the panel's (card1-eDP-1)
tree "$D/twoedp"     i915   intel_backlight:400:raw
echo connected > "$D/twoedp/class/drm/card1/status"
mkdir -p "$D/twoedp/class/drm/card0" "$D/twoedp/pci/dev1" "$D/twoedp/bus/pci/drivers/nvidia"
ln -s "$D/twoedp/bus/pci/drivers/nvidia" "$D/twoedp/pci/dev1/driver"
ln -s "$D/twoedp/pci/dev1" "$D/twoedp/class/drm/card0/device"
echo disconnected > "$D/twoedp/class/drm/card0/status"
ln -s "$D/twoedp/class/drm/card0" "$D/twoedp/class/drm/card0-eDP-2"

# case <tree> <expected device> <max> <zeroIsBlack 1|0>
cases=("hybrid intel_backlight 400 1" "stray intel_backlight 400 1" "nvidia nvidia_0 100 0" "nothing - 0 1" "nodrvstray intel_backlight 400 1" "nodrvnv nvidia_0 100 0" "twoedp intel_backlight 400 1")
[ -n "${ONLY:-}" ] && cases=("${cases[@]}")
: > "$D/log"
for c in "${cases[@]}"; do
    read -r name dev mx zero <<< "$c"
    [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ] && continue
    [ "$dev" = - ] && dev=""
    cp -r "$D/$name" "$D/run-$name"
    # symlinks inside are absolute into $D/<name>: re-point them at the run copy
    find "$D/run-$name" -type l | while read -r l; do t=$(readlink "$l"); ln -sfn "${t/$D\/$name/$D/run-$name}" "$l"; done
    echo "## $name" >> "$D/log"
    run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi LARES_SLEEP_MONITOR=off LARES_SYSFS_ROOT='"$D/run-$name"' PB_SYS='"$D/run-$name"' EXPECT_DEV='"$dev"' EXPECT_MAX='"$mx"' EXPECT_ZERO='"$zero"' PATH="'"$PWD/tools/dev/fixtures/panel_backlight"':$PATH" timeout 120 quickshell -p tools/dev/qml/panel_backlight_probe.qml'
    tools/dev/sandbox.sh bash -c "$run" > "$D/log-$name" 2>&1
    rl_clean "$D/log-$name" | grep -a 'PB \(ok\|FAIL\) \|PB RESULT' | sed "s/^.*PB /[$name] PB /" | tee -a "$D/log"
done
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'PB RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D)"; exit 1; fi
    if grep -a 'PB FAIL' "$D/log" | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D)"; exit 1
fi
nres=$(grep -ac 'PB RESULT' "$D/log"); npass=$(grep -ac 'PB RESULT PASS' "$D/log")
if [ "$nres" -lt 1 ] || [ "$nres" != "$npass" ]; then KEEP_D=1; echo "PANEL_BACKLIGHT RESULT FAIL ($npass/$nres trees passed; logs $D)"; exit 1; fi
echo "PANEL_BACKLIGHT RESULT PASS ($npass trees)"
