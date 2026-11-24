#!/usr/bin/env bash
# tools/dev/panorama_hypr_facts.sh -- the env-tier entry of tools/dev/panorama_hypr_facts.py (shell_gates runs runners with bash).
#   ends in PANORAMA_FACTS RESULT PASS|FAIL; ARM=snapdown|reservewiped and ONLY= pass through.
exec python3 -B "$(dirname "$0")/panorama_hypr_facts.py" "$@"
