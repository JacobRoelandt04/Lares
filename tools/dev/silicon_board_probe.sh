#!/usr/bin/env bash
# silicon_board_probe.sh -- does the silicon BOARD draw, on the context the shell really gets?
#
#   tools/dev/silicon_board_probe.sh [outdir]       offscreen (desktop GL, GLSL 120: the gates' context)
#   SHIM=1 tools/dev/silicon_board_probe.sh          the NVIDIA path on this machine's Mesa: inside the nested Hyprland (tools/dev/lock_env.sh, LOCK_ENV
#                                                    name) with tools/dev/egl_nvidia_shim.c preloaded, so Qt sees EGL_VENDOR "NVIDIA" and takes
#                                                    OpenGL ES 3.2 as it does in dGPU-only mode. An agent's run; nothing opens on the desktop.
#   WAYLAND=1 tools/dev/silicon_board_probe.sh       THE USER'S, ONCE, in a dGPU-only boot: the session's own context, the real NVIDIA driver. It opens a
#                                                    window (a few seconds per variant, one after the other) on the desktop. AGENTS NEVER RUN THIS.
#   ARM=oldboard  (with SHIM=1)  the board without its own vertex shader again: Qt's built-in one, the GLSL ES 1.00 variant of the
#                                board -- must FAIL, naming the board variants that did not draw
#   ARM=hidden    the board layers invisible: the ink check reads zero and must FAIL
#   VARIANTS="cached uncached all"   only these (`all` = nothing hidden, the whole scene: the before / after sheets);  FAMILY=0|1;  MODE=light|dark;  SIZE=1|2;
#   KEEP=1 keeps a SHIM run's nested Hyprland up
#   ends in SILICON_BOARD RESULT PASS|FAIL
#
# WHAT IT DRAWS. The real SiliconScene's BoardLayers (the board, the CPU patch, the card's patch: the real textures, the scene's own uniforms at a rest
# pose) on an opaque magenta ground, with every part of the scene that is not a BoardLayer hidden -- the glows and holograms draw on any context, and the
# 2026-11-11 screenshot from dGPU-only mode showed exactly them without the board. One grab per variant; ink = the share of pixels that are not the
# ground (a grab on an opaque ground: coverage reads as colour, CLAUDE.md).
#   COUNTED (the verdict): cached (as the popup has it), uncached (no layer), forcecard (the card's patch over a seated card), patchoff (the board
#     draws the package itself) -- each must show the board's solid body.
#   DIAGNOSTIC (printed, never the verdict; the ladder that names the cause when a counted one is empty): nolod (the board pack with its two texture
#     reads returned as 0), noao (without its contact darkening), novert (the board with no vertex shader of its own: GLSL ES 1.00 on an ES
#     context), mech_flat / mech_bias / mech_lod / mech_loop (one cached layer: a flat colour; the silkscreen read with a bias; at an explicit level;
#     a 75-entry table indexed by a loop).
# READING A DRIVER'S RUN: a counted variant EMPTY and `nolod` drawing = the texture read; `noao` drawing = the table; `novert` empty while the
# board draws = the language level (the board's own vertex shader is what moves it to GLSL ES 3.00); mech_flat empty = layers themselves.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${SBP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-silicon-board}"
    mkdir -p "$SCRATCH"
    # a Wayland run keeps the session's runtime dir (sandbox.sh only privatises an offscreen one): the window opens where Hyprland puts it
    plat=offscreen
    [ -n "${WAYLAND:-}" ] && plat=wayland
    [ -n "${SHIM:-}" ] && plat=wayland
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=$plat SBP_INNER=1 SBP_OUTARG="${1:-}" bash tools/dev/silicon_board_probe.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=SILICON_BOARD
ROOT=$(pwd)
OUT="${SBP_OUTARG:-${1:-${SCRATCH:-/tmp}/silicon-board}}"
[ -n "$OUT" ] || { echo "$NAME RESULT FAIL (no outdir)"; exit 1; }
mkdir -p "$OUT"
QSB=/usr/lib/qt6/bin/qsb
COUNTED="${VARIANTS:-cached uncached forcecard patchoff}"
DIAG="nolod noao novert mech_flat mech_bias mech_lod mech_loop"
[ -n "${VARIANTS:-}" ] && DIAG=""
[ -n "${ARM:-}" ] && DIAG=""
mode=offscreen
[ -n "${WAYLAND:-}" ] && mode=wayland
[ -n "${SHIM:-}" ] && mode=shim

# ---- arms: the fault goes into this sandbox copy (a copy has no .git), never the tree
if [ -n "${ARM:-}" ]; then
    [ -e .git ] && { echo "$NAME RESULT FAIL (ARM in a git tree)"; exit 2; }
    case "$ARM" in
        oldboard)
            [ -n "${SHIM:-}" ] || echo "(ARM=oldboard only bites under SHIM=1: the desktop path never links the GLSL ES 1.00 variant)"
            python3 - modules/silicon/scene/BoardLayer.qml <<'PY' || { echo "$NAME RESULT FAIL (arm anchor)"; exit 2; }
import sys
p = sys.argv[1]; s = open(p).read()
a = '    vertexShader: Qt.resolvedUrl("../shaders/silicon_board.vert.qsb")\n'
if s.count(a) != 1: sys.exit("anchor: %d" % s.count(a))
open(p, "w").write(s.replace(a, ""))
PY
            ;;
        hidden)
            python3 - modules/silicon/scene/BoardLayer.qml <<'PY' || { echo "$NAME RESULT FAIL (arm anchor)"; exit 2; }
import sys
p = sys.argv[1]; s = open(p).read()
a = "    id: fx\n"
if s.count(a) != 1: sys.exit("anchor: %d" % s.count(a))
open(p, "w").write(s.replace(a, a + "    opacity: 0\n"))
PY
            ;;
        *) echo "unknown ARM=$ARM (oldboard|hidden)"; exit 2 ;;
    esac
fi

# ---- the diagnostic packs, baked here from the committed sources: the board with no texture reads / no contact darkening, and the ladder's rungs
PACKS="$OUT/packs"
mkdir -p "$PACKS"
python3 - "$ROOT" "$PACKS" <<'PY' || { echo "$NAME RESULT FAIL (variant sources)"; exit 1; }
import re, sys
root, out = sys.argv[1:3]
src = open(root + "/modules/silicon/shaders/silicon_board.frag").read()
# no texture reads: both `textureLod(<sampler>, <uv>, <lod>)` calls (silkSd, glyphSample) answer 0
nolod, n = re.subn(r"textureLod\((?:silk|glyphs),[^;]*?\)\.rgb;", "vec3(0.0);", src)
if n != 2:
    sys.exit("nolod: %d texture reads, wanted 2" % n)
open(out + "/silicon_board_nolod.frag", "w").write(nolod)
# no contact darkening: sceneAo answers 1
m = re.search(r"vec2 sceneAo\(vec2 p, vec2 sh, int lvl, int two\) \{.*?\n\}\n", src, re.S)
if not m:
    sys.exit("noao: sceneAo not found")
open(out + "/silicon_board_noao.frag", "w").write(src[:m.start()] + "vec2 sceneAo(vec2 p, vec2 sh, int lvl, int two) {\n    return vec2(1.0);\n}\n" + src[m.end():])
PY
for f in "$PACKS"/silicon_board_*.frag "$ROOT"/tools/dev/qml/board_probe_shaders/*.frag; do
    b=$(basename "$f")
    per=""
    grep -q QSHADER_ "$f" && per=-p
    "$QSB" $per --glsl "100 es,120,150,300 es" --hlsl 50 --msl 12 -o "$PACKS/$b.qsb" "$f" > "$PACKS/$b.bake.log" 2>&1 \
        || { echo "bake of $b failed:"; head -5 "$PACKS/$b.bake.log"; echo "$NAME RESULT FAIL (bake $b)"; exit 1; }
done
mkdir -p "$OUT/cfg/theme"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$OUT/cfg/theme/state.json"

# ---- the context
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

# the nested session starts in its own folder, so the shim run names the harness by absolute path -- in THIS copy (the re-exec above
# put every run in a sandbox copy; the tree itself never starts a quickshell)
PROBE_QML="$ROOT/tools/dev/qml/silicon_board_probe.qml"
run_variant() {  # <variant> -> $OUT/<variant>.png and .log
    local v="$1" log="$OUT/$1.log"
    find "$OUT" -maxdepth 1 -name "$v.png" -delete
    case "$mode" in
        offscreen) env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_INFO=1 XDG_CONFIG_HOME="$OUT/cfg" \
                       VARIANT="$v" OUT="$OUT/$v.png" PACKDIR="$PACKS" FAMILY="${FAMILY:-0}" SIZE="${SIZE:-1}" \
                       timeout 120 quickshell -n -p tools/dev/qml/silicon_board_probe.qml > "$log" 2>&1 ;;
        shim)      tools/dev/lock_env.sh run env $shim QSG_INFO=1 VARIANT="$v" OUT="$OUT/$v.png" PACKDIR="$PACKS" FAMILY="${FAMILY:-0}" SIZE="${SIZE:-1}" \
                       timeout 120 quickshell -n -p "$PROBE_QML" > "$log" 2>&1 ;;
        wayland)   env QT_QPA_PLATFORM=wayland QSG_INFO=1 XDG_CONFIG_HOME="$OUT/cfg" \
                       VARIANT="$v" OUT="$OUT/$v.png" PACKDIR="$PACKS" FAMILY="${FAMILY:-0}" SIZE="${SIZE:-1}" \
                       timeout 120 quickshell -n -p tools/dev/qml/silicon_board_probe.qml > "$log" 2>&1 ;;
    esac
}
for v in $COUNTED $DIAG; do
    run_variant "$v"
    [ -f "$OUT/$v.png" ] || echo "  $v: no picture ($(rl_clean "$OUT/$v.log" | grep -a -E 'SBP FAIL|ERROR|Failed' | head -2 | tr '\n' ' '))"
done

# ---- a harness that never loaded is no result, never an empty board (the no-load law: a QML that did not load says so)
for v in $COUNTED; do
    if ! rl_clean "$OUT/$v.log" | grep -a -q "SBP "; then
        [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($OUT/$v.log)"
        echo "$NAME RESULT FAIL (no result: $OUT/$v.log)"; exit 1
    fi
done

# ---- the context named, then the pictures judged
first="$OUT/$(echo $COUNTED | cut -d' ' -f1).log"
ctx=$(rl_clean "$first" | grep -a -o "OpenGL VENDOR: .*" | head -1)
fmt=$(rl_clean "$first" | grep -a -o "Created OpenGL context QSurfaceFormat(version [0-9.]*" | head -1 | sed 's/.*(//')
echo "  context: ${ctx:-(no GL context named)}  [$fmt, mode=$mode]"
case "$ctx" in
    *"OpenGL ES"*) echo "  GLSL linked: the board (its own vertex shader) 300 es; novert and mech_* (Qt's built-in vertex shader) 100 es   [inferred: Qt links at the highest ES version every stage has]" ;;
    *) echo "  GLSL linked: desktop GL (the 120 / 150 variants); no ES variant runs on this context" ;;
esac
python3 -B - "$OUT" "$COUNTED" "$DIAG" "${ARM:-}" <<'PY'
import os, sys
from PIL import Image
out, counted, diag, arm = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4]
GROUND = (255, 0, 255)
MIN_INK = 0.12          # the board's body covers ~0.3 of the window; a context that lost it shows nothing but the ground (< 0.01)
def ink(v):
    p = os.path.join(out, v + ".png")
    if not os.path.exists(p):
        return None
    im = Image.open(p).convert("RGBA")
    bg = Image.new("RGBA", im.size, GROUND + (255,))
    im = Image.alpha_composite(bg, im).convert("RGB")
    px = im.load(); w, h = im.size; n = 0; tot = 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            tot += 1
            if abs(r - GROUND[0]) + abs(g - GROUND[1]) + abs(b - GROUND[2]) > 12:
                n += 1
    return n / max(1, tot)
bad = []
for v in counted + diag:
    f = ink(v)
    kind = "counted" if v in counted else "diag"
    if v.startswith("mech_"):
        word = "-" if f is None else ("draws" if f > 0.02 else "EMPTY")
    else:
        word = "no picture" if f is None else ("draws" if f >= MIN_INK else "EMPTY")
    print("  %-10s ink %s  %s%s" % (v, "-" if f is None else "%.3f" % f, word, "  (diagnostic)" if kind == "diag" else ""))
    if v in counted and (f is None or f < MIN_INK):
        bad.append(v)
if bad:
    print("SILICON_BOARD RESULT FAIL (the board's solid body is missing in: %s)" % " ".join(bad))
    sys.exit(1)
print("SILICON_BOARD RESULT PASS (%s: the solid body drawn in %d variants)" % ("ARM " + arm if arm else "ok", len(counted)))
PY
exit $?
