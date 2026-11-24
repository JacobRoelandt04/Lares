pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// CalendarVisibilityStore.qml
//
// Persists the user's per-calendar show/hide preferences. Default is "show
// everything" — only HIDDEN ids are written to disk so newly added calendars
// (whether mock or imported via calendars.jsonc) start visible without needing
// a config migration.
//
// State file (JSON): $XDG_STATE_HOME/lares/calendar/visibility.json
//   { "hidden": ["work", "family"] }
//
// API:
//   isHidden(id)        -> bool
//   setHidden(id, bool) -- set state directly
//   toggle(id)          -- flip current state
//   hiddenList          -> [id, ...]   (reactive prop, downstream binds)
// =============================================================================
Item {
    id: root

    property string stateDir:
        (Quickshell.env("XDG_STATE_HOME")
            || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/calendar"
    readonly property string statePath: stateDir + "/visibility.json"

    // Source of truth — array of hidden calendar ids. Downstream consumers
    // (data sources, UI checkboxes) bind to this, so any mutation must
    // assign a fresh array, never .push() on the existing one.
    property var hiddenList: []

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
            if (root.hiddenList.length > 0) {
                root.hiddenList = [];
                root.changed();
            }
            return;
        }
        try {
            let obj = JSON.parse(txt);
            if (obj && Array.isArray(obj.hidden)) {
                let next = obj.hidden.slice();
                if (!_arrayEq(root.hiddenList, next)) {
                    root.hiddenList = next;
                    root.changed();
                }
            }
        } catch (e) {
            console.warn("[CalendarVisibilityStore] parse error:", e);
        }
    }

    function _save() {
        fv.setText(JSON.stringify({ hidden: root.hiddenList }, null, 2));
    }

    function _arrayEq(a, b) {
        if (a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }

    function isHidden(id) {
        for (let i = 0; i < root.hiddenList.length; i++) {
            if (root.hiddenList[i] === id) return true;
        }
        return false;
    }

    function setHidden(id, hidden) {
        let cur = isHidden(id);
        if (cur === hidden) return;
        let next = root.hiddenList.slice();
        if (hidden) {
            next.push(id);
        } else {
            let idx = next.indexOf(id);
            if (idx >= 0) next.splice(idx, 1);
        }
        root.hiddenList = next;
        root.changed();
        _save();
    }

    function toggle(id) {
        setHidden(id, !isHidden(id));
    }
}
