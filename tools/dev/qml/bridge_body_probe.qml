pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bridge/body"

// =============================================================================
// tools/dev/qml/bridge_body_probe.qml -- the bridge's phone body, held to its rules (tools/dev/bridge_body_probe.sh runs it
// per scale and judges the pictures). ONE real PhoneStage on an opaque green ground, its two faces one flat colour each
// that nothing on the phone has (the front magenta, the back orange: this phone's own back is blue), so a face that leaves its glass is a pixel of its
// colour against the ground, and a hole the face does not fill is the ground showing inside the body.
//
// It walks a list of steps, one picture each into $OUTDIR:
//   rest        the stage as the popup has it at rest (the body's cached layer)          -> rest.png
//   live0       the same pose held by `pinTurn: 0`: the body drawn live, the faces under faceMatrix -> live0.png
//   pose_<nn>   pinTurn = POSES[n]                                                       -> pose_<nn>.png
//   back        the stage after a real flipTo("back") has landed                         -> back.png
// and it watches the stage at rest for STILL_MS with something else animating in the window: the body must stay its
// cached picture and none of its uniforms may change (a body that goes live, or is fed a clock, is traced every frame).
//
//   OUTDIR=<dir>  SCALE=1|1.25|1.5625  POSES="0.05 0.12 ..."  SKIN=<skin>  STILL_MS=1500
//   OFFSET="10.3 7.7"  the stage's place in the scaled frame (a popup's corner is rarely on a whole device pixel)
// Prints BBP lines; the runner reads them and the PNGs.
// =============================================================================
Window {
    id: root

    readonly property string outDir: Quickshell.env("OUTDIR") || "/tmp"
    readonly property real factor: parseFloat(Quickshell.env("SCALE") || "1")
    readonly property var poses: (Quickshell.env("POSES") || "0.04 0.10 0.18 0.24 0.31 0.40 0.47 0.5 0.56 0.68 0.76 0.90").trim().split(/\s+/).map(Number)
    readonly property string skin: Quickshell.env("SKIN") || "redmagic-10s-pro-moonlight"
    readonly property int stillMs: parseInt(Quickshell.env("STILL_MS") || "1500")
    readonly property var n: ({ swaps: 0, changes: 0, wentLive: 0 })
    readonly property color ground: "#00FF00"
    // where the stage stands in the scaled frame (design px): a fraction puts its corner between two device pixels
    readonly property var offset: (Quickshell.env("OFFSET") || "0 0").trim().split(/\s+/).map(Number)

    width: Math.ceil((320 + root.offset[0] + 2) * root.factor)
    height: Math.ceil((664 + root.offset[1] + 2) * root.factor)
    visible: true
    color: root.ground

    Connections {
        target: root
        function onFrameSwapped() {
            root.n.swaps++;
        }
    }
    // something else in the window that moves: the stage must not care
    Rectangle {
        id: spinner
        width: 2
        height: 2
        color: root.ground
        RotationAnimation on rotation { from: 0; to: 360; duration: 300; loops: Animation.Infinite }
    }

    // the window may be any size (a tiling compositor stretches it); the picture is this fixed sheet
    Item {
        id: sheet
        width: Math.ceil((320 + root.offset[0] + 2) * root.factor)
        height: Math.ceil((664 + root.offset[1] + 2) * root.factor)
        Rectangle {
            anchors.fill: parent
            color: root.ground
        }
        ScaleRoot {
            factor: root.factor
            hostWidth: sheet.width
            hostHeight: sheet.height
            PhoneStage {
                id: stage
                x: root.offset[0]
                y: root.offset[1]
                width: 320
                height: 664
                skin: root.skin
                relight: false
                // the front face IS the display's ground (the stage draws it, round at the corners); the back's is a sheet
                screenGround: "#FF00FF"
                back: [ Rectangle { anchors.fill: parent; color: "#FF8000" } ]
            }
        }
    }

    // every uniform of the body that a motion writes; and whether it ever left its layer
    Connections {
        target: stage.body
        enabled: root.watching
        function onAxesChanged() { root.n.changes++; }
        function onLiftChanged() { root.n.changes++; }
        function onPressChanged() { root.n.changes++; }
        function onStripAChanged() { root.n.changes++; }
        function onViewChanged() { root.n.changes++; }
        function onCachedChanged() { root.n.wentLive++; }
    }
    property bool watching: false

    // ---- the walk: each step sets a pose, waits for frames drawn AFTER it, grabs, then the next ------------------
    property var steps: []
    property int at: -1
    property int waitFrom: 0
    property bool busy: false
    function plan() {
        const s = [{ name: "rest", pin: -1 }, { name: "live0", pin: 0 }];
        for (let i = 0; i < root.poses.length; i++)
            s.push({ name: "pose_" + (i < 10 ? "0" : "") + i, pin: root.poses[i] });
        s.push({ name: "still", pin: -1 });
        s.push({ name: "back", pin: -1, flip: true });
        root.steps = s;
    }
    function next() {
        root.at++;
        if (root.at >= root.steps.length) {
            console.log("BBP done steps=" + root.steps.length + " swaps=" + root.n.swaps);
            Qt.quit();
            return;
        }
        const st = root.steps[root.at];
        stage.pinTurn = st.pin;
        if (st.flip)
            stage.flipTo("back");
        root.waitFrom = root.n.swaps;
        root.waited = 0;
        root.busy = false;
    }
    property int waited: 0
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (root.at < 0) {
                // the first frames, and the shader's first compile
                root.waited += 50;
                if (root.n.swaps >= 6 && root.waited >= 1200) {
                    console.log("BBP geom stage=" + stage.width + "x" + stage.height + " body=" + stage.body.width + "x" + stage.body.height
                        + " tex=" + stage.body.layer.textureSize.width + "x" + stage.body.layer.textureSize.height
                        + " screen=" + stage.screenRect.x + "," + stage.screenRect.y + " " + stage.screenRect.width + "x" + stage.screenRect.height);
                    root.plan();
                    root.next();
                }
                return;
            }
            if (root.busy)
                return;
            root.waited += 50;
            const st = root.steps[root.at];
            if (st.name === "still") {
                if (!stage.atRest) {
                    if (root.waited > 8000) {
                        console.log("BBP still FAIL the stage never came to rest");
                        root.next();
                    }
                    return;
                }
                if (!root.watching) {
                    root.n.changes = 0;
                    root.n.wentLive = 0;
                    root.watching = true;
                    root.waited = 0;
                    return;
                }
                if (root.waited < root.stillMs)
                    return;
                root.watching = false;
                console.log("BBP still cached=" + stage.body.cached + " changes=" + root.n.changes + " wentLive=" + root.n.wentLive + " atRest=" + stage.atRest + " ms=" + root.waited);
                root.next();
                return;
            }
            if (st.flip && (stage.flipping || stage.face !== "back" || !stage.atRest)) {
                if (root.waited > 8000) {
                    console.log("BBP back FAIL the turn never landed face=" + stage.face);
                    root.next();
                }
                return;
            }
            if (root.n.swaps - root.waitFrom < 4 || root.waited < 200)
                return;
            root.busy = true;
            const name = st.name;
            sheet.grabToImage(function (r) {
                const ok = r.saveToFile(root.outDir + "/" + name + ".png");
                console.log("BBP grab " + name + " " + (ok ? "saved" : "NOT-SAVED") + " pin=" + st.pin + " face=" + stage.face + " cached=" + stage.body.cached);
                root.next();
            });
        }
    }
}
