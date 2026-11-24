pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// AerialState.qml -- one small state file the service keeps ($XDG_STATE_HOME/lares/aerial/usage.json, trust.json).
//
// Read once, synchronously (`read()` at the service's go-live), written atomically into a directory made first, THROUGH THIS ONE
// PATH (a FileView skips a write equal to the text it holds, so the last write is remembered and an equal one is not attempted).
// `write(text)` lands `delayMs` after the last call; `flush()` writes now. `exists` says whether the file was there at the read
// (the trust file's "first run" is its absence).
// =============================================================================
Item {
    id: root

    property string path: ""
    property int delayMs: 300

    readonly property bool exists: root._exists
    property bool _exists: false
    property string _pending: ""
    property bool _has: false
    property string _selfWrite: ""
    property bool _dirReady: false
    property bool _dirAsked: false

    // The file's text now ("" when none); sets `exists`.
    function read(): string {
        if (root.path === "")
            return "";
        file.reload();
        const t = file.text();
        root._exists = t.length > 0;
        root._selfWrite = t;
        return t;
    }

    function write(text: string): void {
        root._pending = text;
        root._has = true;
        timer.restart();
    }

    function flush(): void {
        if (!root._has || root.path === "")
            return;
        if (!root._dirReady) {
            if (!root._dirAsked) {
                root._dirAsked = true;
                mkdir.command = ["mkdir", "-p", root.path.substring(0, root.path.lastIndexOf("/"))];
                mkdir.running = true;
            }
            timer.restart();
            return;
        }
        timer.stop();
        if (root._pending === root._selfWrite)
            return;
        root._selfWrite = root._pending;
        root._exists = true;
        file.setText(root._pending);
    }

    Timer {
        id: timer
        interval: root.delayMs
        onTriggered: root.flush()
    }
    FileView {
        id: file
        path: root.path
        blockLoading: true
        blockAllReads: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }
    Process {
        id: mkdir
        running: false
        onExited: {
            root._dirReady = true;
            timer.restart();
        }
    }
    Component.onDestruction: root.flush()
}
