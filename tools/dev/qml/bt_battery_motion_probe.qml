//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/aerial/bar"

// =============================================================================
// bt_battery_motion_probe.qml -- the Bluetooth battery stripe's MOTION on the networking pill, frame by frame
// (tools/dev/bt_battery_motion_probe.sh runs it offscreen and judges `BBM f ...` lines).
//
// Scenario (one run; a frame is one animation tick, 16 ms offscreen): A) a device at 90 % appears (the stripe grows from its foot);
// B) traffic comes (the stripe yields, then the figures fade in); C) the traffic ends (the figures leave, the stripe waits, grows back);
// D) traffic again and leaves, and returns inside the wait (the stripe stays down, the figures come back); E) the traffic ends
// for good (regrows), F) the device goes (shrinks to its foot).
// Prints `BBM f <n> <step> <presence> <height> <foot> <figures presence> <trafficShown>` per frame (design px) and `BBM done`.
// FILM=1: each frame's pill is grabbed to OUT_DIR/film/<n>_<step>.png. K = scale (device px per design px).
// =============================================================================
ShellRoot {
    id: root
    readonly property real k: Number(Quickshell.env("K") || "1")
    readonly property bool film: Quickshell.env("FILM") === "1"
    readonly property string outDir: Quickshell.env("OUT_DIR") || "/tmp/bbm"

    FloatingWindow {
        id: win
        implicitWidth: Math.ceil(90 * root.k)
        implicitHeight: Math.ceil(44 * root.k)
        visible: true
        color: Theme.surface

        Item {
            id: stage
            width: win.width
            height: win.height
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            Item {
                scale: root.k
                transformOrigin: Item.TopLeft
                width: stage.width / root.k
                height: stage.height / root.k
                AerialPillStand {
                    id: stand
                }
                AerialBarButton {
                    id: pill
                    x: 14
                    y: 9
                    service: stand
                    flourishEnabled: false
                    halfLength: 26
                    thickness: 26
                    // wall-clock timer against 16 ms animation frames (offscreen: ~2.7 frames per ms of wall)
                    regrowDelayMs: 300
                    width: implicitWidth
                    height: implicitHeight
                }
            }
        }
    }
    property var devs: []
    onDevsChanged: stand.setBt({ on: true, devices: root.devs.map(d => ({ address: d.addr, name: d.name, connected: d.connected, battery: d.batteryAvailable ? d.batteryPct : -1, parts: null })) })
    property int serial: 0
    function reading(mbps: real): void {
        root.serial++;
        stand.rates = { iface: "wlp", rxBps: mbps * 1e6 / 8, txBps: 0, atMs: root.serial };
    }
    function stripe(): var {
        return pill.children.find(c => c.objectName === "btBattery");
    }

    // a step: its name, what it does on entry, and the frame it ends on (a predicate or a frame count)
    property int _step: 0
    property int _sf: 0
    property int _n: 0
    property int _leftAt: -1
    readonly property var steps: [
        { name: "A_appear", enter: () => { root.devs = [{ addr: "AA", name: "H", connected: true, batteryAvailable: true, batteryPct: 90 }]; },
          until: () => pill.batteryPresence >= 0.9999 && root._sf > 5, tick: () => {} },
        { name: "B_traffic", enter: () => {}, until: () => root._sf > 70, tick: () => { if (root._sf % 6 === 0) root.reading(40); } },
        { name: "C_leave", enter: () => {}, until: () => root._sf > 20 && pill.batteryPresence >= 0.9999, tick: () => { if (root._sf % 6 === 0) root.reading(0); } },
        { name: "D_burst", enter: () => {}, until: () => root._sf > 40, tick: () => { if (root._sf % 6 === 0) root.reading(40); } },
        // leave, and come back as soon as the figures are gone and 10 frames have passed: inside the regrow wait
        { name: "D_leave", enter: () => { root._leftAt = -1; },
          until: () => root._leftAt >= 0 && root._sf - root._leftAt > 10 && pill.batteryPresence < 0.0001,
          tick: () => {
              if (root._sf % 6 === 0) root.reading(0);
              if (root._leftAt < 0 && !pill.trafficShown) root._leftAt = root._sf;
          } },
        { name: "D_back", enter: () => {}, until: () => root._sf > 60, tick: () => { if (root._sf % 6 === 0) root.reading(40); } },
        { name: "E_leave", enter: () => {}, until: () => root._sf > 20 && pill.batteryPresence >= 0.9999, tick: () => { if (root._sf % 6 === 0) root.reading(0); } },
        { name: "F_gone", enter: () => { root.devs = []; }, until: () => root._sf > 5 && pill.batteryPresence < 0.0001, tick: () => {} }
    ]

    FrameAnimation {
        id: fa
        running: true
        onTriggered: {
            if (root._step >= root.steps.length) {
                fa.running = false;
                console.log("BBM done");
                Qt.quit();
                return;
            }
            const st = root.steps[root._step];
            if (root._sf === 0)
                st.enter();
            st.tick();
            const s = root.stripe();
            console.log("BBM f " + root._n + " " + st.name + " " + pill.batteryPresence.toFixed(4) + " " + s.height.toFixed(3) + " "
                        + Number(s.y + s.height).toFixed(3) + " " + pill._present.toFixed(4) + " " + (pill.trafficShown ? 1 : 0));
            if (root.film)
                stage.grabToImage(function (r) { r.saveToFile(root.outDir + "/film/" + String(root._n).padStart(4, "0") + ".png"); });
            root._n++;
            root._sf++;
            if (st.until() || root._sf > 900) {
                root._step++;
                root._sf = 0;
            }
        }
    }
}
