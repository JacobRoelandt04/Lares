pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bridge"
import "modules/bridge/data"

// =============================================================================
// bridge_resize_probe.qml -- the cast's popup resized by its edge, and the way back to the controls, on the REAL BridgePopup and the
// REAL BridgeService (not live), in an offscreen window that follows the popup's asked size as the engine's live resize does. Driven
// by a REAL synthetic drag of the right edge's grip; EVERY frame (afterAnimating) records the asked width, the stage's zoom and the
// drawn display's width. Checks print `BR ok|FAIL <id>: <what>`; the last line is `BRIDGE_RESIZE RESULT PASS|FAIL (<n>/<n>)`.
//
//   r1  while the edge is dragged out the asked width never steps back (the user, 2026-11-19: "it alternates frame by frame
//       between what I am dragging to and what it used to be")
//   r2  the drawn phone follows the asked size on every frame (display width / asked width constant)
//   r3  released, the size is the one dragged to and the popup has NOT moved: a resize grows about the centre, both edges by the
//       drag (320 + 2 x the drag, within a pixel), the along-bar shift still 0 (the user, 2026-11-19: a corner drag walked the popup
//       to the centre island)
//   r5  the middle of the foot MOVES the popup: a drag there shifts it by the drag and keeps its size
//   r4  the back to the controls carries the size down WITH the page's going (many sizes on the way, never up), ending at 320
//   r6  back on the cast page the size comes back; the reset button's resetSize() eases it to the resting size and place on the
//       resize clock (many sizes on the way, never up, live to the host throughout), ending at 320 and shift 0
// Runner: tools/dev/bridge_resize_probe.sh.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("BR " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }

    TestCase {
        id: tc
        name: "br"
        when: false
    }

    Window {
        id: win
        visible: true
        width: 900
        height: 1500
        color: Theme.surface

        BridgeService {
            id: svc
            live: false
            scenario: "wired"
            mockLineMs: 0
            mockStepMs: 0
            mockAnswerMs: 0
        }
        // the host follows the content's asked size, as the engine does while `liveResizeActive`
        BridgePopup {
            id: popup
            x: 0
            y: 0
            width: popup.implicitWidth
            height: popup.implicitHeight
            service: svc
            flipOnOpen: false
        }
    }

    property bool recording: false
    property var frames: []
    Connections {
        target: win
        function onAfterAnimating(): void {
            if (!probe.recording)
                return;
            probe.frames.push({ iw: popup.implicitWidth, z: popup.stage.zoom, sw: popup.stage.screenRect.width });
            if (probe.step === 6 && svc.castScale !== 1 && !popup.liveResizeActive)
                probe.liveAll = false;
        }
    }

    property int step: 0
    property real dragX: 0
    property real dragY: 0
    readonly property int dragPx: 160
    readonly property int dragSteps: 40
    property int moved: 0
    property var dragFrames: []
    readonly property int movePx: 100
    property real wBefore: 0
    // every frame of the reset's ease is live to the host (the engine follows the size exactly)
    property bool liveAll: true

    Timer {
        id: drive
        interval: 30
        repeat: true
        running: true
        property int waited: 0
        onTriggered: {
            drive.waited++;
            if (drive.waited > 600) {
                probe.check("timeout", false, "the probe ran out of time at step " + probe.step);
                probe.finish();
                return;
            }
            switch (probe.step) {
            case 0:
                if (svc.ready && popup.screenFace.dev !== null) {
                    svc.page = "cast";
                    probe.step = 1;
                }
                break;
            case 1:
                if (popup.screenFace.castShown && popup.stage.atRest) {
                    probe.grab("rest");
                    probe.dragX = popup.width - 3;
                    probe.dragY = Math.round(popup.height / 2);
                    probe.recording = true;
                    probe.frames = [];
                    tc.mousePress(win.contentItem, probe.dragX, probe.dragY, Qt.LeftButton);
                    probe.step = 2;
                }
                break;
            case 2:
                // one move a tick: the pointer goes out by dragPx in dragSteps, frames are drawn in between
                if (probe.moved < probe.dragSteps) {
                    probe.moved++;
                    tc.mouseMove(win.contentItem, probe.dragX + probe.dragPx * probe.moved / probe.dragSteps, probe.dragY, -1, Qt.LeftButton);
                } else {
                    tc.mouseRelease(win.contentItem, probe.dragX + probe.dragPx, probe.dragY, Qt.LeftButton);
                    probe.dragFrames = probe.frames.slice();
                    probe.step = 3;
                    drive.waited = 0;
                }
                break;
            case 3:
                if (drive.waited > 20) {
                    const f = probe.dragFrames;
                    let backs = 0, worst = 0;
                    for (let i = 1; i < f.length; i++) {
                        if (f[i].iw < f[i - 1].iw - 0.01) {
                            backs++;
                            worst = Math.max(worst, f[i - 1].iw - f[i].iw);
                        }
                    }
                    probe.check("r1", f.length > 10 && backs === 0, "dragged out, the asked width never steps back (" + f.length + " frames, " + backs + " steps back, worst " + worst.toFixed(1) + " px)");
                    let off = 0;
                    for (const x of f) {
                        if (x.iw > 0 && Math.abs(x.sw / x.iw - f[0].sw / f[0].iw) > 0.01)
                            off++;
                    }
                    probe.check("r2", off === 0, "the drawn phone follows the asked size on every frame (" + off + " frames out of step)");
                    const want = 320 + 2 * probe.dragPx;
                    probe.check("r3", Math.abs(popup.implicitWidth - want) <= 1.5 && Math.abs(popup.width - want) <= 1.5 && Math.abs(svc.castShift) < 0.01,
                                "released, the size is the one dragged to and the popup did not move (" + popup.implicitWidth + ", want " + want + "; shift " + svc.castShift + ")");
                    probe.grab("resized");
                    // the move grip: the middle of the foot
                    probe.wBefore = popup.implicitWidth;
                    probe.dragX = Math.round(popup.width / 2);
                    probe.dragY = popup.height - 4;
                    probe.moved = 0;
                    tc.mousePress(win.contentItem, probe.dragX, probe.dragY, Qt.LeftButton);
                    probe.step = 30;
                    drive.waited = 0;
                }
                break;
            case 30:
                if (probe.moved < 20) {
                    probe.moved++;
                    tc.mouseMove(win.contentItem, probe.dragX + probe.movePx * probe.moved / 20, probe.dragY, -1, Qt.LeftButton);
                } else {
                    tc.mouseRelease(win.contentItem, probe.dragX + probe.movePx, probe.dragY, Qt.LeftButton);
                    probe.step = 31;
                    drive.waited = 0;
                }
                break;
            case 31:
                if (drive.waited > 10) {
                    probe.check("r5", Math.abs(svc.castShift - probe.movePx) <= 1 && Math.abs(popup.implicitWidth - probe.wBefore) <= 0.5,
                                "the foot's middle moves the popup, its size kept (shift " + svc.castShift + ", want " + probe.movePx + "; width " + popup.implicitWidth + ", was " + probe.wBefore + ")");
                    probe.frames = [];
                    popup.screenFace.goBack();
                    probe.step = 4;
                    drive.waited = 0;
                }
                break;
            case 4:
                if (!popup.screenFace.pageOpen && !popup.screenFace.morphing && drive.waited > 10) {
                    const f = probe.frames;
                    const sizes = {};
                    let ups = 0;
                    for (let i = 0; i < f.length; i++) {
                        sizes[Math.round(f[i].iw)] = true;
                        if (i > 0 && f[i].iw > f[i - 1].iw + 0.01)
                            ups++;
                    }
                    const n = Object.keys(sizes).length;
                    probe.check("r4", n >= 4 && ups === 0 && Math.abs(popup.implicitWidth - 320) <= 0.5,
                                "the back carries the size down with the page (" + n + " sizes on the way, " + ups + " steps up, ends at " + popup.implicitWidth + ")");
                    svc.page = "cast";
                    probe.step = 5;
                    drive.waited = 0;
                }
                break;
            case 5:
                if (popup.screenFace.castShown && !popup.screenFace.morphing && drive.waited > 5) {
                    probe.frames = [];
                    probe.liveAll = true;
                    popup.resetSize();
                    probe.step = 6;
                    drive.waited = 0;
                }
                break;
            case 6:
                if (popup.liveResizeActive === false && drive.waited > 3) {
                    const f = probe.frames;
                    const sizes = {};
                    let ups = 0;
                    for (let i = 0; i < f.length; i++) {
                        sizes[Math.round(f[i].iw)] = true;
                        if (i > 0 && f[i].iw > f[i - 1].iw + 0.01)
                            ups++;
                    }
                    const n = Object.keys(sizes).length;
                    probe.check("r6", n >= 4 && ups === 0 && probe.liveAll && Math.abs(popup.implicitWidth - 320) <= 0.5 && Math.abs(svc.castShift) < 0.01 && svc.castScale === 1,
                                "the reset eases back to the resting size and place (" + n + " sizes, " + ups + " steps up, live throughout " + probe.liveAll + ", ends at " + popup.implicitWidth + " shift " + svc.castShift + ")");
                    probe.finish();
                }
                break;
            }
        }
    }

    // GRAB_DIR (optional): the popup's picture at rest on the cast page and after the drag, for a look
    readonly property string grabDir: Quickshell.env("GRAB_DIR") || ""
    function grab(tag: string): void {
        if (probe.grabDir !== "")
            popup.grabToImage(r => r.saveToFile(probe.grabDir + "/" + tag + ".png"));
    }
    function finish(): void {
        drive.stop();
        probe.recording = false;
        console.log("BRIDGE_RESIZE RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
}
