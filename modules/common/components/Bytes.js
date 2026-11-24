.pragma library

// =============================================================================
// Bytes.js
//
// Byte sizes, transfer rates and ETAs in the shapes pacman prints them, in
// both directions: text -> number for the parser reading a package table,
// number -> text for a view showing a sum it computed from those numbers.
//
// A shared library (`.pragma library`) so there is exactly one copy of the
// arithmetic: a total the rail formats must agree with the per-row sizes the
// list formats.
//
// Units are BINARY throughout (1 MiB = 1048576 B), because that is what
// pacman counts in. A bare "MB"/"GB" is read the same way -- the only text
// that reaches us with the "i" missing came from a tool that dropped it, not
// from one that meant 10^9.
// =============================================================================

var _MULT = { "": 1, K: 1024, M: 1048576, G: 1073741824, T: 1099511627776 };
var _UNITS = ["B", "KiB", "MiB", "GiB", "TiB"];

// "741.15 MiB" -> 777150873.6. Also "12.3 KiB", "1.2 GB", "0.0   B" (pacman
// pads the bare-byte column with spaces). Returns 0 for anything unparseable
// so a caller summing sizes never has to guard each one. The lookahead keeps
// "5 Builds" from reading as five bytes.
function parseSize(text) {
    if (text == null) return 0;
    const m = String(text).match(/(-?\d+(?:\.\d+)?)\s*([KMGT]?)i?B(?![A-Za-z])/i);
    if (!m) return 0;
    return parseFloat(m[1]) * _MULT[m[2].toUpperCase()];
}

// "2.47 MiB/s" -> bytes per second. "0 B/s" and "0.00   B/s" -> 0.
function parseRate(text) {
    if (text == null) return 0;
    const m = String(text).match(/(-?\d+(?:\.\d+)?)\s*([KMGT]?)i?B\/s/i);
    if (!m) return 0;
    return parseFloat(m[1]) * _MULT[m[2].toUpperCase()];
}

// 777150873.6 -> "741.2 MiB". Whole bytes never get decimals ("512 B", not
// "512.0 B"). Rounded through an integer first: toFixed alone reads the
// binary value of 741.15 as 741.1499... and prints "741.1", which is not what
// pacman shows for the same bytes.
function formatBytes(bytes, decimals) {
    if (decimals === undefined) decimals = 1;
    let v = Number(bytes);
    if (!isFinite(v)) return "";
    const neg = v < 0;
    if (neg) v = -v;
    let u = 0;
    while (v >= 1024 && u < _UNITS.length - 1) { v /= 1024; u++; }
    const p = Math.pow(10, decimals);
    let r = u === 0 ? Math.round(v) : Math.round(v * p) / p;
    // Rounding can carry the value up to 1024.0; that belongs to the next unit.
    if (r >= 1024 && u < _UNITS.length - 1) { u++; r = Math.round(v / 1024 * p) / p; }
    const num = u === 0 ? String(r) : r.toFixed(decimals);
    return (neg ? "-" : "") + num + " " + _UNITS[u];
}

// 73 -> "01:13", 3723 -> "1:02:03" (pacman's own shapes). "" for a negative
// or non-finite value, so an unknown ETA renders as nothing rather than
// "-1:-1".
function formatEta(seconds) {
    const s = Number(seconds);
    if (!isFinite(s) || s < 0) return "";
    const t = Math.round(s);
    const h = Math.floor(t / 3600);
    const m = Math.floor((t % 3600) / 60);
    const sec = t % 60;
    const two = n => (n < 10 ? "0" : "") + n;
    return h > 0 ? h + ":" + two(m) + ":" + two(sec) : two(m) + ":" + two(sec);
}
