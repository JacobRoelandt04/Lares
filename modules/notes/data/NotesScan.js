.pragma library
.import "../../common/components/Utf8.js" as U

// =============================================================================
// NotesScan.js -- the notes data layer's pure helpers: keys and names, the
// Obsidian suffix, the natural sort, and the parsers for what the shell
// tools print (find, file, realpath/stat, the head reader, NUL lists).
//
// A KEY is a note's path relative to the notes root, "/"-separated; a group
// is a directory, so a key is also a folder ("" = the root itself). Keys
// never contain a component that starts with "." (hidden entries are never
// listed) and never "..".
//
// EVERY PARSER READS BYTES. The tools print NUL-separated records because a
// file name may contain a newline, a tab or quotes; the collectors hand the
// bytes over as an ArrayBuffer, and each record is decoded on its own with
// the strict decoder, so a name that is not valid UTF-8 is SKIPPED (it could
// not be addressed again -- the decoded key would not be the name on disk)
// instead of turning into a key with U+FFFD in it.
// =============================================================================

// ---- keys --------------------------------------------------------------------

function parentOf(key) {
    const i = key.lastIndexOf("/");
    return i < 0 ? "" : key.substring(0, i);
}
function baseOf(key) {
    const i = key.lastIndexOf("/");
    return i < 0 ? key : key.substring(i + 1);
}
function join(parent, name) {
    return parent === "" ? name : parent + "/" + name;
}
function depthOf(key) {
    let n = 0;
    for (let i = 0; i < key.length; i++)
        if (key.charCodeAt(i) === 47)
            n++;
    return n;
}
// `key` lies strictly inside folder `anc` ("" = the root).
function isUnder(key, anc) {
    if (anc === "")
        return key !== "";
    return key.length > anc.length + 1 && key.charCodeAt(anc.length) === 47 && key.substring(0, anc.length) === anc;
}
function isSelfOrUnder(key, anc) {
    return key === anc || isUnder(key, anc);
}
// `key` with the prefix `from` replaced by `to`, or null when it is not
// `from` or under it.
function rebase(key, from, to) {
    if (key === from)
        return to;
    if (from !== "" && isUnder(key, from))
        return join(to, key.substring(from.length + 1));
    return null;
}
function isHiddenRel(rel) {
    if (rel === "")
        return false;
    const parts = rel.split("/");
    for (let i = 0; i < parts.length; i++)
        if (parts[i].length === 0 || parts[i].charCodeAt(0) === 46)
            return true;
    return false;
}
function absOf(root, key) {
    return key === "" ? root : root + "/" + key;
}
// The key of absolute path `abs` under `root`, or null when it is not under it.
function relOf(root, abs) {
    if (abs === root)
        return "";
    if (abs.length > root.length + 1 && abs.substring(0, root.length) === root && abs.charCodeAt(root.length) === 47)
        return abs.substring(root.length + 1);
    return null;
}

// ---- names ---------------------------------------------------------------------

// { base, ext } with ext INCLUDING its dot ("" when there is none). A leading
// dot is not an extension, nor is a trailing one.
function splitExt(name) {
    const i = name.lastIndexOf(".");
    if (i <= 0 || i === name.length - 1)
        return { base: name, ext: "" };
    return { base: name.substring(0, i), ext: name.substring(i) };
}
// The `ext` role: without the dot, as written.
function extOf(name, isGroup) {
    if (isGroup)
        return "";
    const e = splitExt(name).ext;
    return e.length > 0 ? e.substring(1) : "";
}
// Title = file name, with ".md" (any case) hidden; every other extension
// stays visible ("script.py").
function titleOf(name, isGroup) {
    if (isGroup)
        return name;
    const s = splitExt(name);
    return s.ext.toLowerCase() === ".md" ? s.base : name;
}
const _mdExts = { ".md": true, ".markdown": true, ".txt": true };
function kindOf(name, isGroup) {
    if (isGroup)
        return "";
    return _mdExts[splitExt(name).ext.toLowerCase()] === true ? "markdown" : "text";
}
// A user-typed base name made safe for a file name: control characters
// (NUL, newline, tab ...) become spaces, "/" becomes "-", leading dots and
// surrounding space go, and the result is capped at 200 bytes of UTF-8 so a
// long extension and an Obsidian suffix still fit NAME_MAX (255). "" when
// nothing is left (the caller decides what an empty name means).
function sanitize(s) {
    let t = String(s === undefined || s === null ? "" : s);
    t = t.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\//g, "-");
    t = t.trim().replace(/^\.+/, "").trim();
    if (t.length === 0)
        return "";
    return U.utf8Prefix(t, 200).trim();
}
// The Obsidian suffix ("notes.md", "notes 1.md", "notes 2.md" ...) is picked
// by the op scripts ON DISK (NotesFileOps: noclobber, mkdir, ln -s, verified
// mv), never from the model: only the file system knows which names are free
// at the moment of the move.

// ---- natural sort ------------------------------------------------------------

function _chunks(s) {
    return s.match(/[0-9]+|[^0-9]+/g) || [];
}
function _isDigits(c) {
    const k = c.charCodeAt(0);
    return k >= 48 && k <= 57;
}
// Numbers by value (as digit strings, so 30 digits do not lose precision),
// text case-insensitively in the locale's collation; ties fall back to the
// case-sensitive collation and finally to code points, so the order is total.
function natCompare(a, b) {
    const ca = _chunks(a.toLowerCase()), cb = _chunks(b.toLowerCase());
    const n = Math.min(ca.length, cb.length);
    for (let i = 0; i < n; i++) {
        const x = ca[i], y = cb[i];
        if (x === y)
            continue;
        if (_isDigits(x) && _isDigits(y)) {
            const xs = x.replace(/^0+(?=.)/, ""), ys = y.replace(/^0+(?=.)/, "");
            if (xs.length !== ys.length)
                return xs.length < ys.length ? -1 : 1;
            if (xs !== ys)
                return xs < ys ? -1 : 1;
            if (x.length !== y.length)
                return x.length < y.length ? -1 : 1;
            continue;
        }
        const c = x.localeCompare(y);
        if (c !== 0)
            return c < 0 ? -1 : 1;
        if (x !== y)
            return x < y ? -1 : 1;
    }
    if (ca.length !== cb.length)
        return ca.length < cb.length ? -1 : 1;
    const c = a.localeCompare(b);
    if (c !== 0)
        return c < 0 ? -1 : 1;
    return a === b ? 0 : (a < b ? -1 : 1);
}

// The display order of one folder's rows (plain objects with key, name,
// title, mtimeMs, btimeMs, size). Groups are MIXED with notes; a group's
// mtimeMs/size are already its aggregates (newest descendant, sum).
//   name     natural, case-insensitive, by title then by file name
//   modified mtimeMs          created btimeMs         size size
//   custom   `order` (the folder's stored keys): keys it does not know come
//            FIRST, newest-created first (a new note appears at the front),
//            then the stored order. `ascending` does not apply.
// Ties in every mode fall back to the name, ascending, so the order is total.
function sortKeys(rows, mode, ascending, order) {
    const byName = (a, b) => natCompare(a.title, b.title) || natCompare(a.name, b.name);
    if (mode === "custom") {
        const pos = {};
        const ord = order || [];
        for (let i = 0; i < ord.length; i++)
            if (pos[ord[i]] === undefined)
                pos[ord[i]] = i;
        const unknown = rows.filter(r => pos[r.key] === undefined).sort((a, b) => (b.btimeMs - a.btimeMs) || byName(a, b));
        const known = rows.filter(r => pos[r.key] !== undefined).sort((a, b) => pos[a.key] - pos[b.key]);
        return unknown.concat(known).map(r => r.key);
    }
    const dir = ascending ? 1 : -1;
    let prim = null;
    if (mode === "modified")
        prim = (a, b) => a.mtimeMs - b.mtimeMs;
    else if (mode === "created")
        prim = (a, b) => a.btimeMs - b.btimeMs;
    else if (mode === "size")
        prim = (a, b) => a.size - b.size;
    return rows.slice().sort((a, b) => {
        if (prim === null)
            return dir * byName(a, b);
        const c = prim(a, b);
        if (c !== 0)
            return c < 0 ? -dir : dir;
        return byName(a, b);
    }).map(r => r.key);
}

// ---- byte parsers --------------------------------------------------------------

function bytesOf(buf) {
    if (!buf || !(buf instanceof ArrayBuffer) || buf.byteLength === 0)
        return new Uint8Array(0);
    return new Uint8Array(buf);
}
function _nul(u8, from) {
    for (let i = from; i < u8.length; i++)
        if (u8[i] === 0)
            return i;
    return -1;
}
// Decode u8[a, b) strictly: { text, ok }. A character cut at the end (the
// head reader's 4096-byte limit) is dropped, not an error. One decoder is
// reused while it is clean (nothing pending, nothing invalid): a scan
// decodes two records per entry, and a fresh decoder each was a third of
// parseFind's time.
let _dec = null;
function decode(u8, a, b, allowCut) {
    if (b <= a)
        return { text: "", ok: true };
    if (_dec === null || _dec.need !== 0 || _dec.invalid)
        _dec = U.utf8Decoder();
    const t = _dec.push(u8.subarray(a, b), true);
    return { text: t, ok: !_dec.invalid && (allowCut === true || _dec.need === 0) };
}
// NUL-terminated records -> strings (undecodable ones become null, so the
// positions still line up with what was asked). `text`, when given, is Qt's
// decode of the same bytes (the op queue hands it over): with no U+FFFD in
// it the bytes were clean UTF-8, and one native decode plus a split is the
// whole parse -- a JS decode of a 500-note scan was 5 ms of the UI thread.
// NUL is never part of a multibyte sequence, so the records split exactly
// as the bytes do.
function splitZ(u8, text) {
    if (u8.length === 0)
        return [];
    let all = null;
    if (typeof text === "string" && text.indexOf("\ufffd") < 0) {
        all = text;
    } else {
        const d = U.utf8Decoder();
        const t = d.push(u8, true);
        if (!d.invalid && d.need === 0)
            all = t;
    }
    if (all !== null) {
        const parts = all.split("\u0000");
        if (u8[u8.length - 1] === 0)
            parts.pop();
        return parts;
    }
    // A name that is not UTF-8 somewhere: record by record, so only that
    // record is lost.
    const out = [];
    let at = 0;
    while (at < u8.length) {
        let e = _nul(u8, at);
        if (e < 0)
            e = u8.length;
        const d = decode(u8, at, e, false);
        out.push(d.ok ? d.text : null);
        at = e + 1;
    }
    return out;
}

// The scan script's output (NotesFileOps.scanScript):
//   "R\t<canonical root>\0\0"
//   per scanned folder: "#\t<1|0 exists>\t<1|0 deep>\t<rel>\0\0", then find's records
//   "%y\t%Y\t%s\t%T@\t%B@\t%i\t%P\0%l\0" -- the name is the LAST field of its
//   record (it may hold tabs), and the link target is a record of its own.
// -> { canon, sections: [{ rel, exists, deep, recs: [{ key, y, Y, size,
//      mtRaw, mtimeMs, birthMs, inode, link }] }], bad }
function parseFind(u8, text) {
    const res = { canon: "", sections: [], bad: 0 };
    const recs = splitZ(u8, text);
    let cur = null;
    for (let i = 0; i + 1 < recs.length; i += 2) {
        const s = recs[i], link = recs[i + 1];
        if (s === null || link === null) {
            res.bad++;
            continue;
        }
        if (s.substring(0, 2) === "R\t") {
            res.canon = s.substring(2);
            continue;
        }
        if (s.substring(0, 2) === "#\t") {
            cur = { rel: s.substring(6), exists: s.charAt(2) === "1", deep: s.charAt(4) === "1", recs: [] };
            res.sections.push(cur);
            continue;
        }
        if (!cur)
            continue;
        const f = [];
        let p = 0;
        for (let k = 0; k < 6; k++) {
            const q = s.indexOf("\t", p);
            if (q < 0)
                break;
            f.push(s.substring(p, q));
            p = q + 1;
        }
        if (f.length < 6)
            continue;
        const P = s.substring(p);
        if (P.length === 0)
            continue;
        const birth = parseFloat(f[4]);
        cur.recs.push({
            key: cur.rel === "" ? P : cur.rel + "/" + P,
            y: f[0], Y: f[1],
            size: parseFloat(f[2]) || 0,
            mtRaw: f[3],
            mtimeMs: Math.round((parseFloat(f[3]) || 0) * 1000),
            birthMs: birth > 0 ? Math.round(birth * 1000) : 0,
            inode: parseFloat(f[5]) || 0,
            link: link
        });
    }
    return res;
}

// The link step: `realpath -m -z` for each link (in order), "S\0", then
// `stat -L --printf '%s\t%.9Y\t%.9W\t%n\0'` for the ones that resolve
// (keyed by the path as given).
// -> { real: [string|null ...n], stat: { path: { size, mtRaw, mtimeMs, birthMs } } }
function parseLinks(u8, n, text) {
    const recs = splitZ(u8, text);
    const real = [];
    let i = 0;
    for (; i < recs.length && real.length < n; i++) {
        if (recs[i] === "S")
            break;
        real.push(recs[i]);
    }
    while (i < recs.length && recs[i] !== "S")
        i++;
    const stat = {};
    for (i = i + 1; i < recs.length; i++) {
        const s = recs[i];
        if (s === null)
            continue;
        const f = [];
        let p = 0;
        for (let k = 0; k < 3; k++) {
            const q = s.indexOf("\t", p);
            if (q < 0)
                break;
            f.push(s.substring(p, q));
            p = q + 1;
        }
        if (f.length < 3)
            continue;
        const birth = parseFloat(f[2]);
        stat[s.substring(p)] = {
            size: parseFloat(f[0]) || 0,
            mtRaw: f[1],
            mtimeMs: Math.round((parseFloat(f[1]) || 0) * 1000),
            birthMs: birth > 0 ? Math.round(birth * 1000) : 0
        };
    }
    while (real.length < n)
        real.push(null);
    return { real: real, stat: stat };
}

// `file -r -L -N -0 --mime-type` over n paths: "name\0: type\n" each, in
// the order asked. The name is skipped by its NUL (it may hold a newline);
// the type never holds one. -> [type ...n] ("" where the output ran short).
function parseMime(u8, n) {
    const out = [];
    let at = 0;
    while (at < u8.length && out.length < n) {
        const z = _nul(u8, at);
        if (z < 0)
            break;
        let e = z + 1;
        while (e < u8.length && u8[e] !== 10)
            e++;
        const d = decode(u8, z + 1, e, false);
        let t = d.ok ? d.text : "";
        t = t.replace(/^\s*:\s*/, "").trim();
        out.push(t);
        at = e + 1;
    }
    while (out.length < n)
        out.push("");
    return out;
}
function isTextMime(m) {
    return m.substring(0, 5) === "text/" || m === "inode/x-empty";
}
// Decoded text with no control character a text file would not hold (NUL,
// the C0 range but tab, newlines, vertical tab, form feed and escape; DEL).
function looksText(t) {
    return !/[\u0000-\u0008\u000e-\u001a\u001c-\u001f\u007f]/.test(t);
}
// Is this file a note? MIME is the rule (text/*, or empty), with two
// corrections file(1) needs, measured: a text too short to classify is
// "application/octet-stream" (a one-letter note, "x", would vanish from the
// grid the moment it was saved), and a note whose first bytes look like
// something else is that something ("{" -> application/json, "%!PS" ->
// application/postscript, "<svg>" -> image/svg+xml). So an octet-stream file,
// and any .md/.markdown/.txt file, is a note when its head is clean UTF-8
// text (`headOk`).
function isNote(mime, headOk, name) {
    if (isTextMime(mime))
        return true;
    if (!headOk)
        return false;
    return mime === "application/octet-stream" || _mdExts[splitExt(name).ext.toLowerCase()] === true;
}
// Does `isNote` need the head to decide?
function needsHead(mime, name) {
    return isTextMime(mime) || mime === "application/octet-stream" || _mdExts[splitExt(name).ext.toLowerCase()] === true;
}

// The head reader: "path\0" + up to 4096 raw bytes + "\0<token>\0" per file.
// The token is random per run, so a head's own bytes cannot end it early.
// -> { path: { text, ok } }: ok = valid UTF-8 (a character cut at 4096 is
// fine) that looks like text; a head that is not keeps its U+FFFD.
function parseHeads(u8, token) {
    const out = {};
    const tk = [];
    for (let i = 0; i < token.length; i++)
        tk.push(token.charCodeAt(i));
    const m = tk.length;
    let at = 0;
    while (at < u8.length) {
        const z = _nul(u8, at);
        if (z < 0)
            break;
        const name = decode(u8, at, z, false);
        // Find "\0" + token + "\0" after the name.
        let e = -1;
        let s = z + 1;
        while (s < u8.length) {
            const q = _nul(u8, s);
            if (q < 0)
                break;
            let hit = q + m + 1 < u8.length && u8[q + m + 1] === 0;
            for (let k = 0; hit && k < m; k++)
                if (u8[q + 1 + k] !== tk[k])
                    hit = false;
            if (hit) {
                e = q;
                break;
            }
            s = q + 1;
        }
        if (e < 0)
            break;
        if (name.ok)
            out[name.text] = headOf(u8, z + 1, e);
        at = e + m + 2;
    }
    return out;
}

function headOf(u8, a, b) {
    const d = decode(u8, a, b, true);
    return {
        text: d.text,
        ok: d.ok && looksText(d.text)
    };
}

// A token for the head reader: printable, unlikely, fresh per run.
function freshToken() {
    let t = "NOTESHEAD-";
    for (let i = 0; i < 4; i++)
        t += Math.floor(Math.random() * 0x100000000).toString(16);
    return t;
}
