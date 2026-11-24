#!/usr/bin/env bash
# dictation_probe.sh -- dictation end to end on the real chain, never the user's microphone or desktop: the real speech helper and
# model, the real input method (lares-ime) in a nested Hyprland (tools/dev/lock_env.sh, LOCK_ENV=sttproto), a PRIVATE PipeWire with a
# virtual mic playing FLEURS clips (tools/dev/stt_pw_fixture.sh), the harness tools/dev/qml/dictation_probe.qml (its field is a Qt
# TextInput, the shell's own fields' kind), a stub wl-copy.
#
#   tools/dev/dictation_probe.sh                DICTATION RESULT PASS | FAIL
#   ARM=<name> tools/dev/dictation_probe.sh     a fault in the sandbox copy; must FAIL on its needle
#     nopreedit   the live words never reach the field          -> "A preedit in the field"
#     stableonly  the helper shows only agreed words (no tail)   -> "A revision"
#     nomic       the mic is left as the take set it              -> "A mic"
#     noclip      the clipboard fallback copies nothing           -> "B clipboard"
#     offignored  the switch is not read at the press            -> "C switch off"
#     nopassword  a hidden / sensitive field is treated as any field -> "D secret field"
#     keycode9    lares-ime types its first character on keycode 9 (as wtype does) -> "E typing" (the Escape bind fires)
#     nofiller    fillers are not stripped (tools/stt/sttlib/fillers.py)      -> "F fillers"
#     nothink     a pause after a filler ends the sentence like any other  -> "F think"
#     noguard     the tidy pass takes whatever its model proposes            -> "G tidy"
#     nogate      the take never asks for the card, whatever the fact says   -> "H device"
#     norebind    lares-ime never binds again when no `activate` came            -> "I first take live"
#     latecapture the order before round 5: the helper started at the press, its heavy start-up before `ready` -> "K capture from the press"
#     auragroup   the press asks for the whole aura, not the island group     -> "A aura"
#     linkall     a window take links every app's output stream (sttlib/sources.py)  -> "S only the window's streams"
#     sourcemic   a window take takes the mic like a typing take                       -> "S mic untouched"
#     noask       a voice ask's question never goes to the LLM                         -> "Q voice ask"
#
# Round 4's steps F-H run the helper with its stand-in decoder (LARES_STT_STUBS=1, tools/stt/sttlib/stubs.py) on a recording built
# here (tools/dev/stt_filler_wav.py), the tidy pass's stub that adds a word (LARES_STT_TIDY_MODEL=stub-add) and a fake PCI tree
# (LARES_STT_PCI_ROOT): empty for A-G (Integrated), a card with the nvidia driver for H, whose CUDA start then really fails here and
# falls back to the iGPU.
# Round 5's steps: I (the first take live) in a window built here from tools/dev/dictation_probe_ticlient.c, L (a take stopped while
# the stand-in model loads for 4 s: LARES_STT_STUB_LOAD_FILE), K (capture from the press: tools/dev/dictation_probe_capture.sh plays a
# clip cut here so its first word starts 100 ms after the press it makes), S (a window take: A's second clip from a child of a
# window process, B's clip from another app beside it) and Q (a voice ask from a terminal window, A's first clip in the mic), both
# on the real model. lares-ime is built here from the copy under test, never taken from the cache. The sources' rules alone:
# tools/dev/dictation_probe_sources.py (seconds, no PipeWire).
#
# DICTATION_KEEP=1 keeps the run's scratch (the log), as a failed run does by itself. DICTATION_FROM=I runs round 5's steps (I, L, K)
# and C alone: a developer's shortcut, never the probe's verdict (the result line says so).
# Needs tools/stt/setup.sh (the venv, the models) and the clips (`tools/stt/fetch.py clips`); gcc and wayland-scanner build lares-ime and
# I's window. CPU: one model decoding for about two minutes. Runs in a sandbox copy (tools/dev/sandbox.sh); an arm patches that copy only.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/dictp.XXXXXX")"
PWD_="$(mktemp -d /tmp/dpw.XXXXXX)"             # short: the PipeWire socket path
export LOCK_ENV="${LOCK_ENV:-sttproto}"
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-sttproto}"
if [ -z "${LARES_STT_HOME:-}" ] && [ ! -d "$HOME/.cache/lares-stt" ] && [ -d "$HOME/.cache/quickshell-stt" ]; then export LARES_STT_HOME=$HOME/.cache/quickshell-stt; fi
CLIPS="${LARES_STT_HOME:-$HOME/.cache/lares-stt}/clips"
STT_PY="$HOME/.local/share/lares/stt/venv/bin/python"
# THE NAME CHANGE: until `lares migrate-name` has run on this machine the venv and the clips are still under the old name's directories
[ -x "$STT_PY" ] || { [ -x "$HOME/.local/share/quickshell/stt/venv/bin/python" ] && STT_PY=$HOME/.local/share/quickshell/stt/venv/bin/python; }
cleanup() {
    KEEP= tools/dev/lock_env.sh down > /dev/null 2>&1      # lock_env's KEEP keeps the whole env; this runner's is DICTATION_KEEP
    tools/dev/stt_pw_fixture.sh down "$PWD_" > /dev/null 2>&1
    rm -rf "$PWD_"
    [ -n "${DICTATION_KEEP:-}" ] || rm -rf "$D"
}
trap cleanup EXIT

S=modules/dictation/DictationService.qml P=tools/stt/sttlib/policy.py T=modules/dictation/DictationText.js I=tools/stt/ime/lares-ime.c
F=tools/stt/sttlib/fillers.py G=tools/stt/sttlib/tidy.py K=tools/stt/sttlib/decoders.py Q=tools/stt/lares_stt.py W=tools/stt/sttlib/sources.py
ARMCMD="" NEEDLE=""
# round 4's arms patch Python by exact strings (a python patcher, so no quoting survives two shells): FILE OLD NEW, as many triples as
# the fault needs, every anchor checked before anything is written
arm_py() {
    printf '%s\0' "$@" > "$D/arm.args"
    cat > "$D/arm.py" <<'ARM_EOF'
import sys
a = open(sys.argv[1], encoding="utf-8").read().split("\0")[:-1]
out = {}
for i in range(0, len(a), 3):
    f, old, new = a[i:i + 3]
    s = out.get(f) or open(f, encoding="utf-8").read()
    if s.count(old) != 1:
        sys.exit("the arm's anchor is gone from " + f)
    out[f] = s.replace(old, new)
for f, s in out.items():
    open(f, "w", encoding="utf-8").write(s)
ARM_EOF
    ARMCMD="python3 $D/arm.py $D/arm.args"
}
case "${ARM:-}" in
    "") ;;
    nopreedit)  ARMCMD="sed -i 's|if (root._route !== \"ime\" \|\| !root._imeActive \|\| rule === \"refuse\")|if (true)|' $S"; NEEDLE='DICT FAIL A preedit in the field' ;;
    stableonly) ARMCMD="sed -i 's|shown = \" \".join(self.stable + words\[len(self.stable):\])|shown = \" \".join(self.stable)|' $P"; NEEDLE='DICT FAIL A revision' ;;
    nomic)      ARMCMD="sed -i 's|        root._restoreMic(m);|        void m;|' $S"; NEEDLE='DICT FAIL A mic' ;;
    noclip)     ARMCMD="sed -i 's|            root._copy(clip);|            void clip;|' $S"; NEEDLE='DICT FAIL B clipboard' ;;
    offignored) ARMCMD="sed -i 's|        if (!root.enabled) {|        if (false) {|' $S"; NEEDLE='DICT FAIL C switch off' ;;
    nopassword) ARMCMD="sed -i 's|^        return \"refuse\";|        return \"text\";|' $T"; NEEDLE='DICT FAIL D secret field' ;;
    keycode9)   ARMCMD="sed -i 's|    for (int kc = 9; kc < 240 \&\& n_free|    free_codes[n_free++] = 9;\n    for (int kc = 10; kc < 240 \&\& n_free|' $I"
                NEEDLE='DICT FAIL E typing' ;;
    nofiller)   arm_py "$F" $'    cap = False\n    last_dropped = False' '    return text'; NEEDLE='DICT FAIL F fillers' ;;
    nothink)    arm_py "$P" 'if pause and (not held or sil_ms >= c["thinkSilenceMs"]):' 'if pause:'; NEEDLE='DICT FAIL F think' ;;
    noguard)    arm_py "$G" 'out, why, back = guard(text, prop, lang)' 'out, why, back = prop, "", []'; NEEDLE='DICT FAIL G tidy' ;;
    nogate)     arm_py "$K" 'return "cuda", "the card is on the bus"' 'return "igpu", "armed: the card is never asked for"'; NEEDLE='DICT FAIL H device' ;;
    norebind)   arm_py "$I" '    int rebind_due = !type_only && REBIND_MS >= 0;' '    int rebind_due = 0;'; NEEDLE='DICT FAIL I first take live' ;;
    latecapture) arm_py "$Q" $'    faulthandler.enable()\n    emit({"ev": "ready", "v": V})' \
                     $'    faulthandler.enable()\n    from sttlib import decoders\n    from sttlib.vad import StreamingVad\n    decoders.ov_devices()\n    StreamingVad(decoders.MODELS_DIR / "silero-vad")\n    emit({"ev": "ready", "v": V})' \
                     "$S" $'    onEnabledChanged: {\n        if (root.enabled)' $'    onEnabledChanged: {\n        root._warm = false;\n        if (root.enabled)'
                NEEDLE='DICT FAIL K capture from the press' ;;
    auragroup)  arm_py "$S" '        root._aura("island");' '        root._aura("all");'; NEEDLE='DICT FAIL A aura' ;;
    linkall)    arm_py "$W" 'if not (self.match_all or any(self.tree.owns(x) for x in pids)):' 'if False:'; NEEDLE="DICT FAIL S only the window's streams" ;;
    sourcemic)  arm_py "$S" '        const node = source ? "" : root._micTake();' '        const node = root._micTake();'; NEEDLE='DICT FAIL S mic untouched' ;;
    noask)      arm_py "$S" '            root.llm.voiceAsk(said, ctx);' '            void ctx;'; NEEDLE='DICT FAIL Q voice ask' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
for f in "$STT_PY" "$CLIPS/en/refs.tsv"; do
    [ -e "$f" ] || { echo "DICTATION RESULT FAIL (missing $f: run tools/stt/setup.sh and tools/stt/fetch.py clips)"; exit 1; }
done

# the clips: two short English ones for the field (A), one Dutch one for the clipboard (B); A's reference text for the words check
mapfile -t A < <(sort -t$'\t' -k2 -n "$CLIPS/en/refs.tsv" | head -2 | cut -f1)
mapfile -t B < <(sort -t$'\t' -k2 -n "$CLIPS/nl/refs.tsv" | head -1 | cut -f1)
REF=$(for c in "${A[@]}"; do awk -F'\t' -v f="$c" '$1 == f { print $4 }' "$CLIPS/en/refs.tsv"; done | tr '\n' ' ')
CA=""; for c in "${A[@]}"; do CA="$CA $CLIPS/en/$c"; done
CB=""; for c in "${B[@]}"; do CB="$CB $CLIPS/nl/$c"; done
# S: the window plays A's second clip, the other app B's; Q asks A's first
REF_S=$(awk -F'\t' -v f="${A[1]}" '$1 == f { print $4 }' "$CLIPS/en/refs.tsv")
REF_Q=$(awk -F'\t' -v f="${A[0]}" '$1 == f { print $4 }' "$CLIPS/en/refs.tsv")

mkdir -p "$D/state" "$D/bin" "$D/pci"
"$STT_PY" -I tools/dev/stt_filler_wav.py "$D/filler.wav" "$CLIPS/en/${A[0]}" "$CLIPS/en/${A[1]}" > "$D/filler.log" 2>&1 \
    || { cat "$D/filler.log"; echo "DICTATION RESULT FAIL (the filler recording was not built)"; exit 1; }
# I's window (an app that makes its text input when its window is first focused)
G_="$D/gen"; mkdir -p "$G_"
for x in stable/xdg-shell/xdg-shell unstable/text-input/text-input-unstable-v3; do
    wayland-scanner client-header "/usr/share/wayland-protocols/$x.xml" "$G_/${x##*/}-client-protocol.h" \
        && wayland-scanner private-code "/usr/share/wayland-protocols/$x.xml" "$G_/${x##*/}-protocol.c"
done
# shellcheck disable=SC2046
gcc -O2 -Wall -o "$D/ticlient" -I "$G_" tools/dev/dictation_probe_ticlient.c "$G_"/*-protocol.c $(pkg-config --cflags --libs wayland-client) > "$D/ticlient.log" 2>&1 \
    || { cat "$D/ticlient.log"; echo "DICTATION RESULT FAIL (I's window did not build)"; exit 1; }
# K's recording: a clip whose first word's onset (the first 10 ms frame past 15 % of its loudest) lands 1500 ms into the file, the
# 50 ms before it kept; the rig presses 100 ms before that onset
CAPCLIP=1003119935936341070.wav
CAPREF=$(awk -F'\t' -v f="$CAPCLIP" '$1 == f { print $4 }' "$CLIPS/en/refs.tsv" | awk '{ print $1 }')
"$STT_PY" -I - "$CLIPS/en/$CAPCLIP" "$D/capture.wav" 1500 > "$D/capture.log" 2>&1 <<'CAP_EOF' \
    || { cat "$D/capture.log"; echo "DICTATION RESULT FAIL (K's recording was not built)"; exit 1; }
import sys
import numpy as np
import soundfile as sf
a, r = sf.read(sys.argv[1], dtype="float32", always_2d=True)
a = a.mean(axis=1)
f = r // 100
n = a.size // f
rms = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1))
on = int(np.argmax(rms > 0.15 * rms.max())) * f
pre = r // 20
lead = int(r * int(sys.argv[3]) / 1000) - pre
sf.write(sys.argv[2], np.concatenate([np.zeros(lead, np.float32), a[max(0, on - pre):]]), r)
print("onset at %d ms of the clip" % (on * 1000 // r))
CAP_EOF
[ -n "$CAPREF" ] || { echo "DICTATION RESULT FAIL (no reference text for $CAPCLIP)"; exit 1; }
printf '#!/bin/sh\ncat > "$1"\n' > "$D/bin/wl-copy-stub"; chmod +x "$D/bin/wl-copy-stub"
tools/dev/stt_pw_fixture.sh up "$PWD_" > "$D/fixture.up" 2>&1 || { cat "$D/fixture.up"; echo "DICTATION RESULT FAIL (the private PipeWire did not come up)"; exit 1; }
[ -e "/tmp/lrlk-$LOCK_ENV/up" ] && KEEP= tools/dev/lock_env.sh down > /dev/null 2>&1    # this runner's own env, left by a run that died
OUTPUTS=1 tools/dev/lock_env.sh up > "$D/up.log" 2>&1 || { tail -5 "$D/up.log"; echo "DICTATION RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }

cat > "$D/run.sh" <<RUN_EOF
cp $S $D/orig.qml; cp $P $D/orig.py; cp $T $D/orig.js; cp $I $D/orig.c; cp $F $D/orig.f.py; cp $G $D/orig.g.py; cp $K $D/orig.k.py; cp $Q $D/orig.q.py; cp $W $D/orig.w.py
${ARMCMD:-true}
if [ -n "${ARM:-}" ] && cmp -s $S $D/orig.qml && cmp -s $P $D/orig.py && cmp -s $T $D/orig.js && cmp -s $I $D/orig.c \
    && cmp -s $F $D/orig.f.py && cmp -s $G $D/orig.g.py && cmp -s $K $D/orig.k.py && cmp -s $Q $D/orig.q.py && cmp -s $W $D/orig.w.py; then echo "DICT ARMLOST"; exit 3; fi
# lares-ime from the copy under test (an arm's change included), never the cache's
tools/stt/ime/build.sh $D/lares-ime > $D/ime-build.log 2>&1 || { cat $D/ime-build.log; echo "DICT RESULT FAIL (lares-ime did not build)"; exit 1; }
: > $D/stubload
timeout -k 5 700 tools/dev/lock_env.sh run env PIPEWIRE_REMOTE="$PWD_/rt/pipewire-0" DICT_FIXTURE="\$PWD/tools/dev/stt_pw_fixture.sh" DICT_PW="$PWD_" \
    DICT_CLIPS_A="${CA# }" DICT_CLIPS_B="${CB# }" DICT_REF_A="$REF" DICT_COPY="$D/bin/wl-copy-stub" DICT_STATE="$D/state" DICT_IME="$D/lares-ime" \
    DICT_FILLER="$D/filler.wav" DICT_PCI="$D/pci" LARES_STT_PCI_ROOT="$D/pci" LARES_STT_STUBS=1 LARES_STT_TIDY_MODEL=stub-add \
    DICT_TICLIENT="$D/ticlient" DICT_LOADFILE="$D/stubload" LARES_STT_STUB_LOAD_FILE="$D/stubload" \
    DICT_RIG="\$PWD/tools/dev/dictation_probe_capture.sh" DICT_CAPWAV="$D/capture.wav" DICT_CAPREF="$CAPREF" DICT_FROM="${DICTATION_FROM:-}" \
    DICT_CLIP_S="$CLIPS/en/${A[1]}" DICT_REF_S="$REF_S" DICT_CLIP_SB="$CLIPS/nl/${B[0]}" DICT_CLIP_Q="$CLIPS/en/${A[0]}" DICT_REF_Q="$REF_Q" \
    QT_QUICK_BACKEND=rhi quickshell -p tools/dev/qml/dictation_probe.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'DICT .*' | grep -a -v 'DICT log ' | cut -c1-400
if [ -n "${ARM:-}" ]; then
    if rl_has "$D/log" 'DICT ARMLOST'; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if rl_clean "$D/log" | grep -a -q -F "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/log" 'DICT RESULT' || { DICTATION_KEEP=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result DICTATION "$D/log" 'DICT RESULT .*'); rc=$?
if rl_isnoresult "$res"; then DICTATION_KEEP=1; printf '%s\n' "$res"; exit 1; fi
res=$(printf '%s\n' "$res" | sed 's/^DICT RESULT/DICTATION RESULT/')
[ -z "${DICTATION_FROM:-}" ] || { res="$res (DICTATION_FROM=$DICTATION_FROM: a partial run, not the probe's verdict)"; rc=1; }
[ "$rc" -eq 0 ] || DICTATION_KEEP=1
printf '%s\n' "$res"
exit $rc
