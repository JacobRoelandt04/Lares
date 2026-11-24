.pragma library

// =============================================================================
// DayTimes.js -- times of the day ("22:30") as instants, and the quiet hours of notifications.jsonc (`dnd.hours`).
//
//   parse(hhmm)            minutes since midnight, -1 for what is no time
//   at(dayMs, plus, min)   the instant of that time of the day `plus` days after dayMs' local day
//   spans(hours, nowMs)    the quiet hours round now, [{ from, to }]: merged, in order (two days back and two ahead)
//   inside(hours, nowMs)   do-not-disturb by the clock
//   last(hours, nowMs)     { at, on } the latest start or end that has passed, null with no hours
//   next(hours, nowMs)     the instant of the next one, -1 with no hours
//
// EVERY INSTANT COMES FROM LOCAL FIELDS (day + k, the time of the day): a day with a change of the clock is 23 or 25 hours
// long, and 86400000 ms added to one drifts. A local time the spring change skips is the first instant after the gap, one
// the autumn change repeats its first occurrence -- found by walking round the guess, so node and QV4, which resolve both
// differently in the Date constructor, answer alike. A span whose end is not after its start ends on the next day; hours
// that overlap or touch are one span.
// Pure: no Qt, no clock.
// =============================================================================

function parse(hhmm) {
    var m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(hhmm));
    return m ? Number(m[1]) * 60 + Number(m[2]) : -1;
}

function at(dayMs, plus, min) {
    var d = new Date(dayMs);
    var day = new Date(d.getFullYear(), d.getMonth(), d.getDate() + plus);
    var guess = day.getTime() + min * 60000;
    for (var k = -60; k <= 60; k += 30) {
        var t = new Date(guess + k * 60000);
        if (t.getDate() === day.getDate() && t.getHours() * 60 + t.getMinutes() >= min)
            return t.getTime();
    }
    return guess;
}

function spans(hours, nowMs) {
    var list = [];
    var hs = Array.isArray(hours) ? hours : [];
    for (var i = 0; i < hs.length; i++) {
        var p = String(hs[i]).split("-");
        var a = parse(p[0]), b = p.length === 2 ? parse(p[1]) : -1;
        if (a < 0 || b < 0 || a === b)
            continue;
        for (var k = -2; k <= 2; k++)
            list.push({ from: at(nowMs, k, a), to: at(nowMs, b > a ? k : k + 1, b) });
    }
    list.sort(function (x, y) { return x.from - y.from; });
    var out = [];
    for (var j = 0; j < list.length; j++) {
        var top = out.length > 0 ? out[out.length - 1] : null;
        if (top && list[j].from <= top.to)
            top.to = Math.max(top.to, list[j].to);
        else if (list[j].to > list[j].from)
            out.push({ from: list[j].from, to: list[j].to });
    }
    return out;
}

function inside(hours, nowMs) {
    return spans(hours, nowMs).some(function (s) { return s.from <= nowMs && nowMs < s.to; });
}

function last(hours, nowMs) {
    var best = null;
    spans(hours, nowMs).forEach(function (s) {
        if (s.from <= nowMs)
            best = { at: s.from, on: true };
        if (s.to <= nowMs)
            best = { at: s.to, on: false };
    });
    return best;
}

function next(hours, nowMs) {
    var s = spans(hours, nowMs);
    for (var i = 0; i < s.length; i++) {
        if (s[i].from > nowMs)
            return s[i].from;
        if (s[i].to > nowMs)
            return s[i].to;
    }
    return -1;
}
