pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/aerial/data"
import "modules/common/theme"
import "modules/aerial/popup"

// One picture of aerial's popup for the cloud's look (round 3, the signal fan): SCEN FAMILY SCALE STATE -> $PNG.  Offscreen only (the runner sets the platform).
//   SCEN   home crowd earbuds pairing hotspot nowifi vpn ...   (AerialMock's scenarios)
//   STATE  rest      the scenario at rest
//          hover     the pointer rests on a named tag of the first arc
//          carry     a network carried a little way toward the label
//          pulse     PHASE=<0..1>: the pulse's front held at that phase (the clock halted), for a strip of stills; SWEEP=1 the front is a scan's (wider, brighter) too
//          float     R3CLOUD float PASS|FAIL: every tag sways, on the scene's beat      still   R3CLOUD still PASS|FAIL: halted, 0 frames in 1.5 s
//   SCALE  the popup's sizeScale (1 or 1.35)
//   For the label's chrome (any STATE): TILT=<0..1> holds the card that far out of its slot (the airplane's clock, held), PTR=<x>,<y> rests the pointer there (design px:
//   the room in the chrome is led by it), PHASE with STATE=pulse puts the cloud's mirrored front on the plate.
Window {
    id: win
    readonly property real k: Number(Quickshell.env("SCALE") || 1)
    width: Math.ceil(764 * win.k)
    height: Math.ceil(640 * win.k)
    visible: true
    color: Theme.surface
    readonly property string st: Quickshell.env("STATE") || "rest"
    property int frames: 0
    onFrameSwapped: win.frames++
    AerialMock {
        id: mock
        live: true
        scenario: Quickshell.env("SCEN") || "home"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 150
    }
    Rectangle { anchors.fill: parent; color: Theme.surface }       // the popup's own ground (a grab over nothing reads a soft plate as ink)
    AerialPopup {
        id: popup
        service: mock
        family: Number(Quickshell.env("FAMILY") || 0)
        sizeScale: win.k
        renderScale: 1
        animate: true
        entranceEnabled: false
        soundsEnabled: false
    }
    TestCase { id: tc; name: "r3c"; when: false; windowShown: true }
    function tagWhere(pred: var): var {
        const ts = popup.cloud.targets();
        for (let i = 0; i < ts.length; i++)
            if (pred(ts[i]))
                return ts[i];
        return null;
    }
    Timer {
        interval: 2200
        running: true
        onTriggered: {
            const k = win.k;
            if (win.st === "hover") {
                const t = win.tagWhere(x => x.kind === "net" && x.entry.form !== "dot" && x.entry.arc === 0) || win.tagWhere(x => x.kind === "net");
                if (t) {
                    tc.mouseMove(win.contentItem, (t.x - 4) * k, t.y * k);
                    tc.mouseMove(win.contentItem, t.x * k, t.y * k);
                    tc.wait(400);
                }
            } else if (win.st === "carry") {
                const t = win.tagWhere(x => x.kind === "net" && x.entry.form !== "dot" && x.entry.arc === 1) || win.tagWhere(x => x.kind === "net");
                if (t) {
                    tc.mouseMove(win.contentItem, (t.x - 4) * k, t.y * k);
                    tc.mouseMove(win.contentItem, t.x * k, t.y * k);
                    tc.mousePress(win.contentItem, t.x * k, t.y * k, Qt.LeftButton);
                    for (let i = 1; i <= 8; i++) { tc.mouseMove(win.contentItem, (t.x + 3 * i) * k, (t.y + 9 * i) * k); tc.wait(20); }
                    tc.wait(250);
                }
            } else if (win.st === "float") {
                // the tags sway on the cloud's one clock, which takes its rest ticks from the scene's beat
                let moved = 0, n = 0;
                for (let i = 0; i < popup.cloud.tags.count; i++) {
                    const t = popup.cloud.tags.itemAt(i);
                    if (!t || !t.visible)
                        continue;
                    n++;
                    // qmllint disable missing-property
                    if (Math.abs(t.poseX) + Math.abs(t.poseY) + Math.abs(t.poseRot) > 0.05)
                        moved++;
                    // qmllint enable missing-property
                }
                const st = popup.cloud.floatClock.stats;
                console.log("R3CLOUD float " + (moved === n && n > 0 && st.beats > 10 ? "PASS" : "FAIL") + " swaying=" + moved + "/" + n + " frames=" + st.frames + " own=" + st.own + " beats=" + st.beats + " phase=" + popup.cloud.phase.toFixed(3));
            } else if (win.st === "still") {
                // the idle ladder's still: nothing runs, no frame is drawn
                popup.halted = true;
                tc.wait(400);
                const f0 = win.frames, p0 = popup.cloud.phase, b0 = popup.cloud.floatClock.stats.beats + popup.cloud.floatClock.stats.own + popup.cloud.floatClock.stats.frames;
                tc.wait(1500);
                const b1 = popup.cloud.floatClock.stats.beats + popup.cloud.floatClock.stats.own + popup.cloud.floatClock.stats.frames;
                console.log("R3CLOUD still " + (win.frames === f0 && popup.cloud.phase === p0 && b1 === b0 ? "PASS" : "FAIL") + " frames=" + (win.frames - f0) + " ticks=" + (b1 - b0));
            } else if (win.st === "pulse") {
                popup.halted = true;
                popup.cloud.phase = Number(Quickshell.env("PHASE") || 0.3);
                if (Quickshell.env("SWEEP"))
                    popup.cloud.boost = true;         // the front is a scan's
                tc.wait(120);
            }
            if (Quickshell.env("TILT"))
                popup.scene.airplaneT = Number(Quickshell.env("TILT"));
            // (the offscreen platform tells a pointer at 0, 0 when the window maps: a picture "at rest" has the room where no pointer led it)
            popup._leadAimX = 0;
            popup._leadAimY = 0;
            popup._leadFromX = 0;
            popup._leadFromY = 0;
            if (Quickshell.env("PTR")) {
                const xy = String(Quickshell.env("PTR")).split(",").map(Number);
                tc.mouseMove(win.contentItem, (xy[0] - 3) * k, xy[1] * k);
                tc.mouseMove(win.contentItem, xy[0] * k, xy[1] * k);
                tc.wait(700);
            }
            grab.start();
        }
    }
    Timer {
        id: grab
        interval: 400
        onTriggered: {
            const ts = popup.cloud.targets();
            console.log("R3CLOUD tags=" + ts.length + " named=" + ts.filter(t => t.entry.form !== "dot").length + " origin=" + JSON.stringify(popup.cloud.origin) + " size=" + popup.implicitWidth + "x" + popup.implicitHeight + " lead=" + popup.leadX + "," + popup.leadY);
            win.contentItem.grabToImage(r => { if (Quickshell.env("PNG")) r.saveToFile(Quickshell.env("PNG")); Qt.quit(); });
        }
    }
}
