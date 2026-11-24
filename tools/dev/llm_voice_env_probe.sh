#!/usr/bin/env bash
# A spoken ask in the REAL shell: shell.qml (SHELL_SERVICES=mock) in the isolated nested Hyprland of tools/dev/lock_env.sh, and
# the compositor's own word on the keyboard (post-deploy round 5, stream LLMVOICE; round 8: a spoken ask runs SILENTLY, it opens
# no popup -- the per-ask toasts, the glyph, the approvals and the release are proven by tools/dev/llm_voice_probe.sh).
#
#   tools/dev/llm_voice_env_probe.sh              last line: LLM-VOICE-ENV RESULT PASS|FAIL
#   ARM=opens tools/dev/llm_voice_env_probe.sh    a turn's start opens the chat on its conversation (the old show): e2 / e3 must fail
#
# The sandbox copy's modules/shell/ShellMain.qml (shell.qml's body) gets three probe hooks (the `hook` verb answers on a MOCK shell only): `voiceask <text>` calls
# services.llm.service.voiceAsk(text, { windowClass, windowTitle, cwd: "" }) as the dictation's ask key will and answers the
# service's ACTIVE conversation afterwards, `llmactive` answers that id, and `llmtoggle` the focused screen's chat owner's
# toggle() (the click's path), the control that shows the measurement can see a keyboard.
#   e0 at rest        no popup: the lares-bar surface asks for no keyboard
#   e1 control        the chat opened by its button's path: the compositor's lares-bar keyboard_interactivity is not 0
#   e2 spoken         voiceask with the chat shut: no popup is up for the whole of the ask (the mock model answers in it), the
#                     compositor's lares-bar keyboard_interactivity reads 0 (none) all the while, and no conversation became the active one
#   e3 open chat      voiceask with the chat open: the popup stays up on the conversation it showed
# Everything is read from the shell's IPC (`shell probe`) and from Hyprland's Lua API (hl.get_layers()), nothing on the
# user's desktop: the compositor, its bus, its runtime dir and the XDG homes are lock_env's; the copy is a sandbox's.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. "$ROOT/tools/dev/result_lib.sh"
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-llmvenv}"
SANDBOX="${SANDBOX:-${SCRATCH:-/tmp}/lares-sandbox-llmvenv}"
SCR="${SCRATCH:-/tmp}/llmvenv-$LOCK_ENV"
SPID=""; _cleaned=0; _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX" "$SANDBOX.lrrt"
    [ "$_ok" = 1 ] && rm -rf "$SCR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
rm -rf "$SCR"; mkdir -p "$SCR"
SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "LLM-VOICE-ENV RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
python3 tools/dev/shell_tripwires.py "$SB" || { echo "LLM-VOICE-ENV RESULT FAIL (the tripwires did not go in)"; exit 1; }
python3 - "$SB/modules/shell/ShellMain.qml" "${ARM:-}" "$SB/modules/bar/llm/components/LlmAttention.qml" <<'PY' || { echo "LLM-VOICE-ENV RESULT FAIL (the hooks did not go in)"; exit 1; }
import sys
p, arm, owner = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
a = '            case "secret":'
if s.count(a) != 1:
    print("hook anchor: found %d" % s.count(a)); sys.exit(1)
s = s.replace(a, '''            case "voiceask":
                shellServices.llm.service.voiceAsk(arg, { windowClass: "kitty", windowTitle: "env probe", cwd: "" });
                return shellServices.llm.service.activeId;
            case "llmactive":
                return shellServices.llm.service.activeId;
            case "llmtoggle": {
                const o = shellServices.focusedOwner("llm");
                if (o)
                    o.toggle();
                return o ? "1" : "0";
            }
''' + a)
open(p, "w", encoding="utf-8").write(s)
if arm == "opens":
    t = open(owner, encoding="utf-8").read()
    b = "        function onAnswerFailed(convId, message) { root._forget(convId); }"
    if t.count(b) != 1:
        print("ARM anchor: found %d" % t.count(b)); sys.exit(1)
    open(owner, "w", encoding="utf-8").write(t.replace(b, b + "\n        function onTurnStarted(convId) { root.openConversation(convId); }"))
    print("ARMED opens")
PY

"$E" down > /dev/null 2>&1
OUTPUTS=1 "$E" up > /dev/null || { echo "LLM-VOICE-ENV RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
SLOG="$SCR/shell.log"
"$E" run env SHELL_SERVICES=mock QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do
    grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
if ! grep -aq "LARES settled" "$SLOG"; then
    # an armed copy that never loaded failed for the wrong reason and proves nothing: say so (the verdict follows, as for any run)
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($SLOG)"
    rl_noresult LLM-VOICE-ENV "$SLOG"; exit 1
fi

ipc() { "$E" run quickshell ipc -p "$SB/shell.qml" call shell "$@" 2>/dev/null; }
inter() {  # the lares-bar surfaces' keyboard_interactivity, "out=n,..." (0 none, 1 exclusive, 2 on demand)
    "$E" hyprctl eval 'local t = {} for _, l in ipairs(hl.get_layers()) do if l.namespace == "lares-bar" then '\
't[#t+1] = tostring(l.monitor):match(":(.-)%)") .. "=" .. tostring(l.keyboard_interactivity) end end '\
'error("INTERACT " .. table.concat(t, ","))' 2>&1 | sed -n 's/.*INTERACT \([^"]*\).*/\1/p' | head -1
}
llm_state() {  # "<open> <owner> <released>" of the screen whose popup is the chat, or "0 - -"
    ipc probe | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("? ? ?"); sys.exit(0)
for s in (d.get("screens") or {}).values() if isinstance(d.get("screens"), dict) else (d.get("screens") or []):
    p = s.get("popup") or {}
    if p.get("owner") == "llm" and p.get("open"):
        print("1 llm %d" % (1 if (s.get("keys") or {}).get("released") else 0)); sys.exit(0)
print("0 - -")'
}
fails=0
say() {  # name ok detail
    if [ "$2" = 1 ]; then echo "    ok   $1   $3"; else echo "    FAIL $1   $3"; fails=$((fails + 1)); fi
}
nonzero() { printf '%s' "$1" | grep -q '=[12]'; }

# e0 -- at rest
i0=$(inter)
[ -n "$i0" ] && ! nonzero "$i0" && say e0.at-rest 1 "lares-bar keyboard $i0" || say e0.at-rest 0 "lares-bar keyboard '$i0'"

# e1 -- the control: the chat opened by its button's path asks for a keyboard, and the compositor shows it
ipc hook llmtoggle "" > /dev/null
seen=""
for _ in $(seq 1 20); do
    st=$(llm_state); i1=$(inter)
    if [ "${st%% *}" = 1 ] && nonzero "$i1"; then seen="$i1"; break; fi
    sleep 0.25
done
[ -n "$seen" ] && say e1.control-sees-a-keyboard 1 "chat by its toggle: lares-bar keyboard $seen" \
                || say e1.control-sees-a-keyboard 0 "state '$(llm_state)', lares-bar keyboard '$(inter)'"
ipc hook llmtoggle "" > /dev/null
for _ in $(seq 1 20); do [ "$(llm_state | cut -d' ' -f1)" = 0 ] && break; sleep 0.25; done
sleep 1

# e2 -- the spoken ask with the chat shut: nothing opens, for as long as the mock model takes to answer it (and past)
cid=$(ipc hook voiceask "explain what a commit is" | tr -d '"')
opened=0; bad=""; samples=0
for _ in $(seq 1 28); do
    st=$(llm_state)
    [ "${st%% *}" = 1 ] && opened=1
    i=$(inter); samples=$((samples + 1))
    nonzero "$i" && bad="$bad $i"
    [ -z "$i" ] && bad="$bad (no answer)"
    sleep 0.25
done
say e2.no-popup-opens $([ "$opened" = 0 ] && echo 1 || echo 0) "chat open at any of $samples samples over 7 s: $opened"
say e2.no-conversation-made-active $([ -z "$cid" ] && echo 1 || echo 0) "active conversation after the ask: '$cid'"
[ -z "$bad" ] && say e3.compositor-keyless 1 "lares-bar keyboard 0 in all $samples samples over 7 s" \
              || say e3.compositor-keyless 0 "non-zero samples:$bad"

# e4 -- the chat is open on a conversation of its own: a spoken ask leaves it there
ipc hook llmtoggle "" > /dev/null
for _ in $(seq 1 20); do [ "$(llm_state | cut -d' ' -f1)" = 1 ] && break; sleep 0.25; done
a0=$(ipc hook llmactive "" | tr -d '"')
a1=$(ipc hook voiceask "explain what a push is" | tr -d '"')
still=1
for _ in $(seq 1 24); do [ "$(llm_state | cut -d' ' -f1)" = 1 ] || still=0; sleep 0.25; done
a2=$(ipc hook llmactive "" | tr -d '"')
say e4.open-chat-keeps-its-conversation $([ "$a1" = "$a0" ] && [ "$a2" = "$a0" ] && [ "$still" = 1 ] && echo 1 || echo 0) "chat '$a0', after the ask '$a1' / '$a2', popup stayed up: $still"
kill -0 "$SPID" 2> /dev/null || { say shell.alive 0 "the shell died (see $SLOG)"; }
warns=$(rl_clean "$SLOG" | rl_platform_noise | grep -aE "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property" \
    | grep -avE "quickshell.tooling|--- WARNING ---|actually running wayland|does not support setting window masks|Failed to register with host portal|Could not load icon \"(nm-signal-50|internet-chat|blueman-disabled)\"")
if [ -n "$warns" ] && [ -z "${ARM:-}" ]; then say shell.warnings 0 "$(printf '%s' "$warns" | head -3 | tr '\n' '|')"; fi
trips=$(rl_clean "$SLOG" | grep -a "TRIPWIRE" | head -3)
[ -n "$trips" ] && say shell.tripwires 0 "a mock built a real service: $trips"

if [ "$fails" = 0 ]; then _ok=1; echo "LLM-VOICE-ENV RESULT PASS"; exit 0; fi
echo "LLM-VOICE-ENV RESULT FAIL (log $SLOG)"
exit 1
