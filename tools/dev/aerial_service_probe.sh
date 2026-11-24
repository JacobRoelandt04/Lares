#!/usr/bin/env bash
# aerial's data layer end to end, headless, on a FAKE machine, in the sandbox: the pure model under node, then AerialService (live) against
# tools/dev/aerial_helper_stub.py, a fake Bluetooth source and private /proc files, and AerialMock.
#
#   tools/dev/aerial_service_probe.sh               last line: AERIAL_SERVICE RESULT PASS|FAIL
#   ARM=<name> tools/dev/aerial_service_probe.sh    a fault put into the SANDBOX copy of the data layer; the run must end FAIL
#   ARM=all tools/dev/aerial_service_probe.sh       every ARM below; AERIAL_SERVICE ARMS PASS when each one failed
#
#     noparity       the mock loses an intent (btRename)                              -> parity.mock FAILS
#     trustall       a profile the first run did not know is Trusted                  -> trust.later.run.old.trusted.new.public FAILS
#     flap           a signal band is judged with no memory of the previous band     -> band.noise.holds FAILS (and the node band.noflap)
#     portalrace     the tunnel is raised while a login page is up                    -> auto.portal.up.NET.ok.still.waits FAILS
#     dummyprimary   Proton's pvpn-killswitch dummy is taken for a network / link      -> dummy.not.the.network FAILS
#     dayms          day keys by adding 86 400 000 ms                                  -> the node DST cases FAIL
#     pile           a repeat of an error gets a NEW toast key (a second toast)        -> toast.repeat.one.key FAILS
#     fastestalways  every tunnel is "fastest"                                        -> fast.country.is.not FAILS
#     nopersistfast  the fastest server is not written                                -> fast.restart.facts FAILS
#     noretest       a failed pad is never asked again by itself                      -> retest.asks.again.by.itself FAILS
#     quietshown     the quiet re-test shows the helper's `testing`                   -> retest.still.failing.stays.fail.no.testing FAILS
#     deafkeyring    an opened keyring asks nothing again                              -> keyring.open.asks.again FAILS
#     persist        an error is never pruned: it stays in a fact a part would draw    -> error.cause.gone.net FAILS
#
# Nothing here touches the machine: private XDG dirs, a stub for the helper, a fake adapter, a stub opener, `true` for rfkill and pactl.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_SERVICE

if [ "${ARM:-}" = all ] && [ -z "${AS_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-noparity trustall flap portalrace dummyprimary dayms pile persist fastestalways nopersistfast noretest quietshown deafkeyring}; do
        sb="/tmp/lares-sbx-aerial-s-arm-$a"
        res=$(ARM=$a SANDBOX="$sb" SCRATCH="${SCRATCH:-}" ONLY_ARMS='' bash tools/dev/aerial_service_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then
            echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then
            echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then
            echo "  ARM $a: PASSED (it must fail)"; bad=1
        else
            echo "  ARM $a: failed as it must ($(printf '%s\n' "$res" | grep -c ' FAIL') red: $(printf '%s\n' "$res" | grep ' FAIL' | head -3 | sed 's/^AS //; s/  .*//' | tr '\n' ';'))"
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi

if [ -e .git ] && [ -z "${AS_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-s}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen AS_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_service_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
SCR="${SCRATCH:-/tmp}"
OUT="$SCR/aerial_service_probe${ARM:+-$ARM}"
QML=tools/dev/qml/aerial_service_probe.qml
STUB="$(pwd)/tools/dev/aerial_helper_stub.py"
mkdir -p "$SCR"
exec 9> "$OUT.lock"
flock -n 9 || { echo "another run is using $OUT -- wait for it"; echo "$NAME RESULT FAIL (busy)"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT/proc" "$OUT/state" "$OUT/config" "$OUT/xdg/config/theme" "$OUT/xdg/state" "$OUT/xdg/cache" "$OUT/xdg/data"

if [ -n "$ARM" ]; then
    [ -e .git ] && { echo "refusing to arm the real tree"; exit 2; }
    arm() {  # file from to -- the anchor must be there exactly once
        python3 - "$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: anchor not found exactly once in $1"; echo "$NAME RESULT FAIL (arm)"; exit 2; }
import sys
p, a, b = sys.argv[1:]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
        echo "ARMED $ARM in $1"
    }
    D=modules/aerial/data
    case "$ARM" in
        noparity) arm $D/AerialMock.qml '    function btRename(a: string, name: string): void { root._btMap(a, d => Object.assign(d, { name: name })); }
' '' ;;
        trustall) arm $D/AerialModel.js '    return !!map && map[uuid] === true;' '    return !map || map[uuid] !== false;' ;;
        flap) arm $D/AerialModel.js '    if (prev !== 0 && prev !== 1 && prev !== 2 && prev !== 3) {' '    if (true) {' ;;
        portalrace) arm $D/AerialModel.js '    if (i.portal === true || i.netPad === "warn") return "wait-portal";      // a login page is up: no tunnel before the login
' '' ;;
        dummyprimary)
            arm $D/AerialModel.js '    if (/^pvpn-killswitch/.test(id)) return true;' '    return false;'
            arm $D/AerialModel.js 'return /^(lo|docker|br-|veth|virbr|vboxnet|vmnet|tun|tap|wg|proton|pvpn|ipv6leak|p2p-dev|dummy|ifb)/.test(_str(name));' 'return /^(lo|docker|br-|veth|virbr|vboxnet|vmnet|tun|tap|wg|proton|p2p-dev|dummy|ifb)/.test(_str(name));' ;;
        dayms) arm $D/AerialModel.js '    var e = new Date(d.getFullYear(), d.getMonth(), d.getDate() - k);' '    var e = new Date(ms - k * 86400000);' ;;
        pile) arm $D/AerialModel.js 'function toastKey(id) { return "fail-" + _str(id); }' 'function toastKey(id) { return "fail-" + _str(id) + Math.random(); }' ;;
        persist) arm $D/AerialModel.js 'function errorsPrune(errors, facts) {
    var es = _arr(errors);' 'function errorsPrune(errors, facts) {
    return errors;
    var es = _arr(errors);' ;;
        fastestalways) arm $D/AerialModel.js '(p.fastestAsk === true || (fastestName !== "" && server.name === fastestName));' '!!server;' ;;
        nopersistfast) arm $D/AerialService.qml '        vpnFile.write(JSON.stringify({ fastestServer: name }));
' '' ;;
        noretest) arm $D/AerialService.qml '    function _retestArm(): void {
' '    function _retestArm(): void {
        return;
' ;;
        quietshown) arm $D/AerialService.qml '                if (m.state === "testing")
                    return;
' '' ;;
        deafkeyring) arm $D/AerialService.qml '            if (m.locked !== true)
                root._askProton();
' '' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi

# ---- the pure model under node (the armed copy when armed)
fail=0
node_out=$(AERIAL_MOD="$(pwd)/modules" node tools/dev/aerial_model_cases.js 2>&1)
printf '%s\n' "$node_out" | grep -E '^AM .* FAIL|RESULT' | sed 's/^/NODE /'
printf '%s\n' "$node_out" | tail -1 | grep -q 'AERIAL-MODEL RESULT PASS' || fail=1

# ---- the fake machine
printf '// the probe -- comments survive a switch written by the service\n{\n  // keep me\n  "autoTunnel": true,\n  "searchSeconds": 5,\n  "visibleSeconds": 10\n}\n' > "$OUT/config/aerial.jsonc"
echo '{}' > "$OUT/scenario.json"
: > "$OUT/control.jsonl"
printf '#!/bin/sh\necho "$@" >> "%s/open.log"\n' "$OUT" > "$OUT/open_stub.sh"; chmod +x "$OUT/open_stub.sh"
echo '5000.00 0.00' > "$OUT/proc/uptime"
echo '{"theme":"eva","mode":"light"}' > "$OUT/xdg/config/theme/state.json"
echo '{}' > "$OUT/serverlist.json"
REAL_AERIAL="${HOME}/.local/state/lares/aerial"
# The user's OWN deployed shell runs aerial and writes usage.json there on its own beat (2026-11-20: a live helper falsely failed this
# check). Compare everything else; usage.json only while no deployed aerial-helper of this user is running.
real_state_sig() {
    local skip=""
    pgrep -u "$(id -u)" -f 'lares/shell/[^ ]*/tools/aerial/aerial-helper' > /dev/null 2>&1 && skip="usage.json"
    ls -la --time-style=+%s "$REAL_AERIAL" 2> /dev/null | { if [ -n "$skip" ]; then grep -v " $skip\$"; else cat; fi; } | grep -vE ' \.\.?$' | sha256sum
}
before=$(real_state_sig)

log="$OUT/run.log"
env -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= WAYLAND_DISPLAY= \
    QT_LOGGING_RULES="qt.qpa.services.warning=false" \
    XDG_CONFIG_HOME="$OUT/xdg/config" XDG_STATE_HOME="$OUT/xdg/state" XDG_CACHE_HOME="$OUT/xdg/cache" XDG_DATA_HOME="$OUT/xdg/data" \
    AS_OUT="$OUT" AS_STUB="$STUB" \
    quickshell -p "$QML" > "$log" 2>&1 &
qpid=$!
deadline=$((SECONDS + ${DEADLINE:-200}))
while kill -0 "$qpid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
if kill -0 "$qpid" 2> /dev/null; then
    echo "(the probe outlived its deadline and was killed)" >> "$log"
    kill "$qpid" 2> /dev/null; sleep 1; kill -9 "$qpid" 2> /dev/null
fi
wait "$qpid" 2> /dev/null

rl_clean "$log" | grep -a -oE 'qml: AS .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: AS DONE (PASS|FAIL)'; then
    rl_noresult "$NAME" "$log"
    exit 1
fi
rl_has "$log" 'qml: AS DONE PASS' || fail=1
# the shell's own warnings: none
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot' | grep -v 'quickshell.tooling' | grep -v 'qml: AS ' | grep -v 'the network helper exited (3)' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "AS warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
# nothing touched the user's real state dir, the stub opener was never given anything it should not
after=$(real_state_sig)
[ "$before" = "$after" ] && echo "AS real-state-dir-untouched PASS" || { echo "AS real-state-dir-untouched FAIL  $REAL_AERIAL changed"; fail=1; }
# leftovers: no stub of this run is still alive
left=""
for e in $(ls /proc/[0-9]*/cmdline 2> /dev/null); do
    p="${e#/proc/}"; p="${p%/cmdline}"
    [ "$p" = "$$" ] && continue
    [ -r "$e" ] || continue
    if tr '\0' ' ' < "$e" 2> /dev/null | grep -q "aerial_helper_stub.py.*$OUT"; then left="$left $p"; fi
done
if [ -n "$left" ]; then echo "AS no-leftovers FAIL  $left"; for p in $left; do kill -9 "$p" 2> /dev/null; done; fail=1; else echo "AS no-leftovers PASS"; fi
if [ "$fail" = 0 ]; then rm -rf "$OUT" "$OUT.lock"; echo "$NAME RESULT PASS"; else echo "(kept: $OUT)"; echo "$NAME RESULT FAIL"; fi
exit "$fail"
