pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
// This directory's own types, explicitly and LAST: loaded from `file:`, the implicit directory import loses to `import Quickshell`'s
// uncreatable ShellScreen ("ShellScreen can only be obtained via Quickshell.screens"); on `qs:` the scanner's qmldir made it win.
import "perf"
import "."

// =============================================================================
// ShellMain.qml -- THE SHELL'S BODY. shell.qml is a stub (the ShellRoot Quickshell starts, with the Env pragmas) that creates this
// object once, from a `file:` URL (shell.jsonc `"workarounds": { "fileRoot": true }`, the default) or, with that switch false, from
// the relative path on Quickshell's own `qs:` scheme as the shell always did. Why: Qt's QML disk cache refuses every unit that is not
// a local file, and Quickshell serves every file on `qs:`, so all of the shell was parsed and compiled at every start; loaded from
// `file:`, the tree is cached (docs: shell.qml's header).
//
// One ShellServices (everything there is one of), one ShellScreen per output (the bar window with its frame, the
// OSD's pill), the four shortcuts registered once. The console says
//
//     LARES ready screens=<n>
//
// once, when every screen's window has drawn (the supervisor and the probes wait for it), and `quickshell ipc
// call shell ping` answers "ok" (`bars 1|0|toggle` hides / shows all the bars).
// =============================================================================
Scope {
    id: root

    // THE START'S MARKS (shell.qml hands them over; `LARES start root=<ms> load=<ms> services=<ms>`; load: the stub's first JS to its
    // component of this file loaded -- the units read from the disk cache or compiled, their types resolved): the stub's first JS, the moment it asked
    // for this object, and -- once both are known -- the line. `rootMs`: the stub's first JS to this object created (its files
    // compiled and every object of it built); `servicesMs`: this object asked for to ShellServices `ready`.
    property real startMs: 0
    property real buildMs: 0
    property real rootMs: -1
    property real servicesMs: -1
    property bool _startTold: false
    function tellStart(): void {
        if (root._startTold || root.rootMs < 0 || root.servicesMs < 0)
            return;
        root._startTold = true;
        console.log("LARES start root=" + Math.round(root.rootMs) + " load=" + Math.round(root.buildMs - root.startMs) + " services=" + Math.round(root.servicesMs));
    }

    ShellServices {
        id: shellServices
        onReadyChanged: {
            if (shellServices.ready && root.servicesMs < 0) {
                root.servicesMs = Date.now() - root.buildMs;
                root.tellStart();
            }
        }
    }
    ShortcutRouter {
        id: router
        services: shellServices
        enabled: shellServices.shortcutsEnabled
    }

    // The windows wait for the services: an owner built before them would build its own, the real one.
    Variants {
        // (not the lock's own few-hundred-ms headless output, LARESLOCK-HOP: the keyboard hop after a resume, one-screen machines)
        model: shellServices.ready ? shellServices.barScreens : []

        ShellScreen {
            required property var modelData
            screen: modelData
            services: shellServices
            onDrawn: name => root.screenDrawn(name)
        }
    }

    IpcHandler {
        target: "shell"

        function ping(): string {
            return "ok";
        }
        // A popup's toggle by its owner's key (ShellFrame.owners: clock, weather, player, ...) on the FOCUSED screen, as its bar button
        // would: "open" / "shut" after it, "none" when that screen has no such owner. A user-run tour drives the shell with it.
        function toggle(owner: string): string {
            const o = shellServices.focusedOwner(owner);
            if (!o || !o.toggle)
                return "none";
            o.toggle();
            return o.popupMine === true ? "open" : "shut";
        }
        // The frame journal's counters written now: the tour brackets its span with two, so the span has frame totals.
        function perfSum(): string {
            FrameJournal.summaryNow();
            return FrameJournal.enabled ? "ok" : "off";
        }
        // The theme button's click (light <-> dark, through whatever shell.jsonc theme.apply names): the tour switches it twice.
        function theme(): string {
            shellServices.themeControl.click();
            return "asked";
        }
        // "1" shows the bars, "0" hides them, "toggle" (or anything else) flips them; answers the state.
        function bars(on: string): string {
            if (on === "1")
                shellServices.barsShown = true;
            else if (on === "0")
                shellServices.barsShown = false;
            else
                shellServices.barsShown = !shellServices.barsShown;
            return shellServices.barsShown ? "1" : "0";
        }
        // THE AURA (a prototype, shell.jsonc `shadow.aura` must be true): the shadow's halo lit with hues. palette: accent siri ok warn
        // error cool; group: all | island | side. Answers what plays or why not. `auraStop` lets go.
        function aura(palette: string, group: string): string {
            return shellServices.playAura(palette, group, 0);
        }
        function auraStop(): string {
            shellServices.stopAura();
            return "ok";
        }
        // THE OLED CARE (OledShift; `lares oled shift|status|flourish`): the bars' content steps one device pixel every 240 s. `oledShift` takes
        // the next step now (it waits for an open popup and says so), `oledStatus` is one line of JSON (the care's switch is shell.jsonc's `oled.enabled`).
        function oledShift(): string {
            return shellServices.oled.shift();
        }
        function oledStatus(): string {
            return shellServices.oled.status();
        }
        // SESSION RESTORE (SessionService; `lares session status`): one line of JSON -- on or off, the start's decision, the last restore.
        function sessionStatus(): string {
            return shellServices.session.status();
        }
        // THE RANDOM FLOURISHES (FlourishScheduler; `lares oled flourish`): a turn now on every screen, under the timer's gates.
        function oledFlourish(): string {
            const fr = shellServices.frames;
            return Object.keys(fr).map(n => n + ": " + fr[n].flourishNow()).join("; ");
        }
        // The platform probe's eyes: everything observable about the shell, one line of JSON (ShellServices.probeState).
        function probe(): string {
            return JSON.stringify(shellServices.probeState());
        }
        // The service census: the QML type of every service, and how many of each.
        function census(): string {
            return JSON.stringify(shellServices.census);
        }
        // THE PROBE HOOKS (a MOCK shell only; a live one answers "live" and does nothing): the few things a gate in a nested compositor
        // cannot do by a pointer or a bus -- the mock has no notification server and no way to seal a copy.
        //   notify <text>  a toast on the shell's own notification service
        //   critical <text>  a critical one (sticky; the fullscreen hold lets it through)
        //   eye <1|0>      the workspaces' split closed as if the session were locked (ShellFrame.eyeT)
        //   secret         a sealed copy into the clipboard mock
        //   idle <mode>    the idle reel's mode (off / soft / normal / hard), as its click applies it
        //   themeclick     the theme button's click (a probe under a fullscreen window, where the button cannot be reached)
        function hook(name: string, arg: string): string {
            if (!shellServices.mock)
                return "live";
            switch (name) {
            case "notify":
                return shellServices.notifications ? String(shellServices.notifications.post({ source: "shell-hook", key: arg, appName: "Hook", title: arg, body: "", urgency: "normal", timeoutMs: 20000, sound: "none" })) : "";
            case "critical":
                return shellServices.notifications ? String(shellServices.notifications.post({ source: "shell-hook", key: "crit-" + arg, appName: "Hook", title: arg, body: "", urgency: "critical", timeoutMs: -1, sound: "none" })) : "";
            case "eye":
                shellServices.eyeForce = arg === "1";
                return shellServices.eyeForce ? "1" : "0";
            case "idle":
                return shellServices.idle.setMode(arg) ? "1" : "0";
            case "themeclick":
                shellServices.themeControl.click();
                return String(shellServices.themeControl.curtainPhase);
            case "secret":
                if (shellServices.clipboard)
                    shellServices.clipboard.feed("secret");
                return shellServices.clipboard ? String(shellServices.clipboard.secrets.length) : "";
            }
            return "unknown";
        }
        // One line of JSON: what lares cannot see from outside (the polkit agent's registration, the
        // notification server) and a few facts a probe reads.
        function status(): string {
            return JSON.stringify({
                screens: Quickshell.screens.length,
                mode: shellServices.mode,
                polkit: shellServices.polkit.registered === true,
                notifications: shellServices.notifications ? shellServices.notifications.serverRunning === true : false,
                tray: !!shellServices.tray && shellServices.tray.live === true,
                bars: shellServices.barsShown,
                focused: shellServices.focusedScreen,
                ready: root._told
            });
        }
    }

    // ---- the ready line -----------------------------------------------------------------------------
    // Every screen's window has drawn AND the notification server holds its name (live): `lares start` asserts
    // the name's owner within seconds of this line. A server that has not come up by `readyCapMs` after the
    // screens did is reported anyway -- `status` says `notifications: false` -- rather than never.
    property int readyCapMs: 8000
    property var _drawn: ({})
    property int drawnCount: 0
    property bool _told: false
    function screenDrawn(name: string): void {
        if (root._drawn[name] === true)
            return;
        root._drawn[name] = true;
        root.drawnCount++;
        root._maybeTell(false);
    }
    function _maybeTell(capped: bool): void {
        if (root._told)
            return;
        const want = Quickshell.screens.length;
        if (root.drawnCount < want)
            return;
        if (!capped && !shellServices.notificationsUp)
            return;
        root._told = true;
        console.log("LARES ready screens=" + want);
    }
    Connections {
        target: shellServices
        function onNotificationsUpChanged() {
            root._maybeTell(false);
        }
    }
    Timer {
        id: readyCap
        interval: root.readyCapMs
        running: !root._told && root.drawnCount > 0 && root.drawnCount >= Quickshell.screens.length
        onTriggered: root._maybeTell(true)
    }
    // No screen at all (everything unplugged): the shell is as ready as it will be.
    Timer {
        interval: 1500
        running: Quickshell.screens.length === 0
        onTriggered: root._maybeTell(false)
    }
    // THE COLLECTION AT THE BUILD (CLAUDE.md "A GC CYCLE THAT STARTS INSIDE A COMPONENT'S BUILD LOSES LIVE OBJECTS"): shell.qml makes this
    // object with createObject(parent), which parents it after its completion, so here it is still the top of its own tree and a gc()
    // finishes any cycle that started inside the build. The same switch as the screens' (`"workarounds": { "gcAtScreenBuild": false }`).
    Component.onCompleted: {
        console.log("LARES mode=" + shellServices.mode);
        const collect = shellServices.shellConfig.gcAtScreenBuild();
        if (collect)
            gc();
        console.log("LARES gc at build main: " + (collect ? "on" : "off"));
        if (shellServices.ready && root.servicesMs < 0)
            root.servicesMs = Date.now() - root.buildMs;
    }
}
