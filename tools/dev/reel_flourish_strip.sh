#!/usr/bin/env bash
# The reels' flourishes (the power reel's and the idle reel's) as frame strips, and every reel glyph at rest before and after (tools/dev/qml/reel_flourish_strip.qml),
# on an OLD revision and on this tree, in each mode, composed into labelled sheets.
#
#   tools/dev/reel_flourish_strip.sh [outdir]     (from the config it re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#
#   BEFORE=<rev>   the old tree (default 5fdd9cab, 2026-11-19: the soft idle icon's sun is filled, the user's call; before it 36399bfa,
#                  round 5's BARINK merge: the reel cell rests in textMuted; before that c78b1ea4, round 3's base,
#                  the open padlock in place; from a sandbox copy the history is
#                  MOCKUP_REPO's). BEFORE=none: this tree alone
#   MAY_MOVE       rest cells that may differ from the old tree on purpose, a space-separated list of name prefixes (default none;
#                  "rest_power_lock" was round 2's: the padlock's rest went open)
#   THEME / MODES  default eva / "light dark"
#   N              frames per strip (default 12)
#   SCALE          the cells drawn at this scale (default 1; 1.25 is the user's frame)
#
# Writes <outdir>/strips_<mode>.png (one row per flourish, the old tree's row over this tree's, the cells x4 nearest, t under each),
# <outdir>/rest_<mode>.png (every glyph at rest: before, after, and the pixels that differ) and the cells under
# <outdir>/{before,after}/<mode>/. Prints `KNOCK <tree> <mode>: dip <px> rebound <px>` -- the padlock's engage held at its knock's deepest
# dip and rebound, measured against its shut rest cell as the shift of the ink's centroid (in the cell's own px, so at SCALE) -- and
# `END <mode> <strip>` when a strip's last frame is not its rest cell to the pixel. The last line is REEL_FLOURISH_STRIP RESULT
# PASS|FAIL: PASS when every run grabbed every cell, every rest cell is the old tree's to the pixel (but MAY_MOVE's) and every lock
# strip ends on its rest cell to the pixel.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/reel_flourish_strip}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/reel_flourish_strip.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
# the shell renders its text gray (shell.qml's pragma): so does the sheet
export QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
BEFORE="${BEFORE:-5fdd9cab}"
THEME="${THEME:-eva}"
MODES="${MODES:-light dark}"
GITDIR="${MOCKUP_REPO:-$HERE}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/reelstrip.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/before"
HAVE_BEFORE=0
if [ "$BEFORE" != none ] && git -C "$GITDIR" archive "$BEFORE" 2> /dev/null | tar -x -C "$WORK/before" 2> /dev/null \
    && [ -d "$WORK/before/tools/dev/qml" ]; then
    cp tools/dev/qml/reel_flourish_strip.qml "$WORK/before/tools/dev/qml/"
    HAVE_BEFORE=1
else
    echo "no tree for BEFORE=$BEFORE in $GITDIR: this tree alone"
fi

fails=0
noresult=""
run_one() {    # <tree-name> <tree-dir> <mode>
    local name=$1 dir=$2 md=$3
    local o="$OUT/$name/$md"
    rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_$md/theme" "$WORK/state"
    printf '{"theme":"%s","mode":"%s"}\n' "$THEME" "$md" > "$WORK/cfg_$md/theme/state.json"
    local log="$o/run.log"
    XDG_CONFIG_HOME="$WORK/cfg_$md" XDG_STATE_HOME="$WORK/state" OUT_DIR="$o" N="${N:-12}" \
        timeout -k 5 150 quickshell -p "$dir/tools/dev/qml/reel_flourish_strip.qml" > "$log" 2>&1
    local res
    res=$(rl_clean "$log" | grep -o "REELSTRIP RESULT .*" | tail -1)
    echo "$name $md: ${res:-no result ($log)}"
    rl_clean "$log" | grep -E "WARN|ERROR|rror" | rl_platform_noise \
        | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" \
        | sort -u | head -8 | sed 's/^/    /'
    case "$res" in *PASS*) ;; "") fails=$((fails + 1)); [ -n "$noresult" ] || noresult=$log ;; *) fails=$((fails + 1)) ;; esac
}

for md in $MODES; do
    [ "$HAVE_BEFORE" = 1 ] && run_one before "$WORK/before" "$md"
    run_one after "$HERE" "$md"
done

python3 -B - "$OUT" "$HAVE_BEFORE" "${MAY_MOVE:-}" $MODES <<'PY'
import os, sys
from PIL import Image, ImageDraw, ImageChops
out, have_before, may_move, modes = sys.argv[1], sys.argv[2] == "1", sys.argv[3].split(), sys.argv[4:]
Z = 4
bad = 0

def centroid_y(path, ink_l):
    # the ink's vertical centroid, by coverage: |L - ground| / |ink - ground| (L the luminance; the ground the cell's corner)
    im = Image.open(path).convert("L")
    w, h = im.size
    px = im.load()
    g = px[0, 0]
    span = float(ink_l - g) or 1.0
    tot = acc = 0.0
    for y in range(h):
        for x in range(w):
            c = min(1.0, max(0.0, (px[x, y] - g) / span))
            tot += c
            acc += c * (y + 0.5)
    return acc / tot if tot else 0.0

for md in modes:
    a = os.path.join(out, "after", md)
    b = os.path.join(out, "before", md)
    if not os.path.isdir(a):
        continue
    trees = [("before", b), ("after", a)] if have_before and os.path.isdir(b) else [("after", a)]
    # the strips: one row per flourish, the old tree's over this one's
    rows = {}
    for f in sorted(os.listdir(a)):
        if f.startswith("strip_"):
            key = f[len("strip_"):-len(".png")].rsplit("_", 1)[0]
            rows.setdefault(key, []).append(f)
    if rows:
        w0, h0 = Image.open(os.path.join(a, next(iter(rows.values()))[0])).size
        cw, ch = w0 * Z, h0 * Z
        lab = 190
        n = max(len(v) for v in rows.values())
        lines = [(key, name, d) for key in rows for name, d in trees]
        sheet = Image.new("RGB", (lab + n * (cw + 6), len(lines) * (ch + 22) + 6), "white")
        dr = ImageDraw.Draw(sheet)
        for r, (key, name, d) in enumerate(lines):
            y = 6 + r * (ch + 22)
            dr.text((6, y + ch // 2), key + ("  " + name if len(trees) > 1 else ""), fill="black")
            for i, f in enumerate(rows[key]):
                if not os.path.exists(os.path.join(d, f)):
                    continue
                im = Image.open(os.path.join(d, f)).convert("RGB").resize((cw, ch), Image.NEAREST)
                x = lab + i * (cw + 6)
                sheet.paste(im, (x, y))
                dr.text((x + 2, y + ch + 4), "t %.2f" % (i / max(1, len(rows[key]) - 1)), fill="black")
        sheet.save(os.path.join(out, "strips_%s.png" % md))
    # every lock strip ends on its rest: the engage on the shut padlock, the cycle and the release on the open one
    for strip, rest in (("lock_engage", "rest_power_lock_shut"), ("lock_cycle", "rest_power_lock"), ("lock_release", "rest_power_lock")):
        fs = rows.get(strip, [])
        if not fs or not os.path.exists(os.path.join(a, rest + ".png")):
            continue
        diff = ImageChops.difference(Image.open(os.path.join(a, fs[-1])).convert("RGB"), Image.open(os.path.join(a, rest + ".png")).convert("RGB"))
        moved = sum(1 for p in diff.getdata() if max(p) > 0)
        if moved:
            bad += 1
            print("END %s %s: its last frame is %d px off %s" % (md, strip, moved, rest))
    # the knock: the engage held at its deepest dip and rebound, against the shut rest cell
    for name, d in trees:
        shut = os.path.join(d, "rest_power_lock_shut.png")
        if not all(os.path.exists(os.path.join(d, f)) for f in ("rest_power_lock_shut.png", "knock_lock_dip.png", "knock_lock_rebound.png")):
            continue
        L = Image.open(shut).convert("L")
        g = L.getpixel((0, 0))
        ink = max(L.getdata(), key=lambda v: abs(v - g))
        y0 = centroid_y(shut, ink)
        print("KNOCK %s %s: dip %.2f px rebound %.2f px" % (name, md, centroid_y(os.path.join(d, "knock_lock_dip.png"), ink) - y0,
                                                           y0 - centroid_y(os.path.join(d, "knock_lock_rebound.png"), ink)))
    # the rest cells: before | after | diff, and the count
    rest = sorted(f for f in os.listdir(a) if f.startswith("rest_"))
    w0, h0 = Image.open(os.path.join(a, rest[0])).size if rest else (40, 41)
    cw, ch = w0 * Z, h0 * Z
    sheet = Image.new("RGB", (220 + 3 * (cw + 8), len(rest) * (ch + 8) + 26), "white")
    d = ImageDraw.Draw(sheet)
    d.text((220, 6), "before", fill="black"); d.text((220 + cw + 8, 6), "after", fill="black"); d.text((220 + 2 * (cw + 8), 6), "differs", fill="black")
    for r, f in enumerate(rest):
        y = 22 + r * (ch + 8)
        ia = Image.open(os.path.join(a, f)).convert("RGB")
        note = "(no before)"
        if have_before and os.path.exists(os.path.join(b, f)):
            ib = Image.open(os.path.join(b, f)).convert("RGB")
            diff = ImageChops.difference(ia, ib)
            moved = sum(1 for p in diff.getdata() if max(p) > 0)
            note = "%d px differ" % moved
            expected = any(f.startswith(m) for m in may_move)
            if moved and not expected:
                bad += 1
                print("REST %s %s: %d px differ" % (md, f, moved))
            sheet.paste(ib.resize((cw, ch), Image.NEAREST), (220, y))
            mask = diff.convert("L").point(lambda v: 255 if v else 0).resize((cw, ch), Image.NEAREST)
            sheet.paste(Image.new("RGB", (cw, ch), (220, 0, 0)), (220 + 2 * (cw + 8), y), mask)
        sheet.paste(ia.resize((cw, ch), Image.NEAREST), (220 + cw + 8, y))
        d.text((6, y + ch // 2 - 6), f[:-4], fill="black")
        d.text((6, y + ch // 2 + 8), note, fill="black")
    sheet.save(os.path.join(out, "rest_%s.png" % md))
print("MISMATCHES %d" % bad)
sys.exit(1 if bad else 0)
PY
rest_rc=$?
if [ -n "$noresult" ]; then
    rl_noresult REEL_FLOURISH_STRIP "$noresult"
    exit 1
fi
if [ "$fails" = 0 ] && [ "$rest_rc" = 0 ]; then
    echo "REEL_FLOURISH_STRIP RESULT PASS (sheets in $OUT)"
    exit 0
fi
echo "REEL_FLOURISH_STRIP RESULT FAIL ($fails runs without a full grab; rest cells that moved or strips off their rest: see above; $OUT)"
exit 1
