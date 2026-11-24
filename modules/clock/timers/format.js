.pragma library

// =============================================================================
// format.js -- the timers' figures as text.
// Shapes, not values, decide a figure's width (DigitCells): "25:00" and
// "1:05:00" are two shapes; nothing else changes a width.
// =============================================================================

function _two(n) {
    return (n < 10 ? "0" : "") + n;
}

// A countdown: seconds rounded UP (a timer shows 0:01 until it is done),
// "m:ss" under an hour, "h:mm:ss" from one.
function countdown(ms) {
    const s = Math.max(0, Math.ceil(ms / 1000));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    return h > 0 ? h + ":" + _two(m) + ":" + _two(sec) : _two(m) + ":" + _two(sec);
}

// A stopwatch: hundredths under an hour ("mm:ss.cc"), "h:mm:ss" from one.
function stopwatch(ms) {
    const t = Math.max(0, Math.floor(ms / 10));
    const s = Math.floor(t / 100), hundredth = t % 100;
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    return h > 0 ? h + ":" + _two(m) + ":" + _two(sec) : _two(m) + ":" + _two(sec) + "." + _two(hundredth);
}

// A lap: in the stopwatch's own form.
function lap(ms) {
    return stopwatch(ms);
}

function clock(h, m) {
    return _two(h) + ":" + _two(m);
}

function clockOf(ms) {
    const d = new Date(ms);
    return clock(d.getHours(), d.getMinutes());
}

// "in 8 h 12 min", "in 5 min", "in under a minute".
function until(ms) {
    const m = Math.max(0, Math.ceil(ms / 60000));
    if (m < 1)
        return "in under a minute";
    const h = Math.floor(m / 60), r = m % 60;
    return "in " + (h > 0 ? h + " h" + (r > 0 ? " " + r + " min" : "") : r + " min");
}

// A preset's label: "45 s", "5 min", "1:30" (a minute and a half), "1 h",
// "1 h 30".
function preset(ms) {
    const s = Math.round(ms / 1000);
    if (s < 60)
        return s + " s";
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    if (h > 0)
        return h + " h" + (m > 0 ? " " + _two(m) : "");
    return sec === 0 ? m + " min" : m + ":" + _two(sec);
}

function minutes(ms) {
    return Math.round(ms / 60000) + " min";
}
