.pragma library

// =============================================================================
// WindowTitle.js -- what the bar says about the focused window, pure and
// node-testable.
//
//   stripSuffix(title, names)  -> string
//   applyRewrites(title, rules) -> string
//   shownTitle(raw, ctx)        -> string
//   isTerminal(cls, classes)    -> bool
//
// WHY A SUFFIX IS STRIPPED. Browsers and editors repeat their own name at the end
// of every title ("New session - Claude — Zen Browser", "prompt.md - quickshell -
// Visual Studio Code") and the bar already shows the app's mark, so the repeat
// is noise. The name to drop is the window's INITIAL title (exactly the suffix
// that those apps repeat, as Zen and VS Code do) or the app's
// desktop-entry name. It is dropped only as ` <sep> <name>` at the END, with
// whitespace on both sides of the separator, so "foo-kitty" and "Zen Browser
// Plugins" are left alone. A title is never stripped to nothing: "Zen Browser"
// by itself stays "Zen Browser".
//
// REWRITES are the user's windowtray.jsonc `rewrites` (waybar's own, ported):
// [{re, to}] in order, `re` a JS regex source, `to` with $1... An invalid regex
// is skipped, an empty one too (it would match everywhere and insert `to` at
// the start). A rule that rewrites a title to "" is the user's choice and is
// honoured.
//
// No Qt calls, no imports: TextDiff.js (graphemes) is not needed here -- the
// suffix is found by comparing the string's end, on a boundary made of
// whitespace and one separator character, and cuts nothing mid-cluster.
// =============================================================================

var _SEPS = "-" + String.fromCharCode(0x2014) + String.fromCharCode(0x2013) + "|" + String.fromCharCode(0xB7);

function _str(s) {
    return s === undefined || s === null ? "" : String(s);
}

function _space(c) {
    return c !== "" && /\s/.test(c);
}

function _trim(s) {
    return s.replace(/^\s+|\s+$/g, "");
}

function stripSuffix(title, names) {
    var t = _str(title);
    if (!names || t === "")
        return t;
    var body = t.replace(/\s+$/, "");
    for (var n = 0; n < names.length; n++) {
        var name = _trim(_str(names[n]));
        if (name === "" || body.length <= name.length)
            continue;
        var at = body.length - name.length;
        if (body.substring(at).toLowerCase() !== name.toLowerCase())
            continue;
        var i = at;
        while (i > 0 && _space(body.charAt(i - 1)))
            i--;
        if (i === at || i === 0)
            continue;                                   // no space before the name
        if (_SEPS.indexOf(body.charAt(i - 1)) < 0)
            continue;                                   // not a separator
        i--;
        var j = i;
        while (j > 0 && _space(body.charAt(j - 1)))
            j--;
        if (j === i || j === 0)
            continue;                                   // no space before it, or nothing left
        return body.substring(0, j);
    }
    return t;
}

var _re = {};

// null for an invalid or empty source; compiled once.
function _regex(src) {
    if (typeof src !== "string" || src === "")
        return null;
    if (Object.prototype.hasOwnProperty.call(_re, src))
        return _re[src];
    var r = null;
    try {
        r = new RegExp(src);
    } catch (e) {
        r = null;
    }
    _re[src] = r;
    return r;
}

function applyRewrites(title, rules) {
    var t = _str(title);
    if (!rules)
        return t;
    for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        if (!rule || typeof rule !== "object")
            continue;
        var re = _regex(rule.re);
        if (re === null)
            continue;
        t = t.replace(re, typeof rule.to === "string" ? rule.to : "");
    }
    return t;
}

// ctx { initialTitle, appName, rules, stripSuffix }: stripSuffix is on unless it
// is explicitly false.
function shownTitle(raw, ctx) {
    var t = _str(raw);
    if (t === "")
        return "";
    var c = ctx || {};
    if (c.stripSuffix !== false)
        t = stripSuffix(t, [c.initialTitle, c.appName]);
    t = applyRewrites(t, c.rules);
    return _trim(t.replace(/\s+/g, " "));
}


// Is this window class one of `classes` (the config's terminalClasses): whole, whatever the case. A terminal's title
// change is held before the bar shows it (ActiveWindowState).
function isTerminal(cls, classes) {
    var c = _trim(_str(cls)).toLowerCase();
    if (!classes || c === "")
        return false;
    for (var i = 0; i < classes.length; i++)
        if (_trim(_str(classes[i])).toLowerCase() === c)
            return true;
    return false;
}
