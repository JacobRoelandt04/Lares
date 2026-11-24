pragma ComponentBehavior: Bound

import QtQuick

import "../components"
import "PackageJobRules.js" as Rules

// =============================================================================
// PackageJobWatch.qml -- is somebody installing, updating, removing or building packages right now? ONE per shell (ShellServices), read by
// the idle auto layer (IdleAuto: a package job asks for soft, so the machine does not suspend under it).
//
// WHAT IT SEES (PackageJobRules.js has the rules): a pacman / yay / paru command line that is a transaction (the restart guard's rule, one table
// of cases for both), a makepkg build, and a GUI package manager's lock (pamac, PackageKit). It does NOT see checkupdates' `pacman -Sy
// --dbpath <a copy>` (the shell's own update check, every few minutes), `yay -Qua`, a search or a query.
//
// WHY A PROCESS LOOK AND NOT ONLY /var/lib/pacman/db.lck. pacman holds the lock only for its own transaction: an AUR build (yay
// downloading, makepkg compiling for many minutes, yay at its own prompts) holds none, and a crashed pacman leaves the file behind for ever.
// So the lock is read WITH the processes (pkgjobs.py): a lock counts alone only while a GUI package manager's daemon runs.
//
// COST. One long-lived python child (`pkgjobs.py`) that reads /proc in its own process every `intervalS` seconds and prints a line only when
// the picture changes: no fork per look, at rest the shell reads nothing. Not watching (a mock shell, a probe's default): no process runs.
//
// ONLY A LONG JOB COUNTS (`minAgeMs`, 2 minutes -- the user's rule, as for downloads: a short install ends before a suspend could hurt it).
// The age runs from the first look that saw a job; no job at all for `gapMs` begins a new one. One single-shot timer is armed for the
// instant a young job comes of age.
//
// THE SHELL'S OWN UPDATE IS NOT THIS CAUSE. A job whose process tree has `ownPid` (the update's supervisor) among its ancestors is the shell's
// own run: IdleAuto already holds soft for it as "System update running" (`update`), at once. It is not counted here, so one run is one cause with
// its own words, never a second generic one. `ownRun` (a shell-run update goes) with no `ownPid` known counts nothing: no job can be told from it.
//
//   watch     watch at all (the host binds the shell being live)
//   ownPid    the system update supervisor's pid (0 = unknown);  ownRun  the shell's own update goes
//   active    a job that is not the shell's own has run long enough;  what  its words ("Building foo (yay)")
// =============================================================================
Item {
    id: root

    property bool watch: false
    property int ownPid: 0
    property bool ownRun: false
    // How long a job must have run before it counts (see the header) and how long without any job begins a new run.
    property int minAgeMs: 120000
    // a new wait (idle.jsonc, read hot) is judged at once, not at the next event
    onMinAgeMsChanged: root._eval()
    property int gapMs: 15000
    property real intervalS: 5
    // Probes: another /proc and lock file, another launcher (the child dies with the shell however it dies).
    property string procRoot: "/proc"
    property string lockPath: "/var/lib/pacman/db.lck"
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]

    readonly property bool active: root._active
    readonly property string what: root._what
    // The shell's own update is seen as a job (for a probe and the census: it is NOT counted).
    readonly property bool ownSeen: root._ownSeen
    // Jobs of others now, in the order they came (young ones too).
    readonly property var jobs: root._jobs

    property bool _active: false
    property string _what: ""
    property bool _ownSeen: false
    property var _jobs: []
    property var _snap: null
    property var _state: Rules.newState()
    // The clock (a probe may pin it: a function returning ms).
    property var clock: null
    function _now(): double {
        return root.clock ? root.clock() : Date.now();
    }

    // Re-judge the last picture with the facts as they stand (a line arrived, the update's pid changed, a timer fired).
    function _eval(): void {
        const now = root._now();
        let list = root._snap ? Rules.jobs(root._snap, root.ownPid > 0 ? [root.ownPid] : [], root.ownRun && root.ownPid <= 0) : [];
        if (!stream.running)
            list = [];
        const others = list.filter(j => !j.own);
        const ownSeen = list.length > others.length;
        if (ownSeen !== root._ownSeen)
            root._ownSeen = ownSeen;
        const pidsNow = others.map(j => j.pid).join();
        if (pidsNow !== root._jobs.map(j => j.pid).join())
            root._jobs = others;
        Rules.observe(root._state, now, others.length > 0, root.gapMs);
        const holds = Rules.holds(root._state, now, root.minAgeMs);
        if (holds !== root._active)
            root._active = holds;
        const words = others.length > 0 ? others[0].what : "";
        if (words !== root._what)
            root._what = words;
        const left = Rules.untilChange(root._state, now, root.minAgeMs);
        if (left > 0) {
            expiry.interval = Math.max(50, Math.ceil(left) + 5);
            expiry.restart();
        } else {
            expiry.stop();
        }
    }
    Timer {
        id: expiry
        onTriggered: root._eval()
    }
    onOwnPidChanged: root._eval()
    onOwnRunChanged: root._eval()

    SupervisedStream {
        id: stream
        enabled: root.watch
        what: "PackageJobWatch: the package job scanner"
        command: root.launcher.concat(["python3", "-u", Qt.resolvedUrl("pkgjobs.py").toString().replace("file://", ""),
            "--proc", root.procRoot, "--lock", root.lockPath, "--interval", String(root.intervalS)])
        onLine: text => {
            if (text === "")
                return;
            try {
                root._snap = JSON.parse(text);
            } catch (e) {
                return;
            }
            root._eval();
        }
        onRunningChanged: {
            if (!stream.running)
                root._eval();
        }
    }
    onWatchChanged: {
        if (!root.watch) {
            root._snap = null;
            root._eval();
        }
    }
}
