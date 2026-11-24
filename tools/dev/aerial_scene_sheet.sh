#!/usr/bin/env bash
# aerial_scene_sheet.sh -- a contact sheet of aerial's board: every scenario in both families and both modes (mockups/aerial.qml, the stage alone at ZOOM=1), one label a cell.
#
#   tools/dev/aerial_scene_sheet.sh [outdir]          SCENARIOS="home airplane ..."  MODES="light dark"  FAMILIES="material blueprint"  GRAB_MS=3500
#   writes <outdir>/<scenario>_<family>_<mode>.png and <outdir>/sheet_<mode>.png (rows: scenarios, columns: families)
# OFFSCREEN ONLY (sandbox copy, platform forced on the launch, private config / cache / state homes). Ends in AERIAL_SCENE_SHEET RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${ASS_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-sheet}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen ASS_INNER=1 ASS_OUTARG="${1:-}" bash tools/dev/aerial_scene_sheet.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_SCENE_SHEET
OUT="${ASS_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-sheet}}"
mkdir -p "$OUT"
SCEN="${SCENARIOS:-home crowd airplane hotspot vpn portal pairing earbuds nowifi errors}"
n=0; bad=0
for mode in ${MODES:-light dark}; do
    for fam in ${FAMILIES:-material blueprint}; do
        for sc in $SCEN; do
            cfg="$OUT/cfg-$mode"; mkdir -p "$cfg/theme" "$OUT/cache" "$OUT/state"
            printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
            png="$OUT/${sc}_${fam}_${mode}.png"; log="$OUT/${sc}_${fam}_${mode}.log"
            rm -f "$png"
            env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
                SCENARIO="$sc" FAMILY="$fam" MODE="$mode" ZOOM=1 SHEET_GRAB="$png" GRAB_MS="${GRAB_MS:-3500}" QML_DISABLE_DISTANCEFIELD=1 \
                timeout 90 quickshell -n -p mockups/aerial.qml > "$log" 2>&1
            n=$((n + 1))
            [ -f "$png" ] || { echo "  no picture: $sc $fam $mode ($log)"; bad=$((bad + 1)); }
        done
    done
done
# the sheets: rows = scenarios, columns = families, one per mode, each cell labelled
python3 -B - "$OUT" "$SCEN" "${MODES:-light dark}" "${FAMILIES:-material blueprint}" <<'PY'
import os, sys
from PIL import Image, ImageDraw
out, scen, modes, fams = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4].split()
for mode in modes:
    cells = [[Image.open(os.path.join(out, "%s_%s_%s.png" % (s, f, mode))).convert("RGB") if os.path.exists(os.path.join(out, "%s_%s_%s.png" % (s, f, mode))) else None for f in fams] for s in scen]
    sample = next((c for r in cells for c in r if c), None)
    if not sample:
        continue
    w, h = sample.size
    sheet = Image.new("RGB", (w * len(fams), (h + 18) * len(scen)), (30, 30, 34))
    d = ImageDraw.Draw(sheet)
    for i, s in enumerate(scen):
        for j, f in enumerate(fams):
            x, y = j * w, i * (h + 18)
            d.text((x + 6, y + 3), "%s / %s / %s" % (s, f, mode), fill=(230, 230, 230))
            if cells[i][j]:
                sheet.paste(cells[i][j], (x, y + 18))
    sheet.save(os.path.join(out, "sheet_%s.png" % mode))
    print("  sheet_%s.png  %dx%d" % (mode, sheet.size[0], sheet.size[1]))
PY
if [ "$bad" = 0 ]; then echo "$NAME RESULT PASS ($n pictures in $OUT)"; exit 0; fi
echo "$NAME RESULT FAIL ($bad of $n pictures missing)"; exit 1
