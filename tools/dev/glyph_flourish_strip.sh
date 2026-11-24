#!/usr/bin/env bash
# The bar glyphs' flourishes as frame strips, on a held clock (tools/dev/qml/glyph_flourish_strip.qml), in each mode, composed
# into labelled sheets: strip_<theme>_<mode>.png (one row per flourish, the frames at 1x and at ZOOM) and, MODE=story, the system
# update's per-step storyboard story_<theme>_<mode>.png (a proposal: one column per step, the action and the pose held for it).
#
#   tools/dev/glyph_flourish_strip.sh [outdir]      (from the config it re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#
#   THEMES / MODES     default "eva" / "light dark"
#   WHAT               "strip story film" (default) or any of them: film = live clocks, the pointer's entry, motion, rest and
#                      re-entry, a grab per rendered frame (film_<theme>_<mode>_<glyph>.png, the frames in reading order)
#   ZOOM               the magnified rows' factor (default 4, nearest neighbour)
#   SET=pills          the audio and networking pills' strips only; PILLSCALE=4 renders those two pills at four times their
#                      size (a true render: with it take ZOOM=1); FRAMES, ONLY, SPAN as the harness reads them
#   SET=pano           the panorama button's strips only (every count, mirroring or not)
#   THEMESCALE=4       the theme and the panorama button at four times their size, likewise (ONLY=theme or SET=pano, ZOOM=1 with it)
#
# The last line is GLYPH_FLOURISH_STRIP RESULT PASS|FAIL: PASS when every run grabbed every frame and composed its sheet.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/glyph_flourish_strip}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/glyph_flourish_strip.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
export QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
THEMES="${THEMES:-eva}"
MODES="${MODES:-light dark}"
WHAT="${WHAT:-strip story film}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flourishstrip.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fails=0
noresult=""
for th in $THEMES; do
    for md in $MODES; do
        for what in $WHAT; do
            o="$OUT/${what}_${th}_${md}"
            rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_${th}_${md}/theme" "$WORK/state"
            printf '{"theme":"%s","mode":"%s"}\n' "$th" "$md" > "$WORK/cfg_${th}_${md}/theme/state.json"
            log="$o/run.log"
            XDG_CONFIG_HOME="$WORK/cfg_${th}_${md}" XDG_STATE_HOME="$WORK/state" OUT_DIR="$o" MODE="$what" \
                timeout -k 5 150 quickshell -p "$HERE/tools/dev/qml/glyph_flourish_strip.qml" > "$log" 2>&1
            res=$(rl_clean "$log" | grep -o "FLOURISH_STRIP RESULT .*" | tail -1)
            echo "$what $th $md: ${res:-no result ($log)}"
            rl_clean "$log" | grep -E "WARN|ERROR|rror" | rl_platform_noise \
                | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" \
                | sort -u | head -8 | sed 's/^/    /'
            case "$res" in *PASS*) ;; "") fails=$((fails + 1)); [ -n "$noresult" ] || noresult=$log ;; *) fails=$((fails + 1)) ;; esac
        done
    done
done

python3 - "$OUT" "${ZOOM:-4}" <<'PY' || fails=$((fails + 1))
import os, sys, glob, re
from PIL import Image, ImageDraw, ImageFont
out, Z = sys.argv[1], int(sys.argv[2])
import subprocess
try:
    font = ImageFont.truetype(subprocess.run(["fc-match", "-f", "%{file}", "Inter"], capture_output=True, text=True).stdout, 12)
except Exception:
    font = ImageFont.load_default()
LABEL = 96
for d in sorted(glob.glob(os.path.join(out, "*_*_*"))):
    if not os.path.isdir(d):
        continue
    kind = os.path.basename(d).split("_")[0]
    pngs = sorted(glob.glob(os.path.join(d, "*.png")))
    if not pngs:
        continue
    if kind == "film":
        # one sheet per glyph: its frames in reading order, each labelled with its number and the pointer's phase
        films = {}
        for p in pngs:
            m = re.match(r"film_(\w+?)_(\d+)_(\w+)$", os.path.basename(p)[:-4])
            films.setdefault(m.group(1), []).append((int(m.group(2)), m.group(3), p))
        for g, fr in films.items():
            fr.sort()
            cw, ch = Image.open(fr[0][2]).size
            Zf, cols = 3, 12
            rows_n = (len(fr) + cols - 1) // cols
            sheet = Image.new("RGB", (cols * (cw * Zf + 4), 20 + rows_n * (ch * Zf + 16)), (128, 128, 128))
            dr = ImageDraw.Draw(sheet)
            dr.text((4, 4), os.path.basename(d) + " " + g + ": one grab per rendered frame, live clocks (%dx)" % Zf, fill=(255, 255, 255), font=font)
            for i, (n, ph, p) in enumerate(fr):
                x, y = (i % cols) * (cw * Zf + 4), 20 + (i // cols) * (ch * Zf + 16)
                dr.text((x + 2, y), "%d %s" % (n, ph), fill=(255, 255, 255), font=font)
                sheet.paste(Image.open(p).convert("RGB").resize((cw * Zf, ch * Zf), Image.NEAREST), (x, y + 14))
            dst = os.path.join(out, os.path.basename(d) + "_" + g + ".png")
            sheet.save(dst)
            print("sheet", dst)
        continue
    rows = {}
    for p in pngs:
        b = os.path.basename(p)[:-4]
        if kind == "story":
            m = re.match(r"story_(\d+)_(\w+?)_(mid|held)$", b)
            rows.setdefault(m.group(3), []).append((int(m.group(1)), m.group(2), p))
        else:
            name, n = b.rsplit("_", 1)
            rows.setdefault(name, []).append((int(n), "", p))
    for r in rows.values():
        r.sort()
    cw, ch = Image.open(pngs[0]).size
    order = ["mid", "held"] if kind == "story" else ["bell", "bellsleep", "bellburst", "box", "player", "leaf", "scales", "bolt", "feather", "bulb", "bulbidle", "layers", "fire",
        "spkhigh", "spkmed", "spklow", "spkmuted", "spkmutedhigh", "headphones", "headphonesmuted", "headset", "mic", "micmuted",
        "wifi4", "wifi2", "wifi1", "wifisearch", "wifioff", "wifialert", "wired", "wiredoff", "plane", "bluetooth", "btconnected", "btoff", "notes", "sparkle", "theme", "bridge", "bridgedown", "bridgecable", "pano1", "pano2", "pano3", "pano4", "panomirror", "pano2mirror", "pano3mirror", "pano4mirror", "stocks_gain", "stocks_gain_ripple", "stocks_gain_arrow", "stocks_loss", "stocks_closed"]
    order = [o for o in order if o in rows]
    cols = max(len(rows[o]) for o in order)
    W = LABEL + cols * (cw * Z + 4)
    H = 24 + len(order) * (ch + ch * Z + 10) + (16 if kind == "story" else 0)
    sheet = Image.new("RGB", (W, H), (128, 128, 128))
    dr = ImageDraw.Draw(sheet)
    dr.text((4, 4), os.path.basename(d) + ("  (each row: 1x above, %dx below; frames left to right on a held clock)" % Z if kind != "story"
                                           else "  per-step storyboard, a PROPOSAL: the action mid-way, and the pose held for the step"), fill=(255, 255, 255), font=font)
    y = 24
    if kind == "story":
        for i, (_, step, _) in enumerate(rows[order[0]]):
            dr.text((LABEL + i * (cw * Z + 4), y), step, fill=(255, 255, 255), font=font)
        y += 16
    for o in order:
        dr.text((4, y + 4), o, fill=(255, 255, 255), font=font)
        for i, (_, _, p) in enumerate(rows[o]):
            im = Image.open(p).convert("RGB")
            x = LABEL + i * (cw * Z + 4)
            sheet.paste(im, (x, y))
            sheet.paste(im.resize((cw * Z, ch * Z), Image.NEAREST), (x, y + ch + 2))
        y += ch + ch * Z + 10
    dst = os.path.join(out, os.path.basename(d) + ".png")
    sheet.save(dst)
    print("sheet", dst)
PY

if [ -n "$noresult" ]; then
    rl_noresult GLYPH_FLOURISH_STRIP "$noresult"
    exit 1
elif [ "$fails" = 0 ]; then
    echo "GLYPH_FLOURISH_STRIP RESULT PASS"
else
    echo "GLYPH_FLOURISH_STRIP RESULT FAIL ($fails runs without every frame or sheet)"
    exit 1
fi
