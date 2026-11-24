#!/usr/bin/env node
// The hands-free allow-list of a spoken LLM request, table-tested (post-deploy round 5, stream LLMVOICE); and what llm.jsonc may change of
// it: `tools.ask` (LlmToolPolicy.stricter: stricter only) and whose machine `server.url` is (LlmServerUrl).
// modules/bar/llm/components/LlmVoicePolicy.js is a `.pragma library` file with no Qt in it: the loader strips the pragma and
// evals the rest (the osd_js_cases.js pattern). The table is the security boundary's specification: every injection shape below
// must be REFUSED (it goes to the confirmation), every plain read ALLOWED, and every allowed line must split into exactly the
// words bash itself makes of it (the oracle: `bash -c 'set -- <line>; printf "%s\0" "$@"'` under the same HOME).
//
//   node tools/dev/llm_voice_cases.js          must end LLM-VOICE-CASES RESULT PASS
//   node tools/dev/llm_voice_cases.js --arms   the clean run passes AND every ARM below turns it red -> LLM-VOICE-CASES ARMS PASS
//
// ARMs, each patching ONE rule in the loaded COPY (a string replace on the source before eval; the file is never touched):
//   ARM=metachar   `; & | $ ( ) < > \` and backtick are let through inside quotes (the anywhere check off)
//   ARM=glob       any character is accepted outside quotes (globs, braces, `#`, `!`)
//   ARM=gitc       git's `-c name=value` before the verb is skipped instead of refused
//   ARM=tilde      a `~` after the `=` of an assignment-like word is taken literally (bash expands it)
//   ARM=secret     no path is a secret store
//   ARM=resolved   the preflight's resolved paths are not checked (a symlink into ~/.ssh passes)
//   ARM=taint      a web search runs free after the turn read from the machine
//   ARM=copyprose  a fenced block with a paragraph around it is copied
//   ARM=freeread   `tools.ask` lets a read run free all the same
//   ARM=freeact    `tools.ask` turns a refusal into an ask
//   ARM=anyhost    every server is this machine's
//   ARM=noexpand   a leading `~/` is left as written (the bash oracle must see the split differ from bash's)
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const cp = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const DIR = path.join(ROOT, "modules", "bar", "llm", "components");
const HOME = "/home/u";
const REPO = "/home/u/proj";

const ARMS = {
    metachar: ["if (BAD_ANYWHERE.indexOf(s.charAt(k)) >= 0)", "if (false)"],
    glob: ["if (!UNQUOTED_OK.test(c)) return", "if (false) return"],
    gitc: ["    if (verb.charAt(0) === \"-\") return { why: \"git \" + verb + \" changes how git runs\" };",
           "    while (verb === \"-c\" && args.length > 2) { args = args.slice(2); verb = args[0]; }"],
    tilde: ["} else if (tildeAt > 0 && ASSIGN_LIKE.test(t)) {", "} else if (false) {"],
    secret: ["function secretOf(abs, home) {\n", "function secretOf(abs, home) {\n    return \"\";\n"],
    resolved: ["        var sec2 = secretOf(real, home);", "        var sec2 = \"\";"],
    taint: ["if (name === \"web_search\" && f.tainted)", "if (false)"],
    copyprose: ["if (around.indexOf(\"`\") >= 0 || wordsIn(around) > 12) return null;", "if (around.indexOf(\"`\") >= 0) return null;"],
    toastfence: ["        if (/^\\s*(```+|~~~+)/.test(raw[i])) continue;", "        if (false) continue;"],
    noexpand: ["                t = home + t.substring(1);", "                t = t;"],
    freeread: ["    if (out.mode !== \"ask\") out.reason", "    if (out.mode === \"free\") return out;\n    if (out.mode !== \"ask\") out.reason", "LlmToolPolicy.js"],
    freeact: [" || out.mode === \"refused\") return out;", ") return out;", "LlmToolPolicy.js"],
    anyhost: ["    return h === \"localhost\"", "    return true || h === \"localhost\"", "LlmServerUrl.js"],
};

function load(arm, file) {
    let src = fs.readFileSync(path.join(DIR, file), "utf8").replace(/^\.pragma library\s*/, "").replace(/^\.import .*$/mg, "");
    if (arm && (ARMS[arm][2] || "LlmVoicePolicy.js") === file) {
        const [from, to] = ARMS[arm];
        if (src.split(from).length !== 2) { console.log("ARM " + arm + ": anchor gone -- it proves nothing"); process.exit(2); }
        src = src.replace(from, to);
    }
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src, ctx, { filename: file });
    return ctx;
}

// ---- the table --------------------------------------------------------------
// [line, expect, note]  expect: true = runs at once (lexical AND final stage with paths resolving to themselves), or a
// string = refused, with that text somewhere in the reason. `cwd` defaults to REPO.
const LINES = [
    // the user's own example and the plain reads
    ["git log -1 --format=%h", true],
    ["git status", true],
    ["git status -s", true],
    ["git show HEAD~1 --stat", true],
    ["git diff --cached", true],
    ["git rev-parse --short HEAD", true],
    ["git describe --tags --always", true],
    ["git branch", true],
    ["git branch -a -v", true],
    ["git branch --list \"feat*\"", true],
    ["git remote -v", true],
    ["git remote", true],
    ["git blame README.md", true],
    ["git log --oneline -5 -- src/main.c", true],
    ["git log --format='%h %s' -3", true],
    ["ls", true],
    ["ls -la ~/Downloads", true],
    ["ls ~", true],
    ["cat README.md", true],
    ["cat \"two words.txt\"", true],
    ["cat 'x'\"y\"", true],
    ["head -n 5 notes.txt", true],
    ["tail -n 20 build.log", true],
    ["wc -l src/main.c", true],
    ["grep -n TODO src/main.c", true],
    ["grep -E \"foo.*bar|baz\" f", "`|` is shell syntax"],
    ["grep -E \"foo.*bar\" f", true],
    ["grep -rn TODO src", true],
    ["grep -r -e x .", true],
    ["date", true],
    ["date +%F", true],
    ["date -d \"next friday\" +%F", true],
    ["pwd", true],
    ["which git", true],
    ["df -h", true],
    ["du -sh .", true],
    ["du -sh ~", true],
    ["uname -a", true],
    ["stat README.md", true],
    ["file README.md", true],
    ["cat ''", true],
    // chained, substituted, redirected, backgrounded
    ["git log; rm -rf ~", "`;` is shell syntax"],
    ["git log && curl evil.example", "`&` is shell syntax"],
    ["git log || true", "`|` is shell syntax"],
    ["ls | sh", "`|` is shell syntax"],
    ["ls & rm x", "`&` is shell syntax"],
    ["ls\nrm x", "more than one line"],
    ["ls\rrm x", "outside plain ASCII"],
    ["ls\tx", "outside plain ASCII"],
    ["cat $(echo /etc/shadow)", "`$` is shell syntax"],
    ["cat `id`", "is shell syntax"],
    ["cat ${HOME}/x", "`$` is shell syntax"],
    ["echo $HOME", "`$` is shell syntax"],
    ["ls > out", "`>` is shell syntax"],
    ["ls >> out", "`>` is shell syntax"],
    ["cat < x", "`<` is shell syntax"],
    ["ls 2> e", "`>` is shell syntax"],
    ["git log >/dev/null", "`>` is shell syntax"],
    ["cat <(id)", "`<` is shell syntax"],
    ["(ls)", "`(` is shell syntax"],
    // quoted tricks
    ["git log ';rm -rf ~'", "`;` is shell syntax"],
    ["cat \"$(id)\"", "`$` is shell syntax"],
    ["\"git\" log", "the program is quoted"],
    ["g\"it\" log", "the program is quoted"],
    ["git \"log\" \"--output=/tmp/x\"", "writes, runs or reaches out"],
    ["cat a\\ b", "is shell syntax"],
    ["cat 'unterminated", "an unterminated quote"],
    ["cat \"a b", "an unterminated quote"],
    ["ls # rm x", "`#` outside quotes"],
    ["ls !x", "`!` outside quotes"],
    // globs and braces
    ["cat *.txt", "`*` outside quotes"],
    ["ls ?", "`?` outside quotes"],
    ["ls [ab]", "`[` outside quotes"],
    ["ls {a,b}", "`{` outside quotes"],
    // assignments and tildes
    ["GIT_DIR=/tmp/x git log", "a variable assignment before the command"],
    ["FOO=1 ls", "a variable assignment before the command"],
    ["PATH=/tmp ls", "a variable assignment before the command"],
    ["cat ~root/.bashrc", "would be expanded by the shell"],
    ["cat ~+/x", "would be expanded by the shell"],
    ["cat ~-/x", "would be expanded by the shell"],
    ["ls x=~/y", "a `~` after `=` would be expanded"],
    ["ls x=a:~/y", "a `~` after `=` would be expanded"],
    ["cat ~/notes.txt", true],
    ["git show HEAD~2:README.md", true],
    ["ls --file=~/x", true],
    // git that writes, runs or reaches out
    ["git -c core.pager=sh log", "changes how git runs"],
    ["git -c alias.x=!sh x", "outside quotes"],
    ["git -c alias.x=sh x", "changes how git runs"],
    ["git --exec-path=/tmp log", "changes how git runs"],
    ["git -C /tmp log", "changes how git runs"],
    ["git --git-dir=/tmp/x log", "changes how git runs"],
    ["git --no-pager log", "changes how git runs"],
    ["git log --output=/tmp/x", "writes, runs or reaches out"],
    ["git log --outp=/tmp/x", "writes, runs or reaches out"],
    ["git diff --ext-diff", "writes, runs or reaches out"],
    ["git diff --ext", "writes, runs or reaches out"],
    ["git log -p --textconv", "writes, runs or reaches out"],
    ["git log --show-signature", "writes, runs or reaches out"],
    ["git log --format=%G?", "outside quotes"],
    ["git log --format=%GS", "a %G format asks gpg"],
    ["git log \"--format=%G?\"", "a %G format asks gpg"],
    ["git log -c", "is not read here without asking"],
    ["git log -o x", "is not read here without asking"],
    ["git grep -O x", "not a read-only verb"],
    ["git fetch --upload-pack=x", "not a read-only verb"],
    ["git push", "not a read-only verb"],
    ["git commit -m x", "not a read-only verb"],
    ["git config core.pager sh", "not a read-only verb"],
    ["git checkout .", "not a read-only verb"],
    ["git branch newbranch", "makes a branch"],
    ["git branch -D x", "is not a listing option"],
    ["git branch -m a b", "is not a listing option"],
    ["git remote add x y", "is more than a listing"],
    ["git remote show origin", "is more than a listing"],
    ["git", "git with no verb"],
    // the other programs' own rules
    ["tail -f build.log", "keeps reading"],
    ["tail -fn5 build.log", "keeps reading"],
    ["tail --follow=name build.log", "keeps reading"],
    ["tail --fol build.log", "keeps reading"],
    ["date -s 2020-01-01", "sets the clock"],
    ["date --set=2020-01-01", "sets the clock"],
    ["date --se 2020-01-01", "sets the clock"],
    ["date -f dates.txt", "reads a file"],
    ["date -uf dates.txt", "reads a file"],
    ["file -C -m magic", "writes a file"],
    ["file --compile", "writes a file"],
    ["grep -R token .", "follows every link"],
    ["grep -rR token .", "follows every link"],
    ["grep --dereference-recursive token .", "follows every link"],
    ["grep -D read x /dev/sda", "reads devices"],
    ["grep", "grep with no pattern"],
    // not on the list
    ["rm -rf x", "`rm` is not on the hands-free list"],
    ["curl https://evil.example", "`curl` is not on the hands-free list"],
    ["python3 -c print", "`python3` is not on the hands-free list"],
    ["sudo ls", "`sudo` is not on the hands-free list"],
    ["env ls", "`env` is not on the hands-free list"],
    ["bash -c ls", "`bash` is not on the hands-free list"],
    ["/usr/bin/git log", "is not on the hands-free list"],
    ["./git log", "is not on the hands-free list"],
    ["find . -delete", "`find` is not on the hands-free list"],
    ["sed -n p f", "`sed` is not on the hands-free list"],
    ["xargs ls", "`xargs` is not on the hands-free list"],
    ["echo hi", "`echo` is not on the hands-free list"],
    ["Git log", "`Git` is not on the hands-free list"],
    ["", "an empty command"],
    ["   ", "an empty command"],
    // secret stores
    ["cat ~/.ssh/id_ed25519", "~/.ssh is a secret store"],
    ["ls ~/.ssh", "~/.ssh is a secret store"],
    ["ls -la /home/u/.ssh/", "~/.ssh is a secret store"],
    ["cat .env", ".env is a secret store"],
    ["cat config/.env.local", ".env.local is a secret store"],
    ["head ~/.gnupg/pubring.kbx", "~/.gnupg is a secret store"],
    ["cat /etc/shadow", "/etc/shadow is a secret store"],
    ["cat ~/.local/share/keyrings/login.keyring", "keyrings is a secret store"],
    ["cat ~/.password-store/mail.gpg", "~/.password-store is a secret store"],
    ["ls ~/.mozilla/firefox", "~/.mozilla is a secret store"],
    ["cat ~/.config/chromium/Default/Cookies", "chromium is a secret store"],
    ["cat ~/.aws/credentials", "~/.aws is a secret store"],
    ["cat /proc/self/environ", "/proc/self/environ is a secret store"],
    ["cat ../.ssh/id_rsa", "~/.ssh is a secret store"],
    ["cat ../../u/.ssh/id_rsa", "~/.ssh is a secret store"],
    ["cat server.pem", "server.pem is a secret store"],
    ["git show HEAD:.env", ".env is a secret store"],
    ["git show HEAD:config/.env", ".env is a secret store"],
    ["grep -f ~/.ssh/id_rsa notes.txt", "~/.ssh is a secret store"],
    ["grep --file=/home/u/.ssh/id_rsa notes.txt", "~/.ssh is a secret store"],
    ["grep -r token ~", "would read ~/.ssh"],
    ["grep -r token /", "would read /etc/shadow"],
    ["grep -r token /home", "would read ~/.ssh"],
    ["grep -r token ~/.config", "would read ~/.config/google-chrome"],
    ["grep -r token /proc", "would read /proc/*/environ"],
    ["grep -r KEY ~/.local/state/lares/llm", "~/.local/state/lares is a secret store"],
    ["wc -l ~/.local/state/lares/llm/conversations.json", "~/.local/state/lares is a secret store"],
    ["date -r ~/.ssh/id_rsa", "~/.ssh is a secret store"],
    ["du --files0-from=/home/u/.ssh/x", "~/.ssh is a secret store"],
    // look-alikes and controls
    ["cat ~/.\u0455sh/id", "outside plain ASCII (U+0455)"],
    ["g\u0456t log", "outside plain ASCII (U+0456)"],
    ["ls \u202e", "outside plain ASCII (U+202E)"],
    ["ls\uff1brm x", "outside plain ASCII (U+FF1B)"],
    ["ls\u037erm x", "outside plain ASCII (U+037E)"],
    ["ls\u00a0-la", "outside plain ASCII (U+00A0)"],
    ["git log\u200b", "outside plain ASCII (U+200B)"],
    ["cat x\u0000y", "outside plain ASCII (U+0000)"],
];

// Lines judged with a cwd other than REPO, or with the disk resolving a word somewhere else.
const SPECIAL = [
    { line: "grep -r token .", cwd: HOME, expect: "would read ~/.ssh" },
    { line: "ls", cwd: HOME + "/.ssh", expect: "it would run inside ~/.ssh" },
    { line: "cat id_rsa", cwd: HOME + "/.ssh/keys", expect: "it would run inside ~/.ssh" },
    { line: "cat notes", resolved: { notes: HOME + "/.ssh/id_rsa" }, expect: "notes leads into ~/.ssh" },
    { line: "grep -r x src", resolved: { src: HOME }, expect: "a recursive search of src would read ~/.ssh" },
    { line: "ls", realCwd: HOME + "/.gnupg", expect: "it would run inside ~/.gnupg" },
    { line: "cat README.md", resolved: {}, expect: "could not be resolved" },
    { line: "git log", filters: ["evil", "lfs"], argv: ["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false",
        "-c", "filter.evil.clean=", "-c", "filter.evil.smudge=", "-c", "filter.evil.process=",
        "-c", "filter.lfs.clean=", "-c", "filter.lfs.smudge=", "-c", "filter.lfs.process=",
        "log", "--no-ext-diff", "--no-textconv"] },
    { line: "git log", filters: ["a b"], expect: "a filter this cannot switch off" },
    { line: "git log -1 --format=%h", argv: ["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", "log", "--no-ext-diff", "--no-textconv", "-1", "--format=%h"] },
    { line: "git status -s", argv: ["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", "status", "--ignore-submodules=all", "-s"] },
    { line: "git rev-parse HEAD", argv: ["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", "rev-parse", "HEAD"] },
    { line: "cat ~/notes.txt", argv: ["cat", HOME + "/notes.txt"] },
    { line: "grep -rn TODO src", argvHas: ["--exclude=.env", "--exclude-dir=.ssh", "-rn", "TODO", "src"] },
];

// toolVerdict: [name, kind, norm, facts, expectMode, reasonPart]
const TOOLS = [
    ["read_file", "read", { path: "~/.ssh/id_rsa" }, {}, "ask", "~/.ssh is a secret store"],
    ["read_file", "read", { path: "/etc/shadow" }, {}, "ask", "/etc/shadow is a secret store"],
    ["read_file", "read", { path: "~/notes.txt" }, {}, "free", ""],
    ["read_file", "read", { path: "README.md" }, {}, "free", ""],
    ["read_file", "read", { path: "~/notes.txt" }, { resolvedTo: HOME + "/.gnupg/x" }, "ask", "~/.gnupg is a secret store"],
    ["read_file", "read", { path: "~/notes.txt" }, { unresolved: true }, "ask", "could not be resolved"],
    ["search_files", "read", { pattern: "x" }, {}, "ask", "is a secret store"],
    ["search_files", "read", { pattern: "x", path: "~" }, {}, "ask", "is a secret store"],
    ["search_files", "read", { pattern: "x", path: "~/proj" }, {}, "free", ""],
    ["search_files", "read", { pattern: "x", path: "/" }, {}, "ask", "is a secret store"],
    ["clipboard_read", "read", {}, {}, "ask", "may hold a password"],
    ["screenshot", "read", { mode: "full" }, {}, "ask", "may show something private"],
    ["web_search", "read", { query: "x" }, {}, "free", ""],
    ["web_search", "read", { query: "x" }, { tainted: true }, "ask", "could carry it off"],
    ["calculator", "read", { expression: "1+1" }, { tainted: true }, "free", ""],
    ["system_facts", "read", {}, { tainted: true }, "free", ""],
    ["notify", "act", { title: "x" }, {}, "ask", "nothing that acts runs"],
    ["fetch_url", "act", { url: "https://x.example" }, {}, "ask", "nothing that acts runs"],
    ["write_file", "act", { path: "/tmp/x", content: "y" }, {}, "ask", "nothing that acts runs"],
    ["clipboard_write", "act", { text: "y" }, {}, "ask", "nothing that acts runs"],
];

// copyOf: [answer, expected text or null]
// [url, this machine's (its name is "desktop"), what is asked when that differs]
const SERVERS = [
    ["http://localhost:11434", true], ["http://LOCALHOST", true], ["http://127.0.0.1:11434/", true, "http://127.0.0.1:11434"], ["http://127.8.9.1", true],
    ["http://[::1]:11434", true], ["http://0.0.0.0:11434", true], ["http://ollama.localhost", true],
    ["http://desktop:11434", true], ["http://Desktop.local:11434/v1/", true, "http://Desktop.local:11434/v1"],
    ["http://laptop:11434", false], ["https://api.example.com", false], ["http://192.168.1.20:11434", false], ["http://[fe80::1]:11434", false],
    ["http://localhost.example.com", false], ["http://desktop.example.com", false], ["http://127.0.0.1.example.com", false],
    ["http://user:pass@laptop:11434", false, "http://laptop:11434"], ["http://localhost@laptop:11434", false, "http://laptop:11434"],
    ["http://laptop/?x=localhost", false], ["http://laptop#localhost", false], ["", false],
];
const COPIES = [
    ["```\nabc1234\n```", "abc1234"],
    ["```sh\ngit log -1 --format=%h\n```", "git log -1 --format=%h"],
    ["The latest commit:\n\n```\nabc1234\n```", "abc1234"],
    ["```\n$ git status\n```", "git status"],
    ["```bash\nfor f in *; do echo $f; done\n```", "for f in *; do echo $f; done"],
    ["`abc1234`", "abc1234"],
    ["The latest commit is `abc1234`.", "abc1234"],
    ["abc1234", "abc1234"],
    ["**abc1234**", "abc1234"],
    ["192.168.1.12", "192.168.1.12"],
    ["3.7 GiB", "3.7 GiB"],
    ["/home/user/x", "/home/user/x"],
    ["Paris", "Paris"],
    ["git log -1 --format=%h", "git log -1 --format=%h"],
    ["ls -la | wc -l", "ls -la | wc -l"],
    ["The latest commit is abc1234, made yesterday by you.", null],
    ["Use git log to see it.", null],
    ["```\na\n```\n\n```\nb\n```", null],
    ["Here is a command that lists the files in the folder you named and sorts them by size, largest first:\n```\nls -S\n```", null],
    ["Run `git status` and then `git log`.", null],
    ["- one\n- two", null],
    ["First line\nsecond line", null],
    ["Yes.", null],
    ["Sure!", null],
    ["I don't know.", null],
    ["```\nunterminated", null],
    ["", null],
];

// toastBody: [answer, expected body, expected more]
const BODIES = [
    ["```\nabc1234\n```", "abc1234", false],
    ["The latest commit:\n\n```\nabc1234\n```", "The latest commit:\n\nabc1234", false],
    ["one\ntwo\nthree\nfour", "one\ntwo\nthree\nfour", false],
    ["one\ntwo\nthree\nfour\nfive", "one\ntwo\nthree\nfour\n\u2026", true],
    ["a\n\n\n\nb", "a\n\nb", false],
    ["", "", false],
    ["```\n```", "", false],
    ["x".repeat(200), "x".repeat(159) + "\u2026\n\u2026", true],
];

// ---- the runner -------------------------------------------------------------

function bashWords(line) {
    const r = cp.spawnSync("bash", ["--norc", "--noprofile", "-c", "set -- " + line + "; printf '%s\\0' \"$@\""],
                           { env: { HOME: HOME, PATH: process.env.PATH, LC_ALL: "C" }, encoding: "utf8" });
    if (r.status !== 0) return null;
    const parts = r.stdout.split("\0");
    parts.pop();
    return parts;
}

function run(arm, quiet) {
    const P = load(arm, "LlmVoicePolicy.js"), ASK = load(arm, "LlmToolPolicy.js"), URL_ = load(arm, "LlmServerUrl.js");
    const fails = [];
    const fail = (m) => fails.push(m);
    const finalStage = (line, o) => {
        const lex = P.check(line, { home: HOME, cwd: o.cwd || REPO });
        if (!lex.ok) return lex;
        const resolved = {};
        for (const w of lex.resolve) resolved[w] = o.resolved && w in o.resolved ? o.resolved[w] : (w.charAt(0) === "/" ? w : (o.cwd || REPO) + "/" + w);
        if (o.resolved && Object.keys(o.resolved).length === 0) for (const k in resolved) delete resolved[k];
        return P.check(line, { home: HOME, cwd: o.cwd || REPO, realCwd: o.realCwd || o.cwd || REPO,
                               resolved: resolved, filters: o.filters || [] });
    };
    let oracle = 0;
    for (const [line, expect] of LINES) {
        const v = finalStage(line, {});
        if (expect === true) {
            if (!v.ok) { fail("ALLOW " + JSON.stringify(line) + " refused: " + v.why); continue; }
            const sp = P.split(line, HOME);
            const mine = sp.words.map(w => w.text);
            const theirs = bashWords(line);
            oracle++;
            if (theirs === null || JSON.stringify(mine) !== JSON.stringify(theirs))
                fail("ORACLE " + JSON.stringify(line) + " splits " + JSON.stringify(mine) + ", bash " + JSON.stringify(theirs));
        } else {
            if (v.ok) fail("REFUSE " + JSON.stringify(line) + " ran: " + JSON.stringify(v.argv));
            else if (v.why.indexOf(expect) < 0) fail("REASON " + JSON.stringify(line) + " said " + JSON.stringify(v.why) + ", wanted " + JSON.stringify(expect));
        }
    }
    for (const c of SPECIAL) {
        const v = finalStage(c.line, c);
        if (c.expect) {
            if (v.ok) fail("REFUSE* " + JSON.stringify(c.line) + " ran: " + JSON.stringify(v.argv));
            else if (v.why.indexOf(c.expect) < 0) fail("REASON* " + JSON.stringify(c.line) + " said " + JSON.stringify(v.why) + ", wanted " + JSON.stringify(c.expect));
        } else if (!v.ok) {
            fail("ALLOW* " + JSON.stringify(c.line) + " refused: " + v.why);
        } else if (c.argv && JSON.stringify(v.argv) !== JSON.stringify(c.argv)) {
            fail("ARGV " + JSON.stringify(c.line) + " -> " + JSON.stringify(v.argv));
        } else if (c.argvHas) {
            for (const w of c.argvHas) if (v.argv.indexOf(w) < 0) fail("ARGV " + JSON.stringify(c.line) + " lacks " + w + ": " + JSON.stringify(v.argv));
        }
    }
    for (const [name, kind, norm, f, mode, part] of TOOLS) {
        const p = P.pathArgOf(name, norm, HOME);
        const resolved = {};
        if (p && !f.unresolved) resolved[p] = f.resolvedTo || (p.charAt(0) === "/" ? p : REPO + "/" + p);
        const v = P.toolVerdict(name, kind, norm, { home: HOME, cwd: REPO, resolved: resolved, tainted: !!f.tainted });
        if (v.mode !== mode) fail("TOOL " + name + " " + JSON.stringify(norm) + " " + JSON.stringify(f) + " -> " + v.mode + " (" + v.reason + "), wanted " + mode);
        else if (part && v.reason.indexOf(part) < 0) fail("TOOLWHY " + name + " said " + JSON.stringify(v.reason) + ", wanted " + JSON.stringify(part));
        if (name === "search_files" && v.mode === "free" && v.extraGlobs.indexOf("!.env") < 0) fail("TOOLGLOB search_files ran without the secret globs");
    }
    // llm.jsonc: every decision of the table again with its tool in `tools.ask`: nothing runs, a refusal stands, nothing is grantable
    for (const [name, kind, norm, f] of TOOLS) {
        const p = P.pathArgOf(name, norm, HOME);
        const resolved = {};
        if (p && !f.unresolved) resolved[p] = f.resolvedTo || (p.charAt(0) === "/" ? p : REPO + "/" + p);
        const facts = { home: HOME, cwd: REPO, resolved: resolved, tainted: !!f.tainted };
        const was = P.toolVerdict(name, kind, norm, facts).mode;
        const now = ASK.stricter(Object.assign({ grantable: true, grantKeys: ["k"] }, P.toolVerdict(name, kind, norm, facts)), [name], name);
        if (now.mode !== (was === "refused" ? "refused" : "ask") || (now.mode === "ask" && (now.grantable || now.grantKeys.length > 0)))
            fail("ASK " + name + " " + JSON.stringify(norm) + ": " + was + " -> " + now.mode);
    }
    for (const mode of ["free", "auto", "granted", "ask", "refused"]) {
        const d = () => ({ mode: mode, grantable: true, grantKeys: ["k"], grantLabel: "l", reason: "r" });
        const on = ASK.stricter(d(), ["other", "x"], "x"), off = ASK.stricter(d(), ["other"], "x"), none = ASK.stricter(d(), [], "x");
        if (on.mode !== (mode === "refused" ? "refused" : "ask")) fail("ASK a listed tool that was " + mode + " is " + on.mode);
        if (off.mode !== mode || none.mode !== mode || !off.grantable) fail("ASK a tool that is not listed moved: " + mode + " -> " + off.mode);
    }
    for (const [url, local, clean] of SERVERS) {
        if (URL_.isLocal(url, "Desktop\n") !== local) fail("SERVER " + url + " is " + (local ? "" : "not ") + "this machine's");
        if (URL_.clean(url) !== (clean || url)) fail("SERVER " + url + " is asked as " + URL_.clean(url));
    }
    for (const [answer, want] of COPIES) {
        const c = P.copyOf(answer);
        const got = c ? c.text : null;
        if (got !== want) fail("COPY " + JSON.stringify(answer) + " -> " + JSON.stringify(got) + ", wanted " + JSON.stringify(want));
    }
    for (const [answer, body, more] of BODIES) {
        const t = P.toastBody(answer);
        if (t.body !== body || t.more !== more) fail("BODY " + JSON.stringify(answer.substring(0, 40)) + " -> " + JSON.stringify(t) + ", wanted " + JSON.stringify([body, more]));
    }
    if (!quiet) {
        for (const m of fails) console.log("  " + m);
        console.log("lines " + LINES.length + " + " + SPECIAL.length + ", tools " + TOOLS.length + ", copies " + COPIES.length + ", bodies " + BODIES.length
                    + ", bash oracle " + oracle + " lines, " + fails.length + " failure(s)");
    }
    return fails;
}

const argv = process.argv.slice(2);
if (argv.indexOf("--arms") >= 0) {
    const clean = run(null, false);
    if (clean.length > 0) { console.log("LLM-VOICE-CASES ARMS FAIL (the clean run is red)"); process.exit(1); }
    let ok = true;
    for (const arm of Object.keys(ARMS)) {
        const f = run(arm, true);
        console.log("ARM " + arm + ": " + (f.length > 0 ? "red as it must (" + f.length + "): " + f[0] : "STILL GREEN -- toothless"));
        if (f.length === 0) ok = false;
    }
    console.log("LLM-VOICE-CASES ARMS " + (ok ? "PASS" : "FAIL"));
    process.exit(ok ? 0 : 1);
}
const only = process.env.ARM || "";
const f = run(only || null, false);
console.log("LLM-VOICE-CASES RESULT " + (f.length === 0 ? "PASS" : "FAIL") + (only ? " (ARM=" + only + ")" : ""));
process.exit(f.length === 0 ? 0 : 1);
