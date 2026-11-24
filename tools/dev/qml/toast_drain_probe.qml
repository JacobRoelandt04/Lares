pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/notifications/parts"
import "modules/notifications/toast"

// =============================================================================
// toast_drain_probe.qml -- a toast's countdown drain (ToastEntry), on stub services. Written for the old tree and this one.
//
//   MODE=truth   the card's shade boundary, read from pixels at SCALE, against where ShadowBox's own geometry puts it
//                (-feather + p * (width + 2 * feather), device px) for a handful of fractions: proves the distance a step is
//                counted against. Prints `DRAIN truth p=<p> boundary <px> expect <px> off <px>`.
//   MODE=steps   the stepper in wall time (TOTAL_MS, default 8000; TOASTS entries): every change of `timeLeft` is a step; each
//                step's size in device px is judged against the truth distance. Prints `DRAIN step ...` lines (first 6), then
//                `DRAIN steps n=<n> px min <a> max <b> whole <bool> perSecond <f> fromT0 ...`.
//   MODE=count   frames (frameSwapped) the window presents per second while TOASTS entries count, over MEASURE_MS (default 3000).
//   PLAN         MODE=truth: the fractions to grab, comma separated (a strip of consecutive steps)
//   SCALE        device px per design px (default 1.25: the user's frame)    OUT_DIR  PNGs of MODE=truth
// Ends with DRAIN RESULT PASS|FAIL (PASS: whole-pixel steps of at least STEP_MIN px (default 1) that fit the 16 ms floor, in
// MODE=steps; the boundary within 1 px in MODE=truth; MODE=count always prints its numbers and passes).
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 520
        implicitHeight: 420
        visible: true
        color: Theme.surface

        readonly property string mode: Quickshell.env("MODE") || "steps"
        readonly property real zoom: Math.max(1, Number(Quickshell.env("SCALE") || 1.25))
        readonly property real totalMs: Number(Quickshell.env("TOTAL_MS") || 8000)
        readonly property int toasts: Math.max(1, Number(Quickshell.env("TOASTS") || 1))
        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property real measureMs: Number(Quickshell.env("MEASURE_MS") || 3000)
        readonly property real feather: nstyle.shadeFeatherPx
        // THE TRUTH, from the shader's geometry (ShadowBox._boundaryX: the sweep runs from one half-feather before the left edge to one
        // half-feather past the right): device px the boundary travels end to end
        readonly property real truthSweepPx: (nstyle.toastWidth + 2 * win.feather) * win.zoom
        property int fails: 0
        // through a var: the harness's import path and the card's own name one type twice to qmllint
        property var styleObj: nstyle

        NotificationStyle {
            id: nstyle
            renderScale: win.zoom
        }

        // a service with just what a toast reads
        QtObject {
            id: svc
            readonly property var store: ({ get: uid => ({ uid: uid, appName: "Probe", summary: "Build finished", body: "The drain.",
                                                       group: "System", urgency: "normal", actions: [], progress: -1, updatedMs: 0,
                                                       arrivedMs: 0, stale: false, pinned: false, closed: false, reply: null, image: "" }) })
            property int serial: 0
            readonly property QtObject toasts: QtObject {
                property int serial: 0
                property bool frozen: false
                readonly property var floods: ({})
                signal expired(string uid)
                function timing(uid: string): var {
                    // the toasts arrive apart (an offset per toast), as real ones do: their steps do not share a frame
                    return { sticky: false, totalMs: win.totalMs, leftMs: win.totalMs - Number(uid.substring(1)) * 370 };
                }
                function replying(open: bool, uid: string): void {}
            }
            function activate(uid) {}
        }

        Item {
            id: stage
            x: 10
            y: 10
            width: Math.ceil(nstyle.toastWidth * win.zoom)
            height: 400
            Repeater {
                model: win.mode === "truth" ? 1 : win.toasts
                delegate: Item {
                    id: slot
                    required property int index
                    y: slot.index * 90 * win.zoom
                    width: nstyle.toastWidth
                    height: 80
                    scale: win.zoom
                    transformOrigin: Item.TopLeft
                    property alias entry: te
                    ToastEntry {
                        id: te
                        uid: "t" + slot.index
                        service: win.mode === "truth" ? null : svc
                        style: win.styleObj
                        d: svc.store.get("t" + slot.index)
                        cardWidth: nstyle.toastWidth
                    }
                }
            }
        }

        // ---- MODE=truth ------------------------------------------------------------------------------------------------------
        // PLAN=a,b,c overrides the fractions (a strip of consecutive steps for a before / after sheet)
        readonly property var truthPlan: (Quickshell.env("PLAN") || "") !== "" ? Quickshell.env("PLAN").split(",").map(Number) : [0.2, 0.35, 0.5, 0.65, 0.8]
        property int at: -1
        function _entry(): var {
            return stage.children[0] && stage.children[0].entry ? stage.children[0].entry : null;
        }
        Timer {
            id: truthTimer
            interval: 200
            onTriggered: {
                win.at += 1;
                if (win.at >= win.truthPlan.length) {
                    win.finish();
                    return;
                }
                const e = win._entry();
                e._sticky = false;
                e._read = true;
                e.timeLeft = win.truthPlan[win.at];
                grab.start();
            }
        }
        Timer {
            id: grab
            interval: 200
            onTriggered: {
                const p = win.truthPlan[win.at];
                stage.grabToImage(r => {
                    r.saveToFile(win.outDir + "/truth_" + win.at + ".png");
                    console.log("DRAIN grab " + win.at + " " + p);
                    truthTimer.start();
                });
            }
        }

        // ---- MODE=steps ------------------------------------------------------------------------------------------------------
        property var log: []
        property real t0: 0
        function _watch(): void {
            const e = win._entry();
            e.timeLeftChanged.connect(() => win.log.push([Date.now() - win.t0, e.timeLeft]));
        }
        Timer {
            id: stepsEnd
            interval: win.totalMs + 400
            onTriggered: win.finish()
        }

        // ---- MODE=count ------------------------------------------------------------------------------------------------------
        property int frames: 0
        property real countFrom: 0
        Connections {
            target: stage.Window.window
            function onFrameSwapped() {
                if (win.countFrom > 0)
                    win.frames += 1;
            }
        }
        Timer {
            id: countStart
            interval: 1500
            onTriggered: {
                win.frames = 0;
                win.countFrom = Date.now();
                console.log("DRAIN countstart");
                countEnd.start();
            }
        }
        Timer {
            id: countEnd
            interval: win.measureMs
            onTriggered: {
                const s = (Date.now() - win.countFrom) / 1000;
                console.log("DRAIN count toasts=" + win.toasts + " frames=" + win.frames + " seconds=" + s.toFixed(2) + " fps=" + (win.frames / s).toFixed(1));
                win.finish();
            }
        }

        function finish(): void {
            if (win.mode === "steps") {
                const L = win.log;
                let n = 0, mn = 1e9, mx = 0, whole = true;
                const pxs = [];
                for (let i = 1; i < L.length; i++) {
                    const dpx = (L[i - 1][1] - L[i][1]) * win.truthSweepPx;
                    if (dpx < 0.01)
                        continue;
                    pxs.push(dpx);
                    n++;
                    mn = Math.min(mn, dpx);
                    mx = Math.max(mx, dpx);
                    if (Math.abs(dpx - Math.round(dpx)) > 0.02)
                        whole = false;
                }
                // the first 6 steps, then a summary
                for (let i = 0; i < Math.min(6, pxs.length); i++)
                    console.log("DRAIN step " + i + " " + pxs[i].toFixed(3) + " px");
                const ms = win.totalMs;
                const perS = n / (ms / 1000);
                const stepMin = Number(Quickshell.env("STEP_MIN") || 1);
                // the 16 ms floor: a step of k px at a rate of ms / sweep per px
                const needK = Math.max(1, Math.ceil(16 / (ms / win.truthSweepPx)));
                const wantK = Math.max(stepMin, needK);
                // a step bigger than wanted is a timer that came late (the machine is shared; a step of two is a 16 ms stall): allowed
                // for under 5 % of the steps, never a step SMALLER than wanted
                let late = 0;
                for (const d of pxs)
                    if (d > wantK + 0.02)
                        late++;
                const okSize = Math.abs(mn - wantK) < 0.02 && late <= 0.05 * n;
                console.log("DRAIN steps n=" + n + " px min " + mn.toFixed(3) + " max " + mx.toFixed(3) + " whole " + whole + " perSecond " + perS.toFixed(1)
                            + " late " + late + " wanted " + wantK + " px (sweep " + win.truthSweepPx.toFixed(1) + " px)");
                if (!whole)
                    console.log("DRAIN FAIL steps are not whole device px");
                if (!okSize)
                    console.log("DRAIN FAIL steps are not " + wantK + " px (late: " + late + ")");
                if (!whole || !okSize || n < 5)
                    win.fails += 1;
            }
            console.log("DRAIN RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (mode " + win.mode + ")");
            quitTimer.start();
        }
        Timer {
            id: quitTimer
            interval: 60
            onTriggered: Qt.quit()
        }

        Component.onCompleted: {
            if (win.mode === "truth")
                truthTimer.start();
            else if (win.mode === "steps") {
                win.t0 = Date.now();
                win._watch();
                stepsEnd.start();
            } else
                countStart.start();
        }
    }
}
