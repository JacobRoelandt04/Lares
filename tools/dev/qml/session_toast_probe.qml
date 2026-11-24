pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Quickshell registers the types reachable from the ROOT file's imports.
// qmllint disable unused-imports
import "modules/common/theme"
import "modules/common/components"
import "modules/common/notify"
import "modules/bar/gooey"
import "modules/notifications"
import "modules/notifications/parts"
import "modules/notifications/data"
import "modules/session"
// qmllint enable unused-imports

// =============================================================================
// tools/dev/qml/session_toast_probe.qml -- session restore's three toasts as the user sees them (feedback/general.md, "Session
// restore confirmation toast and status toast"): the REAL SessionService on a stub of tools/session/lares-session, the REAL
// NotificationService (no bus, no disk) behind NotificationBus, the real engine lane and toast stack, driven by frames.
//
// What the user saw on 2026-11-15 (MUX mode, deployed 7fc0f21c): restore 1 -> "Session restored: 4 commands are typed" (toast ok);
// restore 2 -> no toast at the end; restore 3 -> the status toast stuck at "6 of 10" while the windows were already back. Each
// scenario here is one restore's sequence with its timing shape; the verdicts are about what is ON THE LANE, not about what was posted:
//
//   every scenario   no GHOST: a uid on the scheduler's `shown` with no record in the store, or a row of the stack whose card shows
//                    a record that is gone, past the time its exit takes
//   clean            ask -> click -> progress (0..10 of 10) -> reveal -> a result with nothing for the user to do
//                    the lane ends with ONE row, "10 windows are back" (the closing confirmation), the progress row and record are
//                    gone, and the confirmation goes by itself (6 s): the lane closes, no row is left
//   tell             the same, the result telling 4 typed commands: ONE row, the result, then it goes by itself (12 s)
//   prewarm          the clean restore while the start-up prewarm builds popups in the same window
//   stall            the GUI thread is away for seconds at 6 of 10 (a cold shader compile: the tool goes on, its lines wait in the
//                    pipe): the toast catches up at once, nothing is left stuck
//
// Prints `STP <check>: ok|FAIL` lines and one `SESSION_TOAST RESULT PASS|FAIL`. Runner: tools/dev/session_toast_probe.sh (env).
// =============================================================================
ShellRoot {
    id: root

    readonly property string work: Quickshell.env("STP_WORK") || ""
    readonly property string only: Quickshell.env("ONLY") || ""
    property int fails: 0
    property int checks: 0
    function check(id, ok, detail) {
        root.checks++;
        console.log("STP " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails++;
    }

    NotificationService {
        id: svc
        serverEnabled: false
        registerOnBus: true
        persist: false
        liveSignals: false
        ipcEnabled: false
        configPath: ""
    }
    BoundaryClock {
        id: laneClock
        active: true
    }
    NotificationStyle {
        id: nstyle
    }
    DesktopNotifier {
        id: toastNotifier
        appName: "Session"
        keys: ["restore", "progress", "result", "spare"]
    }
    Component {
        id: svcComp
        SessionService {
            notifier: toastNotifier
            live: true
            locked: false
            shown: true
        }
    }

    FloatingWindow {
        id: win
        implicitWidth: 900
        implicitHeight: 700
        visible: true
        color: Theme.surface

        GooeyEngine {
            id: laneEngine
            anchors.fill: parent
            surfaceColor: Theme.surface
            barsList: [topBar]

            GooeyBar {
                id: topBar
                engine: laneEngine
                barId: "top"
                edge: "top"
                rawPos: 0
                rawLen: laneEngine.w
                Item {
                    id: bell
                    x: 600
                    y: Math.round((topBar.height - 24) / 2)
                    width: 24
                    height: 24
                }
            }
        }
        Item {
            id: holder
        }
        NotificationsBarOwner {
            id: owner
            engine: laneEngine
            bar: topBar
            barId: "top"
            anchorItem: bell
            screenName: svc.laneScreen
            service: svc
            clock: laneClock
            // qmllint disable incompatible-type
            // (qmllint calls the one NotificationStyle two types here; the same lines lint clean in toast_handover_probe.qml)
            style: nstyle
            // qmllint enable incompatible-type
        }
    }

    // ---- what the lane shows, read every frame --------------------------------------------------------------------
    function laneOpen() {
        const L = laneEngine.theLane;
        return !!L && !!L.box && L.phase !== "closed";
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
    function stackRows() {
        const c = laneEngine.theLane ? laneEngine.theLane.contentItem : null;
        const st = root.find(c, "toastStack");
        const out = [];
        if (!st)
            return out;
        for (let i = 0; i < st.children.length; i++) {
            const k = st.children[i];
            if (k.uid === undefined)
                continue;
            out.push(k);
        }
        return out;
    }
    // what a row's card says (its body text), "" for none
    function wordsOf(row) {
        return row.card && row.card.d ? String(row.card.d.bodyText || "") : "";
    }
    function titleOf(row) {
        return row.card && row.card.d ? String(row.card.d.summary || "") : "";
    }
    function recordOf(uid) {
        return svc.store.get(uid);
    }
    function ghosts() {
        const g = [];
        const shown = svc.toasts.shown;
        for (let i = 0; i < shown.length; i++)
            if (!root.recordOf(shown[i]))
                g.push("shown " + shown[i]);
        return g;
    }
    function rowsSummary() {
        return root.stackRows().map(r => r.uid.split("-")[1] + (r.leaving ? "(leaving)" : "") + (r.waiting ? "(waiting)" : "")
                                          + (r.collapsing ? "(collapsing)" : "") + ":" + root.wordsOf(r).split("\n")[0]).join(" | ");
    }

    // ---- the stub tool ---------------------------------------------------------------------------------------------
    // (the runner writes <work>/<name>/{lares-session,session.jsonc,begin.json,restore.txt}; restore.txt is the real tool's stdout, one
    // line at a time, a `sleep <s>` line between)
    function make(name) {
        return svcComp.createObject(holder, { tool: root.work + "/" + name + "/lares-session", configPath: root.work + "/" + name + "/session.jsonc" });
    }

    // ---- the sequencer -------------------------------------------------------------------------------------------
    property var scenarios: []
    property int _sc: -1
    property var sess: null
    property string _stage: "boot"
    property int _f: 0
    property double _t0: 0
    property var _log: []
    property var ctx: ({})
    function mark(what) {
        root._log.push(((Date.now() - root._t0) / 1000).toFixed(2) + "s f" + root._f + " " + what);
    }

    function _next() {
        if (root.sess) {
            root.sess.destroy();
            root.sess = null;
        }
        do {
            root._sc++;
        } while (root._sc < root.scenarios.length && root.only !== "" && root.scenarios[root._sc].name !== root.only);
        if (root._sc >= root.scenarios.length) {
            root._finish();
            return;
        }
        root._stage = "clear";
        root._f = 0;
    }
    function _go(stage) {
        root._stage = stage;
        root._f = 0;
    }

    // Each scenario: name, a stub dir, and a `run(f)` called every frame once the ask is up; it moves the scenario along by `ctx` and
    // returns true when it is over (after which the lane gets `settleFrames` to come to rest, then `judge` reads it).
    property var _lastRows: ""
    property string _lastPhase: ""
    function _watch() {
        // every frame: a ghost is a fault only once it has stood still for a while (an exit takes its time)
        const g = root.ghosts();
        if (g.length > 0) {
            root.ctx.ghostFrames = (root.ctx.ghostFrames || 0) + 1;
            root.ctx.ghostWhat = g.join(",");
        } else {
            root.ctx.ghostFrames = 0;
        }
        const ph = laneEngine.theLane ? laneEngine.theLane.phase : "";
        if (ph !== root._lastPhase) {
            root._lastPhase = ph;
            root.mark("lane phase " + ph);
        }
        const s = root.rowsSummary();
        if (s !== root._lastRows) {
            root._lastRows = s;
            root.mark("lane " + (root.laneOpen() ? "open" : "closed") + " shown=" + svc.toasts.shown.length + " rows[" + s + "]");
        }
    }

    function _step() {
        root._f++;
        if (root._stage === "boot") {
            if (root._f > 20)
                root._next();
            return;
        }
        const sc = root.scenarios[root._sc];
        root._watch();
        if (root._f > 1800) {
            root.check(sc.name + ": finished (stage " + root._stage + ")", false, "never got there; lane " + root.laneOpen() + " rows[" + root.rowsSummary() + "]");
            root._finish(true);
            return;
        }
        if (root._stage === "expire") {
            root._expireStep(sc);
            return;
        }
        switch (root._stage) {
        case "clear": {
            // an empty, closed lane before the scenario
            const s = svc.toasts.shown.slice();
            for (let i = 0; i < s.length; i++)
                svc.remove(s[i]);
            if (root._f > 40 && !root.laneOpen() && root.stackRows().length === 0 && svc.toasts.shown.length === 0) {
                root.ctx = { name: sc.name };
                root._log = [];
                root._t0 = Date.now();
                root.sess = root.make(sc.name);
                root._go("ask");
            }
            return;
        }
        case "ask":
            // begin -> the ask on the lane
            if (root.sess.phase === "asking" && svc.toasts.shown.length === 1 && root._f > 30) {
                root.mark("the ask is up: " + root.titleOf(root.stackRows()[0]));
                root.ctx.askUid = svc.toasts.shown[0];
                root._go("click");
            }
            return;
        case "click":
            if (root._f < 10)
                return;
            // the user's click on Restore (the real path: the record is consumed, then the source's callback runs)
            root.mark("click Restore");
            root.ctx.clickF = 0;
            svc.invoke(root.ctx.askUid, "restore");
            root._go("run");
            return;
        case "run":
            root.ctx.clickF++;
            if (sc.run(root.ctx.clickF, root.sess))
                root._go("rest");
            return;
        case "rest":
            // the result is in: let the lane come to rest (2.5 s of frames, the exits' and the lane close's time)
            if (root._f >= 150) {
                try {
                    sc.judge(root.sess);
                } catch (e) {
                    root.check(sc.name + ": judged", false, "threw: " + e);
                }
                if (sc.expireMs > 0) {
                    root.ctx.expireAt = Date.now() + sc.expireMs;
                    root._go("expire");
                    return;
                }
                console.log("STP timeline " + sc.name + "\n   " + root._log.join("\n   "));
                root._next();
            }
            return;
        }
    }
    // The confirmation goes by itself (its own timeout, on the wall clock): the lane closes and nothing is left.
    function _expireStep(sc) {
        const gone = !root.laneOpen() && root.stackRows().length === 0 && svc.toasts.shown.length === 0 && root._f > 20;
        if (!gone && Date.now() <= root.ctx.expireAt)
            return;
        root.check(sc.name + ": the confirmation went by itself", gone, gone ? ((Date.now() - root._t0) / 1000).toFixed(1) + " s in"
                   : "still there: rows[" + root.rowsSummary() + "] shown=" + svc.toasts.shown.length);
        console.log("STP timeline " + sc.name + "\n   " + root._log.join("\n   "));
        root._next();
    }
    function _finish(abort) {
        if (root._sc < 0 || (root.only !== "" && root.scenarios.every(s => s.name !== root.only))) {
            root.fails++;
            console.log("STP FAIL no scenario ran");
        }
        console.log("SESSION_TOAST RESULT " + (root.fails === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks"
                    + (root.fails ? ", " + root.fails + " failed" : "") + ")");
        driver.running = false;
        quitTimer.start();
    }
    Timer {
        id: quitTimer
        interval: 0
        onTriggered: Qt.quit()
    }

    // ---- the scenarios ---------------------------------------------------------------------------------------------
    // The result is in when the service says so (lastResult) and a few frames have gone.
    function stall(ms) {
        const end = Date.now() + ms;
        while (Date.now() < end) {
        }
    }
    function _resultIn(sess) {
        return sess.lastResult !== null && sess.phase === "idle";
    }
    // The lane's only row is the closing confirmation, with these words and no progress row beside it.
    function _onlyConfirm(sc, words) {
        const rows = root.stackRows();
        root.check(sc + ": ONE row is left, the confirmation: \"" + words + "\"", rows.length === 1 && /Session restored/.test(root.titleOf(rows[0]))
                   && root.wordsOf(rows[0]).indexOf(words) === 0 && !rows[0].leaving, "rows[" + root.rowsSummary() + "]");
        root.check(sc + ": the lane is open for it", root.laneOpen(), "closed");
        root.check(sc + ": no progress record is left in the store", svc.store.all().filter(r => r.sourceId === "session" && r.key === "progress").length === 0,
                   JSON.stringify(svc.store.all().filter(r => r.sourceId === "session").map(r => r.key + ":" + r.bodyText)));
    }
    function _noGhost(sc) {
        root.check(sc + ": no ghost row (a shown uid with no record)", (root.ctx.ghostFrames || 0) < 60 && root.ghosts().length === 0,
                   "ghost frames " + root.ctx.ghostFrames + " " + (root.ctx.ghostWhat || ""));
    }
    Component.onCompleted: {
        root.scenarios = [
            // restore 3 of the user's run: nothing to tell
            { name: "clean", expireMs: 12000, run: (f, sess) => root._resultIn(sess) && f > 20, judge: sess => {
                root._noGhost("clean");
                root._onlyConfirm("clean", "10 windows are back");
            } },
            // restore 1: something to tell
            { name: "tell", expireMs: 20000, run: (f, sess) => root._resultIn(sess) && f > 20, judge: sess => {
                root._noGhost("tell");
                root._onlyConfirm("tell", "4 commands are typed and wait for Enter");
            } },
            // restore 3 in the shell the user had: the start-up prewarm (6 s after the first frame) builds popups while the restore runs
            { name: "prewarm", run: (f, sess) => {
                if (f === 6 && !root.ctx.pw) {
                    root.ctx.pw = true;
                    root.mark("prewarm asked");
                    laneEngine.prewarm([{ ownerId: owner.ownerId, component: owner.managerComponent, initial: { parked: true } },
                                    { ownerId: owner.ownerId, component: owner.managerComponent, initial: { parked: true } }]);
                }
                return root._resultIn(sess) && f > 20;
            }, judge: sess => {
                root._noGhost("prewarm");
                root._onlyConfirm("prewarm", "10 windows are back");
            } },
            // restore 3 as the user read it: the progress stands at 6 of 10 for a while
            { name: "stall", run: (f, sess) => {
                const rows = root.stackRows();
                // once the count says 6 of 10 the lane shows exactly that, and nothing older
                if (!root.ctx.saw6 && rows.length === 1 && /6 of 10 windows are ready/.test(root.wordsOf(rows[0]))) {
                    root.ctx.saw6 = true;
                    root.mark("the lane shows 6 of 10");
                    // the GUI thread is away for a while (a build, a shader compile): the tool goes on, its lines wait in the pipe
                    root.stall(Number(Quickshell.env("STP_STALL_MS") || 3500));
                    root.mark("the GUI thread is back");
                }
                return root._resultIn(sess) && f > 20;
            }, judge: sess => {
                root._noGhost("stall");
                root.check("stall: the lane showed 6 of 10 while it stood there", root.ctx.saw6 === true, "never");
                root._onlyConfirm("stall", "10 windows are back");
            } }
        ];
        if (root.work === "") {
            quitTimer.start();                       // smoked bare: nothing to drive
            return;
        }
    }
    FrameAnimation {
        id: driver
        running: root.work !== ""
        onTriggered: {
            try {
                root._step();
            } catch (e) {
                root.fails++;
                console.log("STP FAIL a step threw: " + e);
                root._finish(true);
            }
        }
    }
}
