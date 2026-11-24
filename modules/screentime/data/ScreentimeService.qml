pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeService.qml -- the shell's end of screentimed's socket
// (docs/contracts/screentime.md §2, §9). The daemon (helpers/screentimed)
// tracks; this only ASKS: it sends queries, never a feed, so nothing in the
// shell can change what is recorded.
//
// The same members as ScreentimeMock.qml (§9), so the card takes either:
//   status          "connecting" | "ok" | "absent" (no socket file: the
//                   daemon is not installed or not running)
//   state           the daemon's STATE (§6), or null
//   live            the HOST sets it while the card is on show. ONE SNAPSHOT A
//                   SESSION: becoming live re-asks the
//                   state and every cached answer once (`refresh`), each new
//                   answer replacing the old one where it stands -- nothing is
//                   dropped, so no getter reads empty -- and nothing changes
//                   again until the next session. A live push would redraw the whole
//                   card mid-session (a focus push drops today's week: one
//                   empty frame, "the popup flashes"); the daemon is asked, not
//                   listened to.
//   refresh()       that re-ask, on demand (the mockup's Refetch)
//   serial          bumps on every cache change -- read it FIRST in a binding
//   loadWeek/week, loadDay/day, loadRange/range, weekStartOf
// Getters never ask (a getter in a binding that asked could answer inside the
// binding, CLAUDE.md); `load*` asks, at most once per key while in flight.
//
// THE CONNECTION is ShellLink.qml's (the lock's client), for its measured
// reasons: a FRESH Socket per attempt (a Quickshell Socket whose first connect
// failed never retries), and a FileView stat first (a connect to a missing
// path logs an error; a stat that answers NotAFile says a socket is there, and
// says nothing otherwise). Retries back off from 250 ms to 10 s, so a desktop
// without the daemon pays one silent stat every ten seconds. A SplitParser
// slice may hold several lines (Quickshell 0.3.1): each is split again. On the
// daemon's `bye` THIS end closes first (whoever closes decides which log gets
// the PeerClosedError, CLAUDE.md).
// =============================================================================
Scope {
    id: root

    property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    property string socketPath: root.runtimeDir + "/screentime/screentimed.sock"

    property bool live: false
    readonly property string status: root._status
    readonly property var state: root._state
    readonly property int serial: root._serial

    // Lines the daemon sent that were not understood (for probes).
    property int ignored: 0

    property string _status: "connecting"
    property var _state: null
    property int _serial: 0
    property var _weeks: ({})
    property var _days: ({})
    property var _ranges: ({})
    // id -> { kind, key }: what an answer is for; and key -> true while asked.
    property var _pending: ({})
    property var _asked: ({})
    property int _nextId: 1

    // ---- getters (never ask) ------------------------------------------------
    function week(from) {
        const _s = root._serial;
        return root._weeks[from] ?? null;
    }
    function day(date) {
        const _s = root._serial;
        return root._days[date] ?? null;
    }
    function range(a, b) {
        const _s = root._serial;
        return root._ranges[a + "|" + b] ?? null;
    }
    function weekStartOf(date) {
        const ws = root._state && root._state.config ? root._state.config.weekStart : 1;
        return Model.weekStartOf(date, ws || 1);
    }

    // ---- asks ----------------------------------------------------------------
    function loadWeek(from) {
        root._ask("week", from, { q: "week", from: from });
    }
    function loadDay(date) {
        root._ask("day", date, { q: "day", date: date });
    }
    function loadRange(a, b) {
        root._ask("range", a + "|" + b, { q: "range", from: a, to: b });
    }
    // The session's snapshot: the state and everything already answered, asked
    // again; each answer replaces the old one in place.
    function refresh() {
        root._ask("state", "", { q: "state" });
        for (const k of Object.keys(root._weeks))
            root.loadWeek(k);
        for (const k of Object.keys(root._days))
            root.loadDay(k);
        for (const k of Object.keys(root._ranges)) {
            const ab = k.split("|");
            root.loadRange(ab[0], ab[1]);
        }
    }
    onLiveChanged: {
        if (root.live)
            root.refresh();
    }
    function _ask(kind, key, msg) {
        const k = kind + ":" + key;
        if (root._asked[k] || !root.connected)
            return;
        const id = root._nextId++;
        root._pending[id] = { kind: kind, key: key };
        root._asked[k] = true;
        msg.id = id;
        root._write(JSON.stringify(msg));
    }

    // ---- what comes back -------------------------------------------------------
    function _onSlice(data) {
        for (const line of String(data).split("\n")) {
            if (line !== "")
                root._handle(line);
        }
    }
    function _handle(line) {
        let m;
        try {
            m = JSON.parse(line);
        } catch (e) {
            root.ignored++;
            return;
        }
        if (!m || typeof m !== "object" || m.v !== 1) {
            root.ignored++;
            return;
        }
        if (m.ev !== undefined)
            root._onPush(m);
        else if (m.id !== undefined)
            root._onReply(m);
        else
            root.ignored++;
    }
    function _onReply(m) {
        const p = root._pending[m.id];
        if (!p) {
            root.ignored++;
            return;
        }
        delete root._pending[m.id];
        delete root._asked[p.kind + ":" + p.key];
        if (!m.ok) {
            console.log("screentime: " + p.kind + " " + p.key + " refused (" + m.error + ")");
            return;
        }
        if (p.kind === "state") {
            root._setState(m.state);
            return;
        }
        if (p.kind === "week")
            root._weeks[p.key] = m.week;
        else if (p.kind === "day")
            root._days[p.key] = m.day;
        else if (p.kind === "range")
            root._ranges[p.key] = m.range;
        root._serial++;
    }
    function _onPush(m) {
        switch (m.ev) {
        case "state":
        case "focus":
        case "day":
        case "monitors":
            // Not subscribed (one snapshot a session); a daemon that sends one anyway is not news.
            break;
        case "bye":
            root._closeOurEnd();
            break;
        default:
            root.ignored++;
        }
    }
    function _setState(s) {
        root._state = s;
        if (root._status !== "ok")
            root._status = "ok";
    }

    // ---- the socket -------------------------------------------------------------
    readonly property var _sock: gen.object
    readonly property bool connected: root._sock ? root._sock.connected : false

    function _writeTo(sk, line) {
        if (!sk || !sk.connected)
            return;
        sk.write(line + "\n");
        sk.flush();
    }
    function _write(line) {
        root._writeTo(root._sock, line);
    }
    // On the daemon's bye: disconnect THIS end first (the daemon waits for it,
    // and whoever closes decides which log has the PeerClosedError), tear the
    // Socket down a turn later (not inside its own read), and dial again only
    // after a second -- until the stopping daemon has unlinked its socket a
    // dial would reach a listener that is gone (ServerNotFoundError).
    property real _byeAt: 0
    function _closeOurEnd() {
        root._byeAt = Date.now();
        if (root._sock)
            root._sock.connected = false;
        Qt.callLater(() => gen.active = false);
        root._status = "connecting";
        root._pending = ({});
        root._asked = ({});
    }

    property bool _sockThere: false
    property int _misses: 0
    FileView {
        id: probe
        path: root.socketPath
        printErrors: false
        blockLoading: true
        onLoadFailed: error => root._sockThere = (error === FileViewError.NotAFile)
        onLoaded: root._sockThere = false
    }
    onConnectedChanged: {
        if (root.connected) {
            root._misses = 0;
        } else {
            root._pending = ({});
            root._asked = ({});
        }
    }

    Instantiator {
        id: gen
        model: 1
        active: false
        delegate: Socket {
            id: sock
            path: root.socketPath
            connected: true
            parser: SplitParser {
                onRead: data => root._onSlice(data)
            }
            onConnectedChanged: {
                if (!sock.connected)
                    return;
                // A local connect completes inside the creation, before the
                // Instantiator has set `object`: write through THIS socket.
                // The state only: the card asks for its week from it.
                const s = root._nextId++;
                root._pending[s] = { kind: "state", key: "" };
                root._writeTo(sock, JSON.stringify({ q: "state", id: s }));
            }
        }
    }

    // Look for the socket, dial when it is there; again after every disconnect.
    Timer {
        id: retry
        interval: Math.min(10000, 250 * Math.pow(2, Math.min(root._misses, 6)))
        repeat: true
        running: !root.connected
        triggeredOnStart: true
        onTriggered: {
            if (Date.now() - root._byeAt < 1000)
                return;
            probe.reload();
            if (!root._sockThere) {
                root._status = "absent";
                root._misses++;
                return;
            }
            if (root._status === "absent")
                root._status = "connecting";
            if (gen.active)
                root._misses++;
            gen.active = false;
            gen.active = true;
        }
    }
}
