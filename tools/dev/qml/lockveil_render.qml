pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/lockscreen/veil"

// =============================================================================
// tools/dev/qml/lockveil_render.qml -- the lock's veils rendered at held clock times, and the paper
// veil's motion read out, for tools/dev/lockveil_render.sh (sheets, long runs, films) and
// tools/dev/lockveil_paper_check.py (the cascade's margins).
//
// One VeilStage (the stand-in lock screen: the blurred desktop fixture, the veil, the popup's
// silhouette) at the real 2880 x 1620. Its clock is stopped and SEEKED, so every frame is a pure
// function of the job: the same job renders the same picture on any tree (old or new).
//
//   JOBS=<file.json>   a list of jobs, each {name, veil, t, boot?, popup?, presence?, arrive?, pulses?, dump?, grab?}
//                        veil      relief | gooey | dimples | paper | louvres | keycaps | dials
//                        t         veil seconds the clock is seeked to
//                        boot      the veil opaque, no still (a boot lock)            default false
//                        popup     the popup and bar silhouette shown                  default true
//                        presence  0..1                                                 default 1
//                        arrive    veil seconds the shell arrives at (VeilStage.arriveAt; -1 = there from the start)
//                        pulses    [{kind, x, y, t}] injected at those veil times (after a clearPulses)
//                        steps     seek to each of these veil times before `t` ({t, popup}: and show the popup or not from
//                                  then on: a shell that goes), one frame each (a film walks a clock that
//                                  only runs forward, as the lock's does: a veil that keeps a record of a change, the gooey's
//                                  arrival, writes it at the first time that sees it)
//                        dump      true: the paper veil's motion is written to <OUT>/<name>.json (no grab unless `grab`)
//                        grab      default true unless `dump`
//   OUT=<dir>          where the PNGs and dumps go
//   SWEEP=<file.json>  {veil:"paper", ranges: [{from, to, every}], pulses?}: the paper veil's motion at every `every`
//                      veil seconds of each range, in time order, one JSON line each, to <OUT>/sweep.jsonl, no grabs
//                      (tools/dev/lockveil_paper_check.py's input)
//
// Prints LOCKVEIL_RENDER RESULT PASS once every job is written (a job whose grab never lands fails the run by its
// deadline in the runner). Offscreen with QT_QUICK_BACKEND=rhi, or a ShaderEffect draws as nothing.
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

        readonly property string outDir: Quickshell.env("OUT") || "/tmp/lockveil_render"
        property var jobs: []
        property int index: -1
        property int waitFrames: 0
        property var sweep: null

        VeilStage {
            id: stage
            anchors.fill: parent
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
        FileView {
            id: sweepFile
            path: Quickshell.env("SWEEP") || ""
            blockLoading: true
            printErrors: false
        }
        FileView {
            id: writer
            printErrors: true
        }

        function paperState(v) {
            const p = v ? v.item : null;
            if (!p || p._off === undefined)
                return null;
            const keys = [];
            for (const k of p._fx.keys)
                keys.push([k.x, k.y, k.z, k.w]);
            return {
                t: v.time, off: p._off, lev: p._lev, unit: p._unit, w: p.width, h: p.height,
                patternScale: p.patternScale, levelStep: p.levelStep, sheetMargin: p.sheetMargin, swellCap: p.swellCap,
                edgeSwell: p.edgeSwell, keySpeed: p.keySpeed, keyWidth: p.keyWidth, keyHeight: p.keyHeight,
                keyCycles: p.keyCycles, layerDelay: p.layerDelay, gradUnit: p._gradUnit, sway: p._sway,
                failEnv: p._fx.failEnv, wakeEnv: p._fx.wakeEnv, keys: keys
            };
        }

        function setUp(j) {
            stage.boot = !!j.boot;
            stage.showPopup = j.popup === undefined ? true : !!j.popup;
            stage.presence = j.presence === undefined ? 1 : j.presence;
            // (a tree before the arrival existed has no arriveAt: the old side of a sheet)
            if ("arriveAt" in stage)
                stage.arriveAt = j.arrive === undefined ? -1 : j.arrive;
            if (stage.proposal !== j.veil)
                stage.proposal = j.veil;
            stage.veil.clearPulses();
            stage.veil.seek(0, 1);
            for (const s of (j.steps || [])) {
                // a step is a veil time, or {t, popup}: the popup shown or not from that time on (a shell that goes)
                if (typeof s === "object") {
                    stage.showPopup = !!s.popup;
                    stage.veil.seek(s.t, 1);
                } else {
                    stage.veil.seek(s, 1);
                }
            }
            for (const p of (j.pulses || []))
                stage.veil.injectPulse(p.kind, p.x, p.y, p.t);
            stage.veil.seek(j.t, 1);
        }

        function next() {
            win.index++;
            if (win.index >= win.jobs.length) {
                console.log("LOCKVEIL_RENDER RESULT PASS (" + win.jobs.length + " job(s))");
                quitTimer.start();
                return;
            }
            const j = win.jobs[win.index];
            win.setUp(j);
            win.waitFrames = 3;
        }
        function finish() {
            const j = win.jobs[win.index];
            if (j.dump) {
                writer.path = win.outDir + "/" + j.name + ".json";
                writer.setText(JSON.stringify(win.paperState(stage.veil)));
            }
            const grab = j.grab === undefined ? !j.dump : !!j.grab;
            if (!grab) {
                win.next();
                return;
            }
            const ok = stage.grabToImage(function (res) {
                res.saveToFile(win.outDir + "/" + j.name + ".png");
                console.log("LOCKVEIL_RENDER saved " + j.name);
                win.next();
            });
            if (!ok) {
                console.log("LOCKVEIL_RENDER RESULT FAIL (grabToImage refused " + j.name + ")");
                quitTimer.start();
            }
        }
        // A few ticks for a veil to load and its uniforms to land (grabToImage renders the frame it returns).
        Timer {
            id: frameTick
            interval: 40
            repeat: true
            running: win.waitFrames > 0
            onTriggered: {
                win.waitFrames--;
                if (win.waitFrames === 0)
                    win.finish();
            }
        }

        function runSweep(s) {
            stage.boot = false;
            stage.showPopup = true;
            stage.presence = 1;
            stage.proposal = s.veil || "paper";
            stage.veil.clearPulses();
            for (const p of (s.pulses || []))
                stage.veil.injectPulse(p.kind, p.x, p.y, p.t);
            const lines = [];
            const times = [];
            for (const r of (s.ranges || [{ from: s.from, to: s.to, every: s.every }]))
                for (let t = r.from; t <= r.to + 1e-9; t += r.every)
                    times.push(t);
            times.sort((x, y) => x - y);
            for (const t of times) {
                stage.veil.seek(t, 1);
                const st = win.paperState(stage.veil);
                if (!st) {
                    console.log("LOCKVEIL_RENDER RESULT FAIL (the sweep's veil has no motion to read)");
                    quitTimer.start();
                    return;
                }
                lines.push(JSON.stringify(st));
            }
            writer.path = win.outDir + "/sweep.jsonl";
            writer.setText(lines.join("\n") + "\n");
            console.log("LOCKVEIL_RENDER RESULT PASS (sweep of " + lines.length + " sample(s))");
            quitTimer.start();
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
                if (sweepFile.path !== "") {
                    win.runSweep(JSON.parse(sweepFile.text()));
                    return;
                }
                try {
                    win.jobs = JSON.parse(jobsFile.text());
                } catch (e) {
                    console.log("LOCKVEIL_RENDER RESULT FAIL (no jobs: " + e + ")");
                    quitTimer.start();
                    return;
                }
                win.next();
            }
        }
        Component.onCompleted: startTimer.start()
    }
}
