pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bridge"
import "modules/bridge/data"

// =============================================================================
// bridge_popup_probe.qml -- the bridge's popup on the REAL BridgePopup, the REAL BridgeService (not live: nothing runs, the scenarios'
// lines go through the real parser, every action is recorded in `calls`), in a window, driven with REAL synthetic input through the
// window (QtTest: mouseClick, mouseWheel with DIAGONAL deltas, so a handler on the wrong axis cannot pass). Each check prints
// `BP ok|FAIL <id>: <what>`; the last line is `BRIDGE_POPUP RESULT PASS|FAIL (<n>/<n> checks)`. Runner: tools/dev/bridge_popup_probe.sh.
//
//   A  scenarios   none -> the pairing screen, asleep -> the asleep screen, wired -> the home screen with its six tiles
//   B  tiles       a tile click reaches the service; a tile that cannot act calls nothing and its tip carries the tool's `why`
//   C  the page    the Mirror tile opens the page (service.page), a mode is a wish the tool answers, Start calls `mirror` with the
//                  chosen mode, a real click lands on the page's button AFTER the morph, Stop stops it; Mirror with Record on is the
//                  popup's cast (castStart recording), never scrcpy's window
//   D  the swipe   its role is latched at the first scrub: on a page the sideways wheels scrub the page back and the stage does not
//                  turn; at home they turn the phone (flipping rises, a commit lands on the back); a zero delta ends the gesture; a
//                  vertical-dominant wheel does neither
//   E  escape      the menu, then the page, then false -- one thing a press; a committed back is not started again under itself
//   F  input       after a full turn to the back and to the front again a real click on a tile still works
//   K  details     "Details" in the device menu opens the device's sheet as a page; Escape goes back; the back carries no item
//   L  the light   a pointer that comes in far from the light: the light chases it (no jump), catches it, then follows at once
//   G  keys        a click in the body's power zone presses the key when `can.key.ok`, nothing when not (the zone's tip says why)
//   H  drop        files dropped go to the current device when it can receive, else nothing is asked
//   I  the open     a content shown (not parked) plays ONE full turn when the config says so, a parked one plays nothing, a prewarm
//                   only draws the body's pipelines
// The runner holds the log to no warning that names a bridge file.
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    property int checks: 0
    property int fails: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("BP " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }

    TestCase {
        id: tc
        name: "bp"
        when: false
    }

    Window {
        id: win
        visible: true
        width: 320
        height: 664
        color: Theme.surface

        BridgeService {
            id: svc
            live: false
            scenario: "none"
            mockLineMs: 0
            mockStepMs: 0
            mockAnswerMs: 0
        }
        BridgePopup {
            id: popup
            anchors.fill: parent
            service: svc
            flipOnOpen: false
        }
    }

    property bool sawFlip: false
    Connections {
        target: popup.stage
        function onFlippingChanged(): void {
            if (popup.stage.flipping)
                probe.sawFlip = true;
        }
    }

    // ---- helpers ---------------------------------------------------------------------------------------------------------
    function findAll(root: Item, pred: var, out: var): var {
        if (pred(root))
            out.push(root);
        const kids = root.children;
        for (let i = 0; i < kids.length; i++)
            probe.findAll(kids[i], pred, out);
        return out;
    }
    function find(pred: var): Item {
        const all = probe.findAll(popup, pred, []);
        return all.length > 0 ? all[0] : null;
    }
    function shown(it: Item): bool {
        for (let p = it; p; p = p.parent)
            if (p.visible === false)
                return false;
        return true;
    }
    function textItem(s: string): Item {
        return probe.find(it => it.text === s && it.font !== undefined && probe.shown(it));
    }
    function button(s: string): Item {
        return probe.find(it => it.text === s && "accent" in it && probe.shown(it));
    }
    // a home tile by its id (its label can change: an armed Ring says Hold)
    function tileId(id: string): Item {
        const all = probe.findAll(popup, it => "spec" in it && it.spec && it.spec.id === id && "tileSize" in it, []);
        return all.length > 0 ? all[0] : null;
    }
    function tile(label: string): Item {
        return probe.find(it => it.label === label && "actState" in it && probe.shown(it));
    }
    function tiles(): var {
        return probe.findAll(popup, it => "actState" in it && "tileSize" in it && probe.shown(it), []);
    }
    function zone(name: string): Item {
        return probe.find(it => it.modelData === name && "box" in it);
    }
    function click(it: Item): void {
        const p = it.mapToItem(win.contentItem, it.width / 2, it.height / 2);
        tc.mouseClick(win.contentItem, p.x, p.y);
    }
    // sideways two-finger events, diagonal on purpose; the fingers' share is n * 80 of the reader's 900 units
    function swipe(n: int, dir: int): void {
        for (let i = 0; i < n; i++)
            tc.mouseWheel(win.contentItem, 160, 300, 80 * dir, 20);
    }
    function lift(): void {
        tc.mouseWheel(win.contentItem, 160, 300, 0, 0);
    }
    function calls(): var {
        return svc.calls;
    }
    function lastCall(): var {
        const c = svc.calls;
        return c.length > 0 ? c[c.length - 1] : null;
    }
    function callsOf(action: string): var {
        return svc.calls.filter(c => c.action === action);
    }
    property int mark: 0
    function setMark(): void {
        probe.mark = svc.calls.length;
    }
    function since(): var {
        return svc.calls.slice(probe.mark);
    }

    // ---- the sequencer -----------------------------------------------------------------------------------------------------
    // do(label, fn): run once. until(label, cond, ms): poll every tick; a timeout is a failed check naming the thing.
    // keyClick / mouseClick run the event loop, so the driver is stopped around every step.
    property var steps: []
    property int at: 0
    property double since0: 0
    function act(label: string, fn: var): void {
        probe.steps.push({ kind: "do", label: label, fn: fn });
    }
    function until(label: string, cond: var, ms: int): void {
        probe.steps.push({ kind: "until", label: label, fn: cond, ms: ms || 6000 });
    }
    function pause(ms: int): void {
        probe.steps.push({ kind: "pause", label: "pause", ms: ms });
    }
    function tick(): void {
        if (probe.at >= probe.steps.length) {
            probe.finish();
            return;
        }
        const s = probe.steps[probe.at];
        if (s.kind === "do") {
            try {
                s.fn();
            } catch (e) {
                probe.check("run", false, "step '" + s.label + "' threw: " + e);
            }
            probe.at++;
            probe.since0 = 0;
        } else if (s.kind === "pause") {
            if (probe.since0 === 0)
                probe.since0 = Date.now();
            if (Date.now() - probe.since0 >= s.ms) {
                probe.at++;
                probe.since0 = 0;
            }
        } else {
            if (probe.since0 === 0)
                probe.since0 = Date.now();
            let ok = false;
            try {
                ok = !!s.fn();
            } catch (e) {
                ok = false;
            }
            if (ok) {
                probe.at++;
                probe.since0 = 0;
            } else if (Date.now() - probe.since0 > s.ms) {
                probe.check("wait", false, "timed out waiting for: " + s.label);
                probe.at++;
                probe.since0 = 0;
            }
        }
    }
    Timer {
        id: driver
        interval: 25
        repeat: true
        running: false
        onTriggered: {
            driver.stop();
            probe.tick();
            if (!probe.done)
                driver.start();
        }
    }
    property bool done: false
    function finish(): void {
        if (probe.done)
            return;
        probe.done = true;
        console.log("BRIDGE_POPUP RESULT " + (probe.fails === 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
        quitter.start();
    }
    // never from Component.onCompleted: nothing is connected to the engine's quit yet
    Timer {
        id: quitter
        interval: 50
        onTriggered: Qt.quit()
    }

    function scenario(name: string, kind: string): void {
        probe.act("scenario " + name, () => {
            svc.scenario = name;
        });
        probe.until("the " + kind + " screen for " + name, () => svc.scenario === name && popup.screenFace.kind === kind && !popup.screenFace.morphing, 5000);
        probe.pause(120);
    }

    function build(): void {
        // ---- A: the screens ----------------------------------------------------------------------------------------------
        probe.until("the window is up", () => win.width > 0 && popup.stage.screenRect.width > 0 && svc.ready, 8000);
        probe.act("A1", () => {
            probe.check("A1", popup.screenFace.kind === "pairing" && probe.textItem("No phone paired") !== null, "scenario none shows the pairing screen (kind " + popup.screenFace.kind + ")");
        });
        probe.scenario("asleep", "asleep");
        probe.act("A2", () => {
            probe.check("A2", probe.textItem("Not in reach") !== null && probe.button("Look again") !== null, "scenario asleep shows the asleep screen");
        });
        probe.scenario("wired", "home");
        probe.act("A3", () => {
            const t = probe.tiles();
            const labels = t.map(x => x.label).sort().join(",");
            probe.check("A3", t.length === 6 && labels === "Clipboard,Files,Mirror,Ring,Send,Shot", "scenario wired shows the home screen with its six tiles (" + labels + ")");
            probe.check("A4", probe.textItem("On the cable") !== null, "the state line says how the phone is linked");
        });
        // the facts of the back are asked once, from the open (never from a getter)
        probe.until("the facts were asked and arrived", () => probe.callsOf("facts").length >= 1 && svc.current !== null && svc.current.facts !== null, 4000);
        probe.act("A5", () => {
            probe.check("A5", probe.callsOf("facts").length === 1 && svc.current.facts !== null, "the back's facts were asked once and arrived");
        });

        // ---- I: the open ------------------------------------------------------------------------------------------------
        probe.act("I1 park", () => {
            probe.sawFlip = false;
            popup.parked = true;
            popup.flipOnOpen = true;
            popup._shown = false;
        });
        probe.pause(300);
        probe.act("I1", () => {
            probe.check("I1", !probe.sawFlip && !popup.stage.flipping, "a parked content plays no turn");
            popup.parked = false;
        });
        probe.until("the open's turn plays", () => probe.sawFlip, 3000);
        probe.until("and lands on the front", () => !popup.stage.flipping && popup.stage.face === "front", 6000);
        probe.act("I2", () => {
            probe.check("I2", probe.sawFlip && popup.stage.face === "front", "shown, it plays one full turn and lands where it started");
            probe.sawFlip = false;
            popup.prewarm = true;
            popup._shown = false;
            popup.parked = true;
        });
        probe.act("I3 unpark", () => {
            popup.parked = false;
        });
        probe.pause(400);
        probe.act("I3", () => {
            probe.check("I3", !probe.sawFlip && !popup.stage.flipping, "a prewarm draws the pipelines and turns nothing");
            popup.prewarm = false;
            popup.flipOnOpen = false;
        });

        // ---- B: the tiles ------------------------------------------------------------------------------------------------
        probe.act("B1 click", () => {
            probe.setMark();
            probe.click(probe.tile("Shot"));
        });
        probe.until("a shot call", () => probe.since().some(c => c.action === "shot"), 3000);
        probe.act("B1", () => {
            const c = probe.since().filter(x => x.action === "shot");
            probe.check("B1", c.length === 1 && c[0].key === svc.currentKey, "a click on Shot (can.shot.ok) asks the service once for the current device");
        });
        probe.act("B2 click", () => {
            probe.setMark();
            const clip = probe.tile("Clipboard");
            probe.check("B2a", clip.enabledLook === false && !svc.current.can.clip.ok, "the Clipboard tile looks unavailable where the tool says it cannot");
            probe.click(clip);
            probe.click(probe.tile("Ring"));
        });
        probe.pause(250);
        probe.act("B2", () => {
            const clip = probe.tile("Clipboard"), ring = probe.tile("Ring");
            probe.check("B2", probe.since().length === 0, "a click on a tile that cannot act calls nothing (" + probe.since().map(c => c.action).join(",") + ")");
            const why = svc.current.can.clip.why;
            probe.check("B3", why !== "" && clip.tip.indexOf(why) >= 0 && ring.tip.indexOf(svc.current.can.ring.why) >= 0, "its tip carries the tool's own why ('" + clip.tip + "')");
        });

        // the pointer resting on a tile that cannot act: its tip opens in the popup's overlay and says why
        probe.act("B4 hover", () => {
            const t = probe.tile("Clipboard");
            const p = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            tc.mouseMove(win.contentItem, p.x - 8, p.y - 8);
            tc.mouseMove(win.contentItem, p.x, p.y);
        });
        probe.until("the tip opens", () => probe.findAll(popup, it => "_open" in it && "overlayItem" in it && it._open === true, []).length > 0, 4000);
        probe.act("B4", () => {
            const tips = probe.findAll(popup, it => "_open" in it && "overlayItem" in it && it._open === true, []);
            probe.check("B4", tips.length >= 1 && tips.some(x => x.text.indexOf(svc.current.can.clip.why) >= 0), "hovering it opens its tip in the overlay, with the tool's why");
            // (a synthetic pointer sends no hover-leave offscreen: closing a tip is judged in the real shell, not here)
            for (let i = 0; i < 6; i++)
                tc.mouseMove(win.contentItem, 5 + i * 9, 5 + i * 9);
        });

        // ---- C: the Mirror page --------------------------------------------------------------------------------------------
        probe.act("C1 click", () => {
            probe.click(probe.tile("Mirror"));
        });
        probe.until("the page is open and landed", () => svc.page === "mirror" && !popup.screenFace.morphing && probe.button("Start") !== null, 5000);
        probe.act("C1", () => {
            const b = probe.button("Start");
            const p = b.mapToItem(win.contentItem, 0, 0);
            probe.check("C1", p.x >= 0 && p.y >= 0 && p.x + b.width <= win.width && p.y + b.height <= win.height && b.enabled, "the Mirror page is open (service.page) and its Start button is on screen and enabled");
        });
        probe.act("C2 click", () => {
            // the modes are icons since 2026-11-19 (each named by its tip): Camera's
            probe.click(probe.textItem("\u{F0100}"));
        });
        probe.until("the mode landed in the device's prefs", () => svc.current.prefs.mode === "camera", 4000);
        probe.act("C2", () => {
            const s = probe.callsOf("set").filter(c => c.args.name === "mode");
            probe.check("C2", s.length === 1 && s[0].args.value === "camera", "a click on Camera is one setPref(mode, camera), read back from the device's prefs");
        });
        probe.act("C3 click", () => {
            probe.setMark();
            probe.click(probe.button("Start"));
        });
        probe.until("a mirror call", () => probe.since().some(c => c.action === "mirror"), 3000);
        probe.act("C3", () => {
            const c = probe.since().filter(x => x.action === "mirror");
            probe.check("C3", c.length === 1 && c[0].args.mode === "camera", "Start (a real click AFTER the morph) calls mirror with the chosen mode (" + JSON.stringify(c[0] ? c[0].args : null) + ")");
        });
        probe.until("the button became Stop", () => probe.button("Stop") !== null, 3000);
        probe.act("C4 click", () => {
            probe.setMark();
            probe.click(probe.button("Stop"));
        });
        probe.until("a stop call", () => probe.since().some(c => c.action === "stop"), 3000);
        probe.until("the button is Start again", () => probe.button("Start") !== null, 3000);
        probe.act("C4", () => {
            probe.check("C4", probe.since().filter(c => c.action === "stop").length === 1, "Stop stops the job of this device and the button is Start again");
            svc.setPref(svc.currentKey, "mode", "mirror");
            svc.setPref(svc.currentKey, "record", true);
        });
        probe.until("Mirror with Record on", () => svc.current.prefs.mode === "mirror" && svc.current.prefs.record === true && probe.button("Start") !== null, 4000);
        probe.act("C5 click", () => {
            probe.setMark();
            probe.click(probe.button("Start"));
        });
        probe.until("a cast or a mirror call", () => svc.castKey !== "" || probe.since().some(c => c.action === "mirror"), 3000);
        probe.act("C5", () => {
            probe.check("C5", probe.since().filter(c => c.action === "mirror").length === 0 && svc.castKey === svc.currentKey && svc.castMode === "mirror" && svc.castRecording === true,
                        "with Record on, Start on Mirror casts in the popup (castStart, recording; no scrcpy window: " + JSON.stringify(probe.since().map(c => c.action)) + ")");
            svc.castStop();
            svc.setPref(svc.currentKey, "record", false);
            svc.page = "mirror";
        });
        probe.until("back on the Mirror page, Record off", () => svc.page === "mirror" && !popup.screenFace.morphing && svc.current.prefs.record === false && probe.button("Start") !== null, 5000);

        // ---- D: the swipe's role ---------------------------------------------------------------------------------------------
        // on the page: the page scrubs back, the phone does not turn
        probe.act("D1 swipe", () => {
            probe.swipe(5, 1);
        });
        probe.pause(150);
        probe.act("D1", () => {
            probe.check("D1", popup.swipeGestureActive && popup.screenFace.morphing && popup.screenFace._m.scrub === true, "sideways wheels on a page scrub the page back under the fingers");
            probe.check("D2", popup.stage.flipping === false && popup.stage.face === "front", "the stage does not turn while a page scrubs (flipping " + popup.stage.flipping + ")");
        });
        probe.act("D3 lift", () => {
            probe.lift();
        });
        probe.until("the gesture ended and the page went", () => !popup.swipeGestureActive && svc.page === "" && !popup.screenFace.morphing, 4000);
        probe.act("D3", () => {
            probe.check("D3", svc.page === "" && popup.stage.face === "front" && popup.stage.flipping === false, "a lift past a third commits the back: the home screen, the phone still on its front");
        });
        // a stray vertical-dominant wheel does neither
        probe.act("D4 vertical", () => {
            for (let i = 0; i < 4; i++)
                tc.mouseWheel(win.contentItem, 160, 300, 10, -90);
            tc.mouseWheel(win.contentItem, 160, 300, 0, -120);
        });
        probe.pause(150);
        probe.act("D4", () => {
            probe.check("D4", !popup.swipeGestureActive && !popup.screenFace.morphing && popup.stage.flipping === false && popup.stage.face === "front", "a vertical-dominant wheel starts neither a back nor a turn");
            probe.lift();
        });
        // at home: the phone turns
        probe.act("D5 swipe", () => {
            probe.swipe(5, 1);
        });
        probe.until("the body turns under the fingers", () => popup.stage.flipping, 3000);
        probe.act("D5", () => {
            probe.check("D5", popup.swipeGestureActive && popup.stage.face === "front", "at home the same wheels turn the phone (flipping rises; the face is still the front under the fingers)");
        });
        probe.act("D6 lift", () => {
            probe.lift();
        });
        probe.until("the turn landed on the back", () => popup.stage.face === "back" && !popup.stage.flipping, 6000);
        probe.act("D6", () => {
            probe.check("D6", !popup.swipeGestureActive, "the lift commits the half turn and ends the gesture: face back");
        });

        // ---- F: input after a full turn ---------------------------------------------------------------------------------------
        // the other way home: the reverse swipe
        probe.act("F1 swipe", () => {
            probe.swipe(5, -1);
        });
        probe.until("the body turns back", () => popup.stage.flipping, 3000);
        probe.act("F1 lift", () => {
            probe.lift();
        });
        probe.until("the turn landed on the front", () => popup.stage.face === "front" && !popup.stage.flipping, 6000);
        probe.pause(150);
        probe.act("F2 click", () => {
            probe.setMark();
            probe.click(probe.tile("Shot"));
        });
        probe.until("a shot call after the turns", () => probe.since().some(c => c.action === "shot"), 3000);
        probe.act("F2", () => {
            probe.check("F2", probe.since().filter(c => c.action === "shot").length === 1, "after a full turn to the back and to the front a real click on a tile still works");
        });

        // ---- E: Escape ---------------------------------------------------------------------------------------------------------
        probe.act("E1 open", () => {
            popup.screenFace.openPage("mirror");
        });
        probe.until("the page landed", () => svc.page === "mirror" && !popup.screenFace.morphing, 5000);
        probe.act("E1", () => {
            popup.openMenu();
            probe.check("E1a", popup.deviceMenu.open, "the device menu is open over the page");
            const r = popup.handleEscape();
            probe.check("E1", r === true && popup.deviceMenu.open === false && svc.page === "mirror", "Escape with a menu up closes the menu only (the page stays)");
        });
        probe.act("E2", () => {
            const r = popup.handleEscape();
            probe.check("E2", r === true, "Escape on a page goes back and the popup stays (returns true)");
        });
        probe.until("the page went home", () => svc.page === "" && !popup.screenFace.morphing, 4000);
        probe.act("E3", () => {
            probe.check("E3", popup.handleEscape() === false, "Escape at home lets the popup close (returns false)");
        });
        // a committed back is not started again under itself: the fingers that carry on, or the next stray wheel
        probe.act("E4 open", () => {
            popup.screenFace.openPage("mirror");
        });
        probe.until("the page landed again", () => svc.page === "mirror" && !popup.screenFace.morphing, 5000);
        probe.act("E4 swipe", () => {
            probe.swipe(5, 1);
            probe.lift();
            // the back is still playing out (its clock needs several frames): a new gesture now
            probe.swipe(3, 1);
        });
        probe.act("E4", () => {
            const m = popup.screenFace._m;
            probe.check("E4", popup.screenFace.backCommitted || m === null, "a committed back is not taken over by the fingers that carry on (no second back starts under the first)");
            probe.check("E4b", !popup.swipeGestureActive, "the stray wheels hold no gesture");
        });
        probe.until("the committed back landed", () => svc.page === "" && !popup.screenFace.morphing && !popup.swipeGestureActive, 5000);
        probe.act("E4 lift", () => {
            probe.lift();
        });
        probe.pause(150);

        // ---- K: the details live behind the device menu; the back carries nothing --------------------------------------------------
        probe.act("K1 pick", () => {
            probe.check("K0", popup.stage.back.length === 0, "the phone's back carries no item (the turn is a thing to play with)");
            popup.deviceMenu.detailsRequested();
        });
        probe.until("the details landed", () => popup.screenFace.page === "device" && !popup.screenFace.morphing, 5000);
        probe.act("K1", () => {
            probe.check("K1", probe.textItem("Details") !== null && probe.textItem("Keep wireless ready") !== null && svc.page === "",
                "\"Details\" in the device menu opens the device's sheet as a page of the screen (not a service page)");
            const r = popup.handleEscape();
            probe.check("K2", r === true, "Escape on the details goes back and the popup stays");
        });
        probe.until("the details went home", () => popup.screenFace.page === "" && !popup.screenFace.morphing, 4000);

        // ---- G: the body's keys -------------------------------------------------------------------------------------------------
        probe.act("G1 click", () => {
            probe.setMark();
            const z = probe.zone("power");
            probe.check("G0", z !== null && z.visible && z.on, "the power zone is there and enabled where can.key.ok");
            probe.click(z);
        });
        probe.until("a key call", () => probe.since().some(c => c.action === "key"), 3000);
        probe.act("G1", () => {
            const c = probe.since().filter(x => x.action === "key");
            probe.check("G1", c.length === 1 && c[0].args.name === "power", "a click in the power zone presses the power key (" + JSON.stringify(c[0] ? c[0].args : null) + ")");
        });
        probe.act("G2 click", () => {
            probe.setMark();
            probe.click(probe.zone("volup"));
        });
        probe.until("a volume call", () => probe.since().some(c => c.action === "key"), 3000);
        probe.act("G2", () => {
            const c = probe.since().filter(x => x.action === "key");
            probe.check("G2", c.length === 1 && c[0].args.name === "volup", "the rocker presses volup");
        });
        probe.scenario("wifi", "home");
        probe.act("G3 click", () => {
            probe.setMark();
            const z = probe.zone("power");
            probe.check("G3a", z.on === false && !svc.current.can.key.ok, "without adb the power zone is disabled");
            probe.click(z);
        });
        probe.pause(250);
        probe.act("G3", () => {
            probe.check("G3", probe.since().length === 0, "a click in a disabled zone calls nothing (" + probe.since().map(c => c.action).join(",") + ")");
            const why = svc.current.can.key.why;
            probe.check("G4", why !== "" && popup.stage.partTips.power.indexOf(why) >= 0, "its tip says the tool's why ('" + popup.stage.partTips.power + "')");
        });

        // ---- R: Ring is loud, so never by accident: a click arms it, a held press rings ---------------------------------------
        probe.act("R1 click", () => {
            probe.setMark();
            probe.check("R0", svc.current.can.ring.ok, "(Ring can act here)");
            probe.click(probe.tileId("ring"));
        });
        probe.pause(200);
        probe.act("R1", () => {
            probe.check("R1", probe.since().length === 0 && probe.tileId("ring").label === "Hold", "a click on Ring only arms it: it says Hold and nothing is asked (" + probe.since().map(c => c.action).join(",") + ")");
            probe.click(probe.tileId("ring"));
        });
        probe.pause(200);
        probe.act("R2 press", () => {
            probe.check("R2", probe.since().length === 0, "a second click rings nothing either");
            const t = probe.tileId("ring");
            const p = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            tc.mousePress(win.contentItem, p.x, p.y, Qt.LeftButton);
        });
        probe.pause(1500);
        probe.act("R3 release", () => {
            const t = probe.tileId("ring");
            const p = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
        });
        probe.pause(200);
        probe.act("R3", () => {
            const c = probe.since().filter(x => x.action === "ring");
            probe.check("R3", c.length === 1 && probe.tileId("ring").label === "Ring", "held while armed it rings once, and the tile is Ring again (" + c.length + " rings)");
            probe.setMark();
            const t = probe.tileId("ring");
            const p = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            tc.mousePress(win.contentItem, p.x, p.y, Qt.LeftButton);
        });
        probe.pause(1500);
        probe.act("R4 release", () => {
            const t = probe.tileId("ring");
            const p = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            tc.mouseRelease(win.contentItem, p.x, p.y, Qt.LeftButton);
        });
        probe.pause(200);
        probe.act("R4", () => {
            probe.check("R4", probe.since().filter(x => x.action === "ring").length === 0, "a held press that was not armed first rings nothing");
        });

        // ---- P: the unlock PIN on the Details page: a masked field that asks for the keys while open, Escape closes it before the
        // page, Save hands the PIN to the service and no PIN reaches `calls` ------------------------------------------------------
        probe.act("P1 open", () => {
            popup.screenFace.openPage("device");
        });
        probe.until("the Details page landed", () => popup.screenFace.page === "device" && !popup.screenFace.morphing && probe.textItem("Set") !== null, 5000);
        probe.act("P1 set", () => {
            probe.check("P0", !popup.screenFace.keysWanted, "the Details page wants no keys for itself while the field is shut (the popup's own ask, for a pointer that moved onto it, is M1's)");
            probe.click(probe.textItem("Set"));
        });
        probe.until("the field open", () => popup.screenFace.keysWanted, 2000);
        probe.act("P1", () => {
            const f = probe.find(it => it.echoMode === TextInput.Password && probe.shown(it));
            probe.check("P1", f !== null && popup.keyboardFocusRequest === "onDemand", "Set opens a masked field and the popup asks for the keys (" + popup.keyboardFocusRequest + ")");
            probe.check("P2", popup.handleEscape() === true && !popup.screenFace.keysWanted && popup.screenFace.page === "device", "Escape closes the field first and leaves the page open");
            probe.click(probe.textItem("Set"));
        });
        probe.until("the field open again", () => popup.screenFace.keysWanted, 2000);
        probe.act("P3 type", () => {
            probe.setMark();
            const f = probe.find(it => it.echoMode === TextInput.Password && probe.shown(it));
            f.forceActiveFocus();
            win.requestActivate();
            f.text = "4711";
            f.accepted();
        });
        probe.pause(200);
        probe.act("P3", () => {
            const c = probe.since().filter(x => x.action === "pin");
            probe.check("P3", c.length === 1 && c[0].args.op === "set" && JSON.stringify(svc.calls).indexOf("4711") < 0 && !popup.screenFace.keysWanted
                        && svc.current.pin === "set", "Return saves: one pin set, no PIN in `calls`, the field shut, the device now keeps a PIN (" + svc.current.pin + ")");
            popup.screenFace.goBack();
        });
        probe.until("home again", () => popup.screenFace.page === "" && !popup.screenFace.morphing, 4000);

        // ---- H: a drop ------------------------------------------------------------------------------------------------------------
        probe.scenario("wired", "home");
        probe.act("H1", () => {
            probe.setMark();
            popup.dropped(["/home/demo/a.jpg", "/home/demo/b.pdf"]);
        });
        probe.pause(150);
        probe.act("H1 check", () => {
            const c = probe.since().filter(x => x.action === "send");
            probe.check("H1", c.length === 1 && c[0].args.paths.length === 2, "a drop goes to the current device as one send of both files");
        });
        probe.scenario("error", "home");
        probe.act("H2", () => {
            probe.setMark();
            popup.dropped(["/home/demo/a.jpg"]);
        });
        probe.pause(150);
        probe.act("H2 check", () => {
            probe.check("H2", probe.since().length === 0 && !svc.current.can.send.ok, "a drop to a device that cannot receive asks nothing (the mark shakes)");
        });

        // ---- L: the light the pointer leads ----------------------------------------------------------------------------------------
        // a pointer that comes in far from the light does not take it there at once: the light sets off after it and catches it
        probe.scenario("wired", "home");
        probe.act("L in", () => {
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            tc.mouseMove(win.contentItem, o.x + 40, o.y + 60);
            tc.mouseMove(win.contentItem, o.x + 44, o.y + 66);
        });
        probe.until("the light is the pointer's", () => popup.stage._catch === 1 && Math.abs(popup.stage._slideX - popup.stage._aimX) < 0.02 && Math.abs(popup.stage._slideY - popup.stage._aimY) < 0.02, 4000);
        probe.act("L1", () => {
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            const sx = popup.stage._slideX, sy = popup.stage._slideY;
            tc.mouseMove(win.contentItem, o.x + 280, o.y + 590);
            tc.mouseMove(win.contentItem, o.x + 284, o.y + 596);
            const jumped = Math.hypot(popup.stage._slideX - sx, popup.stage._slideY - sy);
            const far = Math.hypot(popup.stage._aimX - sx, popup.stage._aimY - sy);
            probe.check("L1", far > 1 && jumped < 0.1 * far && popup.stage._catch < 1,
                "a pointer that comes in far from the light does not take the light there at once (moved " + jumped.toFixed(3) + " of " + far.toFixed(3) + ")");
        });
        probe.until("the light caught the pointer", () => popup.stage._catch === 1, 4000);
        probe.act("L2", () => {
            probe.check("L2", Math.abs(popup.stage._slideX - popup.stage._aimX) < 0.02 && Math.abs(popup.stage._slideY - popup.stage._aimY) < 0.02,
                "and catches it: the light stands where the pointer is");
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            tc.mouseMove(win.contentItem, o.x + 276, o.y + 590);
            probe.check("L3", popup.stage._catch === 1 && Math.abs(popup.stage._slideX - popup.stage._aimX) < 0.02, "a small move after that is followed at once");
        });

        // ---- M: free look ------------------------------------------------------------------------------------------------------------
        // Alt held with the pointer over the popup: the pointer's motion turns the phone; let go, it is back at its exact rest.
        probe.scenario("wired", "home");
        probe.until("M: at rest before the look", () => popup.stage.atRest, 6000);
        probe.act("M1", () => {
            // (QtTest's pointer carries no keyboard modifiers: the look is read from the KEY here; M10 is the motion's own path)
            popup.lookFromMotion = false;
            // the pointer comes to rest on the Mirror tile: a click there would open its page
            const t = probe.tile("Mirror");
            const c = t.mapToItem(win.contentItem, t.width / 2, t.height / 2);
            probe.lookAt = Qt.point(Math.round(c.x), Math.round(c.y));
            win.requestActivate();
            tc.mouseMove(win.contentItem, probe.lookAt.x - 10, probe.lookAt.y - 10);
            tc.mouseMove(win.contentItem, probe.lookAt.x, probe.lookAt.y);
            probe.check("M1", popup.keyboardFocusRequest === "onDemand", "a pointer that moved onto the popup: it asks for the keyboard (" + popup.keyboardFocusRequest + ")");
            probe.pointerAsks = [];
            probe.setMark();
            tc.keyPress(Qt.Key_Alt);
        });
        probe.pause(250);
        probe.act("M2", () => {
            const blank = probe.find(it => it.cursorShape === Qt.BlankCursor && it.hoverEnabled === true && probe.shown(it));
            probe.check("M2", popup.stage.lookHeld && popup.freeLooking && blank !== null && probe.pointerAsks.join(",") === "hold",
                "Alt down: the look is held, the pointer is blank over the phone, the owner is asked to hold its place (held=" + popup.stage.lookHeld + " blank=" + (blank !== null) + " asks=" + probe.pointerAsks.join(",") + ")");
            // a click while it is held reaches nothing (where the pointer rests: on the tile, the phone still face on)
            tc.mouseClick(win.contentItem, probe.lookAt.x, probe.lookAt.y);
            for (let i = 1; i <= 13; i++)
                tc.mouseMove(win.contentItem, probe.lookAt.x + i * 10, probe.lookAt.y + i * 3);
            const yaw = popup.stage._lookYaw, pitch = popup.stage._lookPitch;
            probe.check("M3", Math.abs(yaw + 130 / popup.stage.lookTurnPx) < 0.01 && Math.abs(pitch + 39 / popup.stage.lookTiltPx * 90) < 0.6 && popup.stage.flipping,
                "the pointer's way turns and tips the phone: 130 px right, 39 down -> yaw " + yaw.toFixed(3) + " turns, pitch " + pitch.toFixed(1) + " deg");
            probe.check("M4", probe.pointerAsks.filter(a => a === "home").length === 1, "past " + popup.stage.lookStrayPx + " px the owner is asked ONCE to put the pointer back (" + probe.pointerAsks.join(",") + ")");
        });
        probe.pause(150);
        probe.act("M5", () => {
            probe.check("M5", probe.since().length === 0 && popup.screenFace.page === "" && !popup.screenFace.morphing, "a click on a tile during the look asks the tool nothing and opens no page (" + probe.since().length + " calls, page '" + popup.screenFace.page + "')");
            tc.keyRelease(Qt.Key_Alt);
            probe.check("M6", !popup.stage.lookHeld && popup.stage.looking && probe.pointerAsks[probe.pointerAsks.length - 1] === "home",
                "Alt up: the look is let go, the phone is on its way back, the pointer is asked home (" + probe.pointerAsks.join(",") + ")");
        });
        probe.pause(1400);
        probe.act("M7", () => {
            const ax = popup.stage._axes;
            probe.check("M7", !popup.stage.looking && !popup.stage.flipping && popup.stage.face === "front" && ax.ex[0] === 1 && ax.ex[2] === 0 && ax.ez[2] === 1 && ax.ey[1] === 1
                        && popup.stage._lookYaw === 0 && popup.stage._lookPitch === 0 && popup.stage._lift === 0,
                "the phone is back on the face it showed, at its exact rest (looking=" + popup.stage.looking + " face=" + popup.stage.face + " ex=" + ax.ex + ")");
        });
        probe.until("M: cached again", () => popup.stage.atRest && popup.stage.body.cached, 4000);
        // more than half a turn round: it goes on to the nearest whole turn, the same face, never the long way back
        probe.act("M8", () => {
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            tc.mouseMove(win.contentItem, o.x + 20, o.y + 300);
            tc.mouseMove(win.contentItem, o.x + 24, o.y + 300);
            tc.keyPress(Qt.Key_Alt);
        });
        probe.pause(250);
        probe.act("M8 turn", () => {
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            const n = Math.round(0.62 * popup.stage.lookTurnPx / 8);
            for (let i = 1; i <= n; i++)
                tc.mouseMove(win.contentItem, o.x + 24 + i * 8, o.y + 300);
            probe.yawAtLift = popup.stage._lookYaw;
            tc.keyRelease(Qt.Key_Alt);
        });
        probe.pause(140);
        probe.act("M8 check", () => {
            const now = popup.stage._lookYawNow;
            probe.check("M8", probe.yawAtLift < -0.55 && popup.stage.looking && now < probe.yawAtLift - 0.01,
                "let go past half a turn (" + probe.yawAtLift.toFixed(2) + "): it runs ON to the whole turn, not back (now " + now.toFixed(2) + ")");
        });
        probe.pause(1400);
        probe.act("M9", () => {
            probe.check("M9", !popup.stage.looking && popup.stage.face === "front" && popup.stage._axes.ex[0] === 1, "and rests on the face it showed");
            // Alt read off a pointer motion: already down as the pointer comes in, and a release the popup never heard
            const o = popup.stage.mapToItem(win.contentItem, 0, 0);
            tc.mouseMove(win.contentItem, o.x + 150, o.y + 300);
            tc.mouseMove(win.contentItem, o.x + 156, o.y + 304);
            popup.lookFromMotion = true;
            popup.stage.pointerMoved(Qt.AltModifier);
        });
        probe.pause(200);
        probe.act("M10", () => {
            const held = popup.stage.lookHeld;
            popup.stage.pointerMoved(0);
            probe.check("M10", held && !popup.stage.lookHeld, "a motion that carries Alt holds the look, one that does not lets it go (held=" + held + ", then " + popup.stage.lookHeld + ")");
            // bridge.jsonc lookKey: Ctrl holds the look instead, and Alt does nothing
            svc.config.apply({ lookKey: "ctrl" });
            popup.stage.pointerMoved(Qt.AltModifier);
            probe.lookAlt = popup.stage.lookHeld;
            popup.stage.pointerMoved(Qt.ControlModifier);
        });
        probe.pause(200);
        probe.act("M11", () => {
            const held = popup.stage.lookHeld;
            popup.stage.pointerMoved(0);
            probe.check("M11", !probe.lookAlt && held && !popup.stage.lookHeld, "bridge.jsonc lookKey \"ctrl\": Ctrl holds the look, Alt does not (alt " + probe.lookAlt + ", ctrl " + held + ")");
            svc.config.apply({});
        });
        probe.pause(900);
    }
    property var pointerAsks: []
    property real yawAtLift: 0
    property bool lookAlt: false
    property point lookAt: Qt.point(0, 0)
    Connections {
        target: popup
        function onLookPointer(what: string): void {
            probe.pointerAsks.push(what);
        }
    }

    Component.onCompleted: {
        probe.build();
        startUp.start();
    }
    Timer {
        id: startUp
        interval: 500
        onTriggered: driver.start()
    }
    // a run that never ends is a failed run
    Timer {
        interval: 110000
        running: true
        onTriggered: {
            console.log("BP FAIL watchdog: the run did not finish (step " + probe.at + " of " + probe.steps.length + ")");
            probe.fails++;
            probe.checks++;
            probe.finish();
        }
    }
}
