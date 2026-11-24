pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// ActionRunner.qml -- the bridge tool's one-shots: `lares-bridge <verb> <args>` prints ONE JSON line (docs/contracts/bridge.md
// section 4), and this is the queue that asks and reads it.
//
//   run(lane, argv, cb, opts)   argv is what follows the program (["mirror", "kdc:abc", "--mode", "desktop"]); cb gets
//                               { ok, reason, hint, answer, code, timedOut, argv }:
//                                 ok       the tool's own `ok` (true only for an answer that says so)
//                                 reason   the tool's reason; or, when it gave none, a stated failure in plain words:
//                                          "the tool is missing", "timed out", "the tool's answer is not JSON",
//                                          or its last stderr line / "the tool failed (exit N)"
//                                 hint     the tool's hint ("" for a stated failure)
//                                 answer   the parsed object ({} when there was none)
//   lane                        one at a time PER LANE (the service uses the device's key; "" is the shared lane): a mirror and a
//                               ring for one phone never overlap, two phones' calls do
//   opts.timeoutMs              the watchdog (BridgeModel.timeoutOf); 0 = none
//   opts.stdin                  text written to the child's stdin, then EOF (a secret goes here, never in argv: `pin set`);
//                               it is not kept in the job's record, the result or anywhere else once written
//   timeoutOverrideMs           a probe's seam: when > 0 it is every job's deadline
//
// A FRESH Process per job (CLAUDE.md: ProcLane's reasoning): made when the job starts, destroyed at the child's exit, so a runner
// at rest holds no Process at all. The program is `launcher + [python, "-u", toolPath] + argv`; a tool that is not there answers
// "the tool is missing" without starting anything (`toolPresent`, which the service binds from a file check: a Process whose
// program does not exist emits neither started nor exited). Only `opts.stdin` is ever written to a child; every other one-shot
// reads nothing.
//
// A watchdog that fires sends TERM to the child and answers `timed out` at once; the job's object lives until the child's own
// exit (a child this shell cannot kill must not be destroyed under a running Process).
// =============================================================================
Item {
    id: root

    property string toolPath: ""
    property string python: "python3"
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]
    property bool toolPresent: true
    property int timeoutOverrideMs: 0

    // calls waiting or running, for the probes and the service's idle checks
    readonly property int pending: root._pending

    function run(lane: string, argv: var, cb: var, opts: var): void {
        const o = opts || {};
        const job = { lane: String(lane || ""), argv: argv.slice(), cb: cb, timeoutMs: root.timeoutOverrideMs > 0 ? root.timeoutOverrideMs : Number(o.timeoutMs || 0), done: false, obj: null,
            stdin: typeof o.stdin === "string" ? o.stdin : null };
        root._pending++;
        if (!root.toolPresent) {
            Qt.callLater(() => root._deliver(job, { ok: false, reason: "the tool is missing", hint: "", answer: ({}), code: -1, timedOut: false }));
            return;
        }
        const q = root._lane(job.lane);
        q.queue.push(job);
        Qt.callLater(() => root._next(job.lane));
    }

    // ---- private ---------------------------------------------------------------------------------------------------
    property int _pending: 0
    property var _lanes: ({})

    function _lane(name: string): var {
        if (!root._lanes[name])
            root._lanes[name] = { cur: null, queue: [] };
        return root._lanes[name];
    }

    Component {
        id: jobComp
        Item {
            id: ji
            property var argv: []
            property int timeoutMs: 0
            property var finish: null
            // what to write at the start, then EOF (CLAUDE.md, Process: stdinEnabled true before running, written in onStarted,
            // then false); cleared once written
            property var input: null
            property bool _ended: false
            property bool _killed: false
            readonly property alias proc: p
            Process {
                id: p
                command: ji.argv
                stdout: StdioCollector {
                    id: o
                }
                stderr: StdioCollector {
                    id: e
                }
            }
            Connections {
                target: p
                function onStarted() {
                    if (ji.input === null)
                        return;
                    p.write(ji.input);
                    ji.input = null;
                    p.stdinEnabled = false;
                }
                function onExited(code) {
                    ji._ended = true;
                    if (ji.finish)
                        ji.finish(code, String(o.text || ""), String(e.text || ""), false);
                    ji.destroy();
                }
            }
            Timer {
                id: dog
                interval: ji.timeoutMs
                onTriggered: {
                    if (ji._ended)
                        return;
                    ji._killed = true;
                    if (p.running)
                        p.signal(15);
                    if (ji.finish)
                        ji.finish(-1, "", "", true);
                }
            }
            function start(): void {
                p.stdinEnabled = ji.input !== null;
                p.running = true;
                if (ji.timeoutMs > 0)
                    dog.start();
            }
        }
    }

    function _next(name: string): void {
        const q = root._lane(name);
        if (q.cur !== null || q.queue.length === 0)
            return;
        const job = q.queue.shift();
        q.cur = job;
        const full = root.launcher.concat([root.python, "-u", root.toolPath]).concat(job.argv);
        job.obj = jobComp.createObject(root, {
            argv: full,
            timeoutMs: job.timeoutMs,
            input: job.stdin,
            finish: (code, out, err, timedOut) => root._finished(job, code, out, err, timedOut)
        });
        job.stdin = null;
        job.obj.start();
    }

    // The tool's answer: the last non-empty line of stdout, as JSON.
    function _answerOf(out: string): var {
        const lines = String(out).split("\n");
        for (let i = lines.length - 1; i >= 0; i--) {
            const t = lines[i].trim();
            if (t === "")
                continue;
            try {
                const o = JSON.parse(t);
                return o !== null && typeof o === "object" && !Array.isArray(o) ? o : null;
            } catch (e) {
                return null;
            }
        }
        return null;
    }

    function _finished(job: var, code: int, out: string, err: string, timedOut: bool): void {
        if (timedOut) {
            root._deliver(job, { ok: false, reason: "timed out", hint: "", answer: ({}), code: -1, timedOut: true });
            return;
        }
        const a = root._answerOf(out);
        if (a === null) {
            let reason = "the tool's answer is not JSON";
            if (String(out).trim() === "") {
                const last = String(err).trim().split("\n").filter(l => l.trim() !== "").pop();
                reason = last ? last.trim() : "the tool failed (exit " + code + ")";
            }
            root._deliver(job, { ok: false, reason: reason, hint: "", answer: ({}), code: code, timedOut: false });
            return;
        }
        const ok = a.ok === true;
        root._deliver(job, { ok: ok, reason: ok ? "" : (typeof a.reason === "string" && a.reason !== "" ? a.reason : "the tool failed (exit " + code + ")"),
            hint: typeof a.hint === "string" ? a.hint : "", answer: a, code: code, timedOut: false });
    }

    function _deliver(job: var, result: var): void {
        if (job.done)
            return;
        job.done = true;
        result.argv = job.argv;
        const q = root._lanes[job.lane];
        if (q && q.cur === job)
            q.cur = null;
        root._pending = Math.max(0, root._pending - 1);
        if (job.cb) {
            try {
                job.cb(result);
            } catch (x) {
                console.warn("ActionRunner: a callback threw: " + x);
            }
        }
        Qt.callLater(() => root._next(job.lane));
    }
}
