pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "LauncherModel.js" as M

// =============================================================================
// LaunchRunner.qml -- how the launcher starts things.
//
// AN APP (a DesktopEntry, or a .desktop file of the scripts root) goes into a
// transient systemd user SCOPE of its own and a new session:
//
//   systemd-run --user --scope --collect --quiet --expand-environment=no
//       --unit=app-launcher-<slug>-<ms> -- setsid -f <command...>
//
// through Quickshell.execDetached in the entry's working directory (Path=,
// else $HOME). The scope is its own cgroup, so the app is not the shell's
// child in anything systemd sees and outlives a shell restart. The app must
// not be in the session of a terminal quickshell was started from (it would
// inherit that terminal and its sudo cache, CLAUDE.md): execDetached already
// starts a new session with no controlling terminal (measured), and `setsid -f` keeps that true whatever starts
// the scope -- an attached Process does not.
// `--expand-environment=no`: without it systemd-run rewrites `${x}` and `$$`
// in the argv (systemd 261).
// A Terminal=true app runs as `kitty -e <command...>` the same way.
//
// A SCRIPT of the scripts root runs as a transient user SERVICE:
//
//   systemd-run --user --wait --collect --quiet --expand-environment=no
//       --unit=launcher-script-<slug>-<ms> --property=Type=exec
//       --working-directory=<$HOME> --setenv=PATH=<the shell's PATH> -- <script>
//
// from a Process held here (setpriv --pdeathsig TERM). The script is the user
// manager's child, not ours -- it has no terminal, a session of its own and
// the manager's environment plus the shell's PATH (it carries WAYLAND_DISPLAY and
// HYPRLAND_INSTANCE_SIGNATURE, checked), and it keeps running if the shell
// restarts (killing a `systemd-run --wait` leaves the service running)
// -- while --wait hands its exit status back to us. A non-zero exit
// reads the script's own last line from the journal,
//
//   journalctl --user _SYSTEMD_USER_UNIT=<unit>.service -o cat -n 1 --no-pager
//
// (NOT `-u <unit>`: that also matches the manager's messages ABOUT the unit,
// and its last line is "…: Failed with result 'exit-code'."), and
// notifies it: title "<name> failed", body the line (or the exit code when
// the script printed nothing). A `# terminal: yes` script runs in kitty in a
// scope, like an app.
//
// `<ms>` is Date.now(), made strictly increasing, so two launches in one
// millisecond do not ask for the same unit name; a counter would restart at
// every shell reload and collide with a script still running from before.
//
// DRY RUN. With `dryRun` nothing is started at all: `lastCommand` says what
// would have run (as a shell would read it), and that is all. The mockup and
// the UI probes run dry; nothing a test does can start an app or a script.
// =============================================================================
Scope {
    id: runner

    property bool dryRun: false
    property var notifier: null            // anything with notify(key, spec)
    property string notifyKey: "script"
    property string home: Quickshell.env("HOME") || "/"
    // The shell's own PATH, handed to every script service: the user manager's
    // lacks ~/.local/bin, and a script run from the launcher should
    // find what it finds in a terminal. Per launch, so nothing system-wide is
    // changed (no import-environment).
    property string scriptPath: Quickshell.env("PATH") || ""
    property var terminalCommand: ["kitty", "-e"]

    readonly property string lastCommand: runner._last
    readonly property int running: runner._running

    // A script ended: code 0 or not (after the journal was read).
    signal scriptExited(string key, int code, string message)

    // ---- argv (pure) ----------------------------------------------------------

    function stamp() {
        let t = Date.now();
        if (t <= runner._lastMs)
            t = runner._lastMs + 1;
        runner._lastMs = t;
        return t;
    }

    // spec: { slug, command: [..], terminal }
    function appArgv(spec, ms) {
        const cmd = spec.terminal ? runner.terminalCommand.concat(spec.command) : spec.command.slice();
        return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--expand-environment=no",
                "--unit=app-launcher-" + M.slug(spec.slug) + "-" + ms, "--", "setsid", "-f"].concat(cmd);
    }
    // spec: { slug, path }
    function scriptUnit(spec, ms) {
        return "launcher-script-" + M.slug(spec.slug) + "-" + ms;
    }
    function scriptArgv(spec, ms) {
        return ["systemd-run", "--user", "--wait", "--collect", "--quiet", "--expand-environment=no",
                "--unit=" + runner.scriptUnit(spec, ms), "--property=Type=exec",
                "--working-directory=" + runner.home].concat(runner.scriptPath !== "" ? ["--setenv=PATH=" + runner.scriptPath] : [], ["--", spec.path]);
    }
    function journalArgv(unit) {
        return ["journalctl", "--user", "_SYSTEMD_USER_UNIT=" + unit + ".service", "-o", "cat", "-n", "1", "--no-pager"];
    }

    // ---- launching --------------------------------------------------------------

    // spec: { key, slug, command, terminal, workingDirectory }. The argv, run.
    function launchApp(spec) {
        const argv = runner.appArgv(spec, runner.stamp());
        runner._last = M.shellQuote(argv);
        if (runner.dryRun)
            return argv;
        Quickshell.execDetached({
            command: argv,
            workingDirectory: spec.workingDirectory || runner.home
        });
        return argv;
    }

    // spec: { key, slug, path, name, terminal }.
    function launchScript(spec) {
        if (spec.terminal)
            return runner.launchApp({
                key: spec.key,
                slug: spec.slug,
                command: [spec.path],
                terminal: true,
                workingDirectory: runner.home
            });
        const ms = runner.stamp();
        const argv = runner.scriptArgv(spec, ms);
        runner._last = M.shellQuote(argv);
        if (runner.dryRun)
            return argv;
        const unit = runner.scriptUnit(spec, ms);
        const p = procComp.createObject(runner, {
            key: spec.key,
            name: spec.name,
            unit: unit,
            command: ["setpriv", "--pdeathsig", "TERM", "--"].concat(argv)
        });
        runner._running += 1;
        p.running = true;     // qmllint disable missing-property
        return argv;
    }

    // ---- internals ----------------------------------------------------------------

    property string _last: ""
    property real _lastMs: 0
    property int _running: 0

    function _finished(p, code, errText) {
        runner._running = Math.max(0, runner._running - 1);
        if (code === 0) {
            runner.scriptExited(p.key, 0, "");
            p.destroy();
            return;
        }
        journalComp.createObject(runner, {
            key: p.key,
            name: p.name,
            unit: p.unit,
            code: code,
            fallback: errText.trim().split("\n").pop() || ""
        });
        p.destroy();
    }

    function _report(key, name, code, line) {
        // the program's own last line when it left one, else the plain fact (CLAUDE.md, Wording)
        const body = line.length > 0 ? line : "It stopped with exit code " + code;
        if (runner.notifier)
            runner.notifier.notify(runner.notifyKey, {
                title: name + " failed",            // a script that ran and failed (an app that cannot start is said elsewhere)
                body: body,
                urgency: "normal",
                timeoutMs: 10000
            });
        runner.scriptExited(key, code, body);
    }

    Component {
        id: procComp
        Process {
            id: sp
            property string key: ""
            property string name: ""
            property string unit: ""
            running: false
            stdout: StdioCollector {}
            stderr: StdioCollector {
                id: errC
            }
            property Connections _exit: Connections {
                target: sp
                function onExited(exitCode) {
                    runner._finished(sp, exitCode, String(errC.text || ""));
                }
            }
        }
    }

    // The journal is read once, and once more 250 ms later if the script's
    // last line had not landed yet; then the systemd-run's own complaint (a
    // unit that could not start), then the exit code.
    Component {
        id: journalComp
        Process {
            id: jp
            property string key: ""
            property string name: ""
            property string unit: ""
            property int code: 0
            property string fallback: ""
            property int tries: 0
            running: false
            stdout: StdioCollector {
                id: jout
            }
            function start() {
                jp.tries += 1;
                jp.command = runner.journalArgv(jp.unit);
                jp.running = true;
            }
            property Connections _exit: Connections {
                target: jp
                function onExited() {
                    const line = String(jout.text || "").replace(/\s+$/, "").split("\n").pop() || "";
                    if (line.length === 0 && jp.tries < 2) {
                        jp.retry.restart();
                        return;
                    }
                    runner._report(jp.key, jp.name, jp.code, line.length > 0 ? line : jp.fallback);
                    jp.destroy();
                }
            }
            property Timer retry: Timer {
                interval: 250
                onTriggered: jp.start()
            }
            Component.onCompleted: jp.start()
        }
    }
}
