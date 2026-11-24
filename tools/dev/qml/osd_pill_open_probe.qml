//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/osd"
import "modules/osd/data/OsdKinds.js" as Kinds

// =============================================================================
// osd_pill_open_probe.qml -- the OSD pill's OPEN, frame by frame (tools/dev/osd_pill_open_probe.sh runs it offscreen and judges).
//
// For each kind (env KINDS, default every kind): the pose at rest with and without its content (INK pngs: the runner diffs them
// into the content's ink), then a real `present()` sampled every animation frame (the FrameAnimation's own clock, 16 ms a frame
// offscreen) for 700 ms, then `dismiss()`. Prints one `OPO f <kind> <ms> <boxW> <boxH> <contentOpacity> <pillT>` per frame, in
// design px; with FILM=1 each frame's stage is also grabbed to OUT_DIR/film/<kind>/<n>.png (a grab lands a frame or so late).
// K = the scale (device px per design px). The runner reads the log; this file judges nothing. Prints `OPO done`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string outDir: Quickshell.env("OUT_DIR") || "/tmp/opo"
    readonly property real k: Number(Quickshell.env("K") || "1")
    readonly property bool film: Quickshell.env("FILM") === "1"
    readonly property var kinds: Quickshell.env("KINDS") ? Quickshell.env("KINDS").split(",") : Kinds.kindIds()

    OsdStyle {
        id: ostyle
    }

    FloatingWindow {
        id: win
        implicitWidth: Math.ceil(540 * root.k)
        implicitHeight: Math.ceil(80 * root.k)
        visible: true
        color: "#2A5A8A"

        Item {
            id: stage
            width: win.width
            height: win.height
            Rectangle {
                anchors.fill: parent
                color: "#2A5A8A"
            }
            Item {
                id: scaled
                scale: root.k
                transformOrigin: Item.TopLeft
                width: stage.width / root.k
                height: stage.height / root.k
                OsdPill {
                    id: pill
                    style: ostyle
                    renderScale: root.k
                    x: Math.round((scaled.width - pill.width) / 2)
                    y: 12
                    onClosed: root._closed = true
                }
            }
        }
    }

    property bool _closed: false
    property int _ki: 0
    // "ink0": pose with content, "ink1": without, "open", "wait"
    property string _ph: "start"
    property int _fr: 0
    property real _t0: 0
    property int _n: 0

    function _req(kind) {
        return Kinds.sampleRequest(kind);
    }
    function _grab(path) {
        stage.grabToImage(function (r) { r.saveToFile(path); });
    }

    FrameAnimation {
        id: fa
        running: true
        onTriggered: {
            root._fr++;
            const kind = root.kinds[root._ki];
            if (kind === undefined) {
                if (root._ph !== "done") {
                    root._ph = "done";
                    console.log("OPO done");
                    Qt.quit();
                }
                return;
            }
            if (root._ph === "start") {
                pill.holdAt(2, root._req(kind), 1);
                root._ph = "ink0";
                root._fr = 0;
            } else if (root._ph === "ink0" && root._fr === 60) {
                root._grab(root.outDir + "/ink_" + kind + "_content.png");
            } else if (root._ph === "ink0" && root._fr === 64) {
                pill.holdAt(2, root._req(kind), 0);
                root._ph = "ink1";
                root._fr = 0;
            } else if (root._ph === "ink1" && root._fr === 60) {
                root._grab(root.outDir + "/ink_" + kind + "_bare.png");
            } else if (root._ph === "ink1" && root._fr === 64) {
                // back to nothing, then the real open
                pill.holdAt(0, root._req(kind), 0);
                pill._finishClose();
                root._ph = "rest";
                root._fr = 0;
            } else if (root._ph === "rest" && root._fr === 6) {
                root._ph = "open";
                root._n = 0;
                pill.present(root._req(kind));
                root._t0 = fa.elapsedTime;
            } else if (root._ph === "open") {
                const ms = Math.round((fa.elapsedTime - root._t0) * 1000);
                console.log("OPO f " + kind + " " + ms + " " + pill.boxW.toFixed(3) + " " + pill.boxH.toFixed(3) + " "
                            + pill.contentOpacity.toFixed(4) + " " + pill.pillT.toFixed(4));
                if (root.film)
                    root._grab(root.outDir + "/film/" + kind + "/" + String(root._n).padStart(3, "0") + "_" + ms + ".png");
                root._n++;
                if (ms >= 700) {
                    root._closed = false;
                    pill.dismiss();
                    root._ph = "closing";
                }
            } else if (root._ph === "closing" && root._closed) {
                root._ki++;
                root._ph = "start";
            }
        }
    }
}
