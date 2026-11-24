pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// AudioCalls.qml -- every child the audio popup runs goes through here, because a sound server can take a
// call and never answer (a locked USB DAC, WirePlumber in D state, `pactl` hanging). So:
//
//   EVERY CALL HAS A DEADLINE, TWICE. `timeout -k 1 <s>` ends a child that hangs (exit 124, 137 when it had to KILL). And a wall-clock backstop
//   stands behind it: a child stuck in the kernel survives SIGKILL and `timeout` waits for it for ever, so at deadline + 2.5 s the call is
//   ANSWERED as hung and the child ABANDONED. Wall clock, not a Timer's interval: offscreen a Timer's interval runs ~3x fast (CLAUDE.md).
//
//   ONE CHILD PER SLOT, NEVER A QUEUE BEHIND A HANG. A read on a busy slot returns false and starts nothing; the caller asks again when the
//   slot answers. An abandoned child keeps its slot until it really exits: a hung backend costs one process, not one per heartbeat, however
//   long it hangs. Writes run one at a time and coalesce by key: the newest ask for a target replaces the one waiting, and the replaced ask
//   is told so (code -3). A write on an abandoned slot is refused at once (code -1): the row says why, the control is not frozen.
//
//   NOTHING HERE BLOCKS THE GUI THREAD. A Process is asynchronous; no `waitFor`, and a child that hangs holds nothing but its slot.
//
// `machine` (AudioWorld) answers instead of a process: the mockup and the shell's mock mode run this same code and the same deadlines,
// and a fake hang is a callback that never comes.
//
// The codes a `done(code, stdout, stderr)` can see beyond a child's exit status: -1 hung (the backstop), -3 superseded, -4 refused (too many waiting).
// =============================================================================
Item {
    id: root

    property var machine: null
    property int deadlineMs: 3000
    // Ablations for a probe: the program that enforces the deadline.
    property string timeoutBin: "timeout"
    // The child's own deadline and the kill after it, in seconds; the backstop's grace on top.
    readonly property int killAfterS: 1
    property int backstopGraceMs: 2500
    readonly property int maxWaiting: 16

    // What a probe reads: children started, and children given up on.
    property int startedCount: 0
    property int abandonedCount: 0
    property int _abandoned: 0
    property int _busy: 0

    property var _queue: []                 // [{ key, argv, done, ms }]

    component Slot: QtObject {
        id: slot
        required property string name
        property var done: null
        property real t0: 0
        property real budget: 0
        property bool busy: false
        property bool abandoned: false
        property int gen: 0
        property int code: -1
        property int pending: 0
        property Process proc: Process {
            stdout: StdioCollector {
                id: out
                onStreamFinished: slot.finishOne()
            }
            stderr: StdioCollector {
                id: err
                onStreamFinished: slot.finishOne()
            }
            onExited: (code, status) => {
                slot.code = code;
                slot.finishOne();
            }
        }
        function start(argv: var, ms: int, cb: var): void {
            slot.done = cb;
            slot.busy = true;
            slot.abandoned = false;
            slot.t0 = Date.now();
            const s = Math.max(1, Math.ceil(ms / 1000));
            // A machine has no `timeout` in front of it: the backstop is its only deadline, and it is the call's own.
            slot.budget = root.machine ? ms : s * 1000 + root.killAfterS * 1000 + root.backstopGraceMs;
            slot.gen++;
            root._busy++;
            root.startedCount++;
            if (root.machine) {
                const g = slot.gen;
                root.machine.exec(argv, (c, o, e) => {
                    if (g === slot.gen)
                        slot.finish(c, o, e);
                });
                return;
            }
            slot.pending = 3;
            slot.proc.command = ["setpriv", "--pdeathsig", "TERM", "--", root.timeoutBin, "-k", String(root.killAfterS), String(s)].concat(argv);
            slot.proc.running = true;
        }
        function finishOne(): void {
            if (--slot.pending === 0)
                slot.finish(slot.code, out.text, err.text);
        }
        function finish(c: int, o: string, e: string): void {
            const cb = slot.abandoned ? null : slot.done;
            if (slot.abandoned)
                root._abandoned--;
            slot.abandoned = false;
            slot.busy = false;
            slot.done = null;
            root._busy--;
            if (cb)
                cb(c, o, e);
            if (slot.name === "write")
                root._pump();
        }
        function check(now: real): void {
            if (!slot.busy || slot.abandoned || now - slot.t0 < slot.budget)
                return;
            slot.abandoned = true;
            root._abandoned++;
            root.abandonedCount++;
            const cb = slot.done;
            slot.done = null;
            if (cb)
                cb(-1, "", "");
            if (slot.name === "write")
                root._failWaiting();
        }
    }

    readonly property var _slots: ({ pactl: s0, pw: s1, meta: s2, codec: s3, diag: s4, write: s5, tone: s6 })
    Slot { id: s0; name: "pactl" }
    Slot { id: s1; name: "pw" }
    Slot { id: s2; name: "meta" }
    Slot { id: s3; name: "codec" }
    Slot { id: s4; name: "diag" }
    Slot { id: s5; name: "write" }
    Slot { id: s6; name: "tone" }

    // The backstop runs only while a child is out: at rest this object wakes nothing.
    Timer {
        interval: 400
        repeat: true
        running: root._busy > 0
        onTriggered: {
            const now = Date.now();
            for (const k in root._slots)
                root._slots[k].check(now);
        }
    }

    function busy(slotName: string): bool {
        return root._slots[slotName].busy;
    }
    function abandoned(slotName: string): bool {
        return root._slots[slotName].abandoned;
    }

    // Starts `argv` in the named slot; false when the slot is occupied (nothing was started).
    function read(slotName: string, argv: var, done: var, ms: int): bool {
        const s = root._slots[slotName];
        if (s.busy)
            return false;
        s.start(argv, ms > 0 ? ms : root.deadlineMs, done);
        return true;
    }

    function write(key: string, argv: var, done: var, ms: int): void {
        const s = root._slots.write;
        if (s.abandoned) {
            done(-1, "", "");
            return;
        }
        if (!s.busy && root._queue.length === 0) {
            s.start(argv, ms > 0 ? ms : root.deadlineMs, done);
            return;
        }
        const q = root._queue.slice();
        for (let i = 0; i < q.length; i++)
            if (q[i].key === key) {
                const old = q[i].done;
                q[i] = { key: key, argv: argv, done: done, ms: ms };
                root._queue = q;
                old(-3, "", "");
                return;
            }
        if (q.length >= root.maxWaiting) {
            done(-4, "", "");
            return;
        }
        q.push({ key: key, argv: argv, done: done, ms: ms });
        root._queue = q;
    }

    function _pump(): void {
        if (root._queue.length === 0 || root._slots.write.busy)
            return;
        const q = root._queue.slice();
        const n = q.shift();
        root._queue = q;
        root._slots.write.start(n.argv, n.ms > 0 ? n.ms : root.deadlineMs, n.done);
    }

    function _failWaiting(): void {
        const q = root._queue;
        root._queue = [];
        for (let i = 0; i < q.length; i++)
            q[i].done(-1, "", "");
    }

    // The tone ends when a new one starts or the user stops it; the child's own deadline ends it otherwise.
    function stopTone(): void {
        const t = root._slots.tone;
        if (t.busy && !root.machine)
            t.proc.running = false;
        else if (t.busy && root.machine)
            root.machine.stopTone();
    }
}
