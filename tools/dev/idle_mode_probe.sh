#!/usr/bin/env bash
# idle_mode_probe.sh -- what each idle mode does to the panel's dimming, on the MOCK IdleService (modules/idle: nothing is held, no program runs).
#
#   tools/dev/idle_mode_probe.sh                  IDLE_MODE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=oldoff tools/dev/idle_mode_probe.sh       off does not dim (the rule as it was: only soft runs the engine)  -> "off: the engine is on"
#   ARM=offholds tools/dev/idle_mode_probe.sh     off holds the Wayland inhibitor like soft (hypridle could not suspend) -> "off holds NO Wayland inhibitor"
#   ARM=normaldims tools/dev/idle_mode_probe.sh   normal dims too                                                  -> "normal: nothing dims"
#   ARM=nopause tools/dev/idle_mode_probe.sh      off ignores ContentHold (a video is dimmed)                      -> "off: a video (ContentHold) pauses"
#   ARM=panelblind tools/dev/idle_mode_probe.sh   a machine with no laptop panel needs the brightness script too   -> "soft needs no script"
#
# Two runs: the machine is a laptop (a fixture /sys with an eDP and its backlight), then a desktop (a /sys with neither).
#
# Off and soft dim by the same engine (steps, levels, the video pause, the away rule, the resume on input); off holds nothing so the machine goes on
# to suspend; normal and hard dim nothing. The ARMs patch the probe's SANDBOX copy of modules/idle. The verdict is the probe's own RESULT line
# (tools/dev/result_lib.sh). Nothing touches the desktop: offscreen, a private copy of this config.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/idlem.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    oldoff)      NEEDLE="off: the engine is on"
                 ARMCMD="sed -i 's|^    readonly property bool dims: .*|    readonly property bool dims: root.mode === \"soft\" \&\& root.softAvailable|' modules/idle/IdleService.qml" ;;
    offholds)    NEEDLE="off holds NO Wayland inhibitor"
                 ARMCMD="sed -i 's|^    readonly property bool normalHold: (root.mode === \"normal\" \|\| root.mode === \"soft\")|    readonly property bool normalHold: (root.mode === \"normal\" \|\| root.mode === \"soft\" \|\| root.mode === \"off\")|' modules/idle/IdleService.qml" ;;
    normaldims)  NEEDLE="normal: nothing dims"
                 ARMCMD="sed -i 's|^    readonly property bool dims: .*|    readonly property bool dims: root.mode !== \"hard\" \&\& root.softAvailable|' modules/idle/IdleService.qml" ;;
    nopause)     NEEDLE="off: a video (ContentHold) pauses"
                 ARMCMD="sed -i 's|const idle = content.held ? Rules.FULL : wanted;|const idle = wanted;|' modules/idle/SoftIdle.qml" ;;
    panelblind)  NEEDLE="soft needs no script"
                 ARMCMD="sed -i 's/ || root.panelless$//' modules/idle/IdleService.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/laptop/class/backlight/intel_backlight" "$D/laptop/class/drm/card1-eDP-1" "$D/desktop/class/backlight" "$D/desktop/class/drm/card1-DP-1"
echo 400 > "$D/laptop/class/backlight/intel_backlight/max_brightness"; echo raw > "$D/laptop/class/backlight/intel_backlight/type"; echo connected > "$D/laptop/class/drm/card1-eDP-1/status"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'for m in laptop desktop; do env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi LARES_SLEEP_MONITOR=off IDLEM_MACHINE=$m LARES_SYSFS_ROOT='"$D"'/$m timeout 90 quickshell -p tools/dev/qml/idle_mode_probe.qml; done'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-idle-mode}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'IDLEM \(ok\|FAIL\) ' | sed 's/^.*IDLEM /IDLEM /'
if [ -n "${ARM:-}" ]; then
    if [ "$(rl_clean "$D/log" | grep -ac 'IDLEM RESULT')" != 2 ]; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'IDLEM FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
[ "$(rl_clean "$D/log" | grep -ac 'IDLEM RESULT')" = 2 ] || { KEEP_D=1; rl_noresult IDLE_MODE "$D/log"; exit 1; }
n=$(rl_clean "$D/log" | grep -ac 'IDLEM ok '); f=$(rl_clean "$D/log" | grep -ac 'IDLEM FAIL ')
if [ "$f" = 0 ] && [ "$(rl_clean "$D/log" | grep -ac 'IDLEM RESULT PASS')" = 2 ]; then echo "IDLE_MODE RESULT PASS ($n/$n checks, 2 machines)"; exit 0; fi
echo "IDLE_MODE RESULT FAIL ($n/$((n + f)) checks)"; exit 1
