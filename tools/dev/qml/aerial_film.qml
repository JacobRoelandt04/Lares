pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/aerial/data"
import "modules/aerial/popup"
import "modules/aerial/scene/AerialLayout.js" as Layout

// aerial_film.qml -- frames of the popup's life, written to $OUT/<film>_<nn>.png (tools/dev/aerial_film.sh composes the strips).
//   FILM=poweron   the power-on on the HELD clock: the entrance's own clock `enter` is written at 0, 1/8 .. 1 (the animation is not run: a frame is the picture at that fraction)
//   FILM=dock      a secured stranger dragged to the label, held, its password panel beside it (the engine's part played by a Loader), a wrong password, the right one, the dock
// One window, 1200 x 700 (round 3's popup is taller); every frame a grab of the whole window after the scene has rendered (a few frames, never a timer racing an animation).
Window {
    id: win
    width: 1200
    height: 700
    visible: true
    color: "#E9ECF3"
    readonly property string out: Quickshell.env("OUT") || "/tmp/aerial_film"
    readonly property string film: Quickshell.env("FILM") || "poweron"
    property int n: 0
    AerialMock {
        id: mock
        live: true
        scenario: "crowd"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 250
    }
    AerialPopup {
        id: popup
        service: mock
        family: Number(Quickshell.env("FAMILY") || 0)
        renderScale: 1
        animate: true
        entranceEnabled: false
    }
    Loader {
        id: sec
        x: 790
        active: popup.secondaryOpen
        sourceComponent: popup.secondaryComponent
        onLoaded: sec.item.secondaryKey = popup.secondaryKey
    }
    TestCase { id: tc; name: "film"; when: false; windowShown: true }
    property bool busy: false
    function shot(tag: string): void {
        win.busy = true;
        const name = win.out + "/" + win.film + "_" + String(win.n++).padStart(2, "0") + ".png";
        win.contentItem.grabToImage(r => { r.saveToFile(name); console.log("AF frame " + name + " " + tag); win.busy = false; });
        while (win.busy)
            tc.wait(30);
    }
    function pickStranger(): var {
        for (let i = 0; i < popup.cloud.tags.count; i++) {
            const x = popup.cloud.tags.itemAt(i);
            const n = x && x.visible && x.e.kind === "net" && x.e.form === "named" && x.e.secured && !x.e.known ? mock.wifi.networks.find(m => m.key === x.key) : null;
            if (n && n.security !== "eap")
                return x;
        }
        return null;
    }
    function type(text: string): void {
        for (let i = 0; i < text.length; i++)
            tc.keyClick(text.charAt(i));
    }
    Timer {
        interval: 2200
        running: true
        onTriggered: {
            win.requestActivate();
            try {
                if (win.film === "poweron") {
                    for (let i = 0; i <= 8; i++) {
                        popup.enter = i / 8;
                        tc.wait(260);
                        win.shot("enter=" + (i / 8));
                    }
                } else {
                    const t = win.pickStranger();
                    const c = { x: t.x + t.hitRect.x + t.hitRect.width / 2, y: t.y + t.hitRect.y + t.hitRect.height / 2 }, z = popup._zoneCentre;
                    win.shot("at rest");
                    tc.mouseMove(win.contentItem, c.x - 6, c.y - 4);
                    tc.mouseMove(win.contentItem, c.x, c.y);
                    tc.mousePress(win.contentItem, c.x, c.y, Qt.LeftButton);
                    for (let i = 1; i <= 8; i++) {
                        tc.mouseMove(win.contentItem, c.x + (z[0] - c.x) * i / 8, c.y + (z[1] - c.y) * i / 8);
                        tc.wait(40);
                        if (i === 3 || i === 6)
                            win.shot("carried " + i);
                    }
                    tc.mouseRelease(win.contentItem, z[0], z[1], Qt.LeftButton);
                    tc.wait(500);
                    win.shot("held, the password asked");
                    win.type("wrong");
                    tc.keyClick(Qt.Key_Return);
                    tc.wait(110);
                    win.shot("wrong: the field shakes");
                    tc.wait(500);
                    win.shot("wrong: kept");
                    for (let i = 0; i < 5; i++)
                        tc.keyClick(Qt.Key_Backspace);
                    win.type("hunter22");
                    tc.keyClick(Qt.Key_Return);
                    tc.wait(300);
                    win.shot("connecting: it flies onto the label");
                    tc.wait(260);
                    win.shot("docking");
                    tc.wait(700);
                    win.shot("docked");
                }
            } catch (e) {
                console.log("AF error " + e);
            }
            console.log("AF done " + win.n);
            Qt.quit();
        }
    }
}
