#!/usr/bin/env bash
# stt_bench.sh -- the dictation bench (tools/stt/bench.py): every shortlisted model, one process each, one after the other, on the
# FLEURS clips in the private cache, and the tidy pass on its test sentences. MACHINE-EXCLUSIVE: minutes of full CPU / iGPU / dGPU
# load; run it with the machine otherwise idle.
#
#   tools/dev/stt_bench.sh [OUT_DIR]          the iGPU / CPU rows (MODELS) and the tidy pass on the CPU (TIDY)
#   tools/dev/stt_bench.sh --dgpu [OUT_DIR]   THE NVIDIA CARD (round 4): run it once the GPU mode is Hybrid (or Smart with the helper
#                                             allowed): Parakeet on CUDA (the card's pick for every take and final: Canary's fp16
#                                             export decoded Dutch at 24.5 % there, 2026-11-08) and the tidy pass. Refuses while the card is
#                                             off the bus. Ends with the table to put in research.md section 11.5.
#   MODELS="canary-1b-v2 parakeet-tdt-0.6b-v3@cpu ..." TIDY="gemma-3-1b-it@cpu" CLIPS=30 tools/dev/stt_bench.sh
#        rows: <id>[@igpu|@cpu|@cuda], <live>+<final> (the second pass for every final), <live>+nl:<final> (only Dutch finals);
#        TIDY rows: <tidy id>[@cpu|@cuda]; TIDY="" skips the tidy pass
#
# Needs tools/stt/setup.sh's venv, `fetch.py pick` (the models, their CUDA builds, the tidy model) and `fetch.py clips`. No
# microphone, no PipeWire, no network. Verdict: STT_BENCH RESULT PASS (every row ran and wrote its numbers) | FAIL (<which>).
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
PY="${LARES_STT_PYTHON:-$HOME/.local/share/lares/stt/venv/bin/python}"
# THE NAME CHANGE: until `lares migrate-name` has run on this machine the venv, the models and the clips are still under the old name's directories
if [ -z "${LARES_STT_HOME:-}" ] && [ ! -d "$HOME/.cache/lares-stt" ] && [ -d "$HOME/.cache/quickshell-stt" ]; then export LARES_STT_HOME=$HOME/.cache/quickshell-stt; fi
[ -x "$PY" ] || { [ -x "$HOME/.local/share/quickshell/stt/venv/bin/python" ] && PY=$HOME/.local/share/quickshell/stt/venv/bin/python; }
DGPU=""
[ "${1:-}" = --dgpu ] && { DGPU=1; shift; }
OUT="${1:-${SCRATCH:-/tmp}/stt-bench${DGPU:+-dgpu}}"
if [ -n "$DGPU" ]; then
    MODELS="${MODELS:-parakeet-tdt-0.6b-v3@cuda}"
    TIDY="${TIDY-gemma-3-1b-it@cuda}"
else
    MODELS="${MODELS:-parakeet-tdt-0.6b-v3 parakeet-tdt-0.6b-v3@cpu canary-1b-v2 parakeet-tdt-0.6b-v3+canary-1b-v2}"
    TIDY="${TIDY-gemma-3-1b-it@cpu}"
fi
CLIPS="${CLIPS:-30}"
mkdir -p "$OUT"
[ -x "$PY" ] || { echo "STT_BENCH RESULT FAIL (no venv at $PY: run tools/stt/setup.sh)"; exit 1; }
fact=$(cd /tmp && "$PY" -I -c "
import sys; sys.path.insert(0, '$REPO/tools/stt')
from sttlib import decoders
f = decoders.dgpu_fact(); print(decoders.device_class('auto', f)[0], '|', f.get('pci') or '-', '|', f.get('why') or 'on the bus')" 2> /dev/null)
[ -n "$fact" ] || fact="unknown | - | the venv could not read the card's fact"
if [ -n "$DGPU" ] && [ "${fact%% *}" != cuda ]; then
    echo "STT_BENCH RESULT FAIL (the NVIDIA card is not usable: ${fact##*| }; switch the GPU mode to Hybrid first -- the silicon popup, or \`cardwire set hybrid\`)"
    exit 1
fi
{
    echo "when: $(date -Iseconds)"
    echo "power: $(cat /sys/class/power_supply/A*/online 2> /dev/null | head -1) (1 = on AC)"
    echo "profile: $(cat /sys/firmware/acpi/platform_profile 2> /dev/null)"
    echo "gpu mode: $(cardwire get 2> /dev/null | head -1)"
    echo "take's device class: $fact"
    echo "loadavg before: $(cat /proc/loadavg)"
} > "$OUT/machine.txt"
bad=""
for row in $MODELS; do
    m=${row%@*} dev=igpu
    [ "$m" = "$row" ] || dev=${row#*@}
    echo "== $m ($dev)"
    if ! (cd /tmp && "$PY" -I "$OLDPWD/tools/stt/bench.py" model "$m" --device "$dev" --clips "$CLIPS" --out "$OUT/$row.json" > "$OUT/$row.stdout" 2> "$OUT/$row.log"); then
        bad="$bad $row"; tail -5 "$OUT/$row.log"; continue
    fi
    grep -v '^ ' "$OUT/$row.log" | grep -v 'Warning' | tail -12
done
for row in $TIDY; do
    m=${row%@*} dev=cpu
    [ "$m" = "$row" ] || dev=${row#*@}
    echo "== tidy $m ($dev)"
    if ! (cd /tmp && "$PY" -I "$OLDPWD/tools/stt/bench.py" tidy "$m" --device "$dev" --out "$OUT/tidy-$row.json" > "$OUT/tidy-$row.stdout" 2> "$OUT/tidy-$row.log"); then
        bad="$bad tidy-$row"; tail -5 "$OUT/tidy-$row.log"; continue
    fi
    grep -a "exact" "$OUT/tidy-$row.log" | tail -1
done
echo "loadavg after: $(cat /proc/loadavg)" >> "$OUT/machine.txt"
files=(); for row in $MODELS; do [ -s "$OUT/$row.json" ] && files+=("$OUT/$row.json"); done
for row in $TIDY; do [ -s "$OUT/tidy-$row.json" ] && files+=("$OUT/tidy-$row.json"); done
[ ${#files[@]} -gt 0 ] && (cd /tmp && "$PY" -I "$OLDPWD/tools/stt/bench.py" table "${files[@]}") > "$OUT/table.md" && cat "$OUT/table.md"
cat "$OUT/machine.txt"
if [ -n "$bad" ]; then echo "STT_BENCH RESULT FAIL (did not run:$bad; logs in $OUT)"; exit 1; fi
echo "STT_BENCH RESULT PASS ($OUT)"
