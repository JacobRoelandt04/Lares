#!/usr/bin/env bash
# Run mockups/osd.qml in the sandbox with PRIVATE XDG dirs.
#
#   tools/dev/osd_mockup.sh                      smoke: load, report every warning
#   tools/dev/osd_mockup.sh run                  interactive, on the desktop (private XDG)
#   tools/dev/osd_mockup.sh grab OUT.png         a grab of the stage after GRAB_MS (OSD_ACT scripts the state)
#   tools/dev/osd_mockup.sh film OUT.png "ms,ms,..."
#                                            ONE run of the OSD_ACT script, a grab of the stage at each
#                                            ms, the crops assembled left to right into OUT.png
#                                            (FILM_CROP=x,y,w,h in stage px to crop each frame; FILM_LABELS=1
#                                            prints each frame's ms on it)
#   tools/dev/osd_mockup.sh tabs DIR [t...]      the panel's tabs to PNG (tools/dev/mockup_grab.sh)
#   tools/dev/osd_mockup.sh panel                the framework's panel self-test (tools/dev/mockup_panel_test.sh)
#   MODE=dark ...                            the theme the private state file holds
#   OSD_ACT="verb[:arg]@ms,..."              the scripted state (see act() in mockups/osd.qml); passed through
#
# The service runs with live:false, so a run touches no Pipewire, backlight or Hyprland; and
# XDG_CONFIG_HOME / STATE / CACHE are private so the theme state the mockup persists is a
# scratch file (the sandbox copies the CONFIG, not the theme state).
#
# SAVE TO MOCKUP AND THE PROFILES WRITE THE REAL TREE (tools/dev/sandbox.sh hands the framework
# MOCKUP_REPO); smoke, grab and film press nothing.
#
# smoke, grab and film end on a verdict line: OSD-MOCKUP RESULT PASS|FAIL (exit 0 on PASS only).
# A warning fails; a run that produced nothing ends on `OSD-MOCKUP RESULT FAIL (no result: <log>)`
# (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-$HOME/.cache/claude-osd/O}"
W="$SCRATCH/osd_mockup"
MODE="${MODE:-light}"
mkdir -p "$W/xdg/config/theme" "$W/xdg/config/quickshell" "$W/xdg/state" "$W/xdg/cache" "$W/xdg/data"
printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$W/xdg/config/theme/state.json"
ENVS=(QT_QPA_PLATFORMTHEME=gtk3 NO_AT_BRIDGE=1 XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache"
      XDG_DATA_HOME="$W/xdg/data" QT_LOGGING_RULES="qt.qpa.services.warning=false;qt.qpa.theme.warning=false;qt.qpa.theme.dbus.warning=false;qt.qpa.theme.gnome.warning=false"
      OSD_ACT="${OSD_ACT:-}" SCRATCH="$W")
OFF=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off)
export SANDBOX="${SANDBOX:-$W/lares-sandbox}"

# warnings <log>: every distinct warning of a run, counted (none: nothing printed).
warnings() {
    rl_clean "$1" | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError" \
        | grep -v "quickshell.tooling" | sed 's/^ *//' | sort | uniq -c | head -30
}

case "${1:-smoke}" in
    smoke)
        log="$W/qml-smoke/osd.log"
        rm -f "$log"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" SECS="${SECS:-12}" tools/dev/smoke.sh mockups/osd.qml
        rc=$?
        rl_has "$log" "Configuration Loaded" || { rl_noresult OSD-MOCKUP "$log"; exit 1; }
        [ "$rc" = 0 ] && { echo "OSD-MOCKUP RESULT PASS (smoke clean)"; exit 0; }
        echo "OSD-MOCKUP RESULT FAIL (smoke: warnings, $log)"
        exit 1
        ;;
    grab)
        out="${2:?grab needs an output path}"
        log="$W/grab.log"
        rm -f "$out"
        rm -rf "$W/xdg/state"; mkdir -p "$W/xdg/state"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-1}" STAGE_GRAB="$out" GRAB_MS="${GRAB_MS:-3000}" \
            timeout "${SECS:-60}" quickshell -p mockups/osd.qml > "$log" 2>&1
        [ -s "$out" ] || { rl_noresult OSD-MOCKUP "$log"; exit 1; }
        echo "GRAB $out"
        w=$(warnings "$log")
        [ -z "$w" ] && { echo "OSD-MOCKUP RESULT PASS"; exit 0; }
        printf '%s\n' "$w"
        echo "OSD-MOCKUP RESULT FAIL (warnings: $log)"
        exit 1
        ;;
    film)
        out="${2:?film needs an output path}"
        at="${3:?film needs the grab times, ms,ms,...}"
        log="$W/film.log"
        base="$W/film_frame"
        rm -f "$out" "$base"_*.png
        rm -rf "$W/xdg/state"; mkdir -p "$W/xdg/state"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM=1 STAGE_GRAB="$base" STAGE_FILM="$at" \
            timeout "${SECS:-90}" quickshell -p mockups/osd.qml > "$log" 2>&1
        n=$(printf '%s' "$at" | tr ',' '\n' | grep -c .)
        have=$(ls "$base"_*.png 2>/dev/null | wc -l)
        [ "$have" = "$n" ] || { echo "film: $have of $n frames"; rl_noresult OSD-MOCKUP "$log"; exit 1; }
        python3 - "$out" "$base" "$at" "${FILM_CROP:-}" "${FILM_LABELS:-1}" <<'PY'
import sys
from PIL import Image, ImageDraw
out, base, at, crop, labels = sys.argv[1:6]
times = [int(x) for x in at.split(",") if x]
frames = []
for i, t in enumerate(times):
    im = Image.open("%s_%d.png" % (base, i)).convert("RGB")
    if crop:
        x, y, w, h = [int(v) for v in crop.split(",")]
        im = im.crop((x, y, x + w, y + h))
    frames.append(im)
w = sum(f.width for f in frames) + 6 * (len(frames) - 1)
h = max(f.height for f in frames) + (16 if labels == "1" else 0)
sheet = Image.new("RGB", (w, h), (255, 255, 255))
x = 0
d = ImageDraw.Draw(sheet)
for t, f in zip(times, frames):
    sheet.paste(f, (x, 16 if labels == "1" else 0))
    if labels == "1":
        d.text((x + 3, 2), "%d ms" % t, fill=(0, 0, 0))
    x += f.width + 6
sheet.save(out)
PY
        echo "FILM $out"
        w=$(warnings "$log")
        [ -z "$w" ] && { echo "OSD-MOCKUP RESULT PASS"; exit 0; }
        printf '%s\n' "$w"
        echo "OSD-MOCKUP RESULT FAIL (warnings: $log)"
        exit 1
        ;;
    tabs)
        out="${2:?tabs needs an output dir}"
        shift 2
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-0.8}" tools/dev/mockup_grab.sh mockups/osd.qml "$out" "$@"
        ;;
    panel)
        P="$W/xdg-panel"
        rm -rf "$P"; mkdir -p "$P/config/theme" "$P/config/quickshell"
        printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$P/config/theme/state.json"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" XDG_CONFIG_HOME="$P/config" tools/dev/mockup_panel_test.sh mockups/osd.qml
        ;;
    run)
        tools/dev/sandbox.sh "${ENVS[@]}" quickshell -p mockups/osd.qml
        ;;
    *)
        sed -n '2,20p' "$0" | sed 's/^# \?//'
        exit 2
        ;;
esac
