#!/usr/bin/env bash
# su_url_close_probe.sh -- the system update popup: the package icon's link opens the URL AND closes the popup, and the lookup
# outlives the content (an injected opener, as the service's).
#
#   tools/dev/su_url_close_probe.sh               SUURLCLOSE RESULT PASS | FAIL (...)
#   ARM=noclose tools/dev/su_url_close_probe.sh   the link no longer closes (the old behaviour): "closeRequested fired" must go red
#   ARM=ownopener tools/dev/su_url_close_probe.sh the popup ignores the injected opener and uses its own (dies with the content): "the opener answered" must go red (the lookup died with the content)
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/sucl.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
P=modules/bar/system_update/components/SystemUpdatePopup.qml
ARMCMD=""; NEEDLE=""
case "${ARM:-}" in
    "") ;;
    noclose)   NEEDLE="closeRequested fired"; ARMCMD="sed -i '/^                        root._opener.open(name, isAur);/{n;s|root.closeRequested();|// armed|}' $P; grep -q '// armed' $P" ;;
    ownopener) NEEDLE="the opener answered"; ARMCMD="sed -i 's|^    readonly property var _opener: root.urlOpener .. localUrlOpener|    readonly property var _opener: localUrlOpener|' $P; grep -q '_opener: localUrlOpener\$' $P" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SU_TMP='"$D"' timeout 60 quickshell -p tools/dev/qml/su_url_close_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'SUCL .*' | grep -a -v 'SUCL RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a "SUCL FAIL" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must ($NEEDLE)"; exit 0; fi
    if ! rl_has "$D/log" 'SUCL RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE'"; exit 1
fi
res=$(rl_result SUURLCLOSE "$D/log" 'SUCL RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^SUCL RESULT/SUURLCLOSE RESULT/'
exit $rc
