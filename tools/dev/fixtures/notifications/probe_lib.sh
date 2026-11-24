# Shared by the notification service probes (stream D):
#   tools/dev/shell_hosted_m2_probe.sh
# Sourced, never run. Every probe:
#   - re-execs itself inside the SANDBOX (tools/dev/sandbox.sh, a private rsync of
#     the config), so nothing next to a running shell is touched;
#   - snapshots what it loads into $OUT/<name> and patches THAT for an ARM;
#   - runs quickshell on a PRIVATE session bus (tools/dev/notifications_bus.sh: no
#     activatable services, so no mako and no portal -- and QT_QPA_PLATFORMTHEME
#     unset, since the desktop's `xdgdesktopportal` theme would ask that bus for
#     a portal and warn), WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE unset
#     (offscreen: nothing reaches the compositor, and quickshell prints no
#     offscreen-under-wayland banner), private XDG dirs, a seeded theme
#     state, and stubs for
#     notify-send / pw-play / gdbus / hyprctl / systemctl / xdg-open on PATH,
#     each logging its argv to $STUB_LOG;
#   - writes the log to a FILE and reads it after the process has ended
#     (never a timeout-killed quickshell piped into grep).

# notif_reexec <script>: become the sandboxed copy of <script>.
notif_reexec() {
    local script="$1"
    SCRATCH="${SCRATCH:-$HOME/.cache/claude-notifications/D}"
    if [ -e .git ] && [ -z "${NOTIF_INNER:-}" ]; then
        mkdir -p "$SCRATCH"
        exec env SCRATCH="$SCRATCH" SANDBOX="$SCRATCH/lares-sandbox" tools/dev/sandbox.sh \
            NOTIF_INNER=1 SCRATCH="$SCRATCH" ARM="${ARM:-}" SMOKE="${SMOKE:-}" bash "$script"
    fi
}

# notif_snapshot <dir> <probe.qml> [extra repo-relative files...]
notif_snapshot() {
    local cfg="$1" probe="$2" f
    shift 2
    rm -rf "$cfg"
    mkdir -p "$cfg/modules" "$cfg/stubs" "$cfg/xdg/theme" "$cfg/xdg/quickshell" \
             "$cfg/state/lares/notifications" "$cfg/data" "$cfg/cache" "$cfg/tools/dev"
    cp -r "$ROOT/modules/common" "$ROOT/modules/notifications" "$cfg/modules/"
    # The manager hosts the wiki's card when it is empty (`import "../wiki"`).
    [ -d "$ROOT/modules/wiki" ] && cp -r "$ROOT/modules/wiki" "$cfg/modules/"
    # modules/common/components (LlmTools, SystemUpdatePopup) imports ../../auth/data for
    # AskpassSource; without it the scanner logs "Ignoring unresolvable import" and a probe's
    # log-clean rule fails although every check passed (measured).
    mkdir -p "$cfg/modules/auth" && cp -r "$ROOT/modules/auth/data" "$cfg/modules/auth/"
    # The toast pill (ToastPill / ToastPillWindow) imports the OSD's pill (which imports the battery's) and the shell's scale: without them the scanner
    # logs "Ignoring unresolvable import" and every probe that judges its log fails on a clean run.
    mkdir -p "$cfg/modules/shell" && rsync -a --exclude data/sources --exclude data/OsdService.qml --exclude data/OsdConfig.qml "$ROOT/modules/osd" "$cfg/modules/" && cp -r "$ROOT/modules/shell/scale" "$cfg/modules/shell/"
    cp -r "$ROOT/modules/shell/perf" "$cfg/modules/shell/"
    cp -r "$ROOT/themes" "$cfg/themes"
    cp "$ROOT/$probe" "$cfg/"
    for f in "$@"; do
        mkdir -p "$cfg/$(dirname "$f")"
        cp -r "$ROOT/$f" "$cfg/$f"
    done
    printf '{"theme":"eva","mode":"light"}\n' > "$cfg/xdg/theme/state.json"
    cat > "$cfg/stubs/notify-send" <<'SH'
#!/usr/bin/env bash
c="$STUB_LOG.ids"; n=$(( $(cat "$c" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$c"
echo "NOTIFY $*" >> "$STUB_LOG"
echo "$n"
case " $* " in *" -A "*) exec sleep 30 ;; esac
SH
    printf '#!/usr/bin/env bash\necho "PLAY $*" >> "$STUB_LOG"\nexec sleep 0.2\n' > "$cfg/stubs/pw-play"
    printf '#!/usr/bin/env bash\necho "GDBUS $*" >> "$STUB_LOG"\n' > "$cfg/stubs/gdbus"
    printf '#!/usr/bin/env bash\necho "HYPRCTL $*" >> "$STUB_LOG"\n' > "$cfg/stubs/hyprctl"
    printf '#!/usr/bin/env bash\necho "SYSTEMCTL $*" >> "$STUB_LOG"\n' > "$cfg/stubs/systemctl"
    printf '#!/usr/bin/env bash\necho "OPEN $*" >> "$STUB_LOG"\n' > "$cfg/stubs/xdg-open"
    chmod +x "$cfg/stubs/"*
    : > "$cfg/stub.log"
}

# notif_arm <file> <from> <to>: exact, unique anchor or a non-zero exit.
notif_arm() {
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("anchor found %d times: %r" % (s.count(a), a)); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

# notif_run <dir> <probe.qml> <log> [VAR=value ...]: one quickshell, on the
# private bus, killed by its own timeout at the latest. Extra env is passed on.
# The probe finds its own pid in PROBE_PID. LARES_PRELOAD=<lib.so> (in the
# caller's env) is LD_PRELOADed into the quickshell ALONE -- not the bus, not
# timeout (the holds probe's wall-clock shim, walljump.c).
notif_run() {
    local cfg="$1" qml="$2" log="$3"
    shift 3
    : > "$cfg/stub.log"
    env -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS -u QT_QPA_PLATFORMTHEME -u WAYLAND_DISPLAY \
        PATH="$cfg/stubs:$PATH" STUB_LOG="$cfg/stub.log" CFG="$cfg" \
        PROBE_STATE="$cfg/state/lares/notifications" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        XDG_CONFIG_HOME="$cfg/xdg" XDG_STATE_HOME="$cfg/state" \
        XDG_DATA_HOME="$cfg/data" XDG_CACHE_HOME="$cfg/cache" "$@" \
        timeout "${NOTIF_TIMEOUT:-150}" "$ROOT/tools/dev/notifications_bus.sh" \
        bash -c 'export PROBE_PID=$$; if [ -n "$2" ]; then export LD_PRELOAD="$2"; fi; exec quickshell -p "$1"' \
        probe "$cfg/$qml" "${LARES_PRELOAD:-}" > "$log" 2>&1
}
# (PROBE_PID: bash execs in place, so $$ IS the quickshell's pid -- what a
# probe hands `quickshell ipc --pid` to reach itself and nobody else.)

# notif_smoke <dir> <probe.qml>: tools/dev/smoke.sh on the snapshot's probe, in
# the same environment as notif_run (SECS long enough for it to finish).
notif_smoke() {
    local cfg="$1" qml="$2"
    : > "$cfg/stub.log"
    env -u HYPRLAND_INSTANCE_SIGNATURE -u DBUS_SESSION_BUS_ADDRESS -u QT_QPA_PLATFORMTHEME -u WAYLAND_DISPLAY \
        PATH="$cfg/stubs:$PATH" STUB_LOG="$cfg/stub.log" CFG="$cfg" \
        PROBE_STATE="$cfg/state/lares/notifications" \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi \
        XDG_CONFIG_HOME="$cfg/xdg" XDG_STATE_HOME="$cfg/state" \
        XDG_DATA_HOME="$cfg/data" XDG_CACHE_HOME="$cfg/cache" SECS="${SECS:-40}" SCRATCH="$SCRATCH" \
        "$ROOT/tools/dev/notifications_bus.sh" bash "$ROOT/tools/dev/smoke.sh" "$cfg/$qml"
}

# notif_lines <log> <TAG>: the probe's own lines, ANSI stripped.
notif_lines() {
    sed -r 's/\x1b\[[0-9;]*m//g' "$1" | grep -E "DEBUG qml: $2 " | sed 's/^ *DEBUG qml: //'
}

# notif_warnings <log>: every warning a clean run must not have.
notif_warnings() {
    sed -r 's/\x1b\[[0-9;]*m//g' "$1" \
        | grep -E "^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError" \
        | grep -v "quickshell.tooling"
}

# notif_arm_check <tag> <name> <needle> <log>: an armed run must FAIL, on its
# own check.
notif_arm_check() {
    local tag="$1" name="$2" want="$3" log="$4" out
    out=$(notif_lines "$log" "$tag")
    if printf '%s\n' "$out" | grep -q "$tag RESULT PASS"; then
        echo "ARM $name: the armed fault PASSED -- the probe proves nothing"; return 1
    fi
    if ! printf '%s\n' "$out" | grep "FAIL" | grep -qF "$want"; then
        echo "ARM $name: failed, but not on \"$want\":"
        printf '%s\n' "$out" | grep FAIL | head -4 | sed 's/^/    /'; return 1
    fi
    printf '%s\n' "$out" | grep FAIL | grep -F "$want" | head -1 | sed 's/^/    /'
    echo "ARM $name: FAIL on \"$want\", as it must"
}
