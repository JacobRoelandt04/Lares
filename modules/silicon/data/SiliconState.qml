pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// SiliconState.qml -- what silicon remembers between runs (never silicon.jsonc).
//
// $XDG_STATE_HOME/lares/silicon/state.json (overridable: `statePath`):
//   { version: 1, lastFullMs, ignoredApps: [app], muxOutcomeSeenAt, afterMuxMode }
//
//   lastFullMs        the last moment THIS SERVICE saw the pack full: it reaching its charge target and it leaving it, whichever
//                     is later (unix ms; 0 = never seen). UPower's history is not kept here: it is asked again every time
//   ignoredApps       Smart-mode apps the user chose "Ignore" for: never asked about again
//   muxOutcomeSeenAt  the request time (ms) of the last MUX record whose outcome the user saw,
//                     so a "reverted" notice is shown once
//   afterMuxMode      the GPU step (0 Integrated, 1 Smart, 2 Hybrid; null = none) wanted once the way back
//                     from dGPU-only has been restarted: the helper's request only says "hybrid", and the
//                     restart ends the shell, so the rest of what the user asked for is kept here, applied
//                     through cardwire once (SiliconService) and cleared
//
// Read once, synchronously, at completion (blockLoading: no waiting for onLoaded). Every change
// is written 300 ms after the last one, atomically, into a directory made first, THROUGH THIS
// ONE PATH: a FileView skips a write equal to the text it holds, so the last write is remembered
// (`_selfWrite`) and an equal one is not attempted. `persist: false` keeps it in memory.
// `ensureLoaded()` is the idempotent read a parent calls first (its Component.onCompleted runs
// before its children's).
// =============================================================================
Item {
    id: root

    property bool persist: true
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/silicon/state.json"

    property real lastFullMs: 0
    property var ignoredApps: []
    property real muxOutcomeSeenAt: 0
    property var afterMuxMode: null

    readonly property bool loaded: root._loaded

    onLastFullMsChanged: root._save()
    onIgnoredAppsChanged: root._save()
    onMuxOutcomeSeenAtChanged: root._save()
    onAfterMuxModeChanged: root._save()

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

    function ignore(app) {
        if (typeof app !== "string" || app === "" || root.ignoredApps.indexOf(app) >= 0)
            return;
        root.ignoredApps = root.ignoredApps.concat([app]);
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
            lastFullMs: root.lastFullMs,
            ignoredApps: root.ignoredApps,
            muxOutcomeSeenAt: root.muxOutcomeSeenAt,
            afterMuxMode: root.afterMuxMode
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
        if (typeof o.lastFullMs === "number" && isFinite(o.lastFullMs) && o.lastFullMs >= 0)
            root.lastFullMs = o.lastFullMs;
        if (Array.isArray(o.ignoredApps))
            root.ignoredApps = o.ignoredApps.filter(function (s) { return typeof s === "string" && s.length > 0; });
        if (typeof o.muxOutcomeSeenAt === "number" && isFinite(o.muxOutcomeSeenAt) && o.muxOutcomeSeenAt >= 0)
            root.muxOutcomeSeenAt = o.muxOutcomeSeenAt;
        if (o.afterMuxMode === 0 || o.afterMuxMode === 1 || o.afterMuxMode === 2)
            root.afterMuxMode = o.afterMuxMode;
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
