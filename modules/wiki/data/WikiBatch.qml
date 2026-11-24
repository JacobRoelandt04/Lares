pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// WikiBatch.qml -- the driver of `wiki.py batch --tab T --n N [--resume]`: the
// batch that processes a pool's worth of new entries (30 by default), one
// notification, no more than one at a time.
//
//   start(tab, n, payload)       payload = { plan: [...], recent: [titles], n }, the
//                                 JSON the tool reads on stdin (the service builds
//                                 it from Interest.planBatch). Runs at once, or is
//                                 QUEUED when a batch is running (one per tab, the
//                                 newest wins; the GPU is one).
//   resumeInterrupted(pid, recent)   at shell start: a batch/<tab>.progress.json that
//                                 says `running` with no live process behind it
//                                 is relaunched with `--resume` (the tool reads the
//                                 plan from that file; stdin carries only `recent`).
//                                 `pid` is the one state.json remembers.
//   cancel()
//
//   status  { running, tab, done, total, blocked, lastError,       (CONTRACT.md `batch`)
//             ok, skipped, failed, generated, stage, title, resumed, offline }
//
// The runner is the WikiTool's (one Process, `setpriv --pdeathsig`, stdin EOF,
// NDJSON re-split); this file is the state machine on top of it and the two
// progress files' reader. Each progress file has its own FileView with a static
// path -- a FileView is never repointed (CLAUDE.md) -- read at completion and
// re-read with reload().
//
// `done` counts every settled item (an entry written, a skip, a failure), so
// "12 / 30" is the number of the plan that has been dealt with; a resumed run
// starts from what the previous one finished (n - todo).
// =============================================================================
Item {
    id: root

    property var tool: null
    property string stateDir: ""
    property int defaultN: 30

    readonly property var status: root._status
    readonly property bool running: root._status.running

    signal itemDone(string tab, var row)
    signal progressed()
    signal finished(string tab, var result)

    function start(tab, n, payload) {
        if (!root.tool) return false;
        const job = { tab: tab, n: n, payload: payload, resume: false };
        if (root._status.running) {
            root._queue = root._queue.filter(function (q) { return q.tab !== tab; }).concat([job]);
            return false;
        }
        root._run(job);
        return true;
    }

    function cancel() {
        root._queue = [];
        if (root.tool) root.tool.cancelBatch();
    }

    // -> the tabs a resume was started for (asynchronous: see _alive)
    function resumeInterrupted(pid, recent) {
        const want = [];
        for (const tab of ["discover", "deepen"]) {
            const p = root._progress(tab);
            if (p && p.running === true) want.push({ tab: tab, n: p.n || (p.plan ? p.plan.length : root.defaultN) });
        }
        if (want.length === 0) return want;
        root._resumeWant = want;
        root._resumeRecent = recent || [];
        if (pid > 0) {
            aliveProc.command = ["bash", "-c",
                '[ -r "/proc/$1/cmdline" ] && tr "\\0" " " < "/proc/$1/cmdline" | grep -q " batch "', "bash", String(pid)];
            aliveProc.running = true;
        } else {
            root._resumeNow();
        }
        return want;
    }

    // ---- private ---------------------------------------------------------------------
    property var _status: root._idle("", "")
    property var _queue: []
    property var _resumeWant: []
    property var _resumeRecent: []
    property var _end: null              // the tool's `end` event, until the process exits

    function _idle(tab, err) {
        return { running: false, tab: tab || null, done: 0, total: 0, blocked: false, lastError: err || "",
                 ok: 0, skipped: 0, failed: 0, generated: 0, stage: "", title: "", resumed: false, offline: false };
    }

    function _set(patch) {
        root._status = Object.assign({}, root._status, patch);
        root.progressed();
    }

    function _run(job) {
        root._end = null;
        root._status = Object.assign(root._idle(job.tab, ""), { running: true, total: job.n, resumed: job.resume });
        const stdin = JSON.stringify(job.payload || {});
        root.tool.batch(job.tab, job.n, job.resume, stdin);
        root.progressed();
    }

    function _resumeNow() {
        for (let i = 0; i < root._resumeWant.length; i++) {
            const w = root._resumeWant[i];
            const job = { tab: w.tab, n: w.n, payload: { recent: root._resumeRecent, n: w.n }, resume: true };
            if (root._status.running) root._queue = root._queue.concat([job]);
            else root._run(job);
        }
        root._resumeWant = [];
    }

    // The file as it was when the shell started (the view's first, blocking
    // load: a reload() would land later than the text() that follows it).
    function _progress(tab) {
        const v = tab === "discover" ? progDiscover : progDeepen;
        let o = null;
        try { o = JSON.parse(v.text() || "null"); } catch (e) { o = null; }
        return o && typeof o === "object" ? o : null;
    }

    function _onEvent(tab, ev) {
        const s = root._status;
        if (ev.ev === "start") {
            const n = typeof ev.n === "number" ? ev.n : s.total;
            const todo = typeof ev.todo === "number" ? ev.todo : n;
            root._set({ total: n, done: Math.max(0, n - todo), resumed: ev.resumed === true });
        } else if (ev.ev === "item") {
            root._set({ stage: String(ev.stage || ""), title: String(ev.title || "") });
        } else if (ev.ev === "done") {
            root._set({ done: s.done + 1, ok: s.ok + 1, generated: s.generated + (ev.generated === true ? 1 : 0), stage: "", title: "" });
            root.itemDone(tab, ev.row || null);
        } else if (ev.ev === "skip") {
            root._set({ done: s.done + 1, skipped: s.skipped + 1 });
        } else if (ev.ev === "fail") {
            root._set({ done: s.done + 1, failed: s.failed + 1, lastError: String(ev.reason || "") });
        } else if (ev.ev === "blocked") {
            root._set({ blocked: true, lastError: String(ev.reason || "blocked") });
        } else if (ev.ev === "end") {
            root._end = { ok: ev.ok | 0, skipped: ev.skipped | 0, failed: ev.failed | 0,
                          jev: ev.jev && typeof ev.jev === "object" ? ev.jev : null };
        }
    }

    function _onFinished(tab, code, error) {
        const s = root._status;
        const end = root._end;
        root._end = null;
        const result = {
            tab: tab, code: code,
            ok: end ? end.ok : s.ok, skipped: end ? end.skipped : s.skipped, failed: end ? end.failed : s.failed,
            generated: s.generated, blocked: s.blocked || code === 3, offline: code === 4, jev: end ? end.jev : null,
            error: s.lastError || (code !== 0 && !end ? (error || "exited " + code) : "")
        };
        root._status = Object.assign({}, s, { running: false, stage: "", title: "", blocked: result.blocked,
                                              offline: result.offline, lastError: result.error,
                                              ok: result.ok, skipped: result.skipped, failed: result.failed });
        root.progressed();
        root.finished(tab, result);
        if (root._queue.length > 0) {
            const next = root._queue[0];
            root._queue = root._queue.slice(1);
            root._run(next);
        }
    }

    Connections {
        target: root.tool
        ignoreUnknownSignals: true
        function onBatchEvent(tab, ev) { root._onEvent(tab, ev); }
        function onBatchFinished(tab, code, error) { root._onFinished(tab, code, error); }
    }

    FileView {
        id: progDiscover
        path: root.stateDir ? root.stateDir + "/batch/discover.progress.json" : ""
        blockLoading: true
        printErrors: false
        watchChanges: false
    }
    FileView {
        id: progDeepen
        path: root.stateDir ? root.stateDir + "/batch/deepen.progress.json" : ""
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    // Is the process state.json remembers still a batch? Exit 0 = yes: nothing is
    // relaunched (the tool's flock would refuse it anyway).
    Process {
        id: aliveProc
        running: false
    }
    Connections {
        target: aliveProc
        function onExited(exitCode, exitStatus) {
            if (exitCode === 0) {
                root._resumeWant = [];
                root._set({ lastError: "a batch from before the reload is still running" });
            } else {
                root._resumeNow();
            }
        }
    }
}
