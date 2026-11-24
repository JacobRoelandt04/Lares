pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "sleep"
import "../common/system"
import "IdleConfig.js" as Cfg
import "DdcDimRules.js" as DdcRules
import "IdleAutoRules.js" as AutoRules
import "../common/config/ConfigCheck.js" as Check
import "../common/config/ConfigSpecs.js" as Specs

// =============================================================================
// IdleService.qml -- what the idle-inhibit reel does (off, soft, normal, hard).
//
// The reel offers four modes (docs/idle.md); the shell
// applies them here:
//
//   off      idle is allowed: the screen DIMS exactly as in soft (SoftIdle's rules, the same steps and levels, ContentHold pausing
//            them for a video, the saved brightness back at the first input) and nothing is held, so the machine goes on to
//            SUSPEND (hypridle's 240 s listener, with the lock and the sleep fade as ever). The dimming is the shell's alone:
//            hypridle.conf has no brightness listener (only screentime's two and the 240 s suspend). hypridle
//            keeps running whatever the mode: it is not a systemd unit, so `systemctl --user stop hypridle` would do nothing.
//   soft     dim, never go dark, blank, lock or suspend: the Wayland inhibitor of "normal" (so hypridle's plain
//            listeners stay quiet) PLUS SoftIdle's rules, which dim the laptop panel -- by themselves, on the OSD's
//            own perceived-brightness curve: to `dimLevel` (0.7, about half the raw value) after 2 minutes without
//            input, to `deepLevel` (0.5, about a quarter) after 3, and with an external output connected to the dim
//            level after 5 minutes with the focus on that one -- never below raw 1, never their --pre-idle / --idle,
//            a panel the user set to 0 left at 0 -- and give the saved value back at once on activity (their --resume).
//            WHERE THERE IS NO LAPTOP PANEL (a desktop) the same two steps dim the external displays over DDC (DdcDim; idle.jsonc `ddcDim`,
//            `ddcDimLevel` 0.35 and `ddcDeepLevel` 0 of the display's own figure), and soft needs no brightness script.
//   normal   a Wayland idle inhibitor on every screen's bar window, all on ONE flag, `normalHold` (ShellScreen's IDLE HOLD makes
//            it afresh for every surface the window gets, asserts it again where Hyprland's count goes stale, and holds one on
//            the OSD pill's window while a fullscreen window covers the bar). hypridle's plain listeners respect it and stay
//            quiet; the ones written `ignore_inhibit = true` (screentime's) still fire.
//   hard     a systemd-inhibit lock on handle-lid-switch:sleep:idle, held by a child that
//            sleeps for ever -- the lid stays open as far as logind is concerned, and neither
//            idle nor sleep happens, whatever asks. Released the moment the mode is left
//            (the child is killed; it also dies with the shell: pdeathsig).
//            LidDim adds the one thing the inhibitor leaves out: a closed lid puts the panel at 0 (an OLED: off) and opening it gives the
//            brightness back, unless a brightness key got there first -- and the sleep veil wakes the panel's picture with that climb.
//
// THE SLEEP FADE (every mode; idle.jsonc `sleepFade`): SleepFade holds a logind sleep delay inhibitor, and when the machine is about to
// sleep it dims the screen to 0 under the sleep veil once the lock's veil has appeared, and wakes it at the same pace after
// (modules/idle/sleep, docs/idle.md). It reads the lock (`lock`, LockOwner) for the veil and for the unlock that skips the climb.
//
// THE AUTO LAYER IS A FLOOR, NEVER A SWAP (round 12). Whatever a cause asks for (`floorMode`) is the lowest the user's mode may be while it
// holds: the mode in force is the higher of the two, the layer never lowers or overwrites a mode the user picked (a hard stays hard under a
// soft cause, and is the user's still when the cause ends), and the idle reel takes PLAIN input at or above the floor -- setting the
// user's mode there -- and REFUSES what is under it: setMode(m) answers false (`refused`), the reel does not turn and shakes, and its side
// popup tells the cause. Ctrl (setMode(m, true)) is the way below: it sets the holders of that moment aside, as ever.
//
// `mode` IS THE MODE IN FORCE: the higher of the user's (`selectedMode`, what setMode sets) and the AUTO LAYER's (IdleAuto: content
// being watched or the screen shared asks for normal; the LLM answering, a timer running, a system update, music playing, a wiki
// batch, a download into the download folder ask for soft -- each after it
// has held for a few seconds, and kept a while after it lets go). `autoActive` says the auto layer is what raised it, `autoReason`
// why (the OSD card), and the idle reel follows the mode in force: it travels there by itself, wears its colour while the auto
// layer holds it. A Ctrl+click or Ctrl+scroll is `setMode(m, true)`: the user's mode, with the holders of that moment set aside until
// another one asks (IdleAutoRules.js). A mode the service refuses (soft with no
// brightness script, a hard lock that could not be held) is said with `refused(mode, reason)`, and the reel turns back to the
// mode in force (ReelActions / ShellFrame's ReelFollow).
//
// NOT LIVE (the mock mode of the whole shell, every probe): nothing is held. `held` says whether the
// lock WOULD be, and `log` records each hold and release with the argv it would have run; the soft rules run on
// the same code with their steps recorded (`soft.log`) and not executed.
// =============================================================================
Item {
    id: root

    property bool live: false
    // The module is there (shell.jsonc `modules`). False: there is no reel to show a mode or to pick one with, so nothing is in force whatever
    // the auto layer hears -- no inhibitor, no hard lock, no reason -- and hypridle's own rules are the only ones. (Not `live`: a mock shell is not
    // live and still shows its modes.)
    property bool present: true
    // the user's mode (the reel's choice, setMode)
    property string selectedMode: "off"
    readonly property var modes: ["off", "soft", "normal", "hard"]
    // THE MODES ON OFFER (idle.jsonc `items`, read once, when the config has landed: the reel's model never changes under a pointer):
    // the reel shows these, a pick of another is refused, a start or saved mode that is not one falls to the nearest one below, and a
    // cause that asks for one that is not gets the nearest one above (AutoRules.offered / down / up). All four until the config lands.
    property var offered: AutoRules.offered(null)

    // ---- the auto layer ----------------------------------------------------------------------------------------------------
    // Its facts are the host's (ShellServices binds the LLM, the timers, the update, the player); content is ContentHold's, watched
    // all the time while live (a player's own inhibitor is a poll; a browser's D-Bus request is heard at once).
    readonly property alias auto: autoLayer
    IdleAuto {
        id: autoLayer
        modes: root.checked.auto
        content: softEngine.content.held
        contentWho: softEngine.content.firstWho
    }
    Binding {
        target: softEngine.content
        property: "watch"
        value: root.live
    }
    // The auto layer raises the mode now.
    readonly property bool autoActive: root.present && AutoRules.rank(root._causeMode) > AutoRules.rank(root.selectedMode)
    // what the causes ask for, on offer (a mode left out of `items` is never in force, a cause's included)
    readonly property string _causeMode: AutoRules.up(autoLayer.mode, root.offered)
    // THE MODE IN FORCE: the higher of the two, read from the two SOURCES in one expression. It used to read the derived `autoActive`, which
    // can be a turn behind the source it is derived from, and for that turn the mode in force was UNDER the user's (hard -> "soft"):
    // the hard lock stopped and was held again, with the lid's inhibitor gone in between (tools/dev/idle_floor_probe.sh, ARM transient).
    readonly property string mode: root.present ? AutoRules.higher(root.selectedMode, AutoRules.up(autoLayer.mode, root.offered)) : "off"
    // Why the auto layer holds it ("" when it does not).
    readonly property string autoReason: root.autoActive ? autoLayer.reason : ""
    // THE FLOOR: whatever an auto cause asks for ("" none, or the user set it aside with Ctrl). It holds whether or not it raised the mode:
    // a plain pick under it is refused (setMode), the idle reel does not go there and shakes (IconReel.floorId).
    readonly property string floorMode: root.present ? root._causeMode : ""
    // The words for the floor, for the reel's side popup when it refuses ("" when no cause holds).
    readonly property string floorReason: root.floorMode !== "" ? autoLayer.reason : ""

    // FocusedScreen (the shell's one focus source): where the attention is, for soft's laptop-panel rule. null: no such rule.
    property var focusSource: null
    // the parsed idle.jsonc (IdleConfig.qml; IdleConfig.js has the keys); anything, including nothing
    property var config: undefined
    readonly property var settings: Cfg.parse(root.config, Quickshell.env("HOME") || "")
    // idle.jsonc's newer keys, through their spec (modules/common/config/specs/idle.js): `auto`, `start`, `download`, `packages`, `autoTell`
    readonly property var checked: Check.read(Specs.specOf("idle"), root.config !== null && typeof root.config === "object" ? root.config : {}).settings
    // The config has landed (IdleConfig.applied): the start mode is decided then, once. A host with no file says true.
    property bool configReady: true
    // The soft rules, for the bar and the probes.
    readonly property alias soft: softEngine
    // The OSD's brightness curve ({ gamma, step, floorRaw }: OsdConfig's `brightness`), which soft's steps are measured on. undefined: the defaults.
    property var ladder: undefined
    // The lock (LockOwner, or a probe's stand-in): the sleep fade waits for its veil, and its going away skips the climb. null: none known.
    property var lock: null

    // The displays' own brightness over DDC (PanoramaService; null: none). DdcDim dims them where there is no laptop panel, or where idle.jsonc says so.
    property var displays: null
    property string stateDir: ""
    readonly property alias ddc: ddcDim
    DdcDim {
        id: ddcDim
        live: root.live
        active: root.dims && DdcRules.applies(root.settings.ddcDim, PanelBacklight.scanned, PanelBacklight.panelThere)
        level: softEngine.idleLevel
        displays: root.displays
        settings: root.settings
        statePath: root.stateDir !== "" ? root.stateDir + "/ddc-dim.json" : ""
    }
    // A machine known to have no laptop panel: soft has nothing of the script's to run there.
    readonly property bool panelless: PanelBacklight.scanned && !PanelBacklight.panelThere

    // Why soft cannot run here ("" = it can): the user's brightness script is not there, or brightnessctl (which both steps read and set the brightness with) is not.
    property string softReason: ""
    readonly property bool softAvailable: root.softReason === "" || root.panelless
    // THE ONE RULE for where the shell dims the panel: in off and in soft (the same engine, the same steps), and only where the
    // dimming CAN run (the brightness script and brightnessctl are there). normal and hard dim nothing.
    readonly property bool dims: (root.mode === "off" || root.mode === "soft") && root.softAvailable

    // Read by ShellScreen's IDLE HOLD: the Wayland inhibitor is held by normal AND soft (soft dims by its own rules and
    // must never let hypridle blank or suspend).
    readonly property bool normalHold: (root.mode === "normal" || root.mode === "soft")
    // The hard lock is held (live: the child runs; not live: it would).
    readonly property bool held: root.mode === "hard"
    // The command the hard lock runs, as the argv it would be started with.
    readonly property var hardCommand: [
        "systemd-inhibit", "--what=handle-lid-switch:sleep:idle", "--who=lares",
        "--why=Idle inhibit: hard (the shell's idle reel)", "--mode=block",
        "setpriv", "--pdeathsig", "TERM", "--", "sleep", "infinity"
    ]

    // [{ event: "hold" | "release", argv, ms }], oldest first: what the hard lock did (live or not).
    readonly property var log: root._log

    signal refused(string mode, string reason)

    property var _log: []

    // Apply the user's mode. True when it is applied (or already is), false when it is refused. `override` (a Ctrl+click or
    // Ctrl+scroll on the reel while the auto layer holds it): the holders of this moment are set aside (IdleAuto.suppress).
    function setMode(m: string, override: var): bool {
        if (root.modes.indexOf(m) < 0)
            return false;
        if (root.offered.indexOf(m) < 0) {
            root.refused(m, "not in idle.jsonc items");
            return false;
        }
        // A plain pick UNDER the floor is refused; Ctrl (override) may go there and sets the holders aside.
        if (override !== true && root.floorMode !== "" && AutoRules.rank(m) < AutoRules.rank(root.floorMode)) {
            root.refused(m, root.floorReason + ": " + root.floorMode + " at least");
            return false;
        }
        if (m === "soft" && !root.softAvailable) {
            root.refused(m, root.softReason);
            return false;
        }
        if (override === true)
            autoLayer.suppress();
        if (m === root.selectedMode)
            return true;
        const wasHard = root.selectedMode === "hard";
        root.selectedMode = m;
        if (m === "hard" || wasHard)
            root._log = root._log.concat([{ event: m === "hard" ? "hold" : "release", argv: root.hardCommand.slice(), ms: Date.now() }]);
        return true;
    }

    // The hard lock. Live only; `setpriv --pdeathsig` inside ends the sleeper with the inhibitor,
    // and the outer one ends the inhibitor with the shell. A lock that ends by itself while hard is still the mode
    // (logind refused it, the program is gone) is NOT a lock: the mode goes back to off and says why, so the reel's
    // selection and the mode in force are seen to differ.
    Process {
        id: lock
        running: root.live && root.mode === "hard"
        command: ["setpriv", "--pdeathsig", "TERM", "--"].concat(root.hardCommand)
        onExited: (code, status) => {
            if (root.selectedMode !== "hard")
                return;
            root._log = root._log.concat([{ event: "release", argv: root.hardCommand.slice(), ms: Date.now() }]);
            root.selectedMode = "off";
            root.refused("hard", "the lock ended by itself (" + (code !== 0 ? "exit " + code : "it stopped") + ")");
        }
    }

    // The soft rules, running in off and in soft (`dims`). Their inputs are this service's: the mode, the focus, the settings.
    SoftIdle {
        id: softEngine
        live: root.live
        active: root.dims
        focusSource: root.focusSource
        settings: root.settings
        ladder: root.ladder
    }

    // The lid closed in hard idle puts the panel at 0 and opening it gives the brightness back (LidDim). The lid is logind's, read on the
    // system bus (LidWatcher); not live, nothing is watched or run.
    readonly property alias lid: lidWatcher
    LidWatcher {
        id: lidWatcher
        enabled: root.live
    }
    LidDim {
        id: lidDimmer
        live: root.live
        active: root.mode === "hard"
        lidClosed: lidWatcher.closed
        brightnessctl: root.settings.brightnessctl
        device: sleepFader.device
        // where the panel's 0 is lit (nvidia_0), the lid-closed dark is the sleep veil held black over the panel
        veil: sleepFader
        restoreMs: Math.round(root.settings.lidRestoreS * 1000)
        ladder: root.ladder
        onClimbing: ms => sleepFader.lidWake(ms)
        onClimbEnded: result => sleepFader.lidEnd(result)
    }

    // The screen falls asleep before the machine does, and wakes after it.
    readonly property alias sleep: sleepFader
    SleepFade {
        id: sleepFader
        live: root.live
        settings: root.settings
        lock: root.lock
        ladder: root.ladder
        // the climb after a suspend gives back what SoftIdle saved before dimming: SoftIdle's level and state file then agree with the panel
        onGaveBack: softEngine.panelGivenBack()
    }

    // Is soft possible here? Asked once at start and again when the settings change. Live only: not live, soft is always possible
    // (nothing runs). A soft that stops being possible while it is the mode in force is not a mode in force.
    // THE COMMAND IS SET WHEN THE CHECK STARTS, from the settings as they are then: a handler of `settings` runs before the binding
    // of a `command` on the same property has followed it, and a check of the old path would answer for the new one.
    Process {
        id: softCheck
        onExited: (code, status) => {
            root.softReason = code === 11 ? "the brightness script " + root._checkedPath + " is not there"
                : code === 12 ? root._checkedCtl + " is not installed" : "";
            if (!root.softAvailable && root.selectedMode === "soft") {
                root.selectedMode = "off";
                root.refused("soft", root.softReason);
            }
            if (root._recheck) {
                root._recheck = false;
                root.checkSoft();
            }
        }
    }
    property string _checkedPath: ""
    property string _checkedCtl: ""
    property bool _recheck: false
    function checkSoft(): void {
        if (!root.live)
            return;
        if (softCheck.running) {
            root._recheck = true;
            return;
        }
        root._checkedPath = root.settings.script;
        root._checkedCtl = root.settings.brightnessctl;
        softCheck.command = ["bash", "-c", "[ -r \"$1\" ] || exit 11; command -v \"$2\" > /dev/null 2>&1 || exit 12", "idle-check", root._checkedPath, root._checkedCtl];
        softCheck.running = true;
    }
    onSettingsChanged: root.checkSoft()
    Component.onCompleted: {
        root.checkSoft();
        root._begin();
    }

    // ---- THE START (idle.jsonc `start`) -------------------------------------------------------------------------------------
    // Once, when the config has landed: a mode, or "last" -- the mode left in THIS Hyprland session (`idle-mode.json` in stateDir, keyed by
    // the instance signature, so a restart of the shell keeps it and a new login starts at off). A start the service refuses now (soft with
    // no brightness tool) is refused as a pick is. Every change of the user's mode after it is written down (stateDir only: a mock's is private).
    property bool _started: false
    readonly property string _session: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    onConfigReadyChanged: root._begin()
    onPresentChanged: root._begin()
    function _begin(): void {
        if (root._started || !root.configReady || !root.present)
            return;
        root._started = true;
        root.offered = AutoRules.offered(root.checked.items);
        let m = root.checked.start;
        if (m === "last") {
            m = "off";
            if (modeFile.path !== "") {
                modeFile.reload();
                try {
                    const d = JSON.parse(modeFile.text() || "{}");
                    if (d && d.session === root._session && root.modes.indexOf(d.mode) >= 0)
                        m = d.mode;
                } catch (e) {}
            }
        }
        m = AutoRules.down(m, root.offered);
        if (m !== root.selectedMode)
            root.setMode(m);
    }
    onSelectedModeChanged: {
        if (root._started && modeFile.path !== "")
            modeFile.setText(JSON.stringify({ session: root._session, mode: root.selectedMode }) + "\n");
    }
    FileView {
        id: modeFile
        path: root.stateDir !== "" ? root.stateDir + "/idle-mode.json" : ""
        blockLoading: true
        blockAllReads: true
        printErrors: false
        atomicWrites: true
    }
}
