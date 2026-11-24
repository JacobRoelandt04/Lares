.pragma library

// =============================================================================
// DesktopFile.js -- a .desktop file the launcher reads itself. Pure.
//
//   parse(text)             -> { type, name, genericName, comment, icon, exec,
//                                path, terminal, noDisplay, hidden, keywords,
//                                categories, onlyShowIn, notShowIn }
//   execArgv(exec)          -> [string]   the Exec line as argv, field codes gone
//   showIn(only, not, desktops) -> bool   OnlyShowIn / NotShowIn against
//                                         XDG_CURRENT_DESKTOP's list
//
// Quickshell's DesktopEntries reads the applications directories; this reads
// the .desktop files a user put in the launcher's scripts root (and the
// links there to .desktop files DesktopEntries does not list), by the same
// rules (Desktop Entry Specification 1.5): the [Desktop Entry] group only,
// the unlocalised keys, string escapes \s \n \t \r \\ (and \; inside lists).
//
// EXEC. The general escapes are undone first, then the quoting rule: an
// argument in double quotes keeps its spaces, and inside it \" \` \$ \\
// stand for the character. Field codes are REMOVED -- a whole-argument %f %F
// %u %U %d %D %n %N %i %c %k %v %m goes, one inside an argument is dropped
// from it -- and %% is a literal %. That is what DesktopEntry.command does
// (measured on tools/dev/fixtures/launcher/applications/fieldcodes.desktop), so an app reads the same whichever
// of the two parsed it; the service probe compares them on every fixture.
// =============================================================================

function _unescape(v) {
    let out = "";
    for (let i = 0; i < v.length; i++) {
        const c = v.charAt(i);
        if (c !== "\\" || i + 1 >= v.length) {
            out += c;
            continue;
        }
        const e = v.charAt(++i);
        if (e === "s")
            out += " ";
        else if (e === "n")
            out += "\n";
        else if (e === "t")
            out += "\t";
        else if (e === "r")
            out += "\r";
        else if (e === "\\")
            out += "\\";
        else
            out += "\\" + e;
    }
    return out;
}

// A list value: split on unescaped ';', then unescape each item; empty items
// (the trailing ';') are dropped.
function _list(v) {
    const parts = [];
    let cur = "";
    for (let i = 0; i < v.length; i++) {
        const c = v.charAt(i);
        if (c === "\\" && i + 1 < v.length) {
            const e = v.charAt(i + 1);
            if (e === ";") {
                cur += ";";
                i++;
                continue;
            }
            cur += c + e;
            i++;
            continue;
        }
        if (c === ";") {
            parts.push(cur);
            cur = "";
            continue;
        }
        cur += c;
    }
    parts.push(cur);
    return parts.map(p => _unescape(p).trim()).filter(p => p.length > 0);
}

function _bool(v) {
    return String(v).trim().toLowerCase() === "true";
}

function parse(text) {
    const out = {
        type: "",
        name: "",
        genericName: "",
        comment: "",
        icon: "",
        exec: "",
        path: "",
        terminal: false,
        noDisplay: false,
        hidden: false,
        keywords: [],
        categories: [],
        onlyShowIn: [],
        notShowIn: []
    };
    const lines = String(text || "").split("\n");
    let group = "";
    const raw = {};
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].replace(/\r$/, "");
        const t = line.trim();
        if (t.length === 0 || t.charAt(0) === "#")
            continue;
        if (t.charAt(0) === "[") {
            group = t;
            continue;
        }
        if (group !== "[Desktop Entry]")
            continue;
        const eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        const key = line.substring(0, eq).trim();
        if (raw[key] !== undefined)
            continue;               // the first of a duplicated key wins
        raw[key] = line.substring(eq + 1).replace(/^[ \t]+/, "");
    }
    const s = k => raw[k] === undefined ? "" : _unescape(raw[k]);
    out.type = s("Type");
    out.name = s("Name");
    out.genericName = s("GenericName");
    out.comment = s("Comment");
    out.icon = s("Icon");
    out.exec = raw.Exec === undefined ? "" : raw.Exec;   // Exec unescapes in execArgv
    out.path = s("Path");
    out.terminal = raw.Terminal !== undefined && _bool(raw.Terminal);
    out.noDisplay = raw.NoDisplay !== undefined && _bool(raw.NoDisplay);
    out.hidden = raw.Hidden !== undefined && _bool(raw.Hidden);
    out.keywords = raw.Keywords === undefined ? [] : _list(raw.Keywords);
    out.categories = raw.Categories === undefined ? [] : _list(raw.Categories);
    out.onlyShowIn = raw.OnlyShowIn === undefined ? [] : _list(raw.OnlyShowIn);
    out.notShowIn = raw.NotShowIn === undefined ? [] : _list(raw.NotShowIn);
    return out;
}

var _CODES = "fFuUdDnNickvm";

// One argument's field codes: %% -> %, a known code dropped, an unknown
// %x kept as written.
function _codes(arg) {
    let out = "";
    for (let i = 0; i < arg.length; i++) {
        const c = arg.charAt(i);
        if (c !== "%" || i + 1 >= arg.length) {
            out += c;
            continue;
        }
        const e = arg.charAt(i + 1);
        if (e === "%") {
            out += "%";
            i++;
        } else if (_CODES.indexOf(e) >= 0) {
            i++;
        } else {
            out += c;
        }
    }
    return out;
}

function execArgv(exec) {
    const v = _unescape(String(exec || ""));
    const args = [];
    let cur = null;          // null: between arguments
    let quoted = false;
    let wasQuoted = false;
    for (let i = 0; i < v.length; i++) {
        const c = v.charAt(i);
        if (quoted) {
            if (c === "\\" && i + 1 < v.length && "\"`$\\".indexOf(v.charAt(i + 1)) >= 0) {
                cur += v.charAt(++i);
                continue;
            }
            if (c === "\"") {
                quoted = false;
                continue;
            }
            cur += c;
            continue;
        }
        if (c === " " || c === "\t" || c === "\n") {
            if (cur !== null) {
                args.push({ text: cur, quoted: wasQuoted });
                cur = null;
                wasQuoted = false;
            }
            continue;
        }
        if (cur === null)
            cur = "";
        if (c === "\"") {
            quoted = true;
            wasQuoted = true;
            continue;
        }
        cur += c;
    }
    if (cur !== null)
        args.push({ text: cur, quoted: wasQuoted });
    const out = [];
    for (let i = 0; i < args.length; i++) {
        const a = args[i];
        // A quoted argument is literal (the spec forbids field codes inside
        // quotes); a bare one loses its codes, and vanishes if that was all.
        if (a.quoted) {
            out.push(a.text);
            continue;
        }
        const t = _codes(a.text);
        if (t.length > 0 || a.text.length === 0)
            out.push(t);
    }
    return out;
}

// XDG_CURRENT_DESKTOP is a colon-separated list; an entry with OnlyShowIn is
// shown only where one of them is listed, one with NotShowIn is hidden where
// one of them is. Names compare exactly (the spec's registered names).
function showIn(onlyShowIn, notShowIn, desktops) {
    const cur = desktops || [];
    const only = onlyShowIn || [], not = notShowIn || [];
    if (only.length > 0 && !cur.some(d => only.indexOf(d) >= 0))
        return false;
    if (not.length > 0 && cur.some(d => not.indexOf(d) >= 0))
        return false;
    return true;
}
