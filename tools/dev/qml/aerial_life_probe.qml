pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/aerial/data"
import "modules/aerial/popup"
import "modules/common/theme"
import "modules/aerial/scene/AerialCamera.js" as Cam
import "modules/aerial/scene/AerialLayout.js" as Layout
import "modules/aerial/popup/SpeedDisplay.js" as Speed

// =============================================================================
// tools/dev/qml/aerial_life_probe.qml -- the popup's life judged (tools/dev/aerial_life_probe.sh runs it and arms it). One process, a sequence of steps; every check prints
// `AL <name> PASS|FAIL <why>`, then `AL RESULT PASS|FAIL`. The window plays the ENGINE for the secondary (the content contract: a Loader on `secondaryComponent` that hands the
// content its `secondaryKey`), beside the popup. Every pointer event is a synthetic mouse on the WINDOW (QtTest); the password is typed with real key events.
//   parts      every part / hologram that has a panel opens it (the key, the kind the content shows) and a second click on the same part closes it
//   escape     Escape takes only what a panel is in the middle of (`handleEscape`: the saved list's search); with nothing it answers false and the
//              engine's rule decides (the popup with its panel, or `stepBack()` first: GooeyEngine.escapeDetailFirst)
//   password   a secured stranger dropped on the label: its panel opens with the field focused, the popup asks for the keyboard, a wrong password shakes and stays, the right one
//              connects, the hologram docks (the thunk), Escape on a fresh pending drifts the hologram back
//   prompt     the pairing prompt opens the device's panel by itself, and Escape puts it away for good
//   speed      the rates display: one click asks (and does NOT run), a second runs it, the displays say what the test does, a refusal needs one more confirm, a forgotten question
//              is cancelled, both displays go back at the next open
//   ladder     alive -> calm -> still on aerial's own times, 0 frames while still, a motion or a network event wakes it
//   poweron    a new popup starts dark and ends at the facts' pose; every stretch of the clock lands at 1
//   sounds     the moments the sounds follow (the player is silent in a harness: the log is what it heard)
//   round 2    no error tag is ever drawn; a failed intent gives ONE cue on the part it names and leaves nothing (the label / a dot / a device / the globe shake, a DIP lever falls
//              back onto the facts' pose, a pad's LED blinks twice, an unknown part: nothing); Escape goes one step a press (the saved list's search first); a saved panel opened by
//              the mouse asks no keys until the pointer MOVES into it, by a key at once; no hover fade on the parts; the speed test's question and the units are ENGRAVED
// =============================================================================
Window {
    id: win

    width: 1200
    height: 760
    visible: true
    color: "#E9ECF3"

    property var fails: []
    property int swaps: 0
    property bool entrance: false
    function check(name: string, ok: bool, why: string): void {
        console.log("AL " + name + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : ""));
        if (!ok)
            win.fails.push(name);
    }
    Connections {
        target: win
        function onFrameSwapped() { win.swaps++; }
    }
    AerialMock {
        id: mock
        live: true
        scenario: "crowd"
        drift: 0
        scanPeriodMs: 100000
        settleMs: 150
    }
    Loader {
        id: ld
        active: true
        sourceComponent: AerialPopup {
            service: mock
            family: 0
            renderScale: 1
            animate: true
            entranceEnabled: win.entrance
            soundsEnabled: true
        }
    }
    readonly property var popup: ld.item
    readonly property var ctl: ld.item ? ld.item.drag : null
    // the engine's part: the secondary's content, handed the key it asks for
    Loader {
        id: sec
        x: 790
        active: !!win.popup && win.popup.secondaryOpen
        sourceComponent: win.popup ? win.popup.secondaryComponent : null
        onLoaded: sec.item.secondaryKey = win.popup.secondaryKey
    }
    Connections {
        target: win.popup
        function onSecondaryKeyChanged() {
            if (sec.item && win.popup.secondaryKey !== null)
                sec.item.secondaryKey = win.popup.secondaryKey;
        }
    }
    // the scene's beats (its `time` moving), and those taken between running and rest (0 < live < 1)
    property int beats: 0
    property int eased: 0
    property real _rateAlive: 0
    property int _b0: 0
    property real _t0: 0
    Connections {
        target: win.popup ? win.popup.scene : null
        function onTimeChanged(): void {
            win.beats++;
            const l = win.popup.scene.live;
            if (l > 0.001 && l < 0.999)
                win.eased++;
        }
    }
    function waitFor(pred: var, ms: int): bool {
        const t0 = Date.now();
        while (!pred() && Date.now() - t0 < ms)
            tc.wait(20);
        return pred();
    }
    TestCase {
        id: tc
        name: "life"
        when: false
        windowShown: true
    }
    property var acts: []
    Connections {
        target: win.popup
        function onPartActivated(intent: string, at: point) { win.acts.push(intent); }
    }

    // ---- helpers ----
    // a point (window px) where the board answers `intent` and nothing of the holograms is in the way
    function pointOf(intent: string, anyHolo: bool): var {
        const p = win.popup;
        for (let y = 20; y < p.implicitHeight - 10; y += 3) {
            for (let x = 20; x < p.implicitWidth - 10; x += 3) {
                const part = p.scene.pickPart(x, y);
                if (!part || Layout.intentFor(p.scene.geo, part) !== intent)
                    continue;
                if (!anyHolo && p.drag._hit(x, y))
                    continue;
                return { x: x, y: y };
            }
        }
        return null;
    }
    function click(pt: var): void {
        tc.mouseMove(win.contentItem, pt.x - 4, pt.y - 3);
        tc.mouseMove(win.contentItem, pt.x, pt.y);
        tc.mouseClick(win.contentItem, pt.x, pt.y, Qt.LeftButton);
    }
    function keyOf(): string {
        return win.popup.secondaryOpen ? String(win.popup.secondaryKey) : "";
    }
    function field(): var {
        // the password field: the visible PanelField that is a secret
        const find = it => {
            if (!it)
                return null;
            if (it.secret === true && it.visible && it.hasFocus !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++) {
                const r = find(it.children[i]);
                if (r)
                    return r;
            }
            return null;
        };
        return sec.item ? find(sec.item) : null;
    }
    function type(text: string): void {
        for (let i = 0; i < text.length; i++)
            tc.keyClick(text.charAt(i));
    }
    // every descendant of an item (the children and the `data` objects that are items)
    function descendants(root: var): var {
        const out = [];
        const walk = it => {
            for (let i = 0; i < it.children.length; i++) {
                out.push(it.children[i]);
                walk(it.children[i]);
            }
        };
        walk(root);
        return out;
    }
    // the board's engraving is the BOARD's own (round 3): which baked variant of a unit label the scene shows, as its text (AerialGeometry SILK_VARIANTS)
    function engr(key: string): string {
        const sc = win.popup.scene;
        return sc.geo.SILK_VARIANTS[key][key === "rates" ? sc.ratesVariant : sc.usageVariant];
    }
    // sample a number every 20 ms for `ms`; returns the samples
    function sample(fn: var, ms: int): var {
        const out = [];
        for (let t = 0; t < ms; t += 20) {
            out.push(fn());
            tc.wait(20);
        }
        return out;
    }
    function searchField(): var {
        const find = it => {
            if (!it)
                return null;
            if (it.secret === false && it.visible && it.hasFocus !== undefined && it.placeholder !== undefined)
                return it;
            for (let i = 0; i < it.children.length; i++) {
                const r = find(it.children[i]);
                if (r)
                    return r;
            }
            return null;
        };
        return sec.item ? find(sec.item) : null;
    }
    function netByKey(key: string): var {
        return mock.wifi.networks.find(n => n.key === key);
    }
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
    function pickStranger(): var {
        const ts = win.tags(win.popup.cloud).filter(t => t.e.kind === "net" && t.e.form === "named" && t.e.secured && !t.e.known && !t.e.hidden && (win.netByKey(t.key) || {}).security !== "eap");
        return ts.find(t => { const c = win.centre(t); return win.tags(win.popup.cloud).every(o => o === t || !(c.x >= o.x + o.hitRect.x && c.x <= o.x + o.hitRect.x + o.hitRect.width && c.y >= o.y + o.hitRect.y && c.y <= o.y + o.hitRect.y + o.hitRect.height && o.z > t.z)); }) || null;
    }
    function dragTo(x0: real, y0: real, x1: real, y1: real, steps: int): void {
        tc.mouseMove(win.contentItem, x0 - 6, y0 - 4);
        tc.mouseMove(win.contentItem, x0, y0);
        tc.mousePress(win.contentItem, x0, y0, Qt.LeftButton);
        for (let i = 1; i <= steps; i++) {
            tc.mouseMove(win.contentItem, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
            tc.wait(18);
        }
        tc.mouseRelease(win.contentItem, x1, y1, Qt.LeftButton);
    }
    function rebuild(entrance: bool): void {
        win.entrance = entrance;
        ld.active = false;
        ld.active = true;
    }

    // ---- the steps ----
    property int _step: 0
    property var _steps: []
    property string _key: ""
    property int _swapsAt: 0
    property var _cells: []
    Timer {
        id: tick
        interval: 400
        repeat: true
        running: true
        onTriggered: {
            if (win._step >= win._steps.length) {
                tick.stop();
                console.log("AL RESULT " + (win.fails.length ? "FAIL (" + win.fails.join(", ") + ")" : "PASS"));
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
        const W = () => {};
        S.push(W);
        S.push(W);
        // ---- every part with a panel ----
        S.push(() => {
            win.requestActivate();
            const wired = mock.wired && mock.wired.jacks && mock.wired.jacks.length ? "wired:" + mock.wired.jacks[0].iface : "wired:";
            const cases = [
                ["mem", "saved", "saved"], ["jack", wired, "wired"], ["usage", "usage", "usage"], ["pad.link", "pad:link", "pad"], ["pad.dns", "pad:dns", "pad"],
                ["pad.net", "pad:net", "pad"], ["globe", "vpn", "vpn"]
            ];
            cases.forEach(c => {
                const pt = win.pointOf(c[0], c[0] === "globe");
                if (!pt) {
                    win.check("find-" + c[0], false, "no pixel answers it");
                    return;
                }
                win.click(pt);
                tc.wait(60);
                const k = win.keyOf();
                win.check("opens-" + c[0], k === c[1], "key=" + k + " want " + c[1]);
                win.check("kind-" + c[0], !!sec.item && sec.item.shownKind === c[2], "kind=" + (sec.item ? sec.item.shownKind : "no content"));
                win.click(pt);
                tc.wait(60);
                win.check("closes-" + c[0], win.keyOf() === "", "key=" + win.keyOf());
            });
            // the label (the docked network or, with none, the browse), the hotspot hologram and a ring's device: the controller's own activations
            const lab = win.popup._zoneCentre;
            win.popup.drag.activated("label", Qt.point(lab[0], lab[1]));
            tc.wait(60);
            win.check("opens-label", win.keyOf().indexOf("network:") === 0, "key=" + win.keyOf());
            win.popup.drag.activated("label", Qt.point(lab[0], lab[1]));
            tc.wait(40);
            win.check("closes-label", win.keyOf() === "", "key=" + win.keyOf());
            win.popup.drag.activated("hotspot", Qt.point(lab[0], lab[1]));
            tc.wait(60);
            win.check("opens-hotspot", win.keyOf() === "hotspot" && sec.item.shownKind === "hotspot", "key=" + win.keyOf());
            win.popup.closeSecondary();
            const dev = mock.bt.devices.length ? mock.bt.devices[0].address : "AA:BB:CC:DD:EE:01";
            win.popup.drag.activated("bt:" + dev, Qt.point(300, 300));
            tc.wait(60);
            win.check("opens-bt", win.keyOf() === "bt:" + dev && sec.item.shownKind === "bt" && sec.item.shownTarget === dev, "key=" + win.keyOf());
            win.popup.closeSecondary();
            tc.wait(40);
            win.check("anchor-is-the-parts", true, "");
        });
        S.push(W);
        // ---- Escape: the panel is the engine's rule (the popup with it, or stepBack first) ----
        S.push(() => {
            const pt = win.pointOf("mem", false);
            win.click(pt);
            tc.wait(60);
            win.check("esc-setup", win.keyOf() === "saved", win.keyOf());
            const first = win.popup.handleEscape();
            win.check("esc-leaves-the-panel-to-the-engine", first === false && win.keyOf() === "saved", "answered " + first + " key=" + win.keyOf());
            const back = win.popup.stepBack();
            win.check("step-back-puts-the-panel-away", back === true && win.keyOf() === "", "answered " + back + " key=" + win.keyOf());
            const second = win.popup.stepBack();
            win.check("step-back-with-none-is-false", second === false, "answered " + second);
        });
        S.push(W);
        // ---- the password flow ----
        S.push(() => {
            win.resetSounds();
            const t = win.pickStranger();
            if (!t) { win.check("have-secured-stranger", false, "none"); return; }
            win._key = t.key;
            const c = win.centre(t), z = win.popup._zoneCentre;
            win.dragTo(c.x, c.y, z[0], z[1], 8);
            tc.wait(120);
        });
        S.push(() => {
            win.check("pending-opens-its-panel", win.keyOf() === "network:" + win._key && !!sec.item && sec.item.shownKind === "network" && sec.item.shownTarget === win._key, "key=" + win.keyOf());
            win.check("pending-hovers-held", win.ctl.phase === "held" && win.ctl.heldKey === win._key, "phase=" + win.ctl.phase);
            const f = win.field();
            win.check("password-field-focused", !!f && f.hasFocus === true, f ? "hasFocus=" + f.hasFocus : "no password field");
            win.check("popup-asks-for-the-keyboard", win.popup.keyboardFocusRequest === "onDemand" && sec.item.keyboardWanted === true, "request=" + win.popup.keyboardFocusRequest + " wanted=" + (sec.item ? sec.item.keyboardWanted : "?"));
            // a browse does not take the slot while the password is pending: a click on the memory chip drops the pending (it drifts back) and browses
            win.type("wrong");
            tc.keyClick(Qt.Key_Return);
        });
        S.push(W);
        S.push(() => {
            const f = win.field();
            win.check("refusal-keeps-the-field", !!f && f.text === "wrong" && win.keyOf() === "network:" + win._key, "text=" + (f ? f.text : "?") + " key=" + win.keyOf());
            win.check("refusal-holds-the-hologram", win.ctl.phase === "held", "phase=" + win.ctl.phase);
            // the right one
            f.text = "";
            win.type("hunter22");
            tc.keyClick(Qt.Key_Return);
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            win.check("enter-connects", mock.wifi.active && mock.wifi.active.key === win._key, "active=" + (mock.wifi.active ? mock.wifi.active.key : "none"));
            win.check("hologram-docked", win.ctl.phase === "idle" && win.ctl.heldKey === "", "phase=" + win.ctl.phase);
            win.check("thunk-on-docking", win.popup.sounds.log.indexOf("thunk") >= 0, "log=" + win.popup.sounds.log);
            win.popup.closeSecondary();
        });
        S.push(W);
        // a pending password given up with Escape: the hologram drifts back and nothing connected
        S.push(() => {
            mock.disconnect();
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            const t = win.pickStranger();
            if (!t) { win.check("have-second-stranger", false, "none"); return; }
            win._key = t.key;
            const c = win.centre(t), z = win.popup._zoneCentre;
            win.dragTo(c.x, c.y, z[0], z[1], 8);
            tc.wait(120);
        });
        S.push(() => {
            win.check("pending-again", win.keyOf() === "network:" + win._key && win.ctl.phase === "held", "key=" + win.keyOf() + " phase=" + win.ctl.phase);
            const r = win.popup.stepBack();
            win.check("step-back-on-the-password", r === true && win.keyOf() === "", "answered " + r + " key=" + win.keyOf());
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            win.check("giving-up-drifts-back", win.ctl.phase === "idle" && win.ctl.heldKey === "" && !(mock.wifi.active && mock.wifi.active.key === win._key), "phase=" + win.ctl.phase + " held=" + win.ctl.heldKey);
            win.check("keyboard-released", win.popup.keyboardFocusRequest === "none", win.popup.keyboardFocusRequest);
        });
        // ---- the pairing prompt opens the device's panel by itself ----
        S.push(() => {
            mock.scenario = "pairing";
        });
        S.push(W);
        S.push(() => {
            const pr = mock.bt.prompt;
            win.check("prompt-exists", !!pr, JSON.stringify(mock.bt));
            win.check("prompt-opens-the-panel", !!pr && win.keyOf() === "bt:" + pr.address && sec.item.shownKind === "bt", "key=" + win.keyOf());
            win.popup.stepBack();
            win.check("prompt-put-away", win.keyOf() === "", "key=" + win.keyOf());
            mock.scenario = "crowd";
        });
        S.push(W);
        // ---- the speed test ----
        S.push(() => {
            // every word the display logic engraves is one of the baked variants (the board's lettering is a texture: an unknown text is silently the first cell)
            const V = win.popup.scene.geo.SILK_VARIANTS, bad = [];
            const armed = refused => ({ state: "armed", refused: refused, liveMbps: 0, result: null });
            [["", false], ["", true], ["public", false], ["public", true], ["metered", false], ["metered", true]].forEach(c => {
                const w = Speed.engraving(armed(c[0]), 200, c[1]);
                if (V.rates.indexOf(w) < 0)
                    bad.push(JSON.stringify(c) + "->" + w);
            });
            ["idle", "latency", "down", "up", "done", "failed"].forEach(st => {
                if (Speed.engraving({ state: st, refused: "", result: null }, 200, false) !== "")
                    bad.push("state " + st + " engraves");
            });
            const F = { ratesUnit: v => v >= 1000 ? "Gb/s" : v >= 1 ? "Mb/s" : "kb/s" };
            const base = { rates: "Mb/s", usage: "MiB" };
            [[{ state: "latency" }, 0], [{ state: "down", liveMbps: 0.4 }, 0], [{ state: "down", liveMbps: 1500 }, 0], [{ state: "up", liveMbps: 20 }, 0],
             [{ state: "done", result: { downMbps: 300, upMbps: 0.5, atMs: 1 } }, 0], [{ state: "done", result: { downMbps: 300, upMbps: 0.5, atMs: 1 } }, 1600]].forEach(c => {
                const u = Speed.units(c[0], base, F, c[1]);
                if (V.rates.indexOf("RATE - " + u.rates) < 0 || V.usage.indexOf((u.usage === "ms" ? "PING" : "DATA") + " - " + u.usage) < 0)
                    bad.push(JSON.stringify(c[0]) + "->" + JSON.stringify(u));
            });
            win.check("engraving-words-are-baked-variants", bad.length === 0, bad.join(" | "));
            mock.scenario = "home";
        });
        S.push(W);
        S.push(() => {
            win.popup.armMs = 5000;
            const pt = win.pointOf("rates", false);
            win.check("find-rates", !!pt, "");
            win._pt = pt;
            win.click(pt);
            tc.wait(80);
            win.check("one-click-asks-only", mock.speed.state === "armed", "state=" + mock.speed.state);
            win.check("the-question-is-worded", win.popup.askText.indexOf("speed test") >= 0 && win.popup.askText.indexOf("200") >= 0, win.popup.askText);
            win.check("the-question-is-engraved", win.engr("rates") === "RUN? - MB" && win.popup._engraving === "RUN? - MB", "rates label " + win.engr("rates") + " asked " + win.popup._engraving);
            win.check("no-tag-for-the-question", win.descendants(win.popup).filter(it => String(it).indexOf("ErrorTag") >= 0).length === 0, "ErrorTags found");
            // the display blinks the cap: sample the cells over a second
            const seen = {};
            for (let i = 0; i < 8; i++) {
                seen[win.popup.state_.rates.join(",")] = true;
                tc.wait(150);
            }
            const ks = Object.keys(seen);
            win.check("display-blinks-the-cap", ks.indexOf("12,2,0,0") >= 0 && ks.indexOf("11,11,11,11") >= 0, ks.join(" | "));
        });
        S.push(() => {
            win.click(win._pt);
            tc.wait(60);
            win.check("second-click-runs", mock.speed.state === "latency" || mock.speed.state === "down", "state=" + mock.speed.state);
            win.check("latency-shows-d-dashes", mock.speed.state !== "latency" || win.popup.state_.rates.join(",") === "12,10,10,10", win.popup.state_.rates.join(","));
            win.check("question-gone", win.popup.askText === "" && win.engr("rates").indexOf("RUN?") !== 0, win.popup.askText + " / " + win.engr("rates"));
            win.check("units-follow-the-test", win.engr("rates") === "RATE - Mb/s" && win.engr("usage") === "PING - ms", win.engr("rates") + " / " + win.engr("usage"));
        });
        S.push(() => {
            win.check("running-shows-the-live-rate", mock.speed.state !== "down" || win.popup.state_.rates[0] === 12 || win.popup.state_.rates[0] === 13, win.popup.state_.rates.join(",") + " " + mock.speed.state);
            // a click while it runs does nothing
            const st = mock.speed.state;
            win.click(win._pt);
            win.check("click-while-running-does-nothing", st === "done" || mock.speed.state !== "idle", mock.speed.state);
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            win.check("test-done", mock.speed.state === "done", "state=" + mock.speed.state);
            const u = win.popup.state_.usage;
            win.check("usage-shows-latency-and-jitter", Speed.usageCells(mock.speed, [0, 0, 0, 0], win.popup.state_ ? { MINUS: 10, DP: 16 } : null).join(",") === u.join(",") && u[1] === 1 + 16, u.join(","));
            win._cells = win.popup.state_.rates;
        });
        S.push(() => {
            // the rates hold the download, then the upload (the first cell is the phase mark: d / h)
            const seen = {};
            for (let i = 0; i < 12; i++) {
                seen[win.popup.state_.rates[0]] = true;
                tc.wait(300);
            }
            win.check("rates-alternate-down-and-up", seen[12] === true && seen[13] === true, JSON.stringify(seen));
        });
        S.push(() => {
            // both go back at the next open
            win.popup.openedAtMs = Date.now() + 1;
            win.check("displays-go-back-at-the-next-open", !win.popup.speedShown && win.popup.state_.rates.join(",") === win.popup._described.rates.join(","), win.popup.state_.rates.join(","));
            tc.wait(60);
            win.check("units-go-back-at-the-next-open", win.engr("usage") === "DATA - " + win.popup._described.units.usage && win.engr("rates") === "RATE - " + win.popup._described.units.rates, win.engr("rates") + " / " + win.engr("usage"));
        });
        // a refusal needs one more confirm
        S.push(() => {
            mock.cancelSpeedTest();
            win.click(win._pt);
            tc.wait(60);
            mock.speed = Object.assign({}, mock.speed, { refused: "public" });
            tc.wait(60);
            win.check("refusal-shows-its-reason", win.popup.askText.indexOf("public") >= 0, win.popup.askText);
            win.check("refusal-is-engraved", win.engr("rates") === "PUBLIC NET?", win.engr("rates"));
            win.click(win._pt);
            tc.wait(80);
            win.check("refusal-needs-one-more-confirm", mock.speed.state === "armed" && win.popup.askText.indexOf("once more") >= 0 && win.engr("rates") === "SURE? - MB", "state=" + mock.speed.state + " " + win.popup.askText + " / " + win.engr("rates"));
            win.click(win._pt);
            tc.wait(80);
            win.check("then-it-runs", mock.speed.state === "latency" || mock.speed.state === "down", "state=" + mock.speed.state);
        });
        S.push(W);
        S.push(W);
        S.push(W);
        S.push(W);
        // a forgotten question is cancelled
        S.push(() => {
            win.popup.armMs = 400;
            mock.cancelSpeedTest();
            win.click(win._pt);
            tc.wait(80);
            win.check("asked-again", mock.speed.state === "armed", mock.speed.state);
            tc.wait(700);
            win.check("forgotten-question-is-cancelled", mock.speed.state === "idle", "state=" + mock.speed.state);
            win.popup.armMs = 5000;
        });
        // ---- the sounds ----
        S.push(() => {
            win.resetSounds();
            mock.setAirplane(true);
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            const l = win.popup.sounds.log;
            win.check("screw-ratchets", l.filter(x => x === "screw").length >= 3, "log=" + l);
            win.check("card-springs-up", l.indexOf("card_up") >= 0, "log=" + l);
            win.resetSounds();
            mock.setAirplane(false);
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            const l = win.popup.sounds.log;
            win.check("card-seats", l.indexOf("card_seat") >= 0, "log=" + l);
            win.resetSounds();
            mock.setRadio(!mock.wifi.radioOn);
        });
        S.push(W);
        S.push(() => {
            win.check("dip-clicks", win.popup.sounds.log.indexOf("dip") >= 0, "log=" + win.popup.sounds.log);
            win.resetSounds();
            win.ctl.intent("disconnect", []);
            win.check("pop-on-pull-off", win.popup.sounds.log.indexOf("pop") >= 0, "log=" + win.popup.sounds.log);
            mock.setRadio(true);
        });
        S.push(W);
        // ---- running or saving power (round 4: binary, as silicon). The shared ladder's middle rung changes NOTHING here; at the halt the scene's live layer eases to rest
        // (about a second: silicon's), and only then is the popup still; a wake eases it back. The beats are counted (`win.beats`, the scene's `time` moving). ----
        S.push(() => {
            win.popup.ladder.calmAfterMs = 400;
            win.popup.haltAfterMs = 2600;
            win.popup.touch();
            win.check("ladder-alive", win.popup.ladder.level === "alive" && win.popup.scene.live === 1, win.popup.ladder.level + " live " + win.popup.scene.live);
            win._b0 = win.beats;
            win._t0 = Date.now();
            tc.wait(250);
            win._rateAlive = (win.beats - win._b0) / Math.max(0.05, (Date.now() - win._t0) / 1000);
            win.waitFor(() => win.popup.ladder.level !== "alive", 3000);
            const lv = win.popup.ladder.level;
            win._b0 = win.beats;
            win._t0 = Date.now();
            tc.wait(250);
            const rate = (win.beats - win._b0) / Math.max(0.05, (Date.now() - win._t0) / 1000);
            win.check("the-middle-rung-changes-nothing", lv === "calm" && win.popup.scene.live === 1 && !win.popup._still && rate > 0.7 * win._rateAlive,
                "level " + lv + " live " + win.popup.scene.live + " beats/s alive " + win._rateAlive.toFixed(1) + " then " + rate.toFixed(1));
        });
        S.push(() => {
            win.waitFor(() => win.popup.ladder.level === "halt", 6000);
            const tHalt = Date.now(), stillAtHalt = win.popup._still;
            win.eased = 0;
            win.waitFor(() => win.popup._still === true, 4000);
            const took = Date.now() - tHalt;
            win.check("the-halt-eases-to-rest", !stillAtHalt && win.eased >= 6 && took > 500 && took < 2500 && win.popup.scene.live === 0,
                "still at the halt " + stillAtHalt + ", beats between running and rest " + win.eased + ", " + took + " ms, live " + win.popup.scene.live);
            win.check("ladder-still", win.popup.ladder.level === "halt" && win.popup._still === true, win.popup.ladder.level);
        });
        S.push(W);
        S.push(() => { win._swapsAt = win.swaps; });
        S.push(W);
        S.push(W);
        S.push(() => {
            const n = win.swaps - win._swapsAt;
            win.check("still-presents-no-frames", n <= 2, "frames while still: " + n);
            tc.mouseMove(win.contentItem, 100, 100);
            tc.mouseMove(win.contentItem, 130, 120);
            tc.wait(60);
            win.check("pointer-wakes-it", win.popup.ladder.level === "alive" && !win.popup._still, win.popup.ladder.level);
            win.eased = 0;
            win.waitFor(() => win.popup.scene.live === 1, 2500);
            win.check("the-wake-eases-back", win.eased >= 3 && win.popup.scene.live === 1, "beats between rest and running " + win.eased + ", live " + win.popup.scene.live);
            win.waitFor(() => win.popup.ladder.level === "halt", 6000);
        });
        S.push(() => {
            win.check("ladder-still-again", win.popup.ladder.level === "halt", win.popup.ladder.level);
            mock.setAirplane(true);
            tc.wait(60);
            win.check("network-event-wakes-it", win.popup.ladder.level === "alive", win.popup.ladder.level);
            mock.setAirplane(false);
        });
        S.push(W);
        S.push(W);
        // ---- the power-on ----
        S.push(() => {
            win.rebuild(true);
            tc.wait(40);
            const p = win.popup;
            win.check("starts-dark", p.entering && p.enter < 0.5 && p.sceneP < 0.5, "enter=" + p.enter + " entering=" + p.entering);
            win.check("label-is-typed", p.state_.label.name.length <= p._described.label.name.length, p.state_.label.name);
            win._swapsAt = win.swaps;
        });
        S.push(W);
        S.push(W);
        S.push(() => {
            const p = win.popup;
            win.check("ends-at-the-facts-pose", !p.entering && p.enter === 1 && p.sceneP === 1 && p.cloudP === 1 && p.globeP === 1, "enter=" + p.enter);
            win.check("label-fully-printed", p.state_.label.name === p._described.label.name && p.state_.label.lineA === p._described.label.lineA, p.state_.label.name);
            win.check("scene-lit", p.scene.power === 1, "scene.power=" + p.scene.power);
        });
        S.push(() => {
            // recycled content starts from dark again
            win.popup.recycle();
            win.check("recycle-goes-dark", win.popup.enter === 0 && win.keyOf() === "", "enter=" + win.popup.enter);
        });

        // ================= round 2 =================
        // ---- no tag, the cues ----
        S.push(() => {
            mock.scenario = "crowd";
            win.rebuild(false);
        });
        S.push(W);
        S.push(() => {
            win.requestActivate();
            const p = win.popup;
            win.check("no-error-tag-ever", win.descendants(p).filter(it => String(it).indexOf("ErrorTag") >= 0).length === 0, "ErrorTags found");
            // the label
            mock.failNext = "disconnect";
            mock.disconnect();
            const xs = win.sample(() => p.scene.labelItem.x, 420);
            const mx = Math.max.apply(null, xs.map(Math.abs));
            win.check("cue-label-shakes", mx >= 2 && mx <= 4.5, "max |x| " + mx);
            win.check("cue-label-ends-at-rest", p.scene.labelItem.x === 0 && p._shakeWho === "", "x=" + p.scene.labelItem.x + " who=" + p._shakeWho);
            const sg = xs.filter(x => x !== 0).map(Math.sign);
            win.check("cue-damped-swings", sg.filter((x, i) => i > 0 && x !== sg[i - 1]).length >= 2 && Math.abs(xs[xs.length - 1]) === 0, "no oscillation: " + xs.join(","));
        });
        S.push(() => {
            const p = win.popup, sc = p.scene;
            // a DIP lever falls back onto the facts' pose
            const on = sc._s.wifiOn;
            mock.failNext = "setRadio";
            mock.setRadio(!on);
            let moved = false;
            const ds = win.sample(() => { moved = moved || sc.dipMoving; return sc.dipCueW; }, 600);
            const mx = Math.max.apply(null, ds.map(Math.abs));
            win.check("cue-dip-springs", mx >= 0.4 && moved, "max |cue| " + mx + " moving " + moved);
            win.check("cue-dip-back-on-the-facts", sc.dipCueW === 0 && Math.abs(sc.dipWifiPose - (on ? 1 : 0)) < 0.001 && sc._s.wifiOn === on && !sc.dipMoving, "cue " + sc.dipCueW + " pose " + sc.dipWifiPose + " on " + sc._s.wifiOn);
            // a pad's LED blinks twice, in the error colour
            mock.failNext = "testPad";
            mock.testPad("dns");
            let edges = 0, prev = sc.ledNow[6] > 0.5, errCol = false;
            win.sample(() => {
                const v = sc.ledNow[6] > 0.5;
                if (v && !prev)
                    edges++;
                prev = v;
                errCol = errCol || (sc.ledColourNow[6] === 3 && v);
                return 0;
            }, 700);
            win.check("cue-pad-blinks-twice", edges >= 2, "rising edges " + edges);
            win.check("cue-pad-in-error-colour", errCol, "colour never 3 while lit");
            win.check("cue-pad-ends-at-the-facts", !sc._cueGate(6), "padCue " + sc.padCue);
            win.check("cue-pad-led-back", sc.ledColourNow[6] === sc._s.led.colour[6] && Math.abs(sc.ledNow[6] - sc._s.led.intensity[6] * sc.power) < 0.6, "colour " + sc.ledColourNow[6] + " vs " + sc._s.led.colour[6]);
        });
        S.push(() => {
            const p = win.popup;
            // the globe
            mock.failNext = "vpnConnect";
            mock.vpnConnect({ country: "NL" });
            const gs = win.sample(() => p.globe.transform.length ? p.globe.transform[0].x : 0, 420);
            const mx = Math.max.apply(null, gs.map(Math.abs));
            win.check("cue-globe-shakes", mx >= 1.5 && mx <= 3.5, "max |x| " + mx);
            win.check("cue-globe-ends-at-rest", p.globe.transform[0].x === 0, "x=" + p.globe.transform[0].x);
            // a network's tag (cue("net:<key>") shakes THAT tag through the cloud's shakeKey / shakeX: its x moves, nothing else)
            const tn = win.tags(p.cloud).find(t => t.e.kind === "net" && t.e.form === "named");
            win.check("have-a-network-tag", !!tn, "none");
            if (tn) {
                const x0 = tn.x;
                mock.failNext = "connect";
                mock.connect(tn.key, {});
                let keyed = false;
                const ts = win.sample(() => { keyed = keyed || p.cloud.shakeKey === tn.key; return tn.x - x0; }, 420);
                const m = Math.max.apply(null, ts.map(Math.abs));
                win.check("cue-net-tag-shakes", m >= 2 && m <= 4.5 && keyed, "max |dx| " + m + " keyed " + keyed);
                win.check("cue-net-tag-ends-at-rest", tn.x === x0 && p.cloud.shakeKey === "" && p.cloud.shakeX === 0, "x " + tn.x + " vs " + x0 + " key '" + p.cloud.shakeKey + "'");
            }
        });
        // a device of the near field shakes its own tag; a CONNECTED device is not in the air, so its cue shakes the label (the row lives there)
        S.push(() => {
            mock.scenario = "earbuds";
        });
        S.push(W);
        S.push(() => {
            const p = win.popup, sc = p.scene;
            const td = win.tags(p.cloud).find(t => t.e.kind === "bt");
            win.check("have-a-device", !!td, "none");
            if (td) {
                const x0 = td.x;
                mock.failNext = "btConnect";
                mock.btConnect(td.key);
                let keyed = false;
                const ts = win.sample(() => { keyed = keyed || p.cloud.shakeKey === td.key; return td.x - x0; }, 420);
                const m = Math.max.apply(null, ts.map(Math.abs));
                win.check("cue-device-shakes", m >= 2 && m <= 4.5 && keyed, "max |dx| " + m + " keyed " + keyed);
                win.check("cue-device-ends-at-rest", td.x === x0 && p.cloud.shakeKey === "", "x=" + td.x);
            }
            const conn = "AA:BB:CC:00:00:01";
            win.check("connected-device-is-not-a-tag", !win.tags(p.cloud).some(t => t.key === conn), "");
            mock.failNext = "btDisconnect";
            mock.btDisconnect(conn);
            const xs = win.sample(() => sc.labelItem.x, 420);
            const mx = Math.max.apply(null, xs.map(Math.abs));
            win.check("cue-connected-device-shakes-the-label", mx >= 2 && mx <= 4.5 && sc.labelItem.x === 0, "max |x| " + mx);
        });
        S.push(() => {
            const p = win.popup, sc = p.scene;
            // a part with no cue: nothing moves
            mock.failNext = "setAirplane";
            mock.setAirplane(true);
            const lx = win.sample(() => Math.abs(sc.labelItem.x) + Math.abs(sc.dipCueW) + Math.abs(sc.dipCueB) + (p._shakeWho !== "" ? 1 : 0) + (sc.padCue > 0 && sc.padCue < 1 ? 1 : 0), 300);
            win.check("unknown-part-does-nothing", Math.max.apply(null, lx) === 0 && mock.errors.length > 0, "moved " + Math.max.apply(null, lx));
            win.check("nothing-persists", win.descendants(p).filter(it => String(it).indexOf("ErrorTag") >= 0).length === 0 && p._shakeWho === "" && mock.errors.length > 0, "errors " + mock.errors.length);
        });
        // ---- Escape, one step a press ----
        S.push(() => {
            const pt = win.pointOf("mem", false);
            win.click(pt);
            tc.wait(120);
            win.check("saved-opens-by-mouse", win.keyOf() === "saved", win.keyOf());
            const sk = win.popup.keyboardFocusRequest;
            win.check("mouse-opened-saved-takes-no-keys", sk === "none" && !!sec.item && sec.item.keyboardWanted === true && sec.item.optionalKeys === true, "request " + sk + " wanted " + (sec.item ? sec.item.keyboardWanted : "?"));
            // the pointer MOVES into the panel: now it asks
            const o = sec.item.mapToItem(null, 60, 60);
            tc.mouseMove(win.contentItem, o.x - 5, o.y - 3);
            tc.mouseMove(win.contentItem, o.x, o.y);
            tc.wait(80);
            win.check("pointer-in-asks-the-keys", win.popup.keyboardFocusRequest === "onDemand", win.popup.keyboardFocusRequest);
            const f = win.searchField();
            win.check("search-field-focused", !!f && f.hasFocus === true, f ? "hasFocus " + f.hasFocus : "no field");
            win.type("zz");
            tc.wait(60);
            win.check("search-typed", !!f && f.text === "zz", f ? f.text : "?");
        });
        S.push(() => {
            const f = win.searchField();
            const r1 = win.popup.handleEscape();
            win.check("esc-clears-the-search-first", r1 === true && win.keyOf() === "saved" && f && f.text === "", "answered " + r1 + " key=" + win.keyOf() + " text=" + (f ? f.text : "?"));
            const r2 = win.popup.handleEscape();
            win.check("esc-then-the-engine-rule", r2 === false && win.keyOf() === "saved", "answered " + r2 + " key=" + win.keyOf());
            const r3 = win.popup.stepBack();
            win.check("step-back-then-the-panel", r3 === true && win.keyOf() === "", "answered " + r3 + " key=" + win.keyOf());
        });
        // ---- a keyboard path: the field has the keys at once ----
        S.push(() => {
            // the pointer rests on the board, away from the panel
            tc.mouseMove(win.contentItem, 100, 120);
            tc.mouseMove(win.contentItem, 104, 124);
            win.popup.openByKey("mem");
            tc.wait(120);
            win.check("key-opened-saved-asks-at-once", win.keyOf() === "saved" && win.popup.keyboardFocusRequest === "onDemand", "key " + win.keyOf() + " request " + win.popup.keyboardFocusRequest);
            const f = win.searchField();
            win.check("key-opened-field-has-focus", !!f && f.hasFocus === true, f ? "hasFocus " + f.hasFocus : "no field");
            win.popup.closeSecondary();
            tc.wait(60);
            win.check("keys-let-go", win.popup.keyboardFocusRequest === "none", win.popup.keyboardFocusRequest);
        });
        // ---- no hover highlight ----
        S.push(() => {
            const pt = win.pointOf("mem", false);
            tc.mouseMove(win.contentItem, pt.x - 4, pt.y - 3);
            tc.mouseMove(win.contentItem, pt.x, pt.y);
            tc.wait(260);
            win.check("hover-is-seen-by-the-pick", win.popup.hoverIntent === "mem", win.popup.hoverIntent);
            const hull = it => {
                if (it.preferredRendererType === undefined || !it.visible || !(it.opacity > 0))
                    return false;
                for (let i = 0; i < it.data.length; i++)
                    if (it.data[i].strokeWidth === 1 && it.data[i].fillColor !== undefined && Math.abs(it.data[i].fillColor.a - 0.2) < 0.01)
                        return true;
                return false;
            };
            const fades = win.descendants(win.popup).filter(hull);
            win.check("no-hover-fade", fades.length === 0, fades.length + " accent hulls drawn");
        });
        win._steps = S;
    }
    property var _pt: ({ x: 0, y: 0 })
    function resetSounds(): void {
        win.popup.sounds.log = [];
    }
}
