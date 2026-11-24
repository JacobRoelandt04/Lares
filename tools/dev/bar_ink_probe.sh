#!/usr/bin/env bash
# The shade the bar's glyphs and text rest in (tools/dev/qml/bar_ink_probe.qml): the power reel's cell at rest, the clock's text and the
# battery's charge digits are all the shade of every other bar glyph (Theme.textMuted; BarText.ink). Sandbox, offscreen. Each cell's most inked pixel (furthest from the surface) is judged against the
# token within LEVELS (default 6) per channel.
#
#   tools/dev/bar_ink_probe.sh [outdir]     THEME (default monokai) MODES (default "light dark") SCALE (default 4)
#   ARM=reelprimary  the reel's rest ink back to Theme.textPrimary: reel_rest must fail
#   ARM=textprimary  BarText's ink back to Theme.textPrimary: clock must fail
#   ARM=silicondigits  the charge digits back to Theme.textPrimary: silicon must fail
# Last line: BAR_INK RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/bar_ink}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/bar_ink_probe.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
THEME="${THEME:-monokai}"
MODES="${MODES:-light dark}"
SCALE="${SCALE:-4}"
LEVELS="${LEVELS:-6}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/barink.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

case "${ARM:-}" in
reelprimary)
    python3 - <<'PY' || { echo "BAR_INK RESULT FAIL (ARM reelprimary: anchor gone)"; exit 1; }
p = "modules/bar/reel/IconReelView.qml"
s = open(p).read()
a = "cell.isSelected ? Theme.textMuted : Theme.textFaint"
assert a in s
open(p, "w").write(s.replace(a, "cell.isSelected ? Theme.textPrimary : Theme.textFaint"))
PY
    ;;
textprimary)
    python3 - <<'PY' || { echo "BAR_INK RESULT FAIL (ARM textprimary: anchor gone)"; exit 1; }
p = "modules/common/theme/BarText.qml"
s = open(p).read()
a = "readonly property color ink: Theme.textMuted"
assert a in s
open(p, "w").write(s.replace(a, "readonly property color ink: Theme.textPrimary"))
PY
    ;;
silicondigits)
    python3 - <<'PY' || { echo "BAR_INK RESULT FAIL (ARM silicondigits: anchor gone)"; exit 1; }
p = "modules/silicon/bar/SiliconBarFace.qml"
s = open(p).read()
a = "        color: BarText.ink\n        fontFamily: fm.font.family"
assert a in s
open(p, "w").write(s.replace(a, "        color: Theme.textPrimary\n        fontFamily: fm.font.family"))
PY
    ;;
esac

bad=0
for md in $MODES; do
    o="$OUT/$md"; rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_$md/theme" "$WORK/state"
    printf '{"theme":"%s","mode":"%s"}\n' "$THEME" "$md" > "$WORK/cfg_$md/theme/state.json"
    log="$o/run.log"
    XDG_CONFIG_HOME="$WORK/cfg_$md" XDG_STATE_HOME="$WORK/state" OUT_DIR="$o" SCALE="$SCALE" \
        timeout -k 5 90 quickshell -p tools/dev/qml/bar_ink_probe.qml > "$log" 2>&1
    # a run that did not load has no BARINK RESULT line: the runner's own no-result verdict, and nothing else (tools/dev/result_lib.sh)
    if ! rl_has "$log" 'BARINK RESULT'; then
        echo "$THEME $md: did not load"
        [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
        rl_noresult BAR_INK "$log"; exit 1
    fi
    res=$(rl_result BARINK "$log"); rc=$?
    echo "$THEME $md: $res"
    python3 -B -W ignore - "$o" "$LEVELS" "$log" <<'PY' || bad=1
import re, sys
from PIL import Image
o, levels, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = open(log, errors="replace").read()
text = re.sub(r"\x1b\[[0-9;]*m", "", text)
exp = {m.group(1): (m.group(2), m.group(3)) for m in re.finditer(r"BARINK expect (\w+) (\w+) (#[0-9a-fA-F]{6,8})", text)}
surf = re.search(r"BARINK surface (#[0-9a-fA-F]{6,8})", text)
def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) if len(h) == 6 else tuple(int(h[i:i + 2], 16) for i in (2, 4, 6))
sc = rgb(surf.group(1))
bad = 0
crops = {m.group(1): tuple(int(m.group(i)) for i in (2, 3, 4, 5)) for m in re.finditer(r"BARINK crop (\w+) (\d+) (\d+) (\d+) (\d+)", text)}
for name, (tok, hx) in exp.items():
    im = Image.open("%s/%s.png" % (o, name)).convert("RGB")
    if name in crops:
        x, y, w, h = crops[name]
        im = im.crop((x, y, x + w, y + h))
    px = list(im.getdata())
    far = max(px, key=lambda p: sum(abs(p[i] - sc[i]) for i in range(3)))
    want = rgb(hx)
    d = max(abs(far[i] - want[i]) for i in range(3))
    ok = d <= levels
    bad |= not ok
    print("  %-10s inked pixel #%02X%02X%02X  %s %s  off by %d  %s" % (name, *far, tok, hx, d, "ok" if ok else "FAIL " + name))
sys.exit(1 if bad else 0)
PY
done
if [ $bad -eq 0 ]; then echo "BAR_INK RESULT PASS"; else echo "BAR_INK RESULT FAIL"; exit 1; fi
