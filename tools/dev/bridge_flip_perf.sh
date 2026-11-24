#!/usr/bin/env bash
# bridge_flip_perf.sh -- what a frame of the bridge's phone costs: at rest (its cached layer, something else animating),
# turning (traced live every frame) and lit (live, still). A measurement first, a gate second.
#
#   tools/dev/bridge_flip_perf.sh [outdir]      offscreen: unthrottled, so the render time is the whole cost of a frame
#   LOCK_ENV=<name> ENV=1 tools/dev/bridge_flip_perf.sh   in the nested Hyprland (a vsync-driven client): the exclusive tier,
#                                               machine to itself -- two frame-time runs at once measure neither
#   SCALE=1.25 (the user's)   PHASE_MS=2500   BUDGET_MS=5 (the turn's median render time; the gate)   COLD=1 (an empty
#   shader cache: the first frame's compile is printed)
#   ends in BRIDGE_FLIP_PERF RESULT PASS|FAIL
#
# TWO READINGS (tools/dev/qml/bridge_flip_perf.qml):
#   by a GRAB   a grab waits for the GPU, which a frame's own timing does not (offscreen every render reads 0 ms): the
#               median of 40 grabs of the phone at a new pose each (traced live), less the median of 40 grabs at rest
#               (the cached layer), is what tracing the phone costs per frame. THE GATE: under BUDGET_MS.
#   by GAPS     the frame gaps of each phase by the wall clock. A number only where a compositor paces the frames
#               (ENV=1): there the turn must not miss frames (no more than 2 gaps over 25 ms in the phase).
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=BRIDGE_FLIP_PERF
if [ -e .git ] && [ -z "${BFP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-body}"
    mkdir -p "$SCRATCH"
    plat=offscreen
    [ -n "${ENV:-}" ] && plat=wayland
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=$plat BFP_INNER=1 BFP_OUTARG="${1:-}" bash tools/dev/bridge_flip_perf.sh "$@"
fi
. tools/dev/result_lib.sh
ROOT=$(pwd)
OUT="${BFP_OUTARG:-${1:-${SCRATCH:-/tmp}/bridge-flip-perf}}"
mkdir -p "$OUT/cfg/theme" "$OUT/state" "$OUT/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/cfg/theme/state.json"
[ -n "${COLD:-}" ] && rm -rf "$OUT/cache" "$OUT/mesa" && mkdir -p "$OUT/cache" "$OUT/mesa"
log="$OUT/perf.log"
if [ -n "${ENV:-}" ]; then
    : "${LOCK_ENV:?ENV=1 needs LOCK_ENV=<name of at most 12 characters>}"
    started_env=0
    if ! tools/dev/lock_env.sh status | grep -q " up:"; then
        tools/dev/lock_env.sh up > "$OUT/lock_env_up.log" 2>&1 || { cat "$OUT/lock_env_up.log"; echo "$NAME RESULT FAIL (lock_env up)"; exit 1; }
        started_env=1
    fi
    cleanup() { [ "$started_env" = 1 ] && [ -z "${KEEP:-}" ] && tools/dev/lock_env.sh down > /dev/null 2>&1; }
    trap cleanup EXIT
    tools/dev/lock_env.sh run env QSG_RENDER_TIMING=1 QSG_INFO=1 SCALE="${SCALE:-1.25}" PHASE_MS="${PHASE_MS:-2500}" GRABS="${GRABS:-40}" SKIN="${SKIN:-}" \
        timeout 120 quickshell -n -p "$ROOT/tools/dev/qml/bridge_flip_perf.qml" > "$log" 2>&1 &
else
    env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QSG_RENDER_TIMING=1 QSG_INFO=1 XDG_CONFIG_HOME="$OUT/cfg" \
        XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" ${COLD:+MESA_SHADER_CACHE_DIR="$OUT/mesa"} \
        SCALE="${SCALE:-1.25}" PHASE_MS="${PHASE_MS:-2500}" GRABS="${GRABS:-40}" SKIN="${SKIN:-}" \
        timeout 120 quickshell -n -p tools/dev/qml/bridge_flip_perf.qml > "$log" 2>&1 &
fi
pid=$!
wait "$pid"
rl_clean "$log" > "$OUT/perf.clean.log"
grep -a -q "BFP done" "$OUT/perf.clean.log" || { cp "$log" "${SCRATCH:-/tmp}/bridge-flip-perf-noresult.log" 2> /dev/null; echo "$NAME RESULT FAIL (no result: ${SCRATCH:-/tmp}/bridge-flip-perf-noresult.log)"; exit 1; }
python3 -B - "$OUT/perf.clean.log" "${BUDGET_MS:-5}" "${SCALE:-1.25}" "${ENV:-}" <<'PY'
import re, sys
log, budget, scale, env = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
text = open(log, errors="replace").read()
ctx = re.search(r"OpenGL VENDOR: .*", text)
print("  context: %s  scale %s  %s" % (ctx.group(0) if ctx else "(not named)", scale, "nested compositor" if env else "offscreen"))
bad = []
phases = {m.group(1): tuple(int(v) for v in m.groups()[1:5]) for m in re.finditer(r"BFP phase (\w+) end frames=(-?\d+) gapMedian=(-?\d+) gapWorst=(-?\d+) over25=(-?\d+)", text)}
for name in ("rest", "turn", "lit"):
    if name in phases:
        f, med, worst, over = phases[name]
        print("  %-5s %4d frames   gap median %d ms   worst %d ms   %d over 25 ms" % (name, f, med, worst, over))
grabs = {m.group(1): tuple(int(v) for v in m.groups()[1:]) for m in re.finditer(r"BFP grab (\w+) n=(\d+) median=(\d+) best=(\d+) worst=(\d+)", text)}
if "rest" not in grabs or "turn" not in grabs:
    bad.append("no grab reading")
else:
    cost = grabs["turn"][1] - grabs["rest"][1]
    print("  one frame by a grab: at rest %d ms, turning %d ms (best %d / %d): tracing the phone costs %d ms" % (grabs["rest"][1], grabs["turn"][1], grabs["rest"][2], grabs["turn"][2], cost))
    if cost > budget:
        bad.append("tracing the phone costs %d ms a frame (budget %g)" % (cost, budget))
    if grabs["turn"][1] <= 0 and grabs["rest"][1] <= 0:
        bad.append("both grab medians read 0: nothing was measured")
if env and "turn" in phases and phases["turn"][3] > 2:
    bad.append("the turn missed frames: %d gaps over 25 ms" % phases["turn"][3])
print("BRIDGE_FLIP_PERF RESULT %s" % ("FAIL (" + "; ".join(bad) + ")" if bad else "PASS"))
sys.exit(1 if bad else 0)
PY
