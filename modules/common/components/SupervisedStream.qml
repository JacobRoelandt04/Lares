import QtQuick
import Quickshell.Io

// =============================================================================
// SupervisedStream -- one long-running child whose stdout is a stream of lines,
// kept alive for as long as it is enabled.
//
// The supervision is shared by SleepWatcher and the clipboard watcher
// (`wl-paste --watch ...`), which need exactly the same thing:
//
// LIFETIME. Give the command `setpriv --pdeathsig TERM --` in front so the child
// dies with the shell however the shell dies (the stream does not add it: a probe
// passes a stub). If the child exits on its own it is started again after 1 s,
// doubling to 60 s while it keeps failing, with ONE warning per failing streak
// ("<what> exited (<code>): <last stderr line>; restarting ..."); a child that ran
// for a minute was working, and its exit starts a new streak.
//
// LINES. Quickshell 0.3.1's SplitParser can hand over two lines in one slice and
// drops an empty line that follows another in the same read (CLAUDE.md), so each
// slice is split on "\n" again and `line` is emitted once per piece; consumers
// skip empty lines themselves if they mean nothing.
//
// Neither `running` nor `command` of the Process is bound: Quickshell writes
// `running` false when the process exits, which would destroy a binding on it.
// A program that does not exist emits neither `started` nor `exited` (CLAUDE.md):
// a consumer that must know checks with `test -x` before enabling the stream.
// =============================================================================
QtObject {
    id: root

    property bool enabled: true
    property var command: []
    // The start of the warning, e.g. "SleepWatcher: the sleep monitor".
    property string what: "SupervisedStream: the child"

    readonly property bool running: root._proc.running
    // A child that reads commands on its stdin (the dictation helper): true before `enabled`; `write(text)` sends while it runs.
    // Its stdin stays open while it runs (a Process's stdin is open until closed, CLAUDE.md): the child ends when it is stopped
    // or when the shell dies (pdeathsig).
    property bool stdinEnabled: false
    function write(text: string): void {
        if (root._proc.running)
            root._proc.write(text);
    }

    // One per line of stdout.
    signal line(string text)
    // Every exit, before any restart is armed. `expected` is true when the stream
    // stopped it itself (disabled, or a new command).
    signal exited(int code, bool expected)
    // One per line of stderr (DictationService keeps its helper's last 200 for the report of a stall).
    signal errorLine(string text)

    property Process _proc: Process {
        stdinEnabled: root.stdinEnabled
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++)
                    root.line(parts[i]);
            }
        }
        stderr: SplitParser {
            onRead: data => {
                root._lastError = data;
                root.errorLine(data);
            }
        }
    }
    property Connections _procExit: Connections {
        target: root._proc
        function onExited(code) {
            root._exited(code);
        }
    }
    property string _runningCommand: ""
    property string _lastError: ""
    // We stopped it (disabled, or a new command): its exit is not a failure.
    property bool _stopping: false
    property int _retryMs: 1000
    property int _failStreak: 0
    property double _startedAt: 0
    property Timer _retry: Timer {
        onTriggered: root._sync()
    }

    function _sync() {
        const cmd = root.command;
        const want = root.enabled && Array.isArray(cmd) && cmd.length > 0;
        const key = want ? JSON.stringify(cmd) : "";
        if (root._proc.running) {
            if (key !== root._runningCommand) {
                root._stopping = true;
                root._proc.running = false;     // its exit re-syncs
            }
            return;
        }
        if (!want) {
            root._retry.stop();
            root._proc.running = false;     // a start Quickshell has only recorded (asked for while the config loads: `running` reads false until then)
            return;
        }
        if (root._retry.running)
            return;
        root._runningCommand = key;
        root._lastError = "";
        root._startedAt = Date.now();
        root._proc.command = cmd;
        root._proc.running = true;
    }

    function _exited(code) {
        root._runningCommand = "";
        const expected = root._stopping;
        root.exited(code, expected);
        if (expected) {
            root._stopping = false;
            Qt.callLater(root._sync);
            return;
        }
        if (!root.enabled)
            return;
        // A child that ran for a minute was working: this is a new streak.
        if (Date.now() - root._startedAt >= 60000) {
            root._retryMs = 1000;
            root._failStreak = 0;
        }
        if (root._failStreak++ === 0)
            console.warn(root.what + " exited (" + code + ")"
                         + (root._lastError !== "" ? ": " + root._lastError : "")
                         + "; restarting it, backing off to 60 s while it fails");
        root._retry.interval = root._retryMs;
        root._retryMs = Math.min(60000, root._retryMs * 2);
        root._retry.start();
    }

    onEnabledChanged: {
        root._retry.stop();
        root._sync();
    }
    onCommandChanged: {
        root._retry.stop();
        root._sync();
    }
    Component.onCompleted: root._sync()
}
