#!/usr/bin/env bash
# The bar's speaker at each volume (tools/dev/qml/audio_levels_probe.qml): the glyph's waves by level and the speaker body's x in each
# grab (it must not move: a wave added grows outward). Runs in a sandbox copy, offscreen.
#
#   tools/dev/audio_levels_probe.sh [outdir]     SCALE (default 4)
#   ARM=old     AudioGlyphs' old thresholds (0.33 / 0.66, inclusive): the glyph check must fail
#   ARM=centred the speaker is not pinned (centred on the half's middle, as before): the body's x check must fail
# Last line: AUDIO_LEVELS RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/audio_levels}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/audio_levels_probe.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
SCALE="${SCALE:-4}"
mkdir -p "$OUT"
rm -f "$OUT"/level_*.png
WORK=$(mktemp -d "${TMPDIR:-/tmp}/audiolv.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg/theme" "$WORK/state"
printf '{"theme":"eva","mode":"light"}\n' > "$WORK/cfg/theme/state.json"

case "${ARM:-}" in
old)
    python3 - <<'PY' || { echo "AUDIO_LEVELS RESULT FAIL (ARM old: anchor gone)"; exit 1; }
p = "modules/common/components/AudioGlyphs.qml"
s = open(p).read()
a = "property real levelLowMax: 0.005"
assert a in s
s = s.replace(a, "property real levelLowMax: 0.33").replace("property real levelMedMax: 0.5", "property real levelMedMax: 0.66")
s = s.replace("if (volume < root.levelLowMax) return root.outputGlyphSpeakerLow;", "if (volume <= root.levelLowMax) return root.outputGlyphSpeakerLow;")
open(p, "w").write(s)
PY
    ;;
centred)
    python3 - <<'PY' || { echo "AUDIO_LEVELS RESULT FAIL (ARM centred: anchor gone)"; exit 1; }
p = "modules/bar/audio/AudioBarButton.qml"
s = open(p).read()
a = 'pinGlyph: root.outputDeviceType === "speaker" ? root.glyphs.outputGlyphSpeakerHigh : ""'
assert a in s
open(p, "w").write(s.replace(a, 'pinGlyph: ""'))
PY
    ;;
esac

log="$OUT/run.log"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" OUT_DIR="$OUT" SCALE="$SCALE" \
    timeout -k 5 90 quickshell -p tools/dev/qml/audio_levels_probe.qml > "$log" 2>&1
rl_clean "$log" | grep -a "AUDIOLV" | grep -v RESULT
# a run that did not load has no AUDIOLV RESULT line: say so in the runner's own name (tools/dev/result_lib.sh)
if ! rl_has "$log" 'AUDIOLV RESULT'; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    rl_noresult AUDIO_LEVELS "$log"; exit 1
fi
res=$(rl_result AUDIOLV "$log") ; rc=$?
[ $rc -eq 0 ] || echo "glyph check: $res"
python3 -B - "$OUT" "$SCALE" "$rc" <<'PY'
import sys, glob
from PIL import Image
out, scale, rc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
bad = 0
xs = []
files = sorted(glob.glob(out + "/level_*.png"), key=lambda f: int(f.rsplit("_", 1)[1][:-4]))
if not files:
    print("AUDIO_LEVELS RESULT FAIL (no grabs)"); sys.exit(1)
for f in files:
    im = Image.open(f).convert("RGB")
    w, h = im.size
    half = w // 2
    # ink = the speaker's own hue (BarHues.speakerOn, green in eva light), left half; the antialiased edge is skipped by the threshold
    px = im.load()
    cols = []
    for x in range(0, half):
        for y in range(int(h * 0.2), int(h * 0.8)):
            if px[x, y][1] - px[x, y][0] > 50:   # the speaker's own hue (green), nothing else on the pill is
                cols.append(x); break
    left = min(cols) if cols else None
    xs.append(left)
    print("body x", f.rsplit("/", 1)[1], left, "(px at %dx; right edge of ink %s)" % (scale, max(cols) if cols else None))
if None in xs or max(xs) != min(xs):
    print("AUDIO_LEVELS body moved: x per level %s (spread %s px at %dx)" % (xs, (max(x for x in xs if x is not None) - min(x for x in xs if x is not None)) if any(x is not None for x in xs) else "?", scale))
    bad = 1
print("AUDIO_LEVELS RESULT " + ("PASS" if bad == 0 and rc == 0 else "FAIL"))
sys.exit(bad or rc)
PY
