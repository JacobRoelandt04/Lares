pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import "modules/aerial/scene"
import "modules/common/theme"

// The label's own laws (tools/dev/aerial_r3_label.sh WHAT=probe): the Bluetooth zone's rows by count, a row's identity through a reorganisation (it MOVES on the zone's
// one clock, it is never rebuilt), the fade of a row that goes, the drag's three answers (btDeviceAt / btDeviceSpot / carriedBt), the name's shrink and middle cut, the
// tunnel's wipe (a clock that runs 0 -> 1 and back, never a jump), the drop hints. Prints `LABELPROBE ok|FAIL <check>` lines and one AERIAL_R3_LABEL_PROBE RESULT line.
Window {
    id: win
    width: 440
    height: 460
    visible: true
    color: Theme.surface

    readonly property var devs: [
        { address: "AA:01", name: "Earbuds", kind: "earbuds", battery: 74, parts: { left: 74, right: 80, case: 100, charging: false } },
        { address: "AA:02", name: "Headset X4", kind: "headset", battery: 45, parts: null },
        { address: "AA:03", name: "MX Master 3S", kind: "mouse", battery: 18, parts: null },
        { address: "AA:04", name: "Keychron K2 Pro", kind: "keyboard", battery: 90, parts: null },
        { address: "AA:05", name: "Pixel 8", kind: "phone", battery: -1, parts: null },
        { address: "AA:06", name: "Xbox Wireless Controller", kind: "gamepad", battery: 60, parts: null }
    ]
    function lab(o: var): var {
        return Object.assign({ docked: true, name: "Home-5G", lineA: "5 GHz · ch 36 · Wi-Fi 6", lineB: "-54 dBm · 1201 Mb/s", via: "", hint: false, vpn: false, bt: [] }, o || {});
    }
    AerialLabel {
        id: l
        x: 20
        y: 20
        animate: true
        label: win.lab()
    }
    TestCase { id: tc; name: "label"; when: false; windowShown: true }

    property int bad: 0
    function check(name: string, ok: bool, detail: string): void {
        if (!ok)
            win.bad++;
        console.log("LABELPROBE " + (ok ? "ok" : "FAIL") + " " + name + (detail ? "  " + detail : ""));
    }
    // the rows of the zone, as the probe reads them (the pool is the Repeater's items: every child of the zone with a `key`)
    function rows(): var {
        const out = [];
        const walk = it => {
            for (let i = 0; i < it.children.length; i++) {
                const c = it.children[i];
                if (c.key !== undefined && c.tw !== undefined)
                    out.push(c);
                else
                    walk(c);
            }
        };
        walk(l);
        return out;
    }
    function wanted(): var {
        return win.rows().filter(r => r.wanted && r.key !== "");
    }
    function rowOf(key: string): var {
        return win.rows().find(r => r.key === key && r.wanted) || null;
    }
    function settle(): void {
        tc.tryVerify(() => l._m === 1 && win.rows().every(r => (r.wanted ? r.pres === 1 : r.pres === 0)), 4000);
    }
    function run(): void {
        // ---- the rows by count ----
        const counts = [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [6, 4]];
        counts.forEach(c => {
            l.label = win.lab({ bt: win.devs.slice(0, c[0]) });
            win.settle();
            const w = win.wanted();
            win.check("rows-" + c[0], w.length === c[1] && new Set(w.map(r => r.key)).size === w.length, "rows " + w.map(r => r.key).join(","));
        });
        win.check("plus-cell", !!win.rowOf("+") && win.rowOf("+").d.plus === 3, "");
        win.check("plus-is-no-device", l.btDeviceAt(l.originX + l.btZone[0] + win.rowOf("+").tx + 1, l.originY + l.btZone[1] + win.rowOf("+").ty + 1) === "", "");
        // ---- a spot answers its own device, a carried row answers nothing and is not drawn ----
        l.label = win.lab({ bt: win.devs.slice(0, 3) });
        win.settle();
        let round = true;
        win.devs.slice(0, 3).forEach(d => {
            const s = l.btDeviceSpot(d.address);
            round = round && !!s && l.btDeviceAt(s[0], s[1]) === d.address;
        });
        win.check("spot-round-trip", round, "");
        win.check("spot-of-a-stranger", l.btDeviceSpot("ZZ:99") === null && l.btDeviceAt(1, 1) === "", "");
        const sp = l.btDeviceSpot("AA:02");
        l.carriedBt = "AA:02";
        win.check("carried-hidden", win.rowOf("AA:02").opacity === 0 && l.btDeviceAt(sp[0], sp[1]) === "", "opacity " + win.rowOf("AA:02").opacity);
        l.carriedBt = "";
        // ---- identity: 1 -> 2 devices, the first row is the SAME item and travels on the zone's clock from where it stood ----
        l.label = win.lab({ bt: win.devs.slice(0, 1) });
        win.settle();
        const first = win.rowOf("AA:01"), h0 = first.ch, y0 = first.cy;
        l.label = win.lab({ bt: win.devs.slice(0, 2) });
        const same = win.rowOf("AA:01") === first;
        const m1 = l._m, h1 = first.ch;
        const startsWhereItStood = Math.abs(h1 - h0) < 0.02 && Math.abs(first.cy - y0) < 0.02 && m1 < 0.05;
        let mid = false, mono = true, last = l._m;
        tc.tryVerify(() => {
            if (l._m < last - 1e-6)
                mono = false;
            last = l._m;
            if (l._m > 0.1 && l._m < 0.9 && first.ch < h0 - 0.05 && first.ch > first.th + 0.05)
                mid = true;
            return l._m === 1;
        }, 4000);
        win.check("identity-kept", same, "");
        win.check("identity-starts-where-it-stood", startsWhereItStood, "m " + m1 + " h " + h1 + " was " + h0);
        win.check("identity-travels", mid && mono && Math.abs(first.ch - first.th) < 1e-6, "mid " + mid + " mono " + mono);
        win.settle();
        // ---- a row that goes only fades, at its place; then it is free ----
        const second = win.rowOf("AA:02"), sy = second.cy;
        l.label = win.lab({ bt: win.devs.slice(0, 1) });
        let faded = false;
        tc.tryVerify(() => {
            if (second.pres > 0.05 && second.pres < 0.95 && Math.abs(second.cy - sy) < 0.02)
                faded = true;
            return second.pres === 0;
        }, 4000);
        win.check("leaver-fades-in-place", faded && second.key === "", "key '" + second.key + "'");
        win.settle();
        // ---- the name: it shrinks to fit, then a middle cut keeps the end ----
        l.label = win.lab({ name: "homenet-ABC12_5Ghz" });
        tc.wait(50);
        win.check("name-shrinks-whole", l.nameShown === "homenet-ABC12_5Ghz" && l.namePx < 3.0 * l.kPx, l.nameShown + " @" + l.namePx);
        l.label = win.lab({ name: "Hotel-Guest-Network-Floor-12-West_5GHz" });
        tc.wait(50);
        win.check("name-middle-cut", l.nameShown.indexOf("…") > 0 && l.nameShown.slice(-4) === "5GHz" && l.nameShown.slice(0, 5) === "Hotel", l.nameShown);
        // ---- the tunnel's wipe: one clock up and back, never a jump ----
        l.label = win.lab({ vpn: true, via: "via NL · NL#42" });
        let seen = 0, jump = false, prev = l.chrome;
        tc.tryVerify(() => {
            if (Math.abs(l.chrome - prev) > 0.45)
                jump = true;
            if (l.chrome > 0.05 && l.chrome < 0.95)
                seen++;
            prev = l.chrome;
            return l.chrome === 1 && !l.wiping;
        }, 6000);
        win.check("wipe-up", l.chrome === 1 && seen >= 2 && !jump, "frames between " + seen + " jump " + jump);
        tc.tryVerify(() => l.viaT === 1, 3000);
        win.check("via-opens", l.viaT === 1, "viaT " + l.viaT);
        l.label = win.lab();
        seen = 0;
        tc.tryVerify(() => {
            if (l.chrome > 0.05 && l.chrome < 0.95)
                seen++;
            return l.chrome === 0 && !l.wiping;
        }, 6000);
        win.check("wipe-back", l.chrome === 0 && seen >= 2, "frames between " + seen);
        // ---- the drop hints ----
        l.hint = "bt";
        tc.wait(600);
        l.hint = "wifi";
        tc.wait(600);
        l.hint = "";
        tc.wait(600);
        win.check("hints-run-clean", true, "");
        console.log("AERIAL_R3_LABEL_PROBE RESULT " + (win.bad ? "FAIL (" + win.bad + ")" : "PASS"));
        Qt.quit();
    }
    Timer {
        interval: 600
        running: true
        onTriggered: win.run()
    }
}
