pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../common/theme"
import "../common/components"
import "../common/system"
import "../theme/data"

// =============================================================================
// ThemeControl.qml -- the theme switch: the button's right click (`click()`: light <-> dark; ThemeBarButton draws it) and the theme popup's cards
// (`pick(name, mode)`, modules/theme). `pairs` is what the popup shows. WHO switches is shell.jsonc's `"theme": { "apply": "shell" | "themectl" }`:
//
//   "shell"     (the default) the shell alone: `Theme.toggleMode()` / `Theme.setPair(name, mode)`. Nothing of the desktop moves --
//               kitty, btop, the borders, GTK and the wallpaper keep the mode they had. This is the default; it stays until the
//               user has read themectl's diff table (docs/theme.md) and switches.
//   "themectl"  the whole desktop: `tools/theme/themectl toggle` / `set <name> <mode>`, as a SUPERVISED CHILD. themectl writes
//               ~/.config/theme/state.json FIRST, which Theme.qml watches, so the shell's own crossfade starts as the child
//               does and the button never touches Theme itself (two flips would cancel). Its `ok` / `FAIL <target> <reason>`
//               lines go to the shell's log as they arrive, and a run that failed -- a FAIL line, a refusal (exit 100), no
//               themectl at all, a hang -- is ONE notification, never one per target.
//
// THE CHILD (CLAUDE.md, on children of a quickshell): `setpriv --pdeathsig TERM` so the kernel ends it when the shell dies (a
// quickshell that is killed destroys nothing), `setsid -w` so it has no controlling terminal and a session of its own (it runs
// gsettings, pkill, hyprctl; a terminal-keyed credential cache must not follow it), a watchdog (`timeoutMs`) that signals a child
// that hangs, one Process per click (two clicks are two children; themectl's own lock makes the second wait for the first). A
// themectl that is not there makes setpriv exit 127 -- a Process whose program does not exist emits neither started nor exited.
//
// `live: false` (a mock shell, a probe, a render) runs nothing: the argv goes to the CommandRunner, which records it.
// `toggled` / `picks` count the switches that were asked for (a probe reads them).
//
// THE CURTAIN (a PROTOTYPE, off by default: shell.jsonc `"theme": { "curtain": true, "curtainStyle": "radial|peel|louvres|cycle" }`).
// The switch above is the same either way; with the curtain on it runs BEHIND a picture of the screen:
//
//   arming      `hyprctl eval` installs the `no_anim` layer rule for the curtain's namespace (a runtime rule dies with a reload, so
//               every run puts it back) and `hyprctl -j cursorpos` says where the pointer is: the theme button, the reveal's origin
//   capturing   every screen's ThemeCurtain maps a clear Overlay window, captures its output (ScreencopyView, one frame) and draws it
//               at progress 0 -- identical to what is under it -- then says `ready` (the picture is ON SCREEN, two presented frames)
//   switching   only now the switch runs (the plain one: Theme.toggleMode / setTheme, or the themectl child). Theme.fadeMs is held
//               at 0 for the run so the shell's own snapshot crossfade does not play a second transition behind the curtain
//   holding     WHAT "SETTLED" MEANS: (1) the shell's tokens are final (Theme.mode / themeName moved; with fadeMs 0 that is synchronous),
//               (2) the apply child has exited (themectl: its targets are written and the apps signalled), and (3) a QUIET period of
//               `curtainHoldMs` (400): the apps repaint within a frame or two of their signal and the shell's own windows draw their
//               new frames, and nothing in Wayland tells the shell when a client has drawn. A fixed period is the honest choice (a
//               screencopy of the output would capture the curtain itself, and a hidden window's frame callbacks do not come at all);
//               it is quiet because a heartbeat watches the GUI thread and a stall (a beat 120 ms late: a window
//               below compiling a shader for the first time, 1-13 s) restarts the count, capped at `curtainHoldCapMs`.
//               The better signal would be per-window captures polled until they stop changing (ScreencopyView on a toplevel);
//               not built.
//   revealing   the reveal runs 0 -> 1 over `curtainRevealMs` (800), advanced BY FRAMES (each frame moves it at most `curtainMaxStepMs`,
//               50), so a frame that stalls pauses the reveal instead of cutting it; the style's shader keeps the picture where it
//               still covers and draws nothing where it has opened, so the live new desktop shows through; the windows go at 1
//
// THE OPEN PROBLEM: interacting with the windows during the transition. The curtain takes NO input (an empty input
// region, no keyboard): clicks, keys, the wheel and the pointer all reach the real windows. What the illusion cannot stand is the
// picture under the curtain changing into something the old picture does not show, so whenever that is about to happen the run
// FAST-FORWARDS: the hold is skipped and the reveal finishes within `curtainFastMs` (120). Triggers, from Hyprland's event socket
// (read only): a workspace switch (workspace, workspacev2, focusedmon, activespecial), a window opening, closing, moving, going
// fullscreen or floating, an output plugged or unplugged; a lock; and another click on the theme button (queued: it runs as the
// next curtain). Before the switch has run (arming, capturing) a trigger DROPS the curtain and the switch runs plain, as it does
// with the curtain off. NOT detectable: a key press or a pointer press INSIDE the focused window (Wayland tells the shell nothing
// of input it does not own, and a window that takes it would break the very thing the curtain is for): the keys go through, the
// window changes under the picture, and it shows when the reveal finishes (at most `curtainHoldMs + curtainRevealMs`, 1.2 s).
// The one trigger that proxies for it is a focus change between windows -- left out, because a pointer that merely crosses
// windows (follow_mouse) would end every run.
//
// Windows on a HIDDEN workspace, and a group's hidden tabs, do not repaint by themselves (Hyprland marks them suspended; a
// `render_unfocused` window rule makes GTK repaint while hidden, not kitty or Qt). So while the curtain holds they are SHOWN by turns
// under the picture: "THE HIDDEN WINDOWS" below, tools/theme/hidden_repaint.py, shell.jsonc `"curtainRepaint": false` turns it off.
//
// THE LIVE CURTAIN (a second prototype, off unless `"curtainLive": true` beside `"curtain": true`; ThemeWipe.qml has the design). The sequence above with four
// differences. The picture is not a window but a part of each shell window (`_claims`: every screen whose shell is on view; a screen covered by a
// fullscreen window keeps the stand-alone curtain). The shell is out of the picture and stays live. Its palette does NOT change behind the picture:
// Theme.deferSwitches keeps the switch while the apps repaint, so through `holding` the shell is simply the old shell, running; the tokens change at
// `committing`, the last moment before the line moves. And Theme.fadeProgress is the line's own clock (Theme.fadeExternal), so a FadeColor and the
// line cannot differ. The triggers stay: a workspace switch, a window opening and the rest fast-forward the reveal, the shell with it, on one clock.
// The theme OSD is announced when the switch arrives, in the old palette, and landed before the commit (`Theme.announcedName`, the hold waits for it), so it is in the old
// shell's picture and the line goes over it. What is out when a run starts stays until the run ends (OsdOwner.held, ToastScheduler.curtain): the still has nothing under it.
// =============================================================================
Item {
    id: root

    width: 0
    height: 0
    visible: false

    // ---- injected -----------------------------------------------------------------------------------------------
    // ShellConfig (its `raw` is the user's shell.jsonc as written); null = the defaults.
    property var config: null
    property bool live: false
    // CommandRunner: records every argv when not live.
    property var commands: null
    property string themectl: RepoRoot.dir + "/tools/theme/themectl"
    // DesktopNotifier's seam (a probe points it at a stub).
    property string notifySend: "notify-send"
    property int timeoutMs: 30000
    // True while the session is locked (ShellServices): the curtain is never used then, and a lock ends a run in progress.
    property bool locked: false
    // The curtain's numbers (see THE CURTAIN above).
    property int curtainHoldMs: 400
    property int curtainRevealMs: 800
    property int curtainFastMs: 120
    // the longest a frame may advance the reveal, the longest a hold waits for the shell to go quiet, and how long past its quiet for a card still landing
    property int curtainMaxStepMs: 50
    property int curtainHoldCapMs: 6000
    property int curtainMotionCapMs: 900
    property int curtainCaptureTimeoutMs: 2500
    property int curtainSwitchTimeoutMs: 4000
    property int curtainCommitTimeoutMs: 1500
    // THE REPAINT (below, "THE HIDDEN WINDOWS"): the tool, how long after the apps were signalled it starts, how long past its planned
    // length it may take (the tool says the plan first: `REPAINT plan ... ms=`), and how long after it the facts it moved stay held
    // (its last events are still in the pipe).
    property string repaintTool: RepoRoot.dir + "/tools/theme/hidden_repaint.py"
    property int curtainRepaintDelayMs: 120
    property int curtainRepaintTimeoutMs: 4000
    property int curtainRepaintGraceMs: 150
    // The Hyprland events that end the illusion (event names, before the ">>").
    readonly property var curtainTriggers: ["workspace", "workspacev2", "focusedmon", "focusedmonv2", "activespecial", "activespecialv2", "openwindow",
        "closewindow", "movewindow", "movewindowv2", "fullscreen", "changefloatingmode", "monitoradded", "monitorremoved", "monitoraddedv2", "monitorremovedv2"]

    // ---- what it says -------------------------------------------------------------------------------------------
    // "shell" | "themectl": shell.jsonc's theme.apply; anything else is "shell" and `problem` says so.
    readonly property string applyMode: root._apply.mode
    readonly property string problem: root._apply.problem !== "" ? root._apply.problem : (root.config && root.config.curtainProblem ? root.config.curtainProblem : "")
    property int toggled: 0
    property int picks: 0
    property string _lastPick: ""
    // Children started / finished / finished with a failure, and the running ones; the last run's stdout lines.
    property int runs: 0
    property int fails: 0
    property int active: 0
    property var lastLines: []

    readonly property var _apply: {
        const cfg = root.config;
        const raw = cfg ? cfg.raw : null;
        const t = raw && typeof raw === "object" ? raw.theme : undefined;
        if (t === undefined || t === null)
            return { mode: "shell", problem: "" };
        if (typeof t !== "object" || Array.isArray(t))
            return { mode: "shell", problem: "shell.jsonc: theme must be an object" };
        if (t.apply === undefined || t.apply === "shell")
            return { mode: "shell", problem: "" };
        if (t.apply === "themectl")
            return { mode: "themectl", problem: "" };
        return { mode: "shell", problem: "shell.jsonc: theme.apply must be \"shell\" or \"themectl\", not " + JSON.stringify(t.apply) };
    }

    function click(): void {
        root.toggled++;
        root._switch(() => {
            if (root.applyMode === "themectl")
                root._run(["toggle"]);
            else
                Theme.toggleMode();
        });
    }

    // The next pair of the list (the theme button's click when shell.jsonc's "clicks" says "next").
    function next(): void {
        root.picks++;
        root._switch(() => {
            if (root.applyMode === "themectl") {
                root._run(["next"]);
                return;
            }
            const all = Theme.pairs || [];
            const order = root.config && root.config.checked ? root.config.checked.theme.pairs.filter(n => all.indexOf(n) >= 0) : [];
            const names = order.length > 0 ? order : all;
            if (names.length > 1)
                Theme.setPair(names[(names.indexOf(Theme.themeName) + 1) % names.length], Theme.mode);
        });
    }

    // A card of the theme popup: that pair in that mode, as one switch. Asking for what the shell already is (or is about to be) does nothing.
    function pick(name: string, mode: string): void {
        const key = name + ":" + mode;
        if (name === Theme.announcedName && mode === Theme.announcedMode)
            return;
        // the second click of a double click: the switch has not reached Theme yet, and a queued one would end the curtain it is waiting for
        if ((root._cs !== "idle" || root.active > 0) && root._lastPick === key)
            return;
        root._lastPick = key;
        root.picks++;
        root._switch(() => {
            if (root.applyMode === "themectl")
                root._run(["set", name, mode]);
            else
                Theme.setPair(name, mode);
        });
    }

    // The pairs: one per shell, here because the screens' popups share it. Reads nothing until a popup is built.
    readonly property alias pairs: pairsData
    ThemePairs {
        id: pairsData
        order: root.config && root.config.checked ? root.config.checked.theme.pairs : []
    }

    function _log(s: string): void {
        console.log("[themectl] " + s);
    }

    function _run(args: var): void {
        const argv = [root.themectl].concat(args);
        root.runs++;
        if (!root.live) {
            if (root.commands)
                root.commands.run(argv);
            return;
        }
        root._awaitProc = true;
        root._log("run: " + argv.join(" "));
        const proc = runComp.createObject(root, { "command": ["setpriv", "--pdeathsig", "TERM", "--", "setsid", "-w"].concat(argv) });
        proc.exited.connect((code, status) => root._finish(proc, code, status));
        root.active++;
        proc.running = true;
    }

    // "/home/user/..." -> "~/..." in a line the user will read.
    function _short(line: string): string {
        const home = Quickshell.env("HOME") || "";
        return home.length > 1 ? line.split(home).join("~") : line;
    }

    function _finish(proc: var, code: int, status: int): void {
        root.active--;
        root._procExited();
        if (root._debugPending && root.active === 0)
            debugDelay.restart();
        const lines = proc.lines;
        root.lastLines = lines;
        const fails = lines.filter(l => /^FAIL\b/.test(l));
        // setpriv could not exec it: 127 not found, 126 not executable (a signal's status is 1, with the signal as the code)
        const missing = Number(status) === 0 && (code === 126 || code === 127);
        const failed = proc.timedOut || missing || fails.length > 0 || code !== 0;
        if (!failed) {
            root._log("ok (" + lines.length + " lines)");
            proc.destroy();
            return;
        }
        root.fails++;
        let title = "";
        let body = "";
        if (proc.timedOut) {
            title = "Theme switch took longer than " + Math.round(root.timeoutMs / 1000) + " s";
            body = lines.length > 0 ? root._short(lines[lines.length - 1]) : "no answer; it was stopped";
        } else if (missing) {
            title = "Theme switch failed";
            body = "themectl is not installed (" + root._short(root.themectl) + " cannot be run)";
        } else if (fails.length > 0) {
            title = "Theme switch: " + (fails.length === 1 ? "1 target failed" : fails.length + " targets failed");
            body = fails.slice(0, 6).map(l => root._short(l)).join("\n") + (fails.length > 6 ? "\n… and " + (fails.length - 6) + " more" : "");
        } else {
            title = "Theme switch failed (exit " + code + ")";
            body = lines.length > 0 ? root._short(lines[lines.length - 1]) : (proc.errTail !== "" ? proc.errTail : "no output");
        }
        root._log("FAILED: " + title);
        notifier.notify("themectl", { title: title, body: body, urgency: "normal", timeoutMs: 10000 });
        proc.destroy();
    }

    // ==========================================================================================================
    // THE CURTAIN
    // ==========================================================================================================
    // "idle" | "arming" | "capturing" | "switching" | "holding" | "committing" (a live curtain only) | "revealing"
    readonly property string curtainPhase: root._cs
    // The switch the config asks for AND this machine can do (a compositor to capture from, a screen).
    readonly property bool curtainWanted: !!root.config && root.config.curtain === true && (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "") !== ""
    // THE LIVE CURTAIN: the switch, and the shell windows that have one. A ShellScreen registers itself; `wipeCan` is its own word (on view, not locked).
    readonly property bool curtainLive: !!root.config && root.config.curtainLive === true
    property var _wipeScreens: []
    function registerWipeScreen(s: var): void {
        if (root._wipeScreens.indexOf(s) < 0)
            root._wipeScreens = root._wipeScreens.concat([s]);
    }
    function unregisterWipeScreen(s: var): void {
        root._wipeScreens = root._wipeScreens.filter(x => x !== s);
        root._claims = root._claims.filter(x => x !== s.outputName);
        root.curtainsChanged();
    }
    // The outputs of the run in hand whose curtain is in the shell's window.
    property var _claims: []
    function wipeClaimed(name: string): bool {
        return root._armed && root._claims.indexOf(name) >= 0;
    }
    function overlayOn(name: string): bool {
        return root._claims.indexOf(name) < 0;
    }
    // A run with at least one wipe in it; the upper halves are up; the shell's old picture exists (false: the switch changed nothing).
    readonly property bool wipeRun: root._claims.length > 0
    readonly property bool wipeEngaged: root._wipeUp
    readonly property bool wipeHasPicture: root._wipeShell
    property bool _wipeUp: false
    property bool _wipeShell: false
    // runs started / runs that dropped the curtain before the switch / fast-forwards (a probe reads them)
    property int curtainRuns: 0
    property int curtainDrops: 0
    property int curtainFastForwards: 0
    // the style of the run in hand, the progress of its reveal, the ms from the run's start to its end
    property string curtainStyleNow: ""
    readonly property real curtainProgress: root._progress
    property real curtainLastMs: 0

    // THE HIDDEN WINDOWS. A window on a hidden workspace, or a hidden tab of a group, is `suspended` and draws nothing (kitty, Qt):
    // it would come back in the old colours for a frame or two. While the curtain holds -- the apps have been signalled, the picture
    // covers the screen -- tools/theme/hidden_repaint.py shows each hidden workspace and tab for a few frames and puts the session
    // back (the tool's header has the how). How many frames is the WINDOW's: its class's in shell.jsonc `curtainRepaintClassFrames`,
    // else `curtainRepaintFrames` (on the user's 120 Hz panel kitty needs 2, VS Code about 16, zen about 24). The run is as long as
    // its steps: the watchdog is armed from the length the tool plans. The run is INSIDE the hold: the reveal waits for it, a
    // fast-forward waits for it too (a reveal over workspaces still changing would show them), and its own workspace events are
    // not triggers. While it runs,
    // and `curtainRepaintGraceMs` after, `repaintHeld` is true: what the bar shows of the focus (the workspace ball, the window
    // title) holds still, since with a live curtain the bar is on show. The tool says `stopped` when the user changed a workspace
    // under it; the run then fast-forwards as it always did.
    readonly property bool repaintWanted: !!root.config && root.config.curtainRepaint === true
        && (root.live || Quickshell.env("SHELL_REPAINT") === "live")
    readonly property bool repaintHeld: (root._repaintBusy && !root._debugRun) || repaintGrace.running
    // THE DEBUG RUN (shell.jsonc "curtainRepaintDebug": true): the switch runs with NO curtain, then the same repaint slowed to
    // `curtainRepaintDebugMs` a step, each named in a Hyprland notice; the bar is not held (it shows where the run is).
    readonly property bool repaintDebug: root.repaintWanted && root.config.curtainRepaintDebug === true
    property bool _debugRun: false
    property bool _debugPending: false
    function _repaintArgv(debug: bool): var {
        const c = root.config;
        const argv = ["setpriv", "--pdeathsig", "TERM", "--", "python3", root.repaintTool, "run", "--frames", String(c.curtainRepaintFrames)];
        const cf = c.curtainRepaintClassFrames || {};
        for (const k of Object.keys(cf))
            argv.push("--class", k + "=" + cf[k]);
        if (debug)
            argv.push("--debug-ms", String(c.curtainRepaintDebugMs));
        return argv;
    }
    function _debugSwitch(doIt: var): void {
        root._clog("debug run: the switch without the curtain, then the repaint slowed");
        root._debugPending = true;
        const before = root.active;
        doIt();
        // a themectl child ends in _finish(); a shell switch is done already
        if (root.active === before)
            debugDelay.restart();
    }
    Timer {
        id: debugDelay
        interval: root.curtainRepaintDelayMs
        onTriggered: {
            root._debugPending = false;
            if (root._repaintBusy)
                return;
            root.repaintRuns++;
            root.repaintLast = "";
            root._debugRun = true;
            root._repaintBusy = true;
            repaintProc.command = root._repaintArgv(true);
            repaintWatch.interval = root.curtainRepaintTimeoutMs;
            repaintWatch.restart();
            repaintProc.running = true;
        }
    }
    // runs started, the last one's line, the mode in force (a probe reads them)
    readonly property string modeNow: Theme.mode
    property int repaintRuns: 0
    property string repaintLast: ""
    property bool _repaintBusy: false

    property string _cs: "idle"
    property bool _armed: false
    property real _progress: 0
    // what ThemeCurtains reads
    readonly property bool curtainArmed: root._armed
    readonly property var curtainCursor: root._cursor
    readonly property real curtainSeed: root._seed
    property bool _ff: false
    property var _doIt: null
    property var _queued: null
    property real _t0: 0
    property var _cursor: null
    property int _cycle: 0
    property int _seedSerial: 0
    property real _seed: 0
    property int _savedFade: -1
    property string _modeBefore: ""
    property string _nameBefore: ""
    // the apply child: a themectl run is waited for; a shell switch is synchronous
    property bool _awaitProc: false
    property real _doneAt: 0
    readonly property var _styles: ["radial", "peel", "louvres"]

    function _clog(msg: string): void {
        console.log("LARESCURTAIN ctl " + Date.now() + " " + msg);
    }

    function _curtainUsable(): bool {
        return root.curtainWanted && !root.locked && root._curtainList().length > 0;
    }

    // Run the switch `doIt`, behind the curtain when there is one.
    function _switch(doIt: var): void {
        if (root.repaintDebug && root._curtainUsable() && root._cs === "idle" && !root._repaintBusy && !root._debugPending) {
            root._debugSwitch(doIt);
            return;
        }
        if (!root._curtainUsable()) {
            doIt();
            return;
        }
        if (root._cs !== "idle") {
            // a second click while a curtain is up: it runs as the next one (two clicks are two switches), and the first finishes now
            root._queued = doIt;
            root._fastForward("another click");
            return;
        }
        root._begin(doIt);
    }

    function _chooseStyle(): string {
        const want = root.config && root.config.curtainStyle ? root.config.curtainStyle : "radial";
        if (want === "cycle")
            return root._styles[(root._cycle++) % root._styles.length];
        return root._styles.indexOf(want) >= 0 ? want : "radial";
    }

    function _begin(doIt: var): void {
        root.curtainRuns++;
        root._doIt = doIt;
        root._ff = false;
        root._t0 = Date.now();
        root._cursor = null;
        root._cs = "arming";
        root.curtainStyleNow = root._chooseStyle();
        root._seed = (++root._seedSerial * 0.6180339887) % 1.0;
        root._clog("begin style=" + root.curtainStyleNow);
        const lua = 'hl.layer_rule({ name = "lares_curtain_noanim", match = { namespace = "^lares-curtain$" }, no_anim = true })';
        prep.command = ["setpriv", "--pdeathsig", "TERM", "--", "sh", "-c", 'hyprctl eval "$1" > /dev/null 2>&1; hyprctl -j cursorpos 2> /dev/null', "sh", lua];
        prep.out = "";
        prepWatch.restart();
        prep.running = true;
    }

    Process {
        id: prep
        property string out: ""
        stdout: SplitParser {
            onRead: data => prep.out += String(data)
        }
        onExited: {
            prepWatch.stop();
            root._prepared();
        }
    }
    // hyprctl that does not answer must not hold a switch: go without the cursor
    StallTimer {
        id: prepWatch
        interval: 1500
        onTriggered: {
            root._clog("WARN the prepare step did not answer");
            if (prep.running)
                prep.signal(15);
        }
    }

    function _prepared(): void {
        if (root._cs !== "arming")
            return;
        try {
            const j = JSON.parse(prep.out);
            if (typeof j.x === "number" && typeof j.y === "number")
                root._cursor = { x: j.x, y: j.y };
        } catch (e) {
            root._cursor = null;
        }
        if (root._ff) {
            root._abort("an interaction while arming");
            return;
        }
        root._cs = "capturing";
        root._claims = root.curtainLive ? root._wipeScreens.filter(s => s.wipeCan).map(s => s.outputName) : [];
        root._armed = true;
        captureWatch.restart();
        root._clog("capturing; cursor=" + (root._cursor ? root._cursor.x + "," + root._cursor.y : "none"));
    }
    StallTimer {
        id: captureWatch
        interval: root.curtainCaptureTimeoutMs
        onTriggered: root._abort("the capture did not finish in " + root.curtainCaptureTimeoutMs + " ms")
    }

    // a curtain said ready / failed
    function curtainsChanged(): void {
        if (root._cs !== "capturing")
            return;
        const list = root._activeList();
        for (let i = 0; i < list.length; i++) {
            if (list[i].failed !== "") {
                root._abort("a capture failed: " + list[i].failed);
                return;
            }
        }
        for (let i = 0; i < list.length; i++)
            if (!list[i].ready)
                return;
        captureWatch.stop();
        if (root._ff) {
            root._abort("an interaction while capturing");
            return;
        }
        root._applyTheme();
    }

    function _applyTheme(): void {
        root._cs = "switching";
        root._modeBefore = Theme.mode;
        root._nameBefore = Theme.themeName;
        if (root.wipeRun) {
            // the shell stays as it is while the apps repaint: the switch is kept for the moment the line starts, and the line is the fade's clock
            Theme.deferSwitches = true;
            Theme.fadeExternal = true;
        } else {
            root._savedFade = Theme.fadeMs;
            Theme.fadeMs = 0;   // the curtain IS the transition: no second one behind it
        }
        root._awaitProc = false;
        root._doneAt = 0;
        const d = root._doIt;
        root._doIt = null;
        root._clog("switching (" + root._modeBefore + "/" + root._nameBefore + ")");
        if (d)
            d();
        if (!root._awaitProc)
            root._doneAt = Date.now();
        switchWatch.restart();
        switchPoll.restart();
    }
    function _procExited(): void {
        if (root._cs === "switching") {
            root._awaitProc = false;
            root._doneAt = Date.now();
        }
    }
    function _switched(): bool {
        return Theme.switchDeferred || Theme.mode !== root._modeBefore || Theme.themeName !== root._nameBefore;
    }
    Timer {
        id: switchPoll
        interval: 30
        repeat: true
        onTriggered: {
            if (root._cs !== "switching") {
                stop();
                return;
            }
            // done = the apply child gone AND the shell's tokens moved (or, for a switch that changes nothing -- one pair, a
            // failed themectl -- a moment after the child ended)
            if (!root._awaitProc && root._doneAt > 0 && (root._switched() || Date.now() - root._doneAt > 600)) {
                stop();
                switchWatch.stop();
                root._startHold();
            }
        }
    }
    StallTimer {
        id: switchWatch
        interval: root.curtainSwitchTimeoutMs
        onTriggered: {
            root._clog("WARN the switch did not finish in " + root.curtainSwitchTimeoutMs + " ms; revealing anyway");
            switchPoll.stop();
            root._startHold();
        }
    }

    // THE HOLD WAITS FOR QUIET. The shell's own windows draw their new-theme frames behind the picture, and a COLD frame (a driver
    // compiling a shader variant for the first time, 1-13 s in the nested test environment, whose Mesa cache is empty at every
    // start) blocks the GUI thread. A heartbeat measures that: a beat that comes 120 ms late is a stall, and the hold counts its
    // `curtainHoldMs` from the LAST one, so the reveal never starts into a frame that is about to freeze. Capped by `curtainHoldCapMs`.
    property real _holdFrom: 0
    property real _lastBeat: 0
    property real _lastStall: 0
    function _startHold(): void {
        if (root._cs !== "switching")
            return;
        root._cs = "holding";
        root._holdFrom = Date.now();
        root._lastBeat = root._holdFrom;
        root._lastStall = 0;
        root._clog("holding (tokens " + (root._switched() ? "moved" : "unchanged") + ")" + (root._ff ? " ff" : ""));
        beat.restart();
        if (root.repaintWanted && !root._ff)
            repaintDelay.restart();
    }
    Timer {
        id: repaintDelay
        interval: root.curtainRepaintDelayMs
        onTriggered: {
            if (root._cs !== "holding" || root._ff)
                return;
            root.repaintRuns++;
            root.repaintLast = "";
            root._repaintBusy = true;
            repaintProc.command = root._repaintArgv(false);
            repaintWatch.interval = root.curtainRepaintTimeoutMs;
            repaintWatch.restart();
            repaintProc.running = true;
        }
    }
    Process {
        id: repaintProc
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++) {
                    const plan = /^REPAINT plan .*\bms=(\d+)/.exec(parts[i]);
                    if (plan) {
                        // the run is as long as its windows need: the watchdog follows the plan (a fixed 4 s cut 60-frame runs)
                        repaintWatch.interval = Number(plan[1]) + root.curtainRepaintTimeoutMs;
                        repaintWatch.restart();
                    } else if (parts[i].indexOf("REPAINT ") === 0) {
                        root.repaintLast = parts[i];
                    }
                }
            }
        }
        onExited: root._repaintEnded("")
    }
    // a tool that hangs must not hold the reveal: the compositor's own chunk finishes and restores without it
    StallTimer {
        id: repaintWatch
        onTriggered: {
            if (repaintProc.running)
                repaintProc.signal(15);
            root._repaintEnded("WARN the repaint did not end in " + repaintWatch.interval + " ms");
        }
    }
    Timer {
        id: repaintGrace
        interval: root.curtainRepaintGraceMs
    }
    function _repaintEnded(warn: string): void {
        if (!root._repaintBusy)
            return;
        repaintWatch.stop();
        root._repaintBusy = false;
        if (root._debugRun) {
            root._debugRun = false;
            root._clog(warn !== "" ? warn : ("debug repaint: " + (root.repaintLast !== "" ? root.repaintLast : "no word from the tool")));
            return;
        }
        repaintGrace.restart();
        root._clog(warn !== "" ? warn : ("repaint: " + (root.repaintLast !== "" ? root.repaintLast : "no word from the tool")));
        if (root.repaintLast.indexOf("REPAINT stopped") === 0)
            root._fastForward("the session changed under the repaint");
    }
    Timer {
        id: beat
        interval: 20
        repeat: true
        onTriggered: {
            const now = Date.now();
            if (now - root._lastBeat > 120) {
                root._lastStall = now;
                root._clog("stall " + (now - root._lastBeat) + " ms while holding");
            }
            root._lastBeat = now;
            if (root._cs !== "holding") {
                stop();
                return;
            }
            // the hidden windows are being shown by turns under the picture: nothing is revealed before the session is back
            if (root._repaintBusy || repaintDelay.running)
                return;
            const quietFor = now - Math.max(root._holdFrom, root._lastStall);
            // the commit's picture is the old shell the line cuts: the theme OSD, opening since the switch arrived, is in it whole
            const landing = quietFor < root.curtainHoldMs + root.curtainMotionCapMs && root._activeList().some(w => w.shellMoving === true);
            if (root._ff)
                root._reveal(root.curtainFastMs);
            else if ((quietFor >= root.curtainHoldMs && !landing) || (now - root._holdFrom >= root.curtainHoldCapMs && quietFor >= 150))
                root._reveal(root.curtainRevealMs);
        }
    }

    // THE REVEAL IS DRIVEN BY FRAMES, NOT BY THE WALL CLOCK: each frame advances the reveal by at most `curtainMaxStepMs`, so a frame
    // that stalls (a cold shader compile in a window below) pauses the reveal instead of cutting it. `_t` is linear, `_progress` is
    // the eased picture the shaders get.
    property real _t: 0
    property real _rate: 1.25      // reveal fractions per second
    function _ease(t: real): real {
        return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
    }
    function _reveal(ms: int): void {
        if (root._cs !== "holding")
            return;
        beat.stop();
        root._revealMs = ms;
        if (root.wipeRun) {
            // THE COMMIT. The upper halves go up (their first frame takes the shell's old picture: they are the consumer ThemeCrossfade's grab lands
            // through), Theme asks its hosts as ever, and the clock starts when the tokens are written. No switch to apply (one pair, a themectl
            // that failed): only the lower half has something to do.
            root._cs = "committing";
            root._wipeShell = Theme.switchDeferred;
            root._wipeUp = true;
            root._clog("committing (the shell's palette changes now)");
            if (root._wipeShell) {
                commitWatch.restart();
                Theme.applyDeferred();
                return;
            }
        }
        root._startClock();
    }
    property int _revealMs: 800
    StallTimer {
        id: commitWatch
        interval: root.curtainCommitTimeoutMs
        onTriggered: {
            root._clog("WARN the commit did not come in " + root.curtainCommitTimeoutMs + " ms; revealing anyway");
            root._startClock();
        }
    }
    Connections {
        target: Theme
        enabled: root._cs === "committing"
        function onSettled() {
            commitWatch.stop();
            root._startClock();
        }
    }
    function _startClock(): void {
        const ms = root._ff ? Math.min(root._revealMs, root.curtainFastMs) : root._revealMs;
        root._cs = "revealing";
        root._t = 0;
        root._progress = 0;
        root._rate = 1000 / Math.max(1, ms);
        revealFrames.start();
        root._clog("revealing over " + ms + " ms");
    }
    FrameAnimation {
        id: revealFrames
        onTriggered: {
            root._t = Math.min(1, root._t + Math.min(revealFrames.frameTime, (root._ff ? root.curtainFastMs : root.curtainMaxStepMs) / 1000) * root._rate);
            root._progress = root._ease(root._t);
            Theme.driveFade(root._progress);
            if (root._t >= 1) {
                revealFrames.stop();
                root._end();
            }
        }
    }

    function _end(): void {
        root.curtainLastMs = Date.now() - root._t0;
        let pace = "";
        const list = root._activeList();
        for (let i = 0; i < list.length; i++)
            pace += " " + list[i].outputName + ":" + list[i].revealFrames + "f/" + Math.round(list[i].revealMaxGap) + "ms";
        root._clog("done after " + root.curtainLastMs + " ms; reveal frames/longest gap" + pace);
        root._armed = false;
        root._claims = [];
        root._wipeUp = false;
        root._wipeShell = false;
        root._progress = 0;
        if (root._savedFade >= 0)
            Theme.fadeMs = root._savedFade;
        root._savedFade = -1;
        root._cs = "idle";
        if (Theme.fadeExternal)
            Theme.endExternalFade();
        // a switch from somewhere else that arrived behind the line goes the plain way, now
        Theme.deferSwitches = false;
        Theme.applyDeferred();
        root._next();
    }

    function _next(): void {
        const q = root._queued;
        root._queued = null;
        if (q)
            Qt.callLater(() => root._switch(q));
    }

    // The curtain is dropped BEFORE the switch has run: the switch runs plain, as it does with the curtain off.
    function _abort(why: string): void {
        root.curtainDrops++;
        root._clog("DROPPED: " + why);
        captureWatch.stop();
        prepWatch.stop();
        beat.stop();
        revealFrames.stop();
        root._armed = false;
        root._claims = [];
        root._cs = "idle";
        const d = root._doIt;
        root._doIt = null;
        if (d)
            d();
        root._next();
    }

    // Something is about to make the picture under the curtain a lie: finish the run now. Public, so a source of input can say so.
    function interacted(reason: string): void {
        root._fastForward(reason);
    }
    function _fastForward(reason: string): void {
        if (root._cs === "idle")
            return;
        root.curtainFastForwards++;
        root._ff = true;
        root._clog("FAST-FORWARD (" + reason + ") in " + root._cs);
        switch (root._cs) {
        case "capturing":
            root._abort("an interaction: " + reason);
            break;
        case "holding":
            // a repaint about to start does not start; one that runs is waited for (the beat reveals, fast, when it has ended)
            repaintDelay.stop();
            if (!root._repaintBusy)
                root._reveal(root.curtainFastMs);
            break;
        case "revealing": {
            // the rest of the reveal in curtainFastMs, if that is faster than it was going
            root._rate = Math.max(root._rate, (1 - root._t) / (root.curtainFastMs / 1000));
            break;
        }
        default:    // arming: _prepared() drops the run; switching: _startHold() skips the hold; committing: _startClock() reads _ff
            break;
        }
    }
    onLockedChanged: if (root.locked) root._fastForward("the session locked")

    Connections {
        target: root._cs !== "idle" ? Hyprland : null
        function onRawEvent(event: var): void {
            // the repaint's own workspace changes are not the user's
            if (root.repaintHeld)
                return;
            if (root.curtainTriggers.indexOf(event.name) >= 0)
                root._fastForward("hyprland " + event.name);
        }
    }

    // one curtain per screen, in a file of its own that is loaded only when the curtain is on (ThemeCurtains.qml says why)
    // The source is set by hand, once, and THEN the loader is made active: a LazyLoader whose `active` and `source` both follow a binding
    // is turned on with the old (empty) source when the config goes off and on again in a running shell, and never loads -- the switch
    // then runs plain for good. The path stays set while off; only `active` follows.
    // (A LazyLoader compiles its source as soon as it is set, so it is not set until the curtain is wanted: offscreen, where a PanelWindow
    // is "unavailable", the log would warn on every run with the curtain off.)
    LazyLoader {
        id: curtainLoader
        active: false
    }
    function _curtainLoad(): void {
        if (root.curtainWanted) {
            if (curtainLoader.source.toString() === "")
                curtainLoader.source = Qt.resolvedUrl("ThemeCurtains.qml");
            curtainLoader.active = true;
        } else {
            curtainLoader.active = false;
        }
    }
    onCurtainWantedChanged: root._curtainLoad()
    Component.onCompleted: root._curtainLoad()
    Binding {
        target: curtainLoader.item
        property: "controller"
        value: root
        when: curtainLoader.item !== null
    }
    function _curtainList(): var {
        return curtainLoader.item ? curtainLoader.item.instances : [];
    }
    // What this run waits for: the stand-alone curtains it armed and the shell windows' wipes.
    function _activeList(): var {
        const out = root._curtainList().filter(c => c.armed);
        for (let i = 0; i < root._wipeScreens.length; i++) {
            const w = root._wipeScreens[i].wipeItem;
            if (w)
                out.push(w);
        }
        return out;
    }

    // A setting of the theme block that was refused is SAID (a value out of range was silently replaced by its default: the user
    // raised curtainRepaintFrames to 20, past the old limit of 12, and tested 3 without knowing).
    onProblemChanged: problemTell.restart()
    Timer {
        id: problemTell
        interval: 0
        onTriggered: {
            if (root.problem !== "")
                notifier.notify("themectl", { title: "Theme: a setting was not accepted", body: root.problem, urgency: "normal", timeoutMs: 12000 });
        }
    }
    DesktopNotifier {
        id: notifier
        appName: "Theme"
        notifySend: root.notifySend
        keys: ["themectl"]
    }

    Component {
        id: runComp
        Process {
            id: run
            property var lines: []
            property string errTail: ""
            property bool timedOut: false
            stdout: SplitParser {
                onRead: data => {
                    // SplitParser's slices are not always lines (an empty line that follows another in the same read is folded
                    // into the next slice): split again.
                    const parts = String(data).split("\n");
                    for (let i = 0; i < parts.length; i++) {
                        if (parts[i].length === 0)
                            continue;
                        run.lines = run.lines.concat([parts[i]]);
                        root._log(parts[i]);
                    }
                }
            }
            stderr: SplitParser {
                onRead: data => {
                    const parts = String(data).split("\n");
                    for (let i = 0; i < parts.length; i++)
                        if (parts[i].length > 0) {
                            run.errTail = parts[i];
                            console.warn("[themectl] " + parts[i]);
                        }
                }
            }
            property Timer watchdog: Timer {
                interval: root.timeoutMs
                running: true
                repeat: false
                onTriggered: {
                    run.timedOut = true;
                    if (Number(run.processId) > 0)
                        run.signal(15);
                    else
                        run.running = false;
                }
            }
        }
    }
}
