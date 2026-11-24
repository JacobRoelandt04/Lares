pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import "modules/common/theme"
import "modules/bar/gooey"
import "modules/aerial"
import "modules/aerial/data"

// =============================================================================
// tools/dev/qml/aerial_side_probe.qml -- where aerial's detail panels land in the REAL engine (tools/dev/aerial_life_probe.sh runs it as its second run; result line `AS RESULT`).
// One GooeyEngine, a top bar, aerial's hosted owner on the mock service, one screen of 1800 x 1000. The owner sits at three places along the bar (the screen's left end, the middle,
// the right end); at each, every panel kind is opened through the popup's own paths and the child body's box is read from the engine:
//   inside      the box is whole on the screen (never offscreen), whatever the panel kind (the tallest: the VPN's 700 and the network's 600)
//   side        on the popup's LEFT, flush with its face (child right edge on the popup's left edge); on the RIGHT when the left has no room (the owner at the screen's left end)
//   long edge   a panel no taller than the popup stays inside the popup's own span (joined along the long edge); a taller one overhangs and is still on screen
// Every pointer / key path is the popup's own function; nothing here touches a real daemon (the service is the mock).
// =============================================================================
Window {
    id: w
    width: 1800
    height: 1000
    visible: true
    color: "#3B4453"

    property var fails: []
    property var rows: []
    function check(name: string, ok: bool, why: string): void {
        console.log("AS " + name + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : ""));
        if (!ok)
            w.fails.push(name);
    }

    AerialMock {
        id: aerialMock
        live: true
        scenario: "crowd"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 100
    }
    GooeyEngine {
        id: eng
        anchors.fill: parent
        surfaceColor: Theme.surface
        barsList: [topBar]
        GooeyBar {
            id: topBar
            engine: eng
            barId: "top"
            edge: "top"
            rawPos: 0
            rawLen: eng.w
            AerialBarOwner {
                id: owner
                x: w.ownerX
                y: Math.round((topBar.height - owner.height) / 2)
                width: owner.implicitWidth
                height: owner.implicitHeight
                engine: eng
                bar: topBar
                barId: "top"
                shellHosted: true
                service: aerialMock
            }
        }
    }
    property real ownerX: 900
    TestCase {
        id: tc
        name: "side"
        when: false
    }

    property int _step: 0
    property var _steps: []
    property var _cases: []
    property int _ci: 0
    property string _where: ""
    readonly property var popup: eng.thePopup ? eng.thePopup.contentItem : null
    function isOpen(): bool {
        return eng.popupOpen && eng.thePopup.phase === "open" && !!eng.thePopup.contentItem;
    }
    function open(kind: string): void {
        const c = w.popup;
        c.closeSecondary();
        if (kind === "bt") {
            c.drag.activated("bt:" + aerialMock.bt.devices[0].address, Qt.point(300, 300));
        } else if (kind === "hotspot") {
            c.drag.activated("hotspot", Qt.point(c._zoneCentre[0], c._zoneCentre[1]));
        } else if (kind === "label") {
            c.drag.activated("label", Qt.point(c._zoneCentre[0], c._zoneCentre[1]));
        } else {
            c.openByKey(kind);
        }
    }
    Timer {
        id: tick
        interval: 300
        repeat: true
        running: true
        onTriggered: {
            tick.stop();
            try {
                w._advance();
            } catch (e) {
                w.check("step-" + w._step, false, "threw " + e);
                w._step = 1e9;
            }
            tick.start();
        }
    }
    property real _t0: 0
    function _advance(): void {
        if (w._step === 0) {
            owner.open();
            w._t0 = Date.now();
            w._step = 1;
            return;
        }
        if (w._step === 1) {
            if (!w.isOpen()) {
                if (Date.now() - w._t0 > 8000) {
                    w.check("popup-opens", false, "never opened at " + w.ownerX);
                    w._step = 1e9;
                }
                return;
            }
            w._cases = ["mem", "jack", "usage", "pad.link", "pad.net", "globe", "label", "hotspot", "bt"];
            w._ci = 0;
            w._step = 2;
            return;
        }
        if (w._step === 2) {
            if (w._ci >= w._cases.length) {
                w._step = 4;
                return;
            }
            w.open(w._cases[w._ci]);
            w._t0 = Date.now();
            w._step = 3;
            return;
        }
        if (w._step === 3) {
            // wait for the child to stand: open and its size final (settled over two reads)
            if (!eng.childOpen || eng.childPopup.phase !== "open" || Date.now() - w._t0 < 1100)
                return;
            const p = eng.thePopup, c = eng.childPopup;
            const px0 = p.popX, py0 = p.popY, px1 = p.popX + p.popW, py1 = p.popY + p.popH;
            const cx0 = c.popX, cy0 = c.popY, cx1 = c.popX + c.popW, cy1 = c.popY + c.popH;
            const kind = w._cases[w._ci], tag = w._where + "." + kind;
            const inside = cx0 >= -0.5 && cy0 >= -0.5 && cx1 <= w.width + 0.5 && cy1 <= w.height + 0.5;
            w.check(tag + ".inside-the-screen", inside, "child [" + cx0.toFixed(0) + "," + cy0.toFixed(0) + " .. " + cx1.toFixed(0) + "," + cy1.toFixed(0) + "] screen " + w.width + "x" + w.height);
            const wantLeft = p.popX >= c.popW + 4;
            const flushLeft = Math.abs(cx1 - px0) <= 2, flushRight = Math.abs(cx0 - px1) <= 2;
            w.check(tag + ".side", wantLeft ? flushLeft : flushRight, (wantLeft ? "left" : "right") + " wanted: child x " + cx0.toFixed(0) + ".." + cx1.toFixed(0) + " popup x " + px0.toFixed(0) + ".." + px1.toFixed(0));
            const longer = c.popH > p.popH + 0.5;
            w.check(tag + ".long-edge", longer ? true : (cy0 >= py0 - 1 && cy1 <= py1 + 1), (longer ? "overhangs (" : "inside (") + c.popH.toFixed(0) + " of " + p.popH.toFixed(0) + ") y " + cy0.toFixed(0) + ".." + cy1.toFixed(0) + " popup " + py0.toFixed(0) + ".." + py1.toFixed(0));
            w.rows.push(tag + " h " + c.popH.toFixed(0));
            w._ci++;
            w._step = 2;
            return;
        }
        if (w._step === 4) {
            w.popup.closeSecondary();
            owner.close();
            w._t0 = Date.now();
            w._step = 5;
            return;
        }
        if (w._step === 5) {
            if (eng.popupOpen && Date.now() - w._t0 < 6000)
                return;
            w._where = w._where === "" ? "mid" : w._where;
            const next = w._places.shift();
            if (next === undefined) {
                console.log("AS tallest " + w.rows.filter(r => /^mid/.test(r)).join(" | "));
                console.log("AS RESULT " + (w.fails.length ? "FAIL (" + w.fails.join(", ") + ")" : "PASS"));
                Qt.quit();
                return;
            }
            w._where = next[0];
            w.ownerX = next[1];
            w._t0 = Date.now();
            w._step = 6;
            return;
        }
        if (w._step === 6) {
            if (Date.now() - w._t0 < 500)
                return;
            owner.open();
            w._t0 = Date.now();
            w._step = 1;
            return;
        }
        if (w._step >= 1e9) {
            console.log("AS RESULT FAIL (" + w.fails.join(", ") + ")");
            Qt.quit();
        }
    }
    property var _places: [["left", 60], ["right", 1700]]
    Component.onCompleted: w._where = "mid"
}
