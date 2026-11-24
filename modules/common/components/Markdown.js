// =============================================================================
// Markdown.js
//
// Markdown -> HTML, in JS, block by block. This exists because
// `textFormat: MarkdownText` re-parses the WHOLE document on every append:
// 1.19 ms at 10 KB, 5.30 ms at 30 KB, measured on this machine, and ablating
// visibility, wrap, a fixed height and the Flickable ancestor changed none of
// it. A streaming answer that grows to 30 KB would spend the last thousand
// tokens re-laying-out everything it had already drawn.
//
// So the view renders one small document per block and only ever touches the
// last one. That only works if the parser can be handed the TAIL of the source
// and still agree with a parse of the whole thing, which is what shapes this
// file:
//
//   * `parseBlocks` is a pure function of the string it is given. Offsets are
//     relative to that string, and `end` includes the block's trailing
//     newline(s), so a caller can advance a `stableLen` cursor by the last
//     final block's `end` and re-parse only what is after it.
//
//   * `complete` is the promise "appending characters to this source cannot
//     change this block". It is false for anything whose terminator has not
//     been seen yet: an unterminated fence, a heading whose newline has not
//     arrived, a paragraph that has not been closed by a blank line, and --
//     the subtle one -- a paragraph closed by a line that is itself still
//     growing ("para\n#" is a paragraph plus a heading; "para\n#x" is one
//     paragraph). A block that is frozen on a bad promise is a block the view
//     can never correct, so the rule is conservative: the TERMINATING line
//     must already carry its newline.
//
//   * Nothing here throws. A lexer or a parse that hits something unforeseen
//     falls back to unstyled text, because a raised exception inside a QML
//     binding kills the rest of the callback silently.
//
// Not a `.pragma library`: `Qt.rgba` and friends live on the QML global
// object, which a shared library context does not have (see Mix.js), and this
// file may grow to want them.
//
// Colours never appear here as Theme reads -- they arrive as "#rrggbb"
// strings in `opt` / `palette`, chosen by the component that owns the theme.
// =============================================================================

// ---- Block model ------------------------------------------------------------
//   { kind, start, end, complete, ... }
//   kind: "para" | "head" | "list" | "quote" | "code" | "table" | "rule" | "math"
//   head  : + level (1..6), text
//   list  : + ordered, listStart, items ([{ text, depth, checked|null, ordered }])
//           (listStart, not `start`: `start` is already the source offset)
//   code  : + lang, code
//   table : + head ([string]), rows ([[string]]), align (["left"|"right"|"center"|""])
//   quote : + text  (inner markdown, quote markers stripped)
//   para  : + text
//   math  : + tex, delim ("$$" | "\\["): a display formula on lines of its own
//           (inline `$..$`, `\\(..\\)` and a `$$..$$` inside a sentence are INLINE: see _mathAt)
// -----------------------------------------------------------------------------

var RE_ATX     = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/;
var RE_FENCE   = /^ {0,3}(`{3,}|~{3,})[ \t]*(.*)$/;
var RE_FENCE_ANY = /^[ \t]*(`{3,}|~{3,})[ \t]*(.*)$/;      // a fence under a list item, indented as far as the item
var RE_RULE    = /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/;
var RE_QUOTE   = /^ {0,3}>/;
var RE_ITEM    = /^([ \t]*)([-*+\u2022\u25e6\u25aa\u2023]|\d{1,9}[.)])(?:([ \t]+)(.*)|())$/;
var RE_SETEXT1 = /^ {0,3}=+[ \t]*$/;
var RE_SETEXT2 = /^ {0,3}-+[ \t]*$/;
var RE_TDELIM  = /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;
var RE_INDENT  = /^(?: {4}|\t)/;
var RE_AUTOLINK = /https?:\/\/[^\s<>()\[\]{}"'`]+/g;
var RE_MATHOPEN = /^ {0,3}(\$\$|\\\[)/;
var RE_IMGONLY  = /^!\[([^\]]*)\]\(\s*(<[^<>\n]*>|[^\s)<]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)$/;   // a destination with spaces is written <like this>

// A heading's size over the body's, per level. `opt.headScale` multiplies the
// STEP above 1 (so 0 puts every heading at body size and 1 is this table).
var HEAD_SCALE = { 1: 1.5, 2: 1.3, 3: 1.15, 4: 1.05, 5: 1.0, 6: 1.0 };
function headPx(sizePx, level, headScale) {
    var s = headScale === undefined || headScale === null ? 1 : headScale;
    return (sizePx || 12) * (1 + ((HEAD_SCALE[level] || 1) - 1) * s);
}

// =============================================================================
// Lines
// =============================================================================

function _lines(src) {
    var out = [];
    var i = 0;
    var n = src.length;
    while (true) {
        var j = src.indexOf("\n", i);
        var nl = j >= 0;
        if (!nl) j = n;
        var e = j;
        if (e > i && src.charCodeAt(e - 1) === 13) e--;   // \r\n
        out.push({ start: i, text: src.substring(i, e), nl: nl });
        if (!nl) break;
        i = j + 1;
    }
    // A trailing empty line with no newline of its own is not a line: it is
    // the spot the next character will land in. Dropping it is exactly what
    // makes an appended character continue the previous paragraph instead of
    // being read as the blank line that ends it.
    if (out.length > 1 && !out[out.length - 1].nl && out[out.length - 1].text === "")
        out.pop();
    return out;
}

function _blank(l) { return l.text.trim().length === 0; }

function _indentOf(t) {
    var w = 0;
    for (var i = 0; i < t.length; i++) {
        var c = t.charAt(i);
        if (c === " ") w += 1;
        else if (c === "\t") w += 4 - (w % 4);
        else break;
    }
    return w;
}

// Does this line open a block of its own? A paragraph, a list item's lazy
// continuation and a blockquote's all stop here.
function _startsBlock(t) {
    if (RE_ATX.test(t)) return true;
    if (RE_RULE.test(t)) return true;
    if (RE_QUOTE.test(t)) return true;
    if (RE_MATHOPEN.test(t)) return true;
    if (RE_ITEM.test(t) && _indentOf(t) < 4) return true;
    var mf = RE_FENCE.exec(t);
    if (mf && !(mf[1].charAt(0) === "`" && mf[2].indexOf("`") >= 0)) return true;
    return false;
}

// =============================================================================
// parseBlocks
// =============================================================================

function parseBlocks(src) {
    try {
        return _parseBlocks(String(src === undefined || src === null ? "" : src));
    } catch (e) {
        // Never throw at a caller inside a binding. One incomplete paragraph
        // is a truthful degradation: the view re-parses it on the next token.
        var s = String(src || "");
        return s.length ? [{ kind: "para", start: 0, end: s.length, complete: false, text: s }] : [];
    }
}

function _parseBlocks(src) {
    var L = _lines(src);
    var n = L.length;
    var out = [];
    var i = 0;
    while (i < n) {
        if (_blank(L[i])) { i++; continue; }
        var r = _blockAt(src, L, i);
        out.push(r.block);
        i = r.next > i ? r.next : i + 1;   // belt and braces: never stall
        // A list that ended at a fence inside one of its items: the code block is its own block (the view draws
        // it full width, with its copy button), however far the fence was indented under the item.
        while (r.fenceAt !== undefined && r.fenceAt === i && i < n) {
            var mf2 = RE_FENCE_ANY.exec(L[i].text);
            if (!mf2) break;
            r = _fenceBlock(src, L, i, mf2);
            out.push(r.block);
            i = r.next > i ? r.next : i + 1;
            // the list's own items go on after it: a new list, numbered by its own markers
        }
    }
    return out;
}

// Close a block: `le` is the first line NOT in it. Trailing blank lines are
// swallowed into `end` so that block[k].end === block[k+1].start and a caller
// advancing a cursor by `end` lands exactly on the next block.
function _close(blk, src, L, ls, le, forced) {
    var n = L.length;
    // Terminated == the line that ends this block already carries its own
    // newline. Without that test "para\n#" freezes as para + heading and then
    // "para\n#x" is one paragraph, and the frozen half can never be taken back.
    var term = (forced !== undefined) ? forced : (le < n && L[le].nl === true);
    var k = le;
    while (k < n && _blank(L[k])) k++;
    blk.start = L[ls].start;
    blk.end = (k < n) ? L[k].start : src.length;
    blk.complete = term;
    return { block: blk, next: k };
}

function _blockAt(src, L, i) {
    var n = L.length;
    var t = L[i].text;

    // ---- fenced code ----
    var mf = RE_FENCE.exec(t);
    if (mf && !(mf[1].charAt(0) === "`" && mf[2].indexOf("`") >= 0))
        return _fenceBlock(src, L, i, mf);

    // ---- display math: `$$ .. $$` or `\[ .. \]` on lines of its own ----
    var mm = RE_MATHOPEN.exec(t);
    if (mm) {
        var mr = _mathBlock(src, L, i, mm[1], t.substring(mm[0].length));
        if (mr) return mr;
    }

    // ---- ATX heading ----
    var mh = RE_ATX.exec(t);
    if (mh) {
        var htext = (mh[2] || "").replace(/[ \t]+#+[ \t]*$/, "").replace(/^#+[ \t]*$/, "");
        return _close({ kind: "head", level: mh[1].length, text: htext },
                      src, L, i, i + 1, L[i].nl === true);
    }

    // ---- thematic break (before lists: "* * *" is not three list items) ----
    if (RE_RULE.test(t))
        return _close({ kind: "rule" }, src, L, i, i + 1, L[i].nl === true);

    // ---- GFM table: a pipe row whose next line is an alignment row with the
    //      same number of cells. The cell count is what keeps "a | b" over
    //      "---" reading as a setext heading rather than a one-column table.
    if (t.indexOf("|") >= 0 && i + 1 < n && RE_TDELIM.test(L[i + 1].text)) {
        var head = _cells(t);
        var dcells = _cells(L[i + 1].text);
        if (dcells.length === head.length) {
            var align = [];
            for (var a = 0; a < dcells.length; a++) align.push(_alignOf(dcells[a]));
            var rows = [];
            var r = i + 2;
            while (r < n && !_blank(L[r]) && L[r].text.indexOf("|") >= 0 && !RE_ATX.test(L[r].text)) {
                var cs = _cells(L[r].text);
                while (cs.length < head.length) cs.push("");
                if (cs.length > head.length) cs = cs.slice(0, head.length);
                rows.push(cs);
                r++;
            }
            return _close({ kind: "table", head: head, rows: rows, align: align }, src, L, i, r);
        }
    }

    // ---- blockquote ----
    if (RE_QUOTE.test(t)) {
        var qs = [];
        var q = i;
        while (q < n) {
            if (RE_QUOTE.test(L[q].text)) {
                qs.push(L[q].text.replace(/^ {0,3}> ?/, ""));
            } else if (q > i && !_blank(L[q]) && !_startsBlock(L[q].text)) {
                qs.push(L[q].text);            // lazy continuation
            } else break;
            q++;
        }
        return _close({ kind: "quote", text: qs.join("\n") }, src, L, i, q);
    }

    // ---- list ----
    if (_indentOf(t) < 4 && RE_ITEM.test(t))
        return _listAt(src, L, i);

    // ---- indented code ----
    if (RE_INDENT.test(t)) {
        var ce = i;
        var lastContent = i;
        while (ce < n && (RE_INDENT.test(L[ce].text) || _blank(L[ce]))) {
            if (!_blank(L[ce])) lastContent = ce;
            ce++;
        }
        var cl = [];
        for (var ci = i; ci <= lastContent; ci++) cl.push(_stripIndent(L[ci].text, 4));
        return _close({ kind: "code", lang: "", code: cl.join("\n") }, src, L, i, lastContent + 1);
    }

    // ---- paragraph (and setext heading, which is a paragraph plus a rule) ----
    var p = i;
    var setext = 0;
    var ptext = [];
    while (p < n) {
        if (p > i) {
            if (_blank(L[p])) break;
            if (RE_SETEXT1.test(L[p].text)) { setext = 1; break; }
            if (RE_SETEXT2.test(L[p].text)) { setext = 2; break; }  // wins over `rule`
            if (_startsBlock(L[p].text)) break;
        }
        ptext.push(L[p].text.trim());
        p++;
    }
    if (setext > 0)
        return _close({ kind: "head", level: setext, text: ptext.join(" ") },
                      src, L, i, p + 1, L[p].nl === true);
    return _close({ kind: "para", text: ptext.join("\n") }, src, L, i, p);
}

// A fenced code block opened by `mf` (a match of RE_FENCE / RE_FENCE_ANY) on line i.
function _fenceBlock(src, L, i, mf) {
    var n = L.length;
    var t = L[i].text;
    var marker = mf[1].charAt(0);
    var need = mf[1].length;
    var info = (mf[2] || "").trim();
    var lang = info.split(/[\s,]+/)[0] || "";
    var strip = _indentOf(t);
    var body = [];
    var j = i + 1;
    var closed = false;
    while (j < n) {
        if (_isFenceClose(L[j].text, marker, need)) { closed = true; break; }
        body.push(_stripIndent(L[j].text, strip));
        j++;
    }
    var blk = { kind: "code", lang: lang, code: body.join("\n") };
    if (!closed) return _close(blk, src, L, i, n, false);
    // A closing fence without its newline can still grow into something
    // that is not a fence at all ("```" -> "```x").
    return _close(blk, src, L, i, j + 1, L[j].nl === true);
}

// ---- display math ------------------------------------------------------------
//
// `$$` or `\[` opens, the same delimiter closes (`$$` / `\]`), and the closing line holds nothing after
// it: a sentence that merely CONTAINS `$$x$$` is a paragraph, and the inline pass draws the formula in it.
// The block runs over non-blank lines only. When the end of the source arrives before the closer the
// whole stretch is ONE INCOMPLETE paragraph, never frozen: its lines may look like anything ("- x", "# y",
// "+ z" are fine inside a formula) and must not be cut into blocks that can never be taken back; the
// source stays on screen as text until the closer has come. Returns null for "not a display formula":
// the caller reads the line as a paragraph.
function _mathBlock(src, L, i, open, rest) {
    var n = L.length;
    var close = open === "$$" ? "$$" : "\\]";
    var body = rest;
    var j = i;
    var at = body.indexOf(close);
    while (at < 0) {
        j++;
        if (j >= n) {
            var all = [];
            for (var q = i; q < n; q++) all.push(L[q].text.trim());
            return _close({ kind: "para", text: all.join("\n") }, src, L, i, n, false);
        }
        if (_blank(L[j])) return null;
        body += "\n" + L[j].text;
        at = body.indexOf(close, Math.max(0, body.length - L[j].text.length));
    }
    if (body.substring(at + close.length).trim().length > 0) return null;
    var tex = body.substring(0, at).trim();
    if (tex.length === 0) return null;
    return _close({ kind: "math", tex: tex, delim: open }, src, L, i, j + 1, L[j].nl === true);
}

// ---- inline math ------------------------------------------------------------
//
// `\(..\)`, `\[..\]`, `$$..$$` and `$..$`. The dollar is also a currency sign, and a conversation about
// stocks is full of "$5 and $10", so the single dollar follows pandoc's rules: the opener is not followed
// by a space, the closer is not preceded by one and not followed by a digit, and no other `$` lies between
// (so "$5, and $x$" is the pair `$x$`, never "5, and "). One more, pandoc's gap: a body that starts with a
// digit and contains a WORD ("$5 and 7$") is a sentence, not a formula. Returns {end, tex, display} or null.
function _mathAt(t, i) {
    var c = t.charAt(i);
    var n1 = t.charAt(i + 1);
    var k;
    if (c === "\\") {
        if (n1 === "(") { k = t.indexOf("\\)", i + 2); return _mathSpan(t, i, k, 2, false); }
        if (n1 === "[") { k = t.indexOf("\\]", i + 2); return _mathSpan(t, i, k, 2, true); }
        return null;
    }
    if (c !== "$") return null;
    if (n1 === "$") {
        k = t.indexOf("$$", i + 2);
        var dd = _mathSpan(t, i, k, 2, true);
        return dd ? dd : { end: i + 2, tex: null };       // "$$" with no partner: two literal dollars
    }
    if (n1 === "" || n1 === " " || n1 === "\t" || n1 === "\n") return null;
    var j = i + 1;
    while (j < t.length) {
        var cj = t.charAt(j);
        if (cj === "\\") { j += 2; continue; }
        if (cj === "$") break;
        j++;
    }
    if (j >= t.length) return null;
    var prev = t.charAt(j - 1);
    if (prev === " " || prev === "\t" || prev === "\n") return null;
    if (/[0-9]/.test(t.charAt(j + 1))) return null;
    var body = t.substring(i + 1, j);
    if (/\n[ \t]*\n/.test(body)) return null;
    if (/^[0-9]/.test(body) && /[A-Za-z]{2,}/.test(body.replace(/\\[A-Za-z]+/g, "").replace(/\\(?:text|mathrm|mbox)\{[^{}]*\}/g, "")))
        return null;
    return { end: j + 1, tex: body.trim(), display: false };
}

function _mathSpan(t, i, k, w, display) {
    if (k < 0) return null;
    var tex = t.substring(i + w, k).trim();
    if (tex.length === 0 || /\n[ \t]*\n/.test(tex)) return null;
    return { end: k + w, tex: tex, display: display };
}

// A formula in a sentence. The host's `opt.math` answers for the picture (see MarkdownView._mathOf); with no
// host, or no picture yet, or a formula mathtext cannot read, the source shows as code -- never an error.
// The picture itself is drawn by an overlay on a transparent PLACEHOLDER image of its size (MathOverlays):
// a TextEdit cannot tint an <img>, and the tint is what lets a theme switch re-render nothing. `n` is the
// placeholder's ordinal among ALL images of the block, the overlay's way to find its character.
function _mathHtml(tex, display, opt) {
    var m = opt && opt.math;
    var k = (m && m.k) || 1;
    var cur = (opt && (opt.cur || opt.sizePx)) || 12;
    var r = (m && opt.acc) ? m.lookup(tex, display, cur / k) : null;
    if (!r || r.state !== "ok") return _codeSpan(tex, opt);
    // The placeholder is laid out in the EDIT's pixels (`k` x the logical ones when the view is magnified);
    // the record keeps the picture's own logical size, which is what the overlay is drawn at. It reserves the
    // picture's room with up to two images, measured on Qt 6.12:
    //   * the MAIN image is as wide as the picture and as tall as its part ABOVE the baseline; a default
    //     image sits on the baseline, so the line grows upward by exactly that;
    //   * when the part BELOW the baseline (`D`) is deeper than the font's own descent (`fd`), a second
    //     ONE-pixel image with `vertical-align:top` makes the line taller. A top-aligned image taller than
    //     the rest of the line (ascent `a` = the larger of the font's ascent and the main image, descent `fd`)
    //     leaves the surplus split EVENLY above and below the text, so a height of `a + 2D - fd` brings the
    //     line's descent to exactly D (and its ascent up by D - fd, which is harmless air). A
    //     `vertical-align:middle` image looks the obvious choice and is not: its centre sits where the font's
    //     middle is only while it is small, and drifts as it grows.
    // The line then ends D below the baseline, so MathOverlays finds the baseline from the line's bottom.
    var above = Math.max(1, Math.ceil((r.h - r.d) * k - 0.01));
    var below = Math.ceil(r.d * k - 0.01);
    var wid = Math.max(1, Math.ceil(r.w * k));
    var fm = m.fm ? m.fm(cur) : [0, 0];
    var tall = below > fm[1] ? Math.ceil(Math.max(fm[0], above) + 2 * below - fm[1]) : 0;
    opt.acc.math.push({ n: opt.acc.imgs, u: r.url, w: r.w, h: r.h, d: r.d, dd: tall > 0 ? below : 0, px: cur, t: tex });
    opt.acc.imgs += tall > 0 ? 2 : 1;
    var src = _attr(m.blank);
    return "<img src=\"" + src + "\" width=\"" + (tall > 0 ? Math.max(1, wid - 1) : wid) + "\" height=\"" + above + "\">"
         + (tall > 0 ? "<img src=\"" + src + "\" width=\"1\" height=\"" + tall + "\" style=\"vertical-align:top;\">" : "");
}

// A list is one list only while its marker keeps its shape: "-" and "*" are
// different lists, and so are "1." and "1)". CommonMark says so, and it is the
// only thing separating a bulleted list from the numbered one after it.
function _markerType(marker) {
    return /\d/.test(marker.charAt(0)) ? ("n" + marker.charAt(marker.length - 1)) : marker;
}

function _isFenceClose(t, marker, need) {
    var k = 0;
    while (k < t.length && (t.charAt(k) === " " || t.charAt(k) === "\t")) k++;
    var c = 0;
    while (k + c < t.length && t.charAt(k + c) === marker) c++;
    if (c < need) return false;
    return t.substring(k + c).trim().length === 0;
}

function _stripIndent(t, w) {
    var i = 0, col = 0;
    while (i < t.length && col < w) {
        var c = t.charAt(i);
        if (c === " ") { col += 1; i++; }
        else if (c === "\t") { col += 4 - (col % 4); i++; }
        else break;
    }
    return t.substring(i);
}

// ---- list scanning ----------------------------------------------------------
//
// Depth comes from the indent column, through a stack rather than a division:
// "*   a" indents its continuation to column 4, "1.  b" to column 4 as well,
// and a hard-coded "two spaces is one level" gets both wrong. A new indent
// counts as deeper only when it is at least 2 columns past the level it sits
// under, so a stray single space does not invent a level.
function _listAt(src, L, i) {
    var n = L.length;
    var stack = [];
    var items = [];
    var first = RE_ITEM.exec(L[i].text);
    var ordered = /\d/.test(first[2].charAt(0));
    // NOT `start`: the block model already uses `start` for the offset into
    // the source, and the offset is what the streaming cursor runs on. The
    // first ordinal of an ordered list lives in `listStart`.
    var startNo = ordered ? (parseInt(first[2], 10) || 1) : 1;
    var firstType = _markerType(first[2]);
    var j = i;
    var cur = null;
    var contentCol = 0;
    var fenceAt;
    while (j < n) {
        var t = L[j].text;
        if (_blank(L[j])) {
            // A blank line ends the list unless an indented line follows: that
            // is a loose list, not the end of one.
            var k = j + 1;
            while (k < n && _blank(L[k])) k++;
            if (k < n && (_indentOf(L[k].text) >= 2 || (RE_ITEM.test(L[k].text) && _indentOf(L[k].text) < 4))) { j = k; continue; }
            break;
        }
        var m = RE_ITEM.exec(t);
        var ind = _indentOf(t);
        if (m && ind < contentCol + 4) {
            // Work the depth out on a copy first: a top-level item whose
            // marker type changed ("- a" then "1. b") starts a NEW list, and
            // that decision has to be taken before the stack is mutated.
            var st = stack.slice();
            while (st.length > 0 && ind <= st[st.length - 1] - 2) st.pop();
            if (st.length === 0 || ind >= st[st.length - 1] + 2) st.push(ind);
            var depth = st.length - 1;
            var mtype = _markerType(m[2]);
            if (depth === 0 && mtype !== firstType) break;
            stack = st;
            var body = (m[4] === undefined ? "" : m[4]);
            var checked = null;
            var task = /^\[([ xX])\][ \t]+(.*)$/.exec(body);
            if (task) { checked = task[1] !== " "; body = task[2]; }
            cur = { text: body, depth: depth, checked: checked,
                    ordered: /\d/.test(m[2].charAt(0)) };
            items.push(cur);
            contentCol = ind + m[2].length + ((m[3] || " ").length);
            j++;
            continue;
        }
        if (cur !== null && ind >= contentCol && RE_FENCE_ANY.test(t)
            && !(RE_FENCE_ANY.exec(t)[1].charAt(0) === "`" && RE_FENCE_ANY.exec(t)[2].indexOf("`") >= 0)) {
            fenceAt = j;                        // the item's code block is a block of its own
            break;
        }
        if (cur !== null && (ind >= contentCol || !_startsBlock(t))) {
            cur.text += (cur.text.length ? " " : "") + t.trim();   // continuation
            j++;
            continue;
        }
        break;
    }
    var lr = _close({ kind: "list", ordered: ordered, listStart: startNo, items: items },
                    src, L, i, j);
    if (fenceAt !== undefined) lr.fenceAt = fenceAt;
    return lr;
}

// ---- table cells ------------------------------------------------------------
function _cells(line) {
    var s = line.trim();
    if (s.charAt(0) === "|") s = s.substring(1);
    if (s.length > 0 && s.charAt(s.length - 1) === "|" && s.charAt(s.length - 2) !== "\\")
        s = s.substring(0, s.length - 1);
    var out = [];
    var cur = "";
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        if (c === "\\" && s.charAt(i + 1) === "|") { cur += "|"; i++; continue; }
        if (c === "|") { out.push(cur.trim()); cur = ""; continue; }
        cur += c;
    }
    out.push(cur.trim());
    return out;
}

function _alignOf(cell) {
    var s = cell.trim();
    var l = s.charAt(0) === ":";
    var r = s.charAt(s.length - 1) === ":";
    if (l && r) return "center";
    if (r) return "right";
    if (l) return "left";
    return "";
}

// =============================================================================
// Inline
// =============================================================================

function escapeHtml(s) {
    // & < > only. Spaces stay literal: a `white-space:pre` wrapper is what
    // preserves runs of them in code, and &nbsp; drifts because a font
    // promises nothing about the advance of U+00A0 (a progress bar set with it
    // walks sideways).
    s = String(s === undefined || s === null ? "" : s);
    var out = "";
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        if (c === "&") out += "&amp;";
        else if (c === "<") out += "&lt;";
        else if (c === ">") out += "&gt;";
        else out += c;
    }
    return out;
}

function _attr(s) {
    return escapeHtml(s).replace(/"/g, "&quot;");
}

function _isWordChar(c) { return c >= "a" && c <= "z" || c >= "A" && c <= "Z" || c >= "0" && c <= "9"; }

// `opt` is optional everywhere: without it the fragment is plain <b>/<i>/
// <code>/<a> and inherits whatever the document says.
function inlineHtml(text, opt) {
    try { return _inline(String(text === undefined || text === null ? "" : text), opt || {}); }
    catch (e) { return escapeHtml(text); }
}

function _inline(t, opt) {
    var out = "";
    var i = 0;
    var n = t.length;
    while (i < n) {
        var c = t.charAt(i);

        if (c === "$" || (c === "\\" && (t.charAt(i + 1) === "(" || t.charAt(i + 1) === "["))) {
            var mi = _mathAt(t, i);
            if (mi) {
                out += mi.tex === null ? "$$" : _mathHtml(mi.tex, mi.display, opt);
                i = mi.end; continue;
            }
        }

        if (c === "&") {
            var me = RE_ENTITY.exec(t.substring(i, i + 12));
            if (me) {
                var dec = _entity(me[1]);
                if (dec !== null) { out += escapeHtml(dec); i += me[0].length; continue; }
            }
        }

        if (c === "<") {
            var ma = RE_ANGLE_URL.exec(t.substring(i, i + 400));
            if (ma) {
                out += "<a href=\"" + _attr(ma[1]) + "\""
                     + (opt.linkColor ? " style=\"color:" + opt.linkColor + ";\"" : "")
                     + ">" + escapeHtml(ma[1]) + "</a>";
                i += ma[0].length; continue;
            }
            var mt = RE_HTML_TAG.exec(t.substring(i, i + 40));
            if (mt) {
                var tag = mt[2].toLowerCase();
                var closing = mt[1] === "/";
                if (tag === "br") { out += "<br>"; i += mt[0].length; continue; }
                var qt = TAG_MAP[tag];
                if (!closing) {
                    // only a tag that has its closer is a tag: "a <b and c" is text
                    if (t.toLowerCase().indexOf("</" + tag, i + mt[0].length) >= 0) {
                        out += qt.open(opt); i += mt[0].length; continue;
                    }
                } else if (_openTags(out, tag) > 0) {
                    out += qt.close; i += mt[0].length; continue;
                }
            }
        }

        // a backslash at the end of a line is a hard break
        if (c === "\\" && t.charAt(i + 1) === "\n") { out += "<br>"; i += 2; continue; }

        if (c === "\\" && i + 1 < n && "\\`*_{}[]()#+-.!>~|$\"'".indexOf(t.charAt(i + 1)) >= 0) {
            out += escapeHtml(t.charAt(i + 1)); i += 2; continue;
        }

        // Two spaces before a newline is a hard break; a lone newline is a
        // soft one and renders as a space, as every markdown does.
        if (c === " ") {
            var sp = 0;
            while (i + sp < n && t.charAt(i + sp) === " ") sp++;
            if (t.charAt(i + sp) === "\n") {
                out += (sp >= 2) ? "<br>" : " ";
                i += sp + 1; continue;
            }
            out += " "; i++; continue;
        }
        if (c === "\n") { out += " "; i++; continue; }

        if (c === "`") {
            var run = 1;
            while (i + run < n && t.charAt(i + run) === "`") run++;
            var mark = _rep("`", run);
            var close = t.indexOf(mark, i + run);
            while (close >= 0 && t.charAt(close + run) === "`")
                close = t.indexOf(mark, close + run + 1);
            if (close >= 0) {
                var inner = t.substring(i + run, close);
                if (inner.length > 2 && inner.charAt(0) === " " && inner.charAt(inner.length - 1) === " ")
                    inner = inner.substring(1, inner.length - 1);
                out += _codeSpan(inner, opt);
                i = close + run; continue;
            }
            out += escapeHtml(mark); i += run; continue;
        }

        if (c === "!" && t.charAt(i + 1) === "[") {
            var ib = _matchPair(t, i + 1, "[", "]");
            if (ib > 0 && t.charAt(ib + 1) === "(") {
                var ip = _matchPair(t, ib + 1, "(", ")");
                if (ip > 0) {
                    var alt = t.substring(i + 2, ib);
                    var isrc = _destOf(t.substring(ib + 2, ip));
                    if (!opt.noImages && opt.acc) opt.acc.imgs++;
                    out += opt.noImages ? escapeHtml(alt)
                         : "<img src=\"" + _attr(isrc) + "\" alt=\"" + _attr(alt) + "\">";
                    i = ip + 1; continue;
                }
            }
        }

        if (c === "[") {
            var lb = _matchPair(t, i, "[", "]");
            if (lb > 0 && t.charAt(lb + 1) === "(") {
                var lp = _matchPair(t, lb + 1, "(", ")");
                if (lp > 0) {
                    var label = t.substring(i + 1, lb);
                    var dest = _destOf(t.substring(lb + 2, lp));
                    out += "<a href=\"" + _attr(dest) + "\""
                         + (opt.linkColor ? " style=\"color:" + opt.linkColor + ";\"" : "")
                         + ">" + _inline(label, opt) + "</a>";
                    i = lp + 1; continue;
                }
            }
        }

        if (c === "~" && t.charAt(i + 1) === "~") {
            var sc = t.indexOf("~~", i + 2);
            if (sc > 0) {
                out += "<s>" + _inline(t.substring(i + 2, sc), opt) + "</s>";
                i = sc + 2; continue;
            }
        }

        if (c === "*" || c === "_") {
            var erun = 1;
            while (i + erun < n && t.charAt(i + erun) === c) erun++;
            var prev = i > 0 ? t.charAt(i - 1) : " ";
            var after = t.charAt(i + erun);
            // `_` inside a word is snake_case, not emphasis.
            var ok = !(c === "_" && _isWordChar(prev)) && after !== "" && after !== " " && after !== "\n";
            if (ok) {
                var want = Math.min(erun, 3);
                var ec = _findEmphClose(t, i + erun, c, want);
                if (ec > 0) {
                    var open = want === 3 ? "<b><i>" : want === 2 ? "<b>" : "<i>";
                    var shut = want === 3 ? "</i></b>" : want === 2 ? "</b>" : "</i>";
                    out += open + _inline(t.substring(i + erun, ec), opt) + shut;
                    i = ec + want; continue;
                }
            }
            out += escapeHtml(_rep(c, erun)); i += erun; continue;
        }

        if ((c === "h" || c === "H") && (i === 0 || !_isWordChar(t.charAt(i - 1)))) {
            RE_AUTOLINK.lastIndex = i;
            var am = RE_AUTOLINK.exec(t);
            if (am && am.index === i) {
                var url = am[0].replace(/[.,;:!?)]+$/, "");
                out += "<a href=\"" + _attr(url) + "\""
                     + (opt.linkColor ? " style=\"color:" + opt.linkColor + ";\"" : "")
                     + ">" + escapeHtml(url) + "</a>";
                i += url.length; continue;
            }
        }

        out += escapeHtml(c); i++;
    }
    return out;
}

// ---- entities and the few html tags models put in markdown --------------------------------------------------
//
// `&amp;` `&nbsp;` `&mdash;` `&#8212;` and friends read as the character (escapeHtml would show them as the
// five letters), an unknown name stays what it was written as. `<br>` is a line break (models use it in
// table cells), `<sub>` `<sup>` `<b>` `<i>` `<u>` `<s>` `<kbd>` and a few more are tags; any other `<..>` is text.
var RE_ENTITY = /^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,9});/;
var RE_ANGLE_URL = /^<(https?:\/\/[^>\s]+)>/;
var RE_HTML_TAG = /^<(\/?)(br|sub|sup|b|i|u|s|em|strong|del|ins|kbd|small)(?:\s[^<>]*)?\/?>/i;
var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: "\u00a0", copy: "\u00a9", reg: "\u00ae",
    trade: "\u2122", mdash: "\u2014", ndash: "\u2013", hellip: "\u2026", laquo: "\u00ab", raquo: "\u00bb",
    lsquo: "\u2018", rsquo: "\u2019", ldquo: "\u201c", rdquo: "\u201d", times: "\u00d7", divide: "\u00f7",
    deg: "\u00b0", plusmn: "\u00b1", middot: "\u00b7", bull: "\u2022", larr: "\u2190", rarr: "\u2192",
    uarr: "\u2191", darr: "\u2193", harr: "\u2194", le: "\u2264", ge: "\u2265", ne: "\u2260", infin: "\u221e",
    euro: "\u20ac", pound: "\u00a3", yen: "\u00a5", cent: "\u00a2", sect: "\u00a7", para: "\u00b6",
    micro: "\u00b5", frac12: "\u00bd", frac14: "\u00bc", frac34: "\u00be", check: "\u2713", hearts: "\u2665",
    alpha: "\u03b1", beta: "\u03b2", gamma: "\u03b3", delta: "\u03b4", pi: "\u03c0", sigma: "\u03c3",
    omega: "\u03c9", mu: "\u03bc", lambda: "\u03bb", theta: "\u03b8", Delta: "\u0394", Omega: "\u03a9",
    sum: "\u2211", radic: "\u221a", asymp: "\u2248", equiv: "\u2261", minus: "\u2212", ensp: "\u2002",
    emsp: "\u2003", thinsp: "\u2009", zwj: "\u200d", shy: "\u00ad" };
function _entity(name) {
    if (name.charAt(0) === "#") {
        var cp = (name.charAt(1) === "x" || name.charAt(1) === "X") ? parseInt(name.substring(2), 16) : parseInt(name.substring(1), 10);
        if (!(cp > 0) || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return null;
        return String.fromCodePoint(cp);
    }
    return ENTITIES.hasOwnProperty(name) ? ENTITIES[name] : null;
}
var TAG_MAP = {
    b: { open: function () { return "<b>"; }, close: "</b>" },
    strong: { open: function () { return "<b>"; }, close: "</b>" },
    i: { open: function () { return "<i>"; }, close: "</i>" },
    em: { open: function () { return "<i>"; }, close: "</i>" },
    u: { open: function () { return "<u>"; }, close: "</u>" },
    ins: { open: function () { return "<u>"; }, close: "</u>" },
    s: { open: function () { return "<s>"; }, close: "</s>" },
    del: { open: function () { return "<s>"; }, close: "</s>" },
    sub: { open: function () { return "<sub>"; }, close: "</sub>" },
    sup: { open: function () { return "<sup>"; }, close: "</sup>" },
    small: { open: function () { return "<small>"; }, close: "</small>" },
    kbd: { open: function (opt) { return "<span style=\"" + (opt.monoFamily ? "font-family:'" + opt.monoFamily + "'; " : "")
                                          + (opt.codeInlineBg ? "background-color:" + opt.codeInlineBg + ";" : "") + "\">"; },
           close: "</span>" }
};
// how many of `tag` the html built so far has open (a closer without an opener is dropped)
function _openTags(html, tag) {
    var q = TAG_MAP[tag];
    var close = q.close;
    var open = tag === "kbd" ? "<span" : q.open({});
    var o = html.split(open).length - 1;
    var c = html.split(close).length - 1;
    return o - c;
}

function _rep(c, n) { var s = ""; for (var i = 0; i < n; i++) s += c; return s; }

function _codeSpan(inner, opt) {
    if (!opt || !opt.monoFamily)
        return "<code>" + escapeHtml(inner) + "</code>";
    var css = "font-family:'" + opt.monoFamily + "';";
    if (opt.monoSizePx) css += " font-size:" + opt.monoSizePx + "px;";
    if (opt.codeInlineBg) css += " background-color:" + opt.codeInlineBg + ";";
    if (opt.codeInlineFg) css += " color:" + opt.codeInlineFg + ";";
    return "<span style=\"" + css + "\">" + escapeHtml(inner) + "</span>";
}

// Matching close for a bracket pair, counting nesting so a link label may
// contain brackets: [a [b] c](url).
function _matchPair(t, from, open, close) {
    var depth = 0;
    for (var i = from; i < t.length; i++) {
        var c = t.charAt(i);
        if (c === "\\") { i++; continue; }
        if (c === open) depth++;
        else if (c === close) { depth--; if (depth === 0) return i; }
    }
    return -1;
}

function _destOf(raw) {
    var d = raw.trim();
    var m = /^(\S+)[ \t]+(?:"[^"]*"|'[^']*'|\([^)]*\))$/.exec(d);
    if (m) d = m[1];
    if (d.charAt(0) === "<" && d.charAt(d.length - 1) === ">") d = d.substring(1, d.length - 1);
    return d;
}

function _findEmphClose(t, from, ch, count) {
    var i = from;
    var n = t.length;
    while (i < n) {
        var c = t.charAt(i);
        if (c === "\\") { i += 2; continue; }
        if (c === "$") {                          // nor inside a formula: x_i, a*b
            var mx = _mathAt(t, i);
            if (mx) { i = mx.end; continue; }
        }
        if (c === "`") {                          // never close inside a code span
            var run = 1;
            while (i + run < n && t.charAt(i + run) === "`") run++;
            var cl = t.indexOf(_rep("`", run), i + run);
            i = (cl < 0) ? i + run : cl + run;
            continue;
        }
        if (c === ch) {
            var r = 1;
            while (i + r < n && t.charAt(i + r) === ch) r++;
            var pre = t.charAt(i - 1);
            var post = t.charAt(i + r);
            var wordTail = (ch === "_") && _isWordChar(post);
            if (r >= count && i > from && pre !== " " && pre !== "\n" && !wordTail) return i;
            i += r; continue;
        }
        i++;
    }
    return -1;
}

// =============================================================================
// IS A SOURCE CHANGE AN APPEND?
//
// The view has two speeds and this is the switch between them. A stream only
// ever appends, and its flush is batched one per frame so that tokens arriving
// faster than frames do not touch the model more than once a frame. Anything
// else -- a conversation switch, a delegate re-used for another message, a
// rebuild after a font or theme change -- REPLACES the document, and that
// build has to land in the caller's own frame, because whatever frame Qt
// presents next can only show what is already there when control returns to
// the event loop.
//
// Told from two numbers the view already keeps: the length of the source it
// last flushed and the last FENCE characters of it. Comparing whole prefixes
// would be O(document) per token, which is the cost the whole design exists to
// avoid; comparing the boundary is O(FENCE).
// =============================================================================
var FENCE = 32;

function fenceOf(src) {
    var s = String(src === undefined ? "" : src);
    return s.substr(Math.max(0, s.length - FENCE), FENCE);
}

function isAppend(src, prevLen, prevFence) {
    var s = String(src === undefined ? "" : src);
    if (prevLen <= 0)
        return s.length === 0;         // nothing has been flushed yet
    if (s.length < prevLen)
        return false;                  // the source shrank
    // The window is min(prevLen, FENCE) wide, not FENCE wide: a source shorter
    // than the fence has a fence shorter than the fence, and slicing FENCE
    // characters out of the NEW source would compare a growing string against
    // a shorter one and call every append a replacement -- which for the first
    // 32 characters of a stream is one synchronous flush per token.
    var n = Math.min(prevLen, FENCE);
    return s.substr(prevLen - n, n) === prevFence;
}

// A paragraph that is nothing but one image: the view draws it as a real
// Image rather than letting QTextDocument try to fetch it.
function _unangle(d) {
    return d.charAt(0) === "<" ? d.substring(1, d.length - 1) : d;
}

function imageOf(text) {
    var m = RE_IMGONLY.exec(String(text === undefined ? "" : text).trim());
    return m ? { alt: m[1], src: _unangle(m[2]) } : null;
}

// =============================================================================
// Block HTML
//
// Body text carries NO colour: it inherits the TextEdit's `color`, which is
// bound to a Theme token, so a light/dark switch moves it live. Only what the
// document cannot express any other way (inline-code fill, link colour, code
// syntax) is written into the HTML, and the view re-converts those once per
// theme switch.
// =============================================================================

function _fontCss(family, px, bold) {
    var css = "";
    if (family) css += "font-family:'" + family + "';";
    if (px) css += " font-size:" + Math.round(px) + "px;";
    if (bold) css += " font-weight:bold;";
    return css;
}

function blockHtml(block, opt) {
    try { return _blockHtml(block, opt || {}); }
    catch (e) { return escapeHtml(block && block.text ? block.text : ""); }
}

function _blockHtml(b, opt) {
    switch (b.kind) {
    case "head":
        opt.cur = headPx(opt.sizePx, b.level, opt.headScale);
        return "<div style=\"" + _fontCss(opt.family, opt.cur, true)
             + "\">" + _inline(b.text, opt) + "</div>";
    case "para":
        opt.cur = opt.sizePx;
        return "<div style=\"" + _fontCss(opt.family, opt.sizePx, opt.bold)
             + "\">" + _inline(b.text, opt) + "</div>";
    case "list":
        opt.cur = opt.sizePx;
        return "<div style=\"" + _fontCss(opt.family, opt.sizePx, opt.bold)
             + "\">" + _listHtml(b, opt) + "</div>";
    case "quote": {
        // The inner markdown is real markdown. The view draws the accent bar
        // and the inset; this only has to render what is inside it.
        var inner = parseBlocks(b.text);
        var s = "";
        for (var i = 0; i < inner.length; i++) {
            var ib = inner[i];
            if (ib.kind === "code")
                s += "<div style=\"" + _fontCss(opt.monoFamily || opt.family, opt.monoSizePx || opt.sizePx, opt.bold)
                   + " white-space:pre-wrap;\">" + escapeHtml(ib.code).replace(/\n/g, "<br>") + "</div>";
            else if (ib.kind === "table") {
                var rowsT = [ib.head].concat(ib.rows);
                var lines = [];
                for (var r = 0; r < rowsT.length; r++) lines.push(_inline(rowsT[r].join("  |  "), opt));
                s += "<div style=\"" + _fontCss(opt.family, opt.sizePx, opt.bold) + "\">" + lines.join("<br>") + "</div>";
            }
            else if (ib.kind === "rule") s += "<div>&nbsp;</div>";
            else if (ib.kind === "math") {
                opt.cur = opt.sizePx;
                s += "<div style=\"" + _fontCss(opt.family, opt.sizePx, opt.bold) + "\">"
                   + _mathHtml(ib.tex, true, opt) + "</div>";
            }
            else s += _blockHtml(ib, opt);
        }
        return s;
    }
    // The view owns these three: a code block is a CodeBlock, a table is real
    // cells that can be aligned and scrolled, a rule is one Rectangle.
    case "code":
    case "table":
    case "rule":
    case "math":
        return "";
    }
    return "";
}

function _listHtml(b, opt) {
    var out = "";
    var stack = [];
    for (var i = 0; i < b.items.length; i++) {
        var it = b.items[i];
        var ord = (it.ordered === undefined) ? b.ordered : it.ordered;
        var tag = ord ? "ol" : "ul";
        while (stack.length > it.depth + 1) out += "</" + stack.pop() + ">";
        if (stack.length === it.depth + 1 && stack[stack.length - 1] !== tag)
            out += "</" + stack.pop() + ">";
        while (stack.length < it.depth + 1) {
            var st = (stack.length === 0 && ord && b.listStart > 1) ? " start=\"" + b.listStart + "\"" : "";
            out += "<" + tag + st + ">";
            stack.push(tag);
        }
        // Qt's rich text has no checkbox; the glyphs are in every fallback font.
        var pre = it.checked === true ? "\u2611 " : it.checked === false ? "\u2610 " : "";
        out += "<li>" + pre + _inline(it.text, opt) + "</li>";
    }
    while (stack.length) out += "</" + stack.pop() + ">";
    return out;
}

// =============================================================================
// Code HTML
// =============================================================================

// `palette` maps a highlight class to a "#rrggbb" string; a class with no
// entry is left unstyled and inherits the edit's colour, which is how a
// language we do not lex still follows the theme.
//
// A code block in an answer is never scrollable and never truncated, so a long
// line WRAPS. Two things make a wrap read as a wrap and not as a new statement:
//
//   * `white-space:pre-wrap` -- `pre` and `pre-wrap` both preserve runs of
//     spaces, but only `pre-wrap` is the one that means "and break me". (The
//     edit's own `wrapMode` is what actually decides, measured; using the
//     honest value here keeps the HTML true to what happens.)
//   * a HANGING INDENT: every source line becomes its own <p> with
//     `margin-left: I` and `text-indent: -I`, so the line starts flush and its
//     continuations sit `I` in. `I` is the line's OWN leading indentation plus
//     `hangChars` characters, so a wrapped line inside a nested block lands
//     just past the code it belongs to instead of back at column zero, where
//     it would read as the next statement. The line's own indent is counted up
//     to `maxIndentChars` so deeply nested code cannot push the text off the
//     right edge of a narrow block.
//
// `opt` is optional: { charPx, hangChars, maxIndentChars }. `charPx` is one
// monospace character's advance, measured by the CALLER (this file never sees
// a font). Without it there is no indent to compute, so the whole block falls
// back to one wrapping <span> -- still no scrolling, just no hang.
function codeHtml(code, lang, palette, family, sizePx, bold, opt) {
    var o = opt || {};
    var runs = highlight(_expandTabs(code), lang);
    var css = "white-space:pre-wrap; font-family:'" + (family || "monospace") + "';"
            + (sizePx ? " font-size:" + Math.round(sizePx) + "px;" : "")
            + (bold ? " font-weight:bold;" : "");
    var i;

    var charPx = o.charPx || 0;
    if (charPx <= 0) {
        var flat = "<span style=\"" + css + "\">";
        for (i = 0; i < runs.length; i++)
            // An explicit break cannot be collapsed by anything downstream.
            flat += _runHtml(runs[i].text, runs[i].cls, palette).replace(/\n/g, "<br>");
        return flat + "</span>";
    }

    var hang = (o.hangChars === undefined ? 2 : o.hangChars) * charPx;
    var maxInd = (o.maxIndentChars === undefined ? 10 : o.maxIndentChars) * charPx;

    // Split the highlight runs at newlines: a run may span lines, and each
    // line has to become its own block to carry its own indent.
    var html = [""];
    var plain = [""];
    for (i = 0; i < runs.length; i++) {
        var parts = runs[i].text.split("\n");
        for (var p = 0; p < parts.length; p++) {
            if (p > 0) { html.push(""); plain.push(""); }
            if (parts[p].length === 0) continue;
            html[html.length - 1] += _runHtml(parts[p], runs[i].cls, palette);
            plain[plain.length - 1] += parts[p];
        }
    }

    var out = "";
    for (i = 0; i < html.length; i++) {
        var ind = Math.round(Math.min(_leadPx(plain[i], charPx), maxInd) + hang);
        // A truly empty <p> is folded away by Qt's HTML importer, which would
        // swallow the blank lines that separate a code block's paragraphs. A
        // zero-width space gives the block content -- and no advance, so it
        // cannot shift anything.
        out += "<p style=\"margin:0px; margin-left:" + ind + "px; text-indent:-" + ind + "px; "
             + css + "\">" + (html[i].length > 0 ? html[i] : "&#8203;") + "</p>";
    }
    return out;
}

function _runHtml(text, cls, palette) {
    var txt = escapeHtml(text);
    var col = palette ? palette[cls] : null;
    return col ? "<span style=\"color:" + col + ";\">" + txt + "</span>" : txt;
}

// How far a line's own leading indentation carries it. Tabs are gone by the
// time this runs -- see _expandTabs.
function _leadPx(line, charPx) {
    var cols = 0;
    while (cols < line.length && line.charAt(cols) === " ") cols++;
    return cols * charPx;
}

// Tabs become spaces to the next 4-column stop, before anything else looks at
// the code. The renderer's own tab stop is a fixed PIXEL distance with no
// relation to the code's columns -- measured: a leading tab draws about
// eleven columns wide while the hanging indent computed for it would be four,
// so the continuation of a tab-indented line would land to the LEFT of where
// the line started, which is the exact confusion the hang exists to prevent. Expanding
// makes the drawn indent and the measured one the same number. The copy button
// still copies `root.code`, untouched.
function _expandTabs(code) {
    var s = String(code === undefined || code === null ? "" : code);
    if (s.indexOf("\t") < 0) return s;
    var out = "";
    var col = 0;
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        if (c === "\n") { out += c; col = 0; }
        else if (c === "\t") { var n = 4 - (col % 4); out += _rep(" ", n); col += n; }
        else { out += c; col++; }
    }
    return out;
}

// =============================================================================
// Table fitting
// =============================================================================

// Column widths for a table that must ALWAYS fit the width it is given: no
// horizontal scrolling, no truncation, no elision. The caller measures, in the
// font it is actually drawing in, and passes:
//
//   nat[c]  the column's widest cell laid out on ONE line  (what it wants)
//   min[c]  the column's widest single WORD                (what it would
//           rather not break)
//   avail   the width the table has, INCLUDING padding
//   padH    the horizontal padding inside one cell, per side
//
// and gets back pixel widths INCLUDING that padding, summing to exactly
// `avail` -- exactly, because a table whose last column stops one pixel short
// of the container's edge is the kind of asymmetry this project notices.
//
// Three regimes, in order: room to spare (share the slack in proportion to
// what each column asked for, so the table runs to the edge); a squeeze (every
// column keeps its longest word and gives up its slack in proportion); and no
// room even for the words (scale the floors together and let cells break
// mid-word -- fitting beats keeping a word intact, because the alternative is
// a table overflowing its container).
function fitColumns(nat, min, avail, padH) {
    var n = nat ? nat.length : 0;
    var out = [];
    var i;
    if (n === 0) return out;
    var pad = (padH || 0) * 2;
    var inner = avail - pad * n;
    if (inner < n) {
        // Pathological width: there is not a pixel of text per column. Share
        // what there is and let the cells do what they can.
        for (i = 0; i < n; i++) out.push(Math.max(1, Math.floor(avail / n)));
        return _spendRemainder(out, avail);
    }

    // A single greedy column (a cell holding a 200-character URL) must not be
    // allowed to claim the whole table as its floor.
    var capMin = (n > 1) ? (inner / n) * 2 : inner;
    var natSum = 0, minSum = 0;
    var floors = [];
    for (i = 0; i < n; i++) {
        var f = Math.min(min[i] || 0, nat[i] || 0, capMin);
        floors.push(f);
        natSum += nat[i] || 0;
        minSum += f;
    }

    var w = [];
    if (natSum <= inner) {
        for (i = 0; i < n; i++)
            w.push(natSum > 0 ? nat[i] + (inner - natSum) * nat[i] / natSum : inner / n);
    } else if (minSum <= inner) {
        var spread = natSum - minSum;
        for (i = 0; i < n; i++)
            w.push(spread > 0 ? floors[i] + (inner - minSum) * ((nat[i] || 0) - floors[i]) / spread
                              : inner / n);
    } else {
        for (i = 0; i < n; i++) w.push(minSum > 0 ? floors[i] * inner / minSum : inner / n);
    }
    for (i = 0; i < n; i++) out.push(Math.max(1, Math.floor(w[i])) + pad);
    return _spendRemainder(out, avail);
}

// The rounding remainder goes to the widest column, where a pixel shows least.
function _spendRemainder(out, avail) {
    var sum = 0, wide = 0;
    for (var i = 0; i < out.length; i++) { sum += out[i]; if (out[i] > out[wide]) wide = i; }
    var give = Math.round(avail) - sum;
    if (out[wide] + give >= 1) out[wide] += give;
    return out;
}

// =============================================================================
// Search highlight
// =============================================================================

// Weave a highlighter-style background behind every case-insensitive match of
// `query` in the TEXT of an HTML fragment. Tags and attributes are never
// touched -- only text runs are matched -- and a match that crosses an inline
// tag boundary ("bold te" across </b>) is wrapped as one span per text run,
// so the markup stays balanced. An entity counts as the character it decodes
// to (a query "a&b" finds "a&amp;b") and the original entity text is kept
// verbatim inside the inserted span. `color` is a "#rrggbb" string chosen by
// the caller; this file never sees a theme.
function highlightHtml(html, query, color) {
    try {
        return _highlightHtml(String(html === undefined || html === null ? "" : html),
                              String(query === undefined || query === null ? "" : query),
                              String(color || ""));
    } catch (e) {
        return html;
    }
}

var _ENT = { "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " " };

function _highlightHtml(s, q, color) {
    if (q.length === 0 || s.length === 0) return s;
    // Map the fragment's text content: `plain` is the decoded text, and for
    // each of its characters `at[i]`/`to[i]` is the html range it came from.
    var plain = "";
    var at = [];
    var to = [];
    var i = 0;
    var n = s.length;
    while (i < n) {
        var c = s.charAt(i);
        if (c === "<") {
            var e = s.indexOf(">", i);
            if (e < 0) break;              // malformed tail: nothing to match in it
            i = e + 1;
            continue;
        }
        if (c === "&") {
            var sc = s.indexOf(";", i);
            if (sc > i && sc - i <= 9) {
                var ent = s.substring(i + 1, sc);
                var dec = null;
                if (_ENT[ent] !== undefined) dec = _ENT[ent];
                else if (ent.charAt(0) === "#") {
                    var code = (ent.charAt(1) === "x" || ent.charAt(1) === "X")
                        ? parseInt(ent.substring(2), 16) : parseInt(ent.substring(1), 10);
                    if (isFinite(code) && code > 0) dec = String.fromCharCode(code);
                }
                if (dec !== null) {
                    for (var k = 0; k < dec.length; k++) {
                        plain += dec.charAt(k);
                        at.push(i);
                        to.push(sc + 1);
                    }
                    i = sc + 1;
                    continue;
                }
            }
        }
        plain += c;
        at.push(i);
        to.push(i + 1);
        i++;
    }
    var pl = plain.toLowerCase();
    var ql = q.toLowerCase();
    var hits = [];
    var from = 0;
    while (true) {
        var hit = pl.indexOf(ql, from);
        if (hit < 0) break;
        hits.push(hit);
        from = hit + ql.length;            // matches never overlap
    }
    if (hits.length === 0) return s;

    var open = "<span style=\"background-color:" + color + ";\">";
    var out = "";
    var pos = 0;                           // cursor into the html
    for (var h = 0; h < hits.length; h++) {
        var a = hits[h];
        var b = a + ql.length;
        // Group the match's characters into contiguous html runs: a tag (or a
        // skipped stretch) between two characters splits the span there.
        var runStart = at[a];
        var runEnd = to[a];
        for (var p = a + 1; p <= b; p++) {
            if (p < b && at[p] === runEnd) {
                runEnd = to[p];
                continue;
            }
            out += s.substring(pos, runStart) + open + s.substring(runStart, runEnd) + "</span>";
            pos = runEnd;
            if (p < b) { runStart = at[p]; runEnd = to[p]; }
        }
    }
    return out + s.substring(pos);
}

// =============================================================================
// Titles and plain text
// =============================================================================

function firstHeadingOrWords(src, maxWords) {
    try {
        var mw = maxWords || 6;
        // Only ever look at the head of the source: this runs on every user
        // turn and the answer may be 30 KB.
        var bs = parseBlocks(String(src === undefined ? "" : src).substring(0, 600));
        var t = "";
        for (var i = 0; i < bs.length && t === ""; i++) {
            var b = bs[i];
            if (b.kind === "head" || b.kind === "para" || b.kind === "quote") t = b.text;
            else if (b.kind === "list" && b.items.length) t = b.items[0].text;
            else if (b.kind === "code") t = b.code;
            else if (b.kind === "math") t = b.tex;
            else if (b.kind === "table" && b.head.length) t = b.head.join(" ");
        }
        t = _inlinePlain(t).replace(/\s+/g, " ").trim();
        if (t === "") return "";
        var w = t.split(" ");
        if (w.length <= mw) return w.join(" ");
        return w.slice(0, mw).join(" ") + "\u2026";
    } catch (e) { return ""; }
}

// TEXT AS IT GOES TO THE CLIPBOARD. Every copy path the module writes itself
// -- the drag layer's Ctrl+C and Ctrl+Shift+C, a code block's copy button,
// a whole answer -- passes through here, because what a TextEdit hands back
// as `selectedText` is NOT a string of lines. (The sent question's Ctrl+C is
// the edit's own `copy()`, whose plain text Qt already writes with `\n` --
// measured alongside -- and a plain-text question has no ZWSP to lose.)
// QTextCursor::selectedText
// (documented, and measured) separates
// paragraphs with U+2029 PARAGRAPH SEPARATOR and marks a soft break (a `<br>`)
// with U+2028 LINE SEPARATOR; a code block is one <p> per source line, so a
// selection across three lines of HTML comes back with two U+2029
// in it -- VS Code's "unusual line terminators" -- and a paragraph with a hard
// break carries a U+2028. The zero-width space is this file's own: codeHtml
// gives an empty line `&#8203;` so Qt's importer keeps the paragraph, and a
// selection across that line brings it back. None of these is text the reader
// selected; a copied shell script with a ZWSP in it fails in a way nobody can
// see. So: every terminator becomes `\n` (including a CR or CRLF a model may
// have emitted), the ZWSP goes, and nothing else is touched.
function copyText(s) {
    return String(s === undefined || s === null ? "" : s)
        .replace(/\r\n?/g, "\n")
        .replace(/[\u2028\u2029]/g, "\n")
        .replace(/\u200b/g, "");
}

function plainText(src) {
    try {
        var bs = parseBlocks(src);
        var out = [];
        for (var i = 0; i < bs.length; i++) {
            var b = bs[i];
            var s = "";
            switch (b.kind) {
            case "head": s = _inlinePlain(b.text); break;
            case "para": s = _inlinePlain(b.text); break;
            case "code": s = b.code; break;
            case "rule": s = "---"; break;
            case "math": s = "$$" + b.tex + "$$"; break;
            case "quote": {
                var q = plainText(b.text).split("\n");
                for (var k = 0; k < q.length; k++) q[k] = q[k].length ? "> " + q[k] : ">";
                s = q.join("\n"); break;
            }
            case "list": {
                var li = [];
                for (var j = 0; j < b.items.length; j++) {
                    var it = b.items[j];
                    var mark = it.ordered === false ? "- " : (b.ordered ? (b.listStart + j) + ". " : "- ");
                    var box = it.checked === true ? "[x] " : it.checked === false ? "[ ] " : "";
                    li.push(_rep("  ", it.depth) + mark + box + _inlinePlain(it.text));
                }
                s = li.join("\n"); break;
            }
            case "table": {
                var tl = [_rowPlain(b.head)];
                for (var r = 0; r < b.rows.length; r++) tl.push(_rowPlain(b.rows[r]));
                s = tl.join("\n"); break;
            }
            }
            if (s.length) out.push(s);
        }
        return out.join("\n\n");
    } catch (e) { return String(src === undefined ? "" : src); }
}

function _rowPlain(cells) {
    var o = [];
    for (var i = 0; i < cells.length; i++) o.push(_inlinePlain(cells[i]));
    return o.join(" | ");
}

function _inlinePlain(t) {
    var s = String(t === undefined || t === null ? "" : t);
    // A formula's source is not markdown: set it aside, whole, while the rest is stripped.
    if (s.indexOf("$") >= 0 || s.indexOf("\\(") >= 0 || s.indexOf("\\[") >= 0) {
        var parts = [];
        var from = 0;
        for (var i = 0; i < s.length; i++) {
            var ch = s.charAt(i);
            if (ch !== "$" && ch !== "\\") continue;
            var mp = _mathAt(s, i);
            if (!mp) continue;
            if (mp.tex === null) { i = mp.end - 1; continue; }
            parts.push(_inlinePlainText(s.substring(from, i)));
            parts.push(s.substring(i, mp.end));
            from = mp.end; i = mp.end - 1;
        }
        if (parts.length) { parts.push(_inlinePlainText(s.substring(from))); return parts.join(""); }
    }
    return _inlinePlainText(s);
}

function _inlinePlainText(s) {
    s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1");
    s = s.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
    s = s.replace(/`+/g, "");
    s = s.replace(/\*{1,3}([^*]+)\*{1,3}/g, "$1");
    s = s.replace(/(^|[^A-Za-z0-9_])_{1,3}([^_]+)_{1,3}(?![A-Za-z0-9])/g, "$1$2");
    s = s.replace(/~~([^~]+)~~/g, "$1");
    s = s.replace(/\\([\\`*_{}\[\]()#+\-.!>~|])/g, "$1");
    return s;
}

// =============================================================================
// Syntax highlighting
//
// Small, regex-and-scanner sized lexers: ordinary code has to look right,
// pathological code only has to not crash. Every entry point is wrapped --
// an exception raised inside a QML binding takes the rest of the callback
// with it and reports as one WARN line.
// =============================================================================

function _set(words) {
    var o = {};
    var w = words.split(" ");
    for (var i = 0; i < w.length; i++) if (w[i]) o[w[i]] = 1;
    return o;
}

var SPECS = {
    sh: {
        line: ["#"], quotes: "\"'", dollar: true, cmd: true, flags: true,
        kw: _set("if then else elif fi for while until do done case esac in function select return exit break continue local export readonly declare set unset shift eval exec trap source alias sudo"),
        ty: _set("true false")
    },
    js: {
        line: ["//"], block: ["/*", "*/"], quotes: "\"'`",
        kw: _set("var let const function return if else for while do break continue new delete typeof instanceof in of class extends super this null undefined true false throw try catch finally switch case default yield async await import export from as void static get set property signal readonly alias pragma component required on enum"),
        ty: _set("Object Array String Number Boolean Math JSON Date RegExp Promise Map Set Symbol Error console Qt int real string bool var color url point rect size date list font vector2d vector3d Item Component Timer number any void unknown never")
    },
    py: {
        line: ["#"], quotes: "\"'", triple: true,
        kw: _set("def class return if elif else for while break continue pass import from as with try except finally raise lambda yield global nonlocal assert del in is not and or None True False async await match case"),
        ty: _set("int float str bool list dict set tuple bytes object type range len print open self super Exception ValueError TypeError KeyError IndexError enumerate zip map filter sum min max abs")
    },
    c: {
        line: ["//", "#"], block: ["/*", "*/"], quotes: "\"'",
        kw: _set("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while class public private protected virtual override final template typename namespace using new delete this nullptr true false try catch throw constexpr noexcept explicit friend operator mutable fn let mut impl pub crate use mod match move ref where trait unsafe async await dyn func package import type interface chan go defer select range map make nil implements extends instanceof synchronized abstract"),
        ty: _set("int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t size_t ssize_t bool string vector pair shared_ptr unique_ptr std i8 i16 i32 i64 u8 u16 u32 u64 usize isize f32 f64 str String Vec Option Result Box Self error byte rune any Integer Boolean Object List Map")
    },
    json: { quotes: "\"", jsonKeys: true, kw: _set("true false null") },
    sql: {
        line: ["--"], block: ["/*", "*/"], quotes: "'\"", ci: true,
        kw: _set("select from where insert into values update set delete create table drop alter add column primary key foreign references index view join inner left right outer full on group by order having limit offset union all distinct as and or not null is like between exists case when then else end begin commit rollback transaction with returning default constraint unique check cascade if"),
        ty: _set("int integer bigint smallint serial text varchar char boolean date timestamp time numeric decimal real double float json jsonb uuid blob")
    }
};

function _langKey(lang) {
    var l = String(lang === undefined || lang === null ? "" : lang).toLowerCase().trim();
    switch (l) {
    case "bash": case "sh": case "zsh": case "shell": case "console": case "shell-session": return "sh";
    case "js": case "javascript": case "mjs": case "ts": case "typescript": case "jsx": case "tsx": case "qml": return "js";
    case "python": case "py": case "python3": return "py";
    case "json": case "jsonc": return "json";
    case "c": case "h": case "cpp": case "c++": case "cc": case "hpp": case "rust": case "rs":
    case "go": case "golang": case "java": case "cs": case "csharp": case "c#": case "kotlin": case "swift": return "c";
    case "yaml": case "yml": case "toml": case "ini": case "conf": case "cfg": return "yaml";
    case "html": case "xml": case "svg": case "xhtml": return "xml";
    case "css": case "scss": case "less": case "qss": return "css";
    case "sql": case "psql": return "sql";
    case "diff": case "patch": return "diff";
    case "markdown": case "md": return "md";
    default: return "";
    }
}

function highlight(code, lang) {
    var c = String(code === undefined || code === null ? "" : code);
    try {
        if (c.length === 0) return [];
        var k = _langKey(lang);
        switch (k) {
        case "": return [{ text: c, cls: "" }];
        case "xml": return _lexXml(c);
        case "css": return _lexCss(c);
        case "diff": return _lexDiff(c);
        case "md": return _lexMd(c);
        case "yaml": return _lexYaml(c);
        default: return _lexGeneric(c, SPECS[k]);
        }
    } catch (e) {
        return [{ text: c, cls: "" }];
    }
}

function _isIdentStart(c) { return _isWordChar(c) && !(c >= "0" && c <= "9") || c === "_" || c === "$"; }
function _isIdentChar(c) { return _isWordChar(c) || c === "_" || c === "$"; }

var OPCH = "+-*/%=<>!&|^~?:";
var PUNCH = "(){}[];,.";

function _lexGeneric(code, spec) {
    var out = [];
    var n = code.length;
    var i = 0;
    var plain = "";
    var cmdPos = spec.cmd === true;
    function flush() { if (plain.length) { out.push({ text: plain, cls: "" }); plain = ""; } }
    function push(t, cls) {
        if (!t.length) return;
        if (!cls) { plain += t; return; }
        flush();
        out.push({ text: t, cls: cls });
    }
    while (i < n) {
        var c = code.charAt(i);
        if (c === "\n") { plain += c; i++; if (spec.cmd) cmdPos = true; continue; }
        if (c === " " || c === "\t" || c === "\r") { plain += c; i++; continue; }

        var lc = null;
        if (spec.line)
            for (var k = 0; k < spec.line.length; k++)
                if (code.substr(i, spec.line[k].length) === spec.line[k]) { lc = spec.line[k]; break; }
        if (lc !== null) {
            // `#` in the C family is the preprocessor, not a comment, but it
            // is the same ink in every editor and the line is the same shape.
            var le = code.indexOf("\n", i);
            if (le < 0) le = n;
            push(code.substring(i, le), "com"); i = le; continue;
        }
        if (spec.block && code.substr(i, spec.block[0].length) === spec.block[0]) {
            var be = code.indexOf(spec.block[1], i + spec.block[0].length);
            be = (be < 0) ? n : be + spec.block[1].length;
            push(code.substring(i, be), "com"); i = be; continue;
        }
        if (spec.quotes && spec.quotes.indexOf(c) >= 0) {
            var se = _scanString(code, i, c, spec.triple === true);
            var cls = "str";
            if (spec.jsonKeys) {
                var q = se;
                while (q < n && (code.charAt(q) === " " || code.charAt(q) === "\t")) q++;
                if (code.charAt(q) === ":") cls = "var";
            }
            push(code.substring(i, se), cls); i = se;
            if (spec.cmd) cmdPos = false;
            continue;
        }
        if (spec.dollar && c === "$") {
            var ve = _scanVar(code, i);
            push(code.substring(i, ve), "var"); i = ve; cmdPos = false; continue;
        }
        if (c >= "0" && c <= "9") {
            var ne = _scanNumber(code, i);
            push(code.substring(i, ne), "num"); i = ne; continue;
        }
        if (_isIdentStart(c)) {
            var j = i + 1;
            while (j < n && _isIdentChar(code.charAt(j))) j++;
            var w = code.substring(i, j);
            var key = spec.ci ? w.toLowerCase() : w;
            var a = j;
            while (a < n && code.charAt(a) === " ") a++;
            var wcls = "";
            if (spec.kw && spec.kw[key] === 1) wcls = "kw";
            else if (spec.ty && spec.ty[key] === 1) wcls = "type";
            else if (code.charAt(a) === "(") wcls = "fn";
            else if (cmdPos) wcls = "fn";          // shell: the word in command position
            push(w, wcls); i = j;
            if (spec.cmd) cmdPos = false;
            continue;
        }
        // A shell flag is one token, not a minus glued to a letter.
        if (spec.flags && c === "-" && (i === 0 || " \t\n(|&;".indexOf(code.charAt(i - 1)) >= 0)
            && /[-A-Za-z]/.test(code.charAt(i + 1))) {
            var fe = i + 1;
            while (fe < n && /[-A-Za-z0-9_]/.test(code.charAt(fe))) fe++;
            push(code.substring(i, fe), "type"); i = fe; continue;
        }
        if (OPCH.indexOf(c) >= 0) {
            var oe = i;
            while (oe < n && OPCH.indexOf(code.charAt(oe)) >= 0) oe++;
            var op = code.substring(i, oe);
            push(op, "op"); i = oe;
            if (spec.cmd && (op.indexOf("|") >= 0 || op.indexOf("&") >= 0)) cmdPos = true;
            continue;
        }
        if (PUNCH.indexOf(c) >= 0) {
            push(c, "punc"); i++;
            if (spec.cmd && (c === ";" || c === "(")) cmdPos = true;
            continue;
        }
        plain += c; i++;
    }
    flush();
    return out;
}

function _scanString(code, i, q, triple) {
    var n = code.length;
    if (triple && code.charAt(i + 1) === q && code.charAt(i + 2) === q) {
        var e = code.indexOf(q + q + q, i + 3);
        return e < 0 ? n : e + 3;
    }
    var j = i + 1;
    while (j < n) {
        var c = code.charAt(j);
        if (c === "\\") { j += 2; continue; }
        if (c === q) return j + 1;
        if (c === "\n" && q !== "`") return j;   // an unterminated quote stops at the line
        j++;
    }
    return n;
}

function _scanVar(code, i) {
    var n = code.length;
    var j = i + 1;
    if (code.charAt(j) === "{") {
        var e = code.indexOf("}", j);
        return e < 0 ? n : e + 1;
    }
    if (code.charAt(j) === "(") {
        var p = _matchPair(code, j, "(", ")");
        return p < 0 ? n : p + 1;
    }
    while (j < n && _isIdentChar(code.charAt(j))) j++;
    return j === i + 1 ? i + 2 : j;   // $? $# $1 ...
}

function _scanNumber(code, i) {
    var n = code.length;
    var j = i;
    if (code.charAt(j) === "0" && "xXbBoO".indexOf(code.charAt(j + 1)) >= 0) {
        j += 2;
        while (j < n && /[0-9a-fA-F_]/.test(code.charAt(j))) j++;
        return j;
    }
    while (j < n && /[0-9._]/.test(code.charAt(j))) j++;
    if (j < n && "eE".indexOf(code.charAt(j)) >= 0) {
        j++;
        if ("+-".indexOf(code.charAt(j)) >= 0) j++;
        while (j < n && /[0-9]/.test(code.charAt(j))) j++;
    }
    while (j < n && /[a-zA-Z]/.test(code.charAt(j))) j++;   // 10px, 3u32, 5L
    return j;
}

// ---- line-shaped languages --------------------------------------------------

function _byLines(code, fn) {
    var out = [];
    var lines = code.split("\n");
    for (var i = 0; i < lines.length; i++) {
        fn(lines[i], out);
        if (i < lines.length - 1) out.push({ text: "\n", cls: "" });
    }
    return out;
}

function _lexDiff(code) {
    // No red in the class list, so removals borrow `kw` (bright magenta) and
    // additions `str` (green): the two never sit on the same line, and the
    // pair reads as the two directions of a change.
    return _byLines(code, function (l, out) {
        var c = l.charAt(0);
        if (l.indexOf("+++") === 0 || l.indexOf("---") === 0 || l.indexOf("diff ") === 0 || l.indexOf("index ") === 0) out.push({ text: l, cls: "com" });
        else if (l.indexOf("@@") === 0) out.push({ text: l, cls: "fn" });
        else if (c === "+") out.push({ text: l, cls: "str" });
        else if (c === "-") out.push({ text: l, cls: "kw" });
        else out.push({ text: l, cls: "" });
    });
}

function _lexMd(code) {
    var fence = false;
    return _byLines(code, function (l, out) {
        if (/^ {0,3}(```|~~~)/.test(l)) { fence = !fence; out.push({ text: l, cls: "str" }); return; }
        if (fence) { out.push({ text: l, cls: "str" }); return; }
        if (RE_ATX.test(l)) { out.push({ text: l, cls: "kw" }); return; }
        if (RE_QUOTE.test(l)) { out.push({ text: l, cls: "com" }); return; }
        if (RE_RULE.test(l)) { out.push({ text: l, cls: "op" }); return; }
        var m = RE_ITEM.exec(l);
        if (m && _indentOf(l) < 4) {
            out.push({ text: m[1] + m[2], cls: "punc" });
            out.push({ text: (m[3] || "") + (m[4] === undefined ? "" : m[4]), cls: "" });
            return;
        }
        out.push({ text: l, cls: "" });
    });
}

function _lexYaml(code) {
    // Covers yaml, toml and ini: all three are "comment, key, value" per line.
    return _byLines(code, function (l, out) {
        var t = l.trim();
        if (t.charAt(0) === "#" || t.charAt(0) === ";") { out.push({ text: l, cls: "com" }); return; }
        if (/^\[.*\]$/.test(t)) { out.push({ text: l, cls: "type" }); return; }
        var m = /^([ \t]*(?:-[ \t]+)?)([A-Za-z0-9_.\-"']+)([ \t]*[:=])(.*)$/.exec(l);
        if (m) {
            out.push({ text: m[1], cls: m[1].indexOf("-") >= 0 ? "punc" : "" });
            out.push({ text: m[2], cls: "var" });
            out.push({ text: m[3], cls: "op" });
            _yamlValue(m[4], out);
            return;
        }
        _yamlValue(l, out);
    });
}

function _yamlValue(v, out) {
    var t = v.trim();
    if (t.length === 0) { out.push({ text: v, cls: "" }); return; }
    var lead = v.substring(0, v.indexOf(t.charAt(0)));
    var cls = "";
    if (/^["'].*["']$/.test(t)) cls = "str";
    else if (/^-?[0-9][0-9._]*$/.test(t)) cls = "num";
    else if (/^(true|false|null|yes|no|on|off|~)$/i.test(t)) cls = "kw";
    if (lead.length) out.push({ text: lead, cls: "" });
    out.push({ text: v.substring(lead.length), cls: cls });
}

function _lexXml(code) {
    var out = [];
    var n = code.length;
    var i = 0;
    var plain = "";
    function flush() { if (plain.length) { out.push({ text: plain, cls: "" }); plain = ""; } }
    function push(t, cls) { if (!t.length) return; if (!cls) { plain += t; return; } flush(); out.push({ text: t, cls: cls }); }
    while (i < n) {
        if (code.substr(i, 4) === "<!--") {
            var ce = code.indexOf("-->", i);
            ce = ce < 0 ? n : ce + 3;
            push(code.substring(i, ce), "com"); i = ce; continue;
        }
        if (code.charAt(i) === "<") {
            var te = code.indexOf(">", i);
            te = te < 0 ? n : te + 1;
            _xmlTag(code.substring(i, te), push);
            i = te; continue;
        }
        var nx = code.indexOf("<", i);
        if (nx < 0) nx = n;
        plain += code.substring(i, nx);
        i = nx;
    }
    flush();
    return out;
}

function _xmlTag(tag, push) {
    var m = /^(<[\/!?]?)([A-Za-z0-9_:.\-]*)([\s\S]*?)([\/?]?>)$/.exec(tag);
    if (!m) { push(tag, "punc"); return; }
    push(m[1], "punc");
    push(m[2], "type");
    var rest = m[3];
    var re = /([A-Za-z_:][A-Za-z0-9_:.\-]*)(\s*=\s*)("[^"]*"|'[^']*'|[^\s>]*)|(\s+)/g;
    var pos = 0;
    var mm;
    while ((mm = re.exec(rest)) !== null) {
        if (mm.index > pos) push(rest.substring(pos, mm.index), "");
        if (mm[4] !== undefined) push(mm[4], "");
        else { push(mm[1], "var"); push(mm[2], "op"); push(mm[3], "str"); }
        pos = re.lastIndex;
    }
    if (pos < rest.length) push(rest.substring(pos), "");
    push(m[4], "punc");
}

function _lexCss(code) {
    var out = [];
    var n = code.length;
    var i = 0;
    var inBlock = false;
    var plain = "";
    function flush() { if (plain.length) { out.push({ text: plain, cls: "" }); plain = ""; } }
    function push(t, cls) { if (!t.length) return; if (!cls) { plain += t; return; } flush(); out.push({ text: t, cls: cls }); }
    while (i < n) {
        var c = code.charAt(i);
        if (c === "/" && code.charAt(i + 1) === "*") {
            var ce = code.indexOf("*/", i);
            ce = ce < 0 ? n : ce + 2;
            push(code.substring(i, ce), "com"); i = ce; continue;
        }
        if (c === "{") { inBlock = true; push(c, "punc"); i++; continue; }
        if (c === "}") { inBlock = false; push(c, "punc"); i++; continue; }
        if (!inBlock) {
            var se = i;
            while (se < n && "{}/".indexOf(code.charAt(se)) < 0) se++;
            // A lone "/" outside a block stops the scan where it starts. Eat
            // it as plain text: a scanner that can make no progress is an
            // infinite loop inside a binding, not a missing colour.
            if (se === i) { plain += code.charAt(i); i++; continue; }
            var sel = code.substring(i, se);
            push(sel, sel.trim().charAt(0) === "@" ? "kw" : "type");
            i = se; continue;
        }
        var pm = /^([ \t\n]*)([-A-Za-z0-9_*]+)([ \t]*:)/.exec(code.substring(i, i + 120));
        if (pm) {
            push(pm[1], ""); push(pm[2], "var"); push(pm[3], "op");
            i += pm[0].length;
            var ve = i;
            while (ve < n && ";}".indexOf(code.charAt(ve)) < 0) ve++;
            _cssValue(code.substring(i, ve), push);
            i = ve; continue;
        }
        if (c === ";" || c === ",") { push(c, "punc"); i++; continue; }
        plain += c; i++;
    }
    flush();
    return out;
}

function _cssValue(v, push) {
    var re = /("[^"]*"|'[^']*')|(#[0-9a-fA-F]{3,8}|-?[0-9][0-9.]*[a-z%]*)|([A-Za-z-]+\s*\()|([A-Za-z-]+)/g;
    var pos = 0;
    var m;
    while ((m = re.exec(v)) !== null) {
        if (m.index > pos) push(v.substring(pos, m.index), "");
        if (m[1] !== undefined) push(m[1], "str");
        else if (m[2] !== undefined) push(m[2], "num");
        else if (m[3] !== undefined) push(m[3], "fn");
        else push(m[4], "");
        pos = re.lastIndex;
    }
    if (pos < v.length) push(v.substring(pos), "");
}

// =============================================================================
// Public names for LiveMarkdown.js (the notes editor's per-line renderer).
//
// The live editor tokenizes one source line at a time with source offsets,
// which this file's recursive html emitter cannot give it -- but it must read
// markdown by the SAME rules, or a note would render one way in the editor
// and another in the LLM view. So the rules are shared, not copied: these
// aliases are the contract, the underscored helpers stay private.
// =============================================================================
var RE = {
    atx: RE_ATX, fence: RE_FENCE, rule: RE_RULE, quote: RE_QUOTE, item: RE_ITEM,
    setext1: RE_SETEXT1, setext2: RE_SETEXT2, tdelim: RE_TDELIM, indent: RE_INDENT,
    autolink: RE_AUTOLINK, imgOnly: RE_IMGONLY
};
function matchPair(t, from, open, close) { return _matchPair(t, from, open, close); }
function findEmphClose(t, from, ch, count) { return _findEmphClose(t, from, ch, count); }
function destOf(raw) { return _destOf(raw); }
function isWordChar(c) { return _isWordChar(c); }
function cellsOf(line) { return _cells(line); }
function alignOf(cell) { return _alignOf(cell); }
function runHtml(text, cls, palette) { return _runHtml(text, cls, palette); }
function langKey(lang) { return _langKey(lang); }
