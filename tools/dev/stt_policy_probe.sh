#!/usr/bin/env bash
# stt_policy_probe.sh -- the dictation's revision policy (tools/stt/sttlib/policy.py) against its promises: the real VAD on joined
# FLEURS clips, a stand-in decoder (no model, seconds of CPU), the simulated clock (tools/stt/policy_check.py has the checks):
# sentences, the stable prefix, fillers never shown, a pause after a filler keeping the sentence open, the tidy pass's guard; round 5:
# an unfinished sentence held over a pause and continued in lower case, repeats across a filler or a held pause, and the final text's
# rules against tools/stt/text_cases.tsv. Round 8: the partial builder by word alignment against rewritten hypothesis sequences, the
# spelled-code rule's cases, the guard's restart rule (an enumeration is no restart).
#
#   tools/dev/stt_policy_probe.sh                  STT_POLICY RESULT PASS | FAIL
#   ARM=nosnapshot tools/dev/stt_policy_probe.sh   the final decode reads the live utterance bounds instead of the closed one's
#                                                  snapshot (the bug that lost whole sentences): "PCHECK FAIL decoded" must show
#   ARM=nofiller   fillers are not stripped (sttlib/fillers.py strip returns the text): "PCHECK FAIL fillers"
#   ARM=nothink    a pause after a filler ends the sentence like any other: "PCHECK FAIL think"
#   ARM=noguard    the tidy pass takes whatever its model proposes: "PCHECK FAIL tidy"
#   ARM=wholerefuse  the guard refuses a whole proposal for one removal it cannot name (before round 6): "PCHECK FAIL guard"
#   ARM=nofillerrepeat   a repeat across a filler or a held pause is written twice (textrules.finish skips fillers.drop_repeats):
#                  "PCHECK FAIL repeat"
#   ARM=nounfinished     a pause after an unfinished sentence ends it (textrules hold() says no): "PCHECK FAIL unfinished"
#   ARM=nosign     "<name> sign" stays words: "PCHECK FAIL cases sign"
#   ARM=nofkey     "F ten" stays words: "PCHECK FAIL cases fkey"
#   ARM=noleadgt   a take beginning "greater than" keeps the words: "PCHECK FAIL cases leadgt"
#   ARM=indextail  round 8: the partial's tail is cut from the new hypothesis by INDEX again (a re-split shows a word twice): "PCHECK FAIL partials"
#   ARM=nocodes    round 8: a spelled code stays words ("X nine five Z B ..."): "PCHECK FAIL cases code"
#   ARM=noownfillers the user's own fillers (dictation.text.fillers) are not read: "PCHECK FAIL cases own fillers"
#   ARM=anyrestart round 8: the guard takes any abandoned run for a restart ("one is a brain, one is a pencil" loses the brain): "PCHECK FAIL guard"
#
# Needs the venv and the clips (tools/stt/setup.sh --clips). An arm patches a copy of tools/stt, never the tree.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
PY="${LARES_STT_PYTHON:-$HOME/.local/share/lares/stt/venv/bin/python}"
# THE NAME CHANGE: until `lares migrate-name` has run on this machine the venv, the models and the clips are still under the old name's directories
if [ -z "${LARES_STT_HOME:-}" ] && [ ! -d "$HOME/.cache/lares-stt" ] && [ -d "$HOME/.cache/quickshell-stt" ]; then export LARES_STT_HOME=$HOME/.cache/quickshell-stt; fi
[ -x "$PY" ] || { [ -x "$HOME/.local/share/quickshell/stt/venv/bin/python" ] && PY=$HOME/.local/share/quickshell/stt/venv/bin/python; }
D="$(mktemp -d "${SCRATCH:-/tmp}/sttpol.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
[ -x "$PY" ] || { echo "STT_POLICY RESULT FAIL (no venv at $PY: run tools/stt/setup.sh)"; exit 1; }
cp -r tools/stt "$D/stt"
NEEDLE=""
# arm FILE OLD NEW: OLD (exact text, found exactly once) becomes NEW in the copy, or the arm says its anchor is gone
arm() {
    python3 - "$D/stt/$1" "$2" "$3" <<'PY' || { echo "ARM $ARM: its anchor is gone -- re-aim it"; exit 1; }
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
    nosnapshot)
        arm sttlib/policy.py 'raw = self._decode(u["a"], u["b"], True)' 'raw = self._decode(self.u_start, self.u_end, True)'
        NEEDLE='PCHECK FAIL decoded' ;;
    nofiller)
        arm sttlib/fillers.py $'    out = []\n    cap = False\n' $'    return text\n'
        NEEDLE='PCHECK FAIL fillers' ;;
    nothink)
        arm sttlib/policy.py 'if pause and (not held or sil_ms >= c["thinkSilenceMs"]):' 'if pause:'
        NEEDLE='PCHECK FAIL think' ;;
    noguard)
        arm sttlib/tidy.py 'out, why, back = guard(text, prop, lang)' 'out, why, back = prop, "", []'
        NEEDLE='PCHECK FAIL tidy' ;;
    wholerefuse)
        arm sttlib/tidy.py $'        for a, b in bad:\n            kept.update(range(a, b))' $'        return src_text, "unexplained", []\n        for a, b in bad:\n            kept.update(range(a, b))'
        NEEDLE='PCHECK FAIL guard' ;;
    nofillerrepeat)
        arm sttlib/textrules.py 'text, fired = fillers.drop_repeats(text, lang, marks, rules.fillers)' 'fired = []'
        NEEDLE='PCHECK FAIL repeat' ;;
    nounfinished)
        arm sttlib/textrules.py 'return not ended(text) or core(toks[-1]) in HOLD_WORDS.get(lang, HOLD_WORDS["en"])' 'return False'
        NEEDLE='PCHECK FAIL unfinished' ;;
    nosign)
        arm sttlib/textrules.py 'toks = self._signs(toks)' 'pass'
        NEEDLE='PCHECK FAIL cases sign' ;;
    nofkey)
        arm sttlib/textrules.py 'toks = self._fkeys(toks)' 'pass'
        NEEDLE='PCHECK FAIL cases fkey' ;;
    noleadgt)
        arm sttlib/textrules.py 'toks = self._leading_quote(toks)' 'pass'
        NEEDLE='PCHECK FAIL cases leadgt' ;;
    indextail)
        arm sttlib/policy.py 'shown = " ".join(self.stable + words[tail_from(self.stable, words):])' 'shown = " ".join(self.stable + words[len(self.stable):])'
        NEEDLE='PCHECK FAIL partials' ;;
    nocodes)
        arm sttlib/textrules.py 'self.codes = bool(sym.get("codes", d["codes"]))' 'self.codes = False'
        NEEDLE='PCHECK FAIL cases code' ;;
    noownfillers)
        arm sttlib/textrules.py 'if isinstance(w, str) and len(w.split()) == 1 and core(w))' 'if False)'
        NEEDLE='PCHECK FAIL cases own fillers' ;;
    anyrestart)
        arm sttlib/tidy.py '    return last in HOLD_WORDS.get(lang, HOLD_WORDS["en"]) or last in _BREAK_EXTRA.get(lang, _BREAK_EXTRA["en"])' '    return True'
        NEEDLE='PCHECK FAIL guard' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
(cd /tmp && timeout -k 5 300 "$PY" -I "$D/stt/policy_check.py") > "$D/log" 2>&1
grep -a '^PCHECK' "$D/log"
if [ -n "${ARM:-}" ]; then
    if grep -a -q -F "$NEEDLE" "$D/log"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    grep -a -q 'PCHECK RESULT' "$D/log" || { KEEP=1; echo "ARM $ARM: the armed copy did not run -- it proves nothing ($D/log)"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the check cannot see it"; exit 1
fi
res=$(rl_result STT_POLICY "$D/log" 'PCHECK RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; tail -5 "$D/log"; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^PCHECK RESULT/STT_POLICY RESULT/'
exit $rc
