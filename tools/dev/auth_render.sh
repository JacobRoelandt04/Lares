#!/usr/bin/env bash
# Run mockups/auth.qml in the sandbox, offscreen, on a PRIVATE bus with PRIVATE XDG dirs.
#
#   tools/dev/auth_render.sh smoke                  load it, report every warning
#   tools/dev/auth_render.sh grab OUT.png           one grab of the stage
#                                               (AUTH_STATE=scan|typed|checking|failed|ok, MODE=light|dark,
#                                                HOST=lane|pill, HOWDY=native|off, GRAB_MS, ZOOM)
#   tools/dev/auth_render.sh states OUTDIR          every state x light/dark in the lane, the pill in both
#                                               themes, a sheet per theme (PIL) -- LOOK at them
#   tools/dev/auth_render.sh run                    interactive on the desktop (still a private bus)
#
# The mockup runs the notification service in-process with no bus name
# (`serverEnabled: false`) and a stand-in polkit flow, so nothing touches mako,
# polkit or the user's history; it still starts under tools/dev/notifications_bus.sh
# (a bus with no activatable services) and with private config / state / cache,
# so the theme it follows is the state file written here, never the user's.
# GRAB states are timed: the card jumps to its state 300 ms after load; GRAB_MS
# is when the picture is taken (the failed state's error flush is at its peak
# around 700 ms, easing back by ~1300).
#
# smoke, grab and states end on `AUTH-RENDER RESULT PASS|FAIL`; no result at all
# (the configuration never loaded) is `AUTH-RENDER RESULT FAIL (no result: <log>)`
# (tools/dev/result_lib.sh). A warning fails.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-$HOME/.cache/claude-auth/U}"
W="$SCRATCH/auth_render"
MODE="${MODE:-light}"
export SANDBOX="${SANDBOX:-$W/lares-sandbox}"
BUS=(tools/dev/notifications_bus.sh)

env_for() {  # env_for <mode> [state] [host] -> sets ENVS, a private tree per mode
    local mode="$1" d="$W/xdg-$1" st="${2:-${AUTH_STATE:-}}" host="${3:-${HOST:-lane}}"
    mkdir -p "$d/config/theme" "$d/config/quickshell" "$d/state" "$d/cache" "$d/data"
    printf '{"theme":"eva","mode":"%s"}\n' "$mode" > "$d/config/theme/state.json"
    ENVS=(QT_QPA_PLATFORMTHEME=gtk3 NO_AT_BRIDGE=1 XDG_CONFIG_HOME="$d/config" XDG_STATE_HOME="$d/state"
          XDG_CACHE_HOME="$d/cache" XDG_DATA_HOME="$d/data" SCRATCH="$W"
          QT_LOGGING_RULES="qt.qpa.services.warning=false;qt.qpa.theme.warning=false;qt.qpa.theme.dbus.warning=false;qt.qpa.theme.gnome.warning=false"
          AUTH_STATE="$st" HOST="$host" HOWDY="${HOWDY:-native}")
}
OFF=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off)

warnings() {
    rl_clean "$1" | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError" \
        | grep -v "quickshell.tooling" | sed 's/^ *//' | sort | uniq -c | head -30
}

# grab <out.png> <log>: one grab with the current ENVS; 0 when a picture came out.
grab_one() {
    local out="$1" log="$2"
    rm -f "$out"
    tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-1}" STAGE_GRAB="$out" GRAB_MS="${GRAB_MS:-1500}" \
        timeout "${SECS:-60}" "${BUS[@]}" quickshell -p mockups/auth.qml > "$log" 2>&1
    [ -s "$out" ]
}

case "${1:-smoke}" in
    smoke)
        env_for "$MODE"
        log="$W/qml-smoke/auth.log"
        rm -f "$log"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" SECS="${SECS:-10}" "${BUS[@]}" tools/dev/smoke.sh mockups/auth.qml
        rc=$?
        rl_has "$log" "Configuration Loaded" || { rl_noresult AUTH-RENDER "$log"; exit 1; }
        [ "$rc" = 0 ] && { echo "AUTH-RENDER RESULT PASS (smoke clean)"; exit 0; }
        echo "AUTH-RENDER RESULT FAIL (smoke: warnings, $log)"
        exit 1
        ;;
    grab)
        out="${2:?grab needs an output path}"
        env_for "$MODE"
        log="$W/grab.log"
        grab_one "$out" "$log" || { rl_noresult AUTH-RENDER "$log"; exit 1; }
        echo "GRAB $out"
        w=$(warnings "$log")
        [ -z "$w" ] && { echo "AUTH-RENDER RESULT PASS"; exit 0; }
        printf '%s\n' "$w"
        echo "AUTH-RENDER RESULT FAIL (warnings: $log)"
        exit 1
        ;;
    states)
        out="${2:?states needs an output dir}"
        mkdir -p "$out"
        bad=0
        # state:grab_ms -- the failed flush is read near its peak, the rest at rest
        for mode in light dark; do
            for spec in lane:scan:1800 lane:typed:1800 lane:checking:1800 lane:failed:1000 lane:ok:2200 pill:typed:1800; do
                IFS=: read -r host st ms <<< "$spec"
                env_for "$mode" "$st" "$host"
                png="$out/${host}_${st}_${mode}.png"
                log="$W/grab_${host}_${st}_${mode}.log"
                if ! (GRAB_MS="$ms" grab_one "$png" "$log"); then
                    rl_noresult AUTH-RENDER "$log"; bad=1; continue
                fi
                w=$(warnings "$log")
                [ -n "$w" ] && { printf '%s\n' "$w"; bad=1; }
                echo "GRAB $png"
            done
        done
        python3 - "$out" <<'PY'
import sys, os
from PIL import Image, ImageDraw
out = sys.argv[1]
for mode in ("light", "dark"):
    names = [f"lane_{s}_{mode}" for s in ("scan", "typed", "checking", "failed", "ok")] + [f"pill_typed_{mode}"]
    ims = []
    for n in names:
        p = os.path.join(out, n + ".png")
        if os.path.exists(p):
            im = Image.open(p).convert("RGB")
            # the toast hangs under the top bar's right end, the pill stands top centre
            box = (520, 0, 900, 330) if n.startswith("lane") else (240, 30, 660, 330)
            ims.append((n, im.crop(box)))
    if not ims:
        continue
    w, h = ims[0][1].size
    cols = 3
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * w, rows * (h + 20)), (255, 255, 255))
    d = ImageDraw.Draw(sheet)
    for i, (n, im) in enumerate(ims):
        x, y = (i % cols) * w, (i // cols) * (h + 20)
        d.text((x + 6, y + 4), n, fill=(0, 0, 0))
        sheet.paste(im.resize((w, h)), (x, y + 20))
    sheet.save(os.path.join(out, f"sheet_{mode}.png"))
    print("SHEET", os.path.join(out, f"sheet_{mode}.png"))
PY
        [ "$bad" = 0 ] && { echo "AUTH-RENDER RESULT PASS"; exit 0; }
        echo "AUTH-RENDER RESULT FAIL"
        exit 1
        ;;
    run)
        env_for "$MODE"
        tools/dev/sandbox.sh "${ENVS[@]}" "${BUS[@]}" quickshell -p mockups/auth.qml
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \?//'
        exit 2
        ;;
esac
