#!/usr/bin/env node
// field_shape_replay.js -- the field-shape differential in node: a corpus (field_shape_record.sh) through two GooeyGeometry.js, call by
// call, chained per field, every output and every input after the call compared for exact identity (field_shape_lib.js `canon`).
//
//   node tools/dev/perf/field_shape_replay.js <corpus.jsonl> <A> <B> [--bench <passes>] [--cls <regex>]
//       <A> / <B>    a GooeyGeometry.js: a file, or <rev>:<path> (git show; e.g. perf-main:modules/bar/gooey/GooeyGeometry.js)
//       --bench N    after the identity, N passes of each over the corpus, A and B interleaved, per scenario class: ms per call
//                    (median and min .. max of the passes). NODE GIVES AN ALGORITHM'S SHARE, NEVER ITS COST (CLAUDE.md): the shell's
//                    engine is QV4 -- tools/dev/perf/field_shape_qv4.sh times there.
//       --cls RE     only the calls whose scenario matches
//   FS_ARM=<name>    the self-test: B is A with one fault put in (`const`: BLEED 1.5 -> 1.5000001; `order`: a fillet's keys in another
//                    order; `state`: one more key in the state) -- the replay must FAIL and name the first differing call.
// Ends in `FIELD_SHAPE_REPLAY RESULT PASS|FAIL`.
"use strict";
const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const args = process.argv.slice(2);
if (args.length < 3) {
    console.log(fs.readFileSync(__filename, "utf8").split("\n").slice(1, 15).map(l => l.replace(/^\/\/ ?/, "")).join("\n"));
    process.exit(2);
}
const [corpus, specA, specB] = args;
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
const passes = Number(opt("--bench", 0));
const clsRe = opt("--cls", null);

function sourceOf(spec) {
    if (fs.existsSync(spec))
        return fs.readFileSync(spec, "utf8");
    const k = spec.indexOf(":");
    return cp.execFileSync("git", ["show", spec.slice(0, k) + ":" + spec.slice(k + 1)], { encoding: "utf8", maxBuffer: 1 << 26 });
}
function arm(src, name) {
    const swaps = {
        const: ["const BLEED = 1.5;", "const BLEED = 1.5000001;"],
        order: ["fillets.push({ vx: vb, vy: va, ex: rb, ey: ra,", "fillets.push({ vy: va, vx: vb, ex: rb, ey: ra,"],
        state: ["state: { rel: nextRel, void: nextVoid },", "state: { rel: nextRel, void: nextVoid, armed: 1 },"],
    };
    const s = swaps[name];
    if (!s || src.split(s[0]).length !== 2) {
        console.log(`FIELD_SHAPE_REPLAY RESULT FAIL (the arm ${name}'s anchor is gone)`);
        process.exit(1);
    }
    return src.replace(s[0], s[1]);
}
function load(src) {
    return new Function(src.replace(/^\.pragma library.*$/m, "") + "\nreturn { fieldShape };")().fieldShape;
}
const L = new Function(fs.readFileSync(path.join(__dirname, "field_shape_lib.js"), "utf8").replace(/^\.pragma library.*$/m, "")
    + "\nreturn { identity, prepare, bench, stats };")();

const srcA = sourceOf(specA);
let srcB = sourceOf(specB);
if (process.env.FS_ARM)
    srcB = arm(srcA, process.env.FS_ARM);
const fsA = load(srcA), fsB = load(srcB);
let lines = fs.readFileSync(corpus, "utf8").split("\n").filter(l => l.length > 0);
if (clsRe) {
    const re = new RegExp(clsRe);
    lines = lines.filter(l => re.test(l.slice(8, l.indexOf('"', 8))));
}

const t0 = Date.now();
const r = L.identity(lines, fsA, fsB);
console.log(`FS_REPLAY identity: ${r.calls} calls, ${r.diffs} differ (${Date.now() - t0} ms)`);
if (r.first) {
    const f = r.first;
    console.log(`FS_REPLAY first difference: line ${f.line} (${f.cls}, field ${f.f}, call ${f.q}) in the ${f.what}, at char ${f.diff.at}`);
    console.log(`  A: ...${f.diff.a}`);
    console.log(`  B: ...${f.diff.b}`);
}

if (passes > 0 && r.diffs === 0) {
    const recs = L.prepare(lines);
    const byCls = {};
    for (const x of recs)
        (byCls[x.cls] = byCls[x.cls] || []).push(x);
    const classes = Object.keys(byCls).sort();
    for (const c of classes) {
        const set = byCls[c], ta = [], tb = [];
        for (let p = 0; p < passes; p++) {
            ta.push(L.bench(set, fsA) / set.length);
            tb.push(L.bench(set, fsB) / set.length);
        }
        const a = L.stats(ta), b = L.stats(tb);
        console.log(`FS_REPLAY bench ${c} (${set.length} calls): A ${a.median.toFixed(4)} ms (${a.min.toFixed(4)} .. ${a.max.toFixed(4)})`
            + `  B ${b.median.toFixed(4)} ms (${b.min.toFixed(4)} .. ${b.max.toFixed(4)})  B/A ${(b.median / a.median).toFixed(3)}`);
    }
}
const armed = !!process.env.FS_ARM;
const ok = armed ? r.diffs > 0 : r.diffs === 0;
console.log(`FIELD_SHAPE_REPLAY RESULT ${ok ? "PASS" : "FAIL"} (${r.calls} calls, ${r.diffs} differ${armed ? ", armed " + process.env.FS_ARM : ""})`);
process.exit(ok ? 0 : 1);
