#!/usr/bin/env bash
# The REAL tools/aerial/aerial-helper against a FAKE WORLD: a private dbus-daemon with a fake NetworkManager + BlueZ AgentManager
# (tools/aerial/fake_nm.py), stub protonvpn / ping / iw that replay the captured outputs, a local HTTP stub for the check URL and
# Cloudflare's speed endpoints. Never the machine's bus, never the internet.
#
#   tools/dev/aerial_helper_probe.sh                 ends in AERIAL_HELPER RESULT PASS|FAIL (exit status follows)
#   ARM=<name> tools/dev/aerial_helper_probe.sh      a fault in a COPY of tools/aerial; must FAIL on its needle
#   ARM=all                                          every ARM; AERIAL_HELPER ARMS RESULT PASS when each failed as it must
#     trustexit   believes the CLI's exit status       -> "proton disconnect that exits 1 is a success"
#     blockcall   a SYNCHRONOUS NetworkManager call     -> "a stuck RequestScan does not stall the loop"
#     dupprofile  add_activate makes a profile always   -> "add_activate on a known SSID makes no second profile"
#     follow302   the portal redirect is followed       -> "a 302 is a portal and is not followed"
#     printsecret every command line is logged          -> "no secret outside the secrets reply"
#     onetry      a pad is tried once (the old rule)    -> "pad gateway: one lost ping then an answer is ok"
#     askslocked  a read runs the CLI whatever the keyring  -> "keyring: locked, the shell's own reads run no CLI"
#     onesight    the keyring is looked at only once     -> "keyring: opened with no signal (as PAM does it), the helper says so by itself"
# Run it in a sandbox copy: SANDBOX=/tmp/lares-sbx-aerial-h tools/dev/sandbox.sh tools/dev/aerial_helper_probe.sh
# The world: every process carries AERIAL_PROBE=<work dir> in its environment and is found through /proc/<pid>/environ at the end
# (never by name). The run starts under `env -i`: the desktop's session bus, display and runtime dir never reach it.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
NAME=AERIAL_HELPER
# shellcheck source=tools/dev/result_lib.sh
. tools/dev/result_lib.sh

reap_world() {
    local w=$1 p pids left
    for _ in 1 2 3; do
        pids=""
        for p in /proc/[0-9]*; do
            [ -O "$p" ] || continue
            { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "AERIAL_PROBE=$w" && pids="$pids ${p#/proc/}"
        done
        [ -z "$pids" ] && break
        # shellcheck disable=SC2086
        kill -TERM $pids 2> /dev/null
        sleep 0.4
        left=""
        for p in $pids; do [ -d "/proc/$p" ] && left="$left $p"; done
        # shellcheck disable=SC2086
        [ -n "$left" ] && kill -KILL $left 2> /dev/null
    done
    if [ -n "${KEEP:-}" ]; then echo "(kept: $w)"; else rm -rf "$w"; fi
}

arm_needle() {
    case $1 in
        trustexit)   echo "proton disconnect that exits 1 is a success" ;;
        blockcall)   echo "a stuck RequestScan does not stall the loop" ;;
        dupprofile)  echo "add_activate on a known SSID makes no second profile" ;;
        follow302)   echo "a 302 is a portal and is not followed" ;;
        printsecret) echo "no secret outside the secrets reply" ;;
        onetry)      echo "pad gateway: one lost ping then an answer is ok" ;;
        askslocked)  echo "keyring: locked, the shell's own reads run no CLI" ;;
        onesight)    echo "keyring: opened with no signal (as PAM does it), the helper says so by itself" ;;
    esac
}

arm_patch() {   # arm_patch <tools/aerial copy> <arm>: a lost anchor stops the run
    python3 -I - "$1" "$2" << 'PY'
import sys
d, arm = sys.argv[1:3]
def patch(old, new):
    p = d + "/aerial-helper"
    s = open(p).read()
    if s.count(old) != 1:
        print("ARM anchor FAIL (%d matches): %r" % (s.count(old), old[:80])); sys.exit(3)
    open(p, "w").write(s.replace(old, new))
    print("ARM step ok: %s" % old[:60].replace("\n", "\\n"))
if arm == "trustexit":
    patch('        ok = bool(re.search(r"\\bDisconnected\\b", out))\n        if ok:', '        ok = rc == 0\n        if ok:')
elif arm == "blockcall":
    patch('    nm_call(wp, NM_WIFI, "RequestScan", "a{sv}", (a_sv(),), lambda: reply(True), bad)',
          '    try:\n        BUS.call_blocking(NM_NAME, wp, NM_WIFI, "RequestScan", "a{sv}", (a_sv(),), timeout=4)\n        reply(True)\n    except Exception as e:\n        bad(e)')
elif arm == "dupprofile":
    patch('    if existing and not msg.get("new"):', '    if False and existing:')
elif arm == "follow302":
    patch('            return ("portal", "", r.getheader("Location", "") or "")', '            return http_check(r.getheader("Location", ""))')
elif arm == "printsecret":
    patch('    try:\n        msg = json.loads(line)', '    log("debug", "cmd: " + line)\n    try:\n        msg = json.loads(line)')
elif arm == "onetry":
    patch('PAD_TRIES = {"gateway": 3, "dns": 2, "net": 2}', 'PAD_TRIES = {}')
elif arm == "askslocked":
    patch('    if action in PROTON_READS:\n        keyring_locked(go)', '    if False:\n        keyring_locked(go)')
elif arm == "onesight":
    patch('        if locked:\n            GLib.timeout_add(KEYRING_POLL_MS, guarded(look))\n            return', '        if locked:\n            return')
else:
    print("no such ARM: " + arm); sys.exit(3)
PY
}

judge_arm() {
    local arm=$1 log=$2 needle
    needle=$(arm_needle "$arm")
    if ! rl_clean "$log" | grep -a -q "^$NAME RESULT " || rl_clean "$log" | grep -a -q "^$NAME RESULT FAIL (no result"; then
        echo "$NAME ARM $arm BAD (the armed copy printed no RESULT: it did not run to its end: $log)"; return 1
    fi
    if ! rl_clean "$log" | grep -a -q "^$NAME RESULT FAIL"; then echo "$NAME ARM $arm BAD (it PASSED: the fault is not caught)"; return 1; fi
    if ! rl_clean "$log" | grep -a "^  FAIL" | grep -aqF -- "$needle"; then
        echo "$NAME ARM $arm BAD (failed, but not on '$needle'):"; rl_clean "$log" | grep -a "^  FAIL" | head -5; return 1
    fi
    echo "$NAME ARM $arm FAILED AS IT MUST ('$needle')"
}

one() {   # one [arm]
    local arm=${1:-} W LOG rc tree=$ROOT
    W=$(mktemp -d /tmp/lra.XXXXXX) || exit 1
    chmod 700 "$W"
    LOG=$W/probe.log
    # shellcheck disable=SC2064
    trap "reap_world '$W'" RETURN
    mkdir -p "$W/home" "$W/cache" "$W/stub"
    if [ -n "$arm" ]; then
        tree=$W/tree
        mkdir -p "$tree/tools"
        cp -r "$ROOT/tools/aerial" "$tree/tools/"
        find "$tree" -name __pycache__ -prune -exec rm -rf {} +
        arm_patch "$tree/tools/aerial" "$arm" > "$W/arm.log" 2>&1 || { cat "$W/arm.log"; echo "$NAME ARM $arm BAD (its anchor is gone)"; return 1; }
    fi
    env -i HOME="$W/home" PATH="$ROOT/tools/dev/stubs/aerial:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 TERM=dumb \
        XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/home/state" XDG_CONFIG_HOME="$W/home/config" XDG_RUNTIME_DIR="$W" \
        AERIAL_PROBE="$W" AERIAL_STUB_DIR="$W/stub" AERIAL_FIXTURES="$ROOT/modules/aerial/data/fixtures" \
        W="$W" TREE="$tree" ROOT="$ROOT" \
        timeout -k 5 300 python3 "$ROOT/tools/dev/aerial_helper_probe.py" > "$LOG" 2>&1
    rc=$?
    grep -a -v "^$NAME RESULT" "$LOG"
    [ "$rc" -ne 0 ] && [ -z "$arm" ] && [ -s "$W/fake.err" ] && { echo "(fake_nm stderr:)"; head -20 "$W/fake.err"; }
    if [ -n "$arm" ]; then judge_arm "$arm" "$LOG"; return $?; fi
    rl_result "$NAME" "$LOG"
}

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in trustexit blockcall dupprofile follow302 printsecret onetry askslocked onesight; do
        out=$(one "$a" 2>&1)
        echo "$out" | grep -a "^$NAME ARM"
        rl_isnoresult "$out" && bad=1
        echo "$out" | grep -aq "FAILED AS IT MUST" || bad=1
    done
    if [ $bad -eq 0 ]; then echo "$NAME ARMS RESULT PASS"; else echo "$NAME ARMS RESULT FAIL"; exit 1; fi
else
    one "${ARM:-}"
fi
