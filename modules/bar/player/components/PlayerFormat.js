.pragma library

// =============================================================================
// PlayerFormat.js -- the player's small text helpers, one place.
//
//   clock(sec)   3:05  /  1:02:09      a track's length (figures; the slot's width is the host's)
//   long(sec)    "43 min" / "2 h 5 min" / "1 min"   an album's or artist's total, the way Auxio writes it
//   bytes(n)     "70.6 MB"             a file size
//   plural(n, "song")   "1 song" / "12 songs"
// =============================================================================

function clock(sec) {
    var s = Math.max(0, Math.round(Number(sec) || 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var r = s % 60;
    var rr = (r < 10 ? "0" : "") + r;
    return h > 0 ? h + ":" + (m < 10 ? "0" : "") + m + ":" + rr : m + ":" + rr;
}

function long(sec) {
    var m = Math.max(0, Math.round((Number(sec) || 0) / 60));
    if (m < 1) return (Number(sec) || 0) > 0 ? "<1 min" : "";
    var h = Math.floor(m / 60);
    var r = m % 60;
    if (h === 0) return m + " min";
    return r === 0 ? h + " h" : h + " h " + r + " min";
}

function bytes(n) {
    var b = Number(n) || 0;
    if (b <= 0) return "";
    var u = ["B", "kB", "MB", "GB"];
    var i = 0;
    while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
    return (i === 0 ? String(Math.round(b)) : b.toFixed(b >= 100 ? 0 : 1)) + " " + u[i];
}

function plural(n, word) {
    var k = Number(n) || 0;
    return k + " " + word + (k === 1 ? "" : "s");
}

// "2015-08-28" -> "28 Aug 2015", "2015-08" -> "Aug 2015", "2015" -> "2015", anything else as it came.
function dateText(d) {
    var s = String(d || "").trim();
    var m = /^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$/.exec(s);
    if (!m) return s;
    var mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    if (!m[2]) return m[1];
    var mi = parseInt(m[2], 10) - 1;
    if (mi < 0 || mi > 11) return m[1];
    return (m[3] ? parseInt(m[3], 10) + " " : "") + mon[mi] + " " + m[1];
}
