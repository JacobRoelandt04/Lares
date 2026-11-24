pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ActiveWindowMock.qml -- ActiveWindowService's API over scripted windows, for
// the mockup and the probes. Never touches Hyprland.
//
//   setWindow({cls, title, initialTitle, empty, focused, urgent, address})
//                       one window, now (omitted fields keep their value; a
//                       new `cls` without an address gets its own)
//   play(name) / stop() the scripts below, one step after another on a Timer;
//                       `playing`, `script`; `loops` repeats a script (default 1)
//   scripts             the names
//   timeScale           1 = the times as written; a probe plays at 0.05
//
// Scripts (titles are the real ones where there are real ones):
//   kittyCwd       one kitty, its title following `cd`
//   kittyCommands  one kitty running commands: the shell sets the title to the command and back to the directory when it
//                  ends. `ls` and `git status` are over in 40 and 70 ms (a terminal's title waits: they never show),
//                  `cargo build` runs on (named once the wait is over, and the directory back at the end)
//   tabSwitch      Zen Browser, tab after tab (the " -- Zen Browser" suffix stripped)
//   appSwitch      kitty -> Zen -> VS Code -> kitty (the icon changes too)
//   spinner        Claude Code's kitty title: "◐ x" / "◑ x" at ~1.2 Hz
//   emptyWorkspace a window, then a workspace with none ("Desktop"), then back
//   longTitle      a title that cannot fit
//   emoji          graphemes: a flag, a ZWJ family, a skin tone
// =============================================================================
ActiveWindowState {
    id: root

    readonly property var scripts: ["kittyCwd", "kittyCommands", "tabSwitch", "appSwitch", "spinner", "emptyWorkspace", "longTitle", "emoji"]
    readonly property bool playing: root._playing
    readonly property string script: root._script
    property real timeScale: 1
    property int loops: 1

    function setWindow(o: var): void {
        if (o.empty === true) {
            root._applyEmpty(o.focused !== false);
            return;
        }
        const p = { empty: false };
        if (o.cls !== undefined) {
            p.cls = String(o.cls);
            if (o.address === undefined && p.cls !== root.cls)
                p.address = "0xmock" + p.cls;
        }
        if (o.address !== undefined)
            p.address = String(o.address);
        if (o.title !== undefined)
            p.title = String(o.title);
        if (o.initialTitle !== undefined)
            p.initialTitle = String(o.initialTitle);
        if (o.focused !== undefined)
            p.focused = !!o.focused;
        if (o.urgent !== undefined)
            p.urgent = !!o.urgent;
        if (root.empty && p.cls === undefined) {
            p.cls = "kitty";
            p.address = "0xmockkitty";
        }
        root._apply(p);
    }

    function play(name: string): bool {
        const steps = root._steps(name);
        if (steps === null)
            return false;
        root.stop();
        root._script = name;
        root._queue = steps;
        root._at = 0;
        root._round = 0;
        root._playing = true;
        root._next();
        return true;
    }

    function stop(): void {
        tick.stop();
        root._playing = false;
        root._script = "";
        root._queue = [];
    }

    // ---- Private ---------------------------------------------------------------
    property bool _playing: false
    property string _script: ""
    property var _queue: []
    property int _at: 0
    property int _round: 0

    readonly property var _kitty: ({ cls: "kitty", initialTitle: "kitty" })
    readonly property var _zen: ({ cls: "zen", initialTitle: "Zen Browser" })
    readonly property var _code: ({ cls: "com.microsoft.VSCode", initialTitle: "Visual Studio Code" })

    function _w(base: var, title: string, ms: int): var {
        return { ms: ms, w: { cls: base.cls, initialTitle: base.initialTitle, title: title, empty: false } };
    }

    function _steps(name: string): var {
        const K = root._kitty, Z = root._zen, C = root._code;
        switch (name) {
        case "kittyCwd":
            return [root._w(K, "~/Documents/suspend-lab", 0), root._w(K, "~/Documents/suspend-lab/src", 900),
                    root._w(K, "~/Documents/suspend-lab/src/lib", 900), root._w(K, "~/Documents/suspend-lab/src", 900),
                    root._w(K, "~/Documents", 900), root._w(K, "~", 900)];
        case "kittyCommands":
            return [root._w(K, "~/Documents/suspend-lab", 0), root._w(K, "ls", 1500), root._w(K, "~/Documents/suspend-lab", 40),
                    root._w(K, "git status", 1500), root._w(K, "~/Documents/suspend-lab", 70),
                    root._w(K, "cargo build --release", 1500), root._w(K, "~/Documents/suspend-lab", 2600)];
        case "tabSwitch":
            return [root._w(Z, "New session - Claude — Zen Browser", 0), root._w(Z, "Inbox (3) - Gmail — Zen Browser", 1200),
                    root._w(Z, "GitHub - JacobRoelandt04/Lares — Zen Browser", 1200), root._w(Z, "Zen Browser", 1200),
                    root._w(Z, "Arch Linux - Wikipedia — Zen Browser", 1200)];
        case "appSwitch":
            return [root._w(K, "~/Documents/suspend-lab", 0), root._w(Z, "New session - Claude — Zen Browser", 1200),
                    root._w(C, "prompt.md - quickshell - Visual Studio Code", 1200), root._w(K, "~/Documents/suspend-lab", 1200)];
        case "spinner": {
            const out = [];
            for (let i = 0; i < 12; i++)
                out.push(root._w(K, (i % 2 === 0 ? "◐" : "◑") + " screentime", i === 0 ? 0 : 830));
            return out;
        }
        case "emptyWorkspace":
            return [root._w(K, "btop", 0), { ms: 1200, w: { empty: true } }, root._w(K, "btop", 1200)];
        case "longTitle":
            return [root._w(Z, "short — Zen Browser", 0),
                    root._w(Z, "The quick brown fox jumps over the lazy dog while the shell measures how much of a very long window title still fits the bar — Zen Browser", 1200),
                    root._w(Z, "short again — Zen Browser", 1800)];
        case "emoji":
            return [root._w(K, "🇧🇪 Belgium", 0),
                    root._w(K, "👨‍👩‍👧 family", 1200),
                    root._w(K, "👍🏽 thumbs up", 1200), root._w(K, "plain again", 1200)];
        }
        return null;
    }

    function _next(): void {
        if (!root._playing)
            return;
        if (root._at >= root._queue.length) {
            root._round++;
            if (root._round < root.loops) {
                root._at = 0;
            } else {
                root._playing = false;
                root._script = "";
                return;
            }
        }
        const step = root._queue[root._at];
        if (step.ms <= 0) {
            root._at++;
            root.setWindow(step.w);
            Qt.callLater(root._next);
            return;
        }
        tick.interval = Math.max(1, Math.round(step.ms * root.timeScale));
        tick.start();
    }

    Timer {
        id: tick
        onTriggered: {
            const step = root._queue[root._at];
            root._at++;
            root.setWindow(step.w);
            root._next();
        }
    }
}
