pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/system"

// =============================================================================
// StockLogos.qml -- the baked logo cache and the ONE worker that fills it.
//
// `dir` holds what tools/stocks/stock_logo.py writes: <slug>.png (the relief
// texture), <slug>.mono.png (always), <slug>.none, and index.json
// ({ slug: { src, brand, wide, bakedAt, mono } }), read through one FileView
// with a static path and reload()ed after every bake.
//
//   logoFor(sym, px)   the baked texture's URL; the monogram when there is no
//                      logo (none, or only the monogram so far), or when a
//                      word-mark (wide) would be shown under 44 px; "" only
//                      until the monogram exists (well under a second: an
//                      unknown symbol's monogram is baked FIRST, --mono-only,
//                      ahead of every fetch in the queue)
//   want(sym, priority, opts)   queue a bake (opts: isin, image, monogram);
//                      priority goes to the head -- the queue is worked
//                      newest-first, so what was asked last (a detail, a
//                      search result) is baked next. A symbol already in the
//                      index is not baked again; a `none` is retried after 30
//                      days.
//   serial             bumped whenever the index changed
//
// `fetching: false` makes it a read-only view of `dir` (the mock's fixtures).
// =============================================================================
Item {
    id: root

    property string dir: ""
    property bool fetching: true
    property string python: "python3"
    property string tool: RepoRoot.dir + "/tools/stocks/stock_logo.py"
    property int serial: 0
    readonly property bool busy: proc.running || root._queue.length > 0

    readonly property real retryNoneMs: 30 * 86400000
    readonly property real retryFailMs: 30 * 60000      // a network failure (exit 4)
    readonly property real wideUnderPx: 44

    function slug(sym) { return String(sym).replace(/[^A-Za-z0-9.\-]/g, "_"); }

    function logoFor(sym, px) {
        const key = root.slug(sym);
        const e = root._index[key];
        if (!e) return "";
        const base = "file://" + root.dir + "/" + key;
        if (!e.src || e.src === "none" || e.src === "mono") return e.mono === false ? "" : base + ".mono.png";
        if (e.wide && px < root.wideUnderPx) return base + ".mono.png";
        return base + ".png";
    }

    function want(sym, priority, opts) {
        if (!root.fetching || !sym) return;
        const key = root.slug(sym);
        const e = root._index[key];
        const settled = e && e.src && e.src !== "mono"
            && !(e.src === "none" && Date.now() - (e.bakedAt || 0) > root.retryNoneMs);
        if (settled) return;
        const o = opts || {};
        let q = root._queue.slice();
        // The monogram first: the cheap half, ahead of every fetch.
        if (!e && root._inFlightMono.indexOf(key) < 0 && !q.some(function (j) { return j.key === key && j.mono; })) {
            const monos = q.filter(function (j) { return j.mono; });
            const rest = q.filter(function (j) { return !j.mono; });
            q = monos.concat([{ key: key, sym: sym, opts: o, mono: true }], rest);
        }
        const queued = q.some(function (j) { return j.key === key && !j.mono; });
        // A repeat without priority leaves a queued job where it is: the
        // service asks for every row on every recompute, and moving the job
        // to the back each time starved the first ones.
        if (root._inFlight !== key && !(queued && !priority)
                && Date.now() - (root._failedAt[key] || 0) >= root.retryFailMs) {
            const full = { key: key, sym: sym, opts: o, mono: false };
            q = q.filter(function (j) { return j.key !== key || j.mono; });
            const nMono = q.filter(function (j) { return j.mono; }).length;
            if (priority) q.splice(nMono, 0, full);
            else q.push(full);
        }
        root._queue = q;
        root._next();
    }

    // ---- Private ---------------------------------------------------------------
    property var _index: ({})
    property var _queue: []
    property string _inFlight: ""
    property var _failedAt: ({})
    property var _inFlightMono: []

    FileView {
        id: indexView
        path: root.dir ? root.dir + "/index.json" : ""
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    Process {
        id: proc
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Connections {
        target: proc
        function onExited(code) {
            if (code !== 0 && code !== 3 && root._inFlight) root._failedAt[root._inFlight] = Date.now();
            root._inFlight = "";
            root._inFlightMono = [];
            root._readIndex(true);
            Qt.callLater(root._next);
        }
    }

    Component.onCompleted: root._readIndex(false)

    function _readIndex(reload) {
        if (!root.dir) return;
        if (reload) indexView.reload();
        let o = {};
        try { o = JSON.parse(indexView.text() || "{}"); } catch (x) { o = {}; }
        root._index = (o && typeof o === "object" && !Array.isArray(o)) ? o : {};
        root.serial++;
    }

    function _next() {
        if (proc.running || root._queue.length === 0) return;
        const q = root._queue.slice();
        if (q[0].mono) {
            // Every queued monogram in ONE run: they bake in parallel, and
            // the interpreter starts once.
            const monos = q.filter(function (j) { return j.mono; });
            root._queue = q.filter(function (j) { return !j.mono; });
            root._inFlightMono = monos.map(function (j) { return j.key; });
            proc.command = ["setpriv", "--pdeathsig", "TERM", "--", root.python, root.tool,
                            monos.map(function (j) { return j.sym; }).join(","), root.dir, "--mono-only"];
            proc.running = true;
            return;
        }
        const job = q.shift();
        root._queue = q;
        root._inFlight = job.key;
        const cmd = ["setpriv", "--pdeathsig", "TERM", "--", root.python, root.tool, job.sym, root.dir];
        if (job.opts.isin) cmd.push("--isin", job.opts.isin);
        if (job.opts.image) cmd.push("--image", String(job.opts.image).replace(/^file:\/\//, ""));
        if (job.opts.monogram) cmd.push("--monogram", job.opts.monogram);
        proc.command = cmd;
        proc.running = true;
    }
}
