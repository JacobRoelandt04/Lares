#!/usr/bin/env bash
# tools/dev/detail_scale_probe.sh -- A POPUP'S DETAIL HAS ITS OWN RATIO (GooeyEngine: A POPUP'S OWN RATIO; GooeyBody.ownScale).
#
#   tools/dev/detail_scale_probe.sh [<out>]
#   TREE=<dir>   run the same states on ANOTHER tree (an old revision: `git archive <rev> | tar -x -C <dir>`); the harness and this
#                runner are laid into a copy of it. The judge then holds only the facts the old tree has.
#   ARM=oldlookup  the fault, in the copy: a child takes its parent's entry (the old lookup); the judge must FAIL on `child ratio`
#   ARM=norsbind   the fault, in the copy: a child's content is not handed its own renderScale; the judge must FAIL on `child renderScale`
#
# The real shell frame on the shell mockup's mock services (offscreen, a sandbox copy, the global scale 1.25), silicon open with its tuning
# card beside it, in four states: the defaults (silicon 1.35, no detail key), `"silicon.detail": 1.2`, `"silicon": 1.0` with nothing
# else, and `"popup": 1.1` (an owner with no entry: its detail is the plain popup ratio, 1.1, and the main's too). Each is one run
# with the shell.json the shell's mock reads (the scale block). <out>/<state>.png are the stage (2880 x 1620), log.txt the DSCALE lines.
# The judge (the facts in each line): the primary's ratio is its own entry (or `popup`'s), the child's is `<owner>.detail` else `popup`'s
# -- never the parent's --, the child's box is its content x that ratio, the content as drawn is the same x the global scale, and the
# content's `renderScale` is the global scale x the child's ratio (the primary's the global x its own). Ends in DETAIL_SCALE RESULT PASS|FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# <out> defaults to a scratch dir, so the probe also runs bare (runner_noload_check runs every runner with no argument)
OUT="${1:-${SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}}/detail_scale_probe}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

if [ -n "${TREE:-}" ] && [ -z "${DSP_TREE_DONE:-}" ]; then
    T="$(cd "$TREE" && pwd)"
    mkdir -p "$T/tools/dev/qml"
    cp "$ROOT/tools/dev/detail_scale_probe.sh" "$T/tools/dev/"
    cp "$ROOT/tools/dev/qml/detail_scale_probe.qml" "$T/tools/dev/qml/"
    exec env DSP_TREE_DONE=1 TREE= "$T/tools/dev/detail_scale_probe.sh" "$OUT"
fi

if [ -z "${DSP_INNER:-}" ]; then
    own=0
    [ -z "${SANDBOX:-}" ] && own=1
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-detailscale}"
    "$ROOT/tools/dev/sandbox.sh" -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= DSP_INNER=1 \
        tools/dev/detail_scale_probe.sh "$OUT"
    rc=$?
    [ "$own" = 1 ] && rm -rf "$SANDBOX"
    exit $rc
fi

[ -e .git ] && { echo "DETAIL_SCALE RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
arm_py() {      # <file> <anchor> <replacement>: one exact anchor, or the runner fails as a gone anchor
    python3 - "$1" "$2" "$3" <<'PY' || { echo "DETAIL_SCALE RESULT FAIL (ARM ${ARM:-}: its anchor is gone in $1)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
oldlookup) arm_py modules/bar/gooey/GooeyBody.qml 'e.popupScales[body.isChild ? id + ".detail" : id]' 'e.popupScales[id]' ;;
norsbind) arm_py modules/bar/gooey/GooeyBody.qml 'body._wantsRenderScale = body.isChild &&' 'body._wantsRenderScale = false &&' ;;
"") ;;
*) echo "DETAIL_SCALE RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-ds.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gcc -shared -fPIC -O2 -o "$WORK/stillclock.so" tools/dev/sheet_stillclock.c -ldl || { echo "DETAIL_SCALE RESULT FAIL (no still clock)"; exit 1; }
python3 -B -c "import sys; sys.path.insert(0, 'tools/dev'); import sheet_render; sheet_render.png_gradient(sys.argv[1])" "$WORK/wall.png"
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done
cp tools/dev/qml/detail_scale_probe.qml mockups/zz_detail_scale.qml

# state = tag | the scale block's body (after "global") | POPUP_RATIO the mockup is given (its own env, as the host's frame gets it)
STATES=(
    'default|{}|1'
    'detail12|{"popups":{"silicon.detail":1.2}}|1'
    'silicon1|{"popups":{"silicon":1.0}}|1'
    'popup11|{}|1.1'
)
SCALE_K=1.25
: > "$OUT/log.txt"
for st in "${STATES[@]}"; do
    IFS='|' read -r tag blk pop <<< "$st"
    d="$WORK/$tag"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt"
    chmod 700 "$d/rt"
    printf '{"theme":"eva","mode":"light"}\n' > "$d/cfg/theme/state.json"
    # the scale block the mock shell reads (`popups`), with the global scale and popup ratio it is run at
    python3 -B - "$blk" "$SCALE_K" "$pop" > "$d/state/lares-shell-mock/config/shell.json" <<'PY'
import json, sys
blk = json.loads(sys.argv[1])
blk.update({"global": float(sys.argv[2]), "popup": float(sys.argv[3])})
print(json.dumps({"scale": blk}))
PY
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QML_DISABLE_DISTANCEFIELD=1 QT_HASH_SEED=0 QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        LARES_SLEEP_MONITOR=off MOCKUP_REPO= SHELL_SERVICES=mock WALL="file://$WORK/wall.png" ZOOM=1 \
        SCALE="$SCALE_K" BAR_RATIO=1 POPUP_RATIO="$pop" DS_OUT="$OUT" DS_TAG="$tag" \
        tools/dev/notifications_bus.sh timeout -k 5 300 env LD_PRELOAD="$WORK/stillclock.so" SHEET_NOW=1793199600 \
        quickshell -p mockups/zz_detail_scale.qml > "$d/log.txt" 2>&1
    grep -E "DSCALE|WARN|ERROR" "$d/log.txt" | grep -v "qt.qpa" >> "$OUT/log.txt"
    cp "$d/log.txt" "$OUT/run_$tag.log"
done

# a state whose run printed no measurement did not load: the kit's no-result verdict (result_lib), never "faults"
. tools/dev/result_lib.sh
for st in "${STATES[@]}"; do
    tag="${st%%|*}"
    if ! rl_has "$OUT/run_$tag.log" "DSCALE $tag"; then
        # an armed copy that did not load failed for the wrong reason: the arm proves nothing (runner_noload_check's arm pass)
        [ -n "${ARM:-}" ] && { echo "ARM $ARM: the armed copy did not load -- it proves nothing ($OUT/run_$tag.log)"; exit 1; }
        rl_noresult DETAIL_SCALE "$OUT/run_$tag.log"; exit 1
    fi
done

python3 -B - "$OUT/log.txt" <<'PY'
import re, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
K = 1.25
want = {            # tag: (primary ratio, child ratio)   -- what the rule says
    "default": (1.35, 1.0),
    "detail12": (1.35, 1.2),
    "silicon1": (1.0, 1.0),
    "popup11": (1.35, 1.1),
}
bad, lines = [], []
def kv(s):
    return dict(re.findall(r"(\w+)=(\S+)", s))
def wh(v):
    a, b = v.split("x")
    return float(a), float(b)
for tag, (wp, wc) in want.items():
    m = re.search(r"DSCALE %s (pop=[^\n]*)" % tag, log)
    if not m or "FAIL" in m.group(0):
        bad.append(f"{tag}: no measurement ({re.search(r'DSCALE ' + tag + r' FAIL[^\n]*', log).group(0) if re.search(r'DSCALE ' + tag + r' FAIL', log) else 'the run did not report'})")
        continue
    f = kv(m.group(1))
    p, c = float(f["primary"]), float(f["child"])
    lines.append(f"{tag}: primary {p}, child {wc and c} (want {wp} / {wc}); child box {f['cbox']}, content {f['ccontent']}, drawn {f['cdraw']}; renderScale primary {f['prs']} child {f['crs']}")
    if abs(p - wp) > 1e-3:
        bad.append(f"{tag}: primary ratio {p}, want {wp}")
    if abs(c - wc) > 1e-3:
        bad.append(f"{tag}: child ratio {c}, want {wc} (a child never takes its parent's)")
    cw, ch = wh(f["ccontent"])
    bw, bh = wh(f["cbox"])
    dw, dh = wh(f["cdraw"])
    # the drawn content is the content x the ratio x the global scale (stage px); the box is in frame px and carries the cutout band the engine writes
    if abs(dw - cw * c * K) > 1.5 or abs(dh - ch * c * K) > 1.5:
        bad.append(f"{tag}: child content drawn {dw:.1f}x{dh:.1f}, want {cw * c * K:.1f}x{ch * c * K:.1f} (its content x ratio x global)")
    if bw < cw * c - 1.5 or bw > cw * c + 40:
        bad.append(f"{tag}: child box {bw:.1f} wide for a content of {cw * c:.1f}")
    prs, crs = float(f["prs"]), float(f["crs"])
    if abs(crs - K * wc) > 1e-3:
        bad.append(f"{tag}: child renderScale {crs}, want {K * wc:.4f} (the global scale x its own ratio)")
    if abs(prs - K * wp) > 1e-3:
        bad.append(f"{tag}: primary renderScale {prs}, want {K * wp:.4f}")
    if f["dr"] == "-" or abs(float(f["dr"]) - wc) > 1e-3 or abs(float(f["drs"]) - K * wc) > 1e-3:
        bad.append(f"{tag}: engine.detailRatio {f['dr']} / detailRenderScale {f['drs']}, want {wc} / {K * wc:.4f}")
for n in re.findall(r"[^\n]*(?:Binding loop|Unable to assign|Cannot assign|non-existent|is not a type)[^\n]*", log):
    bad.append("warning: " + n.strip()[:200])
for l in lines:
    print(l)
for b in bad:
    print("FAIL " + b)
print(f"DETAIL_SCALE RESULT {'FAIL' if bad else 'PASS'} ({len(want)} states, {len(bad)} faults)")
sys.exit(1 if bad else 0)
PY
