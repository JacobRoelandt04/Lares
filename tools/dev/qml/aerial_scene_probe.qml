pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/system"
import "modules/aerial/data"
import "modules/aerial/popup"
import "modules/aerial/scene"
import "modules/aerial/scene/AerialCamera.js" as Cam
import "modules/aerial/scene/AerialLayout.js" as Layout
import "modules/aerial/scene/AerialFacts.js" as Facts

// =============================================================================
// tools/dev/qml/aerial_scene_probe.qml -- aerial's scene, judged (tools/dev/aerial_scene_probe.sh runs it, arms it and reads the PNGs). One process, a sequence of steps; every
// check prints `AP <name> PASS|FAIL <why>`, then `AP RESULT PASS|FAIL`:
//   pick      every intent's part answers a click at its centre (and at four points inside its top face), at rest and with the card tilted and the screw out; the screw's shaft picks "screw" too
//   renders   every scenario in both families drawn to $OUT/<scenario>_<family>.png (the runner judges the ink)
//   none      the card's body, the DIPs' enclosure and every decoration pick NOTHING (round 2); only the latch picks
//   label     the live label is QML on the SHIELD PLANE (its map agrees with the tilted shield's projection), shows the real MACs in the Bluetooth zone's small print while no device
//             is connected (and not once one is), and its corner lies on a whole device pixel (at renderScale 1.25, at rest and tilted)
//   coax      each cable is one smooth thin arch from its connector's back and ENDS ON ITS GROMMET (round 3: no notch, no run to an edge); it follows the lifted card
//   board     (pixels, judged by the runner from the `AP RECT` / `AP POLY` lines and the PNGs this run writes under $OUT/px_*.png) the names are the BOARD's own: the board layer alone
//             differs from the same board with its silk texture taken away exactly inside the names' boxes and nowhere else; the two unit labels follow `ratesVariant` / `usageVariant`
//             (the picture changes inside the label's cell and nowhere else); a latch's emblem is lit in its radio's hue only while the radio is on; the glow's pulses are hidden by the
//             lifted card (airplane: no accent light inside the card's projected shield)
//   light     a light changing (a pad's colour) changes no uniform of the cached board; the glow's LED uniforms do change
//   scheme    during a pose's motion the patch is live and the board has its hole; settled, the patch is off and the board has the final pose
//   still     with the clock halted and nothing easing, the window presents no frames
// Env: OUT=<dir> SCENARIOS="home crowd ..." RS=<renderScale for the label check>
// =============================================================================
Window {
    id: root

    readonly property string out: Quickshell.env("OUT") || "/tmp/aerial_scene_probe"
    readonly property var scenarios: (Quickshell.env("SCENARIOS") || "home crowd airplane hotspot vpn portal pairing earbuds nowifi errors").split(" ")
    readonly property real rs: Number(Quickshell.env("RS") || 1.25)
    width: 760
    height: 640
    visible: true
    color: "#FF00FF"

    property var fails: []
    property int swaps: 0
    // inside the convex hull of `pts` (the card's 8 corners on screen): every hull edge keeps the point on its inner side
    function inHull(pts: var, x: real, y: real): bool {
        const P = pts.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]), cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
        const lo = [], up = [];
        P.forEach(p => { while (lo.length >= 2 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); });
        P.slice().reverse().forEach(p => { while (up.length >= 2 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); });
        const h = lo.slice(0, -1).concat(up.slice(0, -1));
        for (let i = 0; i < h.length; i++)
            if (cr(h[i], h[(i + 1) % h.length], [x, y]) < -0.5)
                return false;
        return true;
    }
    function check(name: string, ok: bool, why: string): void {
        console.log("AP " + name + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : ""));
        if (!ok)
            root.fails.push(name);
    }
    Connections {
        target: root
        function onFrameSwapped() { root.swaps++; }
    }

    // a second scene for the label's name (the middle cut): fed by hand
    AerialScene {
        id: labScene
        visible: false
        width: 760
        state: Facts.describe(null, 0)
    }
    // the pixel checks' two boards (rendered outside the window: a grab draws them anyway): `gs` is the board as it is, `ctl` the same board with its silkscreen texture taken away
    Image {
        id: blankSilk
        visible: false
    }
    Item {
        x: 0
        y: 800
        AerialScene {
            id: gs
            width: 760
            animate: false
            halted: true
            family: 0
            renderScale: 1
            state: Facts.describe(null, 0)
        }
    }
    Item {
        x: 900
        y: 800
        AerialScene {
            id: ctl
            width: 760
            animate: false
            halted: true
            family: 0
            renderScale: 1
            state: Facts.describe(null, 0)
        }
    }
    AerialMock {
        id: mock
        live: false
        scenario: "home"
    }
    Item {
        id: stage
        width: 760
        height: 640
        AerialPopup {
            id: popup
            service: mock
            family: 0
            renderScale: 1
            animate: false
        }
    }
    readonly property var scene: popup.scene
    readonly property var geoDoc: scene.geo

    // ---- the steps ----
    property int _step: 0
    property var _steps: []
    Timer {
        id: tick
        interval: 250
        repeat: true
        running: true
        onTriggered: {
            if (root._busy > 0)
                return;
            if (root._step >= root._steps.length) {
                tick.stop();
                console.log("AP RESULT " + (root.fails.length ? "FAIL (" + root.fails.join(", ") + ")" : "PASS"));
                Qt.quit();
                return;
            }
            const fn = root._steps[root._step++];
            fn();
        }
    }

    function _pickAt(intent: string): var {
        const a = Layout.anchorPoint(root.geoDoc, intent, root.scene.pickState());
        const q = Cam.project(a, root.scene.cam);
        return { px: q, part: root.scene.pickPart(q.x, q.y) };
    }
    // the screen points of a part's top face: the centre and four points a third of the way to its corners
    function _samples(partName: string): var {
        const st = root.scene.pickState();
        const p = root.geoDoc.PARTS.find(q => q.name === partName);
        const cs = Cam.cornersOf(root.geoDoc, p, st);
        const top = cs.filter(c => Math.abs(c[1] - Math.max(...cs.map(d => d[1]))) < 1e-6 || true);
        const mid = [0, 1, 2].map(k => cs.reduce((s, c) => s + c[k], 0) / 8);
        const pts = [mid];
        [cs[1], cs[2], cs[5], cs[6]].forEach(c => pts.push([(mid[0] * 2 + c[0]) / 3, c[1], (mid[2] * 2 + c[2]) / 3]));
        return pts.map(w => Cam.project([w[0], Math.max(w[1], mid[1] + 0.001), w[2]], root.scene.cam));
    }
    // the live label's map against the shield plane: four label points through the item's own transform and through the tilted shield's projection
    function planeError(sc: var): real {
        const li = sc.labelItem, G = sc.geo, C = G.CARD, L = G.LABEL, yTop = C.yPcb + C.pcb + G.SHIELD.h + L.h;
        let worst = 0;
        const w = L.x1 - L.x0, h = L.y1 - L.y0;
        [[0, 0], [w, h], [w / 2, h / 2], [w, 0]].forEach(p => {
            const m = li.mapToItem(sc, p[0] * li.kPx, p[1] * li.kPx);
            const q = Cam.project(Cam.tilt(G, [C.x0 + L.x0 + p[0], yTop, C.z0 + L.y0 + p[1]], sc.cardTilt), sc.cam);
            worst = Math.max(worst, Math.hypot(m.x - q.x, m.y - q.y));
        });
        return worst;
    }
    // the item of a Text whose text starts with `head` and its opacity down the chain to the label, and where it lies in the label's px
    function printOf(li: var, head: string): var {
        let found = null;
        const walk = it => { if (typeof it.text === "string" && it.text.indexOf(head) === 0 && !found) found = it; (it.children || []).forEach(walk); };
        walk(li);
        if (!found)
            return null;
        let op = 1;
        for (let it = found; it && it !== li; it = it.parent)
            op *= it.opacity;
        const m = found.mapToItem(li, 0, 0);
        return { opacity: op, x: m.x, y: m.y, w: found.width, h: found.height, visible: found.visible };
    }
    // ---- the pixel checks: pictures to $OUT/px_<name>.png and the rectangles the runner judges them by (`AP RECT <picture> <what> x0 y0 x1 y1`, `AP POLY <picture> <what> x,y ...`) ----
    property var silkDoc: null
    property int _busy: 0                  // grabs asked and not yet landed: the next step waits (a grab shows the state of its own frame, not of the step that asked)
    function _readJson(rel: string): var {
        const x = new XMLHttpRequest();
        x.open("GET", "file://" + RepoRoot.dir + "/" + rel, false);
        x.send();
        return JSON.parse(x.responseText);
    }
    function _px(sc: var, pts: var): var {          // board points -> the bounding rect of their projection
        const q = pts.map(p => Cam.project(p, sc.cam));
        return [Math.min(...q.map(c => c.x)), Math.min(...q.map(c => c.y)), Math.max(...q.map(c => c.x)), Math.max(...q.map(c => c.y))];
    }
    function _rectOfBoard(sc: var, x0: real, z0: real, x1: real, z1: real, pad: real): var {      // mm box on the board's top face, grown by pad mm
        return root._px(sc, [[x0 - pad, 0, z0 - pad], [x1 + pad, 0, z0 - pad], [x1 + pad, 0, z1 + pad], [x0 - pad, 0, z1 + pad]]);
    }
    function rect(pic: string, what: string, r: var): void {
        console.log("AP RECT " + pic + " " + what + " " + r.map(v => v.toFixed(1)).join(" "));
    }
    function hull(pts: var): var {
        const P = pts.slice().sort((a, b) => a.x - b.x || a.y - b.y), cr = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
        const lo = [], up = [];
        P.forEach(p => { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); });
        P.slice().reverse().forEach(p => { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); });
        return lo.slice(0, -1).concat(up.slice(0, -1));
    }
    function shot(item: var, name: string): void {
        root._busy++;
        item.grabToImage(r => { r.saveToFile(root.out + "/px_" + name + ".png"); root._busy--; });
    }
    function facts(wifi: bool, bt: bool, air: bool, units: var): var {
        const d = Facts.describe(null, 0);
        d.wifiOn = wifi;
        d.btOn = bt;
        d.airplane = air;
        if (units)
            d.units = units;
        return d;
    }
    // the latch's lever box where it is drawn now (bounding rect of its projected corners) -- its face carries the emblem
    function leverRect(sc: var, name: string): var {
        const part = sc.geo.PARTS.find(q => q.name === name);
        return root._px(sc, Cam.cornersOf(sc.geo, part, sc.pickState()));
    }
    function pickAll(tag: string): void {
        // every intent, by its home part's top middle (the card's tilt and the lifted screw are in the frames)
        const bad = [];
        Layout.intents().forEach(intent => {
            const r = root._pickAt(intent);
            const got = Layout.intentFor(root.geoDoc, r.part);
            if (got !== intent)
                bad.push(intent + "->" + (got || "none") + "(" + r.part + ")");
        });
        root.check("pick-centre-" + tag, bad.length === 0, bad.join(" "));
        // the edges: four points inside the top face of the main part of each intent must hit the intent (an occluder of the same kind is fine)
        const edgeBad = [];
        const mains = { label: "shield", screw: "screw", "dip.wifi": "dipWifi", "dip.bt": "dipBt", mem: "mem", "bt.scan": "btnBase", jack: "jack", rates: "segRates", usage: "segUsage", globe: "lensBase", "pad.link": "padLink" };
        Object.keys(mains).forEach(intent => {
            let hits = 0;
            root._samples(mains[intent]).forEach(q => {
                if (Layout.intentFor(root.geoDoc, root.scene.pickPart(q.x, q.y)) === intent)
                    hits++;
            });
            if (hits < 4)
                edgeBad.push(intent + ":" + hits + "/5");
        });
        // the screw's shaft is the screw too: its part maps to the screw intent (the table the pick reads)
        root.check("pick-screwshaft-intent-" + tag, Layout.intentFor(root.geoDoc, "screwShaft") === "screw", "intent=" + Layout.intentFor(root.geoDoc, "screwShaft"));
        root.check("pick-edges-" + tag, edgeBad.length === 0, edgeBad.join(" "));
        // what picks NOTHING: the card's body (the stage, not a button), the DIPs' enclosure (only the latch picks), every decoration -- at the centre and four points of each top face
        const noneBad = [];
        const nones = ["pcb", "socket", "dipBody", "decoQfn1", "decoSoic1", "decoInd", "decoSoic2", "decoXtal"];
        if (root.scene.pickState().tilt < 0.01)
            nones.push("mhfMain");
        nones.forEach(name => {
            root._samples(name).forEach(q => {
                const part = root.scene.pickPart(q.x, q.y);
                const got = Layout.intentFor(root.geoDoc, part);
                // a part standing in front of it may answer its own intent: only a hit on the part itself (or the board / another none) must be empty
                if (got !== "" && (part === name))
                    noneBad.push(name + "->" + got);
            });
        });
        root.check("pick-none-" + tag, noneBad.length === 0, noneBad.join(" "));
        // and the two things the round names outright: a click on the card's PCB and on the DIP's enclosure is no intent
        const dipb = root.geoDoc.PARTS.find(q => q.name === "dipBody");
        // the front-right corner of the lid: nothing stands toward the camera from it (the levers slide on the far side), so only the enclosure itself can answer
        const mid = [dipb.max[0] - 0.8, dipb.max[1] - 0.05, dipb.max[2] - 0.5];
        const qd = Cam.project(mid, root.scene.cam);
        root.check("dip-enclosure-picks-nothing-" + tag, Layout.intentFor(root.geoDoc, root.scene.pickPart(qd.x, qd.y)) === "", "part=" + root.scene.pickPart(qd.x, qd.y));
        // round 6: the latch's WHOLE GROOVE picks the latch -- both ends of each track on the housing's top, wherever the lever stands
        const D = root.geoDoc.DIP, grooveBad = [];
        D.rows.forEach((zc, i) => {
            const want = i === 0 ? "dip.wifi" : "dip.bt";
            [D.xOff + 0.4, D.xOff + D.lever.w + D.travel - 0.4].forEach(x => {
                const q = Cam.project([x, D.h, zc], root.scene.cam), got = Layout.intentFor(root.geoDoc, root.scene.pickPart(q.x, q.y));
                if (got !== want)
                    grooveBad.push(want + "@x" + x.toFixed(1) + "=" + (got || "none"));
            });
        });
        root.check("dip-groove-picks-its-latch-" + tag, grooveBad.length === 0, grooveBad.join(" "));
    }

    Component.onCompleted: {
        const S = [];
        // rest
        S.push(() => { mock.scenario = "home"; popup.animate = false; });
        S.push(() => root.pickAll("rest"));
        // the label: QML, the real MACs, whole device pixels
        S.push(() => {
            popup.renderScale = root.rs;
        });
        S.push(() => {
            const li = root.scene.labelItem;
            const f = Facts.describe(popup._facts, Date.now());
            let texts = [];
            const walk = it => { if (it.text !== undefined && typeof it.text === "string") texts.push(it.text); (it.children || []).forEach(walk); };
            walk(li);
            root.check("label-is-qml", li.visible && !root.scene.labelBaked && texts.length > 8, "texts=" + texts.length + " visible=" + li.visible + " baked=" + root.scene.labelBaked);
            root.check("label-macs", f.wfm.length === 12 && texts.some(t => t.indexOf("WFM: " + f.wfm) === 0) && texts.some(t => t.indexOf("BDM: ") === 0), "wfm=" + f.wfm);
            const rsEff = root.scene.renderScale;
            const fx = li.tx * rsEff, fy = li.ty * rsEff;
            root.check("label-whole-px", Math.abs(fx - Math.round(fx)) < 1e-6 && Math.abs(fy - Math.round(fy)) < 1e-6, "tx*rs=" + fx + " ty*rs=" + fy + " rs=" + rsEff);
            root.check("label-on-the-shield-plane", root.planeError(root.scene) < 1.0, "worst corner error " + root.planeError(root.scene).toFixed(2) + " px");
            // the MACs are the Bluetooth zone's small print: inside that zone, drawn (not faded) while no device is connected
            const z = li.btZone, wf = root.printOf(li, "WFM: "), bd = root.printOf(li, "BDM: ");
            const inZone = p => p && p.x >= z[0] * li.kPx - 1 && p.x + p.w <= z[2] * li.kPx + 1 && p.y >= z[1] * li.kPx - 1 && p.y + p.h <= z[3] * li.kPx + 1;
            root.check("label-macs-in-the-bluetooth-zone", inZone(wf) && inZone(bd) && wf.visible && wf.opacity > 0.4 && bd.opacity > 0.4 && li.label.bt.length === 0,
                       "wfm " + JSON.stringify(wf) + " bdm " + JSON.stringify(bd) + " zone " + z + " devices " + li.label.bt.length);
        });
        // a connected device replaces the small print (the MACs fade out, the device's row is drawn)
        S.push(() => {
            const d = Facts.describe(null, 0);
            d.label = { docked: true, name: "homenet-ABC12", lineA: "5 GHz", lineB: "-48 dBm", via: "", hint: false, vpn: false, bt: [{ address: "AA:BB:CC:00:11:22", name: "Buds", kind: "headphones", battery: 60 }] };
            labScene.animate = false;
            labScene.state = d;
        });
        S.push(() => {
            const wf = root.printOf(labScene.labelItem, "WFM: ");
            root.check("label-macs-fade-with-a-device", wf !== null && wf.opacity < 0.05, JSON.stringify(wf));
        });
        // the network NAME on the label: the full width, the type shrinks to fit, then a MIDDLE cut that keeps the end ("homenet-...5Ghz")
        const names = ["homenet-ABC12", "homenet-ABC12_5Ghz", "homenet-ABC12-AP", "Saved-Network-654321", "eduroam", "A very long network name with a distinguishing-suffix_5Ghz"];
        names.forEach((nm, i) => {
            S.push(() => {
                const d = Facts.describe(null, 0);
                d.label = { docked: true, name: nm, lineA: "5 GHz", lineB: "-48 dBm", via: "", hint: false };
                labScene.state = d;
            });
            S.push(() => {
                const li = labScene.labelItem, shown = li.nameShown;
                const tail = nm.slice(-5);
                const cut = shown !== nm;
                root.check("label-name-" + i, shown.length > 0 && shown.slice(-5) === tail && (!cut || (shown.indexOf("\u2026") > 0 && shown.indexOf("\u2026") < shown.length - 1)) && li.namePx >= 30 && li.namePx <= li.kPx * 3.0,
                           nm + " -> " + shown + " px=" + li.namePx);
                if (nm.length <= 8)
                    root.check("label-name-whole-" + i, !cut, nm + " -> " + shown);
                if (i === 1)
                    root.check("label-name-shrinks-before-cutting", li.namePx < li.kPx * 3.0 || !cut, "px=" + li.namePx + " cut=" + cut);
            });
        });
        // the coax: two thin flexible arches, each leaving its connector's back and ENDING ON ITS GROMMET in the board, never a staircase of boxes
        S.push(() => {
            const sc = root.scene, G = sc.geo, cx = sc.coaxLayer;
            const polys = [0, 1].map(i => cx.path(i, 0, 0, false));
            const turn = pl => {
                let worst = 0;
                for (let i = 1; i + 1 < pl.length; i++) {
                    const a = Math.atan2(pl[i].y - pl[i - 1].y, pl[i].x - pl[i - 1].x), b = Math.atan2(pl[i + 1].y - pl[i].y, pl[i + 1].x - pl[i].x);
                    let d = Math.abs(b - a);
                    if (d > Math.PI) d = 2 * Math.PI - d;
                    worst = Math.max(worst, d * 180 / Math.PI);
                }
                return worst;
            };
            const turns = polys.map(turn);
            root.check("coax-is-a-smooth-curve", polys.every(p => p.length >= 20) && turns.every(t => t < 14), "samples " + polys.map(p => p.length) + " worst turn per step " + turns.map(t => t.toFixed(1)));
            root.check("coax-not-boxes", G.PARTS.every(p => p.name.indexOf("coax") !== 0), "a coax box is still a part");
            root.check("coax-thin", cx._w >= 4 && cx._w <= 9, "width " + cx._w.toFixed(1) + " px");
            // each cable's far end is on its grommet (board x, z within the grommet's ring, down at the board) and its near end on its connector's back face (within 0.4 mm of the box)
            const C = G.CARD, yTop = C.yPcb + C.pcb, mhf = [G.MHF.main, G.MHF.aux];
            const info = [0, 1].map(i => {
                const l3 = cx.line3(i), e = l3[l3.length - 1], h = G.CUTS.grommets[i], st = Cam.tilt(G, l3[0], -sc.cardTilt), m = mhf[i], hb = G.MHF.body / 2;
                const dx = Math.max(C.x0 + m[0] - hb - st[0], 0, st[0] - (C.x0 + m[0] + hb)), dz = Math.max(C.z0 + m[1] - hb - st[2], 0, st[2] - (C.z0 + m[1] + hb));
                const dy = Math.max(yTop - st[1], 0, st[1] - (yTop + G.MHF.h));
                return { onGrommet: Math.hypot(e[0] - h[0], e[2] - h[1]) <= G.CUTS.grommetR && e[1] < 0.5 && e[1] >= -0.05, onConnector: Math.hypot(dx, dy, dz) <= 0.4 };
            });
            const inside = polys.every(p => p.every(q => q.x > 0 && q.x < sc.width && q.y > 0 && q.y < sc.height));
            root.check("coax-ends-on-its-grommet", info.every(r => r.onGrommet), JSON.stringify(info));
            root.check("coax-leaves-its-connector", info.every(r => r.onConnector) && inside, JSON.stringify(info) + " inside the popup " + inside);
            root._coaxRest = polys[0][0].y;
        });
        // the scheme: airplane on, the patch is live while the card moves
        S.push(() => { popup.animate = true; mock.scenario = "airplane"; });
        S.push(() => {
            const sc = root.scene;
            root.check("scheme-patch-live", sc.anyMoving && sc.patchLayer.visible && sc.holeRect.z > sc.holeRect.x && sc.boardLayer.hole.z > sc.boardLayer.hole.x,
                       "moving=" + sc.anyMoving + " patch=" + sc.patchLayer.visible + " hole=" + sc.holeRect);
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const sc = root.scene;
            const finalTilt = sc.geo.CARD.tilt;
            root.check("scheme-settled", !sc.anyMoving && !sc.patchLayer.visible && sc.boardLayer.hole.z <= sc.boardLayer.hole.x && Math.abs(sc.boardLayer.cardTilt - finalTilt) < 1e-3,
                       "moving=" + sc.anyMoving + " patch=" + sc.patchLayer.visible + " boardTilt=" + sc.boardLayer.cardTilt + " want " + finalTilt);
            // the cables leave the connectors, which rise with the card
            const lifted = sc.coaxLayer.path(0, 0, 0, false)[0].y;
            root.check("coax-follows-the-card", Math.abs(lifted - root._coaxRest) > 6, "start y " + root._coaxRest.toFixed(1) + " -> " + lifted.toFixed(1));
            // round 6: the lifted card hides the cable's bend behind it -- MAIN is drawn in pieces, and what is left out lies inside the card's outline on screen
            const cx = sc.coaxLayer, runs = cx.runs3(0, false), n = 64;
            let hid = 0, outside = 0;
            for (let i = 0; i <= n; i++) {
                const p = cx.at(0, i / n);
                if (p[1] >= -0.05 && !cx._shown(p)) {
                    hid++;
                    const G = sc.geo, C = G.CARD, q = Cam.project(p, sc.cam);
                    const quad = [[0, 0], [C.w, 0], [C.w, C.h], [0, C.h]].map(c => Cam.project(Cam.tilt(G, [C.x0 + c[0], C.yPcb + C.pcb, C.z0 + c[1]], sc.cardTilt), sc.cam))
                                 .concat([[0, 0], [C.w, 0], [C.w, C.h], [0, C.h]].map(c => Cam.project(Cam.tilt(G, [C.x0 + c[0], C.yPcb, C.z0 + c[1]], sc.cardTilt), sc.cam)));
                    if (!root.inHull(quad.map(v => [v.x, v.y]), q.x, q.y))
                        outside++;
                }
            }
            root.check("coax-bend-hidden-by-the-lifted-card", hid >= 4 && outside === 0 && runs.length >= 1, hid + " of " + (n + 1) + " samples hidden, " + outside + " of them outside the card's outline, " + runs.length + " run(s)");
            // the label follows the tilt on a whole pixel too
            const li = sc.labelItem, r = sc.renderScale;
            root.check("label-whole-px-tilted", Math.abs(li.tx * r - Math.round(li.tx * r)) < 1e-6 && Math.abs(li.ty * r - Math.round(li.ty * r)) < 1e-6, "");
            root.check("label-on-the-shield-plane-tilted", root.planeError(sc) < 1.0, "worst corner error " + root.planeError(sc).toFixed(2) + " px at tilt " + sc.cardTilt.toFixed(3));
        });
        S.push(() => root.pickAll("tilted"));
        // the tilted card's label is where the label is drawn: pick the centre of the (tilted) label
        S.push(() => {
            const sc = root.scene, st = sc.pickState(), L = sc.geo.LABEL, C = sc.geo.CARD;
            const yTop = C.yPcb + C.pcb + sc.geo.SHIELD.h + L.h;
            const w = Cam.tilt(sc.geo, [C.x0 + (L.x0 + L.x1) / 2, yTop - 0.01, C.z0 + (L.y0 + L.y1) / 2], st.tilt);
            const q = Cam.project(w, sc.cam);
            root.check("pick-tilted-label", Layout.intentFor(sc.geo, sc.pickPart(q.x, q.y)) === "label", "part=" + sc.pickPart(q.x, q.y));
        });
        // the light: a pad's colour changing touches no uniform of the cached board
        S.push(() => { popup.animate = false; mock.scenario = "home"; });
        S.push(() => {
            const b = root.scene.boardLayer, g = root.scene.glowLayer;
            root._snap = JSON.stringify([b.motion, b.parts, b.hole, b.view, b.frame, b.light, b.palA, b.palK, b.quad]);
            root._glow = JSON.stringify([g.ledI0, g.ledI1, g.ledK0, g.ledK1]);
            const pads = mock.health.pads.map(p => Object.assign({}, p, { state: p.state === "ok" ? "fail" : "ok" }));
            mock.health = Object.assign({}, mock.health, { pads: pads });
            mock.serial = mock.serial + 1;
        });
        S.push(() => {
            const b = root.scene.boardLayer, g = root.scene.glowLayer;
            const now = JSON.stringify([b.motion, b.parts, b.hole, b.view, b.frame, b.light, b.palA, b.palK, b.quad]);
            const glowNow = JSON.stringify([g.ledI0, g.ledI1, g.ledK0, g.ledK1]);
            root.check("light-not-cached", now === root._snap, "the cached board's uniforms moved with a light");
            root.check("light-glow-moves", glowNow !== root._glow, "the glow's LED uniforms did not change");
        });
        // ---- the board's own pixels ----
        // names: the board layer alone against the same board with no silk texture
        S.push(() => {
            root.silkDoc = root._readJson("modules/aerial/scene/assets/silk.json");
            gs.state = root.facts(false, false, false, null);
            ctl.state = root.facts(false, false, false, null);
            ctl.boardLayer.silk = blankSilk;
            gs.silkTexts = ({});
        });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            root.shot(gs.boardLayer, "names_a");
            root.shot(ctl.boardLayer, "names_b");
            const G = gs.geo, D = root.silkDoc;
            D.labels.forEach(l => {
                if (!l.unit)
                    root.rect("names", "name:" + l.text.replace(" ", "_"), root._rectOfBoard(gs, l.x0, l.z0, l.x1, l.z1, 0.3));
            });
            // what may differ besides the names: the courtyards' outlines, the two unit cells, the latches' emblems
            G.COURTYARDS.forEach((c, i) => {
                const b = c.r ? [c.r[0], c.r[1], c.r[2], c.r[3]] : [c.c[0] - c.c[2], c.c[1] - c.c[2], c.c[0] + c.c[2], c.c[1] + c.c[2]];
                root.rect("names", "allow:court" + i, root._rectOfBoard(gs, b[0], b[1], b[2], b[3], 1.2));
            });
            G.LABELS.filter(l => l.unit).forEach(l => root.rect("names", "allow:unit-" + l.unit, root._rectOfBoard(gs, l.x - 0.3, l.z - 1.8, l.x + D.cell[0] + 0.3, l.z + 1.8, 1.2)));
            ["dipWifi", "dipBt"].forEach(n => root.rect("names", "allow:" + n, (r => [r[0] - 6, r[1] - 6, r[2] + 6, r[3] + 6])(root.leverRect(gs, n))));
        });
        // the two unit labels follow the variant: a whole text the popup asks for, and the facts' own unit
        S.push(() => { gs.silkTexts = ({ rates: "SURE? - MB" }); });
        S.push(() => {});
        S.push(() => {
            root.check("variant-rates-text", gs.ratesVariant === gs.geo.SILK_VARIANTS.rates.indexOf("SURE? - MB") && gs.ratesVariant === 4 && gs.usageVariant === 0, "rates " + gs.ratesVariant + " usage " + gs.usageVariant);
            root.shot(gs.boardLayer, "unit_rates");
        });
        S.push(() => { gs.silkTexts = ({ usage: "PING - ms" }); });
        S.push(() => {});
        S.push(() => {
            root.check("variant-usage-text", gs.usageVariant === 3 && gs.ratesVariant === 1, "rates " + gs.ratesVariant + " usage " + gs.usageVariant);
            root.shot(gs.boardLayer, "unit_usage");
        });
        S.push(() => {
            gs.silkTexts = ({});
            gs.state = root.facts(false, false, false, { rates: "Gb/s", usage: "TiB" });
        });
        S.push(() => {});
        S.push(() => {
            root.check("variant-follows-the-facts", gs.ratesVariant === 2 && gs.usageVariant === 2, "rates " + gs.ratesVariant + " usage " + gs.usageVariant);
            root.shot(gs.boardLayer, "unit_facts");
            const D = root.silkDoc;
            gs.geo.LABELS.filter(l => l.unit).forEach(l => ["unit_rates", "unit_usage", "unit_facts"].forEach(pic => root.rect(pic, "cell:" + l.unit, root._rectOfBoard(gs, l.x - 0.3, l.z - 1.8, l.x + D.cell[0] + 0.3, l.z + 1.8, 0.6))));
        });
        S.push(() => { gs.state = root.facts(false, false, false, null); });
        S.push(() => {});
        S.push(() => {});
        // emblems: lit in the radio's hue only while the radio is on
        [["wifi", [true, false]], ["bt", [false, true]], ["off", [false, false]], ["both", [true, true]]].forEach(e => {
            S.push(() => { gs.state = root.facts(e[1][0], e[1][1], false, null); });
            S.push(() => {});
            S.push(() => {});
            S.push(() => {
                root.shot(gs.boardLayer, "emblem_" + e[0]);
                root.rect("emblem_" + e[0], "dipWifi", root.leverRect(gs, "dipWifi"));
                root.rect("emblem_" + e[0], "dipBt", root.leverRect(gs, "dipBt"));
                const hw = gs.style.wifiHueV, hb = gs.style.btHueV;
                console.log("AP HUE wifi " + [hw.x, hw.y, hw.z].map(v => v.toFixed(3)).join(" ") + " bt " + [hb.x, hb.y, hb.z].map(v => v.toFixed(3)).join(" "));
            });
        });
        // the glow: airplane (the card up), the pulses held at a few times; no accent light may show inside the card's projected box
        S.push(() => {
            gs.state = root.facts(true, true, true, null);
        });
        S.push(() => {});
        S.push(() => {});
        [0.0, 0.9, 1.8, 2.7].forEach((t, i) => {
            S.push(() => { gs.time = t; });
            S.push(() => {});
            S.push(() => {
                root.shot(gs.glowLayer, "glowt" + i);
                const C = gs.geo.CARD, y0 = C.yPcb, y1 = C.yPcb + C.pcb + gs.geo.SHIELD.h + 0.1, pts = [];
                [C.x0, C.x0 + C.w].forEach(x => [y0, y1].forEach(y => [C.z0, C.z0 + C.h].forEach(z => pts.push(Cam.project(Cam.tilt(gs.geo, [x, y, z], gs.cardTilt), gs.cam)))));
                const h = root.hull(pts);
                console.log("AP POLY glow_" + i + " card " + h.map(q => q.x.toFixed(1) + "," + q.y.toFixed(1)).join(" "));
                if (i === 0)
                    root.check("glow-airplane-card-is-up", gs.cardTilt > 0.3 && !gs.anyMoving, "tilt " + gs.cardTilt + " moving " + gs.anyMoving);
            });
        });
        // the screw TURNS as it lifts (one turn anticlockwise, eased out: aerial_materials.glsl screwTurn). The blueprint family (ink, no
        // light-fixed sheen) at two held poses: the lift's end (a whole turn: the slot as at rest, mirror-symmetric about the head's vertical
        // in the isometric view) and the lift where the turn is 22.5 degrees past a quarter (eased share 0.5625: u = 1 - sqrt(0.4375), so
        // airplaneT = 0.35 u), where the slot is NOT mirror-symmetric. The pixel half judges the two (PX screw-turns).
        S.push(() => { gs.state = root.facts(false, false, false, null); gs.family = 1; gs.airplaneT = gs.screwShare; });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            root.shot(gs, "screw_rest");
            root.rect("screw_rest", "head", root._px(gs, Cam.cornersOf(gs.geo, gs.geo.PARTS.find(p => p.name === "screw"), gs.pickState())));
        });
        S.push(() => { gs.airplaneT = gs.screwShare * (1 - Math.sqrt(0.4375)); });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            root.shot(gs, "screw_turn");
            root.rect("screw_turn", "head", root._px(gs, Cam.cornersOf(gs.geo, gs.geo.PARTS.find(p => p.name === "screw"), gs.pickState())));
        });
        // the renders
        root.scenarios.forEach(sc => {
            [0, 1].forEach(fam => {
                S.push(() => { mock.scenario = sc; popup.family = fam; popup.animate = false; });
                S.push(() => {});
                S.push(() => {
                    root.scene.grabToImage(r => { r.saveToFile(root.out + "/" + sc + "_" + fam + ".png"); });
                });
            });
        });
        // still: the clock halted, nothing easing -> no frames
        S.push(() => { mock.scenario = "home"; popup.family = 0; popup.halted = true; });
        S.push(() => {});
        S.push(() => { root._swapsAt = root.swaps; });
        S.push(() => {});
        S.push(() => {});
        S.push(() => {});
        S.push(() => {
            const n = root.swaps - root._swapsAt;
            root.check("still-no-frames", n <= 2, "frames while still: " + n);
        });
        root._steps = S;
    }
    property real _coaxRest: 0
    property string _snap: ""
    property string _glow: ""
    property int _swapsAt: 0
}
