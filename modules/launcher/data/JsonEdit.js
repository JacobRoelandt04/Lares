.pragma library

.import "../../common/components/JsonComments.js" as JC

// =============================================================================
// JsonEdit.js -- change ONE top-level member of a hand-edited JSON file and
// leave every other byte where the user put it. Pure.
//
//   setTopLevel(text, key, valueText) -> new text, or null
//
// launcher.jsonc is hand-edited and takes comments (JsonComments), and the
// launcher writes one thing into it: the `hidden` list, from Hide / Unhide.
// Re-serialising the parsed object would drop every comment and every
// formatting choice in the file on the first right-click, silently. So the
// value of `key` is replaced IN PLACE -- found by a scan of the comment-
// stripped text, whose offsets are the file's own (JsonComments keeps every
// character's place) -- and the rest of the file is copied through. A
// comment INSIDE the replaced value goes with it (it described the old one).
// When the member is absent it is added after the last one, on its own line,
// at the indentation of the first member.
//
// null when the text is not a JSON object (the caller refuses to write: a
// file it cannot read is never replaced).
// =============================================================================

function _ws(t, i) {
    while (i < t.length && " \t\r\n".indexOf(t.charAt(i)) >= 0)
        i++;
    return i;
}

// t[i] is '"'; the index after the closing quote, or -1.
function _string(t, i) {
    i++;
    while (i < t.length) {
        const c = t.charAt(i);
        if (c === "\\") {
            i += 2;
            continue;
        }
        if (c === "\"")
            return i + 1;
        if (c === "\n")
            return -1;
        i++;
    }
    return -1;
}

// The index after the value that starts at t[i], or -1.
function _value(t, i) {
    const c = t.charAt(i);
    if (c === "\"")
        return _string(t, i);
    if (c === "{" || c === "[") {
        let depth = 0;
        while (i < t.length) {
            const ch = t.charAt(i);
            if (ch === "\"") {
                i = _string(t, i);
                if (i < 0)
                    return -1;
                continue;
            }
            if (ch === "{" || ch === "[")
                depth++;
            else if (ch === "}" || ch === "]") {
                depth--;
                if (depth === 0)
                    return i + 1;
            }
            i++;
        }
        return -1;
    }
    const s = i;
    while (i < t.length && ",}] \t\r\n".indexOf(t.charAt(i)) < 0)
        i++;
    return i > s ? i : -1;
}

function setTopLevel(text, key, valueText) {
    const src = String(text === undefined || text === null ? "" : text);
    const t = JC.strip(src);
    try {
        const parsed = JSON.parse(t);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
            return null;
    } catch (e) {
        return null;
    }
    let i = _ws(t, 0);
    if (t.charAt(i) !== "{")
        return null;
    const open = i;
    i++;
    let lastEnd = -1;
    let indent = "    ";
    let first = true;
    for (;;) {
        i = _ws(t, i);
        if (t.charAt(i) === "}")
            break;
        if (t.charAt(i) !== "\"")
            return null;
        const ks = i;
        const ke = _string(t, i);
        if (ke < 0)
            return null;
        if (first) {
            const nl = src.lastIndexOf("\n", ks);
            const lead = src.substring(nl + 1, ks);
            if (nl >= open && /^[ \t]*$/.test(lead))
                indent = lead;
            first = false;
        }
        let k;
        try {
            k = JSON.parse(t.substring(ks, ke));
        } catch (e) {
            return null;
        }
        i = _ws(t, ke);
        if (t.charAt(i) !== ":")
            return null;
        i = _ws(t, i + 1);
        const vs = i;
        const ve = _value(t, i);
        if (ve < 0)
            return null;
        if (k === key)
            return src.substring(0, vs) + valueText + src.substring(ve);
        lastEnd = ve;
        i = _ws(t, ve);
        if (t.charAt(i) === ",") {
            i++;
            continue;
        }
        if (t.charAt(i) === "}")
            break;
        return null;
    }
    const close = i;
    const member = indent + JSON.stringify(key) + ": " + valueText + "\n";
    if (lastEnd < 0)
        return src.substring(0, open + 1) + "\n" + member + src.substring(close);
    // After the last member: its comma goes right after its value, the new
    // line goes before the closing brace, and whatever sat between the two
    // (a trailing comment) stays with the member it was written beside.
    let between = src.substring(lastEnd, close);
    if (between.length === 0 || between.charAt(between.length - 1) !== "\n")
        between += "\n";
    return src.substring(0, lastEnd) + "," + between + member + src.substring(close);
}
