#!/usr/bin/env bash
# aerial_film.sh -- filmstrips of the popup's life (round 3: the film names the cloud's tags, `popup.cloud`, where it named the dome's): the power-on frame by frame on the held clock, and a drag-dock with the password flow.
#   tools/dev/aerial_film.sh [outdir]      FILMS="poweron dock"  FAMILY=0|1  MODE=light|dark
#   writes <outdir>/<film>_<nn>.png and strip_<film>.png (the frames side by side, a label each). OFFSCREEN ONLY (sandbox copy). Ends in AERIAL_FILM RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${AFM_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-film}"; mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AFM_INNER=1 AFM_OUTARG="${1:-}" bash tools/dev/aerial_film.sh "$@"
fi
NAME=AERIAL_FILM
OUT="${AFM_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-film}}"; mkdir -p "$OUT/cfg/theme" "$OUT/cache" "$OUT/state"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$OUT/cfg/theme/state.json"
bad=0
for film in ${FILMS:-poweron dock}; do
    rm -f "$OUT/${film}"_*.png
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$OUT/cfg" XDG_CACHE_HOME="$OUT/cache" XDG_STATE_HOME="$OUT/state" \
        OUT="$OUT" FILM="$film" FAMILY="${FAMILY:-0}" QML_DISABLE_DISTANCEFIELD=1 timeout 120 quickshell -n -p tools/dev/qml/aerial_film.qml > "$OUT/$film.log" 2>&1
    grep -a "AF " "$OUT/$film.log" | sed 's/^.*AF /AF /' | tail -14
    ls "$OUT/${film}"_*.png > /dev/null 2>&1 || { echo "no frames: $film ($OUT/$film.log)"; bad=1; continue; }
    python3 -B - "$OUT" "$film" <<'PY'
import sys, os, re, glob
from PIL import Image, ImageDraw
out, film = sys.argv[1:3]
fs = sorted(glob.glob(os.path.join(out, film + "_[0-9][0-9].png")))
labels = {}
for l in open(os.path.join(out, film + ".log"), errors="replace"):
    m = re.search(r"AF frame \S*_(\d\d)\.png (.*)", l)
    if m: labels[m.group(1)] = m.group(2).strip()
ims = [Image.open(f).convert("RGBA") for f in fs]
# the popup is the left 790 px of the window; a panel the right 400: crop the poweron to the popup, keep the dock whole
crop = (0, 0, 780, 520) if film == "poweron" else (0, 0, 1200, 520)
cols = 3 if film == "poweron" else 2
cells = [Image.alpha_composite(Image.new("RGBA", im.size, (233, 236, 243, 255)), im).convert("RGB").crop(crop) for im in ims]
w, h = cells[0].size
rows = (len(cells) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols, (h + 16) * rows), (255, 255, 255)); d = ImageDraw.Draw(sheet)
for i, c in enumerate(cells):
    x, y = (i % cols) * w, (i // cols) * (h + 16)
    sheet.paste(c, (x, y + 16)); d.text((x + 4, y + 2), "%02d  %s" % (i, labels.get("%02d" % i, "")), fill=(0, 0, 0))
sheet.save(os.path.join(out, "strip_%s.png" % film)); print("  strip_%s.png %dx%d (%d frames)" % (film, *sheet.size, len(cells)))
PY
done
[ $bad = 0 ] && { echo "$NAME RESULT PASS (frames in $OUT)"; exit 0; }
echo "$NAME RESULT FAIL"; exit 1
