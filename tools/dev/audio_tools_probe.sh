#!/usr/bin/env bash
# A row's tools in the audio popup (test tone, mute, lock channels, the advanced chevron) are ALWAYS on screen, with no pointer
# (tools/dev/qml/audio_tools_probe.qml: the real popup on the mock sound system, offscreen, in a sandbox copy).
#
#   tools/dev/audio_tools_probe.sh
#   ARM=hoverhide   the tools back behind the row's hover (present = _toolsF): the opacity check must fail
# Last line: AUDIO_TOOLS RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen ARM="${ARM:-}" tools/dev/audio_tools_probe.sh
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/audiotools.XXXXXX")
LOGKEEP="${SCRATCH:-${TMPDIR:-/tmp}}/audio_tools.log"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg/theme" "$WORK/state"
printf '{"theme":"eva","mode":"light"}\n' > "$WORK/cfg/theme/state.json"
case "${ARM:-}" in
hoverhide)
    python3 - <<'PY' || { echo "AUDIO_TOOLS RESULT FAIL (ARM hoverhide: anchor gone)"; exit 1; }
p = "modules/audio/AudioRow.qml"
s = open(p).read()
a = '                    glyph: !self.row ? "" : self.isDevice && self.row.kind === "source"'
assert s.count(a) == 1
s = s.replace(a, '                    opacity: self.hovered ? 1 : 0\n' + a)
open(p, "w").write(s)
PY
    ;;
esac
log="$WORK/run.log"
XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" timeout -k 5 90 quickshell -p tools/dev/qml/audio_tools_probe.qml > "$log" 2>&1
# a run that fails keeps its log where the verdict names it (the work dir goes on exit)
if ! rl_has "$log" 'AUDIOTOOLS RESULT'; then
    cp "$log" "$LOGKEEP"
    if [ -n "${ARM:-}" ]; then echo "ARM $ARM: the armed copy did not load -- it proves nothing ($LOGKEEP)"; exit 1; fi
    rl_noresult AUDIO_TOOLS "$LOGKEEP"; exit 1
fi
rl_clean "$log" | grep "AUDIOTOOLS" | sed 's/^.*AUDIOTOOLS/AUDIOTOOLS/'
rl_result AUDIOTOOLS "$log" > /dev/null
rc=$?
if [ $rc -eq 0 ]; then echo "AUDIO_TOOLS RESULT PASS"; else cp "$log" "$LOGKEEP"; echo "AUDIO_TOOLS RESULT FAIL (log: $LOGKEEP)"; exit 1; fi
