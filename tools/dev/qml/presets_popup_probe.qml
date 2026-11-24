pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/presets"
import "modules/presets/data"
import "modules/presets/PresetFaceLayout.js" as FaceLayout

// =============================================================================
// presets_popup_probe.qml -- the presets popup (modules/presets) on its MOCK service, driven by real synthetic clicks on the window. Run by
// tools/dev/presets_popup_probe.sh (offscreen, a sandbox copy, a private config / state). Each check prints `PP ok|FAIL <what>`; the last
// line is `PP RESULT PASS|FAIL (<n>/<n> checks)`.
//
//   size      a card per preset and the save card; the popup's implicit size is the grid's
//   face      every tile on whole pixels inside its screen; a tabbed group is ONE tile with its tab count; "+N" past the width
//   confirm   Load with windows to close asks first ("Close N windows?") and loads on the second click; with none it loads at once; the
//             confirm goes back by itself; Add never asks
//   rename    a rename commits; a taken name is refused (the field stays, the shake runs, nothing renamed)
//   delete    a deleted card stays with an Undo; Undo brings it back; the window's end drops it
//   save      the save card makes a preset; a taken name is refused with the reason on the card
//   escape    the Escape chain: a confirm is taken back first, then the popup may close
//   columns   no preset: the save card alone, one column; the first save and the last delete on show: the cards stand at the edges of the
//             host's easing box at every width of it, and at rest at the end; a change out of sight moves nothing on its own
//   start     a live service reads the list once by itself (a stub tool), so the first open has its columns
// PRESETS_PROBE unset: the file loads and quits (a bare smoke run).
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property bool armed: Quickshell.env("PRESETS_PROBE") === "1"
    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("PP " + (ok ? "ok " : "FAIL ") + what);
    }
    function finish(): void {
        console.log("PP RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
        quitT.start();
    }
    Timer {
        id: quitT
        interval: 0
        onTriggered: Qt.quit()
    }

    property int closes: 0

    Window {
        id: win
        visible: probe.armed
        width: 640
        height: 700
        color: Theme.surface

        AppLookup {
            id: lookup
        }
        PresetsService {
            id: svc
            live: false
            undoMs: 5000
        }
        PresetsPopup {
            id: popup
            width: implicitWidth
            height: implicitHeight
            service: svc
            appLookup: lookup
            motionRunning: false
            onCloseRequested: probe.closes++
        }
    }
    TestCase {
        id: tc
        when: false
    }
    // a LIVE service over the runner's stub tool (it answers `preset list` with one preset and logs its calls): made by the `start` step
    Component {
        id: liveComp
        PresetsService {
            live: true
            tool: Quickshell.env("PRESETS_STUB") || "/nonexistent"
        }
    }
    property var liveSvc: null
    property var liveFace: null
    property int liveMark: 0

    // ---- helpers ------------------------------------------------------------------------------------------------------
    function all(item: Item, name: string, out: var): var {
        const acc = out || [];
        if (!item)
            return acc;
        if (item.objectName === name)
            acc.push(item);
        for (let i = 0; i < item.children.length; i++)
            probe.all(item.children[i], name, acc);
        return acc;
    }
    // the card (PresetCard) an item stands in
    function cardOf(item: Item): var {
        let p = item;
        while (p && !(p.row !== undefined && p.askLoad !== undefined))
            p = p.parent;
        return p;
    }
    function buttonOf(name: string, which: string): var {
        const bs = probe.all(popup, which);
        for (let i = 0; i < bs.length; i++) {
            const c = probe.cardOf(bs[i]);
            if (c && c.name === name && bs[i].visible)
                return bs[i];
        }
        return null;
    }
    function click(item: Item, button: int): void {
        const p = item.mapToItem(win.contentItem, item.width / 2, item.height / 2);
        tc.mouseMove(win.contentItem, p.x - 3, p.y - 3);
        tc.mouseMove(win.contentItem, p.x, p.y);
        tc.mouseClick(win.contentItem, p.x, p.y, button || Qt.LeftButton);
    }
    // a card's left edge in the popup's frame
    function xOf(card: Item): real {
        return card.mapToItem(popup, 0, 0).x;
    }
    function saveCard(): var {
        let c = probe.all(popup, "presetName")[0];
        while (c && c.problem === undefined)
            c = c.parent;
        return c;
    }
    function firstCard(): var {
        const b = probe.all(popup, "presetLoad")[0];
        return b ? probe.cardOf(b) : null;
    }
    // the box eases from one width to the other: the worst distance of the save card from the box's right edge and of the first card from its left
    function worstEdge(from: real, to: real): real {
        let worst = 0;
        for (let k = 0; k <= 16; k++) {
            const w = from + (to - from) * k / 16;
            popup.boxWidth = w;
            const left = (popup.width - w) / 2;
            worst = Math.max(worst, Math.abs(probe.xOf(probe.saveCard()) + 280 - (left + w - 12)));
            const f = probe.firstCard();
            if (f)
                worst = Math.max(worst, Math.abs(probe.xOf(f) - (left + 12)));
        }
        return worst;
    }
    function has(what: string): bool {
        return svc.calls.indexOf(what) >= 0;
    }
    function names(): var {
        return svc.presets.filter(p => !p.deleted).map(p => p.name);
    }

    // ---- the steps: each returns true when done, "wait" to be asked again next tick ----------------------------------------------
    property int step: 0
    property int waited: 0
    property var steps: [
        function () {
            svc.refresh();
            svc.refreshCurrent();
            popup.style.confirmMs = 600;
            return true;
        },
        function () {
            // size
            const cards = probe.all(popup, "presetLoad").length;
            probe.check(cards === 4, "size: a card per preset (" + cards + " of 4)");
            probe.check(probe.all(popup, "presetName").length === 1, "size: the save card is there");
            const w = 2 * 12 + 2 * 280 + 12;
            probe.check(popup.implicitWidth === w, "size: the popup is two cards wide (" + popup.implicitWidth + " vs " + w + ")");
            probe.check(popup.implicitHeight === Math.ceil(2 * 12 + 3 * popup.cardHeight + 2 * 12), "size: three rows tall (" + popup.implicitHeight + ")");
            // face
            let whole = true, inside = true;
            for (let i = 0; i < svc.presets.length; i++) {
                const pl = FaceLayout.plan(svc.presets[i].face, 256, 72, popup.style);
                for (const s of pl.screens) {
                    for (const t of s.tiles) {
                        if (t.x !== Math.round(t.x) || t.y !== Math.round(t.y) || t.w !== Math.round(t.w) || t.h !== Math.round(t.h))
                            whole = false;
                        if (t.x < 0 || t.y < 0 || t.x + t.w > s.w || t.y + t.h > s.h)
                            inside = false;
                    }
                    if (s.x !== Math.round(s.x) || s.w !== Math.round(s.w))
                        whole = false;
                }
            }
            probe.check(whole, "face: every screen and tile on whole pixels");
            probe.check(inside, "face: every tile inside its screen");
            const dev = FaceLayout.plan(svc.presets.find(p => p.name === "dev").face, 256, 72, popup.style);
            probe.check(dev.screens.length === 3 && dev.screens[0].tiles.length === 1 && dev.screens[0].tiles[0].tabs === 6 && dev.screens[0].tiles[0].activeTab === 2,
                "face: the six-tab group is one tile with six tabs, the third shown");
            probe.check(dev.special.length === 1 && dev.special[0] === "kitty", "face: the special workspace is a badge");
            probe.check(dev.screens[0].tiles[0].locked === true && dev.screens[1].tiles[0].locked === false, "face: a locked group's tile says locked, a lone window does not");
            const every = FaceLayout.plan(svc.presets.find(p => p.name === "Everything").face, 256, 72, popup.style);
            probe.check(every.more > 0 && every.screens.length + every.more === 7, "face: seven workspaces end in +N (" + every.screens.length + " + " + every.more + ")");
            return true;
        },
        function () {
            // confirm: the first click asks
            probe.click(probe.buttonOf("dev", "presetLoad"));
            return true;
        },
        function () {
            const card = probe.cardOf(probe.buttonOf("dev", "presetLoad"));
            if (!card.confirming && probe.waited++ < 60)
                return "wait";
            probe.check(card.confirming && probe.buttonOf("dev", "presetLoad").text === "Close 3 windows?", "confirm: the first Load click asks ('" + probe.buttonOf("dev", "presetLoad").text + "')");
            probe.check(probe.has("plan dev replace") && !probe.has("load dev replace"), "confirm: it planned and did not load");
            probe.click(probe.buttonOf("dev", "presetLoad"));
            return true;
        },
        function () {
            probe.check(probe.has("load dev replace") && probe.closes === 1, "confirm: the second click loads and asks the owner to close");
            svc.mockClose = { "Writing": 0 };
            probe.click(probe.buttonOf("Writing", "presetLoad"));
            return true;
        },
        function () {
            if (!probe.has("load Writing replace") && probe.waited++ < 60)
                return "wait";
            probe.check(probe.has("load Writing replace"), "confirm: nothing to close loads at once");
            probe.click(probe.buttonOf("Media", "presetLoad"));
            probe.waited = 0;
            return true;
        },
        function () {
            const card = probe.cardOf(probe.buttonOf("Media", "presetLoad"));
            if (!card.confirming && probe.waited++ < 60)
                return "wait";
            probe.check(card.confirming, "confirm: Media asks");
            probe.check(popup.handleEscape() === true && !card.confirming, "escape: takes the confirm back first");
            probe.check(popup.handleEscape() === false, "escape: with nothing open, the popup may close");
            probe.click(probe.buttonOf("Media", "presetLoad"));
            probe.waited = 0;
            return true;
        },
        function () {
            const card = probe.cardOf(probe.buttonOf("Media", "presetLoad"));
            if (!card.confirming && probe.waited++ < 60)
                return "wait";
            // ... and goes back by itself
            if (card.confirming && probe.waited++ < 200)
                return "wait";
            probe.check(!card.confirming && !probe.has("load Media replace"), "confirm: goes back by itself, nothing loaded");
            probe.click(probe.buttonOf("Media", "presetAdd"));
            probe.check(probe.has("load Media add"), "add: loads at once");
            probe.waited = 0;
            return true;
        },
        function () {
            // rename: commit
            popup._startRename("dev");
            const f = probe.all(popup, "presetRename")[0];
            f.text = "work";
            tc.keyClick(Qt.Key_Return);
            return true;
        },
        function () {
            const n = probe.names();
            probe.check(n.indexOf("work") >= 0 && n.indexOf("dev") < 0, "rename: dev is work (" + n.join(",") + ")");
            popup._startRename("work");
            const f = probe.all(popup, "presetRename")[0];
            f.text = "Media";
            tc.keyClick(Qt.Key_Return);
            return true;
        },
        function () {
            const n = probe.names();
            const f = probe.all(popup, "presetRename")[0];
            const shake = probe.all(popup, "presetRenameShake")[0];
            probe.check(n.indexOf("work") >= 0 && f.visible && popup._renameFor === "work", "rename: a taken name is refused, the field stays");
            probe.check(!!shake && (shake.running || shake.offset !== 0), "rename: the refusal shakes");
            popup._endRename(false);
            probe.check(!f.visible, "rename: Escape-like cancel closes the field");
            // delete through the menu: a real right click opens it
            probe.click(probe.buttonOf("Media", "presetLoad"), Qt.RightButton);
            return true;
        },
        function () {
            const menu = probe.all(popup, "presetsMenu")[0];
            probe.check(!!menu && menu.open, "delete: a right click opens the menu");
            menu.triggered("delete");
            menu.open = false;
            return true;
        },
        function () {
            // the menu's outside-click layer goes with its fade: wait it out before the next click
            return probe.waited++ < 15 ? "wait" : true;
        },
        function () {
            const row = svc.presets.find(p => p.name === "Media");
            const undo = probe.all(popup, "presetUndo").find(u => u.visible);
            probe.check(!!row && row.deleted === true && !!undo, "delete: the card stays, deleted, with an Undo");
            if (undo)
                probe.click(undo);
            return true;
        },
        function () {
            const row = svc.presets.find(p => p.name === "Media");
            probe.check(!!row && row.deleted === false && probe.has("undelete Media"), "delete: Undo brings it back");
            svc.undoMs = 300;
            svc.remove("Writing");
            probe.waited = 0;
            return true;
        },
        function () {
            if (svc.presets.some(p => p.name === "Writing") && probe.waited++ < 200)
                return "wait";
            probe.check(!svc.presets.some(p => p.name === "Writing"), "delete: the Undo window's end drops the card");
            // save
            const f = probe.all(popup, "presetName")[0];
            f.text = "fresh";
            probe.click(probe.all(popup, "presetSave")[0]);
            return true;
        },
        function () {
            probe.check(probe.names().indexOf("fresh") >= 0, "save: the save card made a preset");
            const f = probe.all(popup, "presetName")[0];
            f.text = "Media";
            probe.click(probe.all(popup, "presetSave")[0]);
            return true;
        },
        function () {
            const nc = probe.all(popup, "presetName")[0].parent;
            let card = nc;
            while (card && card.problem === undefined)
                card = card.parent;
            probe.check(!!card && card.problem.indexOf("exists") >= 0 && probe.names().filter(n => n === "Media").length === 1, "save: a taken name is refused with the reason ('" + (card ? card.problem : "?") + "') calls: " + svc.calls.slice(-4).join(" | "));
            // columns: none saved
            svc.mockPresets = [];
            svc.refresh();
            probe.check(popup.columns === 1 && popup.implicitWidth === 304 && probe.xOf(probe.saveCard()) === 12, "columns: no preset: one column, the save card between equal paddings (" + popup.implicitWidth + " wide, the card at " + probe.xOf(probe.saveCard()) + ")");
            // the first preset saved while the popup is on show, the host's box still at the old width
            popup.boxWidth = 304;
            svc.save("first", false, null);
            probe.check(popup.columns === 2 && popup.implicitWidth === 596, "columns: the first preset asks for two (" + popup.implicitWidth + ")");
            const at = probe.xOf(probe.saveCard()) - (popup.width - 304) / 2;
            probe.check(at === 12 && probe.xOf(probe.firstCard()) - (popup.width - 304) / 2 === 12, "columns: the save card has not moved in the box, the saved card is under it (" + at + ")");
            const grow = probe.worstEdge(304, 596);
            probe.check(grow < 0.01, "columns: the cards stand at the box's edges all the way out (" + grow.toFixed(2) + " px off at worst)");
            probe.check(popup._from === 0 && probe.xOf(probe.firstCard()) === 12 && probe.xOf(probe.saveCard()) === 304, "columns: at rest two columns, nothing under way");
            // ... and the last one gone
            svc.mockPresets = [];
            svc.refresh();
            const shrink = probe.worstEdge(596, 304);
            probe.check(shrink < 0.01 && popup._from === 0 && probe.xOf(probe.saveCard()) === 12, "columns: the last preset gone: the save card comes back with the box's edge (" + shrink.toFixed(2) + " px off at worst)");
            // out of sight: no change is under way when the popup is shown again, whatever the box's width
            popup.visible = false;
            svc.save("second", false, null);
            popup.visible = true;
            probe.check(popup._from === 0 && probe.xOf(probe.firstCard()) === 12 && probe.xOf(probe.saveCard()) === 304, "columns: a change out of sight leaves the grid at rest");
            // turned round half way: no jump
            popup.boxWidth = 596;
            svc.mockPresets = [];
            svc.refresh();
            popup.boxWidth = 450;
            const before = probe.xOf(probe.saveCard()) - (popup.width - 450) / 2;
            svc.save("third", false, null);
            const after = probe.xOf(probe.saveCard()) - (popup.width - 450) / 2;
            probe.check(before === after && after === 450 - 12 - 280, "columns: turned round half way, the save card stays where it is in the box (" + before + " -> " + after + ")");
            popup.boxWidth = Qt.binding(() => popup.width);
            probe.check(popup._from === 0, "columns: the box arrived ends it");
            return true;
        },
        // ---- the save card follows the desktop while the tab is watched (PresetsService holdWatch / desktopChanged) ----
        function () {
            svc.watchDebounceMs = 60;
            svc.refreshCurrent();
            probe.liveFace = svc.current;
            probe.liveMark = svc.calls.length;
            // not watched: a desktop change reads nothing
            const m = JSON.parse(JSON.stringify(svc.mockCurrent));       // a new desktop (a copy: the mock hands out its own object)
            m.face.workspaces = m.face.workspaces.slice(0, 2);
            svc.mockCurrent = m;
            svc.desktopChanged("openwindow");
            return true;
        },
        function () {
            if (probe.waited++ < 8)
                return "wait";
            probe.check(svc.current === probe.liveFace && svc.calls.slice(probe.liveMark).indexOf("current") < 0, "live: unwatched, a desktop change reads nothing");
            // watched (two popups, one lets go): a burst of twenty events is one read, and the card shows it
            const lw0 = svc.calls.length;
            svc.holdWatch(probe);
            svc.holdWatch(popup);
            svc.releaseWatch(popup);
            probe.check(svc.watching, "live: a watch held by another popup stays");
            const lw = svc.calls.slice(lw0).filter(c => c.indexOf("lockwatch") === 0);
            probe.check(lw.length === 1 && lw[0] === "lockwatch start", "live: the watch starts the lock watch once, and a second holder letting go stops nothing (" + lw.join(", ") + ")");
            // the events that change what the card shows, in Hyprland's own shapes; the ones that do not
            const yes = [["activewindowv2", "55e0c315e6d0"], ["togglegroup", "1,55e0c315e6d0"], ["moveintogroup", "55e0c315e6d0"],
                ["moveoutofgroup", "55e0c315e6d0"], ["lockgroups", "1"], ["custom", "lares-presets-lock"], ["openwindow", "55e0c315e6d0,1,kitty,kitty"]];
            const no = [["windowtitlev2", "55e0c315e6d0,bash"], ["custom", "something-else"], ["activewindow", "kitty,bash"]];
            probe.check(yes.every(e => svc.isDesktopEvent(e[0], e[1])), "live: a tab flip, (un)grouping, a lock and the lock watch's word are desktop changes ("
                + yes.filter(e => !svc.isDesktopEvent(e[0], e[1])).map(e => e[0] + ">>" + e[1]).join(" ") + ")");
            probe.check(!no.some(e => svc.isDesktopEvent(e[0], e[1])), "live: a title change and another custom word are not");
            probe.liveMark = svc.calls.length;
            for (let i = 0; i < 20; i++)
                svc.desktopChanged(i % 2 ? "movewindowv2" : "workspacev2");
            probe.all(popup, "presetName")[0].text = "keep me";
            return true;
        },
        function () {
            if (svc.current === probe.liveFace && probe.waited++ < 40)
                return "wait";
            const reads = svc.calls.slice(probe.liveMark).filter(c => c === "current").length;
            const face = probe.all(popup, "presetNewFace")[0];
            probe.check(svc.current !== probe.liveFace && svc.current.face.workspaces.length === 2 && !!face && face.face === svc.current.face, "live: a change while watched reaches the card (" + (svc.current ? svc.current.face.workspaces.length : "?") + " workspaces on it)");
            probe.check(reads === 1, "live: a burst of events is one read (" + reads + ")");
            probe.check(probe.all(popup, "presetName")[0].text === "keep me", "live: the name being typed stays");
            // the same desktop read again keeps the very same picture (nothing redrawn)
            probe.liveFace = svc.current;
            svc.mockCurrent = JSON.parse(JSON.stringify(svc.current));
            svc.desktopChanged("activewindow");
            svc.desktopChanged("focusedmon");
            return true;
        },
        function () {
            if (probe.waited++ < 8)
                return "wait";
            probe.check(svc.current === probe.liveFace, "live: the same desktop read again keeps the picture");
            // a tab flip and a lock, told as Hyprland tells them, reach the card's face
            const m = JSON.parse(JSON.stringify(svc.current));
            for (const w of m.face.workspaces[0].windows) {
                w.group.active = w.group.index === 2;
                w.group.locked = true;
            }
            svc.mockCurrent = m;
            probe.liveFace = svc.current;
            if (svc.isDesktopEvent("activewindowv2", "55e0c33ddcb0"))
                svc.desktopChanged("activewindowv2");
            return true;
        },
        function () {
            if (svc.current === probe.liveFace && probe.waited++ < 40)
                return "wait";
            const face = probe.all(popup, "presetNewFace")[0];
            const t = face && face.plan.screens.length > 0 ? face.plan.screens[0].tiles[0] : null;
            probe.check(!!t && t.activeTab === 2 && t.cls === "com.microsoft.VSCode", "live: a tab flip reaches the card (" + (t ? t.activeTab + " " + t.cls : "no tile") + ")");
            probe.check(!!t && t.locked === true, "live: a group's lock reaches the card");
            // let go: nothing is read any more
            svc.releaseWatch(probe);
            probe.liveMark = svc.calls.length;
            svc.desktopChanged("openwindow");
            return true;
        },
        function () {
            if (probe.waited++ < 8)
                return "wait";
            probe.check(!svc.watching && svc.calls.slice(probe.liveMark).indexOf("current") < 0, "live: let go, a desktop change reads nothing");
            probe.check(svc.calls.slice(probe.liveMark - 1).indexOf("lockwatch stop") >= 0, "live: let go, the lock watch is stopped");
            return true;
        },
        function () {
            probe.liveSvc = liveComp.createObject(win.contentItem);
            probe.check(probe.liveSvc.presets.length === 0, "start: nothing is known yet");
            return true;
        },
        function () {
            if (!probe.liveSvc.ready && probe.waited++ < 120)
                return "wait";
            probe.check(probe.liveSvc.ready && probe.liveSvc.presets.length === 1, "start: a live service reads the list by itself (" + probe.liveSvc.presets.length + " preset, calls: " + probe.liveSvc.calls.join(" | ") + ")");
            probe.check(probe.liveSvc.calls.join() === "list", "start: once, and nothing else is asked (" + probe.liveSvc.calls.join(" | ") + ")");
            return true;
        }
    ]
    Timer {
        id: driver
        interval: 30
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
