#!/usr/bin/env bash
# stock_notif_probe.sh -- the stocks cards' graph on the real parts (tools/dev/qml/stock_notif_probe.qml): the real StocksNotifier on
# a fake stocks service whose quotes are the cases of tools/dev/fixtures/stock_notif/ (a late drop with ~58 day points, a mid-morning
# jump with 6 window points, a jump 9 minutes after the open with 3, a thin stock with gaps of up to 35 minutes, one of each alert),
# the real NotificationService and NotificationCard, the real StocksViewModel.notifyAlerts. A sandbox copy, a private bus, private
# XDG dirs, stubs. Then tools/dev/sudden_move_cases.js (the pure half) as a second step with its own result line.
#
#   tools/dev/stock_notif_probe.sh            STOCK_NOTIF RESULT PASS|FAIL (<n> checks)
#   ARM=<name> tools/dev/stock_notif_probe.sh one fault in the snapshot; must FAIL on its own check
#   ARM=all                                   every arm: STOCK_NOTIF ARMS RESULT PASS|FAIL
#     windowonly   the card is fed the move's window, not the day                                   -> S1
#     indexx       the chart spaces its points by index, not by time                                 -> S2
#     norefeed     the card never writes a changed prop into the loaded body                          -> S7
#     nominspan    no least price span: a 3 % and a 12 % move fill the box alike                      -> S4
#     noaxismin    no least axis of an hour: a card at the open stretches 3 points over the box       -> S5
#     nolabelclamp the start label is not kept clear of `now`                                         -> S6
#     nopad        no room round the range: the previous close sits on the box's edge                 -> S3
#     alertnobody  an alert is posted without the body                                               -> S9
# Every anchor is ONE line (`notif_arm` takes one).
set -u
export LARES_SLEEP_MONITOR=off
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-stkgr}"
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
. tools/dev/fixtures/notifications/probe_lib.sh
. tools/dev/result_lib.sh
NAME=STOCK_NOTIF
PROBE=stock_notif_probe.qml
notif_reexec tools/dev/stock_notif_probe.sh
OUT="$SCRATCH/stock_notif_probe"
mkdir -p "$OUT"
ARMS="windowonly indexx norefeed nominspan noaxismin nolabelclamp nopad alertnobody"
B=modules/notifications/sources/StockMoveBody.qml
EXTRA="modules/stocks/data tools/dev/fixtures/stock_notif"

arm_of() {  # name -> file<TAB>from<TAB>to<TAB>needle
    case "$1" in
        windowonly) printf '%s\t%s\t%s\t%s' modules/notifications/sources/SuddenMove.js '    var day = daySeries(q, nowMs);' \
                        '    var day = windowOf(q, nowMs, 30);' "S1 the card carries the whole day" ;;
        indexx)     printf '%s\t%s\t%s\t%s' "$B" '        times: root._f.t || null' '        times: null' "S2 drawn x follows time" ;;
        norefeed)   printf '%s\t%s\t%s\t%s' modules/notifications/parts/NotificationCard.qml '    on_RichChanged: card._feedRich()' \
                        '    readonly property int _noRefeed: 0' "S7 the fine answer re-feeds" ;;
        nominspan)  printf '%s\t%s\t%s\t%s' "$B" '        rangeMinSpan: root._f.minSpanPct > 0 && root._f.prevClose > 0 ? root._f.minSpanPct / 100 * root._f.prevClose : 0' \
                        '        rangeMinSpan: 0' "S4 a 3 % and a 12 % move" ;;
        noaxismin)  printf '%s\t%s\t%s\t%s' "$B" '    readonly property real _to: isFinite(root._from) ? Math.max(Number(root._f.nowMs), root._from + 3600000) : NaN' \
                        '    readonly property real _to: isFinite(root._from) ? Number(root._f.nowMs) : NaN' "S5 9 minutes after the open" ;;
        nolabelclamp) printf '%s\t%s\t%s\t%s' "$B" '        return Math.max(0, Math.min(want, root._nowX - root._gapMin - root._leftW));' \
                        '        return Math.max(0, want);' "S6 the time labels never overlap" ;;
        nopad)      printf '%s\t%s\t%s\t%s' "$B" '        rangePad: 0.1' '        rangePad: 0' "S3 the previous-close line" ;;
        alertnobody) printf '%s\t%s\t%s\t%s' modules/stocks/data/StocksViewModel.qml '            if (o.body) {' '            if (false) {' "S9 each alert kind" ;;
        *) return 1 ;;
    esac
}

run_one() {  # cfg log
    notif_run "$1" "$PROBE" "$2" CASE_DIR="$1/tools/dev/fixtures/stock_notif"
    local out
    out=$(notif_lines "$2" STOCKN)
    if ! printf '%s\n' "$out" | grep -q "STOCKN RESULT"; then
        rl_noresult "$NAME" "$2"; return 2
    fi
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -q "STOCKN RESULT PASS" || return 1
    local w
    w=$(notif_warnings "$2" | grep -v "window masks")
    [ -z "$w" ] || { echo "warnings:"; printf '%s\n' "$w" | head -5; return 1; }
    return 0
}

one_arm() {
    local a="$1" spec f from to needle cfg="$OUT/cfg_$1"
    spec=$(arm_of "$a") || { echo "ARM $a: unknown"; return 1; }
    IFS=$'\t' read -r f from to needle <<< "$spec"
    # shellcheck disable=SC2086
    notif_snapshot "$cfg" "tools/dev/qml/$PROBE" $EXTRA
    notif_arm "$cfg/$f" "$from" "$to" || { echo "ARM $a: NOT PROVEN (its anchor is gone)"; return 1; }
    notif_run "$cfg" "$PROBE" "$OUT/arm_$a.log" CASE_DIR="$cfg/tools/dev/fixtures/stock_notif"
    local out
    out=$(notif_lines "$OUT/arm_$a.log" STOCKN)
    if ! printf '%s\n' "$out" | grep -q "STOCKN RESULT"; then echo "ARM $a: NOT PROVEN (the armed copy did not load)"; return 1; fi
    if printf '%s\n' "$out" | grep -q "STOCKN RESULT PASS"; then echo "ARM $a: STAYED GREEN"; return 1; fi
    if printf '%s\n' "$out" | grep "^STOCKN FAIL" | grep -qF "$needle"; then echo "ARM $a: FAILED AS IT MUST ($needle)"; rm -rf -- "${cfg:?}"; return 0; fi
    echo "ARM $a: FAILED, BUT NOT ON ITS CHECK: $(printf '%s\n' "$out" | grep '^STOCKN FAIL' | head -1)"; return 1
}

if [ "${ARM:-}" = all ]; then
    fail=0
    for a in $ARMS; do one_arm "$a" || fail=1; done
    [ "$fail" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit $fail
elif [ -n "${ARM:-}" ]; then
    one_arm "$ARM"; exit $?
fi

cfg="$OUT/cfg"
# shellcheck disable=SC2086
notif_snapshot "$cfg" "tools/dev/qml/$PROBE" $EXTRA
run_one "$cfg" "$OUT/probe.log"; rc=$?
[ "$rc" = 2 ] && exit 1
if [ "$rc" = 0 ]; then
    echo "$NAME RESULT PASS ($(notif_lines "$OUT/probe.log" STOCKN | grep -c '^STOCKN PASS') checks)"
else
    echo "$NAME RESULT FAIL (log: $OUT/probe.log)"
fi
# the pure half: SuddenMove.js (window, extremes, span, facts, merge), with its own result line; its --arm must fail
if node tools/dev/sudden_move_cases.js | tail -1 | tee "$OUT/cases.txt" | grep -q "RESULT PASS"; then
    cat "$OUT/cases.txt"
else
    cat "$OUT/cases.txt"; rc=1
fi
node tools/dev/sudden_move_cases.js --arm | tail -1 | grep -q "RESULT FAIL" || { echo "SUDDEN_MOVE ARM stayed green"; rc=1; }
[ "$rc" = 0 ] && exit 0
exit 1
