#!/usr/bin/env bash
# silicon_helper_tests.sh -- the silicon root helper's own tests (helpers/silicon_helper: `cargo test`, every unit and integration
# suite, in the helper's TEST mode: nothing is written outside the test roots and nothing is executed). Runs as the user, never as
# root, never installs. Ends in one SILICON_HELPER_TESTS RESULT PASS|FAIL line; the exit status follows it.
set -u
cd "$(dirname "$0")/../../helpers/silicon_helper" || { echo "SILICON_HELPER_TESTS RESULT FAIL (no helpers/silicon_helper)"; exit 1; }
command -v cargo >/dev/null || { echo "SILICON_HELPER_TESTS RESULT FAIL (no cargo)"; exit 1; }
log="$(mktemp "${TMPDIR:-/tmp}/silicon_helper_tests.XXXXXX")"
trap 'rm -f "$log"' EXIT
if cargo test --quiet >"$log" 2>&1; then
    n="$(grep -o 'test result: ok\. [0-9]* passed' "$log" | awk '{s += $4} END {print s + 0}')"
    echo "SILICON_HELPER_TESTS RESULT PASS ($n tests)"
else
    tail -30 "$log"
    echo "SILICON_HELPER_TESTS RESULT FAIL (cargo test: see above)"
    exit 1
fi
