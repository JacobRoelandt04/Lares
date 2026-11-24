pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

import "../common/components"
import "ContentRules.js" as Rules

// =============================================================================
// ContentHold.qml -- is something showing on the screen that asked it to stay on? Soft idle's question: it has to hold natively, for any content consumption.
// SoftIdle's IdleMonitors cannot answer it: they ignore inhibitors because the shell holds one itself, in soft, and a monitor
// that obeyed would never fire; and a browser's video does not reach them anyway. There are three places such a request can go, and this reads all three:
//
//   org.freedesktop.ScreenSaver   what Firefox-family browsers and Chromium call first. hypridle owns the name, so the request quiets hypridle and NOTHING else: Hyprland's
//                                 idle notifications never hear of it. dbus-monitor shows the calls (the session bus lets the user monitor it); a holder is counted from its
//                                 Inhibit to its UnInhibit or its end. It runs all the time: a video started before soft was chosen counts too.
//   a Wayland idle inhibitor      mpv, most native players, a window rule (idle_inhibit): `hyprctl -j clients` says `inhibitingIdle` per window
//   logind                        `systemd-inhibit --what=idle`: a blocking idle inhibitor in ListInhibitors, the shell's own (who "lares": hard idle) excepted
//
// THE IGNORE LIST (`ignore`, idle.jsonc `contentIgnore`): a program may ask for the screen for its whole life whatever it shows (every SDL program does: FreeRDP's SDL client, the
// Windows VM's window), so a holder whose name is on the list holds nothing -- by exact name, any case, in all three sources (the D-Bus application name, a window's class,
// logind's `who`) -- and is said once in the log (`LARES idle content ignored: <name>`). Held whole (`_appsAll` ...), sifted by a binding, so a change of the list acts at once.
//
// The last two have no event: `refresh()` asks them, and `fresh` says the answer is recent. SoftIdle asks when input goes idle and every `pollMs` while it stays idle,
// so a soft dim never lands on a video, and one that lands first gives way at the next look. The idle auto layer (IdleAuto: content asks for normal) `watch`es: the
// two are asked every `pollMs` for as long as it does, so a player's own inhibitor is seen within one poll.
//
// NOT LIVE: nothing is started; `simulate(bool)` stands in for all three.
// =============================================================================
Item {
    id: root

    property bool live: false
    // the answers of the two polls are wanted (SoftIdle: soft is applied and input is idle)
    property bool polling: false
    // ... and wanted all the time (the idle auto layer, live)
    property bool watch: false
    property int pollMs: 15000
    property var dbusCommand: ["setpriv", "--pdeathsig", "TERM", "--", "dbus-monitor", "--session",
        "type='method_call',interface='org.freedesktop.ScreenSaver'",
        "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'"]
    property var clientsCommand: ["hyprctl", "-j", "clients"]
    property var logindCommand: ["busctl", "--system", "--json=short", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "ListInhibitors"]

    // idle.jsonc `contentIgnore` (IdleConfig.js): names whose request is not content, matched exactly and in any case against all three
    // sources (ContentRules.ignores). Read hot: a change re-sifts what is held.
    property var ignore: []

    readonly property bool held: root._sim || root._apps.length > 0 || root._windows.length > 0 || root._logind.length > 0
    // The first holder's name, for words ("Firefox is playing video"); "" when it has none (a simulated hold).
    readonly property string firstWho: root._apps.length > 0 ? root._apps[0] : root._windows.length > 0 ? root._windows[0]
        : root._logind.length > 0 ? root._logind[0] : root._simWho
    // the two polls have answered since this cycle of idleness began
    readonly property bool fresh: !root.live || root._fresh
    // who, for the log (a function: `heldChanged`'s handlers run before a binding on the same change has followed it)
    function who(): var {
        return root._apps.concat(root._windows).concat(root._logind);
    }

    signal answered()

    // `who`: a name for the words (a probe's "Firefox").
    function simulate(on: bool, who: var): void {
        root._simWho = on && who ? String(who) : "";
        root._sim = on;
    }
    function refresh(): void {
        if (!root.live) {
            root.answered();
            return;
        }
        if (clients.running || logind.running)
            return;
        root._waiting = 2;
        clients.running = true;
        logind.running = true;
        lateAnswer.restart();
    }

    property bool _sim: false
    property string _simWho: ""
    property var _state: Rules.start()
    // what each source holds, whole; `_apps` / `_windows` / `_logind` are what is left once the ignore list has had its say
    property var _appsAll: []
    property var _windowsAll: []
    property var _logindAll: []
    readonly property var _sifted: ({
        apps: Rules.sift(root.ignore, root._appsAll),
        windows: Rules.sift(root.ignore, root._windowsAll),
        logind: Rules.sift(root.ignore, root._logindAll)
    })
    readonly property var _apps: root._sifted.apps.kept
    readonly property var _windows: root._sifted.windows.kept
    readonly property var _logind: root._sifted.logind.kept
    // the names the list set aside, for the log: said once each, when first set aside (the holder going and coming says it again)
    readonly property string _ignoredNames: root._sifted.apps.ignored.concat(root._sifted.windows.ignored).concat(root._sifted.logind.ignored).sort().join("\n")
    property var _said: ({})
    on_IgnoredNamesChanged: {
        const now = {};
        const names = root._ignoredNames === "" ? [] : root._ignoredNames.split("\n");
        for (let i = 0; i < names.length; i++) {
            now[names[i]] = true;
            if (!root._said[names[i]])
                console.log("LARES idle content ignored: " + names[i]);
        }
        root._said = now;
    }
    property bool _fresh: false
    property int _waiting: 0

    function _one(): void {
        if (--root._waiting > 0)
            return;
        root._fresh = true;
        root.answered();
    }
    onPollingChanged: if (!root.polling) root._fresh = false
    // the auto layer's first look is at once, not a poll later
    onWatchChanged: if (root.watch) root.refresh()
    // a program that is not there says nothing at all, and neither does a stuck one: the question never holds the dim up
    Timer {
        id: lateAnswer
        interval: 1000
        onTriggered: {
            if (root._waiting > 0) {
                root._waiting = 1;
                root._one();
            }
        }
    }

    SupervisedStream {
        enabled: root.live
        command: root.dbusCommand
        what: "ContentHold: the screensaver watch"
        onLine: text => {
            root._state = Rules.feed(root._state, text);
            if (root._state.wait !== null)
                return;                       // the message's arguments are still to come (the holder's name is the first of them)
            const a = Rules.apps(root._state);
            if (a.join("\n") !== root._appsAll.join("\n"))
                root._appsAll = a;
        }
    }
    Process {
        id: clients
        command: root.clientsCommand
        stdout: StdioCollector {
            onStreamFinished: {
                const win = Rules.windowHolds(this.text);
                if (win.join("\n") !== root._windowsAll.join("\n"))
                    root._windowsAll = win;
                root._one();
            }
        }
    }
    Process {
        id: logind
        command: root.logindCommand
        stdout: StdioCollector {
            onStreamFinished: {
                const w = Rules.logindWho(this.text);
                if (w.join("\n") !== root._logindAll.join("\n"))
                    root._logindAll = w;
                root._one();
            }
        }
    }
    Timer {
        interval: root.pollMs
        repeat: true
        running: root.live && (root.polling || root.watch)
        onTriggered: root.refresh()
    }
}
