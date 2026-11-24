"use strict";
// scenes/silicon.js -- silicon's description for tools/dev/board_gen (gen.js): the paths, the groups, the geometry, and every piece of generated GLSL that
// is silicon's own (the 7-segment displays' tables, the parts' decal numbers, the battery event's flow tables, the contact darkening's classes, the CPU's
// cores and the battery's cells). The generic machinery (the cast, the rows, the traces, the markers) is lib/.
const fs = require("fs");
const path = require("path");
const { f, v3, v2 } = require("../lib/fmt.js");

const ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const SRC = path.join(ROOT, "modules/silicon/shaders/src");
const BOARD_SRC = path.join(ROOT, "modules/common/board/shaders");
// The pieces that moved to the toolkit and were silicon's own @@INCLUDEs: the generated header still names them where they were (a header line is
// a comment, but the shaders are held byte for byte). The toolkit's smaller pieces, which board_materials.glsl includes in turn, are not listed.
const LEGACY_LABEL = { "seg7.glsl": "modules/silicon/shaders/src/seg7.glsl", "holo_common.glsl": "modules/silicon/shaders/src/holo_common.glsl" };
const GEOM_JS = path.join(ROOT, "modules/silicon/scene/SceneGeometry.js");

function loadGeometry() {
    const src = fs.readFileSync(GEOM_JS, "utf8").replace(/^\.pragma.*$/m, "");
    return JSON.parse(new Function(src + "; return json();")());
}

// group ids shared with the templates
const GROUP = { board: 0, pkg: 1, card: 2, plug: 3, lever: 4, lock: 5, shackle: 6, hdmi: 7 };

// the numbers more than one shader leans on, from SceneGeometry (one source: GROOVE, LENS, BLEND_K)
function constantsLines(G) {
    return [
        `const float GROOVE_DEPTH = ${f(G.GROOVE.depth)};         // mm: Material's carved grooves (the board draws them, the glow lights their floor)`,
        `const float BLEND_K = ${f(G.BLEND_K)};                // mm: where traces of one blend group come closer than this they melt into one`,
        `const float LENS_CPU = ${f(G.LENS.cpu)};              // mm: each hologram's lens ring on its anchor`,
        `const float LENS_GPU = ${f(G.LENS.gpu)};`,
        `const float LENS_GPU_RING = ${f(G.LENS.gpuRing)};         // the GPU's big ring, drawn above its anchor`,
        `const float LENS_BEAM = ${f(G.LENS.beam)};`,
        `const float LENS_DISC = ${f(G.LENS.disc)};              // the disc's radius, in lens radii`,
        `const float LENS_RING_FALL = ${f(G.LENS.ringFall)};         // the ring's falloff, mm`,
        `const float BEAM_FAN_W0 = ${f(G.LENS.fanW0)};            // the integrated beam's fan: its width at the tile, mm`,
        `const float BEAM_FAN_W1 = ${f(G.LENS.fanW1)};            //   the width it adds by the card`,
        `const float BEAM_FAN_BACK = ${f(G.LENS.fanBack)};         //   where its density starts, behind the tile, as a share of its length`
    ];
}

// The 7-segment displays (SceneGeometry.SEG7), the figures printed on the board and the glyph atlas they are cut from. Everything a
// shader needs to find a display from a board point: which display a part is, its window, its first cell, its cell count.
function segmentLines(G) {
    const S = G.SEG, L = [];
    L.push("// ---- the 7-segment displays (SceneGeometry.SEG7), the printed figures and the glyph atlas ----");
    L.push(`const float SEG_H = ${f(S.h)};`, `const vec2 SEG_CELL = ${v2(S.cell[0], S.cell[1])};            // a digit's width and height, mm`,
           `const float SEG_STROKE = ${f(S.stroke)};`, `const float SEG_GAP = ${f(S.gap)};            // the clear space between two segments at a joint`, `const float SEG_PITCH = ${f(S.pitch)};`,
           `const float SEG_COLON_GAP = ${f(S.colonGap)};`, `const float SEG_PAD = ${f(S.pad)};`, `#define SEG_COUNT ${G.SEG7.length}`);
    const byIndex = (fn, dflt) => G.SEG7.map((d, i) => `    if (i == ${i}) return ${fn(d)};`).concat([`    return ${dflt};`]);
    L.push("int segIndexOf(int part) {", ...G.SEG7.map((d, i) => `    if (part == PART_${d.name.toUpperCase()}) return ${i};`), "    return -1;", "}");
    L.push("vec4 segWindow(int i) {", ...byIndex((d) => `vec4(${d.window.map(f).join(", ")})`, "vec4(0.0)"), "}");
    L.push("vec2 segCell0(int i) {", ...byIndex((d) => v2(d.cell0[0], d.cell0[1]), "vec2(0.0)"), "}");
    L.push("int segCells(int i) {", ...byIndex((d) => d.cells, "4"), "}");
    L.push("bool segHasColon(int i) {", ...byIndex((d) => (d.colon ? "true" : "false"), "false"), "}");
    // the printed figures: right edge, row centre, digit height and pitch of each line, and the glyph atlas's layout (mm)
    const T = G.FIGTEXT, Gl = G.GLYPHS, M = G.MODE_LABEL;
    L.push(`#define TXT_CELLS ${T.cells}`, `#define TXT_LINES ${T.lines.length}`,
           `const vec4 TXT_LINE0 = vec4(${f(T.lines[0].xEnd)}, ${f(T.lines[0].z)}, ${f(T.size)}, ${f(T.pitch)});     // x of the right edge, z of the row's centre, digit height, pitch`,
           `const vec4 TXT_LINE1 = vec4(${f(T.lines[1].xEnd)}, ${f(T.lines[1].z)}, ${f(T.size)}, ${f(T.pitch)});`);
    L.push(`const vec4 MODE_LABEL_RECT = vec4(${f(M.x - M.w / 2)}, ${f(M.z - M.h / 2)}, ${f(M.x + M.w / 2)}, ${f(M.z + M.h / 2)});     // the time display's printed label (one of ${G.MODE_LABELS.length})`,
           `const vec2 MODE_LABEL_SIZE = ${v2(M.w, M.h)};`);
    // the captions of the figures and the chips' names are printed in the deeper ink of data too: a rect round each. Round 5 (L1): the rect is the label's REAL ink box
    // (tools/silicon/make_silkscreen.py measures the glyphs of both faces: assets/silkscreen_labels.json) grown by the carve's rim (0.6 mm: where the shader still shades a
    // letter), not a generous glyph extent: the CPU's name ("ULTRA 9 185H") was a rect 29.6 mm wide that reached 0.95 mm over the right stroke of the "U" in the CPU's own
    // label, which took the data ink. A label the file does not know (no box, or another text at its place) keeps the old estimate (centre +- 0.5 an em a glyph).
    const data = G.LABELS.map((l) => ({ l })).filter((e) => e.l.data);
    let boxes = [];
    try {
        boxes = JSON.parse(fs.readFileSync(path.join(ROOT, "modules/silicon/assets/silkscreen_labels.json"), "utf8"));
    } catch (e) {
        boxes = [];
    }
    // (found by text and place, not by index: a label added since the mask was last written shifts every index after it, and one the file lacks keeps the estimate)
    const boxOf = (l) => boxes.find((b) => b.text === l.text && l.x >= b.x0 - 1 && l.x <= b.x1 + 1 && Math.abs(l.z - (b.z0 + b.z1) / 2) < 2) || null;
    L.push("bool onDataLabel(vec2 p) {", ...data.map(({ l }) => {
        const bx = boxOf(l);
        if (bx) {
            const m = 0.6;
            return `    if (p.x > ${f(bx.x0 - m)} && p.x < ${f(bx.x1 + m)} && p.y > ${f(bx.z0 - m)} && p.y < ${f(bx.z1 + m)}) return true;`;
        }
        const hx = 0.5 * l.size * l.text.length + 0.4, cx = l.anchor === "right" ? l.x - hx + 0.4 : l.x;       // (0.5 an em a glyph: RTX 4060's Audiowide runs 0.98)
        return `    if (abs(p.x - ${f(cx)}) < ${f(hx)} && abs(p.y - ${f(l.z)}) < ${f(l.size * 0.9)}) return true;`;
    }), "    return false;", "}");
    const atlasW = Gl.chars.length * Gl.cell[0], atlasH = Gl.cell[1] + G.MODE_LABELS.length * M.h;
    L.push(`const vec2 GLYPH_CELL = ${v2(Gl.cell[0], Gl.cell[1])};            // one character's cell in the atlas, mm; row 0 holds ${Gl.chars.length} characters (${Gl.chars}), the labels follow`,
           `const float GLYPH_DIGIT_H = ${f(Gl.digitH)};`, `const vec2 GLYPH_ATLAS = ${v2(atlasW, atlasH)};            // the whole atlas, mm`,
           `const float GLYPH_TEXELS = ${f(Gl.texels)};`, `#define GLYPH_CHARS ${Gl.chars.length}`);
    return L;
}
// The glow's side of the displays: the figure each one shows (uniforms figA, figB, ...: one vec4 of cell codes per display, in
// SEG7's order) and the colour of its lit segments (the charge's, the memory's, the CPU profile's). Spliced where the glow template says `// @@SEGFIG`.
const FIG_NAMES = ["figA", "figB", "figC", "figD", "figE", "figF", "figG"];       // the glow template's uniforms: a display beyond them has none to read
const SEG_LIT = { charge: "colCharge.rgb", memory: "palM.rgb", cpu: "cpuInk(colCpu.rgb)" };
function segFigBlock(G) {
    const L = ["// ---- the displays' figures and lit colours (generated from SceneGeometry.SEG7) ----"];
    if (G.SEG7.length > FIG_NAMES.length)
        throw new Error(`SceneGeometry.SEG7 has ${G.SEG7.length} displays and the glow has ${FIG_NAMES.length} figure uniforms (add figH ... to silicon_glow.frag.in, GlowLayer.qml and SiliconScene.qml)`);
    G.SEG7.forEach((d) => {
        if (!SEG_LIT[d.colour])
            throw new Error(`${d.name}: no lit colour for "${d.colour}" (SEG_LIT)`);
    });
    L.push("vec4 segFig(int i) {", ...G.SEG7.map((d, i) => `    if (i == ${i}) return ${FIG_NAMES[i]};`), "    return vec4(11.0);", "}");
    L.push("vec3 segLit(int i) {", ...G.SEG7.map((d, i) => `    if (i == ${i}) return ${SEG_LIT[d.colour]};`), "    return colCharge.rgb;", "}");
    return L.join("\n");
}

// The numbers of the parts the shaders' decals and cutouts lean on (cutouts.glsl, board_materials.glsl, glow_materials.glsl): the card's
// I/O bracket and fingers, the RAM's sockets, sticks and chip rows, the display ribbon, its connector and the display's path. One source: SceneGeometry.
function partsConstantsLines(G) {
    const Bk = G.BRACKET, T = Bk.tongue, H = Bk.hdmi, V = Bk.vents, R = G.RIBBON, F = G.CARD.fingers, M = G.RAM, CN = G.CONNECTOR;
    const ST = M.stick, stickX = M.x0.map((x0) => [x0 + M.wall, x0 + M.len - M.wall]);
    const stickRect = (k) => [stickX[k][0], M.zFront - ST.inset, stickX[k][1], M.zFront + ST.depth];
    const sockRect = (k) => [M.x0[k], M.z0, M.x0[k] + M.len, M.wallZ1];
    return [
        "// ---- the bracket's, the card fingers', the RAM's and the ribbon's numbers (SceneGeometry: BRACKET, CARD.fingers, RAM, RIBBON) ----",
        `const vec2 BRK_X = ${v2(Bk.x0, Bk.x1)};                 // the plate's x extent`,
        `const vec4 BRK_PLATE = vec4(${f(Bk.z0)}, ${f(Bk.y0)}, ${f(Bk.z1)}, ${f(Bk.y1)});     // the plate's outline, [z0, y0, z1, y1]`,
        `const float BRK_R = ${f(Bk.r)};`,
        `const vec4 BRK_TONGUE = vec4(${f(T.zc)}, ${f(T.hw0)}, ${f(T.hw1)}, ${f(T.r)});     // the tongue: centre z, half width at the plate, half width at the tip, tip radius`,
        `const vec2 BRK_TONGUE_Y = ${v2(T.y0, Bk.y0)};            // tip y, root y`,
        `const vec4 BRK_HDMI = vec4(${f(H.zc)}, ${f(H.yc)}, ${f(H.w)}, ${f(H.h)});     // the receptacle: centre z, centre y, width, height`,
        `const float BRK_HDMI_CHAMFER = ${f(H.chamfer)};`,
        `const vec4 BRK_VENT = vec4(${f(V.z0)}, ${f(V.pitch)}, ${f(V.n)}, ${f(V.w)});     // first slot's z, pitch, count, width`,
        `const vec2 BRK_VENT_Y = ${v2(V.y0, V.y1)};`,
        `const vec3 BRK_NOTCH = vec3(${f(Bk.x1 + (Bk.lip.x1 - Bk.x1) * 0.55)}, ${f(Bk.lip.notchZ)}, ${f(Bk.lip.notchR)});     // the flange's screw notch: x, z, radius`,
        `const float DIP_CZ = ${f(G.DIP.cz)};                // the DIP switch's window and lever travel: the middle of its depth (its top face's front margin carries the 80 / 100)`,
        `const vec4 FINGERS_RECT = vec4(${f(F.x0)}, ${f(F.z0)}, ${f(F.x1)}, ${f(F.z1)});     // the card's gold fingers (card frame = board frame in x z)`,
        `const vec2 FINGERS = ${v2(F.pitch, F.w)};                // pitch, width`,
        `const float RIB_W = ${f(R.w)};                    // the ribbon's width, mm`,
        `const vec4 RIB_P = vec4(${f(R.cx)}, ${f(R.zA)}, ${f(R.r)}, ${f(R.run)});     // its centre line: the first leg's x, where the first bend starts (z), the bends' radius, the straight stretch between them`,
        `const vec4 RIB_A = vec4(${f(Math.sin(R.bend * Math.PI / 180))}, ${f(Math.cos(R.bend * Math.PI / 180))}, ${f(R.bend * Math.PI / 180)}, ${f(R.zStart)});     // the bends' angle (sin, cos, radians) and where the strip starts (z): the arc length is counted from there`,
        `const float RIB_FADE = ${f(R.fade0)};                  // the arc length where the ribbon begins to fade (mm along its centre line)`,
        `const float CABLE_FADE_LEN = ${f(G.CABLE_FADE.len)};         // a cable's fade, the charger's and the ribbon's: a smoothstep over this many mm (cutouts.glsl cableFade)`,
        `const float CABLE_FADE_X = ${f(G.CABLE.x0 + G.CABLE.fade0)};          // where the charger's cable begins it (the plug's own frame, x)`,
        `const float RIB_N = ${f(R.conductors)};           // conductors across the ribbon`,
        `const vec4 CONN_SLOT = vec4(${f(CN.slot.x0)}, ${f(CN.slot.x1)}, ${f(CN.slot.y0)}, ${f(CN.slot.y1)});     // the slot the ribbon enters on the connector's front face: x0 x1 y0 y1`,
        `const vec4 RAM_STICKA = vec4(${stickRect(0).map(f).join(", ")});     // each stick's plate, [x0, z0, x1, z1] (its connector edge lies \`inset\` inside the housing)`,
        `const vec4 RAM_STICKB = vec4(${stickRect(1).map(f).join(", ")});`,
        `const vec4 RAM_SOCKA = vec4(${sockRect(0).map(f).join(", ")});     // each socket's footprint, [x0, z0, x1, z1]: the housing along the back and an end wall at each short end`,
        `const vec4 RAM_SOCKB = vec4(${sockRect(1).map(f).join(", ")});`,
        `const vec2 RAM_SOCK = ${v2(M.zFront, M.wall)};                // the housing's front face (z) and an end wall's thickness`,
        `const vec4 RAM_NOTCH = vec4(${f(M.zFront + ST.notchZ)}, ${f(ST.notchR)}, ${f(ST.tooth[0])}, ${f(ST.tooth[1])});     // the notch in a stick's short edge: its centre z, radius, and the tooth left in it (depth, half width)`,
        `const float RAM_STICK_R = ${f(ST.r)};              // the plate's corner radius`,
        `const vec4 RAM_CAPA = vec4(${f(stickX[0][0] + M.caps.a.dx)}, ${f(M.caps.a.z)}, ${f(M.caps.pitch)}, ${f(M.caps.a.n)});     // the MLCCs painted on stick A's plate: the first pad's min x z, the pitch, the count`,
        `const vec4 RAM_CAPB = vec4(${f(stickX[1][0] + M.caps.b.dx)}, ${f(M.caps.b.z)}, ${f(M.caps.pitch)}, ${f(M.caps.b.n)});`,
        `const vec2 RAM_CAP = ${v2(M.caps.cell[0], M.caps.cell[1])};                // one pad's size (x, z)`,
        `const vec4 RAM_ROWX = vec4(${f(stickX[0][0] + M.chip.dx)}, ${f(stickX[1][0] + M.chip.dx)}, ${f(M.chip.pitch)}, ${f(M.chip.skip)});     // the chip rows' first cell x on stick A and on B, the pitch, the cell left out (the gap)`,
        `const float RAM_UNITS = ${f(M.units)};`,
    ];
}

// The flow's per-trace constants (the glow only; SceneGeometry.js: THE FLOW): which train a trace carries and how it fades, where its colour changes, and where
// it is on the dGPU-only display path. A trace with the default answer has no line (the function returns the default).
const EVENT = require("../../silicon_event_walk.js");     // the battery event's walks and ITS NUMBERS (EVENT.PULSE: speed, reach, the trains' envelope)
function flowTables(G) {
    const L = ["// THE FLOW (SceneGeometry.js): traceFlowA(id) = (channel: 0 power into the package, 1 the package's traffic out, 2 charge, 3 the card's power;",
               "//   the fade's kind: 0 none, 1 while the dGPU does not listen, 2 always; where it starts and ends along the route, mm of the flow coordinate)",
               "vec4 traceFlowA(int id) {"];
    G.TRACES.forEach((t, id) => L.push(`    if (id == ${id}) return vec4(${t.ch}.0, ${t.fade.kind}.0, ${f(t.fade.a)}, ${f(t.fade.b)});`));
    L.push("    return vec4(1.0, 0.0, 0.0, 1.0);", "}");
    L.push("// traceFlowB(id) = (the dGPU's hue takes over from, to: mm of the flow coordinate)", "vec2 traceFlowB(int id) {");
    G.TRACES.forEach((t, id) => {
        if (t.hand.a < 1e3)
            L.push(`    if (id == ${id}) return vec2(${f(t.hand.a)}, ${f(t.hand.b)});`);
    });
    L.push("    return vec2(10000.0, 10001.0);", "}");
    L.push("// traceDisp(id) = where the dGPU-only display path's share rises over the flow coordinate, from, to (below 0 it is on the path whole, above 1000 not on it)",
           "vec2 traceDisp(int id) {");
    G.TRACES.forEach((t, id) => {
        if (t.disp.m0 < 1e3)
            L.push(`    if (id == ${id}) return vec2(${f(t.disp.m0)}, ${f(t.disp.m1)});`);
    });
    L.push("    return vec2(10000.0, 10001.0);", "}");
    L.push(...eventTable(G));
    return L;
}

// The battery event's pulse as data (tools/dev/silicon_event_walk.js: the walks of one pulse over the trace graph): the waves that run on each trace, in one flat list
// (trace by trace), evtAt(i) = (c, dir, from): the pulse's distance from the pack at arc a of the trace is c + dir * a, for the arcs ahead of `from` in the way it
// runs. A balanced tree of ifs picks the entry: one jump a level, where a chain of compares per entry cost 14 instructions each.
function eventTable(G) {
    const P = EVENT.PULSE;
    const W = EVENT.walk(G, { maxDist: P.walkTo });
    const flat = [], base = [], shared = new Map();
    W.entries.forEach((es, id) => {
        // a wave that enters at a trace's own END has no limit: the pulse slides over the round cap with the copper's coverage, as the trains do (a limit at the end is a cut across the cap)
        const mine = es.slice().sort((a, b) => a.c - b.c).map((e) => e.dir > 0 && e.from <= 1e-9 ? Object.assign({}, e, { from: -1e4 }) : (e.dir < 0 && e.from >= G.TRACES[id].length - 1e-9 ? Object.assign({}, e, { from: 1e4 }) : e));
        // traces with the SAME waves (the front T's stem and the lane it ends on) share one run of the table, as the code is the cost of a wave (3.4 SIMD8 instructions each)
        const key = mine.map((e) => `${f(e.c)},${f(e.dir)},${f(e.from)}`).join(";");
        if (mine.length && shared.has(key)) {
            base.push(shared.get(key));
            return;
        }
        base.push(flat.length);
        if (mine.length)
            shared.set(key, flat.length);
        flat.push(...mine);
    });
    const L = [`// THE BATTERY EVENT (tools/dev/silicon_event_walk.js, PULSE): the pulse runs along the traces only, at EVT_SPEED mm/s, into every branch, through the parts the traces join, round`,
               `// every loop, and falls with the distance it has run (EVT_MAXD: gone, at ${f(P.seconds)} s). A trace's waves are evtAt(evtFirst(id)) .. + evtCount(id) - 1: (c, dir, from): at arc a of the`,
               `// trace (ahead of \`from\` in the way it runs, dir +-1) a wave is at distance c + dir * a from the pack. ${flat.length} waves, at most ${Math.max(...W.entries.map((e) => e.length))} on one trace.`,
               `// The passive trains' envelope (evtTrains): out over EVT_DIM_IN s, away while the pulse's strength is over EVT_DIM_AT, back as it falls.`,
               `const float EVT_SPEED = ${f(P.speed)};`,
               `const float EVT_MAXD = ${f(P.maxD)};`,
               `const float EVT_DIM_IN = ${f(P.dimIn)};`,
               `const float EVT_DIM_AT = ${f(P.dimAt)};`];
    L.push("int evtFirst(int id) {");
    base.forEach((b, id) => { if (b > 0 && W.entries[id].length) L.push(`    if (id == ${id}) return ${b};`); });
    L.push("    return 0;", "}", "int evtCount(int id) {");
    W.entries.forEach((es, id) => { if (es.length) L.push(`    if (id == ${id}) return ${es.length};`); });
    L.push("    return 0;", "}", "vec3 evtAt(int i) {");
    const tree = (lo, hi) => {                                     // [lo, hi)
        if (hi - lo === 1) {
            const e = flat[lo];
            return [`return vec3(${f(e.c)}, ${f(e.dir)}, ${f(e.from)});`];
        }
        const mid = (lo + hi) >> 1;
        return [`if (i < ${mid}) {`, ...tree(lo, mid), "} else {", ...tree(mid, hi), "}"];
    };
    L.push(...tree(0, flat.length).map((l) => "    " + l), "}");
    return L;
}

// A part's contact darkening, scaled to its height `h` (mm; see geometryBlock): the reach of the soft band on the board, its peak, and the share (0 .. 1) of the
// lamp-ward shift (2.2 mm) its own cast shadow takes. FOUR CLASSES, not a number a part: the parts of a class share their constants (the compiler holds a part's constants
// in registers through the whole loop the darkening is asked in: every distinct set was a few of them, and 22 sets spilled a dozen).
// The tall class is the battery's own numbers (5.2 mm: reach 2.2, peak h / (h + reach) = 0.70; the jack's 9 mm: 3.2 and 0.74), the others are that, scaled down.
function aoSize(h) {
    if (h >= 4.4)
        return h > 6 ? { reach: 3.2, peak: 0.74, shift: 1 } : { reach: 2.2, peak: 0.70, shift: 1 };
    if (h >= 2.2)
        return { reach: 1.5, peak: 0.67, shift: 0.55 };           // the DIP switch, the sockets and sticks, the chokes, the capacitor
    if (h >= 1.2)
        return { reach: 0.9, peak: 0.64, shift: 0.55 };           // the terminals, the connector, the displays
    return { reach: 0.45, peak: 0.5, shift: 0 };                  // the transistors and MLCCs: a band under a pixel wide, no offset
}

function groupFrame(G) {
    return `
// The frame a group's boxes live in. The caller sets these from its uniforms before casting -- and each starts at its rest pose, because a GLSL global
// that nobody sets is UNDEFINED, not zero: a group a caller does not set stands wherever the driver left it (a lock's box left unset stood
// over the (+) pole's field and hid its particles). A caller that forgets one gets the part at rest.
float gPkgTurn = 0.0;    // the CPU package's turn about the zone centre, radians (a profile change lifts and turns it)
float gPkgLift = 0.0;    // mm the package is lifted while it turns
float gCardLift = 0.0;   // mm
float gPlugOut = 0.0;    // mm the plug is pulled out along +x
float gHdmiOut = 0.0;    // mm the HDMI plug is pulled out along +x
float gLeverX = 0.0;     // mm the lever sits from "80" toward "100"
float gLockX = 0.0;      // mm the lock bar (and its screws and padlock body) stands out along +x from where it rests
float gShackleY = 0.0;   // mm the padlock's shackle is lifted (on top of the bar's own slide)
float gLockA = 0.0;      // the lock's presence 0..1: its shadow is as strong
float gCardA = 1.0;      // the card's presence 0..1 (what is left of it as it dissolves): its shadow on the board and its contact darkening are as strong
// The flags of the cast loop, in ONE float. A pixel is cast again when it finds a group left out of the cast (a dissolved card, a plug or a lock still fading in) or a
// part it is outside the outline of (cutouts.glsl: the cut parts): what the next cast leaves out is carried round the loop, and a float a flag is a register the
// shading of every layer has to hold. Ten of them were that; the cold compile of the board fell by 0.3 s when they became one. The flags are the sum of one power of
// two each, and each is raised AT MOST ONCE: the group or the part it names is left out of the next cast, so it is not found again (raise() adds, it does not test).
// FLAG_CARD: the card group is skipped (a dissolved card pixel is re-cast without it)    FLAG_PLUG: the plug groups are skipped (a fading plug's pixel is re-cast without it;
// the charger's and the HDMI cable's groups share it: no ray meets both)
// FLAG_LOCK: the lock groups are skipped (the lock is not there, or a fading lock's pixel is re-cast without it)${G.PARTS.some((p) => p.cut) ? `
// and one a cut part, left out where the shader found a pixel outside its outline: ${G.PARTS.filter((p) => p.cut).map((p, i) => p.name + " " + 8 * Math.pow(2, i)).join(", ")}.` : ""}
#define FLAG_CARD 1.0
#define FLAG_PLUG 2.0
#define FLAG_LOCK 4.0
float gFlags = 0.0;
bool flagOf(float bit) { return fract(gFlags * (0.5 / bit)) >= 0.5; }
void raise(float bit) { gFlags += bit; }

vec3 rotYAbout(vec3 p, float a) {
    vec2 d = p.xz - ZONE_C;
    float c = cos(a), s = sin(a);
    return vec3(ZONE_C.x + c * d.x - s * d.y, p.y, ZONE_C.y + s * d.x + c * d.y);
}
vec3 rotYDir(vec3 v, float a) {
    float c = cos(a), s = sin(a);
    return vec3(c * v.x - s * v.z, v.y, s * v.x + c * v.z);
}
// world ray -> the group's own frame
void groupRay(int g, vec3 ro, vec3 rd, out vec3 o, out vec3 d) {
    o = ro;
    d = rd;
    if (g == GRP_PKG) {
        o = rotYAbout(ro - vec3(0.0, gPkgLift, 0.0), -gPkgTurn);
        d = rotYDir(rd, -gPkgTurn);
    } else if (g == GRP_CARD) {
        o = flagOf(FLAG_CARD) ? vec3(1e7, -1e7, 1e7) : ro - vec3(0.0, gCardLift, 0.0);
    } else if (g == GRP_PLUG) {
        o = flagOf(FLAG_PLUG) ? vec3(1e7, -1e7, 1e7) : ro - vec3(gPlugOut, 0.0, 0.0);
    } else if (g == GRP_HDMI) {
        o = flagOf(FLAG_PLUG) ? vec3(1e7, -1e7, 1e7) : ro - vec3(gHdmiOut, 0.0, 0.0);
    } else if (g == GRP_LEVER) {
        o = ro - vec3(gLeverX, 0.0, 0.0);
    } else if (g == GRP_LOCK) {
        o = flagOf(FLAG_LOCK) ? vec3(1e7, -1e7, 1e7) : ro - vec3(gLockX, 0.0, 0.0);
    } else if (g == GRP_SHACKLE) {
        o = flagOf(FLAG_LOCK) ? vec3(1e7, -1e7, 1e7) : ro - vec3(gLockX, gShackleY, 0.0);
    }
}
// a hit the shader found outside its part's outline skips that part and casts again
void cutPart(int part) {
${G.PARTS.filter((p) => p.cut).map((p, i) => `    if (part == PART_${p.name.toUpperCase()}) raise(${8 * Math.pow(2, i)}.0);`).join("\n")}
}
// a normal found in the group's frame -> world
vec3 groupNormal(int g, vec3 n) {
    return g == GRP_PKG ? rotYDir(n, gPkgTurn) : n;
}
bool inZone(vec2 p) {
    vec2 d = abs(p - ZONE_C);
    return max(d.x, d.y) < ZONE_HALF;
}`;
}

// the contact darkening (the board's pixel shader only): the parts that stand on the board and on the surfaces above it, as ONE table and one loop
function aoBlock(G, opts) {
    // contact shadow (ambient occlusion) of everything resting near the board, on a board-top point
    // Round 5 (S1, T1): every part standing on the board takes the battery's attachment, SCALED TO ITS SIZE (aoSize: four classes by height). The battery (5.2 mm: reach 2.2)
    // is the model and a part as tall keeps its numbers; a lower one's reach goes with its height (half of it, down to 0.45 mm: the small parts' "subpixel" shading) and the
    // shadow's offset (the second sample, toward the lamp) is the part's own cast length, 0.62 x its height (what the lamp does to a part of that height), not the battery's
    // 2.2 mm for all: a 2 mm terminal's shadow is 1.2 mm, not 2.2. `p` is the board point, `pS` the same point moved toward the lamp by 2.2 mm (the loop's second sample:
    // equal to `p` in its first), `pM` a point between them; a part takes the one its class says.
    // THE TABLE: the contact darkening is ONE loop over a constant table, where ~29 unrolled `a *= aoRect(...)` lines cost 12 SIMD8 instructions each (the five
    // height classes' lines alone were 80 to 130 instructions a class, 471 in all). The rectangles and each one's
    // numbers (peak, the exponent's factor 1 / reach x log2(e), how it is placed) are `const` arrays the driver keeps as constant data and reads with one load an iteration, so a rectangle costs a table
    // row, not twelve instructions -- and room for the parts that stand on PARTS. The arithmetic is the unrolled line's own, in the same order (a product is not
    // associative), the reach as its reciprocal written out the way the compiler folded it (fround(1 / reach)), so the picture is the unrolled lines' to the pixel.
    // LEVELS: the surface the point is on. 0 the board's top; 1 the card PCB's top, 2 the RAM sticks' tops, 3 the battery tray's top: each level's rows are the parts that
    // stand ON that surface (a card's xz is the board's: it only lifts). The kinds: 0 the point itself, 1 / 2 the point toward the lamp (the small / middle classes' 55 % of it,
    // the tall class's all), 3 the package's own frame fading as it lifts, 4 the card's shadow (all of the shift) fading with its lift and dissolve.
    const SURFACE = { cardPcb: 1, ramPcbA: 2, ramPcbB: 2, packTray: 3 };      // a part's `aoOn`: the surface it stands on -> the table's level
    const levels = [[], [], [], []];
    // the exponent's factor: 1 / reach times log2(e), as the compiler folded `exp(-d / reach)` (a constant multiplies into the exp's own log2(e) in float): rounded the same way, so a
    // pixel does not move a level where the table's variable would not have been folded
    const rf = (v) => Math.fround(Math.fround(1 / Math.fround(v)) * Math.fround(Math.LOG2E)).toPrecision(9);
    // a part's rectangles: one, or for a ROW with cells left out (the gap in the middle of a stick's chips) one for each run of cells that are there -- a rectangle over the whole
    // row would darken the empty stick in the gap
    // `apart`: the cells of a row more than a millimetre apart (a column of chokes, a row of capacitors) are a rectangle each, not one over the empty PCB between them
    const rectsOf = (p, apart) => {
        const whole = [p.min[0], p.min[2], p.max[0], p.max[2]];
        if (!p.row || (p.row.skip === undefined && !apart))
            return [whole];
        const sk = [].concat(p.row.skip === undefined ? [] : p.row.skip), alongX = p.row.n[0] > 1, n = alongX ? p.row.n[0] : p.row.n[1];
        const cell = p.row.cell, pitch = alongX ? p.row.pitch[0] : p.row.pitch[1], out = [];
        const split = apart && pitch - (alongX ? cell[0] : cell[2]) > 1.0;
        if (n < 2)
            return [whole];
        for (let a = 0; a < n; a++) {
            if (sk.indexOf(a) >= 0)
                continue;
            let b = a;
            while (!split && b + 1 < n && sk.indexOf(b + 1) < 0)
                b++;
            out.push(alongX ? [p.min[0] + a * pitch, p.min[2], p.min[0] + b * pitch + cell[0], p.max[2]]
                            : [p.min[0], p.min[2] + a * pitch, p.max[0], p.min[2] + b * pitch + cell[2]]);
            a = b;
        }
        return out;
    };
    for (const p of G.PARTS) {
        if (p.name === "board" || p.group === "lever" || p.group === "plug" || p.group === "hdmi" || p.name === "cable")
            continue;
        const lv = p.aoOn ? SURFACE[p.aoOn] : 0;
        if (lv === undefined)
            throw new Error(`${p.name}: aoOn "${p.aoOn}" is not a surface the contact darkening knows`);
        if (lv === 0 && (p.ao === false || (p.min[1] > 0.01 && p.group !== "card" && !p.aoFloat) || (p.group === "card" && p.name !== "cardPcb")))
            continue;      // only what rests on the board (the card: its PCB's shadow under it; `aoFloat`: a plate held above the board, a RAM stick, shades what is under it)
        const h = lv === 0 ? p.max[1] : p.max[1] - p.min[1];
        let c;
        if (lv === 0 && p.group === "pkg")
            c = `vec3(${f(h / (h + 2.4))}, ${rf(2.4)}, 3.0)`;
        else if (lv === 0 && p.name === "cardPcb")
            c = `vec3(${f(2.0 / 7.0)}, ${rf(5.0)}, 4.0)`;
        else {
            const sz = aoSize(h);
            c = `vec3(${f(sz.peak)}, ${rf(sz.reach)}, ${sz.shift >= 0.995 ? "2.0" : (sz.shift <= 0.02 ? "0.0" : "1.0")})`;
        }
        for (const q of rectsOf(p, lv > 0))
            levels[lv].push([`vec4(${f((q[0] + q[2]) / 2)}, ${f((q[1] + q[3]) / 2)}, ${f((q[2] - q[0]) / 2)}, ${f((q[3] - q[1]) / 2)})`, c]);
    }
    const flatAo = levels.flat();
    const lo = [0], N = flatAo.length;
    levels.forEach((l, i) => lo.push(lo[i] + l.length));
    const ao = ["", "// Contact darkening on a surface's top face at p (board space) from the parts that stand on it; `lvl` says which surface (the table above, in the generator).",
                "// A row is a rectangle as its centre and half extents (x z hx hz): |p - c| - h is the box's signed distance per axis, three instructions an axis where the",
                "// rectangle's corners took four.",
                "float aoRect(vec2 p, vec4 r, float peak, float expK) {",
                "    vec2 q = max(abs(p - r.xy) - r.zw, vec2(0.0));",
                "    return 1.0 - exp2(-length(q) * expK) * peak;",
                "}",
                `const int AO_N = ${N};`,
                `const vec4 AO_R[${N}] = vec4[${N}](`,
                flatAo.map((e) => "    " + e[0]).join(",\n"),
                ");",
                `const vec3 AO_C[${N}] = vec3[${N}](`,
                flatAo.map((e) => "    " + e[1]).join(",\n"),
                ");",
                "// (ao at p, ao with the lamp-ward point `sh` away) -- the second only when `two` is 2. ONE loop over the rows and, when asked, the second sample's rows after the first's:",
                "// no loop inside a loop, and the rows are read where they are used",
                "vec2 sceneAo(vec2 p, vec2 sh, int lvl, int two) {",
                "    vec2 a = vec2(1.0);",
                `    int i0 = lvl == 0 ? ${lo[0]} : (lvl == 1 ? ${lo[1]} : (lvl == 2 ? ${lo[2]} : ${lo[3]}));`,
                `    int n = (lvl == 0 ? ${lo[1] - lo[0]} : (lvl == 1 ? ${lo[2] - lo[1]} : (lvl == 2 ? ${lo[3] - lo[2]} : ${lo[4] - lo[3]})));`,
                "    for (int j = 0; j < n * two; j++) {",
                "        int k = j >= n ? 1 : 0;",
                "        int i = i0 + j - k * n;",
                "        vec4 r = AO_R[i];",
                "        vec3 c = AO_C[i];",
                "        vec2 pS = k == 0 ? p : p + sh;",
                "        // the point each class takes (aoSize): the middle and the small class 1.2 mm toward the lamp (the shadow a 2 mm part casts), the tall class all of the shift;",
                "        // the package's own frame turns its contact shadow with it. Made where they are asked: held across the loop they were registers the loop spilled",
                "        vec2 at = c.z < 0.5 ? p : (c.z < 1.5 ? mix(p, pS, 0.55) : (c.z < 3.5 && c.z > 2.5 ? rotYAbout(vec3(pS.x, 0.0, pS.y), -gPkgTurn).xz : pS));",
                "        float v = aoRect(at, r, c.x, c.y);",
                "        if (c.z > 2.5)",
                "            v = mix(v, 1.0, c.z < 3.5 ? clamp(gPkgLift / 12.0, 0.0, 1.0) : clamp(max(gCardLift / 30.0, 1.0 - gCardA), 0.0, 1.0));",
                "        if (k == 0)",
                "            a.x *= v;",
                "        else",
                "            a.y *= v;",
                "    }",
                "    return a;",
                "}"];

    return ao.join("\n");
}

function preludeLines(G) {
    const L = [];
    const Z = G.ZONE, B = G.BOARD;
    L.push(`const vec2 ZONE_C = ${v2(Z.cx, Z.cz)};`);
    L.push(`const float ZONE_HALF = ${f(Z.half)};`);
    L.push(`const float ZONE_COURTYARD = ${f(Z.courtyard)};`);
    L.push(`const vec4 BOARD_RECT = vec4(${f(B.x0)}, ${f(B.z0)}, ${f(B.x1)}, ${f(B.z1)});   // x0 z0 x1 z1`);
    L.push(`const vec2 BOARD_Y = vec2(${f(B.y0)}, ${f(B.y1)});`);
    L.push(`const float PLUG_TRAVEL = ${f(G.PLUG.travel)};`);
    L.push(`const float HDMI_TRAVEL = ${f(G.HDMI.travel)};      // mm the HDMI plug waits out along +x (motion.y)`);
    L.push(`const vec2 HDMI_FADE = ${v2(G.HDMI.fade[0], G.HDMI.fade[1])};      // along x, in the cable's frame, where the HDMI cable fades to nothing`);
    L.push(`const float LOCK_TRAVEL = ${f(G.LOCK.travel)};        // mm the lock bar waits out along +x (its slide: lockP.x)`);
    L.push(`const float LEVER_TRAVEL = ${f(G.LEVER.xHigh - G.LEVER.xLow)};`);
    L.push(`const vec4 CELL_TOP = vec4(${f(G.CELL_TOP)}, 0.0, 0.0, 0.0);`);
    L.push(...partsConstantsLines(G));
    for (const k of Object.keys(G.ANCHORS))
        L.push(`const vec3 ANCHOR_${k.replace(/[A-Z]/g, (c) => "_" + c).toUpperCase()} = ${v3(G.ANCHORS[k])};`);
    return L;
}

function traceTailLines(G) {
    const Po = G.POLES;
    // the battery's poles: where each terminal's field of particles starts (the terminal's outer face) and the way out of it (unit), board space

    return [`const vec2 POLE_MINUS_AT = ${v2(Po.minus.at[0], Po.minus.at[1])};      // the (-) terminal's outer face and the way out of it`,
        `const vec2 POLE_MINUS_DIR = ${v2(Po.minus.dir[0], Po.minus.dir[1])};`,
        `const vec2 POLE_PLUS_AT = ${v2(Po.plus.at[0], Po.plus.at[1])};      // the (+) terminal's`,
        `const vec2 POLE_PLUS_DIR = ${v2(Po.plus.dir[0], Po.plus.dir[1])};`];
}

function tailLines(G) {
    const L = [];
    // cores (package frame, relative to the zone centre) and cells (board space)
    const cr = ["", "// ---- cores: the 16 the service reports (P0-5, E0-7, LPE0-1), package frame ----",
                `#define CORE_COUNT ${G.CORES.length}`, "int coreAt(vec2 q) {"];
    G.CORES.forEach((c, i) => {
        const r = c.rect;
        cr.push(`    if (q.x > ${f(r[0])} && q.y > ${f(r[1])} && q.x < ${f(r[2])} && q.y < ${f(r[3])}) return ${i};`);
    });
    cr.push("    return -1;", "}", "vec4 coreRectOf(int i) {");
    G.CORES.forEach((c, i) => cr.push(`    if (i == ${i}) return vec4(${f(c.rect[0])}, ${f(c.rect[1])}, ${f(c.rect[2])}, ${f(c.rect[3])});`));
    cr.push("    return vec4(0.0);", "}", "int coreKindOf(int i) {");
    cr.push(`    return i < ${G.CORES.filter((c) => c.kind === "P").length} ? 0 : (i < ${G.CORES.filter((c) => c.kind !== "LPE").length} ? 1 : 2);`, "}");
    cr.push("vec4 cellRect(int i) {");
    G.CELLS.forEach((c, i) => cr.push(`    if (i == ${i}) return vec4(${f(c[0])}, ${f(c[1])}, ${f(c[2])}, ${f(c[3])});`));
    cr.push("    return vec4(0.0);", "}");
    cr.push(`#define CELL_COUNT ${G.CELLS.length}`);
    cr.push("// how full cell i is at the battery's fill f (0..1): cell k fills over [CELL_STOPS[k], CELL_STOPS[k + 1]] of the charge");
    cr.push("float cellFill(int i, float f) {");
    G.CELLS.forEach((c, i) => cr.push(`    if (i == ${i}) return clamp((f - ${f(G.CELL_STOPS[i])}) / ${f(G.CELL_STOPS[i + 1] - G.CELL_STOPS[i])}, 0.0, 1.0);`));
    cr.push("    return 0.0;", "}");
    cr.push(`const vec2 PACK_CENTRE = ${v2((G.PACK.x0 + G.PACK.x1) / 2, (G.PACK.z0 + G.PACK.z1) / 2)};`);
    cr.push(...segmentLines(G));
    cr.push(`const vec4 PKG_TILES_COMPUTE = vec4(${G.PKG.compute.map(f).join(", ")});`);
    cr.push(`const vec4 PKG_TILES_GRAPHICS = vec4(${G.PKG.graphics.map(f).join(", ")});`);
    cr.push(`const vec4 PKG_TILES_SOC = vec4(${G.PKG.soc.map(f).join(", ")});`);

    L.push(cr.join("\n"));
    return L;
}

module.exports = {
    name: "silicon",
    resultName: "SILICON_SHADER_GEN",
    // what the generated files say about themselves: the tool that wrote them (silicon's wrapper keeps its old name) and the geometry's file
    tool: "tools/dev/silicon_shader_gen.js",
    geometryLabel: "modules/silicon/scene/SceneGeometry.js",
    srcDir: SRC,
    outDir: path.join(ROOT, "modules/silicon/shaders"),
    // an @@INCLUDE is found in the scene's own src first, then in the toolkit's shared GLSL
    includeDirs: [SRC, BOARD_SRC],
    geometrySourceLabel: "modules/silicon/scene/SceneGeometry.js",
    // the header's name of a source file; the shared pieces keep their old silicon path so the generated shaders stay byte for byte what they were
    // (the baked packs do not carry comments: only the .frag texts do). A scene's own say their real path.
    sourceLabel: (file, resolved) => resolved && resolved.indexOf(BOARD_SRC) === 0 ? (LEGACY_LABEL[file] || null) : "modules/silicon/shaders/src/" + file,
    loadGeometry,
    groups: GROUP,
    generalGroups: ["pkg"],
    basePart: "board",
    shadowWeight: (g) => (g === "lock" ? "gLockA" : (g === "card" ? "gCardA" : "1.0")),
    hitSign: "hGroup == GRP_PKG ? -sign(1.0 / rotYDir(rd, -gPkgTurn)) : -sign(1.0 / rd)",
    optsFor: (name) => ({ glow: name.indexOf("glow") >= 0 || name.indexOf("particles") >= 0, flow: name.indexOf("glow") >= 0, packHalf: name.indexOf("board") >= 0 }),
    constantsLines,
    preludeLines,
    extentGrow: (p, G) => ({
        x: [p.group === "plug" ? G.PLUG.travel : 0, p.group === "hdmi" ? G.HDMI.travel : 0, p.group === "lock" || p.group === "shackle" ? G.LOCK.travel : 0],
        y: [p.group === "card" ? 60 : 0, p.group === "shackle" ? G.LOCK.shackleOpen : 0]
    }),
    groupFrame,
    aoBlock,
    flowTables,
    traceTailLines,
    tailLines,
    // the markers only silicon's templates carry
    markers: {
        SEGFIG: (G) => segFigBlock(G),
        // the board's vertex stage carries the fragment stage's uniform block, copied whole (Qt binds ONE buffer to both stages and nothing checks it;
        // tools/dev/shader_ubo_match.py does): it is taken from the fragment template, so the two cannot drift
        BOARD_UBO: (G, ctx) => {
            const fragTpl = fs.readFileSync(path.join(SRC, "silicon_board.frag.in"), "utf8");
            const blk = fragTpl.match(/^layout\(std140, binding = 0\) uniform buf \{[\s\S]*?^\};$/m);
            if (!blk)
                throw new Error("silicon_board.frag.in: no uniform block to copy");
            ctx.sources.push("modules/silicon/shaders/src/silicon_board.frag.in (its uniform block)");
            return blk[0];
        }
    }
};
