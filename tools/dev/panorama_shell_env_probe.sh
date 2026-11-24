#!/usr/bin/env bash
# panorama_shell_env_probe.sh -- the LIVE Panorama service inside the REAL shell.qml, on a nested Hyprland (tools/dev/lock_env.sh,
# OUTPUTS=2) whose engine (tools/panorama/engine.lua, through a generated config/panorama.lua) is active. The shell runs from a sandbox
# copy with SHELL_SERVICES=mock SHELL_PANORAMA=live SHELL_FOCUS=live. A STUB ddcutil leads its PATH (the popup's open runs
# `ddcutil detect`; the real one probes the machine's i2c buses): the runner REFUSES to start when it is not the first on PATH.
# Driver: tools/dev/panorama_engine/shell_probe.py. Ends in PANORAMA_SHELL_ENV RESULT PASS|FAIL.
#
#   tools/dev/panorama_shell_env_probe.sh        all checks (1 up and active, 2 a plug, 3 popup hover + identify ink, 4 ddcutil, 5 unplug, 6 the log)
#   ARM=noidentify   IdentifyCard's `wanted` is always false: the ink check goes red
#   ARM=nofollow     the service's outputs ignore a new output: "2 plug" goes red
#   ARM=stubnotfirst the stub is LAST on PATH: the runner must refuse to start (exit 2, "REFUSED")
#   ARM=endside      the side popup asked for on the right, as before 2026-11-21's fix: "3b" goes red (no room by the screen's edge)
#   PHASE=mirror     only the mirror phase (a fresh env: eDP-1 headless as the laptop, LOCK-1 mirrors it; the LIVE PanoramaService driven by
#                    tools/dev/qml/panorama_mirror_env.qml: a real mirror trial, its revert, a second trial; no shell.qml). Without PHASE all run.
#   PHASE=cast       only the cast phase (the mirror phase's env; tools/dev/qml/panorama_cast_env.qml: a whole cast on the LIVE service, the LIVE
#                    CastService with a stub tool and the real engine: armed, scan, LARES-CAST-1, stream, stop)
#   ARM=keepstaged   (mirror phase) a revert keeps the staged edit, as before round 2: "m3 revert: at once idle" goes red
#   ARM=mirrormove   (mirror phase) the engine moves a workspace onto an output that is still a mirror, as before round 2: Hyprland answers
#                    "Monitor not found" and "m5 the harness's log: no warning" goes red (the link survives it: the next arm is the latch)
#   ARM=warnlatch    (mirror phase) that warning AND the old latch (a warning is an error, nothing clears it): "m3 the engine is still active"
#   ARM=bracket      (cast phase) a text that ends in "]" closes its own Lua brackets, as before 2026-11-22: "c1 armed" goes red
#   ARM=mirroroutput (cast phase) a cast that mirrors still makes its output: "m1" / "m4 NO cast output" go red
#   ARM=all          every arm: PANORAMA_SHELL_ENV ARMS PASS|FAIL
#   PANORAMA_SHELL_ENV_KEEP=1 keeps the logs
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. "$ROOT/tools/dev/result_lib.sh"
NAME=PANORAMA_SHELL_ENV
export LOCK_ENV="${LOCK_ENV:-pnsh}"
SANDBOX="${SANDBOX:-/tmp/lares-sbx-pnsh}"
E="$ROOT/tools/dev/lock_env.sh"
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in noidentify nofollow stubnotfirst endside keepstaged mirrormove warnlatch bracket; do
        out=$(ARM="$a" SANDBOX="$SANDBOX-$a" bash "$0" 2>&1)
        case "$a" in
            noidentify) need='FAIL 3 identify: ink' ;;
            nofollow) need='FAIL 2 plug: the glyph' ;;
            stubnotfirst) need='REFUSED' ;;
            endside) need='FAIL 3b a click on' ;;
            keepstaged) need='FAIL m3 revert: at once idle' ;;
            mirrormove) need='FAIL m5 the harness' ;;
            bracket) need='FAIL c1 armed' ;;
            warnlatch) need='FAIL m3 the engine is still active' ;;
        esac
        if printf '%s\n' "$out" | grep -qF "$need"; then
            echo "ARM $a: FAILED AS IT MUST ($need)"
        else
            echo "ARM $a: NOT CAUGHT: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ' | cut -c1-240)"; rc=1
        fi
    done
    echo "$NAME ARMS $([ $rc = 0 ] && echo PASS || echo FAIL)"
    exit $rc
fi
SCR="/tmp/pnsh-$$"
rm -rf "$SCR"; mkdir -p "$SCR/stubs"
SPID=""; _ok=0
cleanup() {
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX"
    [ "$_ok" = 1 ] && [ -z "${PANORAMA_SHELL_ENV_KEEP:-}" ] && rm -rf "$SCR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# the stub ddcutil: logs every call, answers like the real one on a machine with no DDC display
DDCLOG="$SCR/ddc.log"; : > "$DDCLOG"
cat > "$SCR/stubs/ddcutil" <<STUB
#!/bin/sh
echo "\$*" >> "$DDCLOG"
case "\$1" in
    detect) echo "No displays found."; exit 0 ;;
    *) echo "ddcutil stub: unexpected call \$*" >&2; exit 1 ;;
esac
STUB
chmod +x "$SCR/stubs/ddcutil"
if [ "${ARM:-}" = stubnotfirst ]; then SHELL_PATH="$PATH:$SCR/stubs"; else SHELL_PATH="$SCR/stubs:$PATH"; fi
first=$(PATH="$SHELL_PATH" command -v ddcutil)
if [ "$first" != "$SCR/stubs/ddcutil" ]; then
    echo "$NAME REFUSED: \`command -v ddcutil\` is '$first', not the stub; the real one would probe the machine's i2c buses"
    exit 2
fi

PHASE="${PHASE:-both}"
SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "$NAME RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
arm() {  # file count from to
    python3 - "$@" <<'PY' || { echo "ARM ${ARM:-}: anchor check failed"; exit 2; }
import sys
p, n, a, b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
s = open(p, encoding="utf-8").read()
c = s.count(a)
if c != n:
    print(f"FAIL  anchor found {c} times in {p}, expected {n}: {a[:70]!r}")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
    ""|stubnotfirst) ;;
    noidentify) arm "$SB/modules/panorama/screen/IdentifyCard.qml" 1 'readonly property bool wanted: !!root.service && root.screenName !== "" && root.service.identify === root.screenName' 'readonly property bool wanted: false' ;;
    nofollow) arm "$SB/modules/panorama/data/PanoramaService.qml" 1 'root._withDrivers(root.focusSource ? root.focusSource.outputs : [], root.drm' 'root._withDrivers(root.focusSource ? root.focusSource.outputs.filter(o => o.name === "LOCK-1" || o.name === "LOCK-2") : [], root.drm' ;;
    endside) arm "$SB/modules/panorama/popup/PanoramaPopup.qml" 1 'return left >= need || left >= right ? "start" : "end";' 'return "end";' ;;
    keepstaged) PHASE=mirror
        arm "$SB/modules/panorama/data/PanoramaService.qml" 1 '        root._pending = null;
        root._staged = null;
        root._stagedSplit = null;
        root._relations = null;
        root._phase = "idle";' '        root._pending = null;
        root._phase = root._staged !== null ? "staged" : "idle";' ;;
    mirrormove) PHASE=mirror
        arm "$SB/tools/panorama/engine.lua" 1 '    if target and mirroring[target] then' '    if false then' ;;
    warnlatch) PHASE=mirror
        arm "$SB/tools/panorama/engine.lua" 1 '    if target and mirroring[target] then' '    if false then'
        arm "$SB/modules/panorama/data/EngineLink.qml" 1 'const warned = code === 0 && out !== ""' 'const warned = false && out !== ""'
        arm "$SB/modules/panorama/data/EngineLink.qml" 1 '(parsed.serial || 0) > root._errorSerial' 'false' ;;
    bracket) PHASE=cast
        arm "$SB/modules/panorama/data/EngineGenerate.js" 1 '(text + "]").indexOf(' 'text.indexOf(' ;;
    mirroroutput) PHASE=cast
        arm "$SB/modules/panorama/data/CastKeeper.qml" 1 '        root._held = false;
        if (root._wantMirror()) {' '        root._held = false;
        if (false) {' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# the shell phase: the real shell.qml on two outputs, the checks of shell_probe.py run
main_phase() {
    "$E" down > /dev/null 2>&1
    OUTPUTS=2 "$E" up > /dev/null || { echo "$NAME RESULT FAIL (the nested Hyprland did not come up)"; return 1; }
    "$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
    python3 tools/dev/panorama_engine/shell_probe.py seed "$ROOT" "$SB" "$LOCK_ENV" || { echo "$NAME RESULT FAIL (the engine did not load)"; return 1; }

    # NO_TOASTS=1 (a diagnosis, not a gate): the service's never-seen / unplug toasts off, to tell a toast's cause from a plug's
    if [ "${NO_TOASTS:-0}" = 1 ]; then
        mkdir -p "$("$E" dir)/state/lares-shell-mock/config"
        echo '{ "toasts": { "newDisplay": false, "unplug": false } }' > "$("$E" dir)/state/lares-shell-mock/config/panorama.jsonc"
    fi
    SLOG="$SCR/shell.log"
    "$E" run env PATH="$SHELL_PATH" SHELL_SERVICES=mock SHELL_PANORAMA=live SHELL_FOCUS=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=0 quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
    SPID=$!
    for _ in $(seq 1 400); do
        grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
        kill -0 "$SPID" 2> /dev/null || break
        sleep 0.3
    done
    grep -aq "LARES settled" "$SLOG" || { rl_noresult "$NAME" "$SLOG"; return 1; }
    sleep 2

    python3 tools/dev/panorama_engine/shell_probe.py run "$ROOT" "$SB" "$LOCK_ENV" "$SLOG" "$DDCLOG" 2>&1
    local rc=$?
    kill -0 "$SPID" 2> /dev/null || { echo "  FAIL the shell died during the run (see $SLOG)"; rc=1; }
    kill "$SPID" 2> /dev/null; wait "$SPID" 2> /dev/null; SPID=""
    return $rc
}

# the mirror phase: a fresh env (eDP-1 headless as the laptop panel, LOCK-1 the external that mirrors it), the LIVE PanoramaService alone
# (tools/dev/qml/panorama_mirror_env.qml), then the compositor's own word (shell_probe.py mirror-after)
mirror_phase() {
    "$E" down > /dev/null 2>&1
    OUTPUTS=2 "$E" up > /dev/null || { echo "  FAIL m0 the nested Hyprland did not come up"; return 1; }
    python3 tools/dev/panorama_engine/shell_probe.py mirror-seed "$ROOT" "$SB" "$LOCK_ENV" || return 1
    MLOG="$SCR/mirror.log"
    ( cd "$SB" && "$E" run env PATH="$SHELL_PATH" PM_ENGINE="$SB/tools/panorama/engine.lua" QS_DISABLE_CRASH_HANDLER=1 timeout -k 5 160 quickshell -n -p tools/dev/qml/panorama_mirror_env.qml > "$MLOG" 2>&1 )
    local rc=0
    rl_clean "$MLOG" | grep -a '^ *DEBUG qml: PM ' | grep -a -v 'PM RESULT' | sed -e 's/^ *DEBUG qml: //' -e 's/^PM ok   /  ok   /' -e 's/^PM FAIL /  FAIL /'
    if rl_clean "$MLOG" | grep -aq '^ *DEBUG qml: PM FAIL'; then rc=1; fi
    rl_has "$MLOG" 'PM RESULT' || { echo "  FAIL m0 the mirror harness gave no result (see $MLOG)"; KEEP_SCR=1; rc=1; }
    python3 tools/dev/panorama_engine/shell_probe.py mirror-after "$ROOT" "$SB" "$LOCK_ENV" "$MLOG" || rc=1
    return $rc
}

# the cast phase: the mirror phase's env, a whole cast (tools/dev/qml/panorama_cast_env.qml); then the compositor holds no cast output
cast_phase() {
    "$E" down > /dev/null 2>&1
    OUTPUTS=2 "$E" up > /dev/null || { echo "  FAIL c0 the nested Hyprland did not come up"; return 1; }
    python3 tools/dev/panorama_engine/shell_probe.py mirror-seed "$ROOT" "$SB" "$LOCK_ENV" || return 1
    CLOG="$SCR/cast.log"
    ( cd "$SB" && "$E" run env PATH="$SHELL_PATH" PM_ENGINE="$SB/tools/panorama/engine.lua" PM_CASTTOOL="$SB/tools/dev/fixtures/cast/cast_stub_tool" QS_DISABLE_CRASH_HANDLER=1 timeout -k 5 280 quickshell -n -p tools/dev/qml/panorama_cast_env.qml > "$CLOG" 2>&1 )
    local rc=0 w
    rl_clean "$CLOG" | grep -a '^ *DEBUG qml: PM ' | grep -a -v 'PM RESULT' | sed -e 's/^ *DEBUG qml: //' -e 's/^PM ok   /  ok   /' -e 's/^PM FAIL /  FAIL /'
    if rl_clean "$CLOG" | grep -aq '^ *DEBUG qml: PM FAIL'; then rc=1; fi
    rl_has "$CLOG" 'PM RESULT' || { echo "  FAIL c0 the cast harness gave no result (see $CLOG)"; rc=1; }
    w=$(rl_clean "$CLOG" | grep -a -E '^ *(WARN|ERROR)' | grep -a -E 'panorama|Cast|Engine' | head -3)
    if [ -n "$w" ]; then echo "  FAIL c5 the harness's log: a warning naming panorama: $w"; rc=1; else echo "  ok   c5 the harness's log: no warning naming panorama"; fi
    if "$E" hyprctl -j monitors all | grep -q LARES-CAST; then echo "  FAIL c5 the compositor still holds a cast output"; rc=1; else echo "  ok   c5 the compositor holds no cast output"; fi
    return $rc
}

rc=0
: > "$SCR/checks.log"
if [ "$PHASE" = both ] || [ "$PHASE" = main ]; then
    main_phase 2>&1 | tee -a "$SCR/checks.log"
    [ "${PIPESTATUS[0]}" = 0 ] || rc=1
fi
if [ "$PHASE" = both ] || [ "$PHASE" = cast ]; then
    cast_phase 2>&1 | tee -a "$SCR/checks.log"
    [ "${PIPESTATUS[0]}" = 0 ] || rc=1
fi
if [ "$PHASE" = both ] || [ "$PHASE" = mirror ]; then
    mirror_phase 2>&1 | tee -a "$SCR/checks.log"
    [ "${PIPESTATUS[0]}" = 0 ] || rc=1
fi
if [ -n "${ARM:-}" ]; then exit 1; fi
grep -aq '^  FAIL' "$SCR/checks.log" && rc=1
if [ "$rc" = 0 ]; then _ok=1; echo "$NAME RESULT PASS ($(grep -ac '^  ok' "$SCR/checks.log") checks)" | tee -a "$SCR/checks.log";
else echo "$NAME RESULT FAIL ($(grep -a '^  FAIL' "$SCR/checks.log" | wc -l) failed)" | tee -a "$SCR/checks.log"; fi
rl_result "$NAME" "$SCR/checks.log" "$NAME RESULT .*" > /dev/null; exit $?
