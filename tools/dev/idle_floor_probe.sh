#!/usr/bin/env bash
# idle_floor_probe.sh -- the idle FLOOR on the MOCK IdleService (modules/idle; nothing is held, no program runs): whatever an auto cause asks for
# is a floor under the user's mode. A plain pick under it is refused, at or above it taken (the user's mode), a Ctrl pick goes below (the cause set
# aside); a fuzz of causes and picks reads the invariant "the mode in force is never under the user's" at every change.
#
#   tools/dev/idle_floor_probe.sh                  IDLE_FLOOR RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=nofloor tools/dev/idle_floor_probe.sh      setMode takes a plain pick under the floor            -> "is refused"
#   ARM=nomodes tools/dev/idle_floor_probe.sh      idle.jsonc `auto` is not handed to the auto layer        -> "auto.llm"
#   ARM=nostart tools/dev/idle_floor_probe.sh      the start mode is never decided                          -> "the service starts in normal"
#   ARM=nosession tools/dev/idle_floor_probe.sh    "last" takes a file another session wrote                -> "another session"
#   ARM=transient tools/dev/idle_floor_probe.sh    the mode in force reads the derived `autoActive` (a stale answer for a turn) -> "never under the user's mode"
#   ARM=noitems tools/dev/idle_floor_probe.sh      idle.jsonc `items` is never read: all four on offer      -> "items: the service offers"
#   ARM=nopickrefuse tools/dev/idle_floor_probe.sh a pick of a mode left out is taken                       -> "items: a pick of a mode left out is refused"
#   ARM=nodown tools/dev/idle_floor_probe.sh       a start on a mode left out is taken as it is            -> "items: a start on a mode left out"
#   ARM=noup tools/dev/idle_floor_probe.sh         a cause's mode left out is in force all the same         -> "items: a cause asking for a mode left out gets the nearest"
# The ARMs patch the SANDBOX copy of modules/idle. Offscreen, a private copy of this config; the verdict is the probe's own RESULT line.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/idlef.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    nofloor)   NEEDLE="is refused"
               ARMCMD="sed -i 's|        if (override !== true \&\& root.floorMode !== \"\" \&\& AutoRules.rank(m) < AutoRules.rank(root.floorMode)) {|        if (false) {|' modules/idle/IdleService.qml" ;;
    transient) NEEDLE="never under the user's mode"
               ARMCMD="sed -i 's|^    readonly property string mode: .*|    readonly property string mode: root.autoActive ? autoLayer.mode : root.selectedMode|' modules/idle/IdleService.qml" ;;
    nomodes)   NEEDLE="auto.llm"
               ARMCMD="sed -i 's|^        modes: root.checked.auto$|        modes: ({})|' modules/idle/IdleService.qml" ;;
    nostart)   NEEDLE="the service starts in normal"
               ARMCMD="sed -i 's|^        root._begin();$|        ;|' modules/idle/IdleService.qml" ;;
    nosession) NEEDLE="another session"
               ARMCMD="sed -i 's|d.session === root._session \&\& ||' modules/idle/IdleService.qml" ;;
    noitems)   NEEDLE="items: the service offers"
               ARMCMD="sed -i 's|        root.offered = AutoRules.offered(root.checked.items);|        root.offered = AutoRules.offered(null);|' modules/idle/IdleService.qml; grep -q 'AutoRules.offered(null);' modules/idle/IdleService.qml" ;;
    nopickrefuse) NEEDLE="items: a pick of a mode left out is refused"
               ARMCMD="sed -i 's|        if (root.offered.indexOf(m) < 0) {|        if (false) {|' modules/idle/IdleService.qml; grep -q '        if (false) {' modules/idle/IdleService.qml" ;;
    nodown)    NEEDLE="items: a start on a mode left out"
               ARMCMD="sed -i 's|        m = AutoRules.down(m, root.offered);|        ;|' modules/idle/IdleService.qml; ! grep -q 'AutoRules.down(m' modules/idle/IdleService.qml" ;;
    noup)      NEEDLE="items: a cause asking for a mode left out gets the nearest"
               ARMCMD="sed -i 's|AutoRules.higher(root.selectedMode, AutoRules.up(autoLayer.mode, root.offered))|AutoRules.higher(root.selectedMode, autoLayer.mode)|' modules/idle/IdleService.qml; grep -q 'AutoRules.higher(root.selectedMode, autoLayer.mode)' modules/idle/IdleService.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/state"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'IDLEF_DIR='"$D/state"' env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 120 quickshell -p tools/dev/qml/idle_floor_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-idle-floor}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'IDLEF \(ok\|FAIL\) ' | sed 's/^.*IDLEF /IDLEF /' | head -60
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'IDLEF RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'IDLEF FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result IDLE_FLOOR "$D/log" 'IDLEF RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="IDLE_FLOOR RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res" | sed 's/^IDLEF RESULT/IDLE_FLOOR RESULT/'
exit $rc
