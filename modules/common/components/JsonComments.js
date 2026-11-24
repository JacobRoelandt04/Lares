.pragma library

// =============================================================================
// JsonComments.js -- comments out of a hand-edited JSON file, and nothing else.
//
//   JSON.parse(JsonComments.strip(text))
//
// The shell's hand-edited files (stocks.jsonc, the audio album overrides) take
// comments because their examples have them, and an example you cannot copy
// is a trap. `// to end of line` and `/* block */` are removed OUTSIDE
// strings only: a path or a URL with `//` in it (`file:///home/...`,
// `https://...`) survives, and so does an escaped quote inside a string.
//
// EVERY CHARACTER KEEPS ITS PLACE. A comment's characters become spaces and
// its newlines stay newlines, so the stripped text is exactly as long as the
// file and any offset found in it is the same offset -- and the same line and
// column -- in the file the user is looking at.
//
// An UNTERMINATED `/*` is left as it is, so JSON.parse fails on it and
// `locate` names it, rather than the rest of the file vanishing into a
// comment. A lone
// `/` is left too, for the same reason.
//
// WHERE A FILE IS BROKEN. Qt's JSON.parse says only "JSON.parse: Parse
// error" -- no position -- so a typo in a hand-edited file would read as
// nothing but that. `locate(text)` is a small strict scanner, run ONLY after
// JSON.parse has failed, that finds the first syntax error and answers
// `{ line, column, reason }` (1-based, in the file as written: it strips the
// comments itself and the offsets do not move), or null if it finds none.
//
// Pure: no Qt, loadable under node.
// =============================================================================

function _blank(s) {
    return s.replace(/[^\n]/g, " ");
}

function strip(text) {
    const txt = (text === undefined || text === null) ? "" : String(text);
    let out = "";
    let inStr = false;
    let esc = false;
    let i = 0;
    while (i < txt.length) {
        const c = txt.charAt(i);
        if (inStr) {
            out += c;
            if (esc) esc = false;
            else if (c === "\\") esc = true;
            else if (c === "\"") inStr = false;
            i++;
            continue;
        }
        if (c === "\"") {
            inStr = true;
            out += c;
            i++;
            continue;
        }
        if (c === "/" && txt.charAt(i + 1) === "/") {
            let j = txt.indexOf("\n", i);
            if (j < 0) j = txt.length;
            out += _blank(txt.substring(i, j));
            i = j;
            continue;
        }
        if (c === "/" && txt.charAt(i + 1) === "*") {
            const j = txt.indexOf("*/", i + 2);
            if (j < 0) {
                out += txt.substring(i);          // unterminated: let the parser say so
                break;
            }
            out += _blank(txt.substring(i, j + 2));
            i = j + 2;
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

// WHICH FILE A CONFIG LIVES IN. Every hand-edited config is `<name>.jsonc` (VS Code takes comments in that name without a
// word; in `.json` it screams at every one) and lives in the config directory's `config/` folder (the user, 2026-11-12: not all
// of them loose in the config's root). A loader names the file where it lives (`.../quickshell/config/osd.jsonc`) and reads it,
// then the `.json` beside it, then -- ONLY for a file in a folder named `config` -- the same names one level up, where every
// config lived before (`.../quickshell/osd.jsonc`, `.../osd.json`): a file not moved yet is still read, the one in config/ wins.
// `configPaths` answers the candidates, `pickFile` which of them is in force.
//   configPaths("/x/config/osd.jsonc") -> { jsonc: "/x/config/osd.jsonc", json: "/x/config/osd.json",
//                                           oldJsonc: "/x/osd.jsonc", oldJson: "/x/osd.json" }
//   configPaths("/x/osd.json")         -> { jsonc: "/x/osd.jsonc", json: "/x/osd.json", oldJsonc: "", oldJson: "" }
//   configPaths("/x/notes.txt")        -> { jsonc: "/x/notes.txt", json: "", oldJsonc: "", oldJson: "" }   (not a JSON name)
function configPaths(path) {
    const p = (path === undefined || path === null) ? "" : String(path);
    let jsonc = p, json = "";
    if (p.length > 6 && p.substring(p.length - 6) === ".jsonc") {
        json = p.substring(0, p.length - 1);
    } else if (p.length > 5 && p.substring(p.length - 5) === ".json") {
        jsonc = p + "c";
        json = p;
    }
    let oldJsonc = "", oldJson = "";
    const slash = jsonc.lastIndexOf("/");
    if (json.length > 0 && slash > 0 && jsonc.substring(0, slash).split("/").pop() === "config") {
        const up = jsonc.substring(0, jsonc.lastIndexOf("/", slash - 1));
        const name = jsonc.substring(slash + 1);
        oldJsonc = up + "/" + name;
        oldJson = up + "/" + name.substring(0, name.length - 1);
    }
    return { jsonc: jsonc, json: json, oldJsonc: oldJsonc, oldJson: oldJson };
}

// The file in force, in the order configPaths gives: "jsonc", "json", "oldJsonc", "oldJson" -- the first that exists -- or ""
// (none: the defaults; a loader that must create the file creates the .jsonc, in config/).
function pickFile(hasJsonc, hasJson, hasOldJsonc, hasOldJson) {
    return hasJsonc ? "jsonc" : (hasJson ? "json" : (hasOldJsonc ? "oldJsonc" : (hasOldJson ? "oldJson" : "")));
}

// The first syntax error in `text` (comments allowed), or null.
function locate(text) {
    const src = (text === undefined || text === null) ? "" : String(text);
    const t = strip(src);
    let i = 0;

    function fail(at, reason) {
        const before = src.substring(0, at);
        const nl = before.lastIndexOf("\n");
        throw { json: true, line: before.split("\n").length, column: at - nl, reason: reason };
    }
    function ws() {
        while (i < t.length) {
            const c = t.charAt(i);
            if (c === " " || c === "\t" || c === "\n" || c === "\r") i++;
            else break;
        }
    }
    function shown(c) {
        return c === "\n" ? "a line break" : "'" + c + "'";
    }
    // Something that cannot stand at `at`; an unterminated `/*` (which strip
    // leaves in place) says so by name.
    function unexpected(at, tail) {
        if (t.charAt(at) === "/" && t.charAt(at + 1) === "*")
            fail(at, "unterminated comment");
        fail(at, "unexpected " + shown(t.charAt(at)) + (tail || ""));
    }
    // A missing comma or colon is reported where it belongs: right after the
    // value or key before it.
    function value() {
        ws();
        if (i >= t.length)
            fail(i, "unexpected end of file");
        const c = t.charAt(i);
        if (c === "{") return object();
        if (c === "[") return array();
        if (c === "\"") return string();
        if (c === "-" || (c >= "0" && c <= "9")) return number();
        if (/[A-Za-z]/.test(c)) return literal();
        unexpected(i);
    }
    function object() {
        const open = i;
        i++;                                           // {
        ws();
        if (t.charAt(i) === "}") { i++; return; }
        for (;;) {
            ws();
            if (i >= t.length) fail(open, "unclosed '{'");
            const k = t.charAt(i);
            if (k !== "\"") {
                if (/[A-Za-z_$]/.test(k)) fail(i, "a key must be in double quotes");
                unexpected(i);
            }
            string();
            const keyEnd = i;
            ws();
            if (i >= t.length) fail(open, "unclosed '{'");
            if (t.charAt(i) !== ":") fail(keyEnd, "missing colon");
            i++;
            value();
            const end = i;
            ws();
            if (i >= t.length) fail(open, "unclosed '{'");
            const c = t.charAt(i);
            if (c === "}") { i++; return; }
            if (c === ",") {
                const comma = i;
                i++;
                ws();
                if (t.charAt(i) === "}") fail(comma, "trailing comma");
                continue;
            }
            if (c === "\"") fail(end, "missing comma");
            if (c === "]") fail(i, "']' where '}' was expected");
            unexpected(i);
        }
    }
    function array() {
        const open = i;
        i++;                                           // [
        ws();
        if (t.charAt(i) === "]") { i++; return; }
        for (;;) {
            value();
            const end = i;
            ws();
            if (i >= t.length) fail(open, "unclosed '['");
            const c = t.charAt(i);
            if (c === "]") { i++; return; }
            if (c === ",") {
                const comma = i;
                i++;
                ws();
                if (t.charAt(i) === "]") fail(comma, "trailing comma");
                continue;
            }
            if (c === "\"" || c === "{" || c === "[" || c === "-" || /[0-9A-Za-z]/.test(c))
                fail(end, "missing comma");
            if (c === "}") fail(i, "'}' where ']' was expected");
            unexpected(i);
        }
    }
    function string() {
        const open = i;
        i++;                                           // "
        for (;;) {
            if (i >= t.length) fail(open, "unterminated string");
            const c = t.charAt(i);
            if (c === "\"") { i++; return; }
            if (c === "\n") fail(open, "unterminated string");
            if (c < " ") fail(i, "control character in a string");
            if (c === "\\") {
                const e = t.charAt(i + 1);
                if (e === "u") {
                    if (!/^[0-9A-Fa-f]{4}$/.test(t.substring(i + 2, i + 6))) fail(i, "bad escape");
                    i += 6;
                    continue;
                }
                if ("\"\\/bfnrt".indexOf(e) < 0 || e === "") fail(i, "bad escape");
                i += 2;
                continue;
            }
            i++;
        }
    }
    function number() {
        const m = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/.exec(t.substring(i));
        const w = /^[-+0-9A-Za-z.]+/.exec(t.substring(i))[0];
        if (!m || m[0].length !== w.length)
            fail(i, "bad number '" + w + "'");
        i += m[0].length;
    }
    function literal() {
        const w = /^[A-Za-z0-9_]+/.exec(t.substring(i))[0];
        if (w !== "true" && w !== "false" && w !== "null")
            fail(i, "bad literal '" + w + "'");
        i += w.length;
    }

    try {
        ws();
        if (i >= t.length)
            fail(i, "the file is empty");
        value();
        ws();
        if (i < t.length)
            unexpected(i, " after the end");
        return null;
    } catch (e) {
        if (e && e.json)
            return { line: e.line, column: e.column, reason: e.reason };
        throw e;
    }
}
