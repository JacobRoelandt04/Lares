pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// CommandRunner.qml -- the shell's one way to run a program.
//
//     runner.run(["systemctl", "suspend"])
//     runner.run(["hyprctl", "dispatch", "hl.dsp.exit()"])
//
// LIVE runs it (fire and forget: a Process per call, destroyed when it exits). NOT LIVE
// -- the mock mode of the whole shell, every probe and every render -- RECORDS it and
// runs nothing, so a test can press the power reel's every item and read what each would
// have run (`calls`, newest last). Both record: the census and the probes read the same
// list in either mode.
//
// A command is an argv ARRAY, never a shell string: nothing here is parsed, quoted or
// expanded by a shell. `detached: true` starts it under `setsid -f`, in a session of its
// own, so it outlives the shell (the lock: a restart of the shell must not unlock the
// session) -- and with its stdin, stdout and stderr on /dev/null. A Process hands its child
// pipes for all three, and `setsid -f` exits at once, which destroys the Process and closes
// the shell's end of the pipes while the child lives on: the child's first word on stdout or
// stderr is a write to a pipe nobody reads and kills it (SIGPIPE). ~/.local/bin/hyprlock (and
// the Lares lock's entry point, whose supervisor `say`s on stderr) talk, so a lock started with the
// Process's pipes dies before it has locked anything whenever the first word comes after the
// Process is gone.
// =============================================================================
Item {
    id: root

    property bool live: false
    // [{ argv, ms, detached }], oldest first, capped at `keep`.
    readonly property var calls: root._calls
    property int keep: 200

    signal ran(var argv)

    property var _calls: []

    function run(argv: var, opts: var): void {
        if (!Array.isArray(argv) || argv.length === 0)
            return;
        const o = opts || {};
        const rec = { argv: argv.slice(), ms: Date.now(), detached: o.detached === true };
        const next = root._calls.concat([rec]);
        root._calls = next.length > root.keep ? next.slice(next.length - root.keep) : next;
        root.ran(rec.argv);
        if (!root.live)
            return;
        const proc = procComp.createObject(root, { command: o.detached === true ? root._detach(argv) : argv });
        // the process object goes with its process (a handler on the Process itself makes qmllint ask for QProcess::ExitStatus)
        proc.exited.connect(() => proc.destroy());
        proc.running = true;
    }

    // The argv of a detached start: its own session, and no stdio of the shell's (see the header).
    function _detach(argv: var): var {
        return ["setsid", "-f", "sh", "-c", "exec \"$@\" </dev/null >/dev/null 2>&1", "sh"].concat(argv);
    }

    // The last call whose argv starts with `head` (an array), or null.
    function last(head: var): var {
        for (let i = root._calls.length - 1; i >= 0; i--) {
            const a = root._calls[i].argv;
            let same = true;
            for (let j = 0; j < head.length; j++)
                if (a[j] !== head[j]) {
                    same = false;
                    break;
                }
            if (same)
                return root._calls[i];
        }
        return null;
    }

    function clear(): void {
        root._calls = [];
    }

    Component {
        id: procComp
        Process {}
    }
}
