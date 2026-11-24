pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../bar/reel/ReelFlourish.js" as Flourish

// =============================================================================
// ReelActions.qml -- what the power reel and the idle reel DO (CONTRACT: the reel only emits).
//
//   power reel  (a RIGHT click on the selected icon fires; the reel's own safety; so does the `lares:lock` key, for Lock)
//     every item plays its FLOURISH first (`flourished(id)`: every screen's power reel plays it), and the ones that end the
//     session or the machine at once WAIT for it (ReelFlourish.waitMs: poweroff, reboot, logout and hibernate run when theirs has
//     played, plus a short margin). Lock never waits: it starts at once and its flourish plays while the lock comes up. Neither
//     does sleep: the lock's veil and the sleep fade are its show, and the moon plays over their start. While one waits, another
//     fire is refused (one right click is one action).
//     sleep      systemctl suspend
//     poweroff   systemctl poweroff
//     reboot     systemctl reboot
//     logout     hyprctl dispatch hl.dsp.exit()        the Lua form (`exit` is gone)
//     lock       <state>/lares/lock/current/tools/lockscreen/lares-lock-session   the Lares lock, from its snapshot, when that
//                file is executable; else ~/.local/bin/hyprlock (the fallback lock) -- never nothing. Detached: a lock
//                that the shell's restart could unlock is no lock
//     hibernate  NOTHING until power.jsonc gives it a command: it says so in a notification.
//     power.jsonc `commands` replaces an item's command (never Lock's); `waitForFlourish` false runs every item at once.
//     THE SESSION'S SAVE comes first for logout, reboot and poweroff while session restore is on (`sessionTool`, from
//     SessionService): `lares-session end <id>` under a 3 s deadline, its status ignored, THEN the item's own command, in one
//     `sh -c` -- a save that fails or hangs never keeps the session from ending, and nothing changes while the feature is off.
//   idle reel   (the mode SELECTED is the mode APPLIED: scroll to one and let it rest, or click the selected icon)
//     off / soft / normal / hard   IdleService.setMode. A mode the service refuses (soft with no brightness script, a
//     hard lock that could not be held) is SAID -- a notice with the service's own reason -- and the reel turns back to the
//     mode in force (ShellFrame's ReelFollow; `idleWaiting` keeps the reel the user's for the 400 ms a scroll is still
//     waiting to apply). While the AUTO layer holds the mode the reel takes no input but a Ctrl+click or Ctrl+scroll: those
//     arrive here with `override` true and become setMode(m, true), which sets the auto layer's holders of that moment aside.
//     A scroll applies after the reel has RESTED on its icon for `idleDwellMs`: every turn restarts the wait, so
//     scrolling past a mode applies nothing on the way (selecting a mode by scrolling the reel is the intuitive
//     way to change it; DeploymentNotes, Idle reel). A click applies at once. A refusal after
//     a scroll is said ONCE per mode per shell session, not at every pass of the reel; one after a click is said every
//     time (it is a question asked on purpose), and so is one that comes by itself (a lock that ended). The power reel
//     stays a right click: its safety is that scrolling never fires anything.
//
// Every command goes through the CommandRunner: live it runs, in the shell's mock mode it is only
// recorded -- a probe presses every item and reads `runner.calls`.
// =============================================================================
QtObject {
    id: root

    property var runner: null
    // The ONE command a MOCK shell may run for real, and only when this is set: the Lock item, in a nested test compositor's own session
    // (ShellServices.reelActions: SHELL_LOCK=live under tools/dev/lock_env.sh). A runner that only records proves the argv; a test of the
    // whole chain -- the click, this table, the detached start, the entry point -- needs the real lock. null (every other host): the runner alone.
    property var lockRunner: null
    property var idle: null
    property var notifier: null
    readonly property string home: Quickshell.env("HOME") || ""

    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (root.home + "/.local/state")
    // The Lares lock runs from a SNAPSHOT of the tree (a link to a committed revision's copy): editing the working tree never changes a
    // lock that is up or about to be. The one entry point sets what the lock needs and runs the snapshot's supervisor.
    readonly property string lockSession: root.stateHome + "/lares/lock/current/tools/lockscreen/lares-lock-session"
    // What the Lock item runs where there is no snapshot of the Lares lock.
    readonly property string lockPath: root.home + "/.local/bin/hyprlock"

    // How long the idle reel must rest on an icon before a scroll applies it.
    property int idleDwellMs: 400

    // Session restore's tool ("" = off: the items run as they always did) and the interpreter it runs under.
    property string sessionTool: ""
    property string sessionPython: "python3"
    // The items that end the session: its picture is saved first.
    function _savedFirst(id: string, argv: var): var {
        if (root.sessionTool === "")
            return argv;
        // $0 the interpreter, $1 the tool, $2 the reason; after the shift the item's own argv is "$@"
        return ["sh", "-c", "timeout -k 1 3 \"$0\" \"$1\" end \"$2\" > /dev/null 2>&1; shift 2; exec \"$@\"",
            root.sessionPython, root.sessionTool, id].concat(argv);
    }

    // power.jsonc: the commands that replace an item's own (`commands`), and whether the ones that end the session wait for their flourish.
    property var commands: ({})
    property bool waitForFlourish: true

    // The argv an item runs, or null for one that runs nothing.
    function commandOf(id: string): var {
        const c = id !== "lock" && root.commands ? root.commands[id] : undefined;
        if (c === undefined)
            return root.ownCommandOf(id);
        return id === "poweroff" || id === "reboot" || id === "logout" ? root._savedFirst(id, c) : c;
    }

    // ... and the one it has of its own (silicon's MUX restart is this reboot, whatever the reel's runs).
    function ownCommandOf(id: string): var {
        switch (id) {
        case "sleep": return ["systemctl", "suspend"];
        case "poweroff": return root._savedFirst(id, ["systemctl", "poweroff"]);
        case "reboot": return root._savedFirst(id, ["systemctl", "reboot"]);
        case "logout": return root._savedFirst(id, ["hyprctl", "dispatch", "hl.dsp.exit()"]);
        // decided when it RUNS (a snapshot made after the shell started counts), and one of the two always runs
        case "lock": return ["sh", "-c", "if [ -x \"$1\" ]; then exec \"$1\"; fi; exec \"$2\"", "sh", root.lockSession, root.lockPath];
        }
        return null;
    }

    // A power item fired: every screen's power reel plays its flourish (ShellFrame).
    signal flourished(string id)

    // The item waiting for its flourish to play out ("" when none), for the probes.
    readonly property string powerPending: root._powerPending
    property string _powerPending: ""
    // THE ACTION RUNS WHEN THE FLOURISH HAS PLAYED, as the screen shows it (a reel's `played`, through the frame: flourishPlayed),
    // plus a short margin -- not on a wall-clock guess of its length. A failsafe runs it anyway when no screen says so (no
    // bar on show): its length and a half second more.
    property Timer _powerMargin: Timer {
        interval: Flourish.FIRE_MARGIN_MS
        onTriggered: root._runPending()
    }
    property Timer _powerFailsafe: Timer {
        onTriggered: root._runPending()
    }
    function _runPending(): void {
        const id = root._powerPending;
        root._powerMargin.stop();
        root._powerFailsafe.stop();
        if (id === "")
            return;
        root._powerPending = "";
        root._runPower(id);
    }

    function firePower(id: string): bool {
        if (root._powerPending !== "")
            return false;
        root.flourished(id);
        const wait = root.waitForFlourish ? Flourish.waitMs(id) : 0;
        if (wait > 0) {
            root._powerPending = id;
            root._powerFailsafe.interval = wait + 500;
            root._powerFailsafe.restart();
            return true;
        }
        return root._runPower(id);
    }

    // A screen's power reel has played `id`'s flourish to its end (the first screen to say so).
    function flourishPlayed(id: string): void {
        if (id !== "" && id === root._powerPending && !root._powerMargin.running)
            root._powerMargin.restart();
    }

    function _runPower(id: string): bool {
        const argv = root.commandOf(id);
        if (id === "hibernate" && !argv) {
            if (root.notifier)
                root.notifier.notify("hibernate", { title: "Hibernate is not set up yet", body: "It has no command: power.jsonc \"commands\" gives it one.", urgency: "low", timeoutMs: 5000 });
            return false;
        }
        if (!argv || !root.runner)
            return false;
        root.runner.run(argv, { detached: id === "lock" });
        if (id === "lock" && root.lockRunner)
            root.lockRunner.run(argv, { detached: true });
        return true;
    }

    // A click on the selected idle icon: applied at once, and a wait for a scroll is over. `override`: made with Ctrl over a
    // reel the auto layer holds.
    function fireIdle(id: string, override: var): bool {
        root._idleDwell.stop();
        return root._applyIdle(id, false, override === true);
    }

    // The idle reel turned to `id` (its selection changed): apply it when the reel has rested there. An override made on the way
    // (a Ctrl+scroll) stays one until the apply.
    function idleSelected(id: string, override: var): void {
        root._pendingIdle = id;
        root._pendingOverride = override === true || (root._idleDwell.running && root._pendingOverride);
        root._idleDwell.restart();
    }

    // A scroll has turned the idle reel and it has not rested yet: the mode in force is about to change, so the bar does not
    // show the two as different.
    readonly property bool idleWaiting: root._idleDwell.running

    property string _pendingIdle: ""
    property bool _pendingOverride: false
    // The modes a scroll has already told about, and whether the apply being made now is a scroll's
    property var _said: ({})
    property bool _fromScroll: false
    property Timer _idleDwell: Timer {
        interval: root.idleDwellMs
        onTriggered: root._applyIdle(root._pendingIdle, true, root._pendingOverride)
    }

    function _applyIdle(id: string, fromScroll: bool, override: bool): bool {
        root._pendingOverride = false;
        if (!root.idle)
            return false;
        root._fromScroll = fromScroll;
        const ok = root.idle.setMode(id, override);
        root._fromScroll = false;
        return ok;
    }

    // Every refusal the service makes, the ones that come while a mode is being applied and the ones that come by themselves.
    property Connections _refusals: Connections {
        target: root.idle
        function onRefused(mode: string, reason: string): void {
            if (!root.notifier)
                return;
            if (root._fromScroll && root._said[mode] === true)
                return;
            if (root._fromScroll)
                root._said[mode] = true;
            const what = mode === "soft" ? "Soft idle is not available" : mode === "hard" ? "Hard idle is not held" : "Idle mode \"" + mode + "\" was not applied";
            root.notifier.notify("idle", { title: what, body: reason, urgency: "low", timeoutMs: 6000 });
        }
    }
}
