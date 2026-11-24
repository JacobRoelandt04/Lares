#!/usr/bin/env bash
# bar_boot_film.sh -- THE BAR'S FIRST FRAMES UNDER THE BOOT LOCK, filmed in tools/dev/lock_env.sh's nested Hyprland.
#
# The boot path as SDDM makes it: Hyprland with --locked-cmd (the real supervisor and lock, the scripted PAM stub of
# tools/dev/lock_a1_lib.sh), the user's geometry (LOCK-1 at 2880x1620, scale 1.25, the user's own shell.jsonc), the `lares-bar`
# no_anim layer rule as the user's config has it, and the REAL shell.qml (mock services but the LIVE window-title service, as
# the desktop's; SHELL_LOCK=live: the lock's socket) started 3 s after the lock, its shaders in the env's cache (a run before
# the lock, as a real session's are; WARM=0 for a cold one). wf-recorder takes every frame Hyprland composes of the top band.
# Then the boot lock is unlocked, an ordinary lock is taken and unlocked again.
#
#   tools/dev/bar_boot_film.sh                   film + judge
#   TREE=<dir> ...                                another tree (a `git archive` of an old revision): the same film
#   VEIL=relief (default) | gooey | ...           LOCK_REFRESH=120 (default) | 60      WARM=1 (default) | 0
#   VEIL_HOUR=12 (default)                        the veil's hour of day, pinned (the relief veil re-lights by the real sky)
#   LATE_LOCK=1                                   the lock dials the shell's socket every 2.5 s (not 250 ms): its first word lands
#                                                 after the bar is otherwise whole, the order a slow boot can have
#   OUT=<dir> (default $SCRATCH/barboot)          KEEP_FRAMES=1 keeps the frames (PNG, the top band at device size)
#   BB_ENV=<name> (default barboot)               the env's name: two films side by side need two
#
# THE JUDGE (tools/dev/bar_boot_judge.py) reads the band from the bar's first frame on, and the shell's own record (BARBOOT
# lines, the test copy only: every change of what the bar is built from, with the islands' rects):
#   first       the bar's first frame IS the bar at rest: inside every island (its rows, away from its ends) it differs from the
#               frame 1.0 s later by no more than an icon's recolour -- a hole (the reel cells), a ramp (the middle island), an
#               island that grows under its title, a title that morphs all fail it, per island
#   boottitle   the first frame shown says "New session" (the session is locked since boot)
#   bootlength  the left island's length and title do not change from the first frame shown until the unlock (record + pixels)
#   relock      an ordinary lock later says "<name> is away" ("Mock is away": a mock names "Mock")
# One line per check, then BAR_BOOT_FILM RESULT PASS|FAIL.
#
# ARM=<arm> puts one fault back in the TEST COPY; the film must then FAIL on its needle:
#   firstframe   the window shows its content from its first frame (no hold)              first: "differs from the bar at rest"
#   lockwait     the hold does not wait for the lock's first word (with LATE_LOCK)       boottitle: "not New session"
#   bootword     no boot title: the boot lock reads like any other                         boottitle: "not New session"
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/dev/lock_a1_lib.sh"
TREE="${TREE:-$ROOT}"
VEIL="${VEIL:-relief}"
OUT="${OUT:-${SCRATCH:-/tmp}/barboot}"
export LOCK_REFRESH="${LOCK_REFRESH:-120}"
A1_ENV_PREFIX="" a1_init "${BB_ENV:-barboot}"
REC=""; SHPID=""
cleanup() {
    [ -n "$REC" ] && kill -INT "$REC" 2> /dev/null
    [ -n "$SHPID" ] && kill "$SHPID" 2> /dev/null
    a1_down > /dev/null 2>&1
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
USERCFG="$HOME/.config/quickshell/shell.jsonc"

# THE RECORD (this copy only): one BARBOOT line per change of what the bar is built from, the top islands' [x0, x1] in logical px.
# (An old tree has no `presented`: the line says what it has.)
ANCHOR='    Component.onDestruction: win.services.themeControl.unregisterWipeScreen(win)'
RECORD="$ANCHOR"'
    readonly property string _bbState: "presented=" + (win.presented !== undefined ? win.presented : true) + " locked=" + win.services.lock.locked
        + " boot=" + win.services.lock.lockState.boot + " title=\"" + screenFrame.buttons.windowtray.titleText + "\" left=" + screenFrame.lengths.left
        + " bars=" + screenFrame.barSpecs.filter(b => b.barId.indexOf("top") === 0).map(b => b.barId + ":" + Math.round(b.rawPos * win.frameScale)
            + ":" + Math.round((b.rawPos + b.rawLen) * win.frameScale)).join(",")
    on_BbStateChanged: console.log("BARBOOT state t=" + Date.now() + " " + win._bbState)'
prep() {
    a1_build_pam > /dev/null || return 1
    rm -rf "$T"; mkdir -p "$T"
    rsync -a --exclude '.git' --exclude '.qmlls.ini' --exclude '.claude' --exclude 'screenshots' "$TREE/" "$T/" || return 1
    local f="$T/modules/lockscreen/lock/AuthController.qml"
    [ "$(grep -c 'property string pamDirectory: "/etc/pam.d"' "$f")" = 1 ] || { echo "prep: pamDirectory anchor missing"; return 1; }
    sed -i "s|property string pamDirectory: \"/etc/pam.d\"|property string pamDirectory: \"$W/pam.d\"|" "$f"
    printf '{ "veil": "%s", "bootFallbackDelayMs": 30000, "face": "off" }\n' "$VEIL" > "$T/lockscreen.json"
    rm -f "$T/lockscreen.jsonc"
    a1_patch modules/shell/ShellScreen.qml "$ANCHOR" "$RECORD" || return 1
    # the live window-title service, as the desktop has it (it reads the env's own Hyprland)
    a1_patch modules/shell/ShellFrame.qml '        sourceComponent: frame.services.mock ? windowMock : windowLive' '        sourceComponent: windowLive' || return 1
    [ "${ARM:-}" = lockwait ] && LATE_LOCK=1
    if [ "${LATE_LOCK:-0}" = 1 ]; then
        a1_patch modules/lockscreen/lock/ShellLink.qml '        interval: root._misses < 8 ? 250 : 2000' '        interval: 2500' || return 1
        echo "  LATE_LOCK: the lock dials every 2.5 s"
    fi
    case "${ARM:-}" in
        "") ;;
        firstframe) a1_patch modules/shell/ShellScreen.qml '    property bool presented: false' '    property bool presented: true' || return 1 ;;
        lockwait) a1_patch modules/shell/ShellScreen.qml '    readonly property bool _lockKnown: win._lockHeld === 0 || win.services.lock.locked || win._lockWaited' \
                      '    readonly property bool _lockKnown: win._lockHeld >= 0' || return 1 ;;
        bootword) a1_patch modules/shell/ShellFrame.qml '            bootLock: frame.services.lock.lockState.boot' '            bootLock: false' || return 1 ;;
        *) echo "unknown ARM=$ARM"; return 1 ;;
    esac
    [ -n "${ARM:-}" ] && echo "  ARMED $ARM"
    # the relief veil is lit by the real sky and re-lights every 10 s: at dawn one step moves ~15 000 px of the band, which the judge
    # took for the bar's first frame (a red on the round-start tree too, 2026-11-08 05:40). The hour is pinned: the film judges the bar.
    printf '#!/bin/sh\nwhile [ ! -e %s/go ]; do sleep 0.02; done\nexec env VEIL_HOUR=%s bash %s/tools/lockscreen/lares-lock --boot\n' "$W" "${VEIL_HOUR:-12}" "$T" > "$W/bootlock.sh"
    chmod +x "$W/bootlock.sh"
    rm -f "$W/go"
}

up() {
    "$E" down > /dev/null 2>&1
    env MODE=light LOCKED_CMD="$W/bootlock.sh" "$E" up > /dev/null || { echo "BAR_BOOT_FILM env up failed"; return 1; }
    "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", mode = "2880x1620@'"$LOCK_REFRESH"'", position = "0x0", scale = 1.25 })' > /dev/null
    "$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
    # the shell's mock home, with the user's shell.jsonc (the geometry the user saw)
    local mh="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
    mkdir -p "$mh"
    [ -f "$USERCFG" ] && cp "$USERCFG" "$mh/shell.jsonc"
    sleep 1
}
shell_start() {  # log
    "$E" run env SHELL_SERVICES=mock SHELL_LOCK=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        quickshell -n -p "$T/shell.qml" > "$1" 2>&1 &
    SHPID=$!
}
# wait until a lock-log line has been seen N times (S seconds)
wait_count() {  # ere n s
    local i; for i in $(seq 1 $(($3 * 10))); do [ "$(a1_lock_log | grep -acE "$1")" -ge "$2" ] && return 0; sleep 0.1; done; return 1
}
unlock() { "$E" type hunter2; sleep 0.3; "$E" key Return; }
mark() { echo "$1 $(date +%s%3N)" >> "$d/marks"; }

mkdir -p "$OUT"
d="$OUT/film"; rm -rf "$d"; mkdir -p "$d"
fails=0
prep || { echo "BAR_BOOT_FILM RESULT FAIL (prep)"; exit 1; }
up || { echo "BAR_BOOT_FILM RESULT FAIL (env)"; exit 1; }
if [ "${WARM:-1}" = 1 ]; then
    # (no lock yet: the boot lock waits for `go`) -- the shell once, so its pipelines are in the env's Mesa cache
    shell_start "$d/shell-warm.log"
    for _ in $(seq 1 300); do grep -aq 'LARES settled\|Failed to load' "$d/shell-warm.log" 2> /dev/null && break; sleep 0.2; done
    kill "$SHPID" 2> /dev/null; wait "$SHPID" 2> /dev/null; SHPID=""
    if grep -aq 'Failed to load' "$d/shell-warm.log"; then
        sed 's/\x1b\[[0-9;]*m//g' "$d/shell-warm.log" | grep -a ERROR | head -5
        echo "BAR_BOOT_FILM RESULT FAIL (the shell does not load)"; exit 1
    fi
fi
"$E" run wf-recorder -o LOCK-1 -g "0,0 2304x96" -c ffv1 -x bgr0 -f "$d/film.mkv" > "$d/rec.log" 2>&1 &
REC=$!
sleep 1.5
mark rec
touch "$W/go"
a1_wait_log 'LARESLOCK secure' 20 || echo "  (no secure line)"
sleep 3
shell_start "$d/shell.log"
wait_count 'LARESLOCK shell on' 1 60 || echo "  (the lock never heard the shell)"
sleep 3
mark unlock
unlock
wait_count 'LARESLOCK unlocked' 1 10 || echo "  (no unlock)"
sleep 2
# an ordinary lock, as Super+L or the reel's Lock takes it
a1_lock
wait_count 'LARESLOCK shell on' 2 30 || echo "  (the second lock never heard the shell)"
sleep 2
unlock
wait_count 'LARESLOCK unlocked' 2 10 || echo "  (no second unlock)"
sleep 1
kill -INT "$REC" 2> /dev/null; for _ in $(seq 1 100); do kill -0 "$REC" 2> /dev/null || break; sleep 0.1; done; REC=""
cp "$B/rt/lares-lock.log" "$d/lock.log" 2> /dev/null
sed 's/\x1b\[[0-9;]*m//g' "$d/shell.log" | grep -a "LARES shown\|BARBOOT state\|ERROR\|Cannot assign\|Unable to assign\|binding loop" | sed 's/.*qml: //' | head -40 | sed 's/^/  /'
python3 "$ROOT/tools/dev/bar_boot_judge.py" "$d" || fails=1
[ "${KEEP_FRAMES:-0}" = 1 ] || rm -rf "$d/frames"
rm -f "$d/film.mkv"
[ "$fails" = 0 ] && echo "BAR_BOOT_FILM RESULT PASS" || { echo "BAR_BOOT_FILM RESULT FAIL"; exit 1; }
