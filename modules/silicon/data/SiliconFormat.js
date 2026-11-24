.pragma library

// =============================================================================
// SiliconFormat.js -- the figures the popup prints, as strings. Pure, no Qt. One place, so the
// bar button, the popup's slots, an OSD and a notification say a number the same way.
//
//   watts(w, opts)       13.4 W   -13.4 W (opts.signed)   "—" when unknown
//   minutes(m)           "1h 05m" | "45m" | "<1m" | "—"   (minutes zero-padded under an hour sign
//                        so the width does not move when the minute rolls over)
//   percent(p)           "62 %"
//   clock(mhz)           "3.42 GHz" | "800 MHz"
//   temp(c)              "65 °C"
//   mib(mb)              "1.5 GiB" | "812 MiB"
//   profileLabel / gpuStepLabel / eppLabel / governorLabel / dStateLabel   the words
//   segWatts / segTime / segSince / segGiB   the BOARD's seven-segment displays (below)
//
// Unknown is always the same dash, never "NaN" and never an empty slot.
// =============================================================================

var DASH = "—";

function _num(v) {
    return typeof v === "number" && isFinite(v);
}

function watts(w, opts) {
    if (!_num(w))
        return DASH;
    var o = opts || {};
    var a = Math.abs(w);
    var body = (a >= 100 ? a.toFixed(0) : a.toFixed(1)) + " W";
    if (o.signed)
        return (w < 0 ? "−" : (w > 0 ? "+" : "")) + body;
    return body;
}

function minutes(m) {
    if (!_num(m) || m < 0)
        return DASH;
    var total = Math.round(m);
    if (total < 1)
        return "<1m";
    var h = Math.floor(total / 60);
    var r = total % 60;
    if (h > 0)
        return h + "h " + (r < 10 ? "0" : "") + r + "m";
    return r + "m";
}

function percent(p) {
    return _num(p) ? Math.round(p) + " %" : DASH;
}

function clock(mhz) {
    if (!_num(mhz) || mhz <= 0)
        return DASH;
    return mhz >= 1000 ? (mhz / 1000).toFixed(2) + " GHz" : Math.round(mhz) + " MHz";
}

function temp(c) {
    return _num(c) ? Math.round(c) + " °C" : DASH;
}

function mib(mb) {
    if (!_num(mb) || mb < 0)
        return DASH;
    return mb >= 1024 ? (mb / 1024).toFixed(1) + " GiB" : Math.round(mb) + " MiB";
}

function _title(s) {
    var t = String(s === undefined || s === null ? "" : s).replace(/[_-]+/g, " ").trim();
    return t === "" ? DASH : t.charAt(0).toUpperCase() + t.slice(1);
}

function profileLabel(name) {
    return _title(name);
}

// The scene's step order: 0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU only.
function gpuStepLabel(step) {
    var l = ["Integrated", "Smart", "Hybrid", "dGPU only"];
    return step >= 0 && step < l.length ? l[step] : DASH;
}

function eppLabel(name) {
    return _title(name);
}

function governorLabel(name) {
    return _title(name);
}

// D0 awake ... D3cold off.
function dStateLabel(d) {
    var l = { D0: "awake", D1: "light sleep", D2: "light sleep", D3hot: "asleep", D3cold: "off" };
    return l.hasOwnProperty(d) ? l[d] : DASH;
}

// --- the board's seven-segment displays --------------------------------------------------------
// The grammar the scene's `figures` speak (SiliconScene.figures): the characters are 0-9, `-`, a
// space, `d` and `h`; a `.` right after a character lights that cell's decimal point and takes no cell; a `:` is
// only in a time, between its 2nd and 3rd cell. The scene right-aligns each string into its display's fixed cells,
// so a string here never carries padding, and each function says how many cells it can fill:
//
//   segWatts(w)      4 cells   -12.2  9.8  -123  (a discharge is signed, a charge is not: a seven-segment cannot
//                              draw a plus; 0-9.9 and 10-99.9 W have one decimal, from 100 W whole watts)
//   segTime(min)     4 cells   1:32  12:05  --:--   (hours:minutes, 99:59 at most)
//   segSince(ms, now) 3 cells  4.0h  37h  4d  99d   (the unit in the last cell: tenths of an hour below 10 hours,
//                              whole hours below 100, days beyond, 99d at most; "" while the pack has never been
//                              full) -> { text, nextMs }: nextMs is the instant the text changes (RelTime's
//                              contract, for a BoundaryClock), -1 when it is final
//   segGiB(kib)      3 cells   12.4  9.8  123   (used memory, GiB)
//
// Unknown is dashes (`----`, `--:--`, `--`); "" is a display with nothing to say (blank cells, the caller's call).

function segWatts(w) {
    if (!_num(w))
        return "----";
    var a = Math.abs(w);
    var r = Math.round(a * 10) / 10;
    var body = r >= 100 ? String(Math.min(999, Math.round(a))) : r.toFixed(1);
    return (w < 0 && r > 0 ? "-" : "") + body;
}

function segTime(minutes) {
    if (!_num(minutes) || minutes < 0)
        return "--:--";
    var t = Math.min(99 * 60 + 59, Math.round(minutes));
    var r = t % 60;
    return Math.floor(t / 60) + ":" + (r < 10 ? "0" : "") + r;
}

var SEG_TENTH_H_MS = 360000;
var SEG_HOUR_MS = 3600000;
var SEG_DAY_MS = 86400000;

function segSince(ms, nowMs) {
    if (!_num(ms) || ms <= 0 || !_num(nowMs))
        return { text: "", nextMs: -1 };
    var age = Math.max(0, nowMs - ms);
    var tenths = Math.floor(age / SEG_TENTH_H_MS);
    if (tenths < 100)
        return { text: Math.floor(tenths / 10) + "." + (tenths % 10) + "h", nextMs: ms + (tenths + 1) * SEG_TENTH_H_MS };
    var h = Math.floor(age / SEG_HOUR_MS);
    if (h < 100)
        return { text: h + "h", nextMs: ms + (h + 1) * SEG_HOUR_MS };
    var d = Math.floor(age / SEG_DAY_MS);
    if (d >= 99)
        return { text: "99d", nextMs: -1 };
    return { text: d + "d", nextMs: ms + (d + 1) * SEG_DAY_MS };
}

function segGiB(kib) {
    if (!_num(kib) || kib < 0)
        return "--";
    var g = kib / 1048576;
    var r = Math.round(g * 10) / 10;
    return r >= 100 ? String(Math.min(999, Math.round(g))) : r.toFixed(1);
}
