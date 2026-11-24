pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SleepWatcher.qml
//
// Tells the shell when the machine suspends and when it is back, by following
// logind's `PrepareForSleep(b start)` on the SYSTEM bus: `true` right before a
// suspend/hibernate, `false` right after it (logind(5): "sent right before
// (with the argument true) or after (with the argument false) the system goes
// down for ... suspend/hibernate").
//
//   aboutToSleep()   PrepareForSleep(true) -- once per sleep
//   resumed()        PrepareForSleep(false) -- EVERY one, paired or not (a
//                    watcher that restarted between the two missed the true;
//                    a consumer's refresh is idempotent, a missed one is not)
//   sleeping         true between the two
//   watching         the monitor runs and has seen logind on the bus
//   enabled          run the monitor (default true)
//   bus              "system" (default; where logind lives) or "session" --
//                    only for a probe's PRIVATE bus with a stand-in logind
//   monitorCommand   the monitor's argv (gdbus monitor on `bus`); a probe
//                    points it at a stub printing byte-exact gdbus lines
//   feed(text)       one chunk of monitor output, parsed exactly as the
//                    monitor's own is -- a probe's byte-exact line goes in here,
//                    whether or not the monitor runs
//
// ONE PER SHELL. Every BoundaryClock follows the shell's one watcher,
// `Sleep.watcher` (modules/common/system/Sleep.qml), with no wiring by its
// host; build a SleepWatcher of your own only for a probe.
//
// WHY IT EXISTS. Qt's timers run on CLOCK_MONOTONIC, which does not advance
// while the machine is suspended (measured on this laptop: 12.0 h of suspend
// in one boot that CLOCK_MONOTONIC never counted -- CLOCK_BOOTTIME minus
// CLOCK_MONOTONIC). A single-shot Timer armed for "3 min" before a two-hour
// suspend fires three minutes AFTER the resume, so anything that shows the
// wall clock relative to now (BoundaryClock's "3 min", "2 h") is stale until
// then. A resume is the one moment everything wall-based must be re-read.
//
// THE SOURCE, measured (gdbus 2.88 / systemd 261):
//
//   Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1
//   The name org.freedesktop.login1 is owned by :1.4
//   /org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)
//   /org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)
//   The name org.freedesktop.login1 does not have an owner
//
// The first two lines come in ONE read at start. Each signal is its own line,
// flushed as it is emitted even into a pipe (arrival within 1 ms of the emit).
// The monitor itself filters by sender (it matches on the owner's UNIQUE name,
// so a PrepareForSleep emitted by anybody else never prints) and by object
// path, and it keeps running when logind leaves the bus. What it sends on the
// bus is only to the bus daemon -- Hello, AddMatch, StartServiceByName,
// GetNameOwner, RemoveMatch -- never a call to logind (measured with
// dbus-monitor): nothing here can inhibit, delay or
// trigger a sleep.
//
// PARSING. A line is matched WHOLE, never by substring: another signal's
// arguments can carry any text, including this exact line
// (`PropertiesChanged (..., {'x': <'/org/freedesktop/login1: ...PrepareForSleep
// (false,)'>}, ...)` is a real gdbus rendering). `PreparingForSleep` has
// EmitsChangedSignal("false"), so no PropertiesChanged ever reports a sleep.
// Each slice is split on "\n" again (Quickshell 0.3.1's SplitParser can hand
// over two lines in one slice, CLAUDE.md).
//
// LIFETIME. `setpriv --pdeathsig TERM` so the monitor dies with the shell,
// however the shell dies. If the monitor
// exits on its own (the system bus restarted, gdbus missing), it is started
// again after 1 s, doubling to 60 s while it keeps failing, with one warning
// per failing streak; a monitor that ran for a minute was working, and its
// exit starts a new streak (a header alone proves nothing: a monitor that
// prints one and dies would restart every second). A monitor lost mid-sleep,
// or logind leaving the bus mid-sleep, can no longer report the end of that
// sleep, so the sleep is taken as over (`resumed()`).
// =============================================================================
QtObject {
    id: root

    property bool enabled: true
    property string bus: "system"
    property var monitorCommand: ["setpriv", "--pdeathsig", "TERM", "--", "gdbus", "monitor",
        root.bus === "session" ? "--session" : "--system",
        "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]

    readonly property bool sleeping: root._sleeping
    readonly property bool watching: root._owner !== ""

    signal aboutToSleep
    signal resumed

    function feed(text) {
        const lines = String(text).split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].replace(/\s+$/, "");
            const sleep = /^\/org\/freedesktop\/login1: org\.freedesktop\.login1\.Manager\.PrepareForSleep \((true|false),\)$/.exec(line);
            if (sleep) {
                if (sleep[1] === "true")
                    root._sleepStarted();
                else
                    root._sleepEnded();
                continue;
            }
            const owned = /^The name org\.freedesktop\.login1 is owned by (\S+)$/.exec(line);
            if (owned)
                root._owner = owned[1];
            else if (line === "The name org.freedesktop.login1 does not have an owner")
                root._lost();
        }
    }

    property bool _sleeping: false
    // logind's unique name while the monitor sees it, "" otherwise.
    property string _owner: ""

    function _sleepStarted() {
        if (root._sleeping)
            return;
        root._sleeping = true;
        root.aboutToSleep();
    }
    function _sleepEnded() {
        root._sleeping = false;
        root.resumed();
    }
    // Whoever would have said "false" is gone.
    function _lost() {
        root._owner = "";
        if (root._sleeping)
            root._sleepEnded();
    }

    // ---- the monitor ---------------------------------------------------------
    // Supervision (restart, backoff, the one warning per failing streak, the
    // re-split lines) is SupervisedStream's. Every exit, expected or not, is a lost monitor.
    property SupervisedStream _stream: SupervisedStream {
        enabled: root.enabled
        command: root.monitorCommand
        what: "SleepWatcher: the sleep monitor"
        onLine: text => root.feed(text)
        onExited: (code, expected) => root._lost()
    }
}
