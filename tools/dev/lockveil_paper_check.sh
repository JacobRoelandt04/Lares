#!/usr/bin/env bash
# lockveil_paper_check.sh -- the paper veil's cascade over a long run: every sheet stays inside the one beneath it, at
# least `sheetMargin` from its edge, for two hours of veil time, through a failed attempt, a wake and a burst of keys
# (tools/dev/lockveil_paper_check.py has the check; the motion is the REAL VeilPaper.qml's, read by
# tools/dev/qml/lockveil_render.qml at each sampled time, offscreen).
#
#   tools/dev/lockveil_paper_check.sh [--tree DIR]          SCRATCH=<dir> keeps the sweep there
#   ARM=<arm> tools/dev/lockveil_paper_check.sh             one fault in a COPY of the tree; the run must FAIL
#   ARM=all tools/dev/lockveil_paper_check.sh               every ARM, each must fail its own check
#
# ARMs (each in a copy; the needle is the check line that must fail):
#   oldmotion   the motion before the cascade: every sheet drifts at a speed and angle of its own      margin
#   nobudget    the sway is not held under the budget and 90 px are asked (with the budget they are held at 15.4) margin
#   noclamp     the vertex stage pushes an edge by the whole swell again                                 clamp
#   gradunit    the QML's steepest slope is not the shader's (the budget sized for another field)       grad
# Ends in LOCKVEIL_PAPER_CHECK RESULT PASS|FAIL (ARM=all: LOCKVEIL_PAPER_CHECK ARMS RESULT PASS|FAIL).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TREE="$ROOT"
[ "${1:-}" = --tree ] && TREE="$(realpath "$2")"
SCR="${SCRATCH:-$(mktemp -d /tmp/lrlvp.XXXXXX)}"
mkdir -p "$SCR"

if [ "${ARM:-}" = all ]; then
    rc=0
    declare -A NEED=([oldmotion]="margin" [nobudget]="margin" [noclamp]="clamp" [gradunit]="grad")
    for a in oldmotion nobudget noclamp gradunit; do
        out=$(ARM="$a" SWEEP_TO=1800 SWEEP_EVERY=15 SCRATCH="$SCR/arm-$a" bash "$0" --tree "$TREE" 2>&1)
        if printf '%s\n' "$out" | grep -q "^LOCKVEIL_PAPER_CHECK RESULT FAIL" && printf '%s\n' "$out" | grep -qE "^  ${NEED[$a]} .*FAIL"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -E "^  ${NEED[$a]} .*FAIL" | head -1 | sed 's/^ *//' | cut -c1-110))"
        elif printf '%s\n' "$out" | grep -q "^LOCKVEIL_PAPER_CHECK RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS OWN CHECK (${NEED[$a]}): $(printf '%s\n' "$out" | tail -1 | cut -c1-140)"; rc=1
        else
            echo "ARM $a: STAYED GREEN ($(printf '%s\n' "$out" | tail -1 | cut -c1-140))"; rc=1
        fi
    done
    [ -z "${SCRATCH:-}" ] && rm -rf "$SCR"
    [ "$rc" = 0 ] && echo "LOCKVEIL_PAPER_CHECK ARMS RESULT PASS" || echo "LOCKVEIL_PAPER_CHECK ARMS RESULT FAIL"
    exit "$rc"
fi

# The tree the sweep runs on: the tree itself, or an armed copy of what the render needs.
RUNTREE="$TREE"
if [ -n "${ARM:-}" ]; then
    RUNTREE="$SCR/tree"
    rm -rf "$RUNTREE"; mkdir -p "$RUNTREE/mockups"
    rsync -a "$TREE/modules" "$TREE/themes" "$RUNTREE/" && rsync -a "$TREE/mockups/fixtures" "$RUNTREE/mockups/" || { echo "LOCKVEIL_PAPER_CHECK RESULT FAIL (copy)"; exit 1; }
    arm() {  # file from to: exactly one occurrence, in the copy
        python3 - "$RUNTREE/$1" "$2" "$3" <<'PY' || { echo "ARM ${ARM}: anchor missing"; echo "LOCKVEIL_PAPER_CHECK RESULT FAIL (the ARM's anchor is gone)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    print("anchor found %d times in %s" % (s.count(a), p)); sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
    }
    V=modules/lockscreen/veil/VeilPaper.qml
    case "$ARM" in
        oldmotion) arm "$V" '        o.push([x, y]);
        for (let j = 1; j < 4; j++) {
            const s = root._swayOf(j, t);
            x += s[0];
            y += s[1];' '        o.length = 0;
        for (let j = 0; j < 4; j++) {
            const sp = root.driftSpeed * (1 + 0.55 * (j - 1.5)) * u * t;
            const a = root.driftAngle + 0.15 * (j - 1.5);
            x = Math.cos(a) * sp;
            y = Math.sin(a) * sp;' ;;
        nobudget) arm "$V" '    readonly property real _sway: Math.max(0, Math.min(root.swayReach,
        root._gapBound - root.sheetMargin - 2 * root.swellCap - 1.06 * root.rattleLayer))' '    readonly property real _sway: root.swayReach' \
                  && arm "$V" '    property real swayReach: 14' '    property real swayReach: 90' ;;
        noclamp) arm modules/lockscreen/shaders/veil_paper.vert '    d += gm * cap * sy * si;' '    d += gm * geo.w * H;' ;;
        gradunit) arm "$V" '    readonly property real _gradUnit: 0.0191854' '    readonly property real _gradUnit: 0.0151854' ;;
        *) echo "unknown ARM=$ARM"; exit 2 ;;
    esac
    echo "ARMED $ARM"
fi

# Two hours of veil time every 6 s (SWEEP_TO / SWEEP_EVERY: an ARM's run needs less to fail); a failed attempt at 600 s,
# a wake at 1200 s and sixteen keys from 1800 s, each sampled densely while it plays (the stand-in's field point: where
# the stage's password field is).
cat > "$SCR/sweep.json" <<EOF
{ "veil": "paper",
  "ranges": [ { "from": 0, "to": ${SWEEP_TO:-7200}, "every": ${SWEEP_EVERY:-6} }, { "from": 600, "to": 602, "every": 0.05 },
              { "from": 1200, "to": 1205, "every": 0.25 }, { "from": 1800, "to": 1806, "every": 0.08 } ],
  "pulses": [ { "kind": "fail", "x": 1440, "y": 433, "t": 600 }, { "kind": "wake", "x": 1440, "y": 433, "t": 1200 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1800.0 }, { "kind": "key", "x": 1440, "y": 433, "t": 1800.12 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1800.24 }, { "kind": "key", "x": 1440, "y": 433, "t": 1800.36 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1800.48 }, { "kind": "key", "x": 1440, "y": 433, "t": 1800.6 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1800.72 }, { "kind": "key", "x": 1440, "y": 433, "t": 1800.84 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1800.96 }, { "kind": "key", "x": 1440, "y": 433, "t": 1801.08 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1801.2 }, { "kind": "key", "x": 1440, "y": 433, "t": 1801.32 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1801.44 }, { "kind": "key", "x": 1440, "y": 433, "t": 1801.56 },
              { "kind": "key", "x": 1440, "y": 433, "t": 1801.68 }, { "kind": "key", "x": 1440, "y": 433, "t": 1801.8 } ] }
EOF
r=$(LVR_TMO=300 "$ROOT/tools/dev/lockveil_render.sh" --sweep "$SCR/sweep.json" "$SCR/out" --tree "$RUNTREE")
case "$r" in *PASS*) ;; *) echo "$r"; echo "LOCKVEIL_PAPER_CHECK RESULT FAIL (the sweep did not run: $SCR/out)"; exit 1 ;; esac
python3 -B "$ROOT/tools/dev/lockveil_paper_check.py" "$SCR/out/sweep.jsonl" "$RUNTREE/modules/lockscreen/shaders/veil_paper.vert" --step "${STEP:-3}"
rc=$?
[ -z "${SCRATCH:-}" ] && rm -rf "$SCR"
exit $rc
