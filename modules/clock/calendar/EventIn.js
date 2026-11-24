.pragma library

// =============================================================================
// EventIn.js -- the line an expanded appointment shows under its place: how long until it
// begins, so the time left to an event need not be worked out. Pure: no Qt state.
//
//   line(startMs, endMs, allDay, nowMs) -> { label, text, nextMs } | null
//
//   not begun    "in"       "25 min" / "2 h 15 min" / "3 d 4 h" / "12 d"
//   running      "started"  "20 min ago" / "just now"   (minutes, hours, then whole days: "ended 2 days ago".
//   over         "ended"    "3 h ago" / "2 days ago"      Never a date or a time of day -- the event shows its own)
//   all day      null: a day-long event has no time of day to count to
//
// The past forms are for an event whose day is open while it runs or after it ran: a row that
// says nothing once the event begins would read as a broken line, so it says what happened.
//
// The future form counts WHOLE MINUTES, rounded UP: with 59 s left it says "1 min", never "0 min", and it
// changes on the second the minute below begins. Under a day it is hours and minutes; from a day on it is days
// and hours (the minutes would be noise three days out); from a week on, days alone.
//
// NEXTMS is the first millisecond at which the text would read differently (RelTime.format's own contract: never
// earlier, never later), so ONE BoundaryClock wakes the line exactly when it changes -- a three-day-out event wakes
// once an hour, a quarter-hour-out event once a minute. A running event also wakes at its end.
// =============================================================================

var MINUTE_MS = 60000;
var DAY_MIN = 1440;
var WEEK_MIN = 7 * DAY_MIN;

function _valid(v) {
    return typeof v === "number" && isFinite(v);
}

// Whole minutes left, rounded up; the minutes count the text is made of.
function minutesLeft(startMs, nowMs) {
    return Math.ceil((startMs - nowMs) / MINUTE_MS);
}

function _future(startMs, nowMs) {
    var m = minutesLeft(startMs, nowMs);
    var text, floorMin;
    if (m < 60) {
        text = m + " min";
        floorMin = m - 1;
    } else if (m < DAY_MIN) {
        var h = Math.floor(m / 60), r = m % 60;
        text = h + " h" + (r > 0 ? " " + r + " min" : "");
        floorMin = m - 1;
    } else if (m < WEEK_MIN) {
        var d = Math.floor(m / DAY_MIN), hh = Math.floor((m % DAY_MIN) / 60);
        text = d + " d" + (hh > 0 ? " " + hh + " h" : "");
        // the text holds while m stays within [60 k, 60 k + 59] (k whole hours): it changes when m drops below 60 k
        floorMin = Math.floor(m / 60) * 60 - 1;
    } else {
        var dd = Math.floor(m / DAY_MIN);
        text = dd + " d";
        floorMin = dd * DAY_MIN - 1;
    }
    // m minutes are read while the time left is in ((m - 1) minutes, m minutes]; `floorMin` is the m at which the text
    // reads differently, reached when the time left falls to `floorMin` minutes
    return { label: "in", text: text, nextMs: startMs - floorMin * MINUTE_MS };
}

var HOUR_MS = 3600000;
var DAY_MS = 86400000;

// The past forms count and never name a date (the end's date and time are duplicate
// information: the event shows both): "just now" under a minute, minutes under an hour, hours under a day, then
// whole days ("2 days ago"). Each text holds until the next whole unit, which is its nextMs.
function _ago(ms, nowMs) {
    var age = Math.max(0, nowMs - ms);
    if (age < MINUTE_MS)
        return { text: "just now", nextMs: ms + MINUTE_MS };
    if (age < HOUR_MS) {
        var m = Math.floor(age / MINUTE_MS);
        return { text: m + " min ago", nextMs: ms + (m + 1) * MINUTE_MS };
    }
    if (age < DAY_MS) {
        var h = Math.floor(age / HOUR_MS);
        return { text: h + " h ago", nextMs: ms + (h + 1) * HOUR_MS };
    }
    var d = Math.floor(age / DAY_MS);
    return { text: d + (d === 1 ? " day ago" : " days ago"), nextMs: ms + (d + 1) * DAY_MS };
}

function line(startMs, endMs, allDay, nowMs) {
    if (allDay === true || !_valid(startMs) || !_valid(nowMs))
        return null;
    if (nowMs < startMs)
        return _future(startMs, nowMs);
    if (!_valid(endMs) || endMs <= startMs || nowMs < endMs) {
        var s = _ago(startMs, nowMs);
        var next = s.nextMs;
        if (_valid(endMs) && endMs > nowMs && (next < 0 || endMs < next))
            next = endMs;
        return { label: "started", text: s.text, nextMs: next };
    }
    var e = _ago(endMs, nowMs);
    return { label: "ended", text: e.text, nextMs: e.nextMs };
}
