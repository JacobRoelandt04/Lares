#!/usr/bin/env bash
# stocks_note_probe.sh -- the stocks summary card's note ("updated 11:02", "offline, from 08:02", ...) says when the figures on
# show were fetched and changes with them (modules/stocks/StocksSummaryCard.qml, THE NOTE BESIDE THE TITLE).
#
#   tools/dev/stocks_note_probe.sh             STOCKSNOTE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=cfgnote|cfglist|cfgwarn|cfgalways   a broken stocks.jsonc is not said (card note / list words / warn colour) or always said
#   ARM=live tools/dev/stocks_note_probe.sh    the note reads the service's live flags again: the "before the figures" checks go red
#   ARM=all                                    every arm in turn: STOCKSNOTE ARMS RESULT PASS when each failed on its own needle
#
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh); an ARM runs in the sandbox copy and must fail on its own needle.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then   # every arm, each in a fresh sandbox sync; PASS only when each failed on its own needle
    rc=0
    for a in live cfgnote cfglist cfgwarn cfgalways; do
        out=$(ARM="$a" bash "$0" 2>&1); printf '%s\n' "$out" | grep -a '^ARM ' | tail -1
        printf '%s\n' "$out" | grep -aq "^ARM $a: failed as it must" || rc=1
    done
    [ "$rc" -eq 0 ] && echo "STOCKSNOTE ARMS RESULT PASS" || echo "STOCKSNOTE ARMS RESULT FAIL"
    exit "$rc"
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/sn.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
C=modules/stocks/StocksSummaryCard.qml
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    live) ARMCMD="grep -q 'readonly property var n: card._note' $C && sed -i 's|readonly property var n: card._note|readonly property var n: card.service ? { at: card.service.fetchedAtMs, loading: card.service.loading, offline: card.service.offline, stale: card.service.stale, rateLimited: card.service.rateLimited, retryAtMs: card.service.retryAtMs } : null|' $C"
          NEEDLE='SN FAIL a landed fetch changes nothing before the figures' ;;
    cfgnote) ARMCMD="grep -q 'if (n.configError)' $C && sed -i 's|if (n.configError)|if (false)|' $C"
          NEEDLE='SN FAIL cfg: the card.s note says' ;;
    cfglist) ARMCMD="grep -q 'readonly property string cfgError: list.service' modules/stocks/StocksList.qml && sed -i 's|readonly property string cfgError: list.service \&\& list.service.configError ? String(list.service.configError) : \"\"|readonly property string cfgError: \"\"|' modules/stocks/StocksList.qml"
          NEEDLE='SN FAIL cfg: the empty list says' ;;
    cfgwarn) ARMCMD="grep -q 'list.tab === \"holdings\" && emptyText.cfgError ? Theme.warn' modules/stocks/StocksList.qml && sed -i 's|list.tab === \"holdings\" \&\& emptyText.cfgError ? Theme.warn|list.tab === \"holdings\" \&\& false ? Theme.warn|' modules/stocks/StocksList.qml"
          NEEDLE='SN FAIL cfg: the empty list says' ;;
    cfgalways) ARMCMD="grep -q ': emptyText.cfgError ? \"stocks.jsonc has an error: \"' modules/stocks/StocksList.qml && sed -i 's|: emptyText.cfgError ? \"stocks.jsonc has an error: \"|: true ? \"stocks.jsonc has an error: \"|' modules/stocks/StocksList.qml"
          NEEDLE='SN FAIL cfg: healthy empty list has no config error' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' timeout 60 quickshell -p tools/dev/qml/stocks_note_probe.qml'
QT_QPA_PLATFORM=offscreen SANDBOX="${SANDBOX:-/tmp/lares-sandbox-stocks-note}" tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'SN .*' | grep -a -v 'SN RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'SN RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result STOCKSNOTE "$D/log" 'SN RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi    # the log the verdict names must outlive the run
printf '%s\n' "$res" | sed 's/^SN RESULT/STOCKSNOTE RESULT/'
exit $rc
