#!/usr/bin/env bash
# bridge_body_probe.sh -- the bridge's phone body, held to its rules.
#
#   tools/dev/bridge_body_probe.sh [outdir]        offscreen (desktop GL, GLSL 120: the gates' context), scales 1, 1.25, 1.5625
#   SHIM=1 LOCK_ENV=<name> tools/dev/bridge_body_probe.sh   the NVIDIA path on this machine's Mesa: in the nested Hyprland with
#                                                  tools/dev/egl_nvidia_shim.c preloaded, so Qt takes OpenGL ES as in dGPU-only mode
#   ARM=<name|all>   hidden | nosnap | nogrid | nomatrix | nocache | leftclock   (offscreen)   novert (SHIM=1 only)
#   SCALES="1.25"    only these;   KEEP=1 keeps a SHIM run's nested Hyprland up
#   ends in BRIDGE_BODY RESULT PASS|FAIL
#
# WHAT IS JUDGED, per scale, on the real PhoneStage with a flat colour on each face (tools/dev/qml/bridge_body_probe.qml):
#   ink       the body itself draws (a comparison of two empty pictures passes anything)
#   same      the cached layer at rest and the body drawn live at the same pose are one picture, within 3 levels
#   edges     at rest the display's four straight edges are whole pixels: border, then face, nothing between -- with
#             the stage standing at OFFSET (default "10.3 7.7" design px: a corner between two device pixels, as a
#             popup's is), in the cached picture and in the live one
#   aligned   at every pose of a turn no pixel of a face touches the ground (a face that left its glass, or a body cut
#             off at the stage's edge with its face standing past the cut: the turning phone must stay inside the
#             stage) and the ground shows nowhere inside the body (a hole the face does not fill); never blank
#   back      after a real turn to the back the back's face is up and the front's is not drawn
#   still     at rest, with something else animating in the window, the body stays its cached picture and none of
#             its uniforms changes
# ARMS (each in a fresh sandbox copy; each must fail its own check): hidden (the body at opacity 0: ink), nosnap (the
# geometry not snapped to device pixels: edges), nogrid (the stage's content not moved onto the device grid: edges), nomatrix (the faces not carried by the turning body: aligned), nocache
# (the body never a layer: still), leftclock (a uniform left animating at rest: still), novert (under SHIM: the body
# without its own vertex stage links at GLSL ES 1.00 and draws nothing: ink).
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=BRIDGE_BODY
ARMS="hidden nosnap nogrid nomatrix nocache leftclock"
if [ -e .git ] && [ -z "${BBP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-body}"
    mkdir -p "$SCRATCH"
    plat=offscreen
    [ -n "${SHIM:-}" ] && plat=wayland
    run_inner() {
        env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
            QT_QPA_PLATFORM=$plat BBP_INNER=1 BBP_OUTARG="${1:-}" bash tools/dev/bridge_body_probe.sh "$@"
    }
    if [ "${ARM:-}" = all ]; then
        bad=0
        for a in $ARMS; do
            out=$(ARM=$a SCALES="${SCALES:-1.25}" run_inner "$SCRATCH/arm-$a" 2>&1)
            last=$(printf '%s\n' "$out" | grep -a "^$NAME RESULT" | tail -1)
            want=$(printf '%s\n' "$out" | grep -a -c "^  FAIL ${a_check:-}" || true)
            case "$a" in hidden) need="ink" ;; nosnap | nogrid) need="edges" ;; nomatrix) need="aligned" ;; *) need="still" ;; esac
            if printf '%s\n' "$last" | grep -q "RESULT FAIL" && printf '%s\n' "$out" | grep -a -q "^  FAIL $need"; then
                echo "  arm $a: failed as it must ($need)"
            else
                echo "  arm $a: DID NOT BITE -- $last"
                printf '%s\n' "$out" | tail -12 | sed 's/^/      /'
                bad=1
            fi
        done
        [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
        echo "$NAME ARMS FAIL"; exit 1
    fi
    run_inner "$@"
    exit $?
fi
. tools/dev/result_lib.sh
ROOT=$(pwd)
OUT="${BBP_OUTARG:-${1:-${SCRATCH:-/tmp}/bridge-body-probe}}"
mkdir -p "$OUT"
mode=offscreen
[ -n "${SHIM:-}" ] && mode=shim

# ---- arms: the fault goes into this sandbox copy (a copy has no .git), never the tree
arm_patch() {  # <file> <anchor> <replacement>
    python3 - "$1" "$2" "$3" <<'PY' || { echo "$NAME RESULT FAIL (arm anchor: $1)"; exit 2; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit("anchor matches %d times: %r" % (s.count(a), a))
open(p, "w").write(s.replace(a, b))
PY
}
if [ -n "${ARM:-}" ]; then
    [ -e .git ] && { echo "$NAME RESULT FAIL (ARM in a git tree)"; exit 2; }
    case "$ARM" in
        hidden)    arm_patch modules/bridge/body/BodyLayer.qml $'    id: fx\n' $'    id: fx\n    opacity: 0\n' ;;
        nosnap)    arm_patch modules/bridge/body/BodyGeometry.js $'function _snap(v, rs) {\n    return Math.round(v * rs) / rs;' $'function _snap(v, rs) {\n    return v + 0.37 / rs;' ;;
        nogrid)    arm_patch modules/bridge/body/PhoneStage.qml $'        x: stage._gx\n        y: stage._gy\n' '' ;;
        nomatrix)  arm_patch modules/bridge/body/PhoneStage.qml 'matrix: stage._moving ? stage._matrix(frontHost, false) : stage._still' 'matrix: stage._still' ;;
        nocache)   arm_patch modules/bridge/body/PhoneStage.qml 'cached: !(stage._moving || stage._lit)' 'cached: false' ;;
        leftclock) arm_patch modules/bridge/body/BodyLayer.qml $'    id: fx\n' $'    id: fx\n    NumberAnimation on lightSlideX { from: 0; to: 0.2; duration: 500; loops: Animation.Infinite }\n' ;;
        novert)    [ -n "${SHIM:-}" ] || echo "(ARM=novert only bites under SHIM=1: a desktop context never links the ES 1.00 variant)"
                   arm_patch modules/bridge/body/BodyLayer.qml $'    vertexShader: Qt.resolvedUrl("../shaders/bridge_body.vert.qsb")\n' '' ;;
        *) echo "unknown ARM=$ARM ($ARMS novert)"; exit 2 ;;
    esac
fi

mkdir -p "$OUT/cfg/theme" "$OUT/state" "$OUT/cache"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$OUT/cfg/theme/state.json"

shim=""
if [ "$mode" = shim ]; then
    cc -shared -fPIC -O2 -o "$OUT/egl_nvidia_shim.so" tools/dev/egl_nvidia_shim.c -ldl || { echo "$NAME RESULT FAIL (shim build)"; exit 1; }
    shim="LD_PRELOAD=$OUT/egl_nvidia_shim.so"
    : "${LOCK_ENV:?SHIM=1 needs LOCK_ENV=<name of at most 12 characters>}"
    started_env=0
    if ! tools/dev/lock_env.sh status | grep -q " up:"; then
        tools/dev/lock_env.sh up > "$OUT/lock_env_up.log" 2>&1 || { cat "$OUT/lock_env_up.log"; echo "$NAME RESULT FAIL (lock_env up)"; exit 1; }
        started_env=1
    fi
    cleanup() { [ "$started_env" = 1 ] && [ -z "${KEEP:-}" ] && tools/dev/lock_env.sh down > /dev/null 2>&1; }
    trap cleanup EXIT
fi
PROBE_QML="$ROOT/tools/dev/qml/bridge_body_probe.qml"

SCALES="${SCALES:-1 1.25 1.5625}"
[ "$mode" = shim ] && SCALES="${SCALES_SHIM:-1}"
for sc in $SCALES; do
    d="$OUT/s$sc"
    rm -rf "$d"; mkdir -p "$d"
    case "$mode" in
        offscreen) env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_INFO=1 XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
                       XDG_CACHE_HOME="$OUT/cache" OUTDIR="$d" SCALE="$sc" POSES="${POSES:-}" SKIN="${SKIN:-}" OFFSET="${OFFSET:-10.3 7.7}" \
                       timeout 180 quickshell -n -p tools/dev/qml/bridge_body_probe.qml > "$d/log" 2>&1 & ;;
        shim)      tools/dev/lock_env.sh run env $shim QSG_INFO=1 OUTDIR="$d" SCALE="$sc" POSES="${POSES:-}" SKIN="${SKIN:-}" OFFSET="${OFFSET:-10.3 7.7}" \
                       timeout 180 quickshell -n -p "$PROBE_QML" > "$d/log" 2>&1 & ;;
    esac
    pid=$!
    wait "$pid"
    if ! rl_clean "$d/log" | grep -a -q "BBP done"; then
        [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($d/log)"
        cp "$d/log" "${SCRATCH:-/tmp}/bridge-body-probe-noresult.log" 2> /dev/null
        echo "$NAME RESULT FAIL (no result: ${SCRATCH:-/tmp}/bridge-body-probe-noresult.log)"; exit 1
    fi
    rl_clean "$d/log" > "$d/clean.log"
done
first="$OUT/s$(echo $SCALES | cut -d' ' -f1)/clean.log"
echo "  context: $(grep -a -o 'OpenGL VENDOR: .*' "$first" | head -1) [mode=$mode]"
warn=$(cat "$OUT"/s*/clean.log | grep -a -E "WARN|ERROR" | grep -a -i -E "bridge|ShaderEffect|shader|PhoneStage|BodyLayer|CableStub" | head -5)

python3 -B - "$OUT" "$SCALES" "${ARM:-}" "$warn" <<'PY'
import math, os, re, sys
import numpy as np
from PIL import Image
from scipy import ndimage
out, scales, arm, warn = sys.argv[1], sys.argv[2].split(), sys.argv[3], sys.argv[4]
bad = []
def say(ok, check, text):
    print("  %s %s  %s" % ("ok  " if ok else "FAIL", check, text))
    if not ok:
        bad.append(check)
def load(d, name):
    p = os.path.join(d, name + ".png")
    if not os.path.exists(p):
        return None
    im = Image.open(p).convert("RGBA")
    bg = Image.new("RGBA", im.size, (0, 255, 0, 255))
    return np.asarray(Image.alpha_composite(bg, im).convert("RGB")).astype(np.int16)
# A skin with a slim border round its display (the fallback: 1.4 mm against the REDMAGIC's 2.2) has less body in the
# front's picture, and its far border closes under two pixels a little sooner in a turn.
SLIM = os.environ.get("SKIN", "") == "generic"
INK = 0.03 if SLIM else 0.05
EDGE_ON = 0.50 if SLIM else 0.42
def classes(a):
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    ground = (g > 200) & (r < 70) & (b < 70)
    front = (r > 170) & (b > 170) & (g < 150) & (np.abs(r - b) < 60)      # magenta, with the glass's glare over it
    back = (r > 200) & (g > 90) & (g < 175) & (b < 80)                    # orange
    return ground, front, back
for sc in scales:
    d = os.path.join(out, "s" + sc)
    log = open(os.path.join(d, "clean.log"), errors="replace").read()
    rest, live = load(d, "rest"), load(d, "live0")
    if rest is None or live is None:
        say(False, "ink", "scale %s: no rest / live0 picture" % sc)
        continue
    ground, front, back = classes(rest)
    body = ~ground & ~front & ~back
    share = body.mean()
    say(share > INK, "ink", "scale %s: the body covers %.3f of the picture (needs > %.2f)" % (sc, share, INK))
    # ---- same: the cached layer and the live body
    diff = np.abs(rest - live).max(axis=2)
    over = int((diff > 3).sum())
    say(over == 0, "same", "scale %s: cached vs live at rest: %d px over 3 levels (worst %d)" % (sc, over, int(diff.max())))
    # ---- edges: border, then face, nothing between, on the four straight edges of the display
    h, w = rest.shape[:2]
    mixed = []
    def cross(line, what):
        r, g, b = line[:, 0], line[:, 1], line[:, 2]
        face = (r > 170) & (b > 170) & (g < 150)
        idx = np.nonzero(face)[0]
        if len(idx) == 0:
            mixed.append(what + ": no face on this line")
            return
        for edge, i, j in ((" start", idx[0] - 1, idx[0]), (" end", idx[-1] + 1, idx[-1])):
            px, fx = line[i], line[j]
            if int(px.max()) > 96:                    # the border is black glass: a brighter pixel is a half-covered one
                mixed.append("%s%s at %d: border rgb %s" % (what, edge, i, tuple(int(v) for v in px)))
            if int(min(fx[0], fx[2])) < 246:          # and the face's own first pixel is all face
                mixed.append("%s%s at %d: face rgb %s" % (what, edge, j, tuple(int(v) for v in fx)))
    fy, fx = np.nonzero(front)
    if len(fy) == 0:
        mixed.append("no face in the rest picture")
    else:
        # in the cached picture AND in the live one: a layer is shown at the nearest pixel, so content that is off the
        # glass's grid is still crisp in it (only shifted) and soft only when the body is traced into the window
        cross(rest[int(np.median(fy)), :, :], "row")
        cross(rest[:, int(np.median(fx)), :], "column")
        cross(live[int(np.median(fy)), :, :], "live row")
        cross(live[:, int(np.median(fx)), :], "live column")
    say(not mixed, "edges", "scale %s: %s" % (sc, "the display's edges are whole pixels" if not mixed else "; ".join(mixed)))
    # ---- aligned: every pose of the turn
    poses = sorted(f[:-4] for f in os.listdir(d) if re.match(r"pose_\d+\.png$", f))
    pins = {m.group(1): float(m.group(2)) for m in re.finditer(r"BBP grab (\S+) saved pin=(-?[0-9.]+)", log)}
    touching, holes, blank, worst, judged = 0, 0, [], "", 0
    near = ndimage.generate_binary_structure(2, 2)
    for name in poses + ["back"]:
        a = load(d, name)
        if a is None:
            blank.append(name + " (no picture)")
            continue
        ground, front, back = classes(a)
        body = ~ground & ~front & ~back
        if body.mean() < 0.012:
            blank.append("%s (%.4f)" % (name, body.mean()))
        # nearly edge-on a face is a sliver whose rim is thinner than a pixel: it lies AT the silhouette by geometry
        # (and the display has closed to a mirror there). Those poses are judged for blankness only.
        turn = pins.get(name, 0.5)
        if turn >= 0 and abs(math.cos(2 * math.pi * turn)) < EDGE_ON:
            continue
        judged += 1
        grown = ndimage.binary_dilation(ground, structure=near, iterations=2)
        t = int((grown & (front | back)).sum())
        lab, n = ndimage.label(ground)
        edge = set(np.unique(np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]])))
        hole = sum(int((lab == i).sum()) for i in range(1, n + 1) if i not in edge)
        if t + hole > 0 and not worst:
            worst = "%s: %d face px at the ground, %d ground px inside the body" % (name, t, hole)
        touching += t
        holes += hole
    say(judged >= 6 and touching == 0 and holes == 0 and not blank, "aligned",
        "scale %s: %d poses, %d judged for place; %s%s" % (sc, len(poses), judged, worst or "each face on its glass, no hole unfilled",
                                      ("; blank: " + ", ".join(blank)) if blank else ""))
    # ---- back
    a = load(d, "back")
    if a is None:
        say(False, "back", "scale %s: no picture after the turn" % sc)
    else:
        ground, front, back = classes(a)
        say(back.mean() > 0.15 and front.sum() == 0 and "grab back saved" in log and "face=back" in log.split("grab back")[-1],
            "back", "scale %s: the back's face covers %.3f, the front's %d px" % (sc, back.mean(), int(front.sum())))
    # ---- still
    m = re.search(r"BBP still cached=(\w+) changes=(\d+) wentLive=(\d+) atRest=(\w+)", log)
    ok = bool(m) and m.group(1) == "true" and m.group(2) == "0" and m.group(3) == "0" and m.group(4) == "true"
    say(ok, "still", "scale %s: %s" % (sc, m.group(0)[4:] if m else "no reading (" + (re.search(r"BBP still FAIL.*", log) or re.search("", "")).group(0) + ")"))
if warn:
    say(False, "log", "warnings: " + warn.replace("\n", " | ")[:300])
if bad:
    print("BRIDGE_BODY RESULT FAIL (%s%s)" % ("ARM " + arm + ": " if arm else "", " ".join(sorted(set(bad)))))
    sys.exit(1)
print("BRIDGE_BODY RESULT PASS (%s%d scales)" % ("ARM " + arm + ": " if arm else "", len(scales)))
PY
