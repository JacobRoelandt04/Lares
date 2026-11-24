//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/bar/gooey"
import "modules/common/theme"
import "modules/osd"
import "modules/osd/data"
import "modules/osd/data/OsdKinds.js" as Kinds

// =============================================================================
// osd_hide_probe.qml -- a card the user hides, and the pill's window (tools/dev/osd_hide_probe.sh runs it offscreen).
//
// The OSD as the shell wires it (OsdOwner + OsdService live: false + the real GooeyEngine with a 40 px top bar and the 6 px
// right outlet, the default spot; OsdPillFrame -- the pill's window but the window -- at the top centre, cut at its edges as
// the window is) and the pointer through QtTest, which drives the WINDOW: the caption's own hide button answers.
//
//   EXTENT   every kind's pill fits the pill's window (OsdStyle.pillWindowExtent), with the drop shadow's reach
//   BAR      the hide button tucks the caption into its bar (osdTuckPx out, the content at 0, the hover zone over the slim bar
//            to the screen's edge); a renewal lands in place; a pointer resting on the zone as it tucks does not bring it back,
//            the first motion does; the sliver itself does; a user card in between comes out whole and the caption returns
//            tucked; a withdraw forgets it
//   PILL     over a fullscreen window: the hide button (clicked through the window's own region) makes the ball -- under
//            half of it on screen, its zone at the top, the content unseen, faint at the end of its fade; a resting pointer
//            does not bring it back, a motion does; a withdraw fades the ball out
//   GRABS    OUT_DIR: the caption pill and the parked ball in their frame at k 1 and 1.25 on an opaque ground (the runner
//            reads the capsule's ends from the pixels)
//
// Prints `OHP ok|FAIL <check>` and `OHP RESULT PASS|FAIL (n/n checks)`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string outDir: Quickshell.env("OUT_DIR") || ""
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("OHP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    OsdService {
        id: svc
        live: false
    }
    OsdStyle {
        id: ostyle
    }
    function caption(live: string): var {
        return { kind: "caption", key: "dictation", source: "dictation", ms: 60000,
                 caption: { mode: "source", head: "Transcribing Zen", lines: ["The town was built on the old trade road, where the river bends twice.",
                            "Its market drew people from three valleys away."], live: live, hint: "" } };
    }

    FloatingWindow {
        id: win
        implicitWidth: 1180
        implicitHeight: 700
        visible: true
        color: "#1F2229"

        Item {
            id: scene
            anchors.fill: parent

            GooeyEngine {
                id: eng
                anchors.fill: parent
                surfaceColor: Theme.surface
                barsList: [topBar, rightBar]
                GooeyBar {
                    id: topBar
                    engine: eng
                    barId: "top"
                    edge: "top"
                    rawPos: 0
                    rawLen: eng.w
                }
                GooeyBar {
                    id: rightBar
                    engine: eng
                    barId: "right"
                    edge: "right"
                    thickness: 6
                    reserve: 0
                    // as the shell's outlets: in the compositor's gap, no input of their own (ShellFrame)
                    inputMask: false
                    rawPos: topBar.thickness
                    rawLen: eng.h - topBar.thickness
                }
            }
            OsdPillFrame {
                id: pillFrame
                z: 6
                clip: true
                style: ostyle
                k: 1
                x: Math.round((scene.width - pillFrame.width) / 2)
                y: 0
                width: pillFrame.implicitWidth
                height: pillFrame.implicitHeight
            }
            OsdOwner {
                id: owner
                engine: eng
                service: svc
                style: ostyle
                pill: pillFrame.pill
                fullscreen: false
                spot: ({ bar: "right", along: 0.5 })
            }
        }
        TestCase {
            id: tc
            name: "osdhide"
            when: false
        }
    }

    // The pill and the ball in their frame, at k 1 and 1.25, for the runner's pixels.
    FloatingWindow {
        id: grabWin
        implicitWidth: 760
        implicitHeight: 4 * 160
        visible: true
        color: "#00A040"
        Column {
            Repeater {
                id: cellRep
                model: [{ k: 1, ball: false }, { k: 1.25, ball: false }, { k: 1, ball: true }, { k: 1.25, ball: true }]
                delegate: Rectangle {
                    id: cell
                    required property var modelData
                    required property int index
                    readonly property alias frame: gf
                    width: gf.width
                    height: 160
                    color: "#00A040"
                    OsdPillFrame {
                        id: gf
                        clip: true
                        style: ostyle
                        k: cell.modelData.k
                        renderScale: cell.modelData.k
                        width: gf.implicitWidth
                        height: gf.implicitHeight
                    }
                }
            }
        }
    }

    // ---- the sequencer: each step waits for its condition (or its deadline in ticks), then runs ----------------------------
    property int step: 0
    property int rest: -1
    property int waited: 0
    property var full: null
    function boxOf() {
        const b = eng.theOsd.box;
        return b ? { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, w: b.x1 - b.x0, h: b.y1 - b.y0 } : null;
    }
    function contentItem(): var {
        return eng.theOsd.contentItem;
    }
    function move(x: real, y: real): void {
        tc.mouseMove(win.contentItem, x - 2, y);
        tc.mouseMove(win.contentItem, x, y);
    }
    function centreOfRect(item: var, r: rect): point {
        return item.mapToItem(win.contentItem, r.x + r.width / 2, r.y + r.height / 2);
    }
    readonly property bool barRest: eng.osdPhase === "open" && !!eng.theOsd.box
    readonly property real tuckPx: eng.osdTuckPx

    function wait(cond: bool, ticks: int, name: string): bool {
        if (cond) {
            root.waited = 0;
            return true;
        }
        root.waited++;
        if (root.waited > ticks) {
            root.check("wait: " + name, false, "timed out");
            root.waited = 0;
            return true;
        }
        return false;
    }

    function run(): void {
        const s = root.step;
        const b = root.boxOf();
        switch (s) {
        case 0: {
            // EXTENT: every kind's pill in the window
            const ext = ostyle.pillWindowExtent();
            const out = [];
            for (const k of Kinds.kindIds()) {
                const e = ostyle.extentOf(k, "pill");
                if (e.w + 2 * ext.reach > ext.w + 1e-6 || ostyle.pillTop + e.h + ext.reach > ext.h + 1e-6)
                    out.push(k + " " + e.w + "x" + e.h);
            }
            root.check("every kind's pill fits the pill's window (" + ext.w + " x " + ext.h + ", reach " + ext.reach + ")", out.length === 0,
                       "too big: " + out.join(", "));
            for (let i = 0; i < 4; i++) {
                const cell = cellRep.itemAt(i);
                // qmllint disable missing-property
                const f = cell ? cell.frame : null;
                // qmllint enable missing-property
                if (!f)
                    continue;
                if (i < 2)
                    f.pill.holdAt(2, root.caption("and the bridge was for a long time"), 1);
                else
                    f.pill.holdBall(root.caption(""), 1, 1);
            }
            svc.show(root.caption("and the bridge"));
            break;
        }
        case 1:
            if (!root.wait(root.barRest && eng.theOsd.contentOpacity >= 1, 400, "the caption out on the bar"))
                return;
            root.full = b;
            root.check("the caption is out on the right bar", !!b && b.w > 300, JSON.stringify(b));
            {
                // the hide button, clicked through the window
                const c = root.contentItem();
                const p = root.centreOfRect(c, c.hideRect);
                root.move(p.x, p.y);
                tc.mouseClick(win.contentItem, p.x, p.y);
            }
            break;
        case 2:
            if (!root.wait(eng.osdTuckedRest, 400, "tucked at rest"))
                return;
            {
                const f = root.full;
                root.check("the hide button hid the caption", owner.hidden, "hidden " + owner.hidden);
                root.check("tucked: osdTuckPx out of the bar, the same span along it", !!b && Math.abs(b.w - root.tuckPx) < 0.01
                           && Math.abs(b.x1 - f.x1) < 0.01 && Math.abs(b.y0 - f.y0) < 0.5 && Math.abs(b.y1 - f.y1) < 0.5, JSON.stringify(b));
                root.check("tucked: the content is out of sight", eng.theOsd.contentOpacity === 0, "opacity " + eng.theOsd.contentOpacity);
                const z = eng.osdTuckZone;
                root.check("the hover zone is the sliver and the slim bar beside it, to the screen's edge",
                           z.x === Math.floor(b.x0) && z.x + z.width === eng.w && z.y === Math.floor(b.y0) && z.height > 50,
                           z.x + "," + z.y + " " + z.width + "x" + z.height + " (box " + JSON.stringify(b) + ", w " + eng.w + ")");
                root.check("a pointer that clicked hide and rests does not bring it back", owner.hidden, "hidden " + owner.hidden);
                // the window takes input there: one of the engine's input rects holds the whole zone (the outlet takes none)
                const held = eng.maskItems.some(m => m && m.width > 0 && m.x <= z.x && m.y <= z.y && m.x + m.width >= z.x + z.width
                                                     && m.y + m.height >= z.y + z.height);
                root.check("the input region holds the zone (over an outlet that takes no input)", held && z.width > 0,
                           eng.maskItems.filter(m => m && m.width > 0).map(m => m.x + "," + m.y + " " + m.width + "x" + m.height).join(" | "));
            }
            svc.show(root.caption("a renewal"));
            break;
        case 3:
            root.check("a renewal while hidden lands in place: still tucked, the words renewed", owner.hidden && eng.osdTuckedRest
                       && Math.abs(b.w - root.tuckPx) < 0.01 && owner.shown && owner.shown.caption.live === "a renewal",
                       "hidden " + owner.hidden + " box " + JSON.stringify(b));
            owner.unhide();
            break;
        case 4:
            if (!root.wait(root.barRest && b.w > 300 && eng.theOsd.contentOpacity >= 1, 400, "out again"))
                return;
            // the pointer onto the slim bar at the card's middle, then hidden under it
            root.move(eng.w - 3, Math.round((b.y0 + b.y1) / 2));
            owner.hideShown();
            break;
        case 5:
            if (!root.wait(eng.osdTuckedRest, 400, "tucked under a resting pointer"))
                return;
            root.step = 6;
            root.waited = 0;
            return;
        case 6:
            // a while with the pointer resting on the zone
            if (root.waited++ < 40)
                return;
            root.waited = 0;
            root.check("a pointer resting on the zone as it tucks does not bring it back", owner.hidden, "hidden " + owner.hidden);
            tc.mouseMove(win.contentItem, eng.w - 2, Math.round((b.y0 + b.y1) / 2) + 1);
            break;
        case 7:
            if (!root.wait(!owner.hidden, 100, "a motion on the bar beside the sliver"))
                return;
            root.check("the pointer moving on the slim bar beside the sliver brings it back out", !owner.hidden, "hidden " + owner.hidden);
            break;
        case 8:
            if (!root.wait(root.barRest && b.w > 300 && eng.theOsd.contentOpacity >= 1, 400, "out after the hover"))
                return;
            root.check("out again: whole, the words seen", b.w > 300 && eng.theOsd.contentOpacity >= 1, JSON.stringify(b));
            tc.mouseMove(win.contentItem, 200, 600);
            owner.hideShown();
            break;
        case 9:
            if (!root.wait(eng.osdTuckedRest, 400, "tucked again"))
                return;
            root.move(Math.round(b.x0 + 1), Math.round((b.y0 + b.y1) / 2));
            break;
        case 10:
            if (!root.wait(!owner.hidden, 100, "a motion onto the sliver"))
                return;
            root.check("the pointer moving onto the sliver itself brings it back out", !owner.hidden, "hidden " + owner.hidden);
            break;
        case 11:
            if (!root.wait(root.barRest && b.w > 300, 400, "out after the sliver"))
                return;
            tc.mouseMove(win.contentItem, 200, 600);
            owner.hideShown();
            break;
        case 12:
            if (!root.wait(eng.osdTuckedRest, 400, "tucked before another card"))
                return;
            // a user card in between (the lock keys); a renewal of the caption waits behind it
            svc.sources.lockKeys.simulateKeys(true, false);
            svc.lockkeys();
            break;
        case 13:
            if (!root.wait(owner.shown && owner.shown.kind === "lockkeys" && root.barRest && eng.theOsd.contentOpacity >= 1, 600, "the lock keys' card"))
                return;
            root.check("another card comes out whole over the hidden one", b.w > 20 && eng.theOsd.contentOpacity >= 1 && !owner.hidden,
                       JSON.stringify(b) + " hidden " + owner.hidden);
            svc.show(root.caption("after the keys"));
            break;
        case 14:
            if (!root.wait(owner.shown && owner.shown.kind === "caption" && eng.osdTuckedRest, 1500, "the caption back after the keys"))
                return;
            root.check("the hidden caption comes back tucked after it", owner.hidden && Math.abs(b.w - root.tuckPx) < 0.01
                       && eng.theOsd.contentOpacity === 0, JSON.stringify(b) + " hidden " + owner.hidden);
            svc.withdraw("caption", "dictation");
            break;
        case 15:
            if (!root.wait(eng.osdPhase === "closed", 400, "closed after the withdraw"))
                return;
            root.check("a withdraw takes the tucked card away and forgets it", eng.osdPhase === "closed" && !owner.hidden
                       && owner._hiddenKey === "", "phase " + eng.osdPhase + " key " + owner._hiddenKey);
            // ---- PILL ----
            owner.fullscreen = true;
            svc.show(root.caption("in the pill"));
            break;
        case 16: {
            const q = pillFrame.pill;
            if (!root.wait(q.showing && q.pillT >= 2 && q.contentOpacity >= 1 && !q.moving, 600, "the caption in the pill"))
                return;
            const r = pillFrame.hideZone;
            root.check("the pill takes the hide button only: its zone over the button, no ball zone",
                       r.width > 10 && r.height > 10 && pillFrame.ballZone.width === 0 && r.x > q.x && r.x + r.width < q.x + q.width,
                       "hide " + r.x + "," + r.y + " " + r.width + "x" + r.height + " ball " + pillFrame.ballZone.width);
            const p = pillFrame.mapToItem(win.contentItem, r.x + r.width / 2, r.y + r.height / 2);
            root.move(p.x, p.y);
            tc.mouseClick(win.contentItem, p.x, p.y);
            break;
        }
        case 17: {
            const q = pillFrame.pill;
            if (!root.wait(q.ballParked, 600, "the ball parked"))
                return;
            const shown = (q.y + q.height) / q.height;
            root.check("the hide button (clicked through the pill's region) made the ball", owner.hidden && q.hidden, "hidden " + owner.hidden);
            root.check("the ball is the dot, under half of it on screen", Math.abs(q.width - ostyle.pillDotD) < 0.5 && shown > 0.05 && shown < 0.5,
                       "w " + q.width + " on screen " + shown.toFixed(3));
            root.check("the ball's zone is at the screen's top, round the ball", pillFrame.ballZone.y === 0 && pillFrame.ballZone.height > 4
                       && pillFrame.ballZone.width > q.width && pillFrame.hideZone.width === 0,
                       "ball " + pillFrame.ballZone.x + "," + pillFrame.ballZone.y + " " + pillFrame.ballZone.width + "x" + pillFrame.ballZone.height);
            root.check("the content is unseen in the ball", q.contentOpacity === 0, "content " + q.contentOpacity);
            svc.show(root.caption("renewed in the ball"));
            break;
        }
        case 18: {
            const q = pillFrame.pill;
            if (!root.wait(!q.moving, 1500, "the ball's fade"))
                return;
            root.check("a renewal lands in the ball unseen; it fades to faint", q.ballParked && Math.abs(q._ballOpacity - ostyle.pillBallFaint) < 0.01
                       && owner.shown.caption.live === "renewed in the ball", "opacity " + q._ballOpacity);
            // the pointer from elsewhere onto the ball's zone
            tc.mouseMove(win.contentItem, 200, 600);
            const z = pillFrame.ballZone;
            const p = pillFrame.mapToItem(win.contentItem, z.x + z.width / 2, z.y + 2);
            root.move(p.x, p.y);
            break;
        }
        case 19: {
            const q = pillFrame.pill;
            if (!root.wait(!owner.hidden, 100, "a motion onto the ball"))
                return;
            root.check("the pointer moving onto the ball brings the pill back", !owner.hidden && !q.hidden, "hidden " + owner.hidden);
            break;
        }
        case 20: {
            const q = pillFrame.pill;
            if (!root.wait(q.pillT >= 2 && q.contentOpacity >= 1 && !q.moving && q.offsetY === 0, 600, "the pill out again"))
                return;
            root.check("out again: full width, the words seen, back in its place", q.pillT >= 2 && q.offsetY === 0, "t " + q.pillT);
            // the pointer resting where the ball will park (over the top of the screen, above the pill), then hidden by the owner
            const p = pillFrame.mapToItem(win.contentItem, pillFrame.width / 2, 3);
            root.move(p.x, p.y);
            owner.hideShown();
            break;
        }
        case 21: {
            const q = pillFrame.pill;
            if (root.rest < 0) {
                if (!root.wait(q.ballParked || !owner.hidden, 600, "the ball parked under a resting pointer"))
                    return;
                root.rest = 0;
            }
            // a while with the pointer resting on the zone
            if (root.rest++ < 40 && owner.hidden)
                return;
            root.check("a pointer resting where the ball parks does not bring it back", q.ballParked && owner.hidden, "hidden " + owner.hidden);
            const p = pillFrame.mapToItem(win.contentItem, pillFrame.width / 2 + 1, 4);
            tc.mouseMove(win.contentItem, p.x, p.y);
            break;
        }
        case 22: {
            if (!root.wait(!owner.hidden, 100, "a motion on the ball"))
                return;
            root.check("then a motion on it brings the pill back", !owner.hidden, "hidden " + owner.hidden);
            break;
        }
        case 23: {
            const q = pillFrame.pill;
            if (!root.wait(q.pillT >= 2 && !q.moving, 600, "out before the last ball"))
                return;
            tc.mouseMove(win.contentItem, 200, 600);
            owner.hideShown();
            break;
        }
        case 24: {
            if (!root.wait(pillFrame.pill.ballParked, 600, "the ball again"))
                return;
            svc.withdraw("caption", "dictation");
            break;
        }
        case 25: {
            const q = pillFrame.pill;
            if (!root.wait(!q.showing, 400, "the ball gone"))
                return;
            root.check("a withdraw fades the ball out and forgets it", !q.showing && !owner.hidden && pillFrame.ballZone.width === 0,
                       "showing " + q.showing + " hidden " + owner.hidden);
            root.step = 26;
            root.grabAll(0);
            return;
        }
        }
        root.step++;
    }

    function grabAll(i: int): void {
        if (root.outDir === "" || i >= cellRep.count) {
            root.finish();
            return;
        }
        const names = ["pill_k1", "pill_k125", "ball_k1", "ball_k125"];
        const c = cellRep.itemAt(i);
        // qmllint disable missing-property
        const f = c.frame;
        // qmllint enable missing-property
        console.log("OHP frame " + names[i] + " " + f.width + "x" + f.height + " pill " + f.pill.x + "," + f.pill.y + " " + f.pill.width + "x" + f.pill.height
                    + " k " + f.k);
        c.grabToImage(r => {
            r.saveToFile(root.outDir + "/" + names[i] + ".png");
            root.grabAll(i + 1);
        });
    }
    function finish(): void {
        console.log("OHP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        id: ticker
        interval: 20
        repeat: true
        running: false
        onTriggered: {
            try {
                root.run();
            } catch (e) {
                root.check("step " + root.step + " threw", false, String(e) + " " + e.stack);
                ticker.stop();
                root.finish();
            }
            if (root.step > 25)
                ticker.stop();
        }
    }
    Timer {
        interval: 800
        running: true
        onTriggered: ticker.start()
    }
}
