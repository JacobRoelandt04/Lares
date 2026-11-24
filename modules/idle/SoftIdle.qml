pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "SoftRules.js" as Rules
import "IdleConfig.js" as Cfg
import "../common/system"
// the OSD's own brightness curve: how bright a raw value LOOKS (brightnessRungs / brightnessPos / brightnessRawAt)
import "../osd/data/OsdKinds.js" as Osd

// =============================================================================
// SoftIdle.qml -- the dimming rule engine of the idle modes soft AND off (docs/idle.md): the screen dims, but never goes
// dark. In soft the system never suspends either (IdleService holds the Wayland inhibitor); in off nothing is held and the machine goes
// on to suspend by hypridle's own 240 s listener, the dimming being the same (an OLED could burn in at full brightness).
//
// WHAT IT DOES TO THE MACHINE is one thing: the laptop panel's brightness, in three levels. It does the two dimming steps ITSELF
// (at 2 min: `dimLevel`, 0.7, of how bright the panel looked; at 3 min: `deepLevel`, 0.5) on the OSD's own perceived-brightness curve,
// saving the full raw value in the script's state file first, and gives the saved value back with the user's script (--resume on
// activity). SOFT NEVER GOES DARK: it never runs their --pre-idle (half by integer division: 0 on a panel at 1) or --idle
// (brightnessctl set 0); its steps are never below raw 1, never raise the panel, and leave a panel the user set to 0 at 0. It never
// blanks, locks or suspends either -- IdleService holds the Wayland inhibitor while soft is applied, so hypridle's own listeners
// (their dim, their suspend) stay quiet and these rules are the only ones that act. SoftRules.js has the levels and the steps.
//
// TWO THINGS ASK FOR A LEVEL, and the panel takes the higher of the two:
//   the input idleness   two IdleMonitors with respectInhibitors OFF (the inhibitor is ours, and a monitor that obeyed it would
//                        never fire): nothing touched for dimAfter -> dimmed, for deepAfter -> deep. Any input is both
//                        monitors resuming at once.
//                        CONTENT THAT ASKED FOR THE SCREEN holds the input idleness off (ContentHold: a browser's video, a player): the shell's own inhibitor is why these
//                        monitors cannot see it. It decides when input goes idle, before any step, and every 15 s after; when it ends, the idleness counts again.
//   the attention        with an external output connected and a laptop panel beside it, the focus (FocusedScreen: it follows
//                        the pointer and the windows) has been on the external one for awayAfter -> dimmed, until the focus or
//                        the pointer comes back to the panel. Only the panel is dimmed: it is the one the script's backlight is.
//
// NO BACKLIGHT (PanelBacklight found none: a desktop, or one that has not registered yet) means no dimming step: each would fail and be tried
// again at every look at the content. A device that comes is a new decision.
//
// THE STEPS RUN ONE AT A TIME, in the order resume -> dim -> deep, and only ever from where the last step left the panel: the dim
// step saves the brightness it finds as the one to give back, so a second dim (or one made while the panel is deep) would save the
// dimmed value for good; the deep step reads that saved value and writes nothing, so --resume still gives the full one back. A dim or
// deep step is two small commands (read the panel and the state file; then save and set what SoftRules.decide worked out). A step in
// flight cannot be taken back, so a new answer waits for it and replaces what had not started: activity while the dim step runs
// makes the plan "--resume" next, and a queued deep step never runs.
//
// A DIM LEFT BEHIND by an earlier run (the shell restarted or crashed while the panel was dimmed: the script's state file is still
// there) is given back at start.
//
// NOT LIVE (the mock mode of the whole shell, every probe that is not the nested-compositor one): no IdleMonitor is enabled and no
// script runs; each step is recorded in `log` and counts as done at once. `setIdle()` stands in for the monitors, a FocusedScreen
// fake stands in for the compositor's focus, so the rules are the same code in both.
// =============================================================================
Item {
    id: root

    // ---- in ------------------------------------------------------------------------------------------------------------------
    property bool live: false
    // the dimming applies (IdleService.dims: the mode is off or soft, and the brightness script is there)
    property bool active: false
    // FocusedScreen: `name`, `monitors`. null: the attention rule is off.
    property var focusSource: null
    // IdleConfig.parse(): dimAfterS, deepAfterS, dimLevel, deepLevel, awayAfterS, panel, script, stateFile, brightnessctl
    property var settings: Cfg.parse(undefined, Quickshell.env("HOME") || "")
    // the panel's backlight, by name (PanelBacklight: the GPU that drives the eDP). The rules' steps name it in every brightnessctl call.
    property string device: PanelBacklight.device
    readonly property var _rs: Object.assign({}, root.settings, { device: root.device })
    // The OSD's brightness curve numbers ({ gamma, step, floorRaw }: OsdConfig's `brightness`); anything missing takes OsdKinds' default.
    property var ladder: undefined

    // ---- out -----------------------------------------------------------------------------------------------------------------
    // The level the panel is at: the last step that finished (0 full, 1 dimmed, 2 deep -- never dark).
    readonly property int level: root._level
    // The attention is away from the laptop panel, with an external output on (the timer for the dim runs while this holds).
    readonly property bool away: root.active && root.settings.awayAfterS > 0 && root.attention.away
    // ... and has been for awayAfter.
    readonly property bool awayDimmed: root._awayDimmed
    // The level the INPUT IDLENESS asks for, content that holds the screen taken into account (0 full, 1 dimmed, 2 deep): the panel's steps
    // follow it through the plan; DdcDim takes it for the external displays.
    readonly property int idleLevel: root._idleLevel
    readonly property var attention: Rules.attention(root.focusSource ? root.focusSource.monitors : [], root.focusSource ? root.focusSource.name : "", root.settings.panel)
    // [{ event: "step" | "set" | "skip" | "done" | "recover" | "given", arg, argv?, full?, max?, save?, target?, why?, code?, level?, idle, away, ms }],
    // oldest first, the last 200. "set": what a dim / deep step worked out (the full value, the panel's maximum, the number saved, the
    // raw value set; target 0 = nothing); "skip": it had nothing to go on (`why`).
    readonly property var log: root._log

    signal stepped(int level)

    // ---- the idleness -------------------------------------------------------------------------------------------------------
    // The monitors' answer, or a probe's (setIdle): what the input idleness asks for.
    function setIdle(dim: bool, deep: bool): void {
        root._idleDim = dim;
        root._idleDeep = deep;
        root._soon();
    }

    IdleMonitor {
        id: monDim
        enabled: root.live && root.active && root.settings.dimAfterS > 0
        timeout: Math.max(1, root.settings.dimAfterS)
        respectInhibitors: false
        onIsIdleChanged: {
            root._idleDim = monDim.isIdle;
            root._soon();
        }
    }
    IdleMonitor {
        id: monDeep
        enabled: root.live && root.active && root.settings.deepAfterS > 0
        timeout: Math.max(1, root.settings.deepAfterS)
        respectInhibitors: false
        onIsIdleChanged: {
            root._idleDeep = monDeep.isIdle;
            root._soon();
        }
    }

    // ---- what is on the screen ------------------------------------------------------------------------------------------------
    readonly property alias content: content
    ContentHold {
        id: content
        live: root.live
        ignore: root.settings.contentIgnore
        polling: root.active && (root._idleDim || root._idleDeep)
        onHeldChanged: {
            console.log("LARES idle content " + (content.held ? "holds: " + content.who().join(", ") : "let go"));
            root._soon();
        }
        onAnswered: root._soon()
    }

    // ---- the attention ------------------------------------------------------------------------------------------------------
    // Running while the attention is away; the dim comes when it has run its course, and goes the moment the attention is back.
    Timer {
        id: awayTimer
        interval: Math.round(root.settings.awayAfterS * 1000)
        running: root.away
        onTriggered: {
            root._awayDimmed = true;
            root._soon();
        }
    }
    onAwayChanged: {
        if (!root.away)
            root._awayDimmed = false;
        root._soon();
    }

    onDeviceChanged: root._soon()
    onActiveChanged: {
        if (!root.active) {
            root._idleDim = false;
            root._idleDeep = false;
            root._awayDimmed = false;
        }
        root._soon();
    }

    // ---- the plan and the steps -----------------------------------------------------------------------------------------------
    property bool _idleDim: false
    property bool _idleDeep: false
    property bool _awayDimmed: false
    property int _level: 0
    property int _idleLevel: 0
    property int _planned: 0
    // [{ arg, end }] not started; the one in flight (null when none)
    property var _queue: []
    property var _current: null
    property bool _pumping: false
    property var _log: []

    // One decision per turn of the event loop: the two monitors report a resume one after the other, and a decision made between
    // the two would take the panel from deep to dimmed and on to full.
    function _soon(): void {
        Qt.callLater(root._retarget);
    }

    function _retarget(): void {
        const wanted = root._idleDeep ? Rules.DEEP : root._idleDim ? Rules.DIM : Rules.FULL;
        // nothing dims before the question has been asked: the answer comes back through _soon
        if (wanted !== Rules.FULL && !content.fresh) {
            content.refresh();
            return;
        }
        const idle = content.held ? Rules.FULL : wanted;
        root._idleLevel = root.active ? idle : Rules.FULL;
        // the plan starts where the step in flight will leave the panel; what had not started is replaced
        const from = root._current ? root._current.end : root._level;
        let to = Rules.target(root.active, idle, root._awayDimmed, from);
        if (root.live && root.device === "" && to > from)
            to = from;
        root._queue = Rules.planSteps(from, to);
        root._planned = to;
        root._pump();
    }

    function _pump(): void {
        if (root._pumping)
            return;
        root._pumping = true;
        while (root._current === null && root._queue.length > 0) {
            root._current = root._queue[0];
            root._queue = root._queue.slice(1);
            root._begin(root._current);
        }
        root._pumping = false;
    }

    function _note(e: var): void {
        e.ms = Date.now();
        e.idle = root._idleDeep ? 2 : root._idleDim ? 1 : 0;
        e.away = root._awayDimmed;
        const next = root._log.concat([e]);
        root._log = next.length > 200 ? next.slice(next.length - 200) : next;
    }

    function _begin(step: var): void {
        const argv = Rules.argvOf(step.arg, root._rs);
        root._note({ event: "step", arg: step.arg, argv: argv });
        if (!root.live) {
            root._finish(0);
            return;
        }
        if (step.arg === Rules.DIM_ARG || step.arg === Rules.DEEP_ARG) {
            // dim and deep read the panel and the state file first; _readOut goes on from what they said
            step.phase = "read";
            reader.command = argv;
            reader.running = true;
            return;
        }
        run.command = argv;
        run.running = true;
    }

    // What the read step printed (empty when it failed): worked out into a save and a set, and run.
    function _readOut(text: string): void {
        const step = root._current;
        if (step === null || step.phase !== "read")
            return;
        const d = Rules.decide(Osd, step.arg, text, root.settings, root.ladder);
        if (!d.ok) {
            step.phase = "skipped";
            root._note({ event: "skip", arg: step.arg, why: d.why });
            console.log("IdleService: the " + step.arg + " step has nothing to go on: " + d.why);
            root._finish(4);
            return;
        }
        step.phase = "set";
        root._note({ event: "set", arg: step.arg, full: d.full, max: d.max, save: d.save, target: d.target });
        run.command = Rules.setArgv(root._rs, d.save, d.target);
        run.running = true;
    }

    function _finish(code: int): void {
        const step = root._current;
        if (step === null)
            return;
        root._current = null;
        // A dim or deep step that did not complete (nothing to read, the state file unwritable, brightnessctl refused) left the panel
        // where it was: the level only moves on a step that worked. The script's --resume always counts -- it is the way back, and
        // it complains when there is nothing to give back.
        const own = step.arg === Rules.DIM_ARG || step.arg === Rules.DEEP_ARG;
        if (code === 0 || !own)
            root._level = step.end;
        root._note({ event: "done", arg: step.arg, code: code, level: root._level });
        if (code !== 0)
            console.log("IdleService: " + (own ? "the " + step.arg + " step (" + root.settings.brightnessctl + ", " + root.settings.stateFile + ")" : root.settings.script + " " + step.arg) + " exited " + code);
        root.stepped(root._level);
        root._pump();
    }

    // The script's --resume, and the second half of a dim / deep step (save and set).
    Process {
        id: run
        onExited: (code, status) => root._finish(code)
    }
    // The first half of a dim / deep step: its answer is the collector's text. (A read that fails prints nothing, and `_readOut`
    // takes the empty text as "nothing to go on".)
    Process {
        id: reader
        stdout: StdioCollector {
            onStreamFinished: root._readOut(this.text)
        }
    }

    // ---- the sleep fade gave the brightness back ------------------------------------------------------------------------------
    // The machine slept while the panel was dimmed (off mode: hypridle's suspend comes after the two dimming steps), and SleepFade's climb
    // after the resume went to the brightness this engine SAVED before it dimmed -- the user's -- instead of the --resume it would otherwise
    // have run. So the panel is full: the level is 0, no step is owed, the state file (which exists only between a dim and its give-back) goes,
    // and the idleness the monitors reported before the sleep is over (waking the machine was activity; the monitors say the next one when it
    // comes, and a dim then saves the full value again, not a dimmed one). A step in flight is left to finish; the decision after it is fresh.
    function panelGivenBack(): void {
        root._idleDim = false;
        root._idleDeep = false;
        root._queue = [];
        const was = root._level;
        if (root._current === null) {
            root._level = 0;
            root._planned = 0;
        }
        root._note({ event: "given", level: root._level });
        if (root.live) {
            forget.command = ["rm", "-f", root.settings.stateFile];
            forget.running = true;
        }
        if (root._level !== was)
            root.stepped(root._level);
        root._soon();
    }
    Process {
        id: forget
    }

    // ---- a dim an earlier run left ----------------------------------------------------------------------------------------------
    // The script's state file exists only between a dim step (which saves the full value there) and its --resume.
    Process {
        id: recover
        command: ["bash", "-c", "test -e \"$1\" || exit 99; bash \"$2\" --resume", "idle-recover", root.settings.stateFile, root.settings.script]
        onExited: (code, status) => {
            if (code !== 99)
                root._note({ event: "recover", arg: "--resume", code: code });
        }
    }

    Component.onCompleted: {
        if (root.live)
            recover.running = true;
    }
}
