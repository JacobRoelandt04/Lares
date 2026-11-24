#!/usr/bin/env node
// tools/dev/panorama_cases.js -- Panorama's rules (modules/panorama/data/PanoramaModel.js) against the ONE case table both twins
// share, tools/dev/panorama_cases.json (the Lua twin, tools/panorama/engine.lua, runs it through tools/dev/panorama_cases.lua).
//
//   node tools/dev/panorama_cases.js          must end PANORAMA_CASES_JS RESULT PASS
//   node tools/dev/panorama_cases.js --arms   the clean run passes AND every ARM fails -> PANORAMA_CASES_JS ARMS PASS
//
// ARMs patch ONE rule in the loaded COPY (a string replace before eval; the file is never touched):
//   jslocale   the set key sorts with localeCompare (the byte order is the contract with Lua)
//   snapdown   the scale snap tries downward first (FACT F5: ties go upward)
//   nofloor    the physical scale has no floor of 1 (decision 30)
//   nohop      the lock's hop output counts in the set
//   nodedup    liveDiff reports a difference for an equal output (every plug would re-modeset the eDP)
//   castident    a cast output is identified as headless:<name>, not by its device
//   castdefault  a never-seen cast takes the physical-scale default of an external, not 1080p60 at scale 1
//   castmirror   a cast output whose spec says mirror is made a mirror (it could never be removed again)
//   castoff      a cast output is switched off when its spec says so
//   grownoff     a set that grows carries its base's off
//   nofast       a never-seen display of a machine with no internal panel keeps the preferred refresh
//   homeextern   with no internal panel the home display counts as an external too (it is handed workspace 3)
//   castsplit    a cast display is no external for the split
//   castfirst    a cast display picks its workspace before the real externals
"use strict";
const fs = require("fs");
const path = require("path");
const ROOT = path.resolve(__dirname, "../..");
const SRC = path.join(ROOT, "modules/panorama/data/PanoramaModel.js");
const TABLE = JSON.parse(fs.readFileSync(path.join(__dirname, "panorama_cases.json"), "utf8"));

const ARMS = {
    jslocale: ["c.sort(_byteLess);", "c.sort(function (a, b) { return a.localeCompare(b); });"],
    snapdown: ["        if (_validK(k0 + i, w, h)) return (k0 + i) / 120;\n        if (k0 - i > 0 && _validK(k0 - i, w, h)) return (k0 - i) / 120;",
               "        if (k0 - i > 0 && _validK(k0 - i, w, h)) return (k0 - i) / 120;\n        if (_validK(k0 + i, w, h)) return (k0 + i) / 120;"],
    nofloor: ["var SCALE_MIN = 1.0;", "var SCALE_MIN = 0.5;"],
    nohop: ['var IGNORED = ["LARESLOCK-HOP", "FALLBACK"];', 'var IGNORED = ["FALLBACK"];'],
    nodedup: ['    if (out.x !== spec.position[0] || out.y !== spec.position[1]) return "position";',
              '    if (true) return "position";'],
    castident: ["    if (out.castId)\n        return out.castId;\n", ""],
    castdefault: ["            if (isCast(o.name)) {\n                spec.mode = CAST_MODE;", "            if (false) {\n                spec.mode = CAST_MODE;"],
    castmirror: ['    if (isCast(name) && name !== CAST_STANDIN) return "";', ''],
    castoff: ["    return !!spec.enabled || isCast(name);", "    return !!spec.enabled;"],
    grownoff: ["if (byId[c] && !isInternal(byId[c].name)) specById[c].enabled = true;", ""],
    nofast: ["if (!internal && fm && fm.r > pm.r) spec.mode", "if (false) spec.mode"],
    homeextern: ["    if (!internal)\n        externals = externals.filter(", "    if (false)\n        externals = externals.filter("],
    castsplit: ["var externals = shown.filter(function (o) { return o !== internal; });", "var externals = shown.filter(function (o) { return o !== internal && !isCast(o.name); });"],
    castfirst: ["return isCast(a.name) ? 1 : -1;", "return isCast(a.name) ? -1 : 1;"],
};

function load(arm) {
    let src = fs.readFileSync(SRC, "utf8").replace(/^\.pragma library\s*$/m, "");
    if (arm) {
        const [a, b] = ARMS[arm];
        if (src.split(a).length !== 2) throw new Error("ARM " + arm + ": its anchor is gone in PanoramaModel.js");
        src = src.replace(a, b);
    }
    const names = [...src.matchAll(/^function ([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm)].map(m => m[1]);
    const vars = [...src.matchAll(/^var ([A-Za-z_][A-Za-z0-9_]*)\s*=/gm)].map(m => m[1]);
    // eslint-disable-next-line no-new-func
    return new Function(src + "\nreturn {" + names.concat(vars).join(",") + "};")();
}

function fixture(v) {
    if (typeof v === "string" && v[0] === "$") {
        const f = TABLE.fixtures[v.slice(1)];
        if (f === undefined) throw new Error("no fixture " + v);
        return JSON.parse(JSON.stringify(f));
    }
    if (Array.isArray(v)) return v.map(fixture);
    return v;
}

function eq(a, b) {
    if (typeof a === "number" && typeof b === "number") return Math.abs(a - b) < 1e-6;
    if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return a === b;
    if (Array.isArray(a) !== Array.isArray(b)) return false;
    const ka = Object.keys(a), kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    return ka.every(k => eq(a[k], b[k]));
}

function subset(got, want) {
    if (want === null || typeof want !== "object") return eq(got, want);
    if (got === null || typeof got !== "object") return false;
    if (Array.isArray(want)) {
        if (!Array.isArray(got) || got.length !== want.length) return false;
        return want.every((w, i) => subset(got[i], w));
    }
    return Object.keys(want).every(k => subset(got[k], want[k]));
}

function run(arm) {
    const M = load(arm);
    let fails = 0, n = 0;
    for (const c of TABLE.cases) {
        if (c.lang && c.lang !== "js") continue;
        n++;
        let got, ok;
        try {
            got = M[c.fn](...c.args.map(fixture));
            ok = c.want !== undefined ? eq(got, c.want) : subset(got, c.wantSubset);
        } catch (e) {
            got = "threw " + e.message;
            ok = false;
        }
        if (!ok) {
            fails++;
            if (!arm) console.log("CASE FAIL " + c.fn + "(" + JSON.stringify(c.args).slice(0, 120) + ")" + (c.note ? " [" + c.note + "]" : "") +
                                  "\n    got  " + JSON.stringify(got).slice(0, 600) + "\n    want " + JSON.stringify(c.want !== undefined ? c.want : c.wantSubset).slice(0, 600));
        }
    }
    return { fails, n };
}

const r = run(null);
if (process.argv.includes("--arms")) {
    if (r.fails) { console.log("PANORAMA_CASES_JS ARMS FAIL (the clean run has " + r.fails + " failures)"); process.exit(1); }
    let bad = [];
    for (const a of Object.keys(ARMS)) {
        let ar;
        try { ar = run(a); } catch (e) { console.log(e.message); bad.push(a); continue; }
        console.log("ARM " + a + ": " + (ar.fails ? "fails as it must (" + ar.fails + " cases)" : "STILL PASSES"));
        if (!ar.fails) bad.push(a);
    }
    console.log("PANORAMA_CASES_JS ARMS " + (bad.length ? "FAIL (" + bad.join(", ") + ")" : "PASS"));
    process.exit(bad.length ? 1 : 0);
}
console.log("PANORAMA_CASES_JS RESULT " + (r.fails ? "FAIL (" + r.fails + " of " + r.n + ")" : "PASS (" + r.n + " cases)"));
process.exit(r.fails ? 1 : 0);
