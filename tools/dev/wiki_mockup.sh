#!/usr/bin/env bash
# Run mockups/wiki.qml in the sandbox, with a PRIVATE theme, config, state and cache.
#
#   tools/dev/wiki_mockup.sh                       smoke: load, report every warning (WIKI-MOCKUP RESULT PASS|FAIL)
#   tools/dev/wiki_mockup.sh grab OUT.png          a grab of the stage alone (STAGE_GRAB, GRAB_MS, ZOOM=1)
#   tools/dev/wiki_mockup.sh run                   interactive, on the desktop (a private theme state)
#   tools/dev/wiki_mockup.sh panel                 the framework's panel self-test on copies
#                                              (tools/dev/mockup_panel_test.sh: marks, profiles, Save to mockup)
#   tools/dev/wiki_mockup.sh tabs DIR [tab ...]    the panel's tabs to PNG (tools/dev/mockup_grab.sh); no tab = all
#   MODE=dark ...                              the theme the private state file holds (default light)
#   SCENE=card|compact|clock  SCENARIO=<WikiMock scenario>  TAB=discover|deepen  FONT=<family>  VEIL=<pattern>
#   OPEN=1 (scene clock: open the popup)       passed through to the mockup
#   LIVE=1 tools/dev/wiki_mockup.sh run            the REAL WikiService, on the PRIVATE state dir (an empty
#                                              pool: the empty state, and its asks). LIVE=1 is the yes
#   REAL=1 LIVE=1 tools/dev/wiki_mockup.sh run     ... on YOUR real config, state and cache (the user's own
#                                              pool; the theme toggle then flips the real desktop too).
#                                              `quickshell -p mockups/wiki.qml` with LIVE=1 is the same
#
# WHY A PRIVATE XDG. The mockup's Run tab (and the toolbar) toggle the theme,
# and Theme.setMode persists to ~/.config/theme/state.json, which the live shell
# follows: an unseeded launch flips the user's desktop. Every launch here seeds
# its own state file. WikiMock reads nothing of the user's: the fixtures are in
# the tree, the clock is pinned, and nothing touches the network or D-Bus.
#
# SAVE TO MOCKUP AND THE PROFILES WRITE THE REAL TREE. The mockup runs from the
# sandbox copy; tools/dev/sandbox.sh names this tree (MOCKUP_REPO) so a save lands
# in ./mockups/wiki.qml and the profiles in ./mockup_profiles/wiki/. smoke, grab and
# tabs press nothing: they rewrite only the derived default.json there, and only
# while the copy's mockup is this one byte for byte.
#
# smoke and grab end on a verdict line: WIKI-MOCKUP RESULT PASS|FAIL, exit 0 on
# PASS only. A warning fails either. A run that produced no result (smoke: the
# configuration never loaded; grab: no picture was written) ends on
# `WIKI-MOCKUP RESULT FAIL (no result: <log>)` after the log's load errors
# (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
SCRATCH="${SCRATCH:-$HOME/.cache/claude-wiki}"
W="$SCRATCH/wiki_mockup"
MODE="${MODE:-light}"
mkdir -p "$W/xdg/config/theme" "$W/xdg/state" "$W/xdg/cache" "$W/xdg/data"
printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$W/xdg/config/theme/state.json"
ENVS=(XDG_CONFIG_HOME="$W/xdg/config" XDG_STATE_HOME="$W/xdg/state" XDG_CACHE_HOME="$W/xdg/cache" XDG_DATA_HOME="$W/xdg/data"
      QT_LOGGING_RULES="qt.qpa.services.warning=false" SCRATCH="$W"
      SCENE="${SCENE:-}" SCENARIO="${SCENARIO:-}" TAB="${TAB:-}" FONT="${FONT:-}" OPEN="${OPEN:-}" VEIL="${VEIL:-}")
# offscreen alone loads the software scene graph, which draws every ShaderEffect
# (every ShadowBox) as nothing; rhi is what makes the carved boxes appear.
OFF=(QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi WAYLAND_DISPLAY= HYPRLAND_INSTANCE_SIGNATURE=)
export SANDBOX="${SANDBOX:-$W/lares-sandbox}"

# warnings <log>: every distinct warning of a run, counted (none: nothing printed).
warnings() {
    rl_clean "$1" | grep -a -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError|is not a type|Cannot " \
        | grep -a -v -E "quickshell.tooling|WAYLAND_DISPLAY|QT_QPA_PLATFORM to |WARNING ---|actually running wayland|does not support setting window masks" \
        | sed 's/^ *//' | sort | uniq -c | head -30
}

case "${1:-smoke}" in
    smoke)
        # tools/dev/smoke.sh writes its log under its SCRATCH, which ENVS makes $W.
        log="$W/qml-smoke/wiki.log"
        rm -f "$log"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" SECS="${SECS:-10}" tools/dev/smoke.sh mockups/wiki.qml
        rc=$?
        rl_has "$log" "Configuration Loaded" || { rl_noresult WIKI-MOCKUP "$log"; exit 1; }
        [ "$rc" = 0 ] && { echo "WIKI-MOCKUP RESULT PASS (smoke clean)"; exit 0; }
        echo "WIKI-MOCKUP RESULT FAIL (smoke: warnings, $log)"
        exit 1
        ;;
    grab)
        out="${2:?grab needs an output path}"
        log="$W/grab.log"
        rm -f "$out"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-1}" STAGE_GRAB="$out" GRAB_MS="${GRAB_MS:-2500}" \
            timeout "${SECS:-60}" quickshell -p mockups/wiki.qml > "$log" 2>&1
        [ -s "$out" ] || { rl_noresult WIKI-MOCKUP "$log"; exit 1; }
        echo "GRAB $out"
        w=$(warnings "$log")
        [ -z "$w" ] && { echo "WIKI-MOCKUP RESULT PASS"; exit 0; }
        printf '%s\n' "$w"
        echo "WIKI-MOCKUP RESULT FAIL (warnings: $log)"
        exit 1
        ;;
    tabs)
        out="${2:?tabs needs an output dir}"
        shift 2
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" ZOOM="${ZOOM:-1}" tools/dev/mockup_grab.sh mockups/wiki.qml "$out" "$@"
        ;;
    panel)
        # Its own config tree: the self-test nudges values, and no write of it
        # may be what the next `run` starts from.
        P="$W/xdg-panel"
        rm -rf "$P"; mkdir -p "$P/config/theme" "$P/config/quickshell"
        printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$P/config/theme/state.json"
        tools/dev/sandbox.sh "${ENVS[@]}" "${OFF[@]}" XDG_CONFIG_HOME="$P/config" tools/dev/mockup_panel_test.sh mockups/wiki.qml
        ;;
    run)
        if [ "${REAL:-}" = "1" ]; then
            # The user's own XDG dirs: only the scene envs, no private state.
            tools/dev/sandbox.sh QT_LOGGING_RULES="qt.qpa.services.warning=false" SCENE="${SCENE:-}" SCENARIO="${SCENARIO:-}" \
                TAB="${TAB:-}" FONT="${FONT:-}" OPEN="${OPEN:-}" quickshell -p mockups/wiki.qml
        else
            tools/dev/sandbox.sh "${ENVS[@]}" quickshell -p mockups/wiki.qml
        fi
        ;;
    *)
        sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//' | head -20
        exit 2
        ;;
esac
