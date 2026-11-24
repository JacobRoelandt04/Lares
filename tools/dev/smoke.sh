#!/usr/bin/env bash
# Load a QML file and report every warning it produces.
#
#   tools/dev/smoke.sh <file.qml> [more.qml ...]
#   tools/dev/smoke.sh --all            every mockup (mockups/*.qml), every harness (tools/dev/qml/*.qml), any test_*.qml left in the root
#
# Exits non-zero when anything warned, and prints each distinct warning with
# a count, so twenty copies of one fault read as one line.
#
# WHY THIS IS A SCRIPT AND NOT A ONE-LINER. The obvious form
#
#     timeout 6 quickshell -p x.qml 2>&1 | grep -iE "error|warn"
#
# LIES. `timeout` kills the process, and what quickshell had buffered on
# stderr dies with it, so a run with twenty warnings reports clean -- which is
# how twenty "Unable to assign [undefined] to QColor" per launch survived a
# round of "smoke: clean". Redirect to a FILE, wait for the process to end,
# then read the file.
#
# SECS (default 8) is how long each file is given. Set QUIET=1 for the
# summary only.
#
# A WORLD OF ITS OWN FOR EVERY FILE -- WHERE THE CALLER'S WORLD IS THE USER'S.
# A smoke run is a real quickshell, and what it does to the machine it runs on is
# nobody's to keep:
#   - XDG_STATE_HOME is private: the mock services keep what they write in
#     $XDG_STATE_HOME/lares-shell-mock (a smoke run of mockups/shell.qml
#     created ~/.local/state/lares-shell-mock on 2026-10-15), a mockup
#     keeps its view settings in $XDG_STATE_HOME/lares/mockup, the
#     stores of the modules sit under $XDG_STATE_HOME/lares.
#   - XDG_CONFIG_HOME is private, with the theme state SEEDED from the user's
#     own (a copy; the light eva default when there is none): Theme persists a
#     mode switch to $XDG_CONFIG_HOME/theme/state.json and the live shell
#     follows that file (CLAUDE.md: a test that launches a quickshell without a
#     private XDG_CONFIG_HOME flips the user's desktop).
#   - the session bus is private (tools/dev/notifications_bus.sh: no activatable
#     service): mockups/notifications.qml starts a NotificationServer, whose name
#     on the user's bus is the notification daemon's (mako's), and a tray host
#     or an agent would be the same trespass. Whatever a file owns on a bus, it
#     owns there.
# ONLY WHAT IS THE USER'S OWN is replaced. A caller that made a world of its own keeps it: a runner
# that seeds module configs under its XDG_CONFIG_HOME, puts stubs on a bus of its own and then
# smokes a probe (SMOKE=1) wants the file to see exactly that. So a
# state or config home that is unset or the default under $HOME is substituted, one that was set to
# anything else is left as the caller made it; and a bus is left alone when it carries LARES_TEST_BUS
# (set by tools/dev/notifications_bus.sh and tools/dev/lock_env.sh, which make the buses tests use).
# The caches stay the user's (the QML compile cache and the icon atlases are
# the shell's own and warm on purpose: a cold compile would eat the SECS).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
SECS="${SECS:-8}"
OUT="${SCRATCH:-/tmp}/qml-smoke"
mkdir -p "$OUT"
PRIV=$(mktemp -d "$OUT/env.XXXXXX") || exit 1
trap 'rm -rf "$PRIV"' EXIT
REAL_THEME_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/theme/state.json"
# What is the user's own, and so to be replaced (see the header).
OWN_STATE=0; OWN_CONFIG=0; OWN_BUS=1
case "${XDG_STATE_HOME:-}" in "" | "$HOME/.local/state") OWN_STATE=1 ;; esac
case "${XDG_CONFIG_HOME:-}" in "" | "$HOME/.config") OWN_CONFIG=1 ;; esac
[ -n "${LARES_TEST_BUS:-}" ] && OWN_BUS=0

if [ "${1:-}" = "--all" ]; then
    shopt -s nullglob
    set -- mockups/*.qml tools/dev/qml/*.qml test_*.qml
    shopt -u nullglob
fi
[ $# -gt 0 ] || { sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 2; }

bad=0
for f in "$@"; do
    [ -f "$f" ] || { echo "no such file: $f"; bad=1; continue; }
    # A file that can LOCK THE SESSION is never started on the user's desktop:
    # a lock killed by `timeout` there leaves them on Hyprland's lockdead
    # screen with a TTY as the only way out. Run it offscreen (no Wayland, no
    # lock) or inside tools/dev/lock_env.sh.
    if grep -qE 'WlSessionLock|lockscreen/lock' "$f" \
       && [ "${QT_QPA_PLATFORM:-}" != "offscreen" ] && [ -z "${LOCK_ENV_DIR:-}" ]; then
        printf '%-40s REFUSED: it can lock the session (QT_QPA_PLATFORM=offscreen, or tools/dev/lock_env.sh run)\n' "$f"
        bad=1
        continue
    fi
    log="$OUT/$(basename "$f" .qml).log"
    # qt.qpa.services is silenced, and ONLY that category: Qt's portal theme
    # re-registers an app id the compositor's clients already hold ("Connection
    # already associated with an application ID"). It is Qt talking to itself,
    # it appears on modules nobody has touched, and left in it would bury the
    # next real warning -- which is the whole point of this gate.
    rm -rf "$PRIV"; mkdir -p "$PRIV/config/theme" "$PRIV/state"
    cp "$REAL_THEME_STATE" "$PRIV/config/theme/state.json" 2> /dev/null \
        || printf '{"theme":"eva","mode":"light"}\n' > "$PRIV/config/theme/state.json"
    world=(); bus=()
    [ "$OWN_STATE" = 1 ] && world+=(XDG_STATE_HOME="$PRIV/state")
    [ "$OWN_CONFIG" = 1 ] && world+=(XDG_CONFIG_HOME="$PRIV/config")
    [ "$OWN_BUS" = 1 ] && bus=(tools/dev/notifications_bus.sh)
    # The desktop's own entry is LIVE by default, and a live shell is the machine's: the real lock socket, pkexec and the silicon helper, the real mpd. A smoke
    # of it runs on the mock services. Inside tools/dev/lock_env.sh too, unless the caller ASKS for live by name: there an unset SHELL_SERVICES once
    # ran the live services -- the real SiliconService among them, which only its own probe may build (2026-11-21).
    if [ "$(realpath -- "$f")" = "$(realpath -- shell.qml)" ]; then
        if [ -z "${LOCK_ENV_DIR:-}" ] && [ "${SHELL_SERVICES:-}" = live ]; then
            printf '%-40s REFUSED: SHELL_SERVICES=live is the machine'"'"'s, not a smoke test\n' "$f"
            bad=1
            continue
        fi
        [ "${SHELL_SERVICES:-}" = live ] || world+=(SHELL_SERVICES=mock)
    fi
    # NEVER A WINDOW ON THE USER'S DESKTOP: outside tools/dev/lock_env.sh every smoke is offscreen, forced ON THE LAUNCH (a caller's
    # session platform, wayland;xcb, once put a mockup on the desktop for 8 s, 2026-11-21). DISPLAY stays: the offscreen platform takes
    # its GL context through GLX on Xwayland (no window); rhi, or every ShaderEffect draws nothing.
    plat=()
    [ -z "${LOCK_ENV_DIR:-}" ] && plat=(-u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi)
    env "${plat[@]}" "${world[@]}" QT_LOGGING_RULES="${QT_LOGGING_RULES:-qt.qpa.services.warning=false}" \
        "${bus[@]}" timeout "$SECS" quickshell -p "$f" > "$log" 2>&1
    # Quickshell's own INFO lines mention neither; the ANSI codes have to go
    # first or the level word is not at a word boundary. `quickshell.tooling`
    # is dropped: it reports on the qmlls config symlink beside the project,
    # which says nothing about the QML that was loaded. The portal refusals are
    # the private bus's doing: it has no portal, so Qt's platform theme asks
    # for the colour scheme and the file chooser and logs that nobody answered.
    # `rl_platform_noise` (result_lib.sh) drops the ONE exact line qtwayland 6.12
    # prints when a toplevel window loses the text input: any file with a
    # FloatingWindow printed it, in a compositor; it is the platform's, not the file's.
    hits=$(sed 's/\x1b\[[0-9;]*m//g' "$log" \
        | rl_platform_noise \
        | grep -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property" \
        | grep -v "quickshell.tooling" \
        | grep -v "org.freedesktop.portal.Desktop was not provided" \
        | sed 's/^ *//' | sort | uniq -c | sort -rn)
    n=$(printf '%s' "$hits" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        [ "${QUIET:-}" = "1" ] || printf '%-40s clean\n' "$f"
    else
        printf '%-40s %s distinct warning(s)   (%s)\n' "$f" "$n" "$log"
        printf '%s\n' "$hits" | sed 's/^/    /'
        bad=1
    fi
done
exit $bad
