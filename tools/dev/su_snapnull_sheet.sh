#!/usr/bin/env bash
# The update popup with NO snapshots, as a sheet of PNGs (tools/dev/qml/su_snapnull_sheet.qml): the same harness on two trees, and the two
# sheets compared pixel by pixel -- the snapshots work must move none of them.
#
#   tools/dev/su_snapnull_sheet.sh <outdir>                   render this tree's sheet into <outdir>
#   tools/dev/su_snapnull_sheet.sh --vs-rev <rev>             the same against a commit (git archive into a throwaway folder)
#   tools/dev/su_snapnull_sheet.sh --compare <dirA> <dirB>    SU_SNAPNULL RESULT PASS | FAIL (the count of differing pixels per image)
#   BASE=<tree> tools/dev/su_snapnull_sheet.sh --vs <tree>     renders <tree> (an old checkout, `git archive` into /tmp) and this one, compares
#
# Distance-field text is off (it differs a level between two runs of one tree: CLAUDE.md), offscreen, rhi, private XDG dirs and a sandbox copy.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
# This tree's half runs in a sandbox copy (a quickshell never starts in the tree itself); a base tree is a throwaway checkout and runs as it is.
if [ -e .git ] && [ -z "${SNS_INNER:-}" ] && [ "${1:-}" != --compare ] && [ "${1:-}" != --vs ] && [ "${1:-}" != --vs-rev ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-sns}"
    out=$(realpath -m "$1")
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen SNS_INNER=1 bash tools/dev/su_snapnull_sheet.sh "$out"
fi
render() {   # <tree> <outdir>
    local tree=$1 out=$2 work
    mkdir -p "$out"
    work=$(mktemp -d "${SCRATCH:-/tmp}/sns.XXXXXX")
    mkdir -p "$work/cfg/theme" "$work/state" "$work/cache"
    echo '{"theme":"eva","mode":"light"}' > "$work/cfg/theme/state.json"
    [ "$tree" = "$(pwd)" ] || { mkdir -p "$tree/tools/dev/qml"; cp tools/dev/qml/su_snapnull_sheet.qml "$tree/tools/dev/qml/"; }
    ( cd "$tree" && env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="$work/cfg" XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache" SNS_OUT="$out" \
        QML_DISABLE_DISTANCEFIELD=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= \
        timeout -k 5 120 quickshell -n -p "$tree/tools/dev/qml/su_snapnull_sheet.qml" > "$work/log" 2>&1 )
    grep -q 'SNS DONE' "$work/log" || { echo "SU_SNAPNULL RESULT FAIL (no result: $work/log)"; return 1; }
    rm -rf "$work"
}
compare() {
    python3 - "$@" <<'PY'
import sys, os
from PIL import Image, ImageChops
a, b = sys.argv[1:]
names = sorted(f for f in os.listdir(a) if f.endswith(".png"))
bad = 0
def flat(path):
    im = Image.open(path).convert("RGBA")
    return Image.alpha_composite(Image.new("RGBA", im.size, (0, 0, 0, 255)), im).convert("RGB")
for n in names:
    if not os.path.exists(os.path.join(b, n)):
        print("missing", n); bad += 1; continue
    x, y = flat(os.path.join(a, n)), flat(os.path.join(b, n))
    if x.size != y.size:
        print(n, "size differs"); bad += 1; continue
    # a pixel moved when ANY channel moved (a luma of the difference rounds one level of blue away)
    r, g, bl = ImageChops.difference(x, y).split()
    c = sum(1 for v in ImageChops.lighter(ImageChops.lighter(r, g), bl).tobytes() if v)
    print(f"{n}: {c} px differ"); bad += 1 if c else 0
print("SU_SNAPNULL RESULT " + ("PASS" if bad == 0 and names else "FAIL"))
sys.exit(1 if bad or not names else 0)
PY
}
case "${1:-}" in
    --compare) shift; compare "$@" ;;
    --vs)
        out=$(mktemp -d "${SCRATCH:-/tmp}/snsv.XXXXXX")
        render "$(realpath "$2")" "$out/base" && "$0" "$out/new" || { rm -rf "$out"; exit 1; }
        compare "$out/base" "$out/new"; rc=$?
        rm -rf "$out"; exit $rc ;;
    --vs-rev)   # a commit instead of a tree: its `git archive` in a throwaway folder (the gate row uses it: the commit before the snapshots work)
        base=$(mktemp -d "${SCRATCH:-/tmp}/snsr.XXXXXX")
        git archive "$2" | tar -x -C "$base" || { rm -rf "$base"; echo "no such revision: $2"; exit 2; }
        "$0" --vs "$base"; rc=$?
        rm -rf "$base"; exit $rc ;;
    "") echo "usage: su_snapnull_sheet.sh <outdir> | --compare A B | --vs <tree> | --vs-rev <rev>"; exit 2 ;;
    *) render "$(pwd)" "$1" ;;
esac
