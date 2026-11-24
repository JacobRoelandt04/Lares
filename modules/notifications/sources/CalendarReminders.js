.pragma library
.import "../data/DayTimes.js" as DayTimes
.import "SourceFormat.js" as F

// =============================================================================
// CalendarReminders.js -- an appointment about to start, as pure decisions (SOURCES.md, "Later sources").
//
// "calendar reminders (N min before an appointment)", from the clock's calendar data (CalendarService.events: the
// occurrences its feeds expanded -- { uid, title, start: Date, end: Date, allDay, location, calendarId }).
//
//   due(events, nowMs, opts, reminded)     -> [{ key, marks, untilMs, uid, title, allDay, startMs, endMs, location }] the reminders
//                                             to say now; opts { leadMin: [min], allDayAt: "09:00" | "", calendars: [ids, none = all],
//                                             remind: { <calendar id>: false (none of its appointments) | minutes (its one lead) } }
//   nextAt(events, nowMs, opts, reminded)  -> the instant of the next one (ms), -1 none: the boundary to wake at
//   prune(reminded, nowMs)                 the days that are over go
//   text(ev, nowMs)                        { title, body }
//
// AN OCCURRENCE IS REMINDED ONCE PER LEAD: its key is the event and its start (a weekly event is a new key each week) and
// names its one card; a lead that was said is a mark, the key and the lead, kept in sources.json so a restart inside it
// does not say it again (a mark of the plain key, an earlier shell's, is every lead's). Leads that are due together are one
// reminder. One that begins in under the lead is told at once, with the minutes it really has left; one that began more than
// a minute ago (the shell was off, the machine was asleep) is not: it is no longer "about to start". An ALL-DAY event is
// told at `allDayAt` of its first day, or later that day when the shell was off then.
// No Qt, no clock.
// =============================================================================

var LATE_MS = 60000;      // an appointment this far into its start is still "starting now"

function _ms(d) {
    if (d instanceof Date)
        return d.getTime();
    var n = Number(d);
    return isFinite(n) ? n : NaN;
}

function keyOf(ev) {
    return "cal:" + F.keyPart(ev.uid) + "@" + _ms(ev.start);
}

// The moments of every occurrence that still matter: [{ ev, startMs, untilMs, at: [{ mark, ms }] }].
function _live(events, nowMs, opts) {
    var out = [];
    var list = Array.isArray(events) ? events : [];
    var only = opts.calendars || [];
    var dayMin = DayTimes.parse(opts.allDayAt);
    for (var i = 0; i < list.length; i++) {
        var e = list[i];
        if (!e || (only.length > 0 && only.indexOf(e.calendarId) < 0))
            continue;
        var own = opts.remind ? opts.remind[e.calendarId] : undefined;
        if (own === false)
            continue;
        var leads = typeof own === "number" ? [own] : opts.leadMin;
        var s = _ms(e.start);
        if (!isFinite(s))
            continue;
        var k = keyOf(e), until = s + LATE_MS, at = [];
        if (e.allDay === true) {
            if (dayMin < 0)
                continue;
            until = DayTimes.at(s, 1, 0);
            at.push({ mark: k + "#day", ms: DayTimes.at(s, 0, dayMin) });
        } else {
            for (var j = 0; j < leads.length; j++)
                at.push({ mark: k + "#" + leads[j], ms: s - leads[j] * 60000 });
        }
        if (until > nowMs)
            out.push({ ev: e, startMs: s, untilMs: e.allDay === true ? until : s, at: at });
    }
    return out;
}

function _done(reminded, l, mark) {
    return reminded[mark] !== undefined || reminded[keyOf(l.ev)] !== undefined;
}

function due(events, nowMs, opts, reminded) {
    var out = [];
    var done = reminded || {};
    var live = _live(events, nowMs, opts);
    for (var i = 0; i < live.length; i++) {
        var l = live[i], e = l.ev;
        var marks = l.at.filter(function (a) { return a.ms <= nowMs && !_done(done, l, a.mark); }).map(function (a) { return a.mark; });
        if (marks.length === 0)
            continue;
        out.push({ key: keyOf(e), marks: marks, untilMs: l.untilMs, uid: String(e.uid), title: String(e.title || ""), allDay: e.allDay === true,
                   startMs: l.startMs, endMs: e.end ? _ms(e.end) : NaN, location: String(e.location || "") });
    }
    out.sort(function (a, b) { return a.startMs - b.startMs; });
    return out;
}

function nextAt(events, nowMs, opts, reminded) {
    var best = -1;
    var done = reminded || {};
    _live(events, nowMs, opts).forEach(function (l) {
        l.at.forEach(function (a) {
            if (a.ms > nowMs && !_done(done, l, a.mark) && (best < 0 || a.ms < best))
                best = a.ms;
        });
    });
    return best;
}

function prune(reminded, nowMs) {
    var out = {};
    for (var k in (reminded || {}))
        if (Object.prototype.hasOwnProperty.call(reminded, k) && Number(reminded[k]) + 86400000 > nowMs)
            out[k] = reminded[k];
    return out;
}

// "Standup", "In 10 min . 14:30-15:00 . Room 3" (the minutes it really has left; "Starting now" past the start).
function text(r, nowMs) {
    var left = Math.round((r.startMs - nowMs) / 60000);
    var when = left > 0 ? "In " + left + " min" : "Starting now";
    var bits = r.allDay ? ["Today"]
        : [when, F.hm(r.startMs) + (isFinite(r.endMs) && r.endMs > r.startMs ? "–" + F.hm(r.endMs) : "")];
    if (r.location !== "")
        bits.push(r.location);
    return { title: r.title !== "" ? r.title : "Appointment", body: bits.join(" · ") };
}
