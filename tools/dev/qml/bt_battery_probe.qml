pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/glyphs"
import "modules/aerial/bar"
import "modules/aerial/bar/BtBattery.js" as Battery

// =============================================================================
// bt_battery_probe.qml -- the battery stripe's rules (BtBattery.js) on fixtures, then the pill: the stripe's presence follows
// them, the icons never move, the colours are theme tokens. Prints one `BT_BATTERY FAIL <check>` per failure and
// `BT_BATTERY RESULT PASS|FAIL` (tools/dev/bt_battery_probe.sh).
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 200
        implicitHeight: 100
        visible: true
        color: Theme.surface

        property int fails: 0
        function check(ok, what) {
            if (!ok) {
                win.fails++;
                console.log("BT_BATTERY FAIL " + what);
            }
        }
        function dev(addr, pct, connected) {
            return { addr: addr, name: "d" + addr, connected: connected !== false, batteryAvailable: pct >= 0, batteryPct: Math.max(0, pct) };
        }

        function rules() {
            const A = "AA:00:00:00:00:01", B = "AA:00:00:00:00:02", C = "AA:00:00:00:00:03";
            let s = Battery.summary([], null);
            win.check(!s.shown && s.count === 0, "none -> collapsed");
            s = Battery.summary([win.dev(A, -1)], null);
            win.check(!s.shown, "a device with no report -> collapsed");
            s = Battery.summary([win.dev(A, 60, false)], null);
            win.check(!s.shown, "a device not connected -> not counted");
            s = Battery.summary([win.dev(A, 90), win.dev(B, 40), win.dev(C, -1)], null);
            win.check(s.shown && s.pct === 40 && s.count === 2 && Math.abs(s.fraction - 0.4) < 1e-9, "several -> the lowest (40 of 90/40, 2 counted)");
            s = Battery.summary([win.dev(C, -1)], { "AA:00:00:00:00:03": { left: { pct: 70 }, right: { pct: 35 }, case: { pct: 5 } } });
            win.check(s.shown && s.pct === 35, "earbuds -> the lower bud, never the case");
            s = Battery.summary([win.dev(C, -1)], { "AA:00:00:00:00:03": { case: { pct: 50 } } });
            win.check(!s.shown, "a case alone is no report");
            s = Battery.summary([win.dev(C, 80)], { "AA:00:00:00:00:03": { left: { pct: 70 } } });
            win.check(s.pct === 70, "one bud alone counts, over the device's main figure");
            s = Battery.summary([win.dev(A, 15)], { "AA:00:00:00:00:01": { main: { pct: 15, charging: true } } });
            win.check(s.charging && s.level === "low", "charging comes from UPower");
            win.check(Battery.levelOf(20) === "low" && Battery.levelOf(21) === "ok" && Battery.levelOf(10) === "crit" && Battery.levelOf(11) === "low", "level edges 20 / 10");
            s = Battery.summary([win.dev(A, 0)], null);
            win.check(s.shown && s.pct === 0 && s.level === "crit", "0 % that is reported is shown (empty)");
            // the same rules on the service's own device records (summaryOfDevs): the lowest connected figure, none -> collapsed, charging from the parts
            const sd = (b, c, p) => ({ address: "AA:00:00:00:00:0" + b, name: "s" + b, connected: c !== false, battery: b === 0 ? -1 : p, parts: null });
            s = Battery.summaryOfDevs([]);
            win.check(!s.shown, "service records: none -> collapsed");
            s = Battery.summaryOfDevs([sd(1, true, 90), sd(2, true, 40), sd(0, true, -1), sd(3, false, 10)]);
            win.check(s.shown && s.pct === 40 && s.count === 2, "service records: the lowest connected figure (a device with none and a gone one do not count)");
            s = Battery.summaryOfDevs([{ address: "A", name: "b", connected: true, battery: 15, parts: { left: 15, right: 30, case: -1, charging: true } }]);
            win.check(s.charging && s.level === "low", "service records: charging is the parts' flag");
        }

        AerialPillStand {
            id: stand
        }
        // the pill reads the SERVICE's device records (`battery`: -1 = none reported, `parts`)
        property var devs: []
        onDevsChanged: stand.setBt({ on: true, devices: win.devs.map(d => ({ address: d.addr, name: d.name, connected: d.connected, battery: d.batteryAvailable ? d.batteryPct : -1, parts: null })) })
        AerialBarButton {
            id: pill
            x: 20
            y: 20
            service: stand
            flourishEnabled: false
            width: implicitWidth
            height: implicitHeight
        }

        function pillSteps() {
            const stripe = pill.children.find(c => c.objectName === "btBattery");
            win.check(!!stripe, "the pill has its stripe");
            // the rest places, read once the first frames have settled (the glyphs' text sizes land with the font)
            // a connected device that reports nothing: the Bluetooth glyph is already its "connected" form, so the reference
            // is taken there and only the stripe differs afterwards
            win.devs = [win.dev("AA:00:00:00:00:09", -1)];
            const netX = pill.netGlyphItem.mapToItem(null, 0, 0).x, btX = pill.btGlyphItem.mapToItem(null, 0, 0).x;
            win.check(!stripe.visible && pill.batteryPresence === 0, "no device: stripe collapsed");
            return { stripe: stripe, netX: netX, btX: btX };
        }
        property var ctx: null
        property int phase: 0
        Timer {
            interval: 700
            running: true
            repeat: true
            onTriggered: {
                if (win.phase === 0) {
                    win.rules();
                } else if (win.phase === 1) {
                    win.ctx = win.pillSteps();
                } else if (win.phase === 2) {
                    win.devs = [win.dev("AA:00:00:00:00:01", 90)];
                } else if (win.phase === 3) {
                    const c = win.ctx;
                    win.check(c.stripe.visible && c.stripe.opacity > 0.99, "a device at 90: stripe present");
                    win.check(Math.abs(c.stripe.fill - 0.9) < 0.01, "stripe fill is the charge (0.9)");
                    win.check(pill.netGlyphItem.mapToItem(null, 0, 0).x === c.netX && pill.btGlyphItem.mapToItem(null, 0, 0).x === c.btX, "the icons did not move " + c.netX + "/" + c.btX + " -> " + pill.netGlyphItem.mapToItem(null, 0, 0).x + "/" + pill.btGlyphItem.mapToItem(null, 0, 0).x);
                    const mid = c.stripe.x + c.stripe.width / 2;
                    win.check(mid === pill.width / 2 && c.stripe.x === Math.round(c.stripe.x), "stripe centred on whole pixels");
                    win.check(Qt.colorEqual(pill.batteryColor, BarHues.btOn), "ok level wears the Bluetooth hue");
                    win.devs = [win.dev("AA:00:00:00:00:01", 15)];
                } else if (win.phase === 4) {
                    win.check(Qt.colorEqual(pill.batteryColor, Theme.warn), "15 % -> theme warn");
                    win.devs = [win.dev("AA:00:00:00:00:01", 5)];
                } else if (win.phase === 5) {
                    win.check(Qt.colorEqual(pill.batteryColor, Theme.error), "5 % -> theme error");
                    win.devs = [];
                } else if (win.phase === 6) {
                    win.check(!win.ctx.stripe.visible, "device gone: collapsed again");
                    win.check(pill.netGlyphItem.mapToItem(null, 0, 0).x === win.ctx.netX, "icons still did not move");
                    console.log("BT_BATTERY RESULT " + (win.fails === 0 ? "PASS" : "FAIL"));
                    Qt.quit();
                }
                win.phase++;
            }
        }
    }
}
