.pragma library

// =============================================================================
// ScreentimeModel.js -- every figure the screentime UI draws, pure.
//
// One file, no Qt, loadable under node. It holds
// what the daemon's day files and replies (CONTRACT.md §2, §5, §6) need turned
// into facts for the cards: numbers and class strings, NEVER a colour (a row
// carries facts, the delegate resolves the hue).
//
// THE CALENDAR. A date is a logical day "YYYY-MM-DD": it starts at `dayStartHour`
// local. Every function that needs the wall clock takes `cfg` =
//   { dayStartHour: 4, weekStart: 1, tz: function (ms) -> offset of local time
//     from UTC in ms }
// `tz` is injected so node tests are deterministic (a DST week); it defaults to
// the machine's own zone (`localTz`). `cfgOf(stateConfig, tz)` builds one from a
// STATE's `config` object. Dates are pure calendar strings: adding days or
// finding a weekday never touches a time zone.
//
//   fmt(s)                          DUR text (CONTRACT §8)
//   localTz(ms)                     the machine's UTC offset at ms
//   cfgOf(config, tz)               -> cfg
//   addDays(date, n)                -> date
//   dow(date)                       -> 1 (Mon) .. 7 (Sun)
//   dayLabel(date)                  -> "Mon" .. "Sun"
//   weekStartOf(date, weekStart)    -> the date a week containing `date` starts on
//   weekDates(from)                 -> the 7 dates of the week
//   dayBounds(date, cfg)            -> {start, end} ms of the logical day
//   dayOf(ms, cfg)                  -> the logical day a time falls in
//   isFuture(date, nowMs, cfg)      -> a date after today's
//   hourIndex(ms, cfg)              -> hour bucket 0..23 (0 = the day's first hour)
//   splitHours(s, e, cfg)           -> [[bucket, ms], ...] an interval cut at wall hours
//   emptySum(), sumFromDay(...)     SUM (§5) -- the daemon's `rebuild`, in JS
//   sessionsOf(day, cont)           -> [[s, e, activeSeconds, cont]]
//   liveSum(sum, state, nowMs, tz)  today's SUM with the open interval merged in
//   liveFigures(state, nowMs)       -> {today, session, liveS} for the header
//   bars / heat / span / stats / rows / dayColumns   the faces (below)
//
// THE LIVE MERGE counts what the SUM does not yet hold. A closed-only SUM ends
// at or before `state.appSince`; a SUM the daemon built "as of now" (§2: today's
// entry includes the open interval) ends at its query time, which is later --
// so the merge starts at max(appSince, sum.last) and never counts a second
// twice. A focus change after the query loses the sliver between; the host
// re-asks on a focus push.
//
// Durations are whole seconds: every interval rounds DOWN to a second, and a
// split across hour buckets distributes those seconds so the buckets add up to
// the interval's own.
// =============================================================================

var HOUR_MS = 3600000;
var DAY_MS = 86400000;
var DESKTOP = "~desktop";
// A terminal program that is a shell at its prompt: recorded, never listed (fg.rs SHELLS).
var SHELLS = ["bash", "zsh", "fish", "sh", "dash", "nu"];
// A list row, and a program beside it, needs this many seconds (a "<1m" row is not shown).
var MIN_ROW_S = 60;
// How many of a terminal's programs its row names.
var ROW_PROGS = 3;
// A stay on an app shorter than this is not a switch (day.rs MIN_STAY_MS).
var MIN_STAY_MS = 2000;
var DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

// ----------------------------------------------------------------- DUR (§8)
function fmt(s) {
    var n = Math.floor(Number(s));
    if (!isFinite(n) || n <= 0)
        return "0m";
    if (n < 60)
        return "<1m";
    if (n < 3600)
        return Math.floor(n / 60) + "m";
    return Math.floor(n / 3600) + "h " + Math.floor((n % 3600) / 60) + "m";
}

// ----------------------------------------------------------------- calendar
function localTz(ms) {
    return -new Date(ms).getTimezoneOffset() * 60000;
}

function cfgOf(config, tz) {
    var c = config || {};
    return {
        dayStartHour: c.dayStartHour === undefined || c.dayStartHour === null ? 4 : Number(c.dayStartHour),
        weekStart: c.weekStart === undefined || c.weekStart === null ? 1 : Number(c.weekStart),
        tz: tz || localTz
    };
}

function _tz(cfg) {
    return cfg && cfg.tz ? cfg.tz : localTz;
}

function _mod(a, m) {
    return ((a % m) + m) % m;
}

function _p2(n) {
    return (n < 10 ? "0" : "") + n;
}

function _utc(date) {                   // "YYYY-MM-DD" -> ms at UTC midnight
    return Date.UTC(Number(date.substring(0, 4)), Number(date.substring(5, 7)) - 1, Number(date.substring(8, 10)));
}

function _dateOfUtc(ms) {
    var d = new Date(ms);
    return d.getUTCFullYear() + "-" + _p2(d.getUTCMonth() + 1) + "-" + _p2(d.getUTCDate());
}

function addDays(date, n) {
    return _dateOfUtc(_utc(date) + n * DAY_MS);
}

function dow(date) {                    // 1 = Monday .. 7 = Sunday
    var d = new Date(_utc(date)).getUTCDay();
    return d === 0 ? 7 : d;
}

function dayLabel(date) {
    return DAY_NAMES[dow(date) - 1];
}

function weekStartOf(date, weekStart) {
    return addDays(date, -_mod(dow(date) - Number(weekStart || 1), 7));
}

function weekDates(from) {
    var out = [];
    for (var i = 0; i < 7; i++)
        out.push(addDays(from, i));
    return out;
}

// The instant whose local wall time is `wall` (a wall time written as if UTC), the daemon's rule (cal.rs): the offsets a
// day before and a day after are the only ones that can apply; a wall time that one of them reproduces is that instant, the
// EARLIER if both do (the first pass of a repeated hour); one the spring change skips moves forward (02:30 -> 03:30).
// tools/dev/dst_audit_cases.js S4.
function _wallToMs(wall, tz) {
    var before = tz(wall - DAY_MS), after = tz(wall + DAY_MS), best = null;
    var offs = [before, after];
    for (var i = 0; i < offs.length; i++) {
        var t = wall - offs[i];
        if (t + tz(t) === wall && (best === null || t < best))
            best = t;
    }
    return best !== null ? best : wall - before;
}

function dayBounds(date, cfg) {
    var tz = _tz(cfg), h = cfg && cfg.dayStartHour !== undefined ? cfg.dayStartHour : 4;
    return {
        start: _wallToMs(_utc(date) + h * HOUR_MS, tz),
        end: _wallToMs(_utc(addDays(date, 1)) + h * HOUR_MS, tz)
    };
}

function dayOf(ms, cfg) {
    var tz = _tz(cfg), h = cfg && cfg.dayStartHour !== undefined ? cfg.dayStartHour : 4;
    return _dateOfUtc(ms + tz(ms) - h * HOUR_MS);
}

function isFuture(date, nowMs, cfg) {
    return date > dayOf(nowMs, cfg);
}

function hourIndex(ms, cfg) {
    var tz = _tz(cfg), h = cfg && cfg.dayStartHour !== undefined ? cfg.dayStartHour : 4;
    var wallHour = Math.floor(_mod(ms + tz(ms), DAY_MS) / HOUR_MS);
    return _mod(wallHour - h, 24);
}

// [s, e) cut at wall-hour boundaries -> [[bucket, ms], ...]. A DST day's
// repeated hour lands twice on one bucket (the caller adds).
function splitHours(s, e, cfg) {
    var tz = _tz(cfg), out = [], t = s;
    while (t < e) {
        var wall = t + tz(t);
        var next = Math.min(e, t + (HOUR_MS - _mod(wall, HOUR_MS)));
        out.push([hourIndex(t, cfg), next - t]);
        t = next;
    }
    return out;
}

// ---------------------------------------------------------------------- SUM
function _zeros() {
    var z = [];
    for (var i = 0; i < 24; i++)
        z.push(0);
    return z;
}

function emptySum() {
    return { total: 0, apps: {}, hours: _zeros(), appHours: {}, first: null, last: null,
             switches: 0, longest: { app: null, s: 0, at: null }, sessions: [], pickups: 0, mons: {}, sub: {} };
}

// The sessions a day file implies: a break ends the session it falls in. `cont`
// says the day's first session began on an earlier day (a file does not keep
// that; the caller knows it). -> [[s, e, activeSeconds, cont]].
function sessionsOf(day, cont) {
    return _sessions(day, cont).sessions;
}

// {sessions, idx: the session index of every interval}.
function _sessions(day, cont) {
    var iv = day.iv || [], br = (day.breaks || []).map(function (b) { return b[0]; }).sort(function (a, b) { return a - b; });
    var out = [], cur = null, idx = [];
    for (var i = 0; i < iv.length; i++) {
        if (cur) {
            for (var k = 0; k < br.length; k++)
                if (br[k] >= cur[1] && br[k] <= iv[i][0]) {
                    out.push(cur);
                    cur = null;
                    break;
                }
        }
        var secs = Math.floor((iv[i][1] - iv[i][0]) / 1000);
        if (cur) {
            cur[1] = iv[i][1];
            cur[2] += secs;
        } else {
            cur = [iv[i][0], iv[i][1], secs, out.length === 0 && !!cont];
        }
        idx.push(out.length);
    }
    if (cur)
        out.push(cur);
    return { sessions: out, idx: idx };
}

// SUM derived from a day's intervals (CONTRACT §5): what the daemon's `rebuild`
// computes. The mock builds every SUM through this, so a SUM and its `iv` cannot
// disagree. `day` = {apps:[], mons:[], iv:[[s,e,ai,mi]], breaks:[[at,why]]}.
function sumFromDay(day, cfg, cont) {
    var sum = emptySum(), iv = day.iv || [], apps = day.apps || [], mons = day.mons || [], progs = day.progs || [];
    var sp = _sessions(day, cont), sessions = sp.sessions;
    var si = 0, lastApp = null, run = null;
    // A STAY: one app over touching intervals in one session (a monitor or program change does
    // not end it). The longest stretch is the longest stay; a switch is a change of app between
    // stays of MIN_STAY_MS or more -- a shorter one passes through like the Desktop
    // (day.rs compute_sum, the same rule).
    var settle = function (r) {
        if (!r || r.app === DESKTOP)
            return;
        if (r.e - r.s >= MIN_STAY_MS) {
            if (lastApp !== null && lastApp !== r.app)
                sum.switches++;
            lastApp = r.app;
        }
        var rs = Math.floor((r.e - r.s) / 1000);
        if (rs > sum.longest.s)
            sum.longest = { app: r.app, s: rs, at: r.s };
    };
    for (var i = 0; i < iv.length; i++) {
        var s = iv[i][0], e = iv[i][1], app = String(apps[iv[i][2]]), mon = String(mons[iv[i][3]]);
        var secs = Math.floor((e - s) / 1000);
        var extends_ = run !== null && run.app === app && run.e === s && run.si === sp.idx[i];
        if (!extends_) {
            settle(run);
            run = null;
        }
        if (sp.idx[i] !== si) {
            si = sp.idx[i];
            lastApp = null;
        }
        sum.total += secs;
        sum.apps[app] = (sum.apps[app] || 0) + secs;
        sum.mons[mon] = (sum.mons[mon] || 0) + secs;
        if (iv[i].length > 4 && iv[i][4] >= 0 && iv[i][4] < progs.length) {
            var pn = String(progs[iv[i][4]]), sub = sum.sub[app] || (sum.sub[app] = {});
            sub[pn] = (sub[pn] || 0) + secs;
        }
        if (!sum.appHours[app])
            sum.appHours[app] = _zeros();
        var parts = splitHours(s, e, cfg), cum = 0;
        for (var p = 0; p < parts.length; p++) {
            var got = Math.floor((cum + parts[p][1]) / 1000) - Math.floor(cum / 1000);
            cum += parts[p][1];
            sum.hours[parts[p][0]] += got;
            sum.appHours[app][parts[p][0]] += got;
        }
        if (sum.first === null)
            sum.first = s;
        if (extends_)
            run.e = e;
        else
            run = { app: app, s: s, e: e, si: si };
        sum.last = e;
    }
    settle(run);
    sum.sessions = sessions;
    for (var q = 0; q < sessions.length; q++)
        if (!sessions[q][3])
            sum.pickups++;
    return sum;
}

// ---------------------------------------------------------------- live merge
function _copySum(sum) {
    var c = {};
    for (var k in sum)
        c[k] = sum[k];
    c.apps = Object.assign({}, sum.apps);
    c.hours = sum.hours.slice();
    c.appHours = Object.assign({}, sum.appHours);
    c.mons = Object.assign({}, sum.mons);
    c.sub = Object.assign({}, sum.sub || {});
    return c;
}

// Today's SUM with the open interval merged in, as of nowMs. Inputs are never
// mutated; with nothing to merge the SUM itself comes back (the same object, so
// a binding reading it stays quiet).
function liveSum(sum, state, nowMs, tz) {
    if (!sum || !state || !state.active || state.appSince === null || state.appSince === undefined)
        return sum;
    var cfg = cfgOf(state.config, tz);
    var from = Math.max(state.appSince, sum.last === null || sum.last === undefined ? 0 : sum.last,
                        state.dayStart === undefined ? 0 : state.dayStart);
    var to = Math.min(nowMs, state.dayEnd === undefined ? nowMs : state.dayEnd);
    if (to <= from)
        return sum;
    var app = String(state.app), secs = Math.floor((to - from) / 1000);
    var c = _copySum(sum);
    c.total += secs;
    c.apps[app] = (c.apps[app] || 0) + secs;
    if (state.mon !== null && state.mon !== undefined)
        c.mons[state.mon] = (c.mons[state.mon] || 0) + secs;
    var ah = (sum.appHours[app] || _zeros()).slice(), parts = splitHours(from, to, cfg), cum = 0;
    for (var p = 0; p < parts.length; p++) {
        var got = Math.floor((cum + parts[p][1]) / 1000) - Math.floor(cum / 1000);
        cum += parts[p][1];
        c.hours[parts[p][0]] += got;
        ah[parts[p][0]] += got;
    }
    c.appHours[app] = ah;
    if (state.prog !== null && state.prog !== undefined) {
        var sub = Object.assign({}, c.sub[app] || {});
        sub[state.prog] = (sub[state.prog] || 0) + secs;
        c.sub[app] = sub;
    }
    if (c.first === null || c.first === undefined)
        c.first = from;
    c.last = to;
    // The current run began at stretchSince (a program or monitor change does not end it).
    var since = state.stretchSince !== null && state.stretchSince !== undefined ? state.stretchSince : state.appSince;
    var span = Math.floor((to - since) / 1000);
    if (app !== DESKTOP && span > c.longest.s)
        c.longest = { app: app, s: span, at: since };
    return c;
}

// The header's two figures (CONTRACT §6): today.total and session.active plus
// the open interval. `liveS` is that interval's seconds.
function liveFigures(state, nowMs) {
    if (!state)
        return { today: 0, session: 0, liveS: 0 };
    var liveS = state.active && state.appSince !== null && state.appSince !== undefined
        ? Math.max(0, Math.floor((nowMs - state.appSince) / 1000)) : 0;
    return { today: (state.today ? state.today.total : 0) + liveS,
             session: state.session ? state.session.active + liveS : 0, liveS: liveS };
}

// -------------------------------------------------------------------- faces
function _okSum(day) {
    return day && day.status === "ok" && day.sum ? day.sum : null;
}

// Bars face: 7 daily totals, the focused app's own seconds beside them (null
// without a focus), the weekday labels from the week's own dates, and where
// `today` (a date) sits in the week (-1 when it is not in it). `dates`,
// `future` and `ok` are facts for the faint future bars and the ghost.
function bars(week, focusApp, today) {
    var total = [], focus = focusApp ? [] : null, labels = [], dates = [], future = [], ok = [], idx = -1;
    var days = week && week.days ? week.days : [];
    for (var i = 0; i < days.length; i++) {
        var s = _okSum(days[i]);
        total.push(s ? s.total : 0);
        if (focus)
            focus.push(s ? (s.apps[focusApp] || 0) : 0);
        labels.push(dayLabel(days[i].date));
        dates.push(days[i].date);
        future.push(days[i].status === "future");
        ok.push(!!s);
        if (today && days[i].date === today)
            idx = i;
    }
    return { total: total, focus: focus, labels: labels, todayIndex: idx, dates: dates, future: future, ok: ok };
}

// Hours face: 168 fractions, row = day, column = hour from the day's start,
// seconds / 3600 capped at 1 (a DST day's doubled hour can hold 7200).
function heat(week, focusApp) {
    var out = [], days = week && week.days ? week.days : [];
    for (var d = 0; d < 7; d++) {
        var s = d < days.length ? _okSum(days[d]) : null;
        var h = s ? (focusApp ? s.appHours[focusApp] : s.hours) : null;
        for (var k = 0; k < 24; k++)
            out.push(h ? Math.min(1, Math.max(0, (h[k] || 0) / 3600)) : 0);
    }
    return out;
}

// Span face: 7 x {lo, hi}, hours elapsed since the logical day's start at the
// first and the last moment of activity; null for a day without any.
function span(week) {
    var out = [], days = week && week.days ? week.days : [];
    for (var d = 0; d < 7; d++) {
        var day = d < days.length ? days[d] : null, s = _okSum(day);
        if (!s || s.first === null || s.first === undefined || s.last === null || s.last === undefined) {
            out.push(null);
            continue;
        }
        out.push({ lo: (s.first - day.start) / HOUR_MS, hi: (s.last - day.start) / HOUR_MS });
    }
    return out;
}

function _sums(sumOrWeek) {
    if (!sumOrWeek)
        return [];
    if (sumOrWeek.days)
        return sumOrWeek.days.map(_okSum).filter(function (s) { return !!s; });
    return [sumOrWeek];
}

// Stats strip, for one day's SUM or aggregated over a week: switches per hour of
// active time, the longest single stretch on one app, pickups.
function stats(sumOrWeek) {
    var sums = _sums(sumOrWeek), total = 0, sw = 0, pick = 0, best = { app: null, s: 0 };
    for (var i = 0; i < sums.length; i++) {
        total += sums[i].total;
        sw += sums[i].switches;
        pick += sums[i].pickups;
        if (sums[i].longest && sums[i].longest.s > best.s)
            best = { app: sums[i].longest.app, s: sums[i].longest.s };
    }
    return { switchesPerHour: total > 0 ? sw / (total / 3600) : 0, longest: best, pickups: pick };
}

// List rows: [{app, secs, frac, progs}] sorted by seconds (ties by name), frac
// relative to the top row. Desktop is a row like any other (`~desktop`). A row
// under MIN_ROW_S is not listed ("<1m"). `progs` names a terminal's programs, most
// time first: at most ROW_PROGS of them, each over MIN_ROW_S, shells (the prompt) left out.
function rows(sumOrWeek) {
    var acc = {}, sub = {}, sums = _sums(sumOrWeek), i, k, p;
    for (i = 0; i < sums.length; i++) {
        for (k in sums[i].apps)
            acc[k] = (acc[k] || 0) + sums[i].apps[k];
        for (k in (sums[i].sub || {})) {
            var s = sub[k] || (sub[k] = {});
            for (p in sums[i].sub[k])
                s[p] = (s[p] || 0) + sums[i].sub[k][p];
        }
    }
    var list = [];
    for (k in acc)
        if (acc[k] >= MIN_ROW_S)
            list.push({ app: k, secs: acc[k], frac: 0, progs: _rowProgs(sub[k]) });
    list.sort(function (a, b) { return b.secs - a.secs || (a.app < b.app ? -1 : a.app > b.app ? 1 : 0); });
    for (i = 0; i < list.length; i++)
        list[i].frac = list[0].secs > 0 ? list[i].secs / list[0].secs : 0;
    return list;
}

function _rowProgs(sub) {
    var out = [];
    for (var p in (sub || {}))
        if (sub[p] >= MIN_ROW_S && SHELLS.indexOf(p) < 0)
            out.push(p);
    out.sort(function (a, b) { return sub[b] - sub[a] || (a < b ? -1 : 1); });
    return out.slice(0, ROW_PROGS);
}

// The day's columns: one day as equal time slots from its first activity's
// hour to its last's (whole hours of the wall clock), and per slot the share
// of it each app was focused, stacked. The day's `topN` apps keep a layer each
// (most time first: the foot of the stack); the rest share one, app null. The
// slot is the shortest of COLUMN_MIN that fits `maxColumns` columns, so a
// bursty day reads as a clean histogram at any width, and each app's area is
// exactly its time: sum(f) * slotMs = its focused ms. `iv` is
// [s, e, appIndex, monIndex] against `apps`; `tz` the wall clock's offset.
var COLUMN_MIN = [5, 10, 15, 20, 30, 60];
function dayColumns(dayFull, maxColumns, topN, tz) {
    tz = tz || localTz;
    var iv = dayFull && dayFull.iv ? dayFull.iv : [], apps = dayFull && dayFull.apps ? dayFull.apps : [];
    if (!iv.length)
        return { start: null, end: null, slotMs: 0, n: 0, layers: [] };
    var first = iv[0][0], last = iv[0][1], tot = {}, i, k;
    for (i = 0; i < iv.length; i++) {
        first = Math.min(first, iv[i][0]);
        last = Math.max(last, iv[i][1]);
        tot[iv[i][2]] = (tot[iv[i][2]] || 0) + Math.max(0, iv[i][1] - iv[i][0]);
    }
    var start = first - _mod(first + tz(first), HOUR_MS);
    var lastHour = last - _mod(last + tz(last), HOUR_MS);
    var end = lastHour === last ? last : lastHour + HOUR_MS;
    var slotMs = COLUMN_MIN[COLUMN_MIN.length - 1] * 60000;
    for (i = 0; i < COLUMN_MIN.length; i++)
        if (Math.ceil((end - start) / (COLUMN_MIN[i] * 60000)) <= maxColumns) {
            slotMs = COLUMN_MIN[i] * 60000;
            break;
        }
    var n = Math.ceil((end - start) / slotMs);
    var order = Object.keys(tot).map(Number);
    order.sort(function (a, b) { return tot[b] - tot[a] || (String(apps[a]) < String(apps[b]) ? -1 : 1); });
    var layers = [], layerOf = {};
    for (i = 0; i < order.length; i++) {
        var top = i < topN;
        if (top || layers.length === topN)
            layers.push({ app: top ? String(apps[order[i]]) : null, f: new Array(n).fill(0) });
        layerOf[order[i]] = Math.min(i, topN);
    }
    for (i = 0; i < iv.length; i++) {
        var s = iv[i][0], e = iv[i][1], f = layers[layerOf[iv[i][2]]].f;
        for (k = Math.floor((s - start) / slotMs); k < n && start + k * slotMs < e; k++) {
            var a = start + k * slotMs;
            var ov = Math.min(e, a + slotMs) - Math.max(s, a);
            if (ov > 0)
                f[k] += ov / slotMs;
        }
    }
    return { start: start, end: end, slotMs: slotMs, n: n, layers: layers };
}
