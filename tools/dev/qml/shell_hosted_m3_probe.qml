pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bar/gooey"
import "modules/aerial"
import "modules/aerial/data"

// =============================================================================
// tools/dev/qml/shell_hosted_m3_probe.qml -- aerial's bar owner as the SHELL hosts it
// (tools/dev/shell_hosted_m3_probe.sh; docs/contracts/shell.md section 4).
//
// The shell builds one AerialBarOwner per screen on ONE AerialService. This is that: two screens (two GooeyEngines, a top bar and a hosted owner
// each) on one AerialMock, every click a synthetic click through the WINDOW (tc.mouseClick(w.contentItem, ...)). The host's wiring is written out
// here as the shell writes it: the service's `popupOpen` driven by the OR of the screens' owners' `sharedFlags`.
//
//   h0 no service built   a hosted owner builds no service of its own -- handed the mock it uses it, handed none it has none (a second launch,
//                         NSHM_PHASE=own, where the runner's stubs would log the helper / nmcli a real service starts); its Bindings are off
//   h1 the flags          a hosted owner WRITES no service property: with the host's aggregation off, an open popup leaves the service's
//                         popupOpen false; its `sharedFlags` say what it wants (the popup, the traffic figures), down on close; with the host's
//                         OR on, two screens drive the service together and neither overrules the other
//   h2 airplane           the screw (the popup's part, answered by the owner) on one screen: the radios go down, the plane is on BOTH screens'
//                         pills, it survives the popup's close and the next open, and the screw on the OTHER screen gives back what was taken
//   h3 one popup          ONE popup for ANY click on the pill (its left end, its right end): the popup is aerial's, a second click on the pill
//                         closes it, and the other screen's pill opens its own (each screen has its engine)
//
// SAFETY. Nothing is built without NSHM=1 and the runner's stub directory first on PATH (a regression that built a real service would start the
// helper and run nmcli, and the stubs log it instead). Without the gate this file loads, says SKIP and quits, so a `tools/dev/smoke.sh --all`
// sweep is inert.
// =============================================================================
Window {
    id: w
    width: 1300
    height: 780
    visible: true
    color: "#3B4453"

    readonly property bool armed: Quickshell.env("NSHM") === "1"
    readonly property string stubDir: Quickshell.env("NSHM_STUB_DIR") || ""
    readonly property bool stubbed: w.armed && w.stubDir.length > 0
        && String(Quickshell.env("PATH") || "").indexOf(w.stubDir + ":") === 0
    readonly property bool ownPhase: Quickshell.env("NSHM_PHASE") === "own"

    Loader {
        id: host
        anchors.fill: parent
        active: w.stubbed
        sourceComponent: w.ownPhase ? ownComp : rigComp
    }

    // Quit from a Timer: Qt.quit() from Component.onCompleted does not quit.
    Timer {
        interval: 0
        running: !w.stubbed
        onTriggered: {
            console.log("NSHM not armed -- NSHM=1 and the stub first on PATH (tools/dev/shell_hosted_m3_probe.sh does both)");
            console.log("SHELL-HOSTED-M3 RESULT SKIP");
            Qt.quit();
        }
    }

    // h0, second launch: a hosted owner handed NO service. It has no engine, so nothing opens.
    Component {
        id: ownComp
        Item {
            AerialBarOwner {
                id: bare
                shellHosted: true
            }

            Timer {
                interval: 1500
                running: true
                onTriggered: {
                    const fails = [];
                    if (bare.svc !== null)
                        fails.push("svc is " + String(bare.svc).split("(")[0]);
                    let loaders = 0, binds = 0;
                    for (let i = 0; i < bare.data.length; i++) {
                        const o = bare.data[i];
                        if (o && o.sourceComponent !== undefined && o.item !== undefined)
                            loaders++;
                        if (String(o).indexOf("QQmlBind") === 0) {
                            binds++;
                            if (o.when)
                                fails.push("a Binding on " + String(o.target).split("(")[0] + " is switched on");
                        }
                    }
                    if (loaders !== 0)
                        fails.push(loaders + " Loader(s) in the owner (it builds nothing)");
                    if (bare.sharedFlags.aerialPopupOpen !== false || bare.sharedFlags.aerialRatesWatch !== true)
                        fails.push("sharedFlags " + JSON.stringify(bare.sharedFlags) + " with no popup");
                    bare.open();
                    if (bare.popupMine)
                        fails.push("open() with no service / engine opened something");
                    console.log(fails.length === 0
                        ? "PASS h0 own services: no service built (svc " + bare.svc + "), " + loaders + " Loaders, " + binds + " Bindings off"
                        : "FAIL h0 own services: " + fails.join("; "));
                    console.log("SHELL-HOSTED-M3 OWN RESULT " + (fails.length === 0 ? "PASS" : "FAIL"));
                    Qt.quit();
                }
            }
        }
    }

    Component {
        id: rigComp

        Item {
            id: rig

            // ---- the ledger ----------------------------------------------------
            readonly property var names: ({
                h0: "no service built by a hosted owner",
                h1: "the flags are the host's",
                h2: "airplane survives the popup",
                h3: "one popup for any click on the pill"
            })
            property var ledger: ({})
            function _v(id) {
                if (!rig.ledger[id])
                    rig.ledger[id] = { fails: [], facts: [], n: 0 };
                return rig.ledger[id];
            }
            function sub(id, name, ok, saw) {
                const v = rig._v(id);
                v.n++;
                if (!ok)
                    v.fails.push(name + " (" + saw + ")");
                console.log("  " + (ok ? "ok  " : "FAIL") + " " + id + "." + name + "   " + saw);
            }
            function fact(id, s) {
                rig._v(id).facts.push(s);
            }
            function note(s) {
                console.log("NOTE " + s);
            }
            function same(a, b) {
                return JSON.stringify(a) === JSON.stringify(b);
            }

            // ---- the scene: two screens, ONE service -----------------------------
            AerialMock {
                id: svc
                live: true
                settleMs: 100
            }

            component HostedScreen: Item {
                id: scr
                property var service: null
                readonly property alias engine: eng
                readonly property alias owner: theOwner

                GooeyEngine {
                    id: eng
                    anchors.fill: parent
                    surfaceColor: Theme.surface
                    barsList: [topBar]

                    GooeyBar {
                        id: topBar
                        engine: eng
                        barId: "top"
                        edge: "top"
                        rawPos: 0
                        rawLen: eng.w

                        // The wiring a shell does (CONTRACT section 4): hosted, the service handed in.
                        AerialBarOwner {
                            id: theOwner
                            x: 300
                            y: Math.round((topBar.height - theOwner.height) / 2)
                            width: theOwner.implicitWidth
                            height: theOwner.implicitHeight
                            engine: eng
                            bar: topBar
                            barId: "top"
                            shellHosted: true
                            service: scr.service
                        }
                    }
                }
            }
            HostedScreen {
                id: sa
                x: 0
                width: 640
                height: 780
                service: svc
            }
            HostedScreen {
                id: sb
                x: 650
                width: 640
                height: 780
                service: svc
            }

            // The shell's ShellServices does this: the service's flag is the OR of every screen's owner, written ONCE. Off, it shows what an owner writes by itself.
            property bool aggregate: false
            Binding {
                target: svc
                property: "popupOpen"
                when: rig.aggregate
                value: sa.owner.sharedFlags.aerialPopupOpen || sb.owner.sharedFlags.aerialPopupOpen
            }

            TestCase {
                id: tc
                name: "shellhosted"
                when: false
            }

            function isOpen(s) {
                return s.engine.popupOpen && s.engine.thePopup.phase === "open" && !!s.engine.thePopup.contentItem;
            }
            function isClosed(s) {
                return !s.engine.popupOpen && s.engine.thePopup.phase === "closed" && s.engine.thePopup.contentItem === null;
            }
            function button(s) {
                return s.owner.button;
            }
            readonly property string plane: String.fromCharCode(0xF072)
            function glyph(s) {
                return rig.button(s).netGlyph;
            }
            // a click through the window on the owner's pill, at a fraction of its width
            function clickAt(it, fx, fy) {
                const p = it.mapToItem(null, it.width * fx, it.height * fy);
                tc.mouseClick(w.contentItem, p.x, p.y, Qt.LeftButton);
            }
            // Real services built by an owner: a child of the real type, directly or as a Loader's item.
            function realBuilt(s) {
                const found = [];
                const d = s.owner.data;
                for (let i = 0; i < d.length; i++) {
                    const o = d[i];
                    const cands = [o];
                    if (o && o.item !== undefined && o.sourceComponent !== undefined)
                        cands.push(o.item);
                    for (const c of cands)
                        if (String(c).indexOf("AerialService") === 0)
                            found.push("AerialService");
                }
                return found;
            }

            // ---- the run: steps polled on the WALL clock ---------------------------
            // (offscreen, a Timer runs on the animation clock, ~3x fast -- CLAUDE.md)
            property var steps: []
            property int si: 0
            property real at: Date.now()
            // NOT RE-ENTRANT: a step that clicks spins the event loop inside QtTest, and a tick
            // that fires in the middle of it would run the same step again (a second click on a
            // toggle) and skip one when the outer call returns.
            property bool stepping: false
            function advance() {
                if (rig.stepping)
                    return;
                rig.stepping = true;
                try {
                    rig.advanceOnce();
                } finally {
                    rig.stepping = false;
                }
            }
            function advanceOnce() {
                if (rig.si >= rig.steps.length) {
                    stepTimer.stop();
                    return;
                }
                const s = rig.steps[rig.si];
                const waited = Date.now() - rig.at;
                if (s.wait && waited < s.wait)
                    return;
                if (s.until) {
                    let ok = false;
                    try {
                        ok = s.until();
                    } catch (e) {
                        ok = false;
                    }
                    if (!ok) {
                        if (waited <= (s.timeout || 6000))
                            return;
                        rig.sub(s.vid || "h0", "step " + s.name + " finished", false, "TIMEOUT after " + waited + " ms");
                    }
                }
                try {
                    if (s.run)
                        s.run();
                } catch (e) {
                    rig.sub(s.vid || "h0", "step " + s.name + " ran", false, String(e));
                }
                rig.si++;
                rig.at = Date.now();
            }
            Timer {
                id: stepTimer
                interval: 25
                repeat: true
                onTriggered: rig.advance()
            }
            // The runner's backstop is behind this one.
            Timer {
                interval: 100000
                running: true
                onTriggered: {
                    console.log("FAIL watchdog: the run did not finish in 100 s (step " + rig.si + " of " + rig.steps.length + ": "
                                + (rig.si < rig.steps.length ? rig.steps[rig.si].name : "-") + ")");
                    console.log("SHELL-HOSTED-M3 RESULT FAIL");
                    Qt.quit();
                }
            }

            function finish() {
                let bad = 0;
                const ids = Object.keys(rig.names);
                for (const id of ids) {
                    const v = rig._v(id);
                    const ok = v.fails.length === 0 && v.n > 0;
                    if (!ok)
                        bad++;
                    console.log((ok ? "PASS " : "FAIL ") + id + " " + rig.names[id] + " -- " + v.n + " checks"
                                + (v.facts.length ? ": " + v.facts.join("; ") : "")
                                + (v.fails.length ? "  FAILED: " + v.fails.join(" | ") : (v.n === 0 ? "  NO CHECK RAN" : "")));
                }
                console.log("SHELL-HOSTED-M3 RESULT " + (bad === 0 ? "PASS" : "FAIL"));
                Qt.quit();
            }

            Component.onCompleted: {
                const S = rig.steps;
                const step = (name, vid, run, opts) => S.push(Object.assign({ name: name, vid: vid, run: run }, opts || {}));
                const pause = ms => S.push({ name: "pause", wait: ms });
                const until = (name, vid, cond, ms) => S.push({ name: name, vid: vid, until: cond, timeout: ms || 6000 });
                // aerialRatesWatch: a horizontal owner always asks for the bar's traffic figures (the host ORs it, the service reads once)
                const FLAGS = open => ({ aerialPopupOpen: open, aerialRatesWatch: true });

                pause(900);
                step("setup", "h0", () => {
                    rig.sub("h0", "uses-the-mock", sa.owner.svc === svc && sb.owner.svc === svc, "owners on " + String(sa.owner.svc).split("(")[0]);
                    for (const s of [sa, sb]) {
                        const built = rig.realBuilt(s);
                        rig.sub("h0", "builds-none", built.length === 0, built.length ? "built " + built.join(", ") : "no real service in the owner");
                    }
                    let on = 0, n = 0;
                    for (const s of [sa, sb])
                        for (let i = 0; i < s.owner.data.length; i++)
                            if (String(s.owner.data[i]).indexOf("QQmlBind") === 0) {
                                n++;
                                if (s.owner.data[i].when)
                                    on++;
                            }
                    rig.sub("h0", "bindings-off", n === 4 && on === 0, n + " Bindings, " + on + " switched on");
                    // the owner contract's members (CONTRACT section 4, point 6)
                    for (const s of [sa, sb])
                        rig.sub("h0", "owner-members", typeof s.owner.toggle === "function" && typeof s.owner.open === "function"
                                && typeof s.owner.close === "function" && typeof s.owner.popupMine === "boolean"
                                && typeof s.owner.sharedFlags === "object" && s.owner.shellHosted === true,
                                "toggle " + typeof s.owner.toggle + ", open " + typeof s.owner.open + ", close " + typeof s.owner.close
                                + ", popupMine " + typeof s.owner.popupMine + ", sharedFlags " + typeof s.owner.sharedFlags);
                    rig.fact("h0", "two owners on one mock, none built");
                });
                pause(300);

                // ---- h1: the flags ------------------------------------------------------------
                // The host's aggregation is OFF: a hosted owner writes nothing to the service.
                step("A opens", "h1", () => rig.clickAt(sa.owner, 0.25, 0.5));
                until("A open", "h1", () => rig.isOpen(sa));
                pause(300);
                step("flags with the host off", "h1", () => {
                    rig.sub("h1", "a.flags-open", rig.same(sa.owner.sharedFlags, FLAGS(true)), JSON.stringify(sa.owner.sharedFlags));
                    rig.sub("h1", "b.flags-idle", rig.same(sb.owner.sharedFlags, FLAGS(false)), JSON.stringify(sb.owner.sharedFlags));
                    rig.sub("h1", "writes-nothing", svc.popupOpen === false, "popupOpen=" + svc.popupOpen + " with A's popup open");
                    rig.clickAt(sa.owner, 0.75, 0.5);
                });
                until("A closed", "h1", () => rig.isClosed(sa));
                step("flags down", "h1", () => {
                    rig.sub("h1", "a.flags-down", rig.same(sa.owner.sharedFlags, FLAGS(false)), JSON.stringify(sa.owner.sharedFlags));
                    // the host takes over
                    rig.aggregate = true;
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("A open again", "h1", () => rig.isOpen(sa));
                pause(200);
                step("the service follows A", "h1", () => {
                    rig.sub("h1", "host-on.follows-A", svc.popupOpen === true, "popupOpen=" + svc.popupOpen);
                    rig.clickAt(sb.owner, 0.5, 0.5);
                });
                until("B open", "h1", () => rig.isOpen(sb));
                pause(300);
                step("two screens, one service", "h1", () => {
                    // each screen has its own engine, so both popups are up at once; the service's flag is the OR
                    rig.sub("h1", "host-on.both-open", sb.owner.popupMine && sa.owner.popupMine, "A " + sa.owner.popupMine + ", B " + sb.owner.popupMine);
                    rig.sub("h1", "host-on.still-open", svc.popupOpen === true, "popupOpen=" + svc.popupOpen + " with both popups open");
                    rig.clickAt(sb.owner, 0.5, 0.5);
                });
                until("B closed", "h1", () => rig.isClosed(sb));
                step("A alone holds the flag", "h1", () => {
                    rig.sub("h1", "host-on.A-alone", svc.popupOpen === true && sa.owner.popupMine && !sb.owner.popupMine, "popupOpen=" + svc.popupOpen + " with only A's popup open (neither overrules the other)");
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("all closed", "h1", () => rig.isClosed(sb) && rig.isClosed(sa));
                step("all down", "h1", () => {
                    rig.sub("h1", "host-on.all-down", svc.popupOpen === false && !sa.owner.sharedFlags.aerialPopupOpen && !sb.owner.sharedFlags.aerialPopupOpen,
                            "popupOpen=" + svc.popupOpen);
                    rig.fact("h1", "the flags OR over two screens");
                });
                pause(200);

                // ---- h2: airplane --------------------------------------------------------------
                step("idle glyphs", "h2", () => {
                    rig.sub("h2", "idle.no-plane", rig.glyph(sa) !== rig.plane && rig.glyph(sb) !== rig.plane, "A " + rig.glyph(sa).charCodeAt(0).toString(16) + ", B " + rig.glyph(sb).charCodeAt(0).toString(16));
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("A open for the screw", "h2", () => rig.isOpen(sa));
                step("the screw on A", "h2", () => sa.owner._answer("screw"));
                until("airplane in effect", "h2", () => svc.airplane.on === true && svc.wifi.radioOn === false, 4000);
                step("on both pills", "h2", () => {
                    rig.sub("h2", "plane-on-A-and-B", rig.glyph(sa) === rig.plane && rig.glyph(sb) === rig.plane,
                            "A " + rig.glyph(sa).charCodeAt(0).toString(16) + ", B " + rig.glyph(sb).charCodeAt(0).toString(16));
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("A closed with the plane up", "h2", () => rig.isClosed(sa));
                pause(200);
                step("survives the close", "h2", () => {
                    rig.sub("h2", "close.plane-on-A", svc.airplane.on === true && rig.glyph(sa) === rig.plane, "on " + svc.airplane.on + ", A " + rig.glyph(sa).charCodeAt(0).toString(16));
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("A reopens", "h2", () => rig.isOpen(sa));
                step("a new content that still knows", "h2", () => {
                    rig.sub("h2", "reopen.plane-on-A", svc.airplane.on === true && rig.glyph(sa) === rig.plane, "on " + svc.airplane.on);
                    rig.clickAt(sa.owner, 0.5, 0.5);
                });
                until("A closed again", "h2", () => rig.isClosed(sa));
                step("the screw on B", "h2", () => sb.owner._answer("screw"));
                until("released", "h2", () => svc.airplane.on === false && svc.wifi.radioOn === true, 4000);
                step("back on both", "h2", () => {
                    rig.sub("h2", "released.no-plane", rig.glyph(sa) !== rig.plane && rig.glyph(sb) !== rig.plane, "A " + rig.glyph(sa).charCodeAt(0).toString(16));
                    rig.sub("h2", "released.radio-back", svc.wifi.radioOn === true, "radioOn " + svc.wifi.radioOn);
                });
                pause(200);
                // round 6: SCAN and BEACON are toggles -- a second press ends what runs
                step("SCAN", "h2", () => sa.owner._answer("bt.scan"));
                until("searching", "h2", () => svc.bt.discovering === true, 3000);
                step("SCAN again", "h2", () => sa.owner._answer("bt.scan"));
                pause(500);
                step("BEACON", "h2", () => {
                    rig.sub("h2", "scan.second-press-stops", svc.bt.discovering === false, "discovering " + svc.bt.discovering);
                    sa.owner._answer("beacon");
                });
                until("visible", "h2", () => svc.bt.discoverable === true, 3000);
                step("BEACON again", "h2", () => sa.owner._answer("beacon"));
                pause(500);
                step("both ended", "h2", () => rig.sub("h2", "beacon.second-press-hides", svc.bt.discoverable === false, "discoverable " + svc.bt.discoverable));
                pause(200);

                // ---- h3: one popup for any click --------------------------------------------------
                step("click the pill's left end", "h3", () => rig.clickAt(sa.owner, 0.08, 0.5));
                until("opened by the left end", "h3", () => rig.isOpen(sa));
                step("it is aerial's, one popup", "h3", () => {
                    rig.sub("h3", "left.owner-aerial", sa.engine.popupOwnerId === "aerial" && sa.owner.popupMine, "owner " + sa.engine.popupOwnerId);
                    rig.sub("h3", "left.pill-active", rig.button(sa).popupOpen === true, "popupOpen " + rig.button(sa).popupOpen);
                    // the right end of the SAME pill: the second click closes it (no travel to another half)
                    rig.clickAt(sa.owner, 0.92, 0.5);
                });
                until("closed by the right end", "h3", () => rig.isClosed(sa));
                step("closed, nothing left", "h3", () => {
                    rig.sub("h3", "second-click-closes", !sa.owner.popupMine && rig.button(sa).popupOpen === false, "popupMine " + sa.owner.popupMine);
                    rig.clickAt(sb.owner, 0.92, 0.5);
                });
                until("opened by B's right end", "h3", () => rig.isOpen(sb));
                step("B's popup", "h3", () => {
                    rig.sub("h3", "right.owner-aerial", sb.engine.popupOwnerId === "aerial" && sb.owner.popupMine && !sa.owner.popupMine, "owner " + sb.engine.popupOwnerId);
                    sb.owner.close();
                });
                until("B closed", "h3", () => rig.isClosed(sb));
                step("close() with nothing open, open(), close()", "h3", () => {
                    sb.owner.close();
                    sb.owner.open();
                });
                until("open() opened", "h3", () => rig.isOpen(sb));
                step("close() closes", "h3", () => sb.owner.close());
                until("closed by close()", "h3", () => rig.isClosed(sb));
                step("contract entry points done", "h3", () => {
                    rig.sub("h3", "entry-points", !sb.owner.popupMine, "popupMine " + sb.owner.popupMine);
                });
                // the password field's keyboard request: the engine asks the PRIMARY's content only, so while a secured stranger's panel wants its field the popup itself asks (onDemand)
                step("open B for a password", "h3", () => sb.owner.open());
                until("B open again", "h3", () => rig.isOpen(sb));
                step("a secured stranger's panel", "h3", () => {
                    const c = sb.engine.thePopup.contentItem;
                    const n = svc.wifi.networks.find(x => x.security !== "open" && x.security !== "owe" && !x.known && !x.hidden && x.security !== "eap");
                    rig.sub("h3", "psk.has-a-stranger", !!n && !!c && "keyboardFocusRequest" in c, "network " + (n ? n.key : "none"));
                    rig.sub("h3", "psk.none-before", sb.engine._keyboardOf(sb.engine._primary) === "none", "asks " + sb.engine._keyboardOf(sb.engine._primary));
                    if (n && c)
                        c._panelKey = "network:" + n.key;
                });
                until("the field wants the keys", "h3", () => sb.engine._keyboardOf(sb.engine._primary) === "onDemand", 4000);
                step("it asks onDemand, and lets go with the panel", "h3", () => {
                    const c = sb.engine.thePopup.contentItem;
                    rig.sub("h3", "psk.asks-onDemand", sb.engine._keyboardOf(sb.engine._primary) === "onDemand" && c.secondaryOpen === true, "asks " + sb.engine._keyboardOf(sb.engine._primary) + " open " + c.secondaryOpen + " key " + c.secondaryKey + " live " + c._live + " wants " + JSON.stringify(c._wants) + " childOpen " + sb.engine.childOpen + "");
                    // Escape under shell.jsonc `"escape": "detail"` (GooeyEngine.escapeDetailFirst): the panel goes, the popup stays
                    sb.engine.escapeDetailFirst = true;
                    const took = sb.engine.pressEscape();
                    rig.sub("h3", "psk.escape-detail-first-puts-the-panel-away", took === true && c.secondaryOpen === false && sb.engine.popupOpen, "open " + c.secondaryOpen + " popup " + sb.engine.popupOpen);
                });
                until("the request is let go", "h3", () => sb.engine._keyboardOf(sb.engine._primary) === "none", 4000);
                // the default (`"escape": "all"`): one press closes the popup with its panel
                step("the panel again", "h3", () => {
                    const c = sb.engine.thePopup.contentItem;
                    const n = svc.wifi.networks.find(x => x.security !== "open" && x.security !== "owe" && !x.known && !x.hidden && x.security !== "eap");
                    if (n && c)
                        c._panelKey = "network:" + n.key;
                });
                until("the panel is out again", "h3", () => !!sb.engine.thePopup.contentItem && sb.engine.thePopup.contentItem.secondaryOpen === true, 4000);
                step("Escape, one press", "h3", () => {
                    sb.engine.escapeDetailFirst = false;
                    sb.engine.pressEscape();
                });
                until("B closed at last", "h3", () => rig.isClosed(sb));
                step("the popup and its panel went with one press", "h3", () => {
                    rig.sub("h3", "psk.escape-closes-popup-and-panel", rig.isClosed(sb) && !sb.engine.childOpen, "childOpen " + sb.engine.childOpen);
                });
                step("end", "h0", () => rig.finish(), { wait: 100 });
                stepTimer.start();
            }
        }
    }
}
