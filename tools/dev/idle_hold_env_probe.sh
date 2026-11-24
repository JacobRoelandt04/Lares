#!/usr/bin/env bash
# idle_hold_env_probe.sh -- the idle reel's "normal" holds the session awake across every remap of the bar's window (round 7, IDLEHOLD:
# "system went into suspend while on normal idleinhibition", 2026-11-10). shell.qml on its mock services in the isolated nested
# Hyprland of tools/dev/lock_env.sh, with a stand-in for hypridle's suspend listener (tools/dev/qml/idle_hold_env_client.qml: an
# ext-idle-notify-v1 notification that RESPECTS INHIBITORS, timeout 4 s -- the compositor's own verdict, which no mock can fake)
# and an app the probe puts fullscreen. Nothing of the user's is touched: the compositor, its bus and runtime dir are lock_env's,
# the shell runs from a sandbox copy, and no logind, hypridle or bus of the user's is asked anything.
#
#   tools/dev/idle_hold_env_probe.sh                  IDLEHOLD RESULT PASS | FAIL
#   IDLEHOLD_KEEP=1 ...                               keep the work dir (the logs) after a PASS too
#   IDLEHOLD_ANIM=0 ...                               the env's animations off (default ON, with the user's `fade` leaf: speed 6 --
#                                                     a Top layer's alpha comes back over ~0.6 s when a fullscreen window goes, which is
#                                                     what Hyprland's recheck at that moment reads)
#   ONLY_ARMS="nopill ..." ARM=all ...                some of the ARMs
#
# The copy is patched so that EVERY rise over a fullscreen window remaps the bar window (`riseStallMs` 1, the frame that would
# cancel it ignored): the path the user's shell took at 18:2x, when the rise found the window stale. And the remap shows the window
# again IN THE SAME TURN, so the old QQuickWindow's deferred deletion lands after the new surface is up -- the order the user's log
# shows (`Destroyed`, `Created`, `Destroyed`: the old window's end took the new surface's inhibitor), which the real code's one-turn
# callLater leaves to chance (an arm on an order of arrivals needs the order forced). The shell runs with Quickshell's
# `quickshell.wayland.idle_inhibit` debug lines on, which name every inhibitor made and destroyed.
#
#   P0  off: nothing held, the listener idles (the calibration: the listener and the seat work)
#   P1  normal: the listener stays awake
#   P2  normal, the app fullscreen (the bar window covered, frozen), nothing else happening: awake
#   P2b and in it SOMETHING ELSE MAKES HYPRLAND RECHECK (a blip: another client's inhibitor made and destroyed, as any window mapped
#       or focused does in a real session): awake
#   P3  normal, a popup floated over the fullscreen app (the clipboard's key) -- the bar window REMAPPED -- and closed: awake
#   P4  the fullscreen ends, nothing touched (the user's path: the focus on kitty, idle): awake
#   P5  P2 .. P4 once more (a second remap of the same window, as in the user's log)
#   P6  off again: the listener idles (nothing is left holding)
# A phase is judged over 10 s (two and a half timeouts) from 1.5 s after its action, by the listener's last verdict and any idle in between.
# The shell follows the nested compositor's focus and fullscreen (SHELL_FOCUS=live), as the live shell follows the user's.
#
# ARMs (each patches ONE thing in the run's sandbox copy; the run must FAIL the phase named):
#   ARM=oneinhibitor   the IDLE HOLD block as it was (31f7ed13: one IdleInhibitor for the window's life)                     P2
#   ARM=onegeneration  the bar window's inhibitor one object for the window's life (Quickshell's stale path at the remap)    P4
#   ARM=noreassert     no fresh inhibitor after Hyprland says a shell surface mapped (the pill's is made before its buffer)  P2
#   ARM=nopill         no inhibitor on the OSD pill's window while covered (the bar's Top layer has alpha 0 there)          P2b
#   ARM=all            each of them in turn, each must fail its own phase with the listener idling: IDLEHOLD ARMS RESULT PASS | FAIL
set -u
# ONE BRACE GROUP: bash reads a script from disk as it runs
{
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. tools/dev/result_lib.sh

if [ "${ARM:-}" = all ]; then
    rc=0
    declare -A NEED=([oneinhibitor]=P2b [onegeneration]=P4 [noreassert]=P2 [nopill]=P2b)
    for a in ${ONLY_ARMS:-oneinhibitor onegeneration noreassert nopill}; do
        out=$(ARM="$a" IDLEHOLD_KEEP= bash "$0" 2>&1)
        ad=$(printf '%s\n' "$out" | grep -a -o 'logs: [^)]*' | tail -1 | sed 's/^logs: //')
        if printf '%s\n' "$out" | grep -aq "anchor in "; then
            echo "ARM $a: NOT PROVEN (its anchor is gone: $(printf '%s\n' "$out" | grep -a 'anchor in ' | head -1 | cut -c1-110))"; rc=1
        elif rl_isnoresult "$out" || printf '%s\n' "$out" | grep -aq "the armed copy did not load"; then
            echo "ARM $a: NOT PROVEN (the armed copy did not load)"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^IDLEHOLD RESULT FAIL" && printf '%s\n' "$out" | grep -aqE "^IHP FAIL ${NEED[$a]} [^:]*: the listener idled"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aE "^IHP FAIL ${NEED[$a]} " | head -1 | cut -c10-130))"
        elif printf '%s\n' "$out" | grep -aq "^IDLEHOLD RESULT FAIL"; then
            echo "ARM $a: FAILED, BUT NOT AT ITS OWN PHASE (${NEED[$a]}): $(printf '%s\n' "$out" | grep -a 'IHP FAIL' | head -1 | cut -c1-110)"; rc=1
        else
            echo "ARM $a: STAYED GREEN"; rc=1
        fi
        # the armed run kept its logs for this reading; they go now
        case "$ad" in "${SCRATCH:-/tmp}"/idlehold.*) rm -rf "$ad" ;; esac
    done
    [ "$rc" = 0 ] && echo "IDLEHOLD ARMS RESULT PASS" || echo "IDLEHOLD ARMS RESULT FAIL"
    exit "$rc"
fi
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-idlehold}"
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-idlehold}"
D="$(mktemp -d "${SCRATCH:-/tmp}/idlehold.XXXXXX")"
SPID="" CPID="" _cleaned=0 _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    [ -n "$CPID" ] && kill "$CPID" 2> /dev/null
    KEEP= "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX" "$SANDBOX.lrrt"
    [ "$_ok" = 1 ] && [ -z "${IDLEHOLD_KEEP:-}" ] && rm -rf "$D"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "IDLEHOLD RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
python3 - "$SB" "${ARM:-}" <<'PY' || { echo "IDLEHOLD RESULT FAIL (the copy's patch did not go in)"; exit 1; }
import sys
sb, arm = sys.argv[1:3]
def patch(path, pairs):
    p = sb + "/" + path
    s = open(p, encoding="utf-8").read()
    for a, b in pairs:
        if s.count(a) != 1:
            print("anchor in %s found %d times: %s" % (path, s.count(a), a.splitlines()[0][:90])); sys.exit(1)
        s = s.replace(a, b)
    open(p, "w", encoding="utf-8").write(s)
# every rise over a fullscreen window remaps (the stale window's path, forced)
patch("modules/shell/ShellScreen.qml", [
    ("    property int riseStallMs: 64\n", "    property int riseStallMs: 1\n"),
    # the rule asks for a frame once, then remaps -- at most once per cool-down (RemapRule.js): no cool-down here
    ("    property int remapCooldownMs: 10000\n", "    property int remapCooldownMs: 0\n"),
    ("        enabled: riseWatch.running\n        function onAfterAnimating() {", "        enabled: false\n        function onAfterAnimating() {"),
    ("                win.remapping = true;\n                Qt.callLater(() => {\n                    win.remapping = false;\n                });\n",
     "                win.remapping = true;\n                win.remapping = false;\n"),
])
SS = "modules/shell/ShellScreen.qml"
if arm == "oneinhibitor":
    s = open(sb + "/" + SS, encoding="utf-8").read()
    a, b = "    // >>> IDLE HOLD\n", "    // <<< IDLE HOLD\n"
    if s.count(a) != 1 or s.count(b) != 1:
        print("anchor in %s: the IDLE HOLD block's marks are gone" % SS); sys.exit(1)
    i, j = s.index(a), s.index(b) + len(b)
    s = s[:i] + "    IdleInhibitor {\n        window: win\n        enabled: win.services.idle.normalHold\n    }\n" + s[j:]
    open(sb + "/" + SS, "w", encoding="utf-8").write(s)
elif arm == "onegeneration":
    patch(SS, [("    HeldInhibitor {\n        target: win\n        want: win._holdWanted\n        serial: win._barSerial\n    }\n",
                "    IdleInhibitor {\n        window: win\n        enabled: win._holdWanted\n    }\n")])
elif arm == "noreassert":
    patch(SS, [("                    if (ev.name !== \"openlayer\")\n                        return;\n", "                    return;\n")])
elif arm == "nopill":
    patch(SS, [("        want: win._holdWanted && win._covered\n", "        want: false\n")])
elif arm:
    print("unknown ARM=" + arm); sys.exit(2)
if arm:
    print("ARMED " + arm)
PY

"$E" down > /dev/null 2>&1
ANIM=true; [ "${IDLEHOLD_ANIM:-1}" = 0 ] && ANIM=false
OUTPUTS=1 ANIMATIONS="$ANIM" "$E" up > "$D/up.log" 2>&1 || { tail -5 "$D/up.log"; echo "IDLEHOLD RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
# the user's fade (~/.config/hypr/config/animations.lua)
[ "$ANIM" = true ] && "$E" hyprctl eval 'hl.animation({ leaf = "fade", enabled = true, speed = 6, bezier = "default" })' > /dev/null
# the user's layer rules for the shell's surfaces (~/.config/hypr/config/layerrules.lua): no fade in or out
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_osd_pill_noanim", match = { namespace = "^osd-pill$" }, no_anim = true })' > /dev/null

CLOG="$D/client.log" SLOG="$D/shell.log"
"$E" run env QS_DISABLE_CRASH_HANDLER=1 IHC_TIMEOUT=4 quickshell -n -p "$SB/tools/dev/qml/idle_hold_env_client.qml" > "$CLOG" 2>&1 &
CPID=$!
for _ in $(seq 1 100); do grep -aq "IHC up" "$CLOG" 2> /dev/null && break; sleep 0.2; done
grep -aq "IHC up" "$CLOG" || { rl_noresult IDLEHOLD "$CLOG"; exit 1; }

"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n --log-rules "quickshell.wayland.idle_inhibit.debug=true" -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do
    grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
if ! grep -aq "LARES settled" "$SLOG"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($SLOG)"
    IDLEHOLD_KEEP=1; rl_noresult IDLEHOLD "$SLOG"; exit 1
fi

ipc() { "$E" run quickshell ipc -p "$SB/shell.qml" call shell "$@" 2> /dev/null; }
global() { "$E" hyprctl dispatch "hl.dsp.global(\"lares:$1\")" > /dev/null; }
fullscreen() { "$E" hyprctl dispatch "hl.dsp.window.fullscreen({ action = \"$1\", window = \"title:^ihc-app\$\" })"; }
now() { date +%s%3N; }
# the lares-bar layer's level on LOCK-1 (2 top, 3 overlay; "" when it is not mapped)
barlevel() {
    "$E" hyprctl -j layers 2> /dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for mon in d.values():
    for lv, ls in mon.get("levels", {}).items():
        if any(l.get("namespace") == "lares-bar" for l in ls):
            print(lv); sys.exit(0)
'
}
# the lares-bar layer surface's address on LOCK-1 (a remap makes a new one)
baraddr() {
    "$E" hyprctl -j layers 2> /dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(l.get("address", "") for mon in d.values() for ls in mon.get("levels", {}).values() for l in ls if l.get("namespace") == "lares-bar"))'
}
inhib() { rl_clean "$SLOG" | grep -a -c "idle_inhibit.*$1 inhibitor"; }
fails=0
# judge <name> <from ms> <until ms> <want 0|1>: the listener's verdict over [from, until]: want 0 = never idle in it (awake),
# want 1 = idle at its end
judge() {
    local name="$1" from="$2" until="$3" want="$4" r
    r=$(rl_clean "$CLOG" | python3 -c '
import re, sys
frm, until, want = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ev = [(int(m.group(2)), int(m.group(1))) for m in (re.search(r"IHC idle (\d) (\d+)", l) for l in sys.stdin) if m]
before = [v for t, v in ev if t <= frm]
state = before[-1] if before else 0
idled = state == 1
for t, v in ev:
    if frm < t <= until:
        state = v
        idled = idled or v == 1
if want == "0":
    ok = not idled
    print(("ok  " if ok else "FAIL") + " awake (never idle in the %.1f s)" % ((until - frm) / 1000.0) if ok else "FAIL the listener idled: the suspend would have run")
else:
    ok = state == 1
    print("ok   idle at the end (the listener fires)" if ok else "FAIL not idle at the end: the listener does not fire")
' "$from" "$until" "$want")
    case "$r" in ok*) ;; *) fails=$((fails + 1)) ;; esac
    echo "IHP ${r%% *} $name: ${r#* }"
}
# pre <what> <1 or empty>: a phase's precondition (a phase whose setup did not happen proves nothing)
pre() {
    if [ "$2" = 1 ]; then echo "IHP ok   $1"; else echo "IHP FAIL $1"; fails=$((fails + 1)); fi
}
# the app is fullscreen (hyprctl's view): 2, else 0
appfs() {
    "$E" hyprctl -j clients 2> /dev/null | python3 -c '
import json, sys
print(max([c.get("fullscreen", 0) for c in json.load(sys.stdin) if c.get("title") == "ihc-app"] or [0]))'
}
# phase <name> <want> <action...>: run the action, wait 1.5 s, judge the next 9 s (DURING=blip: a blip at its start)
phase() {
    local name="$1" want="$2" t0 t1 bp
    shift 2
    "$@"
    sleep 1.5
    t0=$(now)
    if [ "${DURING:-}" = blip ]; then
        local nb
        nb=$(grep -ac "IHC blip off" "$D/blip.log" 2> /dev/null)
        # (no -n: the listener's process runs the same file)
        "$E" run env IHC_MODE=blip QS_DISABLE_CRASH_HANDLER=1 quickshell -p "$SB/tools/dev/qml/idle_hold_env_client.qml" >> "$D/blip.log" 2>&1 &
        bp=$!
        sleep 10
        kill "$bp" 2> /dev/null; wait "$bp" 2> /dev/null
        pre "$name: the blip made and destroyed its inhibitor" "$([ "$(grep -ac "IHC blip off" "$D/blip.log")" -gt "${nb:-0}" ] && echo 1)"
    else
        sleep 10
    fi
    t1=$(now)
    judge "$name" "$t0" "$t1" "$want"
    echo "IHP      ($name: inhibitors made $(inhib Created), destroyed $(inhib Destroyed); bar on level $(barlevel))"
}
mode() { ipc hook idle "$1" > /dev/null; }
rise() {  # the clipboard's key over the fullscreen app: the bar window rises to Overlay and (patched) remaps; then closed
    local a0 a1 i
    a0=$(baraddr)
    global clipboard
    for i in $(seq 1 40); do [ "$(barlevel)" = 3 ] && break; sleep 0.1; done
    sleep 1
    a1=$(baraddr)
    pre "the popup floated: the bar window on the Overlay layer (level $(barlevel)), REMAPPED (its surface $a0 -> $a1)" \
        "$([ "$(barlevel)" = 3 ] && [ -n "$a0" ] && [ -n "$a1" ] && [ "$a0" != "$a1" ] && echo 1)"
    global clipboard
    sleep 0.5
}
covered() {
    fullscreen set > /dev/null
    sleep 0.5
    pre "the app is fullscreen" "$([ "$(appfs)" = 2 ] && echo 1)"
}
uncovered() {
    fullscreen unset > /dev/null
    sleep 0.5
    pre "the app is no longer fullscreen" "$([ "$(appfs)" = 0 ] && echo 1)"
}

phase "P0 off: the calibration" 1 true
phase "P1 normal" 0 mode normal
phase "P2 normal, the app fullscreen (the bar covered)" 0 covered
DURING=blip phase "P2b normal, covered, another client's recheck" 0 true
phase "P3 normal, a popup floated over it (the bar window remapped) and closed" 0 rise
phase "P4 normal, the fullscreen ended" 0 uncovered
phase "P5a normal, fullscreen again" 0 covered
DURING=blip phase "P5b normal, covered, another client's recheck" 0 true
phase "P5c normal, a second remap" 0 rise
phase "P5d normal, the fullscreen ended again" 0 uncovered
phase "P6 off again: nothing left holding" 1 mode off

kill -0 "$SPID" 2> /dev/null || { echo "IHP FAIL the shell died during the run (see $SLOG)"; fails=$((fails + 1)); }
# the compositor's side, for the reader of a red run: every inhibitor it registered
hl=$(ls "$("$E" dir)"/rt/hypr/*/hyprland.log 2> /dev/null | head -1)
[ -n "$hl" ] && grep -a -i "inhibit" "$hl" > "$D/hyprland_inhibitors.log" 2> /dev/null; [ -n "${IDLEHOLD_HYPRLOG:-}" ] && [ -n "$hl" ] && cp "$hl" "$D/hyprland.log"
warns=$(rl_clean "$SLOG" | rl_platform_noise | grep -aE "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError" \
    | grep -avE "quickshell.tooling|--- WARNING ---|actually running wayland|does not support setting window masks|Failed to register with host portal|Could not load icon")
if [ -n "$warns" ]; then
    echo "IHP FAIL the shell's log complains:"
    printf '%s\n' "$warns" | sed 's/^ *//' | sort | uniq -c | sort -rn | head -8 | sed 's/^/        /'
    fails=$((fails + 1))
fi
if [ "$fails" = 0 ]; then
    _ok=1
    echo "IDLEHOLD RESULT PASS (11 phases, $(inhib Created) inhibitors made)"
    exit 0
fi
IDLEHOLD_KEEP=1
echo "IDLEHOLD RESULT FAIL ($fails of the checks; logs: $D)"
exit 1
}
