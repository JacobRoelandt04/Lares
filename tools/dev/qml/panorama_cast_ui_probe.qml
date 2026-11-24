pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/panorama/data"
import "modules/panorama/popup"
import "modules/panorama/secondary"

// panorama_cast_ui_probe.qml -- the cast chip, the TV's tile and its detail on the mock service, driven by REAL pointer events (QtTest):
//   off      "cast": false: no chip, no mark, no scan (a census of the popup's items), the popup's picture the same with and without a cast service
//            (the runner compares the two PNGs this writes: PCU_TMP/off_a.png, off_b.png)
//   chip     a found TV is ONE chip in the parked row; the row appears in ONE step of implicitHeight
//   confirm  a click: the confirm step in the reserved room (the popup's height and the laptop's tile do not move), the honest Wi-Fi line, a
//            Cast button; leaving the chip or Escape puts it back
//   connect  the cast's words in the chip ("Preparing…", "Connecting…", "Negotiating…"), no tile yet, no keep prompt
//   tile     the TV is a tile with the cast mark and its name, the chip is gone, ONE step of implicitHeight
//   detail   the Cast block (state with the mode, Stop casting), no brightness / VRR / bit depth, Mirror stays; a quality change is a draft until
//            Apply to stream (ONE restart); Stop casting goes down and the chip comes back
//   figures  the stream's figures in the detail: eight with their texts, two columns that flow, nothing over anything whatever the font, every figure
//            of ONE beat (the frames they change on), no delegate rebuilt, a figure that comes is ONE step of the height, a lost link leaves the
//            totals, held while the detail shows them and released with it
//   failure  the reason in the chip for its time, then the chip is back
// One line per check: `PU PASS|FAIL <what>`; the end is `PU RESULT PASS|FAIL (n of m)`.
Window {
    id: win
    width: 1100
    height: 900
    visible: true
    color: "#E9ECF3"

    CastMock {
        id: cm
        stepMs: 60
        beatMs: 100
        stopMs: 60
        scanMs: 40
    }
    PanoramaMock {
        id: svc
        scenario: "laptop"
        timeScale: 20
        castConfig: false
        cast: null
    }
    PanoramaPopup {
        id: popup
        service: svc
        fontFamily: "Inter"
        width: implicitWidth
        height: implicitHeight
        parked: true
    }
    Loader {
        id: sideLoader
        x: 500
        sourceComponent: popup.secondaryComponent
    }
    TestCase { id: tc; name: "panocast"; when: false; windowShown: true }

    readonly property string tv: "wfd:02:AE:00:00:0A:01"
    readonly property string tvName: "[TV] Living Room OLED 65"
    property int total: 0
    property int bad: 0
    property int scans: 0
    property int ups: 0
    function check(ok: bool, what: string): void {
        win.total++;
        if (!ok)
            win.bad++;
        console.log("PU " + (ok ? "PASS " : "FAIL ") + what);
    }
    function wait(ms: int): void {
        tc.wait(ms);
    }
    function until(fn: var, ms: int): bool {
        for (let t = 0; t < ms; t += 20) {
            if (fn())
                return true;
            tc.wait(20);
        }
        return fn();
    }
    Connections {
        target: cm
        function onScanningChanged() {
            if (cm.scanning)
                win.scans++;
        }
        function onStarted() {
            win.ups++;
        }
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
    function count(o: var, name: string): int {
        let n = o.objectName === name ? 1 : 0;
        for (const c of o.children)
            n += win.count(c, name);
        return n;
    }
    function textLike(o: var, part: string): var {
        if (typeof o.text === "string" && o.text.indexOf(part) >= 0 && o.visible)
            return o;
        for (const c of o.children) {
            const r = win.textLike(c, part);
            if (r)
                return r;
        }
        return null;
    }
    function symbols(o: var): int {          // Texts in the cast mark's font, visible
        let n = o.font && o.font.family === "Symbols Nerd Font" && o.visible ? 1 : 0;
        for (const c of o.children)
            n += win.symbols(c);
        return n;
    }
    function click(it: var): void {
        const p = it.mapToItem(null, it.width / 2, it.height / 2);
        tc.mouseMove(win.contentItem, p.x - 3, p.y - 2);
        tc.mouseMove(win.contentItem, p.x, p.y);
        tc.mouseClick(win.contentItem, p.x, p.y);
    }
    readonly property var canvas: win.find(popup, "canvas")
    function chip(): var {
        return win.find(popup, "castChip");
    }

    // implicitHeight, sampled every frame while `act` runs: the number of changes
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
        win.wait(ms);
        sampler.running = false;
        let a = 0, b = 0;
        const s = win._samples;
        for (let i = 1; i < s.length; i++) {
            if (s[i][0] !== s[i - 1][0]) a++;
            if (s[i][1] !== s[i - 1][1]) b++;
        }
        return { popup: a, side: b };
    }

    function grab(name: string): void {
        let done = false;
        popup.grabToImage(r => {
            r.saveToFile(Quickshell.env("PCU_TMP") + "/" + name);
            done = true;
        });
        win.until(() => done, 3000);
    }

    // ---- the figures ----
    readonly property var keys: ["fps", "kbps", "dropped", "rttMs", "repeated", "signalDbm", "behindMs", "linkMbps"]
    readonly property var full: ({ fps: 29.96, kbps: 8312, dropped: 3, rttMs: 4.1, repeated: 41, signalDbm: -52, behindMs: 340, linkMbps: 866.7 })
    readonly property var long: ({ fps: 60, kbps: 160300, dropped: 123456, rttMs: 1240, repeated: 98765, signalDbm: -100, behindMs: 123400, linkMbps: 144.4 })
    function cell(sec: var, k: string): var {
        return win.find(sec, "castFigure-" + k);
    }
    function figure(sec: var, k: string): string {
        const c = win.cell(sec, k);
        return c && c.visible ? win.find(c, "castFigureText").text : "";
    }
    // a name that reaches its figure, or a figure outside its column
    function crowded(sec: var): string {
        for (const k of win.keys) {
            const c = win.cell(sec, k);
            if (!c.visible)
                continue;
            const f = win.find(c, "castFigureText"), label = c.children.find(x => x !== f && x.text !== undefined);
            if (label.x + label.implicitWidth > f.x - 4 || f.x < 0 || f.x + f.width > c.width + 0.01)
                return k + " " + label.implicitWidth + " + " + f.implicitWidth + " of " + c.width;
        }
        return "";
    }
    property int _frame: 0
    property var _changes: ({})
    FrameAnimation {
        running: true
        onTriggered: win._frame++
    }
    function changed(): void {
        win._changes[win._frame] = (win._changes[win._frame] || 0) + 1;
    }
    function figures(sec: var): void {
        cm.pinned = win.full;
        win.until(() => win.figure(sec, "repeated") === "41", 2000);
        const texts = win.keys.map(k => win.figure(sec, k)).join("|");
        win.check(texts === "30 fps|8.3 Mbit/s|3|4 ms|41|-52 dBm|0.3 s|867 Mbit/s", "figures: the eight with their texts: " + texts);
        win.check(cm.figures.holds === 1, "figures: the detail holds them once (" + cm.figures.holds + ")");
        const col = win.cell(sec, "fps"), at = k => win.cell(sec, k).x + "," + win.cell(sec, k).y;
        const right = col.parent.width - col.width, row = popup.style.castFigureRow;
        win.check(win.keys.map(at).join(" ") === win.keys.map((k, i) => (i % 2 ? right : 0) + "," + Math.floor(i / 2) * row).join(" "), "figures: the stream's in the left column, the link's in the right: " + win.keys.map(at).join(" "));
        let tight = "";
        for (const font of ["Audiowide", "Inter"]) {
            popup.fontFamily = font;
            for (const set of [win.long, win.full]) {
                cm.pinned = set;
                win.wait(300);
                tight = tight || (win.crowded(sec) !== "" ? font + " " + win.crowded(sec) : "");
            }
        }
        win.check(tight === "" && win.figure(sec, "dropped") === "3", "figures: the longest and the shortest keep clear of their names, in Audiowide and in Inter" + (tight === "" ? "" : ": " + tight));

        // one beat: whatever changes, changes on one frame; nothing is rebuilt
        cm.pinned = null;
        win.wait(300);
        const cells = win.keys.map(k => win.cell(sec, k));
        const recs = cells.map(c => {
            const f = win.find(c, "castFigureText");
            f.textChanged.connect(win.changed);
            return f;
        });
        win._changes = ({});
        const b0 = cm._run.beats;
        win.until(() => cm._run.beats >= b0 + 6, 4000);
        const beats = cm._run.beats - b0, on = Object.keys(win._changes).length;
        const same = win.keys.every((k, i) => win.cell(sec, k) === cells[i]);
        win.check(same, "figures: no delegate is built anew at a beat");
        if (!same)
            return;                                       // (the recorded texts are gone with their delegates)
        recs.forEach(f => f.textChanged.disconnect(win.changed));
        win.check(on >= 2 && on <= beats + 1, "figures: all of one beat change on one frame (" + on + " frames for " + beats + " beats)");

        // a figure comes: the rows flow, ONE step of the height; the cells are the same ones
        cm.pinned = { fps: 30, dropped: 0, repeated: 0, behindMs: 0, kbps: 8000 };
        win.until(() => win.figure(sec, "signalDbm") === "", 2000);
        win.check(win.figure(sec, "rttMs") === "" && win.keys.filter(k => win.cell(sec, k).visible).map(at).join(" ") === ["0,0", right + ",0", "0," + row, right + "," + row, "0," + 2 * row].join(" "),
                  "figures: one with no source is not there and leaves no hole");
        win.wait(300);
        const st = win.stepsOf(() => { cm.pinned = win.full; }, 600);
        win.check(st.side === 1 && win.figure(sec, "linkMbps") === "867 Mbit/s" && win.keys.every((k, i) => win.cell(sec, k) === cells[i]), "figures: those that come are ONE step of the height (" + st.side + ")");

        // the link is lost: the totals stand, nothing live is shown as if it were
        const h = sec.implicitHeight;
        cm._apply({ event: "lost" });
        win.wait(60);
        const t2 = win.keys.map(k => win.figure(sec, k)).join("|");
        win.check(t2 === "–|–|3|–|41|–|–|–" && sec.implicitHeight === h, "figures: a lost link leaves the totals, the height stays: " + t2);
        const line = win.findShown(sec, "castLine");
        win.check(line.text === "Reconnecting…", "figures: ... and the state line says so (" + line.text + ")");
        cm._apply({ event: "retry", n: 1 });
        for (const s of ["scanning", "connecting", "negotiating", "streaming"])
            cm._apply({ event: "state", state: s });
        win.until(() => win.figure(sec, "fps") === "30 fps", 2000);
        win.check(win.figure(sec, "fps") === "30 fps" && !!win.textLike(sec, "reconnected once"), "figures: the stream is back: the figures and \"reconnected once\"");
    }

    function run(): void {
        win.wait(1800);                                   // the tiles are dealt in, then held (parked)

        // ---- off
        win.check(win.count(popup, "castChip") === 0 && win.symbols(popup) === 0, "off: no chip, no cast mark anywhere in the popup (a census)");
        popup.selected = "eDP-1";
        win.until(() => !!sideLoader.item && sideLoader.item.ok, 1000);
        win.check(!!sideLoader.item && win.count(sideLoader.item, "castFigures") === 0, "off: no figures in a display's detail (a census)");
        popup.selected = "";
        win.wait(300);
        const h0 = popup.implicitHeight;
        win.grab("off_a.png");
        svc.cast = cm;                                    // a cast service is there, the config still says false
        svc.popupOpen = true;
        win.wait(400);
        win.check(win.scans === 0 && svc.castEnabled === false && svc.castDevices.length === 0, "off: a cast service and the view open: no scan, no devices (" + win.scans + ")");
        win.check(win.count(popup, "castChip") === 0 && popup.implicitHeight === h0, "off: still no chip, the popup's height is the same (" + popup.implicitHeight + ")");
        win.grab("off_b.png");

        // ---- chip: the config turns it on, the scan runs, ONE chip
        let st = win.stepsOf(() => { svc.castConfig = true; }, 700);
        win.check(win.scans === 1 && svc.castDevices.length === 2, "chip: the scan ran once and found two devices (" + win.scans + ")");
        win.check(win.count(popup, "castChip") === 1 && win.chip().deviceName === win.tvName, "chip: ONE chip, for the capable TV (the phone has none)");
        win.check(popup.implicitHeight === h0 + popup.style.castRowHeight, "chip: the parked row's room is reserved (" + (popup.implicitHeight - h0) + " px)");
        win.check(st.popup === 1, "chip: implicitHeight changed in exactly ONE step (" + st.popup + ")");

        // ---- confirm
        const lap0 = win.canvas.restRect("eDP-1"), ph = popup.implicitHeight;
        const chip = win.chip();
        win.click(chip);
        win.wait(150);
        const bt = win.findShown(popup, "castButton");
        win.check(chip.confirming && !!bt, "confirm: a click turns the chip into its confirm step");
        const rowW = win.canvas.width - 2 * popup.style.canvasPad;
        win.check(chip.width === rowW && chip.height >= 56, "confirm: it takes the parked row (" + chip.width + " x " + chip.height + ")");
        win.check(!!win.textLike(popup, "Pairing can fail and drop Wi-Fi for a few seconds."), "confirm: the honest line about the pairing is there");
        win.check(popup.implicitHeight === ph && JSON.stringify(win.canvas.restRect("eDP-1")) === JSON.stringify(lap0), "confirm: nothing under it moved (the height and the laptop's tile)");
        win.check(!!bt && bt.y + bt.height <= chip.height && bt.x + bt.width <= chip.width, "confirm: the Cast button is inside the chip");
        // leaving puts it back
        tc.mouseMove(win.contentItem, 4, 4);
        win.wait(200);
        win.check(!chip.confirming, "confirm: leaving the chip cancels it");
        win.click(chip);
        win.wait(150);
        win.check(chip.confirming && popup.handleEscape() === true && !chip.confirming, "confirm: Escape puts it back (and is taken)");
        win.check(popup.handleEscape() === false, "confirm: the next Escape is not taken (nothing is open)");

        // ---- connect: the cast's words in the chip, no tile yet, no keep prompt
        cm.script("ok");
        cm.stepMs = 250;
        win.click(chip);
        win.wait(150);
        const bt2 = win.findShown(popup, "castButton");
        win._samples = [];
        sampler.running = true;
        win.click(bt2);
        const seen = {};
        let tileEarly = false;
        const hConn = popup.implicitHeight;
        let hStable = true;
        for (let i = 0; i < 100 && svc.castPhase !== "streaming"; i++) {
            const t = chip.status;
            if (t !== "")
                seen[t] = true;
            if (svc.castPhase !== "streaming" && win.canvas.tileItem("LARES-CAST-1"))
                tileEarly = true;
            if (svc.castPhase !== "streaming" && popup.implicitHeight !== hConn)
                hStable = false;
            win.wait(20);
        }
        win.check(!!seen["Preparing…"] || !!seen["Connecting…"], "connect: the chip says what is going on: " + JSON.stringify(Object.keys(seen)));
        win.check(!tileEarly, "connect: the TV is no tile until the stream is up");
        win.check(hStable, "connect: the popup does not change size while it connects");
        win.check(svc.phase === "idle" && svc.postedToasts.length === 0, "connect: no keep prompt, no toast (phase " + svc.phase + ")");

        // ---- tile
        win.until(() => svc.castPhase === "streaming", 4000);
        win.wait(400);
        sampler.running = false;
        let tileSteps = 0;
        for (let i = 1; i < win._samples.length; i++)
            if (win._samples[i][0] !== win._samples[i - 1][0])
                tileSteps++;
        const tile = win.canvas.tileItem("LARES-CAST-1");
        win.check(!!tile && tile.cast === true && tile.label === win.tvName, "tile: the TV is a normal tile with its name (" + (tile ? tile.label : "none") + ")");
        win.check(!!tile && win.symbols(tile) >= 1, "tile: the cast mark is drawn in its corner");
        win.check(win.count(popup, "castChip") === 0, "tile: the chip is gone");
        win.check(win.canvas._rowH === 0 && tileSteps === 1 && svc.phase === "idle", "tile: the parked row went in ONE step of implicitHeight, from the click to the tile (" + tileSteps + ")");
        win.check(!!win.canvas.tileItem("eDP-1") && win.canvas.tileItem("eDP-1").carry.cy > tile.carry.cy, "tile: placed ABOVE the laptop");

        // ---- detail
        win.click(tile);
        win.until(() => popup.secondaryOpen && popup.secondaryKey === "LARES-CAST-1", 2000);
        const sec = sideLoader.item as DisplaySettings;
        sec.secondaryKey = popup.secondaryKey;
        win.wait(300);
        const line = sec ? win.findShown(sec, "castLine") : null;
        win.check(!!line && line.text.indexOf("Casting · 1920 × 1080 @ 30 fps") === 0, "detail: the state line with the mode (" + (line ? line.text : "none") + ")");
        win.check(!!sec && !!win.findShown(sec, "stopCasting"), "detail: Stop casting");
        win.check(!!sec && !win.findShown(sec, "brightnessSlider") && !!win.textLike(sec, "Mirror the laptop"), "detail: no brightness, Mirror stays");
        win.check(!!sec && !win.textLike(sec, "Bit depth") && !win.textLike(sec, "Variable refresh") && !win.textLike(sec, "SDR"), "detail: no bit depth, no VRR, no colour blocks");
        // (the user's cast, 2026-11-23: resolution stood twice, and a rotation staged an Apply that changed nothing on the TV; ARM castdisplayrows)
        win.check(!!sec && !!win.findShown(sec, "castRes") && !win.findShown(sec, "resolutionDropdown") && !win.textLike(sec, "Rotation") && !win.textLike(sec, "Refresh"),
                  "detail: ONE resolution, the stream's; no Refresh and no Rotation of a display that is a stream");
        win.check(!!sec && !win.findShown(sec, "applyToStream"), "detail: no Apply to stream while nothing is changed");
        const ups0 = win.ups;
        st = win.stepsOf(() => { sec.setQ("fps", 60); }, 500);
        const ap = win.findShown(sec, "applyToStream");
        win.check(!!ap && st.side === 1, "detail: a changed quality offers Apply to stream, the side popup's height steps once (" + st.side + ")");
        win.check(win.ups === ups0 && svc.castPhase === "streaming", "detail: nothing restarted before the button");
        win.click(ap);
        win.until(() => svc.castPhase === "restarting", 600);
        win.until(() => svc.castPhase === "streaming", 5000);
        win.wait(200);
        win.check(win.ups === ups0 + 1 && svc.castQualityOf("LARES-CAST-1").fps === 60 && !win.findShown(sec, "applyToStream"), "detail: Apply to stream restarted the stream ONCE and saved the quality (" + (win.ups - ups0) + ")");

        // ---- figures
        win.figures(sec);

        // ---- stop
        win.click(win.findShown(sec, "stopCasting"));
        win.until(() => svc.castPhase === "idle", 5000);
        win.wait(400);
        win.check(!win.canvas.tileItem("LARES-CAST-1") || !win.canvas.tileItem("LARES-CAST-1").visible, "stop: the TV's tile is gone");
        win.check(win.count(popup, "castChip") === 1 && !popup.secondaryOpen, "stop: the chip is back and the detail is closed");
        win.check(cm.figures.holds === 0 && cm.stats === null, "figures: released with the cast's detail, nothing published any more (holds " + cm.figures.holds + ")");

        // ---- failure: the reason in the chip, then the chip is back
        cm.script("cancelled");
        svc.castKeeper.noticeMs = 900;
        const chip2 = win.chip();
        win.click(chip2);
        win.wait(150);
        win.click(win.findShown(popup, "castButton"));
        win.until(() => chip2.notice !== "", 5000);
        win.check(chip2.notice === "Cancelled on the TV" && !!win.textLike(chip2, "Cancelled on the TV"), "failure: the chip says why (" + chip2.notice + ")");
        win.check(win.count(popup, "castChip") === 1 && svc.castPhase === "idle", "failure: the output is closed, the chip stays");
        win.until(() => chip2.notice === "", 3000);
        win.check(chip2.notice === "" && !!win.textLike(chip2, win.tvName), "failure: after its time the chip is back with the TV's name");
    }
    Timer {
        interval: 200
        running: true
        onTriggered: {
            // a step that throws (an armed copy takes away what it reads) is a failed check, not a run with no result
            try {
                win.run();
            } catch (e) {
                win.check(false, "a step threw: " + e);
            }
            console.log("PU RESULT " + (win.bad === 0 ? "PASS" : "FAIL") + " (" + (win.total - win.bad) + " of " + win.total + ")");
            Qt.quit();
        }
    }
}
