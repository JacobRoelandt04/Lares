pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/aerial/bar"
import "modules/aerial/data/AerialModel.js" as Model

// =============================================================================
// bt_battery_sheet.qml -- the networking pill's battery stripe in every state, one PNG per cell (tools/dev/bt_battery_sheet.sh
// composes them, in each mode and at each scale). The pill is the module's own AerialBarButton on a stand-in service, in a cell on
// the bar's surface; the fixtures are the probe's (BtBattery.js's inputs).
//   OUT_DIR   where the cells go (<name>.png) -- required
// Prints `BT_BATTERY_SHEET cell <name>` per grab and `BT_BATTERY_SHEET RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 600
        implicitHeight: 300
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""

        function dev(name, addr, pct, extra) {
            return Object.assign({ addr: addr, name: name, connected: true, batteryAvailable: pct >= 0, batteryPct: Math.max(0, pct) }, extra || {});
        }
        readonly property var states: [
            { name: "none", devs: [] },
            { name: "nobattery", devs: [win.dev("Keyboard", "AA:00:00:00:00:01", -1)] },
            { name: "p90", devs: [win.dev("Headset", "AA:00:00:00:00:01", 90)] },
            { name: "p40", devs: [win.dev("Headset", "AA:00:00:00:00:01", 40)] },
            { name: "p15", devs: [win.dev("Headset", "AA:00:00:00:00:01", 15)] },
            { name: "p5", devs: [win.dev("Headset", "AA:00:00:00:00:01", 5)] },
            { name: "two", devs: [win.dev("Headset", "AA:00:00:00:00:01", 90), win.dev("Mouse", "AA:00:00:00:00:02", 40)] },
            { name: "buds", devs: [win.dev("Buds", "AA:00:00:00:00:03", -1)],
              parts: { "AA:00:00:00:00:03": { left: { pct: 70 }, right: { pct: 35 }, case: { pct: 10 } } } },
            { name: "charging", devs: [win.dev("Headset", "AA:00:00:00:00:01", 15)],
              parts: { "AA:00:00:00:00:01": { main: { pct: 15, charging: true } } } }
        ]

        Repeater {
            id: rep
            model: win.states
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                x: 20 + (index % 3) * 190
                y: 20 + Math.floor(index / 3) * 90
                width: 80
                height: 40
                // the service's own folding of the device and UPower's parts into the record the pill reads (AerialModel.btBattery)
                AerialPillStand {
                    id: stand
                    Component.onCompleted: stand.setBt({ on: true, devices: cell.modelData.devs.map(d => {
                        const b = Model.btBattery({ address: d.addr, batteryAvailable: d.batteryAvailable, battery: d.batteryPct }, cell.modelData.parts ?? null);
                        return { address: d.addr, name: d.name, connected: d.connected, battery: b.pct, parts: b.parts };
                    }) })
                }
                Rectangle {
                    anchors.fill: parent
                    color: Theme.surface
                }
                AerialBarButton {
                    id: pill
                    objectName: "pill_" + cell.modelData.name
                    x: 14
                    y: 7
                    service: stand
                    flourishEnabled: false
                    halfLength: 26
                    thickness: 26
                    width: implicitWidth
                    height: implicitHeight
                }
            }
        }

        property int step: 0
        property int fails: 0
        Timer {
            interval: 900
            running: true
            repeat: true
            onTriggered: {
                if (win.step >= win.states.length) {
                    stop();
                    console.log("BT_BATTERY_SHEET RESULT " + (win.fails === 0 ? "PASS" : "FAIL"));
                    Qt.quit();
                    return;
                }
                const nm = win.states[win.step].name;
                win.step++;
                const target = rep.itemAt(win.step - 1);
                if (!target || win.outDir === "") {
                    win.fails++;
                    console.log("BT_BATTERY_SHEET FAIL no cell " + nm);
                    return;
                }
                target.grabToImage(r => {
                    if (!r.saveToFile(win.outDir + "/" + nm + ".png"))
                        win.fails++;
                    console.log("BT_BATTERY_SHEET cell " + nm);
                });
            }
        }
    }
}
