.pragma library
.import "../../common/components/FuzzyMatch.js" as Fuzzy

// =============================================================================
// PickerModel.js -- the picker's pure half: the data asset's shape, search, the skin tone, the grid's rows.
//
//   parse(text)                      -> data | null     picker_data.json (tools/picker/build_data.py), validated
//   index(data)                      -> idx             items with their lower-case search forms, `byChar`, the tabs' sets
//   toned(ch, tone, tones)           -> string          `ch` with the skin tone `tone` (0 = none, 1..5) applied
//   digitsOf(query)                  -> "" | "233"      a query that is only digits (the alt-code jump)
//   search(items, query)             -> [item]          ranked; words first, the fuzzy fallback only when nothing matched
//   altMatches(items, digits)        -> [item]          alt codes that START with the digits, the exact code first
//   dedupe(items)                    -> [item]          the first of each character
//   parseNerd(text)                  -> asset | null    the Nerd Fonts asset (tools/picker/nerd_fetch.py), validated
//   indexNerd(asset)                 -> nidx            { family, version, sets [{id, label, glyph, items}], items }  (no byChar: see nerdFind)
//   nerdFind(nidx, want)             -> { ch: item }    the items of a few characters, one pass
//   searchNerd(items, query, fuzzy)  -> [item]          ranked; the name's words (`nf-md-lightbulb_on` is md, lightbulb, on)
//   groupBySet(sets, hits)           -> [section]       a hit list cut into one section per icon set, in the set order
//   asName(item)                     -> item            the same item, picked as its NAME (Ctrl+Enter on the Nerd tab)
//   isPrivateUse(ch)                 -> bool            one code point in a private use area (a Nerd Fonts glyph)
//   layout(sections, g)              -> L               every row of the grid, with y and height (whole pixels)
//   cellRect(L, i)                   -> {x, y, w, h}    a tile's rect, edges rounded one by one
//   rowAt(L, y)                      -> row index       the row at content y (binary search)
//   indexAt(L, x, y)                 -> flat index | -1
//   move(L, i, dRow, dCol)           -> flat index
//
// An ITEM is { ch, name, kw, tab, set, tonable, codes, nameL, kwL, nameWords, kwWords }: the data's row, plus the words
// matched against. `tab` is "emoji" | "symbols" | "nerd"; `set` an emoji category id, a symbol set id or an icon set id. A NERD item
// is { ch, name ("nf-md-home"), key ("md-home"), tab, set, code ("f02dc"), nameW (" md home"), kwW (the other names' words), setW (the
// set's label words) }: ~10 600 of them, so a search over them is native string work (indexOf on the one prepared string), no per-word arrays.
//
// THE SEARCH is words, not letters: every term of the query must be found, in the name or in the keywords, as the start of
// a word (100 / 80) or anywhere (60 / 40), an exact name 200. The fuzzy subsequence match (FuzzyMatch) runs ONLY when no item
// matched at all ("hrt" finds the heart): 1900 emoji and 3000 symbols through the fuzzy programme on every keystroke is tens
// of milliseconds in the shell's QML engine, and a words pass is a tenth of one.
//
// THE GRID is laid out in ROWS, in whole pixels: a header row (a section's label) and tile rows (`cols` tiles of one profile).
// A tile's column edges are `round(col * w / cols)`, so the tiles fill the width exactly and every edge is a whole pixel.
// =============================================================================

var MODS = ["🏻", "🏼", "🏽", "🏾", "🏿"];

function parse(text) {
    var d;
    try {
        d = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!d || d.version !== 1 || !d.emoji || !d.emoji.rows || !d.symbols || !d.symbols.sets)
        return null;
    return d;
}

function _words(s) {
    var out = [];
    var parts = s.split(/[^a-z0-9]+/);
    for (var i = 0; i < parts.length; i++)
        if (parts[i] !== "")
            out.push(parts[i]);
    return out;
}

function _item(ch, name, kw, tab, set, tonable, codes) {
    var nameL = name.toLowerCase();
    var kwL = (kw || "").toLowerCase();
    return {
        ch: ch,
        name: name,
        kw: kw || "",
        tab: tab,
        set: set,
        tonable: tonable === 1,
        codes: codes || [],
        nameL: nameL,
        kwL: kwL,
        nameWords: _words(nameL),
        kwWords: _words(kwL)
    };
}

function index(data) {
    var byChar = {};
    var byCat = {};
    var emoji = [];
    var rows = data.emoji.rows;
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var it = _item(r[0], r[1], r[2], "emoji", data.emoji.cats[r[3]].id, r[4], null);
        emoji.push(it);
        byChar[it.ch] = it;
        (byCat[it.set] = byCat[it.set] || []).push(it);
    }
    var sets = [];
    var all = [];
    for (var s = 0; s < data.symbols.sets.length; s++) {
        var set = data.symbols.sets[s];
        var items = [];
        for (var j = 0; j < set.rows.length; j++) {
            var q = set.rows[j];
            var codes = set.id === "alt" ? q[2] : [];
            // an alt code is also a keyword: "233" in the Emoji tab's neighbour finds the theta by name search too
            var sym = _item(q[0], q[1], codes.length > 0 ? codes.join(" ") : "", "symbols", set.id, 0, codes);
            items.push(sym);
            all.push(sym);
            if (byChar[sym.ch] === undefined)
                byChar[sym.ch] = sym;
        }
        sets.push({ id: set.id, label: set.label, glyph: set.glyph, tile: set.tile, items: items });
    }
    return {
        cats: data.emoji.cats,
        emoji: emoji,
        byCat: byCat,
        sets: sets,
        symbols: all,
        byChar: byChar,
        tones: data.tones
    };
}

// ---- Nerd Fonts ---------------------------------------------------------------------------
// The asset is the cache file tools/picker/nerd_fetch.py writes: only the glyphs the installed font draws, one row per character.
function parseNerd(text) {
    var d;
    try {
        d = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!d || d.version !== 1 || !d.rows || !d.sets || !d.family)
        return null;
    return d;
}

function isPrivateUse(ch) {
    var s = String(ch);
    var cp = s.codePointAt(0);
    if (cp === undefined || s.length !== (cp > 0xFFFF ? 2 : 1))
        return false;
    return (cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0xFFFFD) || (cp >= 0x100000 && cp <= 0x10FFFD);
}

function _nerdWords(s) {
    return " " + s.replace(/nf-/g, "").replace(/[-_]+/g, " ");
}

function indexNerd(asset) {
    var sets = [];
    var setW = [];
    for (var s = 0; s < asset.sets.length; s++) {
        var st = asset.sets[s];
        sets.push({ id: st.id, label: st.label, glyph: st.glyph, items: [] });
        setW.push(" " + st.label.toLowerCase());
    }
    var items = [];
    var rows = asset.rows;
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var set = sets[r[2]];
        var it = {
            ch: r[0],
            name: r[1],
            kw: "",
            tab: "nerd",
            set: set.id,
            tonable: false,
            codes: [],
            code: r[3],
            key: r[1].slice(3),
            nameW: _nerdWords(r[1].toLowerCase()),
            kwW: r[4] !== "" ? _nerdWords(r[4].toLowerCase()) : "",
            setW: setW[r[2]]
        };
        set.items.push(it);
        items.push(it);
    }
    return { family: asset.family, version: asset.nerd, sets: sets, items: items };
}

// A term of a Nerd query: "nf-md-lightbulb_on" is one term that means the words "md lightbulb on", in that order.
function _nerdTerm(t) {
    var raw = t.replace(/^nf-/, "");
    return { raw: raw, words: raw.replace(/[-_]+/g, " ").trim() };
}

function _nerdScore(it, t) {
    if (it.key === t.raw)
        return 200;
    var at = it.nameW.indexOf(" " + t.words);
    if (at === 0)
        return 110;
    if (at > 0)
        return 100;
    if (it.kwW.indexOf(" " + t.words) >= 0)
        return 80;
    // the set's own words ("material design home"), as the START of a word only: "on" is not "Font Awesome"
    if (it.setW.indexOf(" " + t.words) >= 0)
        return 70;
    if (it.nameW.indexOf(t.words) >= 0)
        return 60;
    if (it.kwW.indexOf(t.words) >= 0)
        return 40;
    return 0;
}

// Words first. `fuzzyMin` (a number of letters, 0 = never): when no word matched and the query is at least that long, the letters are
// looked for IN ORDER inside the name ("hme" finds md-home): one native indexOf per letter, never FuzzyMatch -- its alignment over ~10 600
// names is half a second in the shell's QML engine. Ranked by how tightly the letters sit, then the shorter name.
// The hits are ranked as ONE packed number each (score, name length, place), sorted as numbers: objects in the sort cost four times as much.
function searchNerd(items, query, fuzzyMin) {
    var raws = _terms(query);
    var terms = [];
    for (var k = 0; k < raws.length; k++) {
        var t = _nerdTerm(raws[k]);
        if (t.words !== "")
            terms.push(t);
    }
    if (terms.length === 0)
        return items.slice();
    var n = items.length;
    var packs = [];
    for (var i = 0; i < n; i++) {
        var it = items[i];
        var score = 0;
        for (var j = 0; j < terms.length; j++) {
            var s = _nerdScore(it, terms[j]);
            if (s === 0) {
                score = 0;
                break;
            }
            score += s;
        }
        if (score > 0)
            packs.push(((1000 - score) * 256 + Math.min(it.key.length, 255)) * n + i);
    }
    if (packs.length === 0 && fuzzyMin > 0) {
        var letters = terms.map(function (x) {
            return x.words.replace(/ /g, "");
        }).join("");
        if (letters.length >= fuzzyMin) {
            for (var f = 0; f < n; f++) {
                var key = items[f].key;
                var first = key.indexOf(letters.charAt(0));
                if (first < 0)
                    continue;
                var at = first;
                for (var c = 1; c < letters.length && at >= 0; c++)
                    at = key.indexOf(letters.charAt(c), at + 1);
                if (at >= 0)
                    packs.push(((at - first + 1) * 256 + Math.min(key.length, 255)) * n + f);
            }
        }
    }
    packs.sort(function (a, b) {
        return a - b;
    });
    var out = [];
    for (var h = 0; h < packs.length; h++)
        out.push(items[packs[h] % n]);
    return out;
}

// The items for these characters (an object { "<char>": true }), in one pass over the list: a Nerd tile cannot be looked up by character
// in a map (10 600 keys cost ~700 ms to build in the shell's QML engine); the recents ask for a few.
function nerdFind(nidx, want) {
    var found = {};
    var left = 0;
    for (var k in want)
        left++;
    if (left === 0)
        return found;
    var items = nidx.items;
    for (var i = 0; i < items.length && left > 0; i++) {
        if (want[items[i].ch] === true && found[items[i].ch] === undefined) {
            found[items[i].ch] = items[i];
            left--;
        }
    }
    return found;
}

// Hits cut into one section per icon set (the set order, the hits' order inside), each with the set's label and the Nerd tile profile.
function groupBySet(sets, hits) {
    var by = {};
    for (var i = 0; i < hits.length; i++)
        (by[hits[i].set] = by[hits[i].set] || []).push(hits[i]);
    var out = [];
    for (var s = 0; s < sets.length; s++)
        if (by[sets[s].id])
            out.push({ id: sets[s].id, label: sets[s].label + " (" + by[sets[s].id].length + ")", profile: "nerd", items: by[sets[s].id] });
    return out;
}

// The item picked as its name: the same fields (read through the prototype), pasting `name`.
function asName(it) {
    var o = Object.create(it);
    o.asName = true;
    return o;
}

// ---- the skin tone ------------------------------------------------------------------------
// The modifier goes right after the first code point (a hand, a person); a variation selector that followed it goes.
// A ZWJ sequence keeps the rest: man gesturing OK + moderate skin = U+1F646 U+1F3FD ZWJ U+2642 U+FE0F.
function toned(ch, tone, tones) {
    if (!tone || tone < 1 || tone > 5)
        return ch;
    var mod = tones && tones[tone - 1] ? tones[tone - 1].mod : MODS[tone - 1];
    var cp = ch.codePointAt(0);
    var firstLen = cp > 0xFFFF ? 2 : 1;
    var rest = ch.slice(firstLen);
    if (rest.charCodeAt(0) === 0xFE0F)
        rest = rest.slice(1);
    return ch.slice(0, firstLen) + mod + rest;
}

// ---- search -------------------------------------------------------------------------------
function digitsOf(query) {
    var q = String(query || "").trim();
    return /^[0-9]{1,4}$/.test(q) ? q : "";
}

function _terms(query) {
    var parts = String(query || "").toLowerCase().split(/\s+/);
    var out = [];
    for (var i = 0; i < parts.length; i++)
        if (parts[i] !== "")
            out.push(parts[i]);
    return out;
}

function _startsAny(words, t) {
    for (var i = 0; i < words.length; i++)
        if (words[i].indexOf(t) === 0)
            return true;
    return false;
}

function _termScore(it, t) {
    if (it.nameL === t)
        return 200;
    if (_startsAny(it.nameWords, t))
        return it.nameWords[0].indexOf(t) === 0 ? 110 : 100;
    if (it.kwWords.indexOf(t) >= 0)
        return 90;
    if (_startsAny(it.kwWords, t))
        return 80;
    if (it.nameL.indexOf(t) >= 0)
        return 60;
    if (it.kwL.indexOf(t) >= 0)
        return 40;
    return 0;
}

function search(items, query) {
    var terms = _terms(query);
    if (terms.length === 0)
        return items.slice();
    var hits = [];
    for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var score = 0;
        for (var k = 0; k < terms.length; k++) {
            var s = _termScore(it, terms[k]);
            if (s === 0) {
                score = 0;
                break;
            }
            score += s;
        }
        if (score > 0)
            hits.push({ it: it, score: score, i: i });
    }
    if (hits.length === 0) {
        for (var j = 0; j < items.length; j++) {
            var f = Fuzzy.bestScore(query, [items[j].nameL, items[j].kwL], [1, 0.6]);
            if (f !== null && f > 0)
                hits.push({ it: items[j], score: f, i: j });
        }
    }
    hits.sort(function (a, b) {
        return b.score - a.score || a.i - b.i;
    });
    var out = [];
    for (var h = 0; h < hits.length; h++)
        out.push(hits[h].it);
    return out;
}

// Alt codes that start with `digits`; the code that IS `digits` first ("233" is the theta, then 230-239; "0233" is the e acute).
function altMatches(items, digits) {
    var exact = [];
    var prefix = [];
    for (var i = 0; i < items.length; i++) {
        var codes = items[i].codes;
        var isExact = false;
        var isPrefix = false;
        for (var c = 0; c < codes.length; c++) {
            if (codes[c] === digits)
                isExact = true;
            else if (codes[c].indexOf(digits) === 0)
                isPrefix = true;
        }
        if (isExact)
            exact.push(items[i]);
        else if (isPrefix)
            prefix.push(items[i]);
    }
    return exact.concat(prefix);
}

// The first of each character (a symbol that two sets hold, the euro in Alt codes and in Currency, shows once in a result list).
function dedupe(items) {
    var seen = {};
    var out = [];
    for (var i = 0; i < items.length; i++) {
        if (seen[items[i].ch] === true)
            continue;
        seen[items[i].ch] = true;
        out.push(items[i]);
    }
    return out;
}

// ---- the caption of a tile / of the focused item ---------------------------------------------
function codesCaption(it) {
    return it.codes.join(" · ");
}
// ---- the grid's rows --------------------------------------------------------------------------
// sections: [{ id, label, profile, items }]   label "" = no header row
// g: { width, pad, padTop, padBottom, headH, sectionGap, profiles: { <name>: { minW, h } } }
function layout(sections, g) {
    var inner = Math.max(1, g.width - 2 * g.pad);
    var rows = [];
    var flat = [];
    var rowOf = [];
    var secY = {};
    var secCols = {};
    var y = g.padTop;
    var maxCols = 1;
    var minRowH = 1e9;
    for (var s = 0; s < sections.length; s++) {
        var sec = sections[s];
        if (sec.items.length === 0)
            continue;
        if (rows.length > 0)
            y += g.sectionGap;
        var p = g.profiles[sec.profile];
        var cols = Math.max(1, Math.floor(inner / p.minW));
        maxCols = Math.max(maxCols, cols);
        secCols[sec.id] = cols;
        secY[sec.id] = y;
        if (sec.label !== "") {
            rows.push({ kind: "head", y: y, h: g.headH, label: sec.label, sec: sec.id });
            minRowH = Math.min(minRowH, g.headH);
            y += g.headH;
        }
        for (var i = 0; i < sec.items.length; i += cols) {
            var n = Math.min(cols, sec.items.length - i);
            rows.push({ kind: "tiles", y: y, h: p.h, sec: sec.id, profile: sec.profile, start: flat.length, n: n, cols: cols });
            for (var c = 0; c < n; c++) {
                flat.push(sec.items[i + c]);
                rowOf.push(rows.length - 1);
            }
            minRowH = Math.min(minRowH, p.h);
            y += p.h;
        }
    }
    return {
        rows: rows,
        flat: flat,
        rowOf: rowOf,
        secY: secY,
        secCols: secCols,
        height: y + g.padBottom,
        inner: inner,
        pad: g.pad,
        maxCols: maxCols,
        minRowH: minRowH === 1e9 ? 1 : minRowH
    };
}

function cellRect(L, i) {
    var r = L.rows[L.rowOf[i]];
    var col = i - r.start;
    var x0 = Math.round(L.pad + col * L.inner / r.cols);
    var x1 = Math.round(L.pad + (col + 1) * L.inner / r.cols);
    return { x: x0, y: r.y, w: x1 - x0, h: r.h };
}

function rowAt(L, y) {
    var lo = 0;
    var hi = L.rows.length - 1;
    if (hi < 0)
        return 0;
    while (lo < hi) {
        var mid = (lo + hi + 1) >> 1;
        if (L.rows[mid].y <= y)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

function indexAt(L, x, y) {
    if (L.rows.length === 0 || y < 0)
        return -1;
    var ri = rowAt(L, y);
    var r = L.rows[ri];
    if (r.kind !== "tiles" || y >= r.y + r.h)
        return -1;
    var col = Math.floor((x - L.pad) * r.cols / L.inner);
    if (col < 0 || col >= r.n)
        return -1;
    return r.start + col;
}

// Up / down by tile rows keep the column (clamped to a shorter row); left / right walk the flat order, across sections.
function move(L, i, dRow, dCol) {
    var n = L.flat.length;
    if (n === 0)
        return -1;
    i = Math.max(0, Math.min(n - 1, i));
    if (dCol !== 0)
        return Math.max(0, Math.min(n - 1, i + dCol));
    var ri = L.rowOf[i];
    var r = L.rows[ri];
    var col = i - r.start;
    var tileRows = [];
    var at = 0;
    for (var k = 0; k < L.rows.length; k++) {
        if (L.rows[k].kind === "tiles") {
            if (k === ri)
                at = tileRows.length;
            tileRows.push(k);
        }
    }
    var to = Math.max(0, Math.min(tileRows.length - 1, at + dRow));
    var t = L.rows[tileRows[to]];
    return t.start + Math.min(col, t.n - 1);
}

// The section whose rows hold content y (for the category bar): the last section that starts at or above it.
function sectionAt(L, y) {
    if (L.rows.length === 0)
        return "";
    return L.rows[rowAt(L, Math.max(0, y))].sec;
}
