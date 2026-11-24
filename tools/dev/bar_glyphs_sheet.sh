#!/usr/bin/env bash
# The bar glyphs' before/after sheet: every bar glyph in every state it shows (tools/dev/qml/bar_glyphs_sheet.qml), on an OLD
# revision and on this tree, in each theme and mode, composed into labelled sheets.
#
#   tools/dev/bar_glyphs_sheet.sh [outdir]      (from the config it re-runs itself in a sandbox copy: tools/dev/sandbox.sh)
#
#   BEFORE=<rev>        the old tree (default ab1592e6, the post-deploy round's base); from a sandbox copy the git history is
#                       MOCKUP_REPO's (sandbox.sh names the real tree). BEFORE=none, or a history that does not have it: this
#                       tree alone (the before columns read "(none)")
#   THEMES / MODES      default "eva everbox" / "light dark"
#   FILM=1              the films instead (the hover fade frame by frame, one roll of each figure): film_<what>.png strips
#   COMPOSE_ONLY=1      compose the sheets from the cells already in <outdir>, run nothing
#
# Writes <outdir>/sheet_<group>.png (rows: states; columns: theme x mode x before/after) and <outdir>/{before,after}/<theme>_<mode>/
# with the cells; the old tree's copy is deleted on the way out. The last line is BAR_GLYPHS_SHEET RESULT PASS|FAIL: PASS when
# every run grabbed every cell.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/bar_glyphs_sheet}")"
# Never in the tree itself (a quickshell rewrites .qmlls.ini where it starts): a tree with a git dir is the config, a copy has none.
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/bar_glyphs_sheet.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
# the shell renders its text gray (shell.qml's pragma): so does the sheet
export QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
BEFORE="${BEFORE:-ab1592e6}"
THEMES="${THEMES:-eva everbox}"
MODES="${MODES:-light dark}"
GITDIR="${MOCKUP_REPO:-$HERE}"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glyphsheet.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The old tree: an archive of the revision, with today's harness in it (the harness sets nothing the old buttons lack).
mkdir -p "$WORK/before"
HAVE_BEFORE=0
if [ "$BEFORE" != none ] && git -C "$GITDIR" archive "$BEFORE" 2> /dev/null | tar -x -C "$WORK/before" 2> /dev/null \
    && [ -d "$WORK/before/tools/dev/qml" ]; then
    cp tools/dev/qml/bar_glyphs_sheet.qml "$WORK/before/tools/dev/qml/"
    HAVE_BEFORE=1
else
    echo "no tree for BEFORE=$BEFORE in $GITDIR: this tree alone"
fi

fails=0
noresult=""
run_one() {    # <tree-name> <tree-dir> <theme> <mode>
    local name=$1 dir=$2 th=$3 md=$4
    local o="$OUT/$name/${th}_${md}"
    rm -rf "$o"; mkdir -p "$o" "$WORK/cfg_${th}_${md}/theme" "$WORK/state"
    printf '{"theme":"%s","mode":"%s"}\n' "$th" "$md" > "$WORK/cfg_${th}_${md}/theme/state.json"
    local log="$o/run.log"
    # a tree without modules/bridge (an old BEFORE) leaves the bridge cell empty
    local nobridge=0
    [ -d "$dir/modules/bridge" ] || nobridge=1
    XDG_CONFIG_HOME="$WORK/cfg_${th}_${md}" XDG_STATE_HOME="$WORK/state" OUT_DIR="$o" FILM="${FILM:-}" NO_BRIDGE="$nobridge" \
        timeout -k 5 150 quickshell -p "$dir/tools/dev/qml/bar_glyphs_sheet.qml" > "$log" 2>&1
    local res
    res=$(rl_clean "$log" | grep -o "GLYPHS_SHEET RESULT .*" | tail -1)
    echo "$name $th $md: ${res:-no result ($log)}"
    rl_clean "$log" | grep -E "WARN|ERROR|rror" | rl_platform_noise \
        | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" \
        | sort -u | head -8 | sed 's/^/    /'
    case "$res" in *PASS*) ;; "") fails=$((fails + 1)); [ -n "$noresult" ] || noresult=$log ;; *) fails=$((fails + 1)) ;; esac
}

for th in $THEMES; do
    for md in $MODES; do
        [ -n "${COMPOSE_ONLY:-}" ] && continue
        [ "$HAVE_BEFORE" = 1 ] && run_one before "$WORK/before" "$th" "$md"
        run_one after "$HERE" "$th" "$md"
    done
done

python3 - "$OUT" "$THEMES" "$MODES" "${FILM:-}" <<'PY'
import os, sys, glob
from PIL import Image, ImageDraw, ImageFont
out, themes, modes, film = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4] == "1"
Z = 2
try:
    font = ImageFont.truetype("/usr/share/fonts/inter/InterVariable.ttf", 13)
except Exception:
    font = ImageFont.load_default()
cols = [(t, m, w) for t in themes for m in modes for w in ("before", "after")]

def cell(t, m, w, n):
    p = os.path.join(out, w, f"{t}_{m}", n + ".png")
    return Image.open(p).convert("RGBA") if os.path.exists(p) else None

def compose(names, path, title):
    imgs = {(c, n): cell(*c, n) for c in cols for n in names}
    cw = max([im.width for im in imgs.values() if im] + [40]) * Z
    ch = max([im.height for im in imgs.values() if im] + [20]) * Z
    lw, hh = 170, 40
    sheet = Image.new("RGB", (lw + len(cols) * (cw + 6), hh + len(names) * (ch + 6) + 6), "#808080")
    d = ImageDraw.Draw(sheet)
    d.text((6, 4), title, fill="white", font=font)
    for i, (t, m, w) in enumerate(cols):
        d.text((lw + i * (cw + 6) + 4, 22), f"{t} {m} {w}", fill="white", font=font)
    for r, n in enumerate(names):
        y = hh + r * (ch + 6)
        d.text((6, y + ch // 2 - 7), n, fill="white", font=font)
        for i, c in enumerate(cols):
            im = imgs[(c, n)]
            x = lw + i * (cw + 6)
            if im is None:
                d.rectangle((x, y, x + cw, y + ch), outline="#600000")
                d.text((x + 4, y + 4), "(none)", fill="#600000", font=font)
                continue
            big = im.resize((im.width * Z, im.height * Z), Image.NEAREST)
            sheet.paste(big, (x, y), big)
    sheet.save(path)
    print("sheet", path, sheet.size)

if film:
    for w in ("before", "after"):
        for t in themes:
            for m in modes:
                d = os.path.join(out, w, f"{t}_{m}")
                for what in sorted({os.path.basename(p).rsplit("_", 1)[0] for p in glob.glob(d + "/film_*.png")}):
                    frames = sorted(glob.glob(f"{d}/{what}_*.png"))
                    ims = [Image.open(p).convert("RGBA") for p in frames]
                    s = Image.new("RGB", (sum(i.width for i in ims) * Z + 4 * len(ims), ims[0].height * Z + 20), "#808080")
                    dd = ImageDraw.Draw(s)
                    x = 0
                    for k, im in enumerate(ims):
                        big = im.resize((im.width * Z, im.height * Z), Image.NEAREST)
                        s.paste(big, (x, 20), big)
                        dd.text((x + 2, 2), f"{k * 16}ms", fill="white", font=font)
                        x += big.width + 4
                    p = os.path.join(out, f"{what}_{w}_{t}_{m}.png")
                    s.save(p)
                    print("strip", p)
    sys.exit(0)

# the cells in the harness's own order (its log), then any the log does not name
names = []
for lp in sorted(glob.glob(os.path.join(out, "*", "*", "run.log"))):
    for line in open(lp, errors="replace"):
        if "GLYPHS_SHEET cell " in line:
            n = line.split("GLYPHS_SHEET cell ", 1)[1].strip()
            if n not in names:
                names.append(n)
names += sorted({os.path.basename(p)[:-4] for p in glob.glob(os.path.join(out, "*", "*", "*.png"))} - set(names))
groups = {
    "left": ["theme_", "notes_", "llm_", "reel_"],
    "centre": ["weather_", "stocks_"],
    "right1": ["player_", "audio_", "net_", "bridge_"],
    "right2": ["silicon_", "update_", "bell_"],
    "side": ["side_"],
}
for g, prefixes in groups.items():
    ns = [n for p in prefixes for n in names if n.startswith(p)]
    compose(ns, os.path.join(out, f"sheet_{g}.png"), f"bar glyphs, {g}: before = BEFORE rev, after = this tree; cells 2x")
PY

if [ -n "$noresult" ]; then
    rl_noresult BAR_GLYPHS_SHEET "$noresult"
    exit 1
elif [ "$fails" -eq 0 ]; then
    echo "BAR_GLYPHS_SHEET RESULT PASS"
else
    echo "BAR_GLYPHS_SHEET RESULT FAIL ($fails runs without every cell)"
    exit 1
fi
