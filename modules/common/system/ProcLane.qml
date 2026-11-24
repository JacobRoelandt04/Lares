pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// ProcLane.qml -- ONE lane of short-lived child processes: a queue drained one process at a
// time, each with a watchdog (shared: modules/common/system). Silicon's busctl calls, its helper calls and its reboot, the DRM
// watcher's scans and the DDC client's calls go through
// lanes, so "one Process at a time" is a property of the type, not a habit of its callers.
//
//   run(argv, cb, front)   cb({ code, out, err, timedOut, argv }); `front` puts the job at the head
//   cancel()               drops the queue and abandons the job in flight (its callback is NOT
//                          called: a generation counter makes a late exit a no-op)
//   busy / queued          what is running / waiting
//   timeoutMs              the watchdog; 0 = none
//
// A FRESH Process object per job, never a reused one: an abandoned job (the watchdog fired) may
// belong to a child this shell cannot kill -- pkexec is setuid root, so a SIGTERM from the user
// gets EPERM -- and a Process destroyed while its child still runs would take the whole shell
// down with it. The object is kept until the child's exit, destroyed then, and the next job
// starts at once. A start that fails (no such binary: Quickshell warns, and never reports an
// exit) is only ever seen by the watchdog; callers that know a binary may be missing check
// for it first (HelperClient does).
//
// `stdin` is closed (never enabled): nothing here reads standard input.
// =============================================================================
Item {
    id: root

    property int timeoutMs: 10000
    readonly property bool busy: root._cur !== null
    readonly property int queued: root._queue.length

    function run(argv, cb, front) {
        const job = { argv: argv, cb: cb, gen: root._gen, obj: null, done: false };
        if (front)
            root._queue.unshift(job);
        else
            root._queue.push(job);
        root._touchQueue();
        Qt.callLater(root._next);
    }

    function cancel() {
        root._gen++;
        root._queue = [];
        root._cur = null;
        watchdog.stop();
    }

    // ---- Private ---------------------------------------------------------------
    property int _gen: 0
    property var _queue: []
    property var _cur: null
    function _touchQueue() { root._queue = root._queue.slice(); }

    Component {
        id: jobComp
        Item {
            id: ji
            property var argv: []
            property var finish: null
            readonly property alias proc: p
            Process {
                id: p
                command: ji.argv
                running: false
                stdout: StdioCollector { id: o }
                stderr: StdioCollector { id: e }
            }
            Connections {
                target: p
                function onExited(code) {
                    if (ji.finish)
                        ji.finish(code, String(o.text || ""), String(e.text || ""));
                    ji.destroy();
                }
            }
        }
    }

    function _next() {
        if (root._cur !== null || root._queue.length === 0)
            return;
        const job = root._queue.shift();
        root._touchQueue();
        if (job.gen !== root._gen) {
            Qt.callLater(root._next);
            return;
        }
        root._cur = job;
        job.obj = jobComp.createObject(root, {
            argv: job.argv,
            finish: function (code, out, err) { root._exited(job, code, out, err); }
        });
        job.obj.proc.running = true;
        if (root.timeoutMs > 0)
            watchdog.restart();
    }

    function _deliver(job, result) {
        if (job.done)
            return;
        job.done = true;
        if (root._cur === job) {
            root._cur = null;
            watchdog.stop();
        }
        if (job.gen === root._gen && job.cb) {
            try {
                job.cb(result);
            } catch (x) {
                console.warn("ProcLane: a callback threw: " + x);
            }
        }
        Qt.callLater(root._next);
    }

    function _exited(job, code, out, err) {
        root._deliver(job, { code: code, out: out, err: err, timedOut: false, argv: job.argv });
    }

    Timer {
        id: watchdog
        onTriggered: {
            const job = root._cur;
            if (!job)
                return;
            // Abandon: the caller hears of a failure now; the object lives on until the child's
            // own exit destroys it. A SIGTERM is tried (it works for a child of the user).
            if (job.obj && job.obj.proc.running)
                job.obj.proc.signal(15);
            root._deliver(job, { code: -1, out: "", err: "no answer in " + (root.timeoutMs / 1000) + " s", timedOut: true, argv: job.argv });
        }
        interval: root.timeoutMs
    }
}
