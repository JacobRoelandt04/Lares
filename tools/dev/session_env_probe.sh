#!/usr/bin/env bash
# session_env_probe.sh -- session restore, end to end, in the isolated nested Hyprland of tools/dev/lock_env.sh.
#
# A session is built by hand (a LOCKED 3-tab group one of whose terminals was `kitty --hold <program>`, two tiled windows,
# a floating one, one on the special workspace, a kitty that runs a program with no shell, a maximized one, an app with
# two windows on one pid, a "slow" app), saved with lares-session, closed, restored, and the two pictures are compared window
# by window: workspace, floating, place, group order, the tab on show and the lock, fullscreen, and what each terminal
# runs (read from /proc). A typed command is proven typed by pressing Enter on it. The restore itself is WATCHED: every
# 30 ms the clients are sampled, and until its reveal no new window may stand anywhere but on a staging workspace. Nothing of the user's is touched: the compositor, runtime dir, state, config and HOME are the env's own,
# the tools run from a copy, and no quickshell is started.
#
#   tools/dev/session_env_probe.sh              SESSION_ENV RESULT PASS | FAIL
#   MODE=half ...                               a restore into a session that already holds part of it
#   MODE=locked ...                             the same restore under a session lock (the boot lock's case)
#   MODE=preset ...                             presets: save a desktop, rearrange it, `preset load --add` (reuse + move what is
#                                               open, start what is missing, leave the extra), then `--replace` (close the extra;
#                                               a window that refuses to close is kept and reported); with session restore OFF
#   SESSION_ENV_KEEP=1 ...                      keep the work dir (and the env: KEEP) for a look
#   ARM=<name> ...                              one fault in the copy; the run must FAIL the check named
#   ARM=all ...                                 every arm in turn: SESSION_ENV ARMS RESULT PASS | FAIL
#
# ARMs:
#   nogroup    the groups are not rebuilt                                   -> "tabA group"
#   nomove     a multi-window app's windows are not moved to their place    -> "beta document workspace"
#   runtyped   the classifier lets everything run                           -> "tabC is only typed"
#   notitle    a multi-window app's windows are paired in opening order     -> "alpha document workspace"
#   noactive   the tab on show is not set                                   -> "tabA tab on show"
#   chainwhole a chain is not taken apart (the whole line is typed)         -> "tabB runs again (run list)"
#   nostage    windows open on their own workspaces, in sight                -> "staged until the reveal"
#   nolock     a locked group is rebuilt unlocked                            -> "the group is locked again"
#   heldrerun  a held program that is over runs again                        -> "the held program did not run again"
#   (MODE=preset)
#   nomovereuse  a reused window is not moved to its saved place            -> "add alpha workspace"
#   closesall    --add closes what the preset has no place for               -> "add leaves the extra window"
set -u
# ONE BRACE GROUP: bash reads a script from disk as it runs
{
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. tools/dev/result_lib.sh

if [ "${ARM:-}" = all ]; then
    rc=0
    if [ "${MODE:-}" = preset ]; then
        declare -A NEED=([nomovereuse]="add alpha workspace" [closesall]="add leaves the extra window")
        ARMLIST="nomovereuse closesall"
    else
    ARMLIST="nogroup nomove runtyped notitle noactive chainwhole nostage nolock heldrerun"
    declare -A NEED=([nogroup]="tabA group" [nomove]="beta document workspace" [runtyped]="tabC is only typed" [notitle]="alpha document workspace" [noactive]="tabA tab on show" [chainwhole]="tabB runs again (run list)" [nostage]="staged until the reveal" [nolock]="the group is locked again" [heldrerun]="the held program did not run again")
    fi
    for a in ${ONLY_ARMS:-$ARMLIST}; do
        out=$(ARM="$a" SESSION_ENV_KEEP= bash "$0" 2>&1)
        if printf '%s\n' "$out" | grep -aq "anchor is gone"; then
            echo "ARM $a: NOT PROVEN ($(printf '%s\n' "$out" | grep -a 'anchor is gone' | head -1))"; rc=1
        elif rl_isnoresult "$out"; then
            echo "ARM $a: NOT PROVEN (no result)"; rc=1
        elif printf '%s\n' "$out" | grep -aqF "SRE FAIL ${NEED[$a]}:"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aF "SRE FAIL ${NEED[$a]}:" | head -1 | cut -c1-120))"
        elif printf '%s\n' "$out" | grep -aq "^SESSION_ENV RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS OWN CHECK (${NEED[$a]}): $(printf '%s\n' "$out" | grep -a 'SRE FAIL' | head -1 | cut -c1-110)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "SESSION_ENV ARMS RESULT PASS" || echo "SESSION_ENV ARMS RESULT FAIL"
    exit "$rc"
fi

for t in kitty wtype python3 less tail; do
    command -v "$t" > /dev/null 2>&1 || { echo "SESSION_ENV RESULT FAIL (missing tool: $t)"; exit 1; }
done

W=$(mktemp -d "${SCRATCH:-/tmp}/sre.XXXXXX")
export LOCK_ENV="${LOCK_ENV:-sre$((RANDOM % 9000 + 1000))}"     # 12 characters at most (the nested socket path)
LOG="$W/run.log"
T="$W/tree"
mkdir -p "$T/tools/dev/fixtures" "$W/home" "$W/work"
cp -r tools/session tools/lib "$T/tools/"
cp tools/dev/session_env_probe.py "$T/tools/dev/"
cp -r tools/dev/fixtures/session "$T/tools/dev/fixtures/"

arm() {  # arm <file> <python expr over s that returns the patched text>   (exact anchors; a lost one fails the run)
    python3 - "$T/$1" "$2" "$3" <<'PY' || { echo "ARM ${ARM}: anchor is gone in $1"; echo "SESSION_ENV RESULT FAIL (arm)"; rm -rf "$W"; exit 1; }
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
    nogroup)  arm tools/session/sessionlib/restore.py '        for g in self.plan["groups"]:' '        for g in []:' ;;
    nomove)   arm tools/session/sessionlib/restore.py '            if not here:' '            if False:' ;;
    nostage)  arm tools/session/sessionlib/plan.py '        rule = {"workspace": ws_rule(first["workspace"]) if slow else stage_name(first["workspace"]) + " silent",' '        rule = {"workspace": ws_rule(first["workspace"]),' ;;
    nolock)   arm tools/session/sessionlib/restore.py '            if g.get("locked"):' '            if False:' ;;
    heldrerun) arm tools/session/sessionlib/plan.py '    if term.get("shell") and "--hold" in opts:' '    if False:' ;;
    runtyped) arm tools/session/sessionlib/classify.py '    if verdict is None:
        out["mode"] = "run"' '    if True:
        out["mode"] = "run"' ;;
    notitle)  arm tools/session/sessionlib/restore.py '    scores = sorted(((title_score(s["title"], c.get("title")), si, ci)' '    scores = sorted(((-abs(si - ci), si, ci)' ;;
    chainwhole) arm tools/session/sessionlib/classify.py '    if not segs or len(segs) < 2:
        return None' '    if True:
        return None' ;;
    nomovereuse) arm tools/session/sessionlib/restore.py '            if not here:' '            if not here and wid not in self.reused:' ;;
    closesall) arm tools/session/sessionlib/plan.py '    closing = closable(live_snap, reuse, rules) if replace else []' '    closing = closable(live_snap, reuse, rules)' ;;
    noactive) arm tools/session/sessionlib/restore.py '            self._do("hl.dsp.group.active({ index = %d, window = %s })"' '            (lambda *a: None)("hl.dsp.group.active({ index = %d, window = %s })"' ;;
    *) echo "SESSION_ENV RESULT FAIL (unknown ARM ${ARM})"; rm -rf "$W"; exit 1 ;;
esac

cat > "$W/home/.bashrc" <<'RC'
[[ $- != *i* ]] && return
PS1='[\u@\h \W]\$ '
command -v starship > /dev/null 2>&1 && eval "$(starship init bash)"
alias lg='lazygit'
[ -f "$LARES_HOOK" ] && . "$LARES_HOOK"
RC

cleanup() {
    [ -n "${SESSION_ENV_KEEP:-}" ] && { echo "kept: $W (env $LOCK_ENV: KEEP=1 tools/dev/lock_env.sh down)"; return; }
    tools/dev/lock_env.sh down > /dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT

LOCKED_CMD=""
tools/dev/lock_env.sh up > "$W/up.log" 2>&1 || { cat "$W/up.log"; echo "SESSION_ENV RESULT FAIL (the env did not come up)"; exit 1; }
B=$(tools/dev/lock_env.sh dir)
mkdir -p "$B/cfg/kitty"
printf 'remember_window_size no\nconfirm_os_window_close 0\ninitial_window_width 900\ninitial_window_height 600\n' > "$B/cfg/kitty/kitty.conf"

run_driver() {
    # shellcheck disable=SC2086
    tools/dev/lock_env.sh run env HOME="$W/home" SRE_WORK="$W/work" $1 python3 "$T/tools/dev/session_env_probe.py" >> "$LOG" 2>&1
}
case "${MODE:-full}" in
    full) run_driver "" ;;
    half) run_driver "SRE_HALF=1" ;;
    locked) run_driver "SRE_LOCKED=1 SRE_LOCK_QML=$ROOT/tools/dev/lock_env/probes/lock_basic.qml" ;;
    preset) run_driver "SRE_PRESET=1" ;;
    *) echo "SESSION_ENV RESULT FAIL (unknown MODE)"; exit 1 ;;
esac

grep -a -E '^SRE (FAIL|restore)' "$LOG" | cut -c1-400
[ -n "${VERBOSE:-}" ] && cat "$LOG"
if ! rl_has "$LOG" '^SESSION_ENV RESULT '; then
    cp "$LOG" "${SCRATCH:-/tmp}/session_env_probe.last.log" 2> /dev/null
    tail -5 "$LOG" | sed 's/^/    /'
    rl_noresult SESSION_ENV "${SCRATCH:-/tmp}/session_env_probe.last.log"
    exit 1
fi
rl_result SESSION_ENV "$LOG"
rc=$?
[ "$rc" = 0 ] || cp "$LOG" "${SCRATCH:-/tmp}/session_env_probe.last.log" 2> /dev/null
exit "$rc"
}
