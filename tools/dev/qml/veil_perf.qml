pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "modules/lockscreen/veil"

// =============================================================================
// tools/dev/qml/veil_perf.qml -- what a frame of each lock veil costs, for tools/dev/perf/veil_perf.sh, which runs it as a
// client of tools/dev/lock_env.sh's nested Hyprland (a vsync-paced Wayland client, the lock's own GL path: NVIDIA's GLES here)
// with tools/dev/perf/veil_gputime.c preloaded (each frame's GPU time) and Qt's own per-frame lines on (QSG_RENDER_TIMING).
//
// One VeilStage (the stand-in lock screen: the blurred desktop fixture, the veil, the popup's silhouette) on a layer surface
// that covers the output, as the lock's surface does. Its clock is stopped and SEEKED by a Timer at FPS (the lock's own tick:
// the veil is a pure function of the host's time, so this is the lock's frame sequence), one phase per veil, the veils
// interleaved over ROUNDS so a drift of the machine (other sessions test on it) lands on every veil alike. "none" is the stage
// with no veil: the floor (one pixel changes per tick so it draws a frame per tick too).
//
//   VEILS=none,relief,gooey,dimples,paper,louvres,keycaps,dials   ROUNDS=3   PHASE_MS=4000   WARM_MS=800   FPS=60
//   BOOT=0 (1: opaque veil, no still)   POPUP=1   PULSES=0 (1: a key pulse every 150 ms, typing)
//   GUI_N=400 (seeks timed back to back per veil and round: the GUI thread's share of a tick, bindings only)
//   AB=1 (tools/dev/perf/veil_perf.sh --ab DIR): a name "b:<veil>" is that veil from the other tree (stage B)
//   STILL_MS=0 (> 0: after the rounds, every veil runs its own clock live, rests after 1.5 s, and the frames drawn in the
//              STILL_MS after the rest's ease are counted: must be 0; "none" is the harness's own floor)
//
// Prints, with --log-times stamps:
//   VP first <veil> <round> loadMs=<setSource to Ready> frameMs=<setSource to the first frame swapped with it>
//   VP phase <veil> <round> measure      (the warm-up is over: frames from here belong to this phase)
//   VP phase <veil> <round> end frames=<n>
//   VP gui <veil> <round> n=<n> ms=<total>
//   VP still <veil> frames=<n> ms=<window> resting=<bool>
//   VP done
// =============================================================================
ShellRoot {
    id: shellRoot

    settings.watchFiles: false

    PanelWindow {
        id: win
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "veil-perf"
        color: "black"

        readonly property var veils: (Quickshell.env("VEILS") || "none,relief,gooey,dimples,paper,louvres,keycaps,dials").split(",")
        readonly property int rounds: parseInt(Quickshell.env("ROUNDS") || "3")
        readonly property int phaseMs: parseInt(Quickshell.env("PHASE_MS") || "4000")
        readonly property int warmMs: parseInt(Quickshell.env("WARM_MS") || "800")
        readonly property real fps: parseFloat(Quickshell.env("FPS") || "60")
        readonly property bool pulses: Quickshell.env("PULSES") === "1"
        readonly property int guiN: parseInt(Quickshell.env("GUI_N") || "400")
        readonly property int stillMs: parseInt(Quickshell.env("STILL_MS") || "0")

        property int round: 0
        property int at: -1
        property string cur: ""
        property bool measuring: false
        property int frames: 0
        property real vt: 0
        property real lastPulse: 0
        // the first frame of a phase
        property real setAt: 0
        property real readyAt: 0
        property bool waitFirst: false

        // the still phase
        property int stillAt: -1
        property bool stillCounting: false
        property int stillFrames: 0
        // a swap counts at rest only after an afterAnimating inside the window (the swaps of frames drawn before it arrive queued)
        property bool stillAnimated: false

        // A: this tree's veils. B (AB=1): another tree's, beside them in the same process (modules/lockscreen/veil_b, whose
        // shaders are shaders_b: tools/dev/perf/veil_perf.sh --ab builds the copy and VeilPerfB.qml), so a phase of one and a
        // phase of the other share the GPU's clock state and the machine's load: an A/B of two runs moves with the driver.
        readonly property bool ab: Quickshell.env("AB") === "1"
        readonly property bool useB: win.cur.indexOf("b:") === 0
        // (var: B's VeilStage is another directory's type)
        readonly property var stageBItem: stageB.item
        readonly property var stage: win.useB ? win.stageBItem : stageA
        VeilStage {
            id: stageA
            anchors.fill: parent
            visible: !win.useB
            proposal: ""
            boot: Quickshell.env("BOOT") === "1"
            showPopup: Quickshell.env("POPUP") !== "0"
            clockRunning: false
            autoIdle: false
            awake: true
        }
        Loader {
            id: stageB
            anchors.fill: parent
            visible: win.useB
            active: win.ab
            source: win.ab ? Qt.resolvedUrl("VeilPerfB.qml") : ""
            onLoaded: {
                const b = win.stageBItem;
                b.proposal = "";
                b.boot = Quickshell.env("BOOT") === "1";
                b.showPopup = Quickshell.env("POPUP") !== "0";
                b.clockRunning = false;
                b.autoIdle = false;
                b.awake = true;
            }
        }
        // one pixel that changes every tick, so the floor ("none") draws a frame per tick too
        Rectangle {
            width: 2
            height: 2
            color: Math.floor(win.vt * win.fps) % 2 === 1 ? "#010101" : "black"
        }

        function _name(v) { return v === "none" ? "" : v.replace(/^b:/, ""); }
        function _ready() {
            return win.cur === "none" || (win.stage.veil.item !== null && win.stage.veil.item !== undefined);
        }

        function nextPhase() {
            win.at++;
            if (win.at >= win.veils.length) {
                win.at = 0;
                win.round++;
            }
            if (win.round >= win.rounds) {
                if (win.stillMs > 0) {
                    win.nextStill();
                    return;
                }
                console.log("VP done");
                quitTimer.start();
                return;
            }
            // the stage left behind loads nothing (it is hidden and its veil goes)
            stageA.proposal = "";
            if (win.stageBItem)
                win.stageBItem.proposal = "";
            // odd rounds run the list backwards (A B, then B A): a drift of the machine over a round lands on both alike
            win.cur = win.veils[win.round % 2 === 1 ? win.veils.length - 1 - win.at : win.at];
            win.measuring = false;
            win.frames = 0;
            win.vt = 0;
            win.lastPulse = 0;
            win.readyAt = 0;
            win.setAt = Date.now();
            win.waitFirst = true;
            win.stage.proposal = win._name(win.cur);
            if (win._ready())
                win.readyAt = Date.now();
            win.stage.veil.clearPulses();
            win.stage.veil.seek(0, 1);
            warmTimer.restart();
        }
        Connections {
            target: win.stage ? win.stage.veil : null
            function onItemChanged() {
                if (win.waitFirst && win._ready() && win.readyAt === 0)
                    win.readyAt = Date.now();
            }
        }
        Timer {
            id: warmTimer
            interval: win.warmMs
            onTriggered: {
                console.log("VP phase " + win.cur + " " + win.round + " measure");
                win.measuring = true;
                win.frames = 0;
                phaseTimer.restart();
            }
        }
        Timer {
            id: phaseTimer
            interval: win.phaseMs
            onTriggered: {
                win.measuring = false;
                console.log("VP phase " + win.cur + " " + win.round + " end frames=" + win.frames);
                win.timeGui();
                win.nextPhase();
            }
        }
        // the lock's own tick: one seek per 1/fps
        Timer {
            id: tick
            interval: Math.max(1, Math.round(1000 / Math.max(1, win.fps)))
            repeat: true
            running: win.cur !== "" && win.stillAt < 0
            onTriggered: {
                win.vt += 1 / win.fps;
                if (win.pulses && win.vt - win.lastPulse >= 0.15) {
                    win.lastPulse = win.vt;
                    win.stage.veil.injectPulse("key", win.stage.fieldPoint.x, win.stage.fieldPoint.y, win.vt);
                }
                win.stage.veil.seek(win.vt, 1);
            }
        }
        // the GUI thread's share of a tick: the bindings a seek re-runs, timed back to back (no frame between)
        function timeGui() {
            if (win.guiN <= 0)
                return;
            const t0 = Date.now();
            let t = win.vt;
            for (let i = 0; i < win.guiN; i++) {
                t += 1 / win.fps;
                if (win.pulses && t - win.lastPulse >= 0.15) {
                    win.lastPulse = t;
                    win.stage.veil.injectPulse("key", win.stage.fieldPoint.x, win.stage.fieldPoint.y, t);
                }
                win.stage.veil.seek(t, 1);
            }
            console.log("VP gui " + win.cur + " " + win.round + " n=" + win.guiN + " ms=" + (Date.now() - t0));
            win.vt = t;
        }

        // ---- still: the real clock, at rest, must draw nothing ------------------------------------------------
        function nextStill() {
            win.stillAt++;
            const vs = win.veils;
            if (win.stillAt >= vs.length) {
                console.log("VP done");
                quitTimer.start();
                return;
            }
            win.cur = vs[win.stillAt];
            win.stage.proposal = win._name(win.cur);
            win.stage.veil.clearPulses();
            win.stage.awake = true;
            win.stage.clockRunning = true;
            win.stillCounting = false;
            win.stillFrames = 0;
            restTimer.restart();
        }
        Timer {
            id: restTimer
            interval: 1500
            onTriggered: {
                win.stage.awake = false;
                // the ease to still (restEaseMs) and a little more
                countTimer.interval = win.stage.veil.restEaseMs + 300;
                countTimer.restart();
            }
        }
        Timer {
            id: countTimer
            onTriggered: {
                if (!win.stillCounting) {
                    win.stillCounting = true;
                    win.stillAnimated = false;
                    win.stillFrames = 0;
                    countTimer.interval = win.stillMs;
                    countTimer.restart();
                    return;
                }
                win.stillCounting = false;
                console.log("VP still " + win.cur + " frames=" + win.stillFrames + " ms=" + win.stillMs + " resting=" + win.stage.veil.resting);
                win.stage.clockRunning = false;
                win.nextStill();
            }
        }

        // the first frame DRAWN after the veil exists: a swap is counted only after an afterAnimating since then (a queued
        // swap signal of a frame drawn before would end the wait at once)
        property bool firstAnimated: false
        Connections {
            target: stageA.Window.window
            function onAfterAnimating() {
                if (win.waitFirst && win.readyAt > 0)
                    win.firstAnimated = true;
                if (win.stillCounting)
                    win.stillAnimated = true;
            }
            function onFrameSwapped() {
                if (win.waitFirst && win.firstAnimated) {
                    win.waitFirst = false;
                    win.firstAnimated = false;
                    const now = Date.now();
                    console.log("VP first " + win.cur + " " + win.round + " loadMs=" + (win.readyAt - win.setAt) + " frameMs=" + (now - win.setAt));
                }
                if (win.measuring)
                    win.frames++;
                if (win.stillCounting && win.stillAnimated) {
                    win.stillFrames++;
                    console.log("VP stillframe " + win.cur + " at=" + Date.now());
                }
            }
        }

        Timer {
            id: quitTimer
            interval: 0
            onTriggered: Qt.quit()
        }
        Timer {
            id: startTimer
            interval: 1500
            onTriggered: win.nextPhase()
        }
        Component.onCompleted: startTimer.start()
    }
}
