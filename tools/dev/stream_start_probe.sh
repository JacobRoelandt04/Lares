#!/usr/bin/env bash
# stream_start_probe.sh -- a SupervisedStream (modules/common/components) whose `enabled` or `command` changes while the config is still loading:
# Quickshell only RECORDS a start asked for then and makes it after the load, so a stream switched off in that window must take its start back
# (2026-11-22, the desktop: osd.jsonc "kbd": { "device": "" } and the laptop's LED watcher ran for ever). tools/dev/qml/stream_start_probe.qml,
# offscreen, in a sandbox copy; the children are `sh` and a stub, nothing of the machine is touched.
#
#   tools/dev/stream_start_probe.sh               STREAM_START RESULT PASS | FAIL
#   ARM=norecall tools/dev/stream_start_probe.sh  the recorded start is left standing: "switched off while the config loads" and "no helper" red
#   ARM=nodevice tools/dev/stream_start_probe.sh  the keyboard light's watcher does not ask whether there is a device: "no helper" red
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-ssp}"
D="$(mktemp -d "${SCRATCH:-/tmp}/ssp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
printf '#!/bin/sh\necho helper >> "%s/ran"\nexec sleep 60\n' "$D" > "$D/python-stub"
chmod +x "$D/python-stub"
: > "$D/ran"
ARMCMD="" NEEDLE=""
arm() {   # arm <file> <old> <new>
    printf '%s' "$2" > "$D/arm.from"; printf '%s' "$3" > "$D/arm.to"
    ARMCMD="python3 -c 'import sys; p=sys.argv[1]; a=open(sys.argv[2]).read(); b=open(sys.argv[3]).read(); s=open(p).read(); sys.exit(\"ARM anchor gone\") if s.count(a)!=1 else open(p,\"w\").write(s.replace(a,b))' $1 $D/arm.from $D/arm.to; "
}
case "${ARM:-}" in
    "") ;;
    norecall) arm modules/common/components/SupervisedStream.qml '            root._proc.running = false;     // a start Quickshell has only recorded' '            // ' ; NEEDLE="switched off while the config loads" ;;
    nodevice) arm modules/osd/data/sources/KbdLightSource.qml 'enabled: root.live && root.device !== ""' 'enabled: root.live'; NEEDLE="no keyboard light: no helper" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"$ARMCMD"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SSP_DIR='"$D"' XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache timeout 60 quickshell -p tools/dev/qml/stream_start_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o -E 'SSP (ok|FAIL) .*'
rl_clean "$D/log" | grep -a -E 'WARN|ERROR' | rl_platform_noise | grep -a -v -i 'hyprland' | head -5
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'SSP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; cp "$D/log" "${TMPDIR:-/tmp}/stream_start_probe.log"; echo "STREAM_START RESULT FAIL (no result: ${TMPDIR:-/tmp}/stream_start_probe.log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a 'SSP FAIL' | grep -a -q -F -- "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see it"; exit 1
fi
res=$(rl_result STREAM_START "$D/log" 'SSP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^SSP RESULT/STREAM_START RESULT/'
exit $rc
