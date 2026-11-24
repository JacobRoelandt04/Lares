#!/usr/bin/env bash
# notif_live_probe.sh -- a LIVE post of the notification service (the wiki's batch progress): hidden by a swipe into the manager,
# never re-toasted by its own updates while hidden, brought back by the manager's swipe; kept on the lane when the manager opens.
# The real NotificationService (tools/dev/qml/notif_live_probe.qml), the notifications probe library: a sandbox copy, a private
# bus, private XDG dirs, stubs.
#
#   tools/dev/notif_live_probe.sh            NOTIF_LIVE RESULT PASS|FAIL (<n> checks)
#   ARM=<name> tools/dev/notif_live_probe.sh one fault in the snapshot; must FAIL on its own check
#   ARM=all                                  every arm: NOTIF_LIVE ARMS RESULT PASS|FAIL
#     retoast    a hidden live record is re-toasted by its updates (the user's "it will just reappear")   -> L4
#     manager    an update while the manager is open files (hides) a live toast like any other              -> L2
#     keep       the manager opening files a live toast with every other one                                -> L2
#     limbo      a live toast that ends by itself is filed without being hidden (in neither place)         -> L7
#     askheld    the shell's question is held by a share like any other (it reverts behind the user's back) -> L9
#     anyfixed   any fixed record passes a share, breakDnd or not                                          -> L9
#     lockshare  a lock that becomes a share keeps the question                                            -> L9
#     rulebreak  a rule's breakDnd is not read                                                             -> L10
#     rulesilent a post that asks for no sound gets its urgency's                                          -> L11
#     noapp      dnd.holdApps is not read                                                                  -> L12
#     lanefocus  screen is not read                                                                        -> L13
#     fsfocused  the fullscreen hold is always the focused screen's                                        -> L13
#     handlost   the quiet hours take back a switch by hand at every look                                  -> L14
#     askflood   the flood rule collapses a question (the probe's fifth post in 10 s)                      -> L9
# Every anchor is ONE line (`read` takes one: a multi-line anchor arrives cut and patches something else).
set -u
export LARES_SLEEP_MONITOR=off
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/fixtures/notifications/probe_lib.sh
. tools/dev/result_lib.sh
NAME=NOTIF_LIVE
PROBE=notif_live_probe.qml
notif_reexec tools/dev/notif_live_probe.sh
OUT="$SCRATCH/notif_live_probe"
mkdir -p "$OUT"
S=modules/notifications/data/NotificationService.qml
ARMS="retoast manager limbo keep askheld anyfixed lockshare askflood rulebreak rulesilent noapp lanefocus fsfocused handlost"
P=modules/notifications/data/NotifyPolicy.js
HO=modules/notifications/data/NotificationHolds.qml

arm_of() {  # name -> file<TAB>from<TAB>to<TAB>needle
    case "$1" in
        retoast) printf '%s\t%s\t%s\t%s' "$S" '        const mode = rec.live === true && rec.hidden === true ? "inplace" : Policy.retoast(prev, rec);' \
                     '        const mode = Policy.retoast(prev, rec);' "L4 updates of a hidden one" ;;
        manager) printf '%s\t%s\t%s\t%s' "$S" '            managerOpen: root.managerOpen && !(rec.live === true && rec.hidden !== true),' \
                     '            managerOpen: root.managerOpen,' "L2 the manager opening" ;;
        limbo)   printf '%s\t%s\t%s\t%s' "$S" '        else if (root._isLive(uid))' '        else if (false)' "L7 file hides it" ;;
        keep)    printf '%s\t%s\t%s\t%s' "$S" '        const keepShown = sched.shown.filter(u => root._isFixed(u) || root._liveOnLane(u));' \
                     '        const keepShown = sched.shown.filter(u => root._isFixed(u));' "L2 the manager opening" ;;
        askheld) printf '%s\t%s\t%s\t%s' "$P" '        if (c.breaks && rec && rec.fixed === true)' '        if (false)' "L9 a question is shown under DND and a screen share" ;;
        anyfixed) printf '%s\t%s\t%s\t%s' "$P" '        if (c.breaks && rec && rec.fixed === true)' '        if (rec && rec.fixed === true)' "L9 a fixed record without breakDnd" ;;
        lockshare) printf '%s\t%s\t%s\t%s' "$S" '                    if (rec.urgency === "critical" || rec.fixed === true)      // _decide holds it again if it must wait' '                    if (rec.urgency === "critical")' "L9 a question waits for a lock" ;;
        askflood) printf '%s\t%s\t%s\t%s' "modules/notifications/data/ToastScheduler.qml" '        if (fc.flooded && rec.urgency !== "critical" && rec.fixed !== true) {' '        if (fc.flooded && rec.urgency !== "critical") {' "L9 a question" ;;
        rulebreak) printf '%s\t%s\t%s\t%s' "$S" '            ruleBreaks: !!rule && rule.breakDnd === true,' '            ruleBreaks: false,' "L10 a rule" ;;
        rulesilent) printf '%s\t%s\t%s\t%s' "modules/notifications/data/NotificationSound.qml" '        if (w.spec === "none")' '        if (false)' "L11 a rule" ;;
        noapp) printf '%s\t%s\t%s\t%s' "$HO" '        : root._holdApp ? "app" : ""' '        : ""' "L12 a window" ;;
        lanefocus) printf '%s\t%s\t%s\t%s' "$HO" 'root.focusSource.displayFor(root._screenWord)' 'root.focusedScreen' "L13 the toasts" ;;
        fsfocused) printf '%s\t%s\t%s\t%s' "$HO" 'root.laneNamed ? root.focusSource.fullscreenOn(root.lane) : watch.fullscreen' 'watch.fullscreen' "L13 the toasts" ;;
        handlost) printf '%s\t%s\t%s\t%s' "$S" '        if (last && last.at > st.hoursAt) {' '        if (last) {' "L14 quiet hours" ;;
        *) return 1 ;;
    esac
}

run_one() {  # cfg log
    notif_run "$1" "$PROBE" "$2"
    local out
    out=$(notif_lines "$2" LIVE)
    if ! printf '%s\n' "$out" | grep -q "LIVE RESULT"; then
        rl_noresult "$NAME" "$2"; return 2
    fi
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -q "LIVE RESULT PASS" || return 1
    local w
    w=$(notif_warnings "$2")
    [ -z "$w" ] || { echo "warnings:"; printf '%s\n' "$w" | head -5; return 1; }
    return 0
}

one_arm() {
    local a="$1" spec f from to needle cfg="$OUT/cfg_$1"
    spec=$(arm_of "$a") || { echo "ARM $a: unknown"; return 1; }
    IFS=$'\t' read -r f from to needle <<< "$spec"
    notif_snapshot "$cfg" "tools/dev/qml/$PROBE"
    notif_arm "$cfg/$f" "$from" "$to" || { echo "ARM $a: NOT PROVEN (its anchor is gone)"; return 1; }
    notif_run "$cfg" "$PROBE" "$OUT/arm_$a.log"
    local out
    out=$(notif_lines "$OUT/arm_$a.log" LIVE)
    if ! printf '%s\n' "$out" | grep -q "LIVE RESULT"; then echo "ARM $a: NOT PROVEN (the armed copy did not load)"; return 1; fi
    if printf '%s\n' "$out" | grep -q "LIVE RESULT PASS"; then echo "ARM $a: STAYED GREEN"; return 1; fi
    if printf '%s\n' "$out" | grep "^LIVE FAIL" | grep -qF "$needle"; then echo "ARM $a: FAILED AS IT MUST ($needle)"; rm -rf -- "${cfg:?}"; return 0; fi
    echo "ARM $a: FAILED, BUT NOT ON ITS CHECK: $(printf '%s\n' "$out" | grep '^LIVE FAIL' | head -1)"; return 1
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
notif_snapshot "$cfg" "tools/dev/qml/$PROBE"
run_one "$cfg" "$OUT/probe.log"; rc=$?
[ "$rc" = 2 ] && exit 1
if [ "$rc" = 0 ]; then echo "$NAME RESULT PASS ($(notif_lines "$OUT/probe.log" LIVE | grep -c '^LIVE PASS') checks)"; exit 0; fi
echo "$NAME RESULT FAIL (log: $OUT/probe.log)"; exit 1
