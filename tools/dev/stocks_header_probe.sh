#!/usr/bin/env bash
# stocks_header_probe.sh -- the stock detail's header (modules/stocks/StockDetailHeader.qml): the scrub's date has a slot of its own
# that never reaches the facts line, and a range other than 1D shows its own move, labelled.
#
#   tools/dev/stocks_header_probe.sh                 STOCKSHEADER RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=narrowdate tools/dev/stocks_header_probe.sh  the date slot is the amount's slot again (the old layout): the date check goes red
#   ARM=foreignfig tools/dev/stocks_header_probe.sh  another stock's figure is shown: the "another stock" check goes red
#   ARM=oldwidth tools/dev/stocks_header_probe.sh    the name ends at the whole right block again (the old cut): the "room" check goes red
#
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh); an ARM runs in the sandbox copy and must fail on its own needle.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/sh.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
H=modules/stocks/StockDetailHeader.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    narrowdate) ARMCMD="sed -i 's|^    readonly property real leftW: .*|    readonly property real leftW: head.labelW + 6 + head.absW|' $H"; NEEDLE='SH FAIL the scrub' ;;
    foreignfig) ARMCMD="sed -i 's|head.fig.symbol === head.symbol \&\& ||' $H"; NEEDLE='SH FAIL another stock' ;;
    oldwidth) ARMCMD="grep -q '        width: head.priceX - 10 - x' $H && sed -i 's|        width: head.priceX - 10 - x|        width: head.rightX - 10 - x|' $H"; NEEDLE='SH FAIL room: on every range the name' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 60 quickshell -p tools/dev/qml/stocks_header_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-stocks-header}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'SH .*' | grep -a -v 'SH RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'SH RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result STOCKSHEADER "$D/log" 'SH RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi    # the log the verdict names must outlive the run
printf '%s\n' "$res" | sed 's/^SH RESULT/STOCKSHEADER RESULT/'
exit $rc
