pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Every directory mockups/shell.qml takes types from: a file built by URL finds a directory's types only while a file
// quickshell scanned imports it (CLAUDE.md, Quickshell).
import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/osd"
import "modules/shell"

// =============================================================================
// tools/dev/qml/reel_shell_sheet.qml -- the reel slot's strips over the popups of the REAL shell frame (tools/dev/reel_shell_sheet.sh;
// GooeyEngine: THE REEL PASS). mockups/shell.qml (the shell's own ShellFrame on its mock services, one 2880 x 1620 output at zoom 1) is
// built here as a component -- the runner copies this file into the sandbox copy's mockups/ to run it -- and each cell is driven through
// it with what both this tree and an older one have (the owners' own switches), so the same file renders a BEFORE and an AFTER.
//
// Env:  RS_OUT=<dir>   RS_CELLS=<cell>;<cell>...   RS_MERGE_T (0.25)   a cell:  <name>=<popup>:<reel>:<state>
//   popup   none | an owner key (weather, clipboard, notes, llm, theme, ...): opened first, at rest
//   reel    power | idle (the reels, pinned open) | tray (the tray's strip, pinned) | traylabel (its first item's label out) |
//           traymenu (a scripted item's menu out) | none
//   state   rest             the scene at rest
//           merge            the reel closed and held at RS_MERGE_T of its close clock, the content's fade written to the share a
//                            160 ms fade has reached at 400 ms (the strip half merged into the bar)
//           to-<reel>:<n>    the strip sent to another reel (power | idle) and FILMED on its way: the engine's clocks slowed
//                            RS_SLOW times (8), a grab each time the travel's clock has gone on by 1 / n: <name>_f<i>.png
//                            (`:<n>:<until>` films the clock's first part only, up to <until>)
//           open-<owner>:<n> the popup <owner> opened by its key (its owner's shortcutPressed) UNDER the reel that is out (the popup
//                            named first is ignored: none), filmed the same way on the popup's clock: a key-open under an open reel
//           trace-<reel>     the strip sent to another reel and LEFT TO RUN: no picture, `RSTRACE <name> t=<clock> box=<x0,y0,x1,y1>
//                            drawn=<the field's own box of it> phase=<phase> swapping=<0|1>` on every frame until it rests (engine px)
// Each grab is the whole stage, <name>.png, with `RSCELL <name> reel=<x0,y0,x1,y1> popup=<...> levels=<...>` (stage px; `-` for none): the
// runner's composer crops round the reel. `opengap=<ms>` is the longest gap between two frames while the reel opened. Prints RSSHEET DONE; a step that never comes is `RSSHEET FAIL <cell> <step>`.
// =============================================================================
Scope {
    id: rig

    readonly property string out: Quickshell.env("RS_OUT") || ""
    readonly property real mergeT: Number(Quickshell.env("RS_MERGE_T") || 0.25)
    readonly property var cells: (Quickshell.env("RS_CELLS") || "").split(";").filter(x => x !== "").map(rig.parse)
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null

    function parse(s) {
        const eq = s.indexOf("=");
        const p = s.slice(eq + 1).split(":");
        return { name: s.slice(0, eq), pop: p[0] || "none", reel: p[1] || "none", state: p[2] || "rest", n: Number(p[3]) || 8, until: Number(p[4]) || 2 };
    }

    Component.onCompleted: {
        if (rig.out === "") {
            console.log("RSSHEET no RS_OUT: nothing to do");
            quitLater.start();
            return;
        }
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("RSSHEET the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        tick.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }

    function owner(key) {
        return rig.win.frame.owners[key];
    }
    readonly property var deepSpec: ({
        id: "sheet-deep", title: "Deep menus", icon: "", status: "Active", category: "ApplicationStatus",
        menu: [{ text: "Header", enabled: false }, { isSeparator: true },
               { text: "_Available networks", children: [{ text: "Network 2" }, { text: "Network 3" }] },
               { text: "Edit Connections…" }]
    })
    property string _deepKey: ""
    function deepKey() {
        if (rig._deepKey === "")
            rig._deepKey = rig.owner("windowtray").tray.add(rig.deepSpec);
        return rig._deepKey;
    }

    // ---- what a cell asks of the shell ------------------------------------------------------------------------------------
    function reelBase(reel) {
        return reel === "traylabel" || reel === "traymenu" ? "tray" : reel;
    }
    function openReel(reel) {
        const b = rig.reelBase(reel);
        if (b === "power" || b === "idle") {
            rig.owner(b).pinnedOpen = true;
        } else if (b === "tray") {
            const o = rig.owner("windowtray");
            rig.deepKey();
            o.pinnedOpen = true;
            o.open();
        }
    }
    function reelLevel(reel) {
        const o = rig.owner("windowtray");
        if (reel === "traymenu")
            o.openMenu(rig.deepKey());
        else if (reel === "traylabel")
            o.cellHover(rig.deepKey(), o.rowIndexOf(rig.deepKey()), true);
    }
    function closeReel(reel) {
        const b = rig.reelBase(reel);
        if (b === "power" || b === "idle") {
            rig.owner(b).pinnedOpen = false;
        } else if (b === "tray") {
            const o = rig.owner("windowtray");
            o.pinnedOpen = false;
            o.close();
        }
    }
    function reelOut() {
        const E = rig.engine;
        return E.reelOpen && E.reelPhase === "open" && E.theReel.contentOpacity >= 0.999 && E.theReel.slideT >= 1;
    }
    function levelOut() {
        const C = rig.engine.reelChildPopups[0];
        return C.phase === "open" && C.contentOpacity >= 0.999;
    }
    function popupOut(key) {
        const E = rig.engine;
        return E.popupOpen && E.thePopup.phase === "open" && E.thePopup.contentOpacity >= 0.999 && E.popupOwnerId !== "";
    }
    function allClosed() {
        const E = rig.engine;
        return E.reelPhase === "closed" && !E.popupOpen && E.thePopup.phase === "closed" && E.reelChildPopups.every(C => C.phase === "closed")
            && E.childPopups.every(C => C.phase === "closed");
    }
    function closeAll() {
        rig.release();
        for (const k of ["power", "idle"])
            if (rig.owner(k).pinnedOpen)
                rig.owner(k).pinnedOpen = false;
        const t = rig.owner("windowtray");
        if (t.pinnedOpen || t.popupMine) {
            t.pinnedOpen = false;
            t.close();
        }
        if (rig.engine.thePopup.live)
            rig.engine.close();
    }

    // ---- a held clock: stopped, written, and stopped again if anything restarts it -----------------------------------------
    property var _held: []            // [{ slot, t, o }]
    function hold(S, t, o) {
        S.stop();
        S.slideT = 1;
        S.t = t;
        if (o !== undefined)
            S.contentOpacity = o;
        rig._held = rig._held.filter(h => h.slot !== S).concat([{ slot: S, t: t, o: o }]);
        rig.engine.layout();
    }
    function release() {
        const held = rig._held;
        rig._held = [];
        for (const h of held) {
            const S = h.slot;
            if (S.phase === "closing") {
                S.fadeTo(0, 1);
                S.runTo(1, 20);
            } else if (S.phase === "opening" || S.phase === "moving") {
                S.contentOpacity = 1;
                S.runTo(1, 20);
            }
        }
    }
    function keepHeld() {
        for (const h of rig._held) {
            if (h.slot.t !== h.t) {
                h.slot.stop();
                h.slot.t = h.t;
                if (h.o !== undefined)
                    h.slot.contentOpacity = h.o;
                rig.engine.layout();
            }
        }
    }

    // ---- the grab ---------------------------------------------------------------------------------------------------------
    property string grabbed: ""
    function fmt(b) {
        if (!b)
            return "-";
        const scene = rig.win.sheetGrabItem, E = rig.engine;
        const p0 = E.mapToItem(scene, b.x0, b.y0), p1 = E.mapToItem(scene, b.x1, b.y1);
        return [p0.x, p0.y, p1.x, p1.y].map(v => v.toFixed(2)).join(",");
    }
    function grab(name) {
        const E = rig.engine;
        const lv = E.reelChildPopups.filter(C => C.phase !== "closed" && C.box).map(C => rig.fmt(C.box)).join("/") || "-";
        console.log("RSCELL " + name + " reel=" + rig.fmt(E.reelPhase !== "closed" ? E.theReel.box : null)
                    + " popup=" + rig.fmt(E.thePopup.phase !== "closed" ? E.thePopup.box : null) + " levels=" + lv
                    + " t=" + E.theReel.t.toFixed(4) + " pt=" + E.thePopup.t.toFixed(4) + " phase=" + E.reelPhase + "/" + E.thePopup.phase
                    + " owner=" + (E.reelOwnerId || "-") + "/" + (E.popupOwnerId || "-") + " opengap=" + rig._gapMax
                    + (Quickshell.env("RS_DEBUG") ? " lc=" + E.theReel.localCenter + " to=" + JSON.stringify(E.theReel.toBox) + " from=" + JSON.stringify(E.theReel.fromBox) + " bar=" + E.theReel.barId : "")
                    + (E.reelCast && E.reelCast.drawn ? " pass=" + JSON.stringify(E.reelCast.drawn) : ""));
        rig.grabbed = "";
        rig.win.sheetGrabItem.grabToImage(r => {
            if (!r.saveToFile(rig.out + "/" + name + ".png"))
                console.log("RSSHEET FAIL " + name + " not saved");
            rig.grabbed = name;
        });
    }
    function grabStep(name) {
        return { what: "grab " + name, act: () => rig.grab(name), cond: () => rig.grabbed === name };
    }

    // ---- a cell's steps ---------------------------------------------------------------------------------------------------
    function build(c) {
        const S = [];
        const E = rig.engine;
        S.push({ what: "closed", act: () => rig.closeAll(), cond: () => rig.allClosed() });
        const opens = c.state.indexOf("open-") === 0 ? c.state.slice(5) : "";
        if (c.pop !== "none" && opens === "")
            S.push({ what: "popup " + c.pop, act: () => rig.win.openOwner(c.pop), cond: () => rig.popupOut(c.pop) });
        if (c.reel !== "none") {
            S.push({ what: "reel " + c.reel, act: () => { rig._gapMax = 0; rig._gapLast = Date.now(); rig._gapOn = true; rig.openReel(c.reel); },
                     cond: () => rig.reelOut(), then: () => { rig._gapOn = false; } });
            if (c.reel === "traylabel" || c.reel === "traymenu")
                S.push({ what: "level " + c.reel, act: () => rig.reelLevel(c.reel), cond: () => rig.levelOut() });
        }
        S.push({ what: "settle", act: () => {}, wait: 10 });
        if (c.state === "rest") {
            S.push(rig.grabStep(c.name));
        } else if (c.state === "merge") {
            S.push({ what: "closing", act: () => rig.closeReel(c.reel), cond: () => E.reelPhase === "closing" && E.theReel.t >= rig.mergeT });
            S.push({ what: "held", act: () => rig.hold(E.theReel, rig.mergeT, Math.max(0, 1 - rig.mergeT * 400 / 160)), wait: 5 });
            S.push(rig.grabStep(c.name));
        } else if (c.state.indexOf("to-") === 0) {
            const other = c.state.slice(3);
            S.push({ what: "travel to " + other, act: () => {
                         rig.slow(true);
                         rig._film = { name: c.name, slot: E.theReel, step: 1 / c.n, until: c.until, last: -1, i: 0, seen: false, done: false };
                         rig.owner(other).pinnedOpen = true;
                         rig.owner(rig.reelBase(c.reel)).pinnedOpen = false;
                     }, cond: () => rig._film.done && rig.grabbed !== "" });
            S.push({ what: "filmed", act: () => { rig._film = null; rig.slow(false); }, wait: 2 });
        } else if (c.state.indexOf("trace-") === 0) {
            const other = c.state.slice(6);
            S.push({ what: "trace to " + other, act: () => {
                         rig._trace = { name: c.name, n: 0 };
                         rig.owner(other).pinnedOpen = true;
                         rig.owner(rig.reelBase(c.reel)).pinnedOpen = false;
                     }, cond: () => E.reelOwnerId === other && rig.reelOut() });
            S.push({ what: "traced", act: () => { rig._trace = null; }, wait: 2 });
        } else if (opens !== "") {
            S.push({ what: "open " + opens, act: () => {
                         rig.slow(true);
                         rig._film = { name: c.name, slot: E.thePopup, step: 1 / c.n, until: c.until, last: -1, i: 0, seen: false, done: false };
                         const o = rig.owner(opens);
                         if (typeof o.shortcutPressed === "function")
                             o.shortcutPressed();
                         else
                             rig.win.openOwner(opens);
                     }, cond: () => rig._film.done && rig.grabbed !== "" });
            S.push({ what: "filmed", act: () => { rig._film = null; rig.slow(false); }, wait: 2 });
        }
        S.push({ what: "let go", act: () => rig.closeAll(), cond: () => rig.allClosed() });
        return S;
    }

    // ---- the longest gap between two frames while the reel opened (a pipeline built at its first draw is a frame that long): `opengap` ----
    property bool _gapOn: false
    property real _gapMax: 0
    property real _gapLast: 0
    FrameAnimation {
        running: rig._gapOn
        onTriggered: {
            const t = Date.now();
            if (rig._gapLast > 0)
                rig._gapMax = Math.max(rig._gapMax, t - rig._gapLast);
            rig._gapLast = t;
        }
    }

    // ---- a film: the engine's clocks slowed, a grab each time the watched clock has gone on by a step ----------------------------
    readonly property real slowBy: Number(Quickshell.env("RS_SLOW") || 8)
    property var _speeds: null
    function slow(on) {
        const E = rig.engine, keys = ["openMs", "migrateMs", "contentFadeMs", "resizeMs"];
        if (on && !rig._speeds) {
            rig._speeds = {};
            for (const k of keys) {
                rig._speeds[k] = E[k];
                E[k] = Math.round(E[k] * rig.slowBy);
            }
        } else if (!on && rig._speeds) {
            for (const k of keys)
                E[k] = rig._speeds[k];
            rig._speeds = null;
        }
    }
    property var _film: null
    FrameAnimation {
        running: rig._film !== null && !rig._film.done
        onTriggered: {
            const F = rig._film, S = F ? F.slot : null;
            if (!F || F.done)
                return;
            const moving = S.phase === "opening" || S.phase === "moving";
            if (moving)
                F.seen = true;
            if (!F.seen)
                return;
            const pending = F.i > 0 && rig.grabbed !== F.name + "_f" + (F.i - 1);
            if (pending)
                return;
            if (!moving) {
                // the frame at rest, then done (a film of the first part only ends without it)
                if (F.last < 2 && F.until >= 1) {
                    F.last = 2;
                    rig.grab(F.name + "_f" + (F.i++));
                } else {
                    F.done = true;
                }
                return;
            }
            if (S.t <= F.until && (S.t >= F.last + F.step || F.last < 0)) {
                F.last = S.t;
                rig.grab(F.name + "_f" + (F.i++));
            }
        }
    }

    // ---- a travel left to run, read on every frame --------------------------------------------------------------------------
    property var _trace: null
    FrameAnimation {
        running: rig._trace !== null
        onTriggered: {
            const E = rig.engine, R = E.theReel, T = rig._trace;
            if (!T || R.phase === "closed" || !R.box)
                return;
            const b = R.box;
            console.log("RSTRACE " + T.name + " n=" + (T.n++) + " t=" + R.t.toFixed(4) + " box=" + [b.x0, b.y0, b.x1, b.y1].map(v => v.toFixed(2)).join(",")
                        + " phase=" + R.phase + " owner=" + R.ownerId + " swapping=" + (R.swapping ? 1 : 0) + " ink=" + R.contentOpacity.toFixed(3));
        }
    }

    // ---- the sequence: one timer, a step waits for the thing's own state ----------------------------------------------------
    property int cellAt: -1
    property var steps: []
    property int stepAt: 0
    property bool acted: false
    property int ticks: 0
    property int settleWaits: 0
    Timer {
        id: tick
        interval: 30
        repeat: true
        onTriggered: {
            if (!rig.engine)
                return;
            rig.keepHeld();
            if (rig.cellAt < 0) {
                // the shell's start has tails (the prewarm blocks the GUI thread): begin on `settled`, two minutes at most
                const sv = rig.win.frame.services;
                if (sv && sv.settled === false && rig.settleWaits++ < 4000)
                    return;
                rig.cellAt = 0;
                rig.steps = rig.cells.length ? rig.build(rig.cells[0]) : [];
                rig.stepAt = 0;
                rig.acted = false;
                return;
            }
            if (rig.stepAt >= rig.steps.length) {
                rig.cellAt++;
                if (rig.cellAt >= rig.cells.length) {
                    console.log("RSSHEET DONE");
                    tick.stop();
                    quitLater.start();
                    return;
                }
                rig.steps = rig.build(rig.cells[rig.cellAt]);
                rig.stepAt = 0;
                rig.acted = false;
                return;
            }
            const s = rig.steps[rig.stepAt];
            if (!rig.acted) {
                rig.acted = true;
                rig.ticks = 0;
                s.act();
                return;
            }
            rig.ticks++;
            const ready = s.cond ? s.cond() : rig.ticks >= (s.wait || 1);
            if (!ready && rig.ticks < 600)
                return;
            if (ready && s.then)
                s.then();
            if (!ready) {
                const E = rig.engine;
                console.log("RSSHEET FAIL " + rig.cells[rig.cellAt].name + " step '" + s.what + "' never came: reel " + E.reelPhase + " (" + E.reelOwnerId
                            + ") popup " + E.thePopup.phase + " (" + E.popupOwnerId + ")");
            }
            rig.stepAt++;
            rig.acted = false;
        }
    }
}
