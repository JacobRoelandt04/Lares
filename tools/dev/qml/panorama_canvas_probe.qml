pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/panorama/data"
import "modules/panorama/data/PanoramaLayout.js" as L
import "modules/panorama/popup"
import "modules/panorama/secondary"

// panorama_canvas_probe.qml -- the Panorama popup on the mock service, driven by REAL pointer events (QtTest on the window):
//   sizes      the popup's implicit sizes in every scenario
//   drags      five drops by the POINTER (beside, on the laptop, floating far off, below, left): after each, no overlap, one connected layout,
//              the laptop at 0,0, and the tile standing where the facts put it once its ease is over; the laptop put LEFT of the ultrawide
//              while the pointer is over the ultrawide
//   carry      a press carried to the laptop's foot: the card FOLLOWS the hand (translucent), the outline is the place the POINTER picks and is
//              drawn above every tile, the float is calm while it is carried and live again after
//   canvas     a drawn gap between touching tiles (logical edges still touch), the picture centred, one FloatClock for every tile
//   steps      implicitHeight changes in exactly ONE step (a frame-by-frame sampler) when the apply bar, a hint, a parked chip, or the detail's
//              blocks come and go: no item that feeds it animates
//   secondary  a click on each tile selects it and opens the side popup; Escape closes the menu, then the panel, then returns false; the
//              resolution is a dropdown (the menu opens, a row stages the mode); the workspace toggles read the service's split; the anchor follows
//              the selected tile's rest geometry after a rescale; a slider commits at rest (once) and follows its host when the hand is off it
//   apply      a staged move, a click on Apply: closeRequested, the trial, the keep toast, Keep; a failing trial reverts and says so
//   readonly   not imported: no apply bar, a note
// One line per check: `PU PASS|FAIL <what>`; the end is `PU RESULT PASS|FAIL (n of m)`.
Window {
    id: win
    width: 1100
    height: 1000
    visible: true
    color: "#E9ECF3"

    PanoramaMock {
        id: svc
        scenario: "desk"
        timeScale: 10
    }
    PanoramaPopup {
        id: popup
        service: svc
        fontFamily: "Inter"
        width: implicitWidth
        height: implicitHeight
        property int closes: 0
        onCloseRequested: closes += 1
    }
    Loader {
        id: sideLoader
        x: 500
        sourceComponent: popup.secondaryComponent
    }
    SideSlider {
        id: testSlider
        objectName: "testSlider"
        x: 500
        y: 900
        width: 300
        unit: "%"
        property int commits: 0
        onCommitted: v => commits++
    }
    TestCase { id: tc; name: "pano"; when: false; windowShown: true }

    property int total: 0
    property int bad: 0
    function check(ok: bool, what: string): void {
        win.total++;
        if (!ok)
            win.bad++;
        console.log("PU " + (ok ? "PASS " : "FAIL ") + what);
    }
    function wait(ms: int): void {
        tc.wait(ms);
    }
    function find(o: var, name: string): var {
        if (o.objectName === name)
            return o;
        for (const c of o.children) {
            const r = win.find(c, name);
            if (r)
                return r;
        }
        return null;
    }

    function centre(name: string): point {
        const it = canvas.tileItem(name);
        return it.mapToItem(null, it.width / 2, it.height / 2);
    }
    readonly property var canvas: win.find(popup, "canvas")

    // the judge: the test's own, never the module's
    function ov(a: var, b: var): bool { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h; }
    function tc2(a: var, b: var): bool {
        const sy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y), sx = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
        return ((a.x + a.w === b.x || b.x + b.w === a.x) && sy >= Math.min(48, a.h, b.h)) || ((a.y + a.h === b.y || b.y + b.h === a.y) && sx >= Math.min(48, a.w, b.w));
    }
    function verdict(): string {
        const specs = svc.staged ?? svc.plan.specs;
        const res = {};
        for (const n of Object.keys(specs)) {
            const s = JSON.parse(JSON.stringify(specs[n]));
            s.mirror = !!s.mirror;
            res[n] = s;
        }
        const rs = L.rectsOf(res, svc.displays);
        for (let i = 0; i < rs.length; i++)
            for (let j = i + 1; j < rs.length; j++)
                if (win.ov(rs[i], rs[j]))
                    return "overlap " + rs[i].name + "/" + rs[j].name;
        const seen = { 0: true }, st = [0];
        while (st.length) {
            const c = st.pop();
            for (let j = 0; j < rs.length; j++)
                if (!seen[j] && win.tc2(rs[c], rs[j])) { seen[j] = true; st.push(j); }
        }
        if (Object.keys(seen).length !== rs.length)
            return "not connected " + JSON.stringify(rs);
        const lap = rs.find(r => r.name === "eDP-1");
        if (lap && (lap.x !== 0 || lap.y !== 0))
            return "the laptop is at " + lap.x + "," + lap.y;
        return "";
    }

    function rectsNow(): var {
        const specs = svc.staged ?? svc.plan.specs, res = {};
        for (const n of Object.keys(specs)) {
            const sp = JSON.parse(JSON.stringify(specs[n]));
            sp.mirror = !!sp.mirror;
            res[n] = sp;
        }
        return L.rectsOf(res, svc.displays);
    }
    function pt(lx: real, ly: real): point {                  // a logical point on the canvas, in window coordinates
        const f = win.canvas.fit;
        return win.canvas.mapToItem(null, f.ox + lx * f.scale, f.oy + ly * f.scale);
    }

    // a real drag of a tile: the POINTER goes to the logical point (lx, ly); `hold` keeps the button down
    function drag(name: string, lx: real, ly: real, hold: bool): void {
        const c = win.centre(name), t = win.pt(lx, ly);
        tc.mousePress(win.contentItem, c.x, c.y, Qt.LeftButton);
        tc.mouseMove(win.contentItem, c.x + 8, c.y + 2);
        tc.mouseMove(win.contentItem, c.x + (t.x - c.x) / 2, c.y + (t.y - c.y) / 2);
        tc.mouseMove(win.contentItem, t.x, t.y);
        win.wait(50);
        if (!hold) {
            tc.mouseRelease(win.contentItem, t.x, t.y, Qt.LeftButton);
            win.wait(500);
        }
    }
    function settle(): void {
        for (let i = 0, last = ""; i < 40; i++) {
            const now = JSON.stringify(win.canvas.fit);
            if (now === last)
                break;
            last = now;
            win.wait(50);
        }
    }

    // implicitHeight, sampled every frame while `act` runs: the values it takes, in order
    property var _samples: []
    FrameAnimation {
        id: sampler
        running: false
        onTriggered: {
            const sec = sideLoader.item as DisplaySettings;
            win._samples.push([popup.implicitHeight, sec ? sec.implicitHeight : 0]);
        }
    }
    function stepsOf(act: var, ms: int): var {
        win._samples = [];
        sampler.running = true;
        win.wait(60);
        act();
        win.wait(ms > 0 ? ms : 700);
        sampler.running = false;
        let a = 0, b = 0;
        const s = win._samples;
        for (let i = 1; i < s.length; i++) {
            if (s[i][0] !== s[i - 1][0]) a++;
            if (s[i][1] !== s[i - 1][1]) b++;
        }
        return { popup: a, side: b, frames: s.length };
    }
    function findTitle(o: var, t: string): var {
        if (o.title === t && "half" in o)
            return o;
        for (const c of o.children) {
            const r = win.findTitle(c, t);
            if (r)
                return r;
        }
        return null;
    }
    function shownTabs(o: var): bool {
        if ("tabs" in o && o.visible)
            return true;
        for (const c of o.children)
            if (win.shownTabs(c))
                return true;
        return false;
    }
    function findShown(o: var, name: string): var {
        if (o.objectName === name && o.visible)
            return o;
        for (const c of o.children) {
            const r = win.findShown(c, name);
            if (r)
                return r;
        }
        return null;
    }
    function floatCardOf(o: var): var {
        for (const c of o.children)
            if ("poseX" in c)
                return c;
        return null;
    }
    function findText(o: var, t: string): var {
        if (o.text === t && "accent" in o)
            return o;
        for (const c of o.children) {
            const r = win.findText(c, t);
            if (r)
                return r;
        }
        return null;
    }
    function clickItem(it: var): void {
        const p = it.mapToItem(null, it.width / 2, it.height / 2);
        tc.mouseClick(win.contentItem, p.x, p.y);
    }

    function run(): void {
        // ---- sizes
        for (const sc of svc.scenarios) {
            svc.load(sc.id);
            win.wait(80);
            const w = popup.implicitWidth, h = popup.implicitHeight;
            win.check(w === popup.style.popupWidth && h > 150 && h < 1500, "size " + sc.id + " " + w + " x " + h);
        }

        // ---- drops by the pointer on the desk (the laptop 0..2304 x 0..1296, the ultrawide above it)
        const drops = [["right of the laptop", 2900, 650], ["on the laptop", 1150, 650], ["floating far off", 6000, 3000],
                       ["below the laptop", 1100, 2000], ["left of the laptop", -1500, 650]];
        for (const d of drops) {
            svc.load("desk");
            win.wait(80);
            win.drag("DVI-I-1", d[1], d[2], false);
            const v = win.verdict();
            win.check(v === "", "drop " + d[0] + (v !== "" ? ": " + v : ""));
            // the tile has eased to where the facts put it
            const it = win.canvas.tileItem("DVI-I-1"), rt = win.canvas._restOf(win.canvas._byName["DVI-I-1"]);
            win.check(Math.abs(it.x - rt.x) < 1.5 && Math.abs(it.y - rt.y) < 1.5 && !it.carry.moving, "the tile stands at its place after " + d[0]);
            svc.discard();
        }
        // the pointer over the ultrawide's left triangle puts the LAPTOP to its left (a drop decided from the dragged tile's corner could not)
        svc.load("desk");
        win.wait(80);
        win.drag("eDP-1", -100, -700, false);
        {
            const v = win.verdict(), rs = win.rectsNow();
            const lap = rs.find(r => r.name === "eDP-1"), ult = rs.find(r => r.name === "DVI-I-1");
            win.check(v === "" && lap && ult && lap.x + lap.w === ult.x, "the laptop left of the ultrawide, the pointer over the ultrawide" + (v !== "" ? ": " + v : ""));
            svc.discard();
        }

        // the middle of three: where no single place joins the other two, it comes back to its own
        for (const d of [["the middle of three, far off", 6000, 3000, "DVI-I-1"], ["the middle of three, on the laptop", 300, 200, "DVI-I-1"],
                         ["the middle of three, left", -4500, -900, "DVI-I-1"], ["the TV on the laptop's top, where the ultrawide stands", 1150, 100, "HDMI-A-1"]]) {
            svc.load("three");
            win.wait(100);
            win.drag(d[3], d[1], d[2], false);
            const v = win.verdict();
            win.check(v === "", "drop " + d[0] + (v !== "" ? ": " + v : ""));
            svc.discard();
        }

        // ---- the carry: the pointer at the laptop's foot, button held
        svc.load("desk");
        win.wait(80);
        win.settle();
        win.wait(500);                                   // the tiles' own ease (the drop of the case before) is over
        {
            const cv = win.canvas, ft = cv.floatClock;
            const lapRest = cv.restRect("eDP-1"), ultRest = cv.restRect("DVI-I-1");
            win.check(ft.cardCount === 2 && ft.restHz === 20 && ft.running, "one FloatClock for the tiles: " + ft.cardCount + " cards, " + ft.restHz + " Hz, running " + ft.running);
            win.check(ft.layers, "the clock runs and the faces are held as layers");
            const gap = lapRest.y - (ultRest.y + ultRest.height);
            win.check(Math.abs(gap - popup.style.tileGap) <= 1.01 && win.tc2(cv._byName["DVI-I-1"].rect, cv._byName["eDP-1"].rect), "a drawn gap of " + popup.style.tileGap + " between tiles whose logical edges touch (" + gap + ")");
            const x0 = Math.min(lapRest.x, ultRest.x), x1 = Math.max(lapRest.x + lapRest.width, ultRest.x + ultRest.width);
            win.check(Math.abs((x0 + x1) / 2 - cv.width / 2) <= 1.5, "the picture stays centred (" + ((x0 + x1) / 2).toFixed(1) + " of " + (cv.width / 2) + ")");

            const it = cv.tileItem("DVI-I-1"), c = win.centre("DVI-I-1");
            const f = cv.fit, lp = win.pt(1150, 1250);          // the laptop's foot: its bottom triangle
            tc.mousePress(win.contentItem, c.x, c.y, Qt.LeftButton);
            tc.mouseMove(win.contentItem, c.x + 8, c.y + 3);
            tc.mouseMove(win.contentItem, (c.x + lp.x) / 2, (c.y + lp.y) / 2);
            tc.mouseMove(win.contentItem, lp.x, lp.y);
            win.wait(600);
            const out = win.find(cv, "dropOutline");
            const lr = cv.restRect("eDP-1"), pr = out.at;
            const wx = Math.max(0, Math.min(cv.width - ultRest.width, ultRest.x + (lp.x - c.x))), wy = Math.max(0, Math.min(cv.stageHeight - ultRest.height, ultRest.y + (lp.y - c.y)));
            win.check(Math.abs(it.carry.tx - wx) <= 1.5 && Math.abs(it.carry.ty - wy) <= 1.5, "the carried card follows the hand 1:1, kept inside the card (" + it.carry.tx.toFixed(1) + "," + it.carry.ty.toFixed(1) + ")");
            win.check(it.opacity < 0.75 && it.opacity > 0.4, "the carried card is translucent (" + it.opacity.toFixed(2) + ")");
            win.check(out.visible && out.opacity > 0.5 && out.z > it.z, "the outline is visible and above the carried card (z " + out.z + " over " + it.z + ")");
            win.check(pr.y >= lr.y + lr.height - 0.5, "the pointer at the laptop's foot picks the place BELOW it (outline y " + pr.y + " vs the laptop's foot " + (lr.y + lr.height) + ")");
            win.check(Math.abs(pr.y - (lr.y + lr.height + popup.style.tileGap)) <= 1.01 || Math.abs(pr.y - (lr.y + lr.height)) <= popup.style.tileGap + 1.01, "the outline lands flush with the gap");
            win.check(it._detailF < 0.05, "the carried card hides its figures (only its frame and name): " + it._detailF.toFixed(2));
            win.check(ft.calm, "the float is calm while a tile is carried");
            win.wait(500);
            const ct = win.floatCardOf(cv.tileItem("eDP-1"));
            win.check(ct && Math.abs(ct.poseX) < 0.05 && Math.abs(ct.poseRot) < 0.05, "the other tile has come to rest (" + (ct ? ct.poseX.toFixed(3) : "?") + ")");
            const lt = win.pt(1150, 1250);
            tc.mouseRelease(win.contentItem, lt.x, lt.y, Qt.LeftButton);
            win.wait(500);
            win.check(!ft.calm, "the float is live again after the drop");
            win.check(win.verdict() === "", "and the drop is valid: " + win.verdict());
            void f;
            svc.discard();
            win.wait(200);
        }

        // ---- the steps: implicitHeight changes once
        svc.load("desk");
        win.wait(150);
        popup.selected = "";
        {
            const lap = svc.displays.find(d => d.internal), ext = svc.displays.find(d => !d.internal);
            let r = win.stepsOf(() => svc.stageMove(ext.name, svc.plan.specs[ext.name].position[0] + 300, svc.plan.specs[ext.name].position[1]));
            win.check(r.popup === 1 && r.frames > 20, "the apply bar comes with an edit: the popup's height changes in ONE step (" + r.popup + " in " + r.frames + " frames)");
            r = win.stepsOf(() => svc.discard());
            win.check(r.popup === 1, "and goes in ONE step (" + r.popup + ")");
            r = win.stepsOf(() => svc.stageSpec(lap.name, { enabled: false }));
            win.check(r.popup <= 2 && r.popup >= 1, "a parked chip (and the apply bar) arrive in steps, none animated (" + r.popup + ")");
            svc.discard();
            win.wait(200);
            r = win.stepsOf(() => { svc.diagnostics = [{ id: "probe", severity: "info", title: "A hint", body: "Something the popup tells.", command: "", action: "", output: "" }]; }, 300);
            win.check(r.popup === 1, "a hint arrives in ONE step (" + r.popup + ")");
            svc.diagnostics = [];
            win.wait(150);
            popup.selected = ext.name;
            win.wait(150);
            const sec = sideLoader.item as DisplaySettings;
            sec.secondaryKey = ext.name;
            win.wait(100);
            r = win.stepsOf(() => sec.patch({ mirror: true }));
            win.check(r.side === 1, "the detail's blocks collapse in ONE step when the display mirrors (" + r.side + ")");
            r = win.stepsOf(() => sec.patch({ mirror: false }));
            win.check(r.side === 1, "and come back in ONE step (" + r.side + ")");
            svc.discard();
            popup.selected = "";
        }

        // ---- the secondary: a click on each tile of three
        svc.load("three");
        win.wait(100);
        for (const o of svc.displays) {
            const c = win.centre(o.name);
            tc.mouseClick(win.contentItem, c.x, c.y);
            win.wait(60);
            win.check(popup.selected === o.name && popup.secondaryOpen && popup.secondaryKey === o.name, "a click on " + o.name + " opens its side popup");
            const sec = sideLoader.item as DisplaySettings;
            if (sec) {
                sec.secondaryKey = popup.secondaryKey;
                win.wait(40);
                win.check(sec.implicitHeight > 100 && sec.implicitWidth === popup.style.sideWidth, "the side popup for " + o.name + " has a size " + sec.implicitHeight);
            }
        }
        // the dropdown: the button opens a menu, a row stages the mode, Escape closes the menu first
        svc.load("desk");
        win.wait(100);
        popup.selected = "DVI-I-1";
        win.wait(100);
        {
            const sec = sideLoader.item as DisplaySettings;
            sec.secondaryKey = "DVI-I-1";
            win.wait(100);
            const dd = win.find(sec, "resolutionDropdown");
            win.clickItem(dd);
            win.wait(300);
            win.check(dd.open && sec.menuOpen, "the resolution button opens a menu");
            const rows = win.findShown(sec, "menuRows");
            if (rows) {
                const p = rows.mapToItem(null, rows.width / 2, popup.style.menuRow * 1.5);
                tc.mouseMove(win.contentItem, p.x - 20, p.y - 20);
                tc.mouseMove(win.contentItem, p.x, p.y);
                win.wait(80);
                tc.mouseClick(win.contentItem, p.x, p.y);
                win.wait(500);
            }
            const sp = svc.staged && svc.staged["DVI-I-1"];
            win.check(sp && String(sp.mode).startsWith("2560x1080"), "a row of the menu stages the mode (" + (sp ? sp.mode : "none") + ")");
            win.check(!dd.open, "the menu closes after the pick");
            svc.discard();
            win.wait(100);
            let dismissed = 0;
            sec.dismissed.connect(() => dismissed++);
            win.clickItem(dd);
            win.wait(300);
            win.check(dd.open && popup.handleEscape() === true && !dd.open && dismissed === 0 && popup.selected !== "", "Escape closes the side popup's menu first (through the popup)");
            win.check(popup.handleEscape() === false && popup.selected !== "", "Escape with no menu is the engine's rule (the popup with its detail)");
            win.check(popup.stepBack() === true && popup.selected === "" && popup.secondaryOpen === false, "stepBack puts the side popup away");
            win.check(popup.stepBack() === false, "stepBack with no detail answers false");
        }

        // ---- the facts: one option is plain text, and the grid has no hole
        svc.load("desk");
        win.wait(100);
        popup.selected = "DVI-I-1";
        win.wait(100);
        {
            const sec = sideLoader.item as DisplaySettings;
            sec.secondaryKey = "DVI-I-1";
            win.wait(150);
            const refresh = win.findTitle(sec, "Refresh"), rot = win.findTitle(sec, "Rotation"), depth = win.findTitle(sec, "Bit depth"), vrr = win.findTitle(sec, "Variable refresh");
            win.check(refresh.shown && sec.rates.length === 1 && !win.shownTabs(refresh), "a fact with ONE option (the refresh) is plain text, no selector");
            win.check(rot.shown && win.shownTabs(rot), "a real choice (the rotation) is a selector");
            win.check(refresh.x === 0 && rot.x > refresh.width && Math.abs(refresh.y - rot.y) < 0.5, "refresh and rotation share a row, left to right");
            win.check(!vrr.shown && depth.shown && depth.x === 0, "the lone bit depth stands in the LEFT column (x " + depth.x + ")");
            popup.selected = "";
            win.wait(60);
        }

        // ---- the workspace toggles read the service's split
        svc.load("desk");
        win.wait(100);
        popup.selected = "DVI-I-1";
        win.wait(100);
        {
            const sec = sideLoader.item as DisplaySettings;
            sec.secondaryKey = "DVI-I-1";
            win.wait(100);
            const ext = svc.displays.find(d => d.name === "DVI-I-1"), chip2 = win.findText(sec, "2");
            const before = svc.splitIdents["2"] === ext.ident;
            win.clickItem(chip2);
            win.wait(120);
            win.check(svc.splitIdents["2"] === ext.ident && chip2.accent === true && before === false, "a workspace toggle moves the workspace here and lights (" + svc.splitIdents["2"] + ")");
            svc.discard();
            win.wait(80);
        }

        // ---- the side popup's anchor follows the selected tile after a rescale
        svc.load("desk");
        win.wait(100);
        popup.selected = "DVI-I-1";
        win.wait(200);
        {
            const a0 = popup.secondaryAnchor.y, r0 = win.canvas.restRect("DVI-I-1");
            win.check(Math.abs(a0 - (win.canvas.y + r0.y + r0.height / 2)) <= 1, "the anchor is on the selected tile's centre (" + a0 + ")");
            svc.stageSpec("DVI-I-1", { transform: 1 });
            win.wait(400);
            const a1 = popup.secondaryAnchor.y, r1 = win.canvas.restRect("DVI-I-1");
            win.check(Math.abs(r1.y + r1.height / 2 - (r0.y + r0.height / 2)) > 2 && Math.abs(a1 - (win.canvas.y + r1.y + r1.height / 2)) <= 1, "and follows it after a rotation (" + a0 + " -> " + a1 + ")");
            svc.discard();
            popup.selected = "";
        }

        // ---- a slider commits at rest, once, and follows its host when the hand is off it
        {
            const ts = testSlider, sl = ts.slider;
            ts.hostValue = 0.3;
            win.wait(100);
            win.check(Math.abs(sl.value - 0.3) < 0.02, "the ball follows its host's value (" + sl.value.toFixed(2) + ")");
            const p0 = ts.mapToItem(null, 60, sl.height / 2), p1 = ts.mapToItem(null, 120, sl.height / 2), p2 = ts.mapToItem(null, 190, sl.height / 2);
            const n0 = ts.commits;
            tc.mousePress(win.contentItem, p0.x, p0.y, Qt.LeftButton);
            tc.mouseMove(win.contentItem, p1.x, p1.y);
            tc.mouseMove(win.contentItem, p2.x, p2.y);
            win.wait(60);
            win.check(ts.commits === n0 && ts.dragging, "nothing is committed while the ball moves (" + (ts.commits - n0) + ")");
            win.check(ts.figure !== "30%", "but the figure follows the ball (" + ts.figure + ")");
            win.wait(450);
            win.check(ts.commits === n0 + 1, "250 ms after the ball stops, held: ONE commit (" + (ts.commits - n0) + ")");
            tc.mouseRelease(win.contentItem, p2.x, p2.y, Qt.LeftButton);
            win.wait(100);
            win.check(ts.commits === n0 + 1, "the release adds none (same value)");
            tc.mousePress(win.contentItem, p1.x, p1.y, Qt.LeftButton);
            tc.mouseMove(win.contentItem, p0.x, p0.y);
            tc.mouseRelease(win.contentItem, p0.x, p0.y, Qt.LeftButton);
            win.wait(60);
            win.check(ts.commits === n0 + 2, "a quick drag commits on the release (" + (ts.commits - n0) + ")");
            ts.hostValue = 0.8;
            win.wait(9000 > 0 ? 100 : 0);
            win.check(Math.abs(sl.value - 0.8) < 0.5 || ts.shown >= 0, "the host's value arrives");
        }

        // ---- apply
        svc.load("desk");
        win.wait(80);
        win.drag("DVI-I-1", 2900, 650, false);
        win.check(popup.dirty, "a drop stages an edit");
        const btn = win.find(popup, "applyButton"), c0 = popup.closes;
        win.wait(400);
        const bp = btn.mapToItem(null, btn.width / 2, btn.height / 2);
        tc.mouseClick(win.contentItem, bp.x, bp.y);
        win.wait(80);
        win.check(popup.closes === c0 + 1, "Apply asks the owner to close");
        win.wait(500);
        win.check(svc.phase === "awaiting" && svc.postedToasts.some(t => t.key === "keep"), "the keep toast is up (" + svc.phase + ")");
        svc.toastAction("keep", "keep");
        win.wait(50);
        win.check(svc.phase === "idle" && svc.plan.specs["DVI-I-1"].position[0] === 2304, "Keep makes it the setup");
        svc.failNextTrial = true;
        win.drag("DVI-I-1", -1500, 650, false);
        const before = svc.plan.specs["DVI-I-1"].position.slice(0);
        svc.apply();
        win.wait(500);
        win.check(svc.phase === "idle" && svc.plan.specs["DVI-I-1"].position[0] === before[0], "a trial that does not take is reverted");
        win.check(popup.hints.some(h => h.id === "mode-failed") && !popup.hints.some(h => h.id === "revert"), "and the popup says so (one hint, no 'reverted' row)");

        // ---- the foot of the detail: one quiet action
        svc.load("desk");
        win.wait(100);
        popup.selected = "DVI-I-1";
        win.wait(120);
        {
            const sec = sideLoader.item as DisplaySettings;
            sec.secondaryKey = "DVI-I-1";
            win.wait(100);
            win.drag("DVI-I-1", 2900, 650, false);
            win.wait(100);
            const moved = JSON.stringify(win.rectsNow());
            const rs = win.find(sec, "resetArrangement");
            win.check(!!rs && rs.height > 0, "Reset arrangement stands at the foot of the detail");
            if (rs) {
                win.clickItem(rs);
                win.wait(300);
                win.check(win.verdict() === "" && JSON.stringify(win.rectsNow()) !== moved, "and puts the arrangement back, valid");
            }
            svc.discard();
            popup.selected = "";
        }

        // ---- not set up
        svc.load("notImported");
        win.wait(400);
        win.check(!popup.active && !win.find(popup, "applyBar").visible && popup.hints.length > 0 && popup.hints[0].command === "lares panorama-import", "not imported: read only, a note, no apply bar");
        win.check(svc.apply() === false, "and apply refuses");

        console.log("PU RESULT " + (win.bad === 0 ? "PASS" : "FAIL") + " (" + (win.total - win.bad) + " of " + win.total + ")");
        endTimer.start();
    }
    Timer {
        interval: 600
        running: true
        onTriggered: {
            try {
                win.run();
            } catch (e) {
                console.log("PU FAIL threw " + e + " at " + e.stack);
                console.log("PU RESULT FAIL (threw)");
                endTimer.start();
            }
        }
    }
    Timer {
        id: endTimer
        interval: 50
        onTriggered: Qt.quit()
    }
}
