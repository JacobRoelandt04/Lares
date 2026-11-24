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
// tools/dev/qml/gooey_overshoot_poses.qml -- popups of the REAL shell frame held at a point of their open
// (tools/dev/gooey_overshoot_poses.sh; GooeyEngine: THE REST FRAME).
//
// mockups/shell.qml (the shell's own ShellFrame on its mock services, one 2880 x 1620 output at zoom 1) is built here
// as a component -- the runner copies this file into the sandbox copy's mockups/ to run it --, and each spec is driven
// through it: the popup is opened the way its button opens it, and the
// moment its clock passes `t` the clock is STOPPED and written to exactly `t` (CLAUDE.md, Films: stop the clock and
// write t), the content at full opacity; the stage is grabbed and the boxes printed. Every spec is opened once
// before (the shell prebuilds and parks contents; the user's opens are of a parked content). A secondary's opens
// (`child`) freeze the SECONDARY's clock, with its popup at rest.
//
// Env:  OS_OUT=<dir>   OS_SPECS=<spec>;<spec>...   a spec:  <tag>=<owner>[+<setup>...][@<t>,<t>...]   (t default p: the open's
//       own peak, wherever its overshoot puts it -- THE OVERSHOOT'S BIAS gives every open its own; 1 = at rest, grabbed with the
//       content cut forced on so the pipeline is the moving one's)
//       owner   a ShellFrame owner key (llm, player, notifications, weather, clock, ..., power | idle: the reels), `tray:<1..3>` (as
//               the measure's <what>, below), or `child:<owner>:<how>` (wiki: the
//               clock's wiki card, opened over the clock at rest), or `act:<owner>:<what>` (the popup at rest, then
//               history / mini / player / browse -- the llm's history fold, the player's view switches -- held at t of the
//               resize the content asks for: a fold must still fold), or `close:<owner>` (the popup at rest, then closed, held at t
//               of the close)
//       setup   mini | browse (the player's view), history (the llm's history out), post<n> (n notifications, their toasts
//               gone before the open), wiki (the clock opened with its wiki card: the secondary out of the overshoot)
//       THE OVERSHOOT'S BIAS (no grab): `peak:<what>` opens <what> the way the user does and samples its box on every frame of
//       the open: OSPEAK <tag> travel=<the longest edge travel, origin to rest> leg=<the last run's> s=<its overshoot>
//       peak=<how far an edge got past its rest, in its own direction> (frame px; `stage=` the same in stage px)
//       want=<the engine's openOvershootPxFor(slot, from, rest) -- of the last run's travel and its extent across the motion
//       (round 3); an older engine's openOvershootPx(leg, slot); `-` for one without either> from=<the run's start> to=<its rest>.
//       `sweep:<what>` holds the open's clock at half way, then writes t = k/400, k = 0..400, laying out each, and prints the
//       displacement of the edge that travels furthest: OSSWEEP <tag> ... d=<401 values> -- the curve's own velocity, for the runner's continuity judge.
//       <what>: a primary's owner key; power | idle (the reels); child:clock:wiki; tray:<1..3>[:nm] (the tray's menu chain at
//       that level, over a pinned strip: a scripted item whose menu nests three deep, or nm-applet's real menu)
// Prints OSPOSE <tag> <t> kind=<open|child|act> phase=<phase> ease=<index> e=<eased> box=<x0,y0,x1,y1> rest=<...> framed=<0|1> frame=<x,y,w,h> content=<x,y,w,h>
// [child=<x0,y0,x1,y1>] [peakpose=1] (stage px), then OSPOSES DONE. Nothing here is a verdict: the runner's judge reads the PNGs
// and the lines.
// =============================================================================
Scope {
    id: rig

    readonly property string out: Quickshell.env("OS_OUT") || ""
    readonly property var specs: (Quickshell.env("OS_SPECS") || "").split(";").filter(x => x !== "").map(rig.parse)
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null

    function parse(s) {
        const eq = s.indexOf("=");
        const tag = s.slice(0, eq);
        let rest = s.slice(eq + 1);
        let ts = [-1];
        const at = rest.indexOf("@");
        if (at >= 0) {
            // `p` (-1): the open's own peak (THE OVERSHOOT'S BIAS: its overshoot is its own)
            ts = rest.slice(at + 1).split(",").map(x => x === "p" ? -1 : Number(x));
            rest = rest.slice(0, at);
        }
        const parts = rest.split("+");
        return { tag: tag, owner: parts[0], setup: parts.slice(1), ts: ts };
    }

    Component.onCompleted: {
        if (rig.out === "") {
            console.log("OSPOSES no OS_OUT: nothing to do");
            quitLater.start();
            return;
        }
        // Beside it: quickshell serves nothing outside the directory of the file it runs, so the runner lays this file into the
        // copy's mockups/ (a sandbox copy, never the tree).
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("OSPOSES the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        step.interval = 4000;           // the frame, its services and the prewarm settle
        step.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }

    // ---- the schedule: one action per tick ----------------------------------------------------------------------
    property var queue: []
    Timer {
        id: step
        repeat: false
        onTriggered: rig.next()
    }
    function next() {
        if (rig.queue.length === 0) {
            if (!rig._built) {
                // The shell's start has tails (the prewarm blocks its GUI thread, the launcher's catalogue): a first open inside them
                // runs while no frame is drawn and is never caught mid-way. Wait for `settled` (ShellServices), a minute at most.
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
            console.log("OSPOSES DONE");
            quitLater.start();
            return;
        }
        const a = rig.queue.shift();
        a.fn();
        step.interval = Math.max(1, a.ms);
        step.start();
    }
    property bool _built: false
    property int _settleWaits: 0
    function push(ms, fn) {
        rig.queue.push({ ms: ms, fn: fn });
    }

    function owner(key) {
        return rig.win.frame.owners[key];
    }
    function isChildSpec(sp) {
        return sp.owner.indexOf("child:") === 0;
    }
    function isActSpec(sp) {
        return sp.owner.indexOf("act:") === 0;
    }
    function isCloseSpec(sp) {
        return sp.owner.indexOf("close:") === 0;
    }
    function isMeasureSpec(sp) {
        return sp.owner.indexOf("peak:") === 0 || sp.owner.indexOf("sweep:") === 0;
    }
    // an act's change, and back
    function act(sp, undo) {
        const a = sp.owner.split(":");
        if (a[2] === "history")
            rig.owner("llm").sidebarOpen = !undo;
        else if (a[2] === "mini")
            rig.owner("player").viewMode = undo ? "player" : "mini";
        else if (a[2] === "player")
            rig.owner("player").viewMode = undo ? "mini" : "player";
        else if (a[2] === "browse")
            rig.owner("player").browseOpen = !undo;
    }
    function openSpec(sp) {
        if (rig.isChildSpec(sp)) {
            const how = sp.owner.split(":");
            if (how[2] === "wiki")
                rig.owner(how[1]).openWiki("discover");
            return;
        }
        if (sp.setup.indexOf("wiki") >= 0) {
            rig.owner(sp.owner).openWiki("discover");
            return;
        }
        rig.openWhat(rig.whatOfOwner(sp.owner));
    }
    function closeAll() {
        rig.unfreeze();
        rig.engine.forceContentClip = false;
        if (rig.engine.thePopup.live)
            rig.engine.close();
    }
    function setupSpec(sp) {
        // every spec from the same start: the history folded, the full player, no sidebar
        rig.owner("llm").sidebarOpen = false;
        rig.owner("player").viewMode = "player";
        rig.owner("player").browseOpen = false;
        for (const st of sp.setup) {
            if (st === "mini")
                rig.owner("player").viewMode = "mini";
            else if (st === "browse") {
                rig.owner("player").viewMode = "player";
                rig.owner("player").browseOpen = true;
            } else if (st === "history")
                rig.owner("llm").sidebarOpen = true;
            else if (st.indexOf("post") === 0) {
                const n = Number(st.slice(4)) || 3;
                const svc = rig.owner("notifications").service;
                for (let i = 0; i < n; i++)
                    svc.post({ source: "overshoot", key: "os" + i, appName: "Shell test", title: ["Compile", "Backup", "Battery"][i % 3],
                               body: ["Build finished: 12 warnings.", "Backup completed in 41 s.", "Battery at 79 %."][i % 3],
                               urgency: "normal", timeoutMs: 400 });
            }
        }
    }

    function build() {
        for (const sp of rig.specs) {
            rig.push(10, () => rig.setupSpec(sp));
            if (rig.isMeasureSpec(sp)) {
                rig.buildMeasure(sp);
                continue;
            }
            if (rig.isCloseSpec(sp)) {
                const key = sp.owner.split(":")[1];
                for (const t of sp.ts) {
                    rig.push(1800, () => rig.win.openOwner(key));
                    rig.push(1, () => rig.arm(sp, t));
                    rig.push(600, () => rig.engine.close());
                    rig.push(700, () => rig.grab(sp, t));
                    rig.push(1200, () => rig.closeAll());
                }
                continue;
            }
            if (rig.isActSpec(sp)) {
                const key = sp.owner.split(":")[1];
                for (const t of sp.ts) {
                    rig.push(1800, () => rig.win.openOwner(key));
                    rig.push(1, () => rig.arm(sp, t));
                    // (the grab well inside the player's switch safety, 1500 ms on the same Timer clock: the pose holds the box short of
                    // arriving, so the switch is still in flight)
                    rig.push(t >= 1 ? 1500 : 600, () => rig.act(sp, false));
                    rig.push(700, () => rig.grab(sp, t));
                    rig.push(1200, () => {
                        rig.closeAll();
                        rig.act(sp, true);
                    });
                }
                continue;
            }
            // a child spec stands on its popup at rest, a tray level on the pinned strip and the levels above it
            const wh = rig.whatOfOwner(sp.owner);
            // the warm-up open and close (a parked content from here on, as the shell's)
            for (const t of [null].concat(sp.ts)) {
                if (wh.kind === "child" || wh.kind === "tray")
                    rig.push(1600, () => rig.baseOf(wh));
                if (wh.kind === "tray")
                    for (let L = 0; L < wh.level - 1; L++)
                        rig.push(1400, () => rig.trayLevel(wh, L));
                if (t === null) {
                    rig.push(1600, () => rig.openSpec(sp));
                } else {
                    rig.push(1, () => rig.arm(sp, t));
                    rig.push(t >= 1 ? 2200 : 900, () => rig.openSpec(sp));
                    rig.push(700, () => rig.grab(sp, t));
                }
                rig.push(1200, () => rig.closeWhat(wh));
            }
        }
    }

    // ---- the freeze ---------------------------------------------------------------------------------------------
    property var _armed: null           // { sp, t, child }
    property bool _frozen: false
    property real _tHold: 0
    property var _held: []              // [{ slot, t }]
    function arm(sp, t) {
        rig._frozen = false;
        rig._held = [];
        rig._armed = t >= 1 ? null : { sp: sp, t: t, child: rig.isChildSpec(sp), close: rig.isCloseSpec(sp) };
        if (t >= 1)
            rig.engine.forceContentClip = true;
    }
    function watched() {
        if (!rig._armed)
            return null;
        return rig._armed.close ? rig.engine.thePopup : rig.slotOf(rig.whatOfOwner(rig._armed.sp.owner));
    }
    FrameAnimation {
        running: rig.engine !== null && (rig._armed !== null || rig._frozen)
        onTriggered: {
            if (rig._frozen) {
                // a clock restarted under the pose (a late resize, a secondary released) is stopped again where it stood
                for (const h of rig._held) {
                    if (h.slot.t !== h.t) {
                        h.slot.stop();
                        h.slot.t = h.t;
                    }
                }
                return;
            }
            const S = rig.watched();
            const want = rig._armed.close ? S && S.phase === "closing" : S && (S.phase === "opening" || S.phase === "moving");
            const at = rig._armed.t < 0 ? rig.peakT(S) : rig._armed.t;
            if (want && S.t >= at)
                rig.freeze(S, at);
        }
    }
    function freeze(S, t) {
        rig._frozen = true;
        const held = [];
        // the popup and its levels, the reel slot's chain (the tray's levels), and the watched slot wherever it is
        const slots = [rig.engine.thePopup].concat(rig.engine.childPopups, rig.engine.reelChildPopups);
        if (slots.indexOf(S) < 0)
            slots.push(S);
        for (const X of slots) {
            if (X.phase === "opening" || X.phase === "moving" || X.phase === "closing" || X.slideT < 1) {
                X.stop();
                X.slideT = 1;
                if (X === S) {
                    X.t = t;
                    X.contentOpacity = 1;
                }
                held.push({ slot: X, t: X.t });
            }
        }
        rig._held = held;
        rig.engine.layout();
    }
    // The t of the open's peak: OutBack's (s = the slot's own overshoot), else OutBack 1.2's.
    function peakT(S) {
        const s = S.easingIndex === 3 ? Math.max(1e-4, S.overshoot) : 1.2;
        return 1 - 2 * s / (3 * (s + 1));
    }
    function unfreeze() {
        rig._armed = null;
        rig._frozen = false;
        rig._held = [];
    }


    // ---- THE OVERSHOOT'S BIAS: the open measured on every frame (peak:), or its curve swept (sweep:) -----------------------
    // <what>: { kind: primary | reel | child | tray, key, level, item }
    function whatOf(sp) {
        return rig.whatOfOwner(sp.owner.slice(sp.owner.indexOf(":") + 1));
    }
    function whatOfOwner(owner) {
        const w = owner.split(":");
        if (w[0] === "power" || w[0] === "idle")
            return { kind: "reel", key: w[0] };
        if (w[0] === "child")
            return { kind: "child", key: w[1], how: w[2], level: 1 };
        if (w[0] === "tray")
            return { kind: "tray", key: "windowtray", level: Math.max(1, Math.min(3, Number(w[1]) || 1)), item: w[2] || "deep" };
        return { kind: "primary", key: w[0] };
    }
    function slotOf(wh) {
        const E = rig.engine;
        if (wh.kind === "reel")
            return E.theReel;
        // the tray's levels are the reel slot's chain (THE REEL'S CHAIN); a clock's child is thePopup's
        if (wh.kind === "tray")
            return E.reelChildPopups[wh.level - 1];
        if (wh.kind === "child")
            return E.childPopups[wh.level - 1];
        return E.thePopup;
    }
    // A scripted tray item whose menu nests three deep (nm-applet's menu, with a level below "Network 3").
    readonly property var deepSpec: ({
        id: "overshoot-deep", title: "Deep menus", icon: "", status: "Active", category: "ApplicationStatus",
        menu: [{ text: "Ethernet Network", enabled: false }, { text: "disconnected", enabled: false }, { isSeparator: true },
               { text: "Wi-Fi Networks", enabled: false }, { text: "Network 1", buttonType: 2, checkState: 2 }, { text: "Disconnect" },
               { text: "_Available networks", children: [{ text: "Network 2" },
                   { text: "Network 3", children: [{ text: "Connect" }, { text: "Forget" }, { text: "_Edit…" }, { text: "Properties" }] },
                   { text: "Network 4" }] },
               { isSeparator: true }, { text: "_Connect to Hidden Wi-Fi Network…" }, { text: "Create _New Wi-Fi Network…" },
               { isSeparator: true }, { text: "Enable _Networking", buttonType: 1, checkState: 2 },
               { text: "Enable _Wi-Fi", buttonType: 1, checkState: 2 }, { isSeparator: true }, { text: "Connection _Information" },
               { text: "Edit Connections…" }]
    })
    property string _deepKey: ""
    function trayKey(wh) {
        const o = rig.owner("windowtray");
        if (wh.item === "nm") {
            const rows = o.tray.rows;
            for (let i = 0; i < rows.count; i++) {
                const rec = rows.get(i).rec;
                if (rec && rec.item && rec.item.trayId === "nm-applet")
                    return rec.key;
            }
            return "";
        }
        if (rig._deepKey === "")
            rig._deepKey = o.tray.add(rig.deepSpec);
        return rig._deepKey;
    }
    // Open the owner's menu level L (0: the item's own menu, the engine's level 1; L: the first submenu of level L - 1).
    function trayLevel(wh, L) {
        const o = rig.owner("windowtray");
        if (L === 0) {
            o.openMenu(rig.trayKey(wh));
            return;
        }
        const P = L - 1, slot = o.levelSlot[P];
        const m = o.menuModelOf(P, slot);
        for (let i = 0; i < m.rows.count; i++) {
            const d = o._rowAt(P, i);
            if (d && d.submenu && !d.disabled) {
                o.menuPick(P, slot, i, d, o._keyRowY(P, i));
                return;
            }
        }
        console.log("OSPEAK tray level " + L + ": no submenu row at level " + P);
    }
    function openWhat(wh) {
        if (wh.kind === "child")
            rig.owner(wh.key).openWiki("discover");
        else if (wh.kind === "tray")
            rig.trayLevel(wh, wh.level - 1);
        else
            rig.win.openOwner(wh.key);
    }
    // What stands under the measured open: the clock under its wiki card, the pinned strip and the levels above.
    function baseOf(wh) {
        if (wh.kind === "child")
            rig.win.openOwner(wh.key);
        else if (wh.kind === "tray") {
            rig.trayKey(wh);
            rig.win.openOwner("windowtray");
        }
    }
    function closeWhat(wh) {
        rig._meas = null;
        rig.unfreeze();
        if (wh.kind === "reel") {
            const o = rig.owner(wh.key);
            if (o.pinnedOpen)
                rig.win.openOwner(wh.key);
            return;
        }
        if (wh.kind === "tray" || wh.key === "windowtray") {
            const o = rig.owner("windowtray");
            o.pinnedOpen = false;
            o.close();
            return;
        }
        rig.closeAll();
    }
    function buildMeasure(sp) {
        const wh = rig.whatOf(sp);
        const sweep = sp.owner.indexOf("sweep:") === 0;
        // the warm-up open and close (a parked content from here on, as the shell's)
        for (const warm of [true, false]) {
            if (wh.kind === "child" || wh.kind === "tray")
                rig.push(1600, () => rig.baseOf(wh));
            if (wh.kind === "tray")
                for (let L = 0; L < wh.level - 1; L++)
                    rig.push(1400, () => rig.trayLevel(wh, L));
            if (!warm)
                rig.push(1, () => rig.measure(sp, wh, sweep));
            rig.push(2200, () => rig.openWhat(wh));
            if (!warm)
                rig.push(10, () => rig.measureMissed(sp));
            rig.push(1200, () => rig.closeWhat(wh));
        }
    }

    property var _meas: null            // { sp, wh, sweep, frames: [{ t, s, box }], seen, done, from }
    function measure(sp, wh, sweep) {
        rig._meas = { sp: sp, wh: wh, sweep: sweep, frames: [], seen: false, done: false, from: null };
    }
    function measureMissed(sp) {
        const m = rig._meas;
        if (m && m.sp === sp && !m.done)
            console.log("OSPEAK " + sp.tag + " MISSED (the open never " + (m.seen ? "came to rest" : "began") + ")");
        rig._meas = null;
    }
    FrameAnimation {
        running: rig._meas !== null && !rig._meas.done
        onTriggered: {
            const m = rig._meas;
            const S = rig.slotOf(m.wh);
            if (!S || m.done)
                return;
            if (S.phase === "opening" || (m.seen && S.phase === "moving")) {
                m.seen = true;
                // the run's own start: a re-aim during the open starts a new leg from where the box had got to
                if (S.fromBox)
                    m.from = { x0: S.fromBox.x0, y0: S.fromBox.y0, x1: S.fromBox.x1, y1: S.fromBox.y1 };
                if (S.box)
                    m.frames.push({ t: S.t, s: S.overshoot, box: { x0: S.box.x0, y0: S.box.y0, x1: S.box.x1, y1: S.box.y1 } });
                if (m.sweep && S.phase === "opening" && S.easingIndex === 3 && S.t >= 0.5)
                    rig.sweep(m, S);
            } else if (m.seen && S.phase === "open") {
                rig.reportPeak(m, S);
            }
        }
    }
    // The box this open grew out of: a primary's origin, a child's span at no extent.
    function originOf(S) {
        return S.isChild ? rig.engine._childBox(S, 0, true) : S.originBox;
    }
    function edgeStats(origin, rest, boxes) {
        const r = { travel: 0, peak: 0, edge: "" };
        for (const k of ["x0", "y0", "x1", "y1"]) {
            const tr = rest[k] - origin[k];
            if (Math.abs(tr) > r.travel) {
                r.travel = Math.abs(tr);
                r.edge = k;
            }
            if (Math.abs(tr) < 0.5)
                continue;
            for (const b of boxes)
                r.peak = Math.max(r.peak, (b[k] - rest[k]) * Math.sign(tr));
        }
        return r;
    }
    function stageBox(b) {
        const scene = rig.win.sheetGrabItem;
        const p0 = rig.engine.mapToItem(scene, b.x0, b.y0), p1 = rig.engine.mapToItem(scene, b.x1, b.y1);
        return { x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y };
    }
    function reportPeak(m, S) {
        m.done = true;
        const rest = S.restBox, origin = rig.originOf(S);
        if (!rest || !origin) {
            console.log("OSPEAK " + m.sp.tag + " MISSED (no rest or origin box)");
            return;
        }
        const boxes = m.frames.map(f => f.box);
        const st = rig.edgeStats(origin, rest, boxes);
        const ss = rig.edgeStats(rig.stageBox(origin), rig.stageBox(rest), boxes.map(rig.stageBox));
        const from = S.isChild ? origin : (m.from || origin);
        const leg = rig.edgeStats(from, rest, []).travel;
        const E = rig.engine;
        // (round 3: of the run's boxes, its extent across the motion too; an older engine's of its travel alone)
        const want = typeof E.openOvershootPxFor === "function" ? E.openOvershootPxFor(S, from, rest).toFixed(2)
                   : typeof E.openOvershootPx === "function" ? E.openOvershootPx(leg, S).toFixed(2) : "-";
        const sMin = Math.min.apply(null, m.frames.map(f => f.s)), sMax = Math.max.apply(null, m.frames.map(f => f.s));
        console.log("OSPEAK " + m.sp.tag + " kind=" + m.wh.kind + " travel=" + st.travel.toFixed(2) + " leg=" + leg.toFixed(2)
                    + " edge=" + st.edge + " s=" + S.overshoot.toFixed(4) + " sRange=" + sMin.toFixed(4) + "," + sMax.toFixed(4)
                    + " peak=" + st.peak.toFixed(2) + " stage=" + ss.peak.toFixed(2) + " stageTravel=" + ss.travel.toFixed(2)
                    + " want=" + want + " frames=" + m.frames.length
                    + " rest=" + (rest.x1 - rest.x0).toFixed(1) + "x" + (rest.y1 - rest.y0).toFixed(1)
                    + " from=" + rig.fmtBox(from) + " to=" + rig.fmtBox(rest));
    }
    // The curve itself: the clock held, t written k / N and laid out, the edge that travels furthest read each time.
    function sweep(m, S) {
        m.done = true;
        S.stop();
        S.slideT = 1;
        S.contentOpacity = 1;
        const rest = S.restBox, origin = rig.originOf(S);
        const st = rig.edgeStats(origin, rest, []);
        const k = st.edge, dir = Math.sign(rest[k] - origin[k]);
        const from0 = S.isChild ? null : JSON.stringify(S.fromBox), to0 = S.isChild ? null : JSON.stringify(S.toBox);
        const N = 400, d = [];
        for (let i = 0; i <= N; i++) {
            S.t = i / N;
            rig.engine.layout();
            d.push(S.box ? ((S.box[k] - origin[k]) * dir).toFixed(4) : "nan");
        }
        const moved = !S.isChild && (JSON.stringify(S.fromBox) !== from0 || JSON.stringify(S.toBox) !== to0);
        console.log("OSSWEEP " + m.sp.tag + " kind=" + m.wh.kind + " s=" + S.overshoot.toFixed(4) + " n=" + N + " edge=" + k
                    + " travel=" + st.travel.toFixed(2) + (moved ? " DISTURBED" : "") + " d=" + d.join(","));
        S.t = 1;
    }

    // ---- the grab -----------------------------------------------------------------------------------------------
    function fmtBox(b) {
        return b ? [b.x0, b.y0, b.x1, b.y1].map(v => v.toFixed(2)).join(",") : "-";
    }
    function grab(sp, t) {
        const E = rig.engine;
        const S = rig.isActSpec(sp) || rig.isCloseSpec(sp) ? E.thePopup : rig.slotOf(rig.whatOfOwner(sp.owner));
        const scene = rig.win.sheetGrabItem;
        // engine px to stage px (the frame's scale and the ratios included)
        const sh = b => {
            if (!b)
                return null;
            const p0 = E.mapToItem(scene, b.x0, b.y0), p1 = E.mapToItem(scene, b.x1, b.y1);
            return { x0: p0.x, y0: p0.y, x1: p1.x, y1: p1.y };
        };
        const it = S.contentItem;
        let cg = "-";
        if (it) {
            const p0 = it.mapToItem(scene, 0, 0), p1 = it.mapToItem(scene, it.width, it.height);
            cg = [p0.x, p0.y, p1.x - p0.x, p1.y - p0.y].map(v => v.toFixed(2)).join(",");
        }
        const framed = ("framed" in S) && S.framed;
        const rest = ("restBox" in S) ? S.restBox : null;
        const eased = (S.isChild && S.closeCurve) ? -1 : Math.round(1e4 * (function () {
            const s = S.overshoot, u = Math.max(0, Math.min(1, S.t)) - 1;
            return S.easingIndex === 3 ? u * u * ((s + 1) * u + s) + 1 : S.easingIndex === 1 ? 1 - Math.pow(-u, 3) : S.t;
        })()) / 1e4;
        const kids = rig.isChildSpec(sp) ? "" : " child=" + rig.fmtBox(E.childPopup.phase !== "closed" ? sh(E.childPopup.box) : null);
        // the fractions a content reads off its own size, where it has them (the llm's history, the player's view and panel)
        let fr = "";
        for (const k of ["_openF", "_folding", "_switchF", "_switching", "_sidebarF"])
            if (it && (k in it))
                fr += " " + k + "=" + it[k];
        const name = sp.tag + "_t" + (t >= 1 ? "1" : t < 0 ? "p" : String(t).replace(".", ""));
        const kind = rig.isActSpec(sp) ? "act" : rig.isCloseSpec(sp) ? "close" : rig.isChildSpec(sp) ? "child" : "open";
        console.log("OSPOSE " + sp.tag + " " + (t < 0 ? S.t.toFixed(4) : t) + " kind=" + kind + " phase=" + S.phase + " ease=" + S.easingIndex + " e=" + eased + " box=" + rig.fmtBox(sh(S.box))
                    + " rest=" + rig.fmtBox(sh(rest)) + " framed=" + (framed ? 1 : 0)
                    + " frame=" + (framed ? [S.frameX, S.frameY, S.frameW, S.frameH].map(v => v.toFixed(2)).join(",") : "-")
                    + " content=" + cg + kids + fr + (t < 0 ? " peakpose=1" : "") + " png=" + name + ".png");
        scene.grabToImage(r => {
            r.saveToFile(rig.out + "/" + name + ".png");
        });
    }
}
