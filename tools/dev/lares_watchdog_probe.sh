#!/usr/bin/env bash
# The supervisor's liveness watchdog (tools/shell/lares-supervise, promise 6) against a FAKE WORLD: a temp HOME / runtime dir, a stub
# `quickshell` that is a sleeping "shell" and answers `ipc ... call shell ping` unless <world>/ctl/hang exists (then the ping hangs, as a
# blocked GUI thread's does), and a stub hyprctl that logs. Starts no quickshell, no window, touches nothing of the user's.
#
#   tools/dev/lares_watchdog_probe.sh                  ends in LARES_WATCHDOG RESULT PASS|FAIL
#   ARM=nowatchdog tools/dev/lares_watchdog_probe.sh   watchdog off (LARES_WATCH_PING_S=0): the stall stays -> must FAIL on "the stall is caught"
#   ARM=noresume   tools/dev/lares_watchdog_probe.sh   the resume gap is not looked for (LARES_WATCH_GAP_S=9999) -> must FAIL on the resume checks
#
#   ARM=noptracer  tools/dev/lares_watchdog_probe.sh   the shell does not name the supervisor its ptracer (a patched COPY of tools/shell) -> must FAIL on "a real stack"
#
#   ARM=forkloop   tools/dev/lares_watchdog_probe.sh   the loop sleeps through an external `sleep` again (a patched COPY) -> must FAIL on "forks nothing at rest"
#
# The numbers are shortened (ping 1 s, stall = 8 s of misses, grace 6 s, a gap of 3 s between two turns is a resume); the logic is the real one.
#   rest      the supervisor's loop at rest forks NOTHING between two pings (the real 15 s ping): the children it has reaped, read from its
#             /proc stat (their page faults and CPU ticks: any fork or exec that ended moves them), stand still over 6 s. It was 2 execs and
#             10 forks a second, 1 % of a core for as long as the session lives
#   slowstart no answer for the first 5 s (inside the grace) and a 4 s hang later (under the stall span) are NOT stalls
#   resume    the supervisor frozen 5 s (SIGSTOP) while the shell hangs: the misses before it are forgotten
#   caught    a hung shell that ignores TERM is restarted: evidence under stalls/ (shell.log tail, threads, hyprctl), KILL, a new pid,
#             a hyprctl notify, shell-last.log, the restart counted
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
NAME=LARES_WATCHDOG
ARM=${ARM:-}
W=$(mktemp -d /tmp/lrwd.XXXXXX) || exit 1
SUP="" FAILS=0
cleanup() {
    [ -z "$SUP" ] || { kill -CONT "$SUP" 2> /dev/null; touch "$W/run/stop"; sleep 0.8; kill -KILL "$SUP" 2> /dev/null; }
    # a stub shell the supervisor could not stop is found by the marker in its environment, never by name
    local p
    for p in /proc/[0-9]*; do { tr '\0' '\n' < "$p/environ" | grep -qx "LARES_WD_WORLD=$W" && kill -KILL "${p##*/}"; } 2> /dev/null; done 2> /dev/null
    if [ -n "${KEEP:-}" ]; then echo "kept $W"; return; fi
    rm -rf "$W"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

mkdir -p "$W/bin" "$W/ctl" "$W/home/.local/state/lares/tool" "$W/run" "$W/dep"
cat > "$W/bin/quickshell" << 'STUB'
#!/usr/bin/env bash
W=$LARES_WD_WORLD
case "$1" in
    ipc) if [ -e "$W/ctl/hang" ]; then exec sleep 30; fi; echo ok ;;
    kill) echo "kill $*" >> "$W/stub.log"; kill "$3"; exit 0 ;;
    *) echo "start $$" >> "$W/stub.log"
       [ -e "$W/ctl/deaf" ] && trap '' TERM
       echo "shell stub up"
       while :; do sleep 0.2; done ;;
esac
STUB
cat > "$W/bin/hyprctl" << 'STUB'
#!/usr/bin/env bash
echo "hyprctl $*" >> "$LARES_WD_WORLD/hypr.log"
echo '[]'
STUB
chmod +x "$W/bin/"*
write_env() {   # write_env <run dir> [more lines]: the supervisor's world
    {
        printf 'RUN=%s\nPERSIST=%s/home/.local/state/lares/tool\nTOOL=/bin/true\nSHELL_QML=%s/dep/current/shell.qml\nDEPLOY_DIR=%s/dep\n' "$1" "$W" "$W" "$W"
        printf 'QUICKSHELL=%s/bin/quickshell\nHYPRCTL=%s/bin/hyprctl\n' "$W" "$W"
        printf 'RESTART_LIMIT=5\nRESTART_WINDOW=60\nBACKOFF=0.3\nSLOW_BACKOFF=5\nSLOW_MAX=10\nSTABLE=30\nSTOP_TIMEOUT=2\n'
        printf 'export HYPRLAND_INSTANCE_SIGNATURE=fakesig XDG_RUNTIME_DIR=%s WAYLAND_DISPLAY=wayland-fake HOME=%s/home PATH=%s/bin:/usr/bin:/bin\n' "$1" "$W" "$W"
        [ $# -lt 2 ] || printf '%s\n' "${@:2}"
    } > "$1/supervise.env"
}
write_env "$W/run"
export LARES_WD_WORLD=$W
export LARES_WATCH_PING_S=1 LARES_WATCH_STALL_S=8 LARES_WATCH_GRACE_S=6 LARES_WATCH_TIMEOUT_S=1 LARES_WATCH_GAP_S=3
[ "$ARM" = nowatchdog ] && export LARES_WATCH_PING_S=0
[ "$ARM" = noresume ] && export LARES_WATCH_GAP_S=9999

SLOG=$W/run/supervise.log
spid() { cat "$W/run/pid" 2> /dev/null; }
wd_count() { grep -c "WATCHDOG" "$SLOG" 2> /dev/null; }
wait_for() { local s=$1 end; shift; end=$((SECONDS + s)); while ! "$@"; do [ $SECONDS -ge $end ] && return 1; sleep 0.2; done; return 0; }
caught() { [ "$(wd_count)" -ge 1 ]; }

SUPBIN=$ROOT/tools/shell/lares-supervise
if [ "$ARM" = noptracer ]; then
    cp -r "$ROOT/tools/shell" "$W/shellcopy" && sed -i 's/prctl(0x59616d61, os.getppid(), 0, 0, 0)/prctl(0)/' "$W/shellcopy/lares-supervise" && SUPBIN=$W/shellcopy/lares-supervise
fi
if [ "$ARM" = forkloop ]; then
    cp -r "$ROOT/tools/shell" "$W/shellcopy" && grep -q '^enable -f /usr/lib/bash/sleep sleep' "$W/shellcopy/lares-supervise" \
        && sed -i '/^enable -f \/usr\/lib\/bash\/sleep sleep/d' "$W/shellcopy/lares-supervise" && SUPBIN=$W/shellcopy/lares-supervise \
        || { echo "$NAME RESULT FAIL (ARM forkloop: its anchor is gone)"; exit 1; }
fi

echo "== rest: the loop forks nothing between two pings"
# its own run dir and the REAL ping period: the first ping goes out in the first turn, the next 15 s later; the log is not looked at for a minute
mkdir -p "$W/rest"
write_env "$W/rest" "LOGCAP_EVERY=60"
reaped() {   # reaped <pid>: "cminflt cutime cstime" -- what the children it has waited for cost; a fork or an exec that ended moves it
    local st
    read -r st 2> /dev/null < "/proc/$1/stat" || return 1
    st=${st##*) }
    # shellcheck disable=SC2086
    set -- $st
    echo "$9 ${14} ${15}"
}
( unset LARES_WATCH_PING_S LARES_WATCH_STALL_S LARES_WATCH_GRACE_S LARES_WATCH_TIMEOUT_S LARES_WATCH_GAP_S
  exec setsid "$SUPBIN" --run "$W/rest" > /dev/null 2>&1 < /dev/null ) &
RSUP=$!
if wait_for 5 test -s "$W/rest/pid"; then
    sleep 3                      # the first ping has gone out and has been reaped
    r0=$(reaped "$RSUP"); sleep 6; r1=$(reaped "$RSUP")
    if [ -n "$r0" ] && [ "$r0" = "$r1" ]; then ok "the supervisor forks nothing at rest (reaped children: $r0, unchanged over 6 s)"
    else bad "the supervisor forks nothing at rest (reaped children's faults / utime / stime: '$r0' -> '$r1' in 6 s)"; fi
else
    bad "the rest phase's supervisor started its stub"
fi
touch "$W/rest/stop"; wait_for 5 bash -c '! kill -0 "$1" 2> /dev/null' _ "$RSUP" || kill -KILL "$RSUP" 2> /dev/null
wait "$RSUP" 2> /dev/null
setsid "$SUPBIN" --run "$W/run" > /dev/null 2>&1 < /dev/null &
SUP=$!
wait_for 5 test -s "$W/run/pid" || { echo "$NAME RESULT FAIL (the supervisor did not start the stub)"; exit 1; }
T0=$SECONDS

echo "== slowstart: a hang inside the grace, then a short hang after it"
touch "$W/ctl/hang"; sleep 5; rm -f "$W/ctl/hang"
sleep 4
touch "$W/ctl/hang"; sleep 4; rm -f "$W/ctl/hang"
sleep 4
check "no stall for a slow start or a short hang" test "$(wd_count)" -eq 0

echo "== resume: the supervisor frozen while the shell hangs"
touch "$W/ctl/hang"; sleep 5     # misses accumulate (span 5 s of the 8 s)
kill -STOP "$SUP"; sleep 5; kill -CONT "$SUP"
sleep 4
check "the resume is seen" grep -q "a resume" "$SLOG"
check "no stall within 4 s of the resume (the misses before it are forgotten)" test "$(wd_count)" -eq 0
rm -f "$W/ctl/hang"

echo "== caught: a shell that stops answering and ignores TERM"
touch "$W/ctl/deaf"
kill -USR1 "$SUP"; sleep 2      # a clean restart: the new stub is deaf to TERM
old=$(spid)
sleep 8                          # the grace (6 s) is over
touch "$W/ctl/hang"
if wait_for 30 caught; then ok "the stall is caught"; else bad "the stall is caught"; fi
wait_for 40 grep -q "restart [0-9] of 5" "$SLOG"; sleep 2
new=$(spid)
d=$(ls -d "$W"/home/.local/state/lares/stalls/*/ 2> /dev/null | head -1)
check "the evidence dir exists" test -n "$d"
if [ -n "$d" ]; then
    check "  shell.log tail" test -s "$d/shell.log"
    check "  threads (comm, wchan, stat)" grep -q "comm=" "$d/threads.txt"
    check "  a real stack of the shell (Yama: the supervisor is its ptracer)" bash -c '! grep -qi "not permitted" "$1/stack.txt" && grep -q "#0" "$1/stack.txt"' _ "$d"
    check "  hyprctl layers / clients / activewindow" test -e "$d/hypr-layers.json" -a -e "$d/hypr-clients.json" -a -e "$d/hypr-activewindow.json"
fi
check "the deaf shell was KILLed" grep -q "ignored TERM: KILL" "$SLOG"
check "a new shell runs" test -n "$new" -a "$new" != "$old"
check "the user is told through hyprctl notify" grep -q "hyprctl notify" "$W/hypr.log"
check "shell-last.log was written" test -s "$W/home/.local/state/lares/shell-last.log"
check "the restart is counted (backoff line)" grep -q "restart [0-9] of 5" "$SLOG"

echo
if [ "$FAILS" -eq 0 ]; then echo "$NAME RESULT PASS"; exit 0; fi
echo "$NAME RESULT FAIL ($FAILS checks)"
exit 1
