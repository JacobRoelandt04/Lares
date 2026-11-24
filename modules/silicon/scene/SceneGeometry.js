.pragma library

// =============================================================================
// SceneGeometry.js -- silicon's board, the ONE source of where everything is.
//
// Board space is millimetres: x and z lie on the board, y points up, and the
// board's top face is y = 0. Everything is an axis-aligned box (the renderer
// ray-casts boxes analytically); a part that moves names the group that moves
// it. Three readers, all generated or computed from this file and nothing else:
//   - tools/dev/silicon_shader_gen.js writes the shaders' @@GEOM blocks from it
//     (`--check` fails when a shader is stale);
//   - IsoCamera.js projects it for layout and hit-testing by arithmetic;
//   - tools/silicon/make_silkscreen.py draws LABELS into the board-space mask.
// No Qt here: it runs under node.
//
// Groups (what moves a part; the shader applies the same transforms):
//   board    never moves
//   pkg      the CPU package: a profile change lifts it (PKG.lift), turns it a
//            quarter per step about the zone centre and sets it down
//   card     the graphics card: lifts out of its slot and dissolves
//   plug     the charger plug: slides along -z into the jack
//   hdmi     the HDMI plug in the card's port, with its cable: slides along +x out of the bracket's receptacle. A group of its own: the card
//            dissolves and lifts, the plug does not (it is out and gone before the card goes)
//   lever    the DIP switch's lever: slides along x between "80" and "100"
//   lock     the charge limit's lock bar on the 4th cell (bar, screws, padlock body): slides in along -x
//            across the cell's contacts, from LOCK.travel mm out, and fades in as it goes
//   shackle  the padlock's shackle: rides with `lock` and drops shut over the padlock's body
//
// A part can also be four things beyond a plain box, all read by the generator and the pick from this file alone: a ROW (many identical
// cells as ONE primitive, ROW()), a `cluster` (parts that stand together behind one bound), `bake` (only the cached board draws it: the live glow
// does not cast it, which hides nothing the glow lights) and `cut` (the part is one box for the ray and the
// shaders cut it to its real outline: modules/silicon/shaders/src/cutouts.glsl).
//
// The CPU zone is the square the package turns in: its courtyard, via field
// and four breakout stubs, and the sub-rect the live patch redraws while the
// package moves (IsoCamera.patchRect).
// =============================================================================

// ---- materials: the shader's ids (silicon_board.frag switches on these) ------------------
var MAT = {
    BOARD: 0, SUBSTRATE: 1, BASE_DIE: 2, TILE_COMPUTE: 3, TILE_GRAPHICS: 4, TILE_SOC: 5, TILE_IO: 6,
    SLOT: 7, LATCH: 8, CARD_PCB: 9, GPU_SUBSTRATE: 10, GPU_DIE: 11, GDDR: 12,
    PACK_TRAY: 13, CELL: 14, TERMINAL: 15, JACK: 16, PLUG: 17, DIP_BODY: 18, DIP_LEVER: 19, CABLE: 20,
    // the 7-segment display modules and the charge limit's lock
    DISPLAY: 21, LOCK_BAR: 22, LOCK_BODY: 23, SCREW: 24,
    // the card's bracket / heatsink / VRM, the RAM, the display ribbon, the small parts (id 34 is unused)
    BRACKET: 25, HEATSINK: 26, CHOKE: 27, MOSFET: 28, MLCC: 29, CAP: 30, RAM_PCB: 31, RAM_CHIP: 32, SOCKET: 33, RIBBON: 35, CONNECTOR: 36,
    // the display connector's flip-lock bar
    LATCH_BAR: 37
};

var BOARD = { x0: -92, x1: 62, z0: -86, z1: 58, y0: -3.2, y1: 0 };

// The CPU zone: a square centred on the package, which turns inside it.
var ZONE = { cx: -55, cz: 18, half: 31, courtyard: 25 };

// The package (Core Ultra 9 185H, Meteor Lake-H: a Foveros base die carrying the compute,
// graphics, SoC and IO tiles), in PACKAGE space: x along its long side, centred on the zone.
var PKG = {
    lift: 12,                      // mm the package rises during a profile change (the scene's pkgRise = 1)
    substrate: { w: 46, d: 30, h: 1.2 },
    base: { w: 32, d: 20, h: 0.5 },
    tileH: 0.9,
    // tile rectangles on the base die, package space [x0, z0, x1, z1]
    compute: [-15.2, -9.2, -1.0, 1.6],
    graphics: [-0.2, -9.2, 9.4, 1.6],
    io: [10.2, -9.2, 15.2, 9.2],
    soc: [-15.2, 2.4, 9.4, 9.2]
};

// Cores, package space [x0, z0, x1, z1] on the tile tops: 6 P-cores (3 x 2), two clusters of
// four E-cores, two LPE cores on the SoC tile -- the order of the service's `cores` array.
var CORES = (function () {
    var out = [];
    var c = PKG.compute;
    // P-cores: the left 62 % of the compute tile, 3 columns x 2 rows
    var px0 = c[0] + 0.6, px1 = c[0] + (c[2] - c[0]) * 0.62, pz0 = c[1] + 0.6, pz1 = c[3] - 0.6;
    var pw = (px1 - px0) / 3, pd = (pz1 - pz0) / 2;
    for (var r = 0; r < 2; r++)
        for (var k = 0; k < 3; k++)
            out.push({ kind: "P", rect: [px0 + k * pw + 0.25, pz0 + r * pd + 0.25, px0 + (k + 1) * pw - 0.25, pz0 + (r + 1) * pd - 0.25] });
    // E-cores: two clusters (2 x 2 each) stacked in the remaining strip
    var ex0 = px1 + 0.5, ex1 = c[2] - 0.6;
    var ew = (ex1 - ex0) / 2, ed = (pz1 - pz0) / 4;
    for (var cl = 0; cl < 2; cl++)
        for (var rr = 0; rr < 2; rr++)
            for (var kk = 0; kk < 2; kk++) {
                var z0 = pz0 + (cl * 2 + rr) * ed + (cl === 1 ? 0.3 : 0);
                out.push({ kind: "E", rect: [ex0 + kk * ew + 0.15, z0 + 0.15, ex0 + (kk + 1) * ew - 0.15, z0 + ed - 0.15] });
            }
    // LPE cores: two small blocks at the SoC tile's left end
    var s = PKG.soc;
    out.push({ kind: "LPE", rect: [s[0] + 1.2, s[1] + 1.2, s[0] + 3.4, s[3] - 1.2] });
    out.push({ kind: "LPE", rect: [s[0] + 3.9, s[1] + 1.2, s[0] + 6.1, s[3] - 1.2] });
    return out;
})();

// The graphics card (artistic licence: a mezzanine card resting flat on its PCIe x16 slot),
// carrying the RTX 4060's AD107 package and its four GDDR6 chips, in BOARD space.
var CARD = {
    x0: -8, x1: 58, z0: -82, z1: -34,        // the card's PCB footprint
    rest: 4.4,                               // the PCB's underside sits on the slot, 4.4 mm up
    pcb: 1.6,
    die: [16, -64, 28.5, -52.5],             // AD107 die footprint on the GPU substrate
    substrate: [10, -70, 34.5, -46.5],
    gddr: [[37, -70, 46, -59], [37, -57.5, 46, -46.5], [10, -80, 21.5, -72], [23, -80, 34.5, -72]],
    // the gold fingers along the slot edge: a decal on the PCB's top, a band across the slot's width. Nothing stands on it.
    fingers: { x0: -7.3, x1: -2.4, z0: -78.6, z1: -37.4, pitch: 1.68, w: 1.0 }
};

var SLOT = { x0: -6, x1: 2, z0: -79, z1: -37, h: 4.4 };            // under the card's near edge
var LATCH = { x0: 51, x1: 57, z0: -62, z1: -54, h: 4.4 };          // the standoff + latch at the far edge

// The battery: a 4S pack, four cells in a row along x, on a tray.
var PACK = { x0: -16, x1: 42, z0: 18, z1: 48, h: 5.2 };
var CELLS = (function () {
    var out = [], n = 4, gap = 2.2, x0 = PACK.x0 + 3.2, x1 = PACK.x1 - 3.2;
    var w = (x1 - x0 - gap * (n - 1)) / n;
    for (var i = 0; i < n; i++)
        out.push([x0 + i * (w + gap), PACK.z0 + 3.2, x0 + i * (w + gap) + w, PACK.z1 - 3.2]);
    return out;
})();
var CELL_TOP = PACK.h + 1.4;
// The charge at which each cell has just filled (20 / 50 / 80 / 100 %: the 80 % limit
// leaves the fourth cell alone, so the first three divide the 80 into 20, 30, 30). Cell k fills over
// [CELL_STOPS[k], CELL_STOPS[k + 1]].
var CELL_STOPS = [0, 0.2, 0.5, 0.8, 1.0];

// How deep Material's carved grooves go, mm: the board draws them with it and the glow lights their floor by it.
var GROOVE = { depth: 0.55 };

// The projector lens each hologram wears on its anchor (holo_common.glsl lensGlow): a soft disc of
// radius `disc` x r and a thin ring at r that falls off over `ringFall`, all in mm. `cpu`, `gpu` and
// `beam` are the three holograms' rings; `gpuRing` is the GPU's big ring, drawn (planeBase - 1) mm above its anchor.
// One source: the shaders' constants are generated from it, and IsoCamera.beamRect pads by it.
var LENS = { cpu: 3.6, gpu: 3.4, gpuRing: 12.5, beam: 3.0, disc: 0.8, ringFall: 0.45,
             fanW0: 1.2, fanW1: 31.0, fanBack: 0.03 };      // the integrated beam's fan: its half width at the tile and the width it adds by the card, mm; where its density starts, as a share of its length behind the tile

// The DC jack on the board's front-right edge (x1), its mouth facing +x; the plug slides in along -x.
var JACK = { x0: 49, x1: 62, z0: -6, z1: 5, h: 9 };
var PLUG = { x0: JACK.x1, x1: 76, y0: 1.5, y1: 7.5, z0: -4.5, z1: 3.5, travel: 22 };      // the plug's body (the grip); fully in it stands at the jack's face (x = JACK.x1), and it slides 22 mm out along +x
// the barrel: the part of the plug that goes INTO the jack, narrower than the jack's round mouth (radius 2.6 in board_materials.glsl, JACK_R: the
// box's corners, `half` x sqrt 2, stay inside it) and on the same axis as the mouth; it rides with the plug, so fully in it lies behind the jack's face
var BARREL = { x0: 54, x1: PLUG.x0, half: 1.7 };
var CABLE = { x0: 76, y0: 3.0, y1: 6.0, z0: -2, z1: 1, fade0: 10.0 };          // x1: where its fade ends (below, with CABLE_FADE): nothing past it is drawn
// The cable's strain relief: a boot just behind the plug where the cable leaves it, a tapered sleeve of stepped collars (the moulded rings of a
// semi-soft boot), each one shorter in the section and smaller than the one before, on the cable's centre line; the cable's own material, riding with the plug.
// `len` along the cable (x), `hy` / `hz` half the collar's height and width.
var BOOT = { collars: [{ len: 2.2, hy: 2.5, hz: 3.1 }, { len: 2.0, hy: 2.15, hz: 2.6 }, { len: 1.8, hy: 1.85, hz: 2.15 }, { len: 1.6, hy: 1.65, hz: 1.8 }] };

// The charge-limit DIP switch beside the pack: the lever sits at "80" (x low) or "100" (x high: no limit, printed MAX).
var DIP = { x0: 24, x1: 42, z0: 4, z1: 15.5, h: 3.6, cz: 8.5 };         // cz: the middle of its window and of the lever's travel; the front 3.6 mm of the top face carry the 80 / 100
var LEVER = { w: 5.2, d: 5.4, h: 1.5, xLow: 29.0, xHigh: 37.0 };

// ---- the 7-segment displays (the battery's figures on the board itself) -------------------------
// Low modules LYING on the board, a window on the top face and the digits in the board's plane (a digit reads along +x like
// the board's lettering; its top is -z). ONE list: the generator makes each entry a part, the shaders' window / cell geometry
// (the board draws the body, the window and the unlit segments, the glow the lit ones) and the picker finds it by name.
// An entry: `name` (the part: segWatts, segTime, segFull; the RAM display is one more entry, `segRam`), `key` (the
// `SiliconScene.figures` string it shows), `cells` digits with a colon between the 2nd and 3rd when `colon`, the module's
// top-left corner [x, z], the lit segments' `colour` (charge: the cells' colour; memory: the RAM's; cpu: the package's profile colour) and the label printed beside it: behind it (-z, clear of the strip the module hides) or, with `front`, in front of it.
// The order is the uniforms' (figA, figB, ... figG): a later entry appends. Millimetres, board space.
var SEG = {
    h: 1.4,                  // the module's height: a low profile
    cell: [2.6, 5.2],        // a digit's width and height
    stroke: 0.7,             // a segment's thickness
    gap: 0.30,               // the clear space between two segments at a joint, measured across the 45 degree ends that face each other (seg7.glsl)
    pitch: 3.8,              // one cell to the next
    colonGap: 1.6,           // the room the colon takes between the 2nd and 3rd cell
    pad: 0.9,                // window edge to the first / last digit, and to the digits' top and foot
    bezel: 0.7               // the module's frame around the window
};
function segDisplay(d) {
    var inner = 2 * SEG.pad + (d.cells - 1) * SEG.pitch + SEG.cell[0] + (d.colon ? SEG.colonGap : 0);
    var w = inner + 2 * SEG.bezel, dp = SEG.cell[1] + 2 * SEG.pad + 2 * SEG.bezel;
    d.body = [d.x, d.z, d.x + w, d.z + dp];                                                   // x0 z0 x1 z1
    d.window = [d.x + SEG.bezel, d.z + SEG.bezel, d.x + w - SEG.bezel, d.z + dp - SEG.bezel];
    d.cell0 = [d.window[0] + SEG.pad, d.window[1] + SEG.pad];                                  // the first cell's top-left
    // the label printed behind it (-z): centred on the module, its box clear of the strip the module hides
    d.label.x = d.x + w / 2 + (d.label.dx || 0);
    d.label.z = d.label.front ? d.z + dp + 0.6 + d.label.size / 2 + 0.4 : d.z - SEG.h - 0.6 - d.label.size / 2 - 0.4;
    return d;
}
var SEG_ROW_Z = -12.2;
var SEG_CPU_X = -49.55, SEG_CPU_Z = -28.1, SEG_CPU_STEP = 15.2;          // the CPU's row (below): the first module's x, the row's z, one module to the next (13.4 wide + 1.8 clear)
var SEG7 = [
    { name: "segWatts", key: "watts", cells: 4, colon: false, colour: "charge", x: -11.4, z: SEG_ROW_Z, label: { text: "W", size: 2.4, dx: 5.3 } },          // its label stands over the module's right end: the PCIe lanes' corner is left of it,
    { name: "segTime", key: "time", cells: 4, colon: true, colour: "charge", x: 7.6, z: SEG_ROW_Z, label: { text: "", size: 2.4 } },     // its label is swapped by figures.timeMode: MODE_LABEL
    // SINCE FULL is the widest label (Audiowide: ~0.9 of the size a glyph): in front of its module it has the room the time label leaves it. (The DIP
    // switch's 80 / 100 keep to the switch's own depth and are small, so they do not read in line with it as one phrase, "80 100 SINCE FULL".)
    { name: "segFull", key: "sinceFull", cells: 3, colon: false, colour: "charge", x: 28.2, z: SEG_ROW_Z, label: { text: "SINCE FULL", size: 2.4, dx: -3.3, front: true } },
    // the RAM's: used GiB, on the empty board in front of the first stick (the sticks stand on the back edge), left of the PCIe lanes, lit in the memory hue
    { name: "segRam", key: "ram", cells: 3, colon: false, colour: "memory", x: -84.0, z: -61.5, label: { text: "RAM GB", size: 2.4, front: true } },
    // the CPU's figures (its clock, usage and temperature): one row of three-cell modules in the CPU's profile colour,
    // on the empty board behind the package's top-right corner, between the PCIe lanes' trunk and the card's power trace (the row is centred between their
    // corridors, 2.65 mm clear of each), their captions behind them. Clear of the CPU hologram's plane on the screen, where the figures read at 1x.
    { name: "segClock", key: "cpuClock", cells: 3, colon: false, colour: "cpu", x: SEG_CPU_X, z: SEG_CPU_Z, label: { text: "GHZ", size: 2.4 } },
    { name: "segLoad", key: "cpuLoad", cells: 3, colon: false, colour: "cpu", x: SEG_CPU_X + SEG_CPU_STEP, z: SEG_CPU_Z, label: { text: "LOAD %", size: 2.4, dx: -0.5 } },
    { name: "segTemp", key: "cpuTemp", cells: 3, colon: false, colour: "cpu", x: SEG_CPU_X + 2 * SEG_CPU_STEP, z: SEG_CPU_Z, label: { text: "TEMP \u00b0C", size: 2.4, dx: 0.5 } }
].map(segDisplay);

// The time display's printed label follows `figures.timeMode` (instant swap): three strings in the glyph atlas
// (tools/silicon/make_glyphs.py), centred on the time module, in the family's lettering. An empty mode prints none.
var MODE_LABELS = ["TIME LEFT", "TO FULL", "TO 80"];          // timeMode "left", "full", "limit"
var MODE_LABEL = { size: 2.4, w: 20.6, h: 3.4 };               // the atlas cell's size, mm
(function () {
    var t = SEG7[1];
    MODE_LABEL.x = t.x + (t.body[2] - t.body[0]) / 2;
    MODE_LABEL.z = t.label.z;
})();

// The battery's condition and cycles, printed on the board as figures (up to FIGTEXT.cells characters, right-aligned to `xEnd`,
// digits FIGTEXT.size tall) with a short label above each. A change re-renders the cached board (rare).
var FIGTEXT = {
    size: 2.6, pitch: 3.0, cells: 4,
    lines: [{ key: "condition", xEnd: 59.4, z: 40.0 }, { key: "cycles", xEnd: 59.4, z: 47.2 }]
};

// The glyph atlas the figures and the mode labels are cut from (tools/silicon/make_glyphs.py reads this; board_materials.glsl samples it)
var GLYPHS = { chars: "0123456789-", cell: [7.0, 8.5], digitH: 6.0, texels: 16 };

// ---- the charge limit's lock -------------------------------------------------------------------------
// A bar across the 4th cell's contacts, two screws and a padlock. `lock` slides the bar (screws and padlock body with it) in
// along -x from LOCK.travel mm out; `shackle` rides with it and drops shut. One fraction drives every piece (MotionScripts.lockPose).
var LOCK = { travel: 16, shackleOpen: 2.2, overhang: 1.2, barH: 1.4, barD: 4.2 };

// ---- the card's I/O bracket, the RAM, the display ribbon ---------------------------------------------------
// The I/O bracket (the "IO shield") at the card's end, its plate facing +x: a plate 1.2 mm thick that stands from 3.0 mm UNDER the card's
// underside to 7.6 mm over its top (a part of it is below the card, and it is not tall), its corners rounded (`r`: the shaders cut them,
// cutSd in cutouts.glsl), with the TONGUE -- the narrow tapered tab that continues below the plate and slots INTO the board like a puzzle
// piece (its foot is under the board's surface), off the plate's centre line -- and the top flange with its screw notch. The HDMI port and the vents are decals on the outer face.
var BRACKET = {
    x0: CARD.x1 + 0.3, x1: CARD.x1 + 1.5, z0: CARD.z0 + 0.4, z1: CARD.z1 - 0.4, y0: 1.4, y1: 13.6, r: 1.7,
    tongue: { zc: -45.5, hw0: 4.4, hw1: 3.0, y0: -1.0, r: 1.4 },                 // half widths at the plate and at the tip
    lip: { x1: CARD.x1 + 3.6, z0: -75.5, z1: -66.5, y0: 12.6, notchZ: -71.0, notchR: 1.1 },
    hdmi: { zc: -52.0, yc: 8.3, w: 14.0, h: 4.6, chamfer: 1.0 },               // the type-A receptacle's shell: 14 x 4.55 mm, the two lower corners chamfered, its bottom on the PCB's top (6.0)
    vents: { z0: -79.0, pitch: 2.4, n: 7, w: 1.1, y0: 6.9, y1: 12.7 }
};

// The HDMI plug in the bracket's receptacle, with its cable: three boxes on the receptacle's own axis (BRACKET.hdmi: z, y), along +x from the plate's outer
// face -- the metal shell that goes in (a little smaller than the receptacle's 14 x 4.6 mm), the moulded hood behind it, the cable. They are the charger plug's own
// materials (PLUG, CABLE) in a group of their own; the card's group dissolves and lifts, this one does not. Out, the plug slides `travel` mm along +x and fades.
// `fade` is where along x the cable fades to nothing, in the cable's own frame -- the charger's cable fades over 10 to 44 mm past its plug (silicon_board.frag.in), and
// this one has what room the popup's edge leaves: the camera's right edge lies 36 mm past the plate along +x, so the cable is gone by x = 88 and the plug pulls out by 8 mm
// (the shell clears the receptacle) -- what is still seen while it slides out, at its faintest, must stay inside the frame.
var HDMI = {
    x0: BRACKET.x1, zc: BRACKET.hdmi.zc, yc: BRACKET.hdmi.yc,
    shell: { len: 5.0, w: 13.4, h: 4.2 },
    hood: { len: 9.5, w: 16.0, h: 8.0 },
    cable: { len: 24.0, w: 4.2, h: 4.2 },
    fade: [76.0, 88.0],
    travel: 8.0
};

// The RAM on the board's upper-right (back) edge, from the top corner toward the card: two SO-DIMM sticks (an 8 GB stick with 4 long chips, a 16 GB one with
// 8: this machine reads two memory devices and 24 GB), each in a socket of its own, the two sockets in a LINE along the edge. A SO-DIMM is held by its LONG
// edge: a stick lies flat on the board's side of its socket (toward +z), the two side by side with their short edges facing across a gap. A socket is a low
// housing along the back with an end wall ("guardrail") at each short end that reaches along the stick's short edge; the wall's hook snaps into a notch cut
// in that edge, and the notch keeps a metal tooth where the hook sits (the shaders cut the stick to its outline: cutouts.glsl). The chips are the usage meter
// (2 GB a chip: SiliconScene.memory.usedFraction), filled in reading order -- stick A left to right, then B's near row, then its far row -- and sit in
// two pairs per row with a wider gap in the middle, where the SPD (and, on the bigger stick, a PMIC) sits; a few MLCCs are painted on each plate's empty board.
var RAM = {
    x0: [-85.4, -51.4], len: 30.0, wall: 1.5,      // each socket's left end and its length (end walls included): the stick between the walls is len - 2 wall long
    z0: -78.2, zFront: -74.7, wallZ1: -70.9, h: 2.9,          // the housing's back and front faces, where the walls end, the socket's height
    stick: { depth: 11.1, y0: 1.6, y1: 2.4, inset: 1.3, r: 0.4, notchZ: 3.0, notchR: 1.6, tooth: [1.0, 0.6] },     // from the connector edge: depth out, `inset` hidden in the housing; the corners' radius `r` (nearly square -- a real SO-DIMM's corners are barely eased, and a rounded outline has no side wall to take a bevel); a notch's centre `notchZ` in, radius `notchR`; the tooth's depth and half width
    chip: { cell: [4.2, 0.9, 3.2], cellA: [4.2, 0.9, 7.4], pitch: 4.6, n: 5, skip: 2, dx: 2.2, z: [-73.7, -69.5] },        // a row of 5 cells with the middle one left out; the first starts `dx` in from the stick's end; the rows' z0. `cell`: the 16 GB stick's (two rows of short packages); `cellA`: the 8 GB stick's single row of four LONG ones (a single-rank SO-DIMM carries 4 long packages), which reach where the other stick's second row ends
    spd: { cell: [2.0, 0.6, 1.6], dx: 12.5, z: -72.9 },        // the SPD in the middle gap of the first row (both sticks)
    pmic: { cell: [2.8, 0.7, 2.8], dx: 12.1, z: -69.3 },       // the PMIC in the middle gap of stick B's second row
    caps: { cell: [1.6, 1.1], pitch: 2.4, a: { dx: 15.2, z: -65.5, n: 4 }, b: { dx: 2.0, z: -65.5, n: 4 } },       // a few MLCCs on each stick's empty board: PAINTED on its plate (the board shader), not parts of the cast
    units: 12
};

// The display ribbon, a phone's flex cable: ONE flat strip at ONE level, in the board's plane. It leaves the connector's front face (+z, toward the board's
// edge) through a slot, runs out past the edge, turns a rounded `bend` toward +x (45 degrees, not a quarter: the legs meet at an obtuse 135, so the
// S is a gentle sweep), runs on diagonally for `run` mm (down on the screen), and turns the same angle back to +z and on. `r` is the bend's radius on the
// strip's centre line (its inner edge is r - w / 2), `run` the straight stretch between the bends; the conductors are offsets of that centre line, so they
// run concentric through the bends (cutouts.glsl: ribbonSd). It fades out along its own length like the charger's cable (CABLE_FADE): the strip is
// at full strength until `fade0` mm along its centre line from its start (`zStart`), gone `CABLE_FADE.len` later, and ends there: nothing of it reaches
// the popup's edge. `sEnd`, `zEnd` and `x1` (where the last leg runs) are derived below.
var RIBBON = { w: 11.0, cx: -35.1, zStart: 55.5, zA: 61.0, r: 18.0, bend: 55.0, run: 22.0, fade0: 44.0, y0: 0.3, y1: 0.65, conductors: 8 };
// the charger cable's fade (and the ribbon's, the same curve over the same length): a smoothstep over `len` mm. The cable starts it `CABLE.fade0` mm
// behind the plug (x = CABLE.x0 + fade0); the ribbon at RIBBON.fade0. The shaders take both from here (cutouts.glsl cableFade).
var CABLE_FADE = { len: 34.0 };
CABLE.x1 = CABLE.x0 + CABLE.fade0 + CABLE_FADE.len;      // the cable ends where its fade ends: anything past it would be cast and shaded for no ink
(function () {
    var th = RIBBON.bend * Math.PI / 180, R = RIBBON.r, e1z = RIBBON.zA + R * Math.sin(th);
    var e2z = e1z + RIBBON.run * Math.cos(th), c2z = e2z + R * Math.sin(th);
    var s3 = RIBBON.zA - RIBBON.zStart + 2 * R * th + RIBBON.run;     // the arc length where the second bend ends and the last leg (along +z) begins
    RIBBON.sEnd = RIBBON.fade0 + CABLE_FADE.len;
    RIBBON.zEnd = c2z + (RIBBON.sEnd - s3);
    RIBBON.x1 = RIBBON.cx + 2 * R * (1 - Math.cos(th)) + RIBBON.run * Math.sin(th);     // the last leg's x
})();
var CONNECTOR = { x0: -42.0, x1: -28.2, z0: 52.1, z1: 55.9, h: 1.8 };       // toward the battery
// its dressing: the slot the ribbon enters on the +z face, and the flip-lock bar along its top (up to 0.8 mm above the housing)
CONNECTOR.slot = { x0: -41.0, x1: -29.2, y0: 0.2, y1: 1.45 };
CONNECTOR.latch = { x0: -41.3, x1: -28.9, z0: 53.0, z1: 55.2, y1: 2.5 };       // its back edge is far enough in that the strip it hides behind the housing (its height) stops short of the display trace's run at z 50.2

// ---- the boxes ------------------------------------------------------------------------------
// opts: `cast` (default true: it shadows what it stands over), `idx`, `shape: "cylY"` (a vertical cylinder, flat lid, inscribed in the
// box: the generator draws it with the analytic one), and `empty: true` -- the part must stand on EMPTY board: its footprint grown 0.6 mm
// may not meet a trace's corridor, a label's box or another part (`on: [names]` are the parts it is
// allowed to stand on, e.g. a card's parts on "cardPcb"; `foot`: the rectangles [x0, z0, x1, z1] of a footprint that its box is not, a U-shaped socket's).
function B(name, mat, group, mn, mx, opts) {
    var o = { name: name, mat: mat, group: group, min: mn, max: mx, cast: true, idx: 0 };
    for (var k in (opts || {}))
        o[k] = opts[k];
    return o;
}
// A ROW: identical boxes (cells) on a grid -- ONE primitive for the shaders, never N unrolled boxes (an orthographic ray crosses a
// few cells of a row, found by arithmetic). `at` is the first cell's min corner, `cell` its size, `pitch` [px, pz] the step between cells along
// x and z (ignored where `n` is 1), `n` [nx, nz] the counts. The part's min / max are the whole row's box (what the picker and the checks
// see); `k` how many cells one ray can touch (2; the shader tests the first k it meets); `shape: "cylY"` makes every cell the cylinder inscribed in it (the cell's x size is its diameter). More opts: `cluster` (parts that
// stand together share a bound the ray tests first), `bake` (only the cached board draws it: the live glow does not cast it), `ao: false`
// (no contact shadow), `aoFloat` (a part held above the board still shades what is under it), `aoOn` (the part it stands on: the contact darkening of THAT surface takes it, tools/dev/silicon_shader_gen.js), `cut` (the part is cut to a shape the shaders know: cutouts.glsl), `skip` (a ROW only: the index, or a list of up to four, of cells left
// out: the gap in the middle of a stick's chips, cells that are hidden behind a tall part).
function ROW(name, mat, group, at, cell, pitch, n, opts) {
    var mx = [at[0] + (n[0] - 1) * pitch[0] + cell[0], at[1] + cell[1], at[2] + (n[1] - 1) * pitch[1] + cell[2]];
    var o = B(name, mat, group, at.slice(), mx, opts);
    o.row = { cell: cell, pitch: pitch, n: n, k: (opts && opts.k) || 2 };       // k: how many cells a ray can touch (the first k it meets are tested)
    if (opts && opts.skip !== undefined)
        o.row.skip = opts.skip;                                                  // the index of a cell left out of the row (the gap in the middle of a stick's chips)
    return o;
}

// package space -> board space for a rectangle [x0, z0, x1, z1] (the package sits at the
// zone centre with no turn in the geometry; the shader turns the zone)
function P(r) {
    return [ZONE.cx + r[0], ZONE.cz + r[1], ZONE.cx + r[2], ZONE.cz + r[3]];
}

var PARTS = (function () {
    var out = [];
    out.push(B("board", MAT.BOARD, "board", [BOARD.x0, BOARD.y0, BOARD.z0], [BOARD.x1, BOARD.y1, BOARD.z1], { cast: false }));

    // CPU package
    var sw = PKG.substrate.w / 2, sd = PKG.substrate.d / 2, sh = PKG.substrate.h;
    out.push(B("substrate", MAT.SUBSTRATE, "pkg", [ZONE.cx - sw, 0, ZONE.cz - sd], [ZONE.cx + sw, sh, ZONE.cz + sd]));
    var bw = PKG.base.w / 2, bd = PKG.base.d / 2, bh = sh + PKG.base.h;
    out.push(B("baseDie", MAT.BASE_DIE, "pkg", [ZONE.cx - bw, sh, ZONE.cz - bd], [ZONE.cx + bw, bh, ZONE.cz + bd]));
    var th = bh + PKG.tileH;
    var tiles = [["compute", MAT.TILE_COMPUTE], ["graphics", MAT.TILE_GRAPHICS], ["soc", MAT.TILE_SOC], ["io", MAT.TILE_IO]];
    for (var i = 0; i < tiles.length; i++) {
        var r = P(PKG[tiles[i][0]]);
        out.push(B(tiles[i][0], tiles[i][1], "pkg", [r[0], bh, r[1]], [r[2], th, r[3]]));
    }

    // slot, latch, card
    out.push(B("slot", MAT.SLOT, "board", [SLOT.x0, 0, SLOT.z0], [SLOT.x1, SLOT.h, SLOT.z1]));
    out.push(B("latch", MAT.LATCH, "board", [LATCH.x0, 0, LATCH.z0], [LATCH.x1, LATCH.h, LATCH.z1]));
    var cy0 = CARD.rest, cy1 = CARD.rest + CARD.pcb;
    out.push(B("cardPcb", MAT.CARD_PCB, "card", [CARD.x0, cy0, CARD.z0], [CARD.x1, cy1, CARD.z1]));
    out.push(B("gpuSubstrate", MAT.GPU_SUBSTRATE, "card", [CARD.substrate[0], cy1, CARD.substrate[1]], [CARD.substrate[2], cy1 + 1.0, CARD.substrate[3]], { aoOn: "cardPcb" }));
    out.push(B("gpuDie", MAT.GPU_DIE, "card", [CARD.die[0], cy1 + 1.0, CARD.die[1]], [CARD.die[2], cy1 + 1.8, CARD.die[3]]));
    for (var g = 0; g < CARD.gddr.length; g++) {
        var q = CARD.gddr[g];
        out.push(B("gddr" + g, MAT.GDDR, "card", [q[0], cy1, q[1]], [q[2], cy1 + 1.1, q[3]], { idx: g, aoOn: "cardPcb" }));
    }

    // battery
    out.push(B("packTray", MAT.PACK_TRAY, "board", [PACK.x0, 0, PACK.z0], [PACK.x1, PACK.h, PACK.z1]));
    for (var c = 0; c < CELLS.length; c++) {
        var cr = CELLS[c];
        out.push(B("cell" + c, MAT.CELL, "board", [cr[0], PACK.h, cr[1]], [cr[2], CELL_TOP, cr[3]], { idx: c, aoOn: "packTray" }));
    }
    out.push(B("termMinus", MAT.TERMINAL, "board", [PACK.x0 - 4.5, 0, 28.5], [PACK.x0, 2.0, 37.5]));
    out.push(B("termPlus", MAT.TERMINAL, "board", [PACK.x1, 0, 25], [PACK.x1 + 4.5, 2.0, 34]));

    // jack, plug, cable
    out.push(B("jack", MAT.JACK, "board", [JACK.x0, 0, JACK.z0], [JACK.x1, JACK.h, JACK.z1]));
    out.push(B("plug", MAT.PLUG, "plug", [PLUG.x0, PLUG.y0, PLUG.z0], [PLUG.x1, PLUG.y1, PLUG.z1]));
    out.push(B("plugBarrel", MAT.PLUG, "plug", [BARREL.x0, (PLUG.y0 + PLUG.y1) / 2 - BARREL.half, (PLUG.z0 + PLUG.z1) / 2 - BARREL.half], [BARREL.x1, (PLUG.y0 + PLUG.y1) / 2 + BARREL.half, (PLUG.z0 + PLUG.z1) / 2 + BARREL.half], { bake: true, cast: false, ao: false }));
    out.push(B("cable", MAT.CABLE, "plug", [CABLE.x0, CABLE.y0, CABLE.z0], [CABLE.x1, CABLE.y1, CABLE.z1], { cast: false }));

    // DIP switch + lever (the lever's geometry is at "80"; the shader slides it)
    out.push(B("dipBody", MAT.DIP_BODY, "board", [DIP.x0, 0, DIP.z0], [DIP.x1, DIP.h, DIP.z1]));
    var lz0 = DIP.cz - LEVER.d / 2;
    out.push(B("dipLever", MAT.DIP_LEVER, "lever", [LEVER.xLow - LEVER.w / 2, DIP.h, lz0], [LEVER.xLow + LEVER.w / 2, DIP.h + LEVER.h, lz0 + LEVER.d]));

    // the 7-segment displays: flat modules (SEG7 above); `idx` is the display's index in the list (figA, figB, ...)
    for (var d = 0; d < SEG7.length; d++) {
        var sd = SEG7[d];
        out.push(B(sd.name, MAT.DISPLAY, "board", [sd.body[0], 0, sd.body[1]], [sd.body[2], SEG.h, sd.body[3]], { idx: d, empty: true }));
    }

    // the lock on the 4th cell, drawn where it rests (the shader slides the group in from LOCK.travel mm out along +x)
    var c3 = CELLS[3], lbz = (c3[1] + c3[3]) / 2, lbx0 = c3[0] - LOCK.overhang, lbx1 = c3[2] + LOCK.overhang, lbm = (lbx0 + lbx1) / 2;
    var by0 = CELL_TOP, by1 = CELL_TOP + LOCK.barH;
    out.push(B("lockBar", MAT.LOCK_BAR, "lock", [lbx0, by0, lbz - LOCK.barD / 2], [lbx1, by1, lbz + LOCK.barD / 2]));
    out.push(B("lockScrewA", MAT.SCREW, "lock", [lbx0 + 0.9, by1, lbz - 0.75], [lbx0 + 2.4, by1 + 0.5, lbz + 0.75], { cast: false, shape: "cylY" }));
    out.push(B("lockScrewB", MAT.SCREW, "lock", [lbx1 - 2.4, by1, lbz - 0.75], [lbx1 - 0.9, by1 + 0.5, lbz + 0.75], { cast: false, shape: "cylY" }));
    out.push(B("lockBody", MAT.LOCK_BODY, "lock", [lbm - 2.4, by1, lbz - 1.6], [lbm + 2.4, by1 + 2.8, lbz + 1.6]));
    // the shackle: two legs that reach down through the body into the bar (both hide them) and a bridge; open it stands
    // LOCK.shackleOpen higher and the legs still reach into the body
    var sy0 = by1 - 0.8, sy1 = by1 + 2.8 + 2.4, sy2 = sy1 + 0.9;
    out.push(B("lockShackleA", MAT.LOCK_BODY, "shackle", [lbm - 1.5, sy0, lbz - 0.45], [lbm - 0.6, sy1, lbz + 0.45], { cast: false }));
    out.push(B("lockShackleB", MAT.LOCK_BODY, "shackle", [lbm + 0.6, sy0, lbz - 0.45], [lbm + 1.5, sy1, lbz + 0.45], { cast: false }));
    out.push(B("lockShackleC", MAT.LOCK_BODY, "shackle", [lbm - 1.5, sy1, lbz - 0.45], [lbm + 1.5, sy2, lbz + 0.45], { cast: false }));

    // ===== the card's bracket, the RAM, the small parts, the display ribbon ==============================================
    // Parts that stand together share a `cluster` (a ray tests its bound first); a `bake` part is drawn by the cached board only. A part
    // flagged `empty` must stand on EMPTY board (or empty card) -- `on` names what it may overlap (what it stands on).

    // ---- the card's I/O bracket: plate, tongue, flange; cut to their rounded outlines by the shaders (cutSd) ----
    var BR = BRACKET, TG = BR.tongue, LP = BR.lip;
    out.push(B("ioPlate", MAT.BRACKET, "card", [BR.x0, BR.y0, BR.z0], [BR.x1, BR.y1, BR.z1], { bake: true, cluster: "bracket", cast: false, cut: true }));
    out.push(B("ioTongue", MAT.BRACKET, "card", [BR.x0, TG.y0, TG.zc - TG.hw0], [BR.x1, BR.y0, TG.zc + TG.hw0], { bake: true, cluster: "bracket", cast: false, cut: true }));
    out.push(B("ioLip", MAT.BRACKET, "card", [BR.x0, LP.y0, LP.z0], [LP.x1, BR.y1, LP.z1], { bake: true, cluster: "bracket", cast: false }));
    // ---- the HDMI plug and its cable in the bracket's receptacle: their own group, drawn by the cached board only ----
    var HD = HDMI, hx = HD.x0;
    var hdmiBox = function (name, mat, len, w, h) {
        out.push(B(name, mat, "hdmi", [hx, HD.yc - h / 2, HD.zc - w / 2], [hx + len, HD.yc + h / 2, HD.zc + w / 2], { bake: true, cluster: "hdmi", cast: false, ao: false }));
        hx += len;
    };
    hdmiBox("hdmiShell", MAT.PLUG, HD.shell.len, HD.shell.w, HD.shell.h);
    hdmiBox("hdmiHood", MAT.PLUG, HD.hood.len, HD.hood.w, HD.hood.h);
    hdmiBox("hdmiCable", MAT.CABLE, HD.cable.len, HD.cable.w, HD.cable.h);
    // ---- the card's heatsink over its front strip (the die stays open) and its VRM / caps on empty card ----
    out.push(B("sinkBase", MAT.HEATSINK, "card", [11.0, cy1, -45.0], [35.0, cy1 + 1.0, -36.0], { bake: true, cluster: "sink", cast: false, aoOn: "cardPcb" }));
    out.push(ROW("sinkFins", MAT.HEATSINK, "card", [11.5, cy1 + 1.0, -44.3], [1.0, 5.4, 7.6], [2.3, 0], [10, 1], { bake: true, cluster: "sink", k: 3 }));
    out.push(ROW("vrmChokes", MAT.CHOKE, "card", [3.0, cy1, -77.5], [5.0, 3.0, 5.0], [0, 8.0], [1, 5], { bake: true, cluster: "vrm", cast: false, empty: true, aoOn: "cardPcb" }));
    out.push(ROW("vrmFets", MAT.MOSFET, "card", [-1.0, cy1, -78.5], [2.8, 0.9, 2.6], [0, 4.5], [1, 9], { bake: true, cluster: "vrm", cast: false, ao: false, empty: true, aoOn: "cardPcb" }));
    out.push(ROW("capsCard", MAT.CAP, "card", [50.5, cy1, -80.0], [4.0, 4.4, 4.0], [0, 7.0], [1, 5], { bake: true, cluster: "caps", shape: "cylY", empty: true, aoOn: "cardPcb" }));
    // cells 1, 4 and 7 of this row would stand behind the caps' columns (4.4 mm tall), hidden from every side in every state: left out
    out.push(ROW("mlccCard", MAT.MLCC, "card", [47.6, cy1, -78.0], [1.6, 0.8, 1.1], [0, 2.4], [1, 9], { bake: true, cluster: "caps", cast: false, ao: false, empty: true, skip: [1, 4, 7], aoOn: "cardPcb" }));

    // ---- the RAM: two sockets in a line along the back edge, a stick in each (cut to its notched outline), the chips (the usage meter: the glow casts
    // them) in two pairs a row with a gap in the middle, the SPD / PMIC in the gap and a few MLCCs. Sockets, sticks and the small parts are baked: only the chips glow ----
    var RM = RAM, ST = RM.stick, CH = RM.chip;
    var stickX = RM.x0.map(function (x0) { return [x0 + RM.wall, x0 + RM.len - RM.wall]; });          // each stick's x range, between its socket's walls
    var stickZ0 = RM.zFront - ST.inset, stickZ1 = RM.zFront + ST.depth;
    var sockets = ["ramSocketA", "ramSocketB"], sticks = ["ramPcbA", "ramPcbB"];
    for (var rk = 0; rk < 2; rk++) {
        var sx0 = RM.x0[rk], sx1 = sx0 + RM.len;
        // `foot`: the footprint's real rectangles (a U: the housing and the two end walls), for the checks that stand a part on empty board
        out.push(B(sockets[rk], MAT.SOCKET, "board", [sx0, 0, RM.z0], [sx1, RM.h, RM.wallZ1],
                   { bake: true, cluster: "ram", empty: true, cut: true, foot: [[sx0, RM.z0, sx1, RM.zFront], [sx0, RM.z0, sx0 + RM.wall, RM.wallZ1], [sx1 - RM.wall, RM.z0, sx1, RM.wallZ1]], on: [sticks[rk]] }));
        out.push(B(sticks[rk], MAT.RAM_PCB, "board", [stickX[rk][0], ST.y0, stickZ0], [stickX[rk][1], ST.y1, stickZ1],
                   { bake: true, cluster: "ram", cast: false, empty: true, cut: true, aoFloat: true, on: [sockets[rk], "ramChipsA", "ramChipsB0", "ramChipsB1", "ramSpd", "ramPmic"] }));
    }
    var chipRow = function (name, rk, row) {
        return ROW(name, MAT.RAM_CHIP, "board", [stickX[rk][0] + CH.dx, ST.y1, CH.z[row]], rk === 0 ? CH.cellA : CH.cell, [CH.pitch, 0], [CH.n, 1], { cluster: "ram", cast: false, ao: false, skip: CH.skip, aoOn: sticks[rk] });
    };
    out.push(chipRow("ramChipsA", 0, 0));
    out.push(chipRow("ramChipsB0", 1, 0));
    out.push(chipRow("ramChipsB1", 1, 1));
    out.push(ROW("ramSpd", MAT.MOSFET, "board", [stickX[0][0] + RM.spd.dx, ST.y1, RM.spd.z], RM.spd.cell, [stickX[1][0] - stickX[0][0], 0], [2, 1], { bake: true, cluster: "ram", cast: false, ao: false, aoOn: "ramPcbA" }));
    out.push(B("ramPmic", MAT.MOSFET, "board", [stickX[1][0] + RM.pmic.dx, ST.y1, RM.pmic.z], [stickX[1][0] + RM.pmic.dx + RM.pmic.cell[0], ST.y1 + RM.pmic.cell[1], RM.pmic.z + RM.pmic.cell[2]], { bake: true, cluster: "ram", cast: false, ao: false, aoOn: "ramPcbB" }));

    // ---- the small parts on empty board: the CPU zone's VRM stub, the charger's input stage at the jack, two rows of MLCCs ----
    out.push(ROW("stubChokes", MAT.CHOKE, "board", [-20.2, 0, -9.5], [3.6, 3.0, 4.4], [0, 6.2], [1, 4], { bake: true, cluster: "stub", cast: false, empty: true }));
    out.push(ROW("stubFets", MAT.MOSFET, "board", [-23.0, 0, -9.5], [2.0, 0.9, 2.4], [0, 3.4], [1, 6], { bake: true, cluster: "stub", cast: false, empty: true }));
    out.push(ROW("chgChokes", MAT.CHOKE, "board", [48.4, 0, 17.0], [4.0, 2.0, 4.4], [0, 6.0], [1, 2], { bake: true, cluster: "chg", cast: false, empty: true }));
    out.push(ROW("chgCaps", MAT.CAP, "board", [53.2, 0, 17.5], [3.4, 4.6, 3.4], [0, 5.0], [1, 3], { bake: true, cluster: "chg", shape: "cylY", empty: true }));
    out.push(ROW("chgFets", MAT.MOSFET, "board", [57.4, 0, 17.0], [2.0, 0.9, 2.6], [0, 3.8], [1, 3], { bake: true, cluster: "chg", cast: false, empty: true }));
    out.push(ROW("mlccFront", MAT.MLCC, "board", [CONNECTOR.x1 + 1.2, 0, 52.8], [1.6, 0.8, 1.1], [2.6, 0], [6, 1], { bake: true, cast: false, empty: true }));
    out.push(ROW("mlccSlot", MAT.MLCC, "board", [3.6, 0, -32.0], [1.6, 0.8, 1.1], [2.4, 0], [5, 1], { bake: true, cast: false, empty: true }));

    // ---- the display connector, its flip-lock bar and the ribbon: one flat strip, cut to its path (cutouts.glsl: ribbonSd) ----
    var RB = RIBBON, CN = CONNECTOR, LT = CN.latch;
    out.push(B("dispConn", MAT.CONNECTOR, "board", [CN.x0, 0, CN.z0], [CN.x1, CN.h, CN.z1], { cluster: "disp", cast: false }));        // not baked: it stands on the front trace's end and hides it from the glow too
    out.push(B("dispLatch", MAT.LATCH_BAR, "board", [LT.x0, CN.h, LT.z0], [LT.x1, LT.y1, LT.z1], { cluster: "disp", cast: false, ao: false }));
    out.push(B("ribbon", MAT.RIBBON, "board", [RB.cx - RB.w / 2, RB.y0, RB.zStart], [RB.x1 + RB.w / 2, RB.y1, RB.zEnd], { bake: true, cluster: "disp", cast: false, ao: false, cut: true }));

    // ===== the strain relief, the substrate's capacitors, the odd parts ======================================================
    // ---- the charger cable's strain relief: stepped collars on the cable behind the plug; they ride with the plug (group `plug`) and only the cached board draws them ----
    var r3y = (PLUG.y0 + PLUG.y1) / 2, r3z = (PLUG.z0 + PLUG.z1) / 2, r3x = PLUG.x1;
    BOOT.collars.forEach(function (c, i) {
        out.push(B("plugBoot" + i, MAT.CABLE, "plug", [r3x, r3y - c.hy, r3z - c.hz], [r3x + c.len, r3y + c.hy, r3z + c.hz], { bake: true, cluster: "boot", cast: false, idx: i }));
        r3x += c.len;
    });
    // ---- small capacitors on the CPU package's substrate margins round the base die (the package's own parts: they turn and lift with it). Two rows along its long margins
    // and a short column on each of the others, lying on the substrate's top (y = PKG.substrate.h) ----
    var r3s = PKG.substrate.h, r3cx = ZONE.cx, r3cz = ZONE.cz, r3hw = PKG.substrate.w / 2, r3hd = PKG.substrate.d / 2;
    var r3opt = { bake: true, cluster: "pkgcaps", cast: false, ao: false };
    out.push(ROW("pkgCapsN", MAT.MLCC, "pkg", [r3cx - 8.2, r3s, r3cz - r3hd + 2.15], [1.2, 0.5, 0.7], [3.8, 0], [5, 1], r3opt));
    out.push(ROW("pkgCapsS", MAT.MLCC, "pkg", [r3cx - 8.2, r3s, r3cz + r3hd - 2.85], [1.2, 0.5, 0.7], [3.8, 0], [5, 1], r3opt));
    out.push(ROW("pkgCapsW", MAT.MLCC, "pkg", [r3cx - r3hw + 3.15, r3s, r3cz - 4.4], [0.7, 0.5, 1.2], [0, 3.8], [1, 3], r3opt));
    out.push(ROW("pkgCapsE", MAT.MLCC, "pkg", [r3cx + r3hw - 3.85, r3s, r3cz - 4.4], [0.7, 0.5, 1.2], [0, 3.8], [1, 3], r3opt));
    // ---- the odd capacitor and transistors on the empty board between the battery's displays, the DIP switch and the pack ----
    var r3k2 = { bake: true, cluster: "k2", cast: false, empty: true };
    out.push(B("k2Cap", MAT.CAP, "board", [9.0, 0, 6.0], [12.0, 3.6, 9.0], { bake: true, cluster: "k2", cast: false, shape: "cylY", empty: true }));
    out.push(ROW("k2Fets", MAT.MOSFET, "board", [-5.0, 0, 2.4], [2.0, 0.9, 2.4], [0, 3.6], [1, 2], { bake: true, cluster: "k2", cast: false, empty: true }));
    out.push(ROW("k2Mlcc", MAT.MLCC, "board", [2.0, 0, 10.0], [1.6, 0.8, 1.1], [2.4, 0], [3, 1], r3k2));
    return out;
})();

// ---- traces: polylines on the board's top face, [x, z] mm ------------------------------------
// kind: power (wide), signal (thin), stub (the zone's breakout, courtyard -> zone edge).
// `from` is where current enters the trace: the glow and the particles run from there.
// A vertex may carry a third number, the trace's FULL width there (mm; the trace's `width` elsewhere):
// a trace that narrows from a stub's 2.2 to a lane's 0.8 does it along its own path, so there is no
// seam where one hands over to the other. `blend` names a group whose traces melt into one another
// where they come close (a smooth union of their distance fields over BLEND_K mm): a fan that opens
// from one body into lanes, lanes that merge into one. `zone: true` marks the four stubs inside the
// CPU zone (the zone shows only those); every other trace stays outside it.
var BLEND_K = 0.7;
var Z = ZONE, ZH = ZONE.half, CY = ZONE.courtyard;

// smootherstep, 0 at 0 and 1 at 1, flat at both ends: an S-curve whose slope is zero where it leaves
// and where it arrives (a lane leaves its fan on it)
function sm5(t) {
    t = Math.max(0, Math.min(1, t));
    return t * t * t * (t * (6 * t - 15) + 10);
}
// A lane leaving a centre line: from [x0, z0] along the unit direction [dx, dz], it drifts sideways by
// `off` mm (along the normal [-dz, dx]) over `len` mm while its width goes from w0 to w1,
// in n steps. Straight-line segments between the points; the fan is a few mm so the chords are
// sub-hundredth-mm from the curve.
function fanLane(x0, z0, dx, dz, len, off, w0, w1, n) {
    var out = [];
    for (var i = 0; i <= n; i++) {
        var u = i / n, s = sm5(u);
        out.push([x0 + dx * len * u - dz * off * s, z0 + dz * len * u + dx * off * s, w0 + (w1 - w0) * Math.min(1, u * 1.4)]);
    }
    return out;
}
// the points of an arc about [cx, cz], radius r, from angle a0 to a1 degrees (0 = +x, 90 = +z), width w
function arcPts(cx, cz, r, a0, a1, n, w) {
    var out = [];
    for (var i = 0; i <= n; i++) {
        var a = (a0 + (a1 - a0) * i / n) * Math.PI / 180;
        out.push(w === undefined ? [cx + r * Math.cos(a), cz + r * Math.sin(a)] : [cx + r * Math.cos(a), cz + r * Math.sin(a), w]);
    }
    return out;
}

// the PCIe lanes: four of them leave the zone's -z stub (the stub's 2.2 mm on the zone edge, z = -13) and fan
// out to their own 1.6 mm pitch, each narrowing to 0.8 as it goes. They start on the stub's own centre line at the
// stub's own width, so the stub carries on into them with no step, and the smooth union melts the crotches
var PCIE_OFF = [-2.4, -0.8, 0.8, 2.4], PCIE_Z = [-61.6, -60.0, -58.4, -56.8], PCIE_FAN = 11;
function pcieLane(i) {
    var edge = Z.cz - ZH, fan = fanLane(Z.cx, edge, 0, -1, PCIE_FAN, PCIE_OFF[i], 2.2, 0.8, 10);
    // heading -z, a positive offset is +x: the lanes are listed from -x to +x
    return fan.concat([[Z.cx + PCIE_OFF[i], PCIE_Z[i]], [SLOT.x0, PCIE_Z[i]]]);
}

// the back-left edge (memory, display). The zone's -x stub carries on as a STEM, 2.2 mm wide, straight to a T on the edge; the T's two branches -- the
// edge's lane up to the top corner and the dGPU's display lane down the edge -- are lane-wide (0.8) from the T itself, so the T accommodates the change
// of width and neither branch tapers after it (the thick part stays thick up to the T, what splits off is the thin one). The stem ends
// flush with the lane's far side (its round end is the T's foot: its tip is the lane's far edge) and the T's two crotches are filleted by a blend of
// their own (a group with its own reach, TEE_K). At the top corner the lane rounds the corner and runs on along the slot's first lane, which it
// meets end to end (same width, same line: no seam), and the slot's second lane merges into that line.
var EDGE_X = -89, TOP_Z = -83.4, TURN_R = 2.0, MERGE_X = -62, MERGE_RUN = 14;
var TEE_K = 1.8;
function stemPts() {
    return [[Z.cx - ZH, Z.cz], [EDGE_X + 0.7, Z.cz]];            // 0.7 = the stem's half width (1.1) less the lane's (0.4)
}
function cpuOutPts() {
    var p = [[EDGE_X, Z.cz], [EDGE_X, TOP_Z + TURN_R]];
    p = p.concat(arcPts(EDGE_X + TURN_R, TOP_Z + TURN_R, TURN_R, 180, 270, 6).slice(1));   // the top corner (its first point is the leg's end)
    p.push([MERGE_X, TOP_Z]);
    return p;
}
// the slot's second lane, out of the slot and along the back-right edge, then it leans onto the first lane's
// line over MERGE_RUN mm and ends on it (a quadratic lean: it arrives at a shallow angle)
function slotOut1Pts() {
    var z0 = -81.8, x0 = MERGE_X + MERGE_RUN, p = [[-0.4, SLOT.z0], [-0.4, z0], [x0, z0]];
    for (var i = 1; i <= 7; i++) {
        var u = i / 7;
        p.push([x0 - MERGE_RUN * u, z0 + (TOP_Z - z0) * u * u]);
    }
    return p;
}

// The display's traces: the dGPU's way to the display leaves the edge's lane at the T, runs down the edge, turns along the front -- BEHIND the
// connector's shadow, FRONT_Z, a 1.8 mm part hides 1.8 mm of board behind it (x and z at once) and the run's far edge stays 0.3 clear of that --
// and meets the zone's +z stub at a T of its own (the stub's round end is the stem), from which the lane runs on to the connector and turns into
// its back face, perpendicular, at the connector's middle (the connector hides the last 1.8 mm of it: it goes in).
var FRONT_Z = 49.6, FRONT_R = 1.5, CONN_X = (CONNECTOR.x0 + CONNECTOR.x1) / 2, CONN_R = 1.0;
function dispDownPts() {
    var p = [[EDGE_X, Z.cz], [EDGE_X, FRONT_Z - FRONT_R]];
    p = p.concat(arcPts(EDGE_X + FRONT_R, FRONT_Z - FRONT_R, FRONT_R, 180, 90, 4).slice(1));
    p.push([Z.cx, FRONT_Z]);
    return p;
}
function frontPts() {
    var p = [[Z.cx, FRONT_Z], [CONN_X - CONN_R, FRONT_Z]];
    p = p.concat(arcPts(CONN_X - CONN_R, FRONT_Z + CONN_R, CONN_R, 270, 360, 4).slice(1));
    p.push([CONN_X, CONNECTOR.z0 + 1.9]);
    return p;
}

var TRACES = [
    // the zone's four breakout stubs (courtyard -> zone edge), 4-fold symmetric
    { name: "stubPx", kind: "stub", width: 2.2, from: "zone", zone: true, pts: [[Z.cx + CY, Z.cz], [Z.cx + ZH, Z.cz]] },
    { name: "stubNx", kind: "stub", width: 2.2, from: "zone", zone: true, pts: [[Z.cx - CY, Z.cz], [Z.cx - ZH, Z.cz]] },
    { name: "stubPz", kind: "stub", width: 2.2, from: "zone", zone: true, pts: [[Z.cx, Z.cz + CY], [Z.cx, Z.cz + ZH]] },
    { name: "stubNz", kind: "stub", width: 2.2, from: "zone", zone: true, pts: [[Z.cx, Z.cz - CY], [Z.cx, Z.cz - ZH]] },

    // the system rail: pack (-) -> CPU (the zone's +x stub) and -> the slot, behind the pack. It starts UNDER the (-) terminal (x -20.5 .. -16, the
    // terminal's outer face is -20.5): a start on the face would stick a round cap out of it. (Its first 16 mm, and the branch to the slot, are behind the
    // pack's wall and are not drawn: the cut at the foot of this file.)
    { name: "packCpu", kind: "power", width: 2.2, from: "pack", pts: [[PACK.x0 - 2, 33], [-20, 33], [-20, Z.cz], [Z.cx + ZH, Z.cz]] },
    // the card's power: it ends UNDER the slot (a cap on its face would stick out of it)
    { name: "packSlot", kind: "power", width: 2.2, from: "pack", pts: [[-20, 26], [-14, 26], [-14, -18], [-2, -18], [-2, SLOT.z1 - 1.4]] },
    // charging: jack -> pack (+). It runs up beside the DC IN and ENDS under the (+) terminal (x 42 .. 46.5, z 25 .. 34): a last stretch turned out
    // to the terminal's outer face would stick a round end out of it, a trace end that goes nowhere
    { name: "jackPack", kind: "power", width: 2.2, from: "jack", pts: [[JACK.x0, -0.5], [45, -0.5], [45, 29.5]] },
    // PCIe lanes: the zone's -z stub -> the slot, four in parallel, fanning out of the stub's body
    { name: "pcie0", kind: "signal", width: 0.8, from: "cpu", blend: "pcie", pts: pcieLane(0) },
    { name: "pcie1", kind: "signal", width: 0.8, from: "cpu", blend: "pcie", pts: pcieLane(1) },
    { name: "pcie2", kind: "signal", width: 0.8, from: "cpu", blend: "pcie", pts: pcieLane(2) },
    { name: "pcie3", kind: "signal", width: 0.8, from: "cpu", blend: "pcie", pts: pcieLane(3) },
    // the zone's -x stub -> its stem to the T on the back-left edge; from the T the edge's lane goes round the top corner to the slot's two lanes (cpuOut)
    // and the display lane goes down the edge (dispDown). The three meet at the T and melt there (blend "tee", TEE_K)
    { name: "cpuOutStem", kind: "signal", width: 2.2, from: "cpu", blend: "tee", blendK: TEE_K, pts: stemPts() },
    { name: "cpuOut", kind: "signal", width: 0.8, from: "cpu", blend: "tee", blendK: TEE_K, fromPack: 54.5, pts: cpuOutPts() },
    // the zone's +z stub -> its stem, just the stub's round end on the front lane (the stem of the T there, a point on the zone's edge: a trace of no length) ...
    { name: "cpuFrontStem", kind: "signal", width: 2.2, from: "cpu", blend: "tee", blendK: TEE_K, pts: [[Z.cx, Z.cz + ZH], [Z.cx, Z.cz + ZH]] },
    // ... and from that T the lane to the connector's back face (cpuFront)
    { name: "cpuFront", kind: "signal", width: 0.8, from: "cpu", blend: "tee", blendK: TEE_K, fromPack: 52.1, pts: frontPts() },
    // out of the slot along the back-right edge toward the top corner: the dGPU's way out, two lanes; the
    // first meets the back-left edge's lane end to end, the second merges into it
    { name: "slotOut0", kind: "signal", width: 0.8, from: "slot", blend: "merge", pts: [[-3.6, SLOT.z0], [-3.6, TOP_Z], [MERGE_X, TOP_Z]] },
    { name: "slotOut1", kind: "signal", width: 0.8, from: "slot", blend: "merge", pts: slotOut1Pts() },
    // the dGPU's way to the display: down the left edge from the T, along the front into cpuFront at its own T (lit only while the dGPU drives the panel)
    { name: "dispDown", kind: "signal", width: 0.8, from: "cpu", blend: "tee", blendK: TEE_K, fromPack: 54.5, pts: dispDownPts() }
];

// Every trace's length, its ROLE (whose light it carries: cpu, gpu, charge) and how far its start lies from the pack along the network (mm): the
// power-on sweep and the battery's event pulse travel outward from the pack by that distance plus the arc.
// THE FLOW: the pulse trains are laid along the copper by a COORDINATE, `s` (mm), one number at every vertex of a trace. The generator
// interpolates it along each stretch and carries it on past a trace's ends -- a cap is copper too, the pulse slides over it with the copper's own
// coverage -- and blends it by distance where traces meet at a T (`soft` stretches), so that wherever two traces meet, the zone's edge, the T, the
// fork, the Y, both sides carry the same `s` and a pulse is ONE pulse through the joint. The coordinates:
//   power in   packCpu, stubPx: mm of copper from the (-) terminal's outer face (the pack's), so a pulse arrives at the package's courtyard at s = P0;
//   the package's own traffic OUT: every other stub starts at P0 too (the package hands pulses through: one arrives while the others leave), and a
//              route goes on from there -- the -x stub through the stem and the T into BOTH branches (the edge's lane round the top corner into BOTH of
//              the slot's lanes, and the display lane down the edge), the -z stub through the fork into ALL four lanes, the +z stub along cpuFront;
//   charge     jackPack: mm from the jack;   the card's power: packSlot: mm from where it leaves the rail.
// Where a route has nobody listening it does not end at a joint: it runs on and fades along the route (`fade`: kind 1 while the dGPU is not awake
// -- listening, the train goes to the slot -- kind 2 always, the display lane's: the connector listens for the display, not for the -x stub's
// traffic), over FADE_LEN mm >= 15 from where the route has split. The colour of a route changes by a blend over >= 6 mm (`hand`: the CPU's light takes the
// dGPU's hue as it nears the card), never at a line. The dGPU-only display path
// (slot -> its two lanes -> the edge's lane back to the T -> the display lane -> cpuFront) is a second train along the same copper: it has its own
// coordinate `g` at every vertex (blended at a T with `s`), and the share of the copper that carries it, m, rises over a ramp of `s` (`disp`: m0 .. m1,
// >= 6 mm on the stems it runs into) -- the CPU's train gives way to it by that share, so nothing is cut off at a T.
var PACK_TO_ZONE = 19.5;            // mm of copper from the (-) terminal's outer face to the zone's +x edge (packCpu's polyline starts 1.5 mm further back, under the terminal)
var FADE_LEN = 24;                  // mm: the pulse trains fade out along a route that nobody listens to
var FLOW_CH = { power: 0, cpu: 1, charge: 2, gpu: 3 };
(function () {
    var len = function (t) {
        var L = 0;
        for (var i = 0; i + 1 < t.pts.length; i++)
            L += Math.sqrt(Math.pow(t.pts[i + 1][0] - t.pts[i][0], 2) + Math.pow(t.pts[i + 1][1] - t.pts[i][1], 2));
        return L;
    };
    var cumOf = function (t) {
        var c = [0];
        for (var i = 0; i + 1 < t.pts.length; i++)
            c.push(c[i] + Math.sqrt(Math.pow(t.pts[i + 1][0] - t.pts[i][0], 2) + Math.pow(t.pts[i + 1][1] - t.pts[i][1], 2)));
        return c;
    };
    var by = {};
    TRACES.forEach(function (t) { t.length = len(t); by[t.name] = t; });
    var stub = ZH - CY;
    var roles = { stub: "cpu", packCpu: "cpu", cpuOut: "cpu", cpuFront: "cpu", packSlot: "gpu", slotOut: "gpu", pcie: "gpu", jackPack: "charge", dispDown: "display" };
    TRACES.forEach(function (t) {
        var key = t.name.replace(/[0-9]+$/, "").replace(/^stub.*/, "stub");
        t.role = roles[key] || "cpu";
        if (t.fromPack !== undefined)
            return;
        if (t.name === "packCpu" || t.name === "packSlot" || t.name === "jackPack")
            t.fromPack = 0;
        else if (t.kind === "stub")
            t.fromPack = PACK_TO_ZONE + stub;             // the sweep runs along a stub from the courtyard (d = fromPack - arc: the stubs are stored courtyard -> edge)
        else if (t.from === "cpu")
            t.fromPack = PACK_TO_ZONE + 2 * stub + 20;    // across the package
        else if (t.from === "slot")
            t.fromPack = by.packSlot.length;
        else
            t.fromPack = 0;
    });

    // ---- the flow coordinates ----
    var P0 = PACK_TO_ZONE + stub;                         // the courtyard
    var E0 = P0 + stub;                                   // the zone's edge, on a route that leaves the package
    var sV = E0 + (Z.cx - ZH - EDGE_X);                   // the left T, on the edge's lane
    var sM = E0 + (FRONT_Z - (Z.cz + ZH));                // the front T
    var FULL = { m0: -1e4, m1: -1e4 + 1 };                // m = 1 everywhere
    var NONE = { m0: 1e4, m1: 1e4 + 1 };                  // m = 0 everywhere
    TRACES.forEach(function (t) {
        t.soft = [];
        t.fade = { kind: 0, a: 0, b: 1 };
        t.hand = { a: 1e4, b: 1e4 + 1 };
        t.disp = { m0: NONE.m0, m1: NONE.m1 };
        t.g = null;
    });
    var C = function (t) { return cumOf(t); };
    // power in
    by.stubPx.ch = FLOW_CH.power;
    by.stubPx.s = [P0, PACK_TO_ZONE];
    by.packCpu.ch = FLOW_CH.power;
    by.packCpu.s = C(by.packCpu).map(function (c) { return c - 1.5; });
    // the package's own traffic out
    ["stubNx", "stubNz", "stubPz"].forEach(function (n) {
        by[n].ch = FLOW_CH.cpu;
        by[n].s = [P0, E0];
    });
    by.cpuOutStem.ch = FLOW_CH.cpu;
    by.cpuOutStem.s = C(by.cpuOutStem).map(function (c) { return E0 + c; });
    by.cpuOutStem.soft = [0];
    by.cpuOut.ch = FLOW_CH.cpu;
    by.cpuOut.s = C(by.cpuOut).map(function (c) { return sV + c; });
    by.cpuOut.soft = [0];
    var sY = sV + by.cpuOut.length;                       // the top corner's split
    ["slotOut0", "slotOut1"].forEach(function (n) {
        var t = by[n], L = t.length;
        t.ch = FLOW_CH.cpu;
        t.s = C(t).map(function (c) { return sY + (L - c); });          // stored from the slot: the CPU's train runs the other way
    });
    by.cpuFrontStem.ch = FLOW_CH.cpu;
    by.cpuFrontStem.s = [sM, sM];
    by.cpuFrontStem.soft = [0];
    by.cpuFront.ch = FLOW_CH.cpu;
    by.cpuFront.s = C(by.cpuFront).map(function (c) { return sM + c; });
    by.cpuFront.soft = [0];
    var dd = by.dispDown, Ldd = dd.length;
    dd.ch = FLOW_CH.cpu;
    // the display lane carries the -x stub's train from the left T (rising s) and the +z stub's from the front T (falling s) and they never meet: each has
    // faded out before the peak of the roof this makes (the peak is beyond 2 FADE_LEN from either T)
    dd.s = C(dd).map(function (c) { return Math.min(sV + c, sM + (Ldd - c)); });
    dd.soft = [0, dd.pts.length - 2];
    for (var i = 0; i < 4; i++) {
        var p = by["pcie" + i];
        p.ch = FLOW_CH.cpu;
        p.s = C(p).map(function (c) { return E0 + c; });
    }
    by.packSlot.ch = FLOW_CH.gpu;
    by.packSlot.s = C(by.packSlot);
    by.jackPack.ch = FLOW_CH.charge;
    by.jackPack.s = C(by.jackPack);

    // ---- the listeners' fades and the colour blends ----
    var fan = E0 + PCIE_FAN;                               // the fork's split is over here
    for (var j = 0; j < 4; j++) {
        by["pcie" + j].fade = { kind: 1, a: fan, b: fan + FADE_LEN };
        by["pcie" + j].hand = { a: 88, b: 100 };
    }
    ["cpuOut", "slotOut0", "slotOut1"].forEach(function (n) {
        by[n].fade = { kind: 1, a: sY + 4, b: sY + 4 + FADE_LEN };       // the Y's split: the lanes beyond it are listened to by the dGPU only
        by[n].hand = { a: sY + 36, b: sY + 48 };
    });
    dd.fade = { kind: 2, a: sV + 2, b: sV + 2 + FADE_LEN };

    // ---- the dGPU-only display path ----
    var L0 = by.slotOut0.length, Lout = by.cpuOut.length;
    var DV = L0 + Lout, DM = DV + Ldd;                     // its coordinate at the left T and at the front T
    var setG = function (t, f) { t.g = C(t).map(f); };
    setG(by.slotOut0, function (c) { return c; });                                                    // stored from the slot: the path runs along the arc
    setG(by.slotOut1, function (c) { return c - (by.slotOut1.length - L0); });                       // equal to slotOut0's at the Y
    setG(by.cpuOut, function (c) { return DV - c; });                                                 // back along the edge's lane, from the Y to the T
    setG(dd, function (c) { return DV + c; });
    setG(by.cpuFront, function (c) { return DM + c; });
    by.cpuFrontStem.g = [DM, DM];
    ["slotOut0", "slotOut1", "cpuOut", "cpuFront", "cpuFrontStem"].forEach(function (n) { by[n].disp = { m0: FULL.m0, m1: FULL.m1 }; });
    dd.disp = { m0: FULL.m0, m1: FULL.m1 };
    // the stems: the path runs into them as a tail whose share falls to 0 at the stubs' courtyard ends
    var dT = Z.cx - ZH - EDGE_X;                                  // the stem's length: the zone's edge to the T
    setG(by.cpuOutStem, function (c) { return DV + dT - c; });
    by.cpuOutStem.disp = { m0: P0 + 1.5, m1: sV };
    setG(by.stubNx, function (c) { return DV + dT + stub - c; });
    by.stubNx.disp = { m0: P0 + 1.5, m1: sV };
    setG(by.stubPz, function (c) { return DM + (sM - E0) + stub - c; });
    by.stubPz.disp = { m0: P0, m1: sM };

    // ---- what is never seen is not drawn ----
    // A stretch of copper that no state of the scene shows -- a part that is in every state stands in front of it: the pack's wall, the jack, a terminal, the slot, the
    // display connector -- is a groove nobody sees (the arcs below are mm along the polylines as built above, and a trace may dive 3 mm
    // under the part it feeds). Each such trace is cut to a dive of TRIM_DIVE mm under that part, so it goes IN: the hidden joints (the rail's
    // branch to the card, the jack's L under the jack) are not drawn, the flow's coordinates, its fades and the sweep's distance keep their values on every point that is
    // seen (the cut interpolates them), and nothing that is seen moves.
    var TRIM_DIVE = 2.0;
    var trim = function (t, a0, a1) {
        var c = cumOf(t), L = c[c.length - 1];
        a0 = Math.max(0, a0);
        a1 = Math.min(L, a1 === undefined ? L : a1);
        var at = function (a) {
            var i = 0;
            while (i + 2 < c.length && a > c[i + 1]) i++;
            var u = (a - c[i]) / Math.max(c[i + 1] - c[i], 1e-9);
            var A = t.pts[i], B = t.pts[i + 1];
            var p = [A[0] + (B[0] - A[0]) * u, A[1] + (B[1] - A[1]) * u];
            if (A.length > 2 || B.length > 2)
                p.push((A.length > 2 ? A[2] : t.width) + ((B.length > 2 ? B[2] : t.width) - (A.length > 2 ? A[2] : t.width)) * u);
            return { p: p, s: t.s[i] + (t.s[i + 1] - t.s[i]) * u, g: t.g ? t.g[i] + (t.g[i + 1] - t.g[i]) * u : 0 };
        };
        var keep = [at(a0)];
        for (var i = 1; i + 1 < t.pts.length; i++)
            if (c[i] > a0 + 1e-9 && c[i] < a1 - 1e-9)
                keep.push({ p: t.pts[i], s: t.s[i], g: t.g ? t.g[i] : 0 });
        keep.push(at(a1));
        t.pts = keep.map(function (k) { return k.p; });
        t.s = keep.map(function (k) { return k.s; });
        if (t.g)
            t.g = keep.map(function (k) { return k.g; });
        t.length = a1 - a0;
        t.fromPack += a0;                                    // the sweep's distance at a point stays what it was
    };
    trim(by.packCpu, 18.0 - TRIM_DIVE);                                       // behind the pack's wall (cell0, 6.6 mm up) all the way from the terminal to x -21
    trim(by.packSlot, 19.0 - TRIM_DIVE);                                      // behind the pack's tray, 19 mm
    trim(by.jackPack, 5.3 - TRIM_DIVE, 28.0 + TRIM_DIVE);                      // under the jack, and under the (+) terminal
    for (var q = 0; q < 4; q++)
        trim(by["pcie" + q], 0, by["pcie" + q].length - (4.5 - TRIM_DIVE));    // the last 4.5 mm under the slot / the card
    trim(by.cpuFront, 0, 20.3 + TRIM_DIVE);                                    // under the display connector
    trim(by.slotOut0, 11.1 - TRIM_DIVE);                                       // under the slot, the first 11 mm
    trim(by.slotOut1, 12.8 - TRIM_DIVE);                                       // under the slot, up to the 13th mm
    by.packSlot.soft = by.packSlot.pts.slice(1).map(function (_, i) { return i; });      // its two visible bends are wide
})();

// The battery's poles: where each terminal's field of particles starts (the middle of the terminal's outer face -- its horizontal AND its vertical centre,
// `y`) and the face's normal, the way straight out of it. Read off the terminal parts themselves, so a terminal that moves or changes takes its pole with
// it. A field may LEAN away from the normal (toward +z): that is the field's own tuning, a degree figure in
// ParticleField.qml (`chargeLeanPlus` ...), not geometry. The discharge goes straight out and ends before the charger's first capacitor.
var POLES = (function () {
    function term(name) {
        return PARTS.filter(function (p) { return p.name === name; })[0];
    }
    var tm = term("termMinus"), tp = term("termPlus");
    return {
        minus: { at: [tm.min[0], (tm.min[2] + tm.max[2]) / 2], y: (tm.min[1] + tm.max[1]) / 2, dir: [-1, 0] },
        plus: { at: [tp.max[0], (tp.min[2] + tp.max[2]) / 2], y: (tp.min[1] + tp.max[1]) / 2, dir: [1, 0] }
    };
})();

// ---- labels (silkscreen), board space; the mask is drawn by tools/silicon/make_silkscreen.py --
// rot: degrees, counter-clockwise seen from above, 0 = text runs along +x. Nothing inside the
// zone's edge band: the zone must stay 4-fold symmetric where it meets the board.
var LABELS = [
    { text: "CPU", x: -76, z: 54, size: 4.2, rot: 0 },
    { text: "GPU", x: 25, z: -26, size: 4.2, rot: 0 },
    // under the four lanes that run to the slot, clear of the GPU hologram's plane (the card, 6 mm up, hides the board beside it)
    { text: "PCIe x16", x: -30, z: -53, size: 2.8, rot: 0 },
    { text: "BAT", x: 8, z: 53, size: 4.0, rot: 0 },
    // the DIP switch's 80 / 100: the board's top is hidden behind a 3.6 mm body (a part hides the board behind it by its height, in x and in
    // z at once) and the pack's tray hides the front strip, so they are printed ON the switch's top face, in its front margin, under the two places the lever rests at ("on": the part the label is on)
    // (`face: "figures"`: Material draws them in the board's printed figures' face, a plain zero -- Audiowide's slashed one reads as "8e 1ee" at 1x)
    { text: "80", x: LEVER.xLow, z: 13.7, size: 3.0, rot: 0, data: true, on: "dipBody", face: "figures" },
    // the limit's off position reads MAX (it is the pack's whole capacity, not a number); a little smaller than the 80 so the word keeps inside the switch's top face
    { text: "MAX", x: LEVER.xHigh, z: 13.7, size: 2.7, rot: 0, data: true, on: "dipBody" },
    { text: "DC IN", x: 55.5, z: 9.5, size: 2.6, rot: 0 },
    // the pack's signs: one either side of the word BAT, on its middle line and in its size class (3.6 beside the word's 4.0: a sign's strokes read larger than a letter's), each a generous gap from the word (the "-" toward the
    // pack's minus end on the left, the "+" toward its plus end on the right); the word is 12.3 mm wide in Audiowide and 9.5 in Bahnschrift, so a sign's centre 10.25 mm from
    // the word's leaves 2.6 mm of paper beside the wider and 4 beside the narrower, and the front of the pack (z 53) is clear of the tray in every state. The word stands at
    // x 8 so the "+" stays clear of Blueprint's title block (its frame starts at x 22)
    { text: "+", x: 8 + 10.25, z: 53, size: 3.6, rot: 0 },
    { text: "\u2212", x: 8 - 10.25, z: 53, size: 3.6, rot: 0 }
];
// the labels that belong to the figures (`data: true`: the board prints them in the deeper ink of data, like the figures): each display's own (the time display's is the glyph atlas's, MODE_LABELS) and the short label
// above each printed figure, its ink ending where the figure's does (`anchor: "right"`: make_silkscreen.py measures the real glyphs)
SEG7.forEach(function (d) {
    if (d.label.text)
        LABELS.push({ text: d.label.text, x: d.label.x, z: d.label.z, size: d.label.size, rot: 0, data: true });
});
(function () {
    var names = { condition: "COND %", cycles: "CYCLES" };
    FIGTEXT.lines.forEach(function (l) {
        var t = names[l.key];
        LABELS.push({ text: t, x: l.xEnd, z: l.z - 3.6, size: 2.2, rot: 0, anchor: "right", data: true });
    });
})();
// The chips' names, in the family's lettering. The GPU's goes under its label, where the board has room to spare. The CPU's has no such room under its label, so
// the name takes the line beside the label, centred on it, from just right of it to short of the connector. Both are small, so they are printed in the deeper ink of data
// (`data: true`), like the figures' captions: the ordinary lettering's light ink does not read at this size at the popup's 1x. The GPU's has zeros, so it takes the
// board's figures' face (a plain zero in Material: Audiowide's slashed one reads as another digit at this size).
LABELS.push({ text: "RTX 4060", x: 25.0, z: -21.0, size: 2.8, rot: 0, data: true, face: "figures" });
LABELS.push({ text: "ULTRA 9 185H", x: -56.0, z: 54.0, size: 2.4, rot: 0, data: true });

// ---- anchors: where the holograms and beams start ------------------------------------
var ANCHORS = {
    cpuHolo: [ZONE.cx, 2.6, ZONE.cz],                                    // the package top centre
    gpuHolo: [(CARD.die[0] + CARD.die[2]) / 2, CARD.rest + CARD.pcb + 1.8, (CARD.die[1] + CARD.die[3]) / 2],
    igpuTile: [ZONE.cx + (PKG.graphics[0] + PKG.graphics[2]) / 2, 2.6, ZONE.cz + (PKG.graphics[1] + PKG.graphics[3]) / 2],
    packMinus: [PACK.x0 - 2.2, 2.0, 33],
    packPlus: [PACK.x1 + 2.2, 2.0, 33]
};

// Everything the scene draws lies inside this (the camera fits it; holograms add height).
var BOUNDS = { min: [BOARD.x0, BOARD.y0, BOARD.z0], max: [BOARD.x1, 14, BOARD.z1] };

function json() {
    return JSON.stringify({
        MAT: MAT, BOARD: BOARD, ZONE: ZONE, PKG: PKG, CORES: CORES, CARD: CARD, SLOT: SLOT, LATCH: LATCH,
        PACK: PACK, CELLS: CELLS, CELL_TOP: CELL_TOP, CELL_STOPS: CELL_STOPS, GROOVE: GROOVE, LENS: LENS, BLEND_K: BLEND_K, JACK: JACK, PLUG: PLUG, BARREL: BARREL, CABLE: CABLE, DIP: DIP,
        BRACKET: BRACKET, HDMI: HDMI, RAM: RAM, RIBBON: RIBBON, CABLE_FADE: CABLE_FADE, CONNECTOR: CONNECTOR, POLES: POLES,
        LEVER: LEVER, SEG: SEG, SEG7: SEG7, MODE_LABELS: MODE_LABELS, MODE_LABEL: MODE_LABEL, FIGTEXT: FIGTEXT, GLYPHS: GLYPHS, LOCK: LOCK, PARTS: PARTS, TRACES: TRACES, LABELS: LABELS, ANCHORS: ANCHORS, BOUNDS: BOUNDS
    });
}
