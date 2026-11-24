"use strict";
// scenes/aerial.js -- aerial's description for tools/dev/board_gen (gen.js): the paths, the groups (the card tilts about its finger end, the screw lifts, the DIP levers
// slide, the button goes down, the plug slides), the geometry, and every piece of generated GLSL that is aerial's own (the card's outline numbers, the jack's mouth, the
// 7-segment displays' tables, the LED table, the contact darkening). The generic machinery is lib/ (the toolkit's README says what a scene provides).
const fs = require("fs");
const path = require("path");
const { f, v3, v2 } = require("../lib/fmt.js");

const ROOT = path.resolve(__dirname, "..", "..", "..", "..");
const SRC = path.join(ROOT, "modules/aerial/shaders/src");
const BOARD_SRC = path.join(ROOT, "modules/common/board/shaders");
const GEOM_JS = path.join(ROOT, "modules/aerial/scene/AerialGeometry.js");

function loadGeometry() {
    const src = fs.readFileSync(GEOM_JS, "utf8").replace(/^\.pragma.*$/m, "");
    return JSON.parse(new Function(src + "; return json();")());
}

// group ids shared with the templates, in cast order (PK() packs the id in 3 bits: at most 8)
const GROUP = { board: 0, card: 1, pcb: 2, screw: 3, dipw: 4, dipb: 5, btn: 6, plug: 7 };

function constantsLines(G) {
    return [
        "const float GROOVE_DEPTH = 0.45;         // mm: Material's carved grooves (the board draws them, the glow lights their floor)",
        "const float BLEND_K = 0.7;               // mm: traces of one blend group (aerial has none) melt where they come closer than this"
    ];
}

const CAP = (s) => s.charAt(0).toUpperCase() + s.slice(1);

function preludeLines(G) {
    const B = G.BOARD, C = G.CARD, P = G.PCB, J = G.JACK, D = G.DIP, S = G.SOCKET;
    const L = [];
    L.push(`const vec4 BOARD_RECT = vec4(${f(B.x0)}, ${f(B.z0)}, ${f(B.x1)}, ${f(B.z1)});   // x0 z0 x1 z1`);
    L.push(`const vec2 BOARD_Y = vec2(${f(B.y0)}, ${f(B.y1)});`);
    L.push("// ---- the card (AerialGeometry CARD, PCB): the frame it tilts in and the PCB's outline, card-local mm (x across, y toward the fingers) ----");
    L.push(`const vec2 CARD_ORG = ${v2(C.x0, C.z0)};            // the PCB's top-left corner on the board`);
    L.push(`const vec2 CARD_PIV = ${v2(C.pivot.y, C.pivot.z)};            // the tilt's axis (parallel to x): y, z`);
    L.push(`const vec2 CARD_SIZE = ${v2(C.w, C.h)};`);
    L.push(`const float PCB_SHOULDER_Y = ${f(P.shoulderY)};`, `const vec2 PCB_SHOULDER_X = ${v2(P.shoulderX[0], P.shoulderX[1])};`);
    L.push(`const vec4 PCB_NOTCH = vec4(${f(P.notch.x)}, ${f(P.notch.y)}, ${f(P.notch.hole)}, ${f(P.notch.ring)});     // the half-moon: centre, hole R, copper ring R`);
    L.push(`const vec2 PCB_VIA = ${v2(P.notch.vias, P.notch.viaR)};`);
    L.push(`const vec3 PCB_KEY0 = ${v3([P.keys[0].x, P.keys[0].y0, P.keys[0].w])};     // E: centre x, closed end y, width`, `const vec3 PCB_KEY1 = ${v3([P.keys[1].x, P.keys[1].y0, P.keys[1].w])};     // A`);
    P.fingers.groups.forEach((g, i) => L.push(`const vec3 FING_G${i} = ${v3(g)};     // x of the first finger, pitch, count`));
    L.push(`const vec4 FING_P = vec4(${f(P.fingers.w)}, ${f(P.fingers.y0)}, ${f(P.fingers.y1)}, ${f(P.fingers.bandY)});     // width, y0, y1, where the mask-free band starts`);
    L.push(`const vec4 FIDUCIAL = vec4(${f(P.fiducial.x)}, ${f(P.fiducial.y)}, ${f(P.fiducial.dot)}, ${f(P.fiducial.ring)});`);
    L.push(`const vec4 SILK_TRI = vec4(${P.silk.triangle.map(f).join(", ")});     // x0, x1, apex y, base y`, `const vec3 SILK_DOT = ${v3(P.silk.dot)};`);
    L.push(`const vec4 SILK_KEYE = vec4(${P.silk.keyE.map(f).join(", ")});`, `const vec4 SILK_KEYA = vec4(${P.silk.keyA.map(f).join(", ")});`, `const vec4 SILK_DATE = vec4(${P.silk.date.map(f).join(", ")});`);
    L.push(`const vec4 SHIELD_RECT = vec4(${f(G.SHIELD.x0)}, ${f(G.SHIELD.y0)}, ${f(G.SHIELD.x1)}, ${f(G.SHIELD.y1)});     // card-local x0 y0 x1 y1`);
    L.push(`const float SCREW_LIFT = ${f(G.SCREW.lift)};`, `const float SCREW_TURNS = ${f(G.SCREW.turns)};     // whole turns over the lift (aerial_materials.glsl screwTurn)`);
    L.push(`const vec4 JACK_MOUTH = vec4(${f(J.mouth.zc)}, ${f(J.mouth.w)}, ${f(J.mouth.y0)}, ${f(J.mouth.y1)});     // the RJ45 opening on the +x face: centre z, width, y0, y1`);
    L.push(`const float PLUG_TRAVEL = ${f(G.PLUG.travel)};`);
    L.push(`const vec2 CABLE_FADE = ${v2(G.PLUG.x1 + G.PLUG.boot + G.PLUG.cable.fade0, G.CABLE_FADE.len)};     // the plug's cable fades to nothing from this x (the plug's own frame) over this length`);
    L.push(`const vec4 DIP_SLOT = vec4(${f(D.xOff - 0.25)}, ${f(D.rows[0])}, ${f(D.xOff + D.lever.w + D.travel + 0.25)}, ${f(D.rows[1])});     // the latches' track: x0, row 1 z, x1, row 2 z`);
    L.push(`const vec3 DIP_LEVER = ${v3([D.lever.w, D.lever.d, D.xOff])};     // a latch's face: width (x), depth (z), its x at rest (off)`);
    L.push(`const vec4 SOCKET_RECT = vec4(${f(S.x0)}, ${f(S.z0)}, ${f(S.x1)}, ${f(S.z1)});`);
    L.push(`const vec3 SCREW_C = ${v3([C.x0 + P.notch.x, C.z0 + P.notch.y, G.SCREW.head])};     // the screw's axis (x, z) and its head's radius`);
    L.push(`const vec2 SCREW_Y = ${v2(C.yPcb + C.pcb, C.yPcb + C.pcb + G.SCREW.headH)};     // the head's underside and top (the screw's own frame)`);
    // the card as ONE box in its own frame (the glow's mask: what the tilted card covers), from the PCB's underside to the shield's top
    L.push(`const vec3 CARD_BOX_MIN = ${v3([C.x0, C.yPcb, C.z0])};`, `const vec3 CARD_BOX_MAX = ${v3([C.x0 + C.w, C.yPcb + C.pcb + G.SHIELD.h + 0.1, C.z0 + C.h])};`);
    silkLines(G).forEach((l) => L.push(l));
    L.push(`const float DIP_TRAVEL = ${f(D.travel)};`, `const float BTN_TRAVEL = ${f(G.BTN.travel)};`);
    L.push(`const vec3 BTN_C = ${v3([G.BTN.cap.cx, G.BTN.cap.cz, G.BTN.cap.r])};`);
    L.push(`const vec2 MEM_PIN1 = ${v2(G.MEM.x0 + 0.9, G.MEM.z0 + 0.9)};`);
    L.push(`const vec3 BEACON_C = ${v3([G.BEACON.x, G.BEACON.z, G.BEACON.ring])};     // centre and the ring's radius (the glow's shrinking ring)`);
    L.push(`const vec3 LENS_C = ${v3([G.LENS.x, G.LENS.z, G.LENS.base])};`);
    const K = G.CUTS;
    L.push("// ---- the board's cut-outs (AerialGeometry CUTS): the two cable grommets behind the card, four small plated holes ----");
    K.grommets.forEach((h, i) => L.push(`const vec2 CUT_GROM${i} = ${v2(h[0], h[1])};`));
    L.push(`const vec2 CUT_GROM_R = ${v2(K.grommetR, K.grommetRing)};     // the hole's radius, the rubber ring's`);
    K.holes.forEach((h, i) => L.push(`const vec2 CUT_HOLE${i} = ${v2(h[0], h[1])};`));
    L.push(`const vec2 CUT_RING = ${v2(K.holeR, K.ringR)};     // the hole's radius, the copper ring's`);
    for (const k of Object.keys(G.ANCHORS))
        L.push(`const vec3 ANCHOR_${k.replace(/[A-Z]/g, (c) => "_" + c).toUpperCase()} = ${v3(G.ANCHORS[k])};`);
    return L;
}

// THE SILKSCREEN (tools/aerial/make_silk.py bakes it; silk.json says where everything is in the texture): the texture's size in mm, each unit label's rect on the
// board, the variants' cells and the emblems' cells
function silkLines(G) {
    const M = JSON.parse(fs.readFileSync(path.join(ROOT, "modules/aerial/scene/assets/silk.json"), "utf8"));
    const L = ["// ---- the silkscreen texture (modules/aerial/scene/assets/silk.json) ----"];
    L.push(`const vec2 SILK_TEX = ${v2(M.texMm[0], M.texMm[1])};            // the texture, mm (the board at its origin, the atlas under it)`);
    L.push(`const float SILK_TEXELS_PER_MM = ${f(M.texelsPerMm)};`);
    L.push(`const vec2 SILK_CELL = ${v2(M.cell[0], M.cell[1])};            // a variant's cell, mm`, `const float SILK_PAD_X = ${f(M.padX)};`, `const float SILK_EMBLEM = ${f(M.emblemCell)};`);
    ["rates", "usage"].forEach((key, k) => {
        const lab = G.LABELS.find((l) => l.unit === key);
        const box = M.labels.find((l) => l.unit === key);
        L.push(`const vec2 SILK_UNIT${k} = ${v2(lab.x - M.padX, lab.z - M.cell[1] / 2)};     // where the "${key}" label's cell lies on the board (its corner)`);
        L.push(`const float SILK_UNIT_W${k} = ${f(Math.min(M.cell[0], box.x1 - box.x0 + 2 * M.padX))};     // ... and how much of the cell it shows (its widest variant: the next label is not eaten)`);
        L.push(`vec2 silkCell${k}(float i) {`, ...M.cells[key].map((c, i) => `    if (i < ${i}.5) return ${v2(c[0], c[1])};`), `    return ${v2(M.cells[key][0][0], M.cells[key][0][1])};`, "}");
    });
    L.push(`const vec2 SILK_EMBLEM_WIFI = ${v2(M.cells.emblem.wifi[0], M.cells.emblem.wifi[1])};`, `const vec2 SILK_EMBLEM_BT = ${v2(M.cells.emblem.bt[0], M.cells.emblem.bt[1])};`);
    return L;
}

function groupFrame(G) {
    return `
// The frame a group's boxes live in. The caller sets these from its uniforms before casting -- each starts at its rest pose, because a GLSL global that nobody sets
// is UNDEFINED, not zero.
float gCardTilt = 0.0;     // rad: the card (and its PCB) rises about the finger end
float gScrewLift = 0.0;    // mm the screw is lifted out of the notch
float gDipW = 0.0;         // mm the Wi-Fi lever has slid from "off" toward "on"
float gDipB = 0.0;
float gBtnDown = 0.0;      // mm the button's cap is pressed
float gPlugOut = 0.0;      // mm the plug is pulled out along +x
// The flags of the cast loop, ONE float (a float a flag is a register): FLAG_CARD the card's groups are left out (the live patch draws it), FLAG_PLUG the plug is left
// out (a fading plug's pixel is cast again without it), FLAG_PCB the PCB alone (a pixel the shader found outside its outline is cast again without it).
#define FLAG_CARD 1.0
#define FLAG_PLUG 2.0
#define FLAG_PCB 4.0
float gFlags = 0.0;
bool flagOf(float bit) { return fract(gFlags * (0.5 / bit)) >= 0.5; }
void raise(float bit) { gFlags += bit; }

// the card's frame: a turn about the x axis through (y, z) = CARD_PIV, the back end (-z) rising for a positive angle
vec3 tiltBy(vec3 p, float a) {            // forward: a point of the card's own frame -> the board's
    float c = cos(a), s = sin(a);
    float dy = p.y - CARD_PIV.x, dz = p.z - CARD_PIV.y;
    return vec3(p.x, CARD_PIV.x + dy * c - dz * s, CARD_PIV.y + dz * c + dy * s);
}
vec3 tiltDirBy(vec3 v, float a) {
    float c = cos(a), s = sin(a);
    return vec3(v.x, v.y * c - v.z * s, v.z * c + v.y * s);
}
// world ray -> the group's own frame
void groupRay(int g, vec3 ro, vec3 rd, out vec3 o, out vec3 d) {
    o = ro;
    d = rd;
    if (g == GRP_CARD || g == GRP_PCB) {
        bool gone = g == GRP_CARD ? flagOf(FLAG_CARD) : (flagOf(FLAG_CARD) || flagOf(FLAG_PCB));
        o = gone ? vec3(1e7, -1e7, 1e7) : tiltBy(ro, -gCardTilt);
        d = tiltDirBy(rd, -gCardTilt);
    } else if (g == GRP_SCREW) {
        o = ro - vec3(0.0, gScrewLift, 0.0);
    } else if (g == GRP_DIPW) {
        o = ro - vec3(gDipW, 0.0, 0.0);
    } else if (g == GRP_DIPB) {
        o = ro - vec3(gDipB, 0.0, 0.0);
    } else if (g == GRP_BTN) {
        o = ro + vec3(0.0, gBtnDown, 0.0);
    } else if (g == GRP_PLUG) {
        o = flagOf(FLAG_PLUG) ? vec3(1e7, -1e7, 1e7) : ro - vec3(gPlugOut, 0.0, 0.0);
    }
}
vec3 cardDir(vec3 rd) {
    return tiltDirBy(rd, -gCardTilt);
}
// a normal found in the group's frame -> world
vec3 groupNormal(int g, vec3 n) {
    return (g == GRP_CARD || g == GRP_PCB) ? tiltDirBy(n, gCardTilt) : n;
}
bool inZone(vec2 p) {
    return false;
}`;
}

// the contact darkening (the board's pixel shader only): what stands on the board, as ONE table and one loop; the card's footprint takes a shadow that
// shows only while it is tilted (kind 4: it fades with the tilt)
function aoSize(h) {
    if (h >= 4.4)
        return { reach: 2.2, peak: 0.70, shift: 1 };
    if (h >= 2.2)
        return { reach: 1.5, peak: 0.67, shift: 0.55 };
    if (h >= 1.2)
        return { reach: 0.9, peak: 0.64, shift: 0.55 };
    return { reach: 0.45, peak: 0.5, shift: 0 };
}
function aoBlock(G, opts) {
    const rf = (v) => Math.fround(Math.fround(1 / Math.fround(v)) * Math.fround(Math.LOG2E)).toPrecision(9);
    const rows = [];
    for (const p of G.PARTS) {
        if (p.name === "board" || p.cast === false && p.group === "board" && p.name !== "beacon")
            continue;
        if (p.group === "board") {
            const h = p.max[1], sz = aoSize(h);
            rows.push([`vec4(${f((p.min[0] + p.max[0]) / 2)}, ${f((p.min[2] + p.max[2]) / 2)}, ${f((p.max[0] - p.min[0]) / 2)}, ${f((p.max[2] - p.min[2]) / 2)})`,
                       `vec3(${f(sz.peak)}, ${rf(sz.reach)}, ${sz.shift >= 0.995 ? "2.0" : (sz.shift <= 0.02 ? "0.0" : "1.0")})`]);
        } else if (p.group === "pcb") {
            rows.push([`vec4(${f((p.min[0] + p.max[0]) / 2)}, ${f((p.min[2] + p.max[2]) / 2)}, ${f((p.max[0] - p.min[0]) / 2)}, ${f((p.max[2] - p.min[2]) / 2)})`, `vec3(${f(2.0 / 7.0)}, ${rf(5.0)}, 4.0)`]);
        } else if (p.group === "plug" && p.name === "plug") {
            // the plug's shadow follows it out: kind 5, shifted by the plug's travel in the shader
            rows.push([`vec4(${f((p.min[0] + p.max[0]) / 2)}, ${f((p.min[2] + p.max[2]) / 2)}, ${f((p.max[0] - p.min[0]) / 2)}, ${f((p.max[2] - p.min[2]) / 2)})`, `vec3(0.62, ${rf(2.2)}, 5.0)`]);
        }
    }
    const N = rows.length;
    return ["", "// Contact darkening on the board's top face at p from the parts that stand on it; `lvl` says which surface (aerial's board is the only one that takes it).",
            "float aoRect(vec2 p, vec4 r, float peak, float expK) {",
            "    vec2 q = max(abs(p - r.xy) - r.zw, vec2(0.0));",
            "    return 1.0 - exp2(-length(q) * expK) * peak;",
            "}",
            `const int AO_N = ${N};`,
            `const vec4 AO_R[${N}] = vec4[${N}](`, rows.map((e) => "    " + e[0]).join(",\n"), ");",
            `const vec3 AO_C[${N}] = vec3[${N}](`, rows.map((e) => "    " + e[1]).join(",\n"), ");",
            "// (ao at p, ao with the lamp-ward point `sh` away) -- the second only when `two` is 2",
            "vec2 sceneAo(vec2 p, vec2 sh, int lvl, int two) {",
            "    vec2 a = vec2(1.0);",
            "    if (lvl != 0)",
            "        return a;",
            "    for (int j = 0; j < AO_N * two; j++) {",
            "        int k = j >= AO_N ? 1 : 0;",
            "        int i = j - k * AO_N;",
            "        vec4 r = AO_R[i];",
            "        vec3 c = AO_C[i];",
            "        vec2 pS = k == 0 ? p : p + sh;",
            "        vec2 at = c.z < 0.5 ? p : (c.z < 1.5 ? mix(p, pS, 0.55) : pS);",
            "        if (c.z > 4.5)",
            "            r.x += gPlugOut;",
            "        float v = aoRect(at, r, c.x, c.y);",
            "        if (c.z > 3.5 && c.z < 4.5)          // the card's footprint: its shadow shows only while it is tilted (seated, the board under it is not seen)",
            "            v = mix(1.0, v, clamp(gCardTilt / 0.2, 0.0, 1.0));",
            "        if (k == 0)",
            "            a.x *= v;",
            "        else",
            "            a.y *= v;",
            "    }",
            "    return a;",
            "}"].join("\n");
}

// The 7-segment displays' tables (seg7.glsl reads them): which display a part is, its window, its first cell, its cell count
function segmentLines(G) {
    const S = G.SEG, L = [];
    L.push("// ---- the 7-segment displays (AerialGeometry SEG7) ----");
    L.push(`const float SEG_H = ${f(S.h)};`, `const vec2 SEG_CELL = ${v2(S.cell[0], S.cell[1])};            // a digit's width and height, mm`,
           `const float SEG_STROKE = ${f(S.stroke)};`, `const float SEG_GAP = ${f(S.gap)};`, `const float SEG_PITCH = ${f(S.pitch)};`,
           `const float SEG_COLON_GAP = ${f(S.colonGap)};`, `const float SEG_PAD = ${f(S.pad)};`, `#define SEG_COUNT ${G.SEG7.length}`);
    const byIndex = (fn, dflt) => G.SEG7.map((d, i) => `    if (i == ${i}) return ${fn(d)};`).concat([`    return ${dflt};`]);
    L.push("int segIndexOf(int part) {", ...G.SEG7.map((d, i) => `    if (part == PART_${d.name.toUpperCase()}) return ${i};`), "    return -1;", "}");
    L.push("vec4 segWindow(int i) {", ...byIndex((d) => `vec4(${d.window.map(f).join(", ")})`, "vec4(0.0)"), "}");
    L.push("vec2 segCell0(int i) {", ...byIndex((d) => v2(d.cell0[0], d.cell0[1]), "vec2(0.0)"), "}");
    L.push("int segCells(int i) {", ...byIndex((d) => d.cells, "4"), "}");
    L.push("bool segHasColon(int i) {", ...byIndex((d) => (d.colon ? "true" : "false"), "false"), "}");
    return L;
}

// The LEDs the glow lights: ledIndexOf(part) names an LED part (0 beacon, 1 jack green, 2 jack amber, 3..7 the five pads' LEDs), ledBoard(i) = where its halo lands on the
// board (x, z, halo radius) -- the jack's two are on a vertical face and have none (radius 0)
function ledLines(G) {
    const L = ["// ---- the LEDs (AerialGeometry: beacon, jack green / amber, the pads' LEDs): the glow's index and halo ----"];
    const names = ["beacon", "jackGreen", "jackAmber"].concat(G.PADS.names.map((n) => "led" + CAP(n)));
    L.push(`#define LED_COUNT ${names.length}`, "int ledIndexOf(int part) {", ...names.map((n, i) => `    if (part == PART_${n.toUpperCase()}) return ${i};`), "    return -1;", "}");
    const part = (n) => G.PARTS.find((p) => p.name === n);
    L.push("vec3 ledBoard(int i) {", ...names.map((n, i) => {
        const p = part(n), r = n === "beacon" ? 3.6 : (n.indexOf("jack") === 0 ? 0.0 : 3.2);
        return `    if (i == ${i}) return vec3(${f((p.min[0] + p.max[0]) / 2)}, ${f((p.min[2] + p.max[2]) / 2)}, ${f(r)});`;
    }), "    return vec3(0.0);", "}");
    return L;
}

// which parts are vertical cylinders (the materials measure their edges as a circle, not a box)
function cylLines(G) {
    const cyl = G.PARTS.filter((p) => p.shape === "cylY");
    return ["bool isCylPart(int part) {", ...cyl.map((p) => `    if (part == PART_${p.name.toUpperCase()}) return true;`), "    return false;", "}"];
}

function tailLines(G) {
    return [segmentLines(G).join("\n"), ledLines(G).join("\n"), cylLines(G).join("\n")];
}

module.exports = {
    name: "aerial",
    resultName: "AERIAL_SHADER_GEN",
    tool: "tools/dev/board_gen/gen.js aerial",
    geometryLabel: "modules/aerial/scene/AerialGeometry.js",
    srcDir: SRC,
    outDir: path.join(ROOT, "modules/aerial/shaders"),
    includeDirs: [SRC, BOARD_SRC],
    geometrySourceLabel: "modules/aerial/scene/AerialGeometry.js",
    sourceLabel: (file, resolved) => resolved && resolved.indexOf(BOARD_SRC) === 0 ? "modules/common/board/shaders/" + file : "modules/aerial/shaders/src/" + file,
    loadGeometry,
    groups: GROUP,
    // the card turns: its groups take the general box tests, the rest the camera ray's cheap ones
    generalGroups: ["card", "pcb"],
    basePart: "board",
    shadowWeight: () => "1.0",
    hitSign: "(hGroup == GRP_CARD || hGroup == GRP_PCB) ? -sign(1.0 / cardDir(rd)) : -sign(1.0 / rd)",
    optsFor: (name) => ({ glow: name.indexOf("glow") >= 0, flow: name.indexOf("glow") >= 0, packHalf: name.indexOf("board") >= 0 }),
    constantsLines,
    preludeLines,
    extentGrow: (p, G) => ({
        x: [p.group === "plug" ? G.PLUG.travel : 0],
        y: [p.group === "card" || p.group === "pcb" ? 14 : 0, p.group === "screw" ? G.SCREW.lift : 0]
    }),
    groupFrame,
    aoBlock,
    // the dimmed pulse trains: which way each route's train runs (1 outward from the slot along `s`, 0 none: a stub that only feeds an LED)
    flowTables: (G) => ["// the trains' direction per trace (AerialGeometry TRACES `pulse`)", "float traceDir(int id) {",
                        ...G.TRACES.map((t, id) => `    if (id == ${id}) return ${f(t.pulse)};`), "    return 0.0;", "}"],
    traceTailLines: () => [],
    tailLines,
    markers: {
        // the board's vertex stage carries the fragment stage's uniform block, copied whole (Qt binds ONE buffer to both stages and nothing checks it;
        // tools/dev/shader_ubo_match.py does): taken from the fragment template of the same name, so the two cannot drift
        BOARD_UBO: (G, ctx) => {
            const tpl = ctx.name.indexOf("glow") >= 0 ? "aerial_glow.frag.in" : "aerial_board.frag.in";
            const fragTpl = fs.readFileSync(path.join(SRC, tpl), "utf8");
            const blk = fragTpl.match(/^layout\(std140, binding = 0\) uniform buf \{[\s\S]*?^\};$/m);
            if (!blk)
                throw new Error(tpl + ": no uniform block to copy");
            ctx.sources.push("modules/aerial/shaders/src/" + tpl + " (its uniform block)");
            return blk[0];
        }
    }
};
