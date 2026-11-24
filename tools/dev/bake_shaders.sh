#!/usr/bin/env bash
# bake_shaders.sh -- compile the shell's fragment shaders to .qsb.
#
# Qt Quick loads a ShaderEffect's `fragmentShader` as a .qsb (a compiled
# shader pack), not as GLSL, so every .frag under
# modules/common/components/shaders/ has a .qsb beside it that must be
# regenerated whenever the .frag changes.  Forgetting is silent: Qt keeps
# using the stale pack and the change simply does not appear.
#
#   tools/dev/bake_shaders.sh                # rebake every .frag that is stale
#   tools/dev/bake_shaders.sh vinyl_disc     # rebake just the ones that match
#   tools/dev/bake_shaders.sh --all          # rebake everything, stale or not
#
# The targets are --qt6's (GLSL 100 es/120/150, HLSL 5.0, MSL 1.2) plus GLSL 300 es.
# This machine runs the GL RHI backend, so the GLSL outputs are the ones that get
# used, and WHICH one depends on the context Qt gets: desktop GL on the Intel GPU
# (4.6 compatibility on Wayland: 150; 2.0 offscreen: 120), but OpenGL ES 3.2 on
# the NVIDIA GPU in dGPU-only mode (2026-10-11: "OpenGL ES 3.2 NVIDIA 615.71.09";
# Qt's EGL config chooser takes GLES on purpose when the EGL vendor is NVIDIA,
# qeglconvenience.cpp: "NVIDIA EGL only provides desktop GL for development").
# WHICH ES VARIANT: Qt 6.12 links a pipeline at the highest GLSL ES version that
# EVERY stage has (QRhiGles2::commonGlslEsVersion: GLSL ES cannot link two
# versions). A ShaderEffect with a vertex shader of its own (the gooey field)
# links at 300 es; one without takes Qt Quick's built-in shadereffect.vert, which
# carries 100 es / 120 / 150 only -- so on NVIDIA every such effect compiles its
# 100 es variant, whatever else its pack holds. Both are needed, and both must
# be valid for their version: NVIDIA refuses what GLSL ES 1.00 forbids (an array
# constructor or a constant array, C7516 / C7553; an integer clamp / min / max,
# C7011), where Mesa takes it. 2026-11-10: the silicon board, the vinyl, the
# weather glyphs and backdrop and the network glyph drew nothing that way.
#
# PER TARGET. A source that names QSHADER_ (qsb's per-target macros:
# QSHADER_GLSL, QSHADER_GLSL_VERSION, QSHADER_GLSL_ES, QSHADER_HLSL, ...) is
# compiled once per target (`qsb -p`), so its ES 1.00 variant can take a form of
# its own (`#if defined(QSHADER_GLSL_ES) && QSHADER_GLSL_VERSION < 300`: a table
# filled element by element where the others keep a constant array). For an
# unchanged source a per-target bake is the same pack byte for byte.
#
# VARIANTS. A source that says `// QSB-VARIANT: <name> <MACRO>` is baked a second
# time with MACRO defined, into <name>.<stage>.qsb beside it (the gooey field's
# REEL_PASS: gooey_reel.frag.qsb, the same source and uniform block drawn by a
# second ShaderEffect). The plain pack is baked exactly as before: code behind
# an #ifdef nobody defines is the same SPIR-V, and the same bytes.
#
# THE CHECKS, over every pack, built or not: the uniform blocks of a pair
# match; every pack has a 300 es variant; every GLSL variant is valid for its
# stage and version (tools/dev/shader_glslang_gate.sh, glslang offline: what a
# strict driver refuses fails the bake here, with no GPU).
set -uo pipefail

QSB=/usr/lib/qt6/bin/qsb
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The shared shaders, and the ones a module keeps beside its own QML.
DIRS=("$ROOT/modules/common/components/shaders" "$ROOT/modules/lockscreen/shaders" "$ROOT/modules/silicon/shaders" "$ROOT/modules/aerial/shaders" "$ROOT/modules/notifications/shaders" "$ROOT/modules/bridge/shaders" "$ROOT/modules/theme/shaders" "$ROOT/modules/bar/player/components/shaders" "$ROOT/modules/weather/shaders" "$ROOT/modules/idle/sleep/shaders" "$ROOT/modules/bar/gooey/shaders" "$ROOT/modules/wiki/shaders")

[[ -x "$QSB" ]] || { echo "FAIL: $QSB missing (pacman -S qt6-shadertools)"; exit 1; }

force=0
pattern=""
for a in "$@"; do
    case "$a" in
        --all) force=1 ;;
        *) pattern="$a" ;;
    esac
done

rc=0
built=0
skipped=0
# Vertex shaders too: a ShaderEffect with a GridMesh places its own vertices
# (the gooey field's tiles), and a stale .vert.qsb is just as silent.
shaders=()
for d in "${DIRS[@]}"; do shaders+=("$d"/*.frag "$d"/*.vert); done
for frag in "${shaders[@]}"; do
    [[ -e "$frag" ]] || continue
    # the pack itself, then one per `// QSB-VARIANT: <name> <MACRO>` line (VARIANTS, above)
    targets=("$(basename "$frag")|")
    while read -r vname vmacro; do
        [[ -n "$vname" && -n "$vmacro" ]] && targets+=("$vname.${frag##*.}|$vmacro")
    done < <(sed -n 's|^// QSB-VARIANT: *\([A-Za-z0-9_]*\) *\([A-Za-z0-9_]*\) *$|\1 \2|p' "$frag")
  for target in "${targets[@]}"; do
    name="${target%%|*}"
    macro="${target#*|}"
    [[ -n "$pattern" && "$name" != *"$pattern"* ]] && continue
    out="$(dirname "$frag")/$name.qsb"
    def=()
    [[ -n "$macro" ]] && def=(-D "$macro")
    # a shader that #includes a .glsl beside it is as stale as that file
    newer=""
    while read -r inc; do
        [[ -f "$(dirname "$frag")/$inc" && "$(dirname "$frag")/$inc" -nt "$out" ]] && newer=1
    done < <(sed -n 's/^#include "\(.*\)"$/\1/p' "$frag")
    if [[ $force -eq 0 && -z "$newer" && -f "$out" && "$out" -nt "$frag" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    # per target when the source (or a file it includes) asks for the per-target macros
    per=()
    grep -q "QSHADER_" "$frag" && per=(-p)
    while read -r inc; do
        [[ -f "$(dirname "$frag")/$inc" ]] && grep -q "QSHADER_" "$(dirname "$frag")/$inc" && per=(-p)
    done < <(sed -n 's/^#include "\(.*\)"$/\1/p' "$frag")
    # a source that says `// QSB-NO-100ES: <why>` has no GLSL ES 1.00 variant: its pipeline always links at 300 es (the silicon board, which has a vertex
    # shader of its own), and a 100 es variant of a per-target source is a trap -- its uniform struct is named by a SPIR-V id that differs from the
    # reflection's, so Qt finds no uniform and the effect draws with every one at 0 (tools/dev/shader_glslang_gate.sh)
    glsl="100 es,120,150,300 es"
    grep -q "^// QSB-NO-100ES:" "$frag" && glsl="120,150,300 es"
    if err=$("$QSB" "${per[@]}" "${def[@]}" --glsl "$glsl" --hlsl 50 --msl 12 -o "$out" "$frag" 2>&1); then
        echo "ok    $name${per[*]:+ (per target)}${macro:+ ($(basename "$frag") with $macro)}"
        built=$((built + 1))
    else
        echo "FAIL  $name"
        echo "$err" | sed 's/^/        /'
        rc=1
    fi
  done
done

# A ShaderEffect's two stages must declare the SAME uniform block: a member
# added to the .frag only shifts every later one in the .vert, silently
# (tools/dev/shader_ubo_match.py; the gooey veil's blobs stopped merging that way).
if ! ubo=$(python3 "$ROOT/tools/dev/shader_ubo_match.py" "${DIRS[@]}" 2>&1); then
    echo "$ubo" | grep -v 'RESULT' | sed 's/^/FAIL  /'
    rc=1
fi

# Every pack carries a GLSL 300 es variant (see the targets above: without it NVIDIA's ES 3.2 context gets the 100 es one and
# refuses it).
missing=()
for d in "${DIRS[@]}"; do
    for q in "$d"/*.qsb; do
        [[ -e "$q" ]] || continue
        # grep reads to the end (no -q): quitting at the first match kills qsb with SIGPIPE, and under pipefail that is a failure
        "$QSB" --dump "$q" 2>/dev/null | grep "^ *Shader [0-9]*: GLSL 300 es" > /dev/null || missing+=("$(basename "$q")")
    done
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "FAIL  no GLSL 300 es variant: ${missing[*]} (rebake: tools/dev/bake_shaders.sh --all)"
    rc=1
fi

# Every GLSL variant of every pack is valid for its stage and version (glslang; the gate's own lines, prefixed).
packs=()
for d in "${DIRS[@]}"; do for q in "$d"/*.qsb; do [[ -e "$q" ]] && packs+=("$q"); done; done
# (ARM is the gate's own switch, never a caller's: a bake run under some other runner's ARM= must not arm the gate)
if ! gl=$(env -u ARM -u _GLSLANG_ARM_COPY bash "$ROOT/tools/dev/shader_glslang_gate.sh" "${packs[@]}" 2>&1); then
    echo "$gl" | grep -v 'RESULT PASS' | sed "s|$ROOT/||; s/^/FAIL  /"
    rc=1
fi
echo "BAKE built=$built up-to-date=$skipped $([[ $rc -eq 0 ]] && echo PASS || echo FAIL)"
exit $rc
