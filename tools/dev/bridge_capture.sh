#!/usr/bin/env bash
# bridge_capture.sh -- record what THIS phone and THIS machine really answer, for the bridge module's parsers and stubs
# (docs/contracts/bridge.md). The user's own step: it talks to the real phone, the real adb and the real KDE Connect, so
# it runs only from a terminal and no agent, runner or gate ever starts it.
#
#   tools/dev/bridge_capture.sh                 the read-only pass (plug the phone in first; USB debugging on)
#   tools/dev/bridge_capture.sh --wireless      the same with the phone UNPLUGGED (what Wi-Fi alone answers)
#   tools/dev/bridge_capture.sh --with-push     + push one 64 MB file to the phone's Download folder and remove it
#                                               (the progress bytes of `adb push`)
#   tools/dev/bridge_capture.sh --with-mount    + mount the storage with aft-mtp-mount on a temp dir, list it, unmount
#   tools/dev/bridge_capture.sh --with-usbmode  + ask the phone to switch its USB mode to File transfer (`svc usb
#                                               setFunctions mtp`): it re-enumerates the device; the mode before is noted
#
# Everything read lands in ~/.cache/lares/bridge/capture-<stamp>/, one file per command (<nn>-<name>.out / .err / .rc
# / .cmd). NOTHING is written into the repo: the capture holds the phone's serial, its addresses and the KDE Connect
# device ids. Tell Claude the folder; the fixtures made from it are scrubbed.
#
# What the read-only pass does on the machine: it starts an adb server if none runs (`adb devices` does that), and
# offers to stop it again at the end; scrcpy's --list-* calls push its server to the phone for a second each. Nothing
# else changes: no mount, no mode switch, no pairing, no file.
{
set -u

if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "bridge_capture: this talks to the real phone and the real adb; run it yourself, from a terminal" >&2
    exit 4
fi

WIRELESS=0; PUSH=0; MOUNT=0; USBMODE=0
for a in "$@"; do
    case "$a" in
        --wireless) WIRELESS=1 ;;
        --with-push) PUSH=1 ;;
        --with-mount) MOUNT=1 ;;
        --with-usbmode) USBMODE=1 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bridge_capture: unknown option $a" >&2; exit 2 ;;
    esac
done

OUT="${XDG_CACHE_HOME:-$HOME/.cache}/lares/bridge/capture-$(date +%Y%m%d-%H%M%S)$([ "$WIRELESS" = 1 ] && echo -wireless)"
mkdir -p "$OUT" && chmod 700 "$OUT" || exit 1
N=0

# cap <name> <argv...>: one command, its bytes exactly as they came (stdout and stderr apart), its status, 20 s at most.
cap() {
    local name="$1"; shift
    N=$((N + 1))
    local base; base="$OUT/$(printf '%02d' "$N")-$name"
    printf '%q ' "$@" > "$base.cmd"; echo >> "$base.cmd"
    timeout -k 2 20 "$@" > "$base.out" 2> "$base.err" < /dev/null
    echo $? > "$base.rc"
    printf '  %-34s rc %s  %s bytes\n' "$name" "$(cat "$base.rc")" "$(stat -c %s "$base.out")"
}
# capsh <name> <shell line>: the same for a pipeline.
capsh() {
    local name="$1"; shift
    cap "$name" bash -c "$1"
}
have() { command -v "$1" > /dev/null 2>&1; }

echo "bridge_capture -> $OUT"
ADB_WAS_UP=0
if pgrep -u "$(id -u)" -x adb > /dev/null 2>&1; then ADB_WAS_UP=1; fi

echo "== the machine"
cap versions bash -c 'for p in adb scrcpy aft-mtp-mount sshfs fusermount3 kdeconnect-cli; do printf "%s: " $p; command -v $p || echo MISSING; done; adb --version 2>&1 | head -2; scrcpy --version 2>&1 | head -1; pacman -Q android-tools scrcpy android-file-transfer kdeconnect sshfs 2>&1'
cap lsusb lsusb
# Every USB device's identity and interfaces, straight from sysfs (what GUdev reads): class ff/42/01 is adb, 06/01/01 MTP/PTP.
capsh usb-sysfs 'for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] || continue; echo "## $d"; for f in idVendor idProduct manufacturer product serial bDeviceClass speed; do [ -f "$d/$f" ] && printf "%s=%s\n" $f "$(cat "$d/$f")"; done; for i in "$d":*; do [ -f "$i/bInterfaceClass" ] && printf "iface %s class=%s sub=%s proto=%s name=%s\n" "${i##*/}" "$(cat "$i/bInterfaceClass")" "$(cat "$i/bInterfaceSubClass")" "$(cat "$i/bInterfaceProtocol")" "$(cat "$i/interface" 2>/dev/null)"; done; done'
capsh usb-udev 'for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] || continue; echo "## $d"; udevadm info -q property -p "$d" 2>/dev/null | grep -E "^(ID_|DEVTYPE|PRODUCT|adb_|DEVNAME|SUBSYSTEM)"; done'
capsh mountinfo 'grep -E "fuse|mtp|sshfs|/mnt/android" /proc/self/mountinfo; echo "--"; ls -ld /mnt/android 2>&1'

echo "== KDE Connect"
if have kdeconnect-cli && busctl --user status org.kde.kdeconnect > /dev/null 2>&1; then
    cap kdc-list kdeconnect-cli -l
    cap kdc-daemon-introspect gdbus introspect --session --dest org.kde.kdeconnect --object-path /modules/kdeconnect
    cap kdc-tree busctl --user tree org.kde.kdeconnect
    for id in $(kdeconnect-cli -l --id-only 2> /dev/null); do
        p="/modules/kdeconnect/devices/$id"
        cap "kdc-dev-$id" busctl --user --json=short call org.kde.kdeconnect "$p" org.freedesktop.DBus.Properties GetAll s org.kde.kdeconnect.device
        for pl in battery connectivity_report sftp clipboard; do
            cap "kdc-$pl-$id" busctl --user --json=short call org.kde.kdeconnect "$p/$pl" org.freedesktop.DBus.Properties GetAll s "org.kde.kdeconnect.device.$pl"
        done
        cap "kdc-sftp-state-$id" bash -c "busctl --user call org.kde.kdeconnect $p/sftp org.kde.kdeconnect.device.sftp isMounted; busctl --user call org.kde.kdeconnect $p/sftp org.kde.kdeconnect.device.sftp mountPoint; busctl --user call org.kde.kdeconnect $p/sftp org.kde.kdeconnect.device.sftp getMountError"
        cap "kdc-plugins-$id" busctl --user --json=short call org.kde.kdeconnect "$p" org.kde.kdeconnect.device loadedPlugins
    done
    # Ten seconds of the daemon's signals as gdbus prints them (lock and unlock the phone meanwhile for a battery / link line).
    echo "  (10 s of KDE Connect signals: lock and unlock the phone now)"
    N=$((N + 1)); base="$OUT/$(printf '%02d' "$N")-kdc-monitor"
    timeout 10 gdbus monitor --session --dest org.kde.kdeconnect > "$base.out" 2> "$base.err"; echo $? > "$base.rc"
else
    echo "  kdeconnectd is not on the bus: skipped"
fi

echo "== adb"
if have adb; then
    cap adb-devices adb devices -l
    cap adb-mdns-check adb mdns check
    cap adb-mdns-services adb mdns services
    # The server's own device feed, raw (what the tool reads instead of polling): 3 s of host:track-devices-l.
    cap adb-track python3 -c '
import socket, sys, time
s = socket.create_connection(("127.0.0.1", 5037), 2)
req = b"host:track-devices-l"
s.sendall(b"%04x" % len(req) + req)
s.settimeout(3)
end = time.time() + 3
try:
    while time.time() < end:
        b = s.recv(65536)
        if not b: break
        sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
except Exception as e:
    sys.stderr.write(repr(e) + "\n")
'
    SERIALS=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
    [ -n "$SERIALS" ] || echo "  no authorised adb device (USB debugging off, not authorised, or unplugged): the device reads are skipped"
    for s in $SERIALS; do
        tag=$(printf '%s' "$s" | tr -c 'A-Za-z0-9' '_')
        cap "adb-state-$tag" adb -s "$s" get-state
        cap "adb-props-$tag" adb -s "$s" shell 'for p in ro.product.model ro.product.device ro.product.manufacturer ro.product.name ro.build.version.release ro.build.version.sdk ro.serialno sys.usb.config sys.usb.state persist.sys.usb.config service.adb.tcp.port persist.adb.tcp.port; do echo "$p=$(getprop $p)"; done'
        cap "adb-ip-$tag" adb -s "$s" shell 'ip -o -4 addr show; echo --; ip route'
        cap "adb-battery-$tag" adb -s "$s" shell dumpsys battery
        cap "adb-df-$tag" adb -s "$s" shell 'df -k /sdcard /storage/emulated/0 /data 2>&1'
        cap "adb-usbfn-$tag" adb -s "$s" shell 'svc usb getFunctions 2>&1; echo "rc=$?"'
        cap "adb-wifiadb-$tag" adb -s "$s" shell 'settings get global adb_wifi_enabled; settings get global adb_enabled'
        cap "adb-wm-$tag" adb -s "$s" shell 'wm size; wm density'
        capsh "adb-screencap-head-$tag" "adb -s '$s' exec-out screencap -p | head -c 32 | xxd"
        if have scrcpy; then
            cap "scrcpy-displays-$tag" scrcpy -s "$s" --list-displays
            cap "scrcpy-cameras-$tag" scrcpy -s "$s" --list-cameras
            cap "scrcpy-encoders-$tag" scrcpy -s "$s" --list-encoders
        fi
        if [ "$PUSH" = 1 ]; then
            echo "  --with-push: 64 MB to /sdcard/Download/.lares-bridge-capture.bin, then removed"
            f=$(mktemp /tmp/lares-bridge-cap.XXXXXX)
            head -c 67108864 /dev/urandom > "$f"
            # On a pty, so the \r-redrawn progress is what the tool's wrapper will see.
            cap "adb-push-$tag" script -q -c "adb -s '$s' push '$f' /sdcard/Download/.lares-bridge-capture.bin" /dev/null
            cap "adb-push-rm-$tag" adb -s "$s" shell rm -f /sdcard/Download/.lares-bridge-capture.bin
            rm -f "$f"
        fi
        if [ "$USBMODE" = 1 ]; then
            echo "  --with-usbmode: asking for File transfer (the device re-enumerates)"
            cap "adb-usbfn-set-$tag" adb -s "$s" shell 'svc usb setFunctions mtp; echo "rc=$?"'
            sleep 4
            cap "adb-usbfn-after-$tag" bash -c "adb devices -l; lsusb"
        fi
    done
else
    echo "  adb is not installed: skipped"
fi

echo "== MTP"
if have aft-mtp-cli; then
    cap aft-list aft-mtp-cli -l
    if [ "$MOUNT" = 1 ] && have aft-mtp-mount; then
        m=$(mktemp -d /tmp/lares-bridge-mnt.XXXXXX)
        echo "  --with-mount: aft-mtp-mount on $m (unlock the phone; choose File transfer if it asks)"
        N=$((N + 1)); base="$OUT/$(printf '%02d' "$N")-aft-mount"
        aft-mtp-mount "$m" > "$base.out" 2> "$base.err"; echo $? > "$base.rc"
        sleep 2
        capsh aft-mounted "grep -F '$m' /proc/self/mountinfo; ls -la '$m' | head -20; df -k '$m'; stat -f '$m'"
        cap aft-unmount fusermount3 -u "$m"
        rmdir "$m" 2> /dev/null
    fi
else
    echo "  android-file-transfer is not installed: skipped"
fi

if [ "$ADB_WAS_UP" = 0 ] && pgrep -u "$(id -u)" -x adb > /dev/null 2>&1; then
    printf 'This run started an adb server. Stop it again? [Y/n] '
    read -r ans
    case "$ans" in n|N) echo "  left running" ;; *) adb kill-server && echo "  stopped" ;; esac
fi

echo
echo "Done: $(find "$OUT" -name '*.out' | wc -l) reads in"
echo "  $OUT"
echo "It holds the phone's serial, addresses and device ids: it stays out of the repo. Give Claude that path."
exit 0
}
