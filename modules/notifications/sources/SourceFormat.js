.pragma library

// =============================================================================
// SourceFormat.js -- the words the notification sources share: sizes, durations,
// "N days ago", the local day a state file keys by. Pure (no Qt, every "now" an
// argument).
//
// One spelling for the whole family, so a battery warning and a disk warning say
// "1 h 12 min" the same way, and a size reads like pacman's ("312 MiB").
// =============================================================================

var MIB = 1048576;
var GIB = 1073741824;

function _ok(v) {
    return typeof v === "number" && isFinite(v);
}

// "1 update", "2 updates".
function plural(n, one, many) {
    return n + " " + (n === 1 ? one : (many === undefined ? one + "s" : many));
}

// 327155712 -> "312 MiB", 2373000000 -> "2.2 GiB", 524288 -> "512 KiB". Binary units, as pacman counts
// them; whole numbers below a GiB (a decimal on "312.4 MiB" says nothing a user acts on).
function bytes(n) {
    if (!_ok(n) || n < 0)
        return "";
    if (n >= GIB)
        return (Math.round(n / GIB * 10) / 10).toFixed(1) + " GiB";
    if (n >= MIB)
        return Math.round(n / MIB) + " MiB";
    if (n >= 1024)
        return Math.round(n / 1024) + " KiB";
    return Math.round(n) + " B";
}

// Free space as `df -h` prints it: GB of 1024^3 bytes, one decimal under ten ("4.2 GB", "56 GB").
function gb(n) {
    if (!_ok(n) || n < 0)
        return "";
    var g = n / GIB;
    return (g < 10 ? (Math.round(g * 10) / 10).toFixed(1) : String(Math.round(g))) + " GB";
}

// Minutes -> "1 h 12 min", "45 min", "<1 min", "2 h". "" for unknown (negative, NaN).
function duration(min) {
    if (!_ok(min) || min < 0)
        return "";
    var t = Math.round(min);
    if (t < 1)
        return "<1 min";
    var h = Math.floor(t / 60);
    var m = t % 60;
    if (h === 0)
        return m + " min";
    return m === 0 ? h + " h" : h + " h " + m + " min";
}

// Whole days since something -> "today", "yesterday", "9 days ago". "" for unknown (<= 0 days is
// the service's "no run known", so the caller passes only what it knows).
function daysAgo(days) {
    if (!_ok(days) || days < 0)
        return "";
    var d = Math.floor(days);
    if (d === 0)
        return "today";
    return d === 1 ? "yesterday" : d + " days ago";
}

function _two(n) {
    return (n < 10 ? "0" : "") + n;
}

// ms -> "2026-10-21" in the LOCAL time zone (the day a once-a-day rule counts in).
function dayKey(ms) {
    var d = new Date(ms);
    return d.getFullYear() + "-" + _two(d.getMonth() + 1) + "-" + _two(d.getDate());
}

// ms -> "14:30" local.
function hm(ms) {
    var d = new Date(ms);
    return _two(d.getHours()) + ":" + _two(d.getMinutes());
}

// A name made safe to sit inside a notification key (keys are compared whole; no separator
// characters of ours may appear in a piece).
function keyPart(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[^A-Za-z0-9._@:+-]/g, "_");
}
