pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/clipboard/data"
import "modules/picker"
import "modules/picker/data"

// =============================================================================
// picker_probe.qml -- the picker's behaviour on the REAL popup, the REAL PickerService and the REAL ClipboardService (no watcher),
// with stubbed wl-copy / hyprctl first on PATH (tools/dev/picker_probe.sh; PK_STUBS is the stubs' log directory, PK_STATE a private
// state folder). Each check prints `PK ok|FAIL <what>`; the last line is `PK RESULT PASS|FAIL (<n>/<n> checks)`.
//
//   paste      a pick puts the picked bytes on the clipboard (one wl-copy) and sends the ORIGIN window's paste key to it
//              (a kitty gets CTRL SHIFT,v; a firefox CTRL,v), after the popup let go of the keyboard
//   multi      Shift+Enter picks go to the tray and paste nothing; the pick that closes pastes them JOINED, in one copy
//   escape     Escape clears the query, then the tray, then closes -- and nothing is copied or sent
//   tone       the popover (Ctrl+T) sets the ONE tone: every tonable emoji, shown and pasted, follows it; a non-tonable one does not;
//              it is remembered (a second service over the same state folder reads it back) with the recents
//   digits     on Symbols, digits are an alt code: "233" is the theta first, "0233" the e acute first, "23" only codes that START with it
//   both       one query counts hits in both tabs
//   clear      Clear (a real click on the Recent header's control) empties THIS tab's recents only, becomes Undo where the header was, Undo puts
//              back exactly what was cleared, a tab change or the expiry ends it for good, the state file follows each; Delete on a highlighted
//              recent forgets that one, and does nothing with the highlight outside Recent or a search typed
//   nerd       the Nerd tab: its list is fetched ONCE for the font's version (stub curl serving the saved 3.5.1 list), Enter pastes the glyph,
//              Ctrl+Enter the name, the tray joins names with a space, a second session and a second ask fetch nothing, a failed fetch is
//              one plain line on the page (and the other tabs work), and the next visit to the tab asks again
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property string stubs: Quickshell.env("PK_STUBS") || ""
    readonly property string stateDir: Quickshell.env("PK_STATE") || ""

    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("PK " + (ok ? "ok " : "FAIL ") + what);
    }

    TestCase {
        id: tc
        name: "pk"
        when: false
    }
    FileView {
        id: reader
        blockLoading: true
        printErrors: false
    }
    function disk(path: string): string {
        reader.path = "";
        reader.path = path;
        reader.reload();
        return reader.text() || "";
    }
    // The stubs' records: one "[bytes]" line per wl-copy, one line per hyprctl dispatch.
    function copies(): var {
        const t = probe.disk(probe.stubs + "/copies.log");
        return t === "" ? [] : t.split("\n").filter(l => l !== "").map(l => l.slice(1, -1));
    }
    function dispatches(): var {
        const t = probe.disk(probe.stubs + "/hyprctl.log");
        return t === "" ? [] : t.split("\n").filter(l => l !== "");
    }

    FileView {
        id: activeFile
        path: probe.stubs !== "" ? probe.stubs + "/active" : ""
        printErrors: false
    }
    // The window the popup was opened over, which the stub hyprctl also reports as the active one.
    function setOrigin(addr: string, cls: string): void {
        svc.origin = { address: addr, cls: cls };
        activeFile.setText(addr);
    }

    ClipboardService {
        id: clip
        enabled: false
        live: true
        restoreOnStart: false
        stateOverride: probe.stateDir + "/clip"
        // clip.py's defaults, which a service with no watcher never reads: a terminal pastes with CTRL SHIFT,V
        config: ({ pasteKeys: { "default": "CTRL,V", "classes": { "kitty": "CTRL SHIFT,V" } } })
    }
    PickerService {
        id: svc
        live: true
        clipboard: clip
        stateOverride: probe.stateDir + "/picker"
        nerdCacheOverride: probe.stateDir + "/nerdcache"
        writeDelayMs: 50
    }
    // The service the popup reads (a failing one for the failure checks).
    property var popSvc: svc
    FileView {
        id: curlMode
        path: probe.stubs !== "" ? probe.stubs + "/curl_mode" : ""
        printErrors: false
    }
    PickerStyle {
        id: sty
    }

    property int closes: 0
    Window {
        id: win
        visible: probe.stubs !== ""
        width: 600
        height: 420
        color: Theme.surface
        Loader {
            id: host
            active: probe.stubs !== ""
            anchors.fill: parent
            sourceComponent: Component {
                PickerPopup {
                    service: probe.popSvc
                    // qmllint disable incompatible-type
                    style: sty
                    // qmllint enable incompatible-type
                    anchors.fill: parent
                    onCloseRequested: {
                        probe.closes++;
                        // the owner's part: the popup is gone, the keyboard is let go of
                        svc.hostOpen = false;
                    }
                }
            }
        }
    }
    readonly property var pop: host.item
    function open() {
        svc.hostOpen = true;
        pop.freshen();
    }
    function type(s: string): void {
        for (let i = 0; i < s.length; i++)
            tc.keyClick(s.charAt(i));
    }
    function curlCalls(): var {
        const t = probe.disk(probe.stubs + "/curl.log");
        return t === "" ? [] : t.split("\n").filter(l => l !== "");
    }
    function find(item: var, name: string): var {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.find(item.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    // The recents of a tab, as one string (every char, in order) joined by "|".
    function recs(tab: string): string {
        return svc.recentsOf(tab, 99).map(it => it.ch).join("|");
    }
    // The records the state file holds.
    function stateRecs(): var {
        try {
            return JSON.parse(probe.disk(probe.stateDir + "/picker/state.json")).frecency || {};
        } catch (e) {
            return {};
        }
    }
    function clearBtn(): var {
        return probe.find(probe.pop, "pickerClear");
    }
    // A real click on an item's middle, through the window (so whatever stands over it is in the chain).
    function clickItem(it: var): void {
        if (!it) {
            probe.check(false, "no control to click");
            return;
        }
        const p = it.mapToItem(win.contentItem, it.width / 2, it.height / 2);
        tc.mouseClick(win.contentItem, p.x, p.y);
    }
    property var rec0: ({})
    property string rec1: ""
    property string deleted: ""
    property real headY: -1
    function flatChars(): var {
        return probe.pop.lay.flat.map(it => it.ch);
    }

    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    Timer {
        id: driver
        interval: 20
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                console.log("PK RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
                Qt.quit();
                return;
            }
            // keyClick runs the event loop: the timer must not run a step inside a step.
            driver.stop();
            const waited = Date.now() - probe.stepStarted;
            let r = false;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check(false, "step " + probe.stepAt + " threw: " + e);
                r = true;
            }
            if (r === "wait" && waited < 8000) {
                driver.start();
                return;
            }
            if (r === "wait")
                probe.check(false, "step " + probe.stepAt + " timed out");
            probe.stepAt++;
            probe.stepStarted = Date.now();
            driver.start();
        }
    }

    property int baseCopies: 0
    property int baseDispatch: 0

    Component.onCompleted: Qt.callLater(() => {
        if (probe.stubs === "") {
            Qt.quit();
            return;
        }
        probe.steps = [
            // ---- paste: a plain pick into a kitty --------------------------------------------------------------------
            w => {
                win.requestActivate();
                probe.setOrigin("0x1a2b", "kitty");
                svc.ensureLoaded();
                probe.check(svc.ready, "the data asset loads (" + (svc.ready ? svc.index.emoji.length : 0) + " emoji)");
                probe.open();
                return false;
            },
            w => {
                probe.type("red heart");
                probe.check(probe.pop.currentItem !== null && probe.pop.currentItem.ch === "❤️", "'red heart' finds the heart first");
                tc.keyClick(Qt.Key_Return);
                probe.check(probe.closes === 1 && svc.lastPick !== null && svc.lastPick.text === "❤️", "Enter picks the highlighted cell and asks the popup to close");
                return false;
            },
            w => {
                const c = probe.copies();
                const d = probe.dispatches();
                if (c.length < 1 || d.length < 1) {
                    if (w < 5000)
                        return "wait";
                    probe.check(false, "pasted bytes: nothing reached the clipboard / the window (copies " + c.length + ", keys " + d.length + ")");
                    return false;
                }
                probe.check(c.length === 1 && c[0] === "❤️", "pasted bytes: one wl-copy holding the heart (" + JSON.stringify(c) + ")");
                probe.check(d.length === 1 && d[0].indexOf("send_shortcut") >= 0 && d[0].indexOf("CTRL SHIFT") >= 0 && d[0].indexOf("key = \"v\"") >= 0
                            && d[0].indexOf("address:0x1a2b") >= 0, "the origin window's paste key: a kitty gets CTRL SHIFT,v to its address (" + d[0] + ")");
                probe.baseCopies = c.length;
                probe.baseDispatch = d.length;
                return false;
            },
            // ---- multi: the tray, joined ------------------------------------------------------------------------------
            w => {
                probe.setOrigin("0x3c4d", "firefox");
                probe.open();
                probe.type("grin");
                tc.keyClick(Qt.Key_Return, Qt.ShiftModifier);
                tc.keyClick(Qt.Key_Right);
                tc.keyClick(Qt.Key_Return, Qt.ShiftModifier);
                probe.check(probe.pop.tray.length === 2 && probe.closes === 1, "Shift+Enter adds to the tray and does not close (tray " + probe.pop.tray.length + ")");
                probe.expect = probe.pop.tray.map(it => it.ch).join("") + probe.pop.currentItem.ch;
                tc.keyClick(Qt.Key_Right);
                probe.expect = probe.pop.tray.map(it => it.ch).join("") + probe.pop.currentItem.ch;
                tc.keyClick(Qt.Key_Return);
                probe.check(probe.closes === 2 && svc.lastPick.bases.length === 3, "Enter with a tray picks the tray and the cell together (" + svc.lastPick.bases.length + ")");
                return false;
            },
            w => {
                const c = probe.copies();
                const d = probe.dispatches();
                if (c.length <= probe.baseCopies || d.length <= probe.baseDispatch) {
                    if (w < 5000)
                        return "wait";
                    probe.check(false, "the tray is pasted joined: nothing reached the clipboard / the window");
                    return false;
                }
                probe.check(c.length === probe.baseCopies + 1 && c[c.length - 1] === probe.expect, "the tray is pasted joined in ONE copy (" + JSON.stringify(c[c.length - 1]) + ")");
                probe.check(d.length === probe.baseDispatch + 1 && d[d.length - 1].indexOf("CTRL\"") >= 0 && d[d.length - 1].indexOf("SHIFT") < 0 && d[d.length - 1].indexOf("address:0x3c4d") >= 0,
                            "a firefox gets plain CTRL,v to its own address (" + d[d.length - 1] + ")");
                probe.baseCopies = c.length;
                probe.baseDispatch = d.length;
                return false;
            },
            // ---- escape: nothing goes ---------------------------------------------------------------------------------
            w => {
                probe.open();
                const before = probe.closes;
                probe.type("smile");
                tc.keyClick(Qt.Key_Return, Qt.ShiftModifier);
                tc.keyClick(Qt.Key_Escape);
                probe.check(probe.pop.query === "" && probe.pop.tray.length === 1 && probe.closes === before, "Escape clears the query first (tray kept, still open)");
                tc.keyClick(Qt.Key_Escape);
                probe.check(probe.pop.tray.length === 0 && probe.closes === before, "Escape clears the tray next");
                tc.keyClick(Qt.Key_Escape);
                probe.check(probe.closes === before + 1, "Escape then closes");
                return false;
            },
            w => {
                // give a stray paste time to show itself
                return w < 700 ? "wait" : false;
            },
            w => {
                probe.check(probe.copies().length === probe.baseCopies && probe.dispatches().length === probe.baseDispatch, "Escape copied and sent nothing");
                return false;
            },
            // ---- tone ---------------------------------------------------------------------------------------------------
            w => {
                probe.setOrigin("0x1a2b", "kitty");
                probe.open();
                probe.type("thumbs up");
                const it = probe.pop.currentItem;
                probe.check(it !== null && it.ch === "👍" && it.tonable, "'thumbs up' finds the thumb, and it takes a tone");
                tc.keyClick(Qt.Key_T, Qt.ControlModifier);
                probe.check(probe.pop.toneOpen, "Ctrl+T opens the tone popover");
                tc.keyClick(Qt.Key_Right);
                tc.keyClick(Qt.Key_Right);
                tc.keyClick(Qt.Key_Return);
                probe.check(!probe.pop.toneOpen && svc.tone === 2, "Right Right Enter in the popover sets tone 2 (" + svc.tone + ")");
                tc.keyClick(Qt.Key_Return);
                return false;
            },
            w => {
                const c = probe.copies();
                if (c.length <= probe.baseCopies) {
                    if (w < 5000)
                        return "wait";
                    probe.check(false, "the tone applies to the paste: nothing reached the clipboard");
                    return false;
                }
                probe.check(c[c.length - 1] === "👍🏼", "the tone applies to the paste: thumbs up, medium-light (" + JSON.stringify(c[c.length - 1]) + ")");
                probe.baseCopies = c.length;
                probe.baseDispatch = probe.dispatches().length;
                return false;
            },
            w => {
                // the tone is GLOBAL: another tonable emoji, a non-tonable one
                probe.open();
                probe.type("waving hand");
                const wave = probe.pop.currentItem;
                probe.check(wave !== null && svc.textOf(wave) === "👋🏼", "every tonable emoji follows the one tone (waving hand: " + (wave ? JSON.stringify(svc.textOf(wave)) : "none") + ")");
                probe.pop.setQuery("red heart");
                probe.check(svc.textOf(probe.pop.currentItem) === "❤️", "an emoji with no tone is left alone");
                probe.pop.freshen();
                return false;
            },
            w => {
                // remembered: the memory is written, and a SECOND service over the same folder reads it
                return w < 400 ? "wait" : false;
            },
            w => {
                const second = svc2.createObject(probe, {});
                second.ensureLoaded();
                const rec = second.recentsOf("emoji", 5).map(it => it.ch);
                probe.check(second.tone === 2, "the tone is remembered across sessions (" + second.tone + ")");
                probe.check(rec.indexOf("👍") >= 0 && rec.indexOf("❤️") >= 0, "the recents are remembered across sessions (" + rec.join(" ") + ")");
                second.destroy();
                return false;
            },
            // ---- digits: the alt code ----------------------------------------------------------------------------------------
            w => {
                probe.open();
                tc.keyClick(Qt.Key_Tab);
                probe.check(probe.pop.tab === "symbols", "Tab goes to the Symbols tab");
                probe.type("233");
                let f = probe.pop.lay.flat;
                probe.check(f.length >= 1 && f[0].ch === "Θ" && probe.pop.currentIndex === 0 && f[0].codes.indexOf("233") >= 0, "'233' jumps to the theta (Alt+233) first, highlighted (" + probe.flatChars().slice(0, 3).join(" ") + ")");
                probe.check(f.every(it => it.codes.length > 0), "'233' shows alt codes only");
                probe.pop.setQuery("0233");
                f = probe.pop.lay.flat;
                probe.check(f.length >= 1 && f[0].ch === "é", "'0233' jumps to the e acute (Alt+0233) first (" + probe.flatChars().slice(0, 3).join(" ") + ")");
                probe.pop.setQuery("23");
                f = probe.pop.lay.flat;
                probe.check(f.length === 11 && f.every(it => it.codes.some(c => c.indexOf("23") === 0)), "'23' lists exactly the codes that START with it (" + f.length + ")");
                return false;
            },
            // ---- both tabs ------------------------------------------------------------------------------------------------------
            w => {
                const tb = Date.now();
                probe.pop.setQuery("arrow");
                console.log("PK info baseline query 'arrow' on Symbols, the Nerd list not loaded: " + (Date.now() - tb) + " ms");
                probe.check(probe.pop._emojiCount > 0 && probe.pop._symbolCount > 0, "one query finds hits in both tabs (emoji " + probe.pop._emojiCount + ", symbols " + probe.pop._symbolCount + ")");
                return false;
            },
            // ---- nerd: the list is fetched once, for the font's version -----------------------------------------------------------
            w => {
                probe.baseCopies = probe.copies().length;
                probe.baseDispatch = probe.dispatches().length;
                probe.open();
                probe.check(svc.nerdState === "idle" && svc.nerdRuns === 0, "the Nerd list is not asked for before the tab is shown");
                tc.keyClick(Qt.Key_Tab);
                tc.keyClick(Qt.Key_Tab);
                probe.check(probe.pop.tab === "nerd" && svc.nerdRuns === 1, "Tab Tab shows the Nerd tab and asks for the list once (runs " + svc.nerdRuns + ")");
                return false;
            },
            w => {
                if (svc.nerdState === "loading")
                    return w < 15000 ? "wait" : false;
                probe.check(svc.nerdState === "ready", "the Nerd list is ready (" + svc.nerdState + " " + svc.nerdError + ")");
                return false;
            },
            w => {
                const calls = probe.curlCalls();
                const r = svc.nerdResult;
                probe.check(calls.length === 1 && calls[0].indexOf("/v3.5.1/glyphnames.json") > 0, "ONE fetch, for the font's own version: " + calls.length + " " + (calls[0] || ""));
                probe.check(calls.length === 1 && /-A lares-picker\S* /.test(calls[0]) && calls[0].indexOf("--max-time") > 0, "the fetch has a generic User-Agent and a timeout");
                probe.check(r !== null && r.status === "fetched" && r.fetched === true && r.nerd === "3.5.1", "the tool says it fetched 3.5.1 (" + JSON.stringify(r) + ")");
                const ni = svc.nerdIndex;
                probe.check(ni !== null && ni.items.length > 10000 && r !== null && ni.items.length === r.count, "the index holds what the tool wrote: " + (ni ? ni.items.length : 0) + " icons");
                probe.check(probe.pop.lay.flat.length === ni.items.length && probe.pop.cats.length === ni.sets.length && ni.sets.length >= 9, "the page is every icon, the category bar one cell per set (" + ni.sets.length + ")");
                probe.check(svc.nerdFamily !== "" && probe.pop.lay.flat[0].tab === "nerd", "the tiles are Nerd items in the font's family (" + svc.nerdFamily + ")");
                return false;
            },
            w => {
                const t0 = Date.now();
                probe.pop.setQuery("lightbulb on");
                const ms = Date.now() - t0;
                console.log("PK info first Nerd query 'lightbulb on': " + ms + " ms, " + probe.pop._nerdCount + " hits");
                const it = probe.pop.currentItem;
                probe.check(it !== null && it.name === "nf-md-lightbulb_on" && probe.pop._nerdCount >= 5, "'lightbulb on' finds nf-md-lightbulb_on first (" + (it ? it.name : "none") + ", " + probe.pop._nerdCount + " hits)");
                probe.expect = it ? it.ch : "";
                probe.check(probe.pop.captionOf(it).indexOf("nf-md-lightbulb_on") === 0 && probe.pop.captionOf(it).indexOf("U+F06E8") > 0, "the foot names the highlighted icon and its code point (" + probe.pop.captionOf(it) + ")");
                let t1 = Date.now();
                probe.pop.setQuery("battery");
                console.log("PK info typical Nerd query 'battery': " + (Date.now() - t1) + " ms, " + probe.pop._nerdCount + " hits");
                t1 = Date.now();
                probe.pop.setQuery("l");
                console.log("PK info one-letter Nerd query 'l': " + (Date.now() - t1) + " ms, " + probe.pop._nerdCount + " hits");
                probe.pop.setQuery("lightbulb on");
                probe.pop.setQuery("nf-md-lightbulb_on");
                probe.check(probe.pop.currentItem !== null && probe.pop.currentItem.name === "nf-md-lightbulb_on", "a whole name finds that icon first");
                probe.pop.setQuery("lightbulb on");
                probe.check(probe.pop.tab === "nerd" && probe.pop._nerdCount > 0 && probe.pop._emojiCount >= 0, "the Nerd label counts its hits");
                probe.check(svc.nerdRuns === 1, "searching asks nothing");
                tc.keyClick(Qt.Key_Return);
                probe.check(probe.closes >= 1 && svc.lastPick !== null && svc.lastPick.text === probe.expect && svc.lastPick.text !== "", "Enter on the Nerd tab picks the GLYPH");
                return false;
            },
            w => {
                const c = probe.copies();
                if (c.length <= probe.baseCopies) {
                    if (w < 5000)
                        return "wait";
                    probe.check(false, "nerd glyph paste: nothing reached the clipboard");
                    return false;
                }
                probe.check(c[c.length - 1] === probe.expect, "nerd glyph paste: wl-copy got the glyph, not its name (" + JSON.stringify(c[c.length - 1]) + ")");
                probe.baseCopies = c.length;
                return false;
            },
            w => {
                probe.open();
                tc.keyClick(Qt.Key_Tab);
                tc.keyClick(Qt.Key_Tab);
                probe.type("lightbulb on");
                tc.keyClick(Qt.Key_Return, Qt.ControlModifier);
                probe.check(svc.lastPick !== null && svc.lastPick.text === "nf-md-lightbulb_on", "Ctrl+Enter picks the NAME (" + (svc.lastPick ? svc.lastPick.text : "none") + ")");
                return false;
            },
            w => {
                const c = probe.copies();
                if (c.length <= probe.baseCopies) {
                    if (w < 5000)
                        return "wait";
                    probe.check(false, "nerd name paste: nothing reached the clipboard");
                    return false;
                }
                probe.check(c[c.length - 1] === "nf-md-lightbulb_on", "nerd name paste: wl-copy got the name (" + JSON.stringify(c[c.length - 1]) + ")");
                probe.baseCopies = c.length;
                return false;
            },
            w => {
                // names in the tray are joined by a space; a plain Enter at the end adds the glyph of the cell
                probe.open();
                tc.keyClick(Qt.Key_Tab);
                tc.keyClick(Qt.Key_Tab);
                probe.type("home");
                const first = probe.pop.currentItem.name;
                tc.keyClick(Qt.Key_Return, Qt.ControlModifier | Qt.ShiftModifier);
                tc.keyClick(Qt.Key_Right);
                const second = probe.pop.currentItem.name;
                probe.check(probe.pop.tray.length === 1 && probe.pop.tray[0].asName === true, "Ctrl+Shift+Enter puts the NAME in the tray");
                tc.keyClick(Qt.Key_Return, Qt.ControlModifier);
                probe.check(svc.lastPick !== null && svc.lastPick.text === first + " " + second, "a tray of names pastes them joined by a space (" + (svc.lastPick ? svc.lastPick.text : "none") + ")");
                return false;
            },
            w => {
                // Ctrl+Enter means nothing off the Nerd tab (as before)
                probe.baseCopies = probe.copies().length;
                probe.open();
                const before = probe.closes;
                probe.type("red heart");
                tc.keyClick(Qt.Key_Return, Qt.ControlModifier);
                probe.check(probe.closes === before && probe.pop.tab === "emoji", "Ctrl+Enter does nothing on the Emoji tab");
                probe.pop.freshen();
                return false;
            },
            // a second SESSION over the same cache and a second ask fetch nothing
            w => {
                const second = svc3.createObject(probe, {});
                probe.svcB = second;
                second.ensureLoaded();
                second.ensureNerd();
                return false;
            },
            w => {
                if (probe.svcB.nerdState === "loading")
                    return w < 15000 ? "wait" : false;
                const r = probe.svcB.nerdResult;
                probe.check(probe.svcB.nerdState === "ready" && r !== null && r.status === "current" && r.fetched === false, "a second session finds the cache current: nothing fetched (" + (r ? r.status : probe.svcB.nerdError) + ")");
                probe.check(probe.curlCalls().length === 1, "curl was called once in all (" + probe.curlCalls().length + ")");
                const runs = svc.nerdRuns;
                svc.ensureNerd();
                svc.ensureNerd();
                probe.check(svc.nerdRuns === runs && probe.curlCalls().length === 1, "asking again for a list that is there runs nothing");
                probe.svcB.destroy();
                return false;
            },
            // a failed fetch: one plain line on the page, the other tabs untouched, the next visit asks again
            w => {
                curlMode.setText("offline");
                probe.popSvc = svc4;
                svc4.ensureLoaded();
                probe.open();
                probe.check(probe.pop.service === svc4, "the popup reads the failing service");
                tc.keyClick(Qt.Key_Tab);
                tc.keyClick(Qt.Key_Tab);
                return false;
            },
            w => {
                if (svc4.nerdState === "loading")
                    return w < 15000 ? "wait" : false;
                const e = probe.find(probe.pop, "pickerEmpty");
                probe.check(svc4.nerdState === "error" && svc4.nerdError.indexOf("offline") === 0, "an offline fetch is a stated reason (" + svc4.nerdState + ": " + svc4.nerdError + ")");
                probe.check(e !== null && e.visible && e.text === "No Nerd Fonts list: " + svc4.nerdError + ". Leave this tab and come back to retry.", "the failure line: " + (e ? JSON.stringify(e.text) : "no empty page"));
                tc.keyClick(Qt.Key_Tab);
                probe.check(probe.pop.tab === "emoji" && probe.pop.lay.flat.length > 1000, "the other tabs are untouched by it");
                curlMode.setText("ok");
                tc.keyClick(Qt.Key_Tab);
                tc.keyClick(Qt.Key_Tab);
                probe.check(svc4.nerdRuns === 2, "the next visit to the tab asks again (runs " + svc4.nerdRuns + ")");
                return false;
            },
            w => {
                if (svc4.nerdState === "loading")
                    return w < 15000 ? "wait" : false;
                probe.check(svc4.nerdState === "ready" && probe.curlCalls().length === 3, "after the failure the retry fetches and the tab works (" + svc4.nerdState + ", curl " + probe.curlCalls().length + ": the first, the failed one, the retry)");
                probe.popSvc = svc;
                return false;
            },
            // ---- clear recents: the Clear control, its Undo, Delete on one --------------------------------------------------------
            w => {
                sty.undoMs = 700;
                probe.setOrigin("0x1a2b", "kitty");
                svc.pick("Θ", ["Θ"]);
                probe.open();
                probe.rec0 = { emoji: probe.recs("emoji"), symbols: probe.recs("symbols"), nerd: probe.recs("nerd") };
                probe.check(probe.pop.tab === "emoji" && probe.rec0.emoji !== "" && probe.rec0.symbols !== "" && probe.rec0.nerd !== "",
                            "all three tabs have recents to clear (" + probe.rec0.emoji.length + " / " + probe.rec0.symbols.length + " / " + probe.rec0.nerd.length + " chars)");
                return false;
            },
            w => (w < 300 ? "wait" : false),
            w => {
                const b = probe.clearBtn();
                const L = probe.pop.lay;
                probe.check(b !== null && b.visible && !b.undoing && L.rows[0].kind === "head" && L.rows[0].sec === "recent",
                            "the Recent header carries the Clear control");
                probe.headY = b ? b.headY : -1;
                probe.clickItem(b);
                return false;
            },
            w => {
                if (probe.recs("emoji") !== "")
                    return w < 3000 ? "wait" : false;
                const b = probe.clearBtn();
                probe.check(probe.recs("emoji") === "", "Clear empties this tab's recents");
                probe.check(probe.recs("symbols") === probe.rec0.symbols && probe.recs("nerd") === probe.rec0.nerd,
                            "Clear empties only this tab's recents (symbols and nerd untouched)");
                probe.check(b !== null && b.visible && b.undoing && b.headY === probe.headY && probe.pop.lay.rows[0].sec !== "recent",
                            "the control turns into Undo where the header was, the Recent section gone (y " + (b ? b.headY : "?") + ")");
                return false;
            },
            w => (w < 400 ? "wait" : false),
            w => {
                const st = probe.stateRecs();
                probe.check(probe.rec0.emoji.split("|").every(c => st[c] === undefined) && st["Θ"] !== undefined, "the state file follows the clear (the emoji records are out, the symbol's stays)");
                probe.clickItem(probe.clearBtn());
                return false;
            },
            w => {
                if (probe.recs("emoji") === "")
                    return w < 3000 ? "wait" : false;
                const b = probe.clearBtn();
                probe.check(probe.recs("emoji") === probe.rec0.emoji, "Undo puts back exactly what was cleared, in the same order");
                probe.check(b !== null && b.visible && !b.undoing && probe.pop.lay.rows[0].sec === "recent", "the Recent section and its Clear are back");
                return false;
            },
            w => (w < 400 ? "wait" : false),
            w => {
                const st = probe.stateRecs();
                probe.check(probe.rec0.emoji.split("|").every(c => st[c] !== undefined), "the state file follows the undo");
                return false;
            },
            // a tab change ends the Undo for good
            w => {
                probe.clickItem(probe.clearBtn());
                return false;
            },
            w => {
                if (probe.recs("emoji") !== "")
                    return w < 3000 ? "wait" : false;
                tc.keyClick(Qt.Key_Tab);
                const b = probe.clearBtn();
                probe.check(probe.pop.tab === "symbols" && b !== null && b.visible && !b.undoing && probe.pop._undo === null,
                            "another tab's Recent header offers Clear, not this clear's Undo");
                tc.keyClick(Qt.Key_Backtab);
                probe.check(probe.pop.tab === "emoji" && probe.recs("emoji") === "" && !probe.clearBtn().visible, "back on Emoji the clear stands and nothing is on offer");
                // put the emoji recents back for the Delete checks
                for (const c of probe.rec0.emoji.split("|"))
                    svc.pick(c, [c]);
                return false;
            },
            // Delete on a highlighted recent tile forgets that one
            w => {
                probe.open();
                const rec = probe.recs("emoji").split("|");
                probe.check(rec.length >= 4, "the emoji recents are back (" + rec.length + ")");
                probe.pop.moveTo(1);
                probe.check(probe.pop.currentItem.ch === rec[1] && probe.pop.lay.rows[probe.pop.lay.rowOf[1]].sec === "recent", "the highlight is on the second recent");
                const sy = probe.recs("symbols");
                const ne = probe.recs("nerd");
                tc.keyClick(Qt.Key_Delete);
                const after = probe.recs("emoji").split("|");
                probe.check(after.indexOf(rec[1]) < 0 && after.length === rec.length - 1 && after.join("|") === rec.filter(c => c !== rec[1]).join("|"),
                            "Delete on a highlighted recent removes that one and only that one (" + after.length + " of " + rec.length + ")");
                probe.check(probe.recs("symbols") === sy && probe.recs("nerd") === ne, "Delete leaves the other tabs' recents alone");
                probe.deleted = rec[1];
                return false;
            },
            w => (w < 400 ? "wait" : false),
            w => {
                probe.check(probe.stateRecs()[probe.deleted] === undefined, "the state file follows the Delete");
                return false;
            },
            // Delete elsewhere does what it did: nothing
            w => {
                const rows = probe.pop.lay;
                // the tiles of the Recent section (its row holds one line of them)
                let n = 0;
                while (n < rows.flat.length && rows.rows[rows.rowOf[n]].sec === "recent")
                    n++;
                const total = probe.recs("emoji").split("|").length;
                probe.pop.moveTo(n);
                const sec = rows.rows[rows.rowOf[n]].sec;
                probe.check(sec !== "recent", "the highlight is outside Recent (" + sec + ")");
                const keys = Object.keys(svc._frecency).sort().join("");
                const closes = probe.closes;
                tc.keyClick(Qt.Key_Delete);
                probe.check(Object.keys(svc._frecency).sort().join("") === keys && probe.recs("emoji").split("|").length === total && probe.closes === closes && probe.pop.query === "",
                            "Delete with the highlight outside Recent changes nothing");
                // with a search typed there is no Recent section: Delete leaves the query and the memory as they were
                const first = svc.recentsOf("emoji", 99)[0];
                probe.pop.setQuery(first.name);
                const keys2 = Object.keys(svc._frecency).sort().join("");
                probe.check(probe.pop.currentItem !== null && probe.pop.lay.rows.every(r => r.sec !== "recent"), "a search shows no Recent section");
                tc.keyClick(Qt.Key_Delete);
                probe.check(Object.keys(svc._frecency).sort().join("") === keys2 && probe.pop.query === first.name, "Delete with a search typed forgets nothing and leaves the query");
                probe.pop.setQuery("");
                return false;
            },
            // the Undo runs out: what was cleared is gone for good
            w => {
                probe.open();
                probe.rec1 = probe.recs("emoji");
                probe.clickItem(probe.clearBtn());
                return false;
            },
            w => {
                if (probe.recs("emoji") !== "")
                    return w < 3000 ? "wait" : false;
                const b = probe.clearBtn();
                probe.check(b !== null && b.undoing, "the Undo is on offer after the clear");
                return false;
            },
            w => {
                const b = probe.clearBtn();
                if (b !== null && b.visible)
                    return w < 4000 ? "wait" : false;
                probe.check(b !== null && !b.visible && !b.undoing && probe.pop._undo === null, "the Undo expires and its control goes");
                probe.check(probe.recs("emoji") === "", "after the expiry the recents stay gone");
                probe.check(probe.recs("symbols") === probe.rec0.symbols && probe.recs("nerd") === probe.rec0.nerd, "the other tabs still have theirs");
                return false;
            },
            w => (w < 400 ? "wait" : false),
            w => {
                const st = probe.stateRecs();
                probe.check(probe.rec1.split("|").every(c => st[c] === undefined), "the state file has no trace of what expired");
                return false;
            },
            // ---- picker.jsonc ----
            w => {
                probe.pop.tabList = ["symbols", "emoji", "symbols"];
                probe.open();
                probe.check(probe.pop.tab === "emoji" && probe.pop.tabIds.length === 2, "config: it opens on openTab, a tab named twice is one");
                tc.keyClick(Qt.Key_Tab);
                probe.check(probe.pop.tab === "symbols", "config: Tab goes round the tabs there are (" + probe.pop.tab + ")");
                probe.check(probe.pop.sections[0].id === "recent", "config: the Recent row stands above the list");
                probe.pop.recents = false;
                probe.check(probe.pop.sections[0].id !== "recent", "config: recents false: it does not");
                probe.pop.recents = true;
                probe.pop.openTab = "nerd";
                probe.open();
                probe.check(probe.pop.tab === "symbols", "config: an openTab that is no tab: the first one (" + probe.pop.tab + ")");
                probe.pop.openTab = "last";
                probe.pop.setTab("emoji");
                probe.open();
                probe.check(probe.pop.tab === "emoji" && svc.lastTab === "emoji", "config: openTab 'last' is the tab it was on");
                probe.pop.tabList = ["nerd"];
                probe.check(probe.pop.tab === "nerd", "config: a tab taken away under the popup gives way to the first one (" + probe.pop.tab + ")");
                probe.pop.nerdPick = "name";
                probe.pop.openTab = "emoji";
                probe.open();
                probe.type("lightbulb on");
                tc.keyClick(Qt.Key_Return, Qt.ControlModifier);
                probe.check(svc.lastPick.text === probe.expect, "config: nerdPick 'name': Ctrl+Enter picks the GLYPH");
                probe.open();
                probe.type("lightbulb on");
                svc.copyOnly = true;
                probe.baseCopies = probe.copies().length;
                probe.baseDispatch = probe.dispatches().length;
                tc.keyClick(Qt.Key_Return);
                probe.check(svc.lastPick.text === "nf-md-lightbulb_on" && svc.lastPick.pasteKey === "", "config: nerdPick 'name': Enter picks the NAME (" + svc.lastPick.text + ")");
                return false;
            },
            w => {
                if (w < 1200)
                    return "wait";
                const c = probe.copies();
                probe.check(c[c.length - 1] === "nf-md-lightbulb_on", "config: pick 'copy': it is on the clipboard");
                probe.check(probe.dispatches().length === probe.baseDispatch, "config: pick 'copy': no paste key is sent (" + (probe.dispatches().length - probe.baseDispatch) + ")");
                let st = {};
                try {
                    st = JSON.parse(probe.disk(probe.stateDir + "/picker/state.json"));
                } catch (e) {}
                probe.check(st.tab === "nerd", "config: the last tab is in the state file (" + st.tab + ")");
                return false;
            }
        ];
        driver.start();
    })
    property string expect: ""
    property var svcB: null
    PickerService {
        id: svc4
        live: true
        stateOverride: probe.stateDir + "/picker4"
        nerdCacheOverride: probe.stateDir + "/nerdfail"
    }
    Component {
        id: svc3
        PickerService {
            live: true
            stateOverride: probe.stateDir + "/picker3"
            nerdCacheOverride: probe.stateDir + "/nerdcache"
        }
    }
    Component {
        id: svc2
        PickerService {
            live: true
            stateOverride: probe.stateDir + "/picker"
        }
    }
}
