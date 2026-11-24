#!/usr/bin/env bash
# Probe of the launcher's answers child (tools/launcher/answers.py): drives the REAL child over its pipe with every case of
# launcher_answers_cases.tsv, the app-name fixture, ids, ping, a pending currency reply and its update against a local
# server, a stale id, offline. Prints the timings and ends with one `LAUNCHER_ANSWERS RESULT PASS|FAIL` line.
#   tools/dev/launcher_answers_probe.sh                 the run
#   ARM=factor|parser|nopending|ratebias|allkinds  tools/dev/launcher_answers_probe.sh    a fault in a COPY: the run must FAIL, case named
# No quickshell, no network but 127.0.0.1, no real home: the cache lives in a private dir.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=result_lib.sh
. "$HERE/result_lib.sh"
SRC="$HERE/../launcher/answers.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lans-run-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/answers.py"
cp "$SRC" "$COPY"
arm_patch() { # <name> <python replace script body>
  python3 - "$COPY" "$1" <<'PY'
import sys
p, arm = sys.argv[1], sys.argv[2]
s = open(p).read()
swap = {
    "factor":    ('add(L_, Fraction(3048, 10000), "ft foot feet")', 'add(L_, Fraction(3049, 10000), "ft foot feet")'),
    "parser":    ('toks.append(("o", "^"))\n            i += 2', 'toks.append(("o", "*"))\n            i += 2'),
    "nopending": ('return [A("currency", f"{shown} {dst}", plain, expr, det, alts, pending=pending)]', 'return [A("currency", f"{shown} {dst}", plain, expr, det, alts, pending=False)]'),
    "allkinds":  ('if f.__name__[4:] in words(kinds))', 'if True)'),
    "ratebias":   ('r = a / rs * rd\n', 'r = a / rs * rd\n'),
}
if arm == "ratebias":
    old, new = 'res = a / rs * rd', 'res = a * rd / rs + Fraction(1, 1000)'
else:
    old, new = swap[arm]
if old not in s:
    print("ARM anchor gone: " + arm); sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
}
if [ -n "${ARM:-}" ]; then
  arm_patch "$ARM" || { echo "LAUNCHER_ANSWERS RESULT FAIL (arm $ARM did not apply)"; exit 1; }
fi
LOG="$WORK/run.log"
python3 "$HERE/launcher_answers_probe.py" "$COPY" >"$LOG" 2>&1
code=$?
cat "$LOG" | grep -v '^LAUNCHER_ANSWERS RESULT' | head -60
rl_result LAUNCHER_ANSWERS "$LOG" || true
exit $code
