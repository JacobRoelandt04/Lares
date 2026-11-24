#!/usr/bin/env bash
# osd_lockkeys_card_probe.sh -- osd.jsonc lockkeys.keys on the lock keys card (modules/osd/kinds/OsdLockKeys.qml, OsdStyle.lockExtent), its
# source (LockKeysSource.shown: a lock the card does not show announces nothing) and the config's merge (OsdKinds.mergeConfig). Offscreen, a
# private copy of this config; the verdict is the probe's own RESULT line. The real keys in a nested Hyprland are osd_lockkeys_probe.sh's.
#
#   tools/dev/osd_lockkeys_card_probe.sh                 OSD_LOCKKEYS_CARD RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=bothdrawn ...   the card draws Num whatever the file says              -> "no Num key"
#   ARM=hiddencard ...  a flip of a lock the card does not show is announced    -> "shows no card"
#   ARM=all             every arm: OSD_LOCKKEYS_CARD ARMS PASS | FAIL
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    bad=""
    for a in bothdrawn hiddencard; do
        out=$(ARM=$a "$0" 2>&1); printf '%s\n' "$out" | tail -1
        printf '%s\n' "$out" | tail -1 | grep -q "failed as it must" || bad="$bad $a"
    done
    [ -z "$bad" ] && { echo "OSD_LOCKKEYS_CARD ARMS PASS"; exit 0; }
    echo "OSD_LOCKKEYS_CARD ARMS FAIL ($bad)"; exit 1
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/olkc.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    bothdrawn)  NEEDLE="no Num key"
                ARMCMD="sed -i 's|^        visible: num.at >= 0\$|        visible: true|' modules/osd/kinds/OsdLockKeys.qml" ;;
    hiddencard) NEEDLE="shows no card"
                ARMCMD="sed -i 's|^        if (root._burst \&\& ((flippedCaps !== null \&\& showsCaps) \|\| (flippedNum !== null \&\& showsNum)))\$|        if (root._burst \&\& (flippedCaps !== null \|\| flippedNum !== null))|' modules/osd/data/sources/LockKeysSource.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 60 quickshell -p tools/dev/qml/osd_lockkeys_card_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-olkc}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'OLKC \(ok\|FAIL\) ' | sed 's/^.*OLKC /OLKC /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'OLKC RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'OLKC FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result OSD_LOCKKEYS_CARD "$D/log" 'OLKC RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="OSD_LOCKKEYS_CARD RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res" | sed 's/^OLKC RESULT/OSD_LOCKKEYS_CARD RESULT/'
exit $rc
