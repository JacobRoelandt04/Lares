#!/usr/bin/env bash
# BatteryNotifier's low-charge levels also run for a pack whose charge is STALLED (Charging, nothing flowing): the notifier on a
# stub host and a fake battery (tools/dev/qml/battery_notifier_probe.qml), offscreen in the sandbox.
#
#   tools/dev/battery_notifier_probe.sh          last line: BATTERY-NOTIFIER RESULT PASS|FAIL
#   ARM=ignorestall tools/dev/battery_notifier_probe.sh   the notifier ignores chargeStalled -> stalled-posts FAILS
#   ARM=stuckrail   the progress follow-up waits for Discharging only      -> stalled-follows FAILS
#   ARM=repost      the rail's follow-up posts the card again, as it did       -> discarded-stays-away FAILS
#   ARM=diskrepost  the same in the disk's                                     -> disk-discarded-stays-away FAILS
#   ARM=all         every ARM; BATTERY-NOTIFIER ARMS PASS when each one failed
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BNP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-battery-notifier}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen BNP_INNER=1 ARM="${ARM:-}" bash tools/dev/battery_notifier_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="BATTERY-NOTIFIER"

arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

run_once() {  # arm -> prints the verdict, returns its status
    local tree log out rc N=modules/notifications/sources/BatteryNotifier.qml
    tree=$(mktemp -d "$SCRATCH/bnp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        ignorestall) arm "$tree/$N" 'const draining = b.status === "Discharging" || b.chargeStalled === true;' 'const draining = b.status === "Discharging";' || return 3 ;;
        stuckrail) arm "$tree/$N" '} else if (src._levelUid !== "" && draining && b.percent !== src._lastPct) {' '} else if (src._levelUid !== "" && b.status === "Discharging" && b.percent !== src._lastPct) {' || return 3 ;;
        repost) arm "$tree/$N" 'if (!src.update(src._levelUid, { progress: Levels.share(b.percent, src._target) }))' 'src.post("level", { title: "Battery very low", progress: Levels.share(b.percent, src._target) }); if (false)' || return 3 ;;
        diskrepost) arm "$tree/modules/notifications/sources/DiskNotifier.qml" 'if (src.update(src._cards[g.device].uid, { progress: t.usedPct }))' 'if (src.post(key, { title: t.title, progress: t.usedPct }) !== "")' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    log="$tree/run.log"
    ( cd "$tree" && env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" HOME="$tree/home" \
        tools/dev/notifications_bus.sh timeout 60 quickshell -n -p tools/dev/qml/battery_notifier_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "BATNOTE RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "BATNOTE .*FAIL" | head -4
    rl_isnoresult "$out" || rm -rf "$tree"   # a no-result verdict names the log: keep it
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in ignorestall stuckrail repost diskrepost; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed as it must ($(printf '%s\n' "$o" | grep -a 'BATNOTE .*FAIL' | head -2 | tr '\n' ';'))"; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    # the probe never loaded: result_lib's verdict (printed above) is the last word
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
