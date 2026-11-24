#!/usr/bin/env bash
# The aerial module proven against a REAL NetworkManager: the test bed (tools/aerial/rig, installed once by the user with
# `sudo ~/.config/quickshell/tools/aerial/rig/install.sh`). An AGENT runs this after the user said the rig is installed; it cannot run
# before that and says so.
#
#   tools/dev/aerial_rig_probe.sh                 the whole run, last line: AERIAL_RIG RESULT PASS|FAIL (exit status follows)
#   tools/dev/aerial_rig_probe.sh --safety        only the safety snapshot, twice, read-only, on the real machine (no rig started)
#   tools/dev/aerial_rig_probe.sh --selftest      the DRY parts (no rig, no root): argument parsing, the refusal without the rig, the safety
#                                                 snapshot proven read-only (a stub nmcli / iw / ip logs every call; each must be on the read
#                                                 list) and stable on the real machine; last line AERIAL_RIG_DRY RESULT PASS|FAIL
#
# The order, which is the point: 1. the SAFETY SNAPSHOT of the real machine (the real card's and Bluetooth's rfkill soft / hard state, the
# hash and link of /etc/resolv.conf, the user's own `nmcli` general / connections / devices, the interfaces, the hostname, the regulatory
# domain, the hwsim module, the netns) -- read only; 2. `systemctl start lares-aerial-rig` (no password: the polkit rule) and the laws WHILE
# it runs: the rig's Wi-Fi switch is flipped on the rig's own bus and the real rfkill must not move, the user's NetworkManager lists no
# virtual radio and nothing of the rig, every snapshot part unchanged; 3. the module's REAL AerialService + REAL aerial-helper on the rig's
# bus (tools/dev/qml/aerial_rig_probe.qml, quickshell offscreen in a sandbox): join open / WPA2 / WPA3 / hidden / PEAP / TTLS, a wrong
# password, roaming between rig-wpa2's two radios, the portal (NET pad amber, login, green, the auto-tunnel's order -- a stub `protonvpn`:
# the rig has no Proton), the hotspot with the phone station joining, airplane; 4. `systemctl stop` and the snapshot again: ANY difference
# from step 1 is a FAIL IN CAPITALS. The unit is stopped on every way out.
#
# Never run as root, never starts anything but the one unit the polkit rule allows, never writes the user's NetworkManager (the only
# `nmcli` writes are `radio wifi on|off` against the RIG's bus, and a static check below holds this file to that).
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
NAME=AERIAL_RIG
LIB=${AERIAL_RIG_LIB:-/usr/local/lib/lares/aerial-rig}
RUN=${AERIAL_RIG_RUN:-/run/lares-rig}
UNIT=lares-aerial-rig.service
MODE=full

# ---------------------------------------------------------------- the safety snapshot (READ ONLY) ----------------------------------------
# Every command here only reads: cat / readlink / ls / hostname / sha256sum, `nmcli -t general | connection show | device` (no verb that
# changes anything), `ip -o link show`, `iw reg get`. The parts are separate files so a law can compare one part.
snap() {   # snap <dir>
    local d=$1 r p
    mkdir -p "$d"
    for r in /sys/class/rfkill/rfkill*; do   # the REAL radios only (a virtual radio's rfkill resolves into mac80211_hwsim)
        [ -e "$r" ] || continue
        case "$(readlink -f "$r")" in *mac80211_hwsim*) continue ;; esac
        printf '%s %s %s soft=%s hard=%s\n' "${r##*/}" "$(cat "$r/name" 2> /dev/null)" "$(cat "$r/type" 2> /dev/null)" "$(cat "$r/soft" 2> /dev/null)" "$(cat "$r/hard" 2> /dev/null)"
    done > "$d/rfkill"
    { readlink /etc/resolv.conf 2> /dev/null; sha256sum < /etc/resolv.conf 2> /dev/null; } > "$d/resolv"
    nmcli -t general > "$d/nm_general" 2>&1
    nmcli -t -f NAME,UUID,TYPE,DEVICE connection show > "$d/nm_connections" 2>&1
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device > "$d/nm_devices" 2>&1
    # the user's NetworkManager LISTS the rig's host-side links while the rig is up (the veth lrig-h, mac80211_hwsim's monitor hwsim0),
    # unmanaged by the conf.d line: law 3 is that it never MANAGES them, so the "unchanged" comparisons read the list without them
    grep -vE '^(lrig|hwsim)' "$d/nm_devices" > "$d/nm_devices_own"
    ip -o link show | awk '{ print $2 }' | sort > "$d/links" 2>&1
    hostname > "$d/hostname" 2>&1
    # `reg` is the REAL card's own country (the AX210 is self-managed: iwlwifi's LAR); the rig sets the GLOBAL domain for its virtual
    # radios (BE, for a 5 GHz access point) and puts 00 back, and the kernel may then report an intersection ("98"): that domain governs
    # only radios that follow cfg80211's own (none on this machine but the rig's), so it is recorded beside, as information, not a law
    { iw reg get 2> /dev/null | awk '/^phy#[0-9]+ \(self-managed\)/ { p = $1; getline; print p, $1, $2 }'; } > "$d/reg"
    { iw reg get 2> /dev/null | sed -n '/^global/,/^$/p'; } > "$d/reg_global"
    { grep '^mac80211_hwsim ' /proc/modules | cut -d' ' -f1; ls /run/netns 2> /dev/null; ls -d "$RUN" 2> /dev/null; } > "$d/leftovers"
}
snap_diff() {   # snap_diff <before> <after> [parts...]: 0 when equal; the differences on stdout
    local a=$1 b=$2 p rc=0; shift 2
    for p in "${@:-rfkill resolv nm_general nm_connections nm_devices links hostname reg leftovers}"; do
        for p in $p; do diff -u "$a/$p" "$b/$p" > "$a/.d" 2>&1 || { echo "== $p"; cat "$a/.d"; rc=1; }; done
    done
    return "$rc"
}

SB=${AERIAL_RIG_SCRATCH:-/tmp/lares-sbx-aerial-r}   # scratch; the sandbox COPY lives in $SB/copy (sandbox.sh rsync --delete empties its own dir)
mkdir -p "$SB"
fail=0
say() { echo "AR $*"; }
check() {   # check <name> <command...>
    local n=$1; shift
    if "$@" > "$SB/.last" 2>&1; then say "$n PASS"; return 0; fi
    say "$n FAIL  $(head -c 400 "$SB/.last" | tr '\n' ' ')"; fail=1; return 1
}

# ---------------------------------------------------------------- the dry parts ---------------------------------------------------------------
selftest() {
    NAME=AERIAL_RIG_DRY
    local W; W=$(mktemp -d "$SB/arr.XXXXXX") || exit 1
    mkdir -p "$W/bin"
    # (1) arguments
    check args.unknown.refused bash -c '! bash "$1" --nonsense > /dev/null 2>&1 && [ "$(bash "$1" --nonsense > /dev/null 2>&1; echo $?)" = 2 ]' _ "$0"
    # (2) the refusal without the rig: a SKIP-style FAIL, nothing started (a stub systemctl would log a call)
    printf '#!/bin/sh\necho "$@" >> "%s/systemctl.log"\nexit 1\n' "$W" > "$W/bin/systemctl"; chmod +x "$W/bin/systemctl"
    local out; out=$(PATH="$W/bin:$PATH" AERIAL_RIG_LIB="$W/not-installed" AERIAL_RIG_RUN="$W/no-run" bash "$0" 2>&1); local rc=$?
    check refusal.says.skip bash -c 'echo "$1" | tail -1 | grep -q "^AERIAL_RIG RESULT FAIL (SKIP: the test bed is not installed" && [ "$2" != 0 ]' _ "$out" "$rc"
    check refusal.starts.nothing test ! -e "$W/systemctl.log"
    # (3) the snapshot is READ ONLY: a stub nmcli / ip / iw / systemctl logs each call; every one must be on the read list
    for t in nmcli ip iw; do printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexec /usr/bin/%s "$@"\n' "$t" "$W" "$t" > "$W/bin/$t"; chmod +x "$W/bin/$t"; done
    : > "$W/calls.log"
    ( PATH="$W/bin:$PATH"; snap "$W/s1" )
    check snapshot.only.reads bash -c '
        bad=$(grep -vxE "nmcli -t general|nmcli -t -f NAME,UUID,TYPE,DEVICE connection show|nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device|ip -o link show|iw reg get" "$1/calls.log")
        [ -z "$bad" ] || { echo "a call off the read list: $bad"; exit 1; }
        [ "$(wc -l < "$1/calls.log")" = 6 ] || { echo "expected 6 calls (iw reg get twice: the card'"'"'s country, the global domain): $(cat "$1/calls.log")"; exit 1; }' _ "$W"
    check snapshot.function.has.no.write bash -c '
        body=$(sed -n "/^snap() {/,/^}/p" "$1"); ! printf "%s\n" "$body" | grep -E "nmcli (radio|connection (up|down|add|modify|delete)|device (connect|disconnect|wifi connect)|general (reload|hostname))|rfkill (block|unblock)|systemctl|sudo|> */(sys|etc|run)" ' _ "$0"
    # (4) stable on the REAL machine (read only): twice, equal
    snap "$W/s2"; sleep 1; snap "$W/s3"
    check snapshot.stable.on.this.machine snap_diff "$W/s2" "$W/s3"
    check snapshot.has.the.real.card bash -c '[ -s "$1/rfkill" ] && [ -s "$1/resolv" ] && [ -s "$1/nm_devices" ]' _ "$W/s2"
    # (5) this file's only writes: the one unit, the rig's bus, the portal's own file
    check static.nmcli.writes.only.on.the.rigs.bus bash -c '
        bad=$(grep -nE "nmcli (radio|connection (up|down|add|modify|delete)|device (connect|disconnect|wifi)|general (reload|hostname|logging))" "$1" | grep -v "^[0-9]*:[[:space:]]*#" | grep -v "DBUS_SYSTEM_BUS_ADDRESS=\$RIGBUS" | grep -v "static.nmcli" | grep -v "snapshot.function")
        [ -z "$bad" ] || { echo "$bad"; exit 1; }' _ "$0"
    check static.systemctl.only.the.unit bash -c '
        bad=$(grep -n "systemctl" "$1" | grep -v "^[0-9]*:[[:space:]]*#" | grep -vE "grep|printf|stub|echo|static\.|systemctl\.log|bin/systemctl" | grep -vE "systemctl --no-ask-password (start|stop|is-active) \"?[$]UNIT")
        [ -z "$bad" ] || { echo "$bad"; exit 1; }' _ "$0"
    rm -rf "$W"
    if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS (the dry parts only: no rig was started)"; else echo "$NAME RESULT FAIL"; fi
    exit "$fail"
}

# ---------------------------------------------------------------- the quickshell half (inside the sandbox copy) -------------------------
if [ -n "${AR_INNER:-}" ]; then
    . tools/dev/result_lib.sh
    W=$(mktemp -d /tmp/lar.XXXXXX) || exit 1
    chmod 700 "$W"
    mkdir -p "$W/xdg/config/theme" "$W/xdg/state" "$W/xdg/cache" "$W/xdg/data" "$W/config" "$W/state" "$W/stub" "$W/stubbin" "$W/home"
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
            kill -TERM $pids 2> /dev/null; sleep 0.4
            left=""; for p in $pids; do [ -d "/proc/$p" ] && left="$left $p"; done
            # shellcheck disable=SC2086
            [ -n "$left" ] && kill -KILL $left 2> /dev/null
        done
    }
    trap 'reap_world; rm -rf "$W"' EXIT
    # shellcheck disable=SC1090
    . <(sed 's/^/R_/' "$RUN/roles")   # R_ap_a= R_ap_b= R_client= R_phone=
    printf '// the probe\n{\n  "autoTunnel": true,\n  "searchSeconds": 5,\n  "visibleSeconds": 10\n}\n' > "$W/config/aerial.jsonc"
    echo '{"theme":"eva","mode":"light"}' > "$W/xdg/config/theme/state.json"
    echo '{}' > "$W/serverlist.json"
    ln -s "$ROOT/tools/dev/stubs/aerial_rig/iw" "$W/stubbin/iw"
    ln -s "$ROOT/tools/dev/stubs/aerial/protonvpn" "$W/stubbin/protonvpn"
    cat > "$W/phone_join.sh" <<EOF
#!/bin/bash
# the phone station (the rig's wpa_supplicant on the 4th radio) joins the hotspot under test
D=$RUN/wpa-phone; I=$R_phone
wpa_cli -p "\$D" -i "\$I" remove_network all > /dev/null
id=\$(wpa_cli -p "\$D" -i "\$I" add_network | tail -1)
wpa_cli -p "\$D" -i "\$I" set_network "\$id" ssid "\"\$1\"" > /dev/null
wpa_cli -p "\$D" -i "\$I" set_network "\$id" psk "\"\$2\"" > /dev/null
wpa_cli -p "\$D" -i "\$I" select_network "\$id" > /dev/null
EOF
    chmod +x "$W/phone_join.sh"
    log="$W/run.log"
    env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache" XDG_DATA_HOME="$W/xdg/data" \
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=$W/no-system-bus" DBUS_SESSION_BUS_ADDRESS="unix:path=$W/no-session-bus" \
        PATH="$W/stubbin:$PATH" AERIAL_PROBE="$W" AERIAL_STUB_DIR="$W/stub" AERIAL_FIXTURES="$ROOT/modules/aerial/data/fixtures" AERIAL_RIG_PUB="$RUN/pub" AERIAL_STUB_NM_BUS="unix:path=$RUN/bus" \
        AERIAL_LEASE_DIR="$W/leases" AERIAL_AGENT_TIMEOUT_MS=15000 \
        AR_RUN="$RUN" AR_OUT="$W" AR_ROOT="$ROOT" AR_CLIENT="$R_client" AR_PHONE="$R_phone" AR_APA="$R_ap_a" AR_APB="$R_ap_b" \
        quickshell -p tools/dev/qml/aerial_rig_probe.qml > "$log" 2>&1 &
    qpid=$!
    deadline=$((SECONDS + ${DEADLINE:-900}))
    while kill -0 "$qpid" 2> /dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
    if kill -0 "$qpid" 2> /dev/null; then echo "(the probe outlived its deadline and was killed)" >> "$log"; kill "$qpid" 2> /dev/null; sleep 1; kill -9 "$qpid" 2> /dev/null; fi
    wait "$qpid" 2> /dev/null
    rl_clean "$log" | grep -a -oE 'qml: AR .*' | sed 's/^qml: //'
    if ! rl_has "$log" 'qml: AR DONE (PASS|FAIL)'; then cp "$log" /tmp/aerial_rig_last.log 2> /dev/null; echo "AR NORESULT (no AR DONE line; log: /tmp/aerial_rig_last.log)"; exit 1; fi
    rl_has "$log" 'qml: AR DONE PASS' || exit 1
    noise=$(rl_clean "$log" | rl_platform_noise | grep -E '^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|Cannot|aerial helper' | grep -v 'quickshell.tooling' | grep -v 'qml: AR ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
    if [ -n "$noise" ]; then echo "AR warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"; cp "$log" /tmp/aerial_rig_last.log; exit 1; fi
    echo "AR warnings PASS"
    exit 0
fi

# ---------------------------------------------------------------- arguments --------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case $1 in
        --selftest) MODE=selftest ;;
        --safety) MODE=safety ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: $0 [--selftest | --safety]" >&2; exit 2 ;;
    esac
    shift
done
[ "$MODE" = selftest ] && selftest
[ "$(id -u)" -ne 0 ] || { echo "$NAME RESULT FAIL (never run this as root)"; exit 1; }
command -v nmcli > /dev/null || { echo "$NAME RESULT FAIL (nmcli is missing: the safety snapshot cannot be taken)"; exit 1; }

if [ "$MODE" = safety ]; then
    W=$(mktemp -d "$SB/ars.XXXXXX"); trap 'rm -rf "$W"' EXIT
    snap "$W/a"; sleep 1; snap "$W/b"
    check safety.snapshot.stable snap_diff "$W/a" "$W/b"
    cat "$W/a/rfkill"
    [ "$fail" = 0 ] && echo "$NAME RESULT PASS (safety snapshot only)" || echo "$NAME RESULT FAIL"
    exit "$fail"
fi

# ---------------------------------------------------------------- the refusal: the rig is installed first ---------------------------------------
if [ ! -x "$LIB/rig" ]; then
    echo "$NAME RESULT FAIL (SKIP: the test bed is not installed ($LIB/rig is missing) -- the user's one command: sudo ~/.config/quickshell/tools/aerial/rig/install.sh)"
    exit 1
fi
if systemctl --no-ask-password is-active "$UNIT" > /dev/null 2>&1; then
    echo "$NAME RESULT FAIL (the rig is already running: systemctl stop $UNIT first, so the snapshot is of the machine without it)"
    exit 1
fi
for t in hostapd dnsmasq; do command -v "$t" > /dev/null || { echo "$NAME RESULT FAIL (SKIP: $t is not installed)"; exit 1; }; done

W=$(mktemp -d "$SB/ar.XXXXXX") || exit 1
started=0
stop_rig() {
    [ "$started" = 1 ] || return 0
    timeout 60 systemctl --no-ask-password stop "$UNIT" > /dev/null 2>&1
    started=0
}
trap 'stop_rig; rm -rf "$W"' EXIT

# ---- 1. the machine as it is ----
snap "$W/s0"
sleep 1; snap "$W/s0b"
check machine.snapshot.stable snap_diff "$W/s0" "$W/s0b"
[ "$fail" = 0 ] || { echo "$NAME RESULT FAIL (the machine's own state moves by itself: no proof is possible now)"; exit 1; }

# ---- 2. the rig up, and the laws while it runs ----
if timeout 120 systemctl --no-ask-password start "$UNIT" > "$W/start.out" 2>&1; then started=1; else
    started=1   # a half-started unit is stopped (its ExecStopPost cleans) on the way out
    say "rig.starts FAIL  $(head -c 300 "$W/start.out" | tr '\n' ' ') -- journalctl -u $UNIT"
    snap "$W/s2"; stop_rig; sleep 2; snap "$W/s2"
    snap_diff "$W/s0" "$W/s2" || say "SAFETY FAIL after a failed start: the machine is not as it was"
    echo "$NAME RESULT FAIL"; exit 1
fi
say "rig.starts PASS"
check rig.ready bash -c '[ -e "$1/ready" ] && [ -S "$1/bus" ] && [ -s "$1/roles" ]' _ "$RUN"
RIGBUS="unix:path=$RUN/bus"
snap "$W/s1"
check law3.users.nm.manages.no.rig.interface bash -c '! grep -E "lrig|hwsim" "$1/nm_connections" && ! grep -E "^(lrig|hwsim)" "$1/nm_devices" | grep -v ":unmanaged:"' _ "$W/s1"
check law3.users.nm.unchanged.with.the.rig.up snap_diff "$W/s0" "$W/s1" nm_general nm_connections nm_devices_own
check law2.resolv.conf.unchanged.with.the.rig.up snap_diff "$W/s0" "$W/s1" resolv
check law4.hostname.unchanged snap_diff "$W/s0" "$W/s1" hostname
# law 1: flip the RIG's Wi-Fi switch (its own bus); the rig's NetworkManager writes /dev/rfkill, which is masked there. The real radios must not move.
rig_radio() { DBUS_SYSTEM_BUS_ADDRESS=$RIGBUS nmcli radio wifi "$@"; }
rig_radio off > /dev/null 2>&1; sleep 2
state_off=$(rig_radio 2> /dev/null); snap "$W/s1r"
rig_radio on > /dev/null 2>&1; sleep 2
state_on=$(rig_radio 2> /dev/null); snap "$W/s1r2"
check law1.the.rigs.switch.really.moved bash -c '[ "$1" = disabled ] && [ "$2" = enabled ]' _ "$state_off" "$state_on"
check law1.real.rfkill.did.not.move snap_diff "$W/s0" "$W/s1r" rfkill
check law1.real.rfkill.did.not.move.back snap_diff "$W/s0" "$W/s1r2" rfkill

# ---- 3. the module on the real NetworkManager ----
export SANDBOX="$SB/copy"
if [ -e .git ]; then
    tools/dev/sandbox.sh AR_INNER=1 AERIAL_RIG_RUN="$RUN" bash tools/dev/aerial_rig_probe.sh > "$W/inner.out" 2>&1
else
    AR_INNER=1 bash tools/dev/aerial_rig_probe.sh > "$W/inner.out" 2>&1
fi
cat "$W/inner.out" | grep -a '^AR ' | grep -av '^AR DONE'
# (`A || B && C` is `(A || B) && C` in bash: the old line set fail=1 exactly when the module PASSED -- the fifth real run, 48 of 48)
grep -aq '^AR DONE PASS' "$W/inner.out" || fail=1
grep -a ' FAIL' "$W/inner.out" | grep -aq '^AR ' && fail=1
grep -aq '^AR NORESULT' "$W/inner.out" && { say "module.run FAIL  no result"; fail=1; }

# ---- 4. stop, and the machine must be as it was ----
snap "$W/s1x"; check law1.real.rfkill.after.the.module snap_diff "$W/s0" "$W/s1x" rfkill resolv nm_general nm_connections nm_devices_own hostname
stop_rig
for _ in $(seq 40); do [ ! -e "/run/netns/lares-rig" ] && [ ! -e "$RUN" ] && ! grep -q '^mac80211_hwsim ' /proc/modules && break; sleep 0.5; done
snap "$W/s2"
if snap_diff "$W/s0" "$W/s2" > "$W/final.diff"; then say "safety.after.stop PASS  (every part of the machine is as it was before the rig)"
else
    say "SAFETY FAIL: THE MACHINE IS NOT AS IT WAS BEFORE THE RIG"; cat "$W/final.diff"; fail=1
fi
if ! diff -q "$W/s0/reg_global" "$W/s2/reg_global" > /dev/null 2>&1; then
    say "info.global.regdomain  before: $(sed -n 2p "$W/s0/reg_global" | cut -c1-40) / after: $(sed -n 2p "$W/s2/reg_global" | cut -c1-40) (not the card's: it is self-managed)"
fi
if [ "$fail" = 0 ]; then echo "$NAME RESULT PASS"; else echo "$NAME RESULT FAIL"; fi
exit "$fail"
