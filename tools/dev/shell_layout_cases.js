#!/usr/bin/env node
// The shell's geometry, table-tested under node (stream F2). ShellLayout.js is a `.pragma library`
// file with no Qt in it: the loader strips the pragma and evals the rest (the osd_js_cases.js pattern).
//
//   node tools/dev/shell_layout_cases.js          must end SHELL-LAYOUT RESULT PASS
//   node tools/dev/shell_layout_cases.js --arms   the clean run passes AND every ARM below fails
//                                             -> SHELL-LAYOUT ARMS PASS
//
// What it holds: the bars per mode and output (spans, barIds, thickness, reserve, inputMask), the
// islands fit their modules, the voids, the hidden state, and the engine's budget arithmetic for the
// layout (6 bars + the slot stack: THE BUDGET, E1.md).
//
// ARMs, each patching ONE rule in the loaded COPY (a string replace on the source before eval; the
// file is never touched) and each must turn it red:
//   ARM=slimmask     the slim bars take input again (the mask grows by three rects)
//   ARM=slimreserve  the slim bars RECORD a reserve of their thickness (the engine's edgeReserve would carry 6 for them)
//   ARM=noringreserve the main bar's room leaves out the ring (a window's border under the shell's)
//   ARM=slimnoreserve the outlets take no room (gaps_out 0 would put windows under the bars)
//   ARM=roundreserve  the room is rounded down (a ring of 3.75 px under the window's border)
//   ARM=notcentred   the centre island is not centred
//   ARM=nofit        the lengths are not made to fit a narrow screen
//   ARM=noflex       the title's slot does not take the island's remainder
//   ARM=dupmodule    a module listed twice stands twice
//   ARM=hidespan     the side bars keep their shown span while the bars hide (they detach from the top and bottom bars)
//   ARM=hidemin      the bars ease to 2 px, not to nothing
//   ARM=lengthsnap   the island lengths jump to the target (no way in between)
//   ARM=maskcurrent  the held input region is only where the islands stand now (the compositor is told every frame)
//   ARM=ratiothick   the main bar's thickness ignores the bar's ratio (THE BAR'S RATIO, ShellLayout.js)
//   ARM=ratiolen     an island's length ignores it
//   ARM=ratioreserve the main bar's reserve ignores it (the windows would be given 40, not 40 x ratio)
//   ARM=ratiomask    the islands' input rects ignore it
//   ARM=boxgap       the gap between two modules is the ink gap between their BOXES (the rule before 2026-10-25: 12 to 42 px between glyphs)
//   ARM=inkpad       an island's ends ignore the ink of the first and last module
//   ARM=jointfixed   the joint's default is a number, so the shell would not ask Hyprland (HyprJoint; ShellConfig.qml's constant)
//   ARM=oledends     the islands' free ends do not follow the OLED shift (THE OLED SHIFT, ShellLayout.js)
//   ARM=oledcorner   the left island's corner end moves with the OLED shift
//   ARM=modany       any falsy or odd value switches a module off (only an exact false may)
//   ARM=modpicker    the picker stays when the clipboard it pastes through is off
//   ARM=modzone      a switched-off module keeps its place in the zones
//   ARM=barsnone     bars.outputs may leave no display with bars
//   ARM=barsnot      a "!" name is not left out
//   ARM=wsother      a workspace that is on another screen keeps its dot here (workspaces.jsonc scope "screen")
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = path.join(__dirname, "..", "..", "modules", "shell", "ShellLayout.js");
// THE CONSTANTS are ShellConfig.qml's property defaults (inkGap, minVoid, titleSlot, the groove, the joint): read from that file, so the
// cases hold the layout the shell ships. An ARM in QML_ARMS patches that text.
const QML = path.join(__dirname, "..", "..", "modules", "shell", "ShellConfig.qml");
const QML_ARMS = {
    jointfixed: ['property real jointRounding: -1', 'property real jointRounding: 14']
};
function constants(arm) {
    let q = fs.readFileSync(QML, "utf8");
    if (arm && QML_ARMS[arm]) {
        const [a, b] = QML_ARMS[arm];
        if (q.split(a).length !== 2) { console.log("ARM " + arm + ": anchor not unique"); process.exit(2); }
        q = q.replace(a, b);
    }
    const c = {};
    for (const k of ["inkGap", "minVoid", "titleSlot", "workspacesScale", "workspacesPitch", "workspacesWidth", "jointRounding", "jointBorder",
                     "shadowReach", "shadowStrength", "shadowSpread", "shadowSoftness", "shadowBlend"]) {
        const m = new RegExp("^    property (?:int|real) " + k + ": (-?[0-9.]+)$", "m").exec(q);
        if (!m) { console.log("ShellConfig.qml declares no constant " + k); process.exit(2); }
        c[k] = Number(m[1]);
    }
    return c;
}
const ARMS = {
    barsnone: ['    return out.length > 0 ? out : names;', '    return out;'],
    barsnot: ['names.filter(n => no.indexOf(n) < 0 && (yes', 'names.filter(n => (yes'],
    wsother: ['    return ids.filter(id => !list.some(w => w.id === id && w.screen !== "" && w.screen !== screen));', '    return ids;'],
    modany: ['else if (v[k] === false)', 'else if (v[k] !== true)'],
    modpicker: ['    if (r.off.clipboard)\n        r.off.picker = true;\n', ''],
    modzone: ['d.zones[z] = d.zones[z].filter(id => off[id] !== true);', 'd.zones[z] = d.zones[z].slice();'],
    boxgap: ['return cfg.inkGap - inkOf(a)[1] - inkOf(b)[0];', 'return cfg.inkGap;'],
    inkpad: ['function padBefore(cfg, id) {\n    return cfg.inkGap - inkOf(id)[0];', 'function padBefore(cfg, id) {\n    return cfg.inkGap;'],
    slimmask: ['out.push(_bar("right", "right", top, H - top - slim, slim, 0, false));', 'out.push(_bar("right", "right", top, H - top - slim, slim, 0, true));'],
    noringreserve: ['out.top = px(r.top + w);', 'out.top = px(r.top);'],
    slimnoreserve: ['out[e] = px(slim + w);', 'out[e] = 0;'],
    roundreserve: ['const px = v => Math.ceil(v * kk - 1e-6);', 'const px = v => Math.floor(v * kk + 1e-6);'],
    slimreserve: ['out.push(_bar("bottom", "bottom", 0, W, slim, 0, false));', 'out.push(_bar("bottom", "bottom", 0, W, slim, SLIM, false));'],
    notcentred: ['const x = Math.round((W - L.centre) / 2);\n    return { x: x, voidLeft', 'const x = Math.round((W - L.centre) / 2) + 40;\n    return { x: x, voidLeft'],
    nofit: ['    let d = _deficit(cfg, L, W);\n    // The centre', '    let d = 0;\n    // The centre'],
    noflex: ['flexW = Math.max(flexMin(cfg, flex, widths), inner - fixed);', 'flexW = widthOf(flex, widths, cfg);'],
    dupmodule: ['if (typeof id === "string" && NOMINAL[id] !== undefined && !seen[id]) {', 'if (typeof id === "string" && NOMINAL[id] !== undefined) {'],
    hidespan: ['out.push(_bar("right", "right", top, H - top - slim, slim, 0, false));', 'out.push(_bar("right", "right", TOP, H - TOP - SLIM, slim, 0, false));'],
    hidemin: ['var HIDDEN = 0;', 'var HIDDEN = 2;'],
    lengthsnap: ['out[z] = k >= 1 ? to[z] : (k <= 0 ? from[z] : Math.round(from[z] + (to[z] - from[z]) * k));', 'out[z] = to[z];'],
    maskcurrent: ['const o = out[b.barId] || (held && held[b.barId]) || r;', 'const o = r;'],
    ratiothick: ['const top = thicknessAt(TOP * k, hide), slim = thicknessAt(SLIM, hide);', 'const top = thicknessAt(TOP, hide), slim = thicknessAt(SLIM, hide);'],
    ratiolen: ['out.push(_bar("topL", "top", 0, L.left * k, top, TOP * k, true));', 'out.push(_bar("topL", "top", 0, L.left, top, TOP * k, true));'],
    ratioreserve: ['out.push(_bar("topC", "top", c.x * k, L.centre * k, top, TOP * k, true));', 'out.push(_bar("topC", "top", c.x * k, L.centre * k, top, TOP, true));'],
    ratiomask: ['y1: TOP * k };', 'y1: TOP };'],
    oledends: ['        _freeEnds(out, W, shift);\n', ''],
    oledcorner: ['            b.rawLen = Math.max(0, b.rawLen + s);', '            b.rawPos += s;'],
};

function load(arm) {
    let src = fs.readFileSync(SRC, "utf8").replace(/^\.pragma.*$/m, "");
    if (arm && ARMS[arm]) {
        const [a, b] = ARMS[arm];
        if (src.split(a).length !== 2) { console.log("ARM " + arm + ": anchor not unique"); process.exit(2); }
        src = src.replace(a, b);
    }
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src + "\nthis.S = { barOutputs, workspacesOn, workspacesKept, TRAFFIC_REACH, INK, gapBetween, padBefore, padAfter, TOP, SLIM, HIDDEN, ZONES, ZONE_DEFAULTS, FLEX, TITLE_MIN, workspacesWidth, workspacesMin, flexMin, NOMINAL, defaults, merge, zoneOf, widthOf, naturalLength, lengthsFor, centreAt, bars, thicknessAt, barOfZone, place, fits, budget, maskRects, lengthsAt, sameLengths, maskUnion, windowReserve, MODULES, modulesOf };", ctx);
    // the shell's merge always has ShellConfig's constants; a case that tries others passes its own
    const C = constants(arm), merge0 = ctx.S.merge, defaults0 = ctx.S.defaults;
    ctx.S.merge = (o, c, off) => merge0(o, c || C, off);
    ctx.S.defaults = c => defaults0(c || C);
    ctx.S.C = C;
    ctx.S.K = over => Object.assign({}, C, over);
    return ctx.S;
}

function run(arm) {
    const S = load(arm);
    let n = 0, bad = 0;
    function ok(name, cond, extra) {
        n++;
        if (!cond) { bad++; console.log("FAIL " + name + (extra ? "  " + extra : "")); }
    }
    function eq(name, got, want) {
        ok(name, JSON.stringify(got) === JSON.stringify(want), "got " + JSON.stringify(got) + " want " + JSON.stringify(want));
    }
    const byId = list => { const m = {}; list.forEach(b => { m[b.barId] = b; }); return m; };
    const cfg = S.merge({});

    // ---- the config ----------------------------------------------------------
    eq("config: an empty file is the defaults", S.merge({}), S.defaults());
    eq("config: nonsense is the defaults", [S.merge(null), S.merge([]), S.merge("x"), S.merge({ topMode: 7, padding: "a", zones: 3, islands: [1] })].map(c => JSON.stringify(c)).every((s, i, a) => s === a[0]), true);
    eq("config: topMode continuous", S.merge({ topMode: "continuous" }).topMode, "continuous");
    eq("config: the joint asks Hyprland by default (null, null)", cfg.joint, { rounding: null, border: null });
    eq("config: the joint's overrides are numbers 0..64 of compositor px; below 0 asks, a number too big is held",
        [S.merge({}, S.K({ jointRounding: 10, jointBorder: 2 })).joint, S.merge({}, S.K({ jointRounding: -1, jointBorder: 99 })).joint,
         S.merge({}, S.K({ jointRounding: 0 })).joint],
        [{ rounding: 10, border: 2 }, { rounding: null, border: 64 }, { rounding: 0, border: null }]);
    eq("config: the layout's constants are no keys of the file (ShellConfig.qml holds them)",
        (m => [m.joint, m.titleSlot, m.workspacesScale, m.workspacesPitch, m.workspacesWidth, m.inkGap, m.minVoid])(
            S.merge({ joint: { rounding: 10 }, titleSlot: 500, workspacesScale: 0.5, workspacesPitch: 99, workspacesWidth: 300, inkGap: 3, minVoid: 99 })),
        [cfg.joint, cfg.titleSlot, cfg.workspacesScale, cfg.workspacesPitch, cfg.workspacesWidth, cfg.inkGap, cfg.minVoid]);
    eq("config: the zones are the PLAN's top-bar order", cfg.zones, {
        left: ["power", "idle", "theme", "notes", "llm", "windowtray"],
        centre: ["weather", "clock", "stocks"],
        right: ["player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "notifications"]
    });
    // `network` is the module's old id: a user's zones list that still says it moves aerial (round 10), and a file that names both keeps one
    eq("config: the old id `network` is aerial", S.merge({ zones: { left: ["power", "idle", "theme", "notes", "llm", "windowtray", "network"], centre: ["weather", "clock", "stocks"], right: ["player", "volume", "bridge", "silicon", "update", "notifications"] } }).zones,
        { left: ["power", "idle", "theme", "notes", "llm", "windowtray", "aerial"], centre: ["weather", "clock", "stocks"], right: ["player", "volume", "bridge", "silicon", "update", "notifications", "panorama"] });
    // `presets` was a bar module (round 2 of the panorama: it became the Presets tab of the panorama popup): a user's shell.jsonc that still names it in a
    // zone is tolerated -- the id is dropped without a word and nothing else moves (the others keep their order, none is added)
    eq("config: a zones list that still names `presets` drops it and moves nothing else",
        S.merge({ zones: { left: ["power", "idle", "theme", "presets", "notes", "llm", "windowtray"], centre: ["weather", "clock", "stocks"],
                           right: ["player", "volume", "aerial", "bridge", "presets", "panorama", "silicon", "update", "notifications"] } }).zones,
        cfg.zones);
    eq("config: `presets` is in no zone, no width table", [S.zoneOf(cfg, "presets"), S.NOMINAL.presets, S.INK.presets], ["", undefined, undefined]);
    {
        // scale.popups: `network` (and `network.detail`) is aerial's too, unless the file names aerial; aerial's default is the board's 1.35
        const sc = {}; vm.createContext(sc);
        vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "..", "modules", "shell", "scale", "ScaleConfig.js"), "utf8").replace(/^\.pragma.*$/m, "") + "\nthis.SC = { parse, popupMap };", sc);
        const pm = raw => sc.SC.popupMap(sc.SC.parse(raw), "");
        eq("scale: aerial is read at the board's 1.35 by default", pm({}).aerial, 1.35);
        eq("scale: the old `network` entry is aerial's", [pm({ scale: { popups: { network: 1.1, "network.detail": 1.2 } } }).aerial, pm({ scale: { popups: { network: 1.1, "network.detail": 1.2 } } })["aerial.detail"], pm({ scale: { popups: { network: 1.1 } } }).network], [1.1, 1.2, undefined]);
        eq("scale: a file naming aerial wins over `network`", pm({ scale: { popups: { network: 1.1, aerial: 1.5 } } }).aerial, 1.5);
        eq("scale: an output's `network` entry is aerial's", sc.SC.popupMap(sc.SC.parse({ scale: { outputs: { "eDP-1": { popups: { network: 1.3 } } } } }), "eDP-1").aerial, 1.3);
    }
    eq("config: `network` and `aerial` together are one module", (m => [].concat(m.zones.left, m.zones.centre, m.zones.right).filter(x => x === "aerial").length)(S.merge({ zones: { right: ["network", "aerial"] } })), 1);
    {
        const all = [].concat(cfg.zones.left, cfg.zones.centre, cfg.zones.right);
        eq("config: 17 modules, each once", all.length === 17 && new Set(all).size === 17, true);
        const m = S.merge({ zones: { left: ["power", "power", "bogus", "stocks"], centre: ["weather"], right: [] } });
        const mAll = [].concat(m.zones.left, m.zones.centre, m.zones.right);
        eq("config: a module listed twice or unknown stands once; one left out is back in its own zone",
            mAll.length === 17 && new Set(mAll).size === 17 && m.zones.left[0] === "power" && m.zones.left[1] === "stocks"
            && m.zones.centre.indexOf("clock") >= 0 && m.zones.right.indexOf("player") >= 0 && m.zones.left.indexOf("bogus") < 0, true);
        eq("config: a moved module is in its new zone", [S.zoneOf(m, "stocks"), S.zoneOf(m, "clock"), S.zoneOf(m, "player")], ["left", "centre", "right"]);
    }
    {
        const m = S.merge({ islands: { "eDP-1": { left: 700.4, centre: 0, right: "x", bogus: 9 }, "default": { left: 800, centre: 600, right: 500 }, "bad": 5 } });
        eq("config: island lengths are positive integers per zone; nothing else", m.islands, { "eDP-1": { left: 700 }, "default": { left: 800, centre: 600, right: 500 } });
        eq("config: outlets default to the left bar's top", cfg.outlets, { notes: { bar: "left", along: 0 }, llm: { bar: "left", along: 0 } });
    }

    // ---- the bars: 2880 x 1620 (the laptop), islands --------------------------
    const W = 2880, H = 1620;
    const widths = {};
    const L = S.lengthsFor(cfg, "eDP-1", W, widths);
    {
        const list = S.bars(cfg, W, H, L);
        eq("bars: six, in track order", list.map(b => b.barId), ["topL", "topC", "topR", "right", "bottom", "left"]);
        const b = byId(list);
        eq("bars: topL starts at the screen's left edge", [b.topL.edge, b.topL.rawPos, b.topL.rawLen], ["top", 0, L.left]);
        eq("bars: topR ends at the screen's right edge", b.topR.rawPos + b.topR.rawLen, W);
        ok("bars: topC is centred", Math.abs(b.topC.rawPos + b.topC.rawLen / 2 - W / 2) <= 0.5, "centre at " + (b.topC.rawPos + b.topC.rawLen / 2));
        eq("bars: the three islands are 40 px, reserve 40, take input", ["topL", "topC", "topR"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask]), [[40, 40, true], [40, 40, true], [40, 40, true]]);
        eq("bars: the slim bars are 6 px, reserve 0, no input", ["right", "bottom", "left"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask]), [[6, 0, false], [6, 0, false], [6, 0, false]]);
        eq("bars: right and left run from under the main bar to the bottom bar's face", [b.right.rawPos, b.right.rawLen, b.left.rawPos, b.left.rawLen], [40, H - 46, 40, H - 46]);
        eq("bars: the bottom bar runs the whole edge", [b.bottom.rawPos, b.bottom.rawLen], [0, W]);
        ok("bars: every bar has an area", list.every(x => x.rawLen > 0 && x.thickness > 0));
        const c = S.centreAt(cfg, W, L);
        ok("voids: both at least minVoid", c.voidLeft >= cfg.minVoid && c.voidRight >= cfg.minVoid, JSON.stringify(c));
        eq("voids: the island ends meet the voids", [b.topL.rawLen + c.voidLeft, b.topC.rawPos + b.topC.rawLen + c.voidRight], [b.topC.rawPos, b.topR.rawPos]);
    }
    {
        const list = S.bars(S.merge({ topMode: "continuous" }), W, H, L);
        eq("continuous: four bars", list.map(b => b.barId), ["top", "right", "bottom", "left"]);
        const b = byId(list);
        eq("continuous: one 40 px bar across the whole edge", [b.top.rawPos, b.top.rawLen, b.top.thickness, b.top.reserve, b.top.inputMask], [0, W, 40, 40, true]);
        eq("continuous: the slim bars are the same", ["right", "bottom", "left"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask]), [[6, 0, false], [6, 0, false], [6, 0, false]]);
        eq("continuous: barOfZone is `top` for every zone", S.ZONES.map(z => S.barOfZone(S.merge({ topMode: "continuous" }), z)), ["top", "top", "top"]);
        eq("islands: barOfZone", S.ZONES.map(z => S.barOfZone(cfg, z)), ["topL", "topC", "topR"]);
    }

    // ---- THE BAR'S RATIO (round 2, Addendum 3) -------------------------------------
    // The layout is in bar units (W / ratio of room); the bars come back in the frame's: x ratio, the outlets alone untouched.
    {
        eq("ratio 1: the bars are the layout of an unscaled bar, to the bit", S.bars(cfg, W, H, L, 0, 6, 1), S.bars(cfg, W, H, L));
        eq("ratio 1: a garbage ratio is 1", [S.bars(cfg, W, H, L, 0, 6, 0), S.bars(cfg, W, H, L, 0, 6, -2), S.bars(cfg, W, H, L, 0, 6, NaN)].every(x => JSON.stringify(x) === JSON.stringify(S.bars(cfg, W, H, L))), true);
        for (const k of [1.25, 0.8, 1.5]) {
            const Lk = S.lengthsFor(cfg, "eDP-1", W / k, widths);
            const list = S.bars(cfg, W, H, Lk, 0, 6, k);
            const b = byId(list);
            const T = 40 * k;
            eq("ratio " + k + ": the islands are 40 x ratio thick with that reserve, the outlets 6 with none", [["topL", "topC", "topR"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask]), ["right", "bottom", "left"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask])],
               [[[T, T, true], [T, T, true], [T, T, true]], [[6, 0, false], [6, 0, false], [6, 0, false]]]);
            ok("ratio " + k + ": every island is its length (bar units) x ratio", Math.abs(b.topL.rawLen - Lk.left * k) < 1e-9 && Math.abs(b.topC.rawLen - Lk.centre * k) < 1e-9 && Math.abs(b.topR.rawLen - Lk.right * k) < 1e-9,
               [b.topL.rawLen, b.topC.rawLen, b.topR.rawLen] + " of " + [Lk.left, Lk.centre, Lk.right]);
            eq("ratio " + k + ": the right island ends at the screen's right edge, the left starts at its left", [b.topL.rawPos, b.topR.rawPos + b.topR.rawLen], [0, W]);
            ok("ratio " + k + ": the centre island is centred", Math.abs(b.topC.rawPos + b.topC.rawLen / 2 - W / 2) <= k / 2 + 1e-9, "centre at " + (b.topC.rawPos + b.topC.rawLen / 2));
            const voidL = b.topC.rawPos - (b.topL.rawPos + b.topL.rawLen), voidR = b.topR.rawPos - (b.topC.rawPos + b.topC.rawLen);
            ok("ratio " + k + ": both voids at least minVoid x ratio (the screen's room in bar units)", voidL >= cfg.minVoid * k - 1e-9 && voidR >= cfg.minVoid * k - 1e-9, voidL + " / " + voidR);
            eq("ratio " + k + ": the side bars run from under the main bar's face to the bottom bar's", [b.right.rawPos, b.right.rawLen, b.left.rawPos], [T, H - T - 6, T]);
            ok("ratio " + k + ": the same screen, narrower: the islands still fit", (() => {
                const Wn = 1920, Ln = S.lengthsFor(cfg, "eDP-1", Wn / k, widths), bn = byId(S.bars(cfg, Wn, 1080, Ln, 0, 6, k));
                return bn.topL.rawLen <= Wn && bn.topC.rawPos - (bn.topL.rawPos + bn.topL.rawLen) >= cfg.minVoid * k - 1e-9 && bn.topR.rawPos - (bn.topC.rawPos + bn.topC.rawLen) >= cfg.minVoid * k - 1e-9;
            })());
            const cb = byId(S.bars(S.merge({ topMode: "continuous" }), W, H, Lk, 0, 6, k));
            eq("ratio " + k + " continuous: one 40 x ratio bar across the frame, that reserve", [cb.top.rawPos, cb.top.rawLen, cb.top.thickness, cb.top.reserve], [0, W, T, T]);
            const h5 = byId(S.bars(cfg, W, H, Lk, 0.5, 6, k)), h1 = byId(S.bars(cfg, W, H, Lk, 1, 6, k));
            eq("ratio " + k + ": hidden eases from 40 x ratio to nothing", [h5.topL.thickness, h1.topL.thickness, h1.topL.reserve], [T / 2, 0, T]);
            eq("ratio " + k + ": the side bars follow the main bar's current thickness while it hides", [h5.right.rawPos, h5.left.rawPos], [T / 2, T / 2]);
            const from = Lk, to = S.lengthsFor(cfg, "eDP-1", W / k, { power: 90 });
            const held = S.maskUnion(null, cfg, W, H, [from, to], k);
            const rect = (LL, id) => { const x = S.bars(cfg, W, H, LL, 0, 6, k).find(q => q.barId === id); return { x0: x.rawPos, y0: 0, x1: x.rawPos + x.rawLen, y1: T }; };
            ok("ratio " + k + ": the held input rect is the union of where each island stands, T tall", ["topL", "topC", "topR"].every(id => {
                const a = rect(from, id), c2 = rect(to, id);
                const u = { x0: Math.min(a.x0, c2.x0), y0: 0, x1: Math.max(a.x1, c2.x1), y1: T };
                return JSON.stringify(held[id]) === JSON.stringify(u);
            }), JSON.stringify(held));
        }
    }

    // ---- THE OLED SHIFT (round 7): the islands' free ends follow the step's x, the corners and the thickness never ---------
    {
        for (const k of [1, 1.25]) {
            const Lk = S.lengthsFor(cfg, "eDP-1", W / k, widths);
            const rest = byId(S.bars(cfg, W, H, Lk, 0, 6, k));
            eq("oled " + k + ": a shift of 0 is the shown layout, to the bit", S.bars(cfg, W, H, Lk, 0, 6, k, 0), S.bars(cfg, W, H, Lk, 0, 6, k));
            for (const s of [0.8, -0.8, 1, -1]) {
                const b = byId(S.bars(cfg, W, H, Lk, 0, 6, k, s));
                eq("oled " + k + " shift " + s + ": the left island's right end, the centre island and the right island's start move; the corners stay",
                   [b.topL.rawPos, b.topL.rawPos + b.topL.rawLen, b.topC.rawPos, b.topC.rawPos + b.topC.rawLen, b.topR.rawPos, b.topR.rawPos + b.topR.rawLen].map(v => Math.round(v * 1e6) / 1e6),
                   [0, rest.topL.rawLen + s, rest.topC.rawPos + s, rest.topC.rawPos + rest.topC.rawLen + s, rest.topR.rawPos + s, W].map(v => Math.round(v * 1e6) / 1e6));
                eq("oled " + k + " shift " + s + ": the thickness, the reserve, the input and the slim bars do not move",
                   ["topL", "topC", "topR", "right", "bottom", "left"].map(id => [b[id].thickness, b[id].reserve, b[id].inputMask].concat(id.startsWith("top") ? [] : [b[id].rawPos, b[id].rawLen])),
                   ["topL", "topC", "topR", "right", "bottom", "left"].map(id => [rest[id].thickness, rest[id].reserve, rest[id].inputMask].concat(id.startsWith("top") ? [] : [rest[id].rawPos, rest[id].rawLen])));
                const vL = b.topC.rawPos - (b.topL.rawPos + b.topL.rawLen), vR = b.topR.rawPos - (b.topC.rawPos + b.topC.rawLen);
                const rL = rest.topC.rawPos - rest.topL.rawLen, rR = rest.topR.rawPos - (rest.topC.rawPos + rest.topC.rawLen);
                ok("oled " + k + " shift " + s + ": the voids keep their width", Math.abs(vL - rL) < 1e-9 && Math.abs(vR - rR) < 1e-9, [vL, rL, vR, rR].join(" "));
            }
            eq("oled " + k + ": the continuous bar has no free end", S.bars(S.merge({ topMode: "continuous" }), W, H, Lk, 0, 6, k, 1), S.bars(S.merge({ topMode: "continuous" }), W, H, Lk, 0, 6, k));
            const none = byId(S.bars(cfg, W, H, { left: 0, centre: Lk.centre, right: 0 }, 0, 6, k, 1));
            eq("oled " + k + ": an island with no length stays none (no sliver body)", [none.topL.rawLen, none.topR.rawLen], [0, 0]);
            const from = Lk, to = S.lengthsFor(cfg, "eDP-1", W / k, { power: 90 });
            const held = S.maskUnion(null, cfg, W, H, [from, to], k, 1);
            ok("oled " + k + ": the held input rect covers the islands at the shift", ["topL", "topC", "topR"].every(id => [from, to].every(LL => {
                const x = S.bars(cfg, W, H, LL, 0, 6, k, 1).find(q => q.barId === id);
                return held[id].x0 <= x.rawPos + 1e-9 && held[id].x1 >= x.rawPos + x.rawLen - 1e-9;
            })), JSON.stringify(held));
        }
    }

    // ---- lengths: natural, configured, per output, fitted ------------------------
    {
        // (written out from INK on purpose: the formula is the rule, not a copy of the code)
        const R = ["player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "notifications"], G = cfg.inkGap;
        let want = (G - S.INK.player[0]) + (G - S.INK.notifications[1]) + (28 + 52 + 52 + 28 + 28 + 108 + 32 + 32);
        for (let i = 1; i < R.length; i++)
            want += G - S.INK[R[i - 1]][1] - S.INK[R[i]][0];
        eq("lengths: natural = room to the first ink + widths + the gaps that put the ink one ink gap apart + room after the last ink",
            S.naturalLength(cfg, "right", {}), want);
        eq("spacing: the ink gap is the shell's one number", cfg.inkGap, 22);
        eq("spacing: a pair's box gap is the ink gap less the room both boxes keep", [S.gapBetween(cfg, "theme", "notes"), S.gapBetween(cfg, "weather", "clock")], [22 - 5 - 6, 22 - 24 + 4]);
        eq("spacing: padding and gap in a file are gone (the ink gap is the one number)", [S.merge({ padding: 40, gap: 40 }).padding, S.merge({ gap: 40 }).gap], [undefined, undefined]);
        eq("lengths: the title's slot and the groove are config numbers, not item widths",
            [S.widthOf("windowtray", { windowtray: 999 }, cfg), S.widthOf("clock", { clock: 999 }, cfg)], [cfg.titleSlot, S.workspacesWidth(cfg)]);
        eq("groove: the user's scale 0.9 and pitch 30 fit 2 * 30 + 64 + 90", S.workspacesWidth(cfg), 214);
        eq("groove: E2's fitted width at scale 0.75, pitch 64 is 2 * 64 + 64 + 75", S.workspacesWidth(S.merge({}, S.K({ workspacesScale: 0.75, workspacesPitch: 64 }))), 267);
        eq("groove: the three scales of the sheet (pitch 64)", [0.6, 0.75, 0.9].map(k => S.workspacesWidth(S.merge({}, S.K({ workspacesScale: k, workspacesPitch: 64 })))), [252, 267, 282]);
        eq("groove: a width wins; under 100 it is the fitted one", [S.workspacesWidth(S.merge({}, S.K({ workspacesWidth: 300 }))), S.workspacesWidth(S.merge({}, S.K({ workspacesWidth: 40 })))], [300, 214]);
        eq("groove: the least is pitch 32", S.workspacesMin(cfg), 218);
        eq("groove: scale and pitch are clamped", [S.merge({}, S.K({ workspacesScale: 9 })).workspacesScale, S.merge({}, S.K({ workspacesScale: 0 })).workspacesScale, S.merge({}, S.K({ workspacesPitch: 1 })).workspacesPitch], [1, 0.4, 24]);
        eq("lengths: a measured width replaces the nominal one", S.widthOf("notes", { notes: 31 }, cfg), 31);
        const m = S.merge({ islands: { "eDP-1": { left: 800, centre: 520, right: 480 }, "default": { left: 900 } } });
        eq("lengths: the output's own", S.lengthsFor(m, "eDP-1", W, {}), { left: 800, centre: 520, right: 480 });
        const d = S.lengthsFor(m, "DP-3", 3440, {});
        eq("lengths: another output takes `default` where it has one, the natural length elsewhere",
            d, { left: 900, centre: S.naturalLength(m, "centre", {}), right: S.naturalLength(m, "right", {}) });
        ok("lengths: the natural ones fit 2880 with the voids to spare", S.centreAt(cfg, W, L).voidLeft >= 100, JSON.stringify(L));
    }
    for (const [w, label] of [[2880, "2880"], [3440, "3440"], [1920, "1920"], [1366, "1366"], [1024, "1024"]]) {
        const l = S.lengthsFor(cfg, "X", w, {});
        const c = S.centreAt(cfg, w, l);
        ok("fit " + label + ": the voids are at least minVoid", c.voidLeft >= cfg.minVoid - 1 && c.voidRight >= cfg.minVoid - 1, JSON.stringify([l, c]));
        ok("fit " + label + ": islands do not overlap", l.left <= c.x && c.x + l.centre <= w - l.right);
    }
    {
        // a groove with room to give (the sheet's 0.75 and pitch 64: 267 px, the least 203); at the user's 214 it is at its least already.
        // 1440, not 1366: with the panorama glyph the right island is 476 px, and a centred centre island leaves its half of a 1366 screen
        // 7 px short of it plus minVoid -- no flex module stands on that side, so 1366 takes the last-resort squeeze (the fit checks above)
        const roomy = S.merge({}, S.K({ workspacesScale: 0.75, workspacesPitch: 64 }));
        const wide = S.lengthsFor(roomy, "X", 3440, {});
        const narrow = S.lengthsFor(roomy, "X", 1440, {});
        ok("fit: a narrow screen takes the deficit from the groove and the title's slot, not from the buttons",
            narrow.centre < wide.centre && narrow.left <= wide.left && narrow.right === wide.right, JSON.stringify([narrow, wide]));
    }
    {
        const eq1 = S.merge({ centre: "equal", islands: { "default": { left: 900, centre: 600, right: 500 } } });
        const l = S.lengthsFor(eq1, "X", W, {});
        const c = S.centreAt(eq1, W, l);
        ok("equal voids: the centre island is placed so both voids are the same", Math.abs(c.voidLeft - c.voidRight) <= 1, JSON.stringify(c));
        const sym = S.merge({ islands: { "default": { left: 700, centre: 600, right: 700 } } });
        const cs = S.centreAt(sym, W, S.lengthsFor(sym, "X", W, {}));
        ok("equal voids: a symmetric config gives equal voids when centred", cs.voidLeft === cs.voidRight, JSON.stringify(cs));
    }

    // ---- the modules in an island ---------------------------------------------------
    for (const z of S.ZONES) {
        const placed = S.place(cfg.zones[z], {}, L[z], { cfg: cfg, flex: S.FLEX[z] });
        ok("place " + z + ": every module stands inside the island, in order, no ink on ink", S.fits(placed, L[z]), JSON.stringify(placed));
        eq("place " + z + ": the first module's INK starts one ink gap in", placed[0].x + S.INK[placed[0].id][0], cfg.inkGap);
        const last = placed[placed.length - 1];
        eq("place " + z + ": ... and the last module's ink ends one ink gap from the island's end", L[z] - (last.x + last.width - S.INK[last.id][1]), cfg.inkGap);
        for (let i = 1; i < placed.length; i++)
            if ((placed[i].x + S.INK[placed[i].id][0]) - (placed[i - 1].x + placed[i - 1].width - S.INK[placed[i - 1].id][1]) !== cfg.inkGap)
                ok("place " + z + ": the ink of " + placed[i - 1].id + " and " + placed[i].id + " is one ink gap apart", false, JSON.stringify(placed));
    }
    {
        const endPad = cfg.inkGap - S.INK.windowtray[1];
        const p = S.place(cfg.zones.left, {}, L.left, { cfg: cfg, flex: "windowtray" });
        const t = p[p.length - 1];
        eq("place: the title takes what the others leave and its ink ends one ink gap from the island's end", [t.id, t.x + t.width], ["windowtray", L.left - endPad]);
        const p2 = S.place(cfg.zones.left, {}, L.left + 100, { cfg: cfg, flex: "windowtray" });
        eq("place: a longer island gives the title the difference", p2[p2.length - 1].width - t.width, 100);
        const p3 = S.place(cfg.zones.left, {}, 300, { cfg: cfg, flex: "windowtray" });
        eq("place: the title never goes under its least", p3[p3.length - 1].width, S.TITLE_MIN);
        const r = S.place(cfg.zones.right, {}, L.right + 70, { cfg: cfg, flex: "" });
        ok("place: an island with no flex module shares the extra among its gaps", S.fits(r, L.right + 70) && r[r.length - 1].x + r[r.length - 1].width === L.right + 70 - (cfg.inkGap - S.INK.notifications[1]), JSON.stringify(r));
    }

    // ---- the room taken from the compositor (ENGGEO item 5) ---------------------------------------
    // The user: "the thin bars need to reserve 6px (9 with border enabled) and the thick bar reserves its width + the border, adjusted to
    // global/bar scale", so Hyprland's gaps_out can be 0 and windows sit snug in the negative space.
    {
        const er = { top: 40, right: 0, bottom: 0, left: 0 };
        eq("reserve: scale 1, a 3 px ring: 43 on top, 9 on the outlets' three edges", S.windowReserve(er, 6, 3, 1, true), { top: 43, right: 9, bottom: 9, left: 9 });
        eq("reserve: no ring: 40 on top, 6 on the three (the gaps_out the outlets were)", S.windowReserve(er, 6, 0, 1, true), { top: 40, right: 6, bottom: 6, left: 6 });
        eq("reserve: the bars away (the engine's reserve released, shown false): nothing at all", S.windowReserve({ top: 0, right: 0, bottom: 0, left: 0 }, 6, 3, 1, false), { top: 0, right: 0, bottom: 0, left: 0 });
        eq("reserve: the main bar's own ratio is in the engine's number (50 at ratio 1.25): 53 on top, the outlets' 6 + 3 unchanged",
           S.windowReserve({ top: 50, right: 0, bottom: 0, left: 0 }, 6, 3, 1, true), { top: 53, right: 9, bottom: 9, left: 9 });
        // a frame drawn 1.25 times larger: the outlets are 6 / 1.25 frame px (6 compositor px), the ring 3 frame px = 3.75 compositor px, rounded UP
        eq("reserve: frame scale 1.25 (outlet 4.8, ring 3, bar 40): the ring is 3.75 on the glass -> 10 on the outlets, 54 on top ((40 + 3) x 1.25 = 53.75)",
           S.windowReserve(er, 6 / 1.25, 3, 1.25, true), { top: 54, right: 10, bottom: 10, left: 10 });
        // round 3 post-review (GEO item 1): the ring is drawn on whole compositor px (HyprJoint.ringWidth: 3 -> 4 / 1.25 = 3.2), so the reserve IS the drawn edge
        eq("reserve: a ring drawn on whole glass px (3.2 frame px = 4) ends exactly on the reserve: 54 on top (50 + 4), 10 on the outlets (6 + 4)",
           [S.windowReserve(er, 6 / 1.25, 3.2, 1.25, true), (40 + 3.2) * 1.25, (6 / 1.25 + 3.2) * 1.25], [{ top: 54, right: 10, bottom: 10, left: 10 }, 54, 10]);
        eq("reserve: frame scale 1.5 (ring 3 = 4.5): 11 (10.5) on the outlets, 95 (94.5) on a 60 bar", S.windowReserve({ top: 60, right: 0, bottom: 0, left: 0 }, 4, 3, 1.5, true),
           { top: 95, right: 11, bottom: 11, left: 11 });
        eq("reserve: a whole number stays whole (never one more for float noise)", S.windowReserve(er, 6 / 1.2, 3, 1.2, true).left, 10);
        eq("reserve: a ring or scale that is no number is no ring / scale 1", [S.windowReserve(er, 6, undefined, 1, true).left, S.windowReserve(er, 6, -3, 1, true).left, S.windowReserve(er, 6, 3, 0, true).left, S.windowReserve(er, 6, 3, NaN, true).left],
           [6, 6, 9, 9]);
        eq("reserve: nothing given is nothing on top and the outlets when shown", S.windowReserve(null, 6, 3, 1, true), { top: 0, right: 9, bottom: 9, left: 9 });
    }

    // ---- the bars toggle -------------------------------------------------------------
    // Round 2 (the user, DeploymentNotes 78-80): every bar eases to NOTHING and the side bars stay joined to the top and bottom
    // bars all the way -- their span runs from the top bars' current face to the bottom bar's, so nothing detaches or shortens.
    {
        const list = S.bars(cfg, W, H, L);
        eq("hide: with no hide argument the layout is the shown one", S.bars(cfg, W, H, L, 0), list);
        const hid = S.bars(cfg, W, H, L, 1);
        eq("hide: the least thickness is none -- a bar with no area is no body of the engine's", S.HIDDEN, 0);
        eq("hide: hidden, every bar is no thicker than nothing", hid.map(b => b.thickness), list.map(() => 0));
        eq("hide: hidden, no bar is a body (the engine skips a bar with no area)", S.budget(hid).bars, 0);
        eq("hide: the spans along the top and bottom edges do not move", hid.filter(b => b.edge === "top" || b.edge === "bottom").map(b => [b.barId, b.rawPos, b.rawLen]),
           list.filter(b => b.edge === "top" || b.edge === "bottom").map(b => [b.barId, b.rawPos, b.rawLen]));
        eq("hide: thicknessAt is the straight line between the shown and the hidden", [S.thicknessAt(40, 0), S.thicknessAt(40, 0.5), S.thicknessAt(40, 1), S.thicknessAt(6, 0.25), S.thicknessAt(40, 7), S.thicknessAt(40, -1)],
           [40, 20, 0, 4.5, 0, 40]);
        for (const [mode, c] of [["islands", cfg], ["continuous", S.merge({ topMode: "continuous" })]]) {
            let prevTop = Infinity, prevSlim = Infinity, okMono = true, okJoin = true, okSpan = true, saw = "";
            const steps = [0, 0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 0.99, 0.999, 1];
            for (const h of steps) {
                const b = byId(S.bars(c, W, H, S.lengthsFor(c, "eDP-1", W, {}), h));
                const topIds = Object.keys(b).filter(id => b[id].edge === "top");
                const top = b[topIds[0]].thickness, slim = b.bottom.thickness;
                if (!topIds.every(id => b[id].thickness === top) || !(b.right.thickness === slim && b.left.thickness === slim)) { okSpan = false; saw = "thicknesses differ at " + h; }
                if (top > prevTop + 1e-9 || slim > prevSlim + 1e-9) { okMono = false; saw = "thickens at " + h; }
                prevTop = top; prevSlim = slim;
                // the side bars start on the top bars' face and end on the bottom bar's face, every step of the way
                for (const id of ["right", "left"]) {
                    if (Math.abs(b[id].rawPos - top) > 1e-9 || Math.abs(b[id].rawPos + b[id].rawLen - (H - slim)) > 1e-9) {
                        okJoin = false;
                        saw = id + " at hide " + h + ": spans " + b[id].rawPos + " .. " + (b[id].rawPos + b[id].rawLen) + " against the faces " + top + " / " + (H - slim);
                    }
                }
            }
            ok("hide (" + mode + "): the top bars and the slim bars each share one thickness at every step", okSpan, saw);
            ok("hide (" + mode + "): the thickness only falls as the toggle goes", okMono, saw);
            ok("hide (" + mode + "): the side bars stay joined to the top and the bottom bars at every step, to the last", okJoin, saw);
        }
    }

    // ---- the island lengths on their way (round 2, item 7) -------------------------------------------
    {
        const from = { left: 400, centre: 380, right: 420 }, to = { left: 520, centre: 300, right: 420 };
        eq("lengths: at 0 they are the ones it starts from, at 1 exactly the target", [S.lengthsAt(from, to, 0), S.lengthsAt(from, to, 1)], [from, to]);
        eq("lengths: past the ends they stay on them", [S.lengthsAt(from, to, -0.5), S.lengthsAt(from, to, 3)], [from, to]);
        let integer = true, monoL = true, monoC = true, prev = null, seen = [];
        for (let i = 0; i <= 40; i++) {
            const m = S.lengthsAt(from, to, i / 40);
            integer = integer && Number.isInteger(m.left) && Number.isInteger(m.centre) && Number.isInteger(m.right);
            if (prev) {
                monoL = monoL && m.left >= prev.left;
                monoC = monoC && m.centre <= prev.centre;
            }
            seen.push(m.left);
            prev = m;
        }
        ok("lengths: whole pixels on every step (an island's edges stay on the grid)", integer);
        ok("lengths: a growing island only grows and a shrinking one only shrinks", monoL && monoC);
        ok("lengths: it passes through many values on the way (not a jump)", new Set(seen).size >= 30, new Set(seen).size + " distinct values");
        eq("lengths: an island that does not change stays where it is", S.lengthsAt(from, to, 0.37).right, 420);
        ok("lengths: sameLengths", S.sameLengths(from, { left: 400, centre: 380, right: 420 }) && !S.sameLengths(from, to));
        // A retarget from where it is: the new trip starts at the current lengths.
        const cur = S.lengthsAt(from, to, 0.4);
        eq("lengths: a retarget starts exactly where the clock stands", S.lengthsAt(cur, { left: 450, centre: 330, right: 420 }, 0), cur);
        // The held input region.
        const W = 2880, H = 1620;
        const held1 = S.maskUnion(null, cfg, W, H, [from, to]);
        const rect = (L, id) => { const b = S.bars(cfg, W, H, L, 0).find(x => x.barId === id); return { x0: b.rawPos, x1: b.rawPos + b.rawLen }; };
        let covers = true;
        for (const id of ["topL", "topC", "topR"]) {
            const r = held1[id], a = rect(from, id), c = rect(to, id), m = rect(S.lengthsAt(from, to, 0.5), id);
            covers = covers && r.x0 <= Math.min(a.x0, c.x0, m.x0) && r.x1 >= Math.max(a.x1, c.x1, m.x1) && r.y0 === 0 && r.y1 === S.TOP;
        }
        ok("mask hold: an island's rect covers where it stands at the start, at the target and half way", covers, JSON.stringify(held1));
        const to2 = { left: 450, centre: 330, right: 420 };
        const held2 = S.maskUnion(held1, cfg, W, H, [S.lengthsAt(from, to, 0.4), to2]);
        ok("mask hold: a retarget keeps covering what was held (it only grows until the move ends)",
            ["topL", "topC", "topR"].every(id => held2[id].x0 <= held1[id].x0 && held2[id].x1 >= held1[id].x1), JSON.stringify(held2));
        eq("mask hold: the continuous bar has no islands to hold", S.maskUnion(null, S.merge({ topMode: "continuous" }), W, H, [from, to]), {});
    }

    // ---- the engine's body budget (E1.md) --------------------------------------------
    {
        const list = S.bars(cfg, W, H, L);
        eq("budget: six bars and the slot stack (primary, spare, 3 children, lane, OSD) are 13 bodies -- one over the field's 12",
            S.budget(list), { bars: 6, slots: 7, total: 13, max: 12, fits: false });
        eq("budget: without the spare (a popup closing in place) the stack is 12 and fits",
            S.budget(list, { primary: 1, spare: 0, children: 3, lane: 1, osd: 1 }).fits, true);
        eq("budget: continuous has four bars and always fits", S.budget(S.bars(S.merge({ topMode: "continuous" }), W, H, L)).fits, true);
        eq("mask: the slim bars out of the input region, the mask is 11 rects of GooeyMask's 16", S.maskRects(list), 11);
        ok("mask: even the most it can ask for fits the 16", S.maskRects(list) <= 16);
    }
    // ---- the traffic figures' margin (AerialBarButton): the pill grows into the gap, so the gap pays for it ----
    {
        eq("traffic: the default ink gap leaves 8 px clear beside a pill grown by TRAFFIC_REACH (14: three figures in Audiowide)", [S.TRAFFIC_REACH, cfg.inkGap - S.TRAFFIC_REACH], [14, 8]);
        const natural = S.naturalLength(cfg, "right", {});
        const R = ["player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "notifications"];
        let want = (cfg.inkGap - S.INK.player[0]) + (cfg.inkGap - S.INK.notifications[1]) + (28 + 52 + 52 + 28 + 28 + 108 + 32 + 32);
        for (let i = 1; i < R.length; i++)
            want += cfg.inkGap - S.INK[R[i - 1]][1] - S.INK[R[i]][0];
        eq("traffic: a grown pill is a paint, not a width: the right island's natural length counts the pill's slot only", natural, want);
    }
    // ---- .examples/shell.jsonc documents the defaults exactly -----------------------------------------------------
    {
        const jc = {}; vm.createContext(jc);
        vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "..", "modules", "common", "components", "JsonComments.js"), "utf8").replace(/^\.pragma.*$/m, "") + "\nthis.JC = { strip };", jc);
        const text = fs.readFileSync(path.join(__dirname, "..", "..", ".examples", "shell.jsonc"), "utf8");
        let ex = null;
        try { ex = JSON.parse(jc.JC.strip(text)); } catch (e) { ok("example: parses with comments stripped", false, String(e)); }
        if (ex) {
            eq("example: merges to exactly the defaults (every key documented at its default)", S.merge(ex), S.defaults());
            // The file's other keys are not the layout's (ShellScale's, ThemeControl's ...): that every key of the example is one the shell takes
            // is config_spec_check.js's. The layout's constants are ShellConfig.qml's, not the file's.
            const consts = ["inkGap", "minVoid", "titleSlot", "workspacesScale", "workspacesPitch", "workspacesWidth", "joint"];
            eq("example: names every top-level key of the defaults that is the file's",
               Object.keys(S.defaults()).filter(k => consts.indexOf(k) < 0 && ex[k] === undefined), []);
            eq("example: names every module once, each at its default (on)", [Object.keys(ex.modules).slice().sort(), Object.keys(ex.modules).every(k => ex.modules[k] === true)],
               [S.MODULES.slice().sort(), true]);
            eq("example: its modules switch nothing off", S.modulesOf(ex.modules), { off: {}, problems: [] });
            eq("example: geoclueAgent is documented at its default (off)", ex.geoclueAgent, false);
            eq("example: hoverCursor is documented at its default (off)", ex.hoverCursor, false);
        }
    }

    // ---- the module switches ----
    eq("modules: no key, nothing off", S.modulesOf(undefined), { off: {}, problems: [] });
    eq("modules: an exact false is off, true is on", S.modulesOf({ silicon: false, weather: true }), { off: { silicon: true }, problems: [] });
    eq("modules: 0, null, \"no\" switch nothing off and are said", (r => [r.off, r.problems.length])(S.modulesOf({ silicon: 0, weather: null, stocks: "no" })), [{}, 3]);
    eq("modules: a name that is none, and one that cannot be switched, are said", S.modulesOf({ silikon: false, clock: false, launcher: false }),
       { off: {}, problems: ["modules: \"silikon\" is no module", "modules: \"clock\" cannot be switched off", "modules: \"launcher\" cannot be switched off"] });
    eq("modules: the network popup under its old name", S.modulesOf({ network: false }), { off: { aerial: true }, problems: [] });
    eq("modules: the picker goes with the clipboard it pastes through", S.modulesOf({ clipboard: false }).off, { clipboard: true, picker: true });
    eq("modules: a list is no switch", S.modulesOf(["silicon"]).off, {});
    eq("modules: nothing off leaves every zone as it was", S.merge({}, undefined, {}), S.merge({}));
    {
        const all = S.merge({}), some = S.merge({}, undefined, { silicon: true, weather: true });
        const flat = z => [].concat(z.left, z.centre, z.right);
        eq("modules: a switched-off module stands in no zone, the rest in their order", flat(some.zones), flat(all.zones).filter(id => id !== "silicon" && id !== "weather"));
        eq("modules: also when the file's own zones name it", flat(S.merge({ zones: { right: ["silicon", "volume"] } }, undefined, { silicon: true }).zones).indexOf("silicon"), -1);
    }

    // ---- which displays get the bars ----
    const outs = ["DP-1", "eDP-1", "HDMI-A-1"];
    eq("bars: all", S.barOutputs(outs, "all"), outs);
    eq("bars: the laptop's own panel", S.barOutputs(outs, "internal"), ["eDP-1"]);
    eq("bars: internal on a machine with none is all", S.barOutputs(["DP-1"], "internal"), ["DP-1"]);
    eq("bars: the named ones, in the screens' order", S.barOutputs(outs, ["HDMI-A-1", "DP-1"]), ["DP-1", "HDMI-A-1"]);
    eq("bars: all but one", S.barOutputs(outs, ["!HDMI-A-1"]), ["DP-1", "eDP-1"]);
    eq("bars: a list that leaves none is all", S.barOutputs(outs, ["DP-9"]), outs);
    eq("bars: leaving every one out is all", S.barOutputs(["DP-1"], ["!DP-1"]), ["DP-1"]);
    // ---- a bar that shows its own workspaces alone ----
    const ws = [{ id: 1, screen: "DP-1" }, { id: 3, screen: "eDP-1" }, { id: 7, screen: "DP-1" }, { id: 9, screen: "" }];
    eq("workspaces: the screen's own", S.workspacesOn(ws, "DP-1").map(w => w.id), [1, 7]);
    eq("workspaces: of the always shown, not the ones that are on another screen", S.workspacesKept([1, 2, 3, 4, 9], ws, "DP-1"), [1, 2, 4, 9]);

    return { n, bad };
}

const arms = process.argv.includes("--arms");
const clean = run(null);
if (!arms) {
    console.log("SHELL-LAYOUT RESULT " + (clean.bad ? "FAIL" : "PASS") + " (" + (clean.n - clean.bad) + "/" + clean.n + ")");
    process.exit(clean.bad ? 1 : 0);
}
let allRed = clean.bad === 0;
if (!allRed) console.log("the clean run is not green");
const realLog = console.log;
for (const a of Object.keys(ARMS).concat(Object.keys(QML_ARMS))) {
    const lines = [];
    console.log = (s) => lines.push(s);
    const r = run(a);
    console.log = realLog;
    const red = r.bad > 0;
    console.log("ARM " + a + ": " + (red ? "red on " + lines[0].slice(0, 90) : "STAYED GREEN"));
    if (!red) allRed = false;
}
console.log("SHELL-LAYOUT ARMS " + (allRed ? "PASS" : "FAIL"));
process.exit(allRed ? 0 : 1);
