#!/usr/bin/env bash
# toast_routes_probe.sh -- how three behaviours are TIED, on the real ShellServices (mock services) and two real ShellFrames, offscreen
# (tools/dev/qml/toast_routes_probe.qml): a click on a timer / alarm / pomodoro toast opens the clock on its Timers tab on the FOCUSED
# screen; a click on a network toast opens the network popup there; a right click on the player's bar disc plays / pauses.
#
#   tools/dev/toast_routes_probe.sh              TOAST_ROUTES RESULT PASS | FAIL
#   ARM=<name> tools/dev/toast_routes_probe.sh   one fault in a SANDBOX copy; it must FAIL on its check's own needle
#   ARM=all                                      every arm (ONLY_ARMS="a b" narrows it): TOAST_ROUTES ARMS RESULT PASS when each failed on its needle
#     notimersroute  ShellServices drops the timers' openRequested Connections  -> "R1 countdown: the click opens the clock on DP-2"
#     noaerialroute  ShellServices drops the aerial openRequested Connections   -> "R2 the click opens the network popup on DP-2"
#     nodefault      DesktopNotifier stops passing onDefault to the bus         -> "R2 the network failure is one toast of the aerial source, with a body-click default"
#     nouserdefault  TimerService posts no `default` action                     -> "R1 the countdown toast is the clock's, with a body-click default"
#     nofocus        the clock route takes the FIRST screen, not the focused    -> "R1 countdown: the click opens the clock on DP-2"
#     norightclick   ShellFrame drops the right-click branch of the disc        -> "R3 a right click on the disc plays"
#
# Private XDG dirs (theme state seeded), no real daemon: the mock mpd, the mock aerial, a private bus-less notification service.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh

if [ -e .git ] && [ -z "${TOASTR_INNER:-}" ]; then
    export TOASTR_INNER=1
    exec tools/dev/sandbox.sh env QT_QPA_PLATFORM=offscreen TOASTR_INNER=1 ARM="${ARM:-}" ONLY_ARMS="${ONLY_ARMS:-}" KEEP="${KEEP:-}" bash tools/dev/toast_routes_probe.sh "$@"
fi

D="$(mktemp -d "${SCRATCH:-/tmp}/toastr.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT

arm_needle() {
    case $1 in
        notimersroute) echo "R1 countdown: the click opens the clock on DP-2" ;;
        noaerialroute) echo "R2 the click opens the network popup on DP-2" ;;
        nodefault) echo "R2 the network failure is one toast of the aerial source, with a body-click default" ;;
        nouserdefault) echo "R1 the countdown toast is the clock's, with a body-click default" ;;
        nofocus) echo "R1 countdown: the click opens the clock on DP-2" ;;
        norightclick) echo "R3 a right click on the disc plays" ;;
    esac
}
patch() {   # patch <file> <old> <new>: exactly one match, or the run says so
    python3 - "$1" "$2" "$3" << 'PY' || { echo "TOASTR ARM anchor gone: $1"; exit 3; }
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
        notimersroute) patch modules/shell/ShellServices.qml '        target: timersService
        ignoreUnknownSignals: true' '        target: null
        ignoreUnknownSignals: true' ;;
        noaerialroute) patch modules/shell/ShellServices.qml '        target: services.aerial
        ignoreUnknownSignals: true
        function onOpenRequested() {' '        target: null
        ignoreUnknownSignals: true
        function onOpenRequested() {' ;;
        nodefault) patch modules/common/components/DesktopNotifier.qml 'onDefault: typeof spec.onDefault === "function" ? spec.onDefault : null,' 'onDefault: null,' ;;
        nouserdefault) patch modules/clock/data/TimerService.qml 'actions: [open].concat(spec.actions || [])' 'actions: (spec.actions || [])' ;;
        nofocus) patch modules/shell/ShellServices.qml '            const o = services.focusedOwner("clock");
            if (o && o.openTimers)' '            const o = services.ownerOn(services.screenNames[0], "clock");
            if (o && o.openTimers)' ;;
        norightclick) patch modules/shell/ShellFrame.qml '                else if (button === Qt.RightButton && frame.services.mpd)' '                else if (false)' ;;
    esac
}

run_one() {   # run_one <log>
    local log=$1 priv
    priv=$(mktemp -d "$D/w.XXXXXX")
    mkdir -p "$priv/config/theme" "$priv/state" "$priv/cache"
    printf '{"theme":"eva","mode":"light"}\n' > "$priv/config/theme/state.json"
    env -u WAYLAND_DISPLAY XDG_STATE_HOME="$priv/state" XDG_CONFIG_HOME="$priv/config" XDG_CACHE_HOME="$priv/cache" SHELL_SERVICES=mock TOAST_ROUTES=1 \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout 300 quickshell -p tools/dev/qml/toast_routes_probe.qml > "$log" 2>&1
}

judge() {   # judge <arm|"">
    local arm=$1 log needle res
    if [ -n "$arm" ]; then arm_apply "$arm" || return 3; fi
    log="$D/log"
    run_one "$log"
    rl_clean "$log" | grep -a -o 'TOASTR .*' | grep -a -v 'TOASTR RESULT' | grep -a -E "$([ -n "${VERBOSE:-}" ] && echo . || echo '^TOASTR FAIL')" || true
    if [ -n "$arm" ]; then
        needle=$(arm_needle "$arm")
        if rl_clean "$log" | grep -a -q 'TOASTR ARM anchor gone'; then echo "ARM $arm: the anchor is gone"; return 1; fi
        if rl_clean "$log" | grep -a "TOASTR FAIL" | grep -aqF -- "$needle"; then echo "ARM $arm: failed as it must ('$needle')"; return 0; fi
        if ! rl_has "$log" 'TOASTR RESULT'; then KEEP_D=1; echo "ARM $arm: the armed copy did not load -- it proves nothing ($log)"; return 1; fi
        echo "ARM $arm: DID NOT FAIL on '$needle'"; rl_clean "$log" | grep -a "TOASTR FAIL" | head -3; return 1
    fi
    res=$(rl_result TOAST_ROUTES "$log" 'TOASTR RESULT .*') || true
    printf '%s\n' "$res" | sed 's/^TOASTR RESULT/TOAST_ROUTES RESULT/'
    if rl_isnoresult "$res"; then KEEP_D=1; return 1; fi
    case $res in *PASS*) return 0 ;; esac
    return 1
}

if [ -n "${ARM:-}" ]; then
    if [ "$ARM" = all ]; then
        bad=0
        ARMED=(modules/shell/ShellServices.qml modules/common/components/DesktopNotifier.qml modules/clock/data/TimerService.qml modules/shell/ShellFrame.qml)
        ORIG="$(mktemp -d "${TMPDIR:-/tmp}/toastr-orig.XXXXXX")"
        for f in "${ARMED[@]}"; do mkdir -p "$ORIG/$(dirname "$f")" && cp -p "$f" "$ORIG/$f"; done
        for a in ${ONLY_ARMS:-notimersroute noaerialroute nodefault nouserdefault nofocus norightclick}; do
            for f in "${ARMED[@]}"; do cp -p "$ORIG/$f" "$f"; done
            ( cd "$(pwd)" && ARM=$a TOASTR_INNER=1 bash tools/dev/toast_routes_probe.sh ) || bad=1
        done
        for f in "${ARMED[@]}"; do cp -p "$ORIG/$f" "$f"; done
        rm -rf "$ORIG"
        [ "$bad" = 0 ] && echo "TOAST_ROUTES ARMS RESULT PASS" || echo "TOAST_ROUTES ARMS RESULT FAIL"
        exit $bad
    fi
    judge "$ARM"
    exit $?
fi
judge ""
