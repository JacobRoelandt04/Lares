#!/usr/bin/env bash
# bridge_resize_probe.sh -- the cast's popup resized by its edge, and the way back to the controls (tools/dev/qml/bridge_resize_probe.qml:
# r1 no step back while dragged, r2 the drawn phone follows on every frame, r3 the size released is the size dragged to and the popup
# did not move, r5 the foot's middle moves it, r4 the back carries the size down with the page, r6 the reset eases home). The REAL BridgePopup on the REAL BridgeService, not live; offscreen (forced on the launch
# itself), a private sandbox copy and private homes. Nothing touches a phone, adb or a daemon.
#
#   tools/dev/bridge_resize_probe.sh            BRIDGE_RESIZE RESULT PASS | FAIL (<n>/<n>)
#   ARM=<name> / ARM=all                        a fault in a COPY; its check must fail
#     snapback   the popup's size is the zoom alone again, not tied to the page's going    -> r4
#     current    the dragged side is judged against the CURRENT size again (the flicker)     -> r1
#     onesided   a resize holds the opposite edge again (the popup walks)                    -> r3
#     nomove     the foot's middle is a plain resize edge again                              -> r5
#     jumpreset  the reset writes the resting size at once (no ease)                         -> r6
set -u
{
cd "$(dirname "$0")/../.." || exit 1
if [ -e .git ] && [ -z "${BRS_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-bridge-resize}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-/tmp/lares-sbx-bridge-resize}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi BRS_INNER=1 ARM="${ARM:-}" bash tools/dev/bridge_resize_probe.sh "$@"
fi
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-/tmp}"
NAME="BRIDGE_RESIZE"

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

run_once() {
    local tree log out rc
    tree=$(mktemp -d "$SCRATCH/brs.XXXXXX") || return 1
    rsync -a --exclude .git --exclude .qmlls.ini --exclude Screenshots ./ "$tree/" || return 1
    case "$1" in
        "") ;;
        current) arm "$tree/modules/bridge/BridgePopup.qml" 'dw >= dh ? w / 320 : h / 664' 'Math.abs(w / 320 - popup._zoom) > Math.abs(h / 664 - popup._zoom) ? w / 320 : h / 664' || return 3 ;;
        snapback) arm "$tree/modules/bridge/BridgePopup.qml" '1 + (popup.service.castScale - 1) * popup._castShare' '(popup._castShare > 0.999 ? popup.service.castScale : 1)' || return 3 ;;
        onesided) arm "$tree/modules/bridge/BridgePopup.qml" 'symmetric: true' 'symmetric: false' || return 3 ;;
        nomove) arm "$tree/modules/bridge/BridgePopup.qml" 'moveWidth: Math.round(120 * popup._zoom)' 'moveWidth: 0' || return 3 ;;
        jumpreset) arm "$tree/modules/bridge/BridgePopup.qml" '        resetClock.f = 0;
        resetAnim.restart();' '        popup.service.castScale = 1;
        popup.service.castShift = 0;' || return 3 ;;
        *) echo "unknown ARM $1"; return 3 ;;
    esac
    mkdir -p "$tree/xdg/config/theme" "$tree/xdg/state" "$tree/xdg/cache" "$tree/home"
    printf '{"theme":"eva","mode":"light"}\n' > "$tree/xdg/config/theme/state.json"
    log="$tree/run.log"
    ( cd "$tree" && env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$tree/xdg/config" XDG_STATE_HOME="$tree/xdg/state" XDG_CACHE_HOME="$tree/xdg/cache" HOME="$tree/home" GRAB_DIR="${GRAB_DIR:-}" \
        tools/dev/notifications_bus.sh timeout -k 2 120 quickshell -n -p tools/dev/qml/bridge_resize_probe.qml > "$log" 2>&1 )
    out=$(rl_result "$NAME" "$log" "BRIDGE_RESIZE RESULT .*")
    rc=$?
    printf '%s\n' "$out"
    rl_clean "$log" | rl_platform_noise | grep -a "BR " | head -12
    bad=$(rl_clean "$log" | rl_platform_noise | grep -a -E "WARN|ERROR" | grep -a -E "modules/bridge|Binding loop|Unable to assign|ReferenceError|TypeError" | head -4)
    if [ -n "$bad" ]; then echo "BR FAIL h: a warning that names the bridge:"; printf '%s\n' "$bad" | sed 's/^/    /'; rc=1; fi
    rl_isnoresult "$out" || rm -rf "$tree"
    return $rc
}

if [ "${ARM:-}" = all ]; then
    bad=0
    declare -A NEED=([snapback]="r4" [current]="r1" [onesided]="r3" [nomove]="r5" [jumpreset]="r6")
    for a in snapback current onesided nomove jumpreset; do
        o=$(run_once "$a" 2>&1); rc=$?
        if printf '%s\n' "$o" | grep -aq "BR FAIL ${NEED[$a]}:"; then echo "ARM $a: failed as it must (${NEED[$a]})"
        elif [ "$rc" = 0 ]; then echo "ARM $a: still PASSES (toothless)"; bad=1
        else echo "ARM $a: failed, but not at its own check: $(printf '%s\n' "$o" | grep -a 'FAIL' | head -2 | tr '\n' ';')"; bad=1; fi
    done
    echo "$NAME ARMS $([ "$bad" = 0 ] && echo PASS || echo FAIL)"
    exit $bad
fi
out=$(run_once "${ARM:-}" 2>&1); rc=$?
printf '%s\n' "$out"
echo "$NAME RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
exit $rc
}
