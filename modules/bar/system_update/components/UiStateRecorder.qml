pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// UiStateRecorder.qml
//
// Records what the UI BELIEVED, alongside what the terminal said.
//
// The raw transcript already tells us what yay did. What it cannot tell us is
// what the popup made of it — which step the rail was on, which packages it
// thought were downloading, whether a category was open. Every fault found in
// a real run has been a disagreement between those two, and finding
// them takes replaying by hand and guessing. Recording both sides makes the
// disagreement searchable.
//
// Snapshots are written on CHANGE, not on a clock: a run is mostly stillness
// punctuated by transitions, and sampling it at a fixed rate would bury the
// transitions in duplicates while costing power for the stillness. A slow
// heartbeat still fires during measurable steps so a stall is visible as a gap
// in progress rather than a gap in the record.
//
// Written as JSONL so it can be read with grep and aggregated by a script.
//
// ABORTS: the file opens with a header and is closed by a final record. A run
// killed with Ctrl-C takes the whole shell down with it, so no final record is
// written — and a log without one IS the abort marker. Nothing needs to
// survive the signal for that to work.
//
// SETTLING: a Connections handler runs the moment its signal fires, which is
// BEFORE the bindings that depend on the changed property have re-evaluated.
// Read at once, a `phase` record would show the popup's rawStep and promptKind as they
// were under the PREVIOUS phase, the rail one notch behind
// the phase it is reacting to, every single time. So every snapshot is
// queued to the end of the current event-loop turn (Qt.callLater), by which
// point the bindings have settled; reasons raised in the same turn share one
// record ("phase+step") rather than writing two of which the first would be
// half-stale anyway.
//
// ORDERING: records only ever go through one buffer, in call order, and the
// sink drains that buffer once mkdir has made the directory. The header is
// therefore written into the buffer synchronously from start(): written from
// mkdir's onExited, it would sit behind the first snapshots (the popup's step
// reset, the backend starting) and a log would open with two state records and
// have its `begin` at seq 2.
//
// OLDER HOSTS: every popup/parser read goes through _v(), which returns a
// fallback for a field the host does not have. A recorder that throws inside
// a signal handler loses that record and every later one, and a host running
// an older popup is exactly the case where a record is worth having.
// =============================================================================
Item {
    id: rec

    // ---- Wiring ----
    property var popup: null
    property var parser: null
    property var backend: null
    property var service: null

    property string runId: ""
    property string baseDir:
        (Quickshell.env("XDG_DATA_HOME")
         || (Quickshell.env("HOME") + "/.local/share"))
        + "/system-update-logs/runs"
    readonly property string runDir: rec.baseDir + "/" + rec.runId
    readonly property string statePath: rec.runDir + "/ui-state.jsonl"

    property bool recording: false
    property real _t0: 0
    property int _seq: 0

    // Heartbeat during steps that report progress, so a stall reads as a gap
    // in the numbers rather than an absence of records.
    property int heartbeatMs: 2000

    signal started(string dir)

    // =====================================================================
    //  Lifecycle
    // =====================================================================
    // `startedAtMs` is for a run this shell did not begin: a shell that
    // attached to a run already going has to carry the ORIGINAL start, or `t`
    // restarts at zero halfway through the file and the analyser reads the
    // whole run as two. The sink appends, so the records simply join what is
    // already there.
    function start(id, startedAtMs) {
        if (rec.recording) return;
        const resumed = startedAtMs !== undefined && startedAtMs > 0;
        rec.runId = id;
        rec._t0 = resumed ? startedAtMs : Date.now();
        rec._seq = 0;
        rec._pendingWhy = "";
        rec._lastSteps = "";
        rec.recording = true;
        // Header first, into the buffer, before anything can queue a
        // snapshot (see ORDERING at the top). The sink flushes it once the
        // directory exists.
        rec._write({kind: "begin", runId: rec.runId, resumed: resumed,
                    startedAt: new Date(rec._t0).toISOString()});
        _mkdir.command = ["mkdir", "-p", rec.runDir];
        _mkdir.running = true;
        // The sink opens once the directory exists (mkdir's onExited).
        rec.started(rec.runDir);
    }

    // `outcome` is one of: completed, failed, stopped.
    // An aborted run never reaches here — see the note at the top.
    function finish(outcome) {
        if (!rec.recording) return;
        // A snapshot deferred a moment ago has to land before the marker; a
        // moment later the sink is closed and it lands nowhere.
        rec._snapshotNow();
        rec._write({kind: "end", outcome: outcome,
                    exitCode: rec._v(rec.backend, "exitCode", null),
                    durationMs: Date.now() - rec._t0});
        rec._closeSink();
        rec.recording = false;
    }

    Process {
        id: _mkdir
        running: false
        onExited: {
            if (!rec.recording) return;
            rec._openSink();
            rec._collectMeta();
        }
    }

    // Metadata the transcript cannot carry: what this machine was, so a log
    // read weeks later still means something.
    Process {
        id: _meta
        running: false
        stdout: StdioCollector { id: _metaOut }
        onExited: {
            if (!rec.recording) return;
            rec._write({kind: "meta", text: _metaOut.text});
            rec._snapshot("start");
        }
    }

    function _collectMeta() {
        _meta.command = ["bash", "-lc",
            "echo kernel=$(uname -r); echo pacman=$(pacman -V 2>/dev/null | "
            + "grep -oE 'v[0-9.]+' | head -1); echo yay=$(yay --version 2>/dev/null | "
            + "head -1); echo mirrors=$(grep -c '^Server' /etc/pacman.d/mirrorlist "
            + "2>/dev/null); echo parallel=$(grep -oE '^ParallelDownloads *= *[0-9]+' "
            + "/etc/pacman.conf 2>/dev/null)"];
        _meta.running = true;
    }

    // =====================================================================
    //  Snapshots
    // =====================================================================
    // A read that never throws: `fallback` for a missing object or a field
    // this host does not have (see OLDER HOSTS at the top).
    function _v(obj, key, fallback) {
        if (!obj) return fallback;
        const x = obj[key];
        return x === undefined ? fallback : x;
    }

    function _catSnapshot() {
        const out = [];
        if (!rec.popup || !rec.popup._forEachSection) return out;
        rec.popup._forEachSection(sec => {
            const key = rec._v(sec, "categoryKey", "");
            if (!key || key.length === 0) return;
            out.push({key: key, rows: rec._v(sec, "rowModelRefCount", 0),
                      done: rec._v(sec, "stepDone", 0),
                      total: rec._v(sec, "stepTotal", 0),
                      failed: rec._v(sec, "stepFailed", 0),
                      frac: Math.round(rec._v(sec, "stepFraction", 0) * 1000) / 1000,
                      open: rec._v(sec, "expanded", false),
                      hi: rec._v(sec, "highlighted", false)});
        });
        return out;
    }

    function _pkgStates() {
        const c = ({});
        const m = rec._v(rec.parser, "packages", null);
        if (!m || m.count === undefined) return c;
        for (let i = 0; i < m.count; i++) {
            const st = rec._v(m.get(i), "state", "?") || "?";
            c[st] = (c[st] || 0) + 1;
        }
        return c;
    }

    // Packages that claim to be mid-download, with how far each has got. This
    // is the field that exposed pacman's truncated filenames: rows frozen at a
    // percentage while the terminal showed them moving.
    function _activeDownloads() {
        const out = [];
        const m = rec._v(rec.parser, "packages", null);
        if (!m || m.count === undefined) return out;
        for (let i = 0; i < m.count && out.length < 24; i++) {
            const p = m.get(i);
            if (rec._v(p, "state", "") !== "downloading") continue;
            out.push({n: rec._v(p, "name", ""), pct: rec._v(p, "dlPct", -1),
                      rate: rec._v(p, "dlRate", "")});
        }
        return out;
    }

    // The rail's notches as the popup currently lays them out. The array is
    // rebuilt whenever its binding re-evaluates, so callers that want "did it
    // change" compare the joined keys (see _stepKeys / on_PhaseStepsChanged).
    function _stepKeys() {
        const out = [];
        const ps = rec._v(rec.popup, "_phaseSteps", null);
        if (!ps || ps.length === undefined) return out;
        for (let i = 0; i < ps.length; i++) out.push(rec._v(ps[i], "key", ""));
        return out;
    }

    // Everything the UI is claiming, at this instant. The parser's counters
    // and the popup's derived view of them sit side by side on purpose: the
    // disagreements between the two are what the log is for.
    //
    // `prompt` is the PARSER's kind; `promptKind` is the popup's, which adds
    // the backend-tail backstop for a prompt the parser closed too early.
    // Older fields keep their names so older logs still parse.
    function _state(why) {
        const p = rec.parser;
        const u = rec.popup;
        const dl = p ? {done: rec._v(p, "downloadsDone", 0), total: rec._v(p, "downloadsTotal", 0),
                        pct: rec._v(p, "downloadPct", -1), rate: rec._v(p, "downloadRate", ""),
                        eta: rec._v(p, "downloadEta", ""), cur: rec._v(p, "currentDownloading", "")}
                      : null;
        // Byte totals only where the parser has grown them. The done side
        // has no counter of its own: it is the "Total (n/m)" row's size
        // string, which the parser's own parseSize() turns back into bytes.
        if (dl && p.totalDownloadBytes !== undefined) {
            dl.bytesTotal = p.totalDownloadBytes;
            const soFar = rec._v(p, "downloadSoFar", "");
            dl.bytesDone = (soFar && typeof p.parseSize === "function")
                ? p.parseSize(soFar) : null;
        }
        const inst = p ? {done: rec._v(p, "installsDone", 0), total: rec._v(p, "installsTotal", 0),
                          cur: rec._v(p, "currentInstalling", "")}
                       : null;
        if (inst && p.installsStarted !== undefined) inst.started = p.installsStarted;
        return {
            kind: "state", why: why,
            phase: rec._v(p, "phase", ""), sub: rec._v(p, "subPhase", ""),
            step: rec._v(u, "_currentStep", ""), rawStep: rec._v(u, "_rawStep", ""),
            stepProgress: u ? Math.round(rec._v(u, "_stepProgress", -1) * 1000) / 1000 : -1,
            steps: rec._stepKeys(),
            labels: {title: rec._v(u, "_phaseLabel", ""), sub: rec._v(u, "_subLabel", ""),
                     op: rec._v(u, "_currentOperation", ""), prog: rec._v(u, "_progressLabel", "")},
            prompt: rec._v(p, "currentPromptKind", ""),
            promptKind: rec._v(u, "_promptKind", ""),
            promptCats: rec._v(u, "_promptCategories", []),
            mode: rec._v(u, "verbosityMode", ""),
            dl: dl,
            inst: inst,
            hooks: p ? {done: rec._v(p, "hooksDone", 0), total: rec._v(p, "hooksTotal", 0),
                        started: rec._v(p, "hooksStarted", 0),
                        dkms: rec._v(p, "currentDkmsOp", ""),
                        initramfs: rec._v(p, "currentInitramfsKernel", ""),
                        initramfsHook: rec._v(p, "currentInitramfsHook", ""),
                        cur: rec._v(p, "currentHook", "")} : null,
            aur: p ? {done: rec._v(p, "aurBuildsDone", 0), total: rec._v(p, "aurBuildsTotal", 0),
                      cur: rec._v(p, "currentAurBuild", ""),
                      step: rec._v(p, "currentAurBuildStep", "")} : null,
            errors: rec._v(p, "errorCount", 0),
            // The run's kind and the snapshot hook's state, what the Snapshot notch and the card read.
            kind: rec._v(p, "runKind", "update"),
            snap: p ? {state: rec._v(p, "snapshotState", ""), progress: Math.round(rec._v(p, "snapshotProgress", -1) * 1000) / 1000,
                       code: rec._v(p, "snapshotCode", ""), short: rec._v(p, "snapshotShort", ""),
                       text: rec._v(p, "snapshotText", ""), notch: rec._v(u, "_hasSnapshotWork", false)} : null,
            pkgs: rec._pkgStates(),
            active: rec._activeDownloads(),
            cats: rec._catSnapshot()
        };
    }

    // Deferred to the end of the event-loop turn (see SETTLING at the top).
    // The first reason of a turn owns the record; later ones in the same
    // turn are appended with '+', once each.
    property string _pendingWhy: ""

    function _snapshot(why) {
        if (!rec.recording) return;
        if (rec._pendingWhy.length === 0) {
            rec._pendingWhy = why;
            Qt.callLater(rec._snapshotNow);
        } else if (("+" + rec._pendingWhy + "+").indexOf("+" + why + "+") < 0) {
            rec._pendingWhy += "+" + why;
        }
    }
    function _snapshotNow() {
        const why = rec._pendingWhy;
        rec._pendingWhy = "";
        if (why.length === 0 || !rec.recording) return;
        rec._write(rec._state(why));
    }

    // Transitions worth a record. Anything that changes what the UI is
    // claiming, plus the heartbeat for the rest.
    Connections {
        target: rec.recording && rec.parser ? rec.parser : null
        ignoreUnknownSignals: true
        function onPhaseChanged() { rec._snapshot("phase") }
        function onSubPhaseChanged() { rec._snapshot("subphase") }
        function onAwaitingUserInputChanged() { rec._snapshot("prompt") }
        function onErrorCountChanged() { rec._snapshot("error") }
        function onSnapshotStateChanged() { rec._snapshot("snapshot") }
    }
    // `_phaseSteps` is rebuilt on every re-evaluation, most of which leave
    // the notches as they were; only a change in the keys is a record.
    property string _lastSteps: ""
    Connections {
        target: rec.recording && rec.popup ? rec.popup : null
        ignoreUnknownSignals: true
        function on_CurrentStepChanged() { rec._snapshot("step") }
        function on_PromptKindChanged() { rec._snapshot("promptKind") }
        function on_PhaseStepsChanged() {
            const keys = rec._stepKeys().join(",");
            if (keys === rec._lastSteps) return;
            rec._lastSteps = keys;
            rec._snapshot("steps");
        }
        function on_SectionExpandedChanged() { rec._snapshot("expand") }
        function onVerbosityModeChanged() { rec._snapshot("view") }
    }
    Connections {
        target: rec.recording && rec.backend ? rec.backend : null
        ignoreUnknownSignals: true
        function onRunningChanged() {
            if (rec._v(rec.backend, "running", false)) rec._snapshot("backend-start");
        }
        // TerminalBackend sets running=false BEFORE exitCode, so runningChanged
        // always sees the -1 reset value and every run would be "failed exit=-1".
        // `exited` is emitted after the code is stored, so classify there.
        // A -1 with the parser having seen the run finish clean is a child
        // whose exit code never reached us, not a failure.
        function onExited(code, status) {
            rec._snapshot("backend-exit");
            const pp = rec.parser;
            const phase = rec._v(pp, "phase", "");
            const hooksTotal = rec._v(pp, "hooksTotal", 0);
            const finishedClean = pp && rec._v(pp, "errorCount", 0) === 0
                && (phase === "COMPLETE" || phase === "DONE"
                    || (hooksTotal > 0 && rec._v(pp, "hooksDone", 0) >= hooksTotal - 1));
            rec.finish(code === 0 ? "completed"
                     : (code === -1 && finishedClean) ? "completed"
                     : code === -1 ? "unknown" : "failed");
        }
    }
    Timer {
        interval: rec.heartbeatMs
        repeat: true
        // While the child runs, not only while a step reports progress: the
        // post-transaction hooks (DKMS builds, mkinitcpio) report none and
        // are the longest and most failure-prone stretch of a run -- a recorded run can
        // have 217 seconds of them with zero records.
        running: rec.recording && !!rec.backend && rec._v(rec.backend, "running", false)
        onTriggered: rec._snapshot("tick")
    }

    // =====================================================================
    //  Writer
    //
    // ONE long-lived `cat` with its stdin held open for the whole run, rather
    // than a process per flush. Spawning per flush needs a busy-guard, and
    // any collision leaves records queued in memory that are then lost when the
    // shell exits, the final marker included, which makes a completed run look aborted.
    // =====================================================================
    property string _pending: ""
    property bool _open: false

    function _openSink() {
        if (rec._open) return;
        _writeProc.command = ["sh", "-c",
            "cat >> '" + rec.statePath.replace(/'/g, "'\\''") + "'"];
        _writeProc.running = true;
        rec._open = true;
        // Whatever queued while the directory was being made -- the header
        // first, by construction -- goes out now, in order.
        rec._flush();
    }
    function _closeSink() {
        if (!rec._open) return;
        rec._flush();
        _writeProc.stdinEnabled = false;   // cat sees EOF and exits
        rec._open = false;
    }

    function _write(obj) {
        obj.seq = rec._seq++;
        obj.t = Date.now() - rec._t0;
        rec._pending += JSON.stringify(obj) + "\n";
        // Written straight through: a run can be killed at any moment, and a
        // record still sitting in a buffer is a record that never existed.
        rec._flush();
    }
    function _flush() {
        if (rec._pending.length === 0 || !rec._open) return;
        _writeProc.write(rec._pending);
        rec._pending = "";
    }

    Process {
        id: _writeProc
        running: false
        stdinEnabled: true
    }
}
