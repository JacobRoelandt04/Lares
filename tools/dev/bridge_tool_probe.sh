#!/usr/bin/env bash
# The REAL tools/bridge/lares-bridge against a FAKE WORLD -- never the desktop, never a phone.
#
#   tools/dev/bridge_tool_probe.sh                 ends in BRIDGE_TOOL RESULT PASS|FAIL
#   ARM=<name> tools/dev/bridge_tool_probe.sh      a fault in a COPY of tools/bridge; must FAIL on its needle
#   ARM=all                                       every ARM; BRIDGE_TOOL ARMS RESULT PASS when each failed as it must
#     nopidfd      the watcher holds no pidfd on a wrapper    -> "a wrapper killed with -9 reads failed"
#     cleanforeign a stale mount is cleaned whoever made it   -> "a stale mount that is not ours is refused"
#     noack        ack does not forget the record             -> "ack forgets an ended job"
#     rearm        arming does not ask whether the phone is armed already -> "the re-enumeration an arming causes arms nothing"
#                  (adbd's restart re-enumerates the phone: a new plug-in to the watcher, an endless replug; 2026-11-19)
#     nofocus      unlock types without checking the lock screen is in front -> "no typing into a lock screen that is not in front"
#     retryfailed  a PIN that failed may be tried again               -> "a PIN that failed is never typed again"
#     pininargv    the PIN is typed as an adb argv word               -> "the PIN is in no argv"
#     nodismiss    a trust-unlocked phone's lock screen is left alone -> "a trusted lock screen is dismissed without the PIN"
#     nocastunlock castprep --unlock does not unlock                  -> "castprep --unlock unlocks the phone before it answers"
#     nowaitunlock castprep does not wait for a running unlock        -> "castprep waits for a running unlock to finish"
#     unlockfails  a failed unlock fails castprep                     -> "a failed unlock never fails castprep"
#     noaskmtp     mount usb does not ask the phone for File transfer -> "mount usb asks the phone for File transfer first"
#     nocalmpref   usbcalm does not keep the choice in the prefs      -> "usbcalm keeps the choice in the device's prefs"
#     rerecord     a second castprep --hold records the raised timeout as the phone's own -> "a reconnect never records the raised value"
#     restoreany   castend puts the recorded timeout back whatever the phone reads now  -> "a timeout the user changed during the cast is theirs"
#     holdfixed    the hold is 30 min whatever bridge.jsonc cast.holdMin says          -> "bridge.jsonc cast.holdMin 5"
#     grepexit     the facts script ends on `grep` again: the real phone's adb shell exits 1 when the setting is off (round 6's facts broke
#                  on the user's phone while the stub's grep said 0) -> "facts: with no function it reads none"
# The unlock section (PIN in the keyring, typed over adb) runs against a FAKE PHONE LOCK in the stub adb (world adb.phone: locked, pin,
# autoConfirm, keyguardFocus, awake), a file-backed stub `secret-tool` and a fake Secret Service on the private bus (its `Locked`
# property is the world's keyring.locked): the PIN must reach the phone's stdin and nothing else the tool writes or runs.
#
# THE WORLD. A temp dir holds a HOME, an XDG_RUNTIME_DIR, a PRIVATE session bus (a dbus-daemon with no service directories: nothing is
# activated), the fake KDE Connect (tools/dev/stubs/bridge/fake_kdeconnectd.py), the fake adb server and the PATH stubs (adb, scrcpy,
# aft-mtp-mount, fusermount3, systemd-run, systemctl, kitty -- sshfs only when a check adds it), a fake /sys, a fake mount table and
# the four LARES_BRIDGE_* overrides. Everything runs under `env -i`: the desktop's session bus, Wayland display and runtime dir never
# reach a process here. The world file (tools/dev/stubs/bridge/world.py) scripts both fakes.
#
# Pids: every process of the world carries BRIDGE_FAKE=<dir> in its environment and is found through /proc/<pid>/environ at the end
# (never by name); the probe kills nothing else.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
NAME=BRIDGE_TOOL
STUBS=$ROOT/tools/dev/stubs/bridge
# shellcheck source=tools/dev/result_lib.sh
. tools/dev/result_lib.sh

outer() {
    local W LOG rc arm=${1:-}
    W=$(mktemp -d /tmp/lrbt.XXXXXX) || exit 1
    chmod 700 "$W"
    LOG=$W/probe.log
    # shellcheck disable=SC2064
    trap "reap_world '$W' '$LOG'" EXIT
    local tree=$ROOT
    if [ -n "$arm" ]; then
        tree=$W/tree
        mkdir -p "$tree/tools"
        cp -r "$ROOT/tools/bridge" "$ROOT/tools/lib" "$tree/tools/"
        find "$tree" -name __pycache__ -prune -exec rm -rf {} +
        arm_patch "$tree/tools/bridge" "$arm" > "$W/arm.log" 2>&1 || { cat "$W/arm.log"; echo "$NAME ARM $arm BAD (its anchor is gone)"; return 1; }
    fi
    # the machine's programs, less the ones a check needs absent: sshfs is missing until a check links the stub (the user's
    # machine has the real one since 2026-11-18, and a PATH with /usr/bin found it)
    mkdir -p "$W/sysbin"
    for f in /usr/local/bin/* /usr/bin/*; do
        n=${f##*/}
        case $n in sshfs) continue ;; esac
        [ -e "$W/sysbin/$n" ] || ln -s "$f" "$W/sysbin/$n"
    done
    env -i HOME="$W/home" PATH="$W/bin:$W/sysbin" LANG=C.UTF-8 USER="${USER:-probe}" TERM=dumb \
        XDG_RUNTIME_DIR="$W/xrt" XDG_CONFIG_HOME="$W/home/.config" XDG_STATE_HOME="$W/home/.local/state" \
        XDG_CACHE_HOME="$W/home/.cache" XDG_DATA_HOME="$W/home/.local/share" BRIDGE_FAKE="$W" \
        BRIDGE_PROBE_INNER=1 W="$W" TREE="$tree" ARM="$arm" \
        bash "$ROOT/tools/dev/bridge_tool_probe.sh" > "$LOG" 2>&1
    rc=$?
    grep -a -v "^$NAME RESULT" "$LOG"
    echo "(inner half exited $rc)"
    if [ -n "$arm" ]; then judge_arm "$arm" "$LOG"; return $?; fi
    rl_result "$NAME" "$LOG"
}

reap_world() {
    local w=$1 p pids left
    for _ in 1 2 3; do
        pids=""
        for p in /proc/[0-9]*; do
            [ -O "$p" ] || continue
            { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "BRIDGE_FAKE=$w" && pids="$pids ${p#/proc/}"
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
        nopidfd)      echo "a wrapper killed with -9 reads failed" ;;
        cleanforeign) echo "a stale mount that is not ours is refused" ;;
        noack)        echo "ack forgets an ended job" ;;
        rearm)        echo "the re-enumeration an arming causes arms nothing" ;;
        nofocus)      echo "no typing into a lock screen that is not in front" ;;
        retryfailed)  echo "a PIN that failed is never typed again" ;;
        pininargv)    echo "the PIN is in no argv" ;;
        nodismiss)    echo "a trusted lock screen is dismissed without the PIN" ;;
        nocastunlock) echo "castprep --unlock unlocks the phone before it answers" ;;
        nowaitunlock) echo "castprep waits for a running unlock to finish" ;;
        unlockfails)  echo "a failed unlock never fails castprep" ;;
        noaskmtp)     echo "mount usb asks the phone for File transfer first" ;;
        nocalmpref)   echo "usbcalm keeps the choice in the device's prefs" ;;
        grepexit)     echo "facts: with no function it reads none" ;;
        rerecord)     echo "a reconnect never records the raised value" ;;
        restoreany)   echo "a timeout the user changed during the cast is theirs" ;;
        holdfixed)    echo "bridge.jsonc cast.holdMin 5" ;;
    esac
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

arm_patch() {   # arm_patch <tools/bridge copy> <arm>: a lost anchor stops the run
    python3 - "$1" "$2" << 'PY'
import sys
d, arm = sys.argv[1:3]
def patch(fname, old, new):
    p = d + "/" + fname
    s = open(p).read()
    if s.count(old) != 1:
        print("ARM anchor FAIL (%d matches) in %s: %r" % (s.count(old), fname, old[:80])); sys.exit(3)
    open(p, "w").write(s.replace(old, new))
    print("ARM step ok: %s" % old[:60].replace("\n", "\\n"))
if arm == "nopidfd":
    patch("bridgelib/jobs.py", "        return os.pidfd_open(pid)", "        return -1")
elif arm == "cleanforeign":
    patch("bridgelib/actions.py", '    if m["state"] == "stale" and not m["mine"]:', "    if False:")
elif arm == "rearm":
    patch("bridgelib/actions.py", '    if rc == 0 and out.strip() == str(port):\n        return done(port=port, already=True)', "    pass")
elif arm == "nofocus":
    patch("bridgelib/actions.py", '    if ls is None or ls["focus"] != "keyguard" or not ls["awake"]:', "    if ls is None:")
elif arm == "retryfailed":
    patch("bridgelib/caps.py", '    elif pin == "failed":', "    elif False:")
elif arm == "pininargv":
    patch("bridgelib/actions.py", 'argvlib.adb_shell_stdin(serial), input="input text %s\\n" % pin,', 'argvlib.adb("shell", "input", "text", pin, serial=serial), input="",')
elif arm == "nodismiss":
    patch("bridgelib/actions.py", "        return _dismiss(serial, ls)", "        return done(unlocked=True, already=True)")
elif arm == "nocastunlock":
    patch("bridgelib/actions.py", 'unlock = _castprep_unlock(ctx, dev) if "--unlock" in opts and dev["pin"] == "set" else None', "unlock = None")
elif arm == "nowaitunlock":
    patch("bridgelib/actions.py", '        if time.time() >= end:\n            return {"ok": False, "already": False, "why": "Already unlocking"}',
          '        if True:\n            return {"ok": False, "already": False, "why": "Already unlocking"}')
elif arm == "unlockfails":
    patch("bridgelib/actions.py", '    extra = {} if unlock is None else {"unlock": unlock}',
          '    if unlock is not None and not unlock["ok"]:\n        return fail(FAILED, unlock["why"])\n    extra = {} if unlock is None else {"unlock": unlock}')
elif arm == "noaskmtp":
    patch("bridgelib/actions.py", "        _ask_mtp(ctx, dev)\n", "        pass\n")
elif arm == "nocalmpref":
    patch("bridgelib/actions.py", '        s["prefs"].setdefault(dev["key"], {})["usbUnlockMtp"] = on', "        pass")
elif arm == "grepexit":
    patch("bridgelib/parse.py", "dumpsys usb | grep screen_unlocked_functions; true", "dumpsys usb | grep screen_unlocked_functions")
elif arm == "rerecord":
    patch("bridgelib/actions.py", "    if not isinstance(rec, dict):\n        was = _hold_read(serial)", "    if True:\n        was = _hold_read(serial)")
    patch("bridgelib/actions.py", "            if not isinstance(h.get(key), dict):\n                h[key] =", "            if True:\n                h[key] =")
elif arm == "holdfixed":
    patch("bridgelib/actions.py", '        return int(round(float(ctx.cfg["cast"]["holdMin"]) * 60000))', "        return HOLD_MS")
elif arm == "restoreany":
    patch("bridgelib/actions.py", '    if now == int(rec.get("set", HOLD_MS)):', "    if True:")
elif arm == "noack":
    patch("bridgelib/jobs.py", '    remove(paths, job_id)\n    return "gone"', '    return "gone"')
else:
    print("no such ARM: " + arm); sys.exit(3)
PY
}

if [ "${BRIDGE_PROBE_INNER:-}" != 1 ]; then
    case ${ARM:-} in
        all)
            bad=0
            for a in nopidfd cleanforeign noack rearm nofocus retryfailed pininargv nodismiss nocastunlock nowaitunlock unlockfails noaskmtp nocalmpref grepexit rerecord restoreany holdfixed; do ARM=$a "$0" || bad=1; echo; done
            [ $bad -eq 0 ] && { echo "$NAME ARMS RESULT PASS"; exit 0; }
            echo "$NAME ARMS RESULT FAIL"; exit 1 ;;
        "") outer ""; exit $? ;;
        *) outer "$ARM"; exit $? ;;
    esac
fi

# =====================================================================================================
# THE INNER HALF (inside `env -i`, inside the world)
# =====================================================================================================
LIB=$STUBS/probe_lib.py
TOOL=$TREE/tools/bridge/lares-bridge
FAILS=0
PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1${2:+: $2}"; }
check() { if [ "$2" = 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

mkdir -p "$W/bin" "$W/home" "$W/xrt" "$W/cfg" "$W/state" "$W/rt" "$W/mnt" "$W/vid" "$W/shots" "$W/sys/bus/usb/devices" "$W/files"
chmod 700 "$W/xrt"
for f in adb scrcpy aft-mtp-mount fusermount3 systemd-run systemctl kitty secret-tool; do ln -s "$STUBS/bin/$f" "$W/bin/$f"; done
PORT=$((20000 + RANDOM % 20000))
cat > "$W/bus.conf" << EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><keep_umask/><listen>unix:path=$W/bus</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy></busconfig>
EOF
dbus-daemon --config-file="$W/bus.conf" --nofork --print-address > "$W/bus.addr" 2> "$W/bus.err" &
for _ in $(seq 100); do [ -s "$W/bus.addr" ] && break; sleep 0.05; done
export DBUS_SESSION_BUS_ADDRESS=unix:path=$W/bus
export BRIDGE_PRIVATE_BUS=1 BRIDGE_WORLD=$W/world.json BRIDGE_KDC_LOG=$W/kdc.log BRIDGE_STUB_LOG=$W/stub.log BRIDGE_MOUNTINFO=$W/mountinfo
export BRIDGE_SECRET_FILE=$W/secrets.json BRIDGE_PHONE_LOG=$W/phone.log
export BRIDGE_ADB_PIDFILE=$W/adb.pid ANDROID_ADB_SERVER_PORT=$PORT
export LARES_BRIDGE_CONFIG=$W/cfg/bridge.jsonc LARES_BRIDGE_STATE=$W/state LARES_BRIDGE_RUNTIME=$W/rt LARES_BRIDGE_SYS=$W/sys LARES_BRIDGE_MOUNTINFO=$W/mountinfo
: > "$W/kdc.log"; : > "$W/stub.log"
echo "36 29 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw" > "$W/mountinfo"
cat > "$W/cfg/bridge.jsonc" << EOF
// the probe's config
{ "adb": { "idleKillS": 60 }, "files": { "usbMount": "$W/mnt" }, "mirror": { "recordDir": "$W/vid" }, "shots": { "dir": "$W/shots" } }
EOF
python3 "$LIB" world "$W/world.json" '{"kdc": {"mountOk": false, "mountError": "Failed to start sshfs", "devices": {"abc123": {"name": "REDMAGIC 10S Pro", "type": "phone", "reachable": true, "paired": true, "pairState": 3, "addresses": ["192.168.0.240"], "links": ["LAN"], "plugins": ["battery", "connectivity_report", "sftp", "share", "findmyphone", "clipboard", "ping"], "verificationKey": "305BAF9E", "battery": {"charge": 81, "charging": false}, "cell": {"strength": 3, "type": "LTE"}}}}, "adb": {"devices": [], "mdns": [], "connectable": ["192.168.0.240:5555"], "pushStepMs": 300}}'
wset() { python3 "$STUBS/world.py" "$W/world.json" set "$1" "$2"; }

python3 "$STUBS/fake_kdeconnectd.py" > "$W/kdc.out" 2>&1 &
KPID=$!
for _ in $(seq 100); do grep -q "kdc-stub ready" "$W/kdc.out" 2> /dev/null && break; sleep 0.05; done
grep -q "kdc-stub ready" "$W/kdc.out" || { echo "  FAIL the fake KDE Connect did not start"; cat "$W/kdc.out"; }

python3 "$STUBS/fake_secretservice.py" > "$W/secret.out" 2>&1 &
for _ in $(seq 100); do grep -q "secret-stub ready" "$W/secret.out" 2> /dev/null && break; sleep 0.05; done
grep -q "secret-stub ready" "$W/secret.out" || { echo "  FAIL the fake Secret Service did not start"; cat "$W/secret.out"; }

run() { OUT=$("$TOOL" "$@" 2> "$W/tool.err"); RC=$?; }
wait_w() { python3 "$LIB" wait "$W/watch.out" "$@"; }            # wait_w <s> <expr>
wcheck() { local n=$1 t=$2 e=$3 seen; seen=$(wait_w "$t" "$e"); check "$n" $? "$seen"; }
ocheck() { printf '%s' "$OUT" | python3 "$LIB" ev "$2"; check "$1" $? "$OUT"; }   # ocheck <name> <expr over J>
rccheck() { [ "$RC" = "$2" ]; check "$1" $? "exit $RC (wanted $2): $OUT"; }
logged() { grep -q -- "$2" "$1"; }

# ---- the watcher: the first line ----
"$TOOL" watch > >(python3 "$LIB" stamp "$W/watch.out") 2> "$W/watch.err" &
WPID=$!
wcheck "watch prints a first line with the schema's keys" 8 'L["v"]==1 and L["serial"]==1 and set(L)>={"v","serial","env","current","devices","pairing","jobs"} and set(L["env"])=={"kdeconnect","adbServer","have"} and set(L["env"]["have"])=={"adb","scrcpy","aft","sshfs","fusermount"}'
wcheck "the first line: KDE Connect running, adb down (nothing started it), the paired phone" 3 'L["env"]["kdeconnect"]=="running" and L["env"]["adbServer"]=="down" and L["devices"][0]["key"]=="kdc:abc123" and L["current"]=="kdc:abc123"'
wcheck "the device record: battery, cell, addresses, skin, link" 3 '(lambda d: d["battery"]=={"charge":81,"charging":False} and d["cell"]=={"strength":3,"type":"LTE"} and d["kdc"]["addresses"]==["192.168.0.240"] and d["skin"]=="redmagic-10s-pro-moonlight" and d["link"]=="wifi" and d["present"])(L["devices"][0])'
wcheck "can.mirror is optimistic over the LAN (via tcp)" 3 'L["devices"][0]["can"]["mirror"]=={"ok":True,"why":"","hint":"","via":"tcp"}'
wcheck "can.mountWifi says sshfs is missing when sshfs is not on PATH" 3 'L["devices"][0]["can"]["mountWifi"]=={"ok":False,"why":"sshfs is missing","hint":"sudo pacman -S sshfs","via":""}'
wcheck "the first line has the contract's device keys and the thirteen actions" 3 'set(L["devices"][0])=={"key","name","type","skin","present","link","lastSeen","kdc","battery","cell","usb","adb","prefs","pin","mounts","facts","can"} and L["devices"][0]["pin"]=="none" and list(L["devices"][0]["can"])==["mirror","mountUsb","mountWifi","send","shot","ring","clip","key","pair","unpair","arm","facts","unlock"] and L["devices"][0]["can"]["unlock"]["why"]=="No PIN kept"'

# ---- at rest: no fork, no CPU ----
T0=$(awk '{print $14+$15}' "/proc/$WPID/stat"); C0=$(cat /proc/$WPID/task/*/children 2> /dev/null | wc -w)
sleep 3
T1=$(awk '{print $14+$15}' "/proc/$WPID/stat"); C1=$(cat /proc/$WPID/task/*/children 2> /dev/null | wc -w)
[ $((T1 - T0)) -le 3 ] && [ "$C0" = "$C1" ]; check "the watcher at rest uses no CPU and forks nothing (its one child is the output stamper)" $? "ticks $T0 -> $T1, children $C0 -> $C1: $(ps -o pid,args --ppid "$WPID" | tail -n +2)"

# ---- events: a line per change ----
N0=$(python3 "$LIB" count "$W/watch.out" 'True')
wset kdc.devices.abc123.battery '{"charge": 80, "charging": true}'
wcheck "a battery change is one new line" 4 'L["devices"][0]["battery"]=={"charge":80,"charging":True}'
N1=$(python3 "$LIB" count "$W/watch.out" 'True')
[ "$N1" -le $((N0 + 2)) ]; check "...coalesced (at most two lines for one change)" $? "$N0 -> $N1"
wcheck "serial rises by one per line" 2 '[l["serial"] for l in ALL]==list(range(1,len(ALL)+1))'
wset kdc.devices.abc123.reachable false
wcheck "reachable false: not present, link none" 4 'L["devices"][0]["present"]==False and L["devices"][0]["link"]=="none" and L["devices"][0]["can"]["ring"]["ok"]==False'
wset kdc.devices.abc123.reachable true
wcheck "reachable true again" 4 'L["devices"][0]["present"]==True and L["devices"][0]["link"]=="wifi"'
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wcheck "a USB plug (fake sysfs): the cable joins the KDE Connect device by its name" 4 '(lambda d: d["key"]=="kdc:abc123" and d["usb"]=={"serial":"RZ8N30ABCDE","vendor":"19d2","product":"1234","adbIface":True,"mtpIface":True} and d["link"]=="both")(L["devices"][0]) and len(L["devices"])==1'
wcheck "...and its MTP mode lets the cable's files be mounted" 2 'L["devices"][0]["can"]["mountUsb"]["ok"]'
sleep 0.3
grep -q '"abc123": "RZ8N30ABCDE"' "$W/state/state.json"; check "the link (kdc id -> USB serial) is stored" $? "$(cat "$W/state/state.json" 2>&1 | head -c 300)"
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
wcheck "an unplug: the cable is gone" 4 'L["devices"][0]["usb"] is None and L["devices"][0]["link"]=="wifi"'
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wcheck "plugged again (the stored link joins it)" 4 'L["devices"][0]["usb"] is not None and len(L["devices"])==1'
echo "41 29 0:40 / $W/mnt rw,nosuid,nodev,relatime shared:2 - fuse aft-mtp-mount rw,user_id=1000" >> "$W/mountinfo"
wcheck "a mount appearing in the mount table (POLLPRI stand-in): mounted, not ours" 4 'L["devices"][0]["mounts"]["usb"]=={"point":"'"$W"'/mnt","state":"mounted","mine":False,"open":"'"$W"'/mnt"}'
sed -i "\|$W/mnt|d" "$W/mountinfo"
wcheck "...and going" 4 'L["devices"][0]["mounts"]["usb"]["state"]=="unmounted"'
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
wcheck "(unplugged again)" 4 'L["devices"][0]["usb"] is None'
wset kdc.devices.def456 '{"name": "Tablet", "type": "tablet", "reachable": true, "paired": false, "pairState": 0, "addresses": ["192.168.0.50"], "links": ["LAN"], "plugins": [], "verificationKey": "AA11BB22"}'
wcheck "an unpaired reachable device is in pairing, not in devices" 4 'L["pairing"]==[{"key":"kdc:def456","name":"Tablet","type":"tablet","byPeer":False,"verificationKey":"AA11BB22"}] and len(L["devices"])==1'

# ---- the one-shots ----
run state; rccheck "state exits 0" 0
ocheck "state prints the watch line (serial 1, the same keys)" 'J["v"]==1 and J["serial"]==1 and J["devices"][0]["key"]=="kdc:abc123" and set(J)>={"v","serial","env","current","devices","pairing","jobs"}'
run doctor; rccheck "doctor exits 0" 0
ocheck "doctor: {ok, rows}, the sshfs row says what to install" 'J["ok"]==False and any(r["id"]=="sshfs" and not r["ok"] and "pacman -S sshfs" in r["hint"] for r in J["rows"]) and all(set(r)=={"id","ok","text","hint"} for r in J["rows"])'
OUT=$("$TOOL" doctor --plain 2> /dev/null); echo "$OUT" | grep -q "^MISSING sshfs"; check "doctor --plain prints lines for lares setup" $? "$OUT"
run select kdc:abc123; rccheck "select exits 0" 0
run select kdc:nope; rccheck "select of an unknown device exits 3 (not available)" 3
ocheck "...with a reason" 'J["ok"]==False and J["reason"] and "hint" in J'
run set kdc:abc123 mode '"camera"'; rccheck "set mode camera exits 0" 0
wcheck "...and the watch line carries the pref" 4 'L["devices"][0]["prefs"]["mode"]=="camera"'
run set kdc:abc123 mode '"bogus"'; rccheck "set with a bad value exits 2 (usage)" 2
run set kdc:abc123 record yes; rccheck "set with a value that is not JSON exits 2" 2
run set kdc:abc123 mode '"mirror"'
run mirror; rccheck "mirror with no device exits 2" 2
run frobnicate; rccheck "an unknown command exits 2" 2
ocheck "usage errors are still one JSON line" 'J["ok"]==False'
run refresh; rccheck "refresh exits 0" 0
logged "$W/kdc.log" "daemon forceOnNetworkChange"; check "...and asked the daemon for forceOnNetworkChange" $?
run ring kdc:abc123; rccheck "ring exits 0" 0
logged "$W/kdc.log" "abc123 findmyphone ring"; check "...through the findmyphone plugin" $?
run clip kdc:abc123; rccheck "clip exits 0" 0
logged "$W/kdc.log" "abc123 clipboard sendClipboard"; check "...through the clipboard plugin" $?
run pair kdc:def456; rccheck "pair (a device from the pairing list) exits 0" 0
logged "$W/kdc.log" "def456 device requestPairing"; check "...requestPairing" $?
run accept kdc:def456; rccheck "accept exits 0" 0
wcheck "the accepted device is paired and listed" 5 'any(d["key"]=="kdc:def456" and d["kdc"]["paired"] for d in L["devices"]) and L["pairing"]==[]'
run unpair kdc:def456; rccheck "unpair exits 0" 0
logged "$W/kdc.log" "def456 device unpair"; check "...unpair" $?
run reject kdc:def456; rccheck "reject exits 0" 0
logged "$W/kdc.log" "def456 device cancelPairing"; check "...cancelPairing" $?
run ring kdc:def456; rccheck "ring on an unpaired device is refused as not available (3)" 3

# a phone away from the wire: no cable, KDE Connect only; adb is started for the need
run mirror kdc:abc123
rccheck "mirror over Wi-Fi exits 0" 0
ocheck "...answers the job and the transport" 'J["ok"] and J["job"]=="m-1" and J["via"]=="tcp"'
logged "$W/stub.log" "adb start-server"; check "the adb server was started for the need" $?
[ -f "$W/rt/adb-started" ]; check "...and marked as ours (adb-started)" $?
logged "$W/stub.log" "adb connect 192.168.0.240:5555"; check "the ladder tried KDE Connect's address with the armed port" $?
logged "$W/stub.log" "scrcpy -s 192.168.0.240:5555 --window-title REDMAGIC 10S Pro --max-size=1600 --video-bit-rate=6M --max-fps=60"; check "scrcpy got -s <address> and the Wi-Fi sizes" $? "$(grep scrcpy "$W/stub.log")"
logged "$W/stub.log" "systemd-run --user --scope --collect --quiet --expand-environment=no --unit=lares-bridge-mirror-m-1 -- setsid -f"; check "the job went through the systemd-run wrapper line" $?
wcheck "the job is running in the watch line" 5 'any(j["id"]=="m-1" and j["phase"]=="running" and j["via"]=="tcp" and j["kind"]=="mirror" and j["device"]=="kdc:abc123" for j in L["jobs"])'
wcheck "...and the watcher sees the adb server (the transport the connect made)" 4 'L["env"]["adbServer"]=="up" and L["devices"][0]["adb"]["transport"]=="tcp" and L["devices"][0]["adb"]["address"]=="192.168.0.240:5555"'
WRAP=$(python3 -c "import json;print(json.load(open('$W/rt/jobs/m-1.json'))['pid'])")
[ -d "/proc/$WRAP" ]; check "a job survives the death of the process that started it (the one-shot is gone, the wrapper lives)" $? "wrapper $WRAP"
run mirror kdc:abc123; rccheck "a second mirror of the same phone is refused (4)" 4

# a fresh watcher reports the job
kill -TERM "$WPID" 2> /dev/null; wait "$WPID" 2> /dev/null; TRC=$?
[ "$TRC" = 0 ]; check "TERM ends the watcher cleanly (exit 0)" $? "exit $TRC"
mv "$W/watch.out" "$W/watch1.out"
"$TOOL" watch > >(python3 "$LIB" stamp "$W/watch.out") 2> "$W/watch2.err" &
WPID=$!
wcheck "a fresh watch reports the live job (it outlived the first watcher)" 8 'any(j["id"]=="m-1" and j["phase"]=="running" for j in L["jobs"])'
[ -d "/proc/$WRAP" ]; check "...and the wrapper is still the same process" $?

# a failed try is remembered until the links change
run stop m-1; rccheck "stop exits 0" 0
wcheck "the stopped job is done" 5 'any(j["id"]=="m-1" and j["phase"]=="done" and j["code"]==0 for j in L["jobs"])'
run ack m-1; rccheck "ack exits 0" 0
wcheck "ack forgets an ended job" 4 'not any(j["id"]=="m-1" for j in L["jobs"])'
ls "$W/rt/jobs/" | grep -q "m-1.json"; [ $? -ne 0 ]; check "...the record file is gone" $?
run ack m-99; rccheck "ack of an unknown job exits 3" 3
BRIDGE_SCRCPY_FAIL="Could not find any ADB device" run mirror kdc:abc123
rccheck "a scrcpy that stops at once: mirror exits 1" 1
ocheck "...with scrcpy's own reason" 'J["ok"]==False and J["reason"]=="Could not find any ADB device" and J["hint"]'
wcheck "the failed try is told as can.mirror.why, and mirror stays pressable" 5 'L["devices"][0]["can"]["mirror"]["ok"]==True and L["devices"][0]["can"]["mirror"]["why"]=="Could not find any ADB device"'
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wset adb.devices '["RZ8N30ABCDE\tdevice usb:1-4 product:NX789J model:NX789J device:NX789J transport_id:1", "192.168.0.240:5555\tdevice product:NX789J model:NX789J device:NX789J transport_id:9"]'
wcheck "...until the device's links change (the cable arrives)" 5 'L["devices"][0]["can"]["mirror"]["ok"] and L["devices"][0]["can"]["mirror"]["via"]=="usb" and L["devices"][0]["can"]["mirror"]["why"]==""'

# a mirror over the cable, then a wrapper killed with -9
run mirror kdc:abc123 --mode audio --screen-off --record
rccheck "mirror --mode audio over the cable exits 0" 0
ocheck "...via usb" 'J["via"]=="usb" and J["job"]'
JOB=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['job'])")
logged "$W/stub.log" "scrcpy -s RZ8N30ABCDE --window-title REDMAGIC 10S Pro --no-video --no-control --record=$W/vid/phone-"; check "the audio mode argv: -s <usb serial>, no video, a record file in recordDir" $? "$(grep scrcpy "$W/stub.log" | tail -1)"
wcheck "the audio job is running" 5 'any(j["id"]=="'"$JOB"'" and j["phase"]=="running" and j["mode"]=="audio" for j in L["jobs"])'
WRAP=$(python3 -c "import json;print(json.load(open('$W/rt/jobs/$JOB.json'))['pid'])")
kill -9 "$WRAP"
wcheck "a wrapper killed with -9 reads failed" 5 'any(j["id"]=="'"$JOB"'" and j["phase"]=="failed" and j["reason"]=="ended without a word" and j["code"] is None for j in L["jobs"])'
run ack "$JOB"

# files over the cable: a mount the tool made, and a stale endpoint
# the phone's USB functions: a phone that lacks MTP is asked for File transfer first (world adb.usb; see the adb stub)
: > "$W/stub.log"
run mount kdc:abc123 usb; rccheck "mount usb exits 0" 0
logged "$W/stub.log" "shell svc usb getFunctions"; check "mount usb reads the phone's USB functions first" $? "$(cat "$W/stub.log")"
logged "$W/stub.log" "shell svc usb setFunctions mtp"; check "mount usb asks the phone for File transfer first" $? "$(cat "$W/stub.log")"
ocheck "...answers the point and a job" 'J["point"]=="'"$W"'/mnt" and J["job"].startswith("f-")'
logged "$W/stub.log" "aft-mtp-mount $W/mnt"; check "aft-mtp-mount got the configured mount point" $?
wcheck "the mount shows as mounted and ours" 5 'L["devices"][0]["mounts"]["usb"]["state"]=="mounted" and L["devices"][0]["mounts"]["usb"]["mine"]==True'
run unmount kdc:abc123 usb; rccheck "unmount usb exits 0" 0
logged "$W/stub.log" "fusermount3 -u $W/mnt"; check "...through fusermount3 -u" $?
wcheck "unmounted again" 5 'L["devices"][0]["mounts"]["usb"]["state"]=="unmounted"'
: > "$W/stub.log"
run mount kdc:abc123 usb; rccheck "(the phone is on File transfer now) mount usb exits 0" 0
! logged "$W/stub.log" "setFunctions"; check "a phone already on File transfer is not asked again" $? "$(cat "$W/stub.log")"
run unmount kdc:abc123 usb
wcheck "(unmounted)" 5 'L["devices"][0]["mounts"]["usb"]["state"]=="unmounted"'
# on the cable with adb and no MTP interface yet: offered, asked, and the interface is waited for (up to 4 s)
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb
wset adb.usb '{"functions": "adb", "onMtp": ["1-4", "19d2", "1234", "RZ8N30ABCDE", "REDMAGIC 10S Pro", "adb", "mtp"]}'
wcheck "a cable with adb and no File transfer is still offered usb files (the mount asks the phone)" 5 'L["devices"][0]["usb"] and not L["devices"][0]["usb"]["mtpIface"] and L["devices"][0]["can"]["mountUsb"]["ok"]'
t0=$(date +%s.%N); run mount kdc:abc123 usb; t1=$(date +%s.%N)
rccheck "mount usb on an adb-only cable exits 0" 0
python3 -c "import sys; sys.exit(0 if float('$t1') - float('$t0') < 3.0 else 1)"; check "...as soon as the phone shows File transfer (no 4 s wait)" $? "$(python3 -c "print($t1 - $t0)")"
ls "$W/sys/bus/usb/devices/" | grep -q '^1-4:1.1$'; check "...the phone's MTP interface is on the cable" $? "$(ls "$W/sys/bus/usb/devices/")"
run unmount kdc:abc123 usb
wcheck "(unmounted)" 5 'L["devices"][0]["mounts"]["usb"]["state"]=="unmounted"'
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb
wset adb.usb '{"functions": "adb"}'
wcheck "(an adb-only cable again, and the phone will not switch)" 5 'L["devices"][0]["usb"] and not L["devices"][0]["usb"]["mtpIface"]'
t0=$(date +%s.%N); run mount kdc:abc123 usb; t1=$(date +%s.%N)
python3 -c "import sys; sys.exit(0 if 3.6 <= float('$t1') - float('$t0') <= 9 else 1)"; check "a phone that never shows File transfer is waited for about 4 s, then the mount is tried anyway" $? "$(python3 -c "print($t1 - $t0)") rc $RC"
run unmount kdc:abc123 usb
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wset adb.usb '{}'
wcheck "(the cable is back to adb + mtp)" 5 'L["devices"][0]["usb"] and L["devices"][0]["usb"]["mtpIface"]'
# a stale endpoint that is NOT ours (written by somebody else, ENOTCONN on stat)
rm -f "$W/rt/mine.json"
echo "41 29 0:40 / $W/mnt rw,nosuid,nodev,relatime shared:2 - fuse aft-mtp-mount rw,user_id=1000" >> "$W/mountinfo"
: > "$W/stub.log"
LARES_BRIDGE_ENOTCONN=$W/mnt run unmount kdc:abc123 usb
rccheck "a stale mount that is not ours is refused (4)" 4
! logged "$W/stub.log" "fusermount3"; check "a stale mount that is not ours is refused: nothing was cleaned" $? "$(cat "$W/stub.log")"
printf '{"%s/mnt": {"device": "kdc:abc123", "at": 1}}' "$W" > "$W/rt/mine.json"
LARES_BRIDGE_ENOTCONN=$W/mnt run unmount kdc:abc123 usb
rccheck "a stale mount the tool made is cleaned (0)" 0
logged "$W/stub.log" "fusermount3 -uz $W/mnt"; check "...with the lazy unmount" $?
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4

# Wi-Fi files need sshfs
run state; ocheck "(sshfs still missing)" 'J["devices"][0]["can"]["mountWifi"]["why"]=="sshfs is missing"'
run mount kdc:abc123 wifi; rccheck "mount wifi without sshfs exits 3" 3
ocheck "...says what to install" 'J["reason"]=="sshfs is missing" and J["hint"]=="sudo pacman -S sshfs"'
ln -s "$STUBS/bin/sshfs" "$W/bin/sshfs"
run mount kdc:abc123 wifi; rccheck "with sshfs, a KDE Connect mount that fails exits 1" 1
ocheck "...with the daemon's own error" 'J["reason"]=="Failed to start sshfs"'
wset kdc.mountOk true
run mount kdc:abc123 wifi; rccheck "mount wifi exits 0 when KDE Connect mounts" 0
ocheck "...answers the mount point" 'J["point"]=="/run/user/1000/abc123"'
# the sshfs mount as the table shows it: the row offers the phone's storage inside it (getDirectories), not the phone's whole tree
echo "77 29 0:99 / /run/user/1000/abc123 rw,nosuid,nodev - fuse.sshfs kdeconnect@192.168.0.240:/ rw" >> "$W/mountinfo"
wcheck "the Wi-Fi mount opens at the phone's storage (getDirectories), not at its whole tree" 4 '(lambda m: m["state"]=="mounted" and m["point"]=="/run/user/1000/abc123" and m["open"]=="/run/user/1000/abc123/storage/emulated/0")(L["devices"][0]["mounts"]["wifi"])'
: > "$W/stub.log"
run unmount kdc:abc123 wifi; rccheck "unmount wifi exits 0" 0
# KDE Connect ends its sshfs and leaves the FUSE mount in the table (it read "mounted" for 42 s, then "stale", 2026-11-19): the tool
# takes it away before it answers
! grep -q " /run/user/1000/abc123 " "$W/mountinfo"; check "...and nothing of the mount is left in the table when it answers" $? "$(cat "$W/mountinfo")"
logged "$W/stub.log" "fusermount3 -uz /run/user/1000/abc123" || logged "$W/stub.log" "fusermount3 -u -z /run/user/1000/abc123"; check "...taken away lazily by the tool (its server is gone)" $? "$(cat "$W/stub.log")"
wcheck "...and the watch line says unmounted at once" 4 'L["devices"][0]["mounts"]["wifi"]["state"]=="unmounted"'
rm -f "$W/bin/sshfs"

# send, shot, keys, arming, facts
printf 'hello bridge' > "$W/files/a.txt"
wset adb.devices '["192.168.0.240:5555\tdevice product:NX789J model:NX789J device:NX789J transport_id:9"]'
sleep 0.3
run send kdc:abc123 "$W/files/a.txt"; rccheck "send over adb exits 0" 0
ocheck "...a send job via adb" 'J["via"]=="adb" and J["job"].startswith("s-")'
SJOB=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['job'])")
wcheck "the send job carries figures: one file, its size, a name" 5 'any(j["id"]=="'"$SJOB"'" and j["files"]==1 and j["total"]==12 and j["name"]=="a.txt" for j in L["jobs"])'
wcheck "the send job ends done with done == total" 8 'any(j["id"]=="'"$SJOB"'" and j["phase"]=="done" and j["done"]==12 and j["code"]==0 for j in L["jobs"])'
logged "$W/stub.log" "adb -s 192.168.0.240:5555 push $W/files/a.txt /sdcard/Download/"; check "adb push went to files.sendDir" $?
python3 - "$W/watch.out" "$SJOB" << 'PY'
import json, sys
rows = []
for raw in open(sys.argv[1]):
    t, _, b = raw.partition("\t")
    l = json.loads(b)
    j = next((x for x in l["jobs"] if x["id"] == sys.argv[2]), None)
    if j and (not rows or rows[-1][1] != (j["done"], j["rate"], j["file"], j["phase"])):
        rows.append((float(t), (j["done"], j["rate"], j["file"], j["phase"])))
gaps = [b[0] - a[0] for a, b in zip(rows, rows[1:])]
mid = [g for g, (a, b) in zip(gaps, zip(rows, rows[1:])) if a[1][3] == "running" and b[1][3] == "running"]
print("figures lines", len(rows), "gaps", [round(g, 2) for g in mid])
sys.exit(0 if all(g >= 0.45 for g in mid) and len(rows) >= 2 else 1)
PY
check "job figures change at most every 500 ms in the watch line" $?
run send kdc:abc123 --via kdeconnect "$W/files/a.txt"; rccheck "send --via kdeconnect exits 0" 0
logged "$W/kdc.log" "abc123 share shareUrls"; check "...a KDE Connect share (no job)" $?
run send kdc:abc123 "$W/files/none"; rccheck "send of a missing file exits 1" 1
run shot kdc:abc123; rccheck "shot exits 0" 0
ocheck "...answers a phone-<date>.png path that is a PNG" 'J["path"].startswith("'"$W"'/shots/phone-") and J["path"].endswith(".png")'
head -c 8 "$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['path'])")" | od -An -c | grep -q "P   N   G"; check "...and the file is a PNG" $?
run key kdc:abc123 power; rccheck "key power exits 0" 0
logged "$W/stub.log" "shell input keyevent 26"; check "...adb shell input keyevent 26" $?
run key kdc:abc123 home; rccheck "key with a bad name exits 2" 2
# ---- unlock: the PIN kept in the login keyring, typed over adb (a fake phone lock; see the header) ----
PIN=7Kq93xZp41
: > "$W/unlock-out.log"
urun() { run "$@"; printf '%s\n%s\n' "$OUT" "$(cat "$W/tool.err")" >> "$W/unlock-out.log"; }
phone_set() { wset adb.phone "$1"; : > "$W/phone.log"; }
texts() { grep -c '^text ' "$W/phone.log"; }
sloglines() { grep -c -- "$1" "$W/stub.log"; }
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
run lockstate kdc:abc123; rccheck "lockstate exits 0" 0
ocheck "...locked, keyguard up, asleep, the lock screen in front" 'J=={"ok":True,"locked":True,"keyguard":True,"awake":False,"focus":"keyguard"}'
urun unlock kdc:abc123; rccheck "unlock with no PIN kept is refused as not available (3)" 3
ocheck "...says why, and what to do" 'J["reason"]=="No PIN kept" and J["hint"]=="Set it on the Details page"'
[ "$(texts)" = 0 ]; check "...and nothing was typed" $?
urun castprep kdc:abc123 --unlock; rccheck "castprep --unlock with no PIN kept still answers (0)" 0
ocheck "...with no unlock field and a transport" '"unlock" not in J and J["serial"] and J["via"]'
printf 'ab1\n' | "$TOOL" pin kdc:abc123 set > "$W/pin.out" 2> "$W/pin.err"; PRC=$?
[ "$PRC" = 2 ]; check "pin set with a PIN of 3 characters is a usage error (2)" $? "exit $PRC"
printf 'ab 12\n' | "$TOOL" pin kdc:abc123 set > /dev/null 2>&1; [ $? = 2 ]; check "...and so is one with a space" $?
printf '12345678901234567\n' | "$TOOL" pin kdc:abc123 set > /dev/null 2>&1; [ $? = 2 ]; check "...and one of 17" $?
[ ! -s "$W/secrets.json" ]; check "...and nothing was stored" $? "$(cat "$W/secrets.json" 2> /dev/null)"
run state; ocheck "...the device says pin none" 'J["devices"][0]["pin"]=="none" and not J["devices"][0]["can"]["unlock"]["ok"]'
wset keyring.locked true
printf '%s\n' "$PIN" | "$TOOL" pin kdc:abc123 set > "$W/pin.out" 2> "$W/pin.err"; PRC=$?
[ "$PRC" = 3 ] && grep -q "keyring is locked" "$W/pin.out"; check "pin set with a locked keyring is refused (3) and says so" $? "exit $PRC $(cat "$W/pin.out")"
! grep -q "secret-tool store" "$W/stub.log"; check "...and secret-tool was never asked (a locked keyring is never prompted)" $?
wset keyring.locked false
printf '%s\n' "$PIN" | "$TOOL" pin kdc:abc123 set > "$W/pin.out" 2> "$W/pin.err"; PRC=$?
[ "$PRC" = 0 ] && python3 "$LIB" ev 'J=={"ok":True}' < "$W/pin.out"; check "pin set stores the PIN and answers {ok} only" $? "exit $PRC $(cat "$W/pin.out")"
grep -qF -- "secret-tool store --label=Lares bridge: unlock PIN for REDMAGIC 10S Pro service lares-bridge device abc123" "$W/stub.log"; check "...under service=lares-bridge, device=<kdc id>, labelled with the device's name" $? "$(grep secret-tool "$W/stub.log")"
wcheck "...and the watch line says pin set, unlock ok" 4 'L["devices"][0]["pin"]=="set" and L["devices"][0]["can"]["unlock"]["ok"] and L["devices"][0]["can"]["unlock"]["via"]=="tcp"'
urun unlock kdc:abc123 --auto; rccheck "unlock (auto-confirm PIN pad, asleep) exits 0" 0
ocheck "...unlocked, not already" 'J=={"ok":True,"unlocked":True}'
grep -q '^key KEYCODE_WAKEUP' "$W/phone.log" && grep -q '^dismiss-keyguard' "$W/phone.log" && grep -q "^text $PIN\$" "$W/phone.log"; check "the phone was woken, its PIN pad brought up and the PIN typed" $? "$(cat "$W/phone.log")"
! grep -q 'KEYCODE_ENTER' "$W/phone.log"; check "...with no Enter after an auto-confirmed unlock (it would land in an app)" $? "$(cat "$W/phone.log")"
grep -q '"kind":"unlock","step":"start","auto":true' "$W/state-cache/trace.jsonl"; check "--auto is recorded in the trace and changes nothing else" $?
urun unlock kdc:abc123; rccheck "unlock of an unlocked phone exits 0" 0
ocheck "...says already" 'J=={"ok":True,"unlocked":True,"already":True}'
[ "$(texts)" = 1 ]; check "...and typed nothing more" $? "$(cat "$W/phone.log")"
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": false, "keyguardFocus": true, "awake": true, "bouncer": false}'
urun unlock kdc:abc123; rccheck "unlock on a PIN pad that waits for Enter exits 0" 0
grep -q '^key KEYCODE_ENTER' "$W/phone.log"; check "...Enter was sent after the text" $? "$(cat "$W/phone.log")"
run lockstate kdc:abc123; ocheck "(the phone is unlocked now)" 'J["locked"]==False and J["focus"]=="app"'
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": false, "awake": true, "bouncer": false}'
urun unlock kdc:abc123; rccheck "unlock while an app is in front of the lock screen exits 1" 1
ocheck "...says the lock screen did not take the keys" 'J["reason"]=="The lock screen did not take the keys"'
[ "$(texts)" = 0 ]; check "no typing into a lock screen that is not in front" $? "$(cat "$W/phone.log")"
wcheck "...and it is no PIN failure: the PIN stays set" 3 'L["devices"][0]["pin"]=="set"'
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
wset keyring.locked true
: > "$W/stub.log"
urun unlock kdc:abc123; rccheck "unlock with the keyring locked exits 3" 3
ocheck "...says so, and where it opens" 'J["reason"]=="The keyring is locked" and "password at the lock screen" in J["hint"]'
! grep -q "secret-tool" "$W/stub.log" && [ "$(texts)" = 0 ]; check "...nothing was looked up in the keyring and nothing typed" $? "$(cat "$W/stub.log")"
wset keyring.locked false
phone_set '{"locked": true, "pin": "999999", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
urun unlock kdc:abc123; rccheck "a wrong PIN: unlock exits 1" 1
ocheck "...says the PIN did not unlock, and what to do" 'J["reason"]=="The PIN did not unlock the phone" and J["hint"]=="Set it again on the Details page"'
wcheck "...the device now says pin failed, and unlock is not offered" 4 'L["devices"][0]["pin"]=="failed" and L["devices"][0]["can"]["unlock"]=={"ok":False,"why":"The PIN failed last time","hint":"Set it again on the Details page","via":""}'
urun unlock kdc:abc123; rccheck "a second unlock is refused (3)" 3
[ "$(texts)" = 1 ]; check "a PIN that failed is never typed again (one text in all)" $? "$(cat "$W/phone.log")"
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
printf '%s\n' "$PIN" | "$TOOL" pin kdc:abc123 set > /dev/null 2>&1
wcheck "pin set again clears the failure" 4 'L["devices"][0]["pin"]=="set" and L["devices"][0]["can"]["unlock"]["ok"]'
# one unlock at a time: a held lock file refuses the second
exec 8> "$W/state/unlock.lock"; flock -n 8
urun unlock kdc:abc123; rccheck "an unlock while another runs is refused (4)" 4
ocheck "...says so" 'J["reason"]=="Already unlocking"'
flock -u 8; exec 8>&-
[ "$(texts)" = 0 ]; check "...and typed nothing" $?
urun unlock kdc:abc123; rccheck "(the right PIN again) unlock exits 0" 0
# castprep --unlock: the unlock before the cast's answer, one at a time (the PIN is set and right; the phone asleep and locked)
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
urun castprep kdc:abc123; rccheck "castprep without --unlock exits 0" 0
ocheck "...no unlock field" '"unlock" not in J and J["serial"]'
[ "$(texts)" = 0 ]; check "...and nothing was typed" $?
ocheck "castprep without --record names no recording" '"record" not in J'
rm -rf "$W/vid"
urun castprep kdc:abc123 --record; rccheck "castprep --record exits 0" 0
ocheck "castprep --record answers the file the cast records into: mirror.recordDir, made, phone-<stamp>.mp4 (argv.record_name)" \
    '__import__("re").fullmatch(__import__("re").escape("'"$W"'/vid/") + r"phone-\d{8}-\d{6}\.mp4", J.get("record", "")) and __import__("os").path.isdir("'"$W"'/vid") and not __import__("os").path.exists(J["record"]) and J["serial"]'
[ "$(texts)" = 0 ]; check "...and typed nothing (--record alone never unlocks)" $?
urun castprep kdc:abc123 --unlock; rccheck "castprep --unlock exits 0" 0
ocheck "castprep --unlock unlocks the phone before it answers" 'J["unlock"]=={"ok":True,"already":False,"why":""} and J["serial"] and J["via"]=="tcp" and J["maxSize"]==1600'
[ "$(texts)" = 1 ]; check "...the PIN was typed once" $? "$(cat "$W/phone.log")"
urun castprep kdc:abc123 --unlock
ocheck "castprep --unlock on an unlocked phone says already" 'J["unlock"]=={"ok":True,"already":True,"why":""}'
[ "$(texts)" = 1 ]; check "...and typed nothing more" $?
# a running unlock is waited for (the one that ran has unlocked the phone: nothing is typed twice)
( exec 9> "$W/state/unlock.lock"; flock -n 9; sleep 2 ) &
HOLD=$!
sleep 0.4
t0=$(date +%s.%N); urun castprep kdc:abc123 --unlock; t1=$(date +%s.%N)
wait "$HOLD"
python3 -c "import sys; sys.exit(0 if 1.2 <= float('$t1') - float('$t0') <= 4.5 else 1)"; check "castprep waits for a running unlock to finish" $? "$(python3 -c "print($t1 - $t0)") $OUT"
ocheck "...then finds the phone unlocked" 'J["unlock"]=={"ok":True,"already":True,"why":""}'
[ "$(texts)" = 1 ]; check "...and typed nothing (never twice)" $?
# one that outlasts the wait is skipped, castprep goes on
phone_set '{"locked": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
( exec 9> "$W/state/unlock.lock"; flock -n 9; sleep 6.5 ) &
HOLD=$!
sleep 0.4
t0=$(date +%s.%N); urun castprep kdc:abc123 --unlock; t1=$(date +%s.%N)
rccheck "castprep with an unlock that never ends exits 0" 0
python3 -c "import sys; sys.exit(0 if 4.4 <= float('$t1') - float('$t0') <= 6.3 else 1)"; check "...after about 5 s" $? "$(python3 -c "print($t1 - $t0)")"
ocheck "...says the phone is being unlocked, and answers the transport" 'J["unlock"]=={"ok":False,"already":False,"why":"Already unlocking"} and J["serial"]'
wait "$HOLD"
[ "$(texts)" = 0 ]; check "...and typed nothing" $? "$(cat "$W/phone.log")"
# a failed unlock never fails castprep, and a PIN that failed is not offered again
phone_set '{"locked": true, "pin": "999999", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
urun castprep kdc:abc123 --unlock; rccheck "a failed unlock never fails castprep (exit 0)" 0
ocheck "...it tells why" 'J["unlock"]=={"ok":False,"already":False,"why":"The PIN did not unlock the phone"} and J["serial"] and J["via"]'
urun castprep kdc:abc123 --unlock
ocheck "castprep --unlock with a PIN that failed says nothing of an unlock" '"unlock" not in J and J["serial"]'
[ "$(texts)" = 1 ]; check "...and typed nothing more (a PIN that failed is never typed again)" $? "$(cat "$W/phone.log")"
printf '%s\n' "$PIN" | "$TOOL" pin kdc:abc123 set > /dev/null 2>&1
# THE HOLD: a Mirror's castprep --hold records the phone's own screen timeout ONCE and raises it; castend puts it back (only if it still reads our
# value) and, with --sleep, darkens an awake phone; castend --all puts back what a crash left. (scrcpy's stay_awake left the user's phone on.)
setting() { python3 -c "import json;print(json.load(open('$W/world.json'))['adb']['settings']['system/screen_off_timeout'])"; }
recorded() { python3 -c "import json,sys;h=json.load(open('$W/state/hold.json'));print(h.get('kdc:abc123',{}).get('was','none'))" 2> /dev/null || echo none; }
wset adb.settings '{"system/screen_off_timeout": "45000"}'
phone_set '{"locked": false, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
urun castprep kdc:abc123 --hold; rccheck "castprep --hold exits 0" 0
ocheck "castprep --hold holds the screen and says the phone was dark when the cast began" 'J["held"]==True and J["asleep"]==True'
[ "$(setting)" = 1800000 ] && [ "$(recorded)" = 45000 ]; check "...the phone's timeout is raised to 30 min and its own 45 s recorded on this computer" $? "$(setting) $(recorded)"
urun castprep kdc:abc123 --hold
[ "$(recorded)" = 45000 ]; check "a reconnect never records the raised value as the phone's own" $? "$(recorded)"
urun castend kdc:abc123; rccheck "castend exits 0" 0
[ "$(setting)" = 45000 ] && [ "$(recorded)" = none ]; check "castend puts the phone's own timeout back and forgets the record" $? "$(setting) $(recorded)"
! grep -q '^key KEYCODE_SLEEP' "$W/phone.log"; check "...and without --sleep it darkens nothing" $?
phone_set '{"locked": false, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": true, "bouncer": false}'
urun castprep kdc:abc123 --hold; ocheck "castprep on a lit phone says it was not dark" 'J["asleep"]==False and J["held"]==True'
urun castend kdc:abc123 --sleep; ocheck "castend --sleep puts an awake phone to sleep" 'J["slept"]==True'
grep -q '^key KEYCODE_SLEEP' "$W/phone.log" && run lockstate kdc:abc123 && python3 "$LIB" ev 'J["awake"]==False' <<< "$OUT"; check "...by KEYCODE_SLEEP: it is dark now" $? "$(cat "$W/phone.log")"
urun castend kdc:abc123 --sleep; ocheck "...and leaves a dark one alone" 'J["slept"]==False'
[ "$(grep -c '^key KEYCODE_SLEEP' "$W/phone.log")" = 1 ]; check "...(one KEYCODE_SLEEP in all)" $?
urun castprep kdc:abc123 --hold
wset adb.settings '{"system/screen_off_timeout": "120000"}'
urun castend kdc:abc123
[ "$(setting)" = 120000 ] && [ "$(recorded)" = none ]; check "a timeout the user changed during the cast is theirs: castend leaves it and forgets the record" $? "$(setting) $(recorded)"
urun castprep kdc:abc123 --hold
urun castprep kdc:abc123; ocheck "castprep without --hold (a Desktop) gives a hold back" 'J["held"]==False'
[ "$(setting)" = 120000 ] && [ "$(recorded)" = none ]; check "...the phone's own timeout is back" $? "$(setting) $(recorded)"
urun castprep kdc:abc123 --hold
urun castend --all; rccheck "castend --all exits 0" 0
ocheck "castend --all (the shell's start) puts back the holds a crash left" 'J["released"]==["kdc:abc123"]'
[ "$(setting)" = 120000 ] && [ "$(recorded)" = none ]; check "...the phone's own timeout is back after a crash" $? "$(setting) $(recorded)"
# bridge.jsonc cast.holdMin: how long the hold keeps the screen on (5 min here)
sed -i 's/^{ "adb"/{ "cast": { "holdMin": 5 }, "adb"/' "$W/cfg/bridge.jsonc"
urun castprep kdc:abc123 --hold
[ "$(setting)" = 300000 ] && [ "$(recorded)" = 120000 ]; check "bridge.jsonc cast.holdMin 5: the hold raises the timeout to 5 min" $? "$(setting) $(recorded)"
urun castend kdc:abc123
[ "$(setting)" = 120000 ] && [ "$(recorded)" = none ]; check "...and castend puts the phone's own back" $? "$(setting) $(recorded)"
sed -i 's/^{ "cast": { "holdMin": 5 }, "adb"/{ "adb"/' "$W/cfg/bridge.jsonc"
# a trusted phone (Smart Lock): unlocked by trust, its swipe-only lock screen still shows -- woken and dismissed, no PIN, no keyring
phone_set '{"locked": false, "trustedKeyguard": true, "pin": "'$PIN'", "autoConfirm": true, "keyguardFocus": true, "awake": false, "bouncer": false}'
run lockstate kdc:abc123; ocheck "(a trusted phone: not locked, the lock screen still showing)" 'J["locked"]==False and J["keyguard"]==True and J["focus"]=="keyguard"'
wset keyring.locked true
: > "$W/stub.log"
urun unlock kdc:abc123 --auto; rccheck "unlock of a trust-unlocked phone whose lock screen still shows exits 0" 0
ocheck "a trusted lock screen is dismissed without the PIN" 'J=={"ok":True,"unlocked":True,"dismissed":True}'
grep -q '^key KEYCODE_WAKEUP' "$W/phone.log" && grep -q '^dismiss-keyguard' "$W/phone.log"; check "...by waking the phone and wm dismiss-keyguard" $? "$(cat "$W/phone.log")"
[ "$(texts)" = 0 ] && ! grep -q "secret-tool" "$W/stub.log"; check "...with no PIN typed and no keyring asked (it was locked all along)" $? "$(cat "$W/phone.log")"
run lockstate kdc:abc123; ocheck "...and the lock screen is gone" 'J["keyguard"]==False and J["locked"]==False'
wset keyring.locked false
urun unlock kdc:abc123 --auto; ocheck "(and an unlocked phone with no lock screen is still already)" 'J=={"ok":True,"unlocked":True,"already":True}'
printf 'zz\n' | "$TOOL" pin kdc:abc123 forget > /dev/null 2>&1; [ $? = 0 ]; check "pin forget exits 0" $?
[ "$(python3 -c "import json;print(len(json.load(open('$W/secrets.json'))))")" = 0 ]; check "...and the keyring holds nothing" $?
wcheck "...the device says pin none again" 4 'L["devices"][0]["pin"]=="none" and L["devices"][0]["can"]["unlock"]["why"]=="No PIN kept"'
# the PIN reaches the phone's stdin and nothing else
leak=""
for f in "$W/stub.log" "$W/kdc.log" "$W/unlock-out.log" "$W/watch.out" "$W/pin.out" "$W/pin.err" "$W/tool.err"; do grep -qF -- "$PIN" "$f" 2> /dev/null && leak="$leak $f"; done
grep -rqF -- "$PIN" "$W/state-cache" "$W/state" "$W/rt" 2> /dev/null && leak="$leak state/cache/runtime"
[ -z "$leak" ]; check "the PIN is in no argv, trace, state file, runtime file, watch line, answer or stderr" $? "found in:$leak"
grep -qF -- "$PIN" "$W/stub.log"; [ $? -ne 0 ]; check "the PIN is in no argv" $? "$(grep -F -- "$PIN" "$W/stub.log" | head -2)"

run facts kdc:abc123; rccheck "facts exits 0" 0
ocheck "...model, Android, storage, battery health and temperature" 'J["facts"]["model"]=="NX789J" and J["facts"]["android"]=="15" and J["facts"]["storageTotal"]>0 and J["facts"]["batteryHealth"]=="good" and J["facts"]["batteryTempC"]==28.7 and J["facts"]["at"]'
wcheck "...stored for the watch line" 4 'L["devices"][0]["facts"] and L["devices"][0]["facts"]["model"]=="NX789J"'
# the USB functions: what the phone switches to at every unlock (world adb.usb), and the way to calm it
wset adb.usb '{"unlocked": "MTP", "functions": "mtp,adb"}'
run facts kdc:abc123; ocheck "facts: the phone's File transfer at unlock reads mtp" 'J["facts"]["usbUnlocked"]=="mtp"'
run usbcalm kdc:abc123 on; rccheck "usbcalm on exits 0" 0
ocheck "...reads the phone back: mtp" 'J=={"ok":True,"usbUnlocked":"mtp"}'
logged "$W/stub.log" "shell svc usb setScreenUnlockedFunctions mtp"; check "...svc usb setScreenUnlockedFunctions mtp" $?
wcheck "usbcalm keeps the choice in the device's prefs: on" 4 'L["devices"][0]["prefs"]["usbUnlockMtp"]==True'
: > "$W/stub.log"
run usbcalm kdc:abc123; rccheck "usbcalm (off is the default) exits 0" 0
ocheck "...reads the phone back: none" 'J=={"ok":True,"usbUnlocked":"none"}'
grep -qxF "adb -s 192.168.0.240:5555 shell svc usb setScreenUnlockedFunctions" "$W/stub.log"; check "...svc usb setScreenUnlockedFunctions with NO function" $? "$(cat "$W/stub.log")"
wcheck "...and the choice is off in the prefs" 4 'L["devices"][0]["prefs"]["usbUnlockMtp"]==False'
[ "$(python3 "$STUBS/world.py" "$W/world.json" get adb.usb.unlocked)" = '""' ]; check "...the phone's world has no unlocked function now" $?
run facts kdc:abc123; ocheck "facts: with no function it reads none" 'J["facts"]["usbUnlocked"]=="none"'
wcheck "...and the watch line carries it" 4 'L["devices"][0]["facts"]["usbUnlocked"]=="none"'
run usbcalm kdc:abc123 maybe; rccheck "usbcalm with a word that is not off or on is a usage error (2)" 2
wset adb.usb '{}'
run usbcalm kdc:abc123 off; rccheck "usbcalm on a phone that has none exits 0 and says none" 0
wset adb.devices '[]'
wset kdc.devices.abc123.reachable false
run usbcalm kdc:abc123 off; rccheck "usbcalm with no way to the phone is refused (3)" 3
wset kdc.devices.abc123.reachable true
run arm kdc:abc123; rccheck "arm with no cable exits 3 (not available)" 3
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wset adb.devices '["RZ8N30ABCDE\tdevice usb:1-4 product:NX789J model:NX789J device:NX789J transport_id:1"]'
sleep 0.4
# a phone not armed yet (Keep wireless ready is on by default: a plug-in above may have armed it already, and then `arm` rightly
# does nothing)
wset adb.armed '{}'
run arm kdc:abc123; rccheck "arm over the cable exits 0" 0
logged "$W/stub.log" "adb -s RZ8N30ABCDE tcpip 5555"; check "...adb tcpip with the configured port" $?
run disarm kdc:abc123; rccheck "disarm exits 0" 0
logged "$W/stub.log" "adb -s RZ8N30ABCDE usb"; check "...adb usb" $?

# Keep wireless ready: a plug-in arms the phone by itself
run set kdc:abc123 keepWireless true
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
wcheck "(unplugged for the plug-in check)" 4 'L["devices"][0]["usb"] is None'
: > "$W/stub.log"
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
for _ in $(seq 60); do logged "$W/stub.log" "adb -s RZ8N30ABCDE tcpip 5555" && break; sleep 0.25; done
logged "$W/stub.log" "adb -s RZ8N30ABCDE tcpip 5555"; check "Keep wireless ready arms the phone at a plug-in" $? "$(cat "$W/stub.log")"
# `adb tcpip` restarts adbd and the phone re-enumerates on the bus, as the real one does: the watcher sees a NEW plug-in. It must
# find the phone armed and leave it alone, or each arming makes the next (the user's phone, 2026-11-19: 166 replugs in 97 min).
for round in 1 2 3; do
    python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4; sleep 0.6
    python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp; sleep 1.2
done
sleep 2
n=$(grep -c "adb -s RZ8N30ABCDE tcpip 5555" "$W/stub.log"); [ "$n" = 1 ]
check "the re-enumeration an arming causes arms nothing (one tcpip after three replugs: $n)" $? "$(grep tcpip "$W/stub.log")"
run set kdc:abc123 keepWireless false

# a phone whose three names differ (the user's, 2026-11-18: KDE Connect "REDMAGIC 10 Pro", adb "NX789J", USB "REDMAGIC 10S Pro"):
# the watcher asks it over the cable for its addresses, and the one KDE Connect reaches it on joins them; a computer is left out
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-4
wset adb.devices '[]'
wset kdc.devices.ph2 '{"name": "Kitchen phone", "type": "phone", "reachable": true, "paired": true, "pairState": 3, "addresses": ["192.168.0.77"], "links": ["LAN"], "plugins": ["battery", "share"], "verificationKey": "CC33DD44"}'
wset kdc.devices.pc1 '{"name": "BEAST", "type": "desktop", "reachable": true, "paired": true, "pairState": 3, "addresses": ["192.168.0.90"], "links": ["LAN"], "plugins": ["battery", "share"], "verificationKey": "EE55FF66"}'
wset adb.ident '{"PN9SERIAL": {"addresses": ["10.9.9.9", "192.168.0.77"], "name": "Kitchen phone"}}'
wcheck "a computer KDE Connect knows is not a device" 4 'any(d["key"]=="kdc:ph2" for d in L["devices"]) and not any(d["key"]=="kdc:pc1" for d in L["devices"])'
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-5 18d1 4ee7 PN9SERIAL "Phone Nine" adb mtp
wset adb.devices '["PN9SERIAL\tdevice usb:1-5 product:PN9-EEA model:PN9 device:PN9 transport_id:3"]'
wcheck "a phone named three ways is ONE device once it says its address over the cable" 6 '(lambda d: d is not None and d["usb"] and d["usb"]["serial"]=="PN9SERIAL" and d["name"]=="Kitchen phone" and d["link"]=="both")(next((x for x in L["devices"] if x["key"]=="kdc:ph2"), None)) and not any(x["key"]=="adb:PN9SERIAL" for x in L["devices"])'
for _ in $(seq 20); do grep -q '"ph2": "PN9SERIAL"' "$W/state/state.json" && break; sleep 0.2; done
grep -q '"ph2": "PN9SERIAL"' "$W/state/state.json"; check "...and the link is stored, never the address" $? "$(head -c 300 "$W/state/state.json")"
grep -q '"kind":"ident","serial":"PN9SERIAL"' "$W/state-cache/trace.jsonl"; check "...the ask is in the trace" $?
python3 "$STUBS/make_sysfs.py" "$W/sys" remove 1-5
wset adb.devices '[]'
wset kdc.devices.ph2.reachable false
wset kdc.devices.pc1.reachable false
# the world as this scenario found it: the first phone back on the cable (the fault check below needs a link to write)
python3 "$STUBS/make_sysfs.py" "$W/sys" add 1-4 19d2 1234 RZ8N30ABCDE "REDMAGIC 10S Pro" adb mtp
wset adb.devices '["RZ8N30ABCDE\tdevice usb:1-4 product:NX789J model:NX789J device:NX789J transport_id:1"]'
wcheck "(the first phone is back on the cable)" 4 '(lambda d: d is not None and d["usb"] is not None)(next((x for x in L["devices"] if x["key"]=="kdc:abc123"), None))'

# the trace: what a later look at a real run reads (in the cache beside the state, never in it)
grep -q '"kind":"call","cmd":"mount"' "$W/state-cache/trace.jsonl" 2> /dev/null && grep -q '"kind":"watch"' "$W/state-cache/trace.jsonl" \
    && grep -q '"kind":"exec"' "$W/state-cache/trace.jsonl"
check "the trace holds the one-shots, the watch lines and the commands run" $? "$(ls "$W/state-cache" 2>&1 | head -3)"
ls "$W/state-cache/jobs/"*-s-*.log > /dev/null 2>&1 && grep -q '^\$ adb' "$W"/state-cache/jobs/*-s-*.log
check "a job's whole output is kept in the cache" $? "$(ls "$W/state-cache/jobs" 2>&1 | head -3)"

# no address ever reaches a file
grep -rqE '192\.168\.|\._adb-tls' "$W/state" 2> /dev/null; [ $? -ne 0 ]; check "no address is ever written to the state file" $? "$(grep -rE '192\.168\.|_adb-tls' "$W/state" | head -3)"
python3 - "$W/state/state.json" << 'PY'
import json, os, stat, sys
p = sys.argv[1]
d = os.path.dirname(p)
ok = stat.S_IMODE(os.stat(p).st_mode) == 0o600 and stat.S_IMODE(os.stat(d).st_mode) == 0o700 and stat.S_IMODE(os.stat(os.path.dirname(d) + "/rt").st_mode) == 0o700
s = json.load(open(p))
sys.exit(0 if ok and set(s) >= {"links", "prefs", "lastSeen", "current"} else 1)
PY
check "the state file is 0600 in a 0700 dir, runtime dir 0700, with the contract's keys" $?

# the adb server is stopped after idleKillS (the config is read hot), only because the tool started it
sed -i 's/"idleKillS": 60/"idleKillS": 5/' "$W/cfg/bridge.jsonc"
for _ in $(seq 100); do logged "$W/stub.log" "adb kill-server" && break; sleep 0.25; done
logged "$W/stub.log" "adb kill-server"; check "the adb server the tool started is stopped after adb.idleKillS" $?
[ ! -e "$W/rt/adb-started" ]; check "...and its marker is gone" $?
python3 "$STUBS/fake_adb_server.py" "$PORT" > "$W/adb2.out" 2>&1 &
for _ in $(seq 60); do grep -q "ready" "$W/adb2.out" 2> /dev/null && break; sleep 0.05; done
: > "$W/stub.log"
run facts kdc:abc123; rccheck "(a server somebody else started) facts exits 0" 0
[ ! -e "$W/rt/adb-started" ]; check "a server the tool did not start is not marked as ours" $?
sleep 7
! logged "$W/stub.log" "adb kill-server"; check "...and is left alone after idleKillS" $? "$(cat "$W/stub.log")"

# KDE Connect going away and back
kill "$KPID" 2> /dev/null; wait "$KPID" 2> /dev/null
wcheck "the daemon leaving the bus is env.kdeconnect = down (and nothing activates it)" 5 'L["env"]["kdeconnect"]=="down"'
python3 "$STUBS/fake_kdeconnectd.py" > "$W/kdc2.out" 2>&1 &
KPID=$!
wcheck "...and coming back is running with the device again" 8 'L["env"]["kdeconnect"]=="running" and any(d["key"]=="kdc:abc123" and d["kdc"] is not None for d in L["devices"])'

# ---- the seam: the service's own reader on the tool's line, and the service's own argv through the tool ----
# modules/bridge/data/BridgeModel.js is what BridgeService parses a line with and builds every one-shot's argv with; its
# probe runs it against a stub tool, this one runs the real tool against the fakes. Here the two halves meet: a line the
# service refuses, an argv the tool calls a usage error, or an answer that is not one JSON object would pass both.
MODEL=$TREE/modules/bridge/data/BridgeModel.js
[ -f "$MODEL" ] || MODEL=$ROOT/modules/bridge/data/BridgeModel.js
SEAM=$ROOT/tools/dev/bridge_seam.js
run state
seen=$(printf '%s\n' "$OUT" | node "$SEAM" "$MODEL" line 2>&1); check "(seam) the service's parser takes the tool's line whole" $? "$seen"
tail -1 "$W/watch.out" | cut -f2- | node "$SEAM" "$MODEL" line > "$W/seam.out" 2>&1; check "(seam) ...and the watcher's latest line" $? "$(cat "$W/seam.out")"
seam_bad=""
while IFS= read -r row; do
    name=$(printf '%s' "$row" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    mapfile -t av < <(printf '%s' "$row" | python3 -c 'import json,sys; [print(a) for a in (json.load(sys.stdin)["argv"] or [])]')
    if [ "${#av[@]}" -eq 0 ]; then seam_bad="$seam_bad $name(no-argv)"; continue; fi
    run "${av[@]}"
    [ "$RC" = 2 ] && seam_bad="$seam_bad $name(usage:$(head -c 80 "$W/tool.err" | tr '\n' ' '))"
    printf '%s\n' "$OUT" | node "$SEAM" "$MODEL" answer > "$W/seam.out" 2>&1 || seam_bad="$seam_bad $name($(cat "$W/seam.out"))"
    # a mirror the stub accepted is a job: end it, so the next ask is not refused as "already mirroring"
    jid=$(printf '%s' "$OUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("job") or "")
except Exception: print("")')
    [ -n "$jid" ] && { "$TOOL" stop "$jid" > /dev/null 2>&1; "$TOOL" ack "$jid" > /dev/null 2>&1; }
done < <(node "$SEAM" "$MODEL" argv kdc:abc123)
[ -z "$seam_bad" ]; check "(seam) every argv the service builds is a call the tool knows, answered by one JSON object" $? "$seam_bad"
run shot kdc:abc123; printf '%s\n' "$OUT" | node "$SEAM" "$MODEL" answer > "$W/seam.out" 2>&1; check "(seam) a shot's answer is one object with ok" $? "$(cat "$W/seam.out") $OUT"

# a fault: one error line, a non-zero exit
kill "$WPID" 2> /dev/null; wait "$WPID" 2> /dev/null
mkdir -p "$W/bad/state.json"
LARES_BRIDGE_STATE=$W/bad "$TOOL" watch > "$W/fault.out" 2> "$W/fault.err" &
FPID=$!
wait "$FPID"; FRC=$?
[ "$FRC" -ne 0 ] && tail -1 "$W/fault.out" | python3 "$LIB" ev 'J["v"]==1 and "error" in J'; check "a fault prints {\"v\":1,\"error\":...} and exits non-zero" $? "exit $FRC: $(tail -c 300 "$W/fault.out")"

echo
echo "$NAME: $PASSES ok, $FAILS failed"
[ "$FAILS" -eq 0 ] && echo "$NAME RESULT PASS" || echo "$NAME RESULT FAIL ($FAILS)"
