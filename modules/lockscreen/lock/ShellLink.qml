pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../"
import "../LockProtocol.js" as LockProtocol

// =============================================================================
// ShellLink.qml -- the lock's end of the socket to the desktop shell (contract
// section 3). The lock is the CLIENT: it connects, sends its LockState after
// every change (coalesced to one line per event-loop turn), and hears back only
// what helps it DRAW and HEAR: which screens the shell's popup is shown on (so
// the fallback card hides), the rects to mask out of step-down captures, where
// the popup's password field is (`targets`: key pulses start there), and `retracted` (the shell's unlock retract finished).
//
// SECURITY. The shell is UNTRUSTED here. Nothing it sends unlocks anything or
// delays anything: `retracted` only lets LockRoot release EARLIER than its own
// 600 ms floor, and only while phase is "unlocking" (earlier ones are ignored).
// Every line goes through LockProtocol.parse, which drops what it does not
// know; the count of dropped lines is `ignored`, for probes.
//
// The lock keeps running whether or not a shell ever connects: it looks for
// the socket every 250 ms for as long as the lock lives, and dials only once
// the socket is there.
// =============================================================================
Scope {
    id: root

    property LockState lockState: null
    property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    property string display: Quickshell.env("WAYLAND_DISPLAY") || ""
    readonly property string path: LockProtocol.socketPath(root.runtimeDir, root.display)

    readonly property var _sock: gen.object
    readonly property bool connected: root._sock ? root._sock.connected : false
    // Screen names the shell reports its popup on.
    property var shownScreens: []
    // When the shell last connected / last said where its popup is shown (ms since epoch, 0 never): the desktop layer waits for the
    // shell's popup to be settled before it takes the picture the veil is made of (DesktopLayer, the capture)
    property real activeAt: 0
    // screen name -> [[x, y, w, h], ...]
    property var hints: ({})
    // per screen, the bar and the popup when the shell NAMED them ({bar, popup}, each [x,y,w,h] or null); null: it did not
    property var hintParts: ({})
    // screen name -> { field: [x, y, w, h] | null }
    property var targets: ({})
    // Lines that were not understood, and messages that were not allowed.
    property int ignored: 0
    property int received: 0

    // The shell's retract finished. Only ever emitted while unlocking.
    signal retracted

    // The whole state as one line; reading every field is what makes this
    // re-evaluate on any change, and the send is coalesced below.
    readonly property string _line: root.lockState ? LockProtocol.stateLine(root.lockState) : ""
    on_LineChanged: Qt.callLater(root._flush)

    function _writeTo(sk, line) {
        if (!sk || !sk.connected)
            return;
        sk.write(line + "\n");
        sk.flush();
    }
    function _write(line) {
        root._writeTo(root._sock, line);
    }
    function _flush() {
        if (root._line !== "")
            root._write(root._line);
    }
    // After the release, before quitting.
    // The last line. The SHELL closes first on it (its log lives for days;
    // Quickshell logs a close from the peer's end as an error and whoever
    // closes decides which log has it), so the lock's own log may end with one
    // PeerClosedError as it exits -- by design. Its end is dropped 50 ms later
    // and nothing re-dials.
    property bool _done: false
    function sendBye() {
        root._done = true;
        root._write(LockProtocol.bye());
        if (root._sock)
            root._sock.flush();
        byeDrop.start();
    }
    Timer {
        id: byeDrop
        interval: 50
        onTriggered: gen.active = false
    }

    function _onLine(line) {
        // A SplitParser slice may hold embedded newlines (Quickshell 0.3.1),
        // so a slice is split again.
        const parts = String(line).split("\n");
        for (const p of parts) {
            if (p === "")
                continue;
            root._handle(p);
        }
    }
    // A line or message that is not accepted: counted, and logged for the first
    // few (a hostile shell must not be able to fill the log).
    function _ignore(why) {
        root.ignored++;
        if (root.ignored <= 64)
            console.log("LARESLOCK ignored " + root.ignored + " (" + why + ")");
    }
    function _handle(text) {
        const r = LockProtocol.parse(text);
        if (!r.ok) {
            root._ignore(r.why);
            return;
        }
        root.received++;
        const m = r.msg;
        switch (m.t) {
        case "hello":
            break;
        case "shown":
            root.shownScreens = m.screens;
            root.activeAt = Date.now();
            break;
        case "hints":
            {
                const h = Object.assign({}, root.hints);
                h[m.screen] = m.rects;
                const p = Object.assign({}, root.hintParts);
                p[m.screen] = m.bar !== undefined ? { "bar": m.bar, "popup": m.popup } : null;
                root.hintParts = p;   // first: _parts reads it when `hints` changes
                // the shell moved its popup: a desktop layer built after this (LockSurface builds it at `locked`) still knows when
                if (JSON.stringify(root.hints[m.screen] || []) !== JSON.stringify(m.rects))
                    root.activeAt = Date.now();
                root.hints = h;
            }
            break;
        case "targets":
            {
                const t = Object.assign({}, root.targets);
                t[m.screen] = { "field": m.field };
                root.targets = t;
            }
            break;
        case "retracted":
            if (root.lockState && root.lockState.phase === "unlocking")
                root.retracted();
            else
                root._ignore("retracted before unlocking");
            break;
        default:
            // state / bye go lock -> shell only.
            root._ignore("not for the lock: " + m.t);
        }
    }

    // A FRESH Socket per attempt: a Quickshell Socket whose first connect failed
    // never tries again when `connected` is set true a second time (measured:
    // one ServerNotFoundError, then silence, however often it was toggled or
    // its path re-set), so a lock that started before the shell would never
    // find it. An Instantiator (non-visual) is torn down and rebuilt instead.
    //
    // And only once the socket FILE is there: every connect to a missing path
    // logs a ServerNotFoundError, and at boot (the lock starts seconds before
    // the shell) that is ~40 warnings in the lock's log. A FileView on the
    // path fails with FileNotFound while it is missing and with NotAFile once
    // the shell listens -- a silent stat, no process. A socket file left by a
    // shell that died still dials and fails, so after a few misses the retry
    // slows to 2 s (reset on every connect).
    property bool _sockThere: false
    property int _misses: 0
    FileView {
        id: probe
        path: root.path
        printErrors: false
        blockLoading: true
        onLoadFailed: error => root._sockThere = (error === FileViewError.NotAFile)
        onLoaded: root._sockThere = false
    }
    onConnectedChanged: if (root.connected) root._misses = 0

    Instantiator {
        id: gen
        model: 1
        active: false
        delegate: Socket {
            id: sock
            path: root.path
            connected: true
            parser: SplitParser {
                onRead: data => root._onLine(data)
            }
            onConnectedChanged: {
                if (sock.connected) {
                    root.activeAt = Date.now();
                    // A local connect completes inside the creation, before the
                    // Instantiator has set `object`: write through THIS socket.
                    root._writeTo(sock, LockProtocol.hello());
                    if (root._line !== "")
                        root._writeTo(sock, root._line);
                } else {
                    root.shownScreens = [];
                    root.hintParts = ({});
                    root.hints = ({});
                    root.targets = ({});
                }
            }
        }
    }

    // Retry until connected, and again after every disconnect.
    Timer {
        interval: root._misses < 8 ? 250 : 2000
        repeat: true
        running: !root.connected && !root._done
        triggeredOnStart: true
        onTriggered: {
            probe.reload();
            if (!root._sockThere)
                return;
            if (gen.active)
                root._misses++;
            gen.active = false;
            gen.active = true;
        }
    }
}
