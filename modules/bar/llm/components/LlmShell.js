.pragma library

// =============================================================================
// LlmShell.js -- what a shell command line IS, decided before anything runs.
//
// The pure half of `run_command`'s policy. A model chains commands
// (`find ~ ... | head; echo x; find ... | head`), and the whole line as a
// single unit is one the grants cannot describe, so it would always ask. This
// file reads the line the way bash does, finds EVERY simple command in it,
// and judges each one:
//
//   auto     a command that cannot write, delete, send or execute anything
//            (the READERS table below, each entry with the reason it is safe)
//   granted  a command the user has already said "always allow" to
//   ask      everything else, and the line asks as a whole
//
// A line runs without asking only when every simple command in it is auto or
// granted AND every redirection is harmless. The line that asks says WHICH
// part needs the answer (`parts`), so the panel can show it.
//
// THE PARSER MAY REFUSE, NEVER GUESS. It understands a subset of bash --
// quoting, escapes, `| |& && || ; newline`, redirections, `$(...)`, backticks,
// `<(...)`, `( ... )`, `{ ...; }`, `for x in ...; do ...; done`, assignments,
// `$name` / `${name}` -- and anything outside it (heredocs, here-strings,
// arithmetic, `${x:-y}`, `$'..'`, `if`/`while`/`case`, functions, `&`, `>(..)`,
// a trailing backslash, an unterminated quote) is a PARSE ERROR, and a line
// that does not parse is asked about, never run free. Where the parser reads a
// construct differently from bash the error must be on the side of asking:
// an unquoted glob that opens a word (`*.lua`) or a `$var` the line did not
// pin is "dynamic" -- its value is not known here -- and a command whose
// safety depends on its arguments (find, sed, git, sort ...) refuses a
// dynamic argument.
//
// WHAT A GRANT CAN AND CANNOT DO. A grant is keyed `program verb`
// (`pacman -Q`, `git commit`) and matches per simple command. A
// program that appears in READERS is judged by its reader test, and a grant
// can never widen a command PAST that test: `Always allow sed -n` covers
// nothing the sed test refuses. A grant keeps its key and its meaning for every program
// that is not in the table.
// =============================================================================

var MAX_SRC = 20000;
var MAX_CMDS = 120;
var MAX_DEPTH = 6;

// ---- small helpers ---------------------------------------------------------

function basename(p) {
    var s = String(p || "");
    var i = s.lastIndexOf("/");
    return i >= 0 ? s.substring(i + 1) : s;
}

// Test `text` against a list of regex sources. Returns { index, match } of the
// first hit or null. A pattern that does not compile is skipped.
function matchPolicy(text, patterns) {
    var list = patterns || [];
    for (var i = 0; i < list.length; i++) {
        var re;
        try { re = new RegExp(list[i]); } catch (e) { continue; }
        var m = re.exec(String(text));
        if (m) return { index: i, match: m[0], pattern: list[i] };
    }
    return null;
}

// The words of a policy hit, for the reason line: "sudo -- always asks".
function hitWords(m) {
    return String(m || "").replace(/^[;&|(\s]+/, "").replace(/\s+/g, " ").trim();
}

function has(obj, k) { return Object.prototype.hasOwnProperty.call(obj, k); }

// ---- the parser ------------------------------------------------------------

// Variables whose value is a plain path or name the user's own session set:
// harmless in any argument, so they do not make a word "dynamic".
var SAFE_VARS = { HOME: 1, PWD: 1, OLDPWD: 1, USER: 1, LOGNAME: 1 };
var ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
var RESERVED_RE = /^(if|then|elif|else|fi|while|until|case|esac|select|function|coproc|\[\[|\]\]|do|done|in)$/;

function ParseError(msg) { this.parseError = msg; }

// parse(src) -> { ok, error, cmds: [ { words, assigns, redirs, text } ] }
//   word:  { text, lit, dyn, quoted, glob, brace, unsure, assign }
//          text  the value with quoting removed (an expansion stays as written)
//          lit   no expansion of any kind        dyn   value unknown here
//          unsure  dyn, or a glob / brace that may open the word (`*.x`)
//   redir: { fd, op, target: word }
function parse(src) {
    var s = String(src === undefined || src === null ? "" : src);
    if (s.length > MAX_SRC) return { ok: false, error: "the command is too long to analyse", cmds: [] };
    var state = { cmds: [] };
    try {
        parseScript(s, 0, state);
    } catch (e) {
        if (e && e.parseError !== undefined) return { ok: false, error: e.parseError, cmds: [] };
        throw e;
    }
    return { ok: true, error: "", cmds: state.cmds };
}

function parseScript(src, depth, state) {
    if (depth > MAX_DEPTH) throw new ParseError("nested too deeply");
    var s = src;
    var n = s.length;
    var i = 0;

    function fail(msg) { throw new ParseError(msg); }
    function isBlank(c) { return c === " " || c === "\t"; }
    function isMeta(c) {
        return c === " " || c === "\t" || c === "\n" || c === "|" || c === "&" || c === ";"
            || c === "(" || c === ")" || c === "<" || c === ">";
    }
    function isDigit(c) { return c >= "0" && c <= "9" && c.length === 1; }

    // Blanks, line continuations and comments; newlines too when asked.
    function skipWs(nl) {
        for (;;) {
            var c = s.charAt(i);
            if (isBlank(c)) i++;
            else if (c === "\\" && s.charAt(i + 1) === "\n") i += 2;
            else if (c === "#") { while (i < n && s.charAt(i) !== "\n") i++; }
            else if (nl && c === "\n") i++;
            else break;
        }
    }

    // A reserved word at the cursor, as a whole word.
    function atKeyword(k) {
        if (s.substr(i, k.length) !== k) return false;
        var c = s.charAt(i + k.length);
        return c === "" || isMeta(c);
    }

    function expansion(w, inDq) {
        // The cursor is on `$`.
        var rest = s.substr(i, 200);
        var c1 = s.charAt(i + 1);
        if (c1 === "(") {
            if (s.charAt(i + 2) === "(") fail("arithmetic expansion");
            var from = i;
            i += 2;
            parseSeq(")");
            if (s.charAt(i) !== ")") fail("unterminated $(");
            i++;
            w.text += s.substring(from, i); w.dyn = true; w.lit = false;
            return;
        }
        if (c1 === "{") {
            var mb = /^\$\{([A-Za-z_][A-Za-z0-9_]*)\}/.exec(rest);
            if (!mb) fail("parameter expansion");
            i += mb[0].length;
            w.text += mb[0]; w.lit = false;
            if (!has(SAFE_VARS, mb[1])) w.dyn = true;
            return;
        }
        var mn = /^\$([A-Za-z_][A-Za-z0-9_]*)/.exec(rest);
        if (mn) {
            i += mn[0].length;
            w.text += mn[0]; w.lit = false;
            if (!has(SAFE_VARS, mn[1])) w.dyn = true;
            return;
        }
        if ("?#@*!$-0123456789".indexOf(c1) >= 0 && c1 !== "") {
            w.text += "$" + c1; i += 2; w.dyn = true; w.lit = false;
            return;
        }
        if (!inDq && (c1 === "'" || c1 === "\"")) fail("$'...' quoting");
        w.text += "$"; i++;
    }

    function backtick(w) {
        // The cursor is on the opening backtick.
        var j = i + 1;
        while (j < n && s.charAt(j) !== "`") {
            if (s.charAt(j) === "\\") j++;
            j++;
        }
        if (j >= n) fail("unterminated backtick");
        var inner = s.substring(i + 1, j).replace(/\\([`\\$])/g, "$1");
        parseScript(inner, depth + 1, state);
        w.text += s.substring(i, j + 1); w.dyn = true; w.lit = false;
        i = j + 1;
    }

    // One shell word, or null at a metacharacter.
    function scanWord() {
        var start = i;
        var w = { text: "", lit: true, dyn: false, quoted: false, glob: false, brace: false, unsure: false, assign: false };
        if (s.charAt(i) === "<" && s.charAt(i + 1) === "(") {
            var from = i;
            i += 2;
            parseSeq(")");
            if (s.charAt(i) !== ")") fail("unterminated <(");
            i++;
            w.text = s.substring(from, i); w.dyn = true; w.lit = false;
            // A process substitution may continue as a word (`<(x)y`): rare, refuse.
            if (i < n && !isMeta(s.charAt(i))) fail("text after <(...)");
            w.unsure = true;
            return w;
        }
        while (i < n) {
            var c = s.charAt(i);
            if (isMeta(c)) break;
            if (c === "'") {
                var j = s.indexOf("'", i + 1);
                if (j < 0) fail("unterminated single quote");
                w.text += s.substring(i + 1, j); w.quoted = true;
                i = j + 1;
            } else if (c === "\"") {
                i++;
                var closed = false;
                w.quoted = true;
                while (i < n) {
                    var d = s.charAt(i);
                    if (d === "\"") { closed = true; i++; break; }
                    if (d === "\\") {
                        var e = s.charAt(i + 1);
                        if (e === "\n") { i += 2; continue; }
                        if (e === "$" || e === "`" || e === "\"" || e === "\\") { w.text += e; i += 2; continue; }
                        w.text += "\\"; i++; continue;
                    }
                    if (d === "$") { expansion(w, true); continue; }
                    if (d === "`") { backtick(w); continue; }
                    w.text += d; i++;
                }
                if (!closed) fail("unterminated double quote");
            } else if (c === "\\") {
                if (i + 1 >= n) fail("trailing backslash");
                if (s.charAt(i + 1) === "\n") { i += 2; continue; }
                w.text += s.charAt(i + 1); w.quoted = true;
                i += 2;
            } else if (c === "$") {
                expansion(w, false);
            } else if (c === "`") {
                backtick(w);
            } else {
                if (c === "*" || c === "?" || c === "[") { w.glob = true; w.lit = false; }
                else if (c === "{") { w.brace = true; w.lit = false; }
                w.text += c; i++;
            }
        }
        w.assign = ASSIGN_RE.test(s.substring(start, i));
        var first = w.text.charAt(0);
        w.unsure = w.dyn || ((w.glob || w.brace) && (first === "*" || first === "?" || first === "[" || first === "{" || first === "-"));
        return w;
    }

    // ---- redirections ----
    // At the cursor: is this the start of a redirection? Returns its length
    // of fd prefix or -1.
    function redirAt() {
        var j = i;
        while (isDigit(s.charAt(j))) j++;
        var c = s.charAt(j);
        if (j > i && (c === "<" || c === ">")) return j - i;
        if (j > i) return -1;
        if (c === ">") return s.charAt(j + 1) === "(" ? -2 : 0;
        if (c === "<") return s.charAt(j + 1) === "(" ? -1 : 0;
        if (c === "&" && s.charAt(j + 1) === ">") return 0;
        return -1;
    }

    function parseRedir() {
        var fdLen = redirAt();
        if (fdLen === -2) fail("process substitution >(...)");
        var fd = s.substr(i, fdLen);
        i += fdLen;
        var op = "";
        var c = s.charAt(i);
        if (c === "&") { op = "&>"; i += 2; if (s.charAt(i) === ">") { op = "&>>"; i++; } }
        else if (c === ">") {
            i++;
            var d = s.charAt(i);
            if (d === ">") { op = ">>"; i++; }
            else if (d === "&") { op = ">&"; i++; }
            else if (d === "|") { op = ">|"; i++; }
            else op = ">";
        } else {
            i++;
            var e = s.charAt(i);
            if (e === "<") fail("heredoc or here-string");
            else if (e === ">") fail("read-write redirection");
            else if (e === "&") { op = "<&"; i++; }
            else op = "<";
        }
        skipWs(false);
        if (i >= n || (isMeta(s.charAt(i)) && !(s.charAt(i) === "<" && s.charAt(i + 1) === "(")))
            fail("a redirection with no target");
        var target = scanWord();
        return { fd: fd, op: op, target: target };
    }

    function trailingRedirs(redirs) {
        for (;;) {
            skipWs(false);
            if (i < n && redirAt() !== -1) redirs.push(parseRedir());
            else break;
        }
    }

    function pushCmd(cmd) {
        if (state.cmds.length >= MAX_CMDS) fail("too many commands");
        state.cmds.push(cmd);
    }

    // ---- commands ----
    function parseSimple() {
        var cmd = { words: [], assigns: [], redirs: [], text: "" };
        var start = i;
        for (;;) {
            skipWs(false);
            if (i >= n) break;
            var c = s.charAt(i);
            if (c === "\n" || c === ";" || c === "|" || c === ")") break;
            if (c === "&" && s.charAt(i + 1) !== ">") break;
            if (c === "(") fail("a subshell in the middle of a command");
            if (redirAt() !== -1) { cmd.redirs.push(parseRedir()); continue; }
            var w = scanWord();
            if (cmd.words.length === 0 && w.assign) cmd.assigns.push(w);
            else cmd.words.push(w);
        }
        cmd.text = s.substring(start, i).replace(/^\s+|\s+$/g, "");
        if (cmd.words.length === 0 && cmd.assigns.length === 0 && cmd.redirs.length === 0)
            fail("an empty command");
        if (cmd.words.length > 0 && !cmd.words[0].quoted && RESERVED_RE.test(cmd.words[0].text))
            fail("unsupported syntax: " + cmd.words[0].text);
        pushCmd(cmd);
    }

    function redirOnly(redirs, text) {
        if (redirs.length > 0) pushCmd({ words: [], assigns: [], redirs: redirs, text: text });
    }

    function parseFor() {
        i += 3;
        skipWs(false);
        var name = scanWord();
        if (!name.lit || name.quoted || !/^[a-z_][a-z0-9_]*$/.test(name.text)) fail("for: the variable name");
        skipWs(false);
        if (!atKeyword("in")) fail("for: no `in`");
        i += 2;
        for (;;) {
            skipWs(false);
            if (i >= n) fail("for: unterminated");
            var c = s.charAt(i);
            if (c === ";" || c === "\n") break;
            if (isMeta(c) && !(c === "<" && s.charAt(i + 1) === "(")) fail("for: unexpected " + c);
            scanWord();
        }
        skipWs(true);
        while (s.charAt(i) === ";") { i++; skipWs(true); }
        if (!atKeyword("do")) fail("for: no `do`");
        i += 2;
        parseSeq("done");
        if (!atKeyword("done")) fail("for: no `done`");
        i += 4;
        var redirs = [];
        trailingRedirs(redirs);
        redirOnly(redirs, "for ... done");
    }

    function parseCommand() {
        skipWs(false);
        var c = s.charAt(i);
        if (c === "(") {
            if (s.charAt(i + 1) === "(") fail("arithmetic command");
            i++;
            parseSeq(")");
            if (s.charAt(i) !== ")") fail("unterminated (");
            i++;
            var r1 = [];
            trailingRedirs(r1);
            redirOnly(r1, "( ... )");
            return;
        }
        if (atKeyword("{")) {
            i++;
            parseSeq("}");
            if (!atKeyword("}")) fail("unterminated {");
            i++;
            var r2 = [];
            trailingRedirs(r2);
            redirOnly(r2, "{ ... }");
            return;
        }
        if (atKeyword("for")) { parseFor(); return; }
        parseSimple();
    }

    function parsePipeline() {
        skipWs(false);
        // `time` and `!` only decorate the pipeline that follows.
        for (;;) {
            if (atKeyword("!")) { i++; skipWs(false); continue; }
            if (atKeyword("time")) {
                i += 4; skipWs(false);
                if (atKeyword("-p")) { i += 2; skipWs(false); }
                continue;
            }
            break;
        }
        parseCommand();
        for (;;) {
            skipWs(false);
            if (s.charAt(i) === "|" && s.charAt(i + 1) !== "|") {
                if (s.charAt(i + 1) === "&") fail("|&");
                i++;
                skipWs(true);
                parseCommand();
            } else break;
        }
    }

    function parseAndOr() {
        parsePipeline();
        for (;;) {
            skipWs(false);
            var two = s.substr(i, 2);
            if (two === "&&" || two === "||") {
                i += 2;
                skipWs(true);
                parsePipeline();
            } else break;
        }
    }

    function parseSeq(closer) {
        for (;;) {
            skipWs(true);
            while (s.charAt(i) === ";") {
                if (s.charAt(i + 1) === ";" || s.charAt(i + 1) === "&") fail("case syntax");
                i++; skipWs(true);
            }
            if (i >= n) {
                if (closer === "") return;
                fail("unexpected end of the command");
            }
            if (closer === ")" && s.charAt(i) === ")") return;
            if (closer === "}" && atKeyword("}")) return;
            if (closer === "done" && atKeyword("done")) return;
            parseAndOr();
            skipWs(false);
            var c = s.charAt(i);
            if (c === "&") fail("a background command (&)");
            if (c === ";" || c === "\n" || i >= n) continue;
            if (c === ")" && closer === ")") continue;
            if (c === ")") fail("unmatched )");
            if (closer === "}" && atKeyword("}")) continue;
            if (closer === "done" && atKeyword("done")) continue;
            fail("unexpected " + c);
        }
    }

    parseSeq("");
}

// ---- the readers: commands that cannot write, delete, send or execute ------

// Programs that need no look at their arguments: nothing they accept makes
// them write a file, run another program or reach the network. (Writing is
// the REDIRECTION's business and is judged apart.) One reason per entry.
var READERS = {
    ls:        { mode: "any", why: "lists names and metadata" },
    cat:       { mode: "any", why: "prints files" },
    head:      { mode: "any", why: "prints the start of files" },
    tail:      { mode: "any", why: "prints the end of files; -f only keeps reading" },
    wc:        { mode: "any", why: "counts lines, words and bytes" },
    stat:      { mode: "any", why: "prints file metadata" },
    cut:       { mode: "any", why: "selects columns of its input" },
    tr:        { mode: "any", why: "rewrites characters of its input to stdout" },
    tac:       { mode: "any", why: "prints lines in reverse" },
    rev:       { mode: "any", why: "reverses lines" },
    nl:        { mode: "any", why: "numbers lines" },
    fold:      { mode: "any", why: "wraps lines" },
    paste:     { mode: "any", why: "merges lines of files to stdout" },
    column:    { mode: "any", why: "lays text out in columns" },
    comm:      { mode: "any", why: "compares two sorted files" },
    diff:      { mode: "any", why: "compares files; prints, never patches" },
    cmp:       { mode: "any", why: "compares two files byte by byte" },
    basename:  { mode: "any", why: "prints a path's last part" },
    dirname:   { mode: "any", why: "prints a path's directory" },
    realpath:  { mode: "any", why: "prints a resolved path" },
    readlink:  { mode: "any", why: "prints where a link points" },
    pwd:       { mode: "any", why: "prints the working directory" },
    echo:      { mode: "any", why: "prints its arguments" },
    printf:    { mode: "printf", why: "prints formatted text; -v would assign a shell variable" },
    "true":    { mode: "any", why: "does nothing" },
    "false":   { mode: "any", why: "does nothing" },
    ":":       { mode: "any", why: "does nothing" },
    test:      { mode: "any", why: "tests a condition" },
    "[":       { mode: "any", why: "tests a condition" },
    cd:        { mode: "any", why: "moves the working directory of this one command line" },
    seq:       { mode: "any", why: "prints numbers" },
    du:        { mode: "any", why: "measures disk use" },
    df:        { mode: "any", why: "reports free space" },
    uname:     { mode: "any", why: "prints the system's name" },
    whoami:    { mode: "any", why: "prints the user's name" },
    id:        { mode: "any", why: "prints user and group ids" },
    which:     { mode: "any", why: "prints where a program is" },
    nproc:     { mode: "any", why: "prints the processor count" },
    uptime:    { mode: "any", why: "prints the uptime" },
    free:      { mode: "any", why: "prints memory use" },
    lsblk:     { mode: "any", why: "lists block devices" },
    lscpu:     { mode: "any", why: "describes the processor" },
    sha256sum: { mode: "any", why: "prints checksums" },
    sha1sum:   { mode: "any", why: "prints checksums" },
    md5sum:    { mode: "any", why: "prints checksums" },
    b2sum:     { mode: "any", why: "prints checksums" },
    grep:      { mode: "any", why: "searches text; no option writes or executes" },
    egrep:     { mode: "any", why: "searches text" },
    fgrep:     { mode: "any", why: "searches text" },
    jq:        { mode: "any", why: "filters JSON to stdout; it cannot write files or run programs" },
    find:      { mode: "find", why: "searches; refused: -exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls" },
    sed:       { mode: "sed", why: "only a script of addresses with p = l q Q or s/// (no w, e) -- never -i, -f" },
    git:       { mode: "git", why: "read verbs only (status log diff show branch --list rev-parse ls-files blame ...); never -c, --output, pagers" },
    sort:      { mode: "sort", why: "sorts; refused: -o / --output and --compress-program" },
    uniq:      { mode: "uniq", why: "filters repeats; a second file operand would be its OUTPUT file" },
    file:      { mode: "file", why: "names file types; refused: -C (writes a compiled magic file)" },
    rg:        { mode: "rg", why: "searches; refused: --pre and --hostname-bin (they run a program)" },
    fd:        { mode: "fd", why: "finds files; refused: -x / -X / --exec / --exec-batch" },
    awk:       { mode: "awk", why: "filters text; only a program that cannot write or run anything (no system(), no | > >> inside it, no -f / -i / -l)" },
    gawk:      { mode: "awk", why: "as awk" },
    mawk:      { mode: "awk", why: "as awk" }
};

var FIND_BAD = { "-exec": 1, "-execdir": 1, "-ok": 1, "-okdir": 1, "-delete": 1,
                 "-fprint": 1, "-fprint0": 1, "-fprintf": 1, "-fls": 1 };
// Primaries that take exactly one value, which is data and not a primary:
// `find . -name '-exec'` is a search for a file called -exec. Only the ones
// that certainly take a value are listed: skipping a value that was not one
// would hide the next primary.
var FIND_VAL = { "-name": 1, "-iname": 1, "-path": 1, "-ipath": 1, "-wholename": 1, "-iwholename": 1,
                 "-regex": 1, "-iregex": 1, "-lname": 1, "-ilname": 1, "-type": 1, "-xtype": 1,
                 "-user": 1, "-group": 1, "-perm": 1, "-size": 1, "-mtime": 1, "-atime": 1,
                 "-ctime": 1, "-mmin": 1, "-amin": 1, "-cmin": 1, "-newer": 1, "-anewer": 1,
                 "-cnewer": 1, "-maxdepth": 1, "-mindepth": 1, "-samefile": 1, "-inum": 1,
                 "-links": 1, "-uid": 1, "-gid": 1, "-fstype": 1, "-printf": 1, "-regextype": 1 };

var GIT_READ = { status: 1, log: 1, diff: 1, show: 1, "rev-parse": 1, "ls-files": 1, blame: 1,
                 shortlog: 1, describe: 1, "rev-list": 1, "ls-tree": 1, grep: 1 };
// Long options that write a file or run a program, as the NAMES git accepts
// them under: git takes any unambiguous prefix (`--outp=x`), so a hit is any
// option that is a prefix of one of these.
var GIT_BAD_LONG = ["output", "ext-diff", "textconv", "open-files-in-pager"];
var GIT_BRANCH_OK = { "-a": 1, "--all": 1, "-r": 1, "--remotes": 1, "-v": 1, "-vv": 1, "--verbose": 1,
                      "--list": 1, "-i": 1, "--ignore-case": 1, "--show-current": 1, "--no-color": 1,
                      "--color": 1, "--no-column": 1, "--column": 1, "--abbrev": 1, "--no-abbrev": 1 };
var GIT_BRANCH_VAL = { "--merged": 1, "--no-merged": 1, "--contains": 1, "--no-contains": 1, "--points-at": 1 };

function safe() { return { k: "safe" }; }
function refuse(why) { return { k: "refuse", why: why }; }
function defer() { return { k: "defer" }; }

function sedScriptProblem(src) {
    var s = String(src);
    var n = s.length;
    var i = 0;
    var depth = 0;
    function ws() { while (i < n && (s.charAt(i) === " " || s.charAt(i) === "\t")) i++; }
    function num() { var j = i; while (i < n && s.charAt(i) >= "0" && s.charAt(i) <= "9") i++; return i > j; }
    // Through the closing delimiter, backslash escapes only -- the way sed
    // itself splits `s/re/rep/` (brackets are NOT special to it). A raw
    // newline before the end is sed's error too.
    function delimited(d) {
        while (i < n) {
            var c = s.charAt(i);
            if (c === "\\") { i += 2; continue; }
            if (c === "\n") return false;
            i++;
            if (c === d) return true;
        }
        return false;
    }
    function address() {
        var c = s.charAt(i);
        if (c >= "0" && c <= "9") {
            num();
            if (s.charAt(i) === "~") { i++; if (!num()) return -1; }
            return 1;
        }
        if (c === "$") { i++; return 1; }
        if (c === "/") {
            i++;
            if (!delimited("/")) return -1;
        } else if (c === "\\") {
            var d = s.charAt(i + 1);
            if (d === "" || d === "\n" || d === "\\") return -1;
            i += 2;
            if (!delimited(d)) return -1;
        } else return 0;
        while (s.charAt(i) === "I" || s.charAt(i) === "M") i++;
        return 1;
    }
    while (true) {
        ws();
        while (i < n && (s.charAt(i) === ";" || s.charAt(i) === "\n")) { i++; ws(); }
        if (i >= n) break;
        if (s.charAt(i) === "}") {
            if (depth === 0) return "an unmatched }";
            depth--; i++;
            ws();
            if (i < n && s.charAt(i) !== ";" && s.charAt(i) !== "\n" && s.charAt(i) !== "}") return "text after }";
            continue;
        }
        var a1 = address();
        if (a1 < 0) return "an address it cannot read";
        if (a1 > 0) {
            ws();
            if (s.charAt(i) === ",") {
                i++; ws();
                if (s.charAt(i) === "+" || s.charAt(i) === "~") { i++; if (!num()) return "an address it cannot read"; }
                else if (address() <= 0) return "an address it cannot read";
            }
        }
        ws();
        while (s.charAt(i) === "!") { i++; ws(); }
        var c = s.charAt(i);
        i++;
        if (c === "p" || c === "=") { /* prints, nothing else */ }
        else if (c === "l" || c === "q" || c === "Q") { ws(); num(); }
        else if (c === "{") { depth++; continue; }
        else if (c === "s") {
            var d = s.charAt(i);
            if (d === "" || d === "\n" || d === "\\") return "an s command it cannot read";
            i++;
            if (!delimited(d)) return "an s command it cannot read";
            if (!delimited(d)) return "an s command it cannot read";
            while (i < n) {
                var f = s.charAt(i);
                if (f === "g" || f === "p" || f === "I" || f === "i" || f === "M" || f === "m" || (f >= "0" && f <= "9")) i++;
                else if (f === "w" || f === "e" || f === "W") return "the s flag `" + f + "` (it writes or runs)";
                else break;
            }
        } else if (c === "") {
            return "a missing command";
        } else {
            return "the command `" + c + "` (only p = l q Q s are read-only)";
        }
        ws();
        if (i < n && s.charAt(i) !== ";" && s.charAt(i) !== "\n" && s.charAt(i) !== "}") return "extra text after a command";
    }
    if (depth !== 0) return "an unclosed {";
    return "";
}

function sedAnalyze(a) {
    var scripts = [];
    var files = 0;
    var haveE = false;
    for (var p = 0; p < a.length; p++) {
        var t0 = a[p].t;
        if (t0 === "-e" || /^--expression/.test(t0) || /^-[A-Za-z]*e/.test(t0)) haveE = true;
    }
    var dd = false;
    var k = 0;
    while (k < a.length) {
        var t = a[k].t;
        k++;
        if (dd) { files++; continue; }
        if (t === "--") { dd = true; continue; }
        if (t.substring(0, 2) === "--") {
            var name = t.split("=")[0];
            if (name === "--quiet" || name === "--silent" || name === "--regexp-extended" || name === "--separate"
                    || name === "--null-data" || name === "--sandbox") continue;
            if (name === "--expression") {
                if (t.indexOf("=") >= 0) scripts.push(t.substring(t.indexOf("=") + 1));
                else if (k < a.length) { scripts.push(a[k].t); k++; }
                else return refuse("sed: --expression with no script");
                continue;
            }
            return refuse("sed: " + name + " is not a read-only option");
        }
        if (t.charAt(0) === "-" && t.length > 1) {
            for (var ci = 1; ci < t.length; ci++) {
                var ch = t.charAt(ci);
                if (ch === "n" || ch === "E" || ch === "r" || ch === "s" || ch === "z") continue;
                if (ch === "e") {
                    var rest = t.substring(ci + 1);
                    if (rest.length > 0) scripts.push(rest);
                    else if (k < a.length) { scripts.push(a[k].t); k++; }
                    else return refuse("sed: -e with no script");
                    break;
                }
                return refuse("sed: -" + ch + " is not a read-only option");
            }
            continue;
        }
        if (!haveE && scripts.length === 0) scripts.push(t);
        else files++;
    }
    if (scripts.length === 0) return refuse("sed: no script to check");
    for (var q = 0; q < scripts.length; q++) {
        var prob = sedScriptProblem(scripts[q]);
        if (prob) return refuse("sed: " + prob + " -- only a reading script runs without asking");
    }
    return safe();
}

function longName(t) { return t.substring(2).split("=")[0]; }
// An option that is a prefix of a dangerous long name (git, sort accept those).
function abbrevOf(name, full) { return name.length > 0 && full.indexOf(name) === 0; }

function gitAnalyze(a) {
    var k = 0;
    while (k < a.length && a[k].t.charAt(0) === "-") {
        var t = a[k].t;
        if (t === "--no-pager" || t === "--no-optional-locks" || t === "--no-replace-objects") { k++; continue; }
        if (t === "-C" && k + 1 < a.length) { k += 2; continue; }
        return refuse("git " + t + " changes how git runs -- never without asking");
    }
    if (k >= a.length) return safe();
    var verb = a[k].t;
    var rest = a.slice(k + 1);
    if (has(GIT_READ, verb)) {
        for (var i = 0; i < rest.length; i++) {
            var o = rest[i].t;
            if (o === "--") break;
            if (o.substring(0, 2) === "--") {
                var nm = longName(o);
                for (var b = 0; b < GIT_BAD_LONG.length; b++)
                    if (abbrevOf(nm, GIT_BAD_LONG[b])) return refuse("git " + verb + " " + o + " writes a file or runs a program");
            } else if (o.charAt(0) === "-" && verb === "grep" && o.indexOf("O") > 0) {
                return refuse("git grep -O runs a program");
            }
        }
        return safe();
    }
    if (verb === "branch") {
        var list = false;
        var positional = false;
        for (var j = 0; j < rest.length; j++) {
            var u = rest[j].t;
            if (has(GIT_BRANCH_OK, u) || /^-[avri]+$/.test(u) || /^--(color|abbrev|column)=/.test(u) || /^--(sort|format)=/.test(u)) {
                if (u === "--list") list = true;
                continue;
            }
            if (has(GIT_BRANCH_VAL, u)) { list = true; if (j + 1 < rest.length && rest[j + 1].t.charAt(0) !== "-") j++; continue; }
            if (u.charAt(0) === "-") return refuse("git branch " + u + " is not a listing option");
            positional = true;
        }
        if (positional && !list) return refuse("git branch with a name creates a branch -- use --list to filter");
        return safe();
    }
    return defer();
}

function sortAnalyze(a) {
    var dd = false;
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (dd) continue;
        if (t === "--") { dd = true; continue; }
        if (t.substring(0, 2) === "--") {
            var nm = longName(t);
            if (abbrevOf(nm, "output") || abbrevOf(nm, "compress-program"))
                return refuse("sort " + t + " writes a file or runs a program");
            continue;
        }
        if (t.charAt(0) === "-" && t.length > 1) {
            for (var c = 1; c < t.length; c++) {
                var ch = t.charAt(c);
                if (ch === "o") return refuse("sort -o writes a file");
                if (ch === "k" || ch === "t" || ch === "T" || ch === "S") break;
            }
        }
    }
    return safe();
}

function uniqAnalyze(a) {
    var pos = 0;
    var dd = false;
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (!dd && t === "--") { dd = true; continue; }
        if (!dd && t.charAt(0) === "-" && t.length > 1) {
            // -f N, -s N, -w N take a value when it is not attached.
            if (/^-[fsw]$/.test(t)) i++;
            continue;
        }
        pos++;
    }
    if (pos > 1) return refuse("uniq with two files writes the second one");
    return safe();
}

function fileAnalyze(a) {
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (t.substring(0, 2) === "--") { if (abbrevOf(longName(t), "compile")) return refuse("file -C writes a compiled magic file"); }
        else if (t.charAt(0) === "-" && t.indexOf("C") > 0) return refuse("file -C writes a compiled magic file");
    }
    return safe();
}

function rgAnalyze(a) {
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (t === "--") break;
        if (t.substring(0, 2) === "--") {
            var nm = longName(t);
            if (nm === "pre" || nm === "hostname-bin") return refuse("rg " + t + " runs a program");
        }
    }
    return safe();
}

function fdAnalyze(a) {
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (t === "--") break;
        if (t.substring(0, 2) === "--") {
            var nm = longName(t);
            if (nm === "exec" || nm === "exec-batch") return refuse("fd " + t + " runs a program");
        } else if (t.charAt(0) === "-" && (t.indexOf("x") > 0 || t.indexOf("X") > 0)) {
            return refuse("fd -x runs a program");
        }
    }
    return safe();
}

function findAnalyze(a) {
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (has(FIND_BAD, t)) return refuse("find " + t + " writes or runs something");
        if (has(FIND_VAL, t) || /^-newer[A-Za-z]{2}$/.test(t)) i++;
    }
    return safe();
}

// ---- awk -------------------------------------------------------------------
//
// awk is a reader when its PROGRAM cannot write a file or start a program. The
// ways it can: system(); `print > "f"` / `>>` / `| "cmd"` (an output redirection
// is only one inside a print / printf statement -- elsewhere `>` compares);
// `"cmd" | getline` and gawk's `|&` (a pipe outside print is always a command);
// gawk's @include / @load; and the options that bring in a program or a module
// we have not read: -f, -i (`-i inplace` rewrites the file), -l, -e, --anything.
// The program is read the way awk's lexer does -- strings, regex literals (a `/`
// after an operand is a division) and comments are skipped, so `/Mem|Swap/` and
// `"a|b"` do not look like a pipe -- and any doubt is a refusal: an unterminated
// string, a `/` inside a regex's brackets (gawk and mawk disagree on where such a
// regex ends, and a lexer that ends it early could be walked into a string).
var AWK_KEYWORDS = { print: 1, printf: 1, "in": 1, getline: 1, "return": 1, "case": 1, "delete": 1, "do": 1, "else": 1 };

function awkProgramProblem(src) {
    var s = String(src);
    var n = s.length;
    var i = 0;
    var operand = false;          // the previous token ends an operand: a `/` divides
    var depth = 0;                // ( [ { nesting
    var printDepth = -1;          // depth at which a print / printf statement is open, or -1
    function ident(c) { return /[A-Za-z0-9_]/.test(c); }
    while (i < n) {
        var c = s.charAt(i);
        if (c === " " || c === "\t" || c === "\r") { i++; continue; }
        if (c === "\\" && s.charAt(i + 1) === "\n") { i += 2; continue; }
        if (c === "\n") { i++; operand = false; if (printDepth === depth) printDepth = -1; continue; }
        if (c === "#") { while (i < n && s.charAt(i) !== "\n") i++; continue; }
        if (c === "\"") {
            i++;
            for (;;) {
                if (i >= n || s.charAt(i) === "\n") return "an unterminated string";
                var d = s.charAt(i);
                if (d === "\\") { i += 2; continue; }
                i++;
                if (d === "\"") break;
            }
            operand = true;
            continue;
        }
        if (c === "/" && !operand) {
            i++;
            var inBr = false;
            for (;;) {
                if (i >= n || s.charAt(i) === "\n") return "an unterminated regular expression";
                var e = s.charAt(i);
                if (e === "\\") { i += 2; continue; }
                if (e === "[" && !inBr) { inBr = true; i++; if (s.charAt(i) === "^") i++; if (s.charAt(i) === "]") i++; continue; }
                if (e === "]" && inBr) { inBr = false; i++; continue; }
                if (e === "/") { if (inBr) return "a / inside a regular expression's brackets"; i++; break; }
                i++;
            }
            operand = true;
            continue;
        }
        if (ident(c)) {
            var j = i;
            while (j < n && ident(s.charAt(j))) j++;
            var w = s.substring(i, j);
            i = j;
            if (w === "system") return "system() runs a program";
            if (w === "print" || w === "printf") printDepth = depth;
            operand = !has(AWK_KEYWORDS, w);
            continue;
        }
        if (c === "@") return "@ (gawk include / load / namespace)";
        if (c === "|") {
            if (s.charAt(i + 1) === "|") { i += 2; operand = false; continue; }
            return "a | pipes to or from a command";
        }
        if (c === ">") {
            if (printDepth === depth) return "print > redirects output to a file";
            i += (s.charAt(i + 1) === ">" ? 2 : 1); operand = false; continue;
        }
        if (c === "(" || c === "[" || c === "{") { depth++; operand = false; i++; continue; }
        if (c === ")" || c === "]" || c === "}") {
            if (printDepth >= depth) printDepth = -1;
            depth--; operand = (c !== "}"); i++; continue;
        }
        if (c === ";") { if (printDepth === depth) printDepth = -1; operand = false; i++; continue; }
        if ((c === "+" || c === "-") && s.charAt(i + 1) === c) { i += 2; continue; }   // ++ -- keep `operand`: a `/` after them divides
        operand = false;
        i++;
    }
    return "";
}

function awkAnalyze(a) {
    var prog = -1;
    for (var i = 0; i < a.length; i++) {
        var t = a[i].t;
        if (t === "--") { prog = i + 1; break; }
        if (t.charAt(0) !== "-" || t === "-") { prog = i; break; }
        if (t === "-F" || t === "-v") { i++; continue; }              // the separator / the assignment is data
        if (t.charAt(1) === "F" || (t.charAt(1) === "v" && t.length > 2)) continue;   // -F: / -vx=1
        return refuse("awk " + t + " brings in a program or module that is not read here");
    }
    if (prog < 0 || prog >= a.length) return refuse("awk with no program text");
    var why = awkProgramProblem(a[prog].t);
    if (why) return refuse("awk: " + why);
    return safe();
}

// Judge a registry program's arguments: safe | refuse(why) | defer.
function readerVerdict(name, args) {
    var m = READERS[name].mode;
    if (m === "any") return safe();
    // Every analyser below reads its arguments, so an argument whose value is
    // only known at run time (`$x`, `$(..)`, a glob that opens a word) cannot
    // be judged -- it could be `-delete`.
    for (var i = 0; i < args.length; i++)
        if (args[i].unsure) return refuse(name + ": an argument (" + args[i].text + ") is only known when it runs");
    if (m === "printf") {
        for (var p = 0; p < args.length; p++) if (args[p].t === "-v") return refuse("printf -v assigns a shell variable");
        return safe();
    }
    if (m === "find") return findAnalyze(args);
    if (m === "sed") return sedAnalyze(args);
    if (m === "git") return gitAnalyze(args);
    if (m === "sort") return sortAnalyze(args);
    if (m === "uniq") return uniqAnalyze(args);
    if (m === "file") return fileAnalyze(args);
    if (m === "rg") return rgAnalyze(args);
    if (m === "fd") return fdAnalyze(args);
    if (m === "awk") return awkAnalyze(args);
    return refuse(name + ": no reader test");
}

// ---- the judgement ---------------------------------------------------------

var VERB_FLAG_RE = /^-{1,2}[A-Za-z][A-Za-z0-9-]*$/;
var VERB_WORD_RE = /^[a-z][a-z0-9-]*$/;
var PROGRAM_RE = /^[A-Za-z0-9_.\/~+-]+$/;

// A command as text for the always-ask patterns: the program reduced to its
// basename (`/usr/bin/sudo` meets `sudo`), a quoted word with the characters
// the patterns read as separators made inert, so `echo "a; sudo b"` is not
// "a; sudo".
function policyText(cmd) {
    var parts = [];
    for (var i = 0; i < cmd.words.length; i++) {
        var w = cmd.words[i];
        var t = w.text;
        if (i === 0 && !w.quoted && PROGRAM_RE.test(t)) t = basename(t);
        else if (w.quoted) t = t.replace(/[;&|()\n]/g, "_").replace(/^-/, "_");
        parts.push(t);
    }
    return parts.join(" ");
}

function redirProblem(r) {
    var t = r.target;
    var op = r.op;
    if (op === "<") return "";
    if (op === ">" || op === ">>" || op === ">|" || op === "&>" || op === "&>>") {
        if (!t.dyn && !t.glob && !t.brace && t.text === "/dev/null") return "";
        return "writes to " + (t.text.length > 40 ? t.text.substring(0, 40) + "..." : t.text);
    }
    if (op === ">&" || op === "<&") {
        if (!t.dyn && /^([0-9]+|-)$/.test(t.text)) return "";
        return "redirects to " + t.text;
    }
    return "redirects with " + op;
}

// The grant key of a command: the program, and the one word
// that says what it is doing when that is a plain flag or verb. null when no
// rule can describe the command.
function keyOf(cmd) {
    if (cmd.assigns.length > 0 || cmd.words.length === 0) return null;
    var prog = cmd.words[0];
    if (prog.quoted || prog.dyn || (prog.glob && prog.text !== "[") || prog.brace || !PROGRAM_RE.test(prog.text)) return null;
    if (prog.text.indexOf("/") >= 0) return null;
    var name = prog.text;
    if (name === "" || name === "{" || name === "}" || name === "!") return null;
    if (cmd.words.length > 1) {
        var v = cmd.words[1];
        if (v.dyn) return null;
        if (!v.quoted && (VERB_FLAG_RE.test(v.text) || VERB_WORD_RE.test(v.text))) return name + " " + v.text;
    }
    return name;
}

var GENERIC = "no rule can describe this command";

// judge(cmd, policy, hasGrant) -> { state, why, key, alwaysAsk }
//   state: "auto" | "granted" | "ask"; key set when a grant could describe it.
function judge(cmd, policy, hasGrant) {
    var out = { state: "ask", why: GENERIC, key: null, alwaysAsk: false, hard: false };
    // 1. The always-ask list sees every command, whatever else is true of it.
    if (cmd.words.length > 0) {
        var ask = matchPolicy(policyText(cmd), policy.alwaysAsk);
        if (ask) { out.alwaysAsk = true; out.hard = true; out.why = hitWords(ask.match) + " — always asks"; return out; }
    }
    // 2. Redirections: only /dev/null and fd duplication are harmless.
    for (var r = 0; r < cmd.redirs.length; r++) {
        var rp = redirProblem(cmd.redirs[r]);
        if (rp) { out.hard = true; out.why = rp + " — asks every time"; return out; }
    }
    // 3. A command made only of redirections (a loop's or group's own).
    if (cmd.words.length === 0 && cmd.assigns.length === 0) { out.state = "auto"; out.why = ""; return out; }
    // 4. A bare assignment: harmless when it cannot be a name the shell reads.
    if (cmd.words.length === 0) {
        for (var a = 0; a < cmd.assigns.length; a++) {
            var nm = cmd.assigns[a].text.split("=")[0];
            if (!/^[a-z_][a-z0-9_]*$/.test(nm)) { out.hard = true; out.why = "sets " + nm + " — asks every time"; return out; }
        }
        out.state = "auto"; out.why = "";
        return out;
    }
    if (cmd.assigns.length > 0) { out.hard = true; return out; }
    // 5. The program itself must be a plain name.
    var prog = cmd.words[0];
    if (prog.quoted || prog.dyn || (prog.glob && prog.text !== "[") || prog.brace || prog.text === "") { out.hard = true; out.why = "the program is not a plain name — " + GENERIC; return out; }
    var name = prog.text;
    if (name.indexOf("/") < 0 && has(READERS, name)) {
        var args = [];
        for (var i = 1; i < cmd.words.length; i++)
            args.push({ t: cmd.words[i].text, text: cmd.words[i].text, unsure: cmd.words[i].unsure });
        var v = readerVerdict(name, args);
        if (v.k === "safe") { out.state = "auto"; out.why = ""; return out; }
        if (v.k === "refuse") { out.hard = true; out.why = v.why; return out; }
        // defer: the program is a reader only for some verbs; this one is not
        // one of them, so it is a command like any other -- a grant may cover it.
    }
    var key = keyOf(cmd);
    if (key === null) { out.hard = true; return out; }
    out.key = key;
    if (hasGrant && hasGrant(key)) { out.state = "granted"; out.why = ""; return out; }
    out.why = "";
    return out;
}

// analyze(command, policy, opts) ->
//   { mode: "auto" | "granted" | "ask" | "refused",
//     keys, label, grantable, reason, alwaysAsk, parsed, parts }
//   opts.hasGrant(key) -> bool
//   keys: the grant keys the line would WRITE (mode ask) or USES (granted).
//   parts: every simple command in order -- { text, state, why, key }.
function analyze(command, policy, opts) {
    var pol = policy || {};
    var text = String(command || "");
    var hasGrant = (opts && opts.hasGrant) ? opts.hasGrant : null;
    var out = { mode: "ask", keys: [], label: "", grantable: false, reason: "", alwaysAsk: false, refused: false,
                parsed: false, parts: [] };
    if (matchPolicy(text, pol.neverRun)) {
        out.mode = "refused"; out.refused = true; out.reason = "refused by policy";
        return out;
    }
    var p = parse(text);
    if (!p.ok || p.cmds.length === 0) {
        // The text could not be read as a whole: the always-ask list still
        // gets the raw text, so `curl x | sh` with a stray quote still says curl.
        var ask = matchPolicy(text, pol.alwaysAsk);
        if (ask) { out.alwaysAsk = true; out.reason = hitWords(ask.match) + " — always asks"; }
        else out.reason = GENERIC;
        out.parts = [{ text: text, state: "ask", why: p.ok ? "nothing to run" : p.error }];
        return out;
    }
    out.parsed = true;
    var verdicts = [];
    var firstAsk = null;
    var firstHard = null;
    for (var i = 0; i < p.cmds.length; i++) {
        var j = judge(p.cmds[i], pol, hasGrant);
        verdicts.push(j);
        // `key`: the rule that would let THIS command through, offered on its own
        // by the confirmation (null for a command no rule may cover, and for one
        // that already passes).
        out.parts.push({ text: p.cmds[i].text, state: j.state, why: j.why,
                         key: (j.state === "ask" && !j.hard && j.key !== null) ? j.key : null });
        if (j.alwaysAsk && firstAsk === null) firstAsk = j;
        if (j.hard && firstHard === null) firstHard = j;
    }
    if (firstAsk) { out.alwaysAsk = true; out.reason = firstAsk.why; return out; }
    if (firstHard) { out.reason = firstHard.why; return out; }
    var need = [];
    var used = [];
    for (var k = 0; k < verdicts.length; k++) {
        var v = verdicts[k];
        if (v.state === "ask" && v.key !== null && need.indexOf(v.key) < 0) need.push(v.key);
        else if (v.state === "granted" && used.indexOf(v.key) < 0) used.push(v.key);
    }
    if (need.length === 0) {
        out.mode = used.length > 0 ? "granted" : "auto";
        out.keys = used;
        out.label = used.map(function (x) { return x + " …"; }).join(" | ");
        out.grantable = used.length > 0;
        return out;
    }
    out.mode = "ask";
    out.keys = need;
    out.grantable = true;
    out.label = need.map(function (x) { return x + " …"; }).join(" | ");
    return out;
}
