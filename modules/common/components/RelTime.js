.pragma library

// =============================================================================
// RelTime.js -- "now", "4 min", "2 h", "Tue 14:05", "3 Sep 09:12",
// "30 Dec 2025": how long ago something happened, and the exact instant that
// text goes stale.
//
//   format(ms, nowMs[, opts]) -> { text, nextMs }
//   absolute(ms)              -> "Thu 24 Sep 2026, 15:05"   (the tip)
//
// age = nowMs - ms:
//   age <  60 s        "now"            (a future ms reads "now" too)
//   age <  60 min      "N min"          floor
//   age <  24 h        "N h"            floor
//   age <   6 days     "ddd HH:mm"      the weekday cannot be today's yet:
//                                        six days back is the latest a weekday
//                                        name is unambiguous
//   otherwise          "d MMM HH:mm"    when ms is in nowMs's year
//                      "d MMM yyyy"     when it is not: an old pin needs the
//                                        date, not the minute
// Every boundary is exact: 59 999 ms is "now", 60 000 is "1 min".
//
// OPTS -- a module's own wording on the same boundaries. Omitted, or any key
// left out, is the default above; nothing here moves a boundary, it only
// leaves one out or changes the words:
//   justNow  "now"   the text under a minute ("just now")
//   suffix   ""      after "N min" and "N h" (" ago")
//   dates    true    false: past a day the hours count on ("49 h") and the
//                    weekday and date forms never come
//   weekday  true    false: a day on, the date form at once (no "ddd" span)
//   time     true    false: the weekday and date forms without " HH:mm"
//                    ("Thu", "24 Sep")
//   year     true    false: the date form never gains its year; it is final
//                    ("d MMM HH:mm" for good, nextMs -1)
// The shell's readers, one line each:
//   notification card   {}                                   now / 4 min / Thu 15:05
//   note tile           { time: false }                      now / 4 min / Thu / 24 Sep
//   LLM turn            { justNow: "just now", suffix: " ago",
//                         weekday: false, year: false }      just now / 4 min ago / 24 Sep 15:05
//   update check        { justNow: "just now", suffix: " ago",
//                         dates: false }                     (checked) 4 min ago / 49 h ago
//
// NEXTMS IS WHAT MAKES THIS CHEAP. A list of timestamps does not need a clock
// ticking every second, or even every minute: each reader asks for its next
// boundary (BoundaryClock.request(nextMs)) and ONE single-shot timer fires at
// the earliest. nextMs is the first millisecond at which format() would
// return a different text -- never earlier (a tick that changes nothing is a
// wasted frame) and never later (a "now" that stays "now" for 61 s is a lie).
//
// FOR THE CLOCK THAT CONSUMES IT (BoundaryClock):
//   * nextMs = -1 means NEVER RE-REQUEST: the text is final ("d MMM yyyy",
//     and the invalid-input answer). Requesting -1 would arm a timer for the
//     past and fire at once, for nothing.
//   * Otherwise nextMs > nowMs, always, and the reader re-requests when the
//     clock's `now` reaches it (then calls format() again for the next one).
//   * nextMs can be MONTHS away: the "d MMM HH:mm" form changes once more, at
//     local midnight of the next 1 January (it gains its year). A single-shot
//     Timer cannot wait that long -- Qt's interval is an int and overflows
//     past 2^31 ms (24.8 days) -- so the clock caps the interval it arms and
//     re-arms on waking until the boundary is reached.
//
// NOWMS IS AN ARGUMENT, NOT Date.now(): a binding that calls Date.now()
// captures nothing and never re-runs, which is how a relative time freezes
// (CLAUDE.md). An invalid ms or nowMs answers { text: "", nextMs: -1 }.
//
// Names are English and fixed (Mon, Sep), whatever the locale: the shell's
// wording is English everywhere, and a figure slot measured for "Tue" must not
// meet "mar." Times are local, 24 h, zero-padded.
//
// Pure: no Qt, loadable under node.
// =============================================================================

var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

var MINUTE_MS = 60000;
var HOUR_MS = 3600000;
var DAY_MS = 86400000;
var WEEKDAY_SPAN_MS = 6 * DAY_MS;

function _valid(v) {
    return typeof v === "number" && isFinite(v);
}

function _p2(n) {
    return n < 10 ? "0" + n : "" + n;
}

function _hm(d) {
    return _p2(d.getHours()) + ":" + _p2(d.getMinutes());
}

function _str(v, dflt) {
    return typeof v === "string" ? v : dflt;
}

function format(ms, nowMs, opts) {
    if (!_valid(ms) || !_valid(nowMs))
        return { text: "", nextMs: -1 };
    var o = opts || {};
    var suffix = _str(o.suffix, "");
    var age = nowMs - ms;
    if (age < MINUTE_MS)
        return { text: _str(o.justNow, "now"), nextMs: ms + MINUTE_MS };
    if (age < HOUR_MS) {
        var m = Math.floor(age / MINUTE_MS);
        return { text: m + " min" + suffix, nextMs: ms + (m + 1) * MINUTE_MS };
    }
    if (age < DAY_MS || o.dates === false) {
        var h = Math.floor(age / HOUR_MS);
        return { text: h + " h" + suffix, nextMs: ms + (h + 1) * HOUR_MS };
    }
    var d = new Date(ms);
    var hm = o.time === false ? "" : " " + _hm(d);
    if (age < WEEKDAY_SPAN_MS && o.weekday !== false)
        return { text: DAYS[d.getDay()] + hm, nextMs: ms + WEEKDAY_SPAN_MS };
    if (o.year === false)
        return { text: d.getDate() + " " + MONTHS[d.getMonth()] + hm, nextMs: -1 };
    var year = new Date(nowMs).getFullYear();
    if (d.getFullYear() !== year)
        return { text: d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear(), nextMs: -1 };
    return { text: d.getDate() + " " + MONTHS[d.getMonth()] + hm,
             nextMs: new Date(year + 1, 0, 1).getTime() };
}

function absolute(ms) {
    if (!_valid(ms))
        return "";
    var d = new Date(ms);
    return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()] + " "
        + d.getFullYear() + ", " + _hm(d);
}
