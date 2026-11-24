#!/usr/bin/env bash
# mux_bench.sh -- ONE-TIME BENCHMARK OF THE DESKTOP'S RESPONSIVENESS, run in each GPU mode (dGPU-only / MUX, then Hybrid) and compared.
#
# The user's report (2026-11-15): "my machine feels slower when in mux mode: typing in vscode has some delay, cli commands that log
# more than one line have their lines appear sequentially, and many more small hiccups". This measures each of those on the REAL
# desktop with test windows of its own (the user allowed them for this benchmark: LARES_SHOW=1 is the switch; without it the runner
# refuses), and writes everything under OUT (default ~/.cache/claude-orch/r11/bench/<mode>-<time>/):
#
#   facts.txt   the mode, AC / battery, CPU profile (platform_profile, EPP, turbo, max frequency), the GPU's P-state, Hyprland's render
#               options and the monitor's format, the load
#   cpu         one fixed single-thread Python workload, best of 3 (ms): what the CPU profile gives a command
#   pacing      a 360x200 window animating for PACE_SECS: the gaps between its presented frames (p50/p95/p99/max, the share that took
#               more than 1.5 periods): the compositor + GPU round trip a client sees
#   typing      a test kitty (class lares-bench) running `cat`: letters typed with wtype (only after checking that THIS window has the
#               focus; it stops at once if the focus moves), and per key, from kitty's own Wayland log: key -> its first commit (the
#               client's work) and commit -> the compositor's frame callback (the compositor's turn)
#   sparse      the same kitty, a key every SPARSE_GAP (3) s: the first key after a pause, the card's clocks dropped
#   burst       the same kitty prints 60 short lines in one write: how many frames it took to draw them and the time from the first
#               commit to the last (lines appearing one by one = many frames)
#   vscode      a SEPARATE VS Code (its own empty profile in OUT, extensions off) on a scratch file, typed into the same way, from its
#               Wayland log (VSCODE=0 skips it; VSCODE_FLAGS adds Chromium flags); the user's own VS Code is never touched
#   latency     a small EGL client (tools/dev/mux_latency/latency.c): the time from deciding a frame to the compositor's
#               `presented` (wp_presentation), in frames: the latency every animation carries; on the default EGL platform, with
#               its own frame-callback pacing (the floor), and pinned to each NVIDIA Wayland platform where both are installed
#   gpu.csv     the NVIDIA card's P-state, clock and load every 100 ms through the run
#   shell       the running shell's frame journal summary for its current session (missed share), read-only
# One summary line per part, then MUX_BENCH RESULT PASS (the measurements were taken) | FAIL (a part could not run).
#
#   LARES_SHOW=1 tools/dev/mux_bench.sh            PACE_SECS=6  KEYS=40
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ "${LARES_SHOW:-0}" = 1 ] || { echo "mux_bench: opens test windows on your desktop; run with LARES_SHOW=1"; echo "MUX_BENCH RESULT FAIL (refused: no LARES_SHOW)"; exit 1; }
[ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { echo "MUX_BENCH RESULT FAIL (not in a Hyprland session)"; exit 1; }
mux=$(cat /sys/class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value 2> /dev/null || cat /sys/devices/platform/asus-nb-wmi/gpu_mux_mode 2> /dev/null || echo "?")
case "$mux" in 0) mode=mux ;; 1) mode=hybrid ;; *) mode="mode$mux" ;; esac
OUT="${OUT:-$HOME/.cache/claude-orch/r11/bench/$mode-$(date +%H%M%S)}"
mkdir -p "$OUT"
PACE_SECS="${PACE_SECS:-6}"; KEYS="${KEYS:-40}"
KPID=""; GPID=""
cleanup() {
    [ -n "$KPID" ] && kill "$KPID" 2> /dev/null
    [ -n "$GPID" ] && kill "$GPID" 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
fails=0
ws=$(hyprctl -j activeworkspace 2> /dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
# A test window is started by Hyprland itself on the ACTIVE workspace, floating (a window rule of the user's may send a new window
# elsewhere: a quickshell FloatingWindow went to a hidden special workspace, where Hyprland suspends it and it draws no frame).
# The script it runs writes its pid first.
launch() {  # launch <script> <w> <h>
    hyprctl dispatch "hl.dsp.exec_cmd(\"$1\", { workspace = \"$ws\", float = true, size = \"$2 $3\", move = \"60 120\" })" > /dev/null 2>&1
}
waitpid() {  # waitpid <pidfile> -> the pid, once written
    local i; for i in $(seq 1 100); do [ -s "$1" ] && { cat "$1"; return 0; }; sleep 0.05; done; return 1
}
# the focused window's address; a letter goes out only while it is the test window's (never into a window of the user's)
active() { hyprctl -j activewindow 2> /dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("address",""))
except Exception: print("")'; }
type_into() {  # type_into <address> <keys> [gap s]: one letter at a time, the focus checked before every one
    local a=$1 n=$2 gap=${3:-0.15} i typed=0 letters=abcdefghijklmnopqrstuvwxyz
    for i in $(seq 1 "$n"); do
        [ "$(active)" = "$a" ] || { echo "  the focus left the test window: typing stopped after $typed keys"; break; }
        wtype -p F24 -- "${letters:$(( (i - 1) % 26 )):1}" 2> /dev/null
        typed=$((typed + 1))
        sleep "$gap"
    done
}
WL="$ROOT/tools/dev/mux_bench_wl.py"

# ---- facts
{
    echo "mode $mode (gpu_mux_mode=$mux)"
    echo "date $(date -Is)"
    for s in /sys/class/power_supply/*; do [ -e "$s/online" ] && echo "ac ${s##*/} online=$(cat "$s/online")"; [ -e "$s/capacity" ] && echo "battery ${s##*/} $(cat "$s/status") $(cat "$s/capacity")%"; done
    echo "platform_profile $(cat /sys/firmware/acpi/platform_profile 2> /dev/null)"
    echo "epp $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2> /dev/null) governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2> /dev/null)"
    echo "no_turbo $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2> /dev/null) max_perf_pct $(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2> /dev/null) min_perf_pct $(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct 2> /dev/null) max_freq $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2> /dev/null)"
    echo "load $(cut -d' ' -f1-3 /proc/loadavg)"
    nvidia-smi --query-gpu=name,driver_version,pstate,clocks.gr,power.draw,utilization.gpu --format=csv,noheader 2> /dev/null | sed 's/^/nvidia /'
    hyprctl -j monitors 2> /dev/null | python3 -c 'import json,sys
for m in json.load(sys.stdin): print("monitor", m["name"], m["width"], m["height"], m["refreshRate"], "scale", m["scale"], "vrr", m.get("vrr"), m.get("currentFormat"))'
    for o in render:direct_scanout render:explicit_sync render:explicit_sync_kms misc:vfr misc:vrr opengl:nvidia_anti_flicker cursor:no_hardware_cursors debug:damage_tracking; do
        echo "hypr $o $(hyprctl -j getoption "$o" 2> /dev/null | tr -d '\n ' | cut -c1-80)"
    done
    tr '\0' '\n' < "/proc/$(pgrep -u "$(id -u)" -x Hyprland | head -1)/environ" 2> /dev/null | grep -E '^(__GL|__GLX|GBM|LIBVA|NVD|AQ_|WLR|ELECTRON|OZONE|__EGL|KITTY)' | sed 's/^/hyprenv /'
} > "$OUT/facts.txt"
cat "$OUT/facts.txt" | sed 's/^/  /'

# ---- GPU sampler
nvidia-smi --query-gpu=timestamp,pstate,clocks.gr,utilization.gpu,power.draw --format=csv,noheader -lms 100 > "$OUT/gpu.csv" 2> /dev/null &
GPID=$!

ONLYV=0; [ "${ONLY:-}" = vscode ] && ONLYV=1
if [ "$ONLYV" = 0 ]; then
# ---- cpu
cpu=$(python3 -c '
import time
best=1e9
for _ in range(3):
    t=time.perf_counter(); s=0
    for i in range(3_000_000): s+=i*i%7
    best=min(best,time.perf_counter()-t)
print(round(best*1000))')
echo "cpu       ${cpu} ms (3e6 iterations of a Python loop, best of 3)" | tee "$OUT/cpu.txt"

# ---- pacing (a private config / state / cache home and a copy of the harness, so no file of the user's or the repo's is written)
PH="$OUT/pacing-home"; rm -rf "$PH"; mkdir -p "$PH/cfg/theme" "$PH/state" "$PH/cache" "$PH/qml"
echo '{"mode":"dark"}' > "$PH/cfg/theme/state.json"
cp "$ROOT/tools/dev/qml/mux_pacing.qml" "$PH/qml/shell.qml"
{
    echo '#!/bin/sh'
    echo "echo \$\$ > '$PH/pid'"
    echo "exec env XDG_CONFIG_HOME='$PH/cfg' XDG_STATE_HOME='$PH/state' XDG_CACHE_HOME='$PH/cache' PACE_SECS=$PACE_SECS QS_DISABLE_CRASH_HANDLER=1 LARES_SHOW=1 quickshell -n -p '$PH/qml/shell.qml' > '$OUT/pacing.log' 2>&1"
} > "$PH/run.sh"
chmod +x "$PH/run.sh"; rm -f "$PH/pid"
launch "$PH/run.sh" 360 200
ppid=$(waitpid "$PH/pid") || ppid=0
for _ in $(seq 1 $(( (PACE_SECS + 25) * 10 ))); do kill -0 "$ppid" 2> /dev/null || break; sleep 0.1; done
kill "$ppid" 2> /dev/null
pace=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/pacing.log" | grep -ao 'MUXPACE .*' | tail -1 | cut -d' ' -f2-)
if [ -n "$pace" ] && ! echo "$pace" | grep -q error; then echo "pacing    $pace" | tee "$OUT/pacing.txt"
else echo "pacing    FAIL (${pace:-no MUXPACE line}; $OUT/pacing.log)"; fails=1; fi

# ---- typing + burst: a test kitty with its own Wayland log
KL="$OUT/kitty-wl.log"
LINES_F="$OUT/burst.txt.src"
for i in $(seq 1 60); do printf 'line %02d  the quick brown fox jumps over the lazy dog %s\n' "$i" "$(printf '%*s' $((i % 17)) '' | tr ' ' '.')"; done > "$LINES_F"
cat > "$OUT/kitty-run.sh" << EOF
#!/bin/sh
# wait for the go file, print the burst in ONE write, then echo what is typed
while [ ! -e "$OUT/go-burst" ]; do sleep 0.05; done
printf 'BURSTSTART\n'; cat "$LINES_F"; printf 'BURSTEND\n'
exec cat
EOF
chmod +x "$OUT/kitty-run.sh"
{
    echo '#!/bin/sh'
    echo "echo \$\$ > '$OUT/kitty-main.pid'"
    echo "exec env WAYLAND_DEBUG=client kitty --class lares-bench --title lares-bench -o remember_window_size=no -o cursor_blink_interval=0 '$OUT/kitty-run.sh' 2> '$KL' > /dev/null"
} > "$OUT/kitty-launch.sh"
chmod +x "$OUT/kitty-launch.sh"; rm -f "$OUT/kitty-main.pid"
launch "$OUT/kitty-launch.sh" 900 500
KPID=$(waitpid "$OUT/kitty-main.pid") || KPID=""
addr=""
for _ in $(seq 1 100); do
    addr=$(hyprctl -j clients 2> /dev/null | python3 -c 'import json,sys
c=[w for w in json.load(sys.stdin) if w.get("class")=="lares-bench"]; print(c[0]["address"] if c else "")')
    [ -n "$addr" ] && break; sleep 0.1
done
[ -n "$addr" ] || { echo "typing    FAIL (the test kitty did not map)"; echo "MUX_BENCH RESULT FAIL"; exit 1; }
hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" > /dev/null 2>&1
sleep 0.8
# burst
mark_burst=$(wc -l < "$KL")
touch "$OUT/go-burst"
sleep 1.5
mark_type=$(wc -l < "$KL")
type_into "$addr" "$KEYS"
sleep 0.5
# sparse: a key every SPARSE_GAP seconds, so the card has dropped its clocks between keys (the first key after a pause)
mark_sparse=$(wc -l < "$KL")
type_into "$addr" "${SPARSE_KEYS:-8}" "${SPARSE_GAP:-3}"
sleep 0.5
kill "$KPID" 2> /dev/null; wait "$KPID" 2> /dev/null; KPID=""
python3 "$WL" burst "$KL" "$mark_burst" "$mark_type" | tee "$OUT/burst.txt"
python3 "$WL" typing <(sed -n "$((mark_type + 1)),${mark_sparse}p" "$KL") 0 typing | tee "$OUT/typing.txt"
python3 "$WL" typing "$KL" "$mark_sparse" sparse | tee "$OUT/sparse.txt"
grep -q '"keys": [1-9]' "$OUT/typing.txt" || fails=1

fi   # ONLY=vscode skips everything above
# ---- VS Code: a separate instance (its own empty profile, extensions off) on a scratch file, typed into the same way (VSCODE=0 skips)
if [ "${VSCODE:-1}" = 1 ] && [ -x /usr/share/code/code ]; then
    VD="$OUT/vscode"; rm -rf "$VD"; mkdir -p "$VD/ud" "$VD/ext"; echo "scratch" > "$VD/scratch.txt"
    {
        echo '#!/bin/sh'
        echo "echo \$\$ > '$VD/pid'"
        echo "exec env WAYLAND_DEBUG=client /usr/share/code/code --user-data-dir='$VD/ud' --extensions-dir='$VD/ext' --disable-extensions --disable-workspace-trust --skip-release-notes --skip-welcome ${VSCODE_FLAGS:-} --new-window '$VD/scratch.txt' > '$VD/out.log' 2> '$VD/wl.log'"
    } > "$VD/launch.sh"
    chmod +x "$VD/launch.sh"; rm -f "$VD/pid"
    launch "$VD/launch.sh" 900 600
    vpid=$(waitpid "$VD/pid") || vpid=""
    vaddr=""
    for _ in $(seq 1 200); do
        vaddr=$(hyprctl -j clients 2> /dev/null | python3 -c 'import json,sys
c=[w for w in json.load(sys.stdin) if str(w.get("pid"))==sys.argv[1] and "scratch.txt" in w.get("title","")]; print(c[0]["address"] if c else "")' "${vpid:-x}")
        [ -n "$vaddr" ] && break; sleep 0.1
    done
    if [ -n "$vaddr" ]; then
        sleep 2   # the editor settles (its first paints, the file's load)
        hyprctl dispatch "hl.dsp.focus({ window = \"address:$vaddr\" })" > /dev/null 2>&1
        sleep 0.8
        vmark=$(wc -l < "$VD/wl.log")
        type_into "$vaddr" "$KEYS"
        sleep 0.5
        python3 "$WL" typing "$VD/wl.log" "$vmark" vscode | tee "$OUT/vscode.txt"
    else
        echo "vscode    FAIL (the test VS Code did not map)"; fails=1
    fi
    [ -n "$vpid" ] && kill "$vpid" 2> /dev/null
    sleep 1
fi
kill "$GPID" 2> /dev/null; GPID=""

# ---- latency: tools/dev/mux_latency/latency.c, built here; decide -> presented (wp_presentation) per frame, on the EGL vendor's default
# Wayland platform and, where NVIDIA's EGL is installed, pinned to each of its two (egl-wayland2 adds a frame: 2026-11-15)
LD="$OUT/latency"; mkdir -p "$LD"
P=/usr/share/egl/egl_external_platform.d
if ( cd "$LD" && wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-client-protocol.h \
     && wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell.c \
     && wayland-scanner client-header /usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml presentation-time-client-protocol.h \
     && wayland-scanner private-code /usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml presentation-time.c \
     && cc -O2 -I. -o latency "$ROOT/tools/dev/mux_latency/latency.c" xdg-shell.c presentation-time.c \
        $(pkg-config --cflags --libs wayland-client wayland-egl egl glesv2) ) > "$LD/build.log" 2>&1; then
    lat_run() {  # lat_run <name> <env...>
        local name=$1; shift
        rm -f "${LD:?}/${name:?}.out"
        printf '#!/bin/sh\nexec env %s timeout 30 %s/latency 600 %s/%s.tsv > %s/%s.out 2>&1\n' "$*" "$LD" "$LD" "$name" "$LD" "$name" > "$LD/$name.sh"
        chmod +x "$LD/$name.sh"
        launch "$LD/$name.sh" 400 300
        for _ in $(seq 1 200); do grep -q LATENCY "$LD/$name.out" 2> /dev/null && break; sleep 0.1; done
        printf 'latency   %-10s %s\n' "$name" "$(grep -o 'LATENCY .*' "$LD/$name.out" | cut -d' ' -f2-)"
        sleep 0.8
    }
    {
        lat_run default X=1
        lat_run manual LAT_MODE=manual
        if [ -e "$P/09_nvidia_wayland2.json" ] && [ -e "$P/10_nvidia_wayland.json" ]; then
            lat_run nv_wl2 "__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=$P/09_nvidia_wayland2.json:$P/15_nvidia_gbm.json"
            lat_run nv_wl1 "__EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES=$P/10_nvidia_wayland.json:$P/15_nvidia_gbm.json"
        fi
    } | tee "$OUT/latency.txt"
else
    echo "latency   FAIL (the client did not build: $LD/build.log)"; fails=1
fi

# ---- the running shell's own journal (read-only)
python3 - "$HOME/.local/state/lares/perf/frame-journal.jsonl" << 'PY' | tee "$OUT/shell.txt"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
s = [r for r in rows if r.get("k") == "sum" and r.get("w") == "bar"]
if s:
    r = s[-1]
    print("shell     session %s: %d frames, %d missed (%.1f %%), %d stutters, worst %d ms" % (r.get("sid"), r["frames"], r["missed"],
          100.0 * r["missed"] / max(1, r["frames"]), r["stutters"], r["worst"]))
PY
echo "  out: $OUT"
[ "$fails" = 0 ] && echo "MUX_BENCH RESULT PASS" || { echo "MUX_BENCH RESULT FAIL"; exit 1; }
