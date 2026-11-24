pragma ComponentBehavior: Bound

import QtQuick
import "ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeMock.qml -- the screentime service without a daemon.
//
// The SAME members as ScreentimeService (CONTRACT §9) and nothing a host could
// lean on that the service lacks: status, state, live, serial, refresh,
// loadWeek/week, loadDay/day, loadRange/range, weekStartOf (and the sim levers,
// clockOffsetMs among them, which only a mockup or a probe touches). The mockup, the card
// and the probes take ONE `service`; swapping this for the real one changes
// nothing above it. Pure: no file is read or written, no socket opened.
//
// THE HISTORY. `weeks` weeks (default 8, ending with the current one) of
// synthetic days, deterministic in (`seed`, date): the same date gives the same
// day on every run, whatever the clock. A weekday has a morning and an afternoon
// work session, an evening one about half the time and now and then a short
// pickup at noon; a weekend has leisure sessions, the last often running past
// midnight (which, with a 04:00 day start, still belongs to that day). Inside a
// session the focus walks over ~12 real-looking classes (kitty, zen,
// com.microsoft.VSCode, org.gnome.Nautilus, steam, discord, spotify, obsidian,
// org.telegram.desktop, mpv, libreoffice-writer, ~desktop), with lognormal stays,
// a few stops on the Desktop and short idle holes. A few days hold nothing (no
// file: status "none"). Days before the history, and after today, are none and
// future.
//
// Every day is an `iv` list (sorted, non-overlapping, inside the logical day,
// whole seconds) plus `breaks`; its SUM is ALWAYS derived from that list by
// ScreentimeModel.sumFromDay, so a SUM and its `iv` cannot disagree.
//
// TODAY is partial: the plan for today is cut at `now()`. The interval running
// at that moment becomes the OPEN one (state.app / appSince); when nothing runs
// then and `startActive` is true (the default) the mock opens one on `startApp`
// at once, so a mockup opened at 03:00 is not dead. Today's DAYSUM/DAYFULL carry
// the open interval closed at `now()` (CONTRACT §2), as the daemon's do.
//
// THE CLOCK. `now()` = Date.now() + clockOffsetMs (the mock's own lever; a
// host reads the snapshot's `state.now`). A forward offset that crosses the day
// start rolls the day exactly as the daemon does (the open interval is split,
// the session continues as `cont`, the old day is kept, the caches of both dates
// are dropped and `serial` bumps). An offset into an earlier day re-plans today
// from scratch (the daemon's "wall clock stepped back" is not simulated).
//
// ASYNC. A load answers from a Timer after `latencyMs` (0 = the next tick) and
// bumps `serial`; a getter only reads the cache and never asks; asking twice for
// what is already on its way queues once. `counters` ({asked, answered}, a var
// mutated in place) is the probe's instrument.
//
// LIVE = a session on show, and ONE SNAPSHOT A SESSION (as the service): while
// `live` nothing the card has been answered changes -- a lever or the day roll
// updates the mock's own truth and marks it stale, the published `state` and
// the cached answers stay. `live` turning true, or `refresh()`, publishes the
// truth and answers every cached key again, each in place. Off-session the
// truth is published at once (nobody is looking).
//
// THE RUN TAB's levers (all update `state` per CONTRACT §3):
//   simSwitch(cls[, mon])  a focus change (while away only the focus is noted)
//   simIdle(agoS)          no input for agoS s: the tail of the day is cut back
//                          (min(ago, maxBackdateS), never before activeSince)
//   simActive()            input again: a new session when the pause was at
//                          least sessionBreakMin, or a lock/sleep ended the last
//   simLock() / simUnlock()   simSleep() / simWake()
//   simAbsent(bool)        status "absent", state null (no daemon)
//   setClockOffset(ms)     shift now()
//   invalidate()           drop every cached reply (a host that wants today again)
//   reset()                rebuild from seed/weeks/config (also run by a change
//                          of any of them)
// =============================================================================
QtObject {
    id: root

    // ---- the mock's own knobs ----
    property int seed: 1
    property int weeks: 8
    property int latencyMs: 0
    property int dayStartHour: 4
    property int weekStart: 1
    property int sessionBreakMin: 5
    property int maxBackdateS: 900
    property bool startActive: true
    property string startApp: "kitty"

    // ---- CONTRACT §9, the service's members ----
    readonly property string status: root._status
    readonly property var state: root._state
    readonly property real clockOffsetMs: root._clockOffset
    property bool live: false
    readonly property int serial: root._serial

    // A probe's instrument, mutated in place (a counter that is a property would
    // be a dependency of the bindings it counts).
    readonly property var counters: ({ asked: 0, answered: 0 })

    property string _status: "connecting"
    property var _state: null
    property real _clockOffset: 0
    property int _serial: 0
    property bool _absent: false
    property bool _ready: false
    property bool _refreshing: false

    // The mutable truth: {d (today), R, activeSince, app, mon, appSince,
    // awaySince, sess, last, contFirst, lastFocus, focusSince, arch, gen}.
    property var _m: null
    property var _weekCache: ({})
    property var _dayCache: ({})
    property var _rangeCache: ({})
    property var _queue: []

    // ------------------------------------------------------------------ clock
    function now(): real {
        return Date.now() + root._clockOffset;
    }

    function _cfg(): var {
        return Model.cfgOf({ dayStartHour: root.dayStartHour, weekStart: root.weekStart }, Model.localTz);
    }

    function weekStartOf(date: string): string {
        return Model.weekStartOf(date, root.weekStart);
    }

    // ---------------------------------------------------------------- getters
    // Getters read the cache and nothing else. `serial` is read so a binding that
    // calls one re-runs when anything lands.
    function week(from: string): var {
        void root._serial;
        return root._weekCache[from] || null;
    }

    function day(date: string): var {
        void root._serial;
        return root._dayCache[date] || null;
    }

    function range(a: string, b: string): var {
        void root._serial;
        return root._rangeCache[a + "|" + b] || null;
    }

    // ------------------------------------------------------------------ loads
    function loadWeek(from: string): void {
        root._ask("w", from, from);
    }

    function loadDay(date: string): void {
        root._ask("d", date, date);
    }

    function loadRange(a: string, b: string): void {
        root._ask("r", a + "|" + b, [a, b]);
    }

    function _ask(kind: string, key: string, arg: var): void {
        root.counters.asked++;
        for (let i = 0; i < root._queue.length; i++)
            if (root._queue[i].kind === kind && root._queue[i].key === key)
                return;
        root._queue.push({ kind: kind, key: key, arg: arg, at: Date.now() + Math.max(0, root.latencyMs) });
        answerTimer.interval = Math.max(0, root.latencyMs);
        if (!answerTimer.running)
            answerTimer.start();
    }

    function _pump(): void {
        const t = Date.now(), keep = [];
        let landed = false;
        for (let i = 0; i < root._queue.length; i++) {
            const q = root._queue[i];
            if (q.at > t) {
                keep.push(q);
                continue;
            }
            if (root._absent || root._m === null)
                continue;                       // no daemon: the question is never answered
            landed = root._answer(q) || landed;
        }
        root._queue = keep;
        if (keep.length > 0) {
            answerTimer.interval = Math.max(0, keep[0].at - t);
            answerTimer.start();
        }
        if (landed)
            root._serial++;
    }

    function _answer(q: var): bool {
        root._checkRoll();
        if (q.kind === "w") {
            if (root.weekStartOf(q.key) !== q.key)
                return false;                   // notweekstart
            root._weekCache[q.key] = { from: q.key, days: Model.weekDates(q.key).map(d => root._daySum(d, root._record(d))) };
        } else if (q.kind === "d") {
            if (!/^\d{4}-\d{2}-\d{2}$/.test(q.key))
                return false;                   // baddate
            root._dayCache[q.key] = root._dayFull(q.key);
        } else {
            const a = q.arg[0], b = q.arg[1];
            if (!/^\d{4}-\d{2}-\d{2}$/.test(a) || !/^\d{4}-\d{2}-\d{2}$/.test(b) || a > b)
                return false;
            const out = {};
            let d = a, n = 0;
            while (d <= b && n < 400) {
                const rec = root._record(d);
                if (rec && rec.sum.total > 0)
                    out[d] = rec.sum.total;
                d = Model.addDays(d, 1);
                n++;
            }
            if (d <= b)
                return false;                   // more than 400 days
            root._rangeCache[q.key] = out;
        }
        root.counters.answered++;
        return true;
    }

    // The session's snapshot (CONTRACT §9): the truth published and every cached
    // key answered again, each answer replacing the old one in place.
    function refresh(): void {
        if (root._absent || root._m === null)
            return;
        root._checkRoll();
        root._refreshing = true;
        root._publish();
        root._refreshing = false;
        for (const k of Object.keys(root._weekCache))
            root._ask("w", k, k);
        for (const k of Object.keys(root._dayCache))
            root._ask("d", k, k);
        for (const k of Object.keys(root._rangeCache))
            root._ask("r", k, k.split("|"));
    }

    // Drop every cached reply and bump serial: a host that wants today again.
    function invalidate(): void {
        root._weekCache = ({});
        root._dayCache = ({});
        root._rangeCache = ({});
        root._serial++;
    }

    // ------------------------------------------------------------- the history
    function _rng(text: string): var {
        let h = 2166136261 >>> 0;
        for (let i = 0; i < text.length; i++) {
            h ^= text.charCodeAt(i);
            h = Math.imul(h, 16777619) >>> 0;
        }
        let a = h;
        return function () {
            a = (a + 0x6D2B79F5) >>> 0;
            let t = a;
            t = Math.imul(t ^ (t >>> 15), t | 1);
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }

    readonly property var _work: [["kitty", 28], ["com.microsoft.VSCode", 24], ["zen", 26], ["obsidian", 6],
                                  ["org.gnome.Nautilus", 4], ["org.telegram.desktop", 4], ["discord", 4], ["libreoffice-writer", 4]]
    readonly property var _play: [["zen", 25], ["steam", 24], ["discord", 14], ["spotify", 8], ["mpv", 12],
                                  ["kitty", 8], ["org.telegram.desktop", 5], ["org.gnome.Nautilus", 4]]
    readonly property var _monitors: ["eDP-1", "HDMI-A-1"]
    // What a terminal stay has in front (the daemon reads it from /proc): drawn from a generator
    // of its own, so the rest of the seeded week does not depend on it.
    readonly property var _terminals: ["kitty"]
    readonly property var _progs: [["claude", 45], ["bash", 20], ["nvim", 14], ["yazi", 8], ["btop", 4], ["yay", 4], ["git", 5]]

    function _pick(table: var, r: var, avoid: string): string {
        let name = "";
        for (let tries = 0; tries < 4; tries++) {
            let sum = 0;
            for (let i = 0; i < table.length; i++)
                sum += table[i][1];
            let x = r() * sum;
            name = table[table.length - 1][0];
            for (let k = 0; k < table.length; k++) {
                x -= table[k][1];
                if (x < 0) {
                    name = table[k][0];
                    break;
                }
            }
            if (name !== avoid)
                break;
        }
        return name;
    }

    // One logical day's plan, or null for a day with no file. `force` (today)
    // never rolls the "no data" die.
    function _plan(date: string, force: bool): var {
        const cfg = root._cfg(), b = Model.dayBounds(date, cfg), r = root._rng(root.seed + "|" + date);
        const weekday = Model.dow(date) <= 5;
        const none = r() < (weekday ? 0.04 : 0.12);
        const jit = (c, w) => c + (r() * 2 - 1) * w;
        const wins = [];
        if (weekday) {
            wins.push([jit(8.5, 0.5), jit(12.3, 0.3), root._work]);
            if (r() < 0.3)
                wins.push([jit(12.85, 0.05), jit(13.05, 0.05), root._play]);
            wins.push([jit(13.4, 0.4), jit(17.7, 1.0), root._work]);
            if (r() < 0.55)
                wins.push([jit(20.0, 0.6), jit(22.5, 1.0), root._play]);
        } else {
            wins.push([jit(10.0, 1.0), jit(12.5, 0.6), root._play]);
            if (r() < 0.9)
                wins.push([jit(14.5, 1.0), jit(18.0, 1.0), root._play]);
            if (r() < 0.7)
                wins.push([jit(21.0, 1.0), jit(24.6, 0.7), root._play]);
        }
        if (none && !force)
            return null;
        const apps = [], iv = [], breaks = [];
        const ai = name => {
            let i = apps.indexOf(name);
            if (i < 0) {
                apps.push(name);
                i = apps.length - 1;
            }
            return i;
        };
        const gauss = () => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());
        let prevEnd = b.start;
        for (let w = 0; w < wins.length; w++) {
            const hours = wins[w][1] - wins[w][0];
            if (hours < 0.1)
                continue;
            const off = (((wins[w][0] - root.dayStartHour) % 24) + 24) % 24;
            const a0 = b.start + Math.round(off * 3600) * 1000;
            const end = Math.min(b.end - 60000, a0 + Math.round(hours * 3600) * 1000);
            let t = Math.max(prevEnd + 600000, a0);
            if (end - t < 300000)
                continue;
            const baseMon = r() < (weekday ? 0.65 : 0.1) ? 1 : 0;
            let cur = "", wrote = false;
            while (t + 15000 < end) {
                let name, dur;
                if (cur !== "" && cur !== "~desktop" && r() < 0.09) {
                    name = "~desktop";
                    dur = Math.round(6 + r() * 34);
                } else {
                    name = root._pick(wins[w][2], r, cur);
                    let x = Math.exp(Math.log(140) + gauss());
                    if (r() < 0.07)
                        x = 900 + r() * 2700;
                    dur = Math.min(3600, Math.max(12, Math.round(x)));
                }
                const e = Math.min(end, t + dur * 1000);
                iv.push([t, e, ai(name), r() < 0.12 ? 1 - baseMon : baseMon]);
                wrote = true;
                t = e;
                cur = name;
                if (r() < 0.12 && t + 200000 < end)
                    t += Math.round(20 + r() * 130) * 1000;
            }
            if (wrote) {
                const last = iv[iv.length - 1][1], p = r();
                breaks.push([last, p < 0.5 ? "lock" : (p < 0.65 ? "sleep" : "idle")]);
                prevEnd = last;
            }
        }
        const progs = [], pr = root._rng(root.seed + "|" + date + "|prog");
        for (let i = 0; i < iv.length; i++) {
            if (root._terminals.indexOf(apps[iv[i][2]]) < 0)
                continue;
            const name = root._pick(root._progs, pr, "");
            let k = progs.indexOf(name);
            if (k < 0) {
                progs.push(name);
                k = progs.length - 1;
            }
            iv[i].push(k);
        }
        return { v: 1, date: date, start: b.start, end: b.end, apps: apps, mons: root._monitors.slice(), progs: progs, iv: iv, breaks: breaks };
    }

    function _histStart(): string {
        return Model.addDays(root.weekStartOf(root._m.d.date), -7 * (Math.max(1, root.weeks) - 1));
    }

    // A past day's {day, sum, cont} (generated once, kept), or null: no file.
    function _record(date: string): var {
        const m = root._m;
        if (date === m.d.date) {
            const day = root._todayDay();
            return { day: day, sum: Model.sumFromDay(day, root._cfg(), m.contFirst), cont: m.contFirst };
        }
        if (date > m.d.date || date < root._histStart())
            return null;
        if (m.arch[date])
            return m.arch[date];
        if (m.gen[date] === undefined) {
            const day = root._plan(date, false);
            m.gen[date] = day ? { day: day, sum: Model.sumFromDay(day, root._cfg(), false), cont: false } : null;
        }
        return m.gen[date];
    }

    // Today's file as the daemon answers it: the closed intervals, plus the open
    // one closed at now() (and never past the day's end).
    function _todayDay(): var {
        const m = root._m, d = m.d, iv = d.iv.slice();
        if (m.R.length === 0 && m.appSince !== null) {
            const to = Math.min(root.now(), d.end);
            if (to > m.appSince)
                iv.push(root._row(d, m.appSince, to));
        }
        return { v: 1, date: d.date, start: d.start, end: d.end, apps: d.apps.slice(), mons: d.mons.slice(), progs: (d.progs || []).slice(),
                 iv: iv, breaks: d.breaks.slice() };
    }

    // Index of `name` in `list`, appended when absent (a copy's own list).
    // The live focus's program: a terminal shows claude in front (the daemon reads it from /proc).
    function _liveProg(app: var): var {
        return app !== null && root._terminals.indexOf(app) >= 0 ? "claude" : null;
    }
    // An interval of the live focus in day `d`, with its program when it has one.
    function _row(d: var, s: real, e: real): var {
        const m = root._m, row = [s, e, root._idx(d.apps, m.app), root._idx(d.mons, m.mon)];
        const p = root._liveProg(m.app);
        if (p !== null)
            row.push(root._idx(d.progs || (d.progs = []), p));
        return row;
    }
    function _idx(list: var, name: string): int {
        let i = list.indexOf(name);
        if (i < 0) {
            list.push(name);
            i = list.length - 1;
        }
        return i;
    }

    // `rec` is a record the caller already took: today's moves with the clock, so
    // a DAYFULL asks once and builds both halves from it.
    function _daySum(date: string, rec: var): var {
        const cfg = root._cfg(), b = Model.dayBounds(date, cfg);
        if (date > root._m.d.date)
            return { date: date, status: "future", start: b.start, end: b.end, sum: null };
        if (!rec)
            return { date: date, status: "none", start: b.start, end: b.end, sum: null };
        return { date: date, status: "ok", start: b.start, end: b.end, sum: rec.sum };
    }

    function _dayFull(date: string): var {
        const rec = root._record(date), out = root._daySum(date, rec);
        out.apps = rec ? rec.day.apps.slice() : [];
        out.mons = rec ? rec.day.mons.slice() : [];
        // As the daemon answers: `progs` only on a day that has a program.
        if (rec && rec.day.progs && rec.day.progs.length > 0)
            out.progs = rec.day.progs.slice();
        out.iv = rec ? rec.day.iv.map(x => x.slice()) : [];
        out.breaks = rec ? rec.day.breaks.map(x => x.slice()) : [];
        if (date === root._m.d.date && root._m.R.length === 0)
            out.open = true;
        return out;
    }

    // ------------------------------------------------------------- the machine
    function _sessMs(): real {
        const m = root._m;
        if (!m.sess)
            return 0;
        let ms = m.sess.carry;
        for (let i = 0; i < m.d.iv.length; i++)
            if (m.d.iv[i][0] >= m.sess.start)
                ms += m.d.iv[i][1] - m.d.iv[i][0];
        return ms;
    }

    // Close the open interval at t (nothing when it would be empty) and leave
    // the user without one.
    function _closeAt(t: real): void {
        const m = root._m;
        if (m.R.length === 0 && m.app !== null && m.appSince !== null && t > m.appSince)
            m.d.iv.push(root._row(m.d, m.appSince, t));
        m.appSince = null;
    }

    function _endSession(at: real, why: string): void {
        const m = root._m;
        if (!m.sess)
            return;
        m.last = { start: m.sess.start, end: at, active: Math.floor(root._sessMs() / 1000), why: why };
        m.sess = null;
    }

    function _becameActive(t: real): void {
        const m = root._m;
        m.activeSince = t;
        m.appSince = t;
        if (m.sess !== null && m.awaySince !== null && t - m.awaySince >= root.sessionBreakMin * 60000) {
            m.d.breaks.push([Math.max(m.d.start, m.awaySince), "idle"]);
            root._endSession(m.awaySince, "idle");
        }
        if (m.sess === null)
            m.sess = { start: t, carry: 0 };
        m.awaySince = null;
    }

    function _add(reason: string, t: real): bool {
        const m = root._m;
        if (m.R.indexOf(reason) >= 0)
            return false;
        if (m.R.length === 0) {
            root._closeAt(t);
            m.awaySince = t;
        }
        m.R.push(reason);
        return true;
    }

    function _remove(reason: string, t: real): void {
        const m = root._m, i = m.R.indexOf(reason);
        if (i < 0)
            return;
        m.R.splice(i, 1);
        if (m.R.length === 0)
            root._becameActive(t);
    }

    function _prep(): bool {
        if (root._m === null || root._absent)
            return false;
        root._checkRoll();
        return true;
    }

    function simSwitch(cls: string, mon: string): void {
        if (!root._prep())
            return;
        const m = root._m, t = root.now(), to = mon ? mon : m.mon;
        if (cls === m.app && to === m.mon)
            return;
        if (m.R.length === 0) {
            root._closeAt(t);
            m.appSince = t;
        }
        m.app = cls;
        if (to !== m.mon)
            m.lastFocus[m.mon] = t;
        m.mon = to;
        m.focusSince = t;
        root._publish();
    }

    function simIdle(agoS: real): void {
        if (!root._prep())
            return;
        const m = root._m, t = root.now();
        if (m.R.indexOf("idle") >= 0)
            return;
        if (m.R.length === 0) {
            const ts = Math.max(t - Math.min(agoS, root.maxBackdateS) * 1000, m.activeSince);
            // The tail of the RAM: whatever ends after t* is cut there or dropped.
            const iv = m.d.iv;
            while (iv.length > 0 && iv[iv.length - 1][1] > ts) {
                const last = iv[iv.length - 1];
                if (last[0] >= ts) {
                    iv.pop();
                } else {
                    last[1] = ts;
                    break;
                }
            }
            root._closeAt(ts);
            m.awaySince = ts;
        }
        m.R.push("idle");
        root._publish();
    }

    function simActive(): void {
        if (!root._prep())
            return;
        root._remove("idle", root.now());
        root._publish();
    }

    function _away(reason: string, why: string): void {
        if (!root._prep())
            return;
        const m = root._m;
        root._add(reason, root.now());
        if (m.sess !== null && m.awaySince !== null) {
            m.d.breaks.push([Math.max(m.d.start, m.awaySince), why]);
            root._endSession(m.awaySince, why);
        }
        root._publish();
    }

    function simLock(): void {
        root._away("locked", "lock");
    }

    function simSleep(): void {
        root._away("asleep", "sleep");
    }

    function simUnlock(): void {
        if (!root._prep())
            return;
        root._remove("locked", root.now());
        root._publish();
    }

    function simWake(): void {
        if (!root._prep())
            return;
        root._remove("asleep", root.now());
        root._publish();
    }

    function simAbsent(on: bool): void {
        if (root._absent === on)
            return;
        root._absent = on;
        if (on) {
            root._status = "absent";
            root._state = null;
        } else {
            root._status = "ok";
            if (root._m !== null)
                root._publish();
        }
        root._armRoll();
    }

    function setClockOffset(ms: real): void {
        root._clockOffset = ms;
        if (root._m === null || root._absent)
            return;
        const m = root._m, t = root.now();
        if (Model.dayOf(t, root._cfg()) < m.d.date) {
            root._initToday();                  // an earlier day: re-plan today
            root.invalidate();
        } else {
            if (m.appSince !== null && m.appSince > t)
                m.appSince = t;
            root._checkRoll();
        }
        root._publish();
    }

    // The day rolled under the clock: split the open interval at each boundary,
    // keep the finished day, start the next (a running session continues).
    function _checkRoll(): void {
        const m = root._m, cfg = root._cfg();
        if (m === null)
            return;
        const target = Model.dayOf(root.now(), cfg);
        let rolled = false, guard = 0;
        while (m.d.date < target && guard++ < 800) {
            const old = m.d, next = Model.addDays(old.date, 1);
            if (m.R.length === 0) {
                root._closeAt(old.end);
                m.appSince = old.end;
            }
            if (m.sess)
                m.sess.carry = root._sessMs();
            m.arch[old.date] = { day: old, sum: Model.sumFromDay(old, cfg, m.contFirst), cont: m.contFirst };
            const b = Model.dayBounds(next, cfg);
            m.d = { v: 1, date: next, start: b.start, end: b.end, apps: old.apps.slice(), mons: old.mons.slice(), progs: [], iv: [], breaks: [] };
            m.contFirst = m.sess !== null;
            // Off-session the rolled dates are asked again; in a session the answers stay
            // until the next snapshot.
            if (!root.live) {
                for (const d of [old.date, next]) {
                    delete root._dayCache[d];
                    delete root._weekCache[Model.weekStartOf(d, root.weekStart)];
                }
            }
            rolled = true;
        }
        if (rolled) {
            if (!root.live) {
                root._rangeCache = ({});
                root._serial++;
            }
            root._publish();
        }
        root._armRoll();
    }
    // One shot at the next day boundary, re-armed by every roll check (a
    // clock offset, a reset). A repeating timer would wake the mockup every
    // second -- offscreen every Timer start renders a frame (CLAUDE.md) -- and
    // the card's idle probe measures exactly that.
    function _armRoll(): void {
        const m = root._m;
        _rollWatch.stop();
        if (m === null || root._absent)
            return;
        // Qt timers stop in a suspend while the wall jumps: a 10 min cap
        // keeps a resumed mock from sitting on yesterday for hours.
        _rollWatch.interval = Math.max(50, Math.min(600000, m.d.end - root.now() + 5));
        _rollWatch.start();
    }

    // ----------------------------------------------------------------- publish
    function _publish(): void {
        const m = root._m;
        if (m === null || root._absent || root._status === "connecting")
            return;
        // In a session only a snapshot publishes (the first state always does: the connect).
        if (root.live && root._state !== null && !root._refreshing)
            return;
        const cfg = root._cfg(), t = root.now();
        const closed = Model.sumFromDay(m.d, cfg, m.contFirst);
        const active = m.R.length === 0;
        root._state = {
            now: t, day: m.d.date, dayStart: m.d.start, dayEnd: m.d.end,
            active: active, away: m.R.slice(), awaySince: m.awaySince,
            app: m.app, mon: m.mon, appSince: active ? m.appSince : null, prog: root._liveProg(m.app),
            // The mock's terminal never changes program live, so its run begins with the interval.
            stretchSince: active ? m.appSince : null,
            session: m.sess ? { start: m.sess.start, active: Math.floor(root._sessMs() / 1000) } : null,
            lastSession: m.last,
            today: { total: closed.total, apps: closed.apps },
            focusedMon: m.mon, focusedMonSince: m.focusSince, lastFocus: Object.assign({}, m.lastFocus),
            present: root._monitors.slice(), dropped: 0,
            config: { dayStartHour: root.dayStartHour, weekStart: root.weekStart, sessionBreakMin: root.sessionBreakMin }
        };
    }

    onLiveChanged: {
        if (root.live)
            root.refresh();
    }

    // ------------------------------------------------------------------ set up
    // Today: the plan cut at now(); the interval running then is the open one.
    function _initToday(): void {
        const cfg = root._cfg(), t = root.now(), date = Model.dayOf(t, cfg);
        const plan = root._plan(date, true);
        const m = root._m;
        const closed = [], breaks = [];
        let open = null;
        for (let i = 0; i < plan.iv.length; i++) {
            const x = plan.iv[i];
            if (x[1] <= t)
                closed.push(x);
            else if (x[0] < t)
                open = x;
        }
        for (let k = 0; k < plan.breaks.length; k++)
            if (plan.breaks[k][0] <= t)
                breaks.push(plan.breaks[k]);
        plan.iv = closed;
        plan.breaks = breaks;
        m.d = plan;
        m.contFirst = false;
        m.R = [];
        m.sess = null;
        m.last = null;
        m.awaySince = null;
        m.appSince = null;
        m.focusSince = t;
        m.lastFocus = ({});
        // Sessions as the file implies them, the open interval counted.
        const probe = { iv: closed.concat(open ? [open] : []), breaks: breaks };
        const sessions = Model.sessionsOf(probe, false);
        const lastBreak = (s) => {
            for (let k = breaks.length - 1; k >= 0; k--)
                if (breaks[k][0] >= s[1])
                    return breaks[k][1];
            return "";
        };
        if (sessions.length > 0) {
            const ls = sessions[sessions.length - 1];
            const ended = !open && lastBreak(ls) !== "";
            if (ended)
                m.last = { start: ls[0], end: ls[1], active: ls[2], why: lastBreak(ls) };
            else
                m.sess = { start: ls[0], carry: 0 };
            if (sessions.length > 1 && m.last === null) {
                const ps = sessions[sessions.length - 2];
                m.last = { start: ps[0], end: ps[1], active: ps[2], why: lastBreak(ps) || "idle" };
            }
        }
        if (open) {
            m.app = plan.apps[open[2]];
            m.mon = plan.mons[open[3]];
            m.appSince = open[0];
            let from = closed.length;
            let start = open[0];
            while (from > 0 && closed[from - 1][1] === start) {
                start = closed[from - 1][0];
                from--;
            }
            m.activeSince = start;
            m.focusSince = open[0];
        } else {
            const lastIv = closed.length > 0 ? closed[closed.length - 1] : null;
            m.app = root.startApp;
            m.mon = root._monitors[0];
            m.R = ["idle"];
            m.awaySince = lastIv ? lastIv[1] : null;
            m.activeSince = lastIv ? lastIv[1] : t;
            if (root.startActive) {
                m.R = [];
                root._becameActive(t);
            }
        }
    }

    function reset(): void {
        root._m = ({ d: null, R: [], activeSince: 0, app: null, mon: null, appSince: null, awaySince: null, sess: null, last: null,
                     contFirst: false, lastFocus: ({}), focusSince: 0, arch: ({}), gen: ({}) });
        root._weekCache = ({});
        root._dayCache = ({});
        root._rangeCache = ({});
        root._initToday();
        root._serial++;
        if (root._status !== "connecting")
            root._publish();
    }

    // A knob changed after creation: rebuild once, on the next tick (a host sets
    // several, or sets them in createObject before the first reset).
    function _reconfigure(): void {
        if (root._ready)
            Qt.callLater(root.reset);
    }

    onSeedChanged: root._reconfigure()
    onWeeksChanged: root._reconfigure()
    onDayStartHourChanged: root._reconfigure()
    onWeekStartChanged: root._reconfigure()
    onStartActiveChanged: root._reconfigure()

    property Timer _answerT: Timer {
        id: answerTimer
        repeat: false
        onTriggered: root._pump()
    }

    // The connection: "connecting" for latencyMs, then "ok" (unless no daemon).
    property Timer _connect: Timer {
        interval: Math.max(0, root.latencyMs)
        running: true
        repeat: false
        onTriggered: {
            if (!root._absent)
                root._status = "ok";
            root._publish();
        }
    }

    // The day roll's own watch (the daemon uses a timerfd at the boundary):
    // armed by _armRoll() for the next boundary, never repeating.
    property Timer _rollWatch: Timer {
        repeat: false
        onTriggered: root._checkRoll()
    }

    Component.onCompleted: {
        root._ready = true;
        root.reset();
    }
}
