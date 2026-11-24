pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// WeekOffsetStore.qml
//
// Persists a per-year "week-1 anchor" — user clicks a week number in the
// calendar grid to declare it as week 1 for that year. Weeks before receive
// 0 and negative numbers, weeks after count upward from 1. Only the year the
// anchor was set in is affected; all other years display normal ISO weeks.
//
// State file (JSON): $XDG_STATE_HOME/lares/calendar/week-offsets.json
//   { "offsets": { "2026": 17, ... } }
//
// API:
//   getOffset(year)                -> int | null
//   toggleOffset(year, isoWeek)    -- click same-week again clears
//   clearOffset(year)
//   displayedFor(year, isoWeek)    -> { value, offset: bool, real }
// =============================================================================
Item {
    id: root

    property string stateDir:
        (Quickshell.env("XDG_STATE_HOME")
            || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/calendar"
    readonly property string statePath: stateDir + "/week-offsets.json"

    property var offsets: ({})

    signal changed()

    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", root.stateDir]);
    }

    FileView {
        id: fv
        path: root.statePath
        preload: true
        watchChanges: true
        atomicWrites: true
        printErrors: false

        onLoaded: root._load(text())
        onTextChanged: root._load(text())
        onFileChanged: reload()
    }

    function _load(txt) {
        if (!txt || txt.length === 0) {
            if (Object.keys(root.offsets).length > 0) {
                root.offsets = {};
                root.changed();
            }
            return;
        }
        try {
            let obj = JSON.parse(txt);
            if (obj && typeof obj.offsets === "object" && obj.offsets !== null) {
                root.offsets = obj.offsets;
                root.changed();
            }
        } catch (e) {
            console.warn("[WeekOffsetStore] parse error:", e);
        }
    }

    function _save() {
        fv.setText(JSON.stringify({ offsets: root.offsets }, null, 2));
    }

    function getOffset(year) {
        let v = root.offsets[String(year)];
        return (typeof v === "number") ? v : null;
    }

    function toggleOffset(year, isoWeek) {
        let y = String(year);
        let cur = root.offsets[y];
        let next = Object.assign({}, root.offsets);
        if (cur === isoWeek) {
            delete next[y];
        } else {
            next[y] = isoWeek;
        }
        root.offsets = next;
        root.changed();
        _save();
    }

    function clearOffset(year) {
        let y = String(year);
        let next = Object.assign({}, root.offsets);
        delete next[y];
        root.offsets = next;
        root.changed();
        _save();
    }

    function displayedFor(year, isoWeek) {
        let off = getOffset(year);
        if (off === null) {
            return { value: isoWeek, offset: false, real: isoWeek };
        }
        return { value: isoWeek - off + 1, offset: true, real: isoWeek };
    }
}
