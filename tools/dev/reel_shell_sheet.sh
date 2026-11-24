#!/usr/bin/env bash
# tools/dev/reel_shell_sheet.sh -- the reel slot's strips over the popups of the REAL shell frame, as pictures (GooeyEngine: THE REEL
# PASS): the power and idle reels and the tray's strip, label and menu over a popup and over none, at rest and half merged into the bar;
# the film of a switch from one reel to the other; the film of a popup opened under an open reel.
#
#   tools/dev/reel_shell_sheet.sh <out> [cell ...]     cells as tools/dev/qml/reel_shell_sheet.qml reads them (default: the set below)
#   MODES=light,dark   the theme modes rendered (light)
#   TREE=<dir>         render ANOTHER tree (an old revision: `git archive <rev> | tar -x -C <dir>`): the harness and this runner are
#                      laid into a copy of it, nothing else of this tree (the harness uses only what both have)
#   SCALE=             the shell's global scale (1.25: the user's panel at 2880 x 1620)
#
# Every cell runs offscreen in a tools/dev/sandbox.sh copy (SANDBOX, default /tmp/lares-sandbox-reelshell), on the shell's mock services, a
# private session bus, private XDG homes with the theme state seeded, the user's halo and ring (tools/dev/sheet_user_shell.jsonc), the
# still wall clock and the fixed gradient wallpaper of tools/dev/sheet_render.py. <out>/<mode>/<cell>.png are the stage (2880 x 1620), <out>/<mode>/log.txt the harness's RSCELL lines
# (the reel's, the popup's and the levels' boxes in stage px: tools/dev/reel_ring_compose.py --boxes crops round them).
# Ends in REEL_SHELL_SHEET RESULT PASS|FAIL: PASS when the harness finished every cell, every cell has its picture and the log
# holds no QML warning.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: reel_shell_sheet.sh <out> [cell ...]}"
shift
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
CELLS=("$@")
if [ ${#CELLS[@]} -eq 0 ]; then
    # (what the shell's layout really puts under a reel: the notes and the LLM, out of the left bar into the reels' corner, and the theme
    # popup under the left island; the clipboard hangs from the bottom edge and the weather from the centre island, never under one)
    CELLS=("notes_power_rest=notes:power:rest" "notes_idle_rest=notes:idle:rest" "notes_power_merge=notes:power:merge" "notes_idle_merge=notes:idle:merge"
           "theme_power_rest=theme:power:rest" "theme_idle_rest=theme:idle:rest" "theme_tray_rest=theme:tray:rest"
           "theme_traylabel_rest=theme:traylabel:rest" "theme_traymenu_rest=theme:traymenu:rest" "theme_tray_merge=theme:tray:merge"
           "llm_power_rest=llm:power:rest" "llm_idle_rest=llm:idle:rest" "llm_traymenu_rest=llm:traymenu:rest"
           "none_power_rest=none:power:rest" "none_idle_rest=none:idle:rest" "none_tray_rest=none:tray:rest"
           "none_traylabel_rest=none:traylabel:rest" "none_traymenu_rest=none:traymenu:rest"
           "none_power_merge=none:power:merge" "none_idle_merge=none:idle:merge" "none_tray_merge=none:tray:merge"
           "sw=notes:power:to-idle:10" "sw2=notes:idle:to-power:10" "key=none:idle:open-notes:14" "keyp=none:power:open-notes:14")
fi
JOINED=$(IFS=';'; echo "${CELLS[*]}")

if [ -n "${TREE:-}" ] && [ -z "${RSS_TREE_DONE:-}" ]; then
    T="$(cd "$TREE" && pwd)"
    mkdir -p "$T/tools/dev/qml"
    cp "$ROOT/tools/dev/reel_shell_sheet.sh" "$T/tools/dev/"
    cp "$ROOT/tools/dev/qml/reel_shell_sheet.qml" "$T/tools/dev/qml/"
    exec env RSS_TREE_DONE=1 TREE= "$T/tools/dev/reel_shell_sheet.sh" "$OUT" "${CELLS[@]}"
fi

if [ -z "${RSS_INNER:-}" ]; then
    own=0
    [ -z "${SANDBOX:-}" ] && own=1          # a copy the caller named is the caller's to remove
    export SANDBOX="${SANDBOX:-/tmp/lares-sandbox-reelshell}"
    "$ROOT/tools/dev/sandbox.sh" -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen MOCKUP_REPO= RSS_INNER=1 \
        tools/dev/reel_shell_sheet.sh "$OUT" "${CELLS[@]}"
    rc=$?
    [ "$own" = 1 ] && rm -rf "$SANDBOX"
    exit $rc
fi

# ---- inside the copy -------------------------------------------------------------------------------------------------
[ -e .git ] && { echo "REEL_SHELL_SHEET RESULT FAIL (the inner run stands in a work tree, not a sandbox copy)"; exit 1; }
. tools/dev/result_lib.sh
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lares-rss.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
gcc -shared -fPIC -O2 -o "$WORK/stillclock.so" tools/dev/sheet_stillclock.c -ldl || { echo "REEL_SHELL_SHEET RESULT FAIL (no still clock)"; exit 1; }
python3 -B -c "import sys; sys.path.insert(0, 'tools/dev'); import sheet_render; sheet_render.png_gradient(sys.argv[1])" "$WORK/wall.png"
mkdir -p "$WORK/stubs"
for prog in nvidia-smi nvidia-modprobe systemd-run; do printf '#!/bin/sh\nexit 1\n' > "$WORK/stubs/$prog"; chmod +x "$WORK/stubs/$prog"; done

# the harness beside the shell mockup it builds (quickshell serves nothing outside the run file's directory); in the copy only
cp tools/dev/qml/reel_shell_sheet.qml mockups/zz_reel_shell_sheet.qml
# (RSS_LIVE_CLOCK=1: the wall clock left running, for the harness's `opengap`, which reads it; pictures then carry the hour)
STILL="$WORK/stillclock.so"
[ -n "${RSS_LIVE_CLOCK:-}" ] && STILL=""
IFS=',' read -r -a MODELIST <<< "${MODES:-light}"
bad=0
for mode in "${MODELIST[@]}"; do
    d="$WORK/$mode"
    mkdir -p "$d/cfg/theme" "$d/state/lares-shell-mock/config" "$d/cache" "$d/data" "$d/rt" "$OUT/$mode"
    chmod 700 "$d/rt"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/cfg/theme/state.json"
    # the user's edge (the halo and the ring: the kit's stand-in for their shell.jsonc, never the live file)
    cp tools/dev/sheet_user_shell.jsonc "$d/state/lares-shell-mock/config/shell.jsonc"
    for c in "${CELLS[@]}"; do rm -f "$OUT/$mode/${c%%=*}".png "$OUT/$mode/${c%%=*}"_f*.png; done
    # (the environment emptied BEFORE the private bus: dbus-run-session hands its own address to the command)
    env -i \
        HOME="$HOME" USER="${USER:-user}" PATH="$WORK/stubs:$PATH" DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TZ=Europe/Brussels \
        XDG_RUNTIME_DIR="$d/rt" XDG_CONFIG_HOME="$d/cfg" XDG_STATE_HOME="$d/state" XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= QT_LOGGING_RULES=qt.qpa.services.warning=false \
        QML_DISABLE_DISTANCEFIELD=1 QT_HASH_SEED=0 QS_ICON_THEME=Papirus QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        LARES_SLEEP_MONITOR=off MOCKUP_REPO= SHELL_SERVICES=mock WALL="file://$WORK/wall.png" ZOOM=1 \
        SCALE="${SCALE:-1.25}" BAR_RATIO="${BAR_RATIO:-1}" POPUP_RATIO="${POPUP_RATIO:-1}" \
        RS_OUT="$OUT/$mode" RS_CELLS="$JOINED" RS_MERGE_T="${MERGE_T:-0.25}" RS_DEBUG="${RS_DEBUG:-}" RS_SLOW="${RS_SLOW:-8}" \
        tools/dev/notifications_bus.sh timeout -k 5 "${RSS_TIMEOUT:-1500}" env LD_PRELOAD="$STILL" SHEET_NOW=1793199600 \
        quickshell -p mockups/zz_reel_shell_sheet.qml > "$OUT/$mode/log.txt" 2>&1
    log="$OUT/$mode/log.txt"
    n=$(rl_clean "$log" | grep -ac 'RSCELL ')
    echo "rendered $mode: $n grabs"
    rl_clean "$log" | grep -a 'RSSHEET FAIL' | sed 's/^.*RSSHEET FAIL/FAIL/'
    rl_has "$log" 'RSSHEET DONE' || { echo "FAIL $mode: the harness did not finish ($log)"; bad=$((bad + 1)); }
    [ "$(rl_clean "$log" | grep -ac 'RSSHEET FAIL')" -gt 0 ] && bad=$((bad + 1))
    warn=$(rl_clean "$log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified|Failed to find shader|does not have a matching|No shader found" | rl_platform_noise | head -5)
    [ -n "$warn" ] && { printf 'WARN %s\n' "$warn"; bad=$((bad + 1)); }
    for png in $(rl_clean "$log" | sed -n 's/^.*RSCELL \([^ ]*\) .*$/\1/p'); do
        [ -s "$OUT/$mode/$png.png" ] || { echo "FAIL $mode: no picture of $png"; bad=$((bad + 1)); }
    done
done
if [ "$bad" = 0 ]; then echo "REEL_SHELL_SHEET RESULT PASS (${#CELLS[@]} cells, modes ${MODES:-light})"; exit 0; fi
echo "REEL_SHELL_SHEET RESULT FAIL ($bad faults: $OUT)"
exit 1
