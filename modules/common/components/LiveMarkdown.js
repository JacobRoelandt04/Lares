.import "Markdown.js" as Md

// =============================================================================
// LiveMarkdown.js -- the notes editor's per-line markdown renderer.
//
// Obsidian's live preview, one SOURCE LINE at a time. The editor keeps the
// note as an array of lines (LineDocument.qml) and shows each line in its own
// TextEdit, in one of two modes:
//
//   RAW       the caret's line (and every line a selection touches): EVERY
//             source character emitted exactly once, markers drawn faint but
//             the content keeps its style. Document position == source
//             column, which is what lets the TextEdit be edited natively and
//             diffed back into the model (measured: identical for every
//             character but a lone CR, shown as a same-length U+240D).
//   RENDERED  every other line: markers OMITTED from the html, with a map
//             from each rendered position back to its source column (`r2s`),
//             so a click on a rendered line lands on the right character when
//             the line turns raw.
//
// Block structure that spans lines (fences, tables, frontmatter, callouts,
// setext headings, an inline html span left open) is carried by an
// incremental CONTEXT PASS: one small object per line, recomputed from the
// edit until the carried state agrees with what it was before.
//
// Markdown is read by the rules in Markdown.js (the LLM view's), through its
// public aliases -- a note must render the same in both. Nothing here throws:
// a line that trips something unforeseen renders as its escaped source.
//
// Colours arrive in a palette object of "#rrggbb" strings chosen by the QML
// that owns the theme; never a Theme read here.
//   pal = { faint, muted, link, codeBg, codeFg, mark, kbdBg,
//           named: { red, orange, yellow, green, teal, blue, purple, pink, gray },
//           code: { kw, str, num, com, fn, type, op, var, punc },
//           callout: { note, tip, warning, danger, ... } }
// =============================================================================

// ---- Block context ------------------------------------------------------------
//
// ctx per line:
//   t    blank | para | head | setext | setextU | rule | list | quote | callout
//        | fenceOpen | fenceBody | fenceClose | thead | tdelim | trow | front
//        | html | image | plain
//   cs   content start: source columns [0, cs) are block markup (list marker,
//        "# ", "> ", ...) -- hidden when rendered, faint when raw
//   lv   heading level (head, setext, setextU)
//   ind  list indent (columns), mk marker, ord, num, task (null | " " | "x")
//   lvl  list nesting level: how many enclosing items' indents lie below this
//        line's (0 for the first level whatever its width, two or four spaces
//        or a tab per level alike -- the carried `lst` stack decides)
//   qd   quote depth (quote, callout)
//   co   callout kind; coHead true on its first line, coTitle
//   lang fence language (fence lines)
//   cols, align   table shape (thead, tdelim, trow)
//   img  { src, alt, width } (image)
//   hin  inline html tags still open at the line's start ([{tag, css, href}])
//   ck   the carried state at the line's START, as a string (convergence key)
//   cin  the same carried state as an object (an incremental pass resumes from it)

var CALLOUT_RE = /^\[!([A-Za-z][A-Za-z0-9-]*)\]([+-]?)(?:[ \t]+(.*))?$/;
var HTML_BLOCK_RE = /^ {0,3}(?:<!--|<\/?(?:div|details|summary|table|thead|tbody|tfoot|tr|td|th|p|pre|ul|ol|li|h[1-6]|section|article|aside|header|footer|nav|figure|figcaption|center|blockquote|hr|iframe|script|style|dl|dt|dd|form|fieldset|video|audio|picture|source|main|address)(?=[\s/>]|$))/i;
var IMG_HTML_ONLY_RE = /^\s*<img\b[^>]*>\s*$/i;

function _carry0() {
    return { front: 0, fence: null, table: null, delim: false, callout: null, htmlBlock: false, html: [], prevT: "blank", lst: [] };
}

function _carryKey(c) {
    return c.front + "|" + (c.fence ? c.fence.ch + c.fence.len + ":" + c.fence.lang : "") + "|"
        + (c.table ? c.table.cols + (c.delim ? "d" : "") : "") + "|" + (c.callout || "") + "|"
        + (c.htmlBlock ? 1 : 0) + "|" + c.html.map(function (h) { return h.tag + h.css + (h.href || ""); }).join(",")
        + "|" + c.prevT + "|" + c.lst.join(",");
}

function _cloneCarry(c) {
    return { front: c.front, fence: c.fence, table: c.table, delim: c.delim, callout: c.callout,
             htmlBlock: c.htmlBlock, html: c.html.slice(), prevT: c.prevT, lst: c.lst.slice() };
}

function _quoteInfo(t) {
    // Depth and the column where the quoted content starts.
    var i = 0, depth = 0, n = t.length;
    while (true) {
        var j = i, sp = 0;
        while (j < n && t.charAt(j) === " " && sp < 3) { j++; sp++; }
        if (t.charAt(j) !== ">") break;
        depth++;
        i = j + 1;
        if (t.charAt(i) === " ") i++;
    }
    return { depth: depth, cs: i };
}

function _lineCtx(line, next, c, index, opt) {
    var x = { t: "para", cs: 0, hin: c.html.slice(), ck: _carryKey(c), cin: _cloneCarry(c) };
    if (opt && opt.kind === "text") {
        x.t = "plain";
        return x;
    }
    // Frontmatter: only a note's very first line opens it.
    if (c.front === 1) {
        x.t = "front";
        if (line === "---" || line === "...")
            c.front = 2;
        return x;
    }
    if (index === 0 && line === "---" && c.front === 0) {
        c.front = 1;
        x.t = "front";
        return x;
    }
    if (c.front === 0)
        c.front = 2;

    if (c.fence) {
        x.lang = c.fence.lang;
        var mc = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line);
        if (mc && mc[1].charAt(0) === c.fence.ch && mc[1].length >= c.fence.len) {
            x.t = "fenceClose";
            c.fence = null;
        } else {
            x.t = "fenceBody";
        }
        return x;
    }

    if (line.trim().length === 0) {
        x.t = "blank";
        c.table = null;
        c.delim = false;
        c.callout = null;
        c.htmlBlock = false;
        c.html = [];
        return x;
    }

    if (c.htmlBlock) {
        x.t = "html";
        return x;
    }

    if (c.table) {
        if (c.delim) {
            x.t = "tdelim";
            x.cols = c.table.cols;
            x.align = c.table.align;
            c.delim = false;
            return x;
        }
        if (!_startsBlock(line)) {
            x.t = "trow";
            x.cols = c.table.cols;
            x.align = c.table.align;
            return x;
        }
        c.table = null;
    }

    var mf = Md.RE.fence.exec(line);
    if (mf && !(mf[1].charAt(0) === "`" && mf[2].indexOf("`") >= 0)) {
        x.t = "fenceOpen";
        x.lang = mf[2].trim().split(/\s+/)[0] || "";
        x.cs = line.length;
        c.fence = { ch: mf[1].charAt(0), len: mf[1].length, lang: x.lang };
        return x;
    }

    var ma = Md.RE.atx.exec(line);
    if (ma) {
        x.t = "head";
        x.lv = ma[1].length;
        var hs = line.indexOf(ma[1]) + ma[1].length;
        while (hs < line.length && (line.charAt(hs) === " " || line.charAt(hs) === "\t")) hs++;
        x.cs = hs;
        return x;
    }

    if (c.prevT === "para" && (Md.RE.setext1.test(line) || Md.RE.setext2.test(line))) {
        x.t = "setextU";
        x.lv = Md.RE.setext1.test(line) ? 1 : 2;
        x.cs = line.length;
        return x;
    }

    if (Md.RE.rule.test(line)) {
        x.t = "rule";
        x.cs = line.length;
        return x;
    }

    if (Md.RE.quote.test(line)) {
        var q = _quoteInfo(line);
        x.qd = q.depth;
        x.cs = q.cs;
        var inner = line.substring(q.cs);
        var co = (c.prevT !== "quote" && c.prevT !== "callout") ? CALLOUT_RE.exec(inner) : null;
        if (co) {
            x.t = "callout";
            x.co = co[1].toLowerCase();
            x.coHead = true;
            x.coTitle = co[3] || "";
            x.cs = q.cs + inner.indexOf("]") + 1 + (co[2] ? 1 : 0);
            while (x.cs < line.length && (line.charAt(x.cs) === " " || line.charAt(x.cs) === "\t")) x.cs++;
            c.callout = x.co;
        } else if (c.callout && (c.prevT === "callout")) {
            x.t = "callout";
            x.co = c.callout;
        } else {
            x.t = "quote";
            c.callout = null;
        }
        return x;
    }
    c.callout = null;

    var mi = Md.RE.item.exec(line);
    if (mi) {
        x.t = "list";
        x.ind = _indentOf(mi[1]);
        // The open items' indents, outermost first: an item nests under the
        // last one that starts left of it, and closes those that start right.
        while (c.lst.length > 0 && c.lst[c.lst.length - 1] > x.ind) c.lst.pop();
        if (c.lst.length === 0 || c.lst[c.lst.length - 1] < x.ind) c.lst.push(x.ind);
        x.lvl = c.lst.length - 1;
        x.mk = mi[2];
        x.ord = /\d/.test(mi[2].charAt(0));
        x.num = x.ord ? parseInt(mi[2], 10) : 0;
        var cs = mi[1].length + mi[2].length + (mi[3] ? mi[3].length : 0);
        var rest = line.substring(cs);
        var mt = /^\[([ xX])\](?:[ \t]+|$)/.exec(rest);
        x.task = null;
        if (mt) {
            x.task = mt[1] === " " ? " " : "x";
            x.tcol = cs + 1;        // column of the box's state character
            cs += mt[0].length;
        }
        x.cs = cs;
        return x;
    }

    if (next !== undefined && next !== null && line.indexOf("|") >= 0 && Md.RE.tdelim.test(next)) {
        var hc = Md.cellsOf(line);
        var dc = Md.cellsOf(next);
        if (hc.length === dc.length) {
            x.t = "thead";
            x.cols = hc.length;
            x.align = dc.map(Md.alignOf);
            c.table = { cols: x.cols, align: x.align };
            c.delim = true;
            return x;
        }
    }

    if (HTML_BLOCK_RE.test(line) && !IMG_HTML_ONLY_RE.test(line)) {
        x.t = "html";
        c.htmlBlock = true;
        return x;
    }

    var im = Md.RE.imgOnly.exec(line.trim());
    if (im) {
        x.t = "image";
        x.img = _imgOf(im[1], im[2].charAt(0) === "<" ? im[2].substring(1, im[2].length - 1) : im[2]);
        return x;
    }
    if (IMG_HTML_ONLY_RE.test(line)) {
        var ai = _attrs(line.substring(line.indexOf("<img") + 4));
        var src = _safeSrc(ai.src || "");
        if (src) {
            x.t = "image";
            x.img = { src: src, alt: ai.alt || "", width: /^\d+$/.test(ai.width || "") ? parseInt(ai.width, 10) : 0 };
            return x;
        }
    }
    return x;
}

// ![alt|300](src): Obsidian's width suffix on the alt text.
function _imgOf(alt, src) {
    var w = 0;
    var m = /^(.*?)\|(\d+)(?:x\d+)?$/.exec(alt);
    if (m) {
        alt = m[1];
        w = parseInt(m[2], 10);
    }
    return { src: src, alt: alt, width: w };
}

function _indentOf(t) {
    var w = 0;
    for (var i = 0; i < t.length; i++) {
        var ch = t.charAt(i);
        if (ch === " ") w += 1;
        else if (ch === "\t") w += 4 - (w % 4);
        else break;
    }
    return w;
}

function _startsBlock(t) {
    if (Md.RE.atx.test(t) || Md.RE.rule.test(t) || Md.RE.quote.test(t)) return true;
    var mf = Md.RE.fence.exec(t);
    if (mf && !(mf[1].charAt(0) === "`" && mf[2].indexOf("`") >= 0)) return true;
    if (Md.RE.item.test(t) && _indentOf(t) < 4) return true;
    return false;
}

// After the line: which allowed inline tags are still open (they re-open at
// the next line's start). Cheap when the line has no "<".
function _htmlAfter(line, ctx, stack) {
    if (line.indexOf("<") < 0 || ctx.t === "fenceBody" || ctx.t === "fenceOpen" || ctx.t === "fenceClose"
            || ctx.t === "html" || ctx.t === "front" || ctx.t === "plain")
        return stack;
    var sp = inlineSpans(line, ctx.cs, line.length, stack, {});
    return sp.hout;
}

function _advance(line, next, c, i, opt) {
    var x = _lineCtx(line, next, c, i, opt);
    c.html = x.t === "blank" ? [] : _htmlAfter(line, x, c.html);
    // A list goes on through blank lines, items and the lines that continue an
    // item (a paragraph line right behind a list line, or one indented under
    // it); anything else ends it.
    if (x.t !== "list" && x.t !== "blank" && !(x.t === "para" && (c.prevT !== "blank" || /^[ \t]/.test(line))))
        c.lst = [];
    c.prevT = x.t;
    return x;
}

// Full pass.
function contextAll(lines, opt) {
    var c = _carry0();
    var out = new Array(lines.length);
    for (var i = 0; i < lines.length; i++) {
        out[i] = _advance(lines[i], lines[i + 1], c, i, opt);
        if (out[i].t === "setextU" && i > 0 && out[i - 1].t === "para") {
            out[i - 1].t = "setext";
            out[i - 1].lv = out[i].lv;
        }
    }
    return out;
}

// Incremental pass after an edit replaced old lines [from, oldTo) with new
// lines [from, newTo). Recomputes from two lines above the edit (a setext
// underline re-types the line above it, a table header is decided by the line
// below it) until the carried state at a line's start is what it was before
// AND the edit is behind us; the rest is the old context, shifted. Returns
// { ctx, from, to } -- the new array and the range of lines whose context was
// recomputed (the caller re-renders those).
function contextUpdate(lines, oldCtx, from, oldTo, newTo, opt) {
    try {
        return _contextUpdate(lines, oldCtx, from, oldTo, newTo, opt);
    } catch (e) {
        return { ctx: contextAll(lines, opt), from: 0, to: lines.length };
    }
}

function _contextUpdate(lines, oldCtx, from, oldTo, newTo, opt) {
    var delta = newTo - oldTo;
    var start = Math.max(0, from - 2);
    if (!oldCtx || oldCtx.length === 0 || start >= oldCtx.length)
        return { ctx: contextAll(lines, opt), from: 0, to: lines.length };
    // Lines above the edit are unchanged, so the carry a line STARTED with
    // (kept on its context) is still true: resume from it.
    var c = _cloneCarry(oldCtx[start].cin);
    var out = [];
    var i;
    var stopNew = lines.length;
    var stopOld = oldCtx.length;
    for (i = start; i < lines.length; i++) {
        if (i >= newTo + 1) {
            var oi = i - delta;
            if (oi >= 0 && oi < oldCtx.length && oldCtx[oi].ck === _carryKey(c)) {
                stopNew = i;
                stopOld = oi;
                break;
            }
        }
        var x = _advance(lines[i], lines[i + 1], c, i, opt);
        if (x.t === "setextU") {
            var prev = out.length > 0 ? out[out.length - 1] : null;
            if (prev && prev.t === "para") {
                prev.t = "setext";
                prev.lv = x.lv;
            }
        }
        out.push(x);
    }
    // The first reused line may be a setext underline whose heading line was
    // just recomputed (fresh, as a paragraph): the patch that line got from
    // its underline in the old pass has to be made again.
    var reused = oldCtx[stopOld];
    var last = out.length > 0 ? out[out.length - 1] : null;
    if (reused && reused.t === "setextU" && last && last.t === "para") {
        last.t = "setext";
        last.lv = reused.lv;
    }
    var ctx = oldCtx.slice(0, start).concat(out, oldCtx.slice(stopOld));
    return { ctx: ctx, from: start, to: stopNew };
}

// ---- Inline spans -----------------------------------------------------------------

var ALLOWED = {
    span: 1, font: 1, u: 1, ins: 1, mark: 1, sub: 1, sup: 1, b: 1, strong: 1, i: 1, em: 1,
    s: 1, del: 1, strike: 1, code: 1, kbd: 1, a: 1
};
var VOIDS = { br: 1, img: 1 };
var NAMED_KEYS = { red: "red", orange: "orange", yellow: "yellow", green: "green", teal: "teal", cyan: "teal",
                   blue: "blue", purple: "purple", violet: "purple", pink: "pink", magenta: "pink",
                   gray: "gray", grey: "gray" };
var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: "\u00a0", copy: "\u00a9", reg: "\u00ae",
                 trade: "\u2122", hellip: "\u2026", mdash: "\u2014", ndash: "\u2013", laquo: "\u00ab", raquo: "\u00bb",
                 deg: "\u00b0", plusmn: "\u00b1", times: "\u00d7", divide: "\u00f7", euro: "\u20ac", pound: "\u00a3",
                 yen: "\u00a5", cent: "\u00a2", sect: "\u00a7", para: "\u00b6", middot: "\u00b7", bull: "\u2022",
                 larr: "\u2190", rarr: "\u2192", uarr: "\u2191", darr: "\u2193", harr: "\u2194", check: "\u2713" };

function _attrs(s) {
    var out = {};
    var re = /([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/g;
    var m;
    while ((m = re.exec(s)) !== null) {
        var k = m[1].toLowerCase();
        if (k.indexOf("on") === 0)
            continue;
        out[k] = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : m[5]);
    }
    return out;
}

function _safeHref(h) {
    var v = String(h || "").trim();
    if (/^(javascript|vbscript|data):/i.test(v.replace(/[\s\u0000-\u001f]/g, "")))
        return "";
    return v;
}

function _safeSrc(h) {
    var v = String(h || "").trim();
    var squeezed = v.replace(/[\s\u0000-\u001f]/g, "");
    if (/^(javascript|vbscript):/i.test(squeezed))
        return "";
    if (/^data:/i.test(squeezed) && !/^data:image\/(png|jpe?g|gif|webp|bmp|svg\+xml);/i.test(squeezed))
        return "";
    return v;
}

// A colour value we are willing to write into Qt's html: #hex, rgb()/rgba(),
// or a plain named colour. The palette's named colours are THEMED -- `red`
// is the theme's red, Latte in light and Mocha in dark.
function _color(v, pal) {
    var s = String(v || "").trim().toLowerCase();
    if (/^#[0-9a-f]{3}([0-9a-f]{3}([0-9a-f]{2})?)?$/.test(s)) return s;
    if (/^rgba?\(\s*[\d.]+%?\s*,\s*[\d.]+%?\s*,\s*[\d.]+%?\s*(,\s*[\d.]+\s*)?\)$/.test(s)) return s;
    if (/^[a-z]{3,24}$/.test(s)) {
        var k = NAMED_KEYS[s];
        if (k && pal && pal.named && pal.named[k]) return pal.named[k];
        return s;
    }
    return "";
}

function sanitizeCss(style, pal) {
    var out = [];
    var decls = String(style || "").split(";");
    for (var i = 0; i < decls.length; i++) {
        var d = decls[i];
        var c = d.indexOf(":");
        if (c < 0) continue;
        var prop = d.substring(0, c).trim().toLowerCase();
        var val = d.substring(c + 1).trim();
        if (/url\s*\(|expression|javascript:/i.test(val)) continue;
        if (prop === "color") {
            var col = _color(val, pal);
            if (col) out.push("color:" + col);
        } else if (prop === "background-color" || prop === "background") {
            var bg = _color(val, pal);
            if (bg) out.push("background-color:" + bg);
        } else if (prop === "font-weight") {
            if (/^(bold|bolder|normal|lighter|[1-9]00)$/i.test(val)) out.push("font-weight:" + val.toLowerCase());
        } else if (prop === "font-style") {
            if (/^(italic|normal|oblique)$/i.test(val)) out.push("font-style:" + val.toLowerCase());
        } else if (prop === "text-decoration" || prop === "text-decoration-line") {
            var parts = val.toLowerCase().split(/\s+/).filter(function (p) { return p === "underline" || p === "line-through" || p === "overline" || p === "none"; });
            if (parts.length) out.push("text-decoration:" + parts.join(" "));
        }
    }
    return out.join("; ");
}

function _tagStyle(tag, attrs, pal) {
    switch (tag) {
    case "span": return { css: sanitizeCss(attrs.style, pal) };
    case "font": { var fc = _color(attrs.color, pal); return { css: fc ? "color:" + fc : "" }; }
    case "u": case "ins": return { css: "text-decoration:underline" };
    case "mark": return { css: "background-color:" + ((pal && pal.mark) || "#F0D98C") };
    case "sub": return { css: "vertical-align:sub" };
    case "sup": return { css: "vertical-align:super" };
    case "b": case "strong": return { css: "font-weight:bold" };
    case "i": case "em": return { css: "font-style:italic" };
    case "s": case "del": case "strike": return { css: "text-decoration:line-through" };
    case "code": case "kbd": return { mono: true, css: "background-color:" + ((pal && (tag === "kbd" ? pal.kbdBg : pal.codeBg)) || "#E1E4EB") };
    case "a": return { css: attrs.style ? sanitizeCss(attrs.style, pal) : "", href: _safeHref(attrs.href) || "#" };
    }
    return { css: "" };
}

// One line's inline structure, with SOURCE offsets:
//   marks  [[s, e]]             markup: hidden when rendered, faint when raw
//   styles [{s, e, k, ...}]     k: b i s code hl link wiki html
//   atoms  [{s, e, text, kind}] a source range drawn as other text when
//                               rendered (entity -> its character, an inline
//                               image -> its alt), `text` escaped by the emitter
//   hout   inline html tags still open at `to`
function inlineSpans(t, from, to, hin, pal) {
    var acc = { marks: [], styles: [], atoms: [], stack: [] };
    var i;
    // Tags carried from the lines above open at `from`.
    for (i = 0; hin && i < hin.length; i++)
        acc.stack.push({ tag: hin[i].tag, css: hin[i].css, href: hin[i].href, mono: hin[i].mono, s: from, carried: true });
    try {
        _scan(t, from, to, acc, pal, 0);
    } catch (e) {
        acc = { marks: [], styles: [], atoms: [], stack: [] };
    }
    // Whatever is still open styles the rest of the line and carries on.
    var hout = [];
    for (i = 0; i < acc.stack.length; i++) {
        var o = acc.stack[i];
        acc.styles.push({ s: o.s, e: to, k: "html", css: o.css, href: o.href, mono: o.mono });
        hout.push({ tag: o.tag, css: o.css, href: o.href, mono: o.mono });
    }
    return { marks: acc.marks, styles: acc.styles, atoms: acc.atoms, hout: hout };
}

function _scan(t, i0, i1, acc, pal, depth) {
    var i = i0;
    while (i < i1) {
        var c = t.charAt(i);

        if (c === "\\" && i + 1 < i1 && "\\`*_{}[]()#+-.!>~|\"'=<".indexOf(t.charAt(i + 1)) >= 0) {
            acc.marks.push([i, i + 1]);
            i += 2;
            continue;
        }

        if (c === "`") {
            var run = 1;
            while (i + run < i1 && t.charAt(i + run) === "`") run++;
            var mark = _rep("`", run);
            var close = t.indexOf(mark, i + run);
            while (close >= 0 && close < i1 && t.charAt(close + run) === "`")
                close = t.indexOf(mark, close + run + 1);
            if (close >= 0 && close + run <= i1) {
                acc.marks.push([i, i + run], [close, close + run]);
                acc.styles.push({ s: i + run, e: close, k: "code" });
                i = close + run;
                continue;
            }
            i += run;
            continue;
        }

        if (c === "[" && t.charAt(i + 1) === "[") {
            var wc = t.indexOf("]]", i + 2);
            if (wc > i + 2 && wc + 2 <= i1 && t.substring(i + 2, wc).indexOf("\n") < 0) {
                var inner = t.substring(i + 2, wc);
                var pipe = inner.indexOf("|");
                var target = pipe >= 0 ? inner.substring(0, pipe) : inner;
                acc.marks.push([i, i + 2], [wc, wc + 2]);
                if (pipe >= 0)
                    acc.marks.push([i + 2, i + 2 + pipe + 1]);
                acc.styles.push({ s: pipe >= 0 ? i + 3 + pipe : i + 2, e: wc, k: "wiki", href: "wiki:" + encodeURIComponent(target.trim()) });
                i = wc + 2;
                continue;
            }
        }

        if (c === "!" && t.charAt(i + 1) === "[") {
            var ib = Md.matchPair(t, i + 1, "[", "]");
            if (ib > 0 && ib < i1 && t.charAt(ib + 1) === "(") {
                var ip = Md.matchPair(t, ib + 1, "(", ")");
                if (ip > 0 && ip < i1) {
                    var alt = _imgOf(t.substring(i + 2, ib), "").alt;
                    var isrc = Md.destOf(t.substring(ib + 2, ip));
                    acc.atoms.push({ s: i, e: ip + 1, text: "\u25a3\u00a0" + (alt || "image"), kind: "img", href: _safeSrc(isrc) });
                    i = ip + 1;
                    continue;
                }
            }
        }

        if (c === "[") {
            var lb = Md.matchPair(t, i, "[", "]");
            if (lb > 0 && lb < i1 && t.charAt(lb + 1) === "(") {
                var lp = Md.matchPair(t, lb + 1, "(", ")");
                if (lp > 0 && lp < i1) {
                    var dest = Md.destOf(t.substring(lb + 2, lp));
                    acc.marks.push([i, i + 1], [lb, lp + 1]);
                    acc.styles.push({ s: i + 1, e: lb, k: "link", href: _safeHref(dest) || "#" });
                    if (depth < 4)
                        _scan(t, i + 1, lb, acc, pal, depth + 1);
                    i = lp + 1;
                    continue;
                }
            }
        }

        if ((c === "~" || c === "=") && t.charAt(i + 1) === c) {
            var dc = t.indexOf(c + c, i + 2);
            if (dc > i + 2 && dc + 2 <= i1 && t.charAt(i + 2) !== " ") {
                acc.marks.push([i, i + 2], [dc, dc + 2]);
                acc.styles.push({ s: i + 2, e: dc, k: c === "~" ? "s" : "hl" });
                if (depth < 4)
                    _scan(t, i + 2, dc, acc, pal, depth + 1);
                i = dc + 2;
                continue;
            }
        }

        if (c === "*" || c === "_") {
            var erun = 1;
            while (i + erun < i1 && t.charAt(i + erun) === c) erun++;
            var prev = i > 0 ? t.charAt(i - 1) : " ";
            var after = t.charAt(i + erun);
            var ok = !(c === "_" && Md.isWordChar(prev)) && after !== "" && after !== " " && after !== "\n" && i + erun < i1;
            if (ok) {
                var want = Math.min(erun, 3);
                var ec = Md.findEmphClose(t, i + erun, c, want);
                if (ec > 0 && ec + want <= i1) {
                    // The opener may be longer than what closes it: the extra
                    // characters are literal, the markup is the inner `want`.
                    var os = i + erun - want;
                    acc.marks.push([os, os + want], [ec, ec + want]);
                    if (want >= 2) acc.styles.push({ s: os + want, e: ec, k: "b" });
                    if (want !== 2) acc.styles.push({ s: os + want, e: ec, k: "i" });
                    if (depth < 4)
                        _scan(t, os + want, ec, acc, pal, depth + 1);
                    i = ec + want;
                    continue;
                }
            }
            i += erun;
            continue;
        }

        if (c === "<") {
            var rest = t.substring(i, i1);
            var cm = /^<!--[\s\S]*?-->/.exec(rest);
            if (cm) {
                acc.marks.push([i, i + cm[0].length]);
                i += cm[0].length;
                continue;
            }
            var tm = /^<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[^<>]*?)?)\s*(\/?)>/.exec(rest);
            if (tm) {
                var tag = tm[2].toLowerCase();
                var end = i + tm[0].length;
                if (VOIDS[tag] && !tm[1]) {
                    if (tag === "br") {
                        acc.atoms.push({ s: i, e: end, text: "\u21b5", kind: "br" });
                    } else {
                        var ia = _attrs(tm[3]);
                        acc.atoms.push({ s: i, e: end, text: "\u25a3\u00a0" + (ia.alt || "image"), kind: "img", href: _safeSrc(ia.src) });
                    }
                    i = end;
                    continue;
                }
                if (ALLOWED[tag]) {
                    acc.marks.push([i, end]);
                    if (!tm[1] && !tm[4]) {
                        var st = _tagStyle(tag, _attrs(tm[3]), pal);
                        acc.stack.push({ tag: tag, css: st.css, href: st.href, mono: st.mono, s: end });
                    } else if (tm[1]) {
                        for (var k = acc.stack.length - 1; k >= 0; k--) {
                            if (acc.stack[k].tag === tag) {
                                var o = acc.stack[k];
                                acc.styles.push({ s: o.s, e: i, k: "html", css: o.css, href: o.href, mono: o.mono });
                                acc.stack.splice(k, 1);
                                break;
                            }
                        }
                    }
                    i = end;
                    continue;
                }
            }
        }

        if (c === "&") {
            var em = /^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z]{2,8});/.exec(t.substring(i, Math.min(i1, i + 12)));
            if (em) {
                var ch = null;
                var name = em[1];
                if (name.charAt(0) === "#") {
                    var cp = name.charAt(1) === "x" || name.charAt(1) === "X" ? parseInt(name.substring(2), 16) : parseInt(name.substring(1), 10);
                    if (cp > 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF))
                        ch = String.fromCodePoint(cp);
                } else if (ENTITIES[name]) {
                    ch = ENTITIES[name];
                }
                if (ch !== null) {
                    acc.atoms.push({ s: i, e: i + em[0].length, text: ch, kind: "entity" });
                    i += em[0].length;
                    continue;
                }
            }
        }

        if ((c === "h" || c === "H") && (i === 0 || !Md.isWordChar(t.charAt(i - 1)))) {
            Md.RE.autolink.lastIndex = i;
            var am = Md.RE.autolink.exec(t);
            if (am && am.index === i) {
                var url = am[0].replace(/[.,;:!?)]+$/, "");
                if (i + url.length <= i1) {
                    acc.styles.push({ s: i, e: i + url.length, k: "link", href: url });
                    i += url.length;
                    continue;
                }
            }
        }
        i++;
    }
}

function _rep(c, n) {
    var s = "";
    for (var i = 0; i < n; i++) s += c;
    return s;
}

// ---- Segments and emitters ------------------------------------------------------------

function _esc(ch) {
    if (ch === "&") return "&amp;";
    if (ch === "<") return "&lt;";
    if (ch === ">") return "&gt;";
    if (ch === "\"") return "&quot;";
    if (ch === "\r") return "\u240d";     // a lone CR would become a paragraph break
    return ch;
}

function _escStr(s) {
    var o = "";
    for (var i = 0; i < s.length; i++) o += _esc(s.charAt(i));
    return o;
}

// Which inline structure applies to a line, by its block type.
function _inlineRange(text, ctx) {
    switch (ctx.t) {
    case "para": case "head": case "setext": case "list": case "quote": case "callout": case "trow": case "thead":
        return { from: ctx.cs || 0, to: text.length };
    }
    return null;
}

function _styleCss(st, pal, opt) {
    var css = [];
    var deco = [];
    var mono = false;
    var href = null;
    for (var i = 0; i < st.length; i++) {
        var s = st[i];
        switch (s.k) {
        case "b": css.push("font-weight:bold"); break;
        case "i": css.push("font-style:italic"); break;
        case "s": deco.push("line-through"); break;
        case "hl": css.push("background-color:" + (pal.mark || "#F0D98C")); break;
        case "code":
            mono = true;
            css.push("background-color:" + (pal.codeBg || "#E1E4EB"));
            if (pal.codeFg) css.push("color:" + pal.codeFg);
            break;
        case "link": case "wiki":
            href = s.href;
            css.push("color:" + (pal.link || "#4480F4"));
            break;
        case "html":
            if (s.css) {
                var parts = s.css.split(";");
                for (var p = 0; p < parts.length; p++) {
                    var d = parts[p].trim();
                    if (!d) continue;
                    if (d.indexOf("text-decoration:") === 0) deco = deco.concat(d.substring(16).split(" "));
                    else css.push(d);
                }
            }
            if (s.mono) mono = true;
            if (s.href) { href = s.href; if (!s.css || s.css.indexOf("color:") < 0) css.push("color:" + (pal.link || "#4480F4")); }
            break;
        }
    }
    if (mono && opt && opt.monoFamily) css.push("font-family:'" + opt.monoFamily + "'");
    if (deco.length) css.push("text-decoration:" + deco.filter(function (d, k) { return d && d !== "none" && deco.indexOf(d) === k; }).join(" "));
    return { css: css.join("; "), href: href };
}

// Split [0, text.length) into runs that share one fate (hidden or not, the
// same styles, inside an atom or not).
function _segments(text, ctx, pal, opt) {
    var n = text.length;
    var sp = null;
    var range = _inlineRange(text, ctx);
    if (range)
        sp = inlineSpans(text, range.from, range.to, ctx.hin || [], pal);
    var cut = {};
    cut[0] = 1;
    cut[n] = 1;
    var blockEnd = Math.min(n, ctx.cs || 0);
    cut[blockEnd] = 1;
    var i, k;
    if (sp) {
        for (i = 0; i < sp.marks.length; i++) { cut[sp.marks[i][0]] = 1; cut[sp.marks[i][1]] = 1; }
        for (i = 0; i < sp.styles.length; i++) { cut[sp.styles[i].s] = 1; cut[sp.styles[i].e] = 1; }
        for (i = 0; i < sp.atoms.length; i++) { cut[sp.atoms[i].s] = 1; cut[sp.atoms[i].e] = 1; }
    }
    var pts = Object.keys(cut).map(Number).filter(function (v) { return v >= 0 && v <= n; }).sort(function (a, b) { return a - b; });
    var segs = [];
    for (k = 0; k + 1 < pts.length; k++) {
        var s = pts[k], e = pts[k + 1];
        if (e <= s) continue;
        var seg = { s: s, e: e, block: s < blockEnd, mark: false, atom: null, styles: [] };
        if (sp) {
            for (i = 0; i < sp.marks.length; i++)
                if (sp.marks[i][0] <= s && e <= sp.marks[i][1]) { seg.mark = true; break; }
            for (i = 0; i < sp.atoms.length; i++)
                if (sp.atoms[i].s <= s && e <= sp.atoms[i].e) { seg.atom = sp.atoms[i]; break; }
            for (i = 0; i < sp.styles.length; i++)
                if (sp.styles[i].s <= s && e <= sp.styles[i].e) seg.styles.push(sp.styles[i]);
        }
        segs.push(seg);
    }
    return segs;
}

// A link carries its style on the <a> itself: Qt underlines anchors unless
// told otherwise, and a note's own html may still ask for the underline.
function _wrap(inner, css, href) {
    if (!inner) return "";
    if (href) {
        var acss = css + (css.indexOf("text-decoration") >= 0 ? "" : (css ? "; " : "") + "text-decoration:none");
        return "<a href=\"" + _escStr(href) + "\" style=\"" + acss + "\">" + inner + "</a>";
    }
    return css ? "<span style=\"" + css + "\">" + inner + "</span>" : inner;
}

// RAW html: every source character exactly once, in order, escaped. Block
// markup and inline markers are faint; content keeps its style so revealing a
// line does not restyle it. Code-fence body lines are highlighted by the
// caller's `opt.codeRuns` ([{text, cls}] covering the line exactly).
function rawHtml(text, ctx, pal, opt) {
    try {
        return _rawHtml(text, ctx, pal || {}, opt || {});
    } catch (e) {
        return "<div style=\"white-space:pre-wrap\">" + _escStr(text) + "</div>";
    }
}

function _rawHtml(text, ctx, pal, opt) {
    var body = "";
    var faint = pal.faint || "#8A8A8C";
    var t = ctx.t;
    if (t === "fenceBody" || t === "plain") {
        body = _codeRunsHtml(text, opt.codeRuns, pal);
    } else if (t === "fenceOpen" || t === "fenceClose" || t === "front" || t === "tdelim" || t === "rule" || t === "setextU") {
        body = "<span style=\"color:" + faint + "\">" + _escStr(text) + "</span>";
    } else if (t === "html") {
        body = "<span style=\"color:" + (pal.muted || faint) + "\">" + _escStr(text) + "</span>";
    } else {
        var segs = _segments(text, ctx, pal, opt);
        for (var i = 0; i < segs.length; i++) {
            var sg = segs[i];
            var txt = _escStr(text.substring(sg.s, sg.e));
            if (sg.block || sg.mark) {
                body += "<span style=\"color:" + faint + "\">" + txt + "</span>";
                continue;
            }
            var st = _styleCss(sg.styles, pal, opt);
            body += st.css ? "<span style=\"" + st.css + "\">" + txt + "</span>" : txt;
        }
    }
    return "<div style=\"white-space:pre-wrap\">" + body + "</div>";
}

function _codeRunsHtml(text, runs, pal) {
    if (!runs || !runs.length)
        return _escStr(text);
    var out = "";
    var at = 0;
    for (var i = 0; i < runs.length && at < text.length; i++) {
        var piece = runs[i].text;
        var col = pal.code ? pal.code[runs[i].cls] : null;
        var esc = _escStr(piece);
        out += col ? "<span style=\"color:" + col + "\">" + esc + "</span>" : esc;
        at += piece.length;
    }
    if (at < text.length)
        out += _escStr(text.substring(at));
    return out;
}

// RENDERED html + the map back to the source.
//   { html, r2s: [source column per rendered position, plus one for the end],
//     len: rendered length, empty: nothing visible }
// A line whose content is drawn by the delegate itself (a rule, a fence's
// delimiters, a table, an image, a folded frontmatter) renders empty.
function renderLine(text, ctx, pal, opt) {
    try {
        return _renderLine(text, ctx, pal || {}, opt || {});
    } catch (e) {
        var r = [];
        for (var i = 0; i <= text.length; i++) r.push(i);
        return { html: "<div style=\"white-space:pre-wrap\">" + _escStr(text) + "</div>", r2s: r, len: text.length, empty: text.length === 0 };
    }
}

function _renderLine(text, ctx, pal, opt) {
    var t = ctx.t;
    var r2s = [];
    var body = "";
    var i;
    if (t === "fenceBody" || t === "plain") {
        for (i = 0; i <= text.length; i++) r2s.push(i);
        return { html: "<div style=\"white-space:pre-wrap\">" + _codeRunsHtml(text, opt.codeRuns, pal) + "</div>", r2s: r2s, len: text.length, empty: false };
    }
    if (t === "html") {
        for (i = 0; i <= text.length; i++) r2s.push(i);
        return { html: "<div style=\"white-space:pre-wrap\"><span style=\"color:" + (pal.muted || "#6F6F72") + "\">" + _escStr(text) + "</span></div>", r2s: r2s, len: text.length, empty: false };
    }
    if (t === "blank" || t === "rule" || t === "fenceOpen" || t === "fenceClose" || t === "setextU" || t === "tdelim"
            || t === "trow" || t === "thead" || t === "front" || t === "image") {
        return { html: "", r2s: [text.length], len: 0, empty: true };
    }
    var segs = _segments(text, ctx, pal, opt);
    var runCss = null, runHref = null, run = "";
    function flush() {
        if (run) body += _wrap(run, runCss, runHref);
        run = "";
    }
    for (i = 0; i < segs.length; i++) {
        var sg = segs[i];
        if (sg.block || sg.mark) continue;
        var st = _styleCss(sg.styles, pal, opt);
        var piece, k;
        if (sg.atom) {
            if (sg.s !== sg.atom.s) continue;          // an atom spans several segments; draw it once
            piece = sg.atom.text;
            if (sg.atom.kind === "img") {
                st = { css: "color:" + (pal.link || "#4480F4"), href: sg.atom.href || null };
            } else if (sg.atom.kind === "br") {
                st = { css: "color:" + (pal.faint || "#8A8A8C"), href: null };
            }
            for (k = 0; k < piece.length; k++) r2s.push(sg.atom.s);
        } else {
            piece = text.substring(sg.s, sg.e);
            for (k = 0; k < piece.length; k++) r2s.push(sg.s + k);
        }
        if (st.css !== runCss || st.href !== runHref) {
            flush();
            runCss = st.css;
            runHref = st.href;
        }
        run += _escStr(piece);
    }
    flush();
    r2s.push(text.length);
    return { html: "<div style=\"white-space:pre-wrap\">" + body + "</div>", r2s: r2s, len: r2s.length - 1, empty: r2s.length === 1 };
}

// Rendered position -> source column, and back.
function toSource(r2s, pos) {
    if (!r2s || r2s.length === 0) return 0;
    return r2s[Math.max(0, Math.min(r2s.length - 1, pos))];
}
function toRendered(r2s, col) {
    if (!r2s || r2s.length === 0) return 0;
    for (var i = 0; i < r2s.length; i++)
        if (r2s[i] >= col) return i;
    return r2s.length - 1;
}

// ---- Code fences -------------------------------------------------------------
//
// A fence is highlighted as ONE piece of code (a block comment or a string
// spans lines) and the runs are split back per line. `lines` is the note,
// `open` the fence's opening line, `close` its closing line (or lines.length).
function fenceRuns(lines, open, close, lang) {
    var body = lines.slice(open + 1, close);
    var runs = Md.highlight(body.join("\n"), lang);
    var per = [];
    var cur = [];
    for (var i = 0; i < runs.length; i++) {
        var parts = runs[i].text.split("\n");
        for (var p = 0; p < parts.length; p++) {
            if (p > 0) {
                per.push(cur);
                cur = [];
            }
            if (parts[p].length) cur.push({ text: parts[p], cls: runs[i].cls });
        }
    }
    per.push(cur);
    while (per.length < body.length) per.push([]);
    return per;
}

// ---- Tables --------------------------------------------------------------------------

// A rendered table cell: inline markdown with markers omitted (no map: a
// click on a table puts the caret on the row's line).
function cellHtml(cell, pal, opt) {
    var ctx = { t: "para", cs: 0, hin: [] };
    return renderLine(cell, ctx, pal, opt).html;
}

// ---- Resolving an image source ---------------------------------------------------------
//
// Relative sources resolve against the directory of the note's REAL file (a
// symlinked foreign note keeps its own neighbours). Returns a URL string or "".
function resolveSrc(src, realDir, home) {
    var s = String(src || "").trim();
    if (!s) return "";
    if (/^(https?|file|data|qrc):/i.test(s)) return s;
    if (s.charAt(0) === "<" && s.charAt(s.length - 1) === ">") s = s.substring(1, s.length - 1);
    try { s = decodeURIComponent(s); } catch (e) { }
    var path;
    if (s.indexOf("~/") === 0) path = (home || "") + s.substring(1);
    else if (s.charAt(0) === "/") path = s;
    else path = _normPath((realDir || "") + "/" + s);
    return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F");
}

function _normPath(p) {
    var parts = p.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var x = parts[i];
        if (x === "" || x === ".") { if (i === 0) out.push(""); continue; }
        if (x === "..") { if (out.length > 1) out.pop(); continue; }
        out.push(x);
    }
    return out.join("/") || "/";
}

// A path relative from directory `fromDir` to `to` (both absolute).
function relativePath(fromDir, to) {
    var a = _normPath(fromDir).split("/").filter(function (x) { return x; });
    var b = _normPath(to).split("/").filter(function (x) { return x; });
    var k = 0;
    while (k < a.length && k < b.length && a[k] === b[k]) k++;
    var up = [];
    for (var i = k; i < a.length; i++) up.push("..");
    return up.concat(b.slice(k)).join("/");
}

// Markdown for linking an image: angle brackets when the path has spaces
// (CommonMark), so "Pasted image 2026.png" stays one destination.
function imageMarkdown(path, alt) {
    var p = /[\s()<>]/.test(path) ? "<" + path + ">" : path;
    return "![" + (alt || "") + "](" + p + ")";
}

// ---- Thumbnails -------------------------------------------------------------------------
//
// The first lines of a note as a tile shows them: images, code, tables,
// frontmatter, html blocks and rules skipped, blank runs collapsed, a leading
// heading that repeats the title dropped. Lists keep their bullets (a task's
// box as a glyph), headings stay bold.
//
// Emitted as Qt's StyledText, NOT RichText: a tile's preview re-lays out on
// every step of a live resize, and RichText (a QTextDocument per tile) cost
// the grid 4.6 ms of polish per frame, StyledText 1.1 (measured, 12 tiles,
// 120 Hz). StyledText has no CSS, so colour is <font color>, emphasis is
// <b>/<i>/<s>, and the highlighter's fill is dropped (the words stay).
function thumbHtml(text, title, pal, opt) {
    try {
        return _thumbStyled(String(text || ""), String(title || ""), pal || {}, opt || {});
    } catch (e) {
        return "";
    }
}

function _cssColor(css) {
    var m = /(?:^|;)\s*color:\s*([^;]+)/.exec(css || "");
    return m ? m[1].trim() : "";
}

// One line as StyledText: markers omitted, styles as tags.
function _styledLine(text, ctx, pal) {
    var segs = _segments(text, ctx, pal, {});
    var out = "";
    for (var i = 0; i < segs.length; i++) {
        var sg = segs[i];
        if (sg.block || sg.mark)
            continue;
        var piece;
        if (sg.atom) {
            if (sg.s !== sg.atom.s)
                continue;
            piece = _escStr(sg.atom.text);
        } else {
            piece = _escStr(text.substring(sg.s, sg.e));
        }
        var open = "", close = "", colour = "";
        for (var k = 0; k < sg.styles.length; k++) {
            var st = sg.styles[k];
            if (st.k === "b") { open += "<b>"; close = "</b>" + close; }
            else if (st.k === "i") { open += "<i>"; close = "</i>" + close; }
            else if (st.k === "s") { open += "<s>"; close = "</s>" + close; }
            else if (st.k === "link" || st.k === "wiki") colour = pal.link || colour;
            else if (st.k === "code") colour = pal.muted || colour;
            else if (st.k === "html") {
                var c = _cssColor(st.css);
                if (c) colour = c;
                if (/font-weight:\s*(bold|[6-9]00)/.test(st.css || "")) { open += "<b>"; close = "</b>" + close; }
                if (/font-style:\s*italic/.test(st.css || "")) { open += "<i>"; close = "</i>" + close; }
                if (/line-through/.test(st.css || "")) { open += "<s>"; close = "</s>" + close; }
            }
        }
        if (sg.atom && sg.atom.kind === "img")
            colour = pal.link || colour;
        if (colour) { open = "<font color=\"" + colour + "\">" + open; close = close + "</font>"; }
        out += open + piece + close;
    }
    return out;
}

function _thumbStyled(text, title, pal, opt) {
    var maxLines = opt.maxLines || 10;
    var lines = text.split("\n").slice(0, 80).map(function (l) { return l.replace(/\r$/, ""); });
    if (lines.length && lines[0].charAt(0) === "\ufeff") lines[0] = lines[0].substring(1);
    var ctx = contextAll(lines, opt);
    var out = [];
    var lastBlank = true;
    var first = true;
    var shown = 0;
    for (var i = 0; i < lines.length && shown < maxLines; i++) {
        var x = ctx[i];
        var t = x.t;
        if (t === "front" || t === "fenceOpen" || t === "fenceBody" || t === "fenceClose" || t === "thead" || t === "tdelim"
                || t === "trow" || t === "image" || t === "html" || t === "rule" || t === "setextU")
            continue;
        if (t === "blank") {
            if (!lastBlank && out.length) out.push("");
            lastBlank = true;
            continue;
        }
        if (first && (t === "head" || t === "setext")) {
            var ht = lines[i].substring(x.cs).replace(/[ \t]+#+[ \t]*$/, "").trim();
            if (ht.toLowerCase() === title.trim().toLowerCase()) {
                first = false;
                continue;
            }
        }
        first = false;
        lastBlank = false;
        var body = t === "plain" ? _escStr(lines[i]) : _styledLine(lines[i], x, pal);
        var lead = "";
        if (t === "list") {
            var pad = Math.min(4, Math.floor((x.ind || 0) / 2));
            lead = _rep("\u2002", pad) + (x.task !== null && x.task !== undefined ? (x.task === "x" ? "\u2611 " : "\u2610 ") : (x.ord ? x.num + ". " : "\u2022 "));
        } else if (t === "quote" || t === "callout") {
            lead = "<font color=\"" + (pal.faint || "#8A8A8C") + "\">\u258e</font>";
        }
        if (t === "head" || t === "setext" || (t === "callout" && x.coHead))
            body = "<b>" + body + "</b>";
        if (t === "list" && x.task === "x")
            body = "<font color=\"" + (pal.faint || "#8A8A8C") + "\">" + body + "</font>";
        out.push(lead + body);
        shown++;
    }
    while (out.length && out[out.length - 1] === "") out.pop();
    return out.join("<br>");
}

// The display title of a file name: `.md` hidden, every other extension kept.
function titleOf(name) {
    var s = String(name || "");
    return /\.md$/i.test(s) ? s.substring(0, s.length - 3) : s;
}
