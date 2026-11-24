#!/usr/bin/env bash
# panorama_common_probe.sh -- the COMMON stream of Panorama: FocusedScreen's `monitors all` read, DrmWatch, DdcClient.
#
#   tools/dev/panorama_common_probe.sh              PANORAMA_COMMON RESULT PASS | FAIL (the three parts, each with its own PC<x> RESULT line)
#   PART=focus|drm|ddc|ddc2 tools/dev/panorama_common_probe.sh   one part
#   ARM=<name> [PART=..] tools/dev/panorama_common_probe.sh   a fault put into the SANDBOX copy; the run must FAIL (exit 0 = it did)
#   ARM=all                                          every ARM; PANORAMA_COMMON ARMS PASS when each one failed
#
#   FOCUS (FocusedScreen against the reader as it stood before, from git: PANORAMA_OLD_REF, default the commit before this stream)
#     focusfires   outputsChanged also fires on a focus move                      -> "outputsChanged silent" FAILS
#     mirrorin     `monitors` lists a mirroring output                            -> "monitors identical" FAILS
#     hopin        the lock's hop and FALLBACK are outputs                        -> "neither the hop nor FALLBACK" FAILS
#     mirrorid     mirrorOf is left as the source's id                            -> "mirrorOf is the SOURCE'S NAME" FAILS
#     noall        the read says `monitors`, not `monitors all`                   -> "the read asks for monitors all" FAILS
#     nobarscreens displayFor answers a screen that has no shell window (bars.outputs)   -> "displayFor: a screen with no shell window" FAILS
#     wsfocused    a workspace event lands on the focused monitor, whatever its home -> "bounce: LOCK-1's workspace never reads" FAILS
#     nodefer      a workspace event is decided at once, not at the end of its turn -> "bounce, a new workspace" FAILS
#   DRM (DrmWatch on a fake /sys and a udevadm stand-in)
#     nvidiaany    any card's HDMI-A counts as the NVIDIA fact                    -> "evdi and the iGPU never count" FAILS
#     eventscan    every udev event is a scan of its own                          -> "a burst is one scan" FAILS
#     nousbfilter  a usb `change` is a scan too                                   -> "usb change is no scan" FAILS
#     alwaysask    systemctl is asked at every scan, dock or not                  -> "systemctl only with a dock" FAILS
#     nomonitor    the monitor is never started                                   -> "ONE monitor, both subsystems" FAILS
#   DDC (DdcClient against a stub ddcutil on PATH-free `program`)
#     nocoalesce   every set goes out                                             -> "coalesced" FAILS
#     nocache      value() asks every time                                        -> "cached" FAILS
#     nobus        a call without --bus N                                         -> "every call names its bus" FAILS
#     slowchecks   the calls run ddcutil's start-up checks (6 s each on NVIDIA HDMI)   -> "every call skips" FAILS
#     evdiddcutil  a DisplayLink output is asked through ddcutil                   -> "read by the direct tool" FAILS
#     evdiblocked  a DisplayLink output takes no DDC (the old rule)                -> "capable on its connector's own bus" FAILS
#
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh). Every quickshell runs offscreen, in the sandbox.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-common}"
OLD_REF="${PANORAMA_OLD_REF:-ad270dcf}"
W="$(mktemp -d "${SCRATCH:-/tmp}/pcom.XXXXXX")"
OLDFILE=modules/common/system/FocusedScreenOld.qml
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"; rm -f "$OLDFILE"' EXIT
PY="$W/arm.py"
cat > "$PY" <<'ARMPY'
import sys
p, a, b = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(p).read()
if s.count(a) != 1:
    print("ARM anchor gone (%d): %r" % (s.count(a), a[:80])); sys.exit(1)
open(p, "w").write(s.replace(a, b))
ARMPY
ARMCMD=""
arm() { printf '%s' "$2" > "$W/arm.from"; printf '%s' "$3" > "$W/arm.to"; ARMCMD="python3 $PY $1 $W/arm.from $W/arm.to"; }
PARTS="${PART:-focus drm ddc ddc2}"
MODES="ok slow noconn nobusmap ignore getfail detectfail scrub"
case "${ARM:-}" in
    "") ;;
    focusfires)  arm modules/common/system/FocusedScreen.qml '        root.stats.published += 1;
        root.changed();' '        root.stats.published += 1;
        root.changed();
        root.outputsChanged();'; PARTS=focus ;;
    mirrorin)    arm modules/common/system/FocusedScreen.qml '            if (m.disabled === true || Out.isMirror(m))' '            if (m.disabled === true)'; PARTS=focus ;;
    hopin)       arm modules/common/system/OutputRecord.js 'var IGNORED = ["LARESLOCK-HOP", "FALLBACK"];' 'var IGNORED = [];'; PARTS=focus ;;
    mirrorid)    arm modules/common/system/OutputRecord.js '        mirrorOf: _sourceName(m.mirrorOf, all),' '        mirrorOf: isMirror(m) ? String(m.mirrorOf) : "",'; PARTS=focus ;;
    noall)       arm modules/common/system/FocusedScreen.qml '"hyprctl -j monitors all; echo' '"hyprctl -j monitors; echo'; PARTS=focus ;;
    nobarscreens) arm modules/common/system/FocusedScreen.qml '        if (!own || own.length === 0 || own.indexOf(at) >= 0)' '        if (true)'; PARTS=focus ;;
    nodefer)     arm modules/common/system/FocusedScreen.qml '            Qt.callLater(root._settleWorkspaces);' '            root._settleWorkspaces();'; PARTS=focus ;;
    wsfocused)   arm modules/common/system/FocusedScreen.qml '            const name = home !== undefined && root._index(home) >= 0 ? home : root._focusName();' '            const name = root._focusName();'; PARTS=focus ;;
    nvidiaany)   arm modules/common/system/DrmRules.js '        if (c.nvidia && c.type === "HDMI-A" && c.status === "connected")' '        if (c.type === "HDMI-A" && c.status === "connected")'; PARTS=drm ;;
    eventscan)   arm modules/common/system/DrmWatch.qml '        debounce.restart();
    }

    function _startMonitor' '        root.rescan();
    }

    function _startMonitor'; PARTS=drm ;;
    nousbfilter) arm modules/common/system/DrmWatch.qml '        if (m[2] === "usb" && m[1] !== "add" && m[1] !== "remove")
            return;
' ''; PARTS=drm ;;
    alwaysask)   arm modules/common/system/DrmWatch.qml '            if (!p.displayLinkUsb) {' '            if (false) {'; PARTS=drm ;;
    nomonitor)   arm modules/common/system/DrmWatch.qml '            mon.enabled = true;' '            void 0;'; PARTS=drm ;;
    nocoalesce)  arm modules/panorama/data/DdcClient.qml '        if (root._setting[connector] === true) {' '        if (false) {'; PARTS=ddc ;;
    nocache)     arm modules/panorama/data/DdcClient.qml '            if (c && Date.now() - c.at < root.cacheMs)' '            if (false)'; PARTS=ddc ;;
    nobus)       arm modules/panorama/data/DdcClient.qml 'String(target), "--bus", String(d.bus)].concat(root.fastArgs)' 'String(target)].concat(root.fastArgs)'; PARTS=ddc ;;
    slowchecks)  arm modules/panorama/data/DdcClient.qml 'property var fastArgs: ["--skip-ddc-checks"]' 'property var fastArgs: []'; PARTS=ddc ;;
    noconnectorline) arm modules/panorama/data/DdcClient.qml 'const res = P.resolveDisplays(list, root.outputs, busMap);' 'const res = { map: {} }; list.forEach(d => { if (d.connector !== "") res.map[d.connector] = d; });'; PARTS=ddc2; MODES=noconn ;;
    noverifyfirst) arm modules/panorama/data/DdcClient.qml '        if (!first)
            argv.push("--noverify");' '        argv.push("--noverify");'; PARTS=ddc2; MODES=ok ;;
    nopending)   arm modules/panorama/data/DdcClient.qml '        return root._goal[connector] !== undefined || (root._delta[connector] || 0) !== 0;' '        return false;'; PARTS=ddc2; MODES=ok ;;
    dropsunknown) arm modules/panorama/data/DdcClient.qml '        root._delta[connector] = (root._delta[connector] || 0) + delta;' '        return false;'; PARTS=ddc2; MODES=slow ;;
    noretrygate) arm modules/panorama/data/DdcClient.qml '        return s !== undefined && s.state === "failing" && Date.now() - s.at < root.retryMs;' '        return false;'; PARTS=ddc2; MODES=ignore ;;
    noscrubrest) arm modules/panorama/data/DdcClient.qml '        root._scrubAt[connector] = Date.now();
        rest.restart();' '        root._dispatch(connector, target);'; PARTS=ddc2; MODES=scrub ;;
    evdiddcutil) arm modules/panorama/data/DdcClient.qml 'return d.direct ? [root.directProgram, "get", String(d.bus)] :' 'return false ? [root.directProgram, "get", String(d.bus)] :'; PARTS=ddc ;;
    evdiblocked) arm modules/panorama/data/DdcClient.qml 'return P.neverDdc(d.connector);' 'return P.neverDdc(d.connector) || d.direct === true;'; PARTS=ddc ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

ENVQ='env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1'
# run_part <name> <qml> <result-prefix> <extra env>
run_part() {
    local name="$1" qml="$2" tag="$3" extra="${4:-}" log="$W/$1.log" run
    run='set -e; '"${PRE:+$PRE; }${ARMCMD:+$ARMCMD; }$ENVQ"' PCOM_FIX='"$PWD/tools/dev/fixtures/panorama"' PCOM_SYS="$PWD/modules/common/system" PCOM_W='"$W/$name"' '"$extra"' timeout 120 quickshell -p tools/dev/qml/'"$qml"
    mkdir -p "$W/$name"
    tools/dev/sandbox.sh bash -c "$run" > "$log" 2>&1
    rl_clean "$log" | grep -a -E "$tag FAIL|WARN" | head -8
    if [ -n "${ARM:-}" ]; then
        if rl_clean "$log" | grep -a -q "$tag FAIL"; then return 0; fi
        rl_has "$log" "$tag RESULT" || { echo "ARM $ARM: the armed copy did not load -- it proves nothing"; rl_clean "$log" | grep -a -E "ERROR|caused by|Failed" | head -4; return 2; }
        return 1
    fi
    local res; res=$(rl_result "$name" "$log" "$tag RESULT .*"); local rc=$?
    printf '%s\n' "$res"
    return $rc
}

# the fake machine of the DRM part: two cards (the NVIDIA one with an HDMI-A and an eDP, the iGPU with an eDP and an HDMI-A that reads connected),
# and the stand-ins udevadm (header, then whatever lands in the feed) and systemctl (logs, says "active")
mk_drm() {
    local d="$W/drm" s="$W/drm/sys/class/drm" c
    mkdir -p "$d/bin" "$s/card0/device" "$s/card1/device" "$d/sys/bus/usb/devices" "$s/card0-HDMI-A-1" "$s/card0-eDP-2" "$s/card1-eDP-1" "$s/card1-HDMI-A-2"
    printf '0x10de\n' > "$s/card0/device/vendor"; ln -s /sys/bus/pci/drivers/nvidia "$s/card0/device/driver"
    printf '0x8086\n' > "$s/card1/device/vendor"; ln -s /sys/bus/pci/drivers/i915 "$s/card1/device/driver"
    for c in card0-HDMI-A-1 card0-eDP-2; do printf 'disconnected\n' > "$s/$c/status"; printf 'disabled\n' > "$s/$c/enabled"; done
    for c in card1-eDP-1 card1-HDMI-A-2; do printf 'connected\n' > "$s/$c/status"; printf 'enabled\n' > "$s/$c/enabled"; done
    : > "$d/feed"
    cat > "$d/bin/udevadm" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/udevadm.log"
printf 'monitor will print the received events for:\nUDEV - the event which udev sends out after rule processing\n\nSUBSYSTEM=drm\n\n'
exec tail -n 0 -F "$d/feed" 2> /dev/null
STUB
    cat > "$d/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$d/systemctl.log"
echo active
STUB
    chmod +x "$d/bin/udevadm" "$d/bin/systemctl"
}

# the DDC part's ddcutil stand-in: logs every argv, detect prints the captured bytes (the laptop's real ones, then a synthetic external set),
# getvcp answers from a value file (bus 7 hangs: the timeout case), setvcp takes 0.4 s and writes the file
mk_ddc() {
    local d="$W/ddc" f="$PWD/tools/dev/fixtures/panorama"
    mkdir -p "$d/bin"
    cat > "$d/bin/ddcutil" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s%3N)" "\$*" >> "$d/ddcutil.log"
bus=""; prev=""
for a in "\$@"; do [ "\$prev" = --bus ] && bus="\$a"; prev="\$a"; done
case "\$1" in
    detect) cat "$f/ddcutil_detect_laptop.txt"; echo; cat "$f/ddcutil_detect_external_synthetic.txt" ;;
    getvcp) [ "\$bus" = 7 ] && exec sleep 30
            printf 'VCP 10 C %s 100\n' "\$(cat "$d/val.\$bus" 2> /dev/null || echo 50)" ;;
    setvcp) sleep 0.4; printf '%s\n' "\$3" > "$d/val.\$bus" ;;
    *) echo "stub: refused \$*" >&2; exit 99 ;;
esac
STUB
    chmod +x "$d/bin/ddcutil"
    # the DisplayLink output: its connector's ddc link names bus 21, and our own tool speaks to it (same log, "direct ...")
    mkdir -p "$d/sys/class/drm/card2-DVI-I-1" "$d/sys/devices/i2c-21"
    ln -sfn ../../../devices/i2c-21 "$d/sys/class/drm/card2-DVI-I-1/ddc"
    echo 40 > "$d/val.21"
    cat > "$d/bin/lares-ddc" <<STUB
#!/usr/bin/env bash
printf '%s direct %s\n' "\$(date +%s%3N)" "\$*" >> "$d/ddcutil.log"
case "\$1" in
    get) printf 'VCP 10 C %s 100\n' "\$(cat "$d/val.\$2")" ;;
    set) printf '%s\n' "\$3" > "$d/val.\$2" ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$d/bin/lares-ddc"
}

# the round-2 DDC part: one stub ddcutil per MODE (slow = 3 s a call, noconn = the NVIDIA detect with no "DRM connector" line, nobusmap = the same
# found by sysfs's bus link, ignore = setvcp acknowledged and ignored, getfail, detectfail = exit 1), getvcp answers `VCP 10 C <v> 255`
mk_ddc2() {
    local m="$1" d="$W/ddc2_$1" f="$PWD/tools/dev/fixtures/panorama"
    mkdir -p "$d/bin" "$d/sys/class/drm/card0-DP-3" "$d/sys/devices/i2c-6"
    ln -s ../../../devices/i2c-6 "$d/sys/class/drm/card0-DP-3/ddc"
    cat > "$d/bin/ddcutil" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s%3N)" "\$*" >> "$d/ddcutil.log"
bus=""; prev=""
for a in "\$@"; do [ "\$prev" = --bus ] && bus="\$a"; prev="\$a"; done
case "\$1" in
    detect) [ "$m" = detectfail ] && { echo "ddcutil: could not open /dev/i2c" >&2; exit 1; }
            case "$m" in noconn|nobusmap) cat "$f/ddcutil_detect_nvidia_noconnector.txt" ;; *) cat "$f/ddcutil_detect_laptop.txt"; echo; cat "$f/ddcutil_detect_external_synthetic.txt" ;; esac ;;
    getvcp) [ "$m" = slow ] && sleep 3
            [ "$m" = getfail ] && { echo "ddcutil: DDC communication failed" >&2; exit 1; }
            printf 'VCP 10 C %s 255\n' "\$(cat "$d/val.\$bus" 2> /dev/null || echo 50)" ;;
    setvcp) if [ "$m" = slow ]; then sleep 3; else sleep 0.2; fi
            [ "$m" = ignore ] && exit 0
            printf '%s\n' "\$3" > "$d/val.\$bus" ;;
    *) echo "stub: refused \$*" >&2; exit 99 ;;
esac
STUB
    chmod +x "$d/bin/ddcutil"
}

fail=0
for p in $PARTS; do
    case "$p" in
        focus)
            git show "$OLD_REF:modules/common/system/FocusedScreen.qml" > "$OLDFILE" 2> /dev/null || { echo "PANORAMA_COMMON RESULT FAIL (no $OLD_REF to read the old reader from)"; exit 1; }
            PRE="echo 'FocusedScreenOld 1.0 FocusedScreenOld.qml' >> modules/common/system/qmldir" run_part focus panorama_common_focus.qml PCF || fail=$?
            ;;
        drm) mk_drm; run_part drm panorama_common_drm.qml PCD || fail=$? ;;
        ddc) mk_ddc; run_part ddc panorama_common_ddc.qml PCC || fail=$? ;;
        ddc2) for m in $MODES; do mk_ddc2 "$m"; run_part "ddc2_$m" panorama_ddc_r2.qml PDR "PDR_W=$W/ddc2_$m PDR_MODE=$m" || fail=$?; done ;;
    esac
done
if [ -n "${ARM:-}" ]; then
    [ "$fail" = 0 ] && { echo "ARM $ARM: failed as it must"; exit 0; }
    echo "ARM $ARM: DID NOT FAIL (or did not load)"; exit 1
fi
[ "$fail" = 0 ] && echo "PANORAMA_COMMON RESULT PASS" || echo "PANORAMA_COMMON RESULT FAIL"
exit "$fail"
