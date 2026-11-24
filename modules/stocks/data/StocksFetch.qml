pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// StocksFetch.qml -- one fetch LANE: a queue drained by ONE curl Process.
//
//   get(key, url, cb, front)   cb(error, text); error "" on success, "429" when
//                              the server rate-limits, else "curl exit N: ..."
//   cancel()                   drops the queue and whatever is in flight: a
//                              generation counter makes a late exit a no-op
//
// A request for a key already queued or in flight is not sent again; its
// callback joins the one that is (dedup). `front` puts it at the head (the
// detail and the search go before background work on the same lane).
//
// curl: `setpriv --pdeathsig TERM -- curl -q -sS -f -L --compressed
// --max-time 20 -A Mozilla/5.0` -- the browser-ish agent because Yahoo
// answers curl's own with 429 (measured), -f so an HTTP error is exit 22 with
// the code in stderr, pdeathsig so a curl never outlives the shell.
// =============================================================================
Item {
    id: root

    property string curl: "curl"
    readonly property bool busy: root._cur !== null || root._queue.length > 0
    signal rateLimited(string url)

    function get(key, url, cb, front) {
        const w = root._waiters[key];
        if (w) {
            w.push(cb);
            // someone now waits for what was background work: it goes first
            const at = front ? root._queue.findIndex(j => j.key === key) : -1;
            if (at > 0)
                root._queue.unshift(root._queue.splice(at, 1)[0]);
            return;
        }
        root._waiters[key] = [cb];
        const job = { key: key, url: url };
        if (front) root._queue.unshift(job);
        else root._queue.push(job);
        root._next();
    }

    function cancel() {
        root._gen++;
        root._queue = [];
        root._waiters = ({});
        root._cur = null;
        if (proc.running) proc.running = false;
    }

    // ---- Private ---------------------------------------------------------------
    property int _gen: 0
    property var _queue: []
    property var _waiters: ({})
    property var _cur: null

    Process {
        id: proc
        running: false
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
    }
    Connections {
        target: proc
        function onExited(code) { root._done(code); }
    }

    function _next() {
        if (root._cur !== null || proc.running || root._queue.length === 0) return;
        const job = root._queue.shift();
        job.gen = root._gen;
        root._cur = job;
        proc.command = ["setpriv", "--pdeathsig", "TERM", "--", root.curl, "-q", "-sS", "-f", "-L",
                        "--compressed", "--max-time", "20", "-A", "Mozilla/5.0", job.url];
        proc.running = true;
    }

    function _done(code) {
        const job = root._cur;
        root._cur = null;
        if (!job || job.gen !== root._gen) { Qt.callLater(root._next); return; }
        const e = String(err.text || "");
        let error = "";
        if (code !== 0) {
            if (code === 22 && /\b429\b/.test(e)) error = "429";
            else error = "curl exit " + code + (e ? ": " + e.trim().split("\n")[0] : "");
        }
        const text = code === 0 ? String(out.text || "") : "";
        const cbs = root._waiters[job.key] || [];
        delete root._waiters[job.key];
        if (error === "429") root.rateLimited(job.url);
        for (let i = 0; i < cbs.length; i++) {
            try { cbs[i](error, text); } catch (x) { console.log("StocksFetch: callback threw: " + x); }
        }
        Qt.callLater(root._next);
    }
}
