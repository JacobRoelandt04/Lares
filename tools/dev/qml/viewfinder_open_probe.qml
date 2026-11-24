pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/player/components"

// =============================================================================
// tools/dev/qml/viewfinder_open_probe.qml -- the player's scrub bar when the popup OPENS on a playing track
// (tools/dev/viewfinder_open_probe.sh runs it). Prints VFO lines and "VFO RESULT PASS|FAIL".
//
// The user's path: the popup was closed for a while, so the player's `elapsed` is stale (the clock is not running with nobody
// looking). The rail is born on it, and the open corrects it twice -- the first holder of the clock catches it up by the
// unwatched time (a jump), then the status read seats it again (a few tenths of a second). Neither is a seek: no spark may
// fly in the first second. A real seek after the grace still sparks. `holdAt` / `readAt` are when, after the rail is born, the
// two corrections arrive (0: in the same turn as the birth).
// =============================================================================
Scope {
    id: root
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("VFO " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // the player's side: `elapsed` as MpdService serves it
    QtObject {
        id: src
        property real elapsed: 40
        property real duration: 240
    }
    // the clock runs only while held, as MpdService's does (here: from the hold on)
    Timer {
        id: clock
        interval: 100
        repeat: true
        onTriggered: src.elapsed += 0.1
    }

    property bool built: false
    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 460
        implicitHeight: 80
        color: Theme.surface
        Loader {
            id: ld
            x: 10
            y: 20
            width: 440
            active: root.built
            sourceComponent: PlayerViewfinder {
                id: vf
                height: implicitHeight
                position: src.elapsed
                duration: src.duration
                playing: true
                seekable: true
            }
        }
    }

    // ---- the cases ------------------------------------------------------------------------------------------
    property var cases: [
        { name: "open, corrections in the build's turn", holdAt: 0, readAt: 15, jump: 95 },
        { name: "open, corrections a few frames on", holdAt: 50, readAt: 90, jump: 95 },
        { name: "open, a late status read", holdAt: 30, readAt: 260, jump: 95 }
    ]
    property int ci: -1
    property real t0: 0
    property int sparksAtBirth: 0
    property bool holdDone: false
    property bool readDone: false
    property bool seekDone: false
    property bool firstChecked: false
    property int sparksBeforeSeek: 0

    function begin(i: int): void {
        root.ci = i;
        const c = root.cases[i];
        root.built = false;
        src.elapsed = 40;
        clock.stop();
        root.holdDone = false;
        root.readDone = false;
        root.seekDone = false;
        root.firstChecked = false;
        startTimer.start();
    }
    Timer {
        id: startTimer
        interval: 200
        onTriggered: {
            root.built = true;
            root.t0 = Date.now();
            stepper.start();
            if (root.cases[root.ci].holdAt === 0)
                root.hold();
        }
    }
    function hold(): void {
        root.holdDone = true;
        src.elapsed += root.cases[root.ci].jump;          // MpdService._catchUp()
        clock.start();
    }
    function readAnswer(): void {
        root.readDone = true;
        src.elapsed += 0.9;                                  // _seatElapsed: the daemon was ahead by more than the tolerance
    }
    Timer {
        id: stepper
        interval: 5
        repeat: true
        onTriggered: {
            const c = root.cases[root.ci];
            const dt = Date.now() - root.t0;
            const vf = ld.item as PlayerViewfinder;
            if (!vf)
                return;
            if (!root.holdDone && dt >= c.holdAt)
                root.hold();
            if (!root.readDone && dt >= c.readAt)
                root.readAnswer();
            if (!root.firstChecked && dt >= 1000) {
                root.firstChecked = true;
                root.sparksBeforeSeek = vf.sparkCount;
                root.check(c.name + ": no sparks in the first second", vf.sparkCount === 0, "sparks " + vf.sparkCount);
            }
            // past the grace (it ends a quiet after the last jump), a real seek
            if (root.firstChecked && !root.seekDone && dt >= 2600) {
                root.seekDone = true;
                src.elapsed += 100;                           // a seek the host reports
            }
            if (root.seekDone && dt >= 2600 + 900) {
                stepper.stop();
                root.check(c.name + ": a seek after the grace still sparks", vf.sparkCount > root.sparksBeforeSeek, "sparks " + vf.sparkCount + " before " + root.sparksBeforeSeek);
                root.next();
            }
        }
    }
    function next(): void {
        if (root.ci + 1 < root.cases.length) {
            root.begin(root.ci + 1);
            return;
        }
        console.log("VFO RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }
    Timer {
        interval: 800
        running: true
        onTriggered: root.begin(0)
    }
}
