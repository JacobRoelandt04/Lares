#!/usr/bin/env bash
# session_service_probe.sh -- modules/session/SessionService.qml and the power reel's save step (docs/session.md), offscreen in a
# sandbox copy, on a STUB of tools/session/lares-session (it logs its argv and answers from the scenario's files). No compositor, no
# window is restored, no session is ended: the reel's command is run with `touch` in the place of the item's own.
#
#   tools/dev/session_service_probe.sh       SESSION_SERVICE RESULT PASS | FAIL
#   ARM=<name> ...   ARM=all ...             SESSION_SERVICE ARMS PASS | FAIL
#
# ARMs (each patches the sandbox copy; the check named must fail):
#   nolock      an ask is posted under the lock                      -> "crit: no toast under the lock"
#   noshown     an ask is posted before the frame is on the glass    -> "crit: no toast before the frame is on the glass"
#   watchfirst  the watcher starts before `begin` has answered       -> "crit: begin, then the watcher"
#   offbegins   the service begins while the feature is off          -> "off: no begin"
#   saveblocks  the save step has no deadline                        -> "save step: a hanging save does not keep the session"
#   noconfirm   a restore with nothing to tell ends in silence           -> "auto: nothing needs the user, one quiet confirmation ..."
#   alltold     resultToast is not read                                  -> "result toast:"
#   loudconfirm the plain confirmation stays as long as a needs-you one  -> "auto: nothing needs the user, one quiet confirmation ..."
#   progresslocked  the progress toast is posted under the lock      -> "auto: no progress toast under the lock"
#   progressstays   the progress toast is not taken away at the end  -> "crit: the progress toast goes with the result"
#   clicklate   the progress toast waits for the tool's first step   -> "crit: the click is answered at once ..."
#   latetell    the result is posted a turn after the progress goes  -> "crit: the result takes the progress toast's place ..."
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${SSP_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-session-service}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen SSP_INNER=1 ARM="${ARM:-}" bash tools/dev/session_service_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="SESSION_SERVICE"

arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

stub() {  # stub <dir> <enabled> <begin json> <restore json> [end mode]
    mkdir -p "$1"
    printf '{ "enabled": %s }\n' "$2" > "$1/session.jsonc"
    printf '%s\n' "$3" > "$1/begin.json"
    printf '%s\n' "$4" > "$1/restore.json"
    printf '%s\n' "${5:-ok}" > "$1/end.mode"
    cat > "$1/lares-session" <<'PY'
#!/usr/bin/env python3
import os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "begin":
    time.sleep(0.3)     # begin takes its time (it reads and freezes): a watcher that did not wait for it is in the log first
with open(os.path.join(d, "calls.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if cmd == "begin":
    print(open(os.path.join(d, "begin.json")).read().strip())
elif cmd in ("restore", "preset"):
    # the real tool's lines: a step at a time, the result's last
    for line in open(os.path.join(d, "restore.json")).read().strip().splitlines():
        time.sleep(0.15)
        print(line, flush=True)
elif cmd == "watch":
    print("watching", flush=True)
    time.sleep(600)
elif cmd == "end":
    mode = open(os.path.join(d, "end.mode")).read().strip()
    if mode == "hang":
        time.sleep(9)       # longer than the reel's deadline, shorter than the probe's patience
    sys.exit(1 if mode == "fail" else 0)
PY
    chmod +x "$1/lares-session"
}

run_once() {
    local tree log out rc S=modules/session/SessionService.qml R=modules/shell/ReelActions.qml
    tree=$(mktemp -d "$SCRATCH/ssp.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        nolock)     arm "$tree/$S" '    readonly property bool _ready: !root.locked && root.shown' '    readonly property bool _ready: root.shown' || return 3 ;;
        noshown)    arm "$tree/$S" '    readonly property bool _ready: !root.locked && root.shown' '    readonly property bool _ready: !root.locked' || return 3 ;;
        watchfirst) arm "$tree/$S" '        enabled: root.live && root.enabled && root._decision !== null' '        enabled: root.live && root.enabled' || return 3 ;;
        offbegins)  arm "$tree/$S" '        if (root._begun || !root.enabled)
            return;' '        if (root._begun)
            return;' || return 3 ;;
        saveblocks) arm "$tree/$R" 'return ["sh", "-c", "timeout -k 1 3 \"$0\" \"$1\" end \"$2\" > /dev/null 2>&1; shift 2; exec \"$@\"",' 'return ["sh", "-c", "\"$0\" \"$1\" end \"$2\" > /dev/null 2>&1; shift 2; exec \"$@\"",' || return 3 ;;
        progresslocked) arm "$tree/$S" '        if (!root._progress || root._phase !== "restoring" || !root._ready || !root.notifier)' '        if (!root._progress || root._phase !== "restoring" || !root.notifier)' || return 3 ;;
        clicklate)  arm "$tree/$S" '                root._postProgress();
            } else if (id === "discard") {' '            } else if (id === "discard") {' || return 3 ;;
        latetell)   arm "$tree/$S" '        root._postTell();
        if (root._progressUp && root.notifier)' '        if (root._progressUp && root.notifier)' || return 3 ;;
        progressstays) arm "$tree/$S" '        if (root._progressUp && root.notifier)
            root.notifier.withdraw("progress");' '' || return 3 ;;
        noconfirm)  arm "$tree/$S" '        root._tell = needs !== "" ? needs : root.confirmWords(r);' '        root._tell = needs;' || return 3 ;;
        alltold)    arm "$tree/$S" '        if (root.resultToast === "off" || (root.resultToast === "needs" && needs === ""))' '        if (false)' || return 3 ;;
        loudconfirm) arm "$tree/$S" '        root._tellMs = needs !== "" ? 12000 : 6000;' '        root._tellMs = 12000;' || return 3 ;;
        presetanswers) arm "$tree/$S" '        root._phaseAfter = root._phase === "asking" ? "asking" : "";' '        root._phaseAfter = "";' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/home" "$tree/work"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    local clean='{"restored": 8, "planned": 8, "skipped": [], "failed": [], "ran": 2, "typed": 0, "waiting": [], "unclaimed": 0}'
    local steps='{"event": "start", "total": 8}
{"event": "progress", "done": 3, "total": 8, "waiting": ["Zen Browser", "kitty"]}
{"event": "progress", "done": 7, "total": 8, "waiting": []}
{"event": "reveal"}'
    local needs="$steps"'
{"event": "result", "restored": 7, "planned": 8, "skipped": [], "failed": [{"name": "Postman", "why": "1 of 1 windows did not open in 30 s"}], "later": [{"name": "Windows", "workspace": "4"}], "ran": 1, "typed": 2, "waiting": [], "unclaimed": 0}'
    clean="$steps"'
'"$clean"
    stub "$tree/work/off"  false '{"decision": "auto"}' "$clean"
    stub "$tree/work/crit" true  '{"decision": "ask-critical", "cause": "Hyprland crashed at 14:02", "clean": false, "snapshot": "x", "summary": "8 windows: kitty x5, Code x2, Zen Browser"}' "$needs"
    stub "$tree/work/auto" true  '{"decision": "auto", "cause": "Logged out at 13:58", "clean": true, "snapshot": "x", "summary": "8 windows"}' "${clean%\}}, \"refocus\": true, \"event\": \"result\"}"
    stub "$tree/work/ask"  true  '{"decision": "ask", "cause": "Restarted at 13:58", "clean": true, "snapshot": "x", "summary": "8 windows"}' "$clean"
    stub "$tree/work/late" false '{"decision": "auto"}' "$clean"
    stub "$tree/work/hang" true  '{"decision": "none"}' "$clean" hang
    stub "$tree/work/preset" true '{"decision": "ask", "cause": "Logged out at 13:58", "clean": true, "snapshot": "x", "summary": "8 windows"}' "$steps"'
{"event": "result", "preset": "dev", "restored": 2, "planned": 8, "reused": 6, "closed": 1, "kept": [{"class": "kitty", "title": "nvim"}], "skipped": [], "failed": [], "ran": 0, "typed": 0, "waiting": [], "unclaimed": 0}'

    log="$tree/run.log"
    ( cd "$tree" && env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" HOME="$tree/home" SSP_WORK="$tree/work" \
        tools/dev/notifications_bus.sh timeout -k 2 90 quickshell -n -p tools/dev/qml/session_service_probe.qml > "$log" 2>&1 )
    # the stubs' `watch` children sleep under setpriv --pdeathsig: gone with the quickshell
    out=$(rl_result "$NAME" "$log" "SESSION_SERVICE RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "SSP .*FAIL" | head -6
    # a warning that names this module is a failure of its own (binding loops, undefined assignments)
    if rl_clean "$log" | grep -a -E "WARN|ERROR" | grep -a -E "SessionService|session_service_probe|ReelActions" | grep -v "the session watcher" | head -5 | grep -a .; then rc=1; fi
    if [ -e "$tree/work/logged-out" ]; then :; else echo "SSP the reel's command never ran (no logged-out file)"; rc=1; fi
    rl_isnoresult "$out" || rm -rf "$tree"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([nolock]="crit: no toast under the lock" [noshown]="crit: no toast before the frame is on the glass" [watchfirst]="crit: begin, then the watcher" [offbegins]="off: no begin" [saveblocks]="save step: a hanging save does not keep the session" [noconfirm]="auto: nothing needs the user, one quiet confirmation (told at the unlock, 6 s)" [loudconfirm]="auto: nothing needs the user, one quiet confirmation (told at the unlock, 6 s)" [progresslocked]="auto: no progress toast under the lock" [progressstays]="crit: the progress toast goes with the result" [clicklate]="crit: the click is answered at once, in the turn its ask goes" [latetell]="crit: the result takes the progress toast's place (posted, then the progress withdrawn)" [presetanswers]="preset: the login's ask is still answerable after the load" [alltold]='result toast: "needs" says only what needs the user, "off" nothing; confirmReplace false is read')
    for a in ${ONLY_ARMS:-nolock noshown watchfirst offbegins saveblocks noconfirm loudconfirm progresslocked progressstays latetell clicklate presetanswers alltold}; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif printf '%s\n' "$o" | grep -aqF "SSP ${NEED[$a]}: FAIL"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check (${NEED[$a]}): $(printf '%s\n' "$o" | grep -a 'SSP .*FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
}
