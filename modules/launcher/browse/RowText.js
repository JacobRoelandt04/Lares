.pragma library

// =============================================================================
// RowText.js -- a launcher row's name as StyledText.
//
// The query's matched letters in `accent`, and, for a search hit found inside
// a folder, the folder's name in `mutedColor` after it. The colours are the
// delegate's to resolve (a Repeater model carries facts, never a colour --
// CLAUDE.md); this only builds the string. StyledText, not RichText: a
// QTextDocument per row is re-laid out on every width change (CLAUDE.md).
// =============================================================================

function _esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function styled(name, indices, accent, suffix, mutedColor) {
    var out = "";
    var hit = {};
    for (var k = 0; indices && k < indices.length; k++)
        hit[indices[k]] = true;
    var open = false;
    for (var i = 0; i < name.length; i++) {
        var on = !!hit[i];
        if (on && !open)
            out += "<font color=\"" + accent + "\">";
        if (!on && open)
            out += "</font>";
        open = on;
        out += _esc(name.charAt(i));
    }
    if (open)
        out += "</font>";
    if (suffix)
        out += "<font color=\"" + mutedColor + "\">  " + _esc(suffix) + "</font>";
    return out;
}
