#!/usr/bin/env bash
# dictation_probe_shell.sh -- dictation into the shell's OWN fields in the real shell (round 6, the user's case of 2026-11-09: a take
# into the notes popup, opened over VS Code, went to the clipboard): shell.qml on its mock services in the isolated nested Hyprland
# of tools/dev/lock_env.sh, with the dictation live on the stand-in speech helper (tools/dev/dictation_probe_helper.py: the words
# "W0 w1." and "W2.", no model, no audio) and the REAL lares-ime built from the copy, over a stand-in app whose text field is enabled
# (tools/dev/dictation_probe_ticlient.c: it prints every preedit and commit it is sent).
#
#   tools/dev/dictation_probe_shell.sh                       DICTSHELL RESULT PASS | FAIL
#   ARM=noshelltarget tools/dev/dictation_probe_shell.sh     the press never looks for the shell's field: "DS FAIL N route" must show
#   ARM=richinsert tools/dev/dictation_probe_shell.sh        round 8: the notes editor puts the preedit in as it did (rich-text `insert`,
#                                                            the leading space dropped): "DS FAIL N.samples" must show
#
#   N  the notes popup opened BY KEY (Alt+N's global) on a note, over the app: the take's route is `shell`, its words land in the
#      note at the caret, the app under the popup gets no preedit and no commit; and (round 8) the live words AS THE NOTE'S LINE SHOWS
#      THEM, sampled after every partial: no word twice in any sample (the user's "duplicated while I speak")
#   L  the LLM chat (its button's path) with the pointer in it: the words land in the prompt (the draft), the app gets nothing
#   A  an AuraEvents ask during a take answers that the take holds the aura, and the take's aura keeps its 10 min life
#
# Probe hooks go into the sandbox copy's modules/shell/ShellMain.qml (shell.qml's body) (`dictstate`, `notesopen`, `llmtoggle`, `auraask`: answered on a MOCK shell only),
# and the copy's ShellServices builds the dictation live on the stand-ins (never the machine's helper, mic or clipboard).
# DICTSHELL_OVERLAY=<rev> lays <rev>'s modules/notes and Markdown files over the copy first: a developer's way to run N before the
# notes side of the contract is merged (the result line says so; never the verdict).
set -u
# ONE BRACE GROUP: bash reads a script from disk as it runs, and a held run (DICTSHELL_HOLD) outlives edits to this file
{
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. tools/dev/result_lib.sh
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-dictshell}"
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-dictshell}"
D="$(mktemp -d "${SCRATCH:-/tmp}/dictshell.XXXXXX")"
SPID="" TPID="" _cleaned=0 _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    [ -n "$TPID" ] && kill "$TPID" 2> /dev/null
    KEEP= "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX" "$SANDBOX.lrrt"
    [ "$_ok" = 1 ] && [ -z "${DICTSHELL_KEEP:-}" ] && rm -rf "$D"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "DICTSHELL RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
if [ -n "${DICTSHELL_OVERLAY:-}" ]; then
    git archive "$DICTSHELL_OVERLAY" modules/notes modules/common/components/Markdown.js modules/common/components/LiveMarkdown.js \
        | tar -x -C "$SB" || { echo "DICTSHELL RESULT FAIL (the overlay of $DICTSHELL_OVERLAY did not unpack)"; exit 1; }
fi
mkdir -p "$D/bin"
printf '#!/bin/sh\ncat > "$1"\n' > "$D/bin/wl-copy-stub"; chmod +x "$D/bin/wl-copy-stub"
printf '{"default":"normal"}\n' > "$D/ctl.json"
python3 - "$SB" "$D" "${ARM:-}" <<'PY' || { echo "DICTSHELL RESULT FAIL (the hooks did not go in)"; exit 1; }
import sys
sb, d, arm = sys.argv[1:4]
def patch(path, pairs):
    p = sb + "/" + path
    s = open(p, encoding="utf-8").read()
    for a, b in pairs:
        if s.count(a) != 1:
            print("anchor in %s found %d times: %s" % (path, s.count(a), a.splitlines()[0][:80])); sys.exit(1)
        s = s.replace(a, b)
    open(p, "w", encoding="utf-8").write(s)
patch("modules/shell/ShellMain.qml", [('            case "secret":', '''            case "dictstate": {
                const dc = shellServices.dictation;
                const tg = shellServices.dictationTarget;
                const ns = shellServices.notes;
                let noteText = "";
                try {
                    const rec = ns._docs[ns.noteKey];
                    noteText = rec ? rec.doc.text() : "";
                } catch (e) {
                    noteText = "";
                }
                const ls = shellServices.llm ? shellServices.llm.service : null;
                return JSON.stringify({ state: dc.state, route: dc.route, n: dc.log.length, log: dc.log.slice(-60),
                                        target: tg ? String(tg) : "", noteView: ns.view, noteText: noteText,
                                        draft: ls ? ls.draftOf(ls.activeId) : "", holds: dc.holdsAura, samples: root.rowSamples });
            }
            case "notesopen":
                return shellServices.notes.openNote(arg) ? "1" : "0";
            case "llmtoggle": {
                const o = shellServices.focusedOwner("llm");
                if (o)
                    o.toggle();
                return o ? "1" : "0";
            }
            case "auraask": {
                auraProbe._ask("probe", "siri", "all");
                const pl = auraProbe.plays;
                let life = -1;
                for (const nm in shellServices.frames)
                    life = Math.max(life, shellServices.frames[nm].engine._auraLife);
                return JSON.stringify({ answer: pl.length ? pl[pl.length - 1].answer : "", life: life });
            }
''' + '            case "secret":')])
# the AuraEvents the shell builds, reached by the hook (its id is ShellServices'): an alias on the services
patch("modules/shell/ShellServices.qml", [
    ("    readonly property alias dictation: dictationItem\n",
     "    readonly property alias dictation: dictationItem\n    readonly property alias auraEventsProbe: auraEventsItem\n"),
    ("""        id: dictationItem
        live: services.live
        rawConfig: shellConfigItem.dictation""",
     """        id: dictationItem
        live: true
        rawConfig: ({ enabled: true })
        pythonPath: "/usr/bin/python3"
        helperScript: "%s/tools/dev/dictation_probe_helper.py"
        imePath: "%s/lares-ime"
        copyCommand: ["%s/bin/wl-copy-stub", "%s/clipboard.txt"]""" % (sb, d, d, d)),
    ("        pipewire: services.pipewire\n        playAura:", "        pipewire: null\n        playAura:"),
])
p = sb + "/modules/shell/ShellMain.qml"
s = open(p, encoding="utf-8").read()
a = "    function hook(name: string, arg: string): string {\n"
if s.count(a) != 1:
    print("hook() anchor gone"); sys.exit(1)
rec = """    // the live words as the note's caret line SHOWS them, after every partial (round 8: no word twice in any sample)
    property var rowSamples: []
    property var editorIn: it => {
        if (!it)
            return null;
        if (it.viewport !== undefined && it.insertImageLine !== undefined)
            return it;
        for (let i = 0; i < it.children.length; i++) {
            const r = root.editorIn(it.children[i]);
            if (r)
                return r;
        }
        return null;
    }
    property var sampleRow: live => {
        const tg = shellServices.dictationTarget;
        const ed = tg ? root.editorIn(tg) : null;
        const row = ed && ed.doc ? ed.viewport.delegateFor(ed.doc.caret.line) : null;
        if (row && row.edit)
            root.rowSamples = root.rowSamples.concat([{ live: live, row: row.edit.getText(0, row.edit.length).replace(/\\u00a0/g, " ") }]).slice(-200);
    }
    property Connections rowRec: Connections {
        target: shellServices.dictation
        function onLiveTextChanged() {
            const t = shellServices.dictation.liveText;
            Qt.callLater(() => root.sampleRow(t));
        }
    }
"""
r0 = "    property bool _startTold: false\n"
if s.count(r0) != 1:
    print("ShellMain anchor gone"); sys.exit(1)
s = s.replace(r0, r0 + "\n" + rec, 1)
open(p, "w", encoding="utf-8").write(s.replace(a, "    readonly property var auraProbe: shellServices.auraEventsProbe\n" + a))
if arm == "richinsert":
    patch("modules/notes/LiveMarkdownEditor.qml", [("        te.insert(col, te.textFormat === TextEdit.RichText ? ed._preeditHtml(t) : t);", "        te.insert(col, t);")])
    print("ARMED richinsert")
if arm == "noshelltarget":
    patch("modules/dictation/DictationService.qml", [("            if (!root._shellCheck()) {", "            if (true) {")])
    print("ARMED noshelltarget")
PY
grep -q 'auraProbe: shellServices' "$SB/modules/shell/ShellMain.qml" || { echo "DICTSHELL RESULT FAIL (the hooks did not go in)"; exit 1; }
# the real lares-ime from the copy, and the stand-in app
(cd "$SB" && tools/stt/ime/build.sh "$D/lares-ime") > "$D/ime-build.log" 2>&1 || { cat "$D/ime-build.log"; echo "DICTSHELL RESULT FAIL (lares-ime did not build)"; exit 1; }
G_="$D/gen"; mkdir -p "$G_"
for x in stable/xdg-shell/xdg-shell unstable/text-input/text-input-unstable-v3; do
    wayland-scanner client-header "/usr/share/wayland-protocols/$x.xml" "$G_/${x##*/}-client-protocol.h" \
        && wayland-scanner private-code "/usr/share/wayland-protocols/$x.xml" "$G_/${x##*/}-protocol.c"
done
# shellcheck disable=SC2046
gcc -O2 -Wall -o "$D/ticlient" -I "$G_" tools/dev/dictation_probe_ticlient.c "$G_"/*-protocol.c $(pkg-config --cflags --libs wayland-client) > "$D/tic-build.log" 2>&1 \
    || { cat "$D/tic-build.log"; echo "DICTSHELL RESULT FAIL (the stand-in app did not build)"; exit 1; }

"$E" down > /dev/null 2>&1
OUTPUTS=1 "$E" up > "$D/up.log" 2>&1 || { tail -5 "$D/up.log"; echo "DICTSHELL RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
B="$("$E" dir)"
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
# the mock shell's home: a note to dictate into, and the aura on (A)
MH="$B/state/lares-shell-mock"
mkdir -p "$MH/notes" "$MH/config"
printf '# Probe\n\nWords\n' > "$MH/notes/probe.md"
printf '{ "shadow": { "aura": true } }\n' > "$MH/config/shell.jsonc"

# the stand-in app first: focused, its text field made and enabled (its stdin a FIFO this runner holds open: it ends on EOF)
mkfifo "$D/tic.in"
exec 7<> "$D/tic.in"
"$E" run "$D/ticlient" < "$D/tic.in" > "$D/tic.log" 2>&1 &
TPID=$!
for _ in $(seq 1 40); do grep -q 'ti-enter' "$D/tic.log" 2> /dev/null && break; sleep 0.25; done
grep -q 'ti-enter' "$D/tic.log" || { cat "$D/tic.log"; echo "DICTSHELL RESULT FAIL (the stand-in app's field was never entered)"; exit 1; }

SLOG="$D/shell.log"
"$E" run env SHELL_SERVICES=mock QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 DT_CTL="$D/ctl.json" DT_HELPERLOG="$D/helper.log" \
    quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do
    grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
if ! grep -aq "LARES settled" "$SLOG"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($SLOG)"
    DICTSHELL_KEEP=1; rl_noresult DICTSHELL "$SLOG"; exit 1
fi

ipc() { "$E" run quickshell ipc -p "$SB/shell.qml" call shell "$@" 2> /dev/null; }
global() { "$E" hyprctl dispatch "hl.dsp.global(\"lares:$1\")" > /dev/null; }
st() {  # a field of the dictation's state (python expression over `d`)
    ipc hook dictstate "" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if isinstance(d, str):
        d = json.loads(d)          # the hook answers a string: JSON in it
except Exception:
    d = {}
print(eval(sys.argv[1]))' "$1" 2> /dev/null
}
fails=0
say() {  # name ok detail
    if [ "$2" = 1 ]; then echo "DS ok $1: $3"; else echo "DS FAIL $1: $3"; fails=$((fails + 1)); fi
}
wait_for() {  # python expression over d, tries of 0.25 s
    local expr=$1 n=${2:-40}
    for _ in $(seq 1 "$n"); do [ "$(st "$expr")" = True ] && return 0; sleep 0.25; done
    return 1
}
tic_words() { grep -c -E '^(preedit|commit)	.' "$D/tic.log"; }
# one take: the press, its two sentences, the stop, the end; prints the log's routes of the take
take() {
    local n0
    n0=$(st 'd.get("n", 0)')
    global dictate
    wait_for "d.get('state') == 'listening' and sum(1 for e in d.get('log', [])[max([k for k, e in enumerate(d.get('log', [])) if e.get('ev') == 'press'] or [0]):] if e.get('ev') == 'seg') >= 2 and d.get('n', 0) != $n0" 40 \
        || echo "TAKE never listened with two sentences" >&2
    [ -n "${1:-}" ] && "$1"
    global dictate
    wait_for "d.get('state') == 'idle'" 40 || echo "TAKE never ended" >&2
}

# N -- the notes popup BY KEY over the app, then a note opened in it (the store scans only while a popup is up)
tic0=$(tic_words)
global notes
opened=0
for _ in $(seq 1 40); do [ "$(ipc hook notesopen probe.md | tr -d '"')" = 1 ] && { opened=1; break; }; sleep 0.25; done
[ "$opened" = 1 ] || say N.open 0 "the note did not open in the store"
if wait_for "'NotesPopup' in d.get('target', '')" 40; then
    say N.target 1 "the notes popup opened by key over the app; its editor has the caret ($(st 'd["target"][:40]'))"
else
    say N.target 0 "no shell target: target '$(st 'd.get("target")')', view $(st 'd.get("noteView")')"
fi
take
# the routes of the last take (the log's events since its last press)
ROUTES='",".join(e["route"] for e in d.get("log", [])[max([k for k, e in enumerate(d.get("log", [])) if e.get("ev") == "press"] or [0]):] if e.get("ev") == "route")'
routes=$(st "$ROUTES")
note=$(st 'd.get("noteText", "")' | tr '\n' '|')
N_ROUTE_FAILED=0
[ "$routes" = "shell" ] && say N.route 1 "routes $routes" || { say N.route 0 "routes '$routes' (the old route: the input method / the clipboard)"; N_ROUTE_FAILED=1; }
case "$note" in *"W0 w1. W2.# Probe"*) say N.words 1 "the note reads \"$note\"" ;; *) say N.words 0 "the note reads \"$note\"" ;; esac
# round 8: the live words as the line showed them (samples after each partial): the stand-in's tokens w<k> once each
samples=$(ipc hook dictstate "" | python3 -c '
import json, re, sys
d = json.loads(sys.stdin.read())
if isinstance(d, str):
    d = json.loads(d)
s = d.get("samples", [])
live = [x for x in s if x.get("live")]
dup = [x for x in live if len(re.findall(r"[Ww]\d+", x["row"])) != len(set(w.lower() for w in re.findall(r"[Ww]\d+", x["row"])))]
print("%d %d %s" % (len(live), len(dup), (dup[0]["row"][-60:] if dup else "")))' 2> /dev/null)
set -- $samples
if [ "${1:-0}" -ge 3 ] && [ "${2:-1}" = 0 ]; then say N.samples 1 "$1 live partials sampled in the note's line after each one: no word twice"
else say N.samples 0 "live partials ${1:-?}, with a word twice in ${2:-?}: '${3:-}...'"; N_ROUTE_FAILED=1; fi
[ "$(tic_words)" = "$tic0" ] && say N.app-untouched 1 "the app under the popup got no preedit and no commit" \
                              || say N.app-untouched 0 "the app got: $(grep -E '^(preedit|commit)' "$D/tic.log" | tail -3 | tr '\n' '|')"
global notes
wait_for "d.get('target', '') == ''" 20

# L -- the LLM chat, the pointer in it
tic0=$(tic_words)
ipc hook llmtoggle "" > /dev/null
box=$(ipc probe | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for s in (d.get("screens") or {}).values():
    p = s.get("popup") or {}
    if p.get("owner") == "llm" and p.get("box"):
        x, y, w, h = p["box"]; k = (s.get("scale") or {}).get("frame", 1) or 1
        print(round((x + w / 2) * k), round((y + h - 40) * k)); break' 2> /dev/null)
if [ -n "$box" ]; then
    # the pointer into the chat (its keyboard is on-demand: given on motion), in whole logical px over the one output's extent
    set -- $box
    ext=$("$E" hyprctl -j monitors | python3 -c 'import json, sys; m = json.load(sys.stdin)[0]; print(round(m["width"] / m["scale"]), round(m["height"] / m["scale"]))')
    "$E" point "abs $(($1 - 3)) $2 $ext" "sleep 80" "abs $1 $2 $ext"
fi
if wait_for "'LlmPopup' in d.get('target', '')" 40; then
    say L.target 1 "the chat's prompt has the caret ($(st 'd["target"][:40]'))"
else
    say L.target 0 "no shell target: target '$(st 'd.get("target")')' (the popup's centre at '$box')"
fi
aura_ask() { ipc hook auraask "" > "$D/aura.json"; }
take aura_ask
routes=$(st "$ROUTES")
draft=$(st 'd.get("draft", "")')
[ "$routes" = "shell" ] && say L.route 1 "routes $routes" || say L.route 0 "routes '$routes'"
case "$draft" in *"W0 w1. W2."*) say L.words 1 "the prompt reads \"$draft\"" ;; *) say L.words 0 "the prompt reads \"$draft\"" ;; esac
[ "$(tic_words)" = "$tic0" ] && say L.app-untouched 1 "the app got nothing" || say L.app-untouched 0 "the app got: $(grep -E '^(preedit|commit)' "$D/tic.log" | tail -3 | tr '\n' '|')"
aura=$(tr -d '\\' < "$D/aura.json" | sed 's/^"//; s/"$//')
case "$aura" in *'the dictation take holds the aura'*'"life":600000'*) say A.aura 1 "an event's ask during the take: $aura" ;;
                *) say A.aura 0 "an event's ask during the take: '$aura'" ;; esac

# a developer's hold: the env stays up for a hand at `quickshell ipc` (LOCK_ENV=dictshell tools/dev/lock_env.sh run quickshell ipc -p ...)
[ -z "${DICTSHELL_HOLD:-}" ] || { echo "DS HOLD $SB $D"; sleep "$DICTSHELL_HOLD"; }
warn=$(rl_clean "$SLOG" | grep -a -E 'Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | grep -a -i -E 'dictation|llm|notes|ShellServices' | head -3)
[ -z "$warn" ] || say warnings 0 "$warn"
if [ -n "${ARM:-}" ]; then
    _ok=1
    if [ "$N_ROUTE_FAILED" = 1 ]; then echo "ARM $ARM: failed as it must"; exit 0; fi
    echo "ARM $ARM: DID NOT FAIL on 'DS FAIL N.route' -- the probe cannot see it"; exit 1
fi
if [ "$fails" -eq 0 ]; then _ok=1; fi
res="DICTSHELL RESULT $([ "$fails" -eq 0 ] && echo PASS || echo "FAIL ($fails; $D)")"
[ -z "${DICTSHELL_OVERLAY:-}" ] || res="$res (DICTSHELL_OVERLAY=$DICTSHELL_OVERLAY: notes from another revision, not the probe's verdict)"
echo "$res"
[ "$fails" -eq 0 ] && [ -z "${DICTSHELL_OVERLAY:-}" ]
exit
}
