pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// MathRender.qml -- the shell's ONE maker of formula pictures (LaTeX -> an alpha mask).
//
//   const r = MathRender.lookup("\\frac{a}{b}", false, 14, 1.25);
//   r.state   "ok" | "fail" | "pending"
//   r.url     the picture (white ink, alpha = coverage: tint it, MathInk.qml)      [ok]
//   r.w r.h   its size in LOGICAL pixels; r.d how far it reaches below the baseline [ok]
//   r.why     the parser's words                                                    [fail]
//   MathRender.serial      +1 whenever an answer lands: a view that got "pending" looks again
//
// WHERE THE WORK IS. matplotlib's mathtext in `tools/llm/mathrender.py --serve`, one child for the whole
// shell, started on the first formula nobody has drawn yet and gone after 3 idle minutes (it is started
// again by the next one): importing matplotlib costs ~0.3 s and ~60 MB, which a shell that never shows
// a formula must not pay. Off the GUI thread by being another process; the GUI thread only writes a line
// and reads a line.
//
// WHAT IS REMEMBERED. Pictures are cached on disk by content, size and scale (the worker's key is md5 of
// the request; Qt.md5 of the same string here), and the worker writes one line per render into
// `index.jsonl`. That index is read ONCE, at first use, synchronously: a formula drawn before is "ok"
// with its size on the very first lookup, so a transcript opened in a new session lays out at once
// instead of showing the source and then jumping when the worker answers. A theme switch asks for
// nothing: the picture has no colour.
//
// LARES_MATH (environment, read once): `off` = never start a worker (every formula is "fail": the source
// shows) -- for the runners that must not run python; LARES_MATH_CACHE = the cache directory.
// =============================================================================
Singleton {
    id: root

    readonly property string mode: Quickshell.env("LARES_MATH") ?? ""
    readonly property string cacheDir: Quickshell.env("LARES_MATH_CACHE")
        ?? Quickshell.cachePath("llm-math")
    property string tool: RepoRoot.dir + "/tools/llm/mathrender.py"

    // Bumped when an answer lands (batched into one change per turn of the event loop).
    property int serial: 0
    // The worker's state, for a probe.
    readonly property bool running: _proc.running
    readonly property int starts: root._starts
    property int _starts: 0
    property int requested: 0       // formulas sent to the worker, a cache hit included
    property int answered: 0

    property var _res: ({})         // key -> result
    property var _asked: ({})       // key -> the request: sent and not answered
    property bool _starting: false
    property int _crashes: 0
    property var _queue: []         // lines waiting for the worker to be up
    property int _nextId: 1
    property bool _bumpQueued: false

    function keyOf(tex: string, display: bool, px: real, scale: real): string {
        return Qt.md5(["v1", tex, display ? "1" : "0", px.toFixed(3), scale.toFixed(3)].join("\x1f"));
    }

    function lookup(tex: string, display: bool, px: real, scale: real): var {
        const key = root.keyOf(tex, display, px, scale);
        const have = root._res[key];
        if (have !== undefined)
            return have;
        if (root.mode === "off")
            return { "state": "fail", "why": "math rendering is off" };
        if (root._asked[key] === undefined) {
            const req = { "id": key, "tex": tex, "display": display, "px": px, "scale": scale };
            root._asked[key] = req;
            root.requested++;
            root._send(req);
        }
        return { "state": "pending" };
    }

    function _send(req: var) {
        root._queue.push(JSON.stringify(req) + "\n");
        if (!_proc.running) {
            root._start();
            return;
        }
        root._flush();
    }

    function _start() {
        if (_proc.running || root._starting)
            return;
        root._starting = true;
        root._starts++;
        _proc.command = ["setpriv", "--pdeathsig", "TERM", "python3", "-I", root.tool,
                              "--serve", "--cache", root.cacheDir];
        _proc.running = true;
    }

    function _flush() {
        while (root._queue.length > 0 && _proc.running && !root._starting)
            _proc.write(root._queue.shift());
    }

    function _land(line: string) {
        if (line.length === 0)
            return;
        let a = null;
        try { a = JSON.parse(line); } catch (e) { return; }
        if (!a || !a.id)
            return;
        root._store(a.id, a.ok === true
            ? { "state": "ok", "url": "file://" + a.file, "w": a.w, "h": a.h, "d": a.d }
            : { "state": "fail", "why": a.why || "" });
        delete root._asked[a.id];
        root.answered++;
        root._bump();
    }

    function _store(key: string, r: var) { root._res[key] = r; }

    function _bump() {
        if (root._bumpQueued)
            return;
        root._bumpQueued = true;
        Qt.callLater(() => { root._bumpQueued = false; root.serial++; });
    }

    // The index of what has been drawn before.
    function _loadIndex() {
        const txt = _index.text();
        if (!txt)
            return;
        const lines = txt.split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].length === 0)
                continue;
            try {
                const e = JSON.parse(lines[i]);
                if (!e.k)
                    continue;
                root._res[e.k] = e.ok === false
                    ? { "state": "fail", "why": e.why || "" }
                    : { "state": "ok", "url": "file://" + root.cacheDir + "/" + e.k + ".png",
                        "w": e.w, "h": e.h, "d": e.d };
            } catch (err) {}
        }
    }

    FileView {
        id: _index
        path: root.cacheDir + "/index.jsonl"
        blockLoading: true
        printErrors: false
    }

    Process {
        id: _proc
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++)
                    root._land(parts[i]);
            }
        }
        onStarted: { root._starting = false; root._flush(); }
        onExited: (code, status) => {
            root._starting = false;
            // Whatever was in flight (a crash, or the idle exit crossing a request) is asked again.
            const lost = Object.keys(root._asked);
            if (lost.length > 0 && code !== 0 && root._crashes++ >= 2) {
                for (let i = 0; i < lost.length; i++) {
                    root._store(lost[i], { "state": "fail", "why": "the formula worker keeps failing" });
                    delete root._asked[lost[i]];
                }
                root._bump();
            } else if (lost.length > 0) {
                // The lines were written to a dead pipe: send them again.
                root._queue = [];
                for (let i = 0; i < lost.length; i++)
                    root._queue.push(JSON.stringify(root._asked[lost[i]]) + "\n");
                root._start();
            }
        }
    }
    Component.onCompleted: root._loadIndex()
}
