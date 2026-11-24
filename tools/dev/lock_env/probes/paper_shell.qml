pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/lockscreen/veil"

// =============================================================================
// paper_shell.qml -- the PAPER veil and the shell's silhouette, frame by frame, for paper_shell_probe.sh (offscreen,
// from a copy of a tree; the runner says how).
//
// The paper veil hosted as the lock hosts it (a LockVeil, its clock stopped and SEEKED, so a frame is a pure function of
// the job), with the bar and the popup rects handed over in any order and at any veil time -- the user's path at a boot:
// the veil alone, then the shell's bar, then its popup opening out of the bar's foot -- and the shell drawn over the veil
// where those rects are, as the shell draws itself over the lock. Every job can be rendered a second time with the veil's
// `stoneShadow` at 0: the two frames differ by the shadow the shell casts and by nothing else, so the probe reads that
// shadow exactly (and finds it where there is no shell at all, or detached from the bar).
//
//   JOBS=<file.json>  [{name, t, presence?, boot?, steps: [{t, bar?, popup?}], noShadow?}]
//                       steps   in time order: seek to t, then hand the veil these rects ([x, y, w, h], null = none;
//                               a key left out keeps what was there) -- a change is recorded at the time that sees it
//                       boot    the veil opaque, nothing behind (default true); false: the blurred desktop fixture behind
//   OUT=<dir>         <name>.png per job
// Prints PAPER_SHELL RESULT PASS once every job is written.
// =============================================================================
ShellRoot {
    id: shellRoot
    settings.watchFiles: false

    FloatingWindow {
        id: win
        implicitWidth: 2880
        implicitHeight: 1620
        visible: true
        color: "black"

        readonly property string outDir: Quickshell.env("OUT") || "/tmp/paper_shell"
        property var jobs: []
        property int index: -1
        property int waitTicks: 0
        property bool boot: true
        property rect barR: Qt.rect(0, 0, 0, 0)
        property rect popupR: Qt.rect(0, 0, 0, 0)
        property real presence: 1
        property string proposal: ""
        // the shell's surface in eva light, the mode the runner seeds (a literal: this harness's imports resolve only in the
        // runner's copy, where the theme is not the point)
        readonly property color shellColor: "#eaedf5"

        Item {
            id: stage
            width: win.width
            height: win.height
            Rectangle {
                anchors.fill: stage
                color: "black"
            }
            Image {
                id: still
                anchors.fill: stage
                visible: !win.boot
                source: "file://" + Quickshell.env("FIXTURE")
                fillMode: Image.Stretch
                asynchronous: false
            }
            LockVeil {
                id: host
                anchors.fill: stage
                proposal: win.proposal
                presence: win.presence
                running: false
                awake: true
                opaque: win.boot
                still: win.boot ? null : still
                popupRect: win.popupR
                barRect: win.barR
            }
            // the shell over the veil, where its rects say (as the shell draws its bar and popup over the lock)
            Rectangle {
                x: win.barR.x
                y: win.barR.y
                width: win.barR.width
                height: win.barR.height
                visible: win.barR.width > 0
                radius: Math.min(20, height / 2)
                color: win.shellColor
            }
            Rectangle {
                x: win.popupR.x
                y: win.popupR.y
                width: win.popupR.width
                height: win.popupR.height
                visible: win.popupR.width > 0 && win.popupR.height > 0
                radius: Math.min(28, height / 2, width / 2)
                color: win.shellColor
            }
        }

        FileView {
            id: jobsFile
            path: Quickshell.env("JOBS") || ""
            blockLoading: true
            printErrors: false
        }

        function toRect(a) {
            return a ? Qt.rect(a[0], a[1], a[2], a[3]) : Qt.rect(0, 0, 0, 0);
        }
        function setUp(j) {
            win.boot = j.boot === undefined ? true : !!j.boot;
            win.barR = Qt.rect(0, 0, 0, 0);
            win.popupR = Qt.rect(0, 0, 0, 0);
            win.presence = j.presence === undefined ? 1 : j.presence;
            // a fresh veil per job: its record of the shell's arrival starts empty
            win.proposal = "";
            win.proposal = "paper";
            host.clearPulses();
            host.seek(0, 1);
            for (const s of (j.steps || [])) {
                host.seek(s.t, 1);
                if ("bar" in s)
                    win.barR = win.toRect(s.bar);
                if ("popup" in s)
                    win.popupR = win.toRect(s.popup);
            }
            host.seek(j.t, 1);
            if (j.noShadow && host.item)
                host.item.stoneShadow = 0;
        }
        function next() {
            win.index++;
            if (win.index >= win.jobs.length) {
                console.log("PAPER_SHELL RESULT PASS (" + win.jobs.length + " job(s))");
                quitTimer.start();
                return;
            }
            win.setUp(win.jobs[win.index]);
            win.waitTicks = 3;
        }
        function finish() {
            const j = win.jobs[win.index];
            const ok = stage.grabToImage(function (res) {
                res.saveToFile(win.outDir + "/" + j.name + ".png");
                win.next();
            });
            if (!ok) {
                console.log("PAPER_SHELL RESULT FAIL (grabToImage refused " + j.name + ")");
                quitTimer.start();
            }
        }
        Timer {
            interval: 40
            repeat: true
            running: win.waitTicks > 0
            onTriggered: {
                win.waitTicks--;
                if (win.waitTicks === 0)
                    win.finish();
            }
        }
        Timer {
            id: quitTimer
            interval: 0
            onTriggered: Qt.quit()
        }
        Timer {
            interval: 300
            running: true
            onTriggered: {
                try {
                    win.jobs = JSON.parse(jobsFile.text());
                } catch (e) {
                    console.log("PAPER_SHELL RESULT FAIL (no jobs: " + e + ")");
                    quitTimer.start();
                    return;
                }
                win.next();
            }
        }
    }
}
