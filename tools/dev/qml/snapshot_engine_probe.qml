pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

// Every directory mockups/shell.qml takes types from (a file built by URL finds a directory's types only while a scanned file imports it).
import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/osd"
import "modules/shell"
import "modules/bar/system_update/snapshots"

// =============================================================================
// tools/dev/qml/snapshot_engine_probe.qml -- the snapshots page as the update popup's SECONDARY in the REAL engine (tools/dev/snapshot_engine_probe.sh).
//
// The shell mockup (the real ShellFrame on its mock services, whose SnapshotService is the mock) is built as a component; the update popup is
// opened as its button opens it, the page beside it, and driven:
//   E1 open     the page is the engine's child, a SnapshotsPage with cards, `ready`
//   E2 place    the page's content stands against the popup's (a constant gap, tops level or the page the taller), at rest and in each view
//   E3 views    quiet / normal / verbose with the page out: it stays out and stays against the popup
//   E4 height   a card opens and unfolds: the child's content follows the page's asked height, nothing is cut, no binding loop (the runner reads the log)
//   E5 hover    the pointer moves from the popup into the page: the popup's size and phase do not change, the page stays
//   E6 swipe    a sideways wheel started on the page: the page and the popup survive it
//   E7 escape   `escapeDetailFirst`: Escape puts the page away and the popup stays, a second closes it; off: one Escape closes both
//   E8 close    the popup's close takes the page with it
// Env: SE_OUT=<dir>  SE_TAG=<name>. Prints `SE ok|FAIL <id>: what`, then `SE DONE`. Grabs <out>/engine_<tag>_<state>.png.
// =============================================================================
Scope {
    id: rig

    readonly property string out: Quickshell.env("SE_OUT") || ""
    readonly property string tag: Quickshell.env("SE_TAG") || "x"
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null
    property int checks: 0
    property int fails: 0
    property var gaps: ({})

    function check(id: string, ok: bool, what: string): void {
        rig.checks++;
        if (!ok)
            rig.fails++;
        console.log("SE " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    function fmt(v: real): string {
        return Number(v).toFixed(2);
    }
    function box(it: Item): var {
        const sc = rig.win.sheetGrabItem;
        const a = it.mapToItem(sc, 0, 0), b = it.mapToItem(sc, it.width, it.height);
        return { x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y, r: b.x, b: b.y };
    }
    function grab(name: string): void {
        rig.win.sheetGrabItem.grabToImage(r => r.saveToFile(rig.out + "/engine_" + rig.tag + "_" + name + ".png"));
    }
    function popupItem(): var { return rig.engine.thePopup.contentItem; }
    function pageItem(): var { return rig.engine.childPopup.contentItem; }

    // the page against the popup: the gap between the page's right edge and the popup's left (side "start"), and how the tops sit
    function place(name: string): void {
        const P = rig.popupItem(), C = rig.pageItem();
        if (!P || !C || !C.cards) {
            rig.check("E2." + name, false, "no popup or page content");
            return;
        }
        const p = rig.box(P), c = rig.box(C);
        const gap = p.x - c.r;
        rig.gaps[name] = gap;
        const first = rig.gaps.rest;
        rig.check("E2." + name, Math.abs(gap - first) < 0.6 && gap > -1 && gap < 60,
                  "gap popup|page " + rig.fmt(gap) + " (at rest " + rig.fmt(first) + "), tops " + rig.fmt(p.y) + " / " + rig.fmt(c.y)
                  + ", popup " + rig.fmt(p.w) + "x" + rig.fmt(p.h) + ", page " + rig.fmt(c.w) + "x" + rig.fmt(c.h));
    }

    property int _step: 0
    property var steps: []
    property real _t0: 0
    TestCase {
        id: tc
        when: false
        name: "se"
    }

    Component.onCompleted: {
        if (rig.out === "") {
            console.log("SE no SE_OUT: nothing to do");
            quitLater.start();
            return;
        }
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("SE the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        rig.build();
        tick.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        id: tick
        interval: 100
        repeat: true
        onTriggered: {
            if (rig._step >= rig.steps.length) {
                tick.stop();
                console.log("SE DONE " + (rig.fails === 0 && rig.checks > 0 ? "PASS" : "FAIL") + " (" + (rig.checks - rig.fails) + "/" + rig.checks + ")");
                quitLater.start();
                return;
            }
            // Date.now() stands still under the runner's still clock: a step's age is its ticks
            rig._t0 += 100;
            const w = rig._t0 - 100;
            let r;
            try {
                r = rig.steps[rig._step](w);
            } catch (e) {
                rig.check("run." + rig._step, false, "a step threw: " + e);
                r = true;
            }
            if (r === "wait" && w < 15000)
                return;
            if (r === "wait")
                rig.check("run.timeout" + rig._step, false, "a step waited 15 s");
            rig._step++;
            rig._t0 = 0;
        }
    }
    function after(f: var, ms: int): var {
        return w => {
            if (w < ms)
                return "wait";
            f();
            return true;
        };
    }
    function settled(): bool {
        const sv = rig.win && rig.win.frame ? rig.win.frame.services : null;
        return !!sv && sv.settled !== false;
    }

    function build() {
        const S = rig.steps = [];
        const add = f => S.push(f);
        add(w => rig.settled() && w > 1500 ? true : "wait");
        add(rig.after(() => rig.win.openOwner("update"), 0));
        add(w => {
            const it = rig.popupItem();
            return it && typeof it.toggleSnapshots === "function" && rig.engine.thePopup.phase === "open" && w > 1200 ? true : "wait";
        });
        add(rig.after(() => {
            const P = rig.popupItem();
            rig.check("E1.service", !!P.snapshots && P._snapReady === true, "the popup has the snapshots service and it is ready");
            P.toggleSnapshots();
        }, 100));
        add(w => rig.engine.childPopup.phase === "open" && w > 1200 ? true : "wait");
        add(rig.after(() => {
            const C = rig.pageItem();
            rig.check("E1.page", !!C && !!C.cards && C.cards.count > 0 && rig.popupItem().secondaryOpen === true, "the page is the engine's child, with " + (C && C.cards ? C.cards.count : 0) + " cards");
            rig.place("rest");
            rig.grab("open");
        }, 500));

        // E3: the three views with the page out
        for (const m of ["quiet", "verbose", "normal"]) {
            add(rig.after(() => { rig.popupItem().verbosityMode = m; }, 0));
            add(rig.after(() => {
                const P = rig.popupItem();
                rig.check("E3." + m, P.verbosityMode === m && P.secondaryOpen === true && rig.engine.childPopup.phase === "open",
                          "view " + m + ": the page is still out (" + rig.engine.childPopup.phase + ")");
                rig.place(m);
                rig.grab(m);
            }, 1800));
        }

        // E4: a card opens and unfolds. Three snapshots, so the page is shorter than its maximum and its height has room to move.
        add(rig.after(() => {
            const sv = rig.win.frame.services.snapshots;
            sv.mockRecords = sv.mockRecords.slice(0, 3);
            rig.pageItem().pick = "-";
        }, 0));
        add(rig.after(() => {
            const C = rig.pageItem();
            rig.scratch = { nh: C.naturalHeight };
            rig.check("E4.short", C.naturalHeight < C.maxHeight - 40, "three snapshots, all shut: the page asks " + rig.fmt(C.naturalHeight) + " of at most " + C.maxHeight);
            C.pick = C.cards.itemAt(0).row.short;
        }, 1800));
        add(rig.after(() => {
            const C = rig.pageItem();
            rig.scratch.nh1 = C.naturalHeight;
            C.cards.itemAt(0).listOpen = true;
        }, 1500));
        add(rig.after(() => {
            const C = rig.pageItem(), B = rig.engine.childPopup;
            const c = rig.box(C), k = rig.win.shellScale;
            rig.check("E4.follow", C.naturalHeight > rig.scratch.nh1 + 20 && C.naturalHeight <= C.maxHeight + 0.5 && rig.scratch.nh1 > rig.scratch.nh + 20 && Math.abs(c.h / k - C.naturalHeight) < 1.5,
                      "the page asked " + rig.fmt(rig.scratch.nh) + " shut, " + rig.fmt(rig.scratch.nh1) + " with a card open, " + rig.fmt(C.naturalHeight) + " unfolded; its content is " + rig.fmt(c.h / k) + " tall (frame px), child box " + rig.fmt(B.height));
            rig.check("E4.cut", B.height * k + 0.5 >= c.h, "the child's box (" + rig.fmt(B.height) + ") is not smaller than the page (" + rig.fmt(c.h / k) + "): nothing is cut");
            rig.place("unfold");
            rig.grab("unfold");
        }, 2500));

        // E5: the pointer moves from the popup into the page
        add(rig.after(() => {
            const P = rig.box(rig.popupItem()), C = rig.box(rig.pageItem());
            const e = rig.engine;
            rig.scratch = { pw: P.w, ph: P.h, phase: e.thePopup.phase, p: P, c: C };
            const sc = rig.win.sheetGrabItem, root = rig.win.contentItem;
            const pt = (x, y) => sc.mapToItem(root, x, y);
            const a = pt(P.x + P.w / 2, P.y + P.h / 2);
            tc.mouseMove(root, a.x, a.y);
            for (let i = 1; i <= 12; i++) {
                const f = i / 12;
                const q = pt(P.x + P.w / 2 + (C.x + C.w / 2 - P.x - P.w / 2) * f, P.y + P.h / 2 + (C.y + C.h / 2 - P.y - P.h / 2) * f);
                tc.mouseMove(root, q.x, q.y);
            }
        }, 0));
        add(rig.after(() => {
            const P = rig.box(rig.popupItem());
            rig.check("E5.hover", Math.abs(P.w - rig.scratch.pw) < 0.5 && Math.abs(P.h - rig.scratch.ph) < 0.5 && rig.engine.thePopup.phase === rig.scratch.phase
                      && rig.engine.childPopup.phase === "open" && rig.popupItem().secondaryOpen === true,
                      "the pointer went popup -> page: popup " + rig.fmt(P.w) + "x" + rig.fmt(P.h) + " (was " + rig.fmt(rig.scratch.pw) + "x" + rig.fmt(rig.scratch.ph) + "), page still out");
        }, 700));

        // E6: a sideways two-finger wheel started on the page
        add(rig.after(() => {
            const C = rig.scratch.c, sc = rig.win.sheetGrabItem, root = rig.win.contentItem;
            const q = sc.mapToItem(root, C.x + C.w / 2, C.y + 80);
            tc.mouseMove(root, q.x, q.y);
            for (let i = 0; i < 6; i++)
                tc.mouseWheel(root, q.x, q.y, -90, 0);
            rig.scratch.mode0 = rig.popupItem().verbosityMode;
        }, 0));
        add(rig.after(() => {
            const P = rig.popupItem();
            rig.check("E6.swipe", rig.engine.thePopup.phase === "open" && rig.engine.childPopup.phase !== "closed" || P.secondaryOpen === false,
                      "a swipe on the page: popup " + rig.engine.thePopup.phase + ", page " + rig.engine.childPopup.phase + ", view " + rig.scratch.mode0 + " -> " + P.verbosityMode);
        }, 1800));
        add(rig.after(() => {
            if (!rig.popupItem().secondaryOpen)
                rig.popupItem().toggleSnapshots();
        }, 0));
        add(w => rig.engine.childPopup.phase === "open" && w > 800 ? true : "wait");

        // E7: Escape
        add(rig.after(() => {
            rig.engine.escapeDetailFirst = true;
            rig.engine.pressEscape();
        }, 0));
        add(rig.after(() => {
            const open = rig.engine.thePopup.phase === "open";
            rig.check("E7.detail", open && rig.popupItem().secondaryOpen === false, "escape (detail first): the page goes, the popup stays (" + rig.engine.thePopup.phase + ")");
            rig.engine.pressEscape();
        }, 900));
        add(w => rig.engine.thePopup.phase === "closed" && w > 800 ? true : "wait");
        add(rig.after(() => {
            rig.check("E7.second", rig.engine.thePopup.phase === "closed", "the second escape closes the popup");
            rig.win.openOwner("update");
        }, 100));
        add(w => rig.engine.thePopup.phase === "open" && w > 1200 ? true : "wait");
        add(rig.after(() => { rig.popupItem().toggleSnapshots(); }, 200));
        add(w => rig.engine.childPopup.phase === "open" && w > 1000 ? true : "wait");
        add(rig.after(() => {
            rig.engine.escapeDetailFirst = false;
            rig.engine.pressEscape();
        }, 0));
        add(rig.after(() => {
            rig.check("E7.plain", rig.engine.thePopup.phase === "closed" && rig.engine.childPopup.phase === "closed", "escape (plain): popup " + rig.engine.thePopup.phase + ", page " + rig.engine.childPopup.phase);
        }, 1800));

        // E8: the close takes the page with it
        add(rig.after(() => rig.win.openOwner("update"), 100));
        add(w => rig.engine.thePopup.phase === "open" && w > 1200 ? true : "wait");
        add(rig.after(() => { rig.popupItem().toggleSnapshots(); }, 200));
        add(w => rig.engine.childPopup.phase === "open" && w > 1000 ? true : "wait");
        add(rig.after(() => rig.engine.close(), 200));
        add(rig.after(() => {
            rig.check("E8.close", rig.engine.thePopup.phase === "closed" && rig.engine.childPopup.phase === "closed", "closing the popup closes the page: " + rig.engine.thePopup.phase + " / " + rig.engine.childPopup.phase);
        }, 1800));
    }
    property var scratch: ({})
}
