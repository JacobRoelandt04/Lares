#!/usr/bin/env bash
# dictation_probe_take.sh -- the shell's side of a dictation take (modules/dictation/DictationService.qml) against a helper that
# misbehaves on cue (round 6: a take must never get stuck; the shell's own fields take the words), offscreen, in seconds: the REAL
# service, tools/dev/dictation_probe_helper.py for the speech helper, a stand-in lares-ime written here, a stand-in shell field, a stub
# wl-copy (tools/dev/qml/dictation_probe_take.qml has the steps T1-T19). No compositor, no PipeWire, no model, never the user's files.
#
#   tools/dev/dictation_probe_take.sh              DICTTAKE RESULT PASS | FAIL
#   ARM=<name> tools/dev/dictation_probe_take.sh   a fault in the sandbox copy; must FAIL on its needle
#     noshelltarget  the press never looks for the shell's own field (before round 6: the input method / the clipboard) -> "T1 shell route"
#     nosettle       a change of the field is acted on at once, not settled (a caret's blink between two lines re-routes) -> "T2"
#     noimewait      a new take's input method does not wait for the last take's to go                -> "T8"
#     stoppingdeaf   a press while the take is stopping is ignored (before round 6)                    -> "T6 forced"
#     laterunning    a helper line of a take that has ended is read (its late `running` plays the aura) -> "T6 late running"
#     nowatchdog     the stop's wait ends the take and leaves the silent helper as it is (before round 6) -> "T4"
#     notrace        a stall is not traced (the shell log says only that it stalled)                   -> "T4 report"
#     nostartwatch   a start the helper never answers is waited on for ever                           -> "T5"
#     warmrace       a keep-warm restart leaves the helper `ready` until it exits (a press in between writes into it) -> "T7"
#     noeol          the take log is appended to whatever its last byte is                            -> "T10"
#     logdrop        a take finished while the last record is written is not logged (before round 6) -> "T10"
#     nolistenwatch  round 8: the beat watch never ends a take whose helper went silent (only the stop's 6 s would)    -> "T13"
#     noloopwatch    round 8: a beat that says the helper's main loop is stuck is read and ignored                      -> "T14"
#     nofallbacktoast round 8: the helper's `fallback` (a GPU decode failed, the CPU took over) is not told in words     -> "T12"
#     startstays     a release while the take is starting does nothing (the take runs on with the key up)                -> "T17"
#     norelease      a press kept for the take that finishes starts one although the key is up again                    -> "T17 held"
#     noquiet        endAfterMin is not read                                                                            -> "T18"
#     unmutes        unmute off is not read                                                                             -> "T19 muted"
#     noexitwhy      round 8: a helper that ends mid-take is told with its bare exit code, no cause                      -> "T16"
#
# The shell log is checked here too: a stall's report names it, carries the helper's threads (its `trace`) and, once
# the helper's last stderr lines (SupervisedStream's `errorLine`). Runs in a sandbox copy (tools/dev/sandbox.sh), offscreen, with private XDG dirs.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/dicttake.XXXXXX")"
export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-dicttake}"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT

S=modules/dictation/DictationService.qml
NEEDLE=""
case "${ARM:-}" in
    "") ;;
    noshelltarget) NEEDLE='DT FAIL T1 shell route' ;;
    nosettle)      NEEDLE='DT FAIL T2' ;;
    noimewait)     NEEDLE='DT FAIL T8' ;;
    stoppingdeaf)  NEEDLE='DT FAIL T6 forced' ;;
    laterunning)   NEEDLE='DT FAIL T6 late running' ;;
    nowatchdog)    NEEDLE='DT FAIL T4' ;;
    notrace)       NEEDLE='DT FAIL T4 report' ;;
    nostartwatch)  NEEDLE='DT FAIL T5' ;;
    warmrace)      NEEDLE='DT FAIL T7' ;;
    noeol)         NEEDLE='DT FAIL T10' ;;
    logdrop)       NEEDLE='DT FAIL T10' ;;
    nolistenwatch) NEEDLE='DT FAIL T13' ;;
    noloopwatch)   NEEDLE='DT FAIL T14' ;;
    nofallbacktoast) NEEDLE='DT FAIL T12' ;;
    noexitwhy)     NEEDLE='DT FAIL T16' ;;
    startstays)    NEEDLE='DT FAIL T17' ;;
    norelease)     NEEDLE='DT FAIL T17 held' ;;
    noquiet)       NEEDLE='DT FAIL T18' ;;
    unmutes)       NEEDLE='DT FAIL T19 muted' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

mkdir -p "$D/state/dictation" "$D/config/theme" "$D/cache" "$D/bin"
printf '{"theme":"eva","mode":"light"}\n' > "$D/config/theme/state.json"
# a take log whose last record has no newline after it (what someone's editor left on 2026-11-08)
printf '{"at":"2026-11-08T00:00:00Z","take":0,"reason":"seeded"}' > "$D/state/dictation/takes.jsonl"
printf '{"default":"normal"}\n' > "$D/ctl.json"
: > "$D/ime.log"; : > "$D/helper.log"
printf '#!/bin/sh\ncat > "$1"\n' > "$D/bin/wl-copy-stub"
# the stand-in lares-ime: `ready`, an `activate` 50 ms later, every line it is sent logged, a `quit` (or the EOF) answered 0.8 s late
cat > "$D/bin/lares-ime" <<'IME_EOF'
#!/bin/bash
echo "$$ up" >> "$DT_IMELOG"
printf 'ready\t2\n'
sleep 0.05
printf 'activate\n'
while IFS= read -r line; do
    echo "$$ $line" >> "$DT_IMELOG"
    [ "$line" = quit ] && { sleep 0.8; exit 0; }
done
sleep 0.8
IME_EOF
chmod +x "$D/bin/wl-copy-stub" "$D/bin/lares-ime"

# the arm, applied in the copy by run.sh: FILE OLD NEW, every anchor checked before anything is written
cat > "$D/arm.py" <<'ARM_EOF'
import sys
arm = sys.argv[1]
S = "modules/dictation/DictationService.qml"
ARMS = {
    "noshelltarget": [(S, "            if (!root._shellCheck()) {", "            if (true) {")],
    "nosettle": [(S, 'root._mode === "type") shellSettle.restart()', 'root._mode === "type") root._shellCheck()')],
    "noimewait": [(S, "            if (root._imeQuitting && !root._imeWanted) {", "            if (false) {")],
    "stoppingdeaf": [(S, "            root._pressStopping();", "            void 0;")],
    "laterunning": [(S, 'if (e.take !== undefined && (e.take !== root._take || root._state === "idle"))',
                     "if (e.take !== undefined && e.take !== root._take)")],
    "nowatchdog": [(S, '            root._stall("stop");', '            root._finish("timeout");')],
    "notrace": [(S, '        helper.write(JSON.stringify({ op: "trace", why: why }) + "\\n");', "")],
    "nostartwatch": [(S, '                root._stall("start");', "                void 0;")],
    "warmrace": [(S, '        root._helperReady = false;\n        root._note({ ev: "restart", why: why });',
                  '        root._note({ ev: "restart", why: why });')],
    "noeol": [(S, "if [ -s \\\"$f\\\" ] && [ -n \\\"$(tail -c 1 \\\"$f\\\")\\\" ]; then printf '\\\\n' >> \\\"$f\\\"; fi; ", "")],
    "nolistenwatch": [(S, '                root._stall("silent", { silentMs: now - root._beatAt });', "                void 0;")],
    "noloopwatch": [(S, '                root._stall("loop", { loopMs: Number(e.loopMs), phase: String(e.phase || "") });', "                void 0;")],
    "nofallbacktoast": [(S, '            root.toast("Dictation", f.why.charAt(0).toUpperCase()', '            void ("Dictation", f.why.charAt(0).toUpperCase()')],
    "noexitwhy": [(S, '            root.toast("Dictation stopped", "The speech helper stopped (" + root._exitInfo.words + (last !== "" ? ": " + last : "")\n                       + "); the take was ended");', '            root.toast("Dictation stopped", "The speech helper ended (" + code + ")");')],
    "startstays": [(S, '        if (mine && (root._state === "starting" || root._state === "listening"))', '        if (mine && root._state === "listening")')],
    "norelease": [(S, "    function holdRelease(): void {\n        root._heldNext = null;", "    function holdRelease(): void {")],
    "noquiet": [(S, "        root._quietArm();\n        if (!activeWindow.running)", "        if (!activeWindow.running)")],
    "unmutes": [(S, '        if (mode !== "source" && !root.config.unmute && root._micMuted()) {', "        if (false) {")],
    "logdrop": [(S, "        if (!root.live || !root.config.logTakes || !root._dirReady || root._secret",
                 "        if (!root.live || !root.config.logTakes || !root._dirReady || logger.running || root._secret")],
}
out = {}
for f, old, new in ARMS[arm]:
    s = out.get(f) or open(f, encoding="utf-8").read()
    if s.count(old) != 1:
        print("DT ARMLOST %s: its anchor is found %d times in %s" % (arm, s.count(old), f))
        sys.exit(3)
    out[f] = s.replace(old, new)
for f, s in out.items():
    open(f, "w", encoding="utf-8").write(s)
print("DT ARMED " + arm)
ARM_EOF

cat > "$D/run.sh" <<RUN_EOF
if [ -n "${ARM:-}" ]; then python3 $D/arm.py "${ARM:-}" || exit 3; fi
env XDG_CONFIG_HOME="$D/config" XDG_STATE_HOME="$D/state" XDG_CACHE_HOME="$D/cache" QT_QPA_PLATFORM=offscreen WAYLAND_DISPLAY= \\
    HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off DT_HELPER="\$PWD/tools/dev/dictation_probe_helper.py" DT_IME="$D/bin/lares-ime" \\
    DT_IMELOG="$D/ime.log" DT_HELPERLOG="$D/helper.log" DT_CTL="$D/ctl.json" DT_STATE="$D/state" DT_COPY="$D/bin/wl-copy-stub" \\
    timeout -k 5 150 quickshell -p tools/dev/qml/dictation_probe_take.qml
RUN_EOF
tools/dev/sandbox.sh bash "$D/run.sh" > "$D/log" 2>&1

# the shell log's report of each stall (the service's console.warn), read here
report() {
    local why=$1 name=$2
    local blk
    # the warning's line and its continuation lines (each begins with two spaces)
    blk=$(rl_clean "$D/log" | awk -v w="stalled ($why)" 'on && !/^  / { exit } index($0, w) { on = 1 } on { print }')
    if [ -z "$blk" ]; then echo "DT FAIL $name: no report of a stall ($why) in the shell log"; return; fi
    local thr err=""
    thr=$(printf '%s\n' "$blk" | grep -c "MainThread: dictation_probe_helper.py")
    if printf '%s\n' "$blk" | grep -q 'fake helper: the decoder did not return' || [ "$why" != stop ]; then err="yes"
    else err="MISSING"; fi
    if [ "$thr" -ge 1 ] && [ "$err" != MISSING ]; then
        echo "DT ok $name: the shell log names the stall ($why), the helper's threads ($thr) and its last stderr lines ($err)"
    else
        echo "DT FAIL $name: the report has the threads $thr time(s), the stderr lines $err"
    fi
}
{ rl_clean "$D/log" | grep -a -o 'DT .*' | grep -a -v '^DT RESULT'; report stop "T4 report"; report start "T5 report"; } > "$D/checks"
cut -c1-400 "$D/checks"
if [ -n "${ARM:-}" ]; then
    if grep -a -q 'DT ARMLOST' "$D/checks"; then echo "ARM $ARM: its anchor matched nothing -- it proves nothing"; exit 1; fi
    if grep -a -q -F "$NEEDLE" "$D/checks"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    rl_has "$D/log" 'DT RESULT' || { KEEP=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; }
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result DICTTAKE "$D/log" 'DT RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
warn=$(rl_clean "$D/log" | grep -a -E 'Unable to assign|Binding loop|non-existent|TypeError|ReferenceError|unqualified' | head -3)
[ -z "$warn" ] || { echo "DT FAIL warnings: $warn"; rc=1; }
grep -a -q '^DT FAIL' "$D/checks" && rc=1
[ "$rc" -eq 0 ] || KEEP=1
echo "DICTTAKE RESULT $([ "$rc" -eq 0 ] && echo PASS || echo "FAIL ($D/log)")"
exit $rc
