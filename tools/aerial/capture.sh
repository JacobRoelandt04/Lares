#!/usr/bin/env bash
# aerial -- the user's capture run (stage 0 of docs/agent_added_files_and_folders/aerial_progress/PLAN.md).
#
#   tools/aerial/capture.sh            run it in a terminal; it asks before every part that changes anything
#
# What it records, into ~/.cache/lares/aerial-capture/<time>/ (OUTSIDE the repo: these files hold your addresses,
# your account's plan and Proton's servers; Claude scrubs what becomes a fixture):
#   1. READ-ONLY, automatic: NetworkManager (devices, the Wi-Fi scan cache, the active profile without secrets,
#      what polkit lets you do), the card (iw link, /proc/net/wireless), BlueZ, UPower, PipeWire's Bluetooth cards,
#      ProtonVPN (version, status, config, countries, the cities of NL).
#   2. ASKED FIRST (y/N each): ProtonVPN connect to NL, status, disconnect; a Secure Core connect and disconnect;
#      the kill switch set to 'standard' for one connect / disconnect and PUT BACK to what it was (also on Ctrl+C).
#      While these run, `nmcli monitor` and `ip monitor` record the order of events with timestamps.
#   3. ASKED FIRST: a Bluetooth part, only if a device is connected (connect your earbuds first if you want it):
#      its profiles and codecs as PipeWire sees them, its battery as UPower sees it. Nothing is switched.
#
# Nothing else is changed: no profile, no radio, no Bluetooth device is touched.
set -u
export LC_ALL=C
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/lares/aerial-capture/$STAMP"
mkdir -p "$OUT"
LOG="$OUT/timeline.txt"
: > "$LOG"

now_ms() { date +%s%3N; }
note() { printf '%s %s\n' "$(now_ms)" "$*" >> "$LOG"; printf '  %s\n' "$*"; }
# cap <file> <timeout-s> <command...>: stdout and stderr apart, the exit status and the time it took.
cap() {
    local name="$1" f="$OUT/$1" t="$2"; shift 2
    local a b rc
    a=$(now_ms)
    timeout --foreground -k 2 "$t" "$@" > "$f" 2> "$f.stderr"; rc=$?
    b=$(now_ms)
    [ -s "$f.stderr" ] || rm -f "$f.stderr"
    printf '%s %s exit=%s ms=%s\n' "$a" "$name" "$rc" "$((b - a))" >> "$LOG"
    printf '  %-40s exit %-3s %6s ms\n' "$name" "$rc" "$((b - a))"
}
ask() {   # ask "question" -> 0 on y
    local r
    printf '\n%s [y/N] ' "$1"
    read -r r
    [ "$r" = "y" ] || [ "$r" = "Y" ]
}

echo "aerial capture -> $OUT"
echo
echo "1. read-only part"
cap nm_general.txt          10 nmcli -t general status
cap nm_permissions.txt      10 nmcli -t general permissions
cap nm_devices.txt          10 nmcli -t -f DEVICE,TYPE,STATE,CONNECTION,DBUS-PATH device status
cap nm_connections.txt      10 nmcli -t -f NAME,UUID,TYPE,DEVICE,STATE,AUTOCONNECT,AUTOCONNECT-PRIORITY,TIMESTAMP,FILENAME connection show
cap nm_wifi_list.txt        10 nmcli -t -f IN-USE,BSSID,SSID,MODE,CHAN,FREQ,RATE,BANDWIDTH,SIGNAL,SECURITY,WPA-FLAGS,RSN-FLAGS,DEVICE,ACTIVE,DBUS-PATH device wifi list --rescan no
wifidev=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi"{print $1; exit}')
wireddev=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1; exit}')
[ -n "$wifidev" ] && cap nm_device_wifi.txt 10 nmcli -t device show "$wifidev"
[ -n "$wireddev" ] && cap nm_device_wired.txt 10 nmcli -t device show "$wireddev"
actuuid=$(nmcli -t -f UUID,TYPE,STATE connection show | awk -F: '$2=="802-11-wireless" && $3=="activated"{print $1; exit}')
# No -s: secrets are NOT printed. Every other setting of the active Wi-Fi profile is.
[ -n "$actuuid" ] && cap nm_active_wifi_profile.txt 10 nmcli -t connection show uuid "$actuuid"
cap nm_eduroam_profile.txt  10 nmcli -t connection show id eduroam
cap nm_hotspot_profile.txt  10 nmcli -t connection show id Hotspot
cap nm_dbus_tree.txt        10 busctl --system --list tree org.freedesktop.NetworkManager
if [ -n "$wifidev" ]; then
    cap iw_link.txt          5 iw dev "$wifidev" link
    cap iw_info.txt          5 iw dev "$wifidev" info
    cap iw_station.txt       5 iw dev "$wifidev" station dump
fi
cap iw_reg.txt              5 iw reg get
cap proc_net_wireless.txt   5 cat /proc/net/wireless
cap rfkill.txt              5 rfkill -o ID,TYPE,DEVICE,SOFT,HARD
cap bluez_tree.txt         10 busctl --system --list tree org.bluez
cap bluez_adapter.txt      10 busctl --system --json=pretty call org.bluez /org/bluez/hci0 org.freedesktop.DBus.Properties GetAll s org.bluez.Adapter1
cap upower_dump.txt        10 upower -d
cap pactl_cards.txt        10 pactl -f json list cards
if command -v protonvpn > /dev/null 2>&1; then
    cap proton_version.txt   5 pacman -Q proton-vpn-cli proton-vpn-daemon python-proton-vpn-api-core
    cap proton_status_off.txt 30 protonvpn status
    cap proton_config.txt   30 protonvpn config list
    cap proton_info.txt     30 protonvpn info
    cap proton_countries.txt 60 protonvpn countries list
    cap proton_cities_NL.txt 60 protonvpn cities list NL
    cap proton_cities_BE.txt 60 protonvpn cities list BE
    ls -la "$HOME/.cache/Proton/VPN" > "$OUT/proton_cache_ls.txt" 2>&1
fi

MONPIDS=()
start_monitors() {   # timestamped event order while a VPN step runs
    ( nmcli monitor 2>&1 | while IFS= read -r l; do printf '%s %s\n' "$(now_ms)" "$l"; done ) >> "$OUT/$1.nmcli_monitor.txt" &
    MONPIDS+=($!)
    ( ip monitor link address route 2>&1 | while IFS= read -r l; do printf '%s %s\n' "$(now_ms)" "$l"; done ) >> "$OUT/$1.ip_monitor.txt" &
    MONPIDS+=($!)
}
stop_monitors() {
    local p
    for p in "${MONPIDS[@]}"; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    MONPIDS=()
}
snapshot() {   # snapshot <tag>: what the system looks like now
    cap "$1.proton_status.txt" 30 protonvpn status
    cap "$1.nm_active.txt"     10 nmcli -t -f NAME,UUID,TYPE,DEVICE,STATE connection show --active
    cap "$1.nm_devices.txt"    10 nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
    cap "$1.ip_addr.txt"        5 ip -br addr
    cap "$1.ip_route.txt"       5 ip route
    cap "$1.ip_rule.txt"        5 ip rule
    cap "$1.resolv.txt"         5 cat /etc/resolv.conf
    cap "$1.nft.txt"            5 nft list tables
    local vpn
    vpn=$(nmcli -t -f UUID,TYPE connection show --active | awk -F: '$2=="vpn" || $2=="wireguard" || $2=="tun"{print $1; exit}')
    [ -n "$vpn" ] && cap "$1.nm_vpn_profile.txt" 10 nmcli -t connection show uuid "$vpn"
}

KS_ORIG=""
restore_ks() {
    stop_monitors
    if [ -n "$KS_ORIG" ]; then
        echo "  putting the kill switch back to '$KS_ORIG'"
        protonvpn config set kill-switch "$KS_ORIG" >> "$OUT/ks_restore.txt" 2>&1
        protonvpn config list >> "$OUT/ks_restore.txt" 2>&1
        KS_ORIG=""
    fi
}
trap 'restore_ks; echo; echo "stopped; what was captured is in $OUT"; exit 130' INT TERM

if command -v protonvpn > /dev/null 2>&1; then
    echo
    echo "2. ProtonVPN (changes your connection for a minute; each step asks first)"
    if ask "Connect Proton to the Netherlands now (protonvpn connect --country NL), then disconnect?"; then
        snapshot p0_before
        start_monitors p1_connect
        cap p1_connect.txt 120 protonvpn connect --country NL
        sleep 2
        snapshot p1_connected
        stop_monitors
        start_monitors p2_disconnect
        cap p2_disconnect.txt 60 protonvpn disconnect
        sleep 2
        snapshot p2_after
        stop_monitors
    fi
    if ask "Connect through Secure Core (protonvpn connect --securecore), then disconnect?"; then
        start_monitors p3_securecore
        cap p3_securecore.txt 120 protonvpn connect --securecore
        sleep 2
        snapshot p3_connected
        cap p3_disconnect.txt 60 protonvpn disconnect
        stop_monitors
    fi
    if ask "Set the kill switch to 'standard' for one connect / disconnect (it is put back afterwards)?"; then
        KS_ORIG=$(protonvpn config list 2>/dev/null | awk 'tolower($0) ~ /kill.?switch/ {print tolower($NF); exit}')
        case "$KS_ORIG" in
            off|standard) echo "  kill switch was '$KS_ORIG'" ;;
            *) echo "  could not read the kill switch's current value ('$KS_ORIG'): this step is skipped"; KS_ORIG="" ;;
        esac
    fi
    if [ -n "$KS_ORIG" ]; then
        cap p4_ks_set.txt 30 protonvpn config set kill-switch standard
        start_monitors p4_ks
        cap p4_connect.txt 120 protonvpn connect --country NL
        sleep 2
        snapshot p4_connected
        cap p4_disconnect.txt 60 protonvpn disconnect
        sleep 2
        snapshot p4_after
        restore_ks
        cap p4_config_after.txt 30 protonvpn config list
    fi
fi

echo
echo "3. Bluetooth (read-only; only useful while a device is connected)"
if ask "Is a Bluetooth device connected that you want recorded (profiles, codecs, battery)?"; then
    cap b_devices.txt      10 busctl --system --list tree org.bluez
    for p in $(busctl --system --list tree org.bluez 2>/dev/null | grep -oE '/org/bluez/hci0/dev_[0-9A-F_]+$'); do
        n=$(basename "$p")
        cap "b_$n.device.txt"  10 busctl --system --json=pretty call org.bluez "$p" org.freedesktop.DBus.Properties GetAll s org.bluez.Device1
        cap "b_$n.battery.txt" 10 busctl --system --json=pretty call org.bluez "$p" org.freedesktop.DBus.Properties GetAll s org.bluez.Battery1
    done
    cap b_pactl_cards.txt  10 pactl -f json list cards
    cap b_upower.txt       10 upower -d
fi

trap - INT TERM
restore_ks
echo
echo "done: $OUT"
echo "tell Claude the capture is done (the folder stays on your disk; nothing is sent anywhere)."
