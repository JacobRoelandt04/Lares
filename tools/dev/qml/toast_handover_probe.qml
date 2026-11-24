pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/components"
import "modules/bar/gooey"
import "modules/notifications"
import "modules/notifications/parts"
import "modules/notifications/data"
// qmllint enable unused-imports

// =============================================================================
// tools/dev/qml/toast_handover_probe.qml -- a toast that leaves while another arrives (feedback/notification.md, "Toast
// behaviour when emptying while getting refilled"): the real engine's lane, the real toast stack, the real
// NotificationService (no bus, no disk), driven by FRAMES (offscreen, a frame is a fixed 16 ms of animation).
//
// Every scenario starts from a settled lane, does its action in ONE turn (or spaced by frames), and samples the lane's
// drawn height (engine.theLane.box) every frame until it settles again. A HAND-OVER scenario must move the box ONCE:
// no reversal (a change of direction of more than 0.5 px), no bump above the larger of its two ends, no dip below the
// smaller. The regular ones (a lone arrival, a lone exit) are timed: their frames are printed for a BEFORE comparison.
//
//   replace      one toast; it is consumed (a click: removed, fades) and another is posted in the same turn
//   arrivefirst  one toast; another is posted, THEN the first withdrawn, in the same turn (a source's progress -> result)
//   duringfade   two toasts; the newest removed, the next posted 4 frames later (inside its 160 ms fade)
//   duringclose  two toasts; the newest removed, the next posted 14 frames later, its room already closing: the box turns
//                (it had come down), so this one is judged on AGREEMENT -- the rows' drawn height and the box move together,
//                lane - rows within 2.5 px of its resting value on every frame (one frame of sampling lag)
//   stack        two toasts; the newest consumed and a new one posted in the same turn (the stack never empties)
//   overflow     two toasts; the OLDEST filed (it flies off right, to the manager) and a new one posted in the same turn
//   arrive       (regular) one toast; a second arrives                  leave  (regular) two toasts; the newest consumed
//   lonefade     (told) the only toast removed, the next posted 4 frames later: the lane had begun to close (it closes the
//                frame the stack empties, NotificationToast GOING EMPTY) and turns round
//   late         (told) the only toast removed; the next posted 14 frames later, the lane nearly closed
//
//   lone         (regular) no toast; one arrives (the lane opens round it)
//   arrive2      (regular) two toasts; a third arrives (the newcomer stands under the row that moves away)
//
// FILM=<dir> [FILM_EVERY=3] [FILM_N=15]: PNGs of the stage during each action (<scenario>_<frame>.png), for a strip.
// EDGE=bottom: the bar (and the lane) at the screen's bottom edge, newest nearest it. SCALE=1.25: the whole frame magnified, as the
// shell's frame is (ScaleRoot; the style's and the engine's renderScale follow), PNGs in device px.
// ENTRY=1: THE ARRIVAL CHECK's pass (tools/dev/toast_handover_probe.sh runs it second): every scenario with an arrival is filmed
// frame by frame into FILM, with `HANDOVER card <scenario> <frame> x0 y0 x1 y1 presence coverTop under qx qy bx0 by0 bx1 by1` (the arriving card's
// rect on the stage, its presence, the top of the opaque row that lies over its place, whether it paints under that row, its
// place in the content's own frame and the lane's box x0 y0 x1 y1 on the stage) and a `rest` frame of the settled stack, for
// tools/dev/toast_entry_judge.py; the shape verdicts are told, not judged (a grab per frame moves the timing).
// `HANDOVER csv <scenario> frame,lane,rows` lines carry the traces (the runner writes OUT_DIR/<scenario>.csv). ONLY=<scenario>
// runs those (comma separated).
// Prints `HANDOVER <scenario> ...` per scenario and ends with `HANDOVER RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string only: Quickshell.env("ONLY") || ""
    // ONLY=a,b: a list
    readonly property var onlyList: root.only === "" ? [] : root.only.split(",")
    readonly property string edgeName: Quickshell.env("EDGE") === "bottom" ? "bottom" : "top"
    readonly property real zoom: Math.max(1, Number(Quickshell.env("SCALE") || 1))
    readonly property bool entryMode: (Quickshell.env("ENTRY") || "") === "1"
    // FILM=<dir>: a grab of the engine every FILM_EVERY frames of the action, for a strip (the grab lands a frame or two late)
    readonly property string filmDir: Quickshell.env("FILM") || ""
    readonly property int filmEvery: Number(Quickshell.env("FILM_EVERY") || 3)
    readonly property int filmN: Number(Quickshell.env("FILM_N") || 15)
    property int fails: 0

    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: false
        persist: false
        liveSignals: false
        ipcEnabled: false
        // EDGE=bottom: the runner's config puts the stack at the bottom-right corner (the default spot is the top-right)
        configPath: Quickshell.env("NOTIF_CONFIG") || ""
    }
    BoundaryClock {
        id: clock
        active: true
    }
    NotificationStyle {
        id: nstyle
        renderScale: root.zoom
    }

    FloatingWindow {
        id: win
        implicitWidth: 900
        implicitHeight: 700
        visible: true
        color: Theme.surface

        // the stage the film grabs, in device px: the engine inside the frame's magnification (ShellScreen's ScaleRoot)
        Item {
            id: stage
            anchors.fill: parent

            ScaleRoot {
                id: frame
                factor: root.zoom
                hostWidth: stage.width
                hostHeight: stage.height

                GooeyEngine {
                    id: engine
                    anchors.fill: parent
                    surfaceColor: Theme.surface
                    renderScale: root.zoom
                    barsList: [topBar]

                    GooeyBar {
                        id: topBar
                        engine: engine
                        barId: "top"
                        edge: root.edgeName
                        rawPos: 0
                        rawLen: engine.w
                        Item {
                            id: bell
                            x: 600
                            y: Math.round((topBar.height - 24) / 2)
                            width: 24
                            height: 24
                        }
                    }
                }
                NotificationsBarOwner {
                    id: owner
                    engine: engine
                    bar: topBar
                    barId: "top"
                    anchorItem: bell
                    screenName: svc.laneScreen
                    service: svc
                    clock: clock
                    style: nstyle
                }
            }
        }
    }

    // ---- what is read every frame ------------------------------------------------------------------------------
    function laneH() {
        const L = engine.theLane;
        if (!L || !L.box || L.phase === "closed")
            return 0;
        return Math.max(0, L.box.y1 - L.box.y0);
    }
    function find(item, name) {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const f = root.find(item.children[i], name);
            if (f)
                return f;
        }
        return null;
    }
    // A row still leaving or waiting (ToastSlot `leaving` / `waiting`): the stack is not at rest, whatever the box does.
    function stackBusy() {
        const c = engine.theLane ? engine.theLane.contentItem : null;
        const st = root.find(c, "toastStack");
        if (!st)
            return false;
        for (let i = 0; i < st.children.length; i++) {
            const k = st.children[i];
            if (k.leaving === true || k.waiting === true)
                return true;
        }
        return false;
    }
    function rowsH() {
        const c = engine.theLane ? engine.theLane.contentItem : null;
        const s = root.find(c, "toastStack");
        return s ? s.height : 0;
    }

    // ---- the posts ---------------------------------------------------------------------------------------------
    property int _n: 0
    property string _lastPost: ""     // the uid of the newest post: THE ARRIVAL CHECK follows its card
    function post(lines) {
        root._n++;
        const body = ["One line of body."];
        for (let i = 1; i < lines; i++)
            body.push("And another line, to make the card taller.");
        // a source each: one app's toasts past floodCount inside floodWindowMs would file silently (NotifyPolicy.floodCheck)
        root._lastPost = svc.post({ source: "probe" + root._n, key: "k", title: "Toast " + root._n, body: body.join("\n"),
                                    urgency: "normal", timeoutMs: 0 });
        return root._lastPost;
    }
    function shown() {
        return svc.toasts.shown.slice();
    }
    function clearAll() {
        const s = root.shown();
        for (let i = 0; i < s.length; i++)
            svc.remove(s[i]);
    }

    // ---- the scenarios -----------------------------------------------------------------------------------------
    // setup: the toasts before (number of body lines each, oldest first); act(frame) runs from the action frame on and
    // returns true once it has done everything it does; judge: true = a hand-over (must move once).
    readonly property var scenarios: [
        { name: "replace", arrival: true, setup: [1], judge: true, act: f => {
            const a = root.shown()[0];
            svc.remove(a);
            root.post(3);
            return true;
        } },
        { name: "arrivefirst", arrival: true, setup: [2], judge: true, act: f => {
            const a = root.shown()[0];
            root.post(1);
            svc.withdrawUid(a);
            return true;
        } },
        { name: "duringfade", arrival: true, setup: [2, 1], judge: true, act: f => {
            if (f === 0) {
                svc.remove(root.shown()[0]);
                return false;
            }
            if (f < 4)
                return false;
            root.post(3);
            return true;
        } },
        { name: "duringclose", arrival: true, setup: [2, 1], judge: "agree", act: f => {
            if (f === 0) {
                svc.remove(root.shown()[0]);
                return false;
            }
            if (f < 14)
                return false;
            root.post(3);
            return true;
        } },
        { name: "stack", arrival: true, setup: [1, 2], judge: true, act: f => {
            const s = root.shown();          // newest first
            svc.remove(s[0]);
            root.post(3);
            return true;
        } },
        { name: "overflow", arrival: true, setup: [1, 2], judge: true, act: f => {
            const s = root.shown();
            svc.file(s[s.length - 1]);
            root.post(1);
            return true;
        } },
        { name: "arrive", arrival: true, setup: [1], judge: false, act: f => {
            root.post(2);
            return true;
        } },
        { name: "arrive2", arrival: true, setup: [1, 2], judge: false, act: f => {
            root.post(2);
            return true;
        } },
        { name: "lone", arrival: true, setup: [], judge: false, act: f => {
            root.post(3);
            return true;
        } },
        { name: "leave", setup: [1, 2], judge: false, act: f => {
            svc.remove(root.shown()[0]);
            return true;
        } },
        { name: "lonefade", arrival: true, setup: [1], judge: false, act: f => {
            if (f === 0) {
                svc.remove(root.shown()[0]);
                return false;
            }
            if (f < 4)
                return false;
            root.post(3);
            return true;
        } },
        { name: "late", arrival: true, setup: [1], judge: false, act: f => {
            if (f === 0) {
                svc.remove(root.shown()[0]);
                return false;
            }
            if (f < 14)
                return false;
            root.post(3);
            return true;
        } }
    ]

    // ---- the sequencer: one step per frame -------------------------------------------------------------------------
    property int _sc: -1              // the scenario index
    property string _stage: "boot"    // boot | clear | setup | settle | act | watch
    property int _f: 0                // frames in this stage
    property int _still: 0            // frames the box has not moved
    property real _lastH: -1
    property int _setupI: 0
    property var _trace: []
    property real _h0: 0

    function _next() {
        do {
            root._sc++;
        } while (root._sc < root.scenarios.length && root.only !== "" && root.onlyList.indexOf(root.scenarios[root._sc].name) < 0);
        if (root._sc >= root.scenarios.length) {
            root._finish();
            return;
        }
        root._go("clear");
    }
    function _go(stage) {
        root._stage = stage;
        root._f = 0;
        root._still = 0;
    }
    function _settled(h) {
        if (Math.abs(h - root._lastH) < 0.01)
            root._still++;
        else
            root._still = 0;
        root._lastH = h;
        const c = engine.theLane ? engine.theLane.contentItem : null;
        const busy = c && c.holding === true;
        return root._still >= 30 && !busy && !root.stackBusy();
    }
    property bool _pendingNext: false
    function _step() {
        if (root._pendingNext) {
            if (root._grabs === 0) {
                root._pendingNext = false;
                root._next();
            }
            return;
        }
        if (root._finishing) {
            root._finish();
            return;
        }
        const h = root.laneH();
        root._f++;
        if (root._stage === "boot") {
            if (root._f > 20)
                root._next();
            return;
        }
        const sc = root.scenarios[root._sc];
        if (root._f > 900) {
            root.fails++;
            console.log("HANDOVER FAIL " + sc.name + ": stage " + root._stage + " never settled (lane " + h.toFixed(1) + ")");
            root._next();
            return;
        }
        switch (root._stage) {
        case "clear":
            if (root._f === 1)
                root.clearAll();
            if (root._settled(h) && h === 0 && root.shown().length === 0) {
                root._setupI = 0;
                root._go("setup");
            }
            return;
        case "setup":
            // one toast every 30 frames, oldest first (each lands, then the next)
            if (root._setupI < sc.setup.length) {
                if (root._f % 30 === 1) {
                    root.post(sc.setup[root._setupI]);
                    root._setupI++;
                }
                return;
            }
            root._go("settle");
            return;
        case "settle":
            if (root._settled(h) && (h > 0 || sc.setup.length === 0)) {
                root._h0 = h;
                root._lastPost = "";
                root._trace = [];
                root._go("act");
                root._step();         // the action's first call is THIS frame
            }
            return;
        case "act":
            root._film(sc);
            root._trace.push({ f: root._trace.length, h: h, rows: root.rowsH() });
            if (sc.act(root._f - 1))
                root._go("watch");
            return;
        case "watch":
            root._film(sc);
            root._trace.push({ f: root._trace.length, h: h, rows: root.rowsH() });
            if (root._settled(h)) {
                root._judge(sc);
                root._rest(sc);
                // the next scenario's first step (its clear) lands before a grab of THIS frame is drawn, and the picture
                // shows it: the rest picture is waited for
                root._pendingNext = true;
            }
            return;
        }
    }
    function _film(sc) {
        const n = root._trace.length;
        if (root.filmDir === "" || n % root.filmEvery !== 0 || n > root.filmN * root.filmEvery)
            return;
        const path = root.filmDir + "/" + sc.name + "_" + String(n).padStart(3, "0") + ".png";
        root._grab(path);
        if (root.entryMode && sc.arrival)
            root._cardState(sc, String(n));
    }
    // A grab lands a frame or two after its request: the run does not end before the last one is on disk.
    property int _grabs: 0
    property bool _finishing: false
    function _grab(path) {
        root._grabs++;
        stage.grabToImage(r => {
            r.saveToFile(path);
            root._grabs--;
        });
    }
    // ---- THE ARRIVAL CHECK's state of a frame (tools/dev/toast_entry_judge.py) ----------------------------------------------
    // The arriving card's rect on the stage (device px), its presence, and the top of the opaque row lying over its place
    // (the next row down the column, while its card shows: 1e9 when nothing does). Taken in the turn the grab is asked for.
    function _slotsOf(): var {
        const c = engine.theLane ? engine.theLane.contentItem : null;
        const st = root.find(c, "toastStack");
        const out = [];
        if (!st)
            return out;
        for (let i = 0; i < st.children.length; i++)
            if (st.children[i].uid !== undefined && st.children[i].card)
                out.push(st.children[i]);
        out.sort((a, b) => a.y - b.y);
        return out;
    }
    function _cardState(sc, tag) {
        const all = root._slotsOf();
        let at = -1;
        for (let i = 0; i < all.length; i++)
            if (all[i].uid === root._lastPost)
                at = i;
        if (at < 0) {
            console.log("HANDOVER card " + sc.name + " " + tag + " none");
            return;
        }
        const c = all[at].card;
        const o = c.mapToItem(stage, 0, 0);
        // and in the content's own frame: the lane's box travels while it opens, the card does not move in the content
        const q = c.mapToItem(engine.theLane.contentItem, 0, 0);
        const z = root.zoom;
        let cover = 1e9, under = 1;
        // the rows after it in the column lie over it (a later sibling); with the bar at the bottom the newest row is the last
        for (let i = at + 1; i < all.length; i++) {
            if (all[i].waiting || all[i].card.opacity < 0.5)
                continue;
            cover = Math.min(cover, all[i].card.mapToItem(stage, 0, 0).y);
            // painted below it: a lower z, or the same z and an earlier place among the column's children (Qt's paint order)
            if (!root._paintedBefore(all[at], all[i]))
                under = 0;
        }
        console.log("HANDOVER card " + sc.name + " " + tag + " " + o.x.toFixed(2) + " " + o.y.toFixed(2) + " "
            + (o.x + c.width * z).toFixed(2) + " " + (o.y + c.height * z).toFixed(2) + " " + all[at].presence.toFixed(4) + " "
            + cover.toFixed(2) + " " + under + " " + q.x.toFixed(2) + " " + q.y.toFixed(2) + " " + root._boxText());
    }
    // the lane's box as drawn, on the stage (the bar's own face is not in it: with the bar at the bottom the picture's alpha goes on past it)
    function _boxText(): string {
        const b = engine.theLane ? engine.theLane.box : null;
        if (!b)
            return "0 0 0 0";
        const z = root.zoom;
        return (b.x0 * z).toFixed(2) + " " + (b.y0 * z).toFixed(2) + " " + (b.x1 * z).toFixed(2) + " " + (b.y1 * z).toFixed(2);
    }
    function _paintedBefore(a, b): bool {
        if (a.z !== b.z)
            return a.z < b.z;
        const kids = a.parent.children;
        let ia = -1, ib = -1;
        for (let i = 0; i < kids.length; i++) {
            if (kids[i] === a)
                ia = i;
            if (kids[i] === b)
                ib = i;
        }
        return ia < ib;
    }
    // the settled stack, once, for the arrival check to read the card's own pixels from
    function _rest(sc) {
        if (!root.entryMode || root.filmDir === "" || !sc.arrival)
            return;
        root._grab(root.filmDir + "/" + sc.name + "_rest.png");
        root._cardState(sc, "rest");
    }
    function _judge(sc) {
        const tr = root._trace.slice(0, root._trace.length - 30);   // the still frames at the end are not the motion
        const h0 = root._h0, h1 = root._trace[root._trace.length - 1].h;
        let mx = -1e9, mn = 1e9, rev = 0, dir = 0, ref = h0, moved = -1;
        for (let i = 0; i < tr.length; i++) {
            const v = tr[i].h;
            mx = Math.max(mx, v);
            mn = Math.min(mn, v);
            if (moved < 0 && Math.abs(v - h0) > 0.01)
                moved = i;
            // a change of direction counts once the box has gone back 0.5 px from its turning point
            if (dir >= 0 && v > ref) {
                ref = v;
                dir = dir === 0 && v - h0 > 0.5 ? 1 : dir;
            }
            if (dir <= 0 && v < ref) {
                ref = v;
                dir = dir === 0 && h0 - v > 0.5 ? -1 : dir;
            }
            if (dir === 1 && v < ref - 0.5) {
                rev++;
                dir = -1;
                ref = v;
            } else if (dir === -1 && v > ref + 0.5) {
                rev++;
                dir = 1;
                ref = v;
            }
        }
        const bump = Math.max(0, mx - Math.max(h0, h1)), dip = Math.max(0, Math.min(h0, h1) - mn);
        const frames = tr.length;
        // the rows against the box: lane - rows at rest is the padding; while they move together it stays there
        const restGap = root._trace[root._trace.length - 1].h - root._trace[root._trace.length - 1].rows;
        let part = 0;
        for (let i = 0; i < tr.length; i++)
            if (tr[i].h > 0)
                part = Math.max(part, Math.abs(tr[i].h - tr[i].rows - restGap));
        let ok = true;
        if (sc.judge === "agree")
            ok = part <= 2.5;
        else if (sc.judge)
            ok = rev === 0 && bump <= 0.5 && dip <= 0.5;
        if (root.entryMode)
            ok = true;
        if (!ok)
            root.fails++;
        console.log("HANDOVER " + (sc.judge ? (ok ? "ok   " : "FAIL ") : "told ") + sc.name + " h " + h0.toFixed(1) + " -> " + h1.toFixed(1)
            + " bump " + bump.toFixed(1) + " dip " + dip.toFixed(1) + " reversals " + rev + " frames " + frames
            + " firstmove " + moved + " apart " + part.toFixed(1));
        // the trace, for the runner to write out (OUT_DIR/<scenario>.csv)
        for (let i = 0; i < root._trace.length; i++)
            console.log("HANDOVER csv " + sc.name + " " + root._trace[i].f + "," + root._trace[i].h.toFixed(2) + "," + root._trace[i].rows.toFixed(2));
    }
    function _finish() {
        if (root._grabs > 0) {
            root._finishing = true;
            return;
        }
        if (root._sc < 0 || (root.only !== "" && root.scenarios.every(s => root.onlyList.indexOf(s.name) < 0))) {
            root.fails++;
            console.log("HANDOVER FAIL no scenario ran");
        }
        console.log("HANDOVER RESULT " + (root.fails === 0 ? "PASS" : "FAIL (" + root.fails + ")"));
        driver.running = false;
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }
    FrameAnimation {
        id: driver
        running: true
        onTriggered: {
            try {
                root._step();
            } catch (e) {
                root.fails++;
                console.log("HANDOVER FAIL a step threw: " + e);
                root._finish();
            }
        }
    }
}
