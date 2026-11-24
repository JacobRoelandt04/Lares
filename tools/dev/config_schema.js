#!/usr/bin/env node
// config_schema.js -- writes what VS Code completes, explains and underlines config/*.jsonc by.
//
//   node tools/dev/config_schema.js           writes .examples/schema/<name>.schema.json (one per spec) and .vscode/settings.json
//   node tools/dev/config_schema.js --check   writes nothing: CONFIG_SCHEMA RESULT PASS | FAIL (which are stale)
//
// Two sources, nothing else: modules/common/config/specs/<name>.js (types, ranges, defaults) and the comments of
// .examples/<name>.jsonc (the words of the hover). Run it after a change to either; the gate config_spec_check.js fails a stale one.
// `lares config` reads the same files (tools/shell/lares-config-check.py).
var fs = require("fs"), path = require("path");
var C = require("./config_node.js");

// { "a\0b": words } -- the comment lines right above a key at its own indentation, then the comment on its line (and the lines under that one
// that begin in the same column).
function wordsOf(name) {
    var text = C.exampleText(name), lines = text.split("\n"), clean = C.Check.strip(text);
    var pl = C.Check.places(clean).at, out = {};
    var starts = [0];
    for (var i = 0; i < text.length; i++)
        if (text[i] === "\n") starts.push(i + 1);
    function lineOf(off) { var lo = 0; while (lo + 1 < starts.length && starts[lo + 1] <= off) lo++; return lo; }
    function say(l) { return l.replace(/^\s*\/\/ ?/, "").replace(/\s+$/, ""); }
    Object.keys(pl).forEach(function (key) {
        if (/(^|\0)\d+(\0|$)/.test(key)) return;                // inside a list: a sample
        var n = lineOf(pl[key]), col = pl[key] - starts[n], got = [];
        if (lines[n].substring(0, col).trim() !== "" && lines[n].substring(0, col).trim() !== "{") return;    // a second key on the line
        for (var u = n - 1; u >= 0 && /^\s*\/\//.test(lines[u]); u--)
            if (lines[u].indexOf("//") === col) got.unshift(say(lines[u])); else break;
        // the comment that ends this key's line: where the stripped line differs from the real one
        var cl = clean.substring(starts[n], starts[n] + lines[n].length), c = lines[n].length;
        while (c > 0 && cl[c - 1] === " ") c--;
        var m = lines[n].substring(c).match(/^\s*(\/\/.*)$/);
        if (m) {
            var at = lines[n].length - m[1].length;
            got.push(say(m[1]));
            for (var d = n + 1; d < lines.length && /^\s*\/\//.test(lines[d]) && lines[d].indexOf("//") === at; d++)
                got.push(say(lines[d]));
        }
        if (got.length) out[key] = got.join("\n").replace(/^\n+|\n+$/g, "");
    });
    return out;
}

function schemaText(name) {
    var words = wordsOf(name);
    var s = C.Check.schema(C.specs[name], function (p, node) {
        var w = words[p.join("\0")] || "";
        if (!C.Check.isNode(node) || p.indexOf("*") >= 0) return w;
        var o = C.Check.opts(node), facts = [];
        if (node[0] !== "any" && node[0] !== "map" && node[0] !== "obj") facts.push("Takes " + C.Check.wants(node) + ".");
        if (node[1] !== undefined && !o.sample) facts.push("Default: " + JSON.stringify(node[1]) + ".");
        if (o.start) facts.push("Read as the shell starts.");
        return (w ? w + "\n\n" : "") + facts.join(" ");
    }, name + ".jsonc");
    return JSON.stringify(s, null, 1) + "\n";
}

function settingsText() {
    var keep = {}, file = path.join(C.ROOT, ".vscode/settings.json");
    if (fs.existsSync(file))
        keep = JSON.parse(C.Check.strip(fs.readFileSync(file, "utf8")));
    keep["json.schemas"] = Object.keys(C.specs).map(function (n) {
        return { fileMatch: ["/config/" + n + ".jsonc", "/.examples/" + n + ".jsonc"], url: "./.examples/schema/" + n + ".schema.json" };
    });
    return JSON.stringify(keep, null, 4) + "\n";
}

var files = { ".vscode/settings.json": settingsText() };
Object.keys(C.specs).forEach(function (n) { files[".examples/schema/" + n + ".schema.json"] = schemaText(n); });
var check = process.argv.indexOf("--check") >= 0, stale = [];
Object.keys(files).forEach(function (rel) {
    var f = path.join(C.ROOT, rel), have = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : null;
    if (have === files[rel]) return;
    stale.push(rel);
    if (!check) {
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(f, files[rel]);
    }
});
var dir = path.join(C.ROOT, ".examples/schema");
(fs.existsSync(dir) ? fs.readdirSync(dir) : []).forEach(function (f) {
    if (files[".examples/schema/" + f] !== undefined) return;
    stale.push(".examples/schema/" + f + " (no such spec)");
    if (!check) fs.unlinkSync(path.join(dir, f));
});
if (check) {
    console.log("CONFIG_SCHEMA RESULT " + (stale.length ? "FAIL (stale: " + stale.join(", ") + " -- node tools/dev/config_schema.js)" : "PASS (" + Object.keys(files).length + " files)"));
    process.exit(stale.length ? 1 : 0);
}
console.log(stale.length ? "written: " + stale.join(", ") : "nothing to write");
