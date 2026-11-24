#!/usr/bin/env node
// tools/dev/panorama_layout_cases.js -- the canvas geometry (modules/panorama/data/PanoramaLayout.js) under node.
//
//   node tools/dev/panorama_layout_cases.js          must end PANORAMA_LAYOUT RESULT PASS
//   node tools/dev/panorama_layout_cases.js --arms   the clean run passes AND every ARM fails -> PANORAMA_LAYOUT ARMS PASS
//
// ARMs patch ONE rule in the loaded COPY (a string replace before eval):
//   nosnap     a carried tile never snaps
//   overlap    a drop may land on a neighbour
//   gap        a drop may float free of the others
//   noconnect  a drop may leave the layout in two pieces
//   corner     two tiles that meet at a corner count as joined
"use strict";
const fs = require("fs");
const path = require("path");
const ROOT = path.resolve(__dirname, "../..");
const L_SRC = path.join(ROOT, "modules/panorama/data/PanoramaLayout.js");
const M_SRC = path.join(ROOT, "modules/panorama/data/PanoramaModel.js");
const TABLE = JSON.parse(fs.readFileSync(path.join(__dirname, "panorama_cases.json"), "utf8"));
const FX = TABLE.fixtures;

const ARMS = {
    overlap: ["if (!_fits(m, c.x, c.y, others)) continue;", ""],
    gap: ["var best = _nearest(moving, others, true, true, Infinity);", "var best = { x: Math.round(moving.x), y: Math.round(moving.y) };"],
    noconnect: ["if (!connected(all2)) continue;", ""],
    corner: ["var MIN_SHARE = 48; ", "var MIN_SHARE = 0; "],
    nodiagonal: ["var horiz = Math.abs(dx) >= Math.abs(dy);", "var horiz = Math.abs(px - (o.x + o.w / 2)) >= Math.abs(py - (o.y + o.h / 2));"],
    nothirds: ["return t < 1 / 3 ? \"start\" : t > 2 / 3 ? \"end\" : \"centre\";", "return \"start\";"],
    pointerless: ["var order = others.map(function (o, i) { return { o: o, d: _dist2(o, px, py), i: i }; });", "var order = others.map(function (o, i) { return { o: o, d: 0, i: i }; });"],
    nocentre: ["var along = re.align === \"centre\" ? at + Math.round((len - mine) / 2) :", "var along = re.align === \"centre\" ? at :"],
    norelfree: ["at + Math.round((re.frac !== undefined ? re.frac : re.offset / Math.max(1, len)) * len)", "at"],
};

function loadModule(src) {
    src = src.replace(/^\.pragma library\s*$/m, "").replace(/^\.import .*$/m, "");
    const names = [...src.matchAll(/^function ([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm)].map(m => m[1]);
    // eslint-disable-next-line no-new-func
    return new Function("Model", src + "\nreturn {" + names.join(",") + "};");
}
const Model = loadModule(fs.readFileSync(M_SRC, "utf8"))();
function load(arm) {
    let src = fs.readFileSync(L_SRC, "utf8");
    if (arm) {
        const [a, b] = ARMS[arm];
        if (src.split(a).length < 2) throw new Error("ARM " + arm + ": its anchor is gone in PanoramaLayout.js");
        src = src.split(a).join(b);
    }
    return loadModule(src)(Model);
}

// the test's own judge (never the module's): rects overlap / touch / connect
function ov(a, b) { return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h; }
function tc(a, b) {
    const sy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y), sx = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    return ((a.x + a.w === b.x || b.x + b.w === a.x) && sy >= Math.min(48, a.h, b.h)) || ((a.y + a.h === b.y || b.y + b.h === a.y) && sx >= Math.min(48, a.w, b.w));
}
function conn(rs) {
    const seen = new Set([0]), st = [0];
    while (st.length) { const c = st.pop(); rs.forEach((r, j) => { if (!seen.has(j) && tc(rs[c], r)) { seen.add(j); st.push(j); } }); }
    return seen.size === rs.length;
}
function judge(rs) {
    for (let i = 0; i < rs.length; i++) for (let j = i + 1; j < rs.length; j++) if (ov(rs[i], rs[j])) return "overlap " + rs[i].name + "/" + rs[j].name;
    if (!conn(rs)) return "not connected";
    return "";
}
function R(name, x, y, w, h) { return { name, x, y, w, h }; }
let seed = 12345;
function rnd() { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; }

function run(arm) {
    const L = load(arm);
    let fails = 0, n = 0;
    function ok(c, what) { n++; if (!c) { fails++; if (!arm) console.log("FAIL " + what); } }

    // fitCanvas: centred, inside the padding, capped
    let f = L.fitCanvas([R("a", 0, 0, 2304, 1296), R("b", -280, -1440, 3440, 1440)], 400, 300, 10, 0);
    const bx = [(-280) * f.scale + f.ox, (3160) * f.scale + f.ox], by = [(-1440) * f.scale + f.oy, 1296 * f.scale + f.oy];
    ok(bx[0] >= 9.99 && bx[1] <= 390.01 && by[0] >= 9.99 && by[1] <= 290.01, "fit inside the padding");
    ok(Math.abs((bx[0] + bx[1]) / 2 - 200) < 0.01 && Math.abs((by[0] + by[1]) / 2 - 150) < 0.01, "fit centred");
    f = L.fitCanvas([R("a", 0, 0, 100, 100)], 400, 300, 10, 0.5);
    ok(f.scale === 0.5, "fit capped at maxScale");

    // dropByPointer: the pointer decides. A wide (3440 x 1440) and a tall (1440 x 3440) neighbour, each quadrant, the thirds, outside, three displays
    const mv = R("m", 0, 0, 1000, 600);
    function drop(o, px, py, others) { return L.dropByPointer(mv, others || [o], px, py, null); }
    const wide = R("wide", 0, 0, 3440, 1440), tall = R("tall", 0, 0, 1440, 3440);
    for (const [name, o] of [["wide", wide], ["tall", tall]]) {
        const cx = o.x + o.w / 2, cy = o.y + o.h / 2, ex = o.w * 0.45, ey = o.h * 0.45;
        const cases = [["left", o.x + o.w * 0.1, cy], ["right", o.x + o.w * 0.9, cy], ["top", cx, o.y + o.h * 0.1], ["bottom", cx, o.y + o.h * 0.9]];
        for (const [side, px, py] of cases) {
            const r = drop(o, px, py);
            ok(r.ok && r.to === o.name && r.side === side, name + ": the " + side + " triangle -> " + JSON.stringify(r));
            const placed = { x: r.x, y: r.y, w: mv.w, h: mv.h };
            ok(!ov(placed, o) && tc(placed, o), name + " " + side + ": touches, overlaps nothing");
        }
        // the pointer's place along a side picks the third
        let r = drop(o, o.x + o.w * 0.9, o.y + o.h * 0.1);
        ok(r.side === "right" && r.align === "start" && r.y === o.y, name + ": right, upper third -> start " + JSON.stringify(r));
        r = drop(o, o.x + o.w * 0.9, o.y + o.h * 0.5);
        ok(r.side === "right" && r.align === "centre" && r.y === Math.round(o.y + (o.h - mv.h) / 2), name + ": right, middle third -> centre");
        r = drop(o, o.x + o.w * 0.97, o.y + o.h * 0.8);
        ok(r.side === "right" && r.align === "end" && r.y === o.y + o.h - mv.h, name + ": right, lower third -> end");
        r = drop(o, o.x + o.w * 0.5, o.y + o.h * 0.05);
        ok(r.side === "top" && r.align === "centre" && r.y === o.y - mv.h, name + ": top, middle -> centre");
        r = drop(o, o.x + o.w * 0.05, o.y + o.h * 0.97);
        ok(r.side === "bottom" && r.align === "start" && r.x === o.x, name + ": bottom, left third -> start (nearer the bottom edge than the left one)");
        void ex; void ey;
    }
    // the laptop can go LEFT of an ultrawide while the pointer is over the ultrawide
    {
        const u = R("ultra", 2304, 0, 3440, 1440), lp = R("eDP-1", 0, 0, 2304, 1296);
        const r = L.dropByPointer(R("eDP-1", 0, 0, 2304, 1296), [u], 2304 + 200, 700, null);
        ok(r.ok && r.side === "left" && r.to === "ultra" && r.x === 2304 - 2304, "the laptop left of the ultrawide, the pointer over the ultrawide: " + JSON.stringify(r));
        void lp;
    }
    // outside every tile: the nearest tile and its facing side
    {
        let r = drop(wide, -600, 700);
        ok(r.side === "left" && r.to === "wide", "outside, left of the tile -> its left side");
        r = drop(wide, 1700, 2600);
        ok(r.side === "bottom", "outside, below -> its bottom side");
        const a = R("a", 0, 0, 1000, 800), c = R("c", 1000, 0, 1000, 800);
        r = drop(null, 2600, 400, [a, c]);
        ok(r.to === "c" && r.side === "right", "outside: the NEAREST tile (" + JSON.stringify(r) + ")");
    }
    // three displays: never on top of the third, the layout stays whole, and the middle one dragged away bridges again
    {
        const A = R("a", 0, 0, 1000, 800), B = R("b", 1000, 0, 1000, 800), C = R("c", 2000, 0, 1000, 800);
        // the pointer on A's right triangle would put the tile on B: the next valid place is taken
        let r = L.dropByPointer(R("m", 0, 0, 800, 800), [A, B, C], 900, 400, null);
        let p = R("m", r.x, r.y, 800, 800);
        ok(judge([A, B, C, p]) === "", "three: a drop over the seam between two is valid " + JSON.stringify(r));
        for (const pt of [[500, 100], [1500, 700], [2900, 400], [-300, 400], [1500, 1500], [5000, 5000]]) {
            r = L.dropByPointer(R("m", 0, 0, 800, 800), [A, B, C], pt[0], pt[1], null);
            ok(judge([A, B, C, R("m", r.x, r.y, 800, 800)]) === "", "three: pointer " + pt + " -> a valid layout " + JSON.stringify(r));
        }
        // the middle tile carried away: the other two do not touch, so only a bridging place is valid
        r = L.dropByPointer(R("b", 1000, 0, 1000, 800), [A, R("c", 2000, 0, 1000, 800)], 1500, 3000, { x: 1000, y: 0 });
        ok(judge([A, R("c", 2000, 0, 1000, 800), R("b", r.x, r.y, 1000, 800)]) === "", "three: the middle tile dropped far off bridges again " + JSON.stringify(r));
    }

    // resolveDrop
    const lap = R("eDP-1", 0, 0, 2304, 1296);
    let d = L.resolveDrop(R("m", 1000, 600, 800, 600), [lap], null);
    ok(!ov({ x: d.x, y: d.y, w: 800, h: 600 }, lap) && tc({ x: d.x, y: d.y, w: 800, h: 600 }, lap), "drop on top lands touching");
    d = L.resolveDrop(R("m", 9000, 9000, 800, 600), [lap], null);
    ok(tc({ x: d.x, y: d.y, w: 800, h: 600 }, lap), "a free drop is brought back to touch");
    // the middle of three dragged away: no single place joins the other two unless it bridges
    const A = R("a", 0, 0, 1000, 800), C = R("c", 2000, 0, 1000, 800);
    d = L.resolveDrop(R("b", 1000, 5000, 1000, 800), [A, C], { x: 1000, y: 0 });
    ok(d.ok && judge([A, C, R("b", d.x, d.y, 1000, 800)]) === "", "a bridge dropped far away still joins its neighbours");
    d = L.resolveDrop(R("b", 500, 5000, 900, 800), [A, C], { x: 1000, y: 0 });
    ok(d.ok === false && d.x === 1000 && d.y === 0, "no place joins them: the origin");

    // normalise
    const nr = L.normalise([R("DP-1", -280, -1440, 3440, 1440), R("eDP-1", 0, 0, 2304, 1296)], "eDP-1");
    ok(nr[1].x === 0 && nr[1].y === 0 && nr[0].x === -280, "normalise: laptop at 0,0");
    const nf = L.normalise([R("DP-1", 500, 700, 100, 100), R("DP-2", 600, 700, 100, 100)], "eDP-1");
    ok(nf[0].x === 0 && nf[0].y === 0 && nf[1].x === 100, "normalise: first display anchors");

    // rectsOf: rotation swaps, mirror and disabled leave
    const outs = [FX.edp, FX.lg];
    const specs = {
        "eDP-1": { enabled: true, mode: "2880x1620@120", position: [0, 0], scale: 1.25, transform: 0, mirror: "" },
        "DVI-I-1": { enabled: true, mode: "3440x1440@59.97", position: [-280, -1440], scale: 1, transform: 1, mirror: "" },
    };
    let rs = L.rectsOf(specs, outs);
    ok(rs.length === 2 && rs[0].w === 2304 && rs[1].w === 1440 && rs[1].h === 3440, "rectsOf: quarter turn swaps " + JSON.stringify(rs));
    specs["DVI-I-1"].mirror = "eDP-1";
    ok(L.rectsOf(specs, outs).length === 1, "rectsOf: a mirror has no tile");
    specs["DVI-I-1"].mirror = ""; specs["DVI-I-1"].enabled = false;
    ok(L.rectsOf(specs, outs).length === 1, "rectsOf: a disabled display has no tile");

    // relayout: a tile that grew over its neighbour is set beside it again; the anchor ends at 0,0
    const rl = L.relayoutOne([R("eDP-1", 0, 0, 2304, 1296), R("DP-1", 2304, 0, 1000, 800)].map((r, i) => i ? R(r.name, 2000, 0, 2400, 800) : r), "DP-1", "eDP-1");
    ok(judge(rl) === "" && rl.filter(r => r.name === "eDP-1")[0].x === 0, "relayoutOne keeps the layout valid: " + JSON.stringify(rl));

    // relations: how each tile hangs on a neighbour, and relayout from them
    {
        const lap2 = R("eDP-1", 0, 0, 2304, 1296), ext = R("DP-1", -568, -1440, 3440, 1440), side = R("HDMI-1", 2304, 100, 1920, 1080);
        const rects = [lap2, ext, side], rels = L.relationsOf(rects, "eDP-1");
        ok(rels["DP-1"].to === "eDP-1" && rels["DP-1"].side === "top" && rels["DP-1"].align === "centre", "relationsOf: the ultrawide is centred above the laptop " + JSON.stringify(rels["DP-1"]));
        ok(rels["HDMI-1"].to === "eDP-1" && rels["HDMI-1"].side === "right" && rels["HDMI-1"].align === "free", "relationsOf: a free hang on the right " + JSON.stringify(rels["HDMI-1"]));
        const same = L.relayout(rects, rels, "eDP-1");
        ok(JSON.stringify(same) === JSON.stringify(rects), "relayout with the same sizes is the identity " + JSON.stringify(same));
        // rotate an external 90 degrees and back: exactly the original
        const turned = rects.map(r => r.name === "HDMI-1" ? R(r.name, r.x, r.y, r.h, r.w) : r);
        const t1 = L.relayout(turned, rels, "eDP-1");
        ok(judge(t1) === "" && t1[2].w === 1080 && t1[2].x === 2304, "relayout after a quarter turn stays valid " + JSON.stringify(t1[2]));
        const back = L.relayout(t1.map(r => r.name === "HDMI-1" ? R(r.name, r.x, r.y, 1920, 1080) : r), rels, "eDP-1");
        ok(JSON.stringify(back) === JSON.stringify(rects), "rotate 90 then back gives exactly the original " + JSON.stringify(back));
        const t2 = L.relayout(rects.map(r => r.name === "DP-1" ? R(r.name, r.x, r.y, 1440, 3440) : r), rels, "eDP-1");
        ok(judge(t2) === "" && t2[1].x === Math.round((2304 - 1440) / 2) && t2[1].y === -3440, "the centred external stays centred when it turns " + JSON.stringify(t2[1]));
        // shrinking a centred external keeps it centred; a start-flush one keeps its edge
        const small = L.relayout(rects.map(r => r.name === "DP-1" ? R(r.name, r.x, r.y, 1720, 720) : r), rels, "eDP-1");
        ok(small[1].x + 860 === 1152 && small[1].y === -720, "shrinking a centred external keeps it centred " + JSON.stringify(small[1]));
        const flush = [R("eDP-1", 0, 0, 2304, 1296), R("X", 2304, 0, 1000, 800)], fr = L.relationsOf(flush, "eDP-1");
        ok(fr.X.align === "start", "flush top is start");
        const fl2 = L.relayout([flush[0], R("X", 2304, 0, 500, 400)], fr, "eDP-1");
        ok(fl2[1].y === 0 && fl2[1].x === 2304, "shrinking a start-flush one keeps its edge");
        // rotating the laptop keeps the externals' sides
        const lapT = rects.map(r => r.name === "eDP-1" ? R(r.name, 0, 0, 1296, 2304) : r);
        const t3 = L.relayout(lapT, rels, "eDP-1");
        ok(judge(t3) === "" && t3[1].y + t3[1].h === 0 && t3[2].x === 1296, "rotating the laptop keeps the externals' sides " + JSON.stringify(t3));
        // a chain: C hangs on B hangs on the laptop; B grows, C follows it
        const ch = [R("eDP-1", 0, 0, 1000, 800), R("B", 1000, 0, 1000, 800), R("C", 2000, 0, 1000, 800)], cr = L.relationsOf(ch, "eDP-1");
        ok(cr.C.to === "B", "a chain hangs on the one it touches");
        const grown = L.relayout([ch[0], R("B", 1000, 0, 1500, 800), ch[2]], cr, "eDP-1");
        ok(judge(grown) === "" && grown[2].x === 2500, "the chain follows a grown neighbour " + JSON.stringify(grown));
        ok(Object.keys(L.relationsOf([lap2], "eDP-1")).length === 0, "a lone display has no relations");
    }

    // scaleShown
    const sc = L.scaleShown(Model.scaleChoices(2880, 1620), 1.3333333333333333, 1.875);
    ok(sc.indexOf(1.25) >= 0 && sc.indexOf(2) >= 0 && sc.indexOf(1.2) < 0 && sc.indexOf(1.875) >= 0 && sc.indexOf(1.3333333333333333) >= 0, "scaleShown: quarters + current + physical " + sc.join(" "));

    // fuzz: random connected layouts, random drops: always valid
    for (let t = 0; t < 400; t++) {
        const k = 2 + Math.floor(rnd() * 3), rects = [R("r0", 0, 0, 1000 + Math.floor(rnd() * 2000), 800 + Math.floor(rnd() * 900))];
        for (let i = 1; i < k; i++) {                         // grow a connected layout: each new rect placed by resolveDrop on the others
            const w = 600 + Math.floor(rnd() * 2400), h = 600 + Math.floor(rnd() * 1400);
            const p = L.resolveDrop(R("r" + i, Math.floor(rnd() * 4000 - 1000), Math.floor(rnd() * 3000 - 1000), w, h), rects, null);
            rects.push(R("r" + i, p.x, p.y, w, h));
        }
        if (judge(rects) !== "") { ok(false, "fuzz seed layout " + judge(rects)); continue; }
        const mi = Math.floor(rnd() * k), m = rects[mi], others = rects.filter((_, i) => i !== mi);
        const drop = R(m.name, Math.floor(rnd() * 7000 - 2500), Math.floor(rnd() * 5000 - 2000), m.w, m.h);
        const r = L.resolveDrop(drop, others, { x: m.x, y: m.y });
        const after = others.concat([R(m.name, r.x, r.y, m.w, m.h)]);
        const bad = judge(after);
        ok(bad === "", "fuzz " + t + " drop (" + drop.x + "," + drop.y + ") -> (" + r.x + "," + r.y + "): " + bad);
        const pr = L.dropByPointer(R(m.name, 0, 0, m.w, m.h), others, Math.floor(rnd() * 7000 - 2500), Math.floor(rnd() * 5000 - 2000), { x: m.x, y: m.y });
        const bad2 = judge(others.concat([R(m.name, pr.x, pr.y, m.w, m.h)]));
        ok(bad2 === "", "fuzz " + t + " pointer drop: " + bad2);
    }
    return { fails, n };
}

const r = run(null);
if (process.argv.includes("--arms")) {
    if (r.fails) { console.log("PANORAMA_LAYOUT ARMS FAIL (the clean run has " + r.fails + " failures)"); process.exit(1); }
    const bad = [];
    for (const a of Object.keys(ARMS)) {
        let ar;
        try { ar = run(a); } catch (e) { console.log(e.message); bad.push(a); continue; }
        console.log("ARM " + a + ": " + (ar.fails ? "fails as it must (" + ar.fails + " checks)" : "STILL PASSES"));
        if (!ar.fails) bad.push(a);
    }
    console.log("PANORAMA_LAYOUT ARMS " + (bad.length ? "FAIL (" + bad.join(", ") + ")" : "PASS"));
    process.exit(bad.length ? 1 : 0);
}
console.log("PANORAMA_LAYOUT RESULT " + (r.fails ? "FAIL (" + r.fails + " of " + r.n + ")" : "PASS (" + r.n + " checks)"));
process.exit(r.fails ? 1 : 0);
