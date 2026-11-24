#!/usr/bin/env bash
# flourish_pool_probe.sh -- the OLED care's random flourishes: the registry every glyph flourish joins, one screen's scheduler, its
# gates, its shuffle bag and its config, on the MOCK shell, offscreen (tools/dev/qml/flourish_pool_probe.qml).
#
#   tools/dev/flourish_pool_probe.sh              FLOURISH_POOL RESULT PASS | FAIL
#   ARM=<name> tools/dev/flourish_pool_probe.sh   one fault in a SANDBOX copy; it must FAIL on its check's own needle
#   ARM=all                                       every arm (ONLY_ARMS="a b" narrows it)
#     nogate     ShellFrame lets a turn play under an open popup             -> "gate: a popup open on this screen skips the turn"
#     firepath   a reel's demo plays its FIRE (ReelFlourishes.play)          -> "demo: no turn took the fire path"
#     staleheld  the registry unregisters a NAME (every entry by that name)  -> "staleheld: a replaced delegate leaves the live entry"
#     configoff  the scheduler arms whatever `idle` / `active` say           -> "config: idle false while idle arms nothing"
#
# Private XDG dirs (the theme state seeded, a fresh OLED state, no shell.jsonc: the probe writes its config through ShellConfig.apply),
# so nothing of the user's desktop moves. A run that printed no RESULT (a QML that did not load) keeps its work dir and names the log
# (tools/dev/runner_noload_check.sh); KEEP=1 keeps it always.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh

if [ -e .git ] && [ -z "${FLPOOL_INNER:-}" ]; then
    export FLPOOL_INNER=1
    exec tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen FLPOOL_INNER=1 ARM="${ARM:-}" ONLY_ARMS="${ONLY_ARMS:-}" KEEP="${KEEP:-}" bash tools/dev/flourish_pool_probe.sh "$@"
fi

D="$(mktemp -d "${SCRATCH:-/tmp}/flpool.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT

arm_needle() {
    case $1 in
        nogate) echo "gate: a popup open on this screen skips the turn" ;;
        firepath) echo "demo: no turn took the fire path" ;;
        staleheld) echo "staleheld: a replaced delegate leaves the live entry" ;;
        configoff) echo "config: idle false while idle arms nothing" ;;
    esac
}
patch() {   # patch <file> <old> <new>: exactly one match, or the run says so
    python3 - "$1" "$2" "$3" << 'PY' || { echo "FLPOOL ARM anchor gone: $1"; exit 3; }
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1:
    sys.exit(1)
open(f, "w").write(s.replace(old, new))
PY
}
arm_apply() {
    case $1 in
        nogate) patch modules/shell/ShellFrame.qml '        if (frame.slotsOut)
            return "popup";
' '' ;;
        firepath) patch modules/bar/reel/ReelFlourishes.qml '        set._demo(id, "random");' '        set.play(id);' ;;
        staleheld) patch modules/common/flourish/FlourishRegistry.qml '        const i = reg.entries.indexOf(e);' '        reg.entries = reg.entries.filter(x => reg.keyOf(x) !== reg.keyOf(e));
        const i = -1;' ;;
        configoff) patch modules/common/flourish/FlourishScheduler.qml 'readonly property bool armed: sch.on && (sch.idle ? sch.settings.idle : sch.settings.active)' 'readonly property bool armed: sch.on' ;;
    esac
}

run_one() {   # run_one <log>
    local log=$1 priv
    priv=$(mktemp -d "$D/w.XXXXXX")
    mkdir -p "$priv/config/theme" "$priv/state"
    printf '{"theme":"eva","mode":"light"}\n' > "$priv/config/theme/state.json"
    env -u WAYLAND_DISPLAY XDG_STATE_HOME="$priv/state" XDG_CONFIG_HOME="$priv/config" SHELL_SERVICES=mock QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        timeout 300 quickshell -p tools/dev/qml/flourish_pool_probe.qml > "$log" 2>&1
}

judge() {   # judge <arm|"">
    local arm=$1 log needle res
    if [ -n "$arm" ]; then arm_apply "$arm" || return 3; fi
    log="$D/log"
    run_one "$log"
    rl_clean "$log" | grep -a -o 'FLPOOL .*' | grep -a -v 'FLPOOL RESULT' | grep -a -E "$([ -n "${VERBOSE:-}" ] && echo . || echo '^FLPOOL (FAIL|drawn|registered)')" || true
    if [ -n "$arm" ]; then
        needle=$(arm_needle "$arm")
        if rl_clean "$log" | grep -a -q 'FLPOOL ARM anchor gone'; then echo "ARM $arm: the anchor is gone"; return 1; fi
        if rl_clean "$log" | grep -a "FLPOOL FAIL" | grep -aqF -- "$needle"; then echo "ARM $arm: failed as it must ('$needle')"; return 0; fi
        if ! rl_has "$log" 'FLPOOL RESULT'; then KEEP_D=1; echo "ARM $arm: the armed copy did not load -- it proves nothing ($log)"; return 1; fi
        echo "ARM $arm: DID NOT FAIL on '$needle'"; rl_clean "$log" | grep -a "FLPOOL FAIL" | head -3; return 1
    fi
    res=$(rl_result FLOURISH_POOL "$log" 'FLPOOL RESULT .*') || true
    printf '%s\n' "$res" | sed 's/^FLPOOL RESULT/FLOURISH_POOL RESULT/'
    if rl_isnoresult "$res"; then KEEP_D=1; return 1; fi
    case $res in *PASS*) return 0 ;; esac
    return 1
}

if [ -n "${ARM:-}" ]; then
    if [ "$ARM" = all ]; then
        bad=0
        # every arm patches the copy in place: put the armed files back before each one, or a later arm is judged on a tree that
        # still carries the earlier arms' faults (CLAUDE.md, the arm laws)
        ARMED=(modules/shell/ShellFrame.qml modules/bar/reel/ReelFlourishes.qml modules/common/flourish/FlourishRegistry.qml
            modules/common/flourish/FlourishScheduler.qml)
        ORIG="$(mktemp -d "${TMPDIR:-/tmp}/flpool-orig.XXXXXX")"
        for f in "${ARMED[@]}"; do mkdir -p "$ORIG/$(dirname "$f")" && cp -p "$f" "$ORIG/$f"; done
        for a in ${ONLY_ARMS:-nogate firepath staleheld configoff}; do
            for f in "${ARMED[@]}"; do cp -p "$ORIG/$f" "$f"; done
            ( cd "$(pwd)" && ARM=$a FLPOOL_INNER=1 bash tools/dev/flourish_pool_probe.sh ) || bad=1
        done
        for f in "${ARMED[@]}"; do cp -p "$ORIG/$f" "$f"; done
        rm -rf "$ORIG"
        exit $bad
    fi
    judge "$ARM"
    exit $?
fi
judge ""
