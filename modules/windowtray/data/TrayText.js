.pragma library

// =============================================================================
// TrayText.js -- the words of the tray, pure and node-testable.
//
//   stripMnemonic(s)                -> string
//   stripMarkup(s)                  -> string
//   nameOf(f, cfg, lookupName)      -> string
//   statusTextOf(f, name)           -> string
//   collapseSeparators(rows)        -> rows
//
// MNEMONICS. A dbusmenu label marks its keyboard accelerator with "_" ("_Exit")
// and writes a literal underscore as "__". Quickshell 0.3.1 ALREADY does this for
// the menus it hands out (measured: "Save__As _Now x_y" arrives as "Save_As Now
// xy"), so the live tray menu must NOT be stripped again -- "Home_Network" would
// lose its underscore. stripMnemonic is for labels that come straight from a
// dbusmenu layout: the mock's trees, which are written as the apps write them.
//
// THE NAME of an item, first of: the user's rename (windowtray.jsonc), the item's
// Title (unless it is just its id: blueman's Title is "blueman"), the tooltip's
// title when the item has no Title at all, the desktop entry's name, the id.
// A Title that equals the id defers to the desktop entry and NEVER to the tooltip:
// such an item uses its tooltip as a status line (blueman: "Bluetooth Disabled"),
// and a name that changes with the state would be no name.
//
// THE STATUS is the tooltip's words that are not the name: title and description,
// markup stripped, joined with " · ".
// =============================================================================

function _str(s) {
    return s === undefined || s === null ? "" : String(s);
}

function _clean(s) {
    return _str(s).replace(/\s+/g, " ").replace(/^ | $/g, "");
}

// "_Exit" -> "Exit", "Save__As" -> "Save_As".
function stripMnemonic(s) {
    return _str(s).replace(/_(_)?/g, function (m, doubled) {
        return doubled ? "_" : "";
    });
}

var _ENT = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };

function _entity(m, body) {
    if (body.charAt(0) === "#") {
        var cp = body.charAt(1) === "x" || body.charAt(1) === "X" ? parseInt(body.substring(2), 16) : parseInt(body.substring(1), 10);
        if (!(cp > 0 && cp <= 0x10FFFF))
            return m;
        return String.fromCodePoint(cp);
    }
    return _ENT[body];
}

// Tags removed (a <br> is a space), entities decoded once, whitespace collapsed.
function stripMarkup(s) {
    var t = _str(s).replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, "");
    t = t.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/g, _entity);
    return _clean(t);
}

// f {id, title, tooltipTitle}; cfg {rename: {id: name}}; lookupName: the desktop
// entry's name for the id ("" when the caller has none).
function nameOf(f, cfg, lookupName) {
    var id = _clean(f ? f.id : "");
    var ren = cfg && cfg.rename ? cfg.rename : null;
    if (ren && Object.prototype.hasOwnProperty.call(ren, id)) {
        var r = _clean(ren[id]);
        if (r !== "")
            return r;
    }
    var title = stripMarkup(f ? f.title : "");
    if (title !== "" && title.toLowerCase() !== id.toLowerCase())
        return title;
    if (title === "") {
        var tip = stripMarkup(f ? f.tooltipTitle : "");
        if (tip !== "")
            return tip;
    }
    var look = _clean(lookupName);
    return look !== "" ? look : id;
}

// f {tooltipTitle, tooltipDescription}.
function statusTextOf(f, name) {
    var n = _clean(name).toLowerCase();
    var parts = [];
    var src = f ? [f.tooltipTitle, f.tooltipDescription] : [];
    for (var i = 0; i < src.length; i++) {
        var s = stripMarkup(src[i]);
        if (s !== "" && s.toLowerCase() !== n && parts.indexOf(s) < 0)
            parts.push(s);
    }
    return parts.join(" " + String.fromCharCode(0xB7) + " ");
}

// rows [{separator: bool, ...}]: no leading, trailing or doubled separators.
function collapseSeparators(rows) {
    var out = [];
    if (!rows)
        return out;
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (r.separator && (out.length === 0 || out[out.length - 1].separator))
            continue;
        out.push(r);
    }
    while (out.length > 0 && out[out.length - 1].separator)
        out.pop();
    return out;
}
