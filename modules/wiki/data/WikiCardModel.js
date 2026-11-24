.pragma library

// =============================================================================
// WikiCardModel.js -- an entry, assembled into what the views read. Pure,
// loads under node. Contract: docs/contracts/wiki.md
// ("Card object"). FACTS ONLY: no colour ever appears here (a
// Repeater's model may not hold a themed colour), the card names its hue as a
// Theme token and the delegate resolves it.
//
//   cardOf(entry, families, stateDirUrl, extras)  -> card
//   whyText(card, why)                            "Physics · you open 40 % · picked 1 in 9"
//   markTips(card)                                { generated, edited } tip texts ("" = none)
//   introSegments(text, links)                    StyledText, links as <a href="N">
//   otdLine(daily, maxChars)                      "On this day, 1791: ..."
//   teaserText(card)                              "Today: <title>"
//   sourceName(wiki) / sourceLogo(wiki)           "ArchWiki" / "assets/logos/archlinux.png"
//   familyOf(families, id)                        { id, label, glyph, hue, topics }
//
// `families` is families.json: discover[], guest, deepen[]; a family's `glyph`
// is a hex codepoint in Symbols Nerd Font and the card carries the character.
// `extras`: { why, followed, parentTitle, otd: {year, text, url} }.
// Intro link offsets are indexes into intro.text as a JS string (UTF-16 units).
// =============================================================================

var SOURCES = {
    wikipedia:   { name: "Wikipedia",         logo: "assets/logos/wikipedia.png" },
    arch:        { name: "ArchWiki",          logo: "assets/logos/archlinux.png" },
    gentoo:      { name: "Gentoo Wiki",       logo: "assets/logos/gentoo.png" },
    kernel:      { name: "Kernel docs",       logo: "assets/logos/linux.png" },
    freedesktop: { name: "freedesktop.org",   logo: "assets/logos/freedesktop.png" },
    commons:     { name: "Wikimedia Commons", logo: "assets/logos/commons.png" }
};

var SOURCE_ALIASES = {
    archwiki: "arch", "wiki.archlinux.org": "arch", archlinux: "arch",
    "kernel_docs": "kernel", "kernel-docs": "kernel", "docs.kernel.org": "kernel", kerneldocs: "kernel",
    "en.wikipedia.org": "wikipedia",
    "wiki.gentoo.org": "gentoo",
    "www.freedesktop.org": "freedesktop", "freedesktop.org": "freedesktop",
    "commons.wikimedia.org": "commons"
};

// What a cleanup code is called in the tip. Keys are the code lower-cased with
// "_" and "-" as spaces; an unknown code is said as it is.
var STRIP_WORDS = {
    "ipa": "IPA transcription",
    "pronunciation": "pronunciation",
    "respelling": "respelling",
    "native names": "native-language names",
    "native name": "native-language names",
    "native": "native-language names",
    "dates": "birth and death dates",
    "date": "birth and death dates",
    "birth death dates": "birth and death dates",
    "coordinates": "coordinates",
    "coords": "coordinates",
    "citations": "citation marks",
    "citation": "citation marks",
    "citation marks": "citation marks",
    "refs": "citation marks",
    "references": "citation marks",
    "hatnote": "hatnote",
    "parentheses": "parenthetical asides",
    "parenthetical": "parenthetical asides"
};

var FALLBACK_HUE = "mdGray";

// ---- sources ---------------------------------------------------------------------

function sourceKey(wiki) {
    const k = String(wiki === undefined || wiki === null ? "" : wiki).toLowerCase();
    return SOURCE_ALIASES[k] || k;
}

function sourceName(wiki) {
    const s = SOURCES[sourceKey(wiki)];
    return s ? s.name : String(wiki || "");
}

function sourceLogo(wiki) {
    const s = SOURCES[sourceKey(wiki)];
    return s ? s.logo : "";
}

// ---- families and urls --------------------------------------------------------------

function familyOf(families, id) {
    const f = families || {};
    const lists = [f.discover || [], f.guest ? [f.guest] : [], f.deepen || []];
    for (let l = 0; l < lists.length; l++)
        for (let i = 0; i < lists[l].length; i++)
            if (lists[l][i] && lists[l][i].id === id)
                return { id: id, label: lists[l][i].label || id, glyph: lists[l][i].glyph || "",
                         hue: lists[l][i].hue || FALLBACK_HUE, topics: lists[l][i].topics || [] };
    return { id: id || "", label: id || "", glyph: "", hue: FALLBACK_HUE, topics: [] };
}

function glyphChar(hex) {
    if (typeof hex !== "string" || hex === "")
        return "";
    if (/^[0-9a-fA-F]{3,6}$/.test(hex)) {
        const cp = parseInt(hex, 16);
        return cp <= 0x10FFFF ? String.fromCodePoint(cp) : "";
    }
    return hex;
}

// stateDirUrl + "/" + file, each path segment percent-encoded so a title with a
// "#", "?" or "%" in its slug still names the file.
function fileUrl(stateDirUrl, file) {
    if (!file)
        return "";
    const base = String(stateDirUrl || "").replace(/\/+$/, "");
    return base + "/" + String(file).split("/").map(encodeURIComponent).join("/");
}

function _wordCount(text) {
    const m = String(text || "").trim().match(/\S+/g);
    return m ? m.length : 0;
}

// ---- the card ------------------------------------------------------------------------

function _images(entry, stateDirUrl) {
    const out = [];
    const list = Array.isArray(entry.images) ? entry.images : [];
    for (let i = 0; i < list.length; i++) {
        const im = list[i] || {};
        // The pool's "glyph" (no picture, no logo) is drawn as a veil; so is an entry with no image at all.
        if (im.kind === "glyph")
            continue;
        out.push({
            kind: im.kind || "photo",
            url: fileUrl(stateDirUrl, im.file),
            thumbUrl: fileUrl(stateDirUrl, im.thumb || im.file),
            aspect: typeof im.aspect === "number" && im.aspect > 0 ? im.aspect : 1.78,
            focusY: typeof im.focusY === "number" ? im.focusY : 0.5,
            credit: im.credit || "",
            license: im.license || ""
        });
    }
    if (out.length === 0)               // the hero is never bare: the article's own veil (WikiVeil)
        out.push({ kind: "veil", url: "", thumbUrl: "", aspect: 1.78, focusY: 0.5, credit: "", license: "" });
    return out;
}

function cardOf(entry, families, stateDirUrl, extras) {
    const x = extras || {};
    const e = entry || {};
    const cat = e.category || {}, intro = e.intro || {}, src = e.source || {};
    const fam = familyOf(families, cat.family);
    const links = [];
    for (let i = 0; i < (Array.isArray(intro.links) ? intro.links.length : 0); i++) {
        const l = intro.links[i];
        links.push({ s: l.s, e: l.e, url: l.url || "", target: l.target || "" });
    }
    const inst = e.installed;
    const card = {
        id: e.id || "",
        tab: e.tab || "",
        kind: e.kind || "article",
        title: e.title || src.title || "",
        family: cat.family || "",
        topic: cat.topic || "",
        via: cat.via || "",
        familyLabel: fam.label,
        glyph: glyphChar(fam.glyph),
        hueToken: fam.hue,
        whyText: "",
        intro: intro.text || "",
        introLinks: links,
        words: typeof intro.words === "number" ? intro.words : _wordCount(intro.text),
        provenance: intro.provenance || "original",
        stripped: Array.isArray(intro.stripped) ? intro.stripped.slice() : [],
        model: intro.model || "",
        source: {
            wiki: src.wiki || "",
            name: sourceName(src.wiki || src.host),
            logo: sourceLogo(src.wiki || src.host),
            url: src.url || "",
            license: src.license || "",
            quality: src.quality || ""
        },
        images: _images(e, stateDirUrl),
        installed: inst && typeof inst.flag === "boolean" ? inst.flag : null,
        installedPkg: inst && inst.pkg ? inst.pkg : "",
        followed: x.followed === true,
        followedFrom: x.parentTitle || "",
        otd: x.otd ? { year: x.otd.year, text: x.otd.text || "", url: x.otd.url || "" } : null
    };
    card.whyText = whyText(card, x.why || cat.why);
    return card;
}

// ---- texts -----------------------------------------------------------------------------

// "Physics · you open 40 % · picked 1 in 9". The open rate is said in steps of
// 5 % and only when the interest engine had enough showings to compute one
// (it hands null otherwise); a family picked every time has no "1 in N".
function whyText(card, why) {
    if (!card)
        return "";
    const via = card.via || "";
    if (card.followed || via === "follow")
        return "Followed from " + (card.followedFrom || "a link");
    if (via === "daily")
        return card.kind === "potd" ? "Picture of the day" : "On this day";
    const parts = [];
    if (card.familyLabel)
        parts.push(card.familyLabel);
    if (why && typeof why.openRate === "number" && isFinite(why.openRate))
        parts.push("you open " + Math.round(why.openRate * 20) * 5 + " %");
    let oneIn = why && typeof why.oneIn === "number" ? why.oneIn : 0;
    if (!oneIn && why && typeof why.p === "number" && why.p > 0)
        oneIn = Math.round(1 / why.p);
    if (oneIn > 1)
        parts.push("picked 1 in " + oneIn);
    return parts.join(" · ");
}

function _stripWord(code) {
    const k = String(code).toLowerCase().replace(/[_-]+/g, " ").trim();
    return STRIP_WORDS[k] || k;
}

// The two mark tips. "" where the mark does not apply.
function markTips(card) {
    const out = { generated: "", edited: "" };
    if (!card)
        return out;
    if (card.provenance === "generated")
        out.generated = "Written by " + (card.model || "a local model") + " from the article's text";
    if (card.provenance === "cleaned") {
        const words = [];
        for (let i = 0; i < (card.stripped ? card.stripped.length : 0); i++) {
            const w = _stripWord(card.stripped[i]);
            if (w && words.indexOf(w) < 0)
                words.push(w);
        }
        out.edited = words.length ? "Removed: " + words.join(", ") : "Cleaned up for reading";
    }
    return out;
}

function _esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// The intro as StyledText. Every link becomes <a href="N">..</a> with N its
// index in `links`; everything else is escaped. The visible characters are the
// text's own, in order, so an offset into `text` is an offset into what is
// shown. A link that is malformed or overlaps one kept before it is dropped.
function introSegments(text, links) {
    const s = String(text === undefined || text === null ? "" : text);
    const kept = [];
    for (let i = 0; i < (links ? links.length : 0); i++) {
        const a = Math.floor(Number(links[i] && links[i].s)), b = Math.floor(Number(links[i] && links[i].e));
        if (!isFinite(a) || !isFinite(b) || a < 0 || b <= a || b > s.length)
            continue;
        let clash = false;
        for (let j = 0; j < kept.length; j++)
            if (a < kept[j].e && kept[j].s < b)
                clash = true;
        if (!clash)
            kept.push({ s: a, e: b, i: i });
    }
    kept.sort(function (p, q) { return p.s - q.s; });
    let out = "", pos = 0;
    for (let k = 0; k < kept.length; k++) {
        out += _esc(s.slice(pos, kept[k].s)) + '<a href="' + kept[k].i + '">' + _esc(s.slice(kept[k].s, kept[k].e)) + "</a>";
        pos = kept[k].e;
    }
    // The intro's own newlines (one per source paragraph) are spaces to StyledText: a <br> keeps them.
    return (out + _esc(s.slice(pos))).replace(/\n/g, "<br>");
}

function _cutWords(s, n) {
    if (s.length <= n)
        return s;
    const cut = s.slice(0, n + 1);          // the extra character says whether the cut is on a space
    const sp = cut.lastIndexOf(" ");
    return (sp > 0 ? cut.slice(0, sp) : s.slice(0, n)).replace(/[\s,;:.\-–—]+$/, "");
}

// "On this day, 1791: Wolfgang ... premiered in Vienna", cut at a word with "…"
// so that the whole line, the head included, is at most maxChars.
function otdLine(daily, maxChars) {
    const o = daily && daily.otd;
    if (!o || !o.text)
        return "";
    const text = String(o.text).replace(/\s+/g, " ").trim();
    const y = Number(o.year);
    const yearTxt = (o.year === null || o.year === undefined || o.year === "" || !isFinite(y)) ? ""
                    : (y < 0 ? (-y) + " BC" : String(y));
    const head = yearTxt ? "On this day, " + yearTxt + ": " : "On this day: ";
    const full = head + text;
    if (!(maxChars > 0) || full.length <= maxChars)
        return full;
    const room = maxChars - head.length - 1;
    if (room < 8)
        return _cutWords(full, maxChars - 1) + "…";
    return head + _cutWords(text, room) + "…";
}

function teaserText(card) {
    return card && card.title ? "Today: " + card.title : "";
}
