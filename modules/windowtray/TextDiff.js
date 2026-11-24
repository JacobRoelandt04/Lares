.pragma library

// =============================================================================
// TextDiff.js -- what changed between two strings, in characters a reader sees.
//
//   graphemes(s)        -> [string]   user-perceived characters
//   diffPlan(from, to)  -> null | { pre, oldMid, newMid, tail }
//
// A morph that moves only what changed (TextMorph) must never cut a character
// in two: half a surrogate pair renders as a replacement box, a flag cut
// between its two regional indicators is two letters, a family emoji cut at a
// ZWJ is three people. So the diff is taken on GRAPHEMES, not UTF-16 units.
//
// THE CLUSTER RULE is a working subset of UAX #29 (Qt's V4 has no
// Intl.Segmenter): a code point JOINS the cluster before it when it is
//   - a combining mark (the Mn/Mc/Me blocks below, or \p{M} where the regex
//     engine knows it), a variation selector, an emoji skin-tone modifier,
//     a tag character or the combining keycap;
//   - a ZERO WIDTH JOINER, and so is whatever follows a ZWJ;
//   - the second regional indicator of a pair (a flag);
//   - LF after CR.
// Everything else starts a new cluster. Hangul syllable composition and the
// Indic conjunct rules are not modelled: a title is rarely there, and the
// worst case is a morph that moves one jamo less than it could.
//
// diffPlan: the longest common prefix and suffix of the two grapheme lists,
// the suffix never overlapping the prefix. pre + oldMid + tail === from and
// pre + newMid + tail === to, always. null when the strings are equal.
//
// Pure, no Qt: it loads under node.
// =============================================================================

var _markRe = null;
try {
    _markRe = new RegExp("^\\p{M}$", "u");
} catch (e) {
    _markRe = null;
}

function _isMark(cp) {
    if (_markRe !== null) {
        try {
            if (_markRe.test(String.fromCodePoint(cp)))
                return true;
        } catch (e) {
            // fall through to the ranges
        }
    }
    return (cp >= 0x0300 && cp <= 0x036F) || (cp >= 0x0483 && cp <= 0x0489)
        || (cp >= 0x0591 && cp <= 0x05BD) || (cp >= 0x0610 && cp <= 0x061A)
        || (cp >= 0x064B && cp <= 0x065F) || (cp >= 0x0900 && cp <= 0x0903)
        || (cp >= 0x093A && cp <= 0x094F) || (cp >= 0x1AB0 && cp <= 0x1AFF)
        || (cp >= 0x1DC0 && cp <= 0x1DFF) || (cp >= 0x20D0 && cp <= 0x20FF)
        || (cp >= 0xFE20 && cp <= 0xFE2F);
}

function _extends(cp) {
    return _isMark(cp)
        || (cp >= 0xFE00 && cp <= 0xFE0F)        // variation selectors
        || (cp >= 0xE0100 && cp <= 0xE01EF)      // variation selectors supplement
        || (cp >= 0x1F3FB && cp <= 0x1F3FF)      // skin tones
        || (cp >= 0xE0020 && cp <= 0xE007F)      // tags (subdivision flags)
        || cp === 0x20E3;                        // combining keycap
}

function _isRegional(cp) {
    return cp >= 0x1F1E6 && cp <= 0x1F1FF;
}

// The code points of s, each as [codePoint, string].
function _codePoints(s) {
    var out = [];
    var i = 0;
    while (i < s.length) {
        var c = s.charCodeAt(i);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
            var d = s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) {
                out.push([(c - 0xD800) * 0x400 + (d - 0xDC00) + 0x10000, s.substring(i, i + 2)]);
                i += 2;
                continue;
            }
        }
        out.push([c, s.charAt(i)]);
        i += 1;
    }
    return out;
}

function graphemes(s) {
    s = s === undefined || s === null ? "" : String(s);
    var cps = _codePoints(s);
    var out = [];
    var prev = -1;           // the previous code point
    var joinNext = false;    // the previous code point was a ZWJ
    var riOpen = false;      // the cluster is a single regional indicator so far
    for (var k = 0; k < cps.length; k++) {
        var cp = cps[k][0];
        var str = cps[k][1];
        var join = out.length > 0 && (
            joinNext
            || cp === 0x200D
            || _extends(cp)
            || (riOpen && _isRegional(cp))
            || (prev === 0x0D && cp === 0x0A));
        if (join) {
            out[out.length - 1] += str;
            riOpen = false;
        } else {
            out.push(str);
            riOpen = _isRegional(cp);
        }
        joinNext = cp === 0x200D;
        prev = cp;
    }
    return out;
}

function diffPlan(from, to) {
    from = from === undefined || from === null ? "" : String(from);
    to = to === undefined || to === null ? "" : String(to);
    if (from === to)
        return null;
    var a = graphemes(from);
    var b = graphemes(to);
    var n = Math.min(a.length, b.length);
    var p = 0;
    while (p < n && a[p] === b[p])
        p++;
    var q = 0;
    while (q < n - p && a[a.length - 1 - q] === b[b.length - 1 - q])
        q++;
    return {
        pre: a.slice(0, p).join(""),
        oldMid: a.slice(p, a.length - q).join(""),
        newMid: b.slice(p, b.length - q).join(""),
        tail: a.slice(a.length - q).join("")
    };
}
