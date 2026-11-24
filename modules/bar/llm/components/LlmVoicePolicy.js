.pragma library

// =============================================================================
// LlmVoicePolicy.js -- what a SPOKEN request may do before anybody looks.
//
// A voice ask (`LlmService.voiceAsk`) is hands-free: the user is typing in
// another window, the popup comes up without the keyboard, and the turn runs
// without a click. Most of a turn needs nobody: the model answers. What it may
// RUN without a click is this file's business, and it is a security boundary,
// so it is small, pure and table-tested (tools/dev/llm_voice_cases.js, which
// also holds every accepted line to what bash itself makes of it).
//
// ONE SIMPLE COMMAND FROM A SHORT LIST, AND NOTHING THE SHELL WOULD EXPAND.
// `check()` takes the model's command line and answers whether it may run at
// once. It accepts a line only when it is one simple command made of plain
// words: printable ASCII only (no look-alike letters, no bidi controls), none
// of `; & | $ ( ) < > \` and backtick anywhere, quoted or not, outside quotes
// only letters, digits and `_ . / , : = + % @ ^ ~ -`, no assignment before the
// command, and a `~` only where bash's own rule is plain (a word that is `~`
// or starts `~/`, expanded here to $HOME; `~user`, `~+` and a `~` after the
// `=` of an assignment-like word are refused, a `~` inside a word such as
// `HEAD~1` is literal in bash and here). The program must be one of PROGRAMS,
// each with its own option rules, and no argument may name a secret store
// (SECRET_HOME / SECRET_ABS / SECRET_NAME), lexically AND after the runner's
// preflight resolved it on disk (a symlink into ~/.ssh is a path into ~/.ssh).
// Everything else is not refused: it goes to the confirmation, as a typed
// chat's commands do.
//
// THE ACCEPTED LINE IS NEVER HANDED TO A SHELL. `check()` returns the argv it
// judged, and the runner executes that argv directly (`timeout ... git ...`,
// no `bash -c`), so what runs is what was read, word for word; a
// disagreement between this splitter and bash cannot change what runs. Its
// stdin is closed at once (a bare `cat` ends instead of waiting a minute).
//
// GIT IN A DIRECTORY NOBODY CHOSE. The command runs in the focused terminal's
// directory, which may be a repository the user unpacked from anywhere, and a
// repository's own .git/config can make a READ run a program: `core.fsmonitor`
// on `git status`, a `post-index-change` hook when status refreshes the index,
// a `filter.<x>.clean` named by .git/info/attributes on `git diff` / `blame`
// (all three measured on git 2.56). So git runs as
//   git --no-pager --no-optional-locks -c core.fsmonitor=false
//       -c core.hooksPath=/dev/null -c log.showSignature=false
//       [-c filter.<x>.clean= -c filter.<x>.smudge= -c filter.<x>.process=
//        for every filter the repository itself defines -- the preflight lists
//        them] <verb> [--no-ext-diff --no-textconv] [--ignore-submodules=all] ...
// which ran none of the three where the plain command ran all of them. A
// filter the user's own ~/.gitconfig defines (git-lfs) is theirs and is left
// alone.
//
// WHAT THE OTHER TOOLS DO IN A SPOKEN TURN is `toolVerdict()`: the reading
// tools keep running free except where they would read a secret store, the
// clipboard or the screen; a web search runs free only until the turn has
// read anything from the machine (after that a query could carry it off); no
// remembered rule ("Always allow") applies, so everything that acts asks.
//
// `copyOf()` decides which final answers go to the clipboard by themselves.
// =============================================================================

var MAX_LINE = 1000;

// ---- the programs ----------------------------------------------------------

// One reason per entry: what it does, and what it may never do here.
var PROGRAMS = {
    git:   "reads the repository: log, status, show, diff, rev-parse, describe, blame, branch (listing), remote -v",
    ls:    "lists names and metadata",
    cat:   "prints files",
    head:  "prints the start of files",
    tail:  "prints the end of files -- never -f (a spoken request must end)",
    wc:    "counts lines, words and bytes",
    grep:  "searches text -- -r only below a directory that holds no secret store, never -R",
    date:  "prints the date -- never -s (sets the clock) or -f (reads a file of dates)",
    pwd:   "prints the working directory",
    which: "prints where a program is",
    df:    "reports free space",
    du:    "measures disk use",
    uname: "prints the system's name",
    stat:  "prints file metadata",
    file:  "names file types -- never -C (writes a compiled magic file)"
};

var GIT_VERBS = { log: 1, status: 1, show: 1, diff: 1, "rev-parse": 1, describe: 1, blame: 1, branch: 1, remote: 1 };
// Verbs that take the diff options: an external diff and a textconv are programs.
var GIT_DIFFS = { log: 1, show: 1, diff: 1, blame: 1 };
// Verbs that would walk into submodules, each with its own .git/config.
var GIT_SUBMODULES = { status: 1, diff: 1 };
// Long options that write a file, run a program or reach another repository.
// git takes an unambiguous prefix of a long option, so a hit is any option
// that is a prefix of one of these.
var GIT_BAD_LONG = ["output", "ext-diff", "textconv", "exec", "upload-pack", "receive-pack", "open-files-in-pager",
                    "show-signature", "config", "git-dir", "work-tree", "namespace"];
var GIT_BRANCH_OK = { "-a": 1, "--all": 1, "-r": 1, "--remotes": 1, "-v": 1, "-vv": 1, "--verbose": 1, "-l": 1,
                      "--list": 1, "--show-current": 1, "--no-color": 1, "--no-column": 1, "--no-abbrev": 1 };
var GIT_SAFE_PREFIX = ["--no-pager", "--no-optional-locks",
                       "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false"];

// grep: the short options that take a value (attached or the next word), and
// the long ones that take the next word when no `=` is attached.
var GREP_SHORT_VAL = "efmABCdD";
var GREP_LONG_VAL = { regexp: 1, file: 1, "max-count": 1, "after-context": 1, "before-context": 1, context: 1,
                      directories: 1, devices: 1, label: 1, "binary-files": 1, include: 1, exclude: 1,
                      "exclude-from": 1, "exclude-dir": 1 };
// What a recursive grep below the user's own tree never opens.
var GREP_EXCLUDES = ["--exclude=.env", "--exclude=.env.*", "--exclude=*.pem", "--exclude=*.key", "--exclude=*.p12",
                     "--exclude=*.pfx", "--exclude=*.kdbx", "--exclude=id_rsa", "--exclude=id_dsa", "--exclude=id_ecdsa",
                     "--exclude=id_ed25519", "--exclude=.netrc", "--exclude=.pgpass", "--exclude=.git-credentials",
                     "--exclude=credentials*", "--exclude=secret*", "--exclude-dir=.ssh", "--exclude-dir=.gnupg",
                     "--exclude-dir=.password-store", "--exclude-dir=keyrings"];
// The same names for ripgrep (search_files), as negated globs.
var RG_EXCLUDES = ["!.env", "!.env.*", "!*.pem", "!*.key", "!*.p12", "!*.pfx", "!*.kdbx", "!id_rsa", "!id_dsa",
                   "!id_ecdsa", "!id_ed25519", "!.netrc", "!.pgpass", "!.git-credentials", "!credentials*", "!secret*",
                   "!.ssh/**", "!.gnupg/**", "!.password-store/**", "!keyrings/**"];

// ---- the secrets -----------------------------------------------------------

// Below $HOME: keys, keyrings, password stores, browser profiles (cookies,
// saved passwords), cloud and registry credentials, the shell's own state
// (the conversations and the clipboard history live there).
var SECRET_HOME = [".ssh", ".gnupg", ".password-store", ".local/share/keyrings", ".local/share/kwalletd",
                   ".mozilla", ".librewolf", ".zen", ".floorp", ".waterfox",
                   ".config/google-chrome", ".config/chromium", ".config/BraveSoftware", ".config/vivaldi",
                   ".config/microsoft-edge", ".config/opera",
                   ".aws", ".kube", ".docker", ".config/gh", ".config/rclone", ".pki",
                   ".netrc", ".git-credentials", ".pgpass", ".local/state/lares"];
var SECRET_ABS = ["/etc/shadow", "/etc/gshadow", "/etc/shadow-", "/etc/gshadow-", "/etc/sudoers", "/etc/sudoers.d",
                  "/etc/ssh", "/root"];
// Anywhere, by name: dotenv files, keys and certificates, key stores.
var SECRET_NAME = /^(\.env(\..*)?|.*\.(pem|key|p12|pfx|kdbx|keystore|jks|gpg)|id_(rsa|dsa|ecdsa|ed25519)(_sk)?|\.netrc|\.pgpass|\.git-credentials|credentials(\..*)?|secrets?(\..*)?)$/;
var SECRET_PROC = /^\/proc\/[^\/]+\/(environ|mem|maps|smaps|auxv)$/;

// ---- small helpers ---------------------------------------------------------

function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

function basename(p) {
    var s = String(p || "");
    var i = s.lastIndexOf("/");
    return i >= 0 ? s.substring(i + 1) : s;
}

// `.` and `..` collapsed; relative paths are taken against `cwd`.
function absPath(p, cwd) {
    var s = String(p);
    var full = s.charAt(0) === "/" ? s : (String(cwd || "/") + "/" + s);
    var parts = full.split("/");
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var seg = parts[i];
        if (seg === "" || seg === ".") continue;
        if (seg === "..") { if (out.length > 0) out.pop(); continue; }
        out.push(seg);
    }
    return "/" + out.join("/");
}

function within(p, root) { return p === root || p.indexOf(root + "/") === 0; }

function secretRoots(home) {
    var out = SECRET_ABS.slice();
    if (home) for (var i = 0; i < SECRET_HOME.length; i++) out.push(home + "/" + SECRET_HOME[i]);
    return out;
}

// The secret store an absolute path is in, or "".
function secretOf(abs, home) {
    var roots = secretRoots(home);
    for (var i = 0; i < roots.length; i++)
        if (within(abs, roots[i])) return roots[i];
    if (SECRET_PROC.test(abs)) return abs;
    var segs = abs.split("/");
    for (var j = 0; j < segs.length; j++)
        if (segs[j] !== "" && SECRET_NAME.test(segs[j])) return segs[j];
    return "";
}

// The secret store a DIRECTORY holds below it (or is in), or "": what a
// recursive read of it would open.
function secretBelow(abs, home) {
    var inside = secretOf(abs, home);
    if (inside) return inside;
    var roots = secretRoots(home);
    for (var i = 0; i < roots.length; i++)
        if (abs === "/" || within(roots[i], abs)) return roots[i];
    // /proc holds every process's environment (tokens exported in a shell rc).
    if (/^\/proc(\/[^\/]+)?$/.test(abs)) return "/proc/*/environ";
    return "";
}

function shortHome(p, home) {
    if (home && p === home) return "~";
    if (home && p.indexOf(home + "/") === 0) return "~" + p.substring(home.length);
    return p;
}

function refuse(why) { return { ok: false, why: why, argv: [], resolve: [], git: false }; }

// ---- the splitter ----------------------------------------------------------

var BAD_ANYWHERE = ";&|$()<>\\`";
var UNQUOTED_OK = /^[A-Za-z0-9_.\/,:=+%@^~-]$/;
var ASSIGN_LIKE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// split(line, home) -> { ok, why, words: [{ text, quoted }] }
// The words as bash would hand them to the program, with `~` and `~/...`
// expanded, or a refusal naming the first thing that is not plain.
function split(src, home) {
    var s = String(src === undefined || src === null ? "" : src);
    if (s.replace(/ /g, "").length === 0) return { ok: false, why: "an empty command", words: [] };
    if (s.length > MAX_LINE) return { ok: false, why: "the line is too long", words: [] };
    for (var k = 0; k < s.length; k++) {
        var code = s.charCodeAt(k);
        if (code < 0x20 || code > 0x7e)
            return { ok: false, why: code === 10 ? "more than one line" : "a character outside plain ASCII (U+" + ("0000" + code.toString(16).toUpperCase()).slice(-4) + ")", words: [] };
        if (BAD_ANYWHERE.indexOf(s.charAt(k)) >= 0)
            return { ok: false, why: "`" + s.charAt(k) + "` is shell syntax", words: [] };
    }
    var words = [];
    var cur = null;
    var i = 0;
    var n = s.length;
    function begin() { if (!cur) cur = { text: "", q: [], quoted: false }; }
    while (i < n) {
        var c = s.charAt(i);
        if (c === " ") {
            if (cur) { words.push(cur); cur = null; }
            i++;
            continue;
        }
        begin();
        if (c === "'" || c === "\"") {
            var j = s.indexOf(c, i + 1);
            if (j < 0) return { ok: false, why: "an unterminated quote", words: [] };
            var inner = s.substring(i + 1, j);
            for (var m = 0; m < inner.length; m++) { cur.text += inner.charAt(m); cur.q.push(true); }
            cur.quoted = true;
            i = j + 1;
            continue;
        }
        if (!UNQUOTED_OK.test(c)) return { ok: false, why: "`" + c + "` outside quotes", words: [] };
        cur.text += c;
        cur.q.push(false);
        i++;
    }
    if (cur) words.push(cur);
    var out = [];
    for (var w = 0; w < words.length; w++) {
        var t = words[w].text;
        var q = words[w].q;
        var tildeAt = -1;
        for (var x = 0; x < t.length; x++) if (t.charAt(x) === "~" && !q[x]) { tildeAt = x; break; }
        if (tildeAt === 0) {
            // bash: the tilde-prefix runs to the first UNQUOTED slash, and is
            // expanded only when none of it is quoted. Only `~` alone is plain.
            if (t.length === 1 || (t.charAt(1) === "/" && !q[1])) {
                if (!home) return { ok: false, why: "`~` with no home directory known", words: [] };
                t = home + t.substring(1);
            } else {
                return { ok: false, why: "`" + t.split("/")[0] + "` would be expanded by the shell", words: [] };
            }
        } else if (tildeAt > 0 && ASSIGN_LIKE.test(t)) {
            return { ok: false, why: "a `~` after `=` would be expanded by the shell", words: [] };
        }
        out.push({ text: t, quoted: words[w].quoted, firstQuoted: q.length > 0 && q[0] });
    }
    return { ok: true, why: "", words: out };
}

// ---- per-program option rules ----------------------------------------------

// Walk a short-option cluster `-abc` (or `-n5`): `valueChars` take the rest
// of the cluster (or the next word) as their value. Returns { letters, takesNext }.
function cluster(word, valueChars) {
    var letters = "";
    for (var i = 1; i < word.length; i++) {
        var ch = word.charAt(i);
        letters += ch;
        if (valueChars.indexOf(ch) >= 0) return { letters: letters, takesNext: i === word.length - 1 };
    }
    return { letters: letters, takesNext: false };
}

function longName(w) { return w.substring(2).split("=")[0]; }
function abbrevOf(name, full) { return name.length >= 2 && full.indexOf(name) === 0; }

// Path candidates of one argument word: the word itself, the value after
// `--opt=`, the rest of `-fFILE`, and what follows `:` (git's `HEAD:path`).
function candidatesOf(word) {
    var out = [];
    if (word.substring(0, 2) === "--") {
        var eq = word.indexOf("=");
        if (eq > 0 && eq < word.length - 1) out.push(word.substring(eq + 1));
    } else if (word.charAt(0) === "-" && word.length > 1) {
        if (word.length > 2) out.push(word.substring(2));
    } else if (word.length > 0) {
        out.push(word);
        var col = word.indexOf(":");
        if (col >= 0 && col < word.length - 1) out.push(word.substring(col + 1));
    }
    return out;
}

function gitRule(args) {
    if (args.length === 0) return { why: "git with no verb" };
    var verb = args[0];
    if (verb.charAt(0) === "-") return { why: "git " + verb + " changes how git runs" };
    if (!has(GIT_VERBS, verb)) return { why: "git " + verb + " is not a read-only verb" };
    var rest = args.slice(1);
    for (var i = 0; i < rest.length; i++) {
        var o = rest[i];
        if (o === "--") break;
        if (o.substring(0, 2) === "--") {
            var nm = longName(o);
            for (var b = 0; b < GIT_BAD_LONG.length; b++)
                if (abbrevOf(nm, GIT_BAD_LONG[b]) || nm === GIT_BAD_LONG[b]) return { why: "git " + verb + " " + o + " writes, runs or reaches out" };
        } else if (o.charAt(0) === "-" && o.length > 1) {
            if (/[cCoO]/.test(o.substring(1)) && verb !== "rev-parse" && !/^-[0-9]+$/.test(o))
                return { why: "git " + verb + " " + o + " is not read here without asking" };
        }
        if (o.indexOf("%G") >= 0) return { why: "a %G format asks gpg" };
    }
    if (verb === "branch") {
        var list = false;
        var positional = false;
        for (var j = 0; j < rest.length; j++) {
            var u = rest[j];
            if (has(GIT_BRANCH_OK, u) || /^--(sort|format)=/.test(u)) { if (u === "--list" || u === "-l") list = true; continue; }
            if (u.charAt(0) === "-") return { why: "git branch " + u + " is not a listing option" };
            positional = true;
        }
        if (positional && !list) return { why: "git branch with a name makes a branch" };
    }
    if (verb === "remote") {
        if (!(rest.length === 0 || (rest.length === 1 && (rest[0] === "-v" || rest[0] === "--verbose"))))
            return { why: "git remote " + rest.join(" ") + " is more than a listing" };
    }
    return { why: "" };
}

function tailRule(args) {
    for (var i = 0; i < args.length; i++) {
        var w = args[i];
        if (w === "--") break;
        if (w.substring(0, 2) === "--") {
            var nm = longName(w);
            if (abbrevOf(nm, "follow") || nm === "follow" || nm === "retry" || nm === "pid") return { why: "tail " + w + " keeps reading" };
        } else if (w.charAt(0) === "-" && w.length > 1 && !/^-[0-9]/.test(w)) {
            var c = cluster(w, "cns");
            if (/[fF]/.test(c.letters)) return { why: "tail -f keeps reading" };
            if (c.takesNext) i++;
        }
    }
    return { why: "" };
}

function dateRule(args) {
    for (var i = 0; i < args.length; i++) {
        var w = args[i];
        if (w === "--") break;
        if (w.substring(0, 2) === "--") {
            var nm = longName(w);
            if (abbrevOf(nm, "set")) return { why: "date --set sets the clock" };
            if (abbrevOf(nm, "file")) return { why: "date --file reads a file" };
        } else if (w.charAt(0) === "-" && w.length > 1) {
            var c = cluster(w, "dfrsI");
            var last = c.letters.charAt(c.letters.length - 1);
            if (/s/.test(c.letters)) return { why: "date -s sets the clock" };
            if (/f/.test(c.letters)) return { why: "date -f reads a file" };
            if (c.takesNext && last !== "I") i++;
        }
    }
    return { why: "" };
}

function fileRule(args) {
    for (var i = 0; i < args.length; i++) {
        var w = args[i];
        if (w === "--") break;
        if (w.substring(0, 2) === "--") {
            if (abbrevOf(longName(w), "compile")) return { why: "file --compile writes a file" };
        } else if (w.charAt(0) === "-" && w.length > 1) {
            var c = cluster(w, "eFfmP");
            if (/C/.test(c.letters)) return { why: "file -C writes a file" };
            if (c.takesNext) i++;
        }
    }
    return { why: "" };
}

// grep: { why, recursive, files: [words], fileArgs: [words that name files] }
function grepRule(args) {
    var recursive = false;
    var patternGiven = false;
    var operands = [];
    var fileArgs = [];
    var ended = false;
    for (var i = 0; i < args.length; i++) {
        var w = args[i];
        if (!ended && w === "--") { ended = true; continue; }
        if (!ended && w.substring(0, 2) === "--") {
            var nm = longName(w);
            var hasEq = w.indexOf("=") >= 0;
            var val = hasEq ? w.substring(w.indexOf("=") + 1) : "";
            if (nm === "dereference-recursive") return { why: "grep -R follows every link" };
            if (nm === "recursive") recursive = true;
            if (nm === "regexp" || nm === "file") patternGiven = true;
            if (!hasEq && GREP_LONG_VAL[nm] === 1) { val = args[i + 1] === undefined ? "" : args[i + 1]; i++; }
            if (nm === "directories" && val === "recurse") recursive = true;
            if (nm === "devices" && val === "read") return { why: "grep --devices=read reads devices" };
            if ((nm === "file" || nm === "exclude-from") && val !== "") fileArgs.push(val);
            continue;
        }
        if (!ended && w.charAt(0) === "-" && w.length > 1) {
            for (var k = 1; k < w.length; k++) {
                var ch = w.charAt(k);
                if (ch === "R") return { why: "grep -R follows every link" };
                if (ch === "r") recursive = true;
                if (GREP_SHORT_VAL.indexOf(ch) >= 0) {
                    var v = k < w.length - 1 ? w.substring(k + 1) : (args[i + 1] === undefined ? "" : args[++i]);
                    if (ch === "e" || ch === "f") patternGiven = true;
                    if (ch === "f") fileArgs.push(v);
                    if (ch === "d" && v === "recurse") recursive = true;
                    if (ch === "D" && v === "read") return { why: "grep -D read reads devices" };
                    break;
                }
            }
            continue;
        }
        operands.push(w);
    }
    var files = patternGiven ? operands : operands.slice(1);
    if (!patternGiven && operands.length === 0) return { why: "grep with no pattern" };
    if (recursive && files.length === 0) files = ["."];
    return { why: "", recursive: recursive, files: files, fileArgs: fileArgs };
}

// ---- the check -------------------------------------------------------------

// check(line, o) -> { ok, why, argv, resolve, git, program }
//   o.home      $HOME
//   o.cwd       the directory it would run in (absolute)
//   o.resolved  null at the LEXICAL stage; then { word: realpath } from the
//               preflight, `cwd` beside the words (`o.realCwd`)
//   o.filters   the repository's own filter driver names (git only)
// At the lexical stage `ok` means "may run, once its paths are resolved":
// `resolve` lists the words to resolve and `git` asks for the filter list.
// At the final stage `ok` means it runs, and `argv` is what runs.
function check(line, o) {
    var opt = o || {};
    var home = String(opt.home || "");
    var cwd = String(opt.cwd || home || "/");
    var sp = split(line, home);
    if (!sp.ok) return refuse(sp.why);
    var words = sp.words;
    var prog = words[0];
    if (prog.quoted) return refuse("the program is quoted");
    if (ASSIGN_LIKE.test(prog.text)) return refuse("a variable assignment before the command");
    if (!has(PROGRAMS, prog.text)) return refuse("`" + prog.text + "` is not on the hands-free list");
    var name = prog.text;
    var args = [];
    for (var i = 1; i < words.length; i++) args.push(words[i].text);

    var cands = [];     // words naming paths, judged as paths
    var dirs = [];      // directories a recursive read walks
    var grepInfo = null;
    var rule = { why: "" };
    if (name === "git") {
        rule = gitRule(args);
        if (!rule.why) for (var g = 1; g < args.length; g++) cands = cands.concat(candidatesOf(args[g]));
    } else if (name === "grep") {
        grepInfo = grepRule(args);
        rule = grepInfo;
        if (!rule.why) {
            cands = grepInfo.files.concat(grepInfo.fileArgs);
            if (grepInfo.recursive) dirs = grepInfo.files.slice();
        }
    } else {
        if (name === "tail") rule = tailRule(args);
        else if (name === "date") rule = dateRule(args);
        else if (name === "file") rule = fileRule(args);
        if (!rule.why) for (var a = 0; a < args.length; a++) cands = cands.concat(candidatesOf(args[a]));
    }
    if (rule.why) return refuse(rule.why);

    // The directory itself: a command run inside a secret store reads it.
    var cwdSecret = secretOf(absPath(cwd, "/"), home);
    if (cwdSecret) return refuse("it would run inside " + shortHome(cwdSecret, home));
    // Every path, as written.
    for (var c = 0; c < cands.length; c++) {
        var sec = secretOf(absPath(cands[c], cwd), home);
        if (sec) return refuse(shortHome(sec, home) + " is a secret store");
    }
    for (var d = 0; d < dirs.length; d++) {
        var below = secretBelow(absPath(dirs[d], cwd), home);
        if (below) return refuse("a recursive search of " + shortHome(absPath(dirs[d], cwd), home) + " would read " + shortHome(below, home));
    }

    var resolve = cands.slice();
    if (!opt.resolved)
        return { ok: true, why: "", argv: [], resolve: resolve, git: name === "git", program: name };

    // ...and as the disk resolves it (links followed).
    var realCwd = String(opt.realCwd || cwd);
    var cwdSecret2 = secretOf(realCwd, home);
    if (cwdSecret2) return refuse("it would run inside " + shortHome(cwdSecret2, home));
    for (var r = 0; r < resolve.length; r++) {
        if (!has(opt.resolved, resolve[r])) return refuse("the path " + resolve[r] + " could not be resolved");
        var real = String(opt.resolved[resolve[r]]);
        var sec2 = secretOf(real, home);
        if (sec2) return refuse(resolve[r] + " leads into " + shortHome(sec2, home));
        if (dirs.indexOf(resolve[r]) >= 0) {
            var below2 = secretBelow(real, home);
            if (below2) return refuse("a recursive search of " + resolve[r] + " would read " + shortHome(below2, home));
        }
    }

    var argv;
    if (name === "git") {
        argv = ["git"].concat(GIT_SAFE_PREFIX);
        var fl = opt.filters || [];
        for (var f = 0; f < fl.length; f++) {
            if (!/^[A-Za-z0-9_.-]+$/.test(fl[f])) return refuse("the repository defines a filter this cannot switch off");
            argv.push("-c", "filter." + fl[f] + ".clean=", "-c", "filter." + fl[f] + ".smudge=", "-c", "filter." + fl[f] + ".process=");
        }
        argv.push(args[0]);
        if (has(GIT_DIFFS, args[0])) argv.push("--no-ext-diff", "--no-textconv");
        if (has(GIT_SUBMODULES, args[0])) argv.push("--ignore-submodules=all");
        argv = argv.concat(args.slice(1));
    } else if (name === "grep" && grepInfo.recursive) {
        argv = ["grep"].concat(GREP_EXCLUDES).concat(args);
    } else {
        argv = [name].concat(args);
    }
    return { ok: true, why: "", argv: argv, resolve: resolve, git: name === "git", program: name };
}

// The argv as a person reads it (single quotes where a word needs them).
function quoteArgv(argv) {
    var out = [];
    for (var i = 0; i < argv.length; i++) {
        var w = String(argv[i]);
        out.push(/^[A-Za-z0-9_.\/,:=+%@^-]+$/.test(w) ? w : "'" + w.replace(/'/g, "'\\''") + "'");
    }
    return out.join(" ");
}

// ---- the other tools in a spoken turn --------------------------------------

// Tools whose results bring nothing from the machine into the turn.
var CLEAN_TOOLS = { calculator: 1, web_search: 1 };

// toolVerdict(name, kind, norm, f) -> { mode: "free"|"ask", reason, extraGlobs }
// for every tool but run_command (which is `check()`), in a spoken turn.
//   f.home, f.cwd, f.resolved ({ path: realpath } from the preflight), f.tainted
function toolVerdict(name, kind, norm, f) {
    var home = String(f.home || "");
    var n = norm || {};
    if (kind !== "read") return { mode: "ask", reason: "spoken request: nothing that acts runs without your OK", extraGlobs: [] };
    if (name === "clipboard_read") return { mode: "ask", reason: "spoken request: the clipboard may hold a password", extraGlobs: [] };
    if (name === "screenshot") return { mode: "ask", reason: "spoken request: the screen may show something private", extraGlobs: [] };
    if (name === "web_search" && f.tainted)
        return { mode: "ask", reason: "this turn has read from your machine: a search could carry it off", extraGlobs: [] };
    if (name === "read_file" || name === "search_files") {
        var raw = n.path === undefined || n.path === null || String(n.path) === "" ? "~" : String(n.path);
        var p = raw === "~" ? home : (raw.indexOf("~/") === 0 ? home + raw.substring(1) : raw);
        var lex = absPath(p, f.cwd || home);
        var real = f.resolved && has(f.resolved, p) ? String(f.resolved[p]) : "";
        if (!real) return { mode: "ask", reason: "spoken request: the path could not be resolved", extraGlobs: [] };
        var walk = name === "search_files";
        var hit = walk ? (secretBelow(lex, home) || secretBelow(real, home)) : (secretOf(lex, home) || secretOf(real, home));
        if (hit) return { mode: "ask", reason: "spoken request: " + shortHome(hit, home) + " is a secret store", extraGlobs: [] };
        return { mode: "free", reason: "", extraGlobs: walk ? RG_EXCLUDES.slice() : [] };
    }
    return { mode: "free", reason: "", extraGlobs: [] };
}

// The path a reading tool's preflight must resolve ("" when it has none).
function pathArgOf(name, norm, home) {
    if (name !== "read_file" && name !== "search_files") return "";
    var raw = norm && norm.path !== undefined && norm.path !== null && String(norm.path) !== "" ? String(norm.path) : "~";
    return raw === "~" ? home : (raw.indexOf("~/") === 0 ? home + raw.substring(1) : raw);
}

// ---- the clipboard ---------------------------------------------------------

var FENCE_RE = /^\s*(```+|~~~+)\s*([A-Za-z0-9_+.#-]*)\s*$/;
var NOT_A_VALUE = /^(yes|no|ok|okay|sure|done|none|nothing|unknown|true|false)$/i;

function wordsIn(s) {
    var t = String(s).replace(/[*_#>`]+/g, " ").replace(/\s+/g, " ").trim();
    return t.length === 0 ? 0 : t.split(" ").length;
}

// copyOf(answer) -> { text, kind } | null -- what a spoken turn's final
// answer puts on the clipboard. Three shapes, each SHORT on everything else:
//   block   exactly one fenced code block, with at most 12 words around it
//           and no other code: the block's text (a one-line block loses a
//           leading `$ ` prompt)
//   span    one line with exactly one `inline code` span and at most 12
//           words around it: the span
//   value   one line with no code: a command line (lowercase program name,
//           an option word, no sentence end) or a value of at most 4 words
//           and 64 characters that has a digit, a path or no space at all
//           (not a bare yes / no / ok)
// Anything else -- prose, two blocks, a list -- only shows.
function copyOf(answer) {
    var s = String(answer === undefined || answer === null ? "" : answer).replace(/\r/g, "").replace(/^\s+|\s+$/g, "");
    if (s.length === 0) return null;
    var lines = s.split("\n");
    var blocks = [];
    var outside = [];
    for (var i = 0; i < lines.length; i++) {
        var m = FENCE_RE.exec(lines[i]);
        if (!m) { outside.push(lines[i]); continue; }
        var fence = m[1];
        var body = [];
        var j = i + 1;
        var closed = false;
        for (; j < lines.length; j++) {
            var e = /^\s*(```+|~~~+)\s*$/.exec(lines[j]);
            if (e && e[1].charAt(0) === fence.charAt(0) && e[1].length >= fence.length) { closed = true; break; }
            body.push(lines[j]);
        }
        if (!closed) return null;
        blocks.push(body.join("\n"));
        i = j;
    }
    if (blocks.length > 1) return null;
    if (blocks.length === 1) {
        var around = outside.join(" ");
        if (around.indexOf("`") >= 0 || wordsIn(around) > 12) return null;
        var t = blocks[0].replace(/^\n+|\s+$/g, "");
        if (t.indexOf("\n") < 0) t = t.replace(/^\$ /, "");
        if (t.length === 0 || t.length > 16384) return null;
        return { text: t, kind: "block" };
    }
    var nonEmpty = lines.filter(function (l) { return l.replace(/\s+/g, "").length > 0; });
    if (nonEmpty.length !== 1) return null;
    var line = nonEmpty[0].replace(/^\s+|\s+$/g, "");
    var spans = line.match(/`[^`]+`/g) || [];
    if (spans.length > 1) return null;
    if (spans.length === 1) {
        var rest = line.replace(spans[0], " ");
        if (rest.indexOf("`") >= 0 || wordsIn(rest) > 12) return null;
        var v = spans[0].substring(1, spans[0].length - 1).replace(/^\s+|\s+$/g, "");
        return v.length > 0 ? { text: v, kind: "span" } : null;
    }
    if (line.indexOf("`") >= 0) return null;
    var plain = line.replace(/^\*\*(.*)\*\*$/, "$1").replace(/^\*(.*)\*$/, "$1").replace(/^"(.*)"$/, "$1").replace(/^\s+|\s+$/g, "");
    var ws = plain.split(/\s+/);
    if (plain.length <= 200 && /^[a-z][a-z0-9._+-]*$/.test(ws[0]) && ws.length > 1 && !/[.!?:]$/.test(plain)) {
        for (var k = 1; k < ws.length; k++)
            if (ws[k].charAt(0) === "-" || ws[k] === "|") return { text: plain, kind: "command" };
    }
    var val = plain.replace(/\.$/, "");
    if (val.length === 0 || val.length > 64 || val.split(/\s+/).length > 4) return null;
    if (/[!?]$/.test(val) || NOT_A_VALUE.test(val)) return null;
    if (/\d/.test(val) || /^(\/|~\/)/.test(val) || !/\s/.test(val)) return { text: val, kind: "value" };
    return null;
}

// The first words of a copied text, for the toast.
function firstWords(text, maxWords, maxChars) {
    var t = String(text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
    var w = t.split(" ");
    var out = w.slice(0, maxWords || 8).join(" ");
    var cap = maxChars || 60;
    if (out.length > cap) out = out.substring(0, cap - 1) + "…";
    else if (w.length > (maxWords || 8)) out += " …";
    return out;
}

// A SPOKEN ANSWER'S TOAST BODY: the answer as plain lines, the first `maxLines` (4) of them, each at most `maxChars` (160) long,
// with the fence lines of a code block left out (the toast draws no code box, and "```" is noise). `more` says something was cut
// (a line, or the end of a long line), which is what the "Open chat" action is for. An answer with nothing to show gives "".
function toastBody(text, maxLines, maxChars) {
    var nl = maxLines || 4;
    var nc = maxChars || 160;
    var raw = String(text === undefined || text === null ? "" : text).replace(/\r/g, "").split("\n");
    var lines = [];
    for (var i = 0; i < raw.length; i++) {
        if (/^\s*(```+|~~~+)/.test(raw[i])) continue;
        var l = raw[i].replace(/\s+$/g, "");
        if (l.replace(/\s+/g, "").length === 0) {
            // one blank line between paragraphs is kept, none at the start or twice
            if (lines.length > 0 && lines[lines.length - 1] !== "") lines.push("");
            continue;
        }
        lines.push(l);
    }
    while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
    var more = lines.length > nl;
    var out = lines.slice(0, nl).map(function (l) {
        if (l.length <= nc) return l;
        more = true;
        return l.substring(0, nc - 1) + "…";
    });
    return { body: out.join("\n") + (more ? "\n…" : ""), more: more };
}
