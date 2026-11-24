#!/usr/bin/env bash
# aerial_round_sheet.sh -- ROUND 3's BEFORE / AFTER sheet: the same scenarios on the tree the user tested (161893d5, the end of round 2) and on this one, both families, light and dark.
#   tools/dev/aerial_round_sheet.sh <outdir> [<before-rev>]       STATES="home crowd earbuds vpn airplane hotspot"  FAMILIES="0 1"  MODES="light dark"
#   BEFORE = <before-rev> (default 161893d5) extracted with `git archive` into <outdir>/tree-before and rendered by ITS OWN tools/dev/qml/aerial_round_sheet.qml (the harness that tree
#            shipped: `STATE=home`; only its scenario line is changed, in the extracted copy, to read the scenario from the SCEN env, so vpn / airplane / hotspot can be asked of it).
#   AFTER  = this tree, through tools/dev/qml/aerial_r3_cloud.qml (the round's look harness: SCEN FAMILY SCALE STATE=rest).
# Writes <outdir>/{before,after}/<state>_<family>_<mode>.png (as rendered) and compare_<mode>.png: one row a state, the columns before | after for family 0, then family 1, a label
# a cell. Both pictures are composited on the theme's surface colour (a grab over nothing lies about translucent pixels), cropped to the popup's own width and padded to one height.
# OFFSCREEN ONLY (a sandbox copy runs the quickshells; platform forced on the launch, private config / cache / state homes); ends in AERIAL_ROUND_SHEET RESULT PASS|FAIL.
# Distance-field text is off (two runs of one tree differ by a glyph level otherwise); the old tree is a whole checkout, so it brings its own modules and shaders.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
OUT=${1:?outdir}; REV=${2:-161893d5}
STATES=${STATES:-home crowd earbuds vpn airplane hotspot}
mkdir -p "$OUT/before" "$OUT/after" "$OUT/cache" "$OUT/state"
if [ -e .git ] && [ -z "${ARS_INNER:-}" ]; then
    # the outer half (it has the repository): the old tree is extracted here, then this tree's own copy runs the quickshells
    rm -rf "$OUT/tree-before"; mkdir -p "$OUT/tree-before"
    git archive "$REV" | tar -x -C "$OUT/tree-before"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-round}" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARS_INNER=1 STATES="$STATES" MODES="${MODES:-}" FAMILIES="${FAMILIES:-}" \
        bash tools/dev/aerial_round_sheet.sh "$@"
fi
# the old harness reads its scenario from STATE (home / earbuds, else crowd): the extracted copy reads SCEN first
OLDH="$OUT/tree-before/tools/dev/qml/aerial_round_sheet.qml"
python3 -B - "$OLDH" <<'PY' || { echo "AERIAL_ROUND_SHEET RESULT FAIL (the old harness's scenario line is not where it was)"; exit 1; }
import sys
p = sys.argv[1]
s = open(p).read()
a = 'scenario: win.st === "earbuds" ? "earbuds" : (win.st === "home" ? "home" : "crowd")'
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, 'scenario: Quickshell.env("SCEN") || (win.st === "earbuds" ? "earbuds" : (win.st === "home" ? "home" : "crowd"))'))
PY
bad=0
for mode in ${MODES:-light dark}; do
    cfg="$OUT/cfg-$mode"; mkdir -p "$cfg/theme"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
    for fam in ${FAMILIES:-0 1}; do
        for st in $STATES; do
            # before: the tree's own harness at rest (STATE=home) on the scenario
            png="$OUT/before/${st}_${fam}_${mode}.png"; rm -f "$png"
            ( cd "$OUT/tree-before" && env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
                STATE=home SCEN="$st" FAMILY="$fam" PNG="$png" QML_DISABLE_DISTANCEFIELD=1 timeout 90 quickshell -n -p tools/dev/qml/aerial_round_sheet.qml > "$OUT/before/${st}_${fam}_${mode}.log" 2>&1 )
            [ -s "$png" ] || { echo "no picture: $png"; bad=1; }
            # after: this tree
            png="$OUT/after/${st}_${fam}_${mode}.png"; rm -f "$png"
            env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
                SCEN="$st" FAMILY="$fam" SCALE=1 STATE=rest PNG="$png" QML_DISABLE_DISTANCEFIELD=1 timeout 90 quickshell -n -p tools/dev/qml/aerial_r3_cloud.qml > "$OUT/after/${st}_${fam}_${mode}.log" 2>&1
            [ -s "$png" ] || { echo "no picture: $png"; bad=1; }
        done
    done
    python3 -B - "$OUT" "$mode" "${FAMILIES:-0 1}" "$STATES" "$ROOT/themes/eva.json" <<'PY' || bad=1
import json, os, sys
from PIL import Image, ImageDraw
out, mode, fams, states, theme = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4].split(), sys.argv[5]
surf = json.load(open(theme))[mode]["surface"].lstrip("#")
ground = tuple(int(surf[i:i + 2], 16) for i in (0, 2, 4))
W = 764                                                    # the popup's own width (the old harness's window is wider: its panel's room)
def load(t, s, f):
    p = os.path.join(out, t, "%s_%s_%s.png" % (s, f, mode))
    if not os.path.exists(p):
        return None
    im = Image.open(p).convert("RGBA")
    base = Image.new("RGBA", im.size, ground + (255,))
    return Image.alpha_composite(base, im).convert("RGB").crop((0, 0, min(W, im.width), im.height))
cols = [(t, f) for f in fams for t in ("before", "after")]
imgs = [[load(t, s, f) for (t, f) in cols] for s in states]
H = max(i.height for r in imgs for i in r if i)
cell = [W, H + 16]
sheet = Image.new("RGB", (cell[0] * len(cols), cell[1] * len(states)), ground)
d = ImageDraw.Draw(sheet)
ink = (40, 40, 44) if mode == "light" else (225, 225, 230)
for i, r in enumerate(imgs):
    for j, im in enumerate(r):
        d.text((j * cell[0] + 4, i * cell[1] + 2), "%s | %s | family %s | %s" % (states[i], cols[j][0], cols[j][1], mode), fill=ink)
        if im:
            sheet.paste(im, (j * cell[0], i * cell[1] + 16))
        else:
            d.text((j * cell[0] + 40, i * cell[1] + 60), "no picture", fill=(200, 0, 0))
sheet.save(os.path.join(out, "compare_%s.png" % mode))
print("  compare_%s.png %dx%d (%d rows, %d columns)" % (mode, sheet.size[0], sheet.size[1], len(states), len(cols)))
if any(im is None for r in imgs for im in r):
    sys.exit(1)
PY
done
[ $bad = 0 ] && { echo "AERIAL_ROUND_SHEET RESULT PASS (pictures in $OUT)"; exit 0; }
echo "AERIAL_ROUND_SHEET RESULT FAIL"; exit 1
