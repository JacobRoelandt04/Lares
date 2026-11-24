#!/usr/bin/env bash
# Stream M2 of the shell assembly: the launcher, clipboard, notifications and OSD owners in
# SHELL-HOSTED mode (CONTRACT section 4) -- two screens (two windows, two engines) on ONE set of
# services, as the shell runs them -- through the REAL engine, owners, popups and services, offscreen.
# Probe: tools/dev/qml/shell_hosted_m2_probe.qml (its header says what each check H1..H9 proves).
#
#   tools/dev/shell_hosted_m2_probe.sh                  expect SHELL_HOSTED_M2 RESULT PASS (last line)
#   ARM=<name> tools/dev/shell_hosted_m2_probe.sh       one fault patched into the SANDBOX copy: must FAIL on its
#                                                   own check (and have loaded)
#   ARM=all tools/dev/shell_hosted_m2_probe.sh          every arm; SHELL_HOSTED_M2 ARMS PASS only when each failed
#                                                   where it must.  ONLY_ARMS="a b" narrows the loop.
#   SMOKE=1 tools/dev/shell_hosted_m2_probe.sh          tools/dev/smoke.sh on the probe (the QML alone, not armed)
#
# The arms (each an exact-once anchored patch of the copy):
#   twostores       a hosted launcher owner builds its own service anyway               (H1: not one)
#   shortcutalways  a hosted owner registers its GlobalShortcut                         (H1: a shortcut)
#   flagwrite       the clipboard owner writes service.hostOpen when hosted             (H3 clipboard)
#   mgrwrite        the manager owner writes service.managerOpen when hosted            (H3 manager)
#   openall         an unaddressed openManagerRequested opens on every screen          (H4)
#   nocatch         the exclusive manager asks for no catch-all                         (H5)
#   norelease       outsidePress does nothing                                           (H5)
#   alongy          _alongOf reads y on a side bar (the old rule)                       (H6)
#   osdeverywhere   an inactive OsdOwner presents anyway                                (H7)
#   noflip          an OsdOwner going inactive keeps what it had out                    (H7)
#   noreport        a hosted manager owner does not report its lane's unseen state     (H8)
#   nopass          OsdService does not hand its audio backend to the source            (H9)
#   instant         BatterySource's Loader is active at creation again (stage N3)       (H9: BatteryData built)
#   sourcesbuild    the five sources' hosted guard removed                              (the static guard check)
#   noholdsource    NotificationService does not hand focusSource to its holds          (H10)
#   osdnosource     OsdOwner's active / fullscreen defaults ignore the tracker           (H10)
#   osdnoscreen     OsdOwner's `screen` is not read                                      (H10)
#   osdnews         fullscreen "keys" shows news too                                     (H10)
#   authnosource    AuthOwner's screenName / fullscreen defaults ignore the tracker      (H10)
#
# NEEDS THE TREE WITH E2 MERGED (main f7c8caec: FocusedScreen, FullscreenWatch.focusSource): H10 drives a
# FocusedScreen fake, and the service's holds pass `focusSource` to a FullscreenWatch.
#
# HOW. Re-execs into the sandbox (tools/dev/sandbox.sh; a copy of the tree), snapshots the whole of `modules/`
# into $OUT/cfg (the ARMs patch THAT), the fixture applications as XDG_DATA_DIRS, private XDG homes and a seeded theme, stubs on PATH for
# every program that could reach the desktop, and runs the probe on a PRIVATE session bus (nothing
# D-Bus-activated: no mako) with QT_QPA_PLATFORM=offscreen and no Hyprland socket. The log is a file read
# after the process has ended. The five OSD sources are instantiated live (hosted, no backend) only when a
# static scan has found their guard in place: a missing guard would build a REAL Pipewire / MPD /
# NetworkManager / BlueZ / EC reader, and that is never started by a probe.
set -u
# The shell's one sleep monitor is a `gdbus monitor` on logind: it has nothing to watch on a private bus.
export LARES_SLEEP_MONITOR=off
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
. tools/dev/fixtures/notifications/probe_lib.sh
. tools/dev/result_lib.sh
NAME=SHELL_HOSTED_M2
PROBE=shell_hosted_m2_probe.qml
SCRATCH="${SCRATCH:-$HOME/.cache/claude-shell/m2}"

# A sandbox runs this very script from its copy (no .git there); in a worktree .git is a FILE.
if [ -e .git ] && [ -z "${M2_INNER:-}" ]; then
    mkdir -p "$SCRATCH"
    exec env SCRATCH="$SCRATCH" SANDBOX="${SANDBOX:-$SCRATCH/lares-sandbox}" tools/dev/sandbox.sh \
        M2_INNER=1 SCRATCH="$SCRATCH" ARM="${ARM:-}" ONLY_ARMS="${ONLY_ARMS:-}" SMOKE="${SMOKE:-}" \
        QT_QPA_PLATFORM=offscreen bash tools/dev/shell_hosted_m2_probe.sh
fi
OUT="$SCRATCH/shell_hosted_m2_probe"
mkdir -p "$OUT"

# the sources that can build a service of their own (a Loader behind the hosted guard), and the two that read the shell's AerialService and never build one
SRCS="AudioSource MpdSource BatterySource"
NOBUILD="NetSource BtSource"
GUARD='active: root.live && root.backend === null && !root.shellHosted'

prepare() {  # cfg: the snapshot the probe (and an ARM) works on
    local cfg="$1" f
    notif_snapshot "$cfg" "tools/dev/qml/$PROBE"
    rm -rf "$cfg/modules"
    cp -r "$ROOT/modules" "$cfg/modules"
    mkdir -p "$cfg/tools/dev/fixtures/launcher" "$cfg/cfg" "$cfg/state/launcher"
    cp -a "$ROOT/tools/dev/fixtures/launcher/applications" "$cfg/tools/dev/fixtures/launcher/"
    return 0
}

guard_ok() {  # cfg: the five sources' Loaders carry the hosted guard
    local f
    for f in $SRCS; do
        grep -qF "$GUARD" "$1/modules/osd/data/sources/$f.qml" || return 1
    done
    for f in $NOBUILD; do
        ! grep -qE '^ *Loader \{' "$1/modules/osd/data/sources/$f.qml" || return 1
    done
}

run_probe() {  # cfg log
    local cfg="$1" log="$2" g=0
    guard_ok "$cfg" && g=1
    NOTIF_TIMEOUT="${NOTIF_TIMEOUT:-170}" notif_run "$cfg" "$PROBE" "$log" PROBE_DIR="$cfg" \
        XDG_DATA_DIRS="$cfg/tools/dev/fixtures/launcher" M2_SOURCES_GUARDED="$g"
}

# The log's warnings, less the hosted sources' own announcement (five instances, one line each; the net and bluetooth sources both read the one AerialService).
expected_warns() { sed -r 's/\x1b\[[0-9;]*m//g' "$1" | grep -aE "shell-hosted but the (audio|mpd|net|bluetooth|battery) source got no backend"; }

verdict() {  # cfg log: prints the probe's lines and the log-clean verdict; 0 only on PASS
    local cfg="$1" log="$2" warns nexp
    rl_has "$log" 'M2 DONE ' || { rl_noresult "$NAME" "$log"; return $?; }
    notif_lines "$log" M2 | sed 's/^/  /'
    local rc=0
    notif_lines "$log" M2 | grep -q "M2 DONE checks=[0-9]* fails=0" || rc=1
    if guard_ok "$cfg"; then
        echo "  M2 PASS H9 static: the five sources' Loaders carry the hosted guard"
    else
        echo "  M2 FAIL H9 static guard: a source's Loader lacks the hosted guard"
        rc=1
    fi
    nexp=$(expected_warns "$log" | wc -l)
    if guard_ok "$cfg" && [ "$nexp" -ne 5 ]; then
        echo "  M2 FAIL H9 each hosted source with no backend says so once in the log (found $nexp lines, wanted 5)"
        rc=1
    fi
    warns=$(notif_warnings "$log" | grep -vE "shell-hosted but the (audio|mpd|net|bluetooth|battery) source got no backend")
    if [ -n "$warns" ]; then
        echo "  M2 FAIL the log warns"
        printf '%s\n' "$warns" | sed 's/^/      /' | head -10
        rc=1
    fi
    return $rc
}

# ---- the arms --------------------------------------------------------------------------------------
ARMS="twostores shortcutalways flagwrite mgrwrite openall nocatch norelease alongy osdeverywhere noflip noreport nopass instant sourcesbuild noholdsource osdnosource osdnoscreen osdnews authnosource"
needle() {
    case "$1" in
        twostores) echo "H1 one LauncherService in the whole shell" ;;
        shortcutalways) echo "H1 a hosted owner registers no GlobalShortcut" ;;
        flagwrite) echo "H3 clipboard: open on a screen" ;;
        mgrwrite) echo "H3 manager: open on a screen" ;;
        openall) echo "H4 openManagerRequested" ;;
        nocatch) echo "H5 opened by a request" ;;
        norelease) echo "H5 a press in the void closes it" ;;
        alongy) echo "H6 " ;;
        osdeverywhere) echo "H7 the active screen presents the OSD" ;;
        noflip) echo "H7 a screen that goes inactive" ;;
        noreport) echo "H8 a hosted owner reports it itself" ;;
        nopass) echo "H9 OsdService hands the shell's backends" ;;
        instant) echo "H9 BatterySource whose adapter arrives" ;;
        sourcesbuild) echo "H9 static guard" ;;
        noholdsource) echo "H10 the service hands focusSource" ;;
        osdnosource) echo "H10 an OsdOwner given the tracker" ;;
        osdnoscreen) echo "H10 ... a named display has it" ;;
        osdnews) echo "H10 ... fullscreen \"keys\"" ;;
        authnosource) echo "H10 the one AuthOwner" ;;
    esac
}
apply_arm() {  # name cfg
    local m="$2/modules" f
    case "$1" in
        twostores) notif_arm "$m/launcher/LauncherBarOwner.qml" \
            '        id: own
        active: !owner.shellHosted
' '        id: own
        active: true
' ;;
        shortcutalways) notif_arm "$m/launcher/LauncherBarOwner.qml" \
            '        active: owner.shortcutEnabled && !owner.shellHosted' \
            '        active: owner.shortcutEnabled' ;;
        flagwrite) notif_arm "$m/clipboard/ClipboardBarOwner.qml" \
            '        when: !!owner.service && !owner.shellHosted' '        when: !!owner.service' ;;
        mgrwrite) notif_arm "$m/notifications/NotificationsBarOwner.qml" \
            '        when: !owner.shellHosted && !!owner.service && owner.popupMine' \
            '        when: !!owner.service && owner.popupMine' ;;
        openall) notif_arm "$m/notifications/NotificationsBarOwner.qml" \
            '(screenName === "" ? owner.service.laneScreen === owner.screenName : screenName === owner.screenName)' \
            '(screenName === "" ? true : screenName === owner.screenName)' ;;
        nocatch) notif_arm "$m/notifications/NotificationManagerPopup.qml" \
            'readonly property bool maskCatchAll: root.openedByKeyboard' 'readonly property bool maskCatchAll: false' ;;
        norelease) notif_arm "$m/notifications/NotificationManagerPopup.qml" \
            '    function outsidePress() {
        if (root.service)
            root.service.closeManagerRequested();
    }' '    function outsidePress() {
    }' ;;
        alongy) notif_arm "$m/notifications/NotificationsBarOwner.qml" \
            '        return item.mapToItem(owner.bar, item.width / 2, item.height / 2).x;' \
            '        const p = item.mapToItem(owner.bar, item.width / 2, item.height / 2);
        return owner.bar && (owner.bar.edge === "left" || owner.bar.edge === "right") ? p.y : p.x;' ;;
        osdeverywhere) notif_arm "$m/osd/OsdOwner.qml" \
            '        if (!owner.active || !req || req.kind === undefined)' '        if (!req || req.kind === undefined)' ;;
        noflip) notif_arm "$m/osd/OsdOwner.qml" \
            '        if (!owner.active)
            owner.dismiss();' '        if (false)
            owner.dismiss();' ;;
        noreport) notif_arm "$m/notifications/NotificationsBarOwner.qml" \
            '        if (owner.shellHosted && owner.service && owner.useLane)' '        if (false)' ;;
        nopass) notif_arm "$m/osd/data/OsdService.qml" \
            '        backend: root.audioBackend
' '' ;;
        instant) notif_arm "$m/osd/data/sources/BatterySource.qml" \
            '        active: root.live && root.backend === null && !root.shellHosted && root.ownBackend
        sourceComponent: BatteryData {}' \
            '        active: root.live && root.backend === null
        sourceComponent: BatteryData { polling: false }' ;;
        noholdsource) notif_arm "$m/notifications/data/NotificationService.qml" \
            '        focusSource: root.focusSource
        config: root.config' '        config: root.config' ;;
        osdnosource) notif_arm "$m/osd/OsdOwner.qml" \
            'property bool active: owner._display === "" || owner._display === owner.screenName' \
            'property bool active: true' ;;
        osdnoscreen) notif_arm "$m/osd/OsdOwner.qml" 'owner.focusSource.displayFor(owner.screen)' 'owner.focusSource.name' ;;
        osdnews) notif_arm "$m/osd/OsdOwner.qml" '(owner.fullscreenMode === "keys" && !Kinds.byUser(req))' 'false' ;;
        authnosource) notif_arm "$m/auth/AuthOwner.qml" \
            'property string screenName: owner.focusSource ? owner.focusSource.name : ""' 'property string screenName: ""' ;;
        sourcesbuild) for f in $SRCS; do
            notif_arm "$m/osd/data/sources/$f.qml" "$GUARD" 'active: root.live && root.backend === null' || return 1
        done ;;
        *) echo "unknown ARM=$1"; return 2 ;;
    esac
}

one_arm() {
    local name="$1" cfg="$OUT/cfg_arm_$1" log="$OUT/arm_$1.log" want out
    prepare "$cfg" || { echo "ARM $name: could not prepare"; return 1; }
    apply_arm "$name" "$cfg" || { echo "ARM $name: could not arm"; return 1; }
    run_probe "$cfg" "$log"
    if ! rl_has "$log" 'M2 DONE '; then
        echo "ARM $name: the armed copy did not load -- it proves nothing"
        rl_noresult "$NAME" "$log"
        return 1
    fi
    want=$(needle "$name")
    out=$(verdict "$cfg" "$log" 2>&1)
    if [ $? -eq 0 ]; then
        echo "ARM $name: the armed fault PASSED -- the probe proves nothing"
        return 1
    fi
    if ! printf '%s\n' "$out" | grep "FAIL" | grep -qF "$want"; then
        echo "ARM $name: failed, but not on \"$want\":"
        printf '%s\n' "$out" | grep FAIL | head -4 | sed 's/^/    /'
        return 1
    fi
    printf '%s\n' "$out" | grep FAIL | grep -F "$want" | head -1 | sed 's/^/    /'
    echo "ARM $name: FAIL on \"$want\", as it must"
    rm -rf -- "${cfg:?}"
}

if [ -n "${SMOKE:-}" ]; then
    prepare "$OUT/cfg_smoke" || exit 1
    notif_smoke "$OUT/cfg_smoke" "$PROBE"
    exit $?
fi

ARM="${ARM:-}"
if [ "$ARM" = all ]; then
    fail=0
    for a in ${ONLY_ARMS:-$ARMS}; do
        out=$(one_arm "$a"); rc=$?
        printf '%s\n' "$out"
        [ "$rc" -ne 0 ] && fail=1
    done
    [ "$fail" = 0 ] && echo "$NAME ARMS RESULT PASS (every arm failed where it must)" || echo "$NAME ARMS RESULT FAIL"
    exit $fail
elif [ -n "$ARM" ]; then
    one_arm "$ARM"
    exit $?
fi

cfg="$OUT/cfg"
prepare "$cfg" || { echo "$NAME RESULT FAIL (the fixture did not build)"; exit 1; }
run_probe "$cfg" "$OUT/probe.log"
out=$(verdict "$cfg" "$OUT/probe.log"); rc=$?
printf '%s\n' "$out"
rl_isnoresult "$out" && exit 1
if [ "$rc" = 0 ]; then
    echo "$NAME RESULT PASS ($(printf '%s\n' "$out" | grep -c 'M2 PASS') checks)"
else
    echo "$NAME RESULT FAIL   (log: $OUT/probe.log)"
    exit 1
fi
