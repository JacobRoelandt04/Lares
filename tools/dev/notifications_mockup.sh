#!/usr/bin/env bash
# Run mockups/notifications.qml in the sandbox, on a PRIVATE bus, with PRIVATE XDG dirs.
#
#   tools/dev/notifications_mockup.sh                 smoke: load, report every warning
#   tools/dev/notifications_mockup.sh grab OUT.png    a grab of the stage (STAGE_GRAB, GRAB_MS, SEND, OPEN)
#   tools/dev/notifications_mockup.sh run             interactive, on the desktop (still a private bus)
#   tools/dev/notifications_mockup.sh panel           the framework's panel self-test (tools/dev/mockup_panel_test.sh:
#                                                 marks, profiles, Save to mockup on copies), INPROC=1
#   tools/dev/notifications_mockup.sh tabs DIR [t...] the panel's tabs to PNG (tools/dev/mockup_grab.sh), INPROC=1
#   MODE=dark ...                                 the theme the private state file holds
#   LANE=stage|popup|lane  INPROC=1  SEND=signal,sms,...  OPEN=manager   passed through
#
# The service registers org.freedesktop.Notifications; on the user's bus that is
# mako's name, so every mode runs under tools/dev/notifications_bus.sh (a bus with no
# activatable services) -- except LIVE=1 run, which is the user's explicit choice
# and still asks inside the mockup before it touches mako. Private
# config/state/cache so no run ever writes the user's history, theme or icon
# cache; the icon cache persists across runs under $W/xdg/cache.
#
# SAVE TO MOCKUP AND THE PROFILES WRITE THE REAL TREE. The mockup runs from a
# sandbox copy, which tools/dev/sandbox.sh rsyncs with --delete on every call: a
# save or a profile written there reported success and was gone at the next
# launch (R2E P1.1). tools/dev/sandbox.sh hands the framework this tree
# (MOCKUP_REPO), so Save to mockup rewrites ./mockups/notifications.qml and the
# profiles live in ./mockup_profiles/notifications/; the panel self-test checks
# that the target is a git work tree. smoke, grab and tabs press nothing: they
# rewrite only the derived default.json there, and only while the copy's
# mockup is this one byte for byte.
#
# THIS IS THE ONLY SUPPORTED WAY TO RUN THE MOCKUP. Its Config tab writes
# notifications.json -- $W/xdg/config/quickshell/notifications.json, the private
# one the service hot-reloads (kept across `run`s, so the panel comes back as it
# was left; a grab starts without it) -- and it refuses to write when
# XDG_CONFIG_HOME is unset or is the user's own ~/.config.
#
# Icons: QT_QPA_PLATFORMTHEME=gtk3 (NO_AT_BRIDGE=1) -- with no platform theme Qt
# has no icon search paths at all and only /usr/share/pixmaps answers (R2B-T
# finding 4); the mockup names its theme itself (`//@ pragma IconTheme Papirus`).
# smoke and grab run with LARES_SLEEP_MONITOR=off (no gdbus monitor on the system
# bus for a scripted run); `run` follows a real suspend.
#
# smoke and grab end on a verdict line: NOTIF-MOCKUP RESULT PASS|FAIL, exit 0 on
# PASS only. A warning fails either. A run that produced no result (smoke: the
# configuration never loaded; grab: no picture was written) ends on
# `NOTIF-MOCKUP RESULT FAIL (no result: <log>)` after the log's load errors
# (tools/dev/result_lib.sh; tools/dev/runner_noload_check.sh proves it).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-$HOME/.cache/claude-notifications/U}"
W="$SCRATCH/notifications_mockup"
MODE="${MODE:-light}"
mkdir -p "$W/xdg/config/theme" "$W/xdg/config/quickshell" "$W/xdg/state" "$W/xdg/cache" "$W/xdg/data"
printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$W/xdg/config/theme/state.json"
ENVS=(QT_QPA_PLATFORMTHEME=gtk3 NO_AT_BRIDGE=1 XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache"
      XDG_DATA_HOME="$W/xdg/data" QT_LOGGING_RULES="qt.qpa.services.warning=false;qt.qpa.theme.warning=false;qt.qpa.theme.dbus.warning=false;qt.qpa.theme.gnome.warning=false"
      LANE="${LANE:-}" ACT="${ACT:-}" INPROC="${INPROC:-}" SEND="${SEND:-}" OPEN="${OPEN:-}" LIVE="${LIVE:-}"
      SCRATCH="$W")
OFF=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE= LARES_SLEEP_MONITOR=off)
export SANDBOX="${SANDBOX:-$W/lares-sandbox}"
BUS=(tools/dev/notifications_bus.sh)

# warnings <log>: every distinct warning of a run, counted (none: nothing printed).
warnings() {
    rl_clean "$1" | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError" \
        | grep -v "quickshell.tooling" | sed 's/^ *//' | sort | uniq -c | head -30
}

case "${1:-smoke}" in
    smoke)
        # tools/dev/smoke.sh writes its log under its SCRATCH, which ENVS makes $W.
        log="$W/qml-smoke/notifications.log"
        rm -f "$log"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" SECS="${SECS:-12}" "${BUS[@]}" tools/dev/smoke.sh mockups/notifications.qml
        rc=$?
        rl_has "$log" "Configuration Loaded" || { rl_noresult NOTIF-MOCKUP "$log"; exit 1; }
        [ "$rc" = 0 ] && { echo "NOTIF-MOCKUP RESULT PASS (smoke clean)"; exit 0; }
        echo "NOTIF-MOCKUP RESULT FAIL (smoke: warnings, $log)"
        exit 1
        ;;
    grab)
        out="${2:?grab needs an output path}"
        log="$W/grab.log"
        rm -f "$out"
        # A grab is a STATE: start it from no history and no config (the icon
        # cache stays).
        rm -rf "$W/xdg/state"; mkdir -p "$W/xdg/state"
        rm -f "$W/xdg/config/quickshell/notifications.json"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-1}" STAGE_GRAB="$out" GRAB_MS="${GRAB_MS:-3000}" \
            timeout "${SECS:-60}" "${BUS[@]}" quickshell -p mockups/notifications.qml > "$log" 2>&1
        [ -s "$out" ] || { rl_noresult NOTIF-MOCKUP "$log"; exit 1; }
        echo "GRAB $out"
        w=$(warnings "$log")
        [ -z "$w" ] && { echo "NOTIF-MOCKUP RESULT PASS"; exit 0; }
        printf '%s\n' "$w"
        echo "NOTIF-MOCKUP RESULT FAIL (warnings: $log)"
        exit 1
        ;;
    tabs)
        out="${2:?tabs needs an output dir}"
        shift 2
        # Like a grab, a state: no config left by an earlier run.
        rm -f "$W/xdg/config/quickshell/notifications.json"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" INPROC=1 ZOOM="${ZOOM:-0.8}" "${BUS[@]}" \
            tools/dev/mockup_grab.sh mockups/notifications.qml "$out" "$@"
        ;;
    panel)
        # Its own config tree: the self-test nudges a Config knob, and that write
        # must not be what the next `run` starts from.
        P="$W/xdg-panel"
        rm -rf "$P"; mkdir -p "$P/config/theme" "$P/config/quickshell"
        printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$P/config/theme/state.json"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" XDG_CONFIG_HOME="$P/config" INPROC=1 "${BUS[@]}" \
            tools/dev/mockup_panel_test.sh mockups/notifications.qml
        ;;
    run)
        if [ "${LIVE:-}" = "1" ]; then
            tools/dev/sandbox.sh "${ENVS[@]}" quickshell -p mockups/notifications.qml
        else
            tools/dev/sandbox.sh "${ENVS[@]}" "${BUS[@]}" quickshell -p mockups/notifications.qml
        fi
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \?//'
        exit 2
        ;;
esac
