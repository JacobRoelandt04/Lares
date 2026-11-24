pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bridge/body"

// =============================================================================
// tools/dev/qml/bridge_flip_perf.qml -- what a frame of the bridge's phone costs (tools/dev/bridge_flip_perf.sh runs it and
// reads QSG_RENDER_TIMING's lines). One real PhoneStage with text-heavy faces, three phases of PHASE_MS each:
//   rest   the body its cached layer, one pixel elsewhere animating (the window draws a frame per tick: what the phone
//          costs when something ELSE moves)
//   turn   the body held live and turned through a whole revolution, over and over (`pinTurn` on a clock)
//   lit    the body live at rest (what a pointer sliding the light costs)
// and prints each phase's frame gaps (frames, the median and the worst gap, how many gaps were over 25 ms): a number
// only where a compositor paces the frames. Then the cost of ONE frame by grabs (see below), which is a number anywhere.
//   SCALE=1.25  PHASE_MS=2500  GRABS=40  SKIN=<skin>
// =============================================================================
Window {
    id: root

    readonly property real factor: parseFloat(Quickshell.env("SCALE") || "1.25")
    readonly property int phaseMs: parseInt(Quickshell.env("PHASE_MS") || "2500")
    readonly property string skin: Quickshell.env("SKIN") || "redmagic-10s-pro-moonlight"
    property string phase: ""
    property real turn: 0

    width: Math.ceil(320 * root.factor)
    height: Math.ceil(664 * root.factor)
    visible: true
    color: Theme.surface

    Rectangle {
        width: 2
        height: 2
        color: Theme.surface
        RotationAnimation on rotation { from: 0; to: 360; duration: 300; loops: Animation.Infinite }
    }
    NumberAnimation {
        target: root
        property: "turn"
        from: 0
        to: 1
        duration: 1100
        loops: Animation.Infinite
        running: root.phase === "turn"
    }
    ScaleRoot {
        factor: root.factor
        hostWidth: root.width
        hostHeight: root.height
        PhoneStage {
            id: stage
            width: 320
            height: 664
            skin: root.skin
            relight: false
            pinTurn: root.grabPhase === "turn" ? root.grabPin : root.phase === "turn" ? Math.max(0.0001, root.turn) : root.phase === "lit" ? 0 : -1
            front: [
                Column {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 8
                    Text { text: "REDMAGIC 10S Pro"; color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }
                    Grid {
                        columns: 3
                        spacing: 14
                        Repeater {
                            model: 6
                            ShadowBox { width: 68; height: 68; raised: true; baseRadius: 14; surfaceColor: Theme.listBox }
                        }
                    }
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: Theme.textMuted
                        font.pixelSize: 11
                        text: "Sphinx of black quartz, judge my vow. ".repeat(12)
                    }
                }
            ]
            back: [ Text { anchors.fill: parent; anchors.margins: 12; wrapMode: Text.Wrap; color: "#2F3136"; font.pixelSize: 11; text: "Android 15   512 GB   192.168.0.240   ".repeat(8) } ]
        }
    }

    // ---- the phases, by the wall clock: the frame gaps of each (a compositor paces them; offscreen nothing does) ---
    property var order: ["rest", "turn", "lit"]
    property int at: -1
    property real lastSwap: 0
    property var gaps: []
    Connections {
        target: root
        function onFrameSwapped() {
            const now = Date.now();
            if (root.phase !== "" && root.lastSwap > 0)
                root.gaps.push(now - root.lastSwap);
            root.lastSwap = now;
        }
    }
    Timer {
        id: stepper
        interval: 1500
        running: true
        onTriggered: {
            if (root.phase !== "") {
                const g = root.gaps.slice().sort((x, y) => x - y);
                const med = g.length ? g[Math.floor(g.length / 2)] : -1;
                console.log("BFP phase " + root.phase + " end frames=" + g.length + " gapMedian=" + med + " gapWorst=" + (g.length ? g[g.length - 1] : -1)
                    + " over25=" + g.filter(v => v > 25).length + " cached=" + stage.body.cached);
            }
            root.at++;
            root.gaps = [];
            root.lastSwap = 0;
            if (root.at >= root.order.length) {
                root.phase = "";
                root.grabPhase = "rest";
                root.grabAt = 0;
                grabStep.start();
                return;
            }
            root.phase = root.order[root.at];
            console.log("BFP phase " + root.phase + " begin");
            stepper.interval = root.phaseMs;
            stepper.restart();
        }
    }

    // ---- the cost of ONE frame, by a grab: a grab waits for the GPU (a read-back), which a frame's own timing does
    // not (offscreen every render reads 0 ms). GRABS grabs of the stage at rest (the cached layer) and GRABS with the
    // body at a new pose each (traced live): the difference of the two medians is what tracing the phone costs.
    readonly property int grabs: parseInt(Quickshell.env("GRABS") || "40")
    property string grabPhase: ""
    property int grabAt: 0
    property real grabT0: 0
    property var grabMs: []
    property real grabPin: -1
    Timer {
        id: grabStep
        interval: 30
        onTriggered: {
            if (root.grabPhase === "turn")
                root.grabPin = 0.02 + 0.96 * root.grabAt / root.grabs;
            root.grabT0 = Date.now();
            stage.grabToImage(function (r) {
                root.grabMs.push(Date.now() - root.grabT0);
                root.grabAt++;
                if (root.grabAt < root.grabs) {
                    grabStep.start();
                    return;
                }
                const g = root.grabMs.slice().sort((x, y) => x - y);
                console.log("BFP grab " + root.grabPhase + " n=" + g.length + " median=" + g[Math.floor(g.length / 2)] + " best=" + g[0] + " worst=" + g[g.length - 1]);
                root.grabMs = [];
                root.grabAt = 0;
                if (root.grabPhase === "rest") {
                    root.grabPhase = "turn";
                    grabStep.start();
                } else {
                    console.log("BFP done");
                    Qt.quit();
                }
            });
        }
    }
}
