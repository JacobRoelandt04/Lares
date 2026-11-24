.pragma library

// =============================================================================
// LlmPathComplete.js
//
// The pure half of the prompt's path completion: everything that can be
// decided from strings alone, with no model, no directory and no item. It is a
// library, as LlmToolPolicy.js is, so that LlmPathCompleter.qml, which owns the
// one FolderListModel, stays a thin shell around these functions.
//
// THE GESTURE, on a path introduced by "@": autocomplete when only one
// solution is possible any more; display all remaining options after tab has
// been pressed twice when more solutions are still possible.
//
// WHY "@" AND WHY IT STAYS IN THE TEXT. The prompt is a plain-text field whose
// `text` IS the message that is sent and the draft that is saved, so a
// completed path cannot be MARKED (marking a substring needs RichText, which
// would turn `text` into HTML and break submit, the draft restore and every
// markdown character the user types). The "@" is therefore the whole mark: it
// is typed, it is shown, and it rides to the model exactly as typed. What the
// model does with a path is already answered by two structured channels --
// a chip attaches the file's CONTENT, `read_file`/`search_files` let the model
// fetch it -- so this is a TYPING aid and nothing else.
//
// THE WORD BOUNDARY IS WHAT SAVES AN EMAIL ADDRESS. The token is the
// whitespace-delimited word the caret sits in, and it counts only if that word
// STARTS with "@": "mail me at foo@bar" completes nothing, ever.
//
// A SPACE IN A NAME IS ESCAPED, because the token ENDS at whitespace and half
// this machine's interesting directories have a space in them. bash's own
// answer is a backslash, and it is the only one that survives round-tripping
// through a plain-text field: "@~/beta\ dir/" is one token, it completes
// further, and a person reads it correctly. So a completion ESCAPES what it
// inserts and every reader UNESCAPES before it touches the filesystem.
//
// THE DOUBLE ENCODE IS LOAD-BEARING (measured). `FolderListModel`'s
// `folder` is a QUrl, which percent-DECODES the path once: a directory whose
// name holds a raw "#" (fragment) or a literal "%20" then silently fails --
// status stays Null, no warning, no error, an empty completion for a directory
// that is right there. Encoding every segment TWICE survives that one decode.
// =============================================================================

function _isWs(c) {
    return c === " " || c === "\t" || c === "\n" || c === "\r";
}

// Is the character at `j` escaped -- an ODD number of backslashes before it?
function _escaped(s, j) {
    var b = 0;
    while (j - 1 - b >= 0 && s.charAt(j - 1 - b) === "\\")
        b++;
    return (b % 2) === 1;
}

// "\ " -> " ", "\\" -> "\": what the document holds, made into a path.
function unescapePath(s) {
    var out = "", t = String(s || "");
    for (var i = 0; i < t.length; i++) {
        if (t.charAt(i) === "\\" && i + 1 < t.length) {
            out += t.charAt(i + 1);
            i++;
        } else {
            out += t.charAt(i);
        }
    }
    return out;
}

// The other direction: a name on its way INTO the document. Only whitespace
// and the backslash itself need it -- everything else a filesystem allows is
// already one token.
function escapePath(s) {
    return String(s || "").replace(/([\\\s])/g, "\\$1");
}

// The completion token at `caret`, or null. `start` is the index of the "@";
// `body` is what has been typed after it, up to the caret (never past it --
// readline completes at the cursor, not at the end of the word).
function tokenAt(text, caret) {
    var s = String(text === undefined || text === null ? "" : text);
    var c = Math.max(0, Math.min(s.length, Math.round(Number(caret) || 0)));
    var i = c;
    while (i > 0 && !(_isWs(s.charAt(i - 1)) && !_escaped(s, i - 1)))
        i--;
    if (s.charAt(i) !== "@" || c <= i)
        return null;
    return { start: i, body: s.substring(i + 1, c) };
}

// The token's body split into the directory to list and the prefix to match.
// `pendingSlash` is the one case where nothing can be matched yet: a bare "~",
// which bash answers by typing the "/" for you.
// Returns null when no directory can be named without guessing a working
// directory -- the popup has none, so a relative path is REFUSED rather than
// resolved against something the user cannot see.
function split(body, home) {
    var b = unescapePath(String(body === undefined || body === null ? "" : body));
    var h = String(home === undefined || home === null ? "" : home).replace(/\/+$/, "");
    if (b === "~")
        return { dir: h, prefix: "", pendingSlash: true };
    var full = b === "" ? h + "/"
             : (b === "~/" ? h + "/"
             : (b.indexOf("~/") === 0 ? h + b.substring(1) : b));
    if (full.charAt(0) !== "/")
        return null;
    var cut = full.lastIndexOf("/");
    return {
        dir: cut === 0 ? "/" : full.substring(0, cut),
        prefix: full.substring(cut + 1),
        pendingSlash: false
    };
}

// `file://` + every segment encoded TWICE -- see the header.
function folderUrl(dir) {
    var parts = String(dir || "").split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++)
        out.push(encodeURIComponent(encodeURIComponent(parts[i])));
    return "file://" + out.join("/");
}

function _lcp(a, b) {
    var n = Math.min(a.length, b.length), i = 0;
    while (i < n && a.charAt(i) === b.charAt(i))
        i++;
    return a.substring(0, i);
}

// HOW WELL A NAME MATCHES WHAT WAS TYPED (fuzzy, so that typing `large` finds `✅large_language_model.md`).
// 0 an exact prefix (what Tab completes), 1 the same ignoring case, 2 the typed letters inside the name (from two letters), 3 the
// typed letters in order, with gaps (from three, and only when nothing better matched), -1 not at all. Nothing is ranked by anything but
// this and then the directory's own order.
function _tier(name, p) {
    if (p.length === 0 || name.substring(0, p.length) === p)
        return 0;
    var n = name.toLowerCase(), q = p.toLowerCase();
    if (n.substring(0, q.length) === q)
        return 1;
    if (q.length >= 2 && n.indexOf(q) >= 0)
        return 2;
    if (q.length >= 3) {
        var j = 0;
        for (var i = 0; i < n.length && j < q.length; i++)
            if (n.charAt(i) === q.charAt(j))
                j++;
        if (j === q.length)
            return 3;
    }
    return -1;
}

// Is there a path reference ANYWHERE in the text: a word that starts with "@" and then "/" or "~"? (A word that merely starts with "@" is a
// mention, or an email's tail: not a path.) The prompt turns the tools on the first time one is written, because the model can do nothing
// with a path it cannot read.
function hasPathRef(text) {
    return /(^|\s)@[\/~]/.test(String(text === undefined || text === null ? "" : text));
}

// The whole decision, from a directory's entries and what has been typed.
//   "one"    exactly one EXACT-PREFIX match: insert the rest of it, and "/" for a
//            directory or " " for a file (bash's own two endings). With no prefix
//            match at all and one fuzzy one, the same, but it REPLACES what was
//            typed (`replace` characters before the caret) -- the typed letters
//            are not the name's beginning.
//   "extend" several prefix matches sharing more than has been typed: insert that.
//   "list"   several matches with nothing left to extend: the caller shows
//            them (the prompt opens the list by itself, and Tab works too).
//   "none"   nothing matches: do nothing at all. No empty box, no beep.
// `rows` is every match, best first (prefix, then case-insensitive prefix, then
// inside, then in order); within a kind the directory's own order. Hidden
// entries are dropped unless the prefix asks for them.
function decide(entries, prefix) {
    var p = String(prefix === undefined || prefix === null ? "" : prefix);
    var es = entries || [];
    var wantHidden = p.charAt(0) === ".";
    var found = [];
    for (var i = 0; i < es.length; i++) {
        var e = es[i];
        if (!e)
            continue;
        var n = String(e.name);
        if (n.length === 0 || n === "." || n === "..")
            continue;
        if (!wantHidden && n.charAt(0) === ".")
            continue;
        var t = _tier(n, p);
        if (t < 0)
            continue;
        found.push({ name: n, isDir: !!e.isDir, tier: t, at: i });
    }
    found.sort(function (a, b) { return a.tier !== b.tier ? a.tier - b.tier : a.at - b.at; });
    // Letters scattered through a name are the last resort: with anything better to show they are only noise (`f00` in a directory of
    // numbered files would list every f100).
    if (found.length > 0 && found[0].tier < 3)
        found = found.filter(function (x) { return x.tier < 3; });
    var rows = [], exact = [];
    for (var f = 0; f < found.length; f++) {
        var row = { name: found[f].name, isDir: found[f].isDir };
        rows.push(row);
        if (found[f].tier === 0)
            exact.push(row);
    }
    if (rows.length === 0)
        return { state: "none", insert: "", rows: [] };
    if (exact.length === 1)
        return {
            state: "one",
            // The separator after a directory and the space after a file are
            // STRUCTURE, so they are never escaped; the name is.
            insert: escapePath(exact[0].name.substring(p.length)) + (exact[0].isDir ? "/" : " "),
            replace: 0,
            rows: rows
        };
    if (exact.length === 0) {
        if (rows.length === 1)
            return {
                state: "one",
                insert: escapePath(rows[0].name) + (rows[0].isDir ? "/" : " "),
                replace: escapePath(p).length,
                rows: rows
            };
        return { state: "list", insert: "", replace: 0, rows: rows };
    }
    var common = exact[0].name;
    for (var k = 1; k < exact.length; k++)
        common = _lcp(common, exact[k].name);
    if (common.length > p.length)
        return { state: "extend", insert: escapePath(common.substring(p.length)), replace: 0, rows: rows };
    return { state: "list", insert: "", replace: 0, rows: rows };
}
