pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/lockscreen/veil"

// =============================================================================
// dials_shell.qml -- the DIALS veil and the shell's place, frame by frame, for dials_shell_probe.sh (offscreen, from a
// copy of a tree; the runner says how).
//
// The dials veil hosted as the lock hosts it (a LockVeil, its clock stopped and SEEKED, so a frame is a pure function of
// what was done to it), driven by a list of operations the runner writes -- the user's path at a boot (the veil alone,
// then the shell's bar, then its popup opening out of the bar's foot one shell frame at a time) and a regular lock --
// and read out two ways: a frame record of what the veil drew (`DIALS_REC {...}` on the log: its centre, hub, tick hubs
// and re-cuts) and grabs of the stage. The shell's silhouette is drawn over the veil only when asked (`shell`): the
// probe's own checks read the veil's pixels everywhere, the sheets show what the user sees.
//
//   OPS=<file.json>  [{op, ...}] in order:
//     reset {boot, presence}   a fresh veil (its records start empty), no rects, no pulses, the clock at 0
//     seek {t}                 the clock to veil time t (forward, as the lock's runs; a backwards seek forgets)
//     rects {bar?, popup?}     hand the veil these rects ([x, y, w, h], null = none; a key left out keeps its rect)
//     presence {p}             the veil's presence
//     shell {on}               draw the bar and popup silhouettes over the veil
//     rec {tag}                print the frame record
//     grab {name, file, half?} the stage to OUT/<file> (a half-size grab with `half`), and its record
//   OUT=<dir>   W, H (default 2304 x 1296: the user's eDP-1 at scale 1.25)
// Prints DIALS_SHELL RESULT PASS once every op has run.
// =============================================================================
ShellRoot {
    id: shellRoot
    settings.watchFiles: false

    FloatingWindow {
        id: win
        implicitWidth: Number(Quickshell.env("W") || 2304)
        implicitHeight: Number(Quickshell.env("H") || 1296)
        visible: true
        color: "black"

        readonly property string outDir: Quickshell.env("OUT") || "/tmp/dials_shell"
        property var ops: []
        property int index: -1
        property int waitTicks: 0
        property var grabOp: null
        property bool boot: true
        property bool drawShell: false
        property rect barR: Qt.rect(0, 0, 0, 0)
        property rect popupR: Qt.rect(0, 0, 0, 0)
        property real presence: 1
        property string proposal: ""
        // the shell's surface in eva light, the mode the runner seeds (a literal: this harness's imports resolve only in
        // the runner's copy, where the theme is not the point)
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
            Rectangle {
                x: win.barR.x
                y: win.barR.y
                width: win.barR.width
                height: win.barR.height
                visible: win.drawShell && win.barR.width > 0
                radius: Math.min(20, height / 2)
                color: win.shellColor
            }
            Rectangle {
                x: win.popupR.x
                y: win.popupR.y
                width: win.popupR.width
                height: win.popupR.height
                visible: win.drawShell && win.popupR.width > 0 && win.popupR.height > 0
                radius: Math.min(28, height / 2, width / 2)
                color: win.shellColor
            }
        }

        FileView {
            id: opsFile
            path: Quickshell.env("OPS") || ""
            blockLoading: true
            printErrors: false
        }

        function toRect(a) {
            return a ? Qt.rect(a[0], a[1], a[2], a[3]) : Qt.rect(0, 0, 0, 0);
        }
        // What the veil drew. The fields a tree before the re-cut does not have are null.
        function rec(tag) {
            const v = host.item;
            if (!v) {
                console.log("DIALS_SHELL RESULT FAIL (no veil at " + tag + ")");
                quitTimer.start();
                return;
            }
            const r = v._recut;
            const o = {
                tag: tag,
                t: host.time,
                cx: v._centre.x,
                cy: v._centre.y,
                hub: v._hub,
                tick: v._tickHub,
                recut: r ? [r.x, r.y, r.z, r.w] : null,
                kind: v._live ? v._live.kind : null,
                live: v._live ? [v._live.cx, v._live.cy, v._live.hub] : null,
                unit: v._unit,
                pitch: v.ringPitch,
                groove: v.grooveWidth,
                minor: v.minorLength,
                tickPitch: v.tickPitch,
                every: v.majorEvery,
                margin: v.hubMargin,
                w: v.width,
                h: v.height
            };
            console.log("DIALS_REC " + JSON.stringify(o));
        }
        function run() {
            while (++win.index < win.ops.length) {
                const o = win.ops[win.index];
                if (o.op === "reset") {
                    win.boot = o.boot === undefined ? true : !!o.boot;
                    win.presence = o.presence === undefined ? 1 : o.presence;
                    win.barR = Qt.rect(0, 0, 0, 0);
                    win.popupR = Qt.rect(0, 0, 0, 0);
                    win.drawShell = false;
                    win.proposal = "";
                    host.clearPulses();
                    host.seek(0, 1);
                    win.proposal = "dials";
                } else if (o.op === "seek") {
                    host.seek(o.t, 1);
                } else if (o.op === "rects") {
                    if ("bar" in o)
                        win.barR = win.toRect(o.bar);
                    if ("popup" in o)
                        win.popupR = win.toRect(o.popup);
                } else if (o.op === "presence") {
                    win.presence = o.p;
                } else if (o.op === "shell") {
                    win.drawShell = !!o.on;
                } else if (o.op === "rec") {
                    win.rec(o.tag);
                } else if (o.op === "grab") {
                    win.rec(o.name);
                    win.grabOp = o;
                    win.waitTicks = 3;
                    return;
                }
            }
            console.log("DIALS_SHELL RESULT PASS (" + win.ops.length + " op(s))");
            quitTimer.start();
        }
        function grab() {
            const o = win.grabOp;
            const done = function (res) {
                res.saveToFile(win.outDir + "/" + o.file);
                win.run();
            };
            const ok = o.half ? stage.grabToImage(done, Qt.size(Math.round(stage.width / 2), Math.round(stage.height / 2))) : stage.grabToImage(done);
            if (!ok) {
                console.log("DIALS_SHELL RESULT FAIL (grabToImage refused " + o.name + ")");
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
                    win.grab();
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
                    win.ops = JSON.parse(opsFile.text());
                } catch (e) {
                    console.log("DIALS_SHELL RESULT FAIL (no ops: " + e + ")");
                    quitTimer.start();
                    return;
                }
                win.run();
            }
        }
    }
}
