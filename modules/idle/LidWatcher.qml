pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../common/components"
import "LidRules.js" as Rules

// =============================================================================
// LidWatcher.qml -- is the lid closed? logind's Manager.LidClosed on the SYSTEM bus (read-only: a property read and a signal
// subscription, nothing that can inhibit or trigger anything), through the same supervised `gdbus monitor` SleepWatcher uses.
//
//   closed   the lid is closed (false until known)
//   known    logind has answered at least once
//   feed(t)  one chunk of monitor output, parsed exactly as the monitor's own (a probe's byte-exact line goes in here)
//
// The state at start -- and again whenever logind comes back on the bus -- is read once the monitor says logind owns its name (the
// subscription is in place by then, so a change between the read and the first signal cannot be missed). The lid file in /proc
// (/proc/acpi/button/lid/LID/state) says the same, but only by polling; this is event-driven.
// `bus` is "system" (where logind lives) or "session", for a probe's PRIVATE bus with a stand-in.
// =============================================================================
QtObject {
    id: root

    property bool enabled: true
    property string bus: "system"
    readonly property bool closed: root._closed
    readonly property bool known: root._known
    property var monitorCommand: ["setpriv", "--pdeathsig", "TERM", "--", "gdbus", "monitor", "--" + root.bus, "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]
    property var queryCommand: ["busctl", "--" + (root.bus === "session" ? "user" : "system"), "get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "LidClosed"]

    property bool _closed: false
    property bool _known: false

    function feed(text: string): void {
        const parts = String(text).split("\n");
        for (let i = 0; i < parts.length; i++) {
            const line = parts[i];
            if (Rules.isOwnedLine(line)) {
                if (root.enabled)
                    root._ask();
                continue;
            }
            const c = Rules.lidOfLine(line);
            if (c !== null)
                root._set(c);
        }
    }

    function _set(c: bool): void {
        root._known = true;
        root._closed = c;
    }

    function _ask(): void {
        if (query.running)
            return;
        query.command = root.queryCommand;
        query.running = true;
    }

    property SupervisedStream _stream: SupervisedStream {
        enabled: root.enabled
        command: root.monitorCommand
        what: "LidWatcher: the lid monitor"
        onLine: text => root.feed(text)
    }

    property Process _query: Process {
        id: query
        stdout: StdioCollector {
            onStreamFinished: {
                const c = Rules.lidOfGet(this.text);
                if (c !== null)
                    root._set(c);
            }
        }
    }
}
