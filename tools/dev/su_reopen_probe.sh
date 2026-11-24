#!/usr/bin/env bash
# su_reopen_probe.sh -- the system update popup reopened MID-RUN seats its ball: no flight from notch 0, no spark burst.
#
#   tools/dev/su_reopen_probe.sh               SUREOPEN RESULT PASS | FAIL (...)
#   ARM=noseat tools/dev/su_reopen_probe.sh    the content does not seat its ball (the old behaviour): the flight and its sparks must show
#
# A real captured run (PROBE_LOG, default: the newest full run under ~/.local/share/system-update-logs/runs) is replayed through the
# backend + parser; the popup is switched off and on again mid-download, mid-install and mid-hooks (tools/dev/qml/su_reopen_probe.qml).
# Runs in the sandbox, offscreen, rhi (the sparks are a ParticleSystem; the software scenegraph draws none).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/sure.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
LOG="${PROBE_LOG:-$HOME/.local/share/system-update-logs/runs/2026-11-05_09-13-10/transcript.log}"
[ -f "$LOG" ] || { echo "SUREOPEN RESULT FAIL (no log: $LOG)"; exit 1; }
ARMCMD=""; EXPECT=seat
case "${ARM:-}" in
    "") ;;
    noseat) EXPECT=flight; ARMCMD="sed -i 's|^        phaseRail.seat();|        // armed: not seated|' modules/bar/system_update/components/SystemUpdatePopup.qml; grep -q 'armed: not seated' modules/bar/system_update/components/SystemUpdatePopup.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SU_EXPECT='"$EXPECT"' PROBE_LOG='"$LOG"' RL_DELAY='"${RL_DELAY:-0.004}"' timeout 120 quickshell -p tools/dev/qml/su_reopen_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a '^SURE ' | grep -a -v 'SURE RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q 'SURE FAIL flight seen'; then echo "ARM $ARM: failed as it must (the flight is seen)"; exit 0; fi
    if ! rl_has "$D/log" 'SURE (PASS|FAIL)'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL -- the probe cannot see the flight"; exit 1
fi
res=$(rl_result SUREOPEN "$D/log" 'SURE RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^SURE RESULT/SUREOPEN RESULT/'
exit $rc
