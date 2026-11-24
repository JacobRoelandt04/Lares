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
// tools/dev/qml/tray_pocket_record.qml -- what the REAL shell frame's engine hands its field on every frame while the
// tray's label moves from a thin item to a thick one (tools/dev/tray_pocket_probe.sh; GooeyGeometry.js THE POCKET).
//
// mockups/shell.qml (the shell's own ShellFrame on its mock services) is built here as a component -- the runner copies
// this file into the sandbox copy's mockups/ --, the mock tray emptied and given the user's two items as the session has
// them (Proton Pass: no status, a one-line label; KDE Connect: "KDE Connect · 1 device connected", a two-line label), the
// strip pinned open, and each leg played the way a pointer plays it: icon A hovered, its label out (or still opening), then
// the pointer onto icon B. Every frame of the leg the field's input (GooeyField.bodies) is printed for the judge, which
// replays it through GooeyGeometry.fieldShape with no Qt.
//
// Env:  TP_ORDER=thin,thick | thick,thin   the tray's row order (the session's registration order decides it)
//       TP_TITLES=<t>|<t>...               the focused window's title per pass: the left island ends where the title does, so it
//                                          decides whether the label (beside the strip, under the title) ends before the island or
//                                          past it -- the trigger the user could not name (default: "~", whose island ends
//                                          inside the thin label; "~/.config/quickshell", inside the thick one's widening; a
//                                          long title, past both)
//       TP_DELAYS=<ms>,<ms>...             per leg: how long after icon A's label was asked for the pointer moves on (a label at
//                                          rest at 700, still opening below ~400)
//       TP_SLOW=<k>                        the engine's child clocks k times slower: k times the frames on the same curves
//       TP_SCENE=owners                    instead: every owner of the frame opened and closed as its button does (and the
//                                          clock's wiki card), each motion a leg -- frames for a revision diff of the geometry
// Prints TPPARAMS {...} once, then TPFRAME {"leg","t","bodies"} per frame of a leg, TPLEG <leg> <frames> island=<x1>, and
// TPRECORD DONE <legs> (the runner's verdict is the judge's).
// =============================================================================
Scope {
    id: rig

    readonly property var order: (Quickshell.env("TP_ORDER") || "thin,thick").split(",")
    readonly property var titles: (Quickshell.env("TP_TITLES") || "~|~/.config/quickshell|"
        + "Secondary connection to bar - feedback/window+tray.md - quickshell - kitty").split("|")
    readonly property var delays: (Quickshell.env("TP_DELAYS") || "700,120").split(",").map(Number)
    readonly property real slow: Math.max(1, Number(Quickshell.env("TP_SLOW") || 1))
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null
    property var field: null

    // The session's two items (busctl, 2026-11-09): Proton Pass names itself only in its tooltip's title, KDE Connect's tooltip
    // says more than its name.
    readonly property var specs: ({
        thin: { id: "Proton Pass_status_icon_1", title: "", icon: "", status: "Active",
                category: "ApplicationStatus", tooltipTitle: "Proton Pass", tooltipDescription: "",
                menu: [{ text: "Open Proton Pass" }, { isSeparator: true }, { text: "Quit" }] },
        thick: { id: "KDE Connect Indicator", title: "KDE Connect Indicator", icon: "", status: "Active",
                 category: "Communications", tooltipTitle: "KDE Connect", tooltipDescription: "1 device connected",
                 menu: [{ text: "Configure..." }, { isSeparator: true }, { text: "Quit" }] }
    })
    property var keys: ({})

    Component.onCompleted: {
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("TPRECORD the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        step.interval = 4000;
        step.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }

    // ---- the schedule: one action per tick ----------------------------------------------------------------------
    property var queue: []
    property bool _built: false
    property int _settleWaits: 0
    Timer {
        id: step
        repeat: false
        onTriggered: rig.next()
    }
    function next() {
        if (rig.queue.length === 0) {
            if (!rig._built) {
                // the shell's start has tails (the prewarm blocks its GUI thread): wait for `settled`, a minute at most
                const sv = rig.win && rig.win.frame ? rig.win.frame.services : null;
                if (sv && sv.settled === false && rig._settleWaits++ < 120) {
                    step.interval = 500;
                    step.start();
                    return;
                }
                rig._built = true;
                rig.build();
                rig.next();
                return;
            }
            console.log("TPRECORD DONE " + rig._legs);
            quitLater.start();
            return;
        }
        const a = rig.queue.shift();
        a.fn();
        step.interval = Math.max(1, a.ms);
        step.start();
    }
    function push(ms, fn) {
        rig.queue.push({ ms: ms, fn: fn });
    }

    function owner() {
        return rig.win.frame.owners.windowtray;
    }
    // The engine's field, found in its tree (it is not exposed).
    function findField(it) {
        if (!it)
            return null;
        if (it.maxBodies !== undefined && it.bodies !== undefined && it.blendRadius !== undefined)
            return it;
        const kids = it.children || [];
        for (let i = 0; i < kids.length; i++) {
            const r = rig.findField(kids[i]);
            if (r)
                return r;
        }
        return null;
    }
    function hover(which, on) {
        const k = rig.keys[which];
        rig.owner().cellHover(k, rig.owner().rowIndexOf(k), on);
    }

    function build() {
        const E = rig.engine;
        rig.field = rig.findField(E);
        if (!rig.field) {
            console.log("TPRECORD no field in the engine");
            return;
        }
        if (rig.slow > 1) {
            E.childMs *= rig.slow;
            E.childSlideMs *= rig.slow;
            E.contentFadeMs *= rig.slow;
            E.migrateMs *= rig.slow;
        }
        const f = rig.field;
        console.log("TPPARAMS " + JSON.stringify({
            blendRadius: f.blendRadius, attachDistance: f.attachDistance, snapDistance: f.snapDistance,
            stickiness: f.stickiness, stretchMax: f.stretchMax, sideStretch: f.sideStretch, settleMs: f.settleMs,
            flushSnap: f.flushSnap, skyOutset: f._bw, maxFillets: f.maxFillets, maxSeams: f.maxSeams, maxTiles: f.maxTiles,
            width: f.width, height: f.height, slow: rig.slow, order: rig.order
        }));
        const o = rig.owner();
        if ((Quickshell.env("TP_SCENE") || "") === "owners") {
            rig.buildOwners();
            return;
        }
        o.tray.clear();
        const ks = {};
        for (const w of rig.order)
            ks[w] = o.tray.add(rig.specs[w]);
        rig.keys = ks;
        const S = rig.slow;
        rig.titles.forEach((title, ti) => {
            // the strip opens on the title's island (closed first: an open strip holds the title's width)
            rig.push(600, () => {
                if (o.popupMine)
                    rig.win.openOwner("windowtray");
                o.window.setWindow({ cls: "kitty", title: title, initialTitle: "kitty" });
            });
            rig.push(1200, () => rig.win.openOwner("windowtray"));
            for (const d of rig.delays) {
            for (const [a, b] of [["thin", "thick"], ["thick", "thin"]]) {
                const leg = "T" + ti + " " + a + ">" + b + "@" + d;
                // (each step runs, then waits its ms) icon A hovered: its label's own delay, then `d` of its open
                rig.push(o.style.labelDelayMs + d * S, () => rig.hover(a, true));
                // the pointer onto icon B; its label's slide recorded
                rig.push(900 * S, () => {
                    rig._leg = { name: leg, t0: Date.now(), frames: 0, last: "" };
                    rig.hover(a, false);
                    rig.hover(b, true);
                });
                // the pointer away: the label gone (its grace, then its close) before the next leg
                rig.push(o.style.labelGraceMs + 700 * S, () => {
                    const isle = rig.field.bodies.find(x => x.id === "bar:" + o.barId);
                    console.log("TPLEG " + leg + " " + rig._leg.frames + " island=" + (isle ? isle.x1 : "-"));
                    rig._legs++;
                    rig._leg = null;
                    rig.hover(b, false);
                });
            }
            }
        });
    }

    function buildOwners() {
        const S = rig.slow;
        const keys = Object.keys(rig.win.frame.owners).filter(k => k !== "osd").concat(["wiki"]);
        for (const k of keys) {
            for (const phase of ["open", "close"]) {
                rig.push(3000 * S, () => {
                    rig._leg = { name: phase + ":" + k, t0: Date.now(), frames: 0, last: "" };
                    if (k === "wiki" && phase === "open") {
                        rig.win.openOwner("clock");
                        rig.win.frame.owners.clock.openWiki("discover");
                    } else if (k === "wiki") {
                        rig.win.openOwner("clock");
                    } else {
                        rig.win.openOwner(k);
                    }
                });
                rig.push(1, () => {
                    console.log("TPLEG " + rig._leg.name + " " + rig._leg.frames);
                    rig._legs++;
                    rig._leg = null;
                });
            }
        }
    }

    property var _leg: null
    property int _legs: 0
    FrameAnimation {
        running: rig._leg !== null && rig.field !== null
        onTriggered: {
            const L = rig._leg;
            if (!L)
                return;
            const s = JSON.stringify(rig.field.bodies);
            if (s === L.last)
                return;
            L.last = s;
            L.frames++;
            console.log("TPFRAME {\"leg\":" + JSON.stringify(L.name) + ",\"t\":" + (Date.now() - L.t0) + ",\"bodies\":" + s + "}");
        }
    }
}
