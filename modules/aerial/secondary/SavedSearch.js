.pragma library

// =============================================================================
// SavedSearch.js -- the saved-networks search (SavedPanel): pure. A query matches a profile's NAME or its SSID, ignoring case and
// accents (each character is folded on its own, so a span found in the folded text maps back to the real characters), as a
// substring; several words must each be found (in any order, in the name or the SSID). The first word's span in the name (else in
// the SSID) is what the row highlights.
// =============================================================================

// "Café" -> { text: "cafe", at: [0, 1, 2, 3] }: `at[i]` is the real index of the folded character i.
function fold(s) {
    s = String(s === undefined || s === null ? "" : s);
    var text = "", at = [];
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
        for (var k = 0; k < c.length; k++) {
            text += c.charAt(k);
            at.push(i);
        }
    }
    return { text: text, at: at };
}

function words(query) {
    return fold(query).text.split(/\s+/).filter(function (w) { return w !== ""; });
}

// { start, end } in the REAL text (end exclusive) of the first place `word` is found, or null.
function spanOf(folded, word, real) {
    var i = folded.text.indexOf(word);
    if (i < 0)
        return null;
    var start = folded.at[i];
    var last = folded.at[i + word.length - 1];
    return { start: start, end: Math.min(real.length, last + 1) };
}

// The profile's match for a query: null (no match), or { nameSpan, ssidSpan } (either may be null; the first word's).
function match(query, name, ssid) {
    var ws = words(query);
    name = String(name || "");
    ssid = String(ssid || "");
    var fn = fold(name), fs = fold(ssid);
    if (ws.length === 0)
        return { nameSpan: null, ssidSpan: null };
    for (var i = 0; i < ws.length; i++)
        if (fn.text.indexOf(ws[i]) < 0 && fs.text.indexOf(ws[i]) < 0)
            return null;
    return { nameSpan: spanOf(fn, ws[0], name), ssidSpan: spanOf(fs, ws[0], ssid) };
}

function _esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// StyledText for `text` with `span` in `colour` ("" or no span: the escaped text).
function styled(text, span, colour) {
    text = String(text || "");
    if (!span || colour === "")
        return _esc(text);
    return _esc(text.substring(0, span.start)) + "<font color=\"" + colour + "\">" + _esc(text.substring(span.start, span.end)) + "</font>" + _esc(text.substring(span.end));
}
