#!/usr/bin/env bash
# The MUX keep prompt is ONE TOAST (SiliconMuxWatcher + MuxKeepPrompt; round 11: "I'd rather have the confirmation to be in a toast"),
# put up only once the session is UNLOCKED and the shell is on the glass (round 7: the dGPU boot of 2026-11-10 started under the boot
# lock, the 15 s of retries ran out there and the prompt never came by itself). The helper is told it is up only when the toast is
# on the glass; the card's drain carries the helper's own deadline; Keep and Go back now reach the helper's calls; the lock takes the
# toast away and the unlock gives it back. The watcher on a stub notification service and a stub view model
# (tools/dev/qml/silicon_mux_watcher_probe.qml), offscreen in the sandbox.
#
#   tools/dev/silicon_mux_watcher_probe.sh          last line: SILICON-MUX-WATCHER RESULT PASS|FAIL
#   ARM=nolock      the watcher ignores the lock                    -> locked-no-post FAILS
#   ARM=noshown     the watcher ignores whether the frame is shown  -> unshown-no-post FAILS
#   ARM=budget      the prompt gives up 1.3 s after its start (the old retry budget, counted from the start, not from the unlock) -> long-lock-then-unlock-posts FAILS
#   ARM=lockkeeps   a lock that takes the toast away leaves the prompt "handled" -> unlock-gives-it-back FAILS
#   ARM=noglass     the helper is told when the toast is posted, not when it is on the glass -> not-told-before-glass FAILS
#   ARM=nodeadline  the drain carries no deadline                    -> deadline-on-record FAILS
#   ARM=nokeepcall  Keep does not reach the helper                   -> keep-reaches-the-helper FAILS
#   ARM=norestart   Go back now never asks for the restart           -> goback-keeps-asks-restarts FAILS
#   ARM=swipeable   the toast is not fixed (the user could swipe it away) -> toast-is-fixed FAILS
#   ARM=all         every ARM; SILICON-MUX-WATCHER ARMS PASS when each one failed
#   RENDER=<dir>    instead of the probe: the keep toast as the shell draws it (tools/dev/qml/silicon_mux_toast_render.qml: the real watcher on
#                   a SiliconMock, the real NotificationService and ToastEntry), light mid-countdown, dark, and on the way back, as PNGs in <dir>
#                   (ask_early / ask_mid / ask_dark / back); the drain is checked against the helper's deadline. WINDOW_S (keep window, default
#                   20), SCALE (default 2). Last line: SILICON-MUX-TOAST-RENDER RESULT PASS|FAIL.
#                   ARM=nodrain  the card ignores the record's deadline (ToastEntry follows the scheduler only: sticky) -> the drain check FAILS
cd "$(dirname "$0")/../.." || exit 1
[ -n "${RENDER:-}" ] && RENDER="$(realpath -m "$RENDER")"
if [ -e .git ] && [ -z "${SMW_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-silicon-mux-watcher}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SMW_INNER=1 ARM="${ARM:-}" RENDER="${RENDER:-}" bash tools/dev/silicon_mux_watcher_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="SILICON-MUX-WATCHER"

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

run_once() {  # arm -> prints the verdict, returns its status
    local tree log out rc N=modules/silicon/SiliconMuxWatcher.qml P=modules/silicon/MuxKeepPrompt.qml
    tree=$(mktemp -d "$SCRATCH/smw.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        nolock) arm "$tree/$N" 'readonly property bool _ready: !root.locked && root.shown' 'readonly property bool _ready: root.shown' || return 3 ;;
        noshown) arm "$tree/$N" 'readonly property bool _ready: !root.locked && root.shown' 'readonly property bool _ready: !root.locked' || return 3 ;;
        budget) arm "$tree/$P" '    property bool _glass: false' '    property bool _glass: false
    property real _t0: Date.now()' || return 3
                arm "$tree/$P" '        const want = root.ready &&' '        const want = Date.now() - root._t0 < 1300 && root.ready &&' || return 3 ;;
        lockkeeps) arm "$tree/$P" '    property bool _glass: false' '    property bool _glass: false
    property bool _once: false' || return 3
                arm "$tree/$P" '        if (root._uid === "" || root._postedPhase !== root.phase)
            root._post();' '        if (!root._once || (root._uid !== "" && root._postedPhase !== root.phase)) {
            root._once = true;
            root._post();
        }' || return 3 ;;
        noglass) arm "$tree/$P" 'root._glass = !!t && t.shown.indexOf(root._uid) >= 0 && !t.blocked && !t.unplaced;' 'root._glass = root._uid !== "";' || return 3 ;;
        nodeadline) arm "$tree/$P" '        root._bus.update(root._uid, { deadlineMs: end, deadlineTotalMs: root._totalMs });' '        void end;' || return 3 ;;
        nokeepcall) arm "$tree/$P" '        keepGuard.restart();
        root.vm.muxKeep();' '        keepGuard.restart();' || return 3 ;;
        norestart) arm "$tree/$P" 'if (!root.vm.muxRebootNow())' 'if (false)' || return 3 ;;
        swipeable) arm "$tree/$P" 'timeoutMs: -1, fixed: true,' 'timeoutMs: -1, fixed: false,' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    log="$tree/run.log"
    ( cd "$tree" && env XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" HOME="$tree/home" \
        tools/dev/notifications_bus.sh timeout 60 quickshell -n -p tools/dev/qml/silicon_mux_watcher_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "MUXW RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "MUXW .*FAIL" | head -4
    rl_isnoresult "$out" || rm -rf "$tree"   # a no-result verdict names the log: keep it
    return $rc
}

render() {  # <outdir> -- the keep toast rendered; the verdict is the harness's own TOASTR RESULT line
    local out_dir="$1" work log out rc
    case "${ARM:-}" in
        "") ;;
        nodrain) arm modules/notifications/toast/ToastEntry.qml 'readonly property real _deadlineMs: !!entry.d && entry.d.deadlineMs > 0 && entry.d.deadlineTotalMs > 0 ? entry.d.deadlineMs : 0' 'readonly property real _deadlineMs: 0' || return 3 ;;
        *) echo "unknown ARM ${ARM}"; return 3 ;;
    esac
    work=$(mktemp -d "$SCRATCH/smwr.XXXXXX") || return 1
    mkdir -p "$out_dir" "$work/xdg/config/theme" "$work/xdg/state" "$work/xdg/cache" "$work/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$work/xdg/config/theme/state.json"
    log="$out_dir/run.log"
    env XDG_CONFIG_HOME="$work/xdg/config" XDG_STATE_HOME="$work/xdg/state" XDG_CACHE_HOME="$work/xdg/cache" HOME="$work/home" OUT_DIR="$out_dir" \
        QML_DISABLE_DISTANCEFIELD=1 tools/dev/notifications_bus.sh timeout 150 quickshell -n -p tools/dev/qml/silicon_mux_toast_render.qml > "$log" 2>&1
    out=$(rl_result "SILICON-MUX-TOAST-RENDER" "$log" "TOASTR RESULT .*")
    rc=$?
    rm -rf "$work"
    printf '%s\n' "$out"
    rl_clean "$log" | grep -a "TOASTR" | head -12
    # the render never loaded: result_lib's verdict (printed above) is the last word
    rl_isnoresult "$out" && return 1
    [ -f "$out_dir/ask_mid.png" ] || rc=1
    echo "SILICON-MUX-TOAST-RENDER RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
    return $rc
}
if [ -n "${RENDER:-}" ]; then
    render "$RENDER"
    exit $?
fi

if [ "${ARM:-}" = all ]; then
    bad=0
    for a in nolock noshown budget lockkeeps noglass nodeadline nokeepcall norestart swipeable; do
        o=$(run_once "$a"); rc=$?
        if rl_isnoresult "$o"; then echo "ARM $a: did not load (proves nothing)"; bad=1
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed as it must ($(printf '%s\n' "$o" | grep -a 'MUXW .*FAIL' | head -2 | tr '\n' ';'))"; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}"); rc=$?
printf '%s\n' "$out"
if rl_isnoresult "$out"; then
    # the probe never loaded: result_lib's verdict (printed above) is the last word
    [ -n "${ARM:-}" ] && echo "ARM ${ARM}: the armed copy did not load -- it proves nothing"
    exit 1
fi
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
