pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../scale"

// =============================================================================
// FrameJournal -- the shell's record of the frames it MISSED (perf pass, phase 1; docs/agent_added_files_and_folders/
// perf_pass/JOURNAL.md has the design and the numbers).
//
// Every window that draws mounts one FrameJournalHook (one line). The hook watches its window's own frame signals and, when a
// frame comes late WHILE THE WINDOW WAS RENDERING CONTINUOUSLY (not the first frame after a rest), records it here with what
// was going on: the popups and their phases, the theme crossfade, the island moves, the transitions of the last two seconds.
// This singleton keeps the records and writes them, in BATCHES and only when every window has been quiet for `quietMs`
// (never a write while something animates), as JSON lines to
//
//     $XDG_STATE_HOME/lares/perf/frame-journal.jsonl     (`path`; LARES_FRAME_JOURNAL_PATH overrides it)
//
// `capLines` to a file: a full journal is moved to frame-journal.1.jsonl (`rotatedPath`, the one before it goes) and starts again,
// so a day of use is kept. tools/dev/perf/frame_journal_report.py reads both, groups what they hold and ranks it.
//
// THE SWITCH. shell.jsonc `"debug": { "frameJournal": false }` turns it off (read through ShellScale.source, which ShellServices
// feeds with the parsed file, hot); it is on otherwise. LARES_FRAME_JOURNAL=0 / =1 in the environment wins over the file.
//
// THE COST. At rest nothing: the hooks are frame-signal handlers and a window at rest draws no frame; the flush is a single-shot
// timer started by a record or a run's start. While a window animates, two handlers per frame: ~25-50 us of the main thread in
// real frames (perf_pass/JOURNAL.md has the measurement and its parts); the capture, the context and the file are paid only when a
// frame was missed, and the file only at rest.
//
// The load figures on a line (`load`: /proc/loadavg, `psi`: /proc/pressure/cpu "some avg10") are read at the FLUSH, seconds
// after the miss: they say how busy the machine was around it, not at its millisecond.
//
//   record(entry)        a hook's record (an object; `sid` is added)
//   mark(label, timed)   a transition named by anyone (a module's own event, a probe): every hook notes it, and with `timed`
//                        times the first frame after it ("latency" when it came late)
//   flush()              write what is pending now (the quiet timer calls it; a probe may)
//   stats                { recorded, dropped, flushes, lines, marks, rotations }, mutated in place (an instrument)
// =============================================================================
Singleton {
    id: journal

    // ---- the switch -----------------------------------------------------------------------------------------------------------
    readonly property string _env: Quickshell.env("LARES_FRAME_JOURNAL") || ""
    readonly property var _debug: {
        const s = ShellScale.source;
        const d = s && typeof s === "object" ? s.debug : null;
        return d && typeof d === "object" && !Array.isArray(d) ? d : null;
    }
    readonly property bool enabled: journal._env === "0" ? false : journal._env === "1" ? true
        : !(journal._debug !== null && journal._debug.frameJournal === false)

    // ---- where and how much ---------------------------------------------------------------------------------------------------
    readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")
    readonly property string path: Quickshell.env("LARES_FRAME_JOURNAL_PATH") || (journal.stateHome + "/lares/perf/frame-journal.jsonl")
    // Lines per file: a full journal becomes frame-journal.1.jsonl (the one before it goes) and the journal starts again, so the
    // last capLines..2 x capLines lines are kept (about a day of use; the report reads both files).
    property int capLines: 1000
    readonly property string rotatedPath: journal.path.replace(/\.jsonl$/, "") + ".1.jsonl"
    // A window's summary line goes in at most this often (and at the first flush): the report's denominators, not a log. A run
    // of frames that starts when one is due arms a flush of the summaries alone, so a day without a miss still says how much
    // was drawn (LARES_FRAME_JOURNAL_SUMMARY_MS overrides the period: a probe's).
    property int summaryEveryMs: Number(Quickshell.env("LARES_FRAME_JOURNAL_SUMMARY_MS") || "600000")
    // A flush waits until no window has drawn for this long (a write is never paid inside an animation).
    property int quietMs: 2000
    // Records held before a flush at most (the oldest go first): a storm of misses cannot grow without bound.
    property int maxPending: 300
    readonly property double startedAt: journal._born
    // One shell's lines from the next's: the process and its start.
    readonly property string session: Quickshell.processId + "-" + Math.round(journal._born / 1000)
    readonly property var stats: journal._stats

    property double _born: Date.now()
    // The journal's path is given to its FileView at the first flush (not at the start: a FileView loads its file synchronously when
    // it gets its path, and a shell that never misses a frame never reads or holds the journal).
    property string _outPath: ""
    property string _rotPath: ""
    // The journal's text as last written: read from the file once, at the first flush, and kept -- a flush appends to it and writes
    // it whole, so no flush reads the file again (a blocking read of up to ~700 KB on the GUI thread, at rest but still a blip).
    property string _text: ""
    property double _sumAt: 0
    property var _hooks: []
    property var _pending: []
    property var _stats: ({ recorded: 0, dropped: 0, flushes: 0, lines: 0, marks: 0, rotations: 0 })

    function register(h: var): void {
        if (journal._hooks.indexOf(h) < 0)
            journal._hooks.push(h);
    }
    function unregister(h: var): void {
        const i = journal._hooks.indexOf(h);
        if (i >= 0)
            journal._hooks.splice(i, 1);
    }

    function record(e: var): void {
        if (!journal.enabled || !e)
            return;
        e.sid = journal.session;
        if (journal._pending.length >= journal.maxPending) {
            journal._pending.shift();
            journal._stats.dropped++;
        }
        journal._pending.push(e);
        journal._stats.recorded++;
        if (!flushTimer.running)
            flushTimer.start();
    }

    // A window began a run of frames (FrameJournalHook): when a summary is due, the next quiet writes one.
    function runStarted(): void {
        if (journal.enabled && !flushTimer.running && journal._summaryDue())
            flushTimer.start();
    }
    // The windows' counters written NOW (the tour's marks: a span's frame totals are the difference of two summaries, and the regular
    // one comes every summaryEveryMs).
    function summaryNow(): void {
        if (!journal.enabled)
            return;
        journal._sumAt = 0;
        journal.flush();
    }
    function _summaryDue(): bool {
        return journal._sumAt === 0 || Date.now() - journal._sumAt >= journal.summaryEveryMs;
    }

    function mark(label: string, timed: bool): void {
        journal._stats.marks++;
        for (let i = 0; i < journal._hooks.length; i++)
            journal._hooks[i].note(label, timed === true);
    }

    // No window has drawn for quietMs.
    function _quiet(): bool {
        const since = Date.now() - journal.quietMs;
        for (let i = 0; i < journal._hooks.length; i++)
            if (journal._hooks[i].lastFrameAt() > since)
                return false;
        return true;
    }

    Timer {
        id: flushTimer
        interval: journal.quietMs
        onTriggered: {
            if (!journal._quiet()) {
                flushTimer.restart();
                return;
            }
            journal.flush();
        }
    }

    function _read(fv: var): string {
        fv.reload();
        const t = fv.text();
        return t === undefined || t === null ? "" : String(t);
    }
    function _load(): var {
        const f = journal._read(loadFv).trim().split(/\s+/);
        return f.length >= 3 ? [Number(f[0]), Number(f[1]), Number(f[2])] : null;
    }
    function _psi(): var {
        const m = /some avg10=([0-9.]+) avg60=([0-9.]+)/.exec(journal._read(psiFv));
        return m ? [Number(m[1]), Number(m[2])] : null;
    }

    function flush(): void {
        flushTimer.stop();
        if (journal._pending.length === 0 && !journal._summaryDue())
            return;
        const load = journal._load();
        const psi = journal._psi();
        const lines = [];
        for (let i = 0; i < journal._pending.length; i++) {
            const e = journal._pending[i];
            if (load)
                e.load = load;
            if (psi)
                e.psi = psi;
            lines.push(JSON.stringify(e));
        }
        journal._pending = [];
        // one summary per window: what it drew and missed since it was mounted (the report's denominators)
        const now = Date.now();
        if (journal._summaryDue() || journal.capLines < 50) {
            journal._sumAt = now;
            for (let i = 0; i < journal._hooks.length; i++) {
                const s = journal._hooks[i].summary();
                s.sid = journal.session;
                lines.push(JSON.stringify(s));
            }
        }
        if (journal._outPath === "") {
            journal._outPath = journal.path;
            journal._text = journal._read(outFv);
            let n = 0;
            for (let i = journal._text.indexOf("\n"); i >= 0; i = journal._text.indexOf("\n", i + 1))
                n++;
            journal._stats.lines = n;
        }
        const add = lines.join("\n") + "\n";
        if (journal._stats.lines > 0 && journal._stats.lines + lines.length > journal.capLines) {
            // full: the journal becomes the rotated file and starts again with these lines
            if (journal._rotPath === "")
                journal._rotPath = journal.rotatedPath;
            rotFv.setText(journal._text);
            journal._text = add;
            journal._stats.lines = lines.length;
            journal._stats.rotations++;
        } else {
            journal._text += add;
            journal._stats.lines += lines.length;
        }
        outFv.setText(journal._text);
        journal._stats.flushes++;
    }

    FileView {
        id: loadFv
        path: "/proc/loadavg"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    FileView {
        id: psiFv
        path: "/proc/pressure/cpu"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    // The journal itself: read once at the first flush, then rewritten whole from `_text` at each (a FileView makes the missing
    // directories on a write). Its path is set once, from nothing, at the first flush, and that read goes through reload() (CLAUDE.md:
    // a FileView loads on its FIRST path only).
    FileView {
        id: rotFv
        path: journal._rotPath
        blockLoading: true
        blockAllReads: true
        atomicWrites: true
        printErrors: false
    }
    FileView {
        id: outFv
        path: journal._outPath
        blockLoading: true
        blockAllReads: true
        atomicWrites: true
        printErrors: false
    }
}
