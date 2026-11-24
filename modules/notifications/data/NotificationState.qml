pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// NotificationState.qml -- what the notification module remembers between
// runs that is not a notification (history.json holds those).
//
// $XDG_STATE_HOME/lares/notifications/state.json (`statePath`):
//   { version: 1, dnd, lastOpenedMs, hoursAt }   hoursAt: the start or end of the quiet hours (dnd.hours) that was last
//   followed, ms (a switch by hand after it stands until the next one)   (an older file also has lastGroup: unread now, the manager opens on the
//   group that last received a notification)
//
// The StocksState pattern: read once, synchronously, at completion
// (blockLoading); every change written 300 ms after the last one, atomically,
// into a directory made first; a write equal to the last one made is skipped
// (the self-write guard). `persist: false` keeps it in memory only.
// =============================================================================
Item {
    id: root

    property bool persist: true
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/notifications/state.json"

    property bool dnd: false
    property real lastOpenedMs: 0
    property real hoursAt: 0

    readonly property bool loaded: root._loaded

    // The first read (idempotent; the service asks for it before its own start).
    function ensureLoaded() {
        if (root._loaded)
            return;
        if (root.persist)
            root._ingest(file.text());
        root._loaded = true;
        if (root.persist)
            mkdir.running = true;
        else
            root._dirReady = true;
    }

    onDndChanged: root._save()
    onLastOpenedMsChanged: root._save()
    onHoursAtChanged: root._save()

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
    property bool _loaded: false
    property bool _ingesting: false
    property bool _dirReady: false
    property string _selfWrite: ""

    function _save() {
        if (!root.persist || root._ingesting || !root._loaded)
            return;
        writeTimer.restart();
    }

    function _serialize() {
        return JSON.stringify({
            version: 1,
            dnd: root.dnd,
            lastOpenedMs: root.lastOpenedMs,
            hoursAt: root.hoursAt
        }, null, 1) + "\n";
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
        root._ingesting = true;
        if (typeof o.dnd === "boolean")
            root.dnd = o.dnd;
        if (typeof o.lastOpenedMs === "number" && isFinite(o.lastOpenedMs))
            root.lastOpenedMs = o.lastOpenedMs;
        if (typeof o.hoursAt === "number" && isFinite(o.hoursAt))
            root.hoursAt = o.hoursAt;
        root._ingesting = false;
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
        function onExited() { root._dirReady = true; }
    }

    Component.onCompleted: root.ensureLoaded()
}
