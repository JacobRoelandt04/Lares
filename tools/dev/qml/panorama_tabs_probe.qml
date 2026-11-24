pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/scroll"
import "modules/common/theme"
import "modules/panorama"
import "modules/panorama/data"
import "modules/presets/data"

// =============================================================================
// panorama_tabs_probe.qml -- the machine popup (PanoramaTabs + PanoramaBarOwner): ONE popup, two tabs. Run by tools/dev/panorama_tabs_probe.sh
// (offscreen, a sandbox copy, a private config / state). Each check prints `PT ok|FAIL <what>`; the last line is `PT RESULT PASS|FAIL (<n>/<n>)`.
//
// THE ENGINE IS A STAND-IN (a few lines: open / close / prebuild of a content in a host item, parked and recycled as GooeyEngine does it): what is
// proved here is the OWNER's rules and the CONTENT's contract; the engine's side of the contract (closing the child when `secondaryOpen` falls,
// easing the box) is the engine's own gates. The owner is SHELL-HOSTED (services injected, none built), as the shell mounts it.
//
//   situation   the tab at an open: the laptop alone -> Presets, an external display or a mirror -> Displays; `openWith` -> Displays (no such display: no crash)
//   built       a tab is built when first shown (the other is not built at the first open)
//   size        header + the tab's own, one step per switch; the rest size aims at the tab the next open shows
//   held        the owner holds the tab: it survives a park / recycle, and reaches a content whose own binding died
//   swipe       a two-finger sideways swipe switches (synthetic pixel events and a real wheel); a vertical one with drift does not
//   escape      Presets: menu, then rename, then the popup; Displays: the detail, then the popup
//   detail      the Displays tab's secondary maps into the popup's frame, closes on the Presets tab and does not come back with the tab
//   keys        keyboardFocusRequest follows the tab
//   flag        sharedFlags.popupOpen is "the Displays tab is on show"
//   deal        a preset load asks the glyph for its flourish once; an Apply (a close with no load) does not
//   census      a hosted owner builds no service
// PANORAMA_TABS unset: the file loads and quits (a bare smoke run).
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property bool armed: Quickshell.env("PANORAMA_TABS") === "1"
    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("PT " + (ok ? "ok " : "FAIL ") + what);
    }
    function finish(): void {
        console.log("PT RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + ")");
        quitT.start();
    }
    Timer {
        id: quitT
        interval: 0
        onTriggered: Qt.quit()
    }

    Window {
        id: win
        visible: probe.armed
        width: 760
        height: 900
        color: Theme.surface

        PanoramaMock {
            id: pano
            scenario: "laptop"
        }
        PresetsService {
            id: psvc
            live: false
        }

        Item {
            id: barItem
            width: 600
            height: 40
        }
        // the bar's button: the owner only asks it to deal
        Item {
            id: button
            x: 280
            width: 28
            height: 28
            property int deals: 0
            function deal(): bool {
                deals++;
                return true;
            }
        }
        Item {
            id: host
            y: 60
            width: 760
            height: 840
        }

        // ---- the engine, as much of it as the owner and the content read ------------------------------------------------------
        QtObject {
            id: eng
            property bool popupOpen: false
            property string popupOwnerId: ""
            property real renderScale: 1
            property var contentItem: null
            property var parkedItem: null
            property int opens: 0
            property var thePopup: QtObject {
                property string ownerId: ""
                property string phase: "closed"
            }
            function _make(component: Component, initial: var): var {
                const it = component.createObject(host, initial);
                it.width = Qt.binding(() => it.implicitWidth);
                it.height = Qt.binding(() => it.implicitHeight);
                return it;
            }
            function prebuild(ownerId: string, component: Component, initial: var): void {
                if (eng.parkedItem)
                    return;
                eng.parkedItem = eng._make(component, initial);
                eng.parkedItem.visible = false;
            }
            function open(ownerId: string, barId: string, centre: real, a: var, b: var, c: bool, component: Component, d: int): void {
                eng.opens++;
                let it = eng.parkedItem;
                eng.parkedItem = null;
                if (it) {
                    it.visible = true;
                    it.parked = false;
                } else {
                    it = eng._make(component, { parked: false });
                }
                eng.contentItem = it;
                eng.popupOwnerId = ownerId;
                eng.thePopup.ownerId = ownerId;
                eng.thePopup.phase = "open";
                eng.popupOpen = true;
            }
            // closed: a content with a recycle() is kept parked and recycled, as the engine does
            function close(): void {
                if (!eng.popupOpen)
                    return;
                eng.popupOpen = false;
                eng.thePopup.phase = "closed";
                const it = eng.contentItem;
                eng.contentItem = null;
                if (it && typeof it.recycle === "function") {
                    it.recycle();
                    it.parked = true;
                    it.visible = false;
                    eng.parkedItem = it;
                } else if (it) {
                    it.destroy();
                }
            }
        }

        PanoramaBarOwner {
            id: owner
            engine: eng
            bar: barItem
            barId: "bar"
            anchorItem: button
            shellHosted: true
            service: pano
            presets: psvc
        }
    }
    TestCase {
        id: tc
        when: false
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------
    readonly property var content: eng.contentItem
    readonly property var eng: win.eng
    property var sizeLog: ({ w: [], h: [] })
    function watchSize(): void {
        probe.sizeLog = { w: [], h: [] };
    }
    Connections {
        target: probe.content
        ignoreUnknownSignals: true
        function onImplicitWidthChanged() {
            probe.sizeLog.w.push(probe.content.implicitWidth);
        }
        function onImplicitHeightChanged() {
            probe.sizeLog.h.push(probe.content.implicitHeight);
        }
    }
    function all(item: var, name: string, out: var): var {
        const acc = out || [];
        if (!item)
            return acc;
        if (item.objectName === name)
            acc.push(item);
        for (let i = 0; i < item.children.length; i++)
            probe.all(item.children[i], name, acc);
        return acc;
    }
    function close(): void {
        owner.close();
    }
    // a touchpad's event, straight into the gesture reader
    function tp(dx: real, dy: real): void {
        probe.content._wheel(WheelHub.fingers(dx, dy, Qt.ScrollUpdate));
    }
    property bool wasPresetsOnly: false

    // ---- the steps: each returns true when done, "wait" to be asked again next tick -----------------------------------------------
    property int step: 0
    property int waited: 0
    property var steps: [
        function () {
            pano.scenario = "laptop";
            return probe.waited++ < 3 ? "wait" : true;
        },
        function () {
            // situation: the laptop alone
            probe.check(owner.situationTab === "presets", "situation: the laptop alone gives Presets (" + owner.situationTab + ")");
            owner.toggle();
            probe.check(eng.popupOpen && probe.content !== null, "situation: a click opens the popup");
            probe.check(owner.currentTab === "presets" && probe.content.currentTab === "presets", "situation: it opens on Presets (" + probe.content.currentTab + ")");
            probe.check(owner.sharedFlags.popupOpen === false, "flag: popupOpen is false on the Presets tab");
            probe.check(psvc.calls.indexOf("list") >= 0, "situation: the open read the presets");
            probe.check(psvc.watching, "watch: the Presets tab on show follows the desktop (the presets' watch is held)");
            probe.check(probe.content.presetsTab !== null && probe.content.displaysTab === null, "built: only the tab on show is built at the first open");
            probe.check(probe.content.implicitWidth === 596, "size: the Presets tab keeps its own width (" + probe.content.implicitWidth + ")");
            probe.check(probe.content.implicitHeight === 46 + Math.ceil(probe.content.presetsTab.implicitHeight), "size: header + the tab's own height (" + probe.content.implicitHeight + ")");
            probe.check(probe.content.restImplicitWidth === 596, "size: the rest size aims at the tab the next open shows (" + probe.content.restImplicitWidth + ")");
            probe.check(probe.content.keyboardFocusRequest === "none", "keys: Presets with no pointer on it asks for none (" + probe.content.keyboardFocusRequest + ")");
            return true;
        },
        function () {
            // detail + built + one step: to Displays by a click on the selector (the laptop alone, so the user chose it)
            probe.watchSize();
            probe.content.currentTab = "displays";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(owner.currentTab === "displays", "held: a tab picked inside is written back to the owner");
            probe.check(!psvc.watching, "watch: on Displays the presets' watch is let go");
            probe.check(probe.content.displaysTab !== null, "built: the Displays tab is built when first shown");
            const L = probe.sizeLog;
            probe.check(probe.content.implicitWidth === 460, "size: the Displays tab keeps its own width (" + probe.content.implicitWidth + ")");
            probe.check(probe.content.implicitHeight === 46 + Math.ceil(probe.content.displaysTab.implicitHeight), "size: header + the tab's own height (" + probe.content.implicitHeight + ")");
            probe.check(L.w.length === 1 && L.h.length === 1 && L.h[0] === probe.content.implicitHeight, "size: a first show is ONE step (w " + JSON.stringify(L.w) + ", h " + JSON.stringify(L.h) + ")");
            probe.check(owner.sharedFlags.popupOpen === true, "flag: popupOpen is true once the Displays tab is on show");
            probe.check(probe.content.keyboardFocusRequest === "none", "keys: Displays asks for none");
            return true;
        },
        function () {
            // one step per switch with both built
            probe.watchSize();
            probe.content.currentTab = "presets";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            const L = probe.sizeLog;
            probe.check(L.w.length === 1 && L.h.length === 1, "size: a switch between built tabs is ONE step (w " + JSON.stringify(L.w) + ", h " + JSON.stringify(L.h) + ")");
            probe.check(owner.sharedFlags.popupOpen === false, "flag: it falls again on the Presets tab");
            return true;
        },
        function () {
            // swipe: synthetic touchpad events, sideways
            let flipped = false;
            for (const sgn of [-1, 1]) {
                if (probe.content.currentTab !== "presets")
                    break;
                for (let i = 0; i < 70; i++)
                    probe.tp(sgn * 40, 0);
                probe.content._wheel(WheelHub.fingers(0, 0, Qt.ScrollEnd));
            }
            probe.check(probe.content.currentTab === "displays", "swipe: a two-finger sideways swipe switches the tab (" + probe.content.currentTab + ")");
            probe.check(probe.content.swipeGestureActive === false, "swipe: the lift (zero delta) ends the gesture");
            probe.check(probe.content.gestureHoldWidth === 596, "swipe: the hold is the larger tab (" + probe.content.gestureHoldWidth + ")");
            return true;
        },
        function () {
            // vertical with drift: the tab stays, the axis is y
            const before = probe.content.currentTab;
            for (let i = 0; i < 90; i++)
                probe.tp(10, 40);
            probe.check(probe.content.currentTab === before && probe.content._gestureAxis === "y", "swipe: a vertical scroll with drift keeps the tab and the y axis (" + probe.content.currentTab + ", " + probe.content._gestureAxis + ")");
            probe.content._wheel(WheelHub.fingers(0, 0, Qt.ScrollEnd));
            return true;
        },
        function () {
            // a real wheel through the window: sideways, the area's own wiring
            const c = probe.content.mapToItem(win.contentItem, probe.content.width / 2, 200);
            const was = probe.content.currentTab;
            tc.mouseMove(win.contentItem, c.x - 3, c.y);
            tc.mouseMove(win.contentItem, c.x, c.y);
            // one sideways notch is one tab: to the next, then back to the previous
            tc.mouseWheel(win.contentItem, c.x, c.y, was === "displays" ? -120 : 120, 0);
            probe.check(probe.content.currentTab !== was, "swipe: one real sideways notch over the popup switches it (" + was + " -> " + probe.content.currentTab + ")");
            tc.mouseWheel(win.contentItem, c.x, c.y, was === "displays" ? 120 : -120, 0);
            probe.check(probe.content.currentTab === was, "swipe: and one the other way back (" + probe.content.currentTab + ")");
            probe.content._wheel(WheelHub.fingers(0, 0, Qt.ScrollEnd));
            const t = probe.content.currentTab;
            tc.mouseWheel(win.contentItem, c.x, c.y, 0, 120);
            tc.mouseWheel(win.contentItem, c.x, c.y, 0, -120);
            probe.check(probe.content.currentTab === t, "swipe: real vertical notches leave the tab alone");
            probe.content.currentTab = "presets";
            return true;
        },
        function () {
            if (probe.waited++ < 2)
                return "wait";
            // escape on Presets: menu, then rename, then the popup
            const p = probe.content.presetsTab;
            probe.check(p.handleEscape() === false && probe.content.handleEscape() === false, "escape: Presets with nothing open lets the popup close");
            const card = probe.all(p, "presetLoad").map(b => { let q = b; while (q && !(q.row !== undefined && q.askLoad !== undefined)) q = q.parent; return q; })[0];
            p._startRename("dev");
            p._openMenu("dev", card, 20, 20);
            probe.check(probe.content.handleEscape() === true, "escape: Presets: the menu closes first");
            probe.check(probe.content.keyboardFocusRequest === "exclusive", "keys: a rename on the Presets tab asks for the keyboard (" + probe.content.keyboardFocusRequest + ")");
            probe.check(probe.content.handleEscape() === true && p._renameFor === "", "escape: Presets: then the rename");
            probe.check(probe.content.handleEscape() === false, "escape: Presets: then the popup may close");
            return true;
        },
        function () {
            // the preset load: the glyph deals once, the popup closes
            probe.content.presetsTab.load("dev", "replace");
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(button.deals === 1, "deal: a preset load asks the glyph for its flourish once (" + button.deals + ")");
            probe.check(eng.popupOpen === false, "deal: and the popup closes");
            probe.check(owner.sharedFlags.popupOpen === false, "flag: closed is false");
            return true;
        },
        function () {
            // park / recycle: the owner's tab reaches a parked content, and a recycled one keeps it
            pano.scenario = "desk";
            return probe.waited++ < 3 ? "wait" : true;
        },
        function () {
            probe.check(owner.situationTab === "displays", "situation: an external display gives Displays (" + owner.situationTab + ")");
            const parked = eng.parkedItem;
            probe.check(!!parked && parked.parked === true, "held: the closed content waits parked (recycled)");
            owner.toggle();
            probe.check(eng.contentItem === parked, "held: the click adopts the parked content");
            probe.check(probe.content.currentTab === "displays" && owner.currentTab === "displays", "situation: it opens on Displays with an external display (" + probe.content.currentTab + ")");
            probe.check(owner.sharedFlags.popupOpen === true, "flag: true on the Displays tab");
            probe.check(probe.content.restImplicitWidth === 460, "size: the rest size follows the situation (" + probe.content.restImplicitWidth + ")");
            return true;
        },
        function () {
            // the content assigns its own tab (its binding dies): the owner still reaches it
            probe.content.currentTab = "presets";
            probe.check(owner.currentTab === "presets", "held: the content's own change reaches the owner");
            owner.currentTab = "displays";
            probe.check(probe.content.currentTab === "displays", "held: the owner's change still reaches a content whose own binding died");
            // the detail: Arrange... while on Presets
            probe.content.currentTab = "presets";
            owner.openWith("DVI-I-1");
            return true;
        },
        function () {
            if (probe.waited++ < 4)
                return "wait";
            probe.check(owner.currentTab === "displays" && probe.content.currentTab === "displays", "situation: openWith always opens Displays (" + probe.content.currentTab + ")");
            probe.check(probe.content.selected === "DVI-I-1" && probe.content.secondaryOpen === true && probe.content.secondaryKey === "DVI-I-1", "detail: the display is selected and its detail is open (" + probe.content.selected + ", " + probe.content.secondaryOpen + ")");
            const a = probe.content.secondaryAnchor;
            probe.check(a.x === probe.content.width && a.y > 46 && a.y < probe.content.height, "detail: the anchor is the popup's right edge at the tile's row (" + a.x + ", " + a.y + ")");
            probe.check(probe.content.secondaryComponent !== null && probe.content.secondarySide !== "", "detail: the component and a side are there (" + probe.content.secondarySide + ")");
            // Escape on Displays: nothing in the middle of -> false (the engine's rule: the popup with its detail, or stepBack first)
            probe.check(probe.content.handleEscape() === false && probe.content.selected === "DVI-I-1", "escape: Displays: the detail is not the content's to take (the engine's rule)");
            probe.check(probe.content.stepBack() === true && probe.content.selected === "", "escape: Displays: stepBack puts the detail away");
            probe.check(probe.content.stepBack() === false, "escape: Displays: stepBack with no detail answers false");
            probe.content.displaysTab.selected = "DVI-I-1";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(probe.content.secondaryOpen === true, "detail: open again");
            probe.content.currentTab = "presets";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(probe.content.secondaryOpen === false && probe.content.selected === "", "detail: the Presets tab closes it (" + probe.content.secondaryOpen + ")");
            probe.content.currentTab = "displays";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(probe.content.secondaryOpen === false, "detail: it does not come back with the tab");
            // an Apply (a close with no load) never deals
            probe.content.displaysTab.closeRequested();
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(button.deals === 1 && eng.popupOpen === false, "deal: an Apply closes the popup and deals nothing (" + button.deals + ")");
            return true;
        },
        function () {
            // openWith with no such display, the laptop alone, the popup closed: no crash, Displays, no detail
            pano.scenario = "laptop";
            return probe.waited++ < 3 ? "wait" : true;
        },
        function () {
            owner.openWith("HDMI-A-9");
            return true;
        },
        function () {
            if (probe.waited++ < 4)
                return "wait";
            probe.check(eng.popupOpen && probe.content.currentTab === "displays", "situation: openWith on a laptop alone still opens Displays (" + probe.content.currentTab + ")");
            probe.check(probe.content.secondaryOpen === false, "detail: a display that is not there opens no detail");
            owner.close();
            // a mirror counts as a display
            pano.scenario = "mirror";
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            probe.check(owner.situationTab === "displays", "situation: a mirror gives Displays (" + owner.situationTab + ")");
            // no preset saved: the Presets tab is one column wide, built or not (a tab not built yet aims at the width it will have)
            psvc.mockPresets = psvc.mockPresets.slice(0, 1);
            psvc.refresh();
            const fresh = owner.popupComponent.createObject(win.contentItem, { visible: false });
            probe.check(fresh.presetsTab === null && fresh._wP === 596, "size: the Presets tab not built, one preset: two columns (" + fresh._wP + ")");
            psvc.mockPresets = [];
            psvc.refresh();
            probe.check(fresh.presetsTab === null && fresh._wP === 304, "size: the Presets tab not built, none saved: one column (" + fresh._wP + ")");
            fresh.currentTab = "presets";
            probe.check(fresh.presetsTab !== null && fresh.implicitWidth === 304 && fresh.presetsTab.boxWidth === fresh.width, "size: none saved: the popup is one column wide, the tab is told its box (" + fresh.implicitWidth + ")");
            fresh.destroy();
            owner.currentTab = "displays";
            // census: a hosted owner builds no service
            const seen = [];
            function walk(o, depth) {
                if (!o || depth > 12)
                    return;
                const s = String(o);
                for (const n of ["PresetsService", "PanoramaMock", "PanoramaService", "SessionService"])
                    if (s.indexOf(n) === 0)
                        seen.push(n);
                if (o.item !== undefined && o.item)
                    walk(o.item, depth + 1);
                if (o.data !== undefined)
                    for (let i = 0; i < o.data.length; i++)
                        walk(o.data[i], depth + 1);
            }
            walk(owner, 0);
            probe.check(seen.length === 0, "census: a hosted owner builds no service (" + seen.join(",") + ")");
            owner.close();
            probe.waited = 0;
            return true;
        },
        // panorama.jsonc openTab: a fixed tab, "last", and a tab asked by name (shell.jsonc clicks)
        function () {
            if (probe.waited++ < 3)
                return "wait";
            pano.settings = Object.assign({}, pano.settings, { openTab: "presets" });
            owner.toggle();
            probe.check(owner.currentTab === "presets", "openTab \"presets\": a click opens on Presets though the situation says Displays (" + owner.currentTab + ", situation " + owner.situationTab + ")");
            owner.close();
            probe.waited = 0;
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            pano.settings = Object.assign({}, pano.settings, { openTab: "last" });
            owner.currentTab = "presets";
            owner.toggle();
            probe.check(owner.currentTab === "presets", "openTab \"last\": the popup opens on the tab it was left on (" + owner.currentTab + ")");
            owner.close();
            probe.waited = 0;
            return true;
        },
        function () {
            if (probe.waited++ < 3)
                return "wait";
            pano.settings = Object.assign({}, pano.settings, { openTab: "situation" });
            owner.openOn("presets");
            probe.check(eng.popupOpen && owner.currentTab === "presets", "openOn(\"presets\"): the popup opens on Presets whatever the situation (" + owner.currentTab + ")");
            owner.close();
            return true;
        }
    ]
    Timer {
        id: driver
        interval: 40
        repeat: true
        running: false
        onTriggered: {
            if (probe.step >= probe.steps.length) {
                driver.stop();
                probe.finish();
                return;
            }
            driver.stop();
            let r;
            try {
                r = probe.steps[probe.step]();
            } catch (e) {
                probe.check(false, "step " + probe.step + " threw: " + e);
                r = true;
            }
            if (r !== "wait") {
                probe.step++;
                probe.waited = 0;
            }
            driver.start();
        }
    }
    Timer {
        interval: 0
        running: true
        onTriggered: {
            if (!probe.armed) {
                Qt.quit();
                return;
            }
            win.requestActivate();
            driver.start();
        }
    }
}
