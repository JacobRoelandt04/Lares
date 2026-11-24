#!/usr/bin/env bash
# balls_probe.sh -- the squishy ball, frame by frame (tools/dev/qml/balls_probe.qml grabs, tools/dev/balls_judge.py judges).
#
#   tools/dev/balls_probe.sh slider|popup|rail [outdir]     BALLS RESULT PASS | FAIL (...)
#   slider  a GrooveSlider made fresh: the FIRST frame that shows it has its ball (the user's "slider balls appear late")
#   popup   the real AudioPopup on AudioMock made fresh, then a tab switch: no frame shows a slider without its ball
#   rail    a SlotRail picks another stop: the ball squishes on the way and is round at rest
# ARM=hideball (SlotRail's ball never shown: the device rail of `BALLS_SECTION=sinks popup` and the menu go red), ARM=nopaint (SquishItem is not painted when it is made: slider / popup go red on "a slider without its ball"), ARM=roundball (SlotRail's
# ball is held round: rail / menu go red on "no squish"); the fault goes into the sandbox copy, the tree is untouched.
# BALLS_THEME_MODE=light|dark (eva; light by default). BALLS_TREE=<dir> runs against another tree (a `git archive` of an older commit) for a before/after; the frames stay in outdir.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
MODE="${1:-slider}"   # slider|popup|rail|menu; slider when none is given
OUT="${2:-${SCRATCH:-/tmp}/balls_$MODE}"
rm -rf "$OUT"; mkdir -p "$OUT"
TREE="${BALLS_TREE:-}"
priv=$(mktemp -d "${SCRATCH:-/tmp}/ballsenv.XXXXXX")
trap 'rm -rf "$priv"' EXIT
mkdir -p "$priv/state" "$priv/cfg/theme"
printf '{"theme": "eva", "mode": "%s"}\n' "${BALLS_THEME_MODE:-light}" > "$priv/cfg/theme/state.json"
case "${ARM:-}" in
    "") ARMCMD="" ;;
    nopaint)   ARMCMD="sed -i 's|^    Component.onCompleted: root._paintIfStale()|    // armed: no first paint|' modules/common/components/SquishItem.qml" ;;
    roundball) ARMCMD="sed -i 's|^        pressure: 0.0$|        pressure: 0.0; overrideWidth: rail.ballSize; overrideHeight: rail.ballSize|' modules/common/components/SlotRail.qml" ;;
    hideball)  ARMCMD="sed -i 's|^        visible: rail.seated\$|        visible: false|' modules/common/components/SlotRail.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run="${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY XDG_STATE_HOME='"$priv"'/state XDG_CONFIG_HOME='"$priv"'/cfg QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 BALLS_MODE='"$MODE"' BALLS_OUT='"$OUT"' timeout 90 quickshell -p tools/dev/qml/balls_probe.qml'
if [ -n "$TREE" ]; then
    cp tools/dev/qml/balls_probe.qml "$TREE/tools/dev/qml/balls_probe.qml"
    (cd "$TREE" && SANDBOX="${SANDBOX:-/tmp/lares-sandbox-balls}-old" tools/dev/sandbox.sh bash -c "$run") > "$OUT/log" 2>&1
else
    SANDBOX="${SANDBOX:-/tmp/lares-sandbox-balls}" tools/dev/sandbox.sh bash -c "$run" > "$OUT/log" 2>&1
fi
rl_clean "$OUT/log" > "$OUT/log.clean"
# A probe QML that never loaded leaves no "BALLS F" line: that is the no-result verdict (result_lib), never a judged FAIL.
if ! rl_has "$OUT/log" 'BALLS (F|DEADLINE)'; then
    [ -n "${ARM:-}" ] && { echo "ARM $ARM: the armed copy did not load -- it proves nothing ($OUT/log)"; exit 1; }
    rl_noresult BALLS "$OUT/log"; exit 1
fi
python3 -I tools/dev/balls_judge.py "$MODE" "$OUT/log.clean" "$OUT" | tee "$OUT/verdict" | tail -${TAILN:-25}
grep -q 'BALLS RESULT PASS' "$OUT/verdict"
