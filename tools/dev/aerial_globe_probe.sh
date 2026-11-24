#!/usr/bin/env bash
# aerial_globe_probe.sh -- the VPN globe judged: a light lands where its lat / lon projects (Brussels, Tokyo, Reykjavik within 2 px at two turns each, by the SHADER's own marker
# against GlobeMath), only front-facing lights pick, the land mask script reproduces its bytes, the shader draws ink in both families, THE MERIDIANS END ON THE POLAR CIRCLES (round 3:
# globe.frag POLAR_CAP, 77.5 degrees: ink on the parallel, none between it and the pole), a live globe turns and a halted one presents nothing.
# ROUND 3: the tunnel (TunnelLayer / tunnel.frag) is gone, so its ink box, its renders and its sheet are gone with it -- the label's chrome is the tunnel's look now, proved by
# tools/dev/aerial_r3_label.sh.
#
#   tools/dev/aerial_globe_probe.sh [outdir]       MODES="light dark"
#   ARM=backpick   lightAt also picks back-facing lights -- must FAIL (pick-back-none)
#   ARM=lonflip    GlobeMath's longitude sign flipped (the shader's is not) -- must FAIL (MARKS)
#   ARM=noink      the sphere's alpha is 0: nothing is drawn -- must FAIL (INK, POLAR)
#   ARM=nopolar    the meridians run to the pole (POLAR_CAP at 90 degrees; shader rebaked in the copy) -- must FAIL (POLAR: ink above the cap, none on the circle)
#   ends in AERIAL_GLOBE RESULT PASS|FAIL
#
# OFFSCREEN ONLY: the run starts itself inside a sandbox copy (tools/dev/sandbox.sh), the platform forced on the launch, private config / cache / state homes. The arms patch the COPY.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${AGP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-globe}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen AGP_INNER=1 AGP_OUTARG="${1:-}" bash tools/dev/aerial_globe_probe.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_GLOBE
OUT="${AGP_OUTARG:-${1:-${SCRATCH:-/tmp}/aerial-globe}}"
mkdir -p "$OUT"

patch() {  # <file> <old> <new>: exactly one anchor, or the arm does not exist
    python3 - "$1" "$2" "$3" <<'PY' || { echo "$NAME RESULT FAIL (arm anchor: $1)"; exit 2; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("anchor %r: %d" % (a, s.count(a)))
open(p, "w").write(s.replace(a, b))
PY
}
if [ -n "${ARM:-}" ]; then
    [ -e .git ] && { echo "$NAME RESULT FAIL (ARM in a git tree)"; exit 2; }
    case "$ARM" in
        backpick) patch modules/aerial/scene/GlobeLayer.qml "            if (L.depth <= 0.05)
                continue;" "            if (false)
                continue;" ;;
        lonflip) patch modules/aerial/scene/GlobeMath.js "var LON_SIGN = 1;" "var LON_SIGN = -1;" ;;
        noink)
            patch modules/aerial/scene/GlobeLayer.qml "Qt.vector4d(root.hue.r, root.hue.g, root.hue.b, root.power)" "Qt.vector4d(root.hue.r, root.hue.g, root.hue.b, 0)" ;;
        nopolar)
            patch modules/aerial/shaders/globe.frag "const float POLAR_CAP = 1.3526301;" "const float POLAR_CAP = 1.5707963;"
            tools/dev/bake_shaders.sh globe > /dev/null || { echo "$NAME RESULT FAIL (ARM nopolar: the bake failed)"; exit 1; } ;;
        *) echo "unknown ARM=$ARM (backpick|lonflip|noink|nopolar)"; exit 2 ;;
    esac
fi

# ---- the mask script reproduces its bytes (it fetches nothing when the cache holds the source)
maskres=$(python3 tools/aerial/make_landmask.py --check 2>&1 | tail -1)
case "$maskres" in *same*) mp=1 ;; *) mp=0 ;; esac
echo "  mask: $maskres"

allp=1; lines=""
for mode in ${MODES:-light dark}; do
    d="$OUT/$mode"; mkdir -p "$d/cfg/theme" "$d/cache" "$d/state"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/cfg/theme/state.json"
    rm -f "$d"/*.png
    LOG="$d/probe.log"
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$d/cfg" XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" \
        OUT="$d" QML_DISABLE_DISTANCEFIELD=1 timeout 240 quickshell -n -p tools/dev/qml/aerial_globe_probe.qml > "$LOG" 2>&1
    rl_clean "$LOG" | grep -a "GP \|EXPECT " | grep -a -v "GP RESULT" | sed 's/^.*\(GP \|EXPECT \)/\1/' | sed "s/^/  [$mode] /"
    if ! rl_clean "$LOG" | grep -a -q "GP RESULT"; then
        [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOG)"
        rl_noresult "$NAME" "$LOG"; exit 1
    fi
    case "$(rl_clean "$LOG" | grep -a 'GP RESULT' | tail -1)" in *PASS*) ;; *) allp=0 ;; esac
    rl_clean "$LOG" | grep -a "EXPECT " | sed 's/^.*EXPECT /EXPECT /' > "$d/expect.txt"
    # the pictures: marks within 2 px, ink in the disc, the meridians' polar circles
    res=$(python3 -B - "$d" <<'PY'
import glob, math, os, sys
from PIL import Image
d = sys.argv[1]
exp = [l.split() for l in open(os.path.join(d, "expect.txt"))]
def load(n):
    p = os.path.join(d, n + ".png")
    return Image.open(p).convert("RGB") if os.path.exists(p) else None
marks_seen, bad = [], []
for e in exp:
    if e[1] != "mark":
        continue
    name, k, x, y, front = e[2], e[3], float(e[4]), float(e[5]), e[6]
    marks_seen.append(name)
    im = load("mark_%s_%s" % (name, k))
    if im is None:
        bad.append("%s %s no picture" % (name, k)); continue
    px = im.load(); w, h = im.size
    sx = sy = n = 0
    for yy in range(h):
        for xx in range(w):
            r, g, b = px[xx, yy]
            if r > 200 and b > 200 and g < 80:
                sx += xx + 0.5; sy += yy + 0.5; n += 1
    if front != "1":
        bad.append("%s %s is not on the visible hemisphere (fixture)" % (name, k)); continue
    if n < 4:
        bad.append("%s %s: no marker drawn (%d px)" % (name, k, n)); continue
    dx, dy = sx / n - x, sy / n - y
    dist = math.hypot(dx, dy)
    print("  mark %-10s turn %s  expect (%.1f, %.1f) drawn (%.1f, %.1f) off %.2f px" % (name, k, x, y, sx / n, sy / n, dist))
    if dist > 2.0:
        bad.append("%s %s off by %.1f px" % (name, k, dist))
if len(marks_seen) != 6:
    bad.append("%d of 6 marks in the log" % len(marks_seen))
print("MARKS " + ("FAIL (" + "; ".join(bad) + ")" if bad else "PASS"))
# ink: the globe's disc against the same scene without it
ibad = []
rects = 0
def diff(a, b, box):
    pa, pb = a.load(), b.load(); n = 0; tot = 0
    x0, y0, x1, y1 = box
    for y in range(max(0, y0), min(a.size[1], y1)):
        for x in range(max(0, x0), min(a.size[0], x1)):
            tot += 1
            if max(abs(pa[x, y][i] - pb[x, y][i]) for i in range(3)) > 6:
                n += 1
    return n, tot
for e in exp:
    if e[1] != "rect":
        continue
    rects += 1
    fam = e[2]; cx, cy, rp = float(e[3]), float(e[4]), float(e[5])
    base = load("base_" + fam)
    for k in range(4):
        for st in ("down", "up"):
            im = load("globe_%s_%d_%s" % (fam, k, st))
            if im is None or base is None:
                ibad.append("fam %s turn %d %s: no picture" % (fam, k, st)); continue
            n, tot = diff(im, base, (int(cx - rp), int(cy - rp), int(cx + rp) + 1, int(cy + rp) + 1))
            share = n / max(1, tot)
            print("  ink globe fam %s turn %d %-4s %.3f of the disc box" % (fam, k, st, share))
            if share < 0.06:
                ibad.append("globe fam %s turn %d %s share %.3f" % (fam, k, st, share))
if rects != 2:
    ibad.append("%d of 2 rects in the log" % rects)
print("INK " + ("FAIL (" + "; ".join(ibad) + ")" if ibad else "PASS"))
# THE POLAR CIRCLES: ink ON the parallel at 77.5 degrees (the meridian's end and the circle's own stretch between two meridians), none between it and the pole on the same meridian
pbad = []
def inkat(im, base, x, y, r):
    """the mean difference from the globe-less scene over a (2r+1)^2 window (a hairline is ~1 px: the mean is what a dot or a ghost of the far side cannot fake alone)"""
    pa, pb = im.load(), base.load(); tot = 0; n = 0
    for yy in range(int(round(y)) - r, int(round(y)) + r + 1):
        for xx in range(int(round(x)) - r, int(round(x)) + r + 1):
            if 0 <= xx < im.size[0] and 0 <= yy < im.size[1]:
                tot += max(abs(pa[xx, yy][i] - pb[xx, yy][i]) for i in range(3)); n += 1
    return tot / max(1, n)
for fam in ("0", "1"):
  for pole in ("n", "s"):
    key = fam + pole
    im, base = load("polar_" + key), load("base_" + fam)
    samples = [e for e in exp if e[1] == "polar" and e[2] == key]
    spans = [float(e[3]) for e in exp if e[1] == "polarspan" and e[2] == key]
    tag = "fam %s %s pole" % (fam, "north" if pole == "n" else "south")
    if im is None or base is None or len(samples) != 16 or not spans:
        pbad.append("%s: no picture / samples" % tag); continue
    mean = {}
    for e in samples:
        kind, x, y, front = e[3], float(e[5]), float(e[6]), e[7]
        if front != "1":
            pbad.append("%s: a sample is on the far side (fixture)" % tag)
        mean.setdefault(kind, []).append(inkat(im, base, x, y, 1))
    m = {k: sum(v) / len(v) for k, v in mean.items()}
    print("  polar %s: ink below the circle on the meridian %.0f / off it %.0f; ON the circle %.0f; above it on the meridian %.0f / off it %.0f (span cap-to-pole %.1f px)" %
          (tag, m["below-m"], m["below-o"], m["cap"], m["above-m"], m["above-o"], spans[0]))
    if spans[0] < 8.0:
        pbad.append("%s: the cap-to-pole stretch is only %.1f px (too foreshortened to judge)" % (tag, spans[0]))
    if m["below-m"] - m["below-o"] < 20:
        pbad.append("%s: the meridian below the circle shows no ink over the bare sphere (the control)" % tag)
    if m["cap"] < 30 or m["cap"] - m["above-o"] < 12:
        pbad.append("%s: no ink ON the parallel at 77.5 degrees" % tag)
    # (dots of the land mask and the far side's ghost put ink above the circle too: the meridian is what the same radius shows OVER an off-meridian one, against what it shows below the circle)
    if m["above-m"] - m["above-o"] > 0.4 * (m["below-m"] - m["below-o"]):
        pbad.append("%s: meridian ink between the polar circle and the pole (%.0f over the bare sphere, %.0f below the circle)" % (tag, m["above-m"] - m["above-o"], m["below-m"] - m["below-o"]))
print("POLAR " + ("FAIL (" + "; ".join(pbad) + ")" if pbad else "PASS"))
PY
)
    echo "$res" | grep -v "^MARKS \|^INK \|^POLAR " | sed "s/^/  [$mode] /"
    mres=$(echo "$res" | grep "^MARKS "); ires=$(echo "$res" | grep "^INK "); pres=$(echo "$res" | grep "^POLAR ")
    echo "  [$mode] $mres"; echo "  [$mode] $ires"; echo "  [$mode] $pres"
    case "$mres" in *PASS*) ;; *) allp=0 ;; esac
    case "$ires" in *PASS*) ;; *) allp=0 ;; esac
    case "$pres" in *PASS*) ;; *) allp=0 ;; esac
done
if [ $allp = 1 ] && [ $mp = 1 ]; then
    echo "$NAME RESULT PASS (${ARM:+ARM $ARM: }marks, picks, ink, polar circles, still, mask bytes)"
    exit 0
fi
echo "$NAME RESULT FAIL (see above)"
exit 1
