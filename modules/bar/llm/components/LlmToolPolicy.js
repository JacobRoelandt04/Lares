.pragma library
.import "../../../common/components/Utf8.js" as Utf8
.import "LlmShell.js" as Shell

// =============================================================================
// LlmToolPolicy.js
//
// The pure half of the tool registry: everything that can be decided from
// strings and objects alone, with no process, no file and no service. It is
// a library so its decisions can be table-tested -- the grantKeyOf table,
// the renderArgv cases, the load-time rejections -- and so
// LlmTools.qml, which owns the files and the one Process, stays a thin shell
// around these functions.
//
// THE TEMPLATING LAW, enforced HERE at load time:
//   1. An argv element is one string; `{name}` is replaced by the argument AS
//      TEXT and the element stays ONE argv entry -- never split, never quoted,
//      never shelled. `{name=default}` supplies a default. A nested array is
//      an optional group, included only when every placeholder in it has a
//      value; a group whose only placeholder is a boolean rides without the
//      value when true.
//   2. A placeholder never sits in code. A shell (`sh -c`) may carry one only
//      at index >= 3 (the positional `$0 $1 ...`); an interpreter (python3,
//      sed, awk, jq, node ...) only after a `--`; an EMBEDDED placeholder
//      (text around it in the element) needs a constrained type -- integer,
//      number, boolean, an enum or a pattern -- and its value may carry none
//      of `" ' \ ( ) { } ;` or a newline. `sed -n '{from},{to}p'` executes
//      `e echo INJECTED` when the model fills `to` (measured); this rule is
//      why that entry cannot be loaded.
//   3. Validation at call time coerces what small models send ("7" -> 7,
//      "true" -> true), refuses everything else with the exact reason, and
//      drops undeclared keys -- naming them so the trailer can say so.
//
// THE VERB RULE: a run_command grant is `program verb` per SIMPLE
// command. The executable alone lets `pacman -Q` cover `pacman -R`; the whole
// line never matches twice; the program plus the word that says what it is
// doing is what a person means by "commands like this" (and Claude Code's own
// unit, `Bash(git commit:*)`). The reading of a line lives in
// LlmShell.js: a chain is judged command by command, a read-only command
// needs no grant at all, and a redirection, a variable prefix or a program
// that is not a plain name is UNKEYABLE: the button is absent and the
// reason says "no rule can describe this command". The heuristic errs toward asking.
// =============================================================================

// Shells and interpreters are matched by SHAPE, not by a list of exact names:
// `python3.14 -c`, `gawk`, `busybox sh` are the same programs (a fixed list
// would let `env bash -c "{x}"` and `python3.14 -c "{x}"` load
// clean). A WRAPPER as argv[0] is refused outright: `env`, `busybox`,
// `timeout`, `nice` and their kin hand the real program's name to the next
// element, where no rule below looks for it -- and the runner adds its own
// timeout, so a registry entry never needs one.
var SHELL_RE = /^(sh|bash|zsh|dash|fish|ksh|mksh|ash|csh|tcsh)$/;
var INTERP_RE = /^(python[0-9.]*|sed|g?awk|mawk|nawk|perl[0-9.]*|jq|node|nodejs|ruby|lua[0-9.]*|luajit|php|tclsh|Rscript|gjs|osascript)$/;
var WRAPPER_RE = /^(env|busybox|toybox|timeout|nice|ionice|nohup|setsid|stdbuf|chrt|taskset|command|exec|sudo|doas|pkexec|su|time|unbuffer|script|systemd-run|flatpak-spawn|xargs|watch|eval|source)$/;
// Programs whose argument after one of these words is CODE in their own
// language: a whole free-string placeholder there is as much an injection
// as one inside a shell script (`hyprctl dispatch {lua}` executes Lua).
var CODE_AFTER = { hyprctl: ["dispatch", "eval", "keyword", "batch", "setprop"] };
var RESERVED = ["outputCap", "timeoutS", "cwd"];
var ALLOW_WORDS = ["tool", "verb", "dir", "host", "action", "exact", "never"];
var TYPES = ["string", "integer", "number", "boolean"];
var SCHEMA_KEYS = ["type", "enum", "pattern", "minimum", "maximum", "maxLength", "default", "description"];
var EMBED_BAD = /["'\\(){};\n]/;
var NAME_RE = /^[a-z][a-z0-9_]{1,31}$/;
var PLACEHOLDER_RE = /\{([A-Za-z][A-Za-z0-9_]*)(=([^}]*))?\}/g;

// ---- small helpers ---------------------------------------------------------

function basename(p) {
    var s = String(p || "");
    var i = s.lastIndexOf("/");
    return i >= 0 ? s.substring(i + 1) : s;
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// Stable JSON: keys sorted at every level, so two calls with the same
// arguments in a different key order compare equal (the repeat detector).
function canonicalJson(v) {
    if (Array.isArray(v)) return "[" + v.map(canonicalJson).join(",") + "]";
    if (isObject(v)) {
        var keys = Object.keys(v).sort();
        var parts = [];
        for (var i = 0; i < keys.length; i++)
            parts.push(JSON.stringify(keys[i]) + ":" + canonicalJson(v[keys[i]]));
        return "{" + parts.join(",") + "}";
    }
    return JSON.stringify(v === undefined ? null : v);
}

// "1234567" -> "1 234 567". A space, not a thin space: the same trailer is
// read by the model, and a plain digit group is what every tokenizer knows.
function groupDigits(n) {
    var s = String(Math.round(Math.abs(n)));
    var out = "";
    while (s.length > 3) {
        out = " " + s.substring(s.length - 3) + out;
        s = s.substring(0, s.length - 3);
    }
    return (n < 0 ? "-" : "") + s + out;
}

// Seconds with one decimal, as the trailer and the block print them.
function fmtSeconds(ms) {
    return (Math.round((ms || 0) / 100) / 10).toFixed(1) + " s";
}

// UTF-8 helpers live in Utf8.js (shared with the notes module); these
// names stay so every caller of Policy.utf8* keeps working.
function utf8Length(s) { return Utf8.utf8Length(s); }
function utf8Prefix(s, maxBytes) { return Utf8.utf8Prefix(s, maxBytes); }
function utf8Suffix(s, maxBytes) { return Utf8.utf8Suffix(s, maxBytes); }
function utf8Decoder() { return Utf8.utf8Decoder(); }
function concatBytes(parts, total) { return Utf8.concatBytes(parts, total); }
function firstCharStart(u8) { return Utf8.firstCharStart(u8); }

// `~` and `~/x` -> the home directory. `$VAR` is never expanded.
function expandTilde(v, home) {
    var s = String(v);
    if (s === "~") return home;
    if (s.indexOf("~/") === 0) return home + s.substring(1);
    return s;
}

// Collapse `.` and `..` segments of an absolute path. Symlinks are the
// runner's business (write.py resolves them and reports the real path).
function normalizePath(p) {
    var abs = p.charAt(0) === "/";
    var parts = p.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var seg = parts[i];
        if (seg === "" || seg === ".") continue;
        if (seg === "..") { if (out.length > 0) out.pop(); continue; }
        out.push(seg);
    }
    return (abs ? "/" : "") + out.join("/");
}

function parentDir(p) {
    var n = normalizePath(p);
    var i = n.lastIndexOf("/");
    if (i <= 0) return "/";
    return n.substring(0, i);
}

// ---- the shell command line ------------------------------------------------

// The parser, the read-only table and the per-command judgement live in
// LlmShell.js; this file keeps the names its
// callers use.
function matchPolicy(text, patterns) { return Shell.matchPolicy(text, patterns); }
function hitWords(m) { return Shell.hitWords(m); }

// analyzeShell(command, policy, { hasGrant }) -> the line's verdict: mode
// "auto" | "granted" | "ask" | "refused", the grant `keys` it would write or
// uses, `label`, `grantable`, `reason`, and `parts` (every simple command with
// its own state -- what the confirmation shows). See LlmShell.js.
function analyzeShell(command, policy, opts) { return Shell.analyze(command, policy, opts); }

// ---- placeholders and argv rendering ---------------------------------------

// Every placeholder in one element: [{ name, def (string|null), whole }].
function placeholdersOf(el) {
    var out = [];
    var s = String(el);
    PLACEHOLDER_RE.lastIndex = 0;
    var m;
    while ((m = PLACEHOLDER_RE.exec(s)) !== null) {
        out.push({ name: m[1], def: (m[2] !== undefined) ? m[3] : null,
                   whole: m[0].length === s.length });
    }
    return out;
}

function valueText(v) {
    if (typeof v === "boolean") return v ? "true" : "false";
    if (typeof v === "number") return String(v);
    return String(v);
}

// renderArgv(argv, norm, ctx) -> { argv: [..], error: "" }
//   ctx: { home, dir, outputCap, timeoutS, cwd, types: { name: type } }
// Whole-element string values that are `~` or `~/...` are expanded; a literal
// element starting `llm_tools/` resolves to the registry dir; the reserved
// names take the entry's own numbers.
// llm.jsonc `tools.ask` over a decision ({ mode, grantable, grantKeys, grantLabel, reason }): a call of a named tool that would have run
// asks, every time, and no rule is offered. Stricter only: a refusal stands, and a name can free nothing.
function stricter(out, names, name) {
    if (!names || names.indexOf(name) < 0 || out.mode === "refused") return out;
    if (out.mode !== "ask") out.reason = "asks first (llm.jsonc)";
    out.mode = "ask";
    out.grantable = false;
    out.grantKeys = [];
    out.grantLabel = "";
    return out;
}

function renderArgv(argv, norm, ctx) {
    var c = ctx || {};
    var vals = {};
    for (var k in (norm || {})) vals[k] = norm[k];
    vals.outputCap = c.outputCap;
    vals.timeoutS = c.timeoutS;
    vals.cwd = c.cwd;
    var types = c.types || {};
    var out = [];
    var renderEl = function (el, inGroup) {
        var s = String(el);
        var phs = placeholdersOf(s);
        if (phs.length === 0) {
            if (s.indexOf("llm_tools/") === 0 && c.dir) return { text: c.dir + "/" + s.substring(10) };
            return { text: s };
        }
        // A boolean placeholder that is the whole element: inside a group it
        // is the switch, outside it is the value as text.
        if (phs.length === 1 && phs[0].whole) {
            var p = phs[0];
            var v = vals[p.name];
            if (v === undefined || v === null || v === "") {
                if (p.def !== null) v = p.def; else return { absent: p.name };
            }
            if (typeof v === "boolean" || types[p.name] === "boolean") {
                var b = (v === true || v === "true");
                if (inGroup) return b ? { drop: true } : { absent: p.name, off: true };
                return { text: b ? "true" : "false" };
            }
            var t = valueText(v);
            if (typeof v === "string") t = expandTilde(t, c.home || "");
            return { text: t };
        }
        var text = s;
        for (var i = 0; i < phs.length; i++) {
            var q = phs[i];
            var w = vals[q.name];
            if (w === undefined || w === null || w === "") {
                if (q.def !== null) w = q.def; else return { absent: q.name };
            }
            var lit = q.def !== null ? "{" + q.name + "=" + q.def + "}" : "{" + q.name + "}";
            text = text.split(lit).join(valueText(w));
        }
        return { text: text };
    };
    for (var i = 0; i < argv.length; i++) {
        var el = argv[i];
        if (Array.isArray(el)) {
            var group = [];
            var skip = false;
            for (var j = 0; j < el.length; j++) {
                var r = renderEl(el[j], true);
                if (r.absent !== undefined) { skip = true; break; }
                if (r.drop) continue;
                group.push(r.text);
            }
            if (!skip) out = out.concat(group);
            continue;
        }
        var r2 = renderEl(el, false);
        if (r2.absent !== undefined)
            return { argv: null, error: "argument " + r2.absent + " is required by argv[" + i + "]" };
        out.push(r2.text);
    }
    return { argv: out, error: "" };
}

// The summary/progress templates: placeholders filled from norm, defaults
// honoured, an absent value left as its name in brackets so a bad template
// never throws. Values are shortened so the line stays under 80 chars.
function fillTemplate(tpl, norm, home) {
    var s = String(tpl || "");
    PLACEHOLDER_RE.lastIndex = 0;
    return s.replace(PLACEHOLDER_RE, function (m, name, eq, def) {
        var v = (norm && norm[name] !== undefined && norm[name] !== null && norm[name] !== "")
            ? norm[name] : (eq !== undefined ? def : undefined);
        if (v === undefined) return "[" + name + "]";
        var t = valueText(v).replace(/\s+/g, " ");
        if (home && typeof v === "string" && t.indexOf(home) === 0) t = "~" + t.substring(home.length);
        if (t.length > 48) t = t.substring(0, 47) + "…";
        return t;
    });
}

// ---- call-time validation --------------------------------------------------

// validateArgs(spec, args) -> { ok, error, norm, ignored }
//   spec: { properties, required, embedded }
function validateArgs(spec, args) {
    if (!isObject(args)) return { ok: false, error: "arguments are not an object", norm: null, ignored: [] };
    var props = spec.properties || {};
    var required = spec.required || [];
    var embedded = spec.embedded || [];
    var norm = {};
    var ignored = [];
    for (var k in args) if (!props.hasOwnProperty(k)) ignored.push(k);
    for (var i = 0; i < required.length; i++) {
        var r = required[i];
        var rv = args[r];
        if (rv === undefined || rv === null || rv === "")
            return { ok: false, error: "missing required argument " + r, norm: null, ignored: ignored };
    }
    for (var name in props) {
        var p = props[name] || {};
        var v = args[name];
        if (v === undefined || v === null || v === "") {
            if (p["default"] !== undefined) norm[name] = p["default"];
            continue;
        }
        var type = p.type || "string";
        if (type === "integer" || type === "number") {
            if (typeof v === "string" && /^\s*-?\d+(\.\d+)?\s*$/.test(v)) v = Number(v);
            if (typeof v !== "number" || !isFinite(v))
                return { ok: false, error: name + " must be a " + type, norm: null, ignored: ignored };
            if (type === "integer" && Math.round(v) !== v)
                return { ok: false, error: name + " must be an integer", norm: null, ignored: ignored };
            if (p.minimum !== undefined && v < p.minimum)
                return { ok: false, error: name + " must be at least " + p.minimum, norm: null, ignored: ignored };
            if (p.maximum !== undefined && v > p.maximum)
                return { ok: false, error: name + " must be at most " + p.maximum, norm: null, ignored: ignored };
        } else if (type === "boolean") {
            if (v === "true") v = true;
            else if (v === "false") v = false;
            if (typeof v !== "boolean")
                return { ok: false, error: name + " must be true or false", norm: null, ignored: ignored };
        } else {
            if (typeof v === "number" || typeof v === "boolean") v = String(v);
            if (typeof v !== "string")
                return { ok: false, error: name + " must be a string", norm: null, ignored: ignored };
            if (p.maxLength !== undefined && v.length > p.maxLength)
                return { ok: false, error: name + " is longer than " + p.maxLength + " characters", norm: null, ignored: ignored };
            if (p.pattern !== undefined) {
                var re = null;
                try { re = new RegExp(p.pattern); } catch (e) { re = null; }
                if (re && !re.test(v))
                    return { ok: false, error: name + " does not match " + p.pattern, norm: null, ignored: ignored };
            }
            if (embedded.indexOf(name) >= 0 && EMBED_BAD.test(v))
                return { ok: false, error: name + " may not contain quotes, backslashes, brackets, braces, semicolons or newlines", norm: null, ignored: ignored };
        }
        if (p["enum"] !== undefined) {
            var en = p["enum"];
            var found = false;
            for (var e2 = 0; e2 < en.length; e2++) if (en[e2] === v) found = true;
            if (!found)
                return { ok: false, error: name + " must be one of " + en.join(", "), norm: null, ignored: ignored };
        }
        norm[name] = v;
    }
    return { ok: true, error: "", norm: norm, ignored: ignored };
}

// ---- load-time compilation -------------------------------------------------

// A parameters schema reduced to the subset the wire and the validator know.
function compileSchema(params, path, errors) {
    var props = {};
    var src = (params && isObject(params.properties)) ? params.properties : {};
    for (var name in src) {
        var p = src[name];
        if (!isObject(p)) { errors.push(path + ".properties." + name + " is not an object"); return null; }
        var type = p.type || "string";
        if (TYPES.indexOf(type) < 0) { errors.push(path + ".properties." + name + ".type " + JSON.stringify(type) + " is not string, integer, number or boolean"); return null; }
        var q = { type: type };
        for (var i = 0; i < SCHEMA_KEYS.length; i++) {
            var k = SCHEMA_KEYS[i];
            if (k !== "type" && p[k] !== undefined) q[k] = p[k];
        }
        if (q.pattern !== undefined) {
            try { new RegExp(q.pattern); } catch (e) { errors.push(path + ".properties." + name + ".pattern does not compile"); return null; }
        }
        if (q["enum"] !== undefined && !Array.isArray(q["enum"])) { errors.push(path + ".properties." + name + ".enum is not an array"); return null; }
        props[name] = q;
    }
    var req = (params && Array.isArray(params.required)) ? params.required.slice() : [];
    for (var r = 0; r < req.length; r++)
        if (!props.hasOwnProperty(req[r])) { errors.push(path + ".required names " + req[r] + " which parameters do not declare"); return null; }
    return { properties: props, required: req };
}

// A constrained parameter may sit embedded in code: a number, a boolean, an
// enum, or a string whose pattern is ANCHORED at both ends (`.*` constrains
// nothing: a sed `e` command can be put through one).
function constrained(p) {
    if (!p) return false;
    if (p.type === "integer" || p.type === "number" || p.type === "boolean") return true;
    if (p["enum"] !== undefined) return true;
    if (p.pattern !== undefined) {
        var s = String(p.pattern);
        return s.charAt(0) === "^" && s.charAt(s.length - 1) === "$" && s.length > 2;
    }
    return false;
}

// The positional references of a `sh -c` script (`$0`, `$1`, `$@`, `${1}`)
// must every one sit inside double quotes: unquoted, the argument is split
// into words and globbed, and as a command word (`bash -c '$0' "{s}"`) it
// is RUN. Returns "" or the offending reference.
function unquotedPositional(script) {
    var s = String(script);
    var inS = false, inD = false;
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        if (c === "\\" && !inS) { i++; continue; }
        if (c === "'" && !inD) { inS = !inS; continue; }
        if (c === "\"" && !inS) { inD = !inD; continue; }
        if (c === "$" && !inS && !inD) {
            var m = /^\$(\{?)([0-9@*])/.exec(s.substring(i));
            if (m) return "$" + m[1] + m[2];
        }
    }
    return "";
}

// The code rules (THE TEMPLATING LAW, 2) on one rendered argv template. Returns "" or the
// reason. `argv` is the full template (exec prefix included), `props` the
// declared properties, `shell` the entry's own flag, `kind` read|act.
// `offset` is the length of a family's exec prefix, so a reported index is
// the one the user sees in the file's own `argv`.
//
// The rules, each with the case that forces it:
//   - argv[0] a wrapper (`env sh -c`, `busybox sh`, `timeout 5 bash`): refused.
//   - a shell: the script is the element after `-c` (or `-lc`, `-xc`), found
//     by looking, not by counting -- `sh -x -c "{s}"` puts the script at
//     index 3, past a plain `< 3` rule. Placeholders only AFTER the
//     script; every `$0`/`$1`/`$@` in the script double-quoted (`bash -c '$0'
//     "{s}"` runs the value). `shell:true` (run_command) is one whole
//     placeholder that IS the script.
//   - an interpreter: placeholders only after `--`, AND a script file must
//     stand before the `--` -- for sed, awk, jq and perl the first word
//     after `--` is the program, so `sed -- "{s}"` executes `e touch pwned`.
//     `python3 -I llm_tools/calc.py -- {expression}` is the legal shape.
//   - a program whose next words are code in its own language (CODE_AFTER:
//     `hyprctl dispatch`): a whole free-string placeholder there needs a
//     constrained type like an embedded one.
//   - embedded placeholders need a constrained type; a string pattern
//     constrains only when anchored.
function checkArgvCode(argv, props, shell, kind, path, offset) {
    if (!Array.isArray(argv) || argv.length === 0) return path + " is empty";
    var off = offset || 0;
    var first = argv[0];
    if (typeof first !== "string") return path + "[0] is not a string";
    var prog = basename(first);
    if (WRAPPER_RE.test(prog))
        return path + "[0] is " + JSON.stringify(prog) + ", a wrapper; name the program itself (the runner adds its own timeout)";
    var isShell = SHELL_RE.test(prog);
    var isInterp = INTERP_RE.test(prog);
    // Flatten, keeping the file's own index for the message.
    var flat = [];
    for (var i = 0; i < argv.length; i++) {
        var el = argv[i];
        if (Array.isArray(el)) { for (var j = 0; j < el.length; j++) flat.push({ el: el[j], idx: i }); }
        else flat.push({ el: el, idx: i });
    }
    for (var f = 0; f < flat.length; f++)
        if (typeof flat[f].el !== "string") return path + "[" + Math.max(0, flat[f].idx - off) + "] is not a string";
    var locOf = function (k) { return path + "[" + Math.max(0, flat[k].idx - off) + "]"; };
    // The shell's script.
    var scriptAt = -1;
    if (isShell) {
        for (var s = 1; s < flat.length; s++) if (/^-[A-Za-z]*c$/.test(flat[s].el)) { scriptAt = s + 1; break; }
        if (scriptAt < 0 || scriptAt >= flat.length) return path + ": a shell entry needs -c <script>, with its arguments after it";
        if (!shell) {
            var up = unquotedPositional(flat[scriptAt].el);
            if (up) return locOf(scriptAt) + " uses " + up + " outside double quotes; write \"" + up + "\" so the argument is one word and never a command";
        }
    }
    // The interpreter's `--` and the script file before it.
    var dashAt = -1;
    var scriptFile = false;
    if (isInterp) {
        for (var d = 1; d < flat.length; d++) if (flat[d].el === "--") { dashAt = d; break; }
        for (var g = 1; g < (dashAt < 0 ? flat.length : dashAt); g++) {
            var w = flat[g].el;
            if (w.charAt(0) !== "-" && w.indexOf("/") >= 0 && placeholdersOf(w).length === 0) scriptFile = true;
        }
    }
    var codeWords = CODE_AFTER[prog] || null;
    var sawCode = false;
    var wholeCount = 0;
    for (var k = 0; k < flat.length; k++) {
        var text = flat[k].el;
        var phs = placeholdersOf(text);
        if (codeWords && phs.length === 0 && codeWords.indexOf(text) >= 0) sawCode = true;
        for (var q = 0; q < phs.length; q++) {
            var ph = phs[q];
            var loc = locOf(k);
            var reserved = RESERVED.indexOf(ph.name) >= 0;
            if (!props.hasOwnProperty(ph.name) && !reserved)
                return loc + " mentions {" + ph.name + "} but parameters declare " + (Object.keys(props).join(", ") || "nothing");
            if (isShell && shell) {
                if (k !== scriptAt || !ph.whole || ++wholeCount > 1)
                    return loc + ": a shell:true entry has exactly one placeholder, the whole -c script";
            } else if (isShell && k <= scriptAt) {
                return loc + " puts {" + ph.name + "} inside a shell script; only positional arguments after -c <script> may carry one";
            }
            if (isInterp && (dashAt < 0 || k < dashAt))
                return loc + " puts {" + ph.name + "} before -- in an interpreter's arguments (an expression is code)";
            if (isInterp && !scriptFile)
                return loc + " hands {" + ph.name + "} to " + prog + " with no script file before --, where the first word is the program (an expression is code)";
            if (reserved) continue;
            if (!ph.whole && !constrained(props[ph.name]))
                return loc + " embeds {" + ph.name + "} in text, which needs integer, number, boolean, enum or an anchored pattern";
            if (ph.whole && sawCode && !constrained(props[ph.name]))
                return loc + " hands {" + ph.name + "} to " + prog + " as code (after " + codeWords.join("/") + "), which needs integer, number, boolean, enum or an anchored pattern";
        }
    }
    if (kind === "read" && (isShell || shell)) return path + ": a read entry may not run a shell";
    return "";
}

// Which declared properties appear embedded (text around them) anywhere in
// the template: their values get the character rule at call time.
function embeddedOf(argv) {
    var out = [];
    var each = function (el) {
        var phs = placeholdersOf(el);
        for (var i = 0; i < phs.length; i++)
            if (!phs[i].whole && out.indexOf(phs[i].name) < 0) out.push(phs[i].name);
    };
    for (var i = 0; i < argv.length; i++) {
        if (Array.isArray(argv[i])) for (var j = 0; j < argv[i].length; j++) each(argv[i][j]);
        else each(argv[i]);
    }
    return out;
}

function templatePlaceholdersDeclared(tpl, props, path) {
    var phs = placeholdersOf(tpl || "");
    for (var i = 0; i < phs.length; i++)
        if (!props.hasOwnProperty(phs[i].name) && RESERVED.indexOf(phs[i].name) < 0)
            return path + " mentions {" + phs[i].name + "} which parameters do not declare";
    return "";
}

function checkNumbers(e, path) {
    if (e.timeoutMs !== undefined && e.timeoutMs !== 0
            && (typeof e.timeoutMs !== "number" || e.timeoutMs < 500 || e.timeoutMs > 600000))
        return path + ".timeoutMs must be 500…600000 (or 0 for the popup's default)";
    if (e.outputCap !== undefined && e.outputCap !== 0
            && (typeof e.outputCap !== "number" || e.outputCap < 256 || e.outputCap > 8 * 1024 * 1024))
        return path + ".outputCap must be 256…8 MiB (or 0 for the popup's default)";
    return "";
}

// One action of a family, compiled against the family's exec prefix and
// readForbidden list. Returns { action } or { error }.
function compileAction(key, raw, fam, file) {
    var path = file + ": actions." + key;
    if (!isObject(raw)) return { error: path + " is not an object" };
    if (!Array.isArray(raw.argv) || raw.argv.length === 0) return { error: path + ".argv must be a non-empty array" };
    var kind = raw.kind || fam.kind || "read";
    if (kind !== "read" && kind !== "act") return { error: path + ".kind must be read or act" };
    var errors = [];
    var schema = compileSchema({ properties: raw.parameters || {}, required: raw.required || [] }, path, errors);
    if (!schema) return { error: errors[0] };
    var argv = (fam.exec || []).concat(raw.argv);
    if (kind === "read" && Array.isArray(fam.readForbidden)) {
        for (var i = 0; i < raw.argv.length; i++)
            if (typeof raw.argv[i] === "string" && fam.readForbidden.indexOf(raw.argv[i]) >= 0)
                return { error: path + ".argv[" + i + "] is " + JSON.stringify(raw.argv[i]) + ", which may never be kind read" };
    }
    var ce = checkArgvCode(argv, schema.properties, false, kind, path + ".argv", (fam.exec || []).length);
    if (ce) return { error: ce };
    var allow = raw.allow || (kind === "act" ? "action" : "tool");
    if (ALLOW_WORDS.indexOf(allow) < 0) return { error: path + ".allow " + JSON.stringify(allow) + " is not a known word" };
    var ne = checkNumbers(raw, path);
    if (ne) return { error: ne };
    var te = templatePlaceholdersDeclared(raw.summary, schema.properties, path + ".summary")
          || templatePlaceholdersDeclared(raw.progress, schema.properties, path + ".progress");
    if (te) return { error: te };
    if (typeof raw.description !== "string" || raw.description.length === 0)
        return { error: path + ".description is empty" };
    return { action: {
        name: key, argv: argv, kind: kind, allow: allow, description: raw.description,
        parameters: schema.properties, required: schema.required, embedded: embeddedOf(argv),
        grantable: raw.grantable !== false,
        timeoutMs: raw.timeoutMs || fam.timeoutMs || 0,
        outputCap: raw.outputCap || fam.outputCap || 0,
        summary: raw.summary || (key.replace(/_/g, " ")),
        progress: raw.progress || (key.replace(/_/g, " ")),
        result: raw.result || fam.result || "text",
        detail: raw.detail || "argv"
    } };
}

// compileEntry(raw, file, ctx) -> { entry: compiled | null, errors: [{file, name, action, reason}] }
// A bad entry is dropped whole; a bad ACTION of a family is dropped alone,
// the rest of the family loads, and every fault names its exact path.
function compileEntry(raw, file) {
    var errors = [];
    var fail = function (reason, action) {
        errors.push({ file: file, name: (raw && raw.name) ? String(raw.name) : "", action: action || "", reason: reason });
        return { entry: null, errors: errors };
    };
    if (!isObject(raw)) return fail(file + ": entry is not an object");
    var name = raw.name;
    if (typeof name !== "string" || !NAME_RE.test(name)) return fail(file + ": name " + JSON.stringify(name) + " does not match ^[a-z][a-z0-9_]{1,31}$");
    var path = file + ": " + name;
    if (typeof raw.description !== "string" || raw.description.length === 0 || raw.description.length > 600)
        return fail(path + ".description must be non-empty and at most 600 characters");
    var kind = raw.kind;
    if (kind !== "read" && kind !== "act") return fail(path + ".kind must be read or act");
    var shell = raw.shell === true;
    var allow = raw.allow || (kind === "act" ? "tool" : "tool");
    if (ALLOW_WORDS.indexOf(allow) < 0) return fail(path + ".allow " + JSON.stringify(allow) + " is not a known word");
    var detail = raw.detail || "argv";
    if (shell) {
        if (kind !== "act") return fail(path + ": shell:true is legal only on kind act");
        if (detail !== "{command}") return fail(path + ": shell:true requires detail \"{command}\"");
        if (allow !== "verb" && allow !== "never") return fail(path + ": shell:true requires allow verb or never");
    }
    var result = raw.result || "text";
    if (result !== "text" && result !== "image") return fail(path + ".result must be text or image");
    var ne = checkNumbers(raw, path);
    if (ne) return fail(ne);
    var e = {
        name: name, description: raw.description, kind: kind, glyph: raw.glyph || "",
        // THE HUMAN NAME. `description` is written for the model and is a
        // paragraph; `name` is the wire's word and reads like an identifier
        // ("system_facts", "hyprctl"). A person looking at a list of tools
        // needs neither, so every entry carries a short imperative phrase --
        // in the DATA, so a tool the user adds names itself, and derived from
        // the wire name when a file omits one.
        label: String(raw.label || name.replace(/_/g, " ")),
        // WHAT THE MODEL SHOULD DO WHEN THIS CALL TIMES OUT, in the tool's
        // own voice, appended to the timedOut trailer by composeResult.
        // It lives in the DATA because only the tool file knows whether the
        // call has a way to narrow: "pass `path`, or a `glob`" is advice
        // search_files can give and the clipboard cannot. Empty means the
        // trailer says what happened and nothing more; measured: a model
        // given "partial output above" and nothing else spends its next
        // round on run_command before re-searching correctly.
        retryHint: String(raw.retryHint || "").substring(0, 200),
        enabled: raw.enabled !== false, shell: shell, allow: allow, detail: detail,
        result: result, timeoutMs: raw.timeoutMs || 0, outputCap: raw.outputCap || 0,
        cwd: raw.cwd || "", stdin: raw.stdin || "", file: file,
        summary: raw.summary || name.replace(/_/g, " "),
        progress: raw.progress || name.replace(/_/g, " "),
        preflight: Array.isArray(raw.preflight) ? raw.preflight : null,
        actions: null, argv: null, parameters: {}, required: [], embedded: [], wire: null
    };
    if (isObject(raw.actions)) {
        // A family: the entry's own parameters are ignored, the wire function
        // is the union of its actions'.
        var fam = { exec: Array.isArray(raw.exec) ? raw.exec : [], readForbidden: raw.readForbidden,
                    kind: kind, timeoutMs: e.timeoutMs, outputCap: e.outputCap, result: result };
        var actions = {};
        var count = 0;
        for (var key in raw.actions) {
            if (!/^[a-z][a-z0-9_]{0,31}$/.test(key)) {
                errors.push({ file: file, name: name, action: key, reason: file + ": actions." + key + " is not a valid action name" });
                continue;
            }
            var r = compileAction(key, raw.actions[key], fam, file);
            if (r.error) { errors.push({ file: file, name: name, action: key, reason: r.error }); continue; }
            actions[key] = r.action;
            count++;
        }
        if (count === 0) return fail(path + ": every action was rejected", "");
        e.actions = actions;
        // Union of parameters, plus `action`.
        var union = { action: { type: "string", "enum": Object.keys(actions), description: "which action to run" } };
        var lines = [];
        for (var ak in actions) {
            var a = actions[ak];
            for (var pn in a.parameters) if (!union.hasOwnProperty(pn)) union[pn] = a.parameters[pn];
            var sig = [];
            for (var pn2 in a.parameters) {
                var pp = a.parameters[pn2];
                var t = pp.type;
                if (pp.minimum !== undefined && pp.maximum !== undefined) t += " " + pp.minimum + "–" + pp.maximum;
                else if (pp["enum"]) t = pp["enum"].join("|");
                sig.push(pn2 + ": " + t + (a.required.indexOf(pn2) >= 0 ? "" : "?"));
            }
            lines.push(ak + "(" + sig.join(", ") + ") — " + a.description + (a.kind === "act" ? " [asks]" : ""));
        }
        e.parameters = union;
        e.required = ["action"];
        e.wire = { type: "function", "function": {
            name: name,
            description: raw.description + "\nActions:\n" + lines.join("\n"),
            parameters: { type: "object", properties: union, required: ["action"] } } };
        return { entry: e, errors: errors };
    }
    if (!Array.isArray(raw.argv) || raw.argv.length === 0) return fail(path + ".argv must be a non-empty array");
    var serrs = [];
    var schema = compileSchema(raw.parameters, path + ".parameters", serrs);
    if (!schema) return fail(serrs[0]);
    if (!isObject(raw.parameters) || !isObject(raw.parameters.properties))
        return fail(path + ".parameters must be an object schema with properties");
    var ce = checkArgvCode(raw.argv, schema.properties, shell, kind, path + ".argv");
    if (ce) return fail(ce);
    if (e.stdin) {
        var sp = placeholdersOf(e.stdin);
        if (sp.length !== 1 || !sp[0].whole) return fail(path + ".stdin must be exactly one whole placeholder");
        if (!schema.properties.hasOwnProperty(sp[0].name)) return fail(path + ".stdin mentions {" + sp[0].name + "} which parameters do not declare");
    }
    if (e.preflight) {
        var pe = checkArgvCode(e.preflight, schema.properties, false, "read", path + ".preflight");
        if (pe) return fail(pe);
    }
    var te = templatePlaceholdersDeclared(e.summary, schema.properties, path + ".summary")
          || templatePlaceholdersDeclared(e.progress, schema.properties, path + ".progress");
    if (te) return fail(te);
    e.argv = raw.argv;
    e.parameters = schema.properties;
    e.required = schema.required;
    e.embedded = embeddedOf(raw.argv);
    e.wire = { type: "function", "function": {
        name: name, description: raw.description,
        parameters: { type: "object", properties: schema.properties, required: schema.required } } };
    return { entry: e, errors: errors };
}

// compileFile(text, file) -> { entries: [], errors: [] }
// A file is either { format, entries: [...] }, a bare array, or one family
// object (hyprctl.json). An unreadable file is one error, nothing loaded.
function compileFile(text, file) {
    var errors = [];
    var d;
    try { d = JSON.parse(text); } catch (e) {
        return { entries: [], errors: [{ file: file, name: "", action: "", reason: file + " is not valid JSON: " + e }] };
    }
    var list;
    if (Array.isArray(d)) list = d;
    else if (isObject(d) && Array.isArray(d.entries)) list = d.entries;
    else if (isObject(d) && d.name) list = [d];
    else return { entries: [], errors: [{ file: file, name: "", action: "", reason: file + " holds neither an entries array nor one entry" }] };
    var entries = [];
    for (var i = 0; i < list.length; i++) {
        var r = compileEntry(list[i], file);
        errors = errors.concat(r.errors);
        if (r.entry) entries.push(r.entry);
    }
    return { entries: entries, errors: errors };
}

// The action (or the entry itself) a call resolves to, plus the spec the
// validator uses. null when the action is unknown.
function resolveAction(entry, args) {
    if (!entry.actions) {
        return { key: "", spec: { properties: entry.parameters, required: entry.required, embedded: entry.embedded },
                 argv: entry.argv, kind: entry.kind, allow: entry.allow, timeoutMs: entry.timeoutMs,
                 outputCap: entry.outputCap, summary: entry.summary, progress: entry.progress,
                 result: entry.result, detail: entry.detail, grantable: true };
    }
    var key = (args && typeof args.action === "string") ? args.action : "";
    var a = entry.actions[key];
    if (!a) return null;
    return { key: key, spec: { properties: a.parameters, required: a.required, embedded: a.embedded },
             argv: a.argv, kind: a.kind, allow: a.allow, timeoutMs: a.timeoutMs, outputCap: a.outputCap,
             summary: a.summary, progress: a.progress, result: a.result, detail: a.detail,
             grantable: a.grantable };
}

// The grant key(s) of a non-shell call, by the entry's allow word.
//   -> { keys: [..] | null, label, reason, unkeyable }
function keysFor(allow, entry, action, norm, argv, facts, policy, home) {
    var f = facts || {};
    var out = { keys: null, label: "", reason: "", unkeyable: false };
    switch (allow) {
    case "tool":
        out.keys = [entry.name];
        out.label = entry.name;
        return out;
    case "action":
        out.keys = [action || entry.name];
        out.label = entry.name + " " + (action || "");
        return out;
    case "exact":
        out.keys = [argv.join("\u0001")];
        out.label = argv.join(" ");
        return out;
    case "dir": {
        var p = f.resolvedPath || (norm && norm.path ? expandTilde(String(norm.path), home) : "");
        if (!p || p.charAt(0) !== "/") { out.unkeyable = true; out.reason = "no rule can describe this path"; return out; }
        var dir = parentDir(p);
        var never = policy.neverGrantWrite || [];
        for (var i = 0; i < never.length; i++) {
            var nd = normalizePath(expandTilde(never[i], home));
            if (dir === nd || dir.indexOf(nd + "/") === 0) {
                out.unkeyable = true; out.reason = "writes under " + never[i] + " are never remembered"; return out;
            }
        }
        var roots = policy.grantWriteRoots || ["~"];
        var inRoot = false;
        for (var j = 0; j < roots.length; j++) {
            var rr = normalizePath(expandTilde(roots[j], home));
            if (dir === rr || dir.indexOf(rr + "/") === 0) inRoot = true;
        }
        if (!inRoot) { out.unkeyable = true; out.reason = "writes outside " + roots.join(", ") + " are never remembered"; return out; }
        out.keys = [dir];
        var shown = (home && dir.indexOf(home) === 0) ? "~" + dir.substring(home.length) : dir;
        out.label = "writes in " + shown + "/";
        return out;
    }
    case "host": {
        var url = (norm && norm.url) ? String(norm.url) : "";
        var host = urlHost(url);
        if (host === null) { out.unkeyable = true; out.reason = "no host in the URL"; return out; }
        if (hostNeverGranted(host, policy.neverGrantHosts || [])) {
            out.unkeyable = true; out.reason = host + " is a local address — never remembered"; return out;
        }
        if (!plainHost(host)) {
            out.unkeyable = true; out.reason = host + " is not a plain host name — never remembered"; return out;
        }
        out.keys = [host];
        out.label = "fetches from " + host;
        return out;
    }
    case "never":
    default:
        out.unkeyable = true;
        out.reason = "asks every time";
        return out;
    }
}

// The host of a URL the way urllib reads it: the
// authority runs to the first `/`, `?` or `#`; userinfo ends at the LAST `@`
// inside it; a port follows the host's `:`; a bracketed IPv6 literal keeps
// its brackets. A regex that lets `?` and `#` into the userinfo would key
// `http://127.0.0.1:11434?@example.com` as example.com and fetch
// the local server. null when there is no host at all.
function urlHost(url) {
    var m = /^https?:\/\/([^\/?#]*)/i.exec(String(url || ""));
    if (!m) return null;
    var auth = m[1];
    var at = auth.lastIndexOf("@");
    if (at >= 0) auth = auth.substring(at + 1);
    var host;
    if (auth.charAt(0) === "[") {
        var e = auth.indexOf("]");
        if (e < 0) return null;
        host = auth.substring(0, e + 1);
    } else {
        var c = auth.indexOf(":");
        host = c >= 0 ? auth.substring(0, c) : auth;
    }
    host = host.toLowerCase();
    return host.length > 0 ? host : null;
}

// A host a rule may be written for: a dotted DNS name (two labels or more,
// letters and digits and hyphens) or a canonical dotted-quad IPv4. Every
// other spelling -- `127.1`, `0x7f000001`, `[::ffff:127.0.0.1]`, a single
// label -- resolves somewhere the never-list cannot check, so it asks every
// time. Names under .local/.localhost/.internal/.lan/.home.arpa are local
// by definition.
function plainHost(host) {
    var h = String(host);
    // Digits and dots only: an IPv4 spelling, plain or not (`127.1`).
    if (/^[\d.]+$/.test(h)) return canonicalIpv4(h);
    if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(h)) return false;
    if (/\.(local|localhost|internal|lan|home\.arpa)$/.test(h)) return false;
    return true;
}

function canonicalIpv4(s) {
    var m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(s);
    if (!m) return false;
    for (var i = 1; i <= 4; i++) {
        if (m[i].length > 1 && m[i].charAt(0) === "0") return false;
        if (parseInt(m[i], 10) > 255) return false;
    }
    return true;
}

function ipv4ToInt(s) {
    var m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(s);
    if (!m) return -1;
    var n = 0;
    for (var i = 1; i <= 4; i++) {
        var o = parseInt(m[i], 10);
        if (o > 255) return -1;
        n = n * 256 + o;
    }
    return n;
}

function hostNeverGranted(host, list) {
    var h = host.replace(/^\[|\]$/g, "");
    var ip4 = ipv4ToInt(h);
    if (h === "localhost" || /\.localhost$/.test(h)) return true;
    for (var i = 0; i < list.length; i++) {
        var rule = String(list[i]).toLowerCase();
        if (rule === h) return true;
        var cidr = /^(\d+\.\d+\.\d+\.\d+)\/(\d+)$/.exec(rule);
        if (cidr && ip4 >= 0) {
            var base = ipv4ToInt(cidr[1]);
            var bits = parseInt(cidr[2], 10);
            var mask = bits === 0 ? 0 : (0xFFFFFFFF << (32 - bits)) >>> 0;
            if (((ip4 & mask) >>> 0) === ((base & mask) >>> 0)) return true;
            continue;
        }
        // IPv6 prefixes: a textual prefix match is all that is needed for the
        // shipped list (::1, fe80::, fc00::/7 -> fc/fd).
        if (rule.indexOf(":") >= 0 && h.indexOf(":") >= 0) {
            var pfx = rule.split("/")[0].replace(/:+$/, "");
            if (rule === "fc00::/7" && /^f[cd]/.test(h)) return true;
            if (pfx.length > 0 && h.indexOf(pfx) === 0) return true;
        }
    }
    return false;
}

// The rendered argv as the policy lists see it: joined by spaces, MINUS a
// leading interpreter that runs one of the registry's OWN helpers
// (`python3 -I [-S] <dir>/x.py --`). The alwaysAsk list names python3
// because a model-composed `python3 -c` is code; a helper the registry
// author shipped beside the entry is not the model's doing, and its
// arguments are what the policy should read. An interpreter pointed at any
// other script stays on the line and asks.
function policyLineOf(argv, dir) {
    var a = argv.slice();
    if (a.length >= 2 && INTERP_RE.test(basename(a[0])) && dir) {
        var i = 1;
        while (i < a.length && /^-[A-Za-z]+$/.test(a[i])) i++;
        if (i < a.length && a[i].indexOf(dir + "/") === 0 && a[i].indexOf("/", dir.length + 1) < 0) {
            i++;
            if (i < a.length && a[i] === "--") i++;
            a = a.slice(i);
        }
    }
    return a.join(" ");
}

// The text the confirmation shows VERBATIM for an entry.
//   detail "{command}" -> the command string as sent
//   detail "file"      -> resolved path, blank line, the content
//   detail "argv"      -> the rendered argv, one element per line, and --
//                         when the entry feeds the child's stdin -- a blank
//                         line and the stdin text in full. Stdin is bytes
//                         that run; a confirmation that showed `wl-copy`
//                         alone would show nothing of what was written.
function detailFor(detailMode, norm, argv, facts, stdin) {
    if (detailMode === "{command}") return { text: String(norm.command || ""), lang: "sh" };
    if (detailMode === "file") {
        var p = (facts && facts.resolvedPath) ? facts.resolvedPath
              : (facts && facts.lexicalPath) ? facts.lexicalPath : String(norm.path || "");
        return { text: p + "\n\n" + String(norm.content || ""), lang: "" };
    }
    var text = argv.join("\n");
    if (stdin !== null && stdin !== undefined) text += "\n\n" + String(stdin);
    return { text: text, lang: "" };
}

// The stored `argsText`: the command string, the file, or the argv --
// on one line when it fits, one element per line when it does not -- and
// the stdin text after a blank line when there is one.
function argsTextFor(detailMode, norm, argv, facts, stdin) {
    if (detailMode === "{command}") return String(norm.command || "");
    if (detailMode === "file") return detailFor(detailMode, norm, argv, facts, stdin).text;
    var one = argv.join(" ");
    var text = one.length <= 80 ? one : argv.join("\n");
    if (stdin !== null && stdin !== undefined) text += "\n\n" + String(stdin);
    return text;
}

// The preflight's stdout (write_file's `write.py --preflight`): line 1 the
// resolved absolute path, line 2 `size N` or `new`. The older `stat -c %s`
// shape (a bare number) still reads as a size with no path.
//   -> { resolvedPath: "" | "/abs/path", size: -1 | N, isNew }
function parsePreflight(out, code) {
    var lines = String(out || "").split("\n");
    var r = { resolvedPath: "", size: -1, isNew: true };
    if (lines.length > 0 && lines[0].charAt(0) === "/") {
        r.resolvedPath = lines[0];
        var m = /^size (\d+)/.exec(lines[1] || "");
        if (m) { r.size = parseInt(m[1], 10); r.isNew = false; }
        return r;
    }
    var n = /^\s*(\d+)/.exec(lines[0] || "");
    if (code === 0 && n) { r.size = parseInt(n[1], 10); r.isNew = false; }
    return r;
}

// ---- what goes back to the model ------------------------------------------

// composeResult(name, raw) -> { result, trailer }
//   raw: { status, exitCode, ms, bytes, lines, head, tail, cut, keptHead,
//          keptTail, stderr, binary, ignored, timeoutS, floodBytes, imageNote,
//          retryHint }
// ONE text for the reader and the model: the first line names the tool
// (granite reads only `content`), then the output, then the trailer as the
// last line. Every cut and every kill is stated with its exact figures.
function composeResult(name, raw) {
    var r = raw || {};
    var status = r.status || "done";
    var secs = fmtSeconds(r.ms);
    var body;
    if (r.binary) {
        body = "(binary output, " + groupDigits(r.bytes || 0) + " bytes, not shown)";
    } else if (r.imageNote) {
        body = r.imageNote;
    } else {
        body = String(r.head || "");
        if (r.cut) {
            var omitted = Math.max(0, (r.bytes || 0) - (r.keptHead || 0) - (r.keptTail || 0));
            body += "\n[… " + groupDigits(omitted) + " bytes omitted …]\n" + String(r.tail || "");
        }
        // The output's own final newline is not content: the trailer takes
        // the next line, never a blank one.
        body = body.replace(/\n$/, "");
        if (body.length === 0) body = "(no output)";
    }
    var err = String(r.stderr || "");
    if (err.length > 0 && !r.imageNote) body += "\n--- stderr ---\n" + err.replace(/\n$/, "");
    var kept = "first " + groupDigits(r.keptHead || 0) + " and last " + groupDigits(r.keptTail || 0) + " bytes kept";
    var trailer;
    if (status === "timedOut") {
        // A TIMEOUT IS THE ONE STATUS THAT HAS A NEXT MOVE, so it is the one
        // that says what it is. The entry's own `retryHint` is the tool
        // telling the model how to narrow it -- the last line of the last
        // thing the model reads, and a fact about the call that just failed
        // rather than a rule bolted onto toolVoice.
        var hint = String(r.retryHint || "");
        trailer = "(timed out after " + (r.timeoutS || 0) + " s; partial output above"
                + (hint.length > 0 ? " -- " + hint : "") + ")";
    } else if (status === "cancelled") {
        trailer = "(cancelled by the user after " + secs + "; partial output above)";
    } else if (status === "flood") {
        trailer = "(killed after " + groupDigits(r.bytes || 0) + " bytes of output, " + secs + "; " + kept + ")";
    } else if (r.cut) {
        trailer = "(" + groupDigits(r.bytes || 0) + " bytes produced, " + secs + ", exit " + (r.exitCode || 0)
                + "; output cut: " + kept + ")";
    } else {
        trailer = "(" + groupDigits(r.lines || 0) + " line" + ((r.lines || 0) === 1 ? "" : "s") + ", " + secs
                + ", exit " + (r.exitCode || 0) + ")";
    }
    var ig = r.ignored || [];
    if (ig.length > 0) trailer += " (ignored argument" + (ig.length > 1 ? "s" : "") + ": " + ig.join(", ") + ")";
    // Processes the call left behind -- a backgrounded child, a job-control
    // escape -- were killed with the call's own cgroup; the trailer says so
    // rather than reporting a job that "ended" with something still running.
    var sv = r.survivors || 0;
    if (sv > 0) trailer += " (" + sv + " process" + (sv === 1 ? " it left behind was" : "es it left behind were") + " killed)";
    return { result: name + " result:\n" + body + "\n" + trailer, trailer: trailer };
}

// The sentences of the trailer, first word the tool's name.
function sentenceFor(name, status, extra) {
    switch (status) {
    case "denied":   return name + ": the user did not allow this call. Do not retry it; ask the user or answer without it.";
    case "refused":  return name + ": Refused by policy.";
    case "invalid":  return name + ": invalid call: " + (extra || "");
    case "repeated": return name + ": Same call as before; the result has not changed. It began: " + String(extra || "").substring(0, 240);
    case "cancelled": return name + ": cancelled by the user before it ran.";
    default: return name + ": " + (extra || "");
    }
}

// MAY THIS COMMAND ASK FOR A PASSWORD? The runner gives such a
// call `sudoAuthWindowMs` on top of its own limit, because sudo's face scan
// and a typed password happen INSIDE the call's clock and a 60 s limit would
// kill the dialog under the user's fingers. Deliberately a word test over
// the whole text and not a parse: `bash -c "sudo x"`, `$(sudo x)`, `env sudo
// x` and `/usr/bin/sudo x` all count, and a false positive (`grep sudo
// /etc/group`) costs nothing but a longer limit, where a false negative
// costs the user their password half-typed.
var ELEVATE_RE = /(^|[^A-Za-z0-9_.-])(sudo|sudoedit|doas|pkexec)(?=$|[\s"')`;|&])/;
function mayElevate(command) {
    return ELEVATE_RE.test(String(command || ""));
}

// A control character made visible for the confirmation: ESC -> ␛,
// CR -> ^M, other C0 codes -> ^X. Newlines and tabs stay.
function visibleControls(s) {
    return String(s || "").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, function (c) {
        var code = c.charCodeAt(0);
        if (code === 0x1b) return "␛";
        if (code === 0x7f) return "^?";
        return "^" + String.fromCharCode(code + 64);
    }).replace(/\r/g, "^M");
}
