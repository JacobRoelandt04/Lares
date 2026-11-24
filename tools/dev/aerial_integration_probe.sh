#!/usr/bin/env bash
# aerial's two halves TOGETHER, headless, on a FAKE machine, in the sandbox: the REAL AerialService (live) on the REAL
# tools/aerial/aerial-helper, which talks to a fake NetworkManager + BlueZ on a PRIVATE bus (tools/aerial/fake_nm.py, driven by
# tools/dev/aerial_integration_world.py), with the stub iw / ping / protonvpn of tools/dev/stubs/aerial first on PATH and a local HTTP
# stub for the check URL. The service's Bluetooth state comes from a fake `btSource`; the NEW bt snapshot (adapter address, rfkill hard
# block, RSSI) from the fake BlueZ. Never the system bus, never NetworkManager / BlueZ / protonvpn / ping / iw of the machine.
#
#   tools/dev/aerial_integration_probe.sh               last line: AERIAL_INTEGRATION RESULT PASS|FAIL (exit status follows)
#   ARM=<name> tools/dev/aerial_integration_probe.sh    a fault put into the SANDBOX copy; the run must end FAIL on the arm's own check
#   ARM=all tools/dev/aerial_integration_probe.sh       every ARM; AERIAL_INTEGRATION ARMS PASS when each failed as it must
#
#     nopsk        the helper drops the `psk` patch of `update`            -> known.new.password.connects FAILS
#     dropwifi     the Wi-Fi fact is taken from NetworkManager's PRIMARY   -> wifi.never.dropped.under.the.dummy.primary FAILS
#     nostations   the helper has no `stations` command                    -> hotspot.clients.with.names FAILS
#     norebind     a profile bound to a dead interface name is activated as it is (round 3's helper) -> connect.saved FAILS
#
# The numbers (a change in the fake -> the service's fact; the helper's resident set) are the `AI time` / `AI info` lines.
set -u
cd "$(dirname "$0")/../.." || exit 1
NAME=AERIAL_INTEGRATION

if [ "${ARM:-}" = all ] && [ -z "${AI_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    bad=0
    for a in ${ONLY_ARMS:-nopsk dropwifi nostations norebind}; do
        case $a in
            nopsk) needle="AI known.new.password.connects FAIL" ;;
            dropwifi) needle="AI wifi.never.dropped.under.the.dummy.primary FAIL" ;;
            nostations) needle="AI hotspot.clients.with.names FAIL" ;;
            norebind) needle="AI connect.saved FAIL" ;;
        esac
        sb="/tmp/lares-sbx-aerial-i-arm-$a"
        res=$(ARM=$a SANDBOX="$sb" SCRATCH="${SCRATCH:-}" ONLY_ARMS='' bash tools/dev/aerial_integration_probe.sh 2>&1)
        rm -rf "$sb"
        if rl_isnoresult "$res"; then
            echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | grep -q 'anchor not found exactly once'; then
            echo "  ARM $a: its anchor is not in the code -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then
            echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -qF "$needle"; then
            echo "  ARM $a: failed, but not on its own check ($needle): $(printf '%s\n' "$res" | grep ' FAIL' | head -3 | tr '\n' ';')"; bad=1
        else
            echo "  ARM $a: failed as it must ($needle)"
        fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi

if [ -e .git ] && [ -z "${AI_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-aerial-i}"
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi AI_INNER=1 ARM="${ARM:-}" SCRATCH="${SCRATCH:-}" bash tools/dev/aerial_integration_probe.sh
fi
. tools/dev/result_lib.sh
ARM="${ARM:-}"
ROOT=$(pwd)
QML=tools/dev/qml/aerial_integration_probe.qml

# the world: a SHORT directory (the fake's bus socket path ends at 108 bytes), private, marked in every process's environment
W=$(mktemp -d /tmp/lai.XXXXXX) || exit 1
chmod 700 "$W"
mkdir -p "$W/xdg/config/theme" "$W/xdg/state" "$W/xdg/cache" "$W/xdg/data" "$W/proc" "$W/config" "$W/state" "$W/stub" "$W/leases" "$W/home"
reap_world() {
    local p pids left
    for _ in 1 2 3; do
        pids=""
        for p in /proc/[0-9]*; do
            [ -O "$p" ] || continue
            { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "AERIAL_PROBE=$W" && pids="$pids ${p#/proc/}"
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
}
trap 'reap_world; [ -n "${KEEP:-}" ] && echo "(kept: $W)" || rm -rf "$W"' EXIT

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
    case "$ARM" in
        nopsk) arm tools/aerial/aerial-helper '    if patch.get("psk"):' '    if False:' ;;
        dropwifi) arm modules/aerial/data/AerialModel.js 'if (!_isWifiType(a0.type) || apUuids[a0.uuid] || isKillswitch(a0)) continue;' 'if (!_isWifiType(a0.type) || apUuids[a0.uuid] || isKillswitch(a0) || (_str(nm.primary) !== "" && _str(nm.primary) !== _str(a0.id))) continue;' ;;
        nostations) arm tools/aerial/aerial-helper 'def cmd_stations(msg, reply):' 'def cmd_stationsX(msg, reply):' ;;
        norebind) arm tools/aerial/aerial-helper '    return device_path_by_iface(name) is None' '    return False' ;;
        *) echo "unknown ARM $ARM"; exit 2 ;;
    esac
fi

# the files the service and the stubs read
printf '// the probe -- comments survive a switch written by the service\n{\n  // keep me\n  "autoTunnel": true,\n  "searchSeconds": 5,\n  "visibleSeconds": 10\n}\n' > "$W/config/aerial.jsonc"
printf '#!/bin/sh\necho "$@" >> "%s/open.log"\n' "$W" > "$W/open_stub.sh"; chmod +x "$W/open_stub.sh"
echo '5000.00 0.00' > "$W/proc/uptime"
echo '{"theme":"eva","mode":"light"}' > "$W/xdg/config/theme/state.json"
echo '{}' > "$W/serverlist.json"
REAL_AERIAL="${HOME}/.local/state/lares/aerial"
# The user's OWN deployed shell runs aerial and writes usage.json there on its own beat (2026-11-20: a live helper falsely failed this
# check). Compare everything else; usage.json only while no deployed aerial-helper of this user is running.
real_state_sig() {
    local skip=""
    pgrep -u "$(id -u)" -f 'lares/shell/[^ ]*/tools/aerial/aerial-helper' > /dev/null 2>&1 && skip="usage.json"
    ls -la --time-style=+%s "$REAL_AERIAL" 2> /dev/null | { if [ -n "$skip" ]; then grep -v " $skip\$"; else cat; fi; } | grep -vE ' \.\.?$' | sha256sum
}
before=$(real_state_sig)

# the world's process
env -i HOME="$W/home" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 AERIAL_PROBE="$W" \
    python3 -I tools/dev/aerial_integration_world.py --dir "$W" --root "$ROOT" > "$W/world.log" 2>&1 &
wpid=$!
for _ in $(seq 1 100); do [ -s "$W/ready.json" ] && break; kill -0 "$wpid" 2> /dev/null || break; sleep 0.2; done
if [ ! -s "$W/ready.json" ]; then
    cat "$W/world.log" "$W/fake.err" 2> /dev/null | head -20
    echo "$NAME RESULT FAIL (the world did not come up)"; exit 1
fi
BUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['bus'])" "$W/ready.json")
PORT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['port'])" "$W/ready.json")

log="$W/run.log"
env -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= WAYLAND_DISPLAY= \
    QT_LOGGING_RULES="qt.qpa.services.warning=false" \
    XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache" XDG_DATA_HOME="$W/xdg/data" \
    DBUS_SYSTEM_BUS_ADDRESS="unix:path=$W/no-system-bus" DBUS_SESSION_BUS_ADDRESS="unix:path=$W/no-session-bus" \
    PATH="$ROOT/tools/dev/stubs/aerial:$PATH" AERIAL_PROBE="$W" AERIAL_STUB_DIR="$W/stub" AERIAL_FIXTURES="$ROOT/modules/aerial/data/fixtures" \
    AERIAL_LEASE_DIR="$W/leases" AERIAL_RFKILL_DIR="$W/rfkill" AERIAL_RFKILL_POLL_MS=300 AERIAL_AGENT_TIMEOUT_MS=15000 \
    AI_OUT="$W" AI_ROOT="$ROOT" AI_BUS="$BUS" AI_URL="http://127.0.0.1:$PORT" \
    quickshell -p "$QML" > "$log" 2>&1 &
qpid=$!
deadline=$((SECONDS + ${DEADLINE:-240}))
while kill -0 "$qpid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
if kill -0 "$qpid" 2> /dev/null; then
    echo "(the probe outlived its deadline and was killed)" >> "$log"
    kill "$qpid" 2> /dev/null; sleep 1; kill -9 "$qpid" 2> /dev/null
fi
wait "$qpid" 2> /dev/null

fail=0
rl_clean "$log" | grep -a -oE 'qml: AI .*' | sed 's/^qml: //'
if ! rl_has "$log" 'qml: AI DONE (PASS|FAIL)'; then
    cp "$log" "/tmp/aerial_integration_last.log" 2> /dev/null
    rl_noresult "$NAME" "/tmp/aerial_integration_last.log"
    exit 1
fi
rl_has "$log" 'qml: AI DONE PASS' || fail=1
# the shell's own warnings: none
noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot|aerial helper' | grep -v 'quickshell.tooling' | grep -v 'qml: AI ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
if [ -n "$noise" ]; then
    echo "AI warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"
    fail=1
fi
# the helper's own log lines of kind error / warn would have been printed as `aerial helper:`; the fake's stderr must be empty
if [ -s "$W/fake.err" ]; then echo "AI fake-stderr FAIL  $(head -c 300 "$W/fake.err")"; fail=1; fi
# nothing touched the user's real state dir
after=$(real_state_sig)
[ "$before" = "$after" ] && echo "AI real-state-dir-untouched PASS" || { echo "AI real-state-dir-untouched FAIL  $REAL_AERIAL changed"; fail=1; }
# leftovers: nothing of this world outlives quickshell except the world's own driver (stopped now), and nothing is left after that
kill -TERM "$wpid" 2> /dev/null; wait "$wpid" 2> /dev/null
sleep 0.5
left=""
for p in /proc/[0-9]*; do
    [ -O "$p" ] || continue
    { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "AERIAL_PROBE=$W" && left="$left ${p#/proc/}"
done
left=$(for p in $left; do [ "$p" = "$$" ] || echo "$p"; done)
if [ -n "$left" ]; then echo "AI no-leftovers FAIL  still alive: $(echo $left)"; fail=1; else echo "AI no-leftovers PASS"; fi
if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS"; else cp "$log" /tmp/aerial_integration_last.log; echo "(log: /tmp/aerial_integration_last.log)"; echo "$NAME RESULT FAIL"; fi
exit "$fail"
