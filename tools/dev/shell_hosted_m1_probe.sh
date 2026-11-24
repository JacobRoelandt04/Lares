#!/usr/bin/env bash
# The clock, stocks, silicon and notes owners in SHELL-HOSTED mode (docs/contracts/shell.md
# section 4): two screens, one set of services (tools/dev/qml/shell_hosted_m1_probe.qml; H1..H11 are
# listed in its header). Ends in `SHELL_HOSTED_M1 RESULT PASS|FAIL`.
#
#   tools/dev/shell_hosted_m1_probe.sh                 the probe: expect SHELL_HOSTED_M1 RESULT PASS
#   ARM=<name> tools/dev/shell_hosted_m1_probe.sh      one fault armed in a SNAPSHOT: must FAIL on its check
#   ARM=all    tools/dev/shell_hosted_m1_probe.sh      every arm in turn
#
# THE SNAPSHOT. A partial copy of the tree (common, the four modules, the wiki and screentime
# the clock loads by URL, the engine, the notes tool, the fixtures the mocks read) under
# $SCRATCH, with FOUR SERVICES REPLACED BY STUBS -- SiliconService (pkexec, the real helper),
# StocksService (Yahoo), WikiService (the day's feed, a model batch), ScreentimeService (a
# socket): a few lines that carry the flags the owners touch. An owner that wrongly BUILDS one
# is counted and reaches nothing; the real files are never in the run. The runner refuses to
# start when a stub is not in place. Private HOME and XDG dirs, offscreen + rhi, the theme
# state seeded: nothing of the user's is read or written.
#
# The arms (each breaks the snapshot's copy of one owner and must FAIL on its own check):
#   selfbuild    a hosted clock builds its TimerService when handed none            H7a
#   writeback    a hosted stocks owner binds svc.popupOpen                          H2
#   writeclock   a hosted clock binds timers.attended                               H2
#   writewiki    a hosted clock binds wiki.popupOpen                                H2
#   route        a hosted clock still answers wiki.openRequested                    H6a
#   routestocks  a hosted stocks owner still answers alertOpenRequested             H6a
#   flags        sharedFlags.timersAttended is always false                         H3c
#   silicon      a hosted silicon owner builds its service when handed none          H7a
#   muxwatcher   a hosted silicon owner makes its own MuxWatcher                     H1
#   store        a hosted notes owner builds a store when handed none                H7a
#   keyopen      shortcutPressed() does not open key-opened                         H9b
#   pulse        a key-opened popup keeps the pulse                                  H9c
#   cleared      a cleared grab does not close                                       H9d
#   nodecay      a remembered stocks detail comes back however long ago it was shown H10
#   prewarm      the prewarm ignores prewarmArmed                                     H11c
#   nowrite      an owner that is not hosted stops writing the service's flag        H8g
#   noguard      a hosted stocks owner with no service opens a popup anyway          H7c
#   holdall      one popup closing stops the store for every screen                    H12
#   nograb       the key-opened popup's HyprlandFocusGrab is never active               S1
set -u
cd "$(dirname "$0")/../.." || exit 1

# Through the sandbox (a private runtime dir for the quickshell, a copy of the tree): a direct
# run in the tree re-executes itself there. [ -e .git ]: in a worktree .git is a file.
if [ -e .git ] && [ -z "${SHM_INNER:-}" ]; then
    SCRATCH="${SCRATCH:-/tmp/lares-scratch-shell-hosted}"
    mkdir -p "$SCRATCH"
    exec env SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" SCRATCH="$SCRATCH" MOCKUP_REPO= tools/dev/sandbox.sh \
        QT_QPA_PLATFORM=offscreen SHM_INNER=1 ARM="${ARM:-}" ONLY_ARMS="${ONLY_ARMS:-}" KEEP="${KEEP:-}" bash tools/dev/shell_hosted_m1_probe.sh "$@"
fi
ROOT="$PWD"
# shellcheck source=result_lib.sh
. "$ROOT/tools/dev/result_lib.sh"
SCRATCH="${SCRATCH:-/tmp}"
OUT="${OUTDIR:-$SCRATCH/shell_hosted_m1_probe}"
mkdir -p "$OUT"

snapshot() {  # tree
    local t="$1"
    rm -rf "$t"
    mkdir -p "$t/modules/bar" "$t/modules/auth" "$t/tools" "$t/xdg/config/theme" "$t/xdg/state" \
             "$t/xdg/data" "$t/xdg/cache" "$t/home" "$t/probe"
    cp -r "$ROOT/modules/common" "$ROOT/modules/clock" "$ROOT/modules/stocks" "$ROOT/modules/silicon" \
          "$ROOT/modules/notes" "$ROOT/modules/wiki" "$ROOT/modules/screentime" "$t/modules/"
    cp -r "$ROOT/modules/auth/data" "$t/modules/auth/"
    # the stocks cards' day graph reads the notifications' SuddenMove.js (stocks, 738c27d5)
    mkdir -p "$t/modules/notifications"
    cp -r "$ROOT/modules/notifications/sources" "$t/modules/notifications/"
    cp -r "$ROOT/modules/bar/gooey" "$t/modules/bar/"
    # the clock owner hands the rail its BreakClock (modules/bar/workspaces)
    cp -r "$ROOT/modules/bar/workspaces" "$t/modules/bar/"
    cp -r "$ROOT/tools/notes" "$t/tools/"
    cp -r "$ROOT/themes" "$t/themes"
    cp -a "$ROOT/mockups/fixtures/notes" "$t/probe/notes"
    cp "$ROOT/tools/dev/qml/shell_hosted_m1_probe.qml" "$t/"
    printf '{"theme":"eva","mode":"light"}\n' > "$t/xdg/config/theme/state.json"
    # The stubs. Each carries what the owners read or write, and announces nothing: the probe counts them.
    cat > "$t/modules/silicon/data/SiliconService.qml" <<'QML'
import QtQuick
// STUB: the real service calls pkexec and the real helper; this one is only counted.
Item {
    property bool popupOpen: false
    property var config: null
    property var battery: null
    property var gpu: null
    property var cpu: null
    property var helper: null
    property int profileIndex: 1
    property int gpuMode: 2
    signal batteryEvent(string kind)
    signal appBlocked(var app)
}
QML
    cat > "$t/modules/stocks/data/StocksService.qml" <<'QML'
import QtQuick
// STUB: the real service fetches quotes; this one is only counted.
Item {
    property bool popupOpen: false
    property var notifier: null
    readonly property var alertKeys: []
    signal alertOpenRequested(string symbol)
}
QML
    cat > "$t/modules/wiki/data/WikiService.qml" <<'QML'
import QtQuick
// STUB: the real service fetches the day's feed and may resume a model batch; this one is only counted.
Item {
    property bool popupOpen: false
    property var notifier: null
    readonly property var notifyKeys: []
    signal openRequested(string tab)
}
QML
    cat > "$t/modules/screentime/data/ScreentimeService.qml" <<'QML'
import QtQuick
// STUB: the real service dials the daemon's socket; this one is only counted.
Item {
}
QML
    local f
    for f in modules/silicon/data/SiliconService.qml modules/stocks/data/StocksService.qml \
             modules/wiki/data/WikiService.qml modules/screentime/data/ScreentimeService.qml; do
        grep -q "^// STUB" "$t/$f" || { echo "SHELL_HOSTED_M1 RESULT FAIL (the stub for $f is not in the snapshot: refusing to run)"; exit 1; }
    done
}

arm() {  # file from to -- the anchor must be there exactly once
    python3 - "$@" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(a) != 1:
    print("ARM anchor found %d times in %s: %r" % (s.count(a), p, a[:80])); sys.exit(2)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
PY
}

apply_arm() {  # name tree
    local t="$2" c="$2/modules/clock/ClockBarOwner.qml" s="$2/modules/stocks/StocksBarOwner.qml" \
          l="$2/modules/silicon/SiliconBarOwner.qml" n="$2/modules/notes/NotesBarOwner.qml"
    case "$1" in
        selfbuild)   arm "$c" '        id: ownTimers
        active: owner.timerService === null && !owner.shellHosted' '        id: ownTimers
        active: owner.timerService === null' ;;
        writeback)   arm "$s" '        when: !owner.shellHosted && !!owner.svc' '        when: !!owner.svc' ;;
        writeclock)  arm "$c" '        when: !owner.shellHosted && !!owner.timers' '        when: !!owner.timers' ;;
        writewiki)   arm "$c" '        when: !owner.shellHosted && !!owner.wiki' '        when: !!owner.wiki' ;;
        route)       arm "$c" '        target: owner.wiki
        enabled: !owner.shellHosted' '        target: owner.wiki
        enabled: true' ;;
        routestocks) arm "$s" '        target: owner.svc
        enabled: !owner.shellHosted' '        target: owner.svc
        enabled: true' ;;
        flags)       arm "$c" '            timersAttended: owner.popupMine && owner.currentTab === "timers"' '            timersAttended: false' ;;
        silicon)     arm "$l" '        active: barOwner.service === null && !barOwner.shellHosted
        source: barOwner.service === null && !barOwner.shellHosted ? Qt.resolvedUrl("data/SiliconService.qml") : ""' '        active: barOwner.service === null
        source: barOwner.service === null ? Qt.resolvedUrl("data/SiliconService.qml") : ""' ;;
        muxwatcher)  arm "$l" '        id: muxWatcherLoader
        active: !barOwner.shellHosted' '        id: muxWatcherLoader
        active: true' ;;
        store)       arm "$n" '        active: owner.store === null && !owner.shellHosted' '        active: owner.store === null' ;;
        keyopen)     arm "$n" '        owner._keyOpened = true;
        owner.open();' '        owner.open();' ;;
        pulse)       arm "$n" '            grabKeyboard: !owner._keyOpened' '            grabKeyboard: true' ;;
        cleared)     arm "$n" '        onCleared: owner.close()' '        onCleared: {}' ;;
        nodecay)     arm "$t/modules/stocks/SecondaryMemory.qml" '            && (root.decayMs <= 0 || Date.now() - root._seenMs < root.decayMs);' '            && true;' ;;
        prewarm)     arm "$l" '        armed: barOwner._wired && barOwner.prewarmArmed' '        armed: barOwner._wired && barOwner.ownsService' ;;
        nowrite)     arm "$s" '        when: !owner.shellHosted && !!owner.svc' '        when: false' ;;
        noguard)     arm "$s" ' || owner.popupMine || (owner.shellHosted && !owner.svc))' ' || owner.popupMine)' ;;
        holdall)     arm "$t/modules/notes/NotesStore.qml" '        store.holders = Math.max(0, store.holders - 1);' '        store.holders = 0;' ;;
        nograb)      arm "$n" '        active: owner.keyOpened && owner.grabWindows.length > 0' '        active: false' ;;
        *) echo "unknown ARM=$1"; return 2 ;;
    esac
}

# The check an arm must fail on (its id starts the probe's FAIL line).
needle() {
    case "$1" in
        selfbuild|silicon|store) echo "H7a" ;;
        writeback|writeclock|writewiki) echo "H2" ;;
        route|routestocks) echo "H6a" ;;
        flags) echo "H3c" ;;
        muxwatcher) echo "H1" ;;
        keyopen) echo "H9b" ;;
        pulse) echo "H9c" ;;
        cleared) echo "H9d" ;;
        nodecay) echo "H10" ;;
        prewarm) echo "H11c" ;;
        nowrite) echo "H8g" ;;
        noguard) echo "H7c" ;;
        holdall) echo "H12" ;;
        nograb) echo "S1" ;;
    esac
}

# run <tree> <log>: one quickshell, its log in a file (a killed quickshell's buffered stderr dies with it).
run() {
    local t="$1" log="$2"
    ( cd "$t" && env -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY \
        QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QT_QPA_PLATFORMTHEME= LARES_SLEEP_MONITOR=off \
        HOME="$t/home" XDG_CONFIG_HOME="$t/xdg/config" XDG_STATE_HOME="$t/xdg/state" XDG_DATA_HOME="$t/xdg/data" XDG_CACHE_HOME="$t/xdg/cache" \
        NOTES_ROOT="$t/probe/notes" PROBE_STATE="$t/xdg/state" QT_LOGGING_RULES="qt.qpa.services.warning=false" \
        timeout 300 quickshell -p "$t/shell_hosted_m1_probe.qml" ) > "$log" 2>&1
}

clean() { sed -r 's/\x1b\[[0-9;]*m//g' "$1" | sed 's/^ *DEBUG qml: //; s/^ *INFO qml: //; s/^ *//'; }

# S1 (static): offscreen cannot read a HyprlandFocusGrab (there is no hyprland_focus_grab_v1: `active` reads false, and
# turning it on logs a WARN), so the one thing the probe cannot see -- that a key-opened popup's grab is switched on over
# the host's windows, and a click outside closes it -- is read from the owner. The compositor half is F2's shell probe
# (hl.get_layers interactivity, a real key).
static_s1() {  # tree
    python3 - "$1/modules/notes/NotesBarOwner.qml" <<'PYS1'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
ok = re.search(r"HyprlandFocusGrab \{\s*id: keyGrab\s*active: owner\.keyOpened && owner\.grabWindows\.length > 0\s*windows: owner\.grabWindows\s*onCleared: owner\.close\(\)\s*\}", s)
print(("SHM PASS " if ok else "SHM FAIL ") + "S1 a key-opened notes popup's HyprlandFocusGrab is active over the host's windows and a click outside closes it (static: offscreen cannot read a grab)")
PYS1
}

warnings() {
    clean "$1" | grep -E "^(WARN|ERROR)|Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError|is not a type|unresolvable|Cannot " \
        | grep -v "WAYLAND_DISPLAY\|WARNING ---\|actually running\|window masks\|QT_QPA_PLATFORM\|path symlink\|quickshell.tooling\|most functionality\|quickshell.ipc" \
        | grep -v -x -E "WARN : Failed to create wl_display \(No such file or directory\)|WARN: Cannot create idle monitor as ext-idle-notify-v1 is not supported by the current compositor\."
    # (the last two: offscreen there is no compositor, and the clock's BreakClock holds IdleMonitors)
}

one_arm() {
    local name="$1" t="$OUT/tree-arm-$1" log="$OUT/arm-$1.log" want out res
    snapshot "$t"
    apply_arm "$name" "$t" || { echo "ARM $name: could not be applied -- proves nothing"; rm -rf "$t"; return 1; }
    run "$t" "$log"
    want=$(needle "$name")
    out=$( { clean "$log" | grep -E "^SHM FAIL ${want} |SHELL_HOSTED_M1 RESULT"; static_s1 "$t" | grep "^SHM FAIL ${want} "; } )
    res=$(clean "$log" | grep -o "SHELL_HOSTED_M1 RESULT .*" | tail -1)
    [ -z "${KEEP:-}" ] && rm -rf "$t"
    if [ -z "$res" ]; then
        echo "ARM $name: the armed copy did not load -- it proves nothing (log: $log)"; return 1
    fi
    if printf '%s\n' "$res" | grep -q "RESULT PASS" && ! printf '%s\n' "$out" | grep -q "^SHM FAIL ${want} "; then
        echo "ARM $name: the armed fault PASSED -- the probe proves nothing"; return 1
    fi
    if ! printf '%s\n' "$out" | grep -q "^SHM FAIL ${want} "; then
        echo "ARM $name: failed, but not on $want:"
        clean "$log" | grep "^SHM FAIL" | head -3 | sed 's/^/    /'
        return 1
    fi
    printf '%s\n' "$out" | grep "^SHM FAIL ${want} " | head -1 | cut -c1-200 | sed 's/^/    /'
    echo "ARM $name: failed on $want, as it must"
}

ARM="${ARM:-}"
if [ "$ARM" = "all" ]; then
    fail=0
    for a in ${ONLY_ARMS:-selfbuild writeback writeclock writewiki route routestocks flags silicon muxwatcher store keyopen pulse cleared nodecay prewarm nowrite noguard holdall nograb}; do
        one_arm "$a" || fail=1
    done
    if [ "$fail" = 0 ]; then echo "SHELL_HOSTED_M1 ARMS PASS (every arm failed where it must)"; else echo "SHELL_HOSTED_M1 ARMS FAIL"; fi
    exit $fail
elif [ -n "$ARM" ]; then
    one_arm "$ARM"; exit $?
fi

t="$OUT/tree"
log="$OUT/probe.log"
snapshot "$t"
run "$t" "$log"
clean "$log" | grep -E "^SHM (PASS|FAIL) " | cut -c1-260
s1=$(static_s1 "$t")
printf '%s\n' "$s1" | cut -c1-260
w=$(warnings "$log")
if [ -n "$w" ]; then
    echo "SHELL_HOSTED_M1 the log warns:"
    printf '%s\n' "$w" | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
fi
res=$(clean "$log" | grep -a -o "SHELL_HOSTED_M1 RESULT .*" | tail -1)
[ -z "${KEEP:-}" ] && rm -rf "$t"
if [ -z "$res" ]; then
    rl_noresult SHELL_HOSTED_M1 "$log"
    exit 1
fi
if [ -n "$w" ]; then
    echo "SHELL_HOSTED_M1 RESULT FAIL (the log warns; probe said: $res)"
    exit 1
fi
if printf '%s\n' "$s1" | grep -q "^SHM FAIL"; then
    echo "SHELL_HOSTED_M1 RESULT FAIL (S1; probe said: $res)"
    exit 1
fi
echo "$res"
case "$res" in *"RESULT PASS"*) exit 0 ;; esac
exit 1
