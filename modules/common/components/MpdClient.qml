pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// MpdClient.qml
//
// The MPD transport, and nothing above it. Two UNIX sockets, line framing,
// one command in flight, and a `changed(subsystem)` signal. It knows the
// protocol's SHAPE — greeting, `OK` / `ACK`, `list_OK`, `changed:`, argument
// quoting — and not one command's meaning. MpdService is what knows those.
//
// WHY TWO SOCKETS. A connection parked in `idle` is the only way MPD pushes
// anything, and sending any command but `noidle` on an idling connection makes
// the daemon close it with a bare EOF — no ACK, no message, verified against
// this daemon. `noidle` on a connection that is NOT idling replies with
// nothing at all, so a client that waits for a terminator after it hangs for
// good. With one socket the two failures are one race apart. With two there is
// no race: `_idle` only ever writes `idle`, `_cmd` only ever writes commands.
//
// WHY THE CALLER CANNOT SEE LINES. `SplitParser` hands over one line at a
// time, but an MPD response is a multi-line block ending in a bare `OK` or an
// `ACK [n@m] {cmd} message`. Every consumer would otherwise reimplement that
// buffering, and a partly-collected response is exactly the state that turns a
// dropped connection into a hang. So `send`/`sendAll` take a callback that
// fires once, with the whole block, or with `ok = false` — including when the
// socket dies underneath the request.
//
// WHY THERE IS A HEARTBEAT. `connection_timeout` (60 s by default) closes a
// SILENT command socket; measured EOF at 61.1 s with zero bytes while the
// idling socket beside it was still healthy. Without the ping, the first click
// after a minute of quiet is swallowed by a reconnect.
//
// Responses are strictly FIFO and MPD pipelines happily, but this queues one
// request at a time anyway: a reply carries no request id, so matching is by
// counting terminators, and a single in-flight job makes that counting
// trivially correct — including after an ACK aborts a command list halfway.
//
// WHY THE SOCKETS ARE BUILT AND THROWN AWAY. A `Quickshell.Io.Socket` that has
// ERRORED cannot be reconnected: measured on 0.3.1, `connected = false` then
// `connected = true` on the same object after a ServerNotFoundError produces
// nothing at all — no attempt, no error, no state change — while a socket that
// was disconnected cleanly reconnects on the same toggle, and a FRESH object
// connects immediately. Reusing the objects therefore works right up until the
// daemon is restarted, and then the shell needs restarting too. So both
// sockets are created per attempt and destroyed on every drop: one rule, no
// case that only looks fine.
// =============================================================================
Item {
    id: root

    // ---- Configuration ----
    // The per-user daemon's socket. systemd's user `mpd.socket` listens on
    // `$XDG_RUNTIME_DIR/mpd/socket`; `Quickshell.Io.Socket` is a QLocalSocket
    // and has no host/port, so this path is the only way in.
    property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/mpd/socket"

    // Both sockets up and past their greeting — i.e. `send` will actually go
    // out and `changed` will actually arrive. Half of that is not useful to
    // anyone, so it is not reported.
    readonly property bool connected: root._cmdReady && root._idleReady

    // Protocol version from the greeting ("0.24.0"), "" until connected. This
    // is the PROTOCOL version, not the daemon's.
    readonly property string version: root._version

    // The last ACK line or socket error, verbatim. Never cleared on success —
    // it is a diagnostic, not a state.
    readonly property string lastError: root._lastError
    // See `commandTimeoutMs`.
    readonly property bool stuck: root._stuck

    // Connect as soon as the object is built. A host that wants to hold the
    // connection back — a mockup that starts on a stub and only reaches for
    // the daemon when the user asks — sets this false and calls `reconnect()`.
    // Until then the object is inert: no socket, no retry, no error in the log.
    property bool autoConnect: true
    property bool autoReconnect: true
    property int reconnectMs: 1500          // backoff base, doubled per attempt
    property int reconnectCapMs: 15000      // …and capped here
    property int heartbeatMs: 25000         // < connection_timeout (60 s)
    // A command that has been on the wire this long without an answer marks the daemon STUCK (`stuck`,
    // true until the answer or the end of the connection). It does nothing else: no teardown, no retry --
    // a daemon blocked on a sound device (state D) answers nothing to a new connection either, and what
    // to do about it is the health check's to say (MpdHealth.qml), never this transport's. 0 turns it off.
    property int commandTimeoutMs: 5000
    property bool debug: false

    // One per subsystem name in an idle notification. MPD coalesces, so a
    // batch of edits can arrive as one `changed: playlist`.
    signal changed(string subsystem)

    // Fired once each time the pair comes up (first connect and every
    // reconnect). The host re-reads its whole state here.
    signal ready()

    // ---- Public API ---------------------------------------------------------

    // One command. `cb(ok, lines)` — `lines` is the response block without its
    // terminator. `cb` may be null for fire-and-forget.
    function send(cmd, cb) {
        root._enqueue([cmd], false, cb || null);
    }

    // A command list. `cb(ok, groups)` — one array of lines per command, in
    // order. An ACK aborts the list at the failing command, so on `ok = false`
    // `groups` holds the commands that had already succeeded.
    function sendAll(cmds, cb) {
        root._enqueue((cmds || []).slice(), true, cb || null);
    }

    // "key: value" lines to an object, LAST occurrence wins (that is what
    // `status` means by repeating nothing). MPD's own capitalisation is kept:
    // the wire mixes `Format` with `duration` and rewriting it would only move
    // the surprise somewhere else.
    function parseKV(lines) {
        const o = {};
        for (let i = 0; i < lines.length; i++) {
            const kv = root._splitLine(lines[i]);
            if (kv) o[kv.key] = kv.value;
        }
        return o;
    }

    // Records split on each `startKey` line ("file" for song lists,
    // "directory" for lsinfo). The start key is the ONLY reliable separator:
    // field order inside a record differs per decoder plugin — the flac plugin
    // emits Title/Album/AlbumArtist/Artist, ffmpeg emits Artist/Album/Title.
    //
    // A REPEATED KEY BECOMES AN ARRAY, and it is not a curiosity: this library
    // has an album credited to two people, whose records carry two `Artist:`
    // and two `AlbumArtist:` lines. Joining them into one string reads well and
    // is a trap — "Lena Raine, Trevor Alan Gomes" is not a value any filter
    // will ever match, and splitting it back would cut a band called
    // "Earth, Wind & Fire" in three. An array cannot be misread. `first()` and
    // `joined()` below say which one a caller wants.
    function parseObjects(lines, startKey) {
        const out = [];
        let cur = null;
        for (let i = 0; i < lines.length; i++) {
            const kv = root._splitLine(lines[i]);
            if (!kv) continue;
            if (kv.key === startKey) {
                cur = {};
                out.push(cur);
            }
            if (!cur) continue;
            const had = cur[kv.key];
            if (had === undefined) cur[kv.key] = kv.value;
            else if (Array.isArray(had)) had.push(kv.value);
            else cur[kv.key] = [had, kv.value];
        }
        return out;
    }

    // The primary value of a field parseObjects may have made an array. This
    // is the one that is safe in a filter: MPD matches a multi-valued tag if
    // ANY of its values matches, so one of them is a key and all of them
    // together are not.
    function first(v) {
        if (v === undefined || v === null) return "";
        return Array.isArray(v) ? (v.length > 0 ? v[0] : "") : v;
    }

    // All of them, for display. "Lena Raine, Trevor Alan Gomes".
    function joined(v) {
        if (v === undefined || v === null) return "";
        return Array.isArray(v) ? v.join(", ") : v;
    }

    // A protocol argument: wrapped in double quotes with `\` and `"` escaped.
    function quote(arg) {
        return '"' + String(arg).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    }

    // A value going INSIDE a filter expression's single quotes, which is a
    // second level of escaping and the one everybody gets wrong. The wire text
    // is unescaped once by the protocol's argument parser and once by the
    // filter parser, so the artist `she's green` has to reach the wire as
    //     (AlbumArtist == 'she\\'s green')
    // — two backslashes. One backslash is `')' expected`, verified live. The
    // caller wraps the finished expression in plain double quotes; every value
    // inside it has already been escaped for both levels by this.
    function filterValue(v) {
        return String(v)
            .replace(/\\/g, "\\\\\\\\")   // wire \\\\ -> arg \\ -> filter \
            .replace(/'/g, "\\\\'")       // wire \\'  -> arg \'  -> filter '
            .replace(/"/g, "\\\"");       // wire \"   -> arg "   -> filter "
    }

    // Drop everything queued and start over. Used by a host that wants a clean
    // slate (a mockup switching between the real daemon and a stub).
    function reconnect() {
        root._started = true;
        _retry.stop();
        root._teardown("reconnect requested");
        root._attempt = 0;
        root._connectSockets();
    }

    // ---- Internal state -----------------------------------------------------
    property string _version: ""
    property string _lastError: ""
    property bool _cmdReady: false
    property bool _idleReady: false
    property bool _stuck: false
    property int _attempt: 0
    // Whether the client has ever been told to connect. A path change before
    // that is configuration, not a reconnect.
    property bool _started: false

    // The job queue. A job is { cmds, isList, cb }; `_inflight` is the one on
    // the wire. `_lines` accumulates the current block, `_groups` the finished
    // blocks of a command list.
    property var _pending: []
    property var _inflight: null
    property var _lines: []
    property var _groups: []
    property var _subs: []

    // The live socket pair, null whenever the client is down.
    property var _cmd: null
    property var _idle: null

    Component.onCompleted: if (root.autoConnect) root._connectSockets();
    onSocketPathChanged: if (root._started) root.reconnect();

    function _log(msg) {
        if (root.debug) console.log("MpdClient: " + (Date.now() % 100000) + " " + msg);
    }

    function _splitLine(line) {
        if (line === undefined || line === null) return null;
        const i = line.indexOf(": ");
        if (i > 0) return { key: line.substring(0, i), value: line.substring(i + 2) };
        // An empty value still arrives as "name: " — with the space. But a
        // trailing space is easy to lose in transit, so a bare "name:" is
        // read the same way rather than thrown away.
        if (line.length > 1 && line.charAt(line.length - 1) === ":")
            return { key: line.substring(0, line.length - 1), value: "" };
        return null;
    }

    function _enqueue(cmds, isList, cb) {
        if (cmds.length === 0) {
            // An empty command list would put a blank line on the wire, which
            // is an unknown command. Answer it here instead.
            if (cb) cb(true, []);
            return;
        }
        root._pending.push({ cmds: cmds, isList: isList, cb: cb });
        root._pump();
    }

    function _pump() {
        if (root._inflight || root._pending.length === 0 || !root._cmdReady || !root._cmd) return;
        const job = root._pending.shift();
        root._inflight = job;
        root._lines = [];
        root._groups = [];
        const text = job.isList
            ? "command_list_ok_begin\n" + job.cmds.join("\n") + "\ncommand_list_end\n"
            : job.cmds[0] + "\n";
        root._log("-> " + job.cmds.join(" | "));
        root._cmd.write(text);
        root._cmd.flush();
        if (root.commandTimeoutMs > 0) _cmdDeadline.restart();
    }

    function _finish(ok) {
        const job = root._inflight;
        root._inflight = null;
        _cmdDeadline.stop();
        root._stuck = false;
        let payload;
        if (job.isList) {
            // On an ACK the failing command's partial lines are still the
            // caller's best evidence, so they go in as the last group.
            if (root._lines.length > 0) root._groups.push(root._lines);
            payload = root._groups;
        } else {
            payload = root._lines;
        }
        root._lines = [];
        root._groups = [];
        if (job.cb) job.cb(ok, payload);
        root._pump();
    }

    // Both sockets land here; `isIdle` says which grammar the line belongs to.
    function _onLine(isIdle, line) {
        if (isIdle) root._onIdleLine(line);
        else root._onCmdLine(line);
    }

    function _onCmdLine(line) {
        if (!root._cmdReady) {
            if (line.indexOf("OK MPD ") === 0) {
                root._version = line.substring(7);
                root._cmdReady = true;
                root._attempt = 0;
                root._log("command socket up, protocol " + root._version);
                root._checkReady();
                root._pump();
            } else {
                root._lastError = "unexpected greeting: " + line;
            }
            return;
        }
        if (!root._inflight) {
            // Nothing asked for this. It can only be a reply to a job whose
            // callback already ran (a disconnect completed it early), so it is
            // dropped rather than mis-attributed to the next one.
            root._log("<- (unowned) " + line);
            return;
        }
        if (line === "OK") { root._finish(true); return; }
        if (line.indexOf("ACK ") === 0) {
            root._lastError = line;
            root._log("<- " + line);
            root._finish(false);
            return;
        }
        if (line === "list_OK") {
            root._groups.push(root._lines);
            root._lines = [];
            return;
        }
        root._lines.push(line);
    }

    function _onIdleLine(line) {
        if (!root._idleReady) {
            if (line.indexOf("OK MPD ") === 0) {
                root._idleReady = true;
                root._subs = [];
                root._armIdle();
                root._checkReady();
            } else {
                root._lastError = "unexpected greeting: " + line;
            }
            return;
        }
        if (line === "OK" || line.indexOf("ACK ") === 0) {
            if (line !== "OK") root._lastError = line;
            const subs = root._subs;
            root._subs = [];
            // Re-arm BEFORE the handlers run. Events that happen while we are
            // not idling are not lost — MPD queues them and the next `idle`
            // returns immediately — but re-arming first keeps the window at
            // zero and stops a slow handler from stacking notifications.
            root._armIdle();
            for (let i = 0; i < subs.length; i++) {
                root._log("changed: " + subs[i]);
                root.changed(subs[i]);
            }
            return;
        }
        if (line.indexOf("changed: ") === 0) root._subs.push(line.substring(9));
    }

    function _armIdle() {
        if (!root._idleReady || !root._idle) return;
        root._idle.write("idle\n");
        root._idle.flush();
    }

    function _checkReady() {
        if (root._cmdReady && root._idleReady) root.ready();
    }

    // Both halves down, every waiting caller answered, backoff armed. Called
    // whenever either socket drops: a client that is half connected can
    // neither read state nor hear about it changing, so there is nothing to
    // salvage by keeping the other half.
    function _teardown(why) {
        if (why) root._lastError = why;
        const job = root._inflight;
        const pending = root._pending;
        root._inflight = null;
        _cmdDeadline.stop();
        root._stuck = false;
        root._pending = [];
        root._lines = [];
        root._groups = [];
        root._subs = [];
        root._cmdReady = false;
        root._idleReady = false;
        root._version = "";
        root._closeSockets();
        // Answer AFTER the state is clean: a callback that reacts by sending
        // again must see a client that is down, not one mid-collapse.
        if (job && job.cb) job.cb(false, []);
        for (let i = 0; i < pending.length; i++)
            if (pending[i].cb) pending[i].cb(false, []);
    }

    // Detached, flagged dead, hung up, deleted — in that order. `dead` is what
    // makes the teardown re-entrancy-proof: hanging a socket up emits
    // connectionStateChanged from inside this function, and its handler must
    // not start a second teardown on the way out of the first.
    function _closeSockets() {
        const a = root._cmd;
        const b = root._idle;
        root._cmd = null;
        root._idle = null;
        if (a) { a.dead = true; a.connected = false; a.destroy(); }
        if (b) { b.dead = true; b.connected = false; b.destroy(); }
    }

    function _connectSockets() {
        root._started = true;
        root._closeSockets();
        root._cmd = root._openSocket(false);
        root._idle = root._openSocket(true);
    }

    function _openSocket(isIdle) {
        const s = _sockComponent.createObject(root, { path: root.socketPath, isIdle: isIdle });
        // `Socket.error` carries a QLocalSocket::LocalSocketError — an enum Qt
        // never registers with QML, so a DECLARATIVE `onError:` can be neither
        // compiled nor linted whether or not it names the parameter. Connected
        // from JS instead, which is the same connection without the type
        // check. It has to be connected at all: a connect attempt that never
        // succeeds (the daemon is down at login) produces an error and no
        // connectionStateChanged, so this is the only thing that arms the
        // backoff in the case that matters most.
        // DEFERRED ONE TURN, never run from inside the signal. Tearing the pair down in this handler
        // destroys the very Socket whose `error` is still being emitted, and Quickshell 0.3.2 then calls
        // deleteLater on it again from its own slot: a segfault, the shell down every time the daemon goes
        // away (PeerClosedError, SIGSEGV in QObject::deleteLater under QAbstractSocketPrivate::setErrorAndEmit).
        s.error.connect(function () {
            Qt.callLater(function () {
                if (!s.dead) root._dropped(isIdle ? "idle socket" : "command socket", "socket error");
            });
        });
        s.connected = true;
        return s;
    }

    function _dropped(which, why) {
        if (!root._cmd && !root._idle) {
            // Already down and already scheduled; the second socket reporting
            // the same outage must not double the backoff.
            root._schedule();
            return;
        }
        root._log(which + " dropped: " + why);
        root._teardown(which + ": " + why);
        root._schedule();
    }

    function _schedule() {
        root._log("schedule: auto " + root.autoReconnect + " retry running " + _retry.running);
        if (!root.autoReconnect || _retry.running) return;
        const delay = Math.min(root.reconnectCapMs, root.reconnectMs * Math.pow(2, Math.min(root._attempt, 10)));
        root._attempt++;
        _retry.interval = delay;
        _retry.start();
    }

    // ---- Sockets ------------------------------------------------------------
    Component {
        id: _sockComponent
        Socket {
            id: sock
            // Which half this is, and whether it has been retired. Both are
            // read by handlers that can still fire after the teardown started.
            property bool isIdle: false
            property bool dead: false
            parser: SplitParser {
                splitMarker: "\n"
                onRead: data => {
                    if (!sock.dead) root._onLine(sock.isIdle, data);
                }
            }
            onConnectionStateChanged: {
                if (sock.dead || sock.connected) return;
                root._dropped(sock.isIdle ? "idle socket" : "command socket", "closed");
            }
        }
    }

    Timer {
        id: _cmdDeadline
        interval: root.commandTimeoutMs
        repeat: false
        onTriggered: if (root._inflight) root._stuck = true
    }

    Timer {
        id: _retry
        repeat: false
        onTriggered: {
            if (!root.autoReconnect) return;
            root._log("reconnecting (attempt " + root._attempt + ")");
            root._connectSockets();
        }
    }

    // Keeps the command socket from being closed for being quiet. Skipped
    // whenever anything else is already on the wire — the point is traffic,
    // not the ping.
    Timer {
        id: _beat
        interval: root.heartbeatMs
        repeat: true
        running: root.connected
        onTriggered: {
            if (!root._inflight && root._pending.length === 0) root.send("ping", null);
        }
    }
}
