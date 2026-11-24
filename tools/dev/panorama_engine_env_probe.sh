#!/usr/bin/env bash
# panorama_engine_env_probe.sh -- Panorama's engine (tools/panorama/engine.lua) inside a REAL nested Hyprland (lock_env.sh, OUTPUTS=2).
# It starts no quickshell. The driver is tools/dev/panorama_engine/env_probe.py.
#
#   tools/dev/panorama_engine_env_probe.sh              ends in PANORAMA_ENGINE_ENV RESULT PASS|FAIL
#   ARM=noguard    the trial's guard timer is never armed: "trial: no shell, guard reverts" goes red
#   ARM=nodedup    liveDiff always differs: "replug: no rule" goes red
#   ARM=nodefer    the focused active workspace moves at once: "deferred: focused active workspace waits" goes red
#   ARM=nosafety   the internal panel is not re-enabled by the handler: "safety: internal re-enabled by the handler" goes red
#   ARM=nohooked   a dofile registers the handlers again: "exactly one rule for it" goes red
#   ARM=mirrormove a workspace is moved onto an output that is still a mirror: "mirror revert: no warning" goes red
#   ARM=norulerun  a deferred workspace the user already moved is cleared without its rule: "deferred: satisfied by the user" goes red
#   ARM=nostraysweep  the sweep removes nothing: "cast: keep([]) sweeps" goes red
#   ARM=castkeepdrop  a reload forgets the names a live cast keeps: "cast: a reload keeps a live cast" goes red
#   ARM=castmirroron  a mirrored cast is mirrored, not off: "cast: mirror switches the output off" goes red
#   ARM=castnoext  a cast is no external for the split: "cast: workspaces 3 and 4 are the cast's" goes red
#   ARM=castopendup   one identity gets a second output: "cast: the same identity reuses its output" goes red
#   ARM=all        every arm in turn: PANORAMA_ENGINE_ENV ARMS PASS|FAIL
#   PANORAMA_ENGINE_ENV_KEEP=1 keeps the env up (LOCK_ENV=pe1; `tools/dev/lock_env.sh down`)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/dev/result_lib.sh"
export LOCK_ENV="${LOCK_ENV:-pe1}"
NAME=PANORAMA_ENGINE_ENV
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in noguard nodedup nodefer nosafety nohooked mirrormove norulerun nostraysweep castkeepdrop castmirroron castnoext castopendup; do
        out=$(ARM="$a" bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "ARM $a: failed at its check"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -a "ARM $a: failed at" | cut -c1-120))"
        else
            echo "ARM $a: NOT CAUGHT: $(printf '%s\n' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"; rc=1
        fi
    done
    echo "$NAME ARMS $([ $rc = 0 ] && echo PASS || echo FAIL)"
    exit $rc
fi
log="$(mktemp /tmp/pe_env.XXXXXX)"
trap 'rm -f "$log"' EXIT
python3 "$ROOT/tools/dev/panorama_engine/env_probe.py" > "$log" 2>&1
cat "$log"
[ -n "${ARM:-}" ] && exit 1
rl_result "$NAME" "$log" "$NAME RESULT .*" > /dev/null; exit $?
