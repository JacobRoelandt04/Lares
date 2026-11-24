#!/usr/bin/env node
// config_spec_check.js -- the specs (modules/common/config/specs), the examples (.examples/*.jsonc) and the schemas say the same.
//
//   node tools/dev/config_spec_check.js            CONFIG_SPEC RESULT PASS | FAIL
//   ARM=<arm> node tools/dev/config_spec_check.js  the fault below is made in memory: must FAIL on it (CONFIG_SPEC ARMS RESULT PASS)
//       default   a spec's default is changed                      "is 9 in the example, 10 in the spec"
//       newkey    a spec has a key the example does not name       "is not in the example"
//       extra     an example has a key no spec has                 "is not a key"
//       list      a list item is not checked                       (the cases)
//       line      the lines are counted from 0                     (the cases)
//       python    `lares config` forgets the ranges                (the cases, Python's side)
//       secret    `lares config set` prints a secret's value        "a secret is printed" (5)
//   ARM=all runs them all.
//
// What is held: (1) every example is right by its own spec and writes every default the spec has (and no other value), and names in words
// every key that has no default; (2) every example has a spec and every spec an example; (3) the schemas and .vscode/settings.json are
// fresh; (4) the cases of tools/dev/fixtures/config_cases.json come out the same in ConfigCheck.js (the shell) and in
// tools/shell/lares-config-check.py (`lares config`), line by line.
var fs = require("fs"), path = require("path"), cp = require("child_process");
var ARM = process.env.ARM || "";
if (ARM === "all") {
    var bad = [];
    ["default", "newkey", "extra", "list", "line", "python", "secret"].forEach(function (a) {
        var r = cp.spawnSync(process.execPath, [__filename], { env: Object.assign({}, process.env, { ARM: a }), encoding: "utf8" });
        if (r.status !== 0) bad.push(a);
        process.stdout.write(r.stdout);
    });
    console.log("CONFIG_SPEC ARMS RESULT " + (bad.length ? "FAIL (" + bad.join(", ") + " did not bite)" : "PASS"));
    process.exit(bad.length ? 1 : 0);
}
var C = require("./config_node.js"), Check = C.Check;
var out = [], checks = 0;
function eq(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
function sorted(v) {
    if (Array.isArray(v)) return v.map(sorted);
    if (v !== null && typeof v === "object") { var o = {}; Object.keys(v).sort().forEach(function (k) { o[k] = sorted(v[k]); }); return o; }
    return v;
}
function bad(say) { out.push(say); }

if (ARM === "default") C.specs.breaks.durationMin = ["num", 51, 1, 600];
if (ARM === "newkey") C.specs.breaks.zebra = ["bool", true];

function walk(name, text, node, have, p) {
    if (Check.isGroup(node)) {
        Object.keys(node).forEach(function (k) { walk(name, text, node[k], have !== null && typeof have === "object" ? have[k] : undefined, p.concat([k])); });
        return;
    }
    var o = Check.opts(node), say = name + ".jsonc: " + Check.pathWords(p);
    checks++;
    if (o.hidden) return;
    if (node[1] === undefined) {
        var key = p[p.length - 1];
        if (have === undefined && text.indexOf('"' + key + '"') < 0)
            bad(say + " has no default and is not named in the example");
        return;
    }
    if (o.sample) { if (have === undefined) bad(say + " is not in the example (a sample)"); return; }
    if (have === undefined) { bad(say + " is not in the example"); return; }
    if (!eq(sorted(have), sorted(node[1]))) bad(say + " is " + JSON.stringify(have) + " in the example, " + JSON.stringify(node[1]) + " in the spec");
}

var examples = fs.readdirSync(path.join(C.ROOT, ".examples")).filter(function (f) { return /\.jsonc$/.test(f); }).map(function (f) { return f.replace(/\.jsonc$/, ""); });
examples.forEach(function (n) { if (!C.specs[n]) bad(".examples/" + n + ".jsonc has no spec"); });
Object.keys(C.specs).forEach(function (n) {
    if (examples.indexOf(n) < 0) { bad("specs/" + n + ".js has no example"); return; }
    var text = C.exampleText(n);
    if (ARM === "extra" && n === "breaks") text = text.replace('"enabled": true', '"enabled": true, "zebra": 1');
    Check.mistakes(C.specs[n], text, C.locate).forEach(function (m) { bad(n + ".jsonc (the example) " + m); });
    var r = Check.parse(text, C.locate);
    if (!r.error) walk(n, text, C.specs[n], r.value, []);
});

// ConfigSpecs.js (what the shell's ConfigWatch looks in) has every spec
var listed = fs.readFileSync(path.join(C.ROOT, "modules/common/config/ConfigSpecs.js"), "utf8");
Object.keys(C.specs).forEach(function (n) {
    checks++;
    if (listed.indexOf('"specs/' + n + '.js"') < 0 || listed.indexOf('"' + n + '": ') < 0) bad("ConfigSpecs.js does not have " + n);
});

// the cases, both sides
var cases = JSON.parse(fs.readFileSync(path.join(C.ROOT, "tools/dev/fixtures/config_cases.json"), "utf8"));
cases.forEach(function (c) {
    checks++;
    var text = c.text.join("\n"), spec = C.specs[c.file];
    var got = Check.mistakes(spec, text, C.locate);
    if (ARM === "line") got = got.map(function (l) { return l.replace(/^line (\d+)/, function (m, d) { return "line " + (d - 1); }); });
    if (ARM === "list") got = got.filter(function (l) { return !/\[\d+\]/.test(l); });
    if (!eq(got, c.want)) bad("case " + c.name + " (the shell): " + JSON.stringify(got) + " instead of " + JSON.stringify(c.want));
});
if (ARM !== "default" && ARM !== "newkey" && ARM !== "extra") {
    var py = cp.spawnSync("python3", ["-B", path.join(C.ROOT, "tools/shell/lares-config-check.py"), "--cases", path.join(C.ROOT, "tools/dev/fixtures/config_cases.json")],
        { encoding: "utf8", env: Object.assign({}, process.env, ARM === "python" ? { LARES_CONFIG_ARM: "noranges" } : {}) });
    var lines = {};
    try { lines = JSON.parse(py.stdout); } catch (e) { bad("lares-config-check.py --cases did not answer: " + (py.stderr || py.stdout).substring(0, 300)); }
    cases.forEach(function (c) {
        checks++;
        if (lines[c.name] === undefined) { bad("case " + c.name + " (lares config): no answer"); return; }
        var want = c.want, got = lines[c.name];
        if (c.syntax) {                    // each side words a syntax error in its own way: the line is what they share
            want = want.map(function (l) { return l.split(":")[0]; });
            got = got.map(function (l) { return l.split(":")[0]; });
        }
        if (!eq(got, want)) bad("case " + c.name + " (lares config): " + JSON.stringify(got) + " instead of " + JSON.stringify(want));
    });
}
// (5) `lares config set` names a secret key and never prints its value, nor anything holding one (the calendars' URLs): a private
// config home with a fake key and a fake calendar link
if (ARM === "" || ARM === "secret") {
    var home = fs.mkdtempSync(path.join(require("os").tmpdir(), "cfgsecret-"));
    fs.mkdirSync(path.join(home, "quickshell", "config"), { recursive: true });
    fs.writeFileSync(path.join(home, "quickshell", "config", "wiki.jsonc"), '{ "jevKey": "dk-FAKEKEY0123456789abcdef", "askAt": 7 }\n');
    fs.writeFileSync(path.join(home, "quickshell", "config", "calendars.jsonc"), '{ "calendars": [ { "url": "https://x/tok-SECRET999" } ] }\n');
    var ps = cp.spawnSync("python3", ["-B", path.join(C.ROOT, "tools/shell/lares-config-check.py"), "set", "wiki", "calendars"],
        { encoding: "utf8", env: Object.assign({}, process.env, { XDG_CONFIG_HOME: home }, ARM === "secret" ? { LARES_CONFIG_ARM: "showsecret" } : {}) });
    fs.rmSync(home, { recursive: true, force: true });
    checks++;
    if (/FAKEKEY|SECRET999/.test(ps.stdout + ps.stderr) || !/jevKey = \(set\)/.test(ps.stdout) || !/askAt = 7/.test(ps.stdout))
        bad("a secret is printed by `lares config set` (or the keys are not named): " + JSON.stringify(ps.stdout.substring(0, 300)));
}
if (ARM === "") {
    var s = cp.spawnSync(process.execPath, [path.join(__dirname, "config_schema.js"), "--check"], { encoding: "utf8" });
    checks++;
    if (s.status !== 0) bad(s.stdout.trim());
}
out.forEach(function (l) { console.log("CONFIG_SPEC FAIL " + l); });
if (ARM) {
    var needle = { "default": "in the spec", newkey: "is not in the example", extra: "is not a key", list: "(the shell)", line: "(the shell)", python: "(lares config)", secret: "a secret is printed" }[ARM];
    var bit = out.some(function (l) { return l.indexOf(needle) >= 0; });
    console.log("CONFIG_SPEC ARM " + ARM + (bit ? ": failed as it must" : ": DID NOT FAIL"));
    process.exit(bit ? 0 : 1);
}
console.log("CONFIG_SPEC RESULT " + (out.length ? "FAIL (" + out.length + ")" : "PASS (" + Object.keys(C.specs).length + " files, " + checks + " checks)"));
process.exit(out.length ? 1 : 0);
