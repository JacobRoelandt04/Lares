pragma ComponentBehavior: Bound

import QtQuick
import "NotifyPolicy.js" as Policy
import "../../common/system"

// =============================================================================
// ToastScheduler.qml -- which notifications are toasts right now, and for how
// long (`service.toasts`).
//
// THE STACK. `shown` is newest first and never longer than `maxToasts`. A new
// toast on a full stack FILES the oldest one at once (it leaves the lane, its
// record stays) and counts it in `moreCount` -- the "+N more" foot -- which
// resets when the stack empties. A FLOOD (NotifyPolicy.floodCheck: more than
// floodCount toasts from one app inside floodWindowMs) files the rest
// silently and counts them on the app's newest toast (`floods[uid]`, the
// "<app> . +N more" line). `held` is what a hold (lock, share, fullscreen) is
// keeping back; the service releases it.
//
// ONE CLOCK. Every toast has a total and a time left; ONE single-shot Timer
// is armed for the earliest deadline, never a timer per toast and never a
// repeating tick. Deadlines are STAGGERED (NotifyPolicy.staggerDeadlines,
// `staggerMs` apart, counted from the last expiry too) and the stagger is
// written back, so a toast that was pushed stays pushed after the one ahead
// of it has gone. `frozen` (hover, the user away, a reply being typed, the
// machine asleep) stops every countdown where it is; on thaw each has at
// least hoverResumeMinMs left. Sticky toasts (-1) never expire.
//
// A COUNTDOWN NEVER REFILLS. The view draws `leftMs / totalMs`, so whatever
// moves a deadline LATER -- a stagger, the thaw's minimum -- stretches the
// total by the same ratio (`_stretch`): the fraction drawn stays where it is
// and drains over the new time. A thaw that only raised the time left would
// draw a hovered toast near its end refilling in one frame (0.048 -> 0.244)
// and a staggered newcomer above full (3116 of 3000 ms, parked at
// the ShadowBox's cap for the length of the push). `totalMs` is therefore
// the DRAIN's span, not the timeout that was asked for.
//
// A SUSPEND IS AN AWAY HOLD. Qt's timers run on CLOCK_MONOTONIC, which stops
// while the machine sleeps, and the deadlines are wall times: a toast left on
// screen across a suspend would drain to nothing at the resume and then stay
// for the rest of its monotonic time (6.1 s). The machine going to
// sleep (`sleepWatcher.sleeping`, the shell's SleepWatcher) freezes the
// stack like the user going idle, so every live deadline moves by the time
// slept; a resume the watcher saw no start of re-reads the wall at once
// (whatever is due goes then, drain and deadline together).
//
// `serial` bumps on every change a view could show (the stack, the timings,
// a flood count); ToastEntry re-reads `timing(uid)` on it.
// =============================================================================
Item {
    id: root

    property var config: null
    property bool idle: false             // holds.idle, bound by the service
    readonly property int maxToasts: root._toastCfg.max > 0 ? root._toastCfg.max : 5
    // Two toasts never expire closer together than this, so a burst leaves one by one (a constant, tuned in the notifications mockup).
    property int staggerMs: 300
    readonly property int hoverResumeMinMs: root._toastCfg.hoverResumeMinMs >= 0 ? root._toastCfg.hoverResumeMinMs : 2000

    readonly property var shown: root._shown
    readonly property var held: root._held
    readonly property int moreCount: root._more
    readonly property var floods: root._floods
    // The lane had no room beside thePopup (engine.laneBlocked): the stack is
    // folded away, so nothing may run out unseen until it is back.
    property bool blocked: false
    // The service has toasts and no screen to show them on yet (the first turns after a start): the
    // clocks wait like they do for the room beside a popup.
    property bool unplaced: false
    // A theme switch's line is running (ThemeControl). A toast that left during one would show a soft fill where it stood, until the line came: the still has nothing there.
    property bool curtain: false
    // Whose sleeps freeze the stack: the shell's one watcher by default; a
    // probe hands its own (or null for none).
    property var sleepWatcher: Sleep.watcher
    // A reply field is open on a toast of the stack (what the lane's keyboard request follows too).
    readonly property bool replyOpen: root._replying
    readonly property bool frozen: root._hover || root.idle || root._replying || root.blocked || root.unplaced || root.curtain || root._asleep
    readonly property int serial: root._serial

    signal expired(string uid)
    signal overflowed(string uid)         // filed by a full stack
    signal grew()                         // a toast was added to the stack

    // { totalMs, leftMs, sticky } as of now, frozen-aware; null when not shown.
    // leftMs <= totalMs always; totalMs is the drain's span (see the header).
    function timing(uid) {
        const e = root._t[uid];
        if (!e)
            return null;
        return { totalMs: e.total, leftMs: e.sticky ? -1 : Math.max(0, root._leftOf(e, Date.now())), sticky: e.sticky };
    }

    function hover(on) { root._hover = !!on; }
    // A reply field is open (`on`) or closed on the toast `uid`: the clocks stand still while one is. The
    // claim is THE RECORD'S: it goes with the toast when the toast leaves the stack with its field open --
    // the app took its notification back, the user deleted or filed it, a full stack pushed it off -- a card
    // destroyed with its field open says nothing, and a stack frozen for ever is a toast that never expires
    // (and a lane that asks for the keys for ever). A close names the toast it closes (one field closing
    // never releases another's hold); a close naming none releases every hold.
    function replying(on, uid) {
        const u = uid === undefined || uid === null ? "" : String(uid);
        const m = Object.assign({}, root._replyUids);
        if (on)
            m[u] = true;
        else if (u === "")
            for (const k of Object.keys(m))
                delete m[k];
        else
            delete m[u];
        root._setReplies(m);
    }

    // Expire a toast now, as its timer would have.
    function expireNow(uid) {
        if (!root._t[uid])
            return;
        root._expire(uid);
        root._arm();
    }

    // The service's side ---------------------------------------------------------

    // A toast for `rec`: "shown", or "flooded" (filed silently, counted).
    function offer(uid, rec, totalMs) {
        const now = Date.now();
        if (root._t[uid]) {
            root.retoast(uid, totalMs);
            return "shown";
        }
        // A critical is never collapsed into a flood: nothing but the user's
        // own rule files a critical silently. Nor is a FIXED one (a question, a live request): nobody could answer it.
        const fc = Policy.floodCheck(root._hist, rec.appKey, now, root.config);
        if (fc.flooded && rec.urgency !== "critical" && rec.fixed !== true) {
            const top = root._newestOf(rec.appKey);
            if (top !== "") {
                const f = Object.assign({}, root._floods);
                f[top] = (f[top] || 0) + 1;
                root._floods = f;
                root._serial++;
                return "flooded";
            }
        }
        root._hist = root._hist.filter(h => now - h.t <= root._floodWindow()).concat([{ appKey: rec.appKey, t: now }]);
        // A FIXED row (a live request, the auth card) is never the one a full
        // stack pushes off: it is UI something is waiting on, not news. The
        // oldest ordinary row goes instead; only a stack of nothing but fixed
        // rows may stand above maxToasts.
        const fixed = !!rec.fixed;
        const isFixed = u => u === uid ? fixed : !!(root._t[u] && root._t[u].fixed);
        const s = [uid].concat(root._shown);
        while (s.length > root.maxToasts) {
            let k = s.length - 1;
            while (k > 0 && isFixed(s[k]))
                k--;
            if (k === 0)
                break;
            const out = s.splice(k, 1)[0];
            root._drop(out);
            root._more++;
            root.overflowed(out);
        }
        root._t[uid] = root._entry(totalMs, now, rec.appKey, fixed);
        root._shown = s;
        root._restagger(now);
        root._serial++;
        root._arm();
        root.grew();
        return "shown";
    }

    // Restart a shown toast's countdown and bring it to the top.
    function retoast(uid, totalMs) {
        if (!root._t[uid])
            return false;
        const now = Date.now();
        root._t[uid] = root._entry(totalMs, now, root._t[uid].appKey, root._t[uid].fixed);
        root._shown = [uid].concat(root._shown.filter(u => u !== uid));
        root._restagger(now);
        root._serial++;
        root._arm();
        return true;
    }

    // It leaves the lane (filed, removed, withdrawn); no `expired`.
    function unshow(uid) {
        const had = !!root._t[uid] || root._held.indexOf(uid) >= 0;
        root._drop(uid);
        root._held = root._held.filter(u => u !== uid);
        if (had) {
            root._serial++;
            root._arm();
        }
        return had;
    }

    function hold(uid) {
        if (root._held.indexOf(uid) >= 0)
            return;
        root._held = root._held.concat([uid]);
        root._serial++;
    }

    // The held uids, handed over and forgotten.
    function takeHeld() {
        const h = root._held;
        root._held = [];
        if (h.length > 0)
            root._serial++;
        return h;
    }

    // The manager opened: every toast is filed, nothing is held back.
    function clear() {
        const was = root._shown.length + root._held.length;
        root._shown = [];
        root._t = ({});
        root._floods = ({});
        root._held = [];
        root._more = 0;
        root._setReplies({});
        timer.stop();
        if (was > 0)
            root._serial++;
    }

    // ---- Private -------------------------------------------------------------
    readonly property var _toastCfg: root.config && root.config.toasts ? root.config.toasts : ({})
    property var _shown: []
    property var _held: []
    property var _t: ({})          // uid -> { total, sticky, left, mark, appKey }
    property var _floods: ({})
    property var _hist: []         // [{ appKey, t }] shown toasts, for floods
    property int _more: 0
    property int _serial: 0
    property bool _hover: false
    property bool _replying: false
    property var _replyUids: ({})          // uid -> true: the toasts with a reply field open
    function _setReplies(m) {
        root._replyUids = m;
        root._replying = Object.keys(m).length > 0;
    }
    property real _lastExpiry: 0
    readonly property bool _asleep: !!root.sleepWatcher && root.sleepWatcher.sleeping === true

    function _floodWindow() {
        return root._toastCfg.floodWindowMs > 0 ? root._toastCfg.floodWindowMs : 10000;
    }

    function _entry(totalMs, now, appKey, fixed) {
        const sticky = !(totalMs > 0);
        return { total: sticky ? -1 : totalMs, sticky: sticky, left: sticky ? -1 : totalMs, mark: now,
                 appKey: String(appKey || ""), fixed: !!fixed };
    }

    function _leftOf(e, now) {
        if (e.sticky)
            return -1;
        return root.frozen ? e.left : e.left - (now - e.mark);
    }

    function _newestOf(appKey) {
        for (let i = 0; i < root._shown.length; i++) {
            const e = root._t[root._shown[i]];
            if (e && e.appKey === appKey)
                return root._shown[i];
        }
        return "";
    }

    function _drop(uid) {
        if (root._replyUids[uid]) {
            const m = Object.assign({}, root._replyUids);
            delete m[uid];
            root._setReplies(m);
        }
        if (root._t[uid])
            delete root._t[uid];
        if (root._floods[uid] !== undefined) {
            const f = Object.assign({}, root._floods);
            delete f[uid];
            root._floods = f;
        }
        const before = root._shown.length;
        root._shown = root._shown.filter(u => u !== uid);
        if (before > 0 && root._shown.length === 0)
            root._more = 0;
    }

    function _expire(uid) {
        root._lastExpiry = Date.now();
        root._drop(uid);
        root._serial++;
        root.expired(uid);
    }

    // The deadline moves LATER, to `newLeft` from now (e.left is from now
    // too): the span grows by the same ratio, so left / total -- the drawn
    // fraction -- stays where it was. Only for a live entry (left > 0).
    function _stretch(e, newLeft) {
        if (!(newLeft > e.left) || !(e.left > 0))
            return;
        e.total = e.total * newLeft / e.left;
        e.left = newLeft;
    }

    // Push the running deadlines apart, the last expiry included, and keep it.
    // What is already due is not pushed: its drain is at nothing, and a push
    // could only draw it refilling; it goes on the next tick.
    function _restagger(now) {
        if (root.frozen)
            return;
        const live = [];
        const keys = Object.keys(root._t);
        for (let i = 0; i < keys.length; i++) {
            const e = root._t[keys[i]];
            if (!e.sticky && e.mark + e.left > now)
                live.push({ uid: keys[i], at: e.mark + e.left });
        }
        if (live.length === 0)
            return;
        live.sort((a, b) => a.at - b.at);
        const anchor = root._lastExpiry > 0 ? [root._lastExpiry] : [];
        const pushed = Policy.staggerDeadlines(anchor.concat(live.map(x => x.at)), root.staggerMs).slice(anchor.length);
        for (let i = 0; i < live.length; i++) {
            const e = root._t[live[i].uid];
            e.left = live[i].at - now;
            e.mark = now;
            root._stretch(e, pushed[i] - now);
        }
    }

    function _arm() {
        timer.stop();
        if (root.frozen)
            return;
        const now = Date.now();
        let next = -1;
        const keys = Object.keys(root._t);
        for (let i = 0; i < keys.length; i++) {
            const e = root._t[keys[i]];
            if (e.sticky)
                continue;
            const at = e.mark + e.left;
            if (next < 0 || at < next)
                next = at;
        }
        if (next < 0)
            return;
        timer.interval = Math.max(1, Math.ceil(next - now));
        timer.start();
    }

    onFrozenChanged: {
        const now = Date.now();
        const keys = Object.keys(root._t);
        for (let i = 0; i < keys.length; i++) {
            const e = root._t[keys[i]];
            if (e.sticky)
                continue;
            if (root.frozen) {
                // Stop the clock where it is (the binding already reads
                // frozen, so compute from the mark by hand).
                e.left = e.left - (now - e.mark);
            } else {
                // At least the minimum, drawn from where the drain stood. One
                // that ran out as the clock stopped is due: it goes at once.
                root._stretch(e, root.hoverResumeMinMs);
            }
            e.mark = now;
        }
        root._restagger(now);
        root._serial++;
        root._arm();
    }

    // A resume: the monotonic timer slept through the wall's jump. After a
    // sleep the watcher saw begin, the thaw has already moved every deadline;
    // after one it did not (its start was never delivered), the wall is all
    // there is -- re-arm from it, and let the view re-read.
    Connections {
        target: root.sleepWatcher
        ignoreUnknownSignals: true
        function onResumed() {
            root._serial++;
            root._arm();
        }
    }

    Timer {
        id: timer
        repeat: false
        onTriggered: {
            const now = Date.now();
            const due = [];
            const keys = Object.keys(root._t);
            for (let i = 0; i < keys.length; i++) {
                const e = root._t[keys[i]];
                if (!e.sticky && e.mark + e.left <= now + 2)
                    due.push({ uid: keys[i], at: e.mark + e.left });
            }
            due.sort((a, b) => a.at - b.at);
            if (due.length > 0) {
                root._expire(due[0].uid);
                root._restagger(Date.now());
            }
            root._arm();
        }
    }
}
