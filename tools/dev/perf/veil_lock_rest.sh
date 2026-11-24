#!/usr/bin/env bash
# veil_lock_rest.sh -- does the REAL lock draw while nobody touches it? The supervisor and lock (lock/shell.qml) from a tree
# copy in tools/dev/lock_env.sh's nested Hyprland (tools/dev/lock_a1_lib.sh: the stub PAM, password "hunter2"; nothing of the
# user's is touched), every frame a process swaps written down by tools/dev/perf/veil_gputime.c (an LD_PRELOAD: the wall time
# and the GPU time of each frame of its first window), and the frames counted in windows of the lock's life:
#
#   awake    the seconds after the veil has risen, before idleSeconds: the veil's own rate (fps) and the lock's GPU ms a frame
#   rest     from idleSeconds + the ease to still (restEaseMs 2000) + 1 s, for REST_S seconds: the lock must draw NO frame
#   same     (fake) the fake shell sends the same hints again, 16 times 250 ms apart: frames the lock drew for them (reported,
#            not judged: the real shell sends a screen's hints only when they changed, LockOwner._sendHints)
#   first    the supervisor's start to the first frame as heavy as half an awake one: the rise (S0's blur-in and the veil's
#            first frame come together; the lock's own start -- launch, secure, the S0 capture -- is most of it). "cold" for the
#            env's first lock (its empty shader caches: a veil's compile then stalls the window AFTER this frame, which the
#            awake rate shows: keycaps 33 fps cold against 60 warm, 2026-11-22), "warm" after
#   shell    (shell) the frames the SHELL drew in the rest window: its lock popup is the shell's window, not the lock's
#
#   tools/dev/perf/veil_lock_rest.sh [OUTDIR]
#   VEILS="relief gooey dimples paper louvres keycaps dials"   SCENES="fake noshell shell"   SHELL_VEILS="relief"   REST_S=8
#   IDLE_S=3   VEIL_GPUTIME_DEBUG=1 (the preload's trace columns)
#   fake: a fake shell on the lock's socket (tools/dev/lock_env/a1_fake_shell.py) names LOCK-1 shown and sends a bar and
#         popup; noshell: none, so the lock's own fallback card shows after fallbackDelayMs; shell: the REAL shell.qml (mock
#         services, SHELL_LOCK=live: the lock's socket), started and settled before the lock, its popup over the lock
# Ends in VEIL_LOCK_REST RESULT PASS|FAIL (a lock that drew at rest, a scene that did not lock or unlock).
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$HERE/tools/dev/lock_a1_lib.sh"
OUT="${1:-${SCRATCH:-/tmp}/veil_lock_rest}"
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
IDLE_S="${IDLE_S:-3}" REST_S="${REST_S:-8}"
SHPID=""
stop_shell() { [ -n "$SHPID" ] && kill "$SHPID" 2> /dev/null; [ -n "$SHPID" ] && wait "$SHPID" 2> /dev/null; SHPID=""; }
a1_init pfvr
trap 'stop_shell; a1_down' EXIT
bad=()
ms() { date +%s%3N; }
count() {  # gpu.tsv t0 t1 -> frames in [t0, t1]
    python3 -c 'import sys
f, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
n = 0
for ln in open(f):
    p = ln.split()
    if len(p) >= 2 and t0 <= float(p[0]) <= t1: n += 1
print(n)' "$@" 2> /dev/null || echo -1
}
printf "  %-8s %-7s %8s %8s %12s %6s %9s %10s %9s\n" veil scene awake/s "gpu ms" rest same "first ms" unlocked "shell"
for v in ${VEILS:-relief gooey dimples paper louvres keycaps dials}; do
    # one env per veil: its first lock compiles the veil's shaders into the env's empty caches (cold), the next finds them
    a1_up || { echo "VEIL_LOCK_REST RESULT FAIL (env up)"; exit 1; }
    a1_build_pam > /dev/null || { echo "VEIL_LOCK_REST RESULT FAIL (the stub PAM did not build)"; exit 1; }
    cc -O2 -shared -fPIC -o "$W/gt.so" "$HERE/tools/dev/perf/veil_gputime.c" -ldl || { echo "VEIL_LOCK_REST RESULT FAIL (cc veil_gputime.c)"; exit 1; }
    nlock=0
    for sc in ${SCENES:-fake noshell shell}; do
        if [ "$sc" = shell ]; then
            case " ${SHELL_VEILS:-relief} " in *" $v "*) ;; *) continue ;; esac
        fi
        nlock=$((nlock + 1))
        cache=$([ "$nlock" = 1 ] && echo cold || echo warm)
        a1_tree '{"veil": "'"$v"'", "idleSeconds": '"$IDLE_S"', "veilRiseMs": 600, "face": "off"}' || { echo "VEIL_LOCK_REST RESULT FAIL (tree)"; exit 1; }
        if [ "$sc" = shell ]; then
            # the real shell beside the lock: the whole tree (the copy's patched PAM directory kept)
            rsync -a --exclude '.git' --exclude '.qmlls.ini' --exclude '.claude' --exclude 'screenshots' --exclude 'config' \
                --exclude 'modules/lockscreen/lock/AuthController.qml' "$HERE/" "$T/" || { echo "VEIL_LOCK_REST RESULT FAIL (copy)"; exit 1; }
        fi
        rm -f "$W"/gpu-*.tsv
        if [ "$sc" = shell ]; then
            "$E" run env LD_PRELOAD="$W/gt.so" VEIL_GPUTIME_OUT="$W/gpu-shell-%p.tsv" SHELL_SERVICES=mock SHELL_LOCK=live \
                QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 quickshell -n -p "$T/shell.qml" > "$OUT/$v-$sc.shell.log" 2>&1 &
            SHPID=$!
            for _ in $(seq 1 600); do grep -aq "LARES settled" "$OUT/$v-$sc.shell.log" 2> /dev/null && break; sleep 0.2; done
            grep -aq "LARES settled" "$OUT/$v-$sc.shell.log" || { bad+=("$v/$sc: the shell never settled"); stop_shell; continue; }
            sleep 2
        elif [ "$sc" = fake ]; then
            a1_fake --reply-hello --shown LOCK-1
        fi
        t_req=$(ms)
        A1_LOCK_ENV="LD_PRELOAD=$W/gt.so VEIL_GPUTIME_OUT=$W/gpu-lock-%p.tsv ${VEIL_GPUTIME_DEBUG:+VEIL_GPUTIME_DEBUG=1}" a1_lock
        if ! a1_wait_log "LARESLOCK secure" 20; then
            bad+=("$v/$sc: never secure"); stop_shell; a1_fake_stop; continue
        fi
        hint='{"t":"hints","screen":"LOCK-1","rects":[[640,0,1600,40],[1160,40,560,660]],"bar":[640,0,1600,40],"popup":[1160,40,560,660]}'
        [ "$sc" = fake ] && a1_fake_cmd "send $hint"
        # the veil has risen (600 ms) and is awake: its own rate
        sleep 1.2
        t_aw0=$(ms); sleep 1.5; t_aw1=$(ms)
        # idle, then the ease to still (restEaseMs 2000), then a second more
        sleep $(( IDLE_S + 2 ))
        t_r0=$(ms); sleep "$REST_S"; t_r1=$(ms)
        same=-
        if [ "$sc" = fake ]; then
            t_h0=$(ms)
            for _ in $(seq 1 16); do a1_fake_cmd "send $hint"; sleep 0.25; done
            t_h1=$(ms)
        fi
        # unlock: the password, typed (a key wakes the veil)
        "$E" type hunter2 > /dev/null 2>&1; "$E" key Return > /dev/null 2>&1
        unlocked=no
        for _ in $(seq 1 80); do a1_sup_alive || { unlocked=yes; break; }; sleep 0.1; done
        cp "$B/rt/lares-lock.log" "$OUT/$v-$sc.lock.log" 2> /dev/null
        cat "$W"/gpu-lock-*.tsv > "$OUT/$v-$sc.gpu.tsv" 2> /dev/null
        read -r aw gms first < <(python3 - "$OUT/$v-$sc.gpu.tsv" "$t_req" "$t_aw0" "$t_aw1" <<'PY'
import sys
f, req, a0, a1 = sys.argv[1], *map(float, sys.argv[2:])
fr = sorted((float(p[0]), float(p[1])) for p in (ln.split() for ln in open(f)) if len(p) >= 2)
awake = sorted(g for t, g in fr if a0 <= t <= a1)
aw = len(awake) / max(0.001, (a1 - a0) / 1000.0)
med = awake[len(awake) // 2] if awake else -1
first = -1
for t, g in fr:
    if t >= req and awake and g >= 0.5 * med:
        first = t - req
        break
print("%.1f %.3f %d" % (aw, med, first))
PY
)
        rest=$(count "$OUT/$v-$sc.gpu.tsv" "$t_r0" "$t_r1")
        [ "$sc" = fake ] && same=$(count "$OUT/$v-$sc.gpu.tsv" "$((t_h0 + 100))" "$t_h1")
        shellf=-
        if [ "$sc" = shell ]; then
            cat "$W"/gpu-shell-*.tsv > "$OUT/$v-$sc.shell.gpu.tsv" 2> /dev/null
            shellf="$(count "$OUT/$v-$sc.shell.gpu.tsv" "$t_r0" "$t_r1")/${REST_S}s"
        fi
        printf "  %-8s %-7s %8s %8s %12s %6s %9s %10s %9s\n" "$v" "$sc" "$aw" "$gms" "$rest in ${REST_S}s" "$same" "$first $cache" "$unlocked" "$shellf"
        [ "$rest" = 0 ] || bad+=("$v/$sc: the lock drew $rest frames at rest")
        [ "$unlocked" = yes ] || bad+=("$v/$sc did not unlock")
        stop_shell
        a1_fake_stop
        sleep 1
    done
    a1_down
    a1_init pfvr
done
if [ ${#bad[@]} -eq 0 ]; then
    echo "VEIL_LOCK_REST RESULT PASS"
else
    echo "VEIL_LOCK_REST RESULT FAIL ($(IFS=';'; echo "${bad[*]}"))"
    exit 1
fi
