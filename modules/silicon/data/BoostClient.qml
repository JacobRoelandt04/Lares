pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// BoostClient.qml -- the shell's side of the interaction boost (docs/silicon.md "The interaction boost").
//
// A root service (`lares-boost.service`: silicon-helper boost-serve, installed by `lares setup`'s R6) raises the Intel
// GPU's frequency floor and the CPU's performance floor for a few hundred ms when asked, and puts both back by itself.
// This is the asking: one unix socket (`socketPath`, /run/lares-boost/sock, the session user's alone), one line per ask,
// `boost <ms>`. ShellServices builds ONE and hands it out as `services.boost` (with `wanted` true) only while silicon.jsonc
// `"interactionBoost": true` and the shell is live; otherwise `services.boost` is null.
//
//   kick(ms)   at the start of a motion: the floors for `ms` (clamped to 50 .. 2000). Never blocks, never logs. An ask
//              that a boost already asked would outlast writes nothing (the server only extends, never shortens).
//
// The socket is connected lazily (the first kick) and kept: the server puts the floors back the moment the connection
// closes, so `wanted` going false, or the shell going away, ends any boost at once. Whether the server is there is asked
// ONCE (`test -S`, a fork) at start, then again at most once a `recheckMs` from a kick while it is absent: a kick never
// tries a connect that would fail (Quickshell would log it). The state is said in ONE line, `LARES boost on|off|absent`,
// at start and when it changes. A dropped connection (the service restarted) is torn down one turn later (never inside
// the Socket's own error signal: CLAUDE.md, the Quickshell Socket law) and asked about again.
// =============================================================================
Item {
    id: root

    property bool wanted: false
    property string socketPath: "/run/lares-boost/sock"
    property int recheckMs: 60000

    // "off" (the key is off) | "on" (the service is there) | "absent" (it is not installed or not running)
    readonly property string status: root._statusOf(root.wanted, root._present)
    // The asks written (a probe's count; never a dependency of anything drawn).
    readonly property var stats: root._stats

    property var _stats: ({ asks: 0, written: 0 })
    property bool _present: false
    property bool _checked: false
    property real _until: 0
    property real _lastCheck: 0
    property int _pending: 0
    property var _sock: null
    property string _said: ""

    function kick(ms: int): void {
        root._stats.asks++;
        if (!root.wanted)
            return;
        const want = Math.max(50, Math.min(2000, Math.round(ms)));
        const now = Date.now();
        if (now + want <= root._until)
            return;  // a boost already asked lasts longer
        if (!root._present) {
            if (root._checked && now - root._lastCheck >= root.recheckMs)
                root._check();
            return;
        }
        if (root._sock && root._sock.connected) {
            root._send(want, now);
            return;
        }
        root._pending = Math.max(root._pending, want);
        if (!root._sock)
            root._open();
    }

    function _send(ms: int, now: real): void {
        root._sock.write("boost " + ms + "\n");
        root._sock.flush();
        root._until = now + ms;
        root._stats.written++;
    }

    function _open(): void {
        const s = sockComponent.createObject(root, { path: root.socketPath });
        // DEFERRED ONE TURN, never inside the signal (a Socket destroyed in its own error signal crashes Quickshell 0.3.2)
        s.error.connect(function () {
            Qt.callLater(function () { root._drop(s); });
        });
        root._sock = s;
        s.connected = true;
    }

    function _drop(s: var): void {
        if (!s || s.dead || s !== root._sock)
            return;
        s.dead = true;
        root._sock = null;
        root._until = 0;
        root._pending = 0;
        s.connected = false;
        s.destroy();
        if (root.wanted)
            root._check();  // the service restarted, or went: ask again
    }

    function _close(): void {
        const s = root._sock;
        if (!s)
            return;
        s.dead = true;
        root._sock = null;
        root._until = 0;
        root._pending = 0;
        s.connected = false;
        s.destroy(100);
    }

    function _check(): void {
        if (check.running)
            return;
        root._lastCheck = Date.now();
        check.command = ["test", "-S", root.socketPath];
        check.running = true;
    }

    function _statusOf(wanted: bool, present: bool): string {
        return !wanted ? "off" : present ? "on" : "absent";
    }

    // from the facts, never from `status`: a change handler of `wanted` runs before the binding has followed it
    function _say(): void {
        const now = root._statusOf(root.wanted, root._present);
        if (now === root._said)
            return;
        root._said = now;
        console.log("LARES boost " + now);
    }

    onWantedChanged: {
        if (!root.wanted)
            root._close();  // the server puts the floors back as the connection closes
        else if (!root._checked)
            root._check();
        if (root._checked || !root.wanted)
            root._say();
    }

    Component.onCompleted: {
        if (root.wanted)
            root._check();
        else
            Qt.callLater(root._say);
    }

    Process {
        id: check
        onExited: code => {
            root._checked = true;
            root._present = code === 0;
            root._say();
        }
    }

    Component {
        id: sockComponent
        Socket {
            id: sock
            property bool dead: false
            parser: SplitParser {
                splitMarker: "\n"
                onRead: line => {
                    // `ok <ms>` or `refused <why>`: a refusal is said (it is a fault of ours or of the install), never repeated
                    if (!sock.dead && line.indexOf("refused") === 0)
                        console.warn("LARES boost: the service said: " + line);
                }
            }
            onConnectedChanged: {
                if (sock.dead)
                    return;
                if (sock.connected) {
                    if (root._pending > 0) {
                        const ms = root._pending;
                        root._pending = 0;
                        root._send(ms, Date.now());
                    }
                } else {
                    Qt.callLater(function () { root._drop(sock); });
                }
            }
        }
    }
}
