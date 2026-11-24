#!/usr/bin/env bash
# setup.sh -- dictation's one-time setup, the user's step (docs/dictation.md). Nothing needs root and nothing is installed
# system-wide: a private Python environment, the picked model, the input method.
#
#   tools/stt/setup.sh            1 the venv at ~/.local/share/lares/stt/venv (uv, the system Python), 2 the packages of
#                                 requirements.txt into it and cuDNN, 3 the models `auto` may use on the iGPU, the CPU and the
#                                 NVIDIA card, and the tidy pass's model (fetch.py pick), 4 lares-ime (ime/build.sh)
#   tools/stt/setup.sh --clips    also the FLEURS test clips the bench and the probe use (~40 MB)
#
# Every step prints `ok <step>` or `FAIL <step>`; the exit status is the number of FAILs.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
venv="${LARES_STT_VENV:-$HOME/.local/share/lares/stt/venv}"
export LARES_STT_HOME="${LARES_STT_HOME:-$HOME/.cache/lares-stt}"
fails=0
step() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi; }

command -v uv > /dev/null || { echo "FAIL uv is not installed (pacman -S uv)"; exit 1; }
mkdir -p "$(dirname "$venv")" "$LARES_STT_HOME"
[ -x "$venv/bin/python" ] || step "venv $venv" uv venv --python /usr/bin/python3 "$venv"
# A venv made under the old name (~/.local/share/quickshell/stt/venv) names that path in the shebangs and activate scripts of its bin/
# (a venv is not relocatable); `lares migrate-name` moved it and leaves a symlink there until `lares cleanup-old-name`, which refuses
# while they still name it. Rewrite the old path to the venv's own in those text files: the packages stay, nothing is downloaded again.
old_venv="$HOME/.local/share/quickshell/stt/venv"
venv_paths() {
    local f
    for f in "$venv"/bin/*; do
        [ -f "$f" ] && [ ! -L "$f" ] && grep -Iq -- "$old_venv" "$f" && { sed -i "s|$old_venv|$venv|g" "$f" || return 1; }
    done
    ! grep -rIlq -- "$old_venv" "$venv/bin"
}
[ "$venv" != "$old_venv" ] && grep -rIlq -- "$old_venv" "$venv/bin" 2> /dev/null && step "venv paths (the old name out of bin/)" venv_paths
export UV_CACHE_DIR="$LARES_STT_HOME/uv-cache"
# onnxruntime-gpu replaces the CPU-only onnxruntime of a venv made before round 4 (both are the module `onnxruntime`)
"$venv/bin/python" -c 'import importlib.metadata as m; m.version("onnxruntime")' 2> /dev/null \
    && step "onnxruntime (CPU) out" uv pip uninstall --python "$venv/bin/python" onnxruntime
step "packages" uv pip install --python "$venv/bin/python" -r "$here/requirements.txt"
# cuDNN for the NVIDIA card (~1 GB), without the pip copies of CUDA's libraries: /opt/cuda's (Arch `cuda`) serve
step "cudnn" uv pip install --python "$venv/bin/python" --no-deps nvidia-cudnn-cu13==9.28.1.4
ldconfig -p 2> /dev/null | grep -q 'libcublas.so.13 ' || echo "note: no CUDA 13 libraries (pacman -S cuda): takes stay on the iGPU"
rm -rf "$LARES_STT_HOME/uv-cache"
step "models" "$venv/bin/python" -I "$here/fetch.py" pick
[ "${1:-}" = --clips ] && step "clips" "$venv/bin/python" -I "$here/fetch.py" clips
step "lares-ime" "$here/ime/build.sh"
exit $fails
