#!/usr/bin/env bash
# aerial_globe_sheet.sh -- the globe at 4 turn angles, tunnel down and up (the exit light), in both families and both modes, and its two poles face-on (round 3: the meridians end on the
# polar circles) -- the probe's own harness, tools/dev/qml/aerial_globe_probe.qml. The tunnel's sheet is gone with the tunnel.
#
#   tools/dev/aerial_globe_sheet.sh [outdir]          MODES="light dark"
#   writes <outdir>/sheet_globe_<mode>.png (rows: family x down / up, columns: the four turns; the globe 3x) and <outdir>/sheet_polar_<mode>.png (both families, north / south pole, 5x)
# OFFSCREEN ONLY (sandbox copy, platform forced on the launch, private homes). Ends in AERIAL_GLOBE_SHEET RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${AGS_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-gsheet}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AGS_INNER=1 AGS_OUTARG="${1:-}" bash tools/dev/aerial_globe_sheet.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_GLOBE_SHEET
OUT="${AGS_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-globe-sheet}}"
mkdir -p "$OUT"
bad=0
for mode in ${MODES:-light dark}; do
    d="$OUT/$mode"; mkdir -p "$d/cfg/theme" "$d/cache" "$d/state"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/cfg/theme/state.json"
    rm -f "$d"/*.png
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$d/cfg" XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" OUT="$d" QML_DISABLE_DISTANCEFIELD=1 \
        timeout 240 quickshell -n -p tools/dev/qml/aerial_globe_probe.qml > "$d/probe.log" 2>&1
    rl_clean "$d/probe.log" | grep -a "EXPECT rect" | sed 's/^.*EXPECT /EXPECT /' > "$d/rects.txt"
    python3 -B - "$d" "$mode" "$OUT" <<'PY' || bad=1
import os, sys
from PIL import Image, ImageDraw
d, mode, out = sys.argv[1:4]
rects = {l.split()[2]: [float(v) for v in l.split()[3:10]] for l in open(os.path.join(d, "rects.txt"))}
if len(rects) != 2:
    sys.exit("no rects in the log")
Z = 3
cells = []
for fam in ("0", "1"):
    cx, cy, rp = rects[fam][:3]
    box = (int(cx - rp - 8), int(cy - rp - 8), int(cx + rp + 9), int(cy + rp + 40))
    for st in ("down", "up"):
        row = []
        for k in range(4):
            p = os.path.join(d, "globe_%s_%d_%s.png" % (fam, k, st))
            row.append(Image.open(p).convert("RGB").crop(box).resize(((box[2] - box[0]) * Z, (box[3] - box[1]) * Z), Image.LANCZOS) if os.path.exists(p) else None)
        cells.append((fam, st, row))
w, h = cells[0][2][0].size
S = Image.new("RGB", (w * 4, (h + 16) * len(cells)), (30, 30, 34))
dr = ImageDraw.Draw(S)
for i, (fam, st, row) in enumerate(cells):
    for k, im in enumerate(row):
        dr.text((k * w + 6, i * (h + 16) + 2), "%s / %s / turn %d / %s" % (("material", "blueprint")[int(fam)], st, k, mode), fill=(230, 230, 230))
        if im:
            S.paste(im, (k * w, i * (h + 16) + 16))
S.save(os.path.join(out, "sheet_globe_%s.png" % mode))
tiles = []
for fam in ("0", "1"):
    for pole in ("n", "s"):
        p = os.path.join(d, "polar_%s%s.png" % (fam, pole))
        cx, cy, rp = rects[fam][:3]
        r = int(rp * 2.1)         # (the grown globe: twice the rest radius)
        tiles.append(Image.open(p).convert("RGB").crop((int(cx - r), int(cy - r), int(cx + r), int(cy + r))).resize((r * 2 * 2, r * 2 * 2), Image.LANCZOS))
tw, th = tiles[0].size
T = Image.new("RGB", (tw * 2, (th) * 2), (30, 30, 34))
for i, t in enumerate(tiles):
    T.paste(t, ((i % 2) * tw, (i // 2) * th))
T.save(os.path.join(out, "sheet_polar_%s.png" % mode))
print("  sheet_globe_%s.png %dx%d, sheet_polar_%s.png" % (mode, S.size[0], S.size[1], mode))
PY
done
if [ "$bad" = 0 ]; then echo "$NAME RESULT PASS (sheets in $OUT)"; exit 0; fi
echo "$NAME RESULT FAIL"; exit 1
