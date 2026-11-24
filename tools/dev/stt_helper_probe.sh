#!/usr/bin/env bash
# stt_helper_probe.sh -- the speech helper's own robustness (round 8): tools/stt/lares_stt.py for real, with its stand-in decoder
# (LARES_STT_STUBS=1) and a fake pw-record that plays a FLEURS clip, against a GPU decoder that raises mid-take, an exception of the
# helper's own and the beat (tools/dev/stt_helper_probe.py has the checks H1-H3). No model, no PipeWire, no desktop, ~1 minute of CPU.
#
#   tools/dev/stt_helper_probe.sh                STTHELPER RESULT PASS | FAIL
#   ARM=<name> tools/dev/stt_helper_probe.sh     one fault in a COPY of tools/stt; the check it names must go red:
#     nofallback    a GPU decode that raises is not recovered (sttlib/devguard.py re-raises)                       -> "SHP FAIL H1"
#     nocrashguard  an exception of the main loop is not caught (the loop dies: no `error`, no `ended`)            -> "SHP FAIL H2"
#     nobeat        the beat thread says nothing                                                                    -> "SHP FAIL H3 beats"
#
# Needs the venv and a FLEURS clip (tools/stt/setup.sh --clips). Reads the models dir only for the VAD. An arm patches the copy.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
PY="${LARES_STT_PYTHON:-$HOME/.local/share/lares/stt/venv/bin/python}"
# THE NAME CHANGE: until `lares migrate-name` has run on this machine the venv, the models and the clips are still under the old name's directories
if [ -z "${LARES_STT_HOME:-}" ] && [ ! -d "$HOME/.cache/lares-stt" ] && [ -d "$HOME/.cache/quickshell-stt" ]; then export LARES_STT_HOME=$HOME/.cache/quickshell-stt; fi
[ -x "$PY" ] || { [ -x "$HOME/.local/share/quickshell/stt/venv/bin/python" ] && PY=$HOME/.local/share/quickshell/stt/venv/bin/python; }
CLIPS="${LARES_STT_HOME:-$HOME/.cache/lares-stt}/clips/en"
D="$(mktemp -d "${SCRATCH:-/tmp}/stthelper.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
[ -x "$PY" ] || { echo "STTHELPER RESULT FAIL (no venv at $PY: run tools/stt/setup.sh)"; exit 1; }
cp -r tools/stt "$D/stt"
NEEDLE=""
arm() {   # arm FILE OLD NEW: OLD (exact text, found exactly once) becomes NEW in the copy
    python3 - "$D/stt/$1" "$2" "$3" <<'PY' || { echo "ARM ${ARM:-}: its anchor is gone -- re-aim it"; exit 1; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
}
case "${ARM:-}" in
    "") ;;
    nofallback)   arm sttlib/devguard.py '            self._fall(e)
        return getattr(self._d, name)(audio, lang)' '            raise
        return getattr(self._d, name)(audio, lang)'
                  NEEDLE='SHP FAIL H1' ;;
    nocrashguard) arm lares_stt.py '        except Exception as e:  # noqa: BLE001
            h.fail(e)' '        except ZeroDivisionError as e:  # noqa: BLE001
            h.fail(e)'
                  NEEDLE='SHP FAIL H2' ;;
    nobeat)       arm lares_stt.py '        emit({"ev": "beat", "take": h.take,' '        _loop["phase"] = "idle"; (lambda *a: None)({"ev": "beat", "take": h.take,'
                  NEEDLE='SHP FAIL H3 beats' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/bin" "$D/pci"
# the clip: the shortest English one, a speaking level, 0.6 s of silence before and 2.5 s after, as raw 16 kHz s16
CL=$(sort -t$'\t' -k2 -n "$CLIPS/refs.tsv" | head -1 | cut -f1)
[ -n "$CL" ] && [ -e "$CLIPS/$CL" ] || { echo "STTHELPER RESULT FAIL (no clip in $CLIPS: run tools/stt/fetch.py clips)"; exit 1; }
"$PY" -I - "$CLIPS/$CL" "$D/clip.raw" <<'PY' || { echo "STTHELPER RESULT FAIL (the clip was not built)"; exit 1; }
import sys
import numpy as np
import soundfile as sf
a, r = sf.read(sys.argv[1], dtype="float32", always_2d=True)
a = a.mean(axis=1)
a = a * (0.5 / float(np.abs(a).max()))
x = np.concatenate([np.zeros(int(0.6 * r), np.float32), a, np.zeros(int(2.5 * r), np.float32)])
open(sys.argv[2], "wb").write((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
PY
# the fake pw-record: the clip at the pace of a microphone, then silence until it is killed
cat > "$D/bin/pw-record" <<'PW'
#!/usr/bin/env python3
import os, sys, time
data = open(os.environ["LARES_FAKE_PW"], "rb").read()
step = 1024                      # 32 ms of 16 kHz s16
t0, i = time.monotonic(), 0
out = sys.stdout.buffer
try:
    while True:
        chunk = data[i: i + step] if i < len(data) else b"\0" * step
        i += step
        out.write(chunk.ljust(step, b"\0"))
        out.flush()
        time.sleep(max(0.0, t0 + (i // step) * 0.032 - time.monotonic()))
except (BrokenPipeError, KeyboardInterrupt):
    pass
PW
chmod +x "$D/bin/pw-record"
SHP_DIR="$D" SHP_PYTHON="$PY" SHP_HELPER="$D/stt/lares_stt.py" timeout -k 5 300 "$PY" -I tools/dev/stt_helper_probe.py > "$D/log" 2>&1
grep -a '^SHP' "$D/log" | cut -c1-420
if [ -n "${ARM:-}" ]; then
    if grep -a -q -F "$NEEDLE" "$D/log"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    grep -a -q 'SHP RESULT' "$D/log" || { KEEP=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result STTHELPER "$D/log" 'SHP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; tail -5 "$D/log"; printf '%s\n' "$res"; exit 1; fi
[ "$rc" -eq 0 ] || { KEEP=1; tail -3 "$D/helper.err" 2> /dev/null; }
printf '%s\n' "$res" | sed 's/^SHP RESULT/STTHELPER RESULT/'
exit $rc
