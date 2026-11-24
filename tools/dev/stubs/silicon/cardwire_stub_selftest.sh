#!/usr/bin/env bash
# The stand-in for cardwire's D-Bus service (tools/dev/stubs/silicon/cardwire_stub.py), proved against the
# bytes the real daemon (0.12.3) printed.
#
#   tools/dev/stubs/silicon/cardwire_stub_selftest.sh     one `CW <check> PASS|FAIL` line per check, then
#                                                     CARDWIRE-STUB RESULT PASS | CARDWIRE-STUB RESULT FAIL (<checks>)
#   SCRATCH=<dir>                                     where the run's temporary directory goes (default $TMPDIR, /tmp)
#   CARDWIRE_STUB_UNDER_TEST=<file>                   prove a modified copy of the stub instead (a fault armed in it
#                                                     must turn a check red; the fixtures are read from this tree)
#
# Everything runs on the PRIVATE session bus of tools/dev/notifications_bus.sh (no activatable services), the
# script re-executes itself under it; the stub and the monitor are killed by the pids this script kept.
#
#   read.*      the ten read-only calls of cardwire/spike_replies.json, with the argv shape of the spike's
#               (busctl --user --json=short get-property | call): the bytes busctl prints equal the recorded ones
#               (GetAppPolicies: equal as parsed JSON -- the real daemon answers its hash map in any order)
#   gpu.*       the recorded Gpu/0 + Gpu/1 replies of stage0_facts.json (GetDevice as twelve out args, PowerState,
#               Lsof, Block, Launchable, Env) and the ProcessBlocked log, equal as parsed JSON
#   mode.*      set-property Mode: accepted for an available mode, refused (error text, value kept) for one that
#               is not, the daemon's words in the error, the CALL / SET / REFUSED log lines
#   config.*    set-property on Config / Gpu: accepted, and refused for a wrong D-Bus type, a read-only
#               property, an unknown property or interface
#   policy.*    SetAppPolicy: policy 1 shows in GetAppPolicies; 2, -1, an unknown app and a wrong signature fail
#   control.*   the Control interface: SetLsof, SetPolicies, SetConfig, refused arguments, EmitBlocked and
#               EmitNewApp reaching the reads, the power spellings (the method's "D3cold\n", the signal's 'D3Cold')
#   monitor.*   `gdbus monitor --session --dest org.opengamingcollective.cardwire`, started before the first
#               call: the two header lines, then one line per signal, in the order they were caused, each in
#               the shape of a real or typed-from-the-source line (monitor_lines.txt, spike_monitor_lines.txt)
#   log.*       the CARDWIRE_STUB_LOG lines (CALL / SET / EMIT / CONTROL)
#   dump.*      Dump / Reset round trip; Quit ends the process (exit 0)
#   guard.*     the stub refuses to start on a bus that is not the private one (both probes use made-up
#               addresses: nothing is ever connected to)
set -u
SELF="${BASH_SOURCE[0]}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"

if [ "${CW_SELFTEST_INNER:-}" != 1 ]; then
    exec "$ROOT/tools/dev/notifications_bus.sh" env CW_SELFTEST_INNER=1 bash "$HERE/$(basename "$SELF")" "$@"
fi

# Inner half: only ever on the private bus.
case "${DBUS_SESSION_BUS_ADDRESS:-}" in
    unix:path=/tmp/dbus-*|unix:abstract=/tmp/dbus-*) ;;
    *) echo "CARDWIRE-STUB RESULT FAIL (not on the private test bus: ${DBUS_SESSION_BUS_ADDRESS:-unset})"; exit 1 ;;
esac

BUSCTL=/usr/bin/busctl; [ -x "$BUSCTL" ] || BUSCTL=$(command -v busctl)
GDBUS=/usr/bin/gdbus;   [ -x "$GDBUS" ] || GDBUS=$(command -v gdbus)
FX="$ROOT/tools/dev/fixtures/silicon"
STUB="${CARDWIRE_STUB_UNDER_TEST:-$HERE/cardwire_stub.py}"      # a modified copy, to prove a check can fail
export CARDWIRE_STUB_FIXTURES="$FX"

SCR="${SCRATCH:-${TMPDIR:-/tmp}}"
mkdir -p "$SCR"
T=$(mktemp -d "$SCR/cardwire-stub-selftest.XXXXXX") || { echo "CARDWIRE-STUB RESULT FAIL (no temporary directory)"; exit 1; }
STUB_PID=""; MON_PID=""
# reap <pid>: TERM the process this script started, KILL it if it is still there 2 s later
reap() {
    local pid=$1 n=20
    kill "$pid" 2>/dev/null || return 0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}
cleanup() {
    [ -n "$MON_PID" ] && reap "$MON_PID"
    [ -n "$STUB_PID" ] && reap "$STUB_PID"
    rm -rf "$T"
}
trap cleanup EXIT

FAILED=()
pass() { echo "CW $1 PASS"; }
fail() { echo "CW $1 FAIL${2:+ ($2)}"; FAILED+=("$1"); }
# check <name> <detail shown on failure> <command...>
check() {
    local name=$1 detail=$2 said; shift 2
    if "$@" > "$T/check.out" 2> "$T/check.err"; then pass "$name"; return; fi
    said=$(cat "$T/check.out" "$T/check.err" | head -c 300 | tr '\n' ' ')
    fail "$name" "$detail${said:+; it said: $said}"
}

CW=org.opengamingcollective.cardwire
OBJ=/org/opengamingcollective/cardwire
G0=$OBJ/Gpu/0
G1=$OBJ/Gpu/1
CTLN=org.lares.CardwireStub
CTLO=/org/lares/cardwire_stub
CTLI=org.lares.CardwireStub.Control
bus() { "$BUSCTL" --user --json=short "$@"; }
ctl() { bus call "$CTLN" "$CTLO" "$CTLI" "$@"; }
LOG="$T/stub.log"

# --- what the real daemon printed, as files -------------------------------------------------------------
python3 - "$FX" "$T" <<'PY' || { echo "CARDWIRE-STUB RESULT FAIL (the recorded fixtures cannot be read)"; exit 1; }
import json, sys
fx, t = sys.argv[1:3]
spike = json.load(open(fx + "/cardwire/spike_replies.json"))
for k, v in spike.items():
    if not k.startswith("_"):
        open("%s/exp.%s" % (t, k), "w", newline="").write(v)
facts = json.load(open(fx + "/stage0_facts.json"))["cardwire"]
for n in "01":
    for m, r in facts["Gpu"][n].items():
        json.dump(r["json"], open("%s/exp.gpu%s.%s" % (t, n, m), "w"))
json.dump(facts["ProcessBlocked"]["json"], open(t + "/exp.blocked", "w"))
PY
printf '{"type":"s","data":["D3cold\\n"]}\n' > "$T/exp.d3cold"
printf '{"type":"s","data":["D0\\n"]}\n' > "$T/exp.d0"
printf '{"type":"s","data":["D3hot\\n"]}\n' > "$T/exp.d3hot"

# jsoneq <file> <file>: the same JSON value (objects compared unordered)
jsoneq() {
    python3 - "$1" "$2" <<'PY'
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
PY
}
# jget <file> <python expression of d>: print it
jget() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# wait_for <timeout tenths> <command...>: poll until the command succeeds
wait_for() { local n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done; return 1; }
has() { grep -q -E -- "$2" "$1" 2>/dev/null; }
log_has() { has "$LOG" "^[0-9]{13} $1\$"; }   # a whole line of the stub's log: <unix-ms> <what>
mode_is() { bus get-property "$CW" "$OBJ" "$CW.Mode" Mode > "$T/got.mode_is"; [ "$(cat "$T/got.mode_is")" = "{\"type\":\"u\",\"data\":$1}" ]; }
cfg_is() { bus get-property "$CW" "$OBJ" "$CW.Config" "$1" > "$T/got.cfg_is"; [ "$(cat "$T/got.cfg_is")" = "{\"type\":\"$2\",\"data\":$3}" ]; }
fails() { # fails <name> <command...>: the command exits non-zero and says something on stderr
    local name=$1; shift
    if "$@" > "$T/got.fails.out" 2> "$T/got.fails.err"; then echo "  [$name] succeeded, should have failed" >&2; return 1; fi
    [ -s "$T/got.fails.err" ] || { echo "  [$name] failed without an error text" >&2; return 1; }
    return 0
}
policy_of() { # <app>: its policy in a fresh GetAppPolicies
    bus call "$CW" "$OBJ" "$CW.SmartPolicy" GetAppPolicies > "$T/got.policy_of"
    jget "$T/got.policy_of" "d['data'][0]['$1'][3]"
}

# --- start the stub --------------------------------------------------------------------------------------
export CARDWIRE_STUB_LOG="$LOG"
python3 -B "$STUB" > "$T/stub.out" 2> "$T/stub.err" &
STUB_PID=$!
if ! wait_for 100 has "$T/stub.out" '^cardwire-stub ready$'; then
    sed 's/^/  stub: /' "$T/stub.err" | head -20
    echo "CARDWIRE-STUB RESULT FAIL (the stub did not become ready)"
    exit 1
fi
check ready.once "the ready line must be the only stdout line, printed once" [ "$(cat "$T/stub.out")" = "cardwire-stub ready" ]

# The monitor first: it must see every signal of the run. Its output goes to a file; it is killed by its pid.
"$GDBUS" monitor --session --dest "$CW" > "$T/monitor.out" 2> "$T/monitor.err" &
MON_PID=$!
wait_for 100 has "$T/monitor.out" '^The name .* is owned by ' || fail monitor.start "no header lines: $(head -c 300 "$T/monitor.err")"

DUMP0=$(ctl Dump | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"][0])')

# --- 1. the ten read-only calls, byte for byte -----------------------------------------------------------
read_check() { # <name> <expected file> <busctl argv...>
    local name=$1 exp=$2; shift 2
    bus "$@" > "$T/got.$name" 2> "$T/got.$name.err"
    if cmp -s "$T/got.$name" "$T/exp.$exp"; then pass "read.$name"; else fail "read.$name" "got: $(head -c 160 "$T/got.$name") $(head -c 160 "$T/got.$name.err")"; fi
}
read_check mode mode get-property "$CW" "$OBJ" "$CW.Mode" Mode
read_check modes modes call "$CW" "$OBJ" "$CW.Mode" AvailableModes
bus call "$CW" "$OBJ" "$CW.SmartPolicy" GetAppPolicies > "$T/got.policies" 2> "$T/got.policies.err"
check read.policies "GetAppPolicies differs from the recorded 26 apps (as parsed JSON)" jsoneq "$T/got.policies" "$T/exp.policies"
check read.policies.count "expected 26 apps" [ "$(jget "$T/got.policies" "len(d['data'][0])")" = 26 ]
read_check power power call "$CW" "$G1" "$CW.Gpu" PowerState
read_check lsof lsof call "$CW" "$G1" "$CW.Gpu" Lsof
for k in AutoApplyGpuState BatteryAutoSwitch BatteryAutoSwitchMode ExperimentalNvidiaBlock ExternalDisplayAutoSwitch; do
    read_check "cfg.$k" "cfg.$k" get-property "$CW" "$OBJ" "$CW.Config" "$k"
done

# --- 2. Gpu/0 + Gpu/1 as recorded ------------------------------------------------------------------------
for n in 0 1; do
    gp=$OBJ/Gpu/$n
    for m in GetDevice PowerState Lsof; do
        bus call "$CW" "$gp" "$CW.Gpu" "$m" > "$T/got.gpu$n.$m" 2>/dev/null
        check "gpu$n.$m" "differs from the recorded reply" jsoneq "$T/got.gpu$n.$m" "$T/exp.gpu$n.$m"
    done
    for p in Block Launchable Env; do
        bus get-property "$CW" "$gp" "$CW.Gpu" "$p" > "$T/got.gpu$n.$p" 2>/dev/null
        check "gpu$n.$p" "differs from the recorded reply" jsoneq "$T/got.gpu$n.$p" "$T/exp.gpu$n.$p"
    done
done
check gpu.getdevice.args "GetDevice must answer twelve separate out args (ssuubbbbssbs)" \
    [ "$(jget "$T/got.gpu1.GetDevice" "d['type']")" = ssuubbbbssbs ]
bus call "$CW" "$OBJ" "$CW.Logger" ProcessBlocked > "$T/got.blocked" 2>/dev/null
check gpu.processblocked "ProcessBlocked differs from the recorded log" jsoneq "$T/got.blocked" "$T/exp.blocked"

# --- 3. Mode ---------------------------------------------------------------------------------------------
check mode.set.available "set-property Mode u 3 must succeed" bus set-property "$CW" "$OBJ" "$CW.Mode" Mode u 3
check mode.set.readback "Mode must read 3 after the set" mode_is 3
check control.setavailable "SetAvailable [1]" ctl SetAvailable s '[1]'
check mode.keep.when.not.available "SetAvailable must not change the current Mode (3 is not in [1])" mode_is 3
check mode.refused "set-property Mode u 0 must fail with an error text while only [1] is available" \
    fails mode0 bus set-property "$CW" "$OBJ" "$CW.Mode" Mode u 0
cp "$T/got.fails.err" "$T/mode0.err"
check mode.refused.words "the error must carry the daemon's words" has "$T/mode0.err" "Couldn't set mode to Integrated.*discrete GPU"
check mode.refused.unchanged "Mode must still be 3 after the refused set" mode_is 3
check mode.refused.unknown "set-property Mode u 7 must fail" fails mode7 bus set-property "$CW" "$OBJ" "$CW.Mode" Mode u 7
check mode.refused.type "set-property Mode s hello must fail (wrong type)" fails modes bus set-property "$CW" "$OBJ" "$CW.Mode" Mode s hello
check control.setavailable.restore "SetAvailable [0,1,3]" ctl SetAvailable s '[0,1,3]'
check mode.refused.manual "set-property Mode u 2 must fail: Manual is not in AvailableModes [0,1,3]" \
    fails mode2 bus set-property "$CW" "$OBJ" "$CW.Mode" Mode u 2
check mode.unchanged.end "Mode must still be 3" mode_is 3
check log.mode.get "CALL of Properties.Get with the JSON args" \
    log_has 'CALL org\.freedesktop\.DBus\.Properties\.Get /org/opengamingcollective/cardwire \["org\.opengamingcollective\.cardwire\.Mode","Mode"\]'
check log.mode.call "CALL of AvailableModes" log_has 'CALL org\.opengamingcollective\.cardwire\.Mode\.AvailableModes /org/opengamingcollective/cardwire \[\]'
check log.mode.set "SET of the accepted value" log_has 'SET org\.opengamingcollective\.cardwire\.Mode\.Mode 3'
check log.mode.control "CONTROL SetAvailable" log_has 'CONTROL SetAvailable \["\[1\]"\]'
check log.mode.refused "SET ... REFUSED with the daemon's words" log_has 'SET org\.opengamingcollective\.cardwire\.Mode\.Mode 0 REFUSED Couldn.t set mode to Integrated.*'
check log.mode.refused.type "SET of a wrong-typed value is logged as REFUSED too" log_has 'SET org\.opengamingcollective\.cardwire\.Mode\.Mode "hello" REFUSED .*'

# --- 4. Config and Gpu properties ------------------------------------------------------------------------
check config.set "set-property Config BatteryAutoSwitch b true must succeed" \
    bus set-property "$CW" "$OBJ" "$CW.Config" BatteryAutoSwitch b true
check config.readback "BatteryAutoSwitch must read true" cfg_is BatteryAutoSwitch b true
check config.wrongtype "a wrong-typed set (s for b) must fail" fails cfg1 bus set-property "$CW" "$OBJ" "$CW.Config" BatteryAutoSwitch s hello
check config.wrongtype.u "a wrong-typed set (b for u) must fail" fails cfg2 bus set-property "$CW" "$OBJ" "$CW.Config" BatteryAutoSwitchMode b true
check config.unchanged "BatteryAutoSwitchMode must still be 1" cfg_is BatteryAutoSwitchMode u 1
check config.unknown "an unknown property must fail" fails cfg3 bus set-property "$CW" "$OBJ" "$CW.Config" NoSuchThing b true
check config.unknown.interface "an unknown interface must fail" fails cfg4 bus set-property "$CW" "$OBJ" "$CW.Gpu" Block b true
check config.readonly "Gpu.Launchable is read-only: a set must fail" fails cfg5 bus set-property "$CW" "$G1" "$CW.Gpu" Launchable b false
check config.block "Gpu/1 Block is writable" bus set-property "$CW" "$G1" "$CW.Gpu" Block b true
bus get-property "$CW" "$G1" "$CW.Gpu" Block > "$T/got.block"
check config.block.readback "Block must read true" [ "$(cat "$T/got.block")" = '{"type":"b","data":true}' ]
check config.block.restore "Block back to false" bus set-property "$CW" "$G1" "$CW.Gpu" Block b false

# --- 5. SetAppPolicy -------------------------------------------------------------------------------------
check policy.initial "btop starts at 0, the Steam game at 1" [ "$(policy_of btop)/$(policy_of steam_app_1295660)" = 0/1 ]
check policy.set "SetAppPolicy btop 1 must succeed" bus call "$CW" "$OBJ" "$CW.SmartPolicy" SetAppPolicy si btop 1
check policy.readback "GetAppPolicies must show 1 for btop" [ "$(policy_of btop)" = 1 ]
check policy.others "the other apps keep their policy (kitty 0)" [ "$(policy_of kitty)" = 0 ]
check policy.two "policy 2 must fail" fails pol2 bus call "$CW" "$OBJ" "$CW.SmartPolicy" SetAppPolicy si btop 2
check policy.negative "policy -1 must fail" fails pol3 bus call "$CW" "$OBJ" "$CW.SmartPolicy" SetAppPolicy si btop -1
check policy.unknown "an unknown app must fail" fails pol4 bus call "$CW" "$OBJ" "$CW.SmartPolicy" SetAppPolicy si no-such-app 0
check policy.signature "a wrong signature (su) must fail" fails pol5 bus call "$CW" "$OBJ" "$CW.SmartPolicy" SetAppPolicy su btop 1
check policy.kept "btop is still 1 after the refused calls" [ "$(policy_of btop)" = 1 ]
noops() {
    bus call "$CW" "$OBJ" "$CW.Config" SaveToFile && bus call "$CW" "$OBJ" "$CW.Debug" RefreshGpu \
        && bus call "$CW" "$OBJ" "$CW.Manager" Status && bus call "$CW" "$OBJ" "$CW.SmartPolicy" RequestProcessAccess usu 1 Allow_dGPU 1
}
check policy.noops "SaveToFile, RefreshGpu, Status, RequestProcessAccess are accepted" noops

# --- 6. the control interface and the signals ------------------------------------------------------------
ctl EmitPowerState s D3cold > /dev/null
bus call "$CW" "$G1" "$CW.Gpu" PowerState > "$T/got.pw1"
check control.power.d3cold "PowerState after EmitPowerState D3cold is exactly \"D3cold\\n\"" cmp -s "$T/got.pw1" "$T/exp.d3cold"
ctl EmitPowerState s D0 > /dev/null
bus call "$CW" "$G1" "$CW.Gpu" PowerState > "$T/got.pw2"
check control.power.d0 "PowerState after EmitPowerState D0 is exactly \"D0\\n\"" cmp -s "$T/got.pw2" "$T/exp.d0"
ctl SetMode u 0 > /dev/null
check control.setmode "SetMode 0 skips the availability check and sets Mode" mode_is 0
ctl EmitBlocked usus 4242 blender 1 org.blender.Blender > /dev/null
bus call "$CW" "$OBJ" "$CW.Logger" ProcessBlocked > "$T/got.blocked2" 2>/dev/null
check control.blocked.count "EmitBlocked appends to ProcessBlocked (one more than recorded)" \
    [ "$(jget "$T/got.blocked2" "len(d['data'][0])")" = "$(( $(jget "$T/exp.blocked" "len(d['data'][0])") + 1 ))" ]
check control.blocked.entry "the new entry is ((secs, nanos), 4242, 'blender', 1, 'org.blender.Blender') stamped now" \
    python3 - "$T/got.blocked2" <<'PY'
import json, sys, time
e = json.load(open(sys.argv[1]))["data"][0][-1]
ok = e[1:] == [4242, "blender", 1, "org.blender.Blender"] and abs(e[0][0] - time.time()) < 60 and 0 <= e[0][1] < 10**9
sys.exit(0 if ok else 1)
PY
ctl EmitNewApp ssu blender Blender 0 > /dev/null
check control.newapp "EmitNewApp adds the app (desktopIds [id], icons [])" \
    [ "$(bus call "$CW" "$OBJ" "$CW.SmartPolicy" GetAppPolicies | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin)["data"][0]["blender"]))')" = '["Blender", ["blender"], [], 0]' ]
ctl SetConfig ss BatteryAutoSwitchMode 0 > /dev/null
check control.setconfig "SetConfig BatteryAutoSwitchMode 0" cfg_is BatteryAutoSwitchMode u 0
ctl EmitPowerState s d3HOT > /dev/null
bus call "$CW" "$G1" "$CW.Gpu" PowerState > "$T/got.pw3"
check control.power.case "EmitPowerState takes any case; PowerState says \"D3hot\\n\"" cmp -s "$T/got.pw3" "$T/exp.d3hot"
check control.power.bad "EmitPowerState D4 is refused" fails ctlbad1 ctl EmitPowerState s D4
check control.available.bad "SetAvailable with text that is not a JSON array is refused" fails ctlbad2 ctl SetAvailable s 'nonsense'
check control.config.bad "SetConfig with the wrong JSON type is refused" fails ctlbad3 ctl SetConfig ss BatteryAutoSwitch 1
check control.config.badkey "SetConfig of an unknown key is refused" fails ctlbad4 ctl SetConfig ss Nope true
check control.lsof.bad "SetLsof with a non-object is refused" fails ctlbad5 ctl SetLsof s '[1]'
check control.policies.bad "SetPolicies with a malformed entry is refused" fails ctlbad6 ctl SetPolicies s '{"x":["only a name"]}'
check control.unchanged.after.bad "the refused control calls changed nothing (BatteryAutoSwitch still true)" cfg_is BatteryAutoSwitch b true
ctl SetLsof s '{"/dev/nvidia0":["cardwired","nvidia-smi"],"/dev/dri/card0":[]}' > /dev/null
bus call "$CW" "$G1" "$CW.Gpu" Lsof > "$T/got.lsof2"
check control.setlsof "SetLsof replaces Gpu/1's Lsof table, in the order given" \
    [ "$(cat "$T/got.lsof2")" = '{"type":"a{sas}","data":[{"/dev/nvidia0":["cardwired","nvidia-smi"],"/dev/dri/card0":[]}]}' ]
ctl SetPolicies s '{"mpv":["mpv Media Player",["mpv"],["mpv"],1],"zzz":["Z",[],[],0]}' > /dev/null
bus call "$CW" "$OBJ" "$CW.SmartPolicy" GetAppPolicies > "$T/got.policies2"
check control.setpolicies "SetPolicies replaces the whole table" \
    [ "$(jget "$T/got.policies2" "sorted(d['data'][0])")" = "['mpv', 'zzz']" ]
bus call "$CW" "$OBJ" "$CW.SmartPolicy" GetProcessStatus u 1234 > "$T/got.status"
check control.processstatus "GetProcessStatus answers two out args (s, au)" [ "$(jget "$T/got.status" "d['type']")" = sau ]

# The monitor: header lines, then one line per signal, in the order the signals were caused.
EXPECT=13        # the two header lines + eleven signals (the list below)
wait_for 100 bash -c '[ "$(wc -l < "$1")" -ge "$2" ]' _ "$T/monitor.out" "$EXPECT"
sleep 0.3        # a stray extra line would land now
cp "$T/monitor.out" "$T/monitor.snapshot"
python3 - "$T/monitor.snapshot" "$FX" <<'PY'
import re, sys

mon = open(sys.argv[1]).read().splitlines()
fx = sys.argv[2]
P = r"/org/opengamingcollective/cardwire"
PC = P + r": org\.freedesktop\.DBus\.Properties\.PropertiesChanged "
exp = [
    r"^Monitoring signals from all objects owned by org\.opengamingcollective\.cardwire$",
    r"^The name org\.opengamingcollective\.cardwire is owned by :\d+\.\d+$",
    "^" + PC + r"\('org\.opengamingcollective\.cardwire\.Mode', \{'Mode': <uint32 3>\}, @as \[\]\)$",
    "^" + PC + r"\('org\.opengamingcollective\.cardwire\.Config', \{'BatteryAutoSwitch': <true>\}, @as \[\]\)$",
    "^" + P + r"/Gpu/1: org\.freedesktop\.DBus\.Properties\.PropertiesChanged \('org\.opengamingcollective\.cardwire\.Gpu', \{'Block': <true>\}, @as \[\]\)$",
    "^" + P + r"/Gpu/1: org\.freedesktop\.DBus\.Properties\.PropertiesChanged \('org\.opengamingcollective\.cardwire\.Gpu', \{'Block': <false>\}, @as \[\]\)$",
    "^" + P + r"/Gpu/1: org\.opengamingcollective\.cardwire\.Gpu\.PowerStateChanged \('D3Cold',\)$",
    "^" + P + r"/Gpu/1: org\.opengamingcollective\.cardwire\.Gpu\.PowerStateChanged \('D0',\)$",
    "^" + PC + r"\('org\.opengamingcollective\.cardwire\.Mode', \{'Mode': <uint32 0>\}, @as \[\]\)$",
    "^" + P + r": org\.opengamingcollective\.cardwire\.Logger\.ProcessBlockedChanged "
        r"\(\(\(uint64 \d+, uint32 \d+\), uint32 4242, 'blender', uint32 1, 'org\.blender\.Blender'\),\)$",
    "^" + P + r": org\.opengamingcollective\.cardwire\.SmartPolicy\.NewAppAdded "
        r"\(\('blender', \('Blender', \['blender'\], @as \[\], uint32 0\)\),\)$",
    "^" + PC + r"\('org\.opengamingcollective\.cardwire\.Config', \{'BatteryAutoSwitchMode': <uint32 0>\}, @as \[\]\)$",
    "^" + P + r"/Gpu/1: org\.opengamingcollective\.cardwire\.Gpu\.PowerStateChanged \('D3Hot',\)$",
]
problems = []
if len(mon) != len(exp):
    problems.append("expected %d lines, the monitor printed %d" % (len(exp), len(mon)))
for i, (line, rx) in enumerate(zip(mon, exp)):
    if not re.match(rx, line):
        problems.append("line %d: %r does not match %s" % (i + 1, line, rx))


def shape(line):
    line = re.sub(r"^(/org/opengamingcollective/cardwire)/Gpu/\d+: (org\.freedesktop\.DBus\.Properties)", r"\1: \2", line)
    line = re.sub(r"<(true|false)>", "<B>", line)
    return re.sub(r"[0-9]+", "N", re.sub(r"'[^']*'", "S", line))


real = set()
for name in ("monitor_lines.txt", "spike_monitor_lines.txt"):
    for l in open("%s/cardwire/%s" % (fx, name)).read().splitlines():
        if l and not l.startswith("#"):
            # the typed-from-the-source ProcessBlockedChanged line is on /Logger; the daemon's own signal comes
            # from the root object (what the stub was told to do)
            real.add(shape(l.replace("/org/opengamingcollective/cardwire/Logger:", "/org/opengamingcollective/cardwire:")))
for line in mon:
    if shape(line) not in real:
        problems.append("shape of %r is not among the real / typed shapes" % line)
for p in problems:
    print("  monitor: " + p)
sys.exit(1 if problems else 0)
PY
mrc=$?
[ "$mrc" = 0 ] && pass monitor.lines || fail monitor.lines "see the lines above; the monitor printed $(wc -l < "$T/monitor.snapshot") lines"
kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null; MON_PID=""

# --- the log ---------------------------------------------------------------------------------------------
check log.emit.power "EMIT PowerStateChanged from Gpu/1 with the Debug spelling" \
    log_has 'EMIT org\.opengamingcollective\.cardwire\.Gpu\.PowerStateChanged /org/opengamingcollective/cardwire/Gpu/1 \["D3Cold"\]'
check log.emit.mode "EMIT PropertiesChanged for Mode" \
    log_has 'EMIT org\.freedesktop\.DBus\.Properties\.PropertiesChanged /org/opengamingcollective/cardwire \["org\.opengamingcollective\.cardwire\.Mode",\{"Mode":0\},\[\]\]'
check log.emit.blocked "EMIT ProcessBlockedChanged from the root object" \
    log_has 'EMIT org\.opengamingcollective\.cardwire\.Logger\.ProcessBlockedChanged /org/opengamingcollective/cardwire \[\[\[[0-9]+,[0-9]+\],4242,"blender",1,"org\.blender\.Blender"\]\]'
check log.emit.newapp "EMIT NewAppAdded" \
    log_has 'EMIT org\.opengamingcollective\.cardwire\.SmartPolicy\.NewAppAdded /org/opengamingcollective/cardwire \[\["blender",\["Blender",\["blender"\],\[\],0\]\]\]'
check log.control "CONTROL lines carry the method and its JSON args" log_has 'CONTROL EmitBlocked \[4242,"blender",1,"org\.blender\.Blender"\]'
check log.control.refused "a refused control call is logged with REFUSED" log_has 'CONTROL EmitPowerState \["D4"\] REFUSED .*'
check log.set.config "SET of a Config property" log_has 'SET org\.opengamingcollective\.cardwire\.Config\.BatteryAutoSwitch true'
check log.set.config.refused "SET of a Config property with a wrong type, REFUSED" \
    log_has 'SET org\.opengamingcollective\.cardwire\.Config\.BatteryAutoSwitch "hello" REFUSED .*'
check log.call.policy "CALL SetAppPolicy with its JSON args" log_has 'CALL org\.opengamingcollective\.cardwire\.SmartPolicy\.SetAppPolicy /org/opengamingcollective/cardwire \["btop",1\]'

# --- 7. Dump / Reset / Quit ------------------------------------------------------------------------------
dump_now() { ctl Dump | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"][0])'; }
DUMP1=$(dump_now)
echo "$DUMP1" > "$T/dump1.json"
check dump.keys "Dump carries mode, available, config, policies, power, lsof, blocked" \
    python3 - "$T/dump1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if all(k in d for k in ("mode", "available", "config", "policies", "power", "lsof", "blocked")) else 1)
PY
check dump.state "Dump reflects the run (Mode 0, power D3hot, btop 0 -> table replaced, Lsof replaced)" \
    python3 - "$T/dump1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = (d["mode"] == 0 and d["power"] == "D3hot" and sorted(d["policies"]) == ["mpv", "zzz"]
      and d["config"]["BatteryAutoSwitch"] is True and "/dev/nvidia0" in d["lsof"] and len(d["blocked"]) == 182
      and d["calls"].get("org.opengamingcollective.cardwire.Mode.AvailableModes", 0) >= 1)
sys.exit(0 if ok else 1)
PY
echo "$DUMP0" > "$T/dump0.json"
check dump.differs "the mutated state differs from the initial one" bash -c '! cmp -s "$1" "$2"' _ "$T/dump0.json" "$T/dump1.json"
ctl Reset > /dev/null
dump_now > "$T/dump2.json"
check dump.reset "Reset brings back the initial state (Dump equals the first one, byte for byte)" cmp -s "$T/dump0.json" "$T/dump2.json"
for f in power lsof; do
    bus call "$CW" "$G1" "$CW.Gpu" "$([ "$f" = power ] && echo PowerState || echo Lsof)" > "$T/got.after.$f"
    check "dump.reset.$f" "Gpu/1 ${f} reads as recorded after Reset" cmp -s "$T/got.after.$f" "$T/exp.$f"
done
check dump.reset.mode "Mode reads 1 after Reset" mode_is 1

# --- the guard (made-up addresses: nothing is connected to) ----------------------------------------------
for variant in unset realish; do
    if [ "$variant" = unset ]; then
        env -u DBUS_SESSION_BUS_ADDRESS python3 -B "$STUB" > "$T/g.out" 2> "$T/g.err"; grc=$?
    else
        DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/cardwire-stub-guard-test/bus" python3 -B "$STUB" > "$T/g.out" 2> "$T/g.err"; grc=$?
    fi
    check "guard.$variant" "must exit 2 with a refusal on stderr and nothing on stdout (rc=$grc)" \
        bash -c '[ "$1" = 2 ] && grep -q "refusing to run" "$2" && [ ! -s "$3" ]' _ "$grc" "$T/g.err" "$T/g.out"
done

# --- Quit ------------------------------------------------------------------------------------------------
ctl Quit > /dev/null
gone() { ! kill -0 "$STUB_PID" 2>/dev/null; }
if wait_for 30 gone; then
    wait "$STUB_PID"; src=$?
    STUB_PID=""
    check dump.quit "Quit ends the process with exit 0 (rc=$src)" [ "$src" = 0 ]
else
    fail dump.quit "the stub is still running 3 s after Quit"
fi

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "CARDWIRE-STUB RESULT PASS"
    exit 0
fi
echo "CARDWIRE-STUB RESULT FAIL (${FAILED[*]})"
exit 1
