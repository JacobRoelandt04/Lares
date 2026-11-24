#!/usr/bin/env bash
# Every aerial detail panel in every state (tools/dev/qml/aerial_panels_sheet.qml), in light and dark, on a contact sheet: sheet_<mode>.png
# (cells in a grid, each labelled). The panels are the real AerialSecondary on AerialMock scenarios, at scale 1 (ZOOM=1 is a mockup-grab
# rule: a stage grab at another zoom is blurred where the engine layers content).
#
#   tools/dev/aerial_panels_sheet.sh [outdir]      (from the config it re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#   MODES   default "light dark"     ONLY   a comma list of cell names
# The last line is AERIAL_PANELS_SHEET RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/aerial_panels_sheet}")"
if [ -e .git ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-p}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ONLY="${ONLY:-}" MODES="${MODES:-}" tools/dev/aerial_panels_sheet.sh "$OUT"
fi
export QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
MODES="${MODES:-light dark}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aerialsheet.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
for md in $MODES; do
    o="$OUT/cells_$md"
    rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_$md/theme" "$WORK/state" "$WORK/cache"
    printf '{"theme":"eva","mode":"%s"}\n' "$md" > "$WORK/cfg_$md/theme/state.json"
    log="$o/run.log"
    env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$WORK/cfg_$md" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" OUT_DIR="$o" ONLY="${ONLY:-}" \
        QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= timeout -k 5 240 quickshell -n -p "$HERE/tools/dev/qml/aerial_panels_sheet.qml" > "$log" 2>&1
    rl_result APS "$log" "APS RESULT .*" | sed "s/^/$md: /" || fails=$((fails + 1))
    rl_clean "$log" | grep -E "WARN|ERROR|Unable to assign|Binding loop|TypeError|ReferenceError|non-existent" | rl_platform_noise | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|WAYLAND_DISPLAY\|window masks" | sort -u | head -12 | sed 's/^/    /'
done
python3 - "$OUT" "$MODES" <<'PY' || fails=$((fails + 1))
import os, sys, subprocess
from PIL import Image, ImageDraw, ImageFont
out, modes = sys.argv[1], sys.argv[2].split()
try:
    font = ImageFont.truetype(subprocess.run(["fc-match", "-f", "%{file}", "Inter"], capture_output=True, text=True).stdout, 13)
except Exception:
    font = ImageFont.load_default()
for md in modes:
    d = os.path.join(out, "cells_" + md)
    names = sorted(f[:-4] for f in os.listdir(d) if f.endswith(".png"))
    if not names:
        continue
    ims = [(n, Image.open(os.path.join(d, n + ".png")).convert("RGB")) for n in names]
    # columns of cells, packed top to bottom by height
    colw = 380
    cols, colh = [[]], [0]
    maxh = 1500
    for n, im in ims:
        h = im.height + 30
        if colh[-1] + h > maxh and cols[-1]:
            cols.append([]); colh.append(0)
        cols[-1].append((n, im)); colh[-1] += h
    sheet = Image.new("RGB", (colw * len(cols) + 20, max(colh) + 20), (200, 200, 205) if md == "light" else (30, 30, 34))
    dr = ImageDraw.Draw(sheet)
    ink = (20, 20, 20) if md == "light" else (230, 230, 230)
    for ci, col in enumerate(cols):
        y = 10
        for n, im in col:
            dr.text((10 + ci * colw, y), n, fill=ink, font=font)
            sheet.paste(im, (10 + ci * colw, y + 18))
            y += im.height + 30
    sheet.save(os.path.join(out, "sheet_%s.png" % md))
    print("sheet", os.path.join(out, "sheet_%s.png" % md), sheet.size)
PY
[ "$fails" = 0 ] && echo "AERIAL_PANELS_SHEET RESULT PASS" || echo "AERIAL_PANELS_SHEET RESULT FAIL"
exit "$fails"
