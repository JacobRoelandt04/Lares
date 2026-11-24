#!/usr/bin/env bash
# bridge_sheet.sh -- the bridge popup's states as PNGs and one contact sheet to look at (not a gate: it judges nothing).
#
#   tools/dev/bridge_sheet.sh [outdir]          every state below, light and dark, offscreen, in a sandbox copy
#   STATES="home mirror back"  MODES=light  SCALE=1  tools/dev/bridge_sheet.sh
#
# A state is a row of the table: a name, then the mockup's own env (mockups/bridge.qml: BRIDGE_SCENARIO, BRIDGE_PAGE,
# BRIDGE_FACE, BRIDGE_POSE, BRIDGE_MENU). Each picture is the mockup's stage alone (SHEET_GRAB), the mock service, no process.
# The sheet is <outdir>/sheet-<mode>.png with a label per cell; for a before / after, run it on both trees and put the
# sheets side by side.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BRS_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-sheet}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen BRS_INNER=1 BRS_OUTARG="${1:-}" bash tools/dev/bridge_sheet.sh "$@"
fi
OUT="${BRS_OUTARG:-${1:-${SCRATCH:-/tmp}/bridge-sheet}}"
mkdir -p "$OUT"
TABLE='
home       BRIDGE_SCENARIO=wired
wifi       BRIDGE_SCENARIO=wifi
transfer   BRIDGE_SCENARIO=transfer
mirror     BRIDGE_SCENARIO=wired BRIDGE_PAGE=mirror
mirroring  BRIDGE_SCENARIO=mirroring BRIDGE_PAGE=mirror
files      BRIDGE_SCENARIO=mounted BRIDGE_PAGE=files
error      BRIDGE_SCENARIO=error
asleep     BRIDGE_SCENARIO=asleep
none       BRIDGE_SCENARIO=none
pair       BRIDGE_SCENARIO=pairing BRIDGE_PAGE=pair
details    BRIDGE_SCENARIO=wired BRIDGE_PAGE=device
menu       BRIDGE_SCENARIO=wired BRIDGE_MENU=1
turning    BRIDGE_SCENARIO=wired BRIDGE_POSE=0.14
side       BRIDGE_SCENARIO=wired BRIDGE_POSE=0.27
back       BRIDGE_SCENARIO=wired BRIDGE_FACE=back
top        BRIDGE_SCENARIO=wired BRIDGE_POSE=0.5 BRIDGE_TILT=-62
bottom     BRIDGE_SCENARIO=wired BRIDGE_POSE=0.5 BRIDGE_TILT=62
'
. tools/dev/result_lib.sh
want="${STATES:-}"
for mode in ${MODES:-light dark}; do
    cfg="$OUT/cfg-$mode"
    mkdir -p "$cfg/theme" "$OUT/state" "$OUT/cache"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$cfg/theme/state.json"
    names=""
    while read -r name envs; do
        [ -n "$name" ] || continue
        if [ -n "$want" ]; then case " $want " in *" $name "*) ;; *) continue ;; esac; fi
        png="$OUT/$name-$mode.png"
        rm -f "$png"
        # shellcheck disable=SC2086
        env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_DISTANCEFIELD_ANTIALIASING=gray XDG_CONFIG_HOME="$cfg" \
            XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" ZOOM="${SCALE:-1}" SHEET_GRAB="$png" GRAB_MS="${GRAB_MS:-2600}" $envs \
            timeout 60 quickshell -n -p mockups/bridge.qml > "$OUT/$name-$mode.log" 2>&1 &
        pid=$!
        wait "$pid"
        if [ -f "$png" ]; then names="$names $name"; else echo "no picture: $name ($mode): $OUT/$name-$mode.log"; fi
        rl_platform_noise < "$OUT/$name-$mode.log" | grep -a -E "WARN|ERROR" | grep -a -v -E "a line was refused" | head -3
    done <<< "$TABLE"
    python3 -B - "$OUT" "$mode" $names <<'PY'
import sys
from PIL import Image, ImageDraw
out, mode, names = sys.argv[1], sys.argv[2], sys.argv[3:]
ground = (234, 237, 245) if mode == "light" else (30, 32, 38)
def flat(path):                 # the stage's rounded corners are transparent in the grab: lay it on the sheet's ground
    im = Image.open(path).convert("RGBA")
    bg = Image.new("RGBA", im.size, ground + (255,))
    return Image.alpha_composite(bg, im).convert("RGB")
ims = [(n, flat("%s/%s-%s.png" % (out, n, mode))) for n in names]
if ims:
    w = max(i.width for _, i in ims); h = max(i.height for _, i in ims); cols = min(7, len(ims)); rows = (len(ims) + cols - 1) // cols
    ink = (60, 60, 64) if mode == "light" else (215, 218, 226)
    sheet = Image.new("RGB", (cols * (w + 12) + 12, rows * (h + 34) + 12), ground)
    d = ImageDraw.Draw(sheet)
    for k, (n, im) in enumerate(ims):
        x = 12 + (k % cols) * (w + 12); y = 12 + (k // cols) * (h + 34)
        d.text((x + 2, y), n, fill=ink)
        sheet.paste(im, (x, y + 20))
    sheet.save("%s/sheet-%s.png" % (out, mode))
    print("SHEET %s/sheet-%s.png  %d cells  %dx%d" % (out, mode, len(ims), sheet.width, sheet.height))
PY
done
