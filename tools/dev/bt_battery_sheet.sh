#!/usr/bin/env bash
# The networking pill's battery stripe in every state (tools/dev/qml/bt_battery_sheet.qml), in each mode and scale, composed
# into one labelled sheet: sheet.png (rows: states; columns: mode x scale; each cell at 1x and magnified 4x beside it).
#
#   tools/dev/bt_battery_sheet.sh [outdir]      (from the config it re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#   SCALES   default "1 1.25" (QT_SCALE_FACTOR: a sheet's stand-in for the shell's frame scale)   MODES  default "light dark"
#
# The last line is BT_BATTERY_SHEET RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/bt_battery_sheet}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/bt_battery_sheet.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
SCALES="${SCALES:-1 1.25}"
MODES="${MODES:-light dark}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/btbatsheet.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
for md in $MODES; do
    for sc in $SCALES; do
        o="$OUT/cells_${md}_${sc}"
        rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_$md/theme" "$WORK/state" "$WORK/cache"
        printf '{"theme":"eva","mode":"%s"}\n' "$md" > "$WORK/cfg_$md/theme/state.json"
        log="$o/run.log"
        XDG_CONFIG_HOME="$WORK/cfg_$md" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" OUT_DIR="$o" QT_SCALE_FACTOR="$sc" \
            timeout -k 5 120 quickshell -n -p "$HERE/tools/dev/qml/bt_battery_sheet.qml" > "$log" 2>&1
        rl_result BT_BATTERY_SHEET "$log" "BT_BATTERY_SHEET RESULT .*" | sed "s/^/$md $sc: /" || fails=$((fails + 1))
        rl_clean "$log" | grep -E "WARN|ERROR" | rl_platform_noise | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|WAYLAND_DISPLAY\|window masks" | sort -u | head -6 | sed 's/^/    /'
    done
done
python3 - "$OUT" "$MODES" "$SCALES" <<'PY' || fails=$((fails + 1))
import os, sys, subprocess
from PIL import Image, ImageDraw, ImageFont
out, modes, scales = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
names = ["none", "nobattery", "p90", "p40", "p15", "p5", "two", "buds", "charging"]
try:
    font = ImageFont.truetype(subprocess.run(["fc-match", "-f", "%{file}", "Inter"], capture_output=True, text=True).stdout, 12)
except Exception:
    font = ImageFont.load_default()
Z = 4
cols = [(m, s) for m in modes for s in scales]
cw, ch, L, H = 80 * 2 + 80 * Z // 1 // 2 + 20, 40 * Z + 8, 96, 24
cw = 100 + 8 + 66 * Z + 16
sheet = Image.new("RGB", (L + cw * len(cols), H + ch * len(names)), (255, 255, 255))
d = ImageDraw.Draw(sheet)
for ci, (m, s) in enumerate(cols):
    d.text((L + ci * cw + 4, 4), f"{m} @{s}x", fill=(0, 0, 0), font=font)
for ri, n in enumerate(names):
    d.text((4, H + ri * ch + ch // 2 - 6), n, fill=(0, 0, 0), font=font)
    for ci, (m, s) in enumerate(cols):
        p = os.path.join(out, f"cells_{m}_{s}", n + ".png")
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGB")
        x = L + ci * cw
        sheet.paste(im, (x, H + ri * ch))
        # magnify the pill's middle (nearest neighbour)
        w, h = im.size
        crop = im.crop((w // 2 - 26 * (w // 80), 0, w // 2 + 26 * (w // 80), h)) if False else im.crop((int(w * 0.17), int(h * 0.1), int(w * 0.83), int(h * 0.9)))
        crop = crop.resize((crop.width * Z, crop.height * Z), Image.NEAREST)
        sheet.paste(crop, (x + w + 8, H + ri * ch))
sheet.save(os.path.join(out, "sheet.png"))
PY
[ "$fails" = 0 ] && echo "BT_BATTERY_SHEET RESULT PASS" || echo "BT_BATTERY_SHEET RESULT FAIL"
exit "$fails"
