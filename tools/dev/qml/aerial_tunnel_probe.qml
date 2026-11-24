pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/aerial/data"
import "modules/common/theme"
import "modules/aerial/popup"

// The tunnel's transition judged ON THE REAL POPUP (round 4: the label's wipe was proven on the label alone and never played in the popup): the service brings the tunnel
// up (`vpnConnect`, the mock's own sequence) and takes it down again, and at every drawn frame the label's `chrome` is read. The run prints
//   TUNNEL up   frames=<n> between=<n> span=<ms>     (frames drawn while 0.02 < chrome < 0.98, and how long the label was between the two; viaLead: the most the
//                                                     "via" line's room and the wipe were apart)
//   TUNNEL down ...
//   AERIAL_TUNNEL RESULT PASS|FAIL
// and with FILM=<dir> grabs a strip of stills (<dir>/up_<i>.png) at the wipe's shares 0.1 .. 0.9. Offscreen only (the runner sets the platform).
// ROUND 5, the chrome is a mirror: with the tunnel up and everything held still the pointer is rested at two far places and the label's middle is grabbed at each
// ($SHOTS/chrome_a.png, chrome_b.png: the room in the plate must have moved), the same on paper afterwards (paper_a / paper_b: not a pixel may), and the plate must hold
// the card's tilt while the card is out. `TUNNEL shots <x> <y> <w> <h>` names the rect the runner compares (tools/dev/aerial_tunnel_probe.sh).
Window {
    id: win
    width: 764
    height: 650
    visible: true
    color: Theme.surface
    readonly property string film: Quickshell.env("FILM") || ""
    AerialMock {
        id: mock
        live: true
        scenario: Quickshell.env("SCEN") || "home"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 400
    }
    Rectangle { anchors.fill: parent; color: Theme.surface }
    // THE BUILD IS THE ENGINE'S (GooeyEngine._prebuildNow): incubated asynchronously, parked, then opened. A popup built in one go never showed the fault: a label whose rows
    // arrive over several turns threw in its first placement and never left "being built" (it snapped every motion for its whole life). BUILD=sync builds in one go.
    Item { id: stage; anchors.fill: parent }
    Component {
        id: popComp
        AerialPopup {
            service: mock
            family: Number(Quickshell.env("FAMILY") || 0)
            sizeScale: 1
            renderScale: 1
            animate: true
            entranceEnabled: false
            soundsEnabled: false
        }
    }
    property var popup: null
    property var _inc: null
    function _build(): void {
        if (Quickshell.env("BUILD") === "sync") {
            win.popup = popComp.createObject(stage, {});
            return;
        }
        const inc = popComp.incubateObject(stage, { parked: true, open: false }, Qt.Asynchronous);
        win._inc = inc;
        const done = () => {
            if (inc.status !== Component.Ready || win.popup)
                return;
            inc.object.parked = false;
            inc.object.open = true;
            win.popup = inc.object;
        };
        if (inc.status === Component.Ready) {
            done();
        } else if (Quickshell.env("BUILD") === "force") {
            // the click that arrives while the hover's build is in the air (GooeyEngine._finishIncubation): the rest of the build in one call
            forceTimer.start();
        } else {
            inc.onStatusChanged = done;
        }
    }
    Timer {
        id: forceTimer
        interval: Number(Quickshell.env("FORCE_MS") || 0)
        onTriggered: {
            win._inc.forceCompletion();
            win._inc.object.parked = false;
            win._inc.object.open = true;
            win.popup = win._inc.object;
        }
    }
    readonly property var lbl: win.popup ? win.popup.scene.labelItem : null
    TestCase { id: tc; name: "tunnel"; when: false; windowShown: true }
    readonly property string shots: Quickshell.env("SHOTS") || ""
    // two grabs of the label's middle, the pointer rested far left / high, then far right / low, everything else held still (no pulse, no float: only the pointer acts)
    function _pair(tag: string, then: var): void {
        const o = win.popup.cloud.origin, r = Qt.rect(Math.round(o[0] - 52), Math.round(o[1] - 40), 104, 80);
        win.popup.halted = true;
        tc.mouseMove(win.contentItem, 96, 120);
        tc.mouseMove(win.contentItem, 100, 124);
        tc.wait(900);
        win.contentItem.grabToImage(a => {
            a.saveToFile(win.shots + "/" + tag + "_a.png");
            tc.mouseMove(win.contentItem, 676, 596);
            tc.mouseMove(win.contentItem, 680, 600);
            tc.wait(900);
            win.contentItem.grabToImage(b => {
                b.saveToFile(win.shots + "/" + tag + "_b.png");
                console.log("TUNNEL shots " + r.x + " " + r.y + " " + r.width + " " + r.height);
                win.popup.halted = false;
                then();
            });
        });
    }
    property string phase: ""
    property var rec: ({ frames: 0, between: 0, t0: 0, tIn: 0, tOut: 0, last: -1, steps: 0, maxStep: 0, viaLead: 0, viaBetween: 0 })
    property var bad: []
    property int shot: 0
    property bool grabbing: false
    onAfterAnimating: {
        if (win.phase === "" || !win.lbl)
            return;
        const c = win.lbl.chrome, r = win.rec;
        r.frames++;
        if (c > 0.02 && c < 0.98) {
            r.between++;
            if (r.tIn === 0)
                r.tIn = Date.now();
            r.tOut = Date.now();
        }
        if (r.last >= 0) {
            const d = Math.abs(c - r.last);
            if (d > 0)
                r.steps++;
            r.maxStep = Math.max(r.maxStep, d);
        }
        r.last = c;
        // the "via" line's room opens WITH the wipe (one motion of the print), never ahead of it
        const v = win.lbl.viaT;
        if (v > 0.02 && v < 0.98)
            r.viaBetween++;
        r.viaLead = Math.max(r.viaLead, Math.abs(v - c));
        if (win.film !== "" && win.phase === "up" && !win.grabbing && win.shot < 5 && c >= 0.1 + 0.2 * win.shot) {
            const i = win.shot++;
            win.grabbing = true;
            win.popup.grabToImage(res => {
                res.saveToFile(win.film + "/up_" + i + ".png");
                win.grabbing = false;
            });
        }
    }
    function _judge(name: string, want: real): void {
        const r = win.rec, span = r.tOut - r.tIn;
        console.log("TUNNEL " + name + " built=" + win.lbl._built + " frames=" + r.frames + " between=" + r.between + " span=" + span + " steps=" + r.steps + " maxStep=" + r.maxStep.toFixed(3) + " chrome=" + win.lbl.chrome + " viaBetween=" + r.viaBetween + " viaLead=" + r.viaLead.toFixed(2));
        if (Math.abs(win.lbl.chrome - want) > 0.001)
            win.bad.push(name + ": the label did not arrive (chrome " + win.lbl.chrome + ")");
        if (r.between < 8)
            win.bad.push(name + ": the label turned in " + r.between + " frames (no wipe)");
        else if (r.between < 60)
            win.bad.push(name + ": the label turned in " + r.between + " frames (a quick wipe: it takes 1.5 s, about 75)");
        if (r.maxStep > 0.34)
            win.bad.push(name + ": the wipe jumped " + r.maxStep.toFixed(2) + " in one frame");
        if (r.viaBetween < 8 || r.viaLead > 0.2)
            win.bad.push(name + ": the via line does not ride the wipe (" + r.viaBetween + " frames between, " + r.viaLead.toFixed(2) + " apart at most)");
    }
    function _begin(name: string): void {
        win.rec = { frames: 0, between: 0, t0: Date.now(), tIn: 0, tOut: 0, last: win.lbl.chrome, steps: 0, maxStep: 0, viaLead: 0, viaBetween: 0 };
        win.phase = name;
    }
    property int step: 0
    Timer {
        id: seq
        interval: 300
        running: Quickshell.env("AT_RUN") === "1"
        onTriggered: {
            if (!win.popup) {
                if (win.step === 0 && !win._inc && Quickshell.env("BUILD") !== "sync" || win.step === 0 && Quickshell.env("BUILD") === "sync")
                    win._build();
                win.step = -1;
                seq.interval = 2500;
                seq.restart();
                return;
            }
            if (win.step < 0)
                win.step = 0;
            win.step++;
            if (win.step === 1) {
                if (win.lbl.chrome !== 0)
                    win.bad.push("start: the label is not paper");
                win._begin("up");
                mock.vpnConnect({ country: "NL" });
                seq.interval = 3500;
                seq.restart();
            } else if (win.step === 2) {
                win._judge("up", 1);
                win.phase = "";
                // the card out of its slot under the tunnel: the plate holds the tilt (the room in it slides)
                // (the scene eases the card out: the plate is read once it is up, and the card is seated again before the shots)
                const sc = win.popup.scene;
                sc.airplaneT = 1;
                for (let i = 0; i < 40 && !(sc.cardTilt > 0.3); i++)
                    tc.wait(100);
                if (!(sc.cardTilt > 0.3) || Math.abs(win.lbl.tilt - sc.cardTilt) > 1e-6)
                    win.bad.push("tilt: the plate does not hold the card's tilt (" + win.lbl.tilt + " of " + sc.cardTilt + ")");
                sc.airplaneT = 0;
                for (let i = 0; i < 40 && sc.cardTilt > 0; i++)
                    tc.wait(100);
                const next = () => {
                    win._begin("down");
                    mock.vpnDisconnect();
                    seq.restart();
                };
                if (win.shots !== "")
                    win._pair("chrome", next);
                else
                    next();
            } else {
                win._judge("down", 0);
                win.phase = "";
                const done = () => {
                    console.log(win.bad.length ? "AERIAL_TUNNEL RESULT FAIL " + win.bad.join(" | ") : "AERIAL_TUNNEL RESULT PASS (the label wipes to chrome and back on the popup)");
                    Qt.quit();
                };
                if (win.shots !== "")
                    win._pair("paper", done);
                else
                    done();
            }
        }
    }
    Timer { interval: 0; running: Quickshell.env("AT_RUN") !== "1"; onTriggered: Qt.quit() }
}
