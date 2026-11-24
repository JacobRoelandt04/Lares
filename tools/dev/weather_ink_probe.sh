#!/usr/bin/env bash
# The weather glyph's two sets, proven by pixels (tools/dev/qml/weather_ink_sheet.qml draws them; this judges).
#
#   tools/dev/weather_ink_probe.sh [outdir]          (from the config it re-runs itself in a sandbox copy)
#   ARM=<name> tools/dev/weather_ink_probe.sh        one fault in the sandbox copy; the run must FAIL on the arm's needle:
#     empty      one composition of the ink set has no parts          -> "no ink"
#     nomotion   the flourish poses every part at beat 0              -> "strip: no motion"
#     jump       the flourish starts a fifth of a beat in             -> "strip: the first beat is not the icon at rest"
#     spill      the fog's rows slide six units                        -> "strip: ink leaves the glyph's box"
#     nopick     an hour picked does not play its glyph                -> "popup: WXFL hourly FAIL"
#     cutshort   a new pick ends the flourishes still running          -> "popup: WXFL hourly_both FAIL"
#
#   THEME / MODE     default eva / light
#
# Checks, on the ink set: the generated outlines are current (weather_ink_parts.py --check); every glyph of every condition at
# every size draws ink inside its cell; a glyph the sheet marks as accented has coloured pixels and one it does not has none;
# switching the set live changes the picture, and switching back restores it to the pixel. Leaves <outdir>/{first,other,back}.png
# (the ink set, the carved set, the ink set again).
# THE FLOURISHES (tools/dev/qml/weather_ink_strip.qml: every icon posed at 16 beats of its flourish, held): the first beat is the
# icon at rest to the pixel and so is the last, something moves in between, and no frame puts ink outside the glyph's
# box. Leaves <outdir>/strip.png.
# IN THE POPUP (tools/dev/qml/weather_flourish_probe.qml: the real WeatherPopup and its detail, a QtTest pointer): the hero's glyph
# plays under the pointer, a column / row / tile plays its glyph under the pointer or when clicked (once per entry), a second pick
# plays beside the first and never cuts it short, a selected day and every slot of a sweep play in the detail, and the carved set
# plays nothing. Last line: WEATHER_INK RESULT PASS|FAIL.
{
set -u
cd "$(dirname "$0")/.."/..
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/weather_ink}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen ARM="${ARM:-}" THEME="${THEME:-}" MODE="${MODE:-}" OTHER="${OTHER:-}" \
        bash tools/dev/weather_ink_probe.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
THEME="${THEME:-eva}"; MODE="${MODE:-light}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/wxink.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
LOG="$OUT/run.log"

arm_patch() {    # <file> <exact old text> <new text>: once, or the arm says its anchor is gone
    python3 - "$1" "$2" "$3" << 'PY' || { echo "WEATHER_INK ARM anchor gone"; echo "WEATHER_INK RESULT FAIL (arm anchor gone)"; exit 3; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
}
POSE=modules/common/components/WeatherInkPose.js
case "${ARM:-}" in
    ""|empty) ;;
    nomotion) arm_patch "$POSE" '        const d = _part(e, key, x, l);' '        const d = _part(e, key, 0, l);' ;;
    jump) arm_patch "$POSE" '        const d = _part(e, key, x, l);' '        const d = _part(e, key, x + 0.2, l);' ;;
    spill) arm_patch "$POSE" 'fogSlide: 1.3,' 'fogSlide: 6,' ;;
    nopick) arm_patch modules/weather/WeatherHourlyStrip.qml '                                strip.glyphFlourish.play(cell.index, ' '                                strip.glyphFlourish.play(cell.index, 0 * ' ;;
    cutshort) arm_patch modules/common/components/WeatherGlyphFlourish.qml '                next[k] = r;' '                continue;' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
if [ "${ARM:-}" = empty ]; then
    # the fault: the plain cloud's composition has no parts (in this copy only)
    python3 - << 'PY' || { echo "WEATHER_INK ARM anchor gone"; echo "WEATHER_INK RESULT FAIL (arm anchor gone)"; exit 3; }
import re, sys
p = "modules/common/components/WeatherInkParts.js"
s = open(p).read()
n = re.subn(r'    "cloudy": \[.*\],\n', '    "cloudy": [],\n', s)
if n[1] != 1:
    sys.exit(1)
open(p, "w").write(n[0])
PY
else
    python3 tools/dev/weather_ink_parts.py --check || { echo "WEATHER_INK RESULT FAIL (stale outlines)"; exit 1; }
fi

mkdir -p "$WORK/cfg/theme" "$WORK/state"
printf '{"theme":"%s","mode":"%s"}\n' "$THEME" "$MODE" > "$WORK/cfg/theme/state.json"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" OUT_DIR="$OUT" SET=ink OTHER="${OTHER:-}" \
    timeout -k 5 120 quickshell -p "$(pwd)/tools/dev/qml/weather_ink_sheet.qml" > "$LOG" 2>&1 &
QS=$!
wait "$QS"
if ! rl_has "$LOG" 'INK_SHEET RESULT'; then
    cp "$LOG" "${SCRATCH:-/tmp}/weather_ink_noload.log" 2> /dev/null
    rl_noresult WEATHER_INK "$LOG"
    exit 1
fi
SLOG="$OUT/strip.log"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" OUT_DIR="$OUT" \
    timeout -k 5 120 quickshell -p "$(pwd)/tools/dev/qml/weather_ink_strip.qml" > "$SLOG" 2>&1 &
QS=$!
wait "$QS"
if ! rl_has "$SLOG" 'INK_STRIP RESULT'; then
    cp "$SLOG" "${SCRATCH:-/tmp}/weather_ink_noload.log" 2> /dev/null
    rl_noresult WEATHER_INK "$SLOG"
    exit 1
fi
rl_clean "$SLOG" > "$OUT/strip.clean.log"
PLOG="$OUT/popup.log"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" PROBE=1 \
    timeout -k 5 150 quickshell -p "$(pwd)/tools/dev/qml/weather_flourish_probe.qml" > "$PLOG" 2>&1 &
QS=$!
wait "$QS"
if ! rl_has "$PLOG" 'WXFL RESULT'; then
    cp "$PLOG" "${SCRATCH:-/tmp}/weather_ink_noload.log" 2> /dev/null
    rl_noresult WEATHER_INK "$PLOG"
    exit 1
fi
rl_clean "$PLOG" | grep -a -o "WXFL .*" > "$OUT/popup.clean.log"
cat "$LOG" "$SLOG" "$PLOG" > "$OUT/both.log"
LOG="$OUT/both.log"
rl_clean "$LOG" | grep -E "WARN|ERROR" | rl_platform_noise \
    | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" \
    | sort -u > "$OUT/warnings.txt"

rl_clean "$LOG" > "$OUT/run.clean.log"
python3 - "$OUT" << 'PY'
import sys
from PIL import Image, ImageChops
out = sys.argv[1]
cells = []
for line in open(f"{out}/run.clean.log", errors="replace"):
    if "INK_SHEET cell " in line:
        n, acc, x, y, w, h = line.split("INK_SHEET cell ", 1)[1].split()
        cells.append((n, int(acc), int(float(x)), int(float(y)), int(float(w)), int(float(h))))
fails = []
def rgb(name):
    im = Image.open(f"{out}/{name}.png").convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
    return Image.alpha_composite(bg, im).convert("RGB")
first, other, back = rgb("first"), rgb("other"), rgb("back")
ground = first.getpixel((2, 2))
if len(cells) < 200:
    fails.append("cells: only %d reported" % len(cells))
for n, acc, x, y, w, h in cells:
    px = [c for _, c in first.crop((x, y, x + w, y + h)).getcolors(w * h)for _ in range(_)]
    ink = [p for p in px if max(abs(p[i] - ground[i]) for i in range(3)) > 40]
    # coloured: well away from grey (the ink is a grey; an accent is a hue)
    hue = [p for p in ink if max(p) - min(p) > 60]
    if len(ink) < 0.025 * w * w:
        fails.append("no ink: %s (%d px)" % (n, len(ink)))
    elif acc and len(hue) < 0.012 * w * w:
        fails.append("no accent: %s (%d coloured px)" % (n, len(hue)))
    elif not acc and len(hue) > 0:
        fails.append("stray colour: %s (%d coloured px)" % (n, len(hue)))
def moved(a, b):
    d = ImageChops.difference(a, b)
    if not d.getbbox():
        return 0
    r, g, bl = d.split()
    return d.size[0] * d.size[1] - ImageChops.lighter(ImageChops.lighter(r, g), bl).histogram()[0]
if moved(first, other) < 5000:
    fails.append("toggle: the other set draws the same picture")
m = moved(first, back)
if m:
    fails.append("toggle: back to the first set moved %d px" % m)
# ---- the flourishes: strip.png, one row per icon: the icon at rest, then `frames` poses from the first beat to the last ----
slot = pad = size = frames = 0
srows = []
for line in open(f"{out}/strip.clean.log", errors="replace"):
    if "INK_STRIP geometry " in line:
        slot, pad, size, frames = [int(v) for v in line.split("INK_STRIP geometry ", 1)[1].split()]
    elif "INK_STRIP row " in line:
        n, i, beats = line.split("INK_STRIP row ", 1)[1].split()
        srows.append((n, int(i), float(beats)))
strip = rgb("strip")
sground = strip.getpixel((1, 1))
def far(a, b, level):
    """pixels of two same-size images further apart than `level` on any channel"""
    r, g, bl = ImageChops.difference(a, b).split()
    h = ImageChops.lighter(ImageChops.lighter(r, g), bl).histogram()
    return sum(h[level + 1:])
if len(srows) < 30 or frames < 8:
    fails.append("strip: only %d rows of %d frames" % (len(srows), frames))
flat = Image.new("RGB", (slot, slot), sground)
for n, i, beats in srows:
    poses = [strip.crop((c * slot, i * slot, (c + 1) * slot, (i + 1) * slot)) for c in range(frames + 1)]
    rest = poses[0]
    if beats <= 0:
        fails.append("strip: %s has no flourish" % n)
        continue
    d0 = far(rest, poses[1], 0)
    if d0:
        fails.append("strip: the first beat is not the icon at rest: %s (%d px)" % (n, d0))
    # (one level allowed: the last pose stands a thousand px from the rest cell, and a TURNED shape -- the wind arrow -- rasters
    # its edge a level apart that far along the window: 22 px by 1/255, measured; every icon that is not turned is exact)
    d1 = far(rest, poses[frames], 1)
    if d1:
        fails.append("strip: the last beat is not the icon at rest: %s (%d px)" % (n, d1))
    moved_most = max(far(rest, c, 40) for c in poses[2:frames])
    if moved_most < 10:
        fails.append("strip: no motion: %s (%d px at most)" % (n, moved_most))
    for c, cell in enumerate(poses):
        # the band around the glyph's box must stay the ground
        hole = cell.copy()
        hole.paste(flat.crop((0, 0, size, size)), (pad, pad))
        spill = far(hole, flat, 24)
        if spill:
            fails.append("strip: ink leaves the glyph's box: %s frame %d (%d px)" % (n, c, spill))
            break
print("WEATHER_INK strip rows %d frames %d" % (len(srows), frames))
# ---- the popup: the probe's own checks ----
plines = [l.strip() for l in open(f"{out}/popup.clean.log", errors="replace")]
for l in plines:
    if " FAIL" in l and "RESULT" not in l:
        fails.append("popup: " + l)
pres = [l for l in plines if l.startswith("WXFL RESULT")]
if not pres or "PASS" not in pres[-1]:
    fails.append("popup: " + (pres[-1] if pres else "no result"))
print("WEATHER_INK popup " + (pres[-1] if pres else "no result"))
warn = [l for l in open(f"{out}/warnings.txt") if l.strip()]
if warn:
    fails.append("warnings: %d (%s)" % (len(warn), warn[0].strip()[:140]))
for f in fails[:12]:
    print("WEATHER_INK FAIL " + f)
print("WEATHER_INK cells %d" % len(cells))
print("WEATHER_INK RESULT " + ("PASS" if not fails else "FAIL (%d)" % len(fails)))
sys.exit(1 if fails else 0)
PY
exit $?
}
