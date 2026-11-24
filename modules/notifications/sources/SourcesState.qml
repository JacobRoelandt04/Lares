pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// SourcesState.qml -- what the notification sources remember between runs.
//
// $XDG_STATE_HOME/lares/notifications/sources.json (`statePath`):
//   { "version": 1, "<section>": { ... }, ... }
// one section per source (the system update's last nudge and boot, the stocks'
// latches, the calendar's reminded events, the failed units already announced).
// A section is a plain object the source owns; this file knows nothing in it.
//
//   get(section)        a deep COPY of the section ({} when there is none)
//   put(section, obj)   replaces it and schedules the write
//   flush()             writes now
//
// NotificationState's pattern: read once, synchronously, at completion; every
// change written 300 ms after the last, atomically, into a directory made first;
// a write equal to the last one made is skipped. `persist: false` keeps it in
// memory only (a mock, a probe that wants a clean start).
// =============================================================================
Item {
    id: root
    visible: false

    property bool persist: true
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/notifications/sources.json"

    readonly property bool loaded: root._loaded

    function get(section) {
        const v = root._data[section];
        return v === undefined ? ({}) : JSON.parse(JSON.stringify(v));
    }

    function put(section, obj) {
        root._data[section] = JSON.parse(JSON.stringify(obj === undefined ? {} : obj));
        root._save();
    }

    function flush() {
        if (!root.persist || !root._loaded)
            return;
        if (!root._dirReady) {
            writeTimer.restart();
            return;
        }
        writeTimer.stop();
        const txt = root._serialize();
        if (txt === root._selfWrite)
            return;
        root._selfWrite = txt;
        file.setText(txt);
    }

    // ---- Private -------------------------------------------------------------
    property var _data: ({})
    property bool _loaded: false
    property bool _dirReady: false
    property string _selfWrite: ""

    function _save() {
        if (!root.persist || !root._loaded)
            return;
        writeTimer.restart();
    }

    function _serialize() {
        return JSON.stringify(Object.assign({ version: 1 }, root._data), null, 1) + "\n";
    }

    function _ingest(txt) {
        if (!txt || txt.trim().length === 0)
            return;
        let o = null;
        try {
            o = JSON.parse(txt);
        } catch (e) {
            return;
        }
        if (!o || typeof o !== "object" || Array.isArray(o))
            return;
        const d = {};
        for (const k in o)
            if (k !== "version" && o[k] !== null && typeof o[k] === "object" && !Array.isArray(o[k]))
                d[k] = o[k];
        root._data = d;
        root._selfWrite = root._serialize();
    }

    Timer {
        id: writeTimer
        interval: 300
        onTriggered: root.flush()
    }

    FileView {
        id: file
        path: root.persist ? root.statePath : ""
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", root.statePath.substring(0, root.statePath.lastIndexOf("/"))]
        running: false
    }
    Connections {
        target: mkdir
        function onExited() {
            root._dirReady = true;
        }
    }

    Component.onCompleted: {
        if (root.persist)
            root._ingest(file.text());
        root._loaded = true;
        if (root.persist)
            mkdir.running = true;
        else
            root._dirReady = true;
    }
    Component.onDestruction: root.flush()
}
