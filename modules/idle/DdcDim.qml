pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "DdcDimRules.js" as Rules

// =============================================================================
// DdcDim.qml -- the idle dimming of EXTERNAL displays, over DDC/CI (SoftIdle dims the laptop panel; a desktop has none).
//
//   level      the level SoftIdle's input idleness asks for (0 full, 1 dimmed, 2 deep): the same clocks, the same content hold
//   active     the shell dims external displays here (idle.jsonc `ddcDim`; by itself only on a machine with no laptop panel)
//   displays   the displays' brightness (PanoramaService; null: nothing is dimmed): ddcNames(), ddcKey(n), ddcState(n), ddcBusy(n),
//              ddcPending(n), ddcGoal(n), ddcMax(n), ddcRead(n), ddcSet(n, v), ddcForgive(n), signal ddcChanged(n). Every write goes through
//              its one lane, so a brightness key and a dim never talk over each other.
//
// ONE LOOK PER CHANGE (`_look`, coalesced to a turn): every display that can be dimmed, or that has a figure to come back to, is asked what
// its next step is (DdcDimRules.next) -- when the level moves, when the backend says anything changed (a write done, a display back, a
// failure), and when a failed one is due again. So a display that was off or unreachable while the idleness ended gets its own figure the
// moment it answers: after a suspend, a replug, a power button, a restart of the shell (the state file).
//
// NOT LIVE: nothing is asked of the displays and no file is touched; `level` is only there to be read.
// =============================================================================
Item {
    id: root

    property bool live: false
    property bool active: false
    property int level: 0
    property var displays: null
    property var settings: ({ ddcDimLevel: 0.35, ddcDeepLevel: 0 })
    property string statePath: ""

    // { "<identity>": { full, wrote, level, giving? } }: the displays that are not at their own figure
    readonly property var saved: root._saved
    readonly property int want: root.active ? root.level : Rules.FULL
    // [{ act, name, value?, full?, ms }], oldest first, the last 100
    readonly property var log: root._log

    property var _saved: ({})
    property var _asked: ({})       // name -> a read for the figure to give back is out, or has landed
    property var _fails: ({})       // name -> tries since it last answered
    property var _dueAt: ({})       // name -> when a failed one is asked again
    property var _log: []

    onWantChanged: {
        root._asked = {};
        root._soon();
    }
    onDisplaysChanged: root._soon()
    onLiveChanged: root._soon()

    function _soon(): void {
        if (root.live && root.displays !== null)
            Qt.callLater(root._look);
    }
    function _note(e: var): void {
        e.ms = Date.now();
        const n = root._log.concat([e]);
        root._log = n.length > 100 ? n.slice(n.length - 100) : n;
        console.log("LARES idle ddc " + e.act + " " + e.name + (e.value !== undefined ? " -> " + e.value : "") + (e.full !== undefined ? " (from " + e.full + ")" : ""));
    }

    function _look(): void {
        const b = root.displays;
        if (!root.live || b === null)
            return;
        if (root.want === Rules.FULL && Object.keys(root._saved).length === 0)
            return;
        const now = Date.now();
        let due = 0;
        const names = b.ddcNames();
        for (let i = 0; i < names.length; i++) {
            const n = names[i], key = b.ddcKey(n);
            const e = root._saved[key] !== undefined ? root._saved[key] : null;
            const st = b.ddcState(n);
            const busy = b.ddcBusy(n);
            if (st === "ok")
                delete root._fails[n];
            const r = Rules.next(root.want, e, {
                present: true, state: st, busy: busy, pending: b.ddcPending(n), goal: b.ddcGoal(n), max: b.ddcMax(n), fresh: root._asked[n] === true && !busy
            }, root.settings);
            if (r.act === "read") {
                root._asked[n] = true;
                b.ddcRead(n);
            } else if (r.act === "dim" || r.act === "set") {
                root._save(key, { full: r.full, wrote: r.value, level: root.want });
                root._note({ act: r.act, name: n, value: r.value, full: r.full });
                b.ddcSet(n, r.value);
            } else if (r.act === "give") {
                root._save(key, { full: e.full, wrote: e.wrote, level: e.level, giving: r.value });
                root._note({ act: "give", name: n, value: r.value });
                b.ddcSet(n, r.value);
            } else if (r.act === "settled") {
                root._note({ act: "settled", name: n, value: b.ddcGoal(n) });
                root._save(key, null);
            } else if (r.act === "retry") {
                // it did not take the write, or does not answer: what was on its way back is not there
                if (e !== null && e.giving !== undefined)
                    root._save(key, { full: e.full, wrote: e.wrote, level: e.level });
                if (root._dueAt[n] === undefined) {
                    const k = root._fails[n] || 0;
                    root._fails[n] = k + 1;
                    root._dueAt[n] = now + Rules.retryMs(k);
                    root._note({ act: "retry", name: n, value: Math.round(Rules.retryMs(k) / 1000) });
                } else if (now >= root._dueAt[n] - 20) {
                    delete root._dueAt[n];
                    root._asked[n] = false;
                    b.ddcForgive(n);
                    continue;
                }
            }
            if (r.act !== "retry")
                delete root._dueAt[n];
            const at = root._dueAt[n];
            if (at !== undefined && (due === 0 || at < due))
                due = at;
        }
        again.stop();
        if (due > 0) {
            again.interval = Math.max(50, due - Date.now());
            again.start();
        }
    }

    Timer {
        id: again
        onTriggered: root._look()
    }
    Connections {
        target: root.live ? root.displays : null
        ignoreUnknownSignals: true
        function onDdcChanged(): void {
            root._soon();
        }
    }

    // The file is written before the display is (a crash in between leaves something to give back).
    function _save(key: string, entry: var): void {
        const n = Object.assign({}, root._saved);
        if (entry === null)
            delete n[key];
        else
            n[key] = entry;
        root._saved = n;
        if (root.live && root.statePath !== "")
            file.setText(Rules.stateText(n));
    }
    FileView {
        id: file
        path: root.statePath
        blockLoading: true
        blockWrites: true
        printErrors: false
        atomicWrites: true
    }
    Component.onCompleted: {
        if (root.live && root.statePath !== "")
            root._saved = Rules.parseState(file.text());
        root._soon();
    }
}
