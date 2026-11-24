#!/usr/bin/env bash
# A SPOKEN LLM ask, end to end (post-deploy round 5, stream LLMVOICE; round 8: it runs SILENTLY in the background, one answer toast,
# approvals as toasts, the model released after it): LlmService.voiceAsk against a stub ollama (tools/dev/llm_voice_stub.py), on
# the real backend, store, tools, attention, machine (its CPU floor), bar glyph and the LlmBarOwner on a real GooeyEngine,
# headless, in its own sandbox. The steps and their checks are in tools/dev/qml/llm_voice_probe.qml (v1..v9); the allow-list
# itself is table-tested by tools/dev/llm_voice_cases.js.
#
#   tools/dev/llm_voice_probe.sh              last line: LLM-VOICE RESULT PASS|FAIL
#   ARM=<name> tools/dev/llm_voice_probe.sh   one fault armed in the SANDBOX copy; it must FAIL its own check
#   ARM=all tools/dev/llm_voice_probe.sh      every arm in turn (last line: LLM-VOICE ARM RESULT PASS|FAIL)
#
# THE ARMS, each patching the sandbox copy (never the tree), each watched red on its check's own name:
#   opens        a turn's start opens the chat on its conversation (the old show)  -> v1.still-no-popup
#   noreleasesilent  the model is never let go after a turn                        -> v1r.deadline (the unload never comes)
#   runwithoutclick  the approval toast answers Run by itself                       -> v3.waits-for-the-click
#   nodrop       an unanswered approval is never dropped                            -> v3d.deadline
#   notools      a spoken turn offers tools only with the wrench on               -> v1.tools-offered-wrench-off
#   nolist       voiceAsk leaves the model list to a popup                        -> v1.lists-the-models-itself
#   nocwd        the tools run in the home directory, not where it was asked      -> v1.in-the-repository
#   bash         an allowed spoken command still goes through bash -c             -> v1.as-an-argv
#   nocopy       a spoken answer is never copied                                  -> v1.copied
#   typedpolicy  a spoken turn is decided by the typed chat's policy              -> v6.stricter-than-typed
#   taint        a web search runs free after the turn read the machine           -> v4.search-asks-after-a-read
#   freeread     llm.jsonc's tools.ask changes nothing (a read that must ask runs) -> c1.reads-ask
#   spokenstays  a spoken ask keeps its model as a typed chat does                -> c4.deadline
#   noglobs      a spoken search runs without the secret-name globs (it reads .env) -> v8.never-opens-a-dotenv
#
# NOTHING REAL IS REACHED. HOME is a private directory (its ~/.ssh holds a fake key, so even an armed copy that runs
# `cat ~/.ssh/id_ed25519` reads nothing of the user's), XDG_CONFIG_HOME / STATE / CACHE are private, the stub directory leads
# PATH: wl-copy writes a log, notify-send writes a log, systemd-run says no (no scope in the user's manager), and python3
# refuses llm_tools/search.py and fetch.py (SEARXNG_URL points at a closed port besides). The only programs that run are git
# on the stub repository, the shipped llm_tools/ helpers and the coreutils the stub's commands name. No `timeout` around
# quickshell: $! is quickshell itself, the only pid this script kills (and the stub server's).
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
if [ -e .git ] && [ -z "${LLMV_INNER:-}" ]; then
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-llm-voice}"
    exec tools/dev/sandbox.sh LLMV_INNER=1 QT_QPA_PLATFORM=offscreen SANDBOX="$SANDBOX" ARM="${ARM:-}" \
        bash tools/dev/llm_voice_probe.sh
fi
ROOT=$(pwd)
OUT="${LLMV_OUT:-$ROOT-out}"
SVC="modules/bar/llm/components/LlmService.qml"
TOOLS="modules/bar/llm/components/LlmTools.qml"
POLICY="modules/bar/llm/components/LlmToolPolicy.js"
RESIDENCY="modules/bar/llm/components/LlmResidency.qml"
ATT="modules/bar/llm/components/LlmAttention.qml"
PROBE="tools/dev/qml/llm_voice_probe.qml"
ARMS_ALL="opens noreleasesilent runwithoutclick nodrop notools nolist nocwd bash nocopy typedpolicy taint noglobs freeread spokenstays"

ARMED_FILES="$SVC $TOOLS $RESIDENCY $ATT $POLICY"
unarm() { local f; for f in $ARMED_FILES; do cp "$OUT/$(basename "$f").bak" "$f"; done; }
arm() {  # file, count, from, to
    [ -e .git ] && { echo "ARM patches the sandbox copy only; run through tools/dev/sandbox.sh"; exit 2; }
    python3 - "$@" <<'PYARM' || { echo "ARM $ARM: anchor not found the expected number of times"; return 1; }
import sys
p, n, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(p, encoding="utf-8").read()
if s.count(a) != n:
    print("  found %d, want %d: %r" % (s.count(a), n, a[:70]))
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PYARM
    echo "ARMED $ARM in $(basename "$1")"
}
apply_arm() {
    case "$1" in
        opens)       arm "$ATT" 1 '        function onAnswerFailed(convId, message) { root._forget(convId); }' '        function onAnswerFailed(convId, message) { root._forget(convId); }
        function onTurnStarted(convId) { root.openConversation(convId); }' ;;
        noreleasesilent) arm "$RESIDENCY" 1 '        root.service.releaseModel();' '' ;;
        runwithoutclick) arm "$ATT" 1 '            onAction: id => root._askAction(req, id)
        });' '            onAction: id => root._askAction(req, id)
        });
        Qt.callLater(function () { root._askAction(req, "run"); });' ;;
        nodrop)      arm "$SVC" 1 '            _voiceDropTimer.restart();' '' ;;
        notools)     arm "$SVC" 1 'root._wantTools = (root.toolsEnabled || root._genHandsFree)' 'root._wantTools = (root.toolsEnabled)' ;;
        nolist)      arm "$SVC" 1 '        if (!root._modelDescribed(m) && root.backend.refreshModels) root.backend.refreshModels();' '' ;;
        nocwd)       arm "$TOOLS" 1 '        if (f.cwd) ctx.cwd = f.cwd;' '' ;;
        bash)        arm "$TOOLS" 1 '                argv = vc.argv;' '' ;;
        nocopy)      arm "$SVC" 1 '                copy = Voice.copyOf(text);' '                copy = null;' ;;
        typedpolicy) arm "$SVC" 1 '            facts.handsFree = true;' '            facts.handsFree = false;' ;;
        taint)       arm "$SVC" 1 '            facts.tainted = root._tainted(root._genConvId);' '            facts.tainted = false;' ;;
        noglobs)     arm "$TOOLS" 1 '                argv = argv.slice(0, at).concat(globs).concat(argv.slice(at));' '' ;;
        freeread)    arm "$POLICY" 1 'if (!names || names.indexOf(name) < 0 || out.mode === "refused") return out;' 'return out;' ;;
        spokenstays) arm "$RESIDENCY" 1 '            if (!root._spoken)
                root._typed = true;' '            root._typed = true;' ;;
        *) echo "unknown ARM=$1"; return 1 ;;
    esac
}
needle() {
    case "$1" in
        opens)       echo "FAIL v1.still-no-popup" ;;
        noreleasesilent) echo "FAIL v1r.deadline" ;;
        runwithoutclick) echo "FAIL v3.waits-for-the-click" ;;
        nodrop)      echo "FAIL v3d.deadline" ;;
        notools)     echo "FAIL v1.tools-offered-wrench-off" ;;
        nolist)      echo "FAIL v1.lists-the-models-itself" ;;
        nocwd)       echo "FAIL v1.in-the-repository" ;;
        bash)        echo "FAIL v1.as-an-argv" ;;
        nocopy)      echo "FAIL v1.copied" ;;
        typedpolicy) echo "FAIL v6.stricter-than-typed" ;;
        taint)       echo "FAIL v4.search-asks-after-a-read" ;;
        noglobs)     echo "FAIL v8.never-opens-a-dotenv" ;;
        freeread)    echo "FAIL c1.reads-ask" ;;
        spokenstays) echo "FAIL c4.deadline" ;;
    esac
}

stubs() {  # dir
    mkdir -p "$1"
    cat > "$1/wl-copy" <<'SH'
#!/usr/bin/env bash
printf '%s\twl-copy\t%s\n' "$(date +%s%3N)" "$*" >> "${LLMV_TOOL_LOG:?}"
cat >> "${LLMV_COPY_LOG:?}"
printf '\036' >> "${LLMV_COPY_LOG:?}"
SH
    cat > "$1/notify-send" <<'SH'
#!/usr/bin/env bash
printf '%s\tnotify-send\t%s\n' "$(date +%s%3N)" "$*" >> "${LLMV_TOOL_LOG:?}"
SH
    cat > "$1/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\tsystemd-run\t%s\n' "$(date +%s%3N)" "$*" >> "${LLMV_TOOL_LOG:?}"
exit 1
SH
    cat > "$1/python3" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        */search.py|*/fetch.py|llm_tools/search.py|llm_tools/fetch.py)
            printf '%s\tpython3-refused\t%s\n' "$(date +%s%3N)" "$*" >> "${LLMV_TOOL_LOG:?}"
            echo "the probe never reaches the network" >&2
            exit 3 ;;
    esac
done
exec /usr/bin/python3 "$@"
SH
    chmod +x "$1/"*
    for t in wl-copy notify-send systemd-run python3; do
        [ "$(PATH="$1:$PATH" command -v "$t")" = "$1/$t" ] || { echo "FAIL runner: $t is not the stub"; return 1; }
    done
}

repo() {  # dir -> prints the short hash `git log -1 --format=%h` gives there
    mkdir -p "$1"
    (
        cd "$1" || exit 1
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=stub GIT_AUTHOR_EMAIL=stub@example.invalid \
               GIT_COMMITTER_NAME=stub GIT_COMMITTER_EMAIL=stub@example.invalid \
               GIT_AUTHOR_DATE="2026-11-08T10:00:00" GIT_COMMITTER_DATE="2026-11-08T10:00:00"
        git -c init.defaultBranch=main init -q . && printf 'STUB-README: a project the probe made\n' > README.md && git add README.md \
            && git commit -q -m "first" && printf 'more\n' >> README.md && git commit -q -am "second" \
            && git log -1 --format=%h
        # beside the commits: a public note and a dotenv a spoken search must never open
        printf 'TODO public note\n' > todo.txt && printf 'TODO=secret-token-of-the-probe\n' > .env
    )
}

run_once() {  # -> $OUT/main.log; RUN_FAIL
    RUN_FAIL=0
    rm -rf "$OUT/state" "$OUT/cache" "$OUT/repo" "$OUT/home"
    mkdir -p "$OUT/state" "$OUT/cache" "$OUT/home/.ssh"
    printf 'FAKE-KEY the probe made\n' > "$OUT/home/.ssh/id_ed25519"
    : > "$OUT/reqs.jsonl"; : > "$OUT/copies.log"; : > "$OUT/tools.log"
    local hash
    hash=$(repo "$OUT/repo") || { echo "FAIL runner: the stub repository"; RUN_FAIL=1; return; }
    python3 -u tools/dev/llm_voice_stub.py "$OUT/reqs.jsonl" > "$OUT/stub.out" 2>&1 &
    local spid=$! port=""
    for _ in $(seq 1 50); do
        port=$(sed -n 's/^LISTEN \([0-9]*\)$/\1/p' "$OUT/stub.out" | head -1)
        [ -n "$port" ] && break
        sleep 0.1
    done
    [ -n "$port" ] || { echo "FAIL runner: the stub server did not listen"; kill "$spid" 2>/dev/null; RUN_FAIL=1; return; }
    env -u WAYLAND_DISPLAY \
        HOME="$OUT/home" PATH="$OUT/stub:$PATH" LLMV=1 LLMV_STUB_DIR="$OUT/stub" \
        LLMV_URL="http://127.0.0.1:$port" LLMV_REPO="$OUT/repo" LLMV_HASH="$hash" \
        LLMV_REQ_LOG="$OUT/reqs.jsonl" LLMV_COPY_LOG="$OUT/copies.log" LLMV_TOOL_LOG="$OUT/tools.log" \
        SEARXNG_URL="http://127.0.0.1:9" \
        XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        quickshell -p "$PROBE" > "$OUT/main.log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 960); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    if kill -0 "$pid" 2>/dev/null; then
        echo "FAIL runner: the probe is still running after 240 s, killing $pid"
        kill "$pid" 2>/dev/null; sleep 0.5; kill -9 "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
    local log
    log=$(rl_clean "$OUT/main.log" | sed 's/^ *DEBUG qml: //; s/^ *INFO qml: //')
    printf '%s\n' "$log" | grep -a -E "^  (ok  |FAIL) |^STEP |^checks "
    printf '%s\n' "$log" | grep -a -q "^LLM-VOICE RESULT PASS" || RUN_FAIL=1
    # What the runner can see from outside: the refused command did not run, nothing reached a network tool.
    # `touch notes.txt` was asked four times and clicked Run once (v3c): the file is there only because of that one click
    if [ -e "$OUT/repo/notes.txt" ]; then echo "  ok   runner.touch-ran-by-the-click-only"; else echo "FAIL runner.touch-never-ran: the Run click made no notes.txt"; RUN_FAIL=1; fi
    if grep -a -q "python3-refused" "$OUT/tools.log"; then echo "  NOTE a network tool was refused by the stub: $(grep -a python3-refused "$OUT/tools.log" | head -1 | cut -f3 | cut -c1-80)"; fi
    local w
    w=$(rl_clean "$OUT/main.log" | rl_platform_noise \
        | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|ReferenceError|TypeError|is not defined|is not a function" \
        | grep -a -v -E "WAYLAND_DISPLAY|WARNING ---|actually running|window masks|quickshell.tooling|no user systemd scope" | sort | uniq -c)
    if [ -n "$w" ]; then echo "FAIL warnings:"; printf '%s\n' "$w" | sed 's/^/    /' | head -20; RUN_FAIL=1; fi
}

# ---- go ----------------------------------------------------------------------------
rm -rf "$OUT"
mkdir -p "$OUT/cfg/theme"
printf '{"theme":"eva","mode":"light"}\n' > "$OUT/cfg/theme/state.json"
stubs "$OUT/stub" || { echo "LLM-VOICE RESULT FAIL (runner)"; exit 1; }

if [ -n "${ARM:-}" ]; then
    arms="$ARM"
    [ "$ARM" = all ] && arms="$ARMS_ALL"
    good=1
    for a in $arms; do
        for f in $ARMED_FILES; do cp "$f" "$OUT/$(basename "$f").bak"; done
        ARM="$a"
        if ! apply_arm "$a"; then good=0; unarm; continue; fi
        run_once > "$OUT/arm_$a.out" 2>&1
        unarm
        text=$(needle "$a")
        if ! rl_has "$OUT/main.log" "LLM-VOICE RESULT "; then
            echo "ARM $a: the armed copy did not load -- it proves nothing"
            rl_noresult LLM-VOICE "$OUT/main.log"
            good=0
        elif grep -a -q -F "$text" "$OUT/arm_$a.out"; then
            grep -a -F "$text" "$OUT/arm_$a.out" | head -1 | cut -c1-200 | sed 's/^/    /'
            echo "ARM $a: FAIL on \"${text#FAIL }\", as it must"
        else
            echo "ARM $a: DID NOT FAIL \"${text#FAIL }\":"
            sed 's/^/    /' "$OUT/arm_$a.out" | grep -a -E "FAIL|STEP" | head -12
            good=0
        fi
    done
    if [ "$good" = 1 ]; then echo "LLM-VOICE ARM RESULT PASS"; exit 0; fi
    echo "LLM-VOICE ARM RESULT FAIL"
    exit 1
fi

run_once
if ! rl_has "$OUT/main.log" "LLM-VOICE RESULT "; then
    rl_noresult LLM-VOICE "$OUT/main.log"
    exit 1
fi
if [ "$RUN_FAIL" -eq 0 ]; then
    echo "LLM-VOICE RESULT PASS"
else
    echo "LLM-VOICE RESULT FAIL (log $OUT/main.log)"
fi
exit "$RUN_FAIL"
