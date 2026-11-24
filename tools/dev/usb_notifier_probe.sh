#!/usr/bin/env bash
# usb_notifier_probe.sh -- the drive card (modules/notifications/sources/UsbNotifier.qml) on the real parts (tools/dev/qml/usb_notifier_probe.qml):
# the real UsbNotifier behind the real NotificationSources host and the real NotificationService, the real NotificationRow / ToastEntry for the
# kept card's refusal. UDisks is a stub pair on PATH (udisksctl: monitor / mount / unmount / power-off; lsblk) over ONE little world
# (an SD card mmcblk0 + mmcblk0p1, USB sticks, a whole-disk filesystem, the internal NVMe) whose lsblk output and monitor lines are shaped
# like the real ones; kitty and xdg-open are stubs that log. A sandbox copy, a private bus, private XDG dirs (cache included).
#
#   tools/dev/usb_notifier_probe.sh            USB_NOTIFIER RESULT PASS|FAIL (<n> checks)
#   ARM=<name> tools/dev/usb_notifier_probe.sh one fault in the snapshot; must FAIL on its own check
#   ARM=all                                    every arm: USB_NOTIFIER ARMS RESULT PASS|FAIL
#     xdgopen       Open asks xdg-open for the folder (easytag here), not yazi         -> U3 Open is yazi
#     nomounttrack  the picture of a drive leaves out its mount points                  -> U2 an unmount made elsewhere
#     notkept       the post never carries `kept`                                       -> U1 the mounted card is kept
#     noshake       the refusal plays no shake                                          -> U4 the delete says no
#     sides         a kept toast's refusal stays on the left whatever the sides' verbs  -> U4 swapped
#     nobaseline    a drive already mounted at the start gets no card                   -> U1 a drive already mounted
#     keptretain    the retention pass takes a kept card like any other                 -> U4 the retention pass
# Every anchor is ONE line (`notif_arm` takes one).
set -u
export LARES_SLEEP_MONITOR=off
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-usbn}"
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/fixtures/notifications/probe_lib.sh
. tools/dev/result_lib.sh
export NOTIF_TIMEOUT=260   # an armed run waits out its failed checks (4-8 s each); the probe ends itself at 200 s
NAME=USB_NOTIFIER
PROBE=usb_notifier_probe.qml
notif_reexec tools/dev/usb_notifier_probe.sh
OUT="$SCRATCH/usb_notifier_probe"
mkdir -p "$OUT"
ARMS="xdgopen nomounttrack notkept noshake nobaseline keptretain sides"

arm_of() {  # name -> file<TAB>from<TAB>to<TAB>needle
    case "$1" in
        xdgopen)      printf '%s\t%s\t%s\t%s' modules/notifications/sources/UsbNotifier.qml \
                          '        src.host.run(Usb.openArgv(src.settings.openCommand, path), { detached: true });' \
                          '        src.host.run(["xdg-open", path]);' "U3 Open is yazi" ;;
        sides) printf '%s\t%s\t%s\t%s' modules/notifications/toast/ToastEntry.qml \
                          '    rightRefuses: entry._kept && entry.rightVerb === "delete"' '    rightRefuses: false' "U4 swapped: the delete to the right" ;;
        nomounttrack) printf '%s\t%s\t%s\t%s' modules/notifications/sources/UsbDrives.js \
                          'p.fstype, p.mountpoints]' 'p.fstype]' "U2 an unmount made elsewhere" ;;
        notkept)      printf '%s\t%s\t%s\t%s' modules/notifications/sources/SourcePoster.qml \
                          ', persist: s.persist !== false, kept: s.kept === true' ', persist: s.persist !== false, kept: false' "U1 the mounted card is kept" ;;
        noshake)      printf '%s\t%s\t%s\t%s' modules/notifications/SwipeVerbCard.qml \
                          '        refusal.play();' '        card._shakeDir = card._shakeDir;' "U4 the delete says no" ;;
        nobaseline)   printf '%s\t%s\t%s\t%s' modules/notifications/sources/UsbNotifier.qml \
                          '            for (const x of drives)' '            for (const x of [])' "U1 a drive already mounted" ;;
        keptretain)   printf '%s\t%s\t%s\t%s' modules/notifications/data/NotificationService.qml \
                          '        const prot = sched.shown.concat(sched.held, recs.filter(r => r.kept === true).map(r => r.uid));' \
                          '        const prot = sched.shown.concat(sched.held);' "U4 the retention pass" ;;
        *) return 1 ;;
    esac
}

# The stubs and the world, into a snapshot dir.
make_world() {  # cfg
    local cfg="$1" fx="$1/fx"
    mkdir -p "$fx" "$cfg/media" "$cfg/xdg/quickshell/config"
    printf '{ "toasts": { "floodCount": 1000 }, "sources": { "usb": { "debounceMs": 150, "safeSec": 2 } } }\n' > "$cfg/xdg/quickshell/config/notifications.jsonc"
    : > "$fx/monitor.log"
    cat > "$fx/gen.py" <<'PY'
#!/usr/bin/env python3
# The world of the usb probe: what `lsblk -J -b -o PATH,NAME,LABEL,FSTYPE,SIZE,RM,HOTPLUG,TRAN,TYPE,PKNAME,MOUNTPOINTS,MODEL,VENDOR` prints
# (the real tool's shape: indent of 3, unmounted filesystems `"mountpoints": [null]`, vendor padded), and the state udisksctl changes.
#   gen.py init | lsblk | mount DEV | unmount DEV | present NAME 0|1
import json, os, sys
FX = os.environ["FX"]; MEDIA = os.environ["MEDIA"]; W = os.path.join(FX, "world.json")
def part(disk, n, label, fs, size):
    return {"path": "/dev/" + disk + n, "name": disk + n, "label": label, "fstype": fs, "size": size, "type": "part", "pkname": disk}
DRIVES = {
    "mmcblk0": {"path": "/dev/mmcblk0", "name": "mmcblk0", "label": None, "fstype": None, "size": 31914983424, "rm": True, "hotplug": False, "tran": None,
                "type": "disk", "model": None, "vendor": None, "children": [part("mmcblk0", "p1", "SDCARD", "vfat", 31913934848)]},
    "sdb": {"path": "/dev/sdb", "name": "sdb", "label": None, "fstype": None, "size": 62008590336, "rm": True, "hotplug": True, "tran": "usb",
            "type": "disk", "model": "DataTraveler 3.0", "vendor": "Kingston ", "children": [part("sdb", "1", "BACKUP", "ext4", 62007541760)]},
    "sdc": {"path": "/dev/sdc", "name": "sdc", "label": None, "fstype": None, "size": 32015679488, "rm": True, "hotplug": True, "tran": "usb",
            "type": "disk", "model": "Ultra", "vendor": "SanDisk ", "children": [part("sdc", "1", "TESTDRIVE", "exfat", 16000000000), part("sdc", "2", "SPARE", "ntfs", 16000000000)]},
    "sdd": {"path": "/dev/sdd", "name": "sdd", "label": "WHOLE", "fstype": "exfat", "size": 15518924800, "rm": True, "hotplug": True, "tran": "usb",
            "type": "disk", "model": "Cruzer Blade", "vendor": "SanDisk ", "children": []},
}
def load():
    try:
        return json.load(open(W))
    except Exception:
        return {"present": [], "mounted": []}
def save(w):
    json.dump(w, open(W + ".tmp", "w")); os.replace(W + ".tmp", W)
def label_of(dev):
    for d in DRIVES.values():
        if d["path"] == dev: return d["label"]
        for c in d["children"]:
            if c["path"] == dev: return c["label"]
def node(n, mounted):
    n = dict(n)
    n.setdefault("rm", False); n.setdefault("hotplug", False); n.setdefault("tran", None); n.setdefault("model", None); n.setdefault("vendor", None)
    n.setdefault("pkname", None); n.setdefault("label", None); n.setdefault("fstype", None)
    n["mountpoints"] = [MEDIA + "/" + (n["label"] or "x")] if n["path"] in mounted else [None]
    kids = [node(c, mounted) for c in n.pop("children", [])]
    out = {k: n[k] for k in ["path", "name", "label", "fstype", "size", "rm", "hotplug", "tran", "type", "pkname", "mountpoints", "model", "vendor"]}
    if kids: out["children"] = kids
    return out
def lsblk(w):
    nvme = {"path": "/dev/nvme0n1", "name": "nvme0n1", "size": 1024209543168, "type": "disk", "tran": "nvme", "model": "MTFDKBA1T0QFM-1BD1AABGB", "children": [
        {"path": "/dev/nvme0n1p1", "name": "nvme0n1p1", "label": None, "fstype": "vfat", "size": 1073741824, "type": "part", "pkname": "nvme0n1"},
        {"path": "/dev/nvme0n1p2", "name": "nvme0n1p2", "label": None, "fstype": "ext4", "size": 1000000000000, "type": "part", "pkname": "nvme0n1"}]}
    mounted = list(w["mounted"]) + ["/dev/nvme0n1p1", "/dev/nvme0n1p2"]
    disks = [node(nvme, mounted)]
    disks[0]["children"][0]["mountpoints"] = ["/boot"]; disks[0]["children"][1]["mountpoints"] = ["/"]
    for n in ["mmcblk0", "sdb", "sdc", "sdd"]:
        if n in w["present"]: disks.append(node(DRIVES[n], mounted))
    print(json.dumps({"blockdevices": disks}, indent=3))
cmd = sys.argv[1]
w = load()
if cmd == "init":
    save({"present": ["mmcblk0", "sdb"], "mounted": ["/dev/mmcblk0p1"]})
elif cmd == "lsblk":
    lsblk(w)
elif cmd == "mount":
    if sys.argv[2] not in w["mounted"]: w["mounted"].append(sys.argv[2])
    save(w); print("Mounted %s at %s/%s." % (sys.argv[2], MEDIA, label_of(sys.argv[2])))
elif cmd == "unmount":
    w["mounted"] = [m for m in w["mounted"] if m != sys.argv[2]]; save(w)
elif cmd == "present":
    n, on = sys.argv[2], sys.argv[3] == "1"
    w["present"] = [x for x in w["present"] if x != n] + ([n] if on else [])
    if not on: w["mounted"] = [m for m in w["mounted"] if not m.startswith("/dev/" + n)]
    save(w)
PY
    cat > "$cfg/stubs/lsblk" <<'SH'
#!/usr/bin/env bash
echo "LSBLK $*" >> "$STUB_LOG"
exec env FX="$CFG/fx" MEDIA="$CFG/media" python3 "$CFG/fx/gen.py" lsblk
SH
    cat > "$cfg/stubs/fxctl" <<'SH'
#!/usr/bin/env bash
# What the world does by itself (another program, a hand): plug NAME | pull NAME | extmount DEV | extunmount DEV
export FX="$CFG/fx" MEDIA="$CFG/media"
ts() { date +%H:%M:%S.%3N; }
ping() { printf '%s: /org/freedesktop/UDisks2/block_devices/%s: org.freedesktop.UDisks2.Filesystem: Properties Changed\n  MountPoints:                 \n' "$(ts)" "${1##*/}" >> "$FX/monitor.log"; }
case $1 in
    plug) python3 "$FX/gen.py" present "$2" 1
          printf '%s: Added /org/freedesktop/UDisks2/drives/%s\n%s: Added /org/freedesktop/UDisks2/block_devices/%s\n' "$(ts)" "$2" "$(ts)" "$2" >> "$FX/monitor.log" ;;
    pull) python3 "$FX/gen.py" present "$2" 0
          printf '%s: Removed /org/freedesktop/UDisks2/block_devices/%s\n%s: Removed /org/freedesktop/UDisks2/drives/%s\n' "$(ts)" "$2" "$(ts)" "$2" >> "$FX/monitor.log" ;;
    extmount) python3 "$FX/gen.py" mount "$2" > /dev/null; ping "$2" ;;
    extunmount) python3 "$FX/gen.py" unmount "$2"; ping "$2" ;;
esac
SH
    cat > "$cfg/stubs/udisksctl" <<'SH'
#!/usr/bin/env bash
export FX="$CFG/fx" MEDIA="$CFG/media"
ts() { date +%H:%M:%S.%3N; }
ping() { printf '%s: /org/freedesktop/UDisks2/block_devices/%s: org.freedesktop.UDisks2.Filesystem: Properties Changed\n' "$(ts)" "${1##*/}" >> "$FX/monitor.log"; }
case $1 in
    monitor)
        echo "MONITOR start" >> "$STUB_LOG"
        echo "Monitoring the udisks daemon. Press Ctrl+C to exit."
        echo "$(ts): The udisks-daemon is running (name-owner :1.42)."
        tail -n0 -F "$FX/monitor.log" 2> /dev/null &
        t=$!
        trap 'kill $t 2> /dev/null; echo "MONITOR end" >> "$STUB_LOG"; exit 0' TERM INT
        wait "$t" ;;
    mount)
        echo "UDISKS $*" >> "$STUB_LOG"
        if [ -e "$FX/fail_mount" ]; then cat "$FX/fail_mount" >&2; exit 1; fi
        python3 "$FX/gen.py" mount "$3"; ping "$3" ;;
    unmount)
        echo "UDISKS $*" >> "$STUB_LOG"
        if [ -e "$FX/fail_unmount" ]; then cat "$FX/fail_unmount" >&2; exit 1; fi
        python3 "$FX/gen.py" unmount "$3"; ping "$3" ;;
    power-off)
        echo "UDISKS $*" >> "$STUB_LOG"
        n=${3##*/}
        # the drive vanishes ~0.3 s after the power-off, the way the kernel does it
        ( sleep 0.3; "$CFG/stubs/fxctl" pull "$n" ) > /dev/null 2>&1 &
        ;;
esac
SH
    printf '#!/usr/bin/env bash\necho "KITTY $*" >> "$STUB_LOG"\n' > "$cfg/stubs/kitty"
    chmod +x "$cfg/stubs/"*
    FX="$fx" MEDIA="$cfg/media" python3 "$fx/gen.py" init
}

snapshot() {  # cfg
    # the host builds every source: the stocks one reads modules/stocks/data
    notif_snapshot "$1" "tools/dev/qml/$PROBE" modules/stocks/data modules/shell/cursor
    make_world "$1"
}

run_qml() {  # cfg log: the same environment as notif_run, plus the world's
    notif_run "$1" "$PROBE" "$2"
}

run_one() {  # cfg log
    run_qml "$1" "$2"
    local out
    out=$(notif_lines "$2" USBN)
    if ! printf '%s\n' "$out" | grep -q "USBN RESULT"; then
        rl_noresult "$NAME" "$2"; return 2
    fi
    printf '%s\n' "$out" | grep -v "^USBN PASS" 
    printf '%s\n' "$out" | grep -q "USBN RESULT PASS" || return 1
    local w
    w=$(notif_warnings "$2")
    [ -z "$w" ] || { echo "warnings:"; printf '%s\n' "$w" | head -5; return 1; }
    return 0
}

one_arm() {
    local a="$1" spec f from to needle cfg="$OUT/cfg_$1"
    spec=$(arm_of "$a") || { echo "ARM $a: unknown"; return 1; }
    IFS=$'\t' read -r f from to needle <<< "$spec"
    snapshot "$cfg"
    notif_arm "$cfg/$f" "$from" "$to" || { echo "ARM $a: NOT PROVEN (its anchor is gone)"; return 1; }
    run_qml "$cfg" "$OUT/arm_$a.log"
    local out
    out=$(notif_lines "$OUT/arm_$a.log" USBN)
    if ! printf '%s\n' "$out" | grep -q "USBN RESULT"; then echo "ARM $a: NOT PROVEN (the armed copy did not load)"; return 1; fi
    if printf '%s\n' "$out" | grep -q "USBN RESULT PASS"; then echo "ARM $a: STAYED GREEN"; return 1; fi
    if printf '%s\n' "$out" | grep "^USBN FAIL" | grep -qF "$needle"; then echo "ARM $a: FAILED AS IT MUST ($needle)"; rm -rf -- "${cfg:?}"; return 0; fi
    echo "ARM $a: FAILED, BUT NOT ON ITS CHECK: $(printf '%s\n' "$out" | grep '^USBN FAIL' | head -1)"; return 1
}

if [ "${ARM:-}" = all ]; then
    fail=0
    for a in $ARMS; do one_arm "$a" || fail=1; done
    [ "$fail" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit $fail
elif [ -n "${ARM:-}" ]; then
    one_arm "$ARM"; exit $?
fi

cfg="$OUT/cfg"
snapshot "$cfg"
run_one "$cfg" "$OUT/probe.log"; rc=$?
[ "$rc" = 2 ] && exit 1
if [ "$rc" = 0 ]; then echo "$NAME RESULT PASS ($(notif_lines "$OUT/probe.log" USBN | grep -c '^USBN PASS') checks)"; exit 0; fi
echo "$NAME RESULT FAIL (log: $OUT/probe.log)"; exit 1
