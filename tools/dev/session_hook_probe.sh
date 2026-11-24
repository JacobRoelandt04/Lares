#!/usr/bin/env bash
# session_hook_probe.sh -- tools/session/session-hook.bash in a real interactive bash on a pty (docs/session.md).
# The harness plays the terminal (it answers the status query as kitty does); HOME, the runtime dir and the history
# are private. No window, no compositor.
#
#   tools/dev/session_hook_probe.sh        SESSION_HOOK RESULT PASS | FAIL
#   ARM=<name> ...                         one fault in a COPY of the hook; the check named must fail
#   ARM=all ...                            SESSION_HOOK ARMS RESULT PASS | FAIL
#
# ARMs:
#   typeruns     the type mode evaluates the command                         -> "H1 nothing ran"
#   unbind       the fill unbinds its key (bash then inserts the answer's n) -> "H1 Enter runs exactly the line"
#   pingpong     the fill stays bound (query and answer for ever)            -> "H1 the status query stops"
#   noclaimonce  the pending file is read, not renamed                       -> "H3 one shell claims"
# (No arm for "the token stays in the environment": the rename already leaves a nested shell nothing to claim, so the
#  unset is tidiness, not a guard -- an arm on it stayed green and was deleted.)
#   nokind       the mark has no kind line                                   -> "H4 a program"
#   nowords      the mark names no command words                             -> "H4 a chain names its command words"
set -u
{
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh

if [ "${ARM:-}" = all ]; then
    rc=0
    declare -A NEED=([typeruns]="H1 nothing ran" [unbind]="H1 Enter runs exactly the line" [pingpong]="H1 the status query stops (no ping-pong)" [noclaimonce]="H3 one shell claims" [nokind]="H4 a program" [nowords]="H4 a chain names its command words")
    for a in ${ONLY_ARMS:-typeruns unbind pingpong noclaimonce nokind nowords}; do
        out=$(ARM="$a" bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "anchor is gone"; then
            echo "ARM $a: NOT PROVEN (its anchor is gone)"; rc=1
        elif rl_isnoresult "$out"; then
            echo "ARM $a: NOT PROVEN (no result)"; rc=1
        elif printf '%s\n' "$out" | grep -aqF "SHP FAIL ${NEED[$a]}:"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aF "SHP FAIL ${NEED[$a]}:" | head -1 | cut -c1-110))"
        elif printf '%s\n' "$out" | grep -aq "^SESSION_HOOK RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS OWN CHECK (${NEED[$a]}): $(printf '%s\n' "$out" | grep -a 'SHP FAIL' | head -1 | cut -c1-100)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "SESSION_HOOK ARMS RESULT PASS" || echo "SESSION_HOOK ARMS RESULT FAIL"
    exit "$rc"
fi

W=$(mktemp -d "${SCRATCH:-/tmp}/shp.XXXXXX")
trap 'rm -rf "$W"' EXIT
cp tools/session/session-hook.bash "$W/hook.bash"
arm() {
    python3 - "$W/hook.bash" "$1" "$2" <<'PY' || { echo "ARM ${ARM}: anchor is gone"; echo "SESSION_HOOK RESULT FAIL (arm)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
    "") ;;
    typeruns)    arm "                bind -x '\"\\e[0n\": __lares_sr_fill' 2> /dev/null && PS1+='\\[\\e[5n\\]' ;;" '                eval "$__lares_sr_cmd" ;;' ;;
    unbind)      arm "    bind '\"\\e[0n\": \"\"' 2> /dev/null" "    bind -r '\\e[0n' 2> /dev/null" ;;
    pingpong)    arm "    bind '\"\\e[0n\": \"\"' 2> /dev/null" "    :" ;;
    noclaimonce) arm 'if mv -n -- "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN" "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$" 2> /dev/null \' 'if cp -- "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN" "$__lares_sr_dir/pending/$LARES_SESSION_TOKEN.$$" 2> /dev/null \' ;;
    nokind)      arm '    kind=${ builtin type -t -- "$w" 2> /dev/null; }' '    kind=""' ;;
    nowords)     arm "        map+=\$'\\t'\"\$w\"\$'\\t'\"\$k\"\$'\\t'\"\$a\"" '        :' ;;
    *) echo "SESSION_HOOK RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac
bash -n "$W/hook.bash" || { echo "SESSION_HOOK RESULT FAIL (the hook does not parse)"; exit 1; }
timeout -k 2 120 python3 tools/dev/session_hook_probe.py "$W/hook.bash" "$W" > "$W/run.log" 2>&1
grep -a '^SHP FAIL' "$W/run.log" | cut -c1-300
[ -n "${VERBOSE:-}" ] && cat "$W/run.log"
rl_has "$W/run.log" '^SESSION_HOOK RESULT ' || { cp "$W/run.log" "${SCRATCH:-/tmp}/session_hook_probe.last.log"; rl_noresult SESSION_HOOK "${SCRATCH:-/tmp}/session_hook_probe.last.log"; exit 1; }
rl_result SESSION_HOOK "$W/run.log"
exit $?
}
