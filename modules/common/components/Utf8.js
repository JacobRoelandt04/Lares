.pragma library

// =============================================================================
// Utf8.js -- UTF-8 helpers for bytes QML hands over as ArrayBuffers
// (Process collectors, FileView.data()). QML has no TextDecoder/TextEncoder.
//
// Shared by LlmToolPolicy.js (which re-exports them for its callers) and the
// notes module, which decodes a note's bytes with the same strict decoder the
// LLM tool runner uses: an undecodable byte sets `invalid`, which is what
// makes a file "binary" -- a note that fails it opens read-only and is never
// written back.
// =============================================================================

// UTF-8 byte length of a JS string: the stdin about to be written, a
// stderr tail. A child's OUTPUT is never measured through this -- the runner
// counts the collector's own byte array and decodes it with utf8Decoder
// below (counting the re-encoded decoded text makes every undecodable byte
// three, and a multibyte character split across two pipe reads reads as
// U+FFFD, so a 64 KiB Japanese text file comes back "binary").
function utf8Length(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        if (c < 0x80) n += 1;
        else if (c < 0x800) n += 2;
        else if (c >= 0xD800 && c <= 0xDBFF) { n += 4; i++; }
        else n += 3;
    }
    return n;
}

// The longest prefix of `s` that fits in `maxBytes` of UTF-8, cut at a
// character (never inside a surrogate pair).
function utf8Prefix(s, maxBytes) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i);
        var w = (c < 0x80) ? 1 : (c < 0x800) ? 2 : (c >= 0xD800 && c <= 0xDBFF) ? 4 : 3;
        if (n + w > maxBytes) return s.substring(0, i);
        n += w;
        if (w === 4) i++;
    }
    return s;
}

function utf8Suffix(s, maxBytes) {
    var n = 0;
    for (var i = s.length - 1; i >= 0; i--) {
        var c = s.charCodeAt(i);
        var w;
        if (c >= 0xDC00 && c <= 0xDFFF) { w = 4; i--; }
        else w = (c < 0x80) ? 1 : (c < 0x800) ? 2 : 3;
        if (n + w > maxBytes) return s.substring(i + (w === 4 ? 2 : 1));
        n += w;
    }
    return s;
}

// A stateful UTF-8 decoder over Uint8Array chunks (QML has no TextDecoder).
//   var d = utf8Decoder();  d.push(u8, true) -> the text of this chunk
// An incomplete sequence at the END of a chunk is held (`d.pending` bytes)
// and completed by the next chunk, so a character split across two pipe
// reads decodes whole. A byte that cannot start or continue a sequence sets
// `d.invalid` (that is what "binary" means) and decodes as U+FFFD. Bytes
// held at the very end of the stream are a character the child cut in half
// (`head -c` on a multibyte file): not invalid, not shown, still counted.
// push(u8, false) validates without building text. ASCII runs go through
// fromCharCode.apply in slices, so a flood costs one call per 4 KiB.
function utf8Decoder() {
    var d = { need: 0, cp: 0, lower: 0x80, upper: 0xBF, pending: 0, invalid: false };
    d.push = function (u8, wantText) {
        var out = wantText ? [] : null;
        var n = u8.length;
        var i = 0;
        while (i < n) {
            if (d.need === 0) {
                // A run of ASCII.
                var a = i;
                while (i < n && u8[i] < 0x80) i++;
                if (i > a && wantText) {
                    // A plain array: QJS's apply over a typed-array view
                    // reads every element as undefined (NULs, measured).
                    for (var s = a; s < i; s += 4096) {
                        var end = Math.min(i, s + 4096);
                        var arr = new Array(end - s);
                        for (var k = s; k < end; k++) arr[k - s] = u8[k];
                        out.push(String.fromCharCode.apply(null, arr));
                    }
                }
                if (i >= n) break;
                var b = u8[i++];
                if (b >= 0xC2 && b <= 0xDF) { d.need = 1; d.cp = b & 0x1F; }
                else if (b >= 0xE0 && b <= 0xEF) {
                    d.need = 2; d.cp = b & 0x0F;
                    d.lower = (b === 0xE0) ? 0xA0 : 0x80;
                    d.upper = (b === 0xED) ? 0x9F : 0xBF;
                } else if (b >= 0xF0 && b <= 0xF4) {
                    d.need = 3; d.cp = b & 0x07;
                    d.lower = (b === 0xF0) ? 0x90 : 0x80;
                    d.upper = (b === 0xF4) ? 0x8F : 0xBF;
                } else {
                    d.invalid = true;
                    if (wantText) out.push("\uFFFD");
                    continue;
                }
                d.pending = 1;
                continue;
            }
            var c = u8[i];
            if (c < d.lower || c > d.upper) {
                // Not a continuation: the sequence so far was bad; this byte
                // is re-read as a lead byte.
                d.invalid = true;
                d.need = 0; d.pending = 0; d.lower = 0x80; d.upper = 0xBF;
                if (wantText) out.push("\uFFFD");
                continue;
            }
            i++;
            d.cp = (d.cp << 6) | (c & 0x3F);
            d.pending++;
            d.lower = 0x80; d.upper = 0xBF;
            if (--d.need === 0) {
                d.pending = 0;
                if (wantText) {
                    var cp = d.cp;
                    if (cp < 0x10000) out.push(String.fromCharCode(cp));
                    else { cp -= 0x10000; out.push(String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))); }
                }
            }
        }
        return wantText ? out.join("") : "";
    };
    return d;
}

// Concatenate Uint8Array pieces.
function concatBytes(parts, total) {
    var out = new Uint8Array(total);
    var at = 0;
    for (var i = 0; i < parts.length; i++) { out.set(parts[i], at); at += parts[i].length; }
    return out;
}

// The offset of the first byte in `u8` that can START a sequence (a lead
// byte or ASCII): where a tail buffer that begins mid-character may be read
// from. Continuation bytes are 0x80..0xBF.
function firstCharStart(u8) {
    var i = 0;
    while (i < u8.length && u8[i] >= 0x80 && u8[i] <= 0xBF) i++;
    return i;
}
