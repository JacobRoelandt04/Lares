pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/lockscreen/veil"

// =============================================================================
// tools/dev/qml/veil_perf_pixels.qml -- the lock's veils rendered at held clock times at any size, for
// tools/dev/perf/veil_pixels.sh (a performance change's pixel proof: the same jobs on the base tree and on the changed one).
//
// One VeilStage (the stand-in lock screen) filling a W x H window, its clock stopped and SEEKED, so every frame is a pure
// function of the job. The job format is tools/dev/qml/lockveil_render.qml's:
//   {name, veil, t, boot?, popup?, presence?, pulses?: [{kind, x, y, t}], steps?: [t | {t, popup}]}
// `steps` walks the clock forward through those times first (one frame each), as the lock's clock only runs forward: what a
// veil keeps a record of (the dials' re-cuts, the gooey's arrival) is written at the first time that sees it.
//   JOBS=<file.json>  OUT=<dir>  W=2880  H=1620
// Prints VP_PIXELS RESULT PASS once every job is written.
// =============================================================================
ShellRoot {
    id: shellRoot

    settings.watchFiles: false

    FloatingWindow {
        id: win
        implicitWidth: parseInt(Quickshell.env("W") || "2880")
        implicitHeight: parseInt(Quickshell.env("H") || "1620")
        visible: true
        color: "black"

        readonly property string outDir: Quickshell.env("OUT") || "/tmp/veil_pixels"
        property var jobs: []
        property int index: -1
        property int waitFrames: 0

        VeilStage {
            id: stage
            width: win.implicitWidth
            height: win.implicitHeight
            proposal: "relief"
            clockRunning: false
            autoIdle: false
            awake: true
        }

        FileView {
            id: jobsFile
            path: Quickshell.env("JOBS") || ""
            blockLoading: true
            printErrors: false
        }

        function setUp(j) {
            stage.boot = !!j.boot;
            stage.showPopup = j.popup === undefined ? true : !!j.popup;
            stage.presence = j.presence === undefined ? 1 : j.presence;
            if (stage.proposal !== j.veil)
                stage.proposal = j.veil;
            stage.veil.clearPulses();
            stage.veil.seek(0, 1);
            for (const p of (j.pulses || []))
                stage.veil.injectPulse(p.kind, p.x, p.y, p.t);
            for (const s of (j.steps || [])) {
                if (typeof s === "object") {
                    stage.showPopup = !!s.popup;
                    stage.veil.seek(s.t, 1);
                } else {
                    stage.veil.seek(s, 1);
                }
            }
            stage.veil.seek(j.t, 1);
        }

        function next() {
            win.index++;
            if (win.index >= win.jobs.length) {
                console.log("VP_PIXELS RESULT PASS (" + win.jobs.length + " job(s))");
                quitTimer.start();
                return;
            }
            win.setUp(win.jobs[win.index]);
            win.waitFrames = 3;
        }
        function finish() {
            const j = win.jobs[win.index];
            const ok = stage.grabToImage(function (res) {
                res.saveToFile(win.outDir + "/" + j.name + ".png");
                win.next();
            });
            if (!ok) {
                console.log("VP_PIXELS RESULT FAIL (grabToImage refused " + j.name + ")");
                quitTimer.start();
            }
        }
        Timer {
            interval: 40
            repeat: true
            running: win.waitFrames > 0
            onTriggered: {
                win.waitFrames--;
                if (win.waitFrames === 0)
                    win.finish();
            }
        }
        Timer {
            id: quitTimer
            interval: 0
            onTriggered: Qt.quit()
        }
        Timer {
            id: startTimer
            interval: 200
            onTriggered: {
                try {
                    win.jobs = JSON.parse(jobsFile.text());
                } catch (e) {
                    console.log("VP_PIXELS RESULT FAIL (no jobs: " + e + ")");
                    quitTimer.start();
                    return;
                }
                win.next();
            }
        }
        Component.onCompleted: startTimer.start()
    }
}
