#!/usr/bin/env bash
# shell_lockwait_probe.sh -- A LOCK THAT ENDED BEFORE IT SPOKE DOES NOT HOLD THE BAR, in tools/dev/lock_env.sh's nested Hyprland.
#
# The user's relog in dGPU-only (2026-11-15): the boot lock unlocked by face 6 s into the shell's QML load, before the shell's socket
# existed, and its supervisor's flock was still held for an instant when the shell's window asked `lares-lock-held`. Asked once, the
# shell held its bar out of sight for the whole lockWaitMs (5 s) waiting for a word that could not come any more: "LARES shown eDP-1
# 5003 ms after its first frame (whole, the lock never spoke)". ShellScreen now asks again every lockRecheckMs while it waits.
#
# The scene: the REAL shell.qml (mock services, SHELL_LOCK=live: it listens on the lock's socket) in the env, and the lock's flock
# ($XDG_RUNTIME_DIR/lares-lock.lock) held by a stand-in (`flock`) that never dials the shell and lets go HOLD_MS after the shell's
# window has asked (a line the test copy prints). Checks:
#   asked     the window found the flock held (the scenario happened)
#   prompt    the bar is shown within GRACE_MS of the flock's release, not after the lock wait ran out ("the lock never spoke")
# One line per check, then SHELL_LOCKWAIT RESULT PASS|FAIL.
#
#   ARM=norecheck   the window asks once (the old code)          prompt: "the lock never spoke"
#   ARM=all         every arm above, each must fail on its needle: SHELL_LOCKWAIT ARMS RESULT PASS|FAIL
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "${ARM:-}" = all ]; then
    out=$(ARM=norecheck "$0" 2>&1); echo "$out" | sed 's/^/  norecheck: /'
    if echo "$out" | grep -q '^prompt    FAIL (the lock never spoke'; then echo "SHELL_LOCKWAIT ARMS RESULT PASS (norecheck failed as it must)"
    else echo "SHELL_LOCKWAIT ARMS RESULT FAIL (norecheck did not fail on its needle)"; exit 1; fi
    exit 0
fi
. "$ROOT/tools/dev/lock_a1_lib.sh"
HOLD_MS="${HOLD_MS:-1200}"
GRACE_MS="${GRACE_MS:-1500}"
A1_ENV_PREFIX="" a1_init "${LW_ENV:-lockwait}"
SHPID=""; HOLDPID=""
cleanup() {
    [ -n "$SHPID" ] && kill "$SHPID" 2> /dev/null
    [ -n "$HOLDPID" ] && kill "$HOLDPID" 2> /dev/null
    a1_down > /dev/null 2>&1
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
OUT="${OUT:-${SCRATCH:-/tmp}/lockwait}"
mkdir -p "$OUT"
fail() { echo "SHELL_LOCKWAIT RESULT FAIL ($1)"; exit 1; }

rm -rf "$T"; mkdir -p "$T"
rsync -a --exclude '.git' --exclude '.qmlls.ini' --exclude '.claude' --exclude 'screenshots' "$ROOT/" "$T/" || fail "copy"
a1_patch modules/shell/ShellScreen.qml '            win._lockHeld = code === 0 ? 1 : 0;' \
    '            win._lockHeld = code === 0 ? 1 : 0;
            console.log("LOCKWAIT held=" + win._lockHeld + " t=" + Date.now());' || fail "record anchor"
case "${ARM:-}" in
    "") ;;
    norecheck) a1_patch modules/shell/ShellScreen.qml '            lockRecheck.start();' '' || fail "arm anchor" ;;
    *) fail "unknown ARM=$ARM" ;;
esac
[ -n "${ARM:-}" ] && echo "  ARMED $ARM"

"$E" down > /dev/null 2>&1
env MODE=light "$E" up > /dev/null || fail "env up"
sleep 1
RT="$B/rt"
rm -f "$W/go"
# the stand-in lock: takes the flock, waits for `go`, holds HOLD_MS more, lets go
"$E" run flock -x "$RT/lares-lock.lock" sh -c "while [ ! -e '$W/go' ]; do sleep 0.02; done; sleep $(awk "BEGIN{print $HOLD_MS/1000}")" > /dev/null 2>&1 &
HOLDPID=$!
sleep 0.5
log="$OUT/shell.log"
"$E" run env SHELL_SERVICES=mock SHELL_LOCK=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$T/shell.qml" > "$log" 2>&1 &
SHPID=$!
clean() { sed 's/\x1b\[[0-9;]*m//g' "$log"; }
for _ in $(seq 1 600); do clean | grep -aq 'LOCKWAIT held=\|Failed to load' && break; sleep 0.1; done
clean | grep -aq 'Failed to load' && { clean | grep -a ERROR | head -5; fail "the shell does not load"; }
asked=$(clean | grep -ao 'LOCKWAIT held=[01] t=[0-9]*' | head -1)
touch "$W/go"
release=$(( $(date +%s%3N) + HOLD_MS ))
for _ in $(seq 1 120); do clean | grep -aq 'LARES shown' && break; sleep 0.1; done
shown=$(clean | grep -a 'LARES shown' | head -1 | sed 's/.*qml: //')
fails=0
case "$asked" in
    "LOCKWAIT held=1"*) echo "asked     PASS (the window found the flock held)" ;;
    *) echo "asked     FAIL (the window did not find the flock held: '${asked:-no answer}'; the scenario did not happen)"; fails=1 ;;
esac
# the shown line says how long after the window's first frame; compare its wall time with the release through the log's order:
# the shell prints `LARES shown` once; its time is taken here as the moment it appeared in the log (polled every 100 ms)
t_shown=$(date +%s%3N)
echo "  $shown"
case "$shown" in
    *"the lock never spoke"*) echo "prompt    FAIL (the lock never spoke: the bar waited the whole lock wait)"; fails=1 ;;
    "") echo "prompt    FAIL (no LARES shown line)"; fails=1 ;;
    *) late=$(( t_shown - release ))
       if [ "$late" -gt "$GRACE_MS" ]; then echo "prompt    FAIL (shown ${late} ms after the flock let go; grace ${GRACE_MS})"; fails=1
       else echo "prompt    PASS (shown about ${late} ms after the flock let go)"; fi ;;
esac
[ "$fails" = 0 ] && echo "SHELL_LOCKWAIT RESULT PASS" || { echo "SHELL_LOCKWAIT RESULT FAIL"; exit 1; }
