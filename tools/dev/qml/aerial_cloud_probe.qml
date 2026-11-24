pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/aerial/data"
import "modules/aerial/popup"
import "modules/common/glyphs"
import "modules/common/theme"
import "modules/aerial/scene/AerialCamera.js" as Cam
import "modules/aerial/scene/CloudPlace.js" as CP

// =============================================================================
// tools/dev/qml/aerial_cloud_probe.qml (round 3: the old aerial_holo_probe.qml, re-aimed at the signal fan) -- the CLOUD's interactions on the real popup
// (tools/dev/aerial_holo_probe.sh runs it and arms it; the placer's own cases are `node tools/dev/aerial_holo_cases.js`). One process, a sequence of steps; every check prints
// `AH <name> PASS|FAIL <why>`, then `AH RESULT PASS|FAIL`:
//   place    what the cloud draws is stable across opens, a scan with a leaver moves nobody, the named tags overlap nothing, every network is a name or a dot, saved ones keep their
//            names, the cloud's clock is the scene's beat and no board uniform moves with it; the three band hues are distinct (every theme: bar_hues_table.sh, run by the runner)
//   rest     a tag opens only after the pointer has RESTED on it (`restMs`), a pass over the cloud opens nothing, a hover acts after a motion
//   drag     a click is not a drag; a network dragged onto the label's Wi-Fi zone connects (the label's `hint` says "wifi" while it is carried and "" after), a secured stranger HOVERS held
//            and the panel is asked, a tag let go on nothing STAYS where it was dropped until the popup closes, the docked network pulled off disconnects, the hotspot starts / stops
//   bt       connected devices are on the label and not in the air, the others stand on the near field; a paired device dragged onto the label connects, a stranger pairs
//            (`hint` "bt"), a CONNECTED device's row pulled off the label disconnects (`btDeviceAt`; `carriedBt` is set while it is in the hand)
//   globe    a click on a country's light connects there and opens NO panel, a click on the connected country's light / the sphere / the lens opens the VPN panel; a light dragged onto
//            the label connects, the tunnel's country pulled off disconnects; 149 lights stay pickable; the globe's rest size and place, its growth, its swipes (rotate / tilt), its picks
//   float    every tag sways on the cloud's one clock (the harness `float` state reads it the same way); the frame rate alive; halted = 0 frames
// Every pointer event is a synthetic mouse on the WINDOW (QtTest), in two steps for a hover.
//
// What went (round 3): the dome's / rings' checks (`popup.dome`, `popup.rings`, `glowZone`, `glowRings`, `HoloPlace.js`: the ring-to-ring device moves, the device figures' clearance
// of silk and parts, the hotspot's reserved spot on the dome) -- the dome and the rings are gone; the placer's own rules (no overlap, labels vs dots, the budget, the seed, the
// sticky places) are `aerial_holo_cases.js`, and the near field / the label's Bluetooth zone replace the rings (the `bt` group).
// =============================================================================
Window {
    id: win

    readonly property string out: Quickshell.env("OUT") || "/tmp/aerial_cloud_probe"
    width: 760
    height: 700
    visible: true
    color: "#E9ECF3"

    property var fails: []
    property int swaps: 0
    property var _forms0: ({})
    property var sent: []
    property var acts: []
    function check(name: string, ok: bool, why: string): void {
        console.log("AH " + name + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : ""));
        if (!ok)
            win.fails.push(name);
    }
    Connections {
        target: win
        function onFrameSwapped() { win.swaps++; }
    }
    AerialMock {
        id: mock
        live: true                          // the mock's own pump (it never touches the machine): a settle lands
        scenario: "crowd"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 300
    }
    Loader {
        id: ld
        active: true
        sourceComponent: AerialPopup {
            service: mock
            family: 0
            renderScale: 1
            animate: false
            power: 1
            entranceEnabled: false
            soundsEnabled: false
        }
    }
    readonly property var popup: ld.item
    readonly property var ctl: ld.item ? ld.item.drag : null
    TestCase {
        id: tc
        name: "cloud"
        when: false
        windowShown: true
    }
    Connections {
        target: win.ctl
        function onIntent(name, args) { win.sent.push(name + "(" + JSON.stringify(args) + ")"); }
        function onActivated(intent, at) { win.acts.push(intent); }
    }

    // ---- helpers ----
    function tags(layer: var): var {
        const out = [];
        for (let i = 0; i < layer.tags.count; i++) {
            const t = layer.tags.itemAt(i);
            if (t && t.visible && t.presence > 0.9)
                out.push(t);
        }
        return out;
    }
    function centre(t: var): var {
        return { x: t.x + t.hitRect.x + t.hitRect.width / 2, y: t.y + t.hitRect.y + t.hitRect.height / 2 };
    }
    function netByKey(key: string): var {
        return mock.wifi.networks.find(n => n.key === key);
    }
    // a network's tag whose centre no other tag covers
    function pickTag(pred: var, dotsToo: bool): var {
        const ts = win.tags(win.popup.cloud).filter(t => t.e.kind === "net" && (dotsToo || t.e.form === "named") && pred(t.e));
        return ts.find(t => { const c = win.centre(t); return win.tags(win.popup.cloud).every(o => o === t || !(c.x >= o.x + o.hitRect.x && c.x <= o.x + o.hitRect.x + o.hitRect.width && c.y >= o.y + o.hitRect.y && c.y <= o.y + o.hitRect.y + o.hitRect.height && o.z > t.z)); }) || null;
    }
    function formsOf(layer: var): var {
        const m = {};
        for (const t of win.tags(layer))
            if (t.e.kind === "net")
                m[t.key] = t.e.form;
        return m;
    }
    function checkBudget(tag: string): void {
        const ts = win.tags(win.popup.cloud).filter(t => t.e.kind === "net");
        const named = ts.filter(t => t.e.form === "named");
        const r = t => Qt.rect(t.x, t.y, t.width, t.height);          // the plates' own boxes (the hit rect is padded by 3 px: two plates one gap apart overlap there)
        const hit = [];
        for (let i = 0; i < named.length; i++)
            for (let j = i + 1; j < named.length; j++) {
                const a = r(named[i]), b = r(named[j]);
                if (Math.min(a.x + a.width, b.x + b.width) > Math.max(a.x, b.x) && Math.min(a.y + a.height, b.y + b.height) > Math.max(a.y, b.y))
                    hit.push(named[i].e.ssid + "/" + named[j].e.ssid);
            }
        win.check("crowd-named-tags-do-not-overlap-" + tag, hit.length === 0 && named.length >= 6, named.length + " named tags, overlapping: " + hit.slice(0, 4).join(", "));
        const shown = mock.wifi.networks.filter(n => !n.connected && !n.ownHotspot && n.key !== (mock.wifi.active ? mock.wifi.active.key : ""));
        const lost = shown.filter(n => !ts.some(t => t.key === n.key));
        win.check("every-network-named-or-dot-" + tag, lost.length === 0 && ts.length === shown.length, shown.length + " networks, " + ts.length + " drawn, lost: " + lost.map(n => n.key).join(" "));
        const savedLost = shown.filter(n => n.known && ts.some(t => t.key === n.key && t.e.form === "dot"));
        const savedN = shown.filter(n => n.known).length;
        win.check("named-count-covers-saved-" + tag, savedLost.length === 0 && named.length >= savedN, named.length + " named for " + savedN + " saved");
    }
    function zone(): var {
        return win.popup._zoneCentre;
    }
    function press(x: real, y: real): void {
        tc.mouseMove(win.contentItem, x - 6, y - 4);
        tc.mouseMove(win.contentItem, x, y);
        tc.mousePress(win.contentItem, x, y, Qt.LeftButton);
    }
    function dragTo(x0: real, y0: real, x1: real, y1: real, steps: int, release: bool): void {
        win.press(x0, y0);
        for (let i = 1; i <= steps; i++) {
            tc.mouseMove(win.contentItem, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
            tc.wait(18);
        }
        if (release)
            tc.mouseRelease(win.contentItem, x1, y1, Qt.LeftButton);
    }
    function lastSent(): string {
        return win.sent.length ? win.sent[win.sent.length - 1] : "";
    }
    function resetLog(): void {
        win.sent = [];
        win.acts = [];
    }
    function qOf(layer: var): var {
        const m = {};
        for (let i = 0; i < layer.tags.count; i++) {
            const t = layer.tags.itemAt(i);
            if (t && t.e)
                m[t.key] = [t.e.x, t.e.y];
        }
        return m;
    }
    function maxMove(a: var, b: var, skip: string): real {
        let d = 0;
        for (const k in a)
            if (b[k] && k !== skip)
                d = Math.max(d, Math.hypot(a[k][0] - b[k][0], a[k][1] - b[k][1]));
        return d;
    }
    // the tags that moved more than a pixel, with where they went (a failure's own evidence)
    function movers(a: var, b: var, skip: string): string {
        const out = [];
        for (const k in a)
            if (b[k] && k !== skip && Math.hypot(a[k][0] - b[k][0], a[k][1] - b[k][1]) > 1)
                out.push(k + " " + a[k].map(Math.round) + "->" + b[k].map(Math.round));
        return out.join("; ");
    }
    function boardSnap(): string {
        const b = win.popup.scene.boardLayer;
        return JSON.stringify([b.motion, b.parts, b.hole, b.view, b.frame, b.light, b.palA, b.palK, b.quad]);
    }
    function hull(pts: var): var {
        const P = pts.slice().sort((a, b) => a.x - b.x || a.y - b.y), cr = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
        const lo = [], up = [];
        P.forEach(p => { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); });
        P.slice().reverse().forEach(p => { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); });
        return lo.slice(0, -1).concat(up.slice(0, -1));
    }
    // a connected device's row on the label, in item px
    function rowPx(addr: string): var {
        const sp = win.popup.scene.labelItem.btDeviceSpot(addr);
        return sp ? CP.labelPx(win.popup.scene.geo, win.popup.scene.labelMap, sp[0], sp[1]) : null;
    }

    // ---- the docking flight under a service that keeps publishing (round 5): a real connection coming up is a run of publications, and a flight restarted by each
    // one shrank and snapped back to full size again and again. While a flight runs the probe bumps the mock's serial (the mock itself publishes once or twice); a
    // flight that goes BACKWARDS mid-way was restarted.
    property int flightRestarts: 0
    property int flightBumps: 0
    property real _lastFlight: 1
    Connections {
        target: win.ctl
        ignoreUnknownSignals: true
        function on_FlightChanged() {
            const f = win.ctl._flight;
            if (f < win._lastFlight - 0.001 && win._lastFlight < 0.999)
                win.flightRestarts++;
            win._lastFlight = f;
        }
    }
    Timer {
        interval: 25
        repeat: true
        running: !!win.ctl && win.ctl.phase === "docking"
        onTriggered: {
            win.flightBumps++;
            mock.serial = mock.serial + 1;
        }
    }

    // the phase at which a scan's (stronger) front turned on
    property var boostAt: []
    Connections {
        target: win.popup ? win.popup.cloud : null
        ignoreUnknownSignals: true
        function onBoostChanged() {
            if (win.popup.cloud.boost)
                win.boostAt.push(win.popup.cloud.phase);
        }
        function onFrontLeft(scan: bool) {
            if (scan && win.boostAt.indexOf(win.popup.cloud.phase) < 0)
                win.boostAt.push(win.popup.cloud.phase);
        }
    }

    // ---- the steps ----
    property int _step: 0
    property var _steps: []
    property var _q0: ({})
    property string _snap: ""
    property string _key: ""
    property int _swapsAt: 0
    property real _tAt: 0
    Timer {
        id: tick
        interval: 400
        repeat: true
        running: true
        onTriggered: {
            if (win._step >= win._steps.length) {
                tick.stop();
                console.log("AH RESULT " + (win.fails.length ? "FAIL (" + win.fails.join(", ") + ")" : "PASS"));
                Qt.quit();
                return;
            }
            tick.stop();                                   // a QtTest wait runs the event loop: never re-enter a step
            const fn = win._steps[win._step++];
            try {
                fn();
            } catch (e) {
                win.check("step-" + win._step, false, "threw " + e);
            }
            tick.start();
        }
    }

    Component.onCompleted: {
        const S = [];
        S.push(() => {});
        S.push(() => {
            mock.hotspot = Object.assign({}, mock.hotspot, { available: true, missing: "" });
            mock.serial = mock.serial + 1;
        });
        // ---- placement: a second open, a scan with a leaver ----
        S.push(() => {
            win._q0 = win.qOf(win.popup.cloud);
            win.check("cloud-has-networks", Object.keys(win._q0).length >= 10, "tags=" + Object.keys(win._q0).length);
            // labels vs dots: a name only where the rule allows one (the rule is the CEILING; the room the floor: a saved network in range keeps its name)
            const bad = [];
            win.tags(win.popup.cloud).forEach(t => {
                const n = win.netByKey(t.key);
                if (!n || t.e.kind !== "net")
                    return;
                const want = CP.formOf ? CP.formOf(n) : ((n.hidden && !n.ssid) ? "dot" : n.known ? "named" : n.signalBand <= 1 ? "named" : "dot");
                if (t.e.form === "named" && want !== "named")
                    bad.push(t.key);
                if (n.known && want === "named" && t.e.form !== "named")
                    bad.push("lostsaved:" + t.key);
            });
            win.check("labels-vs-dots", bad.length === 0, bad.join(" "));
            win.check("hidden-nameless-dots", win.tags(win.popup.cloud).filter(t => t.e.hidden).every(t => t.e.form === "dot" && t.e.ssid === ""), "");
            ld.active = false;
        });
        S.push(() => { ld.active = true; });
        S.push(() => {});
        S.push(() => {
            const q1 = win.qOf(win.popup.cloud);
            const d = win.maxMove(win._q0, q1, "");
            win.check("placement-stable-across-opens", Object.keys(q1).length === Object.keys(win._q0).length && d < 1, "max move " + d.toFixed(2) + " px over " + Object.keys(q1).length);
            win._q0 = q1;
            const victim = Object.keys(q1).find(k => win.netByKey(k) && win.netByKey(k).signalBand <= 1) || Object.keys(q1)[3];
            win._key = victim;
            mock.wifi = Object.assign({}, mock.wifi, { networks: mock.wifi.networks.filter(n => n.key !== victim) });
            mock.serial = mock.serial + 1;
        });
        S.push(() => {});
        S.push(() => {
            const q = win.qOf(win.popup.cloud);
            const d = win.maxMove(win._q0, q, win._key);
            const gone = win.popup.cloud.placed.entries[win._key];
            // a leaver fades where it stood; what is not a Wi-Fi arc (the near field, the hotspot's spot) is not re-spaced by it (an arc whose names changed IS: the placer's spread --
            // `aerial_holo_cases.js` "arrival-moves-few" holds the arcs to it)
            const other = Object.keys(win._q0).filter(k => k !== win._key && q[k] && win.popup.cloud.placed.entries[k].kind !== "net" && Math.hypot(win._q0[k][0] - q[k][0], win._q0[k][1] - q[k][1]) > 1);
            win.check("scan-leaver-fades-in-place", !!gone ? (gone.gone === true && Math.hypot(win._q0[win._key][0] - gone.x, win._q0[win._key][1] - gone.y) < 0.01) : true, "leaver gone=" + (gone ? gone.gone : "pruned"));
            win.check("scan-leaver-leaves-the-near-field-and-hotspot-alone", other.length === 0 && Object.keys(win._q0).some(k => win.popup.cloud.placed.entries[k].kind !== "net"), "moved " + other + " of the non-network tags " + Object.keys(win._q0).filter(k => win.popup.cloud.placed.entries[k].kind !== "net"));
            console.log("AH info scan-leaver: " + d.toFixed(0) + " px at most on the leaver's arcs; moved: " + win.movers(win._q0, q, win._key).slice(0, 200));
            mock.scenario = "crowd";
        });
        // ---- the cloud is never in the cached board; its clock is the scene's beat ----
        S.push(() => { win._snap = win.boardSnap(); win._tAt = win.popup.scene.time; popup_run(true); });
        S.push(() => {});
        S.push(() => {
            win.check("holo-not-in-cached-layer", win.boardSnap() === win._snap && win.popup.scene.time > win._tAt, "uniforms moved or the scene's beat did not run (t " + win._tAt + " -> " + win.popup.scene.time + ")");
            win.check("cloud-clock-is-the-scenes-beat", Math.abs(win.popup.cloud.time - win.popup.scene.time) < 1e-9, "cloud " + win.popup.cloud.time + " scene " + win.popup.scene.time);
        });
        // ---- THE LABEL BUDGET: the crowd's named tags never overlap (two scans), every network is a tag or a dot, saved ones keep their names ----
        S.push(() => {});
        S.push(() => {
            win._forms0 = win.formsOf(win.popup.cloud);
            win.checkBudget("a");
            mock.wifi = Object.assign({}, mock.wifi, { networks: mock.wifi.networks.map(n => Object.assign({}, n, { signal: Math.max(1, n.signal - 1) })) });
            mock.serial = mock.serial + 1;
        });
        S.push(() => {});
        S.push(() => {
            win.checkBudget("b");
            const f1 = win.formsOf(win.popup.cloud);
            const flips = Object.keys(win._forms0).filter(k => f1[k] !== win._forms0[k]);
            win.check("forms-stable-across-scans", Object.keys(f1).length === Object.keys(win._forms0).length && flips.length === 0, flips.join(" "));
        });
        // ---- hue roles ----
        S.push(() => {
            const cs = [BarHues.aerialBand24, BarHues.aerialBand5, BarHues.aerialBand6], bad = [];
            const dist = (a, b) => Math.hypot(a.r - b.r, a.g - b.g, a.b - b.b);
            for (let i = 0; i < 3; i++) {
                for (let j = i + 1; j < 3; j++)
                    if (dist(cs[i], cs[j]) < 0.08)
                        bad.push("band" + i + "=" + j);
                [Theme.textMuted, Theme.warn, Theme.error, BarHues.btOn].forEach((c, k) => { if (dist(cs[i], c) < 0.05) bad.push("band" + i + "~reserved" + k); });
            }
            win.check("hue-roles-distinct", bad.length === 0, bad.join(" "));
        });
        // ---- a tag opens only after the pointer RESTS on it ----
        S.push(() => {
            mock.scenario = "crowd";
            win.resetLog();
            tc.mouseMove(win.contentItem, 3, 3);
        });
        S.push(() => {
            const ts = win.tags(win.popup.cloud).filter(t => t.e.kind === "net" && t.e.form === "named");
            const t = win.pickTag(e => true);
            const c = win.centre(t);
            tc.mouseMove(win.contentItem, 3, 3);
            tc.wait(30);
            win.check("no-hover-before-motion", win.ctl.hoverKey === "", "hover=" + win.ctl.hoverKey);
            tc.mouseMove(win.contentItem, c.x - 5, c.y - 3);
            tc.mouseMove(win.contentItem, c.x, c.y);
            win.check("tag-does-not-open-at-once", win.ctl.hoverKey === "" && win.ctl._restKey === t.key && !t.hovered, "hover=" + win.ctl.hoverKey + " rest=" + win.ctl._restKey);
            tc.wait(win.ctl.restMs * 4);
            win.check("tag-opens-after-the-pointer-rests", win.ctl.hoverKey === t.key && t.hovered, "hover=" + win.ctl.hoverKey + " want " + t.key);
            // a pass over the cloud flickers nothing: the pointer crosses every named tag at speed
            tc.mouseMove(win.contentItem, 3, 3);
            tc.wait(win.ctl.restMs * 3);
            let seen = 0, passed = 0;
            for (const o of ts.slice(0, 6)) {
                const q = win.centre(o);
                tc.mouseMove(win.contentItem, q.x - 3, q.y);
                tc.mouseMove(win.contentItem, q.x, q.y);
                if (win.ctl.hoverKey !== "")
                    seen++;
                tc.wait(6);
                if (win.ctl.hoverKey !== "")
                    seen++;
                passed++;
            }
            win.check("a-pass-over-the-cloud-opens-nothing", passed >= 4 && seen === 0, "crossed " + passed + " tags, " + seen + " opened");
            tc.mouseMove(win.contentItem, 3, 3);
            tc.wait(60);
            win.check("pointer-leaves-closes-the-tag", win.ctl.hoverKey === "", "hover=" + win.ctl.hoverKey);
        });
        // ---- drag: a click is not a drag ----
        S.push(() => {
            mock.scenario = "crowd";
            win.resetLog();
        });
        S.push(() => {
            const t = win.pickTag(e => !e.secured && !e.known && !e.hidden, true);
            if (!t) { win.check("have-open-stranger", false, "none"); return; }
            win._key = t.key;
            const c = win.centre(t);
            win.press(c.x, c.y);
            tc.mouseMove(win.contentItem, c.x + 2, c.y + 1);        // a real click jitters a pixel or two
            tc.mouseRelease(win.contentItem, c.x + 2, c.y + 1, Qt.LeftButton);
            tc.wait(60);
            win.check("click-is-not-a-drag", win.sent.length === 0 && win.acts.indexOf("net:" + t.key) >= 0 && win.ctl.phase === "idle", "sent=" + win.sent + " acts=" + win.acts + " phase=" + win.ctl.phase);
            win.popup.closeSecondary();
        });
        // ---- a network dragged onto the label's Wi-Fi zone connects ----
        S.push(() => {
            win.resetLog();
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            if (!t) { win.check("open-stranger-still-there", false, win._key); return; }
            const lab = win.popup.scene.labelItem;
            win.check("hint-empty-at-rest", win.ctl.hint === "" && lab.hint === "" && lab.carriedBt === "", "ctl " + win.ctl.hint + " label " + lab.hint);
            const c = win.centre(t), z = win.zone();
            win.press(c.x, c.y);
            tc.mouseMove(win.contentItem, c.x + 14, c.y + 14);
            tc.wait(50);
            tc.mouseMove(win.contentItem, (c.x + z[0]) / 2, (c.y + z[1]) / 2);
            tc.wait(50);
            win.check("carried-hides-its-place", win.ctl.carriedKey === win._key && win.ctl.dragging && win.popup.cloud.tagOf(win._key) === null, "carried=" + win.ctl.carriedKey);
            win.check("label-hint-is-wifi-while-a-network-is-carried", win.ctl.hint === "wifi" && lab.hint === "wifi" && lab.carriedBt === "", "ctl " + win.ctl.hint + " label " + lab.hint + " carriedBt " + lab.carriedBt);
            tc.mouseMove(win.contentItem, z[0], z[1]);
            tc.wait(60);
            win.check("zone-lit-when-over", win.ctl.inZone === true, "");
            tc.mouseRelease(win.contentItem, z[0], z[1], Qt.LeftButton);
            tc.wait(30);
            win.check("drop-open-connects", win.lastSent() === "connect(" + JSON.stringify([win._key, {}]) + ")", "sent=" + win.sent);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const a = mock.wifi.active, lab = win.popup.scene.labelItem;
            win.check("connected-and-docked", !!a && a.key === win._key && win.ctl.phase === "idle" && win.ctl.carriedKey === "", "active=" + (a ? a.key : "none") + " phase=" + win.ctl.phase);
            win.check("connected-not-in-the-air", win.tags(win.popup.cloud).every(t => t.key !== win._key), win.tags(win.popup.cloud).filter(t => t.key === win._key).map(t => "presence=" + t.presence + " gone=" + t.e.gone).join(";"));
            win.check("label-hint-clears-after-the-drop", win.ctl.hint === "" && lab.hint === "", "ctl " + win.ctl.hint + " label " + lab.hint);
            win.check("one-flight-under-republication", win.flightBumps >= 3 && win.flightRestarts === 0, win.flightRestarts + " restart(s) of the flight over " + win.flightBumps + " publications");
        });
        // ---- pull the docked one off the label: disconnect ----
        S.push(() => {
            win.resetLog();
            const z = win.zone();
            win.dragTo(z[0], z[1], z[0] - 40, z[1] - 140, 8, true);
            tc.wait(40);
            win.check("pull-docked-disconnects", win.lastSent() === "disconnect([])", "sent=" + win.sent);
        });
        S.push(() => {});
        S.push(() => {
            win.check("disconnected", !mock.wifi.active, "");
            win.check("lifted-network-back-in-the-air", win.tags(win.popup.cloud).some(t => t.key === win._key) || win.popup.cloud.placed.entries[win._key] !== undefined, "");
        });
        // ---- a drop whose attempt FAILS at once (the helper refuses it): it shakes, then drifts back to the air -- it never hovers over the label for ever ----
        S.push(() => {
            win.resetLog();
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            if (!t) { win.check("lifted-network-is-a-tag-again", false, win._key); return; }
            mock.failNext = "connect";
            const c = win.centre(t), z = win.zone();
            win.dragTo(c.x, c.y, z[0], z[1], 6, true);
            tc.wait(30);
            win.check("failed-drop-was-asked", win.lastSent() === "connect(" + JSON.stringify([win._key, {}]) + ")", "sent=" + win.sent);
        });
        // (the mock's knob refuses without a word in the facts: the controller waits its 1.5 s for one, then lets go)
        for (let i = 0; i < 6; i++)
            S.push(() => {});
        S.push(() => {
            const t = win.popup.cloud.tagOf(win._key);
            win.check("failed-drop-drifts-back", win.ctl.phase === "idle" && win.ctl.heldKey === "" && win.ctl.carriedKey === "" && !!t && !mock.wifi.active, "phase=" + win.ctl.phase + " held=" + win.ctl.heldKey + " carried=" + win.ctl.carriedKey + " tag=" + !!t);
        });
        // ---- let go on nothing: the network STAYS where it was dropped until the popup closes; the next open places it by the seed again ----
        S.push(() => {
            win.resetLog();
            const t = win.pickTag(e => e.secured && !e.known && !e.hidden);
            if (!t) { win.check("have-secured-stranger", false, "none"); return; }
            win._key = t.key;
            const c = win.centre(t), home = [t.hx, t.hy];
            win._q0 = { home: home, drop: [60, 420] };
            win.dragTo(c.x, c.y, 60, 420, 6, true);
            tc.wait(40);
            win.check("released-elsewhere-no-intent", win.sent.length === 0, "sent=" + win.sent);
        });
        S.push(() => {});
        S.push(() => {
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            const at = t ? win.centre(t) : { x: 1e9, y: 1e9 };
            const away = t ? Math.hypot(t.hx - win._q0.home[0], t.hy - win._q0.home[1]) : 0;
            win.check("dropped-elsewhere-stays", win.ctl.carriedKey === "" && win.ctl.phase === "idle" && !!t && t.visible && away > 100 && Math.abs(at.x - 60) < 80 && Math.abs(at.y - 420) < 24, "phase=" + win.ctl.phase + " carried=" + win.ctl.carriedKey + " away=" + away.toFixed(0) + " at " + at.x.toFixed(0) + "," + at.y.toFixed(0));
            win._q0.stayAt = t ? [t.hx, t.hy] : [0, 0];
        });
        S.push(() => {});
        S.push(() => {
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            win.check("dropped-stays-put", !!t && Math.hypot(t.hx - win._q0.stayAt[0], t.hy - win._q0.stayAt[1]) < 0.5, "moved");
            // it still drags from where it stands
            const c = win.centre(t);
            win.press(c.x, c.y);
            tc.mouseMove(win.contentItem, c.x + 20, c.y + 10);
            tc.wait(30);
            win.check("dropped-one-drags-again", win.ctl.dragging && win.ctl.carriedKey === win._key, "carried=" + win.ctl.carriedKey);
            tc.mouseRelease(win.contentItem, c.x + 20, c.y + 10, Qt.LeftButton);
            tc.wait(30);
            win.popup.open = false;
        });
        S.push(() => {});
        S.push(() => { win.popup.open = true; });
        S.push(() => {});
        S.push(() => {
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            const e = win.popup.cloud.placed.entries[win._key];
            const d = t && e ? Math.hypot(t.hx - e.x, t.hy - e.y) : 1e9;
            win.check("next-open-places-by-seed", !!t && d < 1 && win.popup.cloud.offsetOf(win._key)[0] === 0, "d=" + d.toFixed(1));
        });
        // ---- a secured stranger dropped on the label: it hovers held and the panel is asked ----
        S.push(() => {
            win.resetLog();
            const t = win.tags(win.popup.cloud).find(x => x.key === win._key);
            const c = win.centre(t), z = win.zone();
            win.dragTo(c.x, c.y, z[0], z[1], 8, true);
            tc.wait(60);
            win.check("secured-drop-asks-the-panel", win.acts.indexOf("net:" + win._key) >= 0 && win.sent.length === 0, "acts=" + win.acts + " sent=" + win.sent);
            win.check("secured-drop-hovers-held", win.ctl.phase === "held" && win.ctl.heldKey === win._key, "phase=" + win.ctl.phase);
            win.check("label-hint-stays-wifi-while-held", win.ctl.hint === "wifi" && win.popup.scene.labelItem.hint === "wifi", "ctl " + win.ctl.hint);
        });
        S.push(() => {
            const z = win.zone();
            win.check("held-hovers-over-the-label", Math.hypot(win.ctl.carryX - z[0], win.ctl.carryY - (z[1] - 6)) < 8, "at " + win.ctl.carryX.toFixed(1) + "," + win.ctl.carryY.toFixed(1) + " zone " + z);
            win.ctl.giveUp(win._key);
        });
        S.push(() => {});
        S.push(() => {
            win.check("given-up-drifts-back", win.ctl.phase === "idle" && win.ctl.carriedKey === "" && win.ctl.heldKey === "" && win.ctl.hint === "", "phase=" + win.ctl.phase);
            win.popup.closeSecondary();
        });
        // ---- the lag: never more than a few px behind the hand ----
        S.push(() => {
            const t = win.pickTag(e => true);
            const c = win.centre(t);
            win.press(c.x, c.y);
            let worst = 0;
            let px = c.x, py = c.y;
            for (let i = 0; i < 16; i++) {
                px += 18;
                py += (i % 2 ? 9 : -4);
                tc.mouseMove(win.contentItem, px, py);
                tc.wait(17);
                const lag = Math.hypot(win.ctl.carryX - (win.ctl._tx), win.ctl.carryY - (win.ctl._ty));
                if (i > 1)
                    worst = Math.max(worst, lag);
            }
            win.check("carry-lag-bounded", worst <= win.ctl.maxLag + 0.5 && win.ctl.dragging, "worst lag " + worst.toFixed(1) + " px (max " + win.ctl.maxLag + ")");
            tc.mouseRelease(win.contentItem, px, py, Qt.LeftButton);
        });
        S.push(() => {});
        S.push(() => {});
        // ---- the hotspot's tag: dragged on starts it, pulled off stops it ----
        // round 6: the hotspot's tag shows only when it can really start -- the card shares what a CABLE brings in
        S.push(() => { mock.hotspot = Object.assign({}, mock.hotspot, { available: true, missing: "", uplink: "none" }); mock.serial = mock.serial + 1; });
        S.push(() => {
            win.check("hotspot-tag-hidden-without-a-cable", !win.popup.cloud.targets().some(x => x.kind === "hotspot"), "uplink=" + mock.hotspot.uplink);
            mock.hotspot = Object.assign({}, mock.hotspot, { uplink: "cable" });
            mock.serial = mock.serial + 1;
        });
        S.push(() => {
            win.resetLog();
            const h = win.popup.cloud.targets().find(x => x.kind === "hotspot");
            if (!h) { win.check("hotspot-tag-shown", false, "available=" + mock.hotspot.available); return; }
            win.check("hotspot-tag-shown", true, "");
            const c = { x: h.rect.x + h.rect.width / 2, y: h.rect.y + h.rect.height / 2 }, z = win.zone();
            win.dragTo(c.x, c.y, z[0], z[1], 8, true);
            tc.wait(40);
            win.check("drag-hotspot-starts-it", win.lastSent() === "startHotspot([])", "sent=" + win.sent);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            win.check("hotspot-up-docks", mock.hotspot.active === true && win.ctl.phase === "idle", "hotspot=" + JSON.stringify(mock.hotspot).slice(0, 160) + " phase=" + win.ctl.phase + " held=" + win.ctl.heldKey);
            win.check("cloud-holds-the-clients", win.popup.cloud.hotspotUp === true, "");
            win.resetLog();
            const z = win.zone();
            win.dragTo(z[0], z[1], z[0] - 30, z[1] - 150, 8, true);
            tc.wait(40);
            win.check("pull-hotspot-stops-it", win.lastSent() === "stopHotspot([])", "sent=" + win.sent);
        });
        S.push(() => {});
        // ---- Bluetooth: the connected are on the label, the others on the near field; the drags ----
        S.push(() => {
            mock.scenario = "earbuds";
            win.resetLog();
        });
        S.push(() => {
            // a stranger heard by a search, in the mock's RAW state (a fact set on `mock.bt` alone is rebuilt away at the next recompute)
            mock._raw.btDevices = mock._raw.btDevices.concat([{ address: "AA:BB:CC:00:00:99", name: "Stranger", deviceName: "Stranger", icon: "audio-speaker", connected: false, paired: false, bonded: false,
                                                               trusted: false, blocked: false, pairing: false, battery: 0, batteryAvailable: false }]);
            mock._raw.btSeen = Object.assign({}, mock._raw.btSeen, { "AA:BB:CC:00:00:99": true });      // (BlueZ remembers a stranger; the model shows it only while it was seen by a search)
            mock._recompute();
        });
        S.push(() => {});
        S.push(() => {
            const C = win.popup.cloud, lab = win.popup.scene.labelItem;
            const bts = win.tags(C).filter(t => t.e.kind === "bt");
            const keys = bts.map(t => t.key).sort();
            win.check("connected-device-is-not-in-the-air", !keys.includes("AA:BB:CC:00:00:01") && win.popup.cloud.placed.entries["AA:BB:CC:00:00:01"] === undefined, "tags " + keys);
            win.check("not-connected-devices-stand-on-the-near-field", ["AA:BB:CC:00:00:02", "AA:BB:CC:00:00:03", "AA:BB:CC:00:00:99"].every(a => keys.includes(a)) && bts.every(t => t.e.arc === "bt"), "tags " + keys + " arcs " + bts.map(t => t.e.arc));
            const near = bts.map(t => Math.hypot(t.hx - C.origin[0], t.hy - C.origin[1]));
            win.check("near-field-is-near", near.every(r => r < C.fan.r[0]), "radii " + near.map(r => r.toFixed(0)) + " < the first Wi-Fi arc " + C.fan.r[0]);
            win.check("connected-device-is-on-the-label", win.rowPx("AA:BB:CC:00:00:01") !== null && lab.btDeviceAt(lab.btDeviceSpot("AA:BB:CC:00:00:01")[0], lab.btDeviceSpot("AA:BB:CC:00:00:01")[1]) === "AA:BB:CC:00:00:01", "row " + win.rowPx("AA:BB:CC:00:00:01"));
        });
        // a connected device's row pulled off the label: btDisconnect (carriedBt set while it is in the hand, the Wi-Fi hint not lit)
        S.push(() => {
            win.resetLog();
            const a = "AA:BB:CC:00:00:01", p = win.rowPx(a), lab = win.popup.scene.labelItem;
            if (!p) { win.check("pull-connected-device-disconnects", false, "no row"); return; }
            win.press(p[0], p[1]);
            tc.mouseMove(win.contentItem, p[0] + 10, p[1] - 20);
            tc.wait(40);
            tc.mouseMove(win.contentItem, p[0] + 20, p[1] - 60);
            tc.wait(60);
            win.check("carried-bt-is-set-while-a-row-is-pulled", win.ctl.dragging && win.ctl.carriedKind === "btdock" && lab.carriedBt === a && win.ctl.hint === "" && lab.hint === "", "kind=" + win.ctl.carriedKind + " carriedBt=" + lab.carriedBt + " hint=" + lab.hint);
            tc.mouseMove(win.contentItem, p[0] + 30, p[1] - 150);
            tc.wait(30);
            tc.mouseRelease(win.contentItem, p[0] + 30, p[1] - 150, Qt.LeftButton);
            tc.wait(30);
            win.check("pull-connected-device-disconnects", win.lastSent() === "btDisconnect(" + JSON.stringify([a]) + ")", "sent=" + win.sent);
            win.check("carried-bt-clears", lab.carriedBt === "" && win.ctl.carriedKey === "", "carriedBt=" + lab.carriedBt);
        });
        S.push(() => {});
        S.push(() => {});
        // a stranger dragged onto the label pairs (hint "bt" while it is carried), a paired device connects
        S.push(() => {
            win.resetLog();
            const lab = win.popup.scene.labelItem, bc = win.popup._btCentre;
            const move = (addr, want) => {
                const t = win.tags(win.popup.cloud).find(x => x.key === addr);
                if (!t) return "notag:" + addr + " tags " + win.tags(win.popup.cloud).map(x => x.key + "/" + x.e.kind).join(",") + " entry " + JSON.stringify(win.popup.cloud.placed.entries[addr] || null).slice(0, 160);
                const c = win.centre(t);
                win.resetLog();
                win.press(c.x, c.y);
                tc.mouseMove(win.contentItem, c.x + 12, c.y + 12);
                tc.wait(40);
                tc.mouseMove(win.contentItem, (c.x + bc[0]) / 2, (c.y + bc[1]) / 2);
                tc.wait(40);
                const hint = win.ctl.hint + "/" + lab.hint + "/" + win.ctl.carriedKind;
                tc.mouseMove(win.contentItem, bc[0], bc[1]);
                tc.wait(40);
                tc.mouseRelease(win.contentItem, bc[0], bc[1], Qt.LeftButton);
                tc.wait(30);
                return win.lastSent() + " hint=" + hint;
            };
            const r1 = move("AA:BB:CC:00:00:99", "btPair");
            win.check("stranger-dropped-on-the-label-pairs", r1.indexOf("btPair([\"AA:BB:CC:00:00:99\"])") === 0 && r1.indexOf("hint=bt/bt/bt") > 0, r1);
            win.ctl.giveUp("AA:BB:CC:00:00:99");
            const r2 = move("AA:BB:CC:00:00:02", "btConnect");
            win.check("paired-dropped-on-the-label-connects", r2.indexOf("btConnect([\"AA:BB:CC:00:00:02\"])") === 0 && r2.indexOf("hint=bt/bt/bt") > 0, r2);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            // let go on the board away from the label: no intent, the device stays where it was dropped
            win.ctl.giveUp("AA:BB:CC:00:00:02");
            win.resetLog();
            const t = win.tags(win.popup.cloud).find(x => x.e.kind === "bt");
            if (!t) { win.check("device-click", false, "no device tag"); return; }
            const c = win.centre(t);
            win.press(c.x, c.y);
            tc.mouseRelease(win.contentItem, c.x, c.y, Qt.LeftButton);
            tc.wait(40);
            win.check("device-click-opens-its-panel", win.acts.indexOf("bt:" + t.key) >= 0 && win.sent.length === 0, "acts=" + win.acts + " sent=" + win.sent);
            win.popup.closeSecondary();
        });
        // ---- the globe's click: a country's light connects there and opens NO panel ----
        S.push(() => {
            mock.scenario = "home";
        });
        S.push(() => {
            mock.scenario = "crowd";
            win.resetLog();
            const cs = [["NL", "Netherlands", 52.1, 5.3], ["CH", "Switzerland", 46.8, 8.2], ["US", "United States", 39.8, -98.6], ["JP", "Japan", 36.2, 138.2], ["BR", "Brazil", -14.2, -51.9]]
                .map(c => ({ code: c[0], name: c[1], lat: c[2], lon: c[3], servers: 6, minLoad: 30, features: 0, cities: [] }));
            mock.catalog = { serial: 1, tier: 2, countries: cs };
            win.popup.globe.spinning = false;
            win.popup.globe.turn = -0.1;
            win.popup.closeSecondary();
            tc.mouseMove(win.contentItem, 3, 3);
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            const code = ["NL", "CH"].find(c => G.lightFront(c));
            if (!code) { win.check("country-click-connects-and-opens-no-panel", false, "no front light"); return; }
            win._key = code;
            // the globe grows under the pointer: let it, then aim at where the light is; a tag over the light is not it (turn the globe a little until the press is the light's own)
            let p = G.lightPos(code);
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.wait(500);
            for (const dt of [0, 0.12, -0.12, 0.25, -0.25]) {
                G.turn = G.turn + dt;
                tc.mouseMove(win.contentItem, 3, 3);
                tc.wait(60);
                p = G.lightPos(code);
                tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
                tc.wait(500);
                p = G.lightPos(code);
                const h = win.ctl._hit(p.x, p.y);
                if (h && h.kind === "country" && h.key === code)
                    break;
            }
            win.resetLog();
            win.press(p.x, p.y);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
            tc.wait(60);
            const st = mock.proton.state;
            win.check("country-click-connects-and-opens-no-panel", win.acts.indexOf("country:" + code) >= 0 && !win.popup.secondaryOpen && win.popup.secondaryKey === null && st !== "off" && st !== "down", "acts=" + win.acts + " panel=" + win.popup.secondaryKey + " open=" + win.popup.secondaryOpen + " proton=" + st + " server=" + JSON.stringify(mock.proton.server));
        });
        S.push(() => {});
        S.push(() => {});
        // ---- the "fastest" light (round 4): it asks for a connect with NO country (it was sent as the country "fastest", which Proton refuses) ----
        S.push(() => {
            mock.vpnDisconnect();
            win.popup.closeSecondary();
            tc.mouseMove(win.contentItem, 3, 3);
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            let p = G.lightPos("fastest");
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.wait(500);
            p = G.lightPos("fastest");
            tc.mouseMove(win.contentItem, p.x, p.y);
            tc.wait(80);
            const h = win.ctl._hit(p.x, p.y), errs = mock.errors.length;
            mock.lastVpnArgs = null;
            win.resetLog();
            win.press(p.x, p.y);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
            tc.wait(60);
            const a = mock.lastVpnArgs;
            // round 6: the asked light pulses at once, while the tunnel comes up
            win.check("asked-light-pulses-at-once", win.popup.globe.pending === "fastest", "pending=" + win.popup.globe.pending);
            win.check("fastest-light-connects-with-no-country", !!h && h.kind === "country" && h.key === "fastest" && !!a && a.country === undefined && mock.errors.length === errs
                && !win.popup.secondaryOpen, "hit=" + JSON.stringify(h ? [h.kind, h.key] : null) + " args=" + JSON.stringify(a) + " errors=" + (mock.errors.length - errs) + " panel=" + win.popup.secondaryKey);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            // THE FASTEST LIGHT IS A TOGGLE (round 5): the tunnel it raised is up now; a second click takes that tunnel down and asks for no other server
            const G = win.popup.globe, was = mock.proton;
            let p = G.lightPos("fastest");
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.wait(200);
            p = G.lightPos("fastest");
            const h = win.ctl._hit(p.x, p.y);
            win._q0 = { state: was.state, fastest: was.fastest, lit: G.fastestLit, kind: h ? h.kind : "", pendBefore: G.pending };
            mock.lastVpnArgs = null;
            win.press(p.x, p.y);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
            tc.wait(60);
            win._q0.pendClick = G.pending;
        });
        S.push(() => {});
        S.push(() => {
            // (the mock takes a tunnel down in the same turn: the pulse of the way down ends at once; the way up was seen pulsing above)
            win.check("asked-light-pulses-until-answered", win._q0.pendBefore === "" && win.popup.globe.pending === "",
                      "before the click '" + win._q0.pendBefore + "', after the answer '" + win.popup.globe.pending + "'");
            win.check("fastest-light-again-takes-the-tunnel-down", win._q0.state === "up" && win._q0.fastest === true && win._q0.lit === true && win._q0.kind === "tunnel"
                && mock.proton.state === "down" && mock.lastVpnArgs === null && !win.popup.secondaryOpen,
                "before: " + JSON.stringify(win._q0) + " after: state=" + mock.proton.state + " asked=" + JSON.stringify(mock.lastVpnArgs) + " panel=" + win.popup.secondaryKey);
        });
        S.push(() => {
            // the country the tunnel runs through: its light opens the VPN panel (no second connect), then the sphere elsewhere and the lens do the same
            const G = win.popup.globe, code = win._key;
            mock.proton = Object.assign({}, mock.proton, { state: "up", server: { name: code + "#1", country: code, city: "", load: 30, protocol: "wireguard", features: [] } });
            mock.serial = mock.serial + 1;
            win.resetLog();
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe, code = win._key;
            let p = G.lightPos(code);
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.wait(500);
            p = G.lightPos(code);
            win.resetLog();
            win.press(p.x, p.y);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
            tc.wait(60);
            win.check("connected-country-light-opens-the-vpn-panel", win.popup.secondaryOpen && String(win.popup.secondaryKey) === "vpn" && win.sent.length === 0, "panel=" + win.popup.secondaryKey + " sent=" + win.sent);
            win.popup.closeSecondary();
        });
        S.push(() => {});
        S.push(() => {
            // the lens (the board's own part under the globe): the same panel
            const L = win.popup.scene.geo.LENS, q = Cam.project([L.x, 2.3, L.z + L.base * 0.6], win.popup.scene.cam);
            win.resetLog();
            tc.mouseMove(win.contentItem, 3, 3);
            tc.wait(60);
            win.press(q.x, q.y);
            tc.mouseRelease(win.contentItem, q.x, q.y, Qt.LeftButton);
            tc.wait(60);
            win.check("lens-click-opens-the-vpn-panel", win.popup.secondaryOpen && String(win.popup.secondaryKey) === "vpn", "panel=" + win.popup.secondaryKey + " acts=" + win.acts + " at " + q.x.toFixed(0) + "," + q.y.toFixed(0));
            win.popup.closeSecondary();
            mock.scenario = "home";
        });
        S.push(() => {});
        // ---- the globe's countries (stream G's layer, the pointer routed by the controller) ----
        S.push(() => {
            mock.scenario = "crowd";
            win.resetLog();
            const cs = [["NL", "Netherlands", 52.1, 5.3], ["CH", "Switzerland", 46.8, 8.2], ["US", "United States", 39.8, -98.6], ["JP", "Japan", 36.2, 138.2], ["BR", "Brazil", -14.2, -51.9]]
                .map(c => ({ code: c[0], name: c[1], lat: c[2], lon: c[3], servers: 6, minLoad: 30, features: 0, cities: [] }));
            mock.catalog = { serial: 1, tier: 2, countries: cs };
            win.popup.globe.spinning = false;
            win.popup.globe.turn = -0.1;
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            const front = ["NL", "CH"].filter(c => G.lightFront(c));
            if (!front.length) { win.check("globe-has-a-front-light", false, "none front"); return; }
            const code = front[0], p = G.lightPos(code), z = win.zone();
            win.check("globe-light-picks-itself", !!G.lightAt(p.x, p.y) && G.lightAt(p.x, p.y).code === code, "code " + code);
            tc.mouseMove(win.contentItem, 3, 3);
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.mouseMove(win.contentItem, p.x, p.y);
            tc.wait(40);
            win.check("globe-hover-names-the-light", G.hoverCode === code, "hover=" + G.hoverCode);
            // the globe GROWS under a resting pointer (R2-H): wait for it, aim at where the light is now
            tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
            tc.wait(500);
            let p2 = G.lightPos(code);
            win.resetLog();
            win.press(p2.x, p2.y);
            tc.mouseMove(win.contentItem, p2.x - 15, p2.y - 15);
            tc.wait(30);
            // a network's dot can stand over the light on this board (dots may sit anywhere): turn the globe a little and press again until the press is the light's own
            for (const dt of [0.12, -0.12, 0.25, -0.25]) {
                if (win.ctl.dragging && win.ctl.carriedKind === "country")
                    break;
                tc.mouseRelease(win.contentItem, p2.x - 15, p2.y - 15, Qt.LeftButton);
                tc.wait(30);
                G.turn = G.turn + dt;
                tc.mouseMove(win.contentItem, 3, 3);
                tc.wait(60);
                tc.mouseMove(win.contentItem, G.lightPos(code).x - 3, G.lightPos(code).y - 2);
                tc.wait(500);
                p2 = G.lightPos(code);
                win.resetLog();
                win.press(p2.x, p2.y);
                tc.mouseMove(win.contentItem, p2.x - 15, p2.y - 15);
                tc.wait(30);
            }
            win.check("globe-carry-hints-the-wifi-zone", win.ctl.dragging && win.ctl.carriedKind === "country" && win.ctl.hint === "wifi" && win.popup.scene.labelItem.hint === "wifi" && G.dragged === code, "kind=" + win.ctl.carriedKind + " dragged=" + G.dragged);
            tc.mouseMove(win.contentItem, z[0], z[1]);
            tc.wait(60);
            tc.mouseRelease(win.contentItem, z[0], z[1], Qt.LeftButton);
            tc.wait(30);
            win.check("drag-country-connects-vpn", win.lastSent() === "vpnConnect(" + JSON.stringify([{ country: code }]) + ")", "sent=" + win.sent);
            win._key = code;
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            // the sphere's click (not a light) is the globe's panel
            const G = win.popup.globe;
            win.resetLog();
            const q = G.project(0, 100);
            let spot = null;
            for (let dx = -30; dx <= 30 && !spot; dx += 6)
                for (let dy = -30; dy <= 30 && !spot; dy += 6) {
                    const x = G.lightPos("NL").x + dx, y = G.lightPos("NL").y + dy;
                    if (G.containsGlobe(x, y) && !G.lightAt(x, y))
                        spot = { x: x, y: y };
                }
            if (!spot) { win.check("globe-click-opens-its-panel", false, "no empty spot"); return; }
            win.press(spot.x, spot.y);
            tc.mouseRelease(win.contentItem, spot.x, spot.y, Qt.LeftButton);
            tc.wait(30);
            win.check("globe-click-opens-its-panel", win.acts.indexOf("globe") >= 0 && win.sent.length === 0 && String(win.popup.secondaryKey) === "vpn" && win.popup.secondaryOpen, "acts=" + win.acts + " panel=" + win.popup.secondaryKey);
            win.popup.closeSecondary();
            // the tunnel's country pulled off the globe: vpnDisconnect
            const p = mock.proton;
            mock.proton = Object.assign({}, p, { state: "up", server: { name: "NL#1", country: win._key, city: "", load: 30, protocol: "wireguard", features: [] } });
            mock.serial = mock.serial + 1;
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            win.resetLog();
            const p = G.lightPos(win._key);
            if (!p || !G.lightFront(win._key)) { win.check("pull-tunnel-disconnects", false, "exit light not front"); return; }
            win.dragTo(p.x, p.y, p.x - 40, p.y - 120, 8, true);
            tc.wait(30);
            win.check("pull-tunnel-disconnects", win.lastSent() === "vpnDisconnect([])", "sent=" + win.sent);
            // released ON the globe it goes back
            win.resetLog();
            win.dragTo(p.x, p.y, p.x + 3, p.y + 3, 6, true);
            tc.wait(30);
            win.check("tunnel-released-on-globe-stays", win.sent.length === 0, "sent=" + win.sent);
        });
        S.push(() => {});
        // 149 lights: how many stay pickable (every front light must answer ITS OWN point)
        S.push(() => {
            const cs = [];
            let h = 7;
            const r = () => { h = (h * 1664525 + 1013904223) >>> 0; return h / 4294967296; };
            for (let i = 0; i < 149; i++) {
                const eu = i < 40;                              // Europe is crowded: a third of the list inside 35..60 N, -10..30 E
                cs.push({ code: "C" + i, name: "Country " + i, lat: eu ? 36 + r() * 24 : -40 + r() * 100, lon: eu ? -10 + r() * 40 : -170 + r() * 340, servers: 1 + Math.floor(r() * 20), minLoad: 20, features: 0, cities: [] });
            }
            mock.catalog = { serial: 2, tier: 2, countries: cs };
            win.popup.globe.turn = -0.17;
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            let front = 0, own = 0;
            for (let i = 0; i < 149; i++) {
                const c = "C" + i;
                if (!G.lightFront(c)) continue;
                front++;
                const p = G.lightPos(c), got = G.lightAt(p.x, p.y);
                if (got && got.code === c) own++;
            }
            console.log("AH globe-149 front=" + front + " pickable-as-itself=" + own);
            win.check("globe-149-lights-pickable", front > 0 && own / front >= 0.8, own + "/" + front + " front lights answer their own point (the rest are within a pick radius of a neighbour)");
        });
        // ---- the globe: bigger at rest, grows while used, grows over the air (nothing moves), swipes rotate and tilt it ----
        // (the pointer of the steps before rests wherever they left it, which on the round-2 board can be over the globe: park it first, so "rest" is a rest)
        S.push(() => { tc.mouseMove(win.contentItem, 3, 3); });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe, D = win.popup.cloud;
            win._q0 = { rest: G._fr.rp, foot: [G._fr.lensX, G._fr.lensY], dome: win.qOf(D), spin: G.spinning };
            // the REST disc overlaps no part of the card, the cables or the label (the pointer is parked: this is the rest size and place), and -- R3 -- stands UNDER the fan's baseline
            // (the label's centre: the cloud's origin), so the globe and the fan never meet
            {
                const f = G._fr, sc = win.popup.scene, C = G.geo.CARD, top = C.yPcb + C.pcb + G.geo.SHIELD.h;
                const hl = win.hull([[C.x0, C.yPcb, C.z0], [C.x0 + C.w, C.yPcb, C.z0], [C.x0 + C.w, top, C.z0 + C.h], [C.x0, top, C.z0 + C.h], [C.x0, top, C.z0], [C.x0 + C.w, top, C.z0], [C.x0 + C.w, C.yPcb, C.z0 + C.h], [C.x0, C.yPcb, C.z0 + C.h]].map(p => Cam.project(p, G.cam)));
                const dCard = CP.distToPoly(hl.map(q => [q.x, q.y]), f.cx, f.cy) - f.rp;
                const dLabel = CP.distToPoly(win.popup._labelPoly, f.cx, f.cy) - f.rp;
                let dCoax = 1e9;
                [0, 1].forEach(i => sc.coaxLayer.path(i, 0, 0, false).forEach(q => { dCoax = Math.min(dCoax, Math.hypot(q.x - f.cx, q.y - f.cy) - f.rp - sc.coaxLayer._w / 2); }));
                win.check("globe-rest-clear-of-card-coax-label", dCard >= 0 && dCoax >= 0 && dLabel >= 0, "gap to the card " + dCard.toFixed(1) + " px, the cables " + dCoax.toFixed(1) + ", the label " + dLabel.toFixed(1));
                // ... and out of the fan: every point of the rest disc is under the baseline, outside the fan's half angle, or past its end
                const Cl = win.popup.cloud, ox = Cl.origin[0], oy = Cl.origin[1], span = Cl.fan.span * Math.PI / 180;
                let worst = 1e9, at = "";
                for (let k = 0; k < 360; k += 3) {
                    const px = f.cx + f.rp * Math.cos(k * Math.PI / 180), py = f.cy + f.rp * Math.sin(k * Math.PI / 180);
                    if (py >= oy)
                        continue;
                    const ang = Math.atan2(Math.abs(px - ox), oy - py), r = Math.hypot(px - ox, py - oy);
                    const clear = ang >= span ? (ang - span) * r : r - Cl.rEnd;
                    if (clear < worst) { worst = clear; at = k + " deg"; }
                }
                win.check("globe-rest-clear-of-the-fan", worst >= 0, "the disc's nearest point to the fan: " + worst.toFixed(1) + " px outside it (" + at + ")");
            }
            G.spinning = false;
            const f0 = G._fr, cx = f0.cx, cy = f0.cy;
            tc.mouseMove(win.contentItem, 3, 3);
            tc.mouseMove(win.contentItem, cx - 4, cy + 2);
            tc.mouseMove(win.contentItem, cx, cy);
            win._q0.samples = [G._fr.rp];
        });
        S.push(() => { const G = win.popup.globe; win._q0.samples.push(G._fr.rp); tc.wait(60); win._q0.samples.push(G._fr.rp); });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe, q = win._q0, s = q.samples;
            const mono = s.every((v, i) => i === 0 || v >= s[i - 1] - 1e-6);
            win.check("globe-grows-under-the-pointer", G.grow > 0.99 && G._fr.rp / q.rest >= 1.4 && mono, "rest " + q.rest.toFixed(1) + " grown " + G._fr.rp.toFixed(1) + " samples " + s.map(v => v.toFixed(1)).join(","));
            // the size is the user's: 1.3 x the globe's ROUND-1 radius on screen (its mm size under round 1's 4.58 px/mm), whatever the camera's zoom is now
            const r1 = G.geo.LENS.globe * 0.9 * 4.58;
            win.check("globe-rest-1.3x-of-round-1", Math.abs(q.rest / r1 - 1.3) < 0.02 && Math.abs(G._fr.rp / q.rest - 2) < 0.02, "rest " + (q.rest / r1).toFixed(3) + " x round 1, grown " + (G._fr.rp / q.rest).toFixed(2) + " x rest");
            // grown, it stays inside the popup (it takes the air over it; nothing is cut by the popup's edges)
            win.check("globe-grown-inside-the-popup", G._fr.cx - G._fr.rp >= 0 && G._fr.cx + G._fr.rp <= win.popup.scene.width && G._fr.cy - G._fr.rp >= 0, "x " + (G._fr.cx - G._fr.rp).toFixed(0) + " .. " + (G._fr.cx + G._fr.rp).toFixed(0) + " of " + win.popup.scene.width + ", top " + (G._fr.cy - G._fr.rp).toFixed(0));
            const moved = win.maxMove(q.dome, win.qOf(win.popup.cloud), "");
            win.check("growing-shoves-nothing", moved < 0.01 && Math.hypot(G._fr.lensX - q.foot[0], G._fr.lensY - q.foot[1]) < 0.01 && G._fr.cy - G._fr.rp >= 0, "tags moved " + moved.toFixed(2) + ", rim top " + (G._fr.cy - G._fr.rp).toFixed(1));
        });
        // synthetic two-finger events straight into the gesture reader (QtTest's wheel carries no pixel delta), then ONE real wheel through the window for the area's wiring
        S.push(() => {
            const G = win.popup.globe, X = win.popup.globeGesture, f = G._fr;
            const ev = (dx, dy) => ({ x: f.cx, y: f.cy, angleDelta: Qt.point(0, 0), pixelDelta: Qt.point(dx, dy) });
            const t0 = G._raw, tl0 = G.tilt;
            X.feed(ev(10, 0));
            const first = G._raw - t0;
            win.check("rotate-follows-the-first-event", Math.abs(first - 10 / G._fr.rp) < 0.2 / G._fr.rp + 1e-4 && G.held, "first event moved " + first.toFixed(4) + " rad, want " + (10 / G._fr.rp).toFixed(4));
            let prev = G._raw, mono = true;
            for (let i = 0; i < 12; i++) {
                X.feed(ev(8, 0));
                if (G._raw < prev - 1e-9) mono = false;
                prev = G._raw;
            }
            const total = G._raw - t0;
            win.check("rotate-is-live-progress", mono && Math.abs(total - 106 / G._fr.rp) < 0.5 / G._fr.rp + 1e-3, "total " + total.toFixed(4) + " want " + (106 / G._fr.rp).toFixed(4));
            // the same axis for the rest of the gesture: vertical drift moves nothing, tilt stays
            for (let i = 0; i < 6; i++) X.feed(ev(2, -30));
            win.check("no-tilt-while-rotating", G.tilt === tl0 && X.axis === "h", "tilt " + G.tilt + " axis " + X.axis);
            win._q0.atLift = G._raw;
            X.feed({ x: f.cx, y: f.cy, angleDelta: Qt.point(0, 0), pixelDelta: Qt.point(0, 0) });
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe, X = win.popup.globeGesture;
            win.check("rotate-coasts-after-the-lift", G._raw > win._q0.atLift + 1e-3 && !X.live, "lift " + win._q0.atLift.toFixed(3) + " now " + G._raw.toFixed(3));
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            // a vertical swipe while nothing turns: live, clamped, settles on the nearer state
            const G = win.popup.globe, X = win.popup.globeGesture, f = G._fr;
            const ev = (dx, dy) => ({ x: f.cx, y: f.cy, angleDelta: Qt.point(0, 0), pixelDelta: Qt.point(dx, dy) });
            win.check("coast-ended", !X.rotating, "still moving");
            const rawA = G._raw;
            X.feed(ev(0, -50));
            const a = G.tilt;
            X.feed(ev(0, -50));
            const b = G.tilt;
            for (let i = 0; i < 8; i++) X.feed(ev(0, -60));
            win.check("tilt-follows-live-and-clamps", a > 0 && b > a && G.tilt === 1 && Math.abs(G._raw - rawA) < 1e-9, "tilt " + a.toFixed(2) + " " + b.toFixed(2) + " " + G.tilt);
            X.feed(ev(0, 40));
            win.check("tilt-eases-back-live", G.tilt < 1 && G.tilt > 0.6, "tilt " + G.tilt);
            X.feed({ x: f.cx, y: f.cy, angleDelta: Qt.point(0, 0), pixelDelta: Qt.point(0, 0) });
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            win.check("tilt-settles-on-a-state", G.tilt === 1 || G.tilt === 0, "tilt " + G.tilt);
            win._q0.tiltState = G.tilt;
        });
        S.push(() => {
            // picking after a turn AND a tilt: every front light answers its own point, and the southern country is visible only when tilted
            const G = win.popup.globe;
            const cs = [["NL", "Netherlands", 52.1, 5.3], ["CH", "Switzerland", 46.8, 8.2], ["BR", "Brazil", -14.2, -51.9], ["AU", "Australia", -25.3, 133.8], ["ZA", "South Africa", -30.6, 22.9]]
                .map(c => ({ code: c[0], name: c[1], lat: c[2], lon: c[3], servers: 6, minLoad: 30, features: 0, cities: [] }));
            mock.catalog = { serial: 3, tier: 2, countries: cs };
            G.tilt = 1;
            G.turn = 0.35;
        });
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe;
            let ok = 0, front = 0, wrong = [];
            ["NL", "CH", "BR", "AU", "ZA"].forEach(c => {
                if (!G.lightFront(c)) return;
                front++;
                const p = G.lightPos(c), got = G.lightAt(p.x, p.y);
                if (got && got.code === c) ok++; else wrong.push(c + "->" + (got ? got.code : "none"));
            });
            win.check("pick-after-turn-and-tilt", front >= 2 && ok === front, ok + "/" + front + " " + wrong.join(","));
            const south = G.project(-30.6, 22.9), south0 = (() => { G.tilt = 0; const p = G.project(-30.6, 22.9); G.tilt = 1; return p; })();
            win.check("tilt-brings-the-south-forward", south.depth > south0.depth + 0.15, "depth tilted " + south.depth.toFixed(2) + " flat " + south0.depth.toFixed(2));
            G.tilt = 0;
            G.pointerOver = false;
            tc.mouseMove(win.contentItem, 3, 3);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const G = win.popup.globe, X = win.popup.globeGesture;
            win.check("globe-shrinks-when-left", !X.held && G.grow < 0.01 && Math.abs(G._fr.rp - win._q0.rest) < 0.5, "grow " + G.grow + " held " + X.held + " rp " + G._fr.rp.toFixed(1) + " rest " + win._q0.rest.toFixed(1));
        });
        // ---- the frames: every tag floats; alive, still (the way from one to the other is the life probe's) ----
        S.push(() => { mock.scenario = "home"; win.popup.animate = true; win.popup.halted = false; });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            // every tag sways on the cloud's one clock (the harness's `float` state reads it the same way), the clock takes its rest ticks from the scene's beat
            let moved = 0, n = 0;
            for (let i = 0; i < win.popup.cloud.tags.count; i++) {
                const t = win.popup.cloud.tags.itemAt(i);
                if (!t || !t.visible)
                    continue;
                n++;
                // qmllint disable missing-property
                if (Math.abs(t.poseX) + Math.abs(t.poseY) + Math.abs(t.poseRot) > 0.05)
                    moved++;
                // qmllint enable missing-property
            }
            const st = win.popup.cloud.floatClock.stats;
            win.check("every-tag-floats", n >= 6 && moved === n && st.beats > 10, "swaying " + moved + "/" + n + " beats=" + st.beats + " own=" + st.own);
            // round 6, ONE CADENCE: a scan's front leaves WITH the regular fronts (it marks the next one), never at a moment of its own
            win.boostAt = [];
            mock.scan();
        });
        for (let i = 0; i < 10; i++)
            S.push(() => {});
        S.push(() => {
            win.check("scan-front-leaves-on-the-beat", win.boostAt.length >= 1 && win.boostAt.every(ph => ph < 0.12), "the scan's front came at phase(s) " + win.boostAt.map(v => v.toFixed(3)).join(", "));
            win._swapsAt = win.swaps;
            win._tAt = Date.now();
        });
        S.push(() => {});
        S.push(() => {
            const s = (Date.now() - win._tAt) / 1000;
            win._alive = (win.swaps - win._swapsAt) / s;
            win.popup.halted = true;
        });
        S.push(() => {});
        S.push(() => {
            const C = win.popup.cloud, st = C.floatClock.stats;
            win._q0 = { ph: C.phase, t: st.beats + st.own + st.frames };
            win._swapsAt = win.swaps;
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const n = win.swaps - win._swapsAt, C = win.popup.cloud, st = C.floatClock.stats;
            console.log("AH rates alive=" + win._alive.toFixed(1) + "/s still=" + n + " frames in 1.2 s (offscreen: frames are not a clock)");
            win.check("still-no-frames", n <= 2 && C.phase === win._q0.ph && st.beats + st.own + st.frames === win._q0.t, "frames while still: " + n + ", phase " + win._q0.ph + " -> " + C.phase + ", clock ticks " + (st.beats + st.own + st.frames - win._q0.t));
        });
        win._steps = S;
    }
    property real _alive: 0
    function popup_run(on: bool): void {
        win.popup.animate = true;
        win.popup.halted = !on;
    }
}
