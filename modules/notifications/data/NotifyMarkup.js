.pragma library

// =============================================================================
// NotifyMarkup.js -- a notification body, made safe for a StyledText Text.
//
//   sanitize(body) -> StyledText (b, i, u, a href, <br>; everything else text)
//   plain(body)    -> the same body as plain text, whitespace collapsed
//
// The spec lets a body carry <b> <i> <u> <a href> <img>, and apps send what
// they like: plain text with angle brackets in it ("Vec<String>", "x < y"),
// half-closed tags, entities, and now and then HTML they were never allowed.
// The body is read ONCE into tokens -- text runs and the six tags this file
// knows (b i u a img br) -- and both functions render those tokens, so what
// `plain` returns is exactly the text `sanitize` shows (the filter and the
// collapsed subtitle read `plain`).
//
// ANYTHING THAT IS NOT ONE OF THOSE TAGS IS TEXT. "<span>" or "<script>" is
// shown as typed rather than swallowed: a plain-text sender's "<String>" is
// more common than a markup sender's unsupported tag, and showing a stray tag
// is harmless where hiding words is not. A "<" that does not open a
// well-formed tag (no closing ">", an unterminated quote) is text too.
//
// ENTITIES are decoded in text -- numeric (&#NN; &#xHH;) and every name
// Qt 6.11's StyledText knows: HTML 4.01's 252 plus &apos; and the upper-case
// &AMP; &GT; &LT; &QUOT; (the table is generated from Python's
// html.entities, not typed; compared with Qt name by name, all 257
// render alike but &or;, which Qt draws as U+22A6 -- a typo in its own table;
// this file keeps HTML's U+2228) -- and the text is escaped again on the
// way out, so the output holds only &amp; &lt; &gt; and the space entities
// below. A name outside that set (&check;, &foo;) renders as NOTHING in
// StyledText; here it stays visible as typed. A numeric entity outside
// Unicode becomes U+FFFD; control characters are removed.
//
// WHITESPACE. StyledText collapses it like HTML (six spaces are as
// wide as one, a raw newline stays on one line), so a newline -- and U+2028 /
// U+2029 -- becomes <br>. It collapses a raw U+00A0 or typographic space
// (U+2000..U+200A, U+202F ...) the same way, but keeps it when it arrives as
// an entity, so those are written as &nbsp; / &#NNNN;: a sender that put a
// no-break space in meant it.
//
// TAGS STAY BALANCED. StyledText has no error recovery worth the name: an
// unclosed <b> bolds the rest of whatever it is concatenated with. Every tag
// this file opens it closes -- at the end of the body at the latest; a close
// tag that does not match the innermost open one closes the tags inside it
// and opens them again after (<b><i>x</b>y</i> -> <b><i>x</i></b><i>y</i>);
// a close tag with nothing to close is dropped. A tag opened while it is
// already open (<b> inside <b>) changes nothing on screen, so it is COUNTED,
// not opened, and its close consumes the count: at most b, i, u and one a
// are ever open, and that bound is what keeps a hostile body linear -- with
// a real stack, "<b><i><u>" x 20 000 then "</b>" x 20 000 would reopen a
// growing pile of tags on every close and run node out of heap.
//
// LINKS keep http, https, mailto and file (the spec's hyperlinks; file: opens
// a local path the way the app meant) and nothing else -- a javascript: or
// data: link keeps its words and loses the link. StyledText reads an href
// RAW (no entity decoding) up to the first quote of EITHER kind, so the href
// is written decoded, with " ' < > ` and whitespace percent-encoded.
//
// <img> is dropped and its alt text kept in its place (the spec's image
// markup is not shown; a sender that wants a picture sends image-data).
//
// Pure: no Qt, loadable under node.
// =============================================================================

var _NBSP = String.fromCharCode(0xA0);
var _REPLACEMENT = String.fromCharCode(0xFFFD);
// HTML 4.01's named entities (python3 html.entities.name2codepoint, 252) plus
// apos, AMP, GT, LT, QUOT: the names StyledText decodes. name:codepoint.
var _ENTITY_TABLE =
    "Aacute:193 aacute:225 Acirc:194 acirc:226 acute:180 AElig:198 aelig:230 Agrave:192 " +
    "agrave:224 alefsym:8501 Alpha:913 alpha:945 AMP:38 amp:38 and:8743 ang:8736 apos:39 " +
    "Aring:197 aring:229 asymp:8776 Atilde:195 atilde:227 Auml:196 auml:228 bdquo:8222 Beta:914 " +
    "beta:946 brvbar:166 bull:8226 cap:8745 Ccedil:199 ccedil:231 cedil:184 cent:162 Chi:935 " +
    "chi:967 circ:710 clubs:9827 cong:8773 copy:169 crarr:8629 cup:8746 curren:164 Dagger:8225 " +
    "dagger:8224 dArr:8659 darr:8595 deg:176 Delta:916 delta:948 diams:9830 divide:247 " +
    "Eacute:201 eacute:233 Ecirc:202 ecirc:234 Egrave:200 egrave:232 empty:8709 emsp:8195 " +
    "ensp:8194 Epsilon:917 epsilon:949 equiv:8801 Eta:919 eta:951 ETH:208 eth:240 Euml:203 " +
    "euml:235 euro:8364 exist:8707 fnof:402 forall:8704 frac12:189 frac14:188 frac34:190 " +
    "frasl:8260 Gamma:915 gamma:947 ge:8805 GT:62 gt:62 hArr:8660 harr:8596 hearts:9829 " +
    "hellip:8230 Iacute:205 iacute:237 Icirc:206 icirc:238 iexcl:161 Igrave:204 igrave:236 " +
    "image:8465 infin:8734 int:8747 Iota:921 iota:953 iquest:191 isin:8712 Iuml:207 iuml:239 " +
    "Kappa:922 kappa:954 Lambda:923 lambda:955 lang:9001 laquo:171 lArr:8656 larr:8592 " +
    "lceil:8968 ldquo:8220 le:8804 lfloor:8970 lowast:8727 loz:9674 lrm:8206 lsaquo:8249 " +
    "lsquo:8216 LT:60 lt:60 macr:175 mdash:8212 micro:181 middot:183 minus:8722 Mu:924 mu:956 " +
    "nabla:8711 nbsp:160 ndash:8211 ne:8800 ni:8715 not:172 notin:8713 nsub:8836 Ntilde:209 " +
    "ntilde:241 Nu:925 nu:957 Oacute:211 oacute:243 Ocirc:212 ocirc:244 OElig:338 oelig:339 " +
    "Ograve:210 ograve:242 oline:8254 Omega:937 omega:969 Omicron:927 omicron:959 oplus:8853 " +
    "or:8744 ordf:170 ordm:186 Oslash:216 oslash:248 Otilde:213 otilde:245 otimes:8855 Ouml:214 " +
    "ouml:246 para:182 part:8706 permil:8240 perp:8869 Phi:934 phi:966 Pi:928 pi:960 piv:982 " +
    "plusmn:177 pound:163 Prime:8243 prime:8242 prod:8719 prop:8733 Psi:936 psi:968 QUOT:34 " +
    "quot:34 radic:8730 rang:9002 raquo:187 rArr:8658 rarr:8594 rceil:8969 rdquo:8221 real:8476 " +
    "reg:174 rfloor:8971 Rho:929 rho:961 rlm:8207 rsaquo:8250 rsquo:8217 sbquo:8218 Scaron:352 " +
    "scaron:353 sdot:8901 sect:167 shy:173 Sigma:931 sigma:963 sigmaf:962 sim:8764 spades:9824 " +
    "sub:8834 sube:8838 sum:8721 sup:8835 sup1:185 sup2:178 sup3:179 supe:8839 szlig:223 Tau:932 " +
    "tau:964 there4:8756 Theta:920 theta:952 thetasym:977 thinsp:8201 THORN:222 thorn:254 " +
    "tilde:732 times:215 trade:8482 Uacute:218 uacute:250 uArr:8657 uarr:8593 Ucirc:219 " +
    "ucirc:251 Ugrave:217 ugrave:249 uml:168 upsih:978 Upsilon:933 upsilon:965 Uuml:220 uuml:252 " +
    "weierp:8472 Xi:926 xi:958 Yacute:221 yacute:253 yen:165 Yuml:376 yuml:255 Zeta:918 zeta:950 " +
    "zwj:8205 zwnj:8204 ";
var _NAMED = (function () {
    var o = {};
    var parts = _ENTITY_TABLE.split(" ");
    for (var i = 0; i < parts.length; i++) {
        var c = parts[i].indexOf(":");
        if (c > 0)
            o[parts[i].substring(0, c)] = String.fromCodePoint(parseInt(parts[i].substring(c + 1), 10));
    }
    return o;
})();
// Spaces StyledText would collapse unless they come as an entity.
var _KEEP_SPACE = /[\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]/g;
var _NEWLINE = /\r\n|\r|\n|\u2028|\u2029/g;
var _TAGS = { b: true, i: true, u: true, a: true, img: true, br: true };
var _SCHEME = /^(https?|mailto|file):/i;
var _CTRL = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g;
var _CTRL_ANY = /[\x00-\x1f\x7f]/;

function _has(o, k) {
    return Object.prototype.hasOwnProperty.call(o, k);
}

function _src(body) {
    if (body === undefined || body === null)
        return "";
    return String(body).trim();
}

function _decode(s) {
    return s.replace(/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);/g, function (m, e) {
        if (e.charAt(0) === "#") {
            var hex = e.charAt(1) === "x" || e.charAt(1) === "X";
            var cp = parseInt(e.substring(hex ? 2 : 1), hex ? 16 : 10);
            if (!(cp > 0) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
                return _REPLACEMENT;
            return String.fromCodePoint(cp);
        }
        return _has(_NAMED, e) ? _NAMED[e] : m;
    });
}

// A text run as the reader sees it.
function _text(raw) {
    return _decode(raw).replace(_CTRL, "");
}

function _esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(_KEEP_SPACE, function (c) {
            return c === _NBSP ? "&nbsp;" : "&#" + c.charCodeAt(0) + ";";
        });
}

function _ws(c) {
    return c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\f";
}

function _nameChar(c, first) {
    return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (!first && c >= "0" && c <= "9");
}

// The tag starting at s[i] === "<", if it is one of _TAGS and well formed:
// { end, name, close, self, attrs }. null otherwise (the "<" is text).
// `last` holds the last index of each quote character, so an unterminated
// quoted value fails at once instead of scanning to the end for every "<".
function _parseTag(s, i, last) {
    var j = i + 1, close = false;
    if (s.charAt(j) === "/") {
        close = true;
        j++;
    }
    var n0 = j;
    while (j < s.length && _nameChar(s.charAt(j), j === n0))
        j++;
    if (j === n0)
        return null;
    var name = s.substring(n0, j).toLowerCase();
    if (!_has(_TAGS, name))
        return null;
    var attrs = {};
    for (;;) {
        while (j < s.length && _ws(s.charAt(j)))
            j++;
        if (j >= s.length)
            return null;
        var c = s.charAt(j);
        if (c === ">")
            return { end: j + 1, name: name, close: close, self: false, attrs: attrs };
        if (c === "/" && s.charAt(j + 1) === ">")
            return { end: j + 2, name: name, close: close, self: true, attrs: attrs };
        if (c === "/") {
            j++;
            continue;
        }
        if (c === "<" || c === "\"" || c === "'" || c === "=")
            return null;
        var a0 = j;
        while (j < s.length) {
            c = s.charAt(j);
            if (_ws(c) || c === "=" || c === ">" || c === "/" || c === "<" || c === "\"" || c === "'")
                break;
            j++;
        }
        var an = s.substring(a0, j).toLowerCase();
        var v = "";
        while (j < s.length && _ws(s.charAt(j)))
            j++;
        if (s.charAt(j) === "=") {
            j++;
            while (j < s.length && _ws(s.charAt(j)))
                j++;
            var q = s.charAt(j);
            if (q === "\"" || q === "'") {
                if (last[q] <= j)
                    return null;
                var e = s.indexOf(q, j + 1);
                v = s.substring(j + 1, e);
                j = e + 1;
            } else {
                var v0 = j;
                while (j < s.length && !_ws(s.charAt(j)) && s.charAt(j) !== ">" && s.charAt(j) !== "<")
                    j++;
                v = s.substring(v0, j);
            }
        }
        if (!_has(attrs, an))
            attrs[an] = v;
    }
}

function _tokens(s) {
    var out = [], text = "", i = 0;
    var last = { "\"": s.lastIndexOf("\""), "'": s.lastIndexOf("'") };
    while (i < s.length) {
        var lt = s.indexOf("<", i);
        if (lt < 0) {
            text += s.substring(i);
            break;
        }
        text += s.substring(i, lt);
        var t = _parseTag(s, lt, last);
        if (!t) {
            text += "<";
            i = lt + 1;
            continue;
        }
        if (text !== "") {
            out.push({ text: text });
            text = "";
        }
        out.push(t);
        i = t.end;
    }
    if (text !== "")
        out.push({ text: text });
    return out;
}

// A link target StyledText can carry, or "" when it may not be a link.
function _href(raw) {
    if (typeof raw !== "string")
        return "";
    var u = _decode(raw).trim();
    if (u === "" || _CTRL_ANY.test(u) || !_SCHEME.test(u))
        return "";
    return u.replace(/["'<>`\s]/g, function (c) {
        return c === "'" ? "%27" : encodeURIComponent(c);
    });
}

function _alt(t) {
    return _has(t.attrs, "alt") ? _text(t.attrs.alt).replace(/\s+/g, " ") : "";
}

function sanitize(body) {
    var toks = _tokens(_src(body));
    var out = "";
    var stack = [];                                   // [{ name, open }], at most b i u a
    var extra = { b: 0, i: 0, u: 0 };                 // opens of a tag already open

    function innermost(name) {
        for (var k = stack.length - 1; k >= 0; k--)
            if (stack[k].name === name)
                return k;
        return -1;
    }
    // Close stack[k] and everything inside it, then reopen the inner ones.
    function closeAt(k) {
        for (var j = stack.length - 1; j >= k; j--)
            out += "</" + stack[j].name + ">";
        var inner = stack.splice(k).slice(1);
        for (var m = 0; m < inner.length; m++) {
            out += inner[m].open;
            stack.push(inner[m]);
        }
    }

    for (var n = 0; n < toks.length; n++) {
        var t = toks[n];
        if (t.text !== undefined) {
            out += _esc(_text(t.text)).replace(_NEWLINE, "<br>");
            continue;
        }
        if (t.name === "br") {
            out += "<br>";
            continue;
        }
        if (t.name === "img") {
            if (!t.close)
                out += _esc(_alt(t));
            continue;
        }
        var k = innermost(t.name);
        if (t.close) {
            if (extra[t.name] > 0)
                extra[t.name]--;
            else if (k >= 0)
                closeAt(k);
            continue;
        }
        if (t.self)
            continue;
        var open = "<" + t.name + ">";
        if (t.name === "a") {
            var href = _href(t.attrs.href);
            if (href === "")
                continue;                             // the words stay, the link goes
            if (k >= 0)
                closeAt(k);                           // links do not nest
            open = "<a href=\"" + href + "\">";
        } else if (k >= 0) {
            extra[t.name]++;                          // bold inside bold is bold
            continue;
        }
        out += open;
        stack.push({ name: t.name, open: open });
    }
    for (var z = stack.length - 1; z >= 0; z--)
        out += "</" + stack[z].name + ">";
    return out;
}

function plain(body) {
    var toks = _tokens(_src(body));
    var out = "";
    for (var n = 0; n < toks.length; n++) {
        var t = toks[n];
        if (t.text !== undefined)
            out += _text(t.text);
        else if (t.name === "br")
            out += " ";
        else if (t.name === "img" && !t.close)
            out += _alt(t);
    }
    return out.replace(/\s+/g, " ").replace(/^ | $/g, "");
}
