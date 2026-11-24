pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// =============================================================================
// AskpassServer -- the socket sudo's askpass helper talks to (the LLM tool jobs
// and the shell's other askers share this one verified path).
//
// A helper (`llm_tools/askpass.py`) connects to `path`, sends one JSON line,
// {"pid": ..., "prompt": ...}, and waits for one line back: the password, or
// an empty line, which is a cancel. Not stderr: a command that says
// `2>/dev/null` would have swallowed the request and left sudo waiting.
//
// A request is VERIFIED before anything is published: the claimed pid must
// descend from `rootPid` (the process whose job may run sudo), and -- with
// `requireSudoParent` -- its parent must be a process named sudo running with
// effective uid 0, which only a setuid binary can be. So a command cannot put
// up a password box by calling the helper itself or by writing to the socket.
// What remains is the ordinary limit of any command the user approved: it
// runs as the user, and a command written to intercept its own password
// could. `request` is then published. It says nothing about faillock: there is
// no lockout ever (faillock.conf `deny = 0`), only pam_unix's ~2 s delay after
// a wrong password, so there is no countdown to show.
//
// `answer(id, secret)` writes the secret down that one connection and closes
// it, and nothing here keeps it. Whoever closes the socket first decides
// whether the close is an error in Quickshell's log, so this side always
// answers first: on an answer, a cancel, `active` or `rootPid` changing under
// a standing request, and `answerWindowMs - 2 s` after it was published (the
// helper's own timeout is `answerWindowMs`).
//
// Served only while `active` (nothing else can have a sudo in it, and a socket
// that does not exist cannot be written to), one request at a time: a second
// connection while one is open is answered "" at once, as is a request while
// `rootPid` is not a process.
//
// THE SETTLE WATCH. sudo does not wait for its helper when the
// answer came from somewhere else: with howdy `workaround = native` the face
// scan runs beside the helper, and a face that wins lets sudo carry on -- or
// exit -- while the helper still sits on its socket (measured).
// So the processes are the only witness. Each
// sudo that asked (the verified parent, `sudoPid`) is watched from its first
// request through `/proc/<sudoPid>/task/<sudoPid>/children` -- a FileView
// reload, no fork, every `watchIntervalMs` and only while something is
// watched -- until it settles or `watchMs` passes:
//   "moved-on"  sudo has a child that was not there when it last asked and is
//               not its askpass helper or howdy's scan: the command runs, so it
//               authenticated, by whatever means
//   "gone"      sudo no longer exists -- or nothing more can be known of it:
//               the server stopped serving, its root changed, or `watchMs` ran out
// The children present when a request is published are the baseline: sudo is
// waiting for a password then, so none of them is the command (howdy's scan,
// the helper itself). A child must also stay unknown for `settleDebounceMs`
// before it counts -- the helper of a retry exists for a moment before its
// request is verified -- and is skipped if its command line matches
// `ignoreChildren`. On a settle the request of that sudo, if it still stands,
// is withdrawn (`withdrawn`, then answered "" and closed from THIS side, so the
// orphaned helper exits 1 and sudo is no longer waited on); then `sudoSettled`.
// =============================================================================
Item {
    id: root

    // The socket path; served only while `active`.
    property string path: ""
    property bool   active: false
    // Requests must descend from this process; 0 refuses every request.
    property int    rootPid: 0
    property bool   requireSudoParent: true
    // How long the helper waits; the request is withdrawn 2 s before.
    property int    answerWindowMs: 120000
    // The settle watch: how long one sudo is watched, how often, how long an
    // unknown child must have stood before it counts as the command, and the
    // command lines (a regular expression) that are never the command.
    property int    watchMs: 600000
    property int    watchIntervalMs: 200
    property int    settleDebounceMs: 300
    property string ignoreChildren: "howdy|askpass"

    // null | { id, pid, sudoPid, prompt }: a new object per request. `pid` is
    // the helper, `sudoPid` its verified parent.
    readonly property var request: root._request

    // A verified request was published (`request` is already it).
    signal requested(var request)
    // The helper went away or the answer window ran out; `request` is null.
    signal withdrawn(string id)
    // A watched sudo moved on or went away (see the settle watch). `how` is
    // "moved-on" | "gone". Any request of that sudo has been withdrawn first.
    signal sudoSettled(int sudoPid, string how)

    // answer(id, secret): "" is a cancel. Ignored unless `id` is the one
    // standing request. Nothing keeps the secret: it is written and this
    // function returns.
    function answer(id, secret) {
        const r = root._request;
        if (!r || String(id) !== r.id) return;
        const conn = root._pending.conn;
        root._drop();
        root._reply(conn, String(secret || "").replace(/[\r\n]/g, ""));
    }
    // cancel(id): answer(id, ""). An empty id withdraws whatever is open,
    // verified or not (a stop while the check is still running).
    function cancel(id) {
        if (String(id || "") === "") root._abort();
        else root.answer(id, "");
    }

    // ---- Internal ----------------------------------------------------------
    property var _pending: null    // { conn, pid, prompt, id }, from the line to the answer
    property var _request: null
    property int _seq: 0
    // sudoPid -> { view, base: {childPid: true}, since: {childPid: ms}, until }
    property var _watches: ({})
    property int _watching: 0

    SocketServer {
        active: root.active && root.path.length > 0
        path: root.path
        handler: Socket {
            id: askConn
            parser: SplitParser {
                onRead: function (line) { root._onLine(askConn, line); }
            }
            onConnectedChanged: if (!askConn.connected) root._onGone(askConn)
        }
    }

    // Who is asking: the claimed pid's parent's name and effective uid,
    // and whether the pid descends from the root process.
    readonly property string _verifyScript:
        'p=$1; job=$2\n'
        + 'pp=$(awk \'/^PPid:/ { print $2 }\' "/proc/$p/status" 2>/dev/null)\n'
        + '[ -n "$pp" ] || { echo "gone 0 0"; exit 0; }\n'
        + 'name=$(awk \'/^Name:/ { print $2 }\' "/proc/$pp/status" 2>/dev/null)\n'
        + 'euid=$(awk \'/^Uid:/ { print $3 }\' "/proc/$pp/status" 2>/dev/null)\n'
        + 'q=$p; in=0; i=0\n'
        + 'while [ -n "$q" ] && [ "$q" -gt 1 ] && [ $i -lt 64 ]; do\n'
        + '  [ "$q" = "$job" ] && { in=1; break; }\n'
        + '  q=$(awk \'/^PPid:/ { print $2 }\' "/proc/$q/status" 2>/dev/null); i=$((i + 1))\n'
        + 'done\n'
        + 'echo "${name:-?} ${euid:-?} $in $pp"'
    Process {
        id: _verifyProc
        running: false
        stdout: StdioCollector { id: _verifyOut; waitForEnd: true }
    }
    Connections {
        target: _verifyProc
        function onExited(exitCode, exitStatus) { root._verified(String(_verifyOut.text || "").trim()); }
    }

    // A request standing under a server that stops serving, or whose root
    // process is replaced, is answered "no" on this side first.
    onActiveChanged: { root._abort(); root._unwatchAll(); }
    onRootPidChanged: { root._abort(); root._unwatchAll(); }

    function _onLine(conn, line) {
        let req = null;
        try { req = JSON.parse(String(line)); } catch (e) { req = null; }
        // One question at a time, under a live root, with a pid in it.
        if (!req || !(Number(req.pid) > 1) || root._pending || !(root.rootPid > 0)) {
            root._reply(conn, "");
            return;
        }
        root._seq++;
        root._pending = { conn: conn, pid: Math.floor(Number(req.pid)),
                          prompt: String(req.prompt || "").substring(0, 200), id: String(root._seq) };
        _verifyProc.command = ["bash", "-c", root._verifyScript, "verify",
                               String(root._pending.pid), String(root.rootPid)];
        _verifyProc.running = true;
    }

    function _verified(out) {
        const a = root._pending;
        if (!a) return;
        const w = out.split(" ");
        const inJob = w[2] === "1";
        const fromSudo = w[0] === "sudo" && w[1] === "0";
        if (!inJob || (root.requireSudoParent && !fromSudo)) {
            console.log("[askpass] password request refused: pid " + a.pid + " "
                        + (inJob ? "is in the job" : "is not in the job") + ", its parent is "
                        + w[0] + " with euid " + w[1]);
            root._abort();
            return;
        }
        root._request = {
            id: a.id, pid: a.pid, sudoPid: parseInt(w[3], 10) || 0, prompt: a.prompt
        };
        _expiry.restart();
        root._watch(root._request.sudoPid);
        root.requested(root._request);
    }

    // ---- The settle watch ---------------------------------------------------
    Component {
        id: _viewC
        FileView { blockLoading: true; blockAllReads: true; printErrors: false }
    }
    Timer {
        interval: root.watchIntervalMs
        repeat: true
        running: root._watching > 0
        onTriggered: root._tick()
    }

    // A reader of one file, read at once. The path goes in AFTER creation: a
    // path given as an initial property is applied before the view's own
    // `blockLoading` and the first read is then not blocking (measured: a
    // fresh `/proc/<pid>/.../children` read back as "not loaded").
    function _view(path) {
        const v = _viewC.createObject(root);
        v.path = path;
        return v;
    }

    // The children of a watched sudo, or null once it no longer exists.
    // `fresh`: the view was just created and has just read the file.
    function _children(w, fresh) {
        if (!fresh) w.view.reload();
        // `loaded` only means something once the (blocking) read has been asked
        // for: text() first.
        const text = String(w.view.text() || "");
        if (!w.view.loaded) return null;
        const out = [];
        const t = text.split(/\s+/);
        for (let i = 0; i < t.length; i++)
            if (t[i].length > 0) out.push(t[i]);
        return out;
    }

    // Starts watching a sudo, or -- at its next request -- moves the baseline
    // up to what stands now.
    function _watch(pid) {
        if (!(pid > 1)) return;
        let w = root._watches[pid];
        const fresh = !w;
        if (fresh) {
            w = { view: root._view("/proc/" + pid + "/task/" + pid + "/children"),
                  base: ({}), since: ({}), until: Date.now() + root.watchMs };
            root._watches[pid] = w;
            root._watching++;
        }
        const ch = root._children(w, fresh);
        if (ch) for (let i = 0; i < ch.length; i++) w.base[ch[i]] = true;
        w.since = ({});
    }

    // Is this child sudo's own scaffolding (howdy's scan, an askpass helper)?
    function _scaffolding(child) {
        const v = root._view("/proc/" + child + "/cmdline");
        const t = String(v.text() || "");
        v.destroy();
        return t.length > 0 && new RegExp(root.ignoreChildren).test(t);
    }

    function _tick() {
        const now = Date.now();
        const pids = Object.keys(root._watches);
        for (let k = 0; k < pids.length; k++) {
            const pid = Number(pids[k]);
            const w = root._watches[pid];
            if (!w) continue;
            if (now > w.until) { root._settle(pid, "gone"); continue; }
            const ch = root._children(w, false);
            if (ch === null) { root._settle(pid, "gone"); continue; }
            const since = ({});
            let moved = false;
            for (let i = 0; i < ch.length && !moved; i++) {
                const c = ch[i];
                if (w.base[c]) continue;
                since[c] = w.since[c] || now;
                if (now - since[c] < root.settleDebounceMs) continue;
                if (root._scaffolding(c)) { w.base[c] = true; delete since[c]; }
                else moved = true;
            }
            w.since = since;
            if (moved) root._settle(pid, "moved-on");
        }
    }

    function _unwatch(pid) {
        const w = root._watches[pid];
        if (!w) return null;
        w.view.destroy();
        delete root._watches[pid];
        root._watching--;
        return w;
    }
    // The server stopped serving or its root changed: nothing more can be
    // known of any sudo, and whoever waits on one is told it is gone.
    function _unwatchAll() {
        const pids = Object.keys(root._watches);
        for (let k = 0; k < pids.length; k++) root._settle(Number(pids[k]), "gone");
    }

    // The sudo settled: its standing request is withdrawn from this side
    // first, then the fact is told.
    function _settle(pid, how) {
        if (!root._unwatch(pid)) return;
        const r = root._request;
        if (r && r.sudoPid === pid) {
            const conn = root._pending.conn;
            root._drop();
            root.withdrawn(r.id);
            root._reply(conn, "");
        }
        root.sudoSettled(pid, how);
    }

    // The question is withdrawn from THIS side two seconds before the helper
    // would give up on its own -- whoever closes the socket first decides
    // whether a close is an error in the log.
    Timer {
        id: _expiry
        interval: Math.max(1000, root.answerWindowMs - 2000)
        repeat: false
        onTriggered: {
            const r = root._request;
            if (!r) return;
            root._abort();
            root.withdrawn(r.id);
        }
    }

    // Whatever is open, forgotten first (closing the connection fires
    // `connected`, which must find nothing to withdraw) and answered "".
    function _abort() {
        if (!root._pending) return;
        const conn = root._pending.conn;
        root._drop();
        root._reply(conn, "");
    }

    function _reply(conn, text) {
        if (!conn) return;
        try {
            conn.write(text + "\n");
            conn.flush();
            conn.connected = false;
        } catch (e) {}
    }

    // The helper went away before an answer (sudo gave up, the job was
    // killed): the question is withdrawn.
    function _onGone(conn) {
        const a = root._pending;
        if (!a || a.conn !== conn) return;
        const r = root._request;
        root._drop();
        if (r) root.withdrawn(r.id);
    }
    // Forgets the standing question; says nothing to anyone.
    function _drop() {
        _expiry.stop();
        root._pending = null;
        root._request = null;
    }
}
