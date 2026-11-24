pragma ComponentBehavior: Bound

import QtQuick

import "components/SystemUpdateProgress.js" as Progress
import "components/SystemUpdateWork.js" as Work

// =============================================================================
// SystemUpdateRunProgress.qml -- the whole run's progress, as the SERVICE keeps it.
//
// The bar's button shows one percentage for the run and a mark for what it is doing; the popup may be
// shut, so the number cannot live in the popup. This reads the parser's counters as ONE snapshot
// (the arithmetic is SystemUpdateProgress.js: weighted by what the run's own plan says, a high-water
// mark held by step key) and publishes
//
//   percent   0..100 (the floor of the high-water figure; 100 only when the run completed)
//   mark      download | disk | cog | ask | fail -- what the run is doing (the card's glyph for the
//             phase, a question while yay waits to be answered, an exclamation while it fails)
//   outcome   "" | "ok" | "failed": what an ENDED run left (the idle dot is red after a failure)
//
// A new run starts a new state. The backend flips `running` BEFORE the parser's started()-reset, so
// for that beat the parser still describes the run that ended; those readings are not this run's and
// are skipped (the popup's step logic and its AUR latch have the same beat to survive).
// Published only when the whole percent moves: the bar window has no damage regions, and a fraction
// that changed with every download row would redraw it at the rate of pacman's output.
// =============================================================================
Item {
    id: root
    visible: false

    property var parser: null
    property bool running: false
    // The SnapshotService (or null): with it the run's plan has a snapshot step when the rule wants one for
    // the run's upgrade list (decided once the list is read), and without it only when the hook speaks.
    property var snapshots: null
    // The run has a snapshot step. Latched for the run, so the plan never loses a step it has counted.
    property bool _hasSnapshot: false
    property string _wantAsked: ""

    property int percent: 0
    property string mark: "download"
    readonly property string outcome: {
        const p = root.parser;
        if (root.running || !p || p.phase === "INITIAL")
            return "";
        if (p.errorCount > 0 || p.phase === "FAILED")
            return "failed";
        return p.phase === "COMPLETE" ? "ok" : "";
    }

    // One reading of everything the figure is made of: reading each field HERE is what makes the
    // binding follow them.
    readonly property var _reading: {
        const p = root.parser;
        if (!p)
            return null;
        return {
            phase: p.phase, subPhase: p.subPhase, packages: p.totalPackages, aurCount: p.aurBuildsTotal,
            kind: p.runKind, snapshotState: p.snapshotState, snapshotProgress: p.snapshotProgress,
            totalDownloadBytes: p.totalDownloadBytes, downloadPct: p.downloadPct,
            downloadsDone: p.downloadsDone, downloadsTotal: p.downloadsTotal,
            installsDone: p.installsDone, installsTotal: p.installsTotal,
            hooksDone: p.hooksDone, hooksTotal: p.hooksTotal,
            aurBuildsDone: p.aurBuildsDone, aurSourcesDone: p.aurSourcesDone, sourceFetchPct: p.sourceFetchPct,
            awaiting: p.awaitingUserInput, failing: p.errorCount > 0, exitCode: p.exitCode
        };
    }
    // A plain object kept in place (a `var` holding the state is mutated by the module): no binding reads it.
    property var _state: Progress.newState()

    on_ReadingChanged: root._advance()
    onRunningChanged: {
        if (root.running) {
            root._state = Progress.newState();
            root._hasSnapshot = false;
            root._wantAsked = "";
            root.percent = 0;
            root.mark = "download";
        }
        root._advance();
    }

    // Decided from a handler, never a binding: once per phase after the upgrade list is read (the names
    // are the official packages of the run), and at once when the hook itself has spoken.
    function _latchSnapshot(r) {
        if (root._hasSnapshot)
            return;
        const s = root.snapshots;
        // (a hook that skips never adds the step: the rule was right)
        if (s && (r.snapshotState === "running" || r.snapshotState === "done")) {
            root._hasSnapshot = true;
            return;
        }
        if (!s || !s.ready || r.phase === "INITIAL" || r.phase === "DB_SYNC_1" || r.phase === "AUR_SEARCH"
                || r.phase === "UPGRADE_LIST" || root._wantAsked === r.phase)
            return;
        root._wantAsked = r.phase;
        const names = [];
        const m = root.parser.packages;
        for (let i = 0; i < m.count; i++)
            if (!m.get(i).isAur)
                names.push(m.get(i).name);
        if (names.length > 0 && Work.wantsYes(s.wantsFor(names)))
            root._hasSnapshot = true;
    }

    function _advance() {
        const r = root._reading;
        if (!r)
            return;
        // the parser has not been reset for this run yet
        if (root.running && r.exitCode >= 0)
            return;
        root._latchSnapshot(r);
        r.hasSnapshot = root._hasSnapshot;
        Progress.advance(root._state, r);
        const pc = Progress.percent(root._state);
        if (pc !== root.percent)
            root.percent = pc;
        const m = Progress.markKind(r);
        if (m !== root.mark)
            root.mark = m;
    }
}
