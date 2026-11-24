.pragma library

// =============================================================================
// AerialGeometry.js -- aerial's board, the ONE source of where everything is (the board toolkit's scene geometry, silicon's conventions:
// modules/silicon/scene/SceneGeometry.js; what the toolkit reads is in modules/common/board/README.md "A NEW SCENE must provide").
//
// Board space is millimetres: x and z lie on the board, y points up, the board's top face is y = 0, -z is the back (up on the screen), +z the
// front edge. Everything is an axis-aligned box or a vertical cylinder (the renderer ray-casts them analytically); a part that moves names the
// group that moves it. Readers, all computed from this file: tools/dev/board_gen/scenes/aerial.js writes the shaders' @@GEOM blocks (`gen.js
// aerial --check` fails when a shader is stale), AerialCamera.js projects it for layout and the pick. No Qt here: it runs under node.
//
// THE CARD is the Intel AX210 as measured (docs/agent_added_files_and_folders/aerial_progress/ax210_ref.json, ax210_geometry.md): card-local
// coordinates (lx, ly) = mm from the PCB's top-left corner seen from above, notch up (-z), fingers down (+z); board x = CARD.x0 + lx, board z =
// CARD.z0 + ly. It stands FLAT in its E-key socket, screwed to a standoff through the half-moon notch, and tilts up out of the slot about its finger
// end (CARD.pivot) when the screw is out (airplane).
//
// Groups (what moves a part; the shader applies the same transforms):
//   board   never moves
//   card    the card's parts (shield, label, connectors, coax): tilt about the pivot
//   pcb     the card's PCB alone: the same frame, a group of its own because the shader cuts it to its outline (the shoulders, the notch, the key slots)
//           and a pixel outside it casts again without it (a flag leaves just this group out)
//   screw   the screw: lifts out of the notch along +y first
//   dipw    the Wi-Fi DIP lever (W_DISABLE1): slides along +x between off and on
//   dipb    the Bluetooth DIP lever (W_DISABLE2)
//   btn     the BT SCAN push button's cap: goes down along -y
//   plug    the RJ45 plug with its cable: slides along +x out of the jack
//
// Parts the shader draws as more than a box: a ROW (identical cells as ONE primitive), `shape: "cylY"` (a vertical cylinder in the box), `cluster`.
// The decals (the card's fingers, key slots, notch ring, fiducial, the jack's mouth, the displays' windows) are the materials' (aerial_materials.glsl)
// and read their numbers from here (CARD, PCB, JACK, SEG ...).
// =============================================================================

var MAT = {
    BOARD: 0, SOCKET: 1, STANDOFF: 2, PCB: 3, SHIELD: 4, SHIELD_RIM: 5, LABEL: 6, MHF: 7, COAX_MAIN: 8, COAX_AUX: 9,
    SCREW: 10, DIP_BODY: 11, DIP_LEVER: 12, FLASH: 13, LEAD: 14, BTN_BASE: 15, BTN_CAP: 16, LED: 17, JACK: 18, PLUG: 19,
    CABLE: 20, RTL: 21, PAD: 22, DISPLAY: 23, LENS: 24, DECO: 25
};

// The board slice: the card mid-board, the parts of the plan's table round it, the RJ45 jack on the right edge, the displays at the front right.
// ROUND 3: one thin slab (silicon's proportions), the card toward the back corner so the air over it is the popup's middle and little of the board lies behind it.
var BOARD = { x0: -31, x1: 30, z0: -28, z1: 28, y0: -1.6, y1: 0 };

// The card. Card-local frame: x 0..22 across (MAIN's connector is the LEFT one), y 0..30 toward the fingers.
var CARD = {
    x0: -19, z0: -24, w: 22, h: 30,
    yPcb: 1.6, pcb: 0.8,                           // the PCB's underside stands 1.6 mm over the board (the socket's contact plane), top face 2.4
    pivot: { y: 2.0, z: -24 + 28 },                // the tilt's axis (parallel to x): the middle of the fingers inside the socket
    tilt: 20 * Math.PI / 180,                      // rad: how far the card rises out of the slot (the S0 note: ~20 deg, unsourced)
    standoff: { r: 1.6, h: 1.6 }
};

// The PCB's outline in card-local mm (aerial_materials.glsl pcbSd reads these): 22 x 30, square corners, narrowing to x 1..21 for the last 4 mm, the half-moon
// notch (hole R1.75 on the edge's middle, copper ring R2.75 with ~8 vias) and the TWO key slots (A + E: 1.2 wide, closed end at y 26.5).
var PCB = {
    shoulderY: 26.0, shoulderX: [1.0, 21.0],
    notch: { x: 11.0, y: 0.0, hole: 1.75, ring: 2.75, vias: 8, viaR: 0.17 },
    keys: [{ x: 13.6, y0: 26.5, w: 1.2 }, { x: 17.6, y0: 26.5, w: 1.2 }],      // E (pins 24-31), A (pins 8-15); y0 = the slot's closed end
    // the 22 gold fingers on top: x0, pitch, count (pins 1.8 3.3 4.8 | 6.3 .. 12.3 | 14.8 15.8 | 18.8 .. 20.3), width, y0..y1; the mask-free band from bandY
    fingers: { groups: [[1.8, 1.5, 3], [6.3, 0.5, 13], [14.8, 1.0, 2], [18.8, 0.5, 4]], w: 0.35, y0: 28.0, y1: 29.8, bandY: 27.95 },
    fiducial: { x: 2.7, y: 2.15, dot: 0.375, ring: 0.8 },
    silk: { triangle: [4.0, 5.6, 26.05, 26.85], dot: [20.45, 27.6, 0.25], keyE: [14.5, 15.3, 26.9, 27.8], keyA: [18.5, 19.6, 26.9, 27.8], date: [6.25, 11.8, 26.7, 27.75] }
};
// The RF shield (a copper-tan solder rim, then the tin lid) and the label on it (a flat sticker, the live label's plane).
var SHIELD = { x0: 0.5, x1: 21.5, y0: 3.85, y1: 25.5, rim: 0.4, h: 1.5, inset: 0.25 };
var LABEL = { x0: 1.0, x1: 21.0, y0: 4.05, y1: 24.9, h: 0.06, radius: 0.4 };
// the two MHF4 connectors: MAIN "2" is the LEFT one, AUX "1" the right (centres, card-local; body 2.0 x 2.0 x 0.6, the pin D0.45)
var MHF = { main: [15.35, 1.9], aux: [19.85, 1.9], body: 2.0, h: 0.6 };
// where the live label's zone sits on the label (card-local mm, lower half: over the large Data Matrix and the strip beside it) and Intel's print above it
// ROUND 3: the label is three bands (card-local mm; the text reads along +x): a thin head with Intel's name, the BLUETOOTH zone (the connected devices; Intel's small print
// while there is none) and the WI-FI zone (the docked network). A device is dropped on LABEL_BT, a network / the hotspot / a country on LABEL_ZONE.
var LABEL_HEAD = { x0: 1.2, x1: 20.8, y0: 4.25, y1: 6.7 };
var LABEL_BT = { x0: 1.2, x1: 20.8, y0: 6.9, y1: 13.5 };
var LABEL_ZONE = { x0: 1.2, x1: 20.8, y0: 13.9, y1: 24.6 };

// The socket and standoff (TE 21.9 x 8.7 x 3.2): the card's fingers inside, its front face at card y 25.5.
// ROUND 3: short and low (the user: "a bit too chunky ... the gold contacts usually are not too long"), and 0.6 mm wider than the card each side so the card never clips into its cheeks.
var SOCKET = { x0: CARD.x0 - 0.6, x1: CARD.x0 + 22.6, z0: CARD.z0 + 26.6, z1: CARD.z0 + 31.3, h: 2.9 };

// Hardware beside the slot (round 2: the slice is re-laid tight round the card so the camera can come in; every mm here is on screen about 8.2 px at the popup's 760)
var SCREW = { head: 1.9, headH: 0.85, shaft: 0.85, shaftLen: 3.4, lift: 11, turns: 1 };       // mm: a pan head with a cross slot on the notch's copper ring, a threaded shaft with a flat end under it; it lifts out 11 mm
// turning once as it does (anticlockwise from above: it unscrews; a whole number of quarter turns, so the cross slot at rest is the same picture at both
// ends; at 1.5 the fastest frame at 60 Hz turned 52 degrees, past the 45 at which a cross slot reads as turning back)
// the two radio latches (Wi-Fi the back row, Bluetooth the front one): each latch's face carries its emblem, engraved (the silk atlas), in the radio's hue
// (round 4: a lower profile, the housing 1.6 mm and the latches 0.9 over it; they were 2.6 and 1.5)
// (round 5: 0.7 mm in from the board's edge and 0.6 back -- its courtyard ran off the board on the left and stood 0.4 mm from the RATE display's)
var DIP = { x0: -29.6, x1: -21.2, z0: 1.9, z1: 12.9, h: 1.6, rows: [4.6, 10.2], lever: { w: 3.6, d: 3.4, h: 0.9 }, xOff: -28.9, travel: 3.4 };
var MEM = { x0: 4.95, x1: 9.85, z0: -2.6, z1: 1.3, h: 1.3 };                         // a SOIC-8 "flash" (its coloured band says it is a part you can pick)
// THE RIGHT EDGE is a column, back to front: the globe's lens, the LAN jack, the SCAN button, the BEACON LED -- each with its name centred in front of it
var BTN = { x0: 22.5, x1: 28, z0: 6, z1: 11.5, h: 2.2, cap: { cx: 25.25, cz: 8.75, r: 1.7, h: 1.3 }, travel: 0.6 };
var BEACON = { x: 25.25, z: 18.4, r: 1.4, h: 1.3, ring: 3.2 };                          // on the board right beside the card's AUX side (the card itself has no LED)
// The RJ45 jack on the right edge (x1), its mouth facing +x: MUCH smaller than a real one (the user: it must not be the main piece), with a green and an amber LED over the mouth.
var JACK = { x0: 23.6, x1: 30, z0: -7.8, z1: 0.2, h: 4.6, mouth: { zc: -3.8, w: 6.0, y0: 0.6, y1: 3.5 }, led: { y0: 3.75, y1: 4.3, w: 1.1, out: 0.25, green: -2.4, amber: 2.4 } };
var PLUG = { x0: 28.6, x1: 34.6, y0: 0.8, y1: 3.3, z0: -3.8 - 2.8, z1: -3.8 + 2.8, travel: 11, boot: 4, cable: { x1: 62, y0: 1.3, y1: 2.9, hz: 0.95, fade0: 0.0 } };
var CABLE_FADE = { len: 7.0 };      // the cable fades to nothing over this many mm from the boot
// the five test pads on one trace from the slot toward the front edge, each with an LED beside it (0603)
// ROUND 3: the LED stands ON its gold pad (the user), so the names start right beside the pad
var PADS = { x: 7.4, zs: [11.4, 14.9, 18.4, 21.9, 25.4], names: ["link", "addr", "gateway", "dns", "net"], w: 3.2, d: 2.2, led: { w: 1.5, d: 1.0, h: 0.7 } };
// the globe lens (a small round projector): the globe hologram stands over it
var LENS = { x: 22, z: -20.5, base: 4.4, ring: 3.1, cap: 1.9, dome: 30, globe: 10 };
// Two 4-digit 7-segment displays, front: rates (down; up in a speed test) and usage (today's total). seg7.glsl's grammar and silicon's geometry, drawn at 0.88 of silicon's size.
var SEG = { h: 1.3, cell: [2.3, 4.6], stroke: 0.62, gap: 0.27, pitch: 3.35, colonGap: 1.5, pad: 0.8, bezel: 0.6 };
function segDisplay(d) {
    var inner = 2 * SEG.pad + (d.cells - 1) * SEG.pitch + SEG.cell[0] + (d.colon ? SEG.colonGap : 0);
    var w = inner + 2 * SEG.bezel, dp = SEG.cell[1] + 2 * SEG.pad + 2 * SEG.bezel;
    d.body = [d.x, d.z, d.x + w, d.z + dp];
    d.window = [d.x + SEG.bezel, d.z + SEG.bezel, d.x + w - SEG.bezel, d.z + dp - SEG.bezel];
    d.cell0 = [d.window[0] + SEG.pad, d.window[1] + SEG.pad];
    return d;
}
var SEG7 = [
    // (round 5: 1 mm back, so the RATE display's courtyard clears the front corner's hole ring)
    { name: "segRates", key: "rates", cells: 4, colon: false, x: -28.6, z: 15.6 },
    { name: "segUsage", key: "usage", cells: 4, colon: false, x: -11.4, z: 15.6 }
].map(segDisplay);

// The board's own cut-outs (a real board's features; aerial_materials.glsl boardCutSd reads these): the two grommets the coax go down through and four mounting holes with thin
// rings at the corners (each 2.2 mm in from both edges). mm, board space. (Round 6: no other hole -- the user does not want one left of the card.)
var CUTS = {
    // the two antenna cables go down through the board right behind their connectors: a rubber grommet each (centre x, z; the hole's radius, the grommet's)
    grommets: [[CARD.x0 + MHF.main[0], CARD.z0 - 2.3], [CARD.x0 + MHF.aux[0], CARD.z0 - 2.3]], grommetR: 0.78, grommetRing: 1.25,
    // small plated holes at the corners (silicon's marks: a hole and a thin ring, never a gold doughnut)
    holes: [[-28.8, -25.8], [27.8, -25.8], [27.8, 25.8], [-28.8, 25.8]], holeR: 0.75, ringR: 1.45
};

// ---- the boxes ------------------------------------------------------------------------------
function B(name, mat, group, mn, mx, opts) {
    var o = { name: name, mat: mat, group: group, min: mn, max: mx, cast: true };
    for (var k in (opts || {}))
        o[k] = opts[k];
    return o;
}
function ROW(name, mat, group, at, cell, pitch, n, opts) {
    var mx = [at[0] + (n[0] - 1) * pitch[0] + cell[0], at[1] + cell[1], at[2] + (n[1] - 1) * pitch[1] + cell[2]];
    var o = B(name, mat, group, at.slice(), mx, opts);
    o.row = { cell: cell, pitch: pitch, n: n, k: (opts && opts.k) || 2 };
    return o;
}
// a card part: card-local box -> board space
function CB(name, mat, group, lx0, ly0, lz0, lx1, ly1, lz1, opts) {
    return B(name, mat, group, [CARD.x0 + lx0, ly0, CARD.z0 + lz0], [CARD.x0 + lx1, ly1, CARD.z0 + lz1], opts);
}
function cyl(name, mat, group, cx, cz, r, y0, y1, opts) {
    return B(name, mat, group, [cx - r, y0, cz - r], [cx + r, y1, cz + r], Object.assign({ shape: "cylY" }, opts || {}));
}

// the two coax cables (MAIN black, AUX grey): NOT boxes (a staircase of boxes read as blocks) but a projected tube the scene draws (CoaxLayer.qml): a cubic Bezier in board space from each
// connector's back side (it rises and tilts with the card) over the board to the back edge's notch, r mm a section. `endLz` is where the card patch's footprint reaches (the camera).
// ROUND 3: each cable is ONE short arch from its connector's back into its grommet (the old run to an edge notch read as squiggles and left a grey stub in the air)
var COAX = { r: 0.42, endLz: -4.5 };

// the decoration: chips (x, z of the corner, w d h) and rows of passives (cell, pitch, n)
// ROUND 3: silicon's manner -- a few low chips and rows of passives on the board's own axes, grouped with the part they would serve, all in the board's grey.
// ROUND 5: every one stands clear of the traces, the hole rings, the courtyards and the cut-out (tools/dev/aerial_clearance_cases.js holds the whole board to it).
var DECO = [
    { name: "decoQfn1", x: -26.9, z: -21.8, w: 3.8, d: 3.8, h: 0.8 },                                         // behind the card, left: the radio's regulator
    { name: "decoCapsE", x: -26.6, z: -16.0, cell: [1.0, 0.45, 0.5], row: { pitch: [1.6, 1.0], n: [3, 1] } },    // its output caps, where round 5's slot was
    { name: "decoCapsA", x: -28.8, z: -13.6, cell: [1.0, 0.45, 0.5], row: { pitch: [1.6, 1.25], n: [1, 6] } },   // a column of bypass caps down the left strip
    { name: "decoCapsD", x: -23.4, z: -12.4, cell: [1.0, 0.45, 0.5], row: { pitch: [1.6, 1.25], n: [1, 4] } },
    { name: "decoInd", x: -27.6, z: -3.6, w: 3.4, d: 3.4, h: 1.2 },
    { name: "decoCapsB", x: -13.2, z: 10.0, cell: [1.0, 0.45, 0.5], row: { pitch: [1.6, 1.0], n: [5, 1] } },   // the slot's decoupling, in front of the socket, midway between the two displays' traces
    { name: "decoResA", x: -1.6, z: 10.0, cell: [0.5, 0.4, 1.0], row: { pitch: [1.25, 1.0], n: [4, 1] } },
    { name: "decoSoic1", x: 11.4, z: -12.6, w: 4.6, d: 3.6, h: 0.8 },                                         // the LAN side
    { name: "decoCapsC", x: 11.8, z: -6.6, cell: [1.0, 0.45, 0.5], row: { pitch: [1.6, 1.0], n: [3, 1] } },
    { name: "decoXtal", x: 12.2, z: 2.2, w: 3.2, d: 1.6, h: 0.8 },
    { name: "decoSoic2", x: 6.0, z: -27.0, w: 4.6, d: 2.8, h: 0.8 },
    { name: "decoResB", x: 20.4, z: -10.6, cell: [1.0, 0.4, 0.5], row: { pitch: [1.6, 1.25], n: [1, 3] } }
];

var PARTS = (function () {
    var out = [];
    var cx0 = CARD.x0, cz0 = CARD.z0, yTop = CARD.yPcb + CARD.pcb;
    out.push(B("board", MAT.BOARD, "board", [BOARD.x0, BOARD.y0, BOARD.z0], [BOARD.x1, BOARD.y1, BOARD.z1], { cast: false }));
    // the slot: the standoff the screw bites into (under the notch), the socket the fingers go into
    out.push(cyl("standoff", MAT.STANDOFF, "board", cx0 + PCB.notch.x, cz0 + PCB.notch.y, CARD.standoff.r, 0, CARD.standoff.h));
    out.push(B("socket", MAT.SOCKET, "board", [SOCKET.x0, 0, SOCKET.z0], [SOCKET.x1, SOCKET.h, SOCKET.z1], { cluster: "slot" }));
    // the card: the PCB (cut to its outline by the shader), then what stands on it
    out.push(CB("pcb", MAT.PCB, "pcb", 0, CARD.yPcb, 0, CARD.w, yTop, CARD.h, { bake: true }));
    out.push(CB("shieldRim", MAT.SHIELD_RIM, "card", SHIELD.x0, yTop, SHIELD.y0, SHIELD.x1, yTop + SHIELD.rim, SHIELD.y1, { bake: true }));
    out.push(CB("shield", MAT.SHIELD, "card", SHIELD.x0 + SHIELD.inset, yTop + SHIELD.rim, SHIELD.y0 + SHIELD.inset, SHIELD.x1 - SHIELD.inset, yTop + SHIELD.h, SHIELD.y1 - SHIELD.inset, { bake: true }));
    out.push(CB("label", MAT.LABEL, "card", LABEL.x0, yTop + SHIELD.h, LABEL.y0, LABEL.x1, yTop + SHIELD.h + LABEL.h, LABEL.y1, { cast: false, bake: true }));
    [["Main", MHF.main], ["Aux", MHF.aux]].forEach(function (c) {
        var cx = c[1][0], cy = c[1][1], h = MHF.body / 2;
        out.push(CB("mhf" + c[0], MAT.MHF, "card", cx - h, yTop, cy - h, cx + h, yTop + MHF.h, cy + h, { bake: true }));
    });
    // the screw: head on the notch's copper ring, the shaft down into the standoff
    out.push(cyl("screw", MAT.SCREW, "screw", cx0 + PCB.notch.x, cz0 + PCB.notch.y, SCREW.head, yTop, yTop + SCREW.headH));
    out.push(cyl("screwShaft", MAT.SCREW, "screw", cx0 + PCB.notch.x, cz0 + PCB.notch.y, SCREW.shaft, yTop - SCREW.shaftLen, yTop, { cast: false }));
    // the DIP switch (W_DISABLE1 Wi-Fi, W_DISABLE2 Bluetooth): two levers sliding along x over a body
    out.push(B("dipBody", MAT.DIP_BODY, "board", [DIP.x0, 0, DIP.z0], [DIP.x1, DIP.h, DIP.z1]));
    DIP.rows.forEach(function (zc, i) {
        var L = DIP.lever;
        out.push(B(i === 0 ? "dipWifi" : "dipBt", MAT.DIP_LEVER, i === 0 ? "dipw" : "dipb", [DIP.xOff, DIP.h, zc - L.d / 2], [DIP.xOff + L.w, DIP.h + L.h, zc + L.d / 2]));
    });
    // the memory chip: a SOIC-8, four leads along each long side
    out.push(B("mem", MAT.FLASH, "board", [MEM.x0, 0, MEM.z0], [MEM.x1, MEM.h, MEM.z1]));
    var lx = MEM.x0 + (MEM.x1 - MEM.x0 - (3 * 1.27 + 0.4)) / 2;
    out.push(ROW("memLeadsBack", MAT.LEAD, "board", [lx, 0, MEM.z0 - 0.8], [0.4, 0.3, 0.9], [1.27, 1], [4, 1], { cast: false }));
    out.push(ROW("memLeadsFront", MAT.LEAD, "board", [lx, 0, MEM.z1 - 0.1], [0.4, 0.3, 0.9], [1.27, 1], [4, 1], { cast: false }));
    // the BT SCAN push button: a base and a round cap that goes down
    out.push(B("btnBase", MAT.BTN_BASE, "board", [BTN.x0, 0, BTN.z0], [BTN.x1, BTN.h, BTN.z1]));
    out.push(cyl("btn", MAT.BTN_CAP, "btn", BTN.cap.cx, BTN.cap.cz, BTN.cap.r, BTN.h, BTN.h + BTN.cap.h));
    // the beacon LED: on the board beside the card's AUX side
    out.push(cyl("beacon", MAT.LED, "board", BEACON.x, BEACON.z, BEACON.r, 0, BEACON.h, { cast: false }));
    // the RJ45 jack and the controller beside it
    out.push(B("jack", MAT.JACK, "board", [JACK.x0, 0, JACK.z0], [JACK.x1, JACK.h, JACK.z1]));
    var Jl = JACK.led;
    out.push(B("jackGreen", MAT.LED, "board", [JACK.x1, Jl.y0, JACK.mouth.zc + Jl.green - Jl.w / 2], [JACK.x1 + Jl.out, Jl.y1, JACK.mouth.zc + Jl.green + Jl.w / 2], { cast: false }));
    out.push(B("jackAmber", MAT.LED, "board", [JACK.x1, Jl.y0, JACK.mouth.zc + Jl.amber - Jl.w / 2], [JACK.x1 + Jl.out, Jl.y1, JACK.mouth.zc + Jl.amber + Jl.w / 2], { cast: false }));
    // the plug + boot + cable (a group that slides out +x)
    out.push(B("plug", MAT.PLUG, "plug", [PLUG.x0, PLUG.y0, PLUG.z0], [PLUG.x1, PLUG.y1, PLUG.z1]));
    out.push(B("plugLatch", MAT.PLUG, "plug", [PLUG.x0 + 2, PLUG.y1, JACK.mouth.zc - 1.6], [PLUG.x0 + 6, PLUG.y1 + 1.0, JACK.mouth.zc + 1.6]));
    out.push(B("plugBoot", MAT.PLUG, "plug", [PLUG.x1, PLUG.y0 + 0.4, JACK.mouth.zc - 3.4], [PLUG.x1 + PLUG.boot, PLUG.y1 - 0.4, JACK.mouth.zc + 3.4]));
    out.push(B("cable", MAT.CABLE, "plug", [PLUG.x1 + PLUG.boot, PLUG.cable.y0, JACK.mouth.zc - PLUG.cable.hz], [PLUG.cable.x1, PLUG.cable.y1, JACK.mouth.zc + PLUG.cable.hz]));
    // the five test pads and their LEDs
    PADS.zs.forEach(function (z, i) {
        var n = PADS.names[i], cap = n.charAt(0).toUpperCase() + n.slice(1);
        out.push(B("pad" + cap, MAT.PAD, "board", [PADS.x - PADS.w / 2, 0, z - PADS.d / 2], [PADS.x + PADS.w / 2, 0.12, z + PADS.d / 2], { cast: false }));
        out.push(B("led" + cap, MAT.LED, "board", [PADS.x - PADS.led.w / 2, 0.12, z - PADS.led.d / 2], [PADS.x + PADS.led.w / 2, 0.12 + PADS.led.h, z + PADS.led.d / 2], { cast: false }));
    });
    // the two displays
    SEG7.forEach(function (d) {
        out.push(B(d.name, MAT.DISPLAY, "board", [d.body[0], 0, d.body[1]], [d.body[2], SEG.h, d.body[3]]));
    });
    // the globe lens
    out.push(cyl("lensBase", MAT.LENS, "board", LENS.x, LENS.z, LENS.base, 0, 0.9));
    out.push(cyl("lensRing", MAT.LENS, "board", LENS.x, LENS.z, LENS.ring, 0.9, 1.7, { cast: false }));
    out.push(cyl("lensCap", MAT.LENS, "board", LENS.x, LENS.z, LENS.cap, 1.7, 2.3, { cast: false }));
    // the DECORATIVE parts (silicon's passives and small chips: grey, flat, unlabelled; they pick nothing and stay clear of the card's clear zone and of every trace)
    DECO.forEach(function (d) {
        if (d.row)
            out.push(ROW(d.name, MAT.DECO, "board", [d.x, 0, d.z], d.cell, d.row.pitch, d.row.n, { cast: false }));
        else
            out.push(B(d.name, MAT.DECO, "board", [d.x, 0, d.z], [d.x + d.w, d.h, d.z + d.d], { cast: false }));
    });
    return out;
})();

// ---- the copper -----------------------------------------------------------------------------
// Real-looking routes: a bus leaves the slot's edges and runs to what it serves with 45-degree corners (a rounded joint is the shader's blend). `pulse` says which way the dimmed
// pulse train runs (1 outward from the slot, 0 none), `s` the route's own coordinate at each vertex (mm from the slot: what the train is a function of).
function len(pts) {
    var l = 0;
    for (var i = 0; i + 1 < pts.length; i++)
        l += Math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]);
    return l;
}
function T(name, kind, width, pts, o) {
    var s = [0];
    for (var i = 0; i + 1 < pts.length; i++)
        s.push(s[i] + Math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]));
    var t = { name: name, kind: kind, width: width, from: "slot", fromPack: 0, length: len(pts), pts: pts, s: s, pulse: 1 };
    for (var k in (o || {}))
        t[k] = o[k];
    return t;
}
var TRACES = (function () {
    var out = [];
    var z1 = SOCKET.z1, S = SEG7, bz = 5.5, bx = 18.5;
    // the bus out of the slot's right end: east along the slot, then back up the corridor to the LAN jack and the globe's lens
    out.push(T("busRight", "signal", 0.8, [[SOCKET.x1 - 0.05, bz], [bx, bz], [bx, LENS.z + 2.0], [bx + 0.9, LENS.z + 1.1]], { blend: "bus", blendK: 0.6 }));
    out.push(T("jackLine", "signal", 0.8, [[bx, JACK.mouth.zc], [JACK.x0, JACK.mouth.zc]], { blend: "bus", blendK: 0.6 }));
    // a clean cross on the bus: the memory behind it, the five test pads in front
    out.push(T("memLine", "signal", 0.8, [[PADS.x, bz], [PADS.x, MEM.z1 + 0.8]], { blend: "bus", blendK: 0.6, pulse: 0 }));
    out.push(T("padLine", "signal", 0.8, [[PADS.x, bz], [PADS.x, PADS.zs[4] + PADS.d / 2]], { blend: "bus", blendK: 0.6 }));
    // on to the Bluetooth pair down the right column: the button from its left, the beacon further down the same lane
    out.push(T("btnLine", "signal", 0.8, [[bx, bz], [20.6, 7.6], [20.6, BTN.cap.cz], [BTN.x0, BTN.cap.cz]], { blend: "bus", blendK: 0.6 }));
    out.push(T("beaconLine", "signal", 0.8, [[20.6, BTN.cap.cz], [20.6, BEACON.z], [BEACON.x - BEACON.r, BEACON.z]], { blend: "bus", blendK: 0.6, pulse: 0 }));
    // the two displays, straight down from the slot's front edge
    out.push(T("ratesLine", "signal", 0.8, [[-15, z1], [-15, S[0].body[1]]]));
    out.push(T("usageLine", "signal", 0.8, [[-4, z1], [-4, S[1].body[1]]]));
    // the radio latches, off the slot's left end
    out.push(T("dipLine", "signal", 0.8, [[SOCKET.x0 + 0.05, DIP.rows[0]], [DIP.x1, DIP.rows[0]]], { blend: "dip", blendK: 0.6 }));
    out.push(T("dipStub", "signal", 0.8, [[-20.8, DIP.rows[0]], [-20.8, DIP.rows[1]], [DIP.x1, DIP.rows[1]]], { blend: "dip", blendK: 0.6, pulse: 0 }));
    // ONE COORDINATE PER ROUTE (round 6: the trains were "discontinuous and unsynced at some joints"): every trace's `s` restarted at 0 at its own first vertex, so a branch's
    // train jumped where it left the bus. A trace that starts ON an earlier one takes that one's coordinate at the junction, so a pulse runs on through the joint.
    out.forEach(function (t, i) { linkRoute(t, out.slice(0, i)); });
    return out;
})();
// the parent's coordinate where a trace's first vertex lies on it (within 0.05 mm), added to the trace's own; `fromPack` (the power-on sweep) the same
function linkRoute(t, earlier) {
    var p = t.pts[0];
    for (var k = earlier.length - 1; k >= 0; k--) {
        var q = earlier[k];
        for (var i = 0; i + 1 < q.pts.length; i++) {
            var a = q.pts[i], b = q.pts[i + 1], dx = b[0] - a[0], dz = b[1] - a[1], l2 = dx * dx + dz * dz;
            var u = l2 > 0 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / l2)) : 0;
            if (Math.hypot(a[0] + dx * u - p[0], a[1] + dz * u - p[1]) < 0.05) {
                var s0 = q.s[i] + u * Math.sqrt(l2);
                t.s = t.s.map(function (v) { return v + s0; });
                t.fromPack = (q.fromPack || 0) + s0;
                t.parent = q.name;
                return;
            }
        }
    }
}

// ---- the printed names (silk): drawn by the popup as text in the board plane, tinted by the theme. Every INTERACTIVE part has one and a courtyard outline (COURTYARDS); a
// decorative one has neither. size mm, anchor: "left" | "right" | "centre"; `unit` names the engraved unit that follows the figures (AerialFacts.describe `units`).
// ROUND 3: the names are carved into the board by its own shader (an SDF silkscreen, tools/aerial/make_silk.py bakes it from THIS list), so a part in front hides them and a
// shadow falls on them like on everything else. Each stands where NO part can cover it: in front of (+z) or to the right of (+x) what it names, on open board.
// `unit`: the label is one of several engraved variants (SILK_VARIANTS), picked by a uniform; its text here is the widest, for the room it needs.
var LABELS = [
    { text: "MEM", x: MEM.x1 + 1.6, z: (MEM.z0 + MEM.z1) / 2, size: 1.3, anchor: "left" },
    { text: "VPN", x: LENS.x, z: LENS.z + LENS.base + 2.5, size: 1.3, anchor: "centre" },
    { text: "LAN", x: (JACK.x0 + JACK.x1) / 2 - 0.4, z: JACK.z1 + 2.5, size: 1.3, anchor: "centre" },
    { text: "SCAN", x: BTN.cap.cx, z: BTN.z1 + 2.4, size: 1.3, anchor: "centre" },
    { text: "BEACON", x: BEACON.x - 0.4, z: BEACON.z + 4.5, size: 1.2, anchor: "centre" },
    { text: "LINK", x: PADS.x + 2.9, z: PADS.zs[0], size: 1.25, anchor: "left" },
    { text: "ADDR", x: PADS.x + 2.9, z: PADS.zs[1], size: 1.25, anchor: "left" },
    { text: "GATEWAY", x: PADS.x + 2.9, z: PADS.zs[2], size: 1.25, anchor: "left" },
    { text: "DNS", x: PADS.x + 2.9, z: PADS.zs[3], size: 1.25, anchor: "left" },
    { text: "NET", x: PADS.x + 2.9, z: PADS.zs[4], size: 1.25, anchor: "left" },
    { text: "KEY E", x: -9.5, z: 13.4, size: 1.25, anchor: "centre" },
    { text: "PUBLIC NET?", unit: "rates", x: SEG7[0].body[0] + 2.4, z: SEG7[0].body[3] + 2.0, size: 1.3, anchor: "left" },
    { text: "DATA - MiB", unit: "usage", x: SEG7[1].body[0] + 2.4, z: SEG7[1].body[3] + 2.0, size: 1.3, anchor: "left" }
];
// the engraved variants of the two `unit` labels (the board shader's `silkVar` uniform picks one index each): the atlas holds every one
var SILK_VARIANTS = {
    rates: ["RATE - kb/s", "RATE - Mb/s", "RATE - Gb/s", "RUN? - MB", "SURE? - MB", "PUBLIC NET?", "METERED?"],
    usage: ["DATA - MiB", "DATA - GiB", "DATA - TiB", "PING - ms"]
};
// the emblems engraved on the two latches' faces (Symbols Nerd Font codepoints; lever-local mm about the face's centre) and their size
var EMBLEMS = { wifi: { glyph: "\uDB81\uDDA9", size: 2.7 }, bt: { glyph: "\uDB80\uDCAF", size: 2.7 } };
// the courtyards (a thin carved outline round each interactive part): { r: [x0, z0, x1, z1, corner radius] } or { c: [x, z, radius] }, mm
function _pad(b, m) {
    return [b[0] - m, b[1] - m, b[2] + m, b[3] + m];
}
var COURTYARDS = (function () {
    var out = [];
    out.push({ r: _pad([DIP.x0, DIP.z0, DIP.x1, DIP.z1], 0.9).concat([0.9]) });
    out.push({ r: _pad([MEM.x0, MEM.z0 - 0.8, MEM.x1, MEM.z1 + 0.8], 0.8).concat([0.7]) });
    out.push({ r: _pad([BTN.x0, BTN.z0, BTN.x1, BTN.z1], 0.9).concat([0.9]) });
    out.push({ c: [BEACON.x, BEACON.z, 2.5] });
    out.push({ r: _pad([JACK.x0, JACK.z0, JACK.x1 - 0.9, JACK.z1], 0.9).concat([0.9]) });
    out.push({ c: [LENS.x, LENS.z, LENS.base + 1.0] });
    SEG7.forEach(function (d) {
        out.push({ r: _pad(d.body, 0.8).concat([0.8]) });
    });
    PADS.zs.forEach(function (z) {
        out.push({ r: [PADS.x - PADS.w / 2 - 0.6, z - PADS.d / 2 - 0.6, PADS.x + PADS.w / 2 + 0.6, z + PADS.d / 2 + 0.6, 0.6] });
    });
    return out;
})();

// ---- anchors: where the holograms start (stage 3 draws them) and what the camera fits ---------
var ANCHORS = {
    // THE CLOUD'S ORIGIN (round 3, the user): the centre of the card's white label -- the pulse, the fan's arcs and every tag's place are measured from it
    cloud: [CARD.x0 + (LABEL.x0 + LABEL.x1) / 2, CARD.yPcb + CARD.pcb + SHIELD.h + LABEL.h, CARD.z0 + (LABEL.y0 + LABEL.y1) / 2],
    globe: [LENS.x, 2.3, LENS.z],
    card: [CARD.x0 + CARD.w / 2, CARD.yPcb + CARD.pcb, CARD.z0 + CARD.h / 2]
};
ANCHORS.dome = ANCHORS.cloud;       // (the old name: readers not yet moved)
// THE AIR, in DESIGN px at the scene's 760 (the camera scales them with the width): the signal fan stands on the label's centre. `rBt` the near field's arc (Bluetooth), `r` the
// Wi-Fi arcs (strong .. weak) and the fringe's (dots), `span` the fan's half angle from the vertical in degrees, `top` what the popup keeps clear above the origin (the fringe + a
// tag's half height + the margin). `globeR` the globe's radius at rest, mm; `globeUp` its centre over the lens.
var CLOUD = { rBt: 112, r: [172, 228], rFringe: 284, span: 62, top: 318 };
var RINGS = { inner: 6, outer: 22, clear: 9 };
var ROOM = { domeR: 30, globeR: 6.4, top: 16, globeUp: 9.6 };

// the pick: part -> an intent name (AerialLayout.js maps; `pad.<id>` carries the pad id)
var INTENTS = {
    shield: "label", shieldRim: "label", label: "label", screw: "screw", dipWifi: "dip.wifi", dipBt: "dip.bt", mem: "mem", memLeadsBack: "mem", memLeadsFront: "mem",
    btn: "bt.scan", btnBase: "bt.scan", beacon: "beacon", jack: "jack", jackGreen: "jack", jackAmber: "jack", plug: "jack", plugLatch: "jack", plugBoot: "jack", cable: "jack",
    screwShaft: "screw", segRates: "rates", segUsage: "usage", lensBase: "globe", lensRing: "globe", lensCap: "globe"
};
// NOT in the table, on purpose: the card's body (pcb, connectors, socket, standoff: the card is the stage, not a button), the DIPs' enclosure (only the latch picks) and every decoration

// board rectangles [x0, z0, x1, z1] (mm, at y = 0), one per printed name (derived from LABELS, so a new label is in it), for a hologram that must not stand over them (the own-hotspot tag landed on BEACON / GLOBE): the dome
// can add these (as it adds the cables' quad) to its avoid list.
var SILK_AVOID = LABELS.map(function (l) {
    var n = l.unit ? 11 : l.text.length, w = 0.66 * l.size * n + 0.6, h = l.size * 0.75 + 0.6;       // "RATE - Mb/s" is the longest a unit label reads
    var x0 = l.anchor === "left" ? l.x - 0.3 : l.anchor === "centre" ? l.x - w / 2 : l.x - w + 0.3;
    return [x0, l.z - h / 2 - 0.2, x0 + w, l.z + h / 2 + 0.2];
});

var BOUNDS = { min: [BOARD.x0, BOARD.y0, BOARD.z0], max: [BOARD.x1 + 18, 30, BOARD.z1] };

function json() {
    return JSON.stringify({
        MAT: MAT, BOARD: BOARD, CARD: CARD, PCB: PCB, SHIELD: SHIELD, LABEL: LABEL, MHF: MHF, LABEL_ZONE: LABEL_ZONE, LABEL_BT: LABEL_BT, LABEL_HEAD: LABEL_HEAD, SOCKET: SOCKET, SCREW: SCREW, DIP: DIP, MEM: MEM, BTN: BTN,
        BEACON: BEACON, CUTS: CUTS, COURTYARDS: COURTYARDS, SILK_AVOID: SILK_AVOID, JACK: JACK, PLUG: PLUG, CABLE_FADE: CABLE_FADE, PADS: PADS, LENS: LENS, SEG: SEG, SEG7: SEG7, COAX: COAX, PARTS: PARTS, TRACES: TRACES,
        LABELS: LABELS, SILK_VARIANTS: SILK_VARIANTS, EMBLEMS: EMBLEMS, CLOUD: CLOUD, ANCHORS: ANCHORS, RINGS: RINGS, ROOM: ROOM, INTENTS: INTENTS, BOUNDS: BOUNDS
    });
}
