#!/usr/bin/env bash
# aerial_globe_cost.sh -- what the globe costs to compile and to draw (the tunnel is gone, round 3) (a measurement, not a gate): the compiler's instruction counts and spills for its fragment
# shader (Mesa iris, INTEL_DEBUG=fs, cache off), the cold first frame (Mesa's shader cache off) against a warm one and against the same window without the effect, and the
# frames presented while nothing moves. OFFSCREEN: sandbox copy, platform forced on the launch, private homes and a private Mesa cache dir.
#   tools/dev/aerial_globe_cost.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${AGC_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-aerial-cost}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AGC_INNER=1 bash tools/dev/aerial_globe_cost.sh "$@"
fi
. tools/dev/result_lib.sh
NAME=AERIAL_GLOBE_COST
W="${SCRATCH:-/tmp}/aerial-cost"; rm -rf "$W"; mkdir -p "$W/cfg/theme" "$W/cache" "$W/state" "$W/mesa"
printf '{"theme":"eva","mode":"light"}\n' > "$W/cfg/theme/state.json"
run() {  # <label> <extra env...>: prints the run's COST lines
    local label="$1"; shift
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$W/cfg" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state" "$@" \
        timeout 120 quickshell -n -p tools/dev/qml/aerial_globe_cost.qml > "$W/$label.log" 2>&1
    rl_clean "$W/$label.log" | grep -a "COST " | sed 's/^.*COST /COST /' | sed "s/^/  $label: /"
}
echo "  -- cold (Mesa's shader cache off), without the effects, then with it"
run bare-cold BARE=1 MESA_SHADER_CACHE_DISABLE=true
run full-cold MESA_SHADER_CACHE_DISABLE=true
echo "  -- warm (a private cache dir, run twice)"
run full-warm0 MESA_SHADER_CACHE_DIR="$W/mesa"
run full-warm1 MESA_SHADER_CACHE_DIR="$W/mesa"
echo "  -- the compiler's counts (INTEL_DEBUG=fs): the lines of the fragment shaders the effect adds"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$W/cfg" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state" MESA_SHADER_CACHE_DISABLE=true INTEL_DEBUG=fs \
    timeout 120 quickshell -n -p tools/dev/qml/aerial_globe_cost.qml 2>&1 | grep -a -E "^(SIMD|Native code for|.*shader: [0-9]+ instructions)" | grep -a -E "SIMD[0-9]+ shader" > "$W/full.counts"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$W/cfg" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state" MESA_SHADER_CACHE_DISABLE=true INTEL_DEBUG=fs BARE=1 \
    timeout 120 quickshell -n -p tools/dev/qml/aerial_globe_cost.qml 2>&1 | grep -a -E "SIMD[0-9]+ shader" > "$W/bare.counts"
echo "  fragment shaders compiled with the effect: $(wc -l < "$W/full.counts"), without: $(wc -l < "$W/bare.counts")"
comm -13 <(sort "$W/bare.counts") <(sort "$W/full.counts") | sed 's/^/  added: /'
echo "$NAME RESULT PASS (a measurement: read the numbers above)"
