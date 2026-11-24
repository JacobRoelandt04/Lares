.pragma library

// =============================================================================
// QrCode.js -- our own QR encoder for the join code of a network (aerial's Sharing page, the hotspot panel). Byte mode only, error
// correction M, versions 1 to 10 (up to 213 bytes: a Wi-Fi string is far under it), the mask chosen by the standard's penalty rules.
// Pure (`.pragma library`, no QML), node-testable. PROVED by decoding, not by reading: tools/dev/aerial_qr_probe.sh renders a corpus and
// decodes every picture with OpenCV's QRCodeDetector (ARM nomask must fail).
//
//   encode(text)            -> { ok, version, mask, size, rows: [string of "0"/"1" per row], bytes } | { ok: false, why }
//   wifiString(ssid, psk, security, hidden)  -> "WIFI:T:WPA;S:..;P:..;H:false;;" ("" for a network a code cannot join: enterprise)
//   runs(code)              -> [[x, y, length]] horizontal runs of dark modules (what a path draws)
//   svgPath(code, m, ox, oy)-> "M x y h w v m h -w z ..." one path of the whole symbol, module size m
//
// The numbers (ISO/IEC 18004) for ECC level M, versions 1-10: ECC codewords per block, blocks as [count, data codewords] groups.
// =============================================================================

var EC_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
var GROUPS = [null,
    [[1, 16]], [[1, 28]], [[1, 44]], [[2, 32]], [[2, 43]], [[4, 27]], [[4, 31]], [[2, 38], [2, 39]], [[3, 36], [2, 37]], [[4, 43], [1, 44]]];
var ALIGN = [null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];
var MAX_VERSION = 10;

// ---- GF(256), polynomial 0x11D ----
var EXP = [];
var LOG = [];
(function () {
    var x = 1;
    for (var i = 0; i < 255; i++) {
        EXP[i] = x;
        LOG[x] = i;
        x <<= 1;
        if (x & 0x100)
            x ^= 0x11D;
    }
    for (var j = 255; j < 512; j++)
        EXP[j] = EXP[j - 255];
})();

function gfMul(a, b) {
    return a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]];
}

function rsGenerator(degree) {
    var g = [1];
    for (var i = 0; i < degree; i++) {
        var next = [];
        for (var k = 0; k <= g.length; k++)
            next[k] = 0;
        for (var j = 0; j < g.length; j++) {
            next[j] ^= g[j];
            next[j + 1] ^= gfMul(g[j], EXP[i]);
        }
        g = next;
    }
    return g;       // highest degree first, monic
}

function rsRemainder(data, degree) {
    var gen = rsGenerator(degree);
    var rem = [];
    for (var i = 0; i < degree; i++)
        rem[i] = 0;
    for (var d = 0; d < data.length; d++) {
        var factor = data[d] ^ rem[0];
        rem.shift();
        rem.push(0);
        if (factor !== 0)
            for (var k = 0; k < degree; k++)
                rem[k] ^= gfMul(gen[k + 1], factor);
    }
    return rem;
}

// ---- the text as UTF-8 bytes (a name may carry any character) ----
function utf8(text) {
    var out = [];
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < text.length) {
            var d = text.charCodeAt(i + 1);
            if (d >= 0xDC00 && d < 0xE000) {
                c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                i++;
            }
        }
        if (c < 0x80)
            out.push(c);
        else if (c < 0x800)
            out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000)
            out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else
            out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
}

function dataCapacity(version) {
    var g = GROUPS[version], n = 0;
    for (var i = 0; i < g.length; i++)
        n += g[i][0] * g[i][1];
    return n;
}

// the data codewords of a byte-mode message: mode 0100, the count (8 bits to version 9, 16 from 10), the bytes, a terminator, the pad bytes
function dataWords(bytes, version) {
    var bits = [];
    function put(v, n) {
        for (var i = n - 1; i >= 0; i--)
            bits.push((v >> i) & 1);
    }
    put(4, 4);
    put(bytes.length, version <= 9 ? 8 : 16);
    for (var i = 0; i < bytes.length; i++)
        put(bytes[i], 8);
    var cap = dataCapacity(version) * 8;
    put(0, Math.min(4, cap - bits.length));
    while (bits.length % 8 !== 0)
        bits.push(0);
    var words = [];
    for (var j = 0; j < bits.length; j += 8) {
        var w = 0;
        for (var k = 0; k < 8; k++)
            w = (w << 1) | bits[j + k];
        words.push(w);
    }
    for (var pad = 0xEC; words.length < dataCapacity(version); pad ^= 0xEC ^ 0x11)
        words.push(pad);
    return words;
}

// the data split into blocks, each given its ECC, then interleaved (data first, then ECC)
function codewords(data, version) {
    var groups = GROUPS[version], ec = EC_PER_BLOCK[version];
    var blocks = [], pos = 0;
    for (var g = 0; g < groups.length; g++)
        for (var b = 0; b < groups[g][0]; b++) {
            var d = data.slice(pos, pos + groups[g][1]);
            pos += groups[g][1];
            blocks.push({ data: d, ecc: rsRemainder(d, ec) });
        }
    var out = [], maxData = 0;
    for (var i = 0; i < blocks.length; i++)
        maxData = Math.max(maxData, blocks[i].data.length);
    for (var c = 0; c < maxData; c++)
        for (var j = 0; j < blocks.length; j++)
            if (c < blocks[j].data.length)
                out.push(blocks[j].data[c]);
    for (var e = 0; e < ec; e++)
        for (var k = 0; k < blocks.length; k++)
            out.push(blocks[k].ecc[e]);
    return out;
}

// ---- the matrix ----
function makeGrid(size) {
    var m = [], f = [];
    for (var y = 0; y < size; y++) {
        m.push([]);
        f.push([]);
        for (var x = 0; x < size; x++) {
            m[y].push(0);
            f[y].push(false);
        }
    }
    return { size: size, m: m, f: f };
}

function setFn(g, x, y, dark) {
    g.m[y][x] = dark ? 1 : 0;
    g.f[y][x] = true;
}

function drawFunction(g, version) {
    var n = g.size, x, y, i;
    for (i = 0; i < n; i++) {                       // timing
        setFn(g, 6, i, i % 2 === 0);
        setFn(g, i, 6, i % 2 === 0);
    }
    function finder(cx, cy) {
        for (var dy = -4; dy <= 4; dy++)
            for (var dx = -4; dx <= 4; dx++) {
                var d = Math.max(Math.abs(dx), Math.abs(dy)), xx = cx + dx, yy = cy + dy;
                if (xx >= 0 && xx < n && yy >= 0 && yy < n)
                    setFn(g, xx, yy, d !== 2 && d !== 4);
            }
    }
    finder(3, 3);
    finder(n - 4, 3);
    finder(3, n - 4);
    var a = ALIGN[version];
    for (var i1 = 0; i1 < a.length; i1++)
        for (var j1 = 0; j1 < a.length; j1++) {
            if ((i1 === 0 && j1 === 0) || (i1 === 0 && j1 === a.length - 1) || (i1 === a.length - 1 && j1 === 0))
                continue;
            for (var dy = -2; dy <= 2; dy++)
                for (var dx = -2; dx <= 2; dx++)
                    setFn(g, a[i1] + dx, a[j1] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }
    drawFormat(g, 0);                               // reserves the format areas (redrawn with the real mask)
    if (version >= 7) {
        var rem = version;
        for (i = 0; i < 12; i++)
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        var bits = (version << 12) | rem;
        for (i = 0; i < 18; i++) {
            var bit = ((bits >> i) & 1) === 1;
            var ax = n - 11 + (i % 3), ay = Math.floor(i / 3);
            setFn(g, ax, ay, bit);
            setFn(g, ay, ax, bit);
        }
    }
}

function drawFormat(g, mask) {
    var n = g.size, i;
    var data = (0 << 3) | mask;                     // ECC level M is 00
    var rem = data;
    for (i = 0; i < 10; i++)
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    var bits = ((data << 10) | rem) ^ 0x5412;
    function bit(k) { return ((bits >> k) & 1) === 1; }
    for (i = 0; i <= 5; i++)
        setFn(g, 8, i, bit(i));
    setFn(g, 8, 7, bit(6));
    setFn(g, 8, 8, bit(7));
    setFn(g, 7, 8, bit(8));
    for (i = 9; i < 15; i++)
        setFn(g, 14 - i, 8, bit(i));
    for (i = 0; i < 8; i++)
        setFn(g, n - 1 - i, 8, bit(i));
    for (i = 8; i < 15; i++)
        setFn(g, 8, n - 15 + i, bit(i));
    setFn(g, 8, n - 8, true);                       // the always-dark module
}

function drawData(g, words) {
    var n = g.size, i = 0, up = true;
    for (var right = n - 1; right >= 1; right -= 2) {
        if (right === 6)
            right = 5;
        for (var v = 0; v < n; v++) {
            var y = up ? n - 1 - v : v;
            for (var j = 0; j < 2; j++) {
                var x = right - j;
                if (!g.f[y][x]) {
                    var dark = false;
                    if (i < words.length * 8)
                        dark = ((words[i >> 3] >> (7 - (i & 7))) & 1) === 1;
                    g.m[y][x] = dark ? 1 : 0;
                    i++;
                }
            }
        }
        up = !up;
    }
}

function maskBit(mask, x, y) {
    switch (mask) {
    case 0: return (x + y) % 2 === 0;
    case 1: return y % 2 === 0;
    case 2: return x % 3 === 0;
    case 3: return (x + y) % 3 === 0;
    case 4: return (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0;
    case 5: return (x * y) % 2 + (x * y) % 3 === 0;
    case 6: return ((x * y) % 2 + (x * y) % 3) % 2 === 0;
    default: return ((x + y) % 2 + (x * y) % 3) % 2 === 0;
    }
}

function applyMask(g, mask) {
    for (var y = 0; y < g.size; y++)
        for (var x = 0; x < g.size; x++)
            if (!g.f[y][x] && maskBit(mask, x, y))
                g.m[y][x] ^= 1;
}

// the penalty of the standard: runs of five or more, 2x2 blocks, the 1:1:3:1:1 finder look-alike, the imbalance of dark and light
function penalty(g) {
    var n = g.size, m = g.m, result = 0, x, y;
    for (var pass = 0; pass < 2; pass++) {
        for (var a = 0; a < n; a++) {
            var run = 1;
            for (var b = 0; b < n; b++) {
                var cur = pass === 0 ? m[a][b] : m[b][a];
                var prev = b > 0 ? (pass === 0 ? m[a][b - 1] : m[b - 1][a]) : -1;
                if (b > 0 && cur === prev) {
                    run++;
                    if (run === 5)
                        result += 3;
                    else if (run > 5)
                        result++;
                }
                else {
                    run = 1;
                }
            }
        }
    }
    // finder-like patterns (N3), scanned straight: 40 each
    var pat1 = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0], pat2 = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
    for (y = 0; y < n; y++)
        for (x = 0; x + 11 <= n; x++) {
            var h1 = true, h2 = true;
            for (var k = 0; k < 11; k++) {
                if (m[y][x + k] !== pat1[k]) h1 = false;
                if (m[y][x + k] !== pat2[k]) h2 = false;
            }
            if (h1) result += 40;
            if (h2) result += 40;
            var v1 = true, v2 = true;
            for (var q = 0; q < 11; q++) {
                if (m[x + q][y] !== pat1[q]) v1 = false;
                if (m[x + q][y] !== pat2[q]) v2 = false;
            }
            if (v1) result += 40;
            if (v2) result += 40;
        }
    for (y = 0; y + 1 < n; y++)
        for (x = 0; x + 1 < n; x++) {
            var c = m[y][x];
            if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1])
                result += 3;
        }
    var dark = 0;
    for (y = 0; y < n; y++)
        for (x = 0; x < n; x++)
            dark += m[y][x];
    var total = n * n;
    var k2 = Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1;
    result += Math.max(0, k2) * 10;
    return result;
}

function copyGrid(g) {
    var c = makeGrid(g.size);
    for (var y = 0; y < g.size; y++)
        for (var x = 0; x < g.size; x++) {
            c.m[y][x] = g.m[y][x];
            c.f[y][x] = g.f[y][x];
        }
    return c;
}

// `forceMask` (0-7) skips the choice: a test's handle, and the fault the probe arms
function encode(text, forceMask) {
    var bytes = utf8(String(text));
    var version = 0;
    for (var v = 1; v <= MAX_VERSION; v++) {
        var needBits = 4 + (v <= 9 ? 8 : 16) + bytes.length * 8;
        if (Math.ceil(needBits / 8) <= dataCapacity(v)) {
            version = v;
            break;
        }
    }
    if (version === 0)
        return { ok: false, why: "too long for a version " + MAX_VERSION + " code (" + bytes.length + " bytes)" };
    var words = codewords(dataWords(bytes, version), version);
    var base = makeGrid(version * 4 + 17);
    drawFunction(base, version);
    drawData(base, words);
    var best = null, bestMask = 0, bestScore = 1e9;
    for (var mask = 0; mask < 8; mask++) {
        if (forceMask !== undefined && forceMask !== null && forceMask !== mask)
            continue;
        var g = copyGrid(base);
        applyMask(g, mask);
        drawFormat(g, mask);
        var s = penalty(g);
        if (s < bestScore) {
            best = g;
            bestMask = mask;
            bestScore = s;
        }
    }
    var rows = [];
    for (var y = 0; y < best.size; y++)
        rows.push(best.m[y].join(""));
    return { ok: true, version: version, mask: bestMask, size: best.size, rows: rows, bytes: bytes.length, penalty: bestScore };
}

function runs(code) {
    var out = [];
    if (!code || !code.ok)
        return out;
    for (var y = 0; y < code.size; y++) {
        var row = code.rows[y], x = 0;
        while (x < code.size) {
            if (row.charAt(x) !== "1") {
                x++;
                continue;
            }
            var s = x;
            while (x < code.size && row.charAt(x) === "1")
                x++;
            out.push([s, y, x - s]);
        }
    }
    return out;
}

function svgPath(code, m, ox, oy) {
    var r = runs(code), p = [];
    for (var i = 0; i < r.length; i++)
        p.push("M " + (ox + r[i][0] * m) + " " + (oy + r[i][1] * m) + " h " + (r[i][2] * m) + " v " + m + " h " + (-r[i][2] * m) + " z");
    return p.join(" ");
}

// ---- the join string (the de-facto standard every phone reads) ----
function wifiEscape(s) {
    // by hand, with the backslash as a char code: no regex to get a class wrong
    var t = String(s), out = "", bs = String.fromCharCode(92);
    for (var i = 0; i < t.length; i++) {
        var c = t.charAt(i);
        out += (c === bs || c === ";" || c === "," || c === ":" || c === '"') ? bs + c : c;
    }
    return out;
}

// a value that is all hex digits would be read as the hex of its own bytes: it travels in quotes
function wifiValue(s) {
    var e = wifiEscape(s);
    return /^[0-9A-Fa-f]+$/.test(String(s)) ? "\"" + e + "\"" : e;
}

function wifiString(ssid, psk, security, hidden) {
    var t;
    if (security === "open" || security === "owe")
        t = "nopass";
    else if (security === "wep")
        t = "WEP";
    else if (security === "eap")
        return "";
    else
        t = "WPA";
    var s = "WIFI:T:" + t + ";S:" + wifiValue(ssid) + ";";
    if (t !== "nopass")
        s += "P:" + wifiValue(psk) + ";";
    return s + "H:" + (hidden === true ? "true" : "false") + ";;";
}
