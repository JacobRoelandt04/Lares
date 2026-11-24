pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// SourceExec.qml -- run a program once and hear how it ended.
//
//     exec.run(["df", "-P", "/"], (code, out, err) => { ... })
//     exec.run(argv, cb, 5000)                  a time limit, ms (default 15000)
//
// One Process per call, destroyed when it ends. The callback gets the exit code,
// stdout and stderr as text. A program that does not exist emits neither `started`
// nor `exited` (CLAUDE.md), so every call also has a limit: past it the process is
// killed and the callback is told code -1 and "timed out" -- a source that waits on
// an answer can never wait for ever.
//
// A source runs only what only reads (df, systemctl --failed, journalctl, lsblk,
// pacman -Sup, the udisks mount / unmount a CLICK asked for): nothing here changes
// the machine on its own. `calls` is every argv started, oldest first, for the probes.
// =============================================================================
Item {
    id: root
    visible: false

    property int keep: 200
    readonly property var calls: root._calls

    property var _calls: []

    function run(argv, cb, limitMs) {
        if (!Array.isArray(argv) || argv.length === 0) {
            if (cb)
                cb(-1, "", "no command");
            return;
        }
        const next = root._calls.concat([argv.slice()]);
        root._calls = next.length > root.keep ? next.slice(next.length - root.keep) : next;
        jobComp.createObject(root, { argv: argv, cb: cb || null, limitMs: limitMs > 0 ? limitMs : 15000 });
    }

    Component {
        id: jobComp
        Item {
            id: job
            property var argv: []
            property var cb: null
            property int limitMs: 15000
            property bool done: false

            function finish(code, out, err) {
                if (job.done)
                    return;
                job.done = true;
                const f = job.cb;
                job.destroy();
                if (f)
                    f(code, out, err);
            }

            Process {
                id: proc
                command: job.argv
                running: true
                stdout: StdioCollector {
                    id: so
                }
                stderr: StdioCollector {
                    id: se
                }
                onExited: code => job.finish(code, so.text, se.text)
            }
            Timer {
                interval: job.limitMs
                running: true
                onTriggered: {
                    proc.signal(9);
                    job.finish(-1, so.text, "timed out");
                }
            }
        }
    }
}
