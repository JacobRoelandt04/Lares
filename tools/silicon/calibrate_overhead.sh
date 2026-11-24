#!/usr/bin/env bash
# calibrate_overhead.sh -- measure silicon's two overhead coefficients on THIS laptop, ON BATTERY.
#
#   tools/silicon/calibrate_overhead.sh            the user runs it, unplugged, the machine otherwise idle (~12 min)
#   DRY=1 SECONDS_PER=10 tools/silicon/...         a plumbing check that may run plugged in (offscreen, numbers
#                                                  meaningless): every step runs, the fit is printed, nothing advised
#
# WHAT IT MEASURES. The popup's battery strip shows the machine's draw WITHOUT the cost of looking at it: the
# shell's own CPU and GPU time per second, times two coefficients (silicon.jsonc `overhead.wPerCpuSec`,
# `wPerGpuSec`; OverheadMeter.qml). This finds those coefficients: it alternates stretches with nothing drawn
# (baselines) and stretches with the whole popup drawn at a steady rate (tools/dev/qml/silicon_perf_probe.qml, SCOPE=popup:
# alive at 1x and 2x pixels -- the GPU's share changes, the CPU's hardly -- and calm), reads the pack's
# `power_now` once a second and the popup process's CPU ticks and DRM render time between its steady marks, and
# fits  extra watts = a * CPU-seconds/s + b * GPU-seconds/s  over the three stretches (least squares, a and b >= 0;
# each stretch's extra watts is its mean minus the mean of the baselines either side, which cancels a slow drift).
#
# ON SCREEN, not offscreen: in the real shell every frame of the popup's window is also composited by Hyprland,
# and that is power too. The window appears for the length of each stretch; leave the machine alone meanwhile
# (no typing, no video, no other load: every watt of it lands in the fit). Nothing is written: the result is
# printed with the silicon.jsonc lines to paste.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
SEC="${SECONDS_PER:-90}"
BAT="${BAT:-/sys/class/power_supply/BAT0}"
AC="${AC:-/sys/class/power_supply/AC0/online}"
OUT="${OUT:-${TMPDIR:-/tmp}/silicon-calibrate-$$}"
mkdir -p "$OUT/cfg/xdg/theme" "$OUT/cfg/state"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/cfg/xdg/theme/state.json"
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-silicon-calibrate}"

if [ "$(cat "$AC" 2> /dev/null)" = 1 ] && [ -z "${DRY:-}" ]; then
    echo "The charger is in: unplug it (the pack's draw is what this measures), then run this again."
    exit 2
fi
[ -r "$BAT/power_now" ] || { echo "no $BAT/power_now to read"; exit 2; }
if [ -n "${DRY:-}" ]; then
    PLATFORM=(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi)
    echo "DRY: offscreen, the numbers mean nothing; checking that every step runs."
else
    PLATFORM=(env QT_QUICK_BACKEND=rhi)
    echo "About $(( (SEC + 15) * 7 / 60 )) minutes. Leave the machine idle; a window comes and goes."
fi
node tools/dev/silicon_shader_gen.js --check > "$OUT/gen.log" 2>&1 || { cat "$OUT/gen.log"; echo "stale shaders"; exit 1; }
exec 9> /tmp/lrlk-veilgpu.lock
flock 9

watts() {  # one power_now reading, W
    awk '{ printf "%.4f\n", $1 / 1e6 }' "$BAT/power_now"
}
cpu_ticks() {
    python3 -c "import sys; f = open('/proc/%s/stat' % sys.argv[1]).read().rsplit(')', 1)[1].split(); print(int(f[11]) + int(f[12]))" "$1" 2> /dev/null || echo 0
}
baseline() {  # name -> SEC seconds of readings with nothing drawn
    : > "$OUT/$1.w"
    for _ in $(seq 1 "$SEC"); do watts >> "$OUT/$1.w"; sleep 1; done
}
stretch() {  # name level size -> readings + the process's cpu ticks and render ns over its steady window
    local name="$1" level="$2" size="$3" log="$OUT/$1.log" top pid c0 c1 s0 s1
    : > "$OUT/$name.w"
    "${PLATFORM[@]}" LARES_SLEEP_MONITOR=off XDG_CONFIG_HOME="$OUT/cfg/xdg" XDG_STATE_HOME="$OUT/cfg/state" \
        SCOPE=popup LEVEL="$level" SIZE="$size" FAMILY=0 SECONDS="$SEC" \
        tools/dev/sandbox.sh timeout $(( SEC + 120 )) quickshell -p tools/dev/qml/silicon_perf_probe.qml > "$log" 2>&1 &
    top=$!
    pid=""
    for _ in $(seq 1 600); do
        pid=$(grep -a -o "SILICON_PERF pid=[0-9]*" "$log" | head -1 | cut -d= -f2)
        [ -n "$pid" ] && break
        kill -0 "$top" 2> /dev/null || break
        sleep 0.05
    done
    [ -n "$pid" ] || { kill "$top" 2> /dev/null; wait "$top" 2> /dev/null; echo "$name: the probe did not start (see $log)"; return 1; }
    until grep -aq "SILICON_PERF steady start" "$log"; do kill -0 "$top" 2> /dev/null || break; sleep 0.02; done
    s0=$(python3 tools/silicon/gpu_sample.py "$pid"); c0=$(cpu_ticks "$pid")
    while ! grep -aq "SILICON_PERF steady end" "$log" && kill -0 "$top" 2> /dev/null; do
        watts >> "$OUT/$name.w"
        sleep 1
    done
    s1=$(python3 tools/silicon/gpu_sample.py "$pid"); c1=$(cpu_ticks "$pid")
    wait "$top" 2> /dev/null
    printf '%s\n%s\n%s\n%s\n' "$c0" "$c1" "$s0" "$s1" > "$OUT/$name.proc"
}

baseline b0
stretch alive1 alive 1 || exit 1
baseline b1
stretch alive2 alive 2 || exit 1
baseline b2
stretch calm1 calm 1 || exit 1
baseline b3

python3 - "$OUT" "$SEC" "${DRY:-}" <<'PY'
import json, os, statistics, sys
out, sec, dry = sys.argv[1], int(sys.argv[2]), sys.argv[3] != ""
tck = os.sysconf("SC_CLK_TCK")
def readings(n):
    return [float(x) for x in open(f"{out}/{n}.w").read().split()]
def mean_se(xs):
    if len(xs) < 2:
        return (xs[0] if xs else 0.0), 0.0
    return statistics.fmean(xs), statistics.stdev(xs) / len(xs) ** 0.5
rows = []
for name, before, after in (("alive1", "b0", "b1"), ("alive2", "b1", "b2"), ("calm1", "b2", "b3")):
    pw, pse = mean_se(readings(name))
    b = readings(before) + readings(after)
    bw, bse = mean_se(b)
    c0, c1, s0, s1 = open(f"{out}/{name}.proc").read().split("\n")[:4]
    s0, s1 = json.loads(s0), json.loads(s1)    # tools/silicon/gpu_sample.py: {t, render_ns, ...}
    wall = max(1e-6, s1["t"] - s0["t"])
    cpu = (int(c1) - int(c0)) / tck / wall
    gpu = (s1["render_ns"] - s0["render_ns"]) / 1e9 / wall
    rows.append((name, pw - bw, (pse ** 2 + bse ** 2) ** 0.5, cpu, gpu))
# least squares a*cpu + b*gpu = dw, a, b >= 0
def fit(rows):
    scc = sum(r[3] * r[3] for r in rows); sgg = sum(r[4] * r[4] for r in rows); scg = sum(r[3] * r[4] for r in rows)
    scw = sum(r[3] * r[1] for r in rows); sgw = sum(r[4] * r[1] for r in rows)
    det = scc * sgg - scg * scg
    if det > 1e-12:
        a, b = (scw * sgg - sgw * scg) / det, (sgw * scc - scw * scg) / det
        if a >= 0 and b >= 0:
            return a, b
    a = max(0.0, scw / scc) if scc > 1e-12 else 0.0
    b = max(0.0, sgw / sgg) if sgg > 1e-12 else 0.0
    ea = sum((r[1] - a * r[3]) ** 2 for r in rows); eb = sum((r[1] - b * r[4]) ** 2 for r in rows)
    return (a, 0.0) if ea <= eb else (0.0, b)
a, b = fit(rows)
print(f"{'stretch':8} {'extra W':>9} {'+-':>6} {'CPU s/s':>8} {'GPU s/s':>8} {'model W':>8}")
for name, dw, se, cpu, gpu in rows:
    print(f"{name:8} {dw:9.3f} {se:6.3f} {cpu:8.4f} {gpu:8.4f} {a * cpu + b * gpu:8.3f}")
print(f"\nwPerCpuSec = {a:.2f} W per CPU-second, wPerGpuSec = {b:.2f} W per GPU-second")
if dry:
    print("DRY run: these numbers mean nothing (plugged in, offscreen). The plumbing ran end to end.")
else:
    noisy = any(se > abs(dw) * 0.5 for _, dw, se, _, _ in rows)
    if noisy:
        print("The readings were noisy for the size of the effect (+- above half the extra watts): run it again, idle.")
    print('\nPaste into silicon.json (the shell reloads it):\n  "overhead": { "wPerCpuSec": %.2f, "wPerGpuSec": %.2f }' % (a, b))
PY
echo "readings and logs: $OUT"
