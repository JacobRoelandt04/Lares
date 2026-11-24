import QtQuick
import "modules/common/notify"
import "modules/silicon"

// SiliconMuxWatcher (and its MuxKeepPrompt) on a stub notification service and a stub view model: the keep prompt is ONE TOAST,
// put up once the session is UNLOCKED and the shell is on the glass (never under the boot lock: the user's dGPU boot, 2026-11-10),
// the helper is told it is up only when the toast is on the glass, the card's drain carries the helper's own deadline, Keep and
// Go back now reach the helper's calls, and the lock takes the toast away and gives it back. Prints MUXW lines and one
// `MUXW RESULT PASS|FAIL`. Runner: tools/dev/silicon_mux_watcher_probe.sh.
Item {
    id: root
    width: 10
    height: 10

    property var fails: []
    property int checks: 0
    function check(id, ok, detail) {
        root.checks++;
        console.log("MUXW " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails.push(id);
    }

    // ---- the notification service, as far as the watcher and the prompt read it ----
    QtObject {
        id: bus
        property var posts: []              // every post, in order (the spec)
        property var updates: []            // every update { uid, patch }
        property var withdrawn: []          // keys withdrawn
        property var records: ({})          // uid -> the spec of the live record
        property int seq: 0
        signal recordRemoved(string uid)
        readonly property QtObject store: QtObject {
            function get(uid) { return bus.records[uid] ? { uid: uid } : null; }
        }
        readonly property QtObject toasts: QtObject {
            property var shown: []
            property bool blocked: false
            property bool unplaced: false
            property int serial: 0
        }
        function post(spec) {
            bus.posts.push(spec);
            let uid = "";
            for (const k in bus.records)
                if (bus.records[k].key === spec.key && bus.records[k].source === spec.source)
                    uid = k;
            if (uid === "")
                uid = "u" + (++bus.seq);
            const r = bus.records;
            r[uid] = spec;
            bus.records = r;
            return uid;
        }
        function update(uid, patch) {
            bus.updates.push({ uid: uid, patch: patch });
            return !!bus.records[uid];
        }
        function withdraw(source, key) {
            bus.withdrawn.push(key);
            const r = bus.records;
            for (const k in r)
                if (r[k].key === key && r[k].source === source) {
                    delete r[k];
                    bus.toasts.shown = bus.toasts.shown.filter(u => u !== k);
                    bus.toasts.serial++;
                }
            bus.records = r;
        }
        function attend() {}
        // the lane takes the toast (or loses it): what the scheduler's `shown` says
        function lane(uid, on) {
            bus.toasts.shown = on ? [uid] : [];
            bus.toasts.serial++;
        }
        function invoke(uid, id) {
            const s = bus.records[uid];
            if (s && s.onAction)
                s.onAction(id);
        }
        function keepUid() {
            for (const k in bus.records)
                if (bus.records[k].key === "silicon-mux-keep")
                    return k;
            return "";
        }
        function keepPosts() { return bus.posts.filter(p => p.key === "silicon-mux-keep"); }
        function notes() { return bus.posts.filter(p => p.key === "silicon-mux"); }
    }
    function stubBus() {
        NotificationBus.service = bus;
    }

    // ---- the view model: the record and the helper's four calls ----
    QtObject {
        id: stubVm
        property var gpu: ({ mux: { state: "awaiting-keep", want: "dgpu", outcomeSeen: true, promptWindowS: 120, bootId: "", deadlineBootId: "",
                                    deadlineMs: Date.now() + 200000 } })
        property var helper: ({ ok: true })
        property int shownCalls: 0
        property int keepCalls: 0
        property var requests: []
        property int rebootCalls: 0
        property bool keepWorks: true
        property bool requestWorks: true
        signal writeRefused(string zone, string why)
        function mux() { return stubVm.gpu.mux; }
        function set(patch) { stubVm.gpu = { mux: Object.assign({}, stubVm.gpu.mux, patch) }; }
        function setState(s) { stubVm.set({ state: s }); }
        function markMuxOutcomeSeen() { stubVm.set({ outcomeSeen: true }); }
        // the helper shortens the guard's window to the prompt's own (a late unlock: 100 s of the boot's window were left)
        function muxPromptShown() {
            stubVm.shownCalls++;
            shorten.start();
            return true;
        }
        function muxKeep() {
            stubVm.keepCalls++;
            if (stubVm.keepWorks)
                lag.fire(() => stubVm.set({ state: "kept", deadlineMs: null }));
            return true;
        }
        function muxRequest(want) {
            stubVm.requests.push(want);
            if (!stubVm.requestWorks)
                return false;
            lag.fire(() => stubVm.set({ state: "queued", want: want }));
            return true;
        }
        function muxRebootNow() {
            stubVm.rebootCalls++;
            lag.fire(() => stubVm.set({ state: "" }));
            return true;
        }
    }
    Timer {
        id: shorten
        interval: 30
        onTriggered: stubVm.set({ deadlineMs: Date.now() + 100000 })
    }
    Timer {
        id: lag
        property var fn: null
        interval: 30
        onTriggered: lag.fn()
        function fire(f) { lag.fn = f; lag.restart(); }
    }

    SiliconMuxWatcher {
        id: w
        vm: stubVm
        locked: true            // the shell starts under the boot lock
        shown: true
    }

    // wait a stretch of live time, then continue
    property var queue: []
    function later(ms, fn) { root.queue.push({ ms: ms, fn: fn }); }
    function pump() {
        if (root.queue.length === 0) { root.finish(); return; }
        const q = root.queue.shift();
        pause.interval = q.ms;
        pause.restart();
        pause.fn = q.fn;
    }
    Timer {
        id: pause
        property var fn: null
        // a step that throws is a failed check, never a chain that stops without its RESULT line
        onTriggered: {
            try {
                pause.fn();
            } catch (e) {
                root.check("step-threw", false, String(e));
            }
            root.pump();
        }
    }

    Component.onCompleted: {
        root.stubBus();
        // 1. under the lock, a long time: nothing is posted, the helper is told nothing
        root.later(500, () => {
            root.check("locked-no-post", bus.keepPosts().length === 0 && stubVm.shownCalls === 0, "posts " + bus.keepPosts().length + " told " + stubVm.shownCalls);
            w.locked = false;
        });
        // 2. unlocked: ONE toast, and it is a fixed, DND-proof one with the two answers
        root.later(300, () => {
            const p = bus.keepPosts();
            root.check("unlock-posts-one", p.length === 1, "posts " + p.length);
            const s = p[0] || {};
            root.check("toast-is-fixed", s.fixed === true && s.timeoutMs === -1 && s.breakDnd === true && s.urgency === "normal",
                       JSON.stringify({ fixed: s.fixed, timeoutMs: s.timeoutMs, breakDnd: s.breakDnd, urgency: s.urgency }));
            root.check("toast-answers", (s.actions || []).map(a => a.id).join() === "back,keep" && s.title === "Keep dGPU only?", JSON.stringify((s.actions || []).map(a => a.id)) + " " + s.title);
            root.check("toast-no-deadline-yet", bus.updates.length === 0 && stubVm.shownCalls === 0, "updates " + bus.updates.length + " told " + stubVm.shownCalls);
        });
        // 3. the lane is folded away: still not on the glass, the helper is not told
        root.later(400, () => {
            root.check("not-told-before-glass", stubVm.shownCalls === 0, "told " + stubVm.shownCalls);
            bus.toasts.blocked = true;
            bus.lane(bus.keepUid(), true);          // in the stack, but the lane is folded away beside a popup
        });
        root.later(300, () => {
            root.check("not-told-while-blocked", stubVm.shownCalls === 0, "told " + stubVm.shownCalls);
            bus.toasts.blocked = false;
            bus.toasts.serial++;
        });
        // 4. on the glass: told ONCE; the window shortens; the drain carries the helper's deadline
        root.later(500, () => {
            root.check("told-once-on-glass", stubVm.shownCalls === 1, "told " + stubVm.shownCalls);
            const u = bus.updates.filter(x => x.patch.deadlineMs !== undefined);
            const last = u.length ? u[u.length - 1].patch : {};
            const rem = last.deadlineMs - Date.now();
            root.check("deadline-on-record", u.length >= 1 && rem > 80000 && rem <= 101000 && last.deadlineTotalMs > 80000 && last.deadlineTotalMs <= 101500,
                       "updates " + u.length + " remaining " + Math.round(rem / 1000) + " s total " + Math.round(last.deadlineTotalMs / 1000) + " s");
            root.check("figure-is-the-guards-clock", w.prompt.figureShown && /^\d:\d\d$/.test(w.prompt.countdownText), w.prompt.countdownText);
        });
        // 5. the helper moves its deadline LATER: the span stretches (a drain never refills)
        root.later(100, () => {
            root.before = bus.updates.filter(x => x.patch.deadlineMs !== undefined).length;
            stubVm.set({ deadlineMs: Date.now() + 119000 });
        });
        root.later(300, () => {
            const u = bus.updates.filter(x => x.patch.deadlineMs !== undefined);
            const a = u[root.before - 1].patch;
            const b = u[u.length - 1].patch;
            root.check("later-deadline-stretches-the-span", u.length > root.before && b.deadlineTotalMs > a.deadlineTotalMs && b.deadlineMs > a.deadlineMs,
                       JSON.stringify([a.deadlineTotalMs, b.deadlineTotalMs]));
        });
        // 6. the lock comes with the toast up: it takes it away; the unlock gives it back and the helper is not told again
        root.later(100, () => {
            w.locked = true;
        });
        root.later(300, () => {
            root.check("lock-takes-the-toast", bus.keepUid() === "" && bus.withdrawn.indexOf("silicon-mux-keep") >= 0, "uid " + bus.keepUid());
            w.locked = false;
        });
        root.later(300, () => {
            root.check("unlock-gives-it-back", bus.keepPosts().length === 2 && bus.keepUid() !== "", "posts " + bus.keepPosts().length);
            bus.lane(bus.keepUid(), true);
        });
        root.later(300, () => {
            root.check("not-told-again", stubVm.shownCalls === 1, "told " + stubVm.shownCalls);
        });
        // 7. Keep reaches the helper; the toast stays until the FACTS say kept (a Keep the helper refused leaves it standing)
        root.later(100, () => {
            stubVm.keepWorks = false;
            bus.invoke(bus.keepUid(), "keep");
        });
        root.later(300, () => {
            root.check("keep-reaches-the-helper", stubVm.keepCalls === 1, "calls " + stubVm.keepCalls);
            root.check("refused-keep-leaves-the-toast", bus.keepUid() !== "", "uid " + bus.keepUid());
            stubVm.keepWorks = true;
        });
        root.later(4300, () => {         // the click guard (4 s) is over: a second click is a click again
            bus.invoke(bus.keepUid(), "keep");
        });
        root.later(400, () => {
            root.check("kept-takes-the-toast", stubVm.mux().state === "kept" && bus.keepUid() === "" && bus.notes().length === 0,
                       stubVm.mux().state + " uid " + bus.keepUid() + " notes " + bus.notes().length);
        });
        // 8. Go back now: keep, request Hybrid, restart -- each step waited for on the facts -- and the toast says so
        root.later(100, () => {
            stubVm.set({ state: "awaiting-keep", want: "dgpu", deadlineMs: Date.now() + 100000 });
        });
        root.later(300, () => {
            bus.lane(bus.keepUid(), true);
        });
        root.later(200, () => {
            stubVm.keepCalls = 0;
            bus.invoke(bus.keepUid(), "back");
        });
        root.later(1200, () => {
            root.check("goback-keeps-asks-restarts", stubVm.keepCalls === 1 && stubVm.requests.join() === "hybrid" && stubVm.rebootCalls === 1,
                       "keep " + stubVm.keepCalls + " requests " + stubVm.requests.join() + " reboot " + stubVm.rebootCalls);
            const back = bus.keepPosts().filter(p => p.title === "Going back to Hybrid");
            root.check("goback-says-so", back.length >= 1 && back[0].actions.length === 0 && back[0].fixed === true, "posts " + bus.keepPosts().map(p => p.title).join(" | "));
            root.check("goback-ends-with-no-toast", bus.keepUid() === "", "uid " + bus.keepUid());
        });
        // 9. a way back whose Hybrid request is refused: the keep took, so the prompt is over and the user is told
        root.later(100, () => {
            stubVm.requests = [];
            stubVm.requestWorks = false;
            stubVm.set({ state: "awaiting-keep", want: "dgpu", deadlineMs: Date.now() + 100000 });
        });
        root.later(300, () => {
            bus.lane(bus.keepUid(), true);
        });
        root.later(200, () => {
            bus.invoke(bus.keepUid(), "back");
        });
        root.later(800, () => {
            const n = bus.notes();
            root.check("failed-way-back-is-told", n.length === 1 && /did not go through/.test(n[0].title) && /dGPU only stays on/.test(n[0].body),
                       JSON.stringify(n.map(x => x.title + ": " + x.body)));
            root.check("failed-way-back-ends-the-prompt", bus.keepUid() === "", "uid " + bus.keepUid());
            stubVm.requestWorks = true;
        });
        // 10. the guard's revert seen happening: the toast says where it is going until the outcome has been told
        root.later(100, () => {
            stubVm.set({ state: "awaiting-keep", want: "dgpu", outcomeSeen: true, deadlineMs: Date.now() + 100000 });
        });
        root.later(300, () => {
            bus.lane(bus.keepUid(), true);
            stubVm.set({ state: "reverted", outcomeSeen: false });
        });
        root.later(300, () => {
            const p = bus.keepPosts();
            root.check("revert-seen-says-going-back", p.length > 0 && p[p.length - 1].title === "Going back to Hybrid" && bus.keepUid() !== "",
                       bus.keepPosts().map(x => x.title).join(" | "));
            stubVm.markMuxOutcomeSeen();
        });
        root.later(300, () => {
            root.check("outcome-told-takes-the-toast", bus.keepUid() === "", "uid " + bus.keepUid());
            stubVm.setState("kept");
        });
        // 11. a new episode before the frame is on the glass: nothing; then shown: the toast
        root.later(100, () => {
            w.shown = false;
            stubVm.set({ state: "awaiting-keep", want: "dgpu", deadlineMs: Date.now() + 100000 });
        });
        root.later(400, () => {
            root.check("unshown-no-post", bus.keepUid() === "", "uid " + bus.keepUid());
            w.shown = true;
        });
        root.later(300, () => {
            root.check("shown-posts", bus.keepUid() !== "", "uid " + bus.keepUid());
            stubVm.setState("kept");
        });
        // 12. a long lock, many times any give-up a retry budget used to have, then the unlock: the toast still comes
        root.later(200, () => {
            w.locked = true;
            stubVm.set({ state: "awaiting-keep", want: "dgpu", deadlineMs: Date.now() + 100000 });
        });
        root.later(1500, () => {
            root.check("long-lock-no-post", bus.keepUid() === "", "uid " + bus.keepUid());
            w.locked = false;
        });
        root.later(300, () => {
            root.check("long-lock-then-unlock-posts", bus.keepUid() !== "", "uid " + bus.keepUid());
        });
    }
    property int before: 0

    function finish() {
        console.log("MUXW RESULT " + (root.fails.length === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks" + (root.fails.length ? "; failed: " + root.fails.join(", ") : "") + ")");
        quit.start();
    }
    Timer { id: quit; interval: 50; onTriggered: Qt.quit() }
    Timer { running: true; interval: 100; onTriggered: root.pump() }
}
