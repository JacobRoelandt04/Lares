.pragma library

// =============================================================================
// dial.js -- the timer dial's scale: angle (degrees wound clockwise from 12,
// any number of turns) <-> time (ms). Pure functions.
//
// The FIRST turn is non-linear, a quarter per order of magnitude a timer is
// set in:
//     0 -  90   0:00 ->  1:00      seconds
//    90 - 180   1:00 -> 10:00      the short timers
//   180 - 270  10:00 -> 30:00
//   270 - 360  30:00 -> 1:00:00
// and every turn after it is linear, an hour a turn (15 min a quarter), up
// to `MAX_MS`. Nothing snaps -- but each quarter's edge is STICKY: within
// `sticky` degrees of it the time holds at the edge's value, so 1:00, 10:00,
// 30:00 and the hours are easy to land on exactly.
//
// A dragged value is rounded to its quarter's STEP (1 s, 5 s, 15 s, 30 s, and
// 1 min past the first hour): round numbers, about one step a degree. Shift
// gives single seconds (the card does that).
// =============================================================================

var MAX_MS = 12 * 3600000;

// The first turn's quarter edges: [degrees, ms].
var EDGES = [[0, 0], [90, 60000], [180, 600000], [270, 1800000], [360, 3600000]];
var STEPS = [1000, 5000, 15000, 30000];
var LATE_STEP = 60000;

// Degrees -> ms, continuous, with the sticky edges. `sticky` is the half
// width of each edge's plateau, degrees.
function msOfAngle(deg, sticky) {
    var z = Math.max(0, Math.min(20, sticky || 0));
    var a = Math.max(0, deg);
    // Which quarter, and where in it.
    var q = Math.floor(a / 90);
    var within = a - q * 90;
    // On a plateau: the nearer edge's value.
    if (within <= z)
        return edgeValue(q);
    if (within >= 90 - z)
        return edgeValue(q + 1);
    var f = (within - z) / (90 - 2 * z);
    return edgeValue(q) + f * (edgeValue(q + 1) - edgeValue(q));
}

// The value at quarter edge `i` (0 = 12 o'clock of the first turn).
function edgeValue(i) {
    if (i <= 4)
        return EDGES[i][1];
    return 3600000 + (i - 4) * 900000;
}

// Ms -> degrees: the inverse, an edge's value landing on the edge itself
// (the middle of its plateau), so a preset of 10:00 draws at 6 o'clock.
function angleOfMs(ms, sticky) {
    var z = Math.max(0, Math.min(20, sticky || 0));
    var v = Math.max(0, Math.min(MAX_MS, ms));
    // The quarter the value falls in.
    var i = 0;
    while (edgeValue(i + 1) < v)
        i++;
    var lo = edgeValue(i), hi = edgeValue(i + 1);
    if (v <= lo)
        return i * 90;
    if (v >= hi)
        return (i + 1) * 90;
    var f = (v - lo) / (hi - lo);
    return i * 90 + z + f * (90 - 2 * z);
}

function maxAngle(sticky) {
    return angleOfMs(MAX_MS, sticky);
}

// The step a value is rounded to, by the quarter it is in.
function stepOf(ms) {
    if (ms < 60000) return STEPS[0];
    if (ms < 600000) return STEPS[1];
    if (ms < 1800000) return STEPS[2];
    if (ms < 3600000) return STEPS[3];
    return LATE_STEP;
}

function quantize(ms) {
    var v = Math.max(0, Math.min(MAX_MS, ms));
    var st = stepOf(v);
    return Math.max(0, Math.min(MAX_MS, Math.round(v / st) * st));
}
