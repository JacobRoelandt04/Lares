.pragma library

// =============================================================================
// ConfigCheck.js -- a hand-edited config against its SPEC: what is wrong in it, and (for the files read through JsonConfig)
// what it comes to.
//
// A SPEC (specs/<name>.js, one per config/<name>.jsonc) says for every key its type, its default and what it may be. Three things
// are made of it and of nothing else, so they cannot drift apart: the mistakes the shell tells (ConfigWatch) and `lares config`
// prints, the schema VS Code completes and underlines by (.examples/schema/<name>.schema.json, written by
// tools/dev/config_schema.js), and the settings of a file that JsonConfig reads.
//
// THE GRAMMAR. A plain object is a GROUP: its keys are the keys of the file, its values the nodes. A node is a list:
//     ["bool", default]
//     ["int",  default, min, max]            a whole number; null = no limit on that side
//     ["num",  default, min, max]
//     ["text", default, { re, words }]       `re`: a regex the whole text must match
//     ["word", default, ["a", "b"]]          one of these, exactly
//     ["path", default]                      a text; `~/` is the home (the reader expands it)
//     ["argv", default]                      a list of texts, the first one the program
//     ["list", default, node, { min, max }]
//     ["map",  default, node, { keys }]      any keys (`keys`: only these words), each value a node
//     ["obj",  default, group]               a group that may be absent as a whole (a list's item, mostly)
//     ["any",  default]
//     ["either", default, node, node ...]    the first that fits
//   A default of null also allows null. undefined is "absent" (nothing is written in the example, nothing is filled in).
//   Any list may end in an options object:
//     null      null is allowed too                  req      (a list's item) must be there
//     start     read once, as the shell starts       sample   the example's value is a sample, not the default
//     hidden    accepted, but not in the example (an old name)
//     say       words for a refused value instead of the built ones
//     secret    the value is a secret (a key, a token, a URL with one in it): no message ever shows it (a refused value is named,
//               never quoted), the schema marks it `x-secret`, and `lares config set` prints "(set)" for it and for anything holding it
//
//   defaults(spec)                  the whole object, every default filled in (a fresh copy)
//   read(spec, obj)                 { settings, problems }: the file over the defaults. A value that is wrong is left out, its
//                                   default stays and it is a problem; a wrong list item or map entry is dropped the same way.
//   keepStart(spec, first, next)    `next` with the keys read at the start as they were in `first`
//   check(spec, obj)                the problems alone: [{ path: ["a", 0, "b"], why: "must be ..." }]
//   parse(text)                     { value, error: null | { line, column, reason }, at(path) -> line, twice: [{ path, line, first }] }
//   mistakes(spec, text, name)      the lines a person reads: ["line 4: timers.snoozeMin is 500, must be a whole number 1 .. 120"]
//   schema(spec, words)             the JSON schema of it; words(path) -> the text of the example about that key
//
// Pure: no Qt. Loadable under node (tools/dev/config_node.js).
// =============================================================================

function isGroup(n) {
    return n !== null && typeof n === "object" && !(n instanceof Array);
}

function isObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array);
}

// The options of a node: its last element when that is a plain object and not a node's own argument.
function opts(n) {
    if (isGroup(n) || n.length < 3)
        return {};
    const last = n[n.length - 1];
    if (!isObject(last))
        return {};
    if ((n[0] === "obj" || n[0] === "list" || n[0] === "map") && n.length === 3)
        return {};                                     // ["list", default, node]: the last one is the node
    return last;
}

function copy(v) {
    if (v instanceof Array)
        return Array.from(v, copy);
    if (isObject(v)) {
        const o = {};
        for (const k in v)
            o[k] = copy(v[k]);
        return o;
    }
    return v;
}

function defaultOf(n) {
    if (isGroup(n)) {
        const o = {};
        for (const k in n) {
            const d = defaultOf(n[k]);
            if (d !== undefined)
                o[k] = d;
        }
        return o;
    }
    return copy(n[1]);
}

function defaults(spec) {
    return defaultOf(spec);
}

function shown(v) {
    if (v === undefined)
        return "nothing";
    const s = JSON.stringify(v);
    return s.length > 60 ? s.substring(0, 57) + "..." : s;
}

function range(lo, hi) {
    const a = lo !== null && lo !== undefined, b = hi !== null && hi !== undefined;
    return a && b ? " " + lo + " .. " + hi : a ? ", " + lo + " and up" : b ? ", " + hi + " at most" : "";
}

// What a node asks for, in words: "true or false", "a whole number 1 .. 120", "\"a\", \"b\" or \"c\"".
function wants(n) {
    if (isGroup(n))
        return "an object";
    const o = opts(n);
    if (o.say)
        return o.say;
    const orNull = n[1] === null || o.null ? " or null" : "";
    switch (n[0]) {
    case "bool": return "true or false" + orNull;
    case "int": return "a whole number" + range(n[2], n[3]) + orNull;
    case "num": return "a number" + range(n[2], n[3]) + orNull;
    case "text": return (o.re ? "a text like " + (o.like || o.re) : "a text") + orNull;
    case "path": return "a path" + orNull;
    case "word": {
        const w = Array.from(n[2], x => JSON.stringify(x));
        return (w.length > 1 ? w.slice(0, -1).join(", ") + " or " + w[w.length - 1] : w[0]) + orNull;
    }
    case "argv": return "a command as a list of texts, like [\"kitty\", \"-e\", \"yazi\"]" + orNull;
    case "list": return "a list of " + plural(n[2]) + orNull;
    case "map":
    case "obj": return "an object" + orNull;
    case "either": {
        const w = [];
        for (let i = 2; i < n.length; i++)
            if (isNode(n[i]))
                w.push(wants(n[i]));
        return w.join(", or ") + orNull;
    }
    }
    return "anything";
}

function plural(n) {
    if (isGroup(n))
        return "objects";
    switch (n[0]) {
    case "text": return "texts";
    case "path": return "paths";
    case "int": return "whole numbers";
    case "num": return "numbers";
    case "word": return "words (" + wants(n) + ")";
    case "obj":
    case "map": return "objects";
    case "either": return "values (" + wants(n) + ")";
    }
    return "values";
}

function isNode(n) {
    return isGroup(n) ? false : (n instanceof Array && typeof n[0] === "string");
}

// One value against one node: { ok, value, problems }. `ok` false: the value is not what the node asks for (its problems say why).
function take(n, v, path) {
    if (isGroup(n))
        return takeGroup(n, v, path);
    const o = opts(n);
    const bad = () => ({ ok: false, value: undefined, problems: [{ path: path, why: (o.secret ? "is not what it must be" : "is " + shown(v)) + ", must be " + wants(n) }] });
    if (v === null)
        return n[1] === null || o.null ? { ok: true, value: null, problems: [] } : bad();
    switch (n[0]) {
    case "any":
        return { ok: true, value: copy(v), problems: [] };
    case "bool":
        return typeof v === "boolean" ? { ok: true, value: v, problems: [] } : bad();
    case "int":
    case "num": {
        if (typeof v !== "number" || !isFinite(v) || (n[0] === "int" && Math.floor(v) !== v))
            return bad();
        const lo = n[2], hi = n[3];
        if (typeof lo === "number" && v < lo || typeof hi === "number" && v > hi)
            return bad();
        return { ok: true, value: v, problems: [] };
    }
    case "text":
    case "path":
        if (typeof v !== "string" || (o.re && !new RegExp(o.re).test(v)))
            return bad();
        return { ok: true, value: v, problems: [] };
    case "word":
        for (let i = 0; i < n[2].length; i++)
            if (n[2][i] === v)
                return { ok: true, value: v, problems: [] };
        return bad();
    case "argv": {
        if (!(v instanceof Array) || v.length === 0)
            return bad();
        for (let i = 0; i < v.length; i++)
            if (typeof v[i] !== "string")
                return bad();
        return v[0].length > 0 ? { ok: true, value: copy(v), problems: [] } : bad();
    }
    case "list": {
        if (!(v instanceof Array))
            return bad();
        if (typeof o.min === "number" && v.length < o.min || typeof o.max === "number" && v.length > o.max)
            return { ok: false, value: undefined, problems: [{ path: path, why: "has " + v.length + " entries, must have"
                + (typeof o.min === "number" && typeof o.max === "number" ? " " + o.min + " .. " + o.max
                    : typeof o.min === "number" ? " at least " + o.min : " at most " + o.max) }] };
        const out = [], problems = [];
        for (let i = 0; i < v.length; i++) {
            const r = take(n[2], v[i], path.concat([i]));
            for (const p of r.problems)
                problems.push(p);
            if (r.ok)
                out.push(r.value);
        }
        return { ok: true, value: out, problems: problems };
    }
    case "map": {
        if (!isObject(v))
            return bad();
        const out = {}, problems = [];
        for (const k in v) {
            if (o.keys) {
                let there = false;
                for (let i = 0; i < o.keys.length; i++)
                    there = there || o.keys[i] === k;
                if (!there) {
                    problems.push({ path: path.concat([k]), why: "is not a key" + maybe(k, o.keys) });
                    continue;
                }
            }
            const r = take(n[2], v[k], path.concat([k]));
            for (const p of r.problems)
                problems.push(p);
            if (r.ok)
                out[k] = r.value;
        }
        return { ok: true, value: out, problems: problems };
    }
    case "obj":
        return takeGroup(n[2], v, path);
    case "either": {
        let first = null;
        for (let i = 2; i < n.length; i++) {
            if (!isNode(n[i]))
                continue;
            const r = take(n[i], v, path);
            if (r.ok && r.problems.length === 0)
                return r;
            // the alternative of the value's own kind says it best (a map with one bad entry, not "must be true or false")
            if (!first || (r.ok && !first.ok))
                first = r;
        }
        return first && first.ok ? first : bad();
    }
    }
    return bad();
}

function takeGroup(g, v, path) {
    if (!isObject(v))
        return { ok: false, value: undefined, problems: [{ path: path, why: "is " + shown(v) + ", must be an object" }] };
    const out = {}, problems = [];
    let ok = true;
    for (const k in v) {
        if (!Object.prototype.hasOwnProperty.call(g, k)) {
            if (!(k === "$schema" && path.length === 0))
                problems.push({ path: path.concat([k]), why: "is not a key" + maybe(k, Object.keys(g)) });
            continue;
        }
        const r = take(g[k], v[k], path.concat([k]));
        for (const p of r.problems)
            problems.push(p);
        if (r.ok)
            out[k] = r.value;
    }
    for (const k in g) {
        if (isNode(g[k]) && opts(g[k]).req && out[k] === undefined) {
            problems.push({ path: path, why: "has no " + JSON.stringify(k) });
            ok = false;
        }
        if (out[k] === undefined) {
            const d = defaultOf(g[k]);
            if (d !== undefined)
                out[k] = d;
        } else if (isGroup(g[k])) {
            // filled in by its own takeGroup
        }
    }
    return { ok: ok, value: out, problems: problems };
}

// ", did you mean \"x\"?" for a word near one of the list, "" else.
function maybe(k, list) {
    let best = "", cost = 3;
    const a = String(k).toLowerCase();
    for (const w of list) {
        const b = String(w).toLowerCase();
        const d = a === b ? 0 : distance(a, b);
        if (d < cost && d < Math.max(a.length, b.length) / 2) {
            cost = d;
            best = w;
        }
    }
    return best === "" ? "" : " -- did you mean " + JSON.stringify(best) + "?";
}

// Edits between two words, a swap of two neighbours counting one.
function distance(a, b) {
    const m = a.length, n = b.length;
    let prev2 = null, prev = [], cur = [];
    for (let j = 0; j <= n; j++)
        prev.push(j);
    for (let i = 1; i <= m; i++) {
        cur = [i];
        for (let j = 1; j <= n; j++) {
            const same = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
            let v = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + same);
            if (prev2 && i > 1 && j > 1 && a.charAt(i - 1) === b.charAt(j - 2) && a.charAt(i - 2) === b.charAt(j - 1))
                v = Math.min(v, prev2[j - 2] + 1);
            cur.push(v);
        }
        prev2 = prev;
        prev = cur;
    }
    return prev[n];
}

// `next` with every key the spec reads at the start (`start`) as it was in `first`: the same objects, so what is bound to one sees no change.
function keepStart(spec, first, next) {
    for (const k in spec) {
        const n = spec[k];
        if (isGroup(n)) {
            if (isObject(first[k]) && isObject(next[k]))
                keepStart(n, first[k], next[k]);
        } else if (opts(n).start) {
            if (first[k] === undefined)
                delete next[k];
            else
                next[k] = first[k];
        }
    }
    return next;
}

function check(spec, obj) {
    return takeGroup(spec, obj, []).problems;
}

function read(spec, obj) {
    const r = takeGroup(spec, isObject(obj) ? obj : {}, []);
    return { settings: r.value, problems: r.problems };
}

// --- the text ---------------------------------------------------------------------------------------------------------

// Comments to spaces, every character in its place (JsonComments.strip's rule).
function strip(text) {
    let out = "", inStr = false, esc = false, i = 0;
    const t = String(text === undefined || text === null ? "" : text);
    const blank = s => s.replace(/[^\n]/g, " ");
    while (i < t.length) {
        const c = t.charAt(i);
        if (inStr) {
            out += c;
            if (esc) esc = false;
            else if (c === "\\") esc = true;
            else if (c === "\"") inStr = false;
            i++;
        } else if (c === "\"") {
            inStr = true;
            out += c;
            i++;
        } else if (c === "/" && t.charAt(i + 1) === "/") {
            let j = t.indexOf("\n", i);
            if (j < 0) j = t.length;
            out += blank(t.substring(i, j));
            i = j;
        } else if (c === "/" && t.charAt(i + 1) === "*") {
            const j = t.indexOf("*/", i + 2);
            if (j < 0) {
                out += t.substring(i);
                break;
            }
            out += blank(t.substring(i, j + 2));
            i = j + 2;
        } else {
            out += c;
            i++;
        }
    }
    return out;
}

// Where every key and list entry of a VALID text begins: { "a\u0000b": offset }, and the keys given twice in one object.
function places(stripped) {
    const t = stripped;
    const at = {}, twice = [];
    let i = 0;
    const ws = () => {
        while (i < t.length && " \t\n\r".indexOf(t.charAt(i)) >= 0)
            i++;
    };
    const string = () => {
        const from = i;
        i++;
        while (i < t.length && t.charAt(i) !== "\"")
            i += t.charAt(i) === "\\" ? 2 : 1;
        i++;
        return JSON.parse(t.substring(from, i));
    };
    const value = path => {
        ws();
        const c = t.charAt(i);
        if (c === "{") {
            i++;
            const seen = {};
            ws();
            while (i < t.length && t.charAt(i) !== "}") {
                ws();
                const where = i;
                const k = string();
                const p = path.concat([k]);
                const key = p.join("\u0000");
                if (Object.prototype.hasOwnProperty.call(seen, k))
                    twice.push({ path: p, at: where, first: seen[k] });
                seen[k] = where;
                at[key] = where;
                ws();
                i++;                                   // :
                value(p);
                ws();
                if (t.charAt(i) === ",")
                    i++;
                ws();
            }
            i++;
        } else if (c === "[") {
            i++;
            let n = 0;
            ws();
            while (i < t.length && t.charAt(i) !== "]") {
                ws();
                const p = path.concat([n]);
                at[p.join("\u0000")] = i;
                value(p);
                n++;
                ws();
                if (t.charAt(i) === ",")
                    i++;
                ws();
            }
            i++;
        } else if (c === "\"") {
            string();
        } else {
            while (i < t.length && ",]} \t\n\r".indexOf(t.charAt(i)) < 0)
                i++;
        }
    };
    value([]);
    return { at: at, twice: twice };
}

function lineAt(text, offset) {
    let n = 1;
    for (let i = text.indexOf("\n"); i >= 0 && i < offset; i = text.indexOf("\n", i + 1))
        n++;
    return n;
}

// `locate` is JsonComments.locate (the first syntax error of a text that does not parse); without one the line is unknown.
function parse(text, locate) {
    const t = String(text === undefined || text === null ? "" : text);
    const clean = strip(t);
    let v;
    try {
        v = JSON.parse(clean);
    } catch (e) {
        const where = locate ? locate(t) : null;
        return { value: undefined, error: where || { line: 0, column: 0, reason: String(e.message || e) }, line: () => 0, twice: [] };
    }
    const pl = places(clean);
    const line = path => {
        for (let n = path.length; n > 0; n--) {
            const off = pl.at[path.slice(0, n).join("\u0000")];
            if (off !== undefined)
                return lineAt(t, off);
        }
        return 0;
    };
    const twice = [];
    for (const d of pl.twice)
        twice.push({ path: d.path, line: lineAt(t, d.at), first: lineAt(t, d.first) });
    return { value: v, error: null, line: line, twice: twice };
}

// A path in words: timers.snoozeMin, calendars[0].url, apps["org.gnome.Loupe"].skip
function pathWords(path) {
    let out = "";
    for (const p of path) {
        if (typeof p === "number")
            out += "[" + p + "]";
        else if (/^[A-Za-z_$][\w$-]*$/.test(p))
            out += (out === "" ? "" : ".") + p;
        else
            out += "[" + JSON.stringify(p) + "]";
    }
    return out;
}

// The lines a person reads; [] for a file that is right (or empty: every key is optional).
function mistakes(spec, text, locate) {
    if (String(text === undefined || text === null ? "" : text).trim().length === 0)
        return [];
    const r = parse(text, locate);
    if (r.error)
        return [(r.error.line > 0 ? "line " + r.error.line + ": " : "") + r.error.reason + " -- the last good version stays in force"];
    if (!isObject(r.value))
        return ["the file is not an object { ... } -- the last good version stays in force"];
    const out = [];
    for (const d of r.twice)
        out.push({ line: d.line, say: pathWords(d.path) + " is given twice (the first on line " + d.first + " does not count)" });
    for (const p of check(spec, r.value))
        out.push({ line: r.line(p.path), say: (p.path.length > 0 ? pathWords(p.path) + " " : "the file ") + p.why });
    out.sort((a, b) => a.line - b.line);
    return Array.from(out, m => (m.line > 0 ? "line " + m.line + ": " : "") + m.say);
}

// --- the schema ---------------------------------------------------------------------------------------------------------

function schemaOf(n, path, words) {
    let s = {};
    if (isGroup(n)) {
        s = { type: "object", additionalProperties: false, properties: {} };
        const req = [];
        for (const k in n) {
            if (isNode(n[k]) && opts(n[k]).hidden) {
                s.properties[k] = { deprecated: true };
                continue;
            }
            s.properties[k] = schemaOf(n[k], path.concat([k]), words);
            if (isNode(n[k]) && opts(n[k]).req)
                req.push(k);
        }
        if (req.length > 0)
            s.required = req;
    } else {
        const o = opts(n);
        const orNull = t => (n[1] === null || o.null ? [t, "null"] : t);
        switch (n[0]) {
        case "bool": s.type = orNull("boolean"); break;
        case "int":
        case "num":
            s.type = orNull(n[0] === "int" ? "integer" : "number");
            if (typeof n[2] === "number") s.minimum = n[2];
            if (typeof n[3] === "number") s.maximum = n[3];
            break;
        case "text":
        case "path":
            s.type = orNull("string");
            if (o.re) s.pattern = o.re;
            if (o.words) s.examples = copy(o.words);
            break;
        case "word":
            s.enum = copy(n[2]);
            if (n[1] === null || o.null) s.enum.push(null);
            break;
        case "argv": s.type = orNull("array"); s.items = { type: "string" }; s.minItems = 1; break;
        case "list":
            s.type = orNull("array");
            s.items = schemaOf(n[2], path.concat(["*"]), words);
            if (typeof o.min === "number") s.minItems = o.min;
            if (typeof o.max === "number") s.maxItems = o.max;
            break;
        case "map":
            s.type = orNull("object");
            if (o.keys) {
                s.additionalProperties = false;
                s.properties = {};
                for (const k of o.keys)
                    s.properties[k] = schemaOf(n[2], path.concat([k]), words);
            } else {
                s.additionalProperties = schemaOf(n[2], path.concat(["*"]), words);
            }
            break;
        case "obj": s = schemaOf(n[2], path, words); if (n[1] === null || o.null) s.type = ["object", "null"]; break;
        case "either":
            s.anyOf = [];
            for (let i = 2; i < n.length; i++)
                if (isNode(n[i]))
                    s.anyOf.push(schemaOf(n[i], path, null));
            if (n[1] === null || o.null) s.anyOf.push({ type: "null" });
            break;
        }
        if (n[1] !== undefined && !o.sample)
            s.default = copy(n[1]);
    }
    if (!isGroup(n))
        s["x-wants"] = wants(n);
    if (!isGroup(n) && opts(n).secret)
        s["x-secret"] = true;
    const w = words ? words(path, n) : "";
    if (w)
        s.description = w;
    return s;
}

function schema(spec, words, title) {
    const s = schemaOf(spec, [], words);
    s.properties = Object.assign({ "$schema": { type: "string" } }, s.properties);
    return Object.assign({ "$schema": "http://json-schema.org/draft-07/schema#", title: title }, s);
}
