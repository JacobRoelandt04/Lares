#!/usr/bin/env bash
# The snapshots page as the update popup's secondary in the REAL engine (tools/dev/qml/snapshot_engine_probe.qml): the shell mockup's real ShellFrame on
# its mock services, offscreen, a sandbox copy, at scale 1 and 1.25, light and dark.
#
#   tools/dev/snapshot_engine_probe.sh [<out>]     last line: SNAPSHOT_ENGINE RESULT PASS|FAIL; <out>/engine_<tag>_<state>.png, log.txt
#   TAGS="s1_light"  the states to run (s1|s125 _ light|dark)
#   ARM=<name> tools/dev/snapshot_engine_probe.sh  a fault in the sandbox copy; the run must end FAIL with the named check red
#     noescape    the popup's stepBack never puts the page away      -> E7.detail FAILS
#     fixedheight the page asks a fixed height whatever its cards    -> E4.follow FAILS
#   ARM=all runs every arm on one state.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME=SNAPSHOT_ENGINE
OUT="${1:-${SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}}/snapshot_engine_probe}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [ "${ARM:-}" = all ] && [ -z "${SEP_INNER:-}" ]; then
    . "$ROOT/tools/dev/result_lib.sh"
    bad=0
    declare -A NEEDLE=([noescape]='E7.detail' [fixedheight]='E4.follow')
    for a in noescape fixedheight; do
        res=$(SANDBOX="/tmp/lares-sbx-sep-arm-$a" ARM=$a TAGS=s1_light "$ROOT/tools/dev/snapshot_engine_probe.sh" "$OUT/arm_$a" 2>&1)
        rm -rf "/tmp/lares-sbx-sep-arm-$a"
        if rl_isnoresult "$res"; then echo "  ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif printf '%s\n' "$res" | tail -1 | grep -q 'RESULT PASS'; then echo "  ARM $a: PASSED (it must fail)"; bad=1
        elif ! printf '%s\n' "$res" | grep -q "SE FAIL ${NEEDLE[$a]}:"; then echo "  ARM $a: failed, but NOT on ${NEEDLE[$a]}"; bad=1
        else echo "  ARM $a: failed as it must (incl. ${NEEDLE[$a]})"; fi
    done
    [ "$bad" = 0 ] && { echo "$NAME ARMS PASS"; exit 0; }
    echo "$NAME ARMS FAIL"; exit 1
fi
if [ -z "${SEP_INNER:-}" ]; then
    own=0
    [ -z "${SANDBOX:-}" ] && own=1
    export SANDBOX="${SANDBOX:-/tmp/lares-sbx-sep}"
    "$ROOT/tools/dev/sandbox.sh" -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= SEP_INNER=1 ARM="${ARM:-}" TAGS="${TAGS:-}" \
        tools/dev/snapshot_engine_probe.sh "$OUT"
    rc=$?
    [ "$own" = 1 ] && rm -rf "$SANDBOX"
    exit $rc
fi
[ -e .git ] && { echo "$NAME RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
arm_py() {
    python3 - "$1" "$2" "$3" <<'PY' || { echo "$NAME RESULT FAIL (ARM ${ARM:-}: its anchor is gone in $1)"; exit 1; }
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}
case "${ARM:-}" in
noescape) arm_py modules/bar/system_update/components/SystemUpdatePopup.qml '        root.secondaryOpen = false;
        return was;' '        root.secondaryOpen = false;
        return false;' ;;
fixedheight) arm_py modules/bar/system_update/snapshots/SnapshotsPage.qml 'readonly property real naturalHeight: Math.ceil(' 'readonly property real naturalHeight: 300 + 0 * Math.ceil(' ;;
"") ;;
*) echo "$NAME RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-sep.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gcc -shared -fPIC -O2 -o "$WORK/stillclock.so" tools/dev/sheet_stillclock.c -ldl || { echo "$NAME RESULT FAIL (no still clock)"; exit 1; }
python3 -B -c "import sys; sys.path.insert(0, 'tools/dev'); import sheet_render; sheet_render.png_gradient(sys.argv[1])" "$WORK/wall.png"
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done
cp tools/dev/qml/snapshot_engine_probe.qml mockups/zz_snapshot_engine.qml
. tools/dev/result_lib.sh
: > "$OUT/log.txt"
fail=0
for tag in ${TAGS:-s1_light s1_dark s125_light s125_dark}; do
    k=1; [ "${tag%%_*}" = s125 ] && k=1.25
    mode="${tag##*_}"
    d="$WORK/$tag"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt"
    chmod 700 "$d/rt"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/cfg/theme/state.json"
    printf '{"scale":{"global":%s,"popup":1}}\n' "$k" > "$d/state/lares-shell-mock/config/shell.json"
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QML_DISABLE_DISTANCEFIELD=1 QT_HASH_SEED=0 QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        LARES_SLEEP_MONITOR=off MOCKUP_REPO= SHELL_SERVICES=mock WALL="file://$WORK/wall.png" ZOOM=1 \
        SCALE="$k" BAR_RATIO=1 POPUP_RATIO=1 SE_OUT="$OUT" SE_TAG="$tag" \
        tools/dev/notifications_bus.sh timeout -k 5 300 env LD_PRELOAD="$WORK/stillclock.so" SHEET_NOW=1793199600 \
        quickshell -p mockups/zz_snapshot_engine.qml > "$d/log.txt" 2>&1
    cp "$d/log.txt" "$OUT/run_$tag.log"
    if ! rl_has "$d/log.txt" "qml: SE DONE"; then
        [ -n "${ARM:-}" ] && { echo "ARM $ARM: the armed copy did not load -- it proves nothing ($OUT/run_$tag.log)"; exit 1; }
        rl_noresult "$NAME" "$OUT/run_$tag.log"; exit 1
    fi
    rl_clean "$d/log.txt" | grep -a -oE 'qml: SE .*' | sed "s/^qml: SE /SE $tag /" | tee -a "$OUT/log.txt" | sed 's/^SE [a-z0-9_]* /SE /'
    rl_has "$d/log.txt" 'qml: SE DONE PASS' || fail=1
    noise=$(rl_clean "$d/log.txt" | rl_platform_noise | grep -E 'Binding loop|Unable to assign|non-existent property|TypeError|ReferenceError|snapshots/' | grep -v 'qml: SE ' | sed 's/^ *//' | sort | uniq -c | sort -rn)
    if [ -n "$noise" ]; then echo "SE $tag warnings FAIL  $(printf '%s\n' "$noise" | head -5 | tr '\n' ';')"; fail=1; fi
done
[ "$fail" = 0 ] && echo "$NAME RESULT PASS" || echo "$NAME RESULT FAIL"
exit "$fail"
