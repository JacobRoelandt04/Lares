pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// SystemUpdateLogger.qml
//
// Wires log-rotation around a TerminalBackend for system-update runs.
//
// Responsibilities:
//   1. On each `backend.started` signal: pick a fresh timestamped path under
//      ~/.cache/lares/system-update-logs/ and set `backend.logFilePath`.
//      TerminalBackend already appends every raw chunk to that file via its
//      internal _logWriter (see TerminalBackend.qml).
//   2. Before starting, run `mkdir -p <dir>`.
//   3. After a run finishes (`backend.exited`), prune old logs so that at
//      most `keepRecent` (default 2) remain.
//
// This does NOT touch the backend's command or start it; the owning module
// still calls `backend.start()` itself. Just drop this into the same scene.
// =============================================================================
Item {
    id: root

    // ---- Required ----
    property var backend: null                   // TerminalBackend

    // ---- Options ----
    property int keepRecent: 2
    // Resolved lazily so $HOME is present when we read it.
    property string logDir: ""
    property string lastLogPath: ""

    function _ensureDir() {
        if (root.logDir.length === 0) {
            const home = Quickshell.env("HOME");
            root.logDir = home + "/.cache/lares/system-update-logs";
        }
        _mkdirProc.command = ["mkdir", "-p", root.logDir];
        _mkdirProc.running = true;
    }

    function _timestamp() {
        const d = new Date();
        const pad = (n) => (n < 10 ? "0" + n : "" + n);
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
             + "_" + pad(d.getHours()) + "-" + pad(d.getMinutes()) + "-" + pad(d.getSeconds());
    }

    function _rotate() {
        // Keep N newest; delete the rest. `ls -1t` sorts newest first.
        // `tail -n +<keepRecent+1>` drops the first N lines; xargs rm quietly.
        if (root.logDir.length === 0) return;
        const keep = Math.max(1, root.keepRecent);
        _rotateProc.command = ["bash", "-c",
            'ls -1t "' + root.logDir + '"/*.log 2>/dev/null | tail -n +' + (keep + 1)
            + ' | xargs -r rm -f'];
        _rotateProc.running = true;
    }

    Process { id: _mkdirProc; running: false }
    Process { id: _rotateProc; running: false }

    Connections {
        target: root.backend
        ignoreUnknownSignals: true
        function onStarted() {
            root._ensureDir();
            // A host that already chose where the transcript goes (the
            // mockup keeps it beside the UI-state log) keeps that choice;
            // overriding it here would make a run's transcript go missing.
            if (root.backend && root.backend.logFilePath && root.backend.logFilePath.length > 0) {
                root.lastLogPath = root.backend.logFilePath;
                return;
            }
            const path = root.logDir + "/" + root._timestamp() + ".log";
            root.lastLogPath = path;
            if (root.backend) root.backend.logFilePath = path;
        }
        function onExited(code, status) {
            root._rotate();
        }
    }

    Component.onCompleted: _ensureDir()
}
