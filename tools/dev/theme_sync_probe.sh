#!/usr/bin/env bash
# Is the light<->dark switch finished, everywhere, when the fade says it is?
#
#   tools/dev/theme_sync_probe.sh [outdir]
#
# Runs tools/dev/qml/theme_sync_probe.qml, which lays out one of every themed thing the
# system-update popup is built from, toggles the mode and grabs three frames:
# `mid` (fadeMs/2), `settle` (fadeMs + SLACK_MS, default 80) and `final`
# (fadeMs + 1400). Then:
#
#   settle vs final   MUST be identical, outside the mask. Any difference is
#                     a colour still moving after the fade -- something
#                     chasing the theme on a clock of its own.
#   mid vs final      must DIFFER, or the probe measured a switch that never
#                     happened and its PASS would mean nothing.
#
# The mask is `final` vs `final2`: whatever still moves 1.6s after the switch
# is animating for its own reasons (the skeleton pulses forever, the rail's
# ball breathes) and cannot be judged here. The masked share of the window is
# reported, so a mask that swallowed everything would be obvious.
#
# On failure it prints the bounding box of the moving pixels and writes
# diff.png (the moving region, boxed) so the culprit can be looked at.
#
# The mode is left as it was found.
set -u
cd "$(dirname "$0")/../.."
OUT="${1:-${SCRATCH:-/tmp}/theme_sync}"
mkdir -p "$OUT"
rm -f "$OUT"/mid.png "$OUT"/settle.png "$OUT"/final.png "$OUT"/final2.png "$OUT"/diff.png

# The probe toggles the theme, which Theme persists to <config>/theme/state.json -- a file the user's running shell
# follows. A config dir of the run's own, seeded light, keeps the toggles here.
# (CLAUDE.md: A TEST THAT LAUNCHES A QUICKSHELL WITHOUT A PRIVATE XDG_CONFIG_HOME FLIPS THE USER'S DESKTOP.)
mkdir -p "$OUT/config/theme"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/config/theme/state.json"
export XDG_CONFIG_HOME="$OUT/config"

# OFFSCREEN, and this matters. Qt renders only while the compositor is
# presenting the window, so a run whose window landed behind whatever the user
# is looking at produces no frames at all: grabToImage starts and never calls
# back, and the animation driver -- which is the render loop -- freezes the
# theme fade too. Measured: with the window occluded, three runs in a row
# produced nothing. Offscreen there is no compositor in the loop, the size is
# the one the probe asks for instead of whatever tiling gives it, and nothing
# appears on the user's screen. The retry is kept for the rest.
for attempt in 1 2 3; do
    rm -f "$OUT"/mid.png "$OUT"/settle.png "$OUT"/final.png "$OUT"/final2.png
    QT_QPA_PLATFORM=offscreen OUT_DIR="$OUT" \
        timeout 40 quickshell -p tools/dev/qml/theme_sync_probe.qml > "$OUT/run.log" 2>&1
    [ -f "$OUT/final2.png" ] && break
    echo "THEME_SYNC attempt $attempt produced no frames; retrying"
done
sed 's/\x1b\[[0-9;]*m//g' "$OUT/run.log" | grep -E "SYNC|WARN|ERROR" \
    | grep -vE "quickshell.tooling|QT_QPA_PLATFORM to .wayland.|does not support setting window masks"


python3 - "$OUT" <<'PY'
import sys, os
try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:
    print("THEME_SYNC SKIP: PIL not installed"); sys.exit(0)

out = sys.argv[1]
need = ["mid", "settle", "final", "final2"]
for n in need:
    if not os.path.exists(f"{out}/{n}.png"):
        print(f"THEME_SYNC FAIL: no {n}.png (see {out}/run.log)"); sys.exit(1)

mid    = Image.open(f"{out}/mid.png").convert("RGB")
settle = Image.open(f"{out}/settle.png").convert("RGB")
final  = Image.open(f"{out}/final.png").convert("RGB")
final2 = Image.open(f"{out}/final2.png").convert("RGB")

def moved(a, b):
    d = ImageChops.difference(a, b)
    return d, d.getbbox(), max(d.getextrema(), key=lambda t: t[1])[1]

_, midbox, midmax = moved(mid, final)
if midbox is None:
    print("THEME_SYNC FAIL: mid == final, the fade never ran -- the probe "
          "would pass on anything"); sys.exit(1)

# Whatever is still moving long after the switch animates for its own
# reasons; it cannot be judged here, so mask it -- grown a little, since an
# animation two frames apart barely moves at its turning points.
# MaxFilter(7): an antialiased edge one pixel outside something that pulses
# still moves by a unit or two, and a 1/255 rounding artefact is not a theme
# laggard. Grown rather than given a tolerance, so a real lag of any size
# anywhere else still fails.
selfmoving = ImageChops.difference(final, final2).convert("L").point(
    lambda v: 255 if v > 0 else 0).filter(ImageFilter.MaxFilter(7))
masked = (sum(1 for p in selfmoving.getdata() if p) * 100.0
          / (final.size[0] * final.size[1]))

d = Image.composite(Image.new("RGB", final.size, (0, 0, 0)),
                    ImageChops.difference(settle, final), selfmoving)
box = d.getbbox()
worst = max(d.getextrema(), key=lambda t: t[1])[1]
if box is None:
    print(f"THEME_SYNC PASS: settled within the fade "
          f"(mid still differed by {midmax}/255, so the switch did run; "
          f"{masked:.1f}% of the window masked as self-animating)")
    sys.exit(0)

# Where, and by how much. Rows of moving pixels, so a laggard can be found by
# its band even before the image is opened.
bands = []
px = d.load()
y = box[1]
while y < box[3]:
    run = 0
    while y < box[3]:
        rowmax = max(max(px[x, y]) for x in range(box[0], box[2], 2))
        if rowmax == 0:
            break
        run += 1
        y += 1
    if run:
        bands.append((y - run, y))
    y += 1

print(f"THEME_SYNC FAIL: {worst}/255 of colour was still moving after the "
      f"fade, in {box} ({masked:.1f}% masked as self-animating)")
for a, b in bands[:12]:
    print(f"    rows {a}-{b}")
shot = final.copy()
dr = ImageDraw.Draw(shot)
for a, b in bands:
    dr.rectangle([box[0] - 2, a - 2, box[2] + 2, b + 2], outline=(255, 0, 0))
shot.save(f"{out}/diff.png")
print(f"    boxed in {out}/diff.png")
sys.exit(1)
PY

# ---------------------------------------------------------------------------
# The static half.
#
# The pixel test above covers the shared components on the board. The popup
# itself cannot be grabbed (grabToImage never calls back with it in the
# subtree), and its own composition -- the status card, the prompt banner, the
# category headers -- is plain Text and Rectangle bound straight to the theme.
# The one way that stops being true is somebody adding a colour animation
# back, so: no file in the popup's dependency closure may contain one.
#
# `Behavior on <anything>Color` and `ColorAnimation` both count. A colour that
# needs to cross-fade drives an eased FRACTION and mixes with Mix.js instead.
python3 - <<'PY'
import os, re, sys

ROOT = os.path.abspath(".")
COMP = "modules/common/components"

# The closure: what each POPUP names, and what those name, within
# modules/common/components. Types are found by their `Name {` usage.
#
# Every drop-in in the shell is a root here, not just the system update's:
# the rule is the theme's, not one module's, and a component that only the
# audio player or the LLM reaches would otherwise never be looked at.
# A module that lives in its own directory (the weather) is a root too; its
# files are found by name across every directory listed here.
DIRS = [COMP, "modules/bar/llm/components", "modules/bar/player/components", "modules/bar/system_update/components",
        "modules/weather", "modules/weather/data",
        "modules/aerial", "modules/aerial/popup", "modules/aerial/scene", "modules/aerial/bar",
        "modules/stocks", "modules/stocks/data",
        "modules/wiki", "modules/wiki/data",
        "modules/windowtray", "modules/windowtray/data",
        "modules/picker",
        "modules/bridge", "modules/bridge/screen", "modules/bridge/body",
        "modules/panorama", "modules/panorama/popup", "modules/panorama/secondary", "modules/panorama/screen", "modules/panorama/bar",
        "modules/presets"]
have = {}
for d in DIRS:
    for f in os.listdir(d):
        if f.endswith(".qml"):
            have.setdefault(f[:-4], f"{d}/{f}")
# The window title + tray has no "...Popup": its drop-ins are the strip, the
# secondary beside it and the title in the bar.
ROOTS = sorted(n for n in have if n.endswith("Popup")) + ["TrayStrip", "TraySide", "WindowTitleButton"]
closure, todo = set(), list(ROOTS)
while todo:
    name = todo.pop()
    if name in closure or name not in have:
        continue
    closure.add(name)
    src = open(have[name]).read()
    todo += [m for m in re.findall(r'\b([A-Z]\w+)\s*\{', src) if m in have]

bad = []
for name in sorted(closure):
    for i, line in enumerate(open(have[name]), 1):
        # Code only: these files EXPLAIN why they no longer animate a colour,
        # and a comment saying so must not read as one.
        if line.lstrip().startswith("//"):
            continue
        if re.search(r'ColorAnimation|Behavior\s+on\s+\w*[Cc]olor\b', line):
            bad.append(f"{have[name]}:{i}: {line.strip()}")

print(f"THEME_SYNC static: {len(closure)} components in the closure of {len(ROOTS)} popups ({', '.join(ROOTS)})")
if bad:
    print("THEME_SYNC FAIL: a colour is animated below the theme --")
    for b in bad:
        print("    " + b)
    print("    Ease a fraction and mix with Mix.js; see docs/contracts/theme.md.")
    sys.exit(1)
print("THEME_SYNC static PASS: no colour animation in any of them")
PY
