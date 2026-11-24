#!/usr/bin/env node
// field_shape_phases.js -- an INSTRUMENTED copy of a GooeyGeometry.js for pricing fieldShape's phases (always ablate or measure before
// optimising: CLAUDE.md). Marks Date.now() at the boundaries of the phases below (exact-string anchors; a lost anchor fails) and adds
// `fsProbe()`, which field_shape_qv4.qml.in prints after a bench: the ms each phase took, summed over the calls of the outermost
// fieldShape (the pocket's nested flush pose counts inside "pockets"). Date.now() is whole ms, ~60 ns a call in QV4: summed over
// thousands of calls the phases are good to a few per cent.
//
//   node tools/dev/perf/field_shape_phases.js <GooeyGeometry.js> <out.js>
"use strict";
const fs = require("fs");
const [inp, outp] = process.argv.slice(2);
let t = fs.readFileSync(inp, "utf8");
const marks = [
    ["    const bodies = [];\n    // THE SKY (header)", "setup"],
    ["    // ---- 0. Bars that overlap touch instead", "bodies"],
    ["    // Weight settling: rise at once, fall by dt / settleMs.", "bars"],
    ["    // ---- 1b. Children follow the side they hang from", "snap"],
    ["    // ---- 2. Relations and joins, on the drawn boxes", "follow"],
    ["    for (let i = 0; i < bodies.length; i++) {\n        for (let j = 0; j < bodies.length; j++) {\n            if (i === j || !hosts(bodies[i], bodies[j]))", "defs"],
    ["    // ---- 2c (defined; run after the corners resolve)", "relations"],
    ["    // ---- 3. Output -----", "defs2"],
    ["    // THE POCKET'S CHANNELS, before the joints", "sortF"],
    ["    // ---- 2b. The joints, now that every sharp claim is in", "pocketChannels"],
    ["    for (let n = 0; n < joins.length; n++) {\n        const j = joins[n];\n        const cO = j.O.claims[j.cornerO];", "facingCaps"],
    ["    // A guest drawn flush with a host's end rests on material only if", "joints"],
    ["    // ---- 2c. THE POCKET: a capped channel zips shut from its cap", "resolve"],
    ["    // The seams over shared lines, on the resolved corners.", "pockets"],
    ["    const maxS = params.maxSeams || 24;", "seams"],
    ["    const margin = 3 + BLEED;", "outBodies"],
    ["    // THE SKY (header): a fillet of the sky wholly outside the clip", "tiles"],
    ["    return {\n        bodies: outBodies,", "shown"],
];
for (const [a, name] of marks) {
    if (t.split(a).length !== 2) {
        console.error("FS_PHASES FAIL anchor for " + name + " matches " + (t.split(a).length - 1) + " times");
        process.exit(1);
    }
    t = t.replace(a, `    __tl = __fsMark(${JSON.stringify(name)}, __tl);\n` + a);
}
// The body's opening: fieldShapeWith's (THE LOCAL NAMES) where fieldShape hands its body over, else fieldShape's own.
const hs = t.indexOf("function fieldShapeWith(") >= 0 ? t.indexOf("function fieldShapeWith(") : t.indexOf("function fieldShape(src, params, state, dtMs) {");
if (hs < 0) { console.error("FS_PHASES FAIL head"); process.exit(1); }
const he = t.indexOf(") {\n", hs) + 4;
t = t.slice(0, he) + "    __fsP.depth++;\n    let __tl = Date.now();\n    try {\n" + t.slice(he);
// The function's end: the only `return {` of fieldShape is its last statement; close the try after it.
const tail = "        droppedSeams: Math.max(0, seams.length - maxS)\n    };\n}\n";
if (t.split(tail).length !== 2) { console.error("FS_PHASES FAIL tail"); process.exit(1); }
t = t.replace(tail, "        droppedSeams: Math.max(0, seams.length - maxS)\n    };\n    } finally {\n        __fsP.depth--;\n    }\n}\n");
t += `
var __fsP = { depth: 0, acc: {}, calls: 0 };
function __fsMark(name, t) {
    const n = Date.now();
    if (__fsP.depth === 1) {
        __fsP.acc[name] = (__fsP.acc[name] || 0) + n - t;
        if (name === "setup")
            __fsP.calls++;
    }
    return n;
}
function fsProbe() {
    const r = __fsP;
    __fsP = { depth: 0, acc: {}, calls: 0 };
    return r;
}
`;
fs.writeFileSync(outp, t);
console.log("FS_PHASES ok " + outp);
