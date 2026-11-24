.pragma library

// =============================================================================
// BodyGeometry.js -- the ONE description of a phone's body, in millimetres, and the camera that draws it.
// The body's shader (BodyLayer -> bridge_body.frag), the stage's placement of the two faces and of its hit zones
// (PhoneStage) and the textures' generator (tools/bridge/make_decor.py, which reads SKINS through node: what lies under
// the back glass, and what each wall of the frame carries) all take their numbers here and nowhere else.
//
// AXES. A skin is written as the phone is seen FROM THE FRONT, upright: the origin at its centre, x to the right, y
// DOWN, z out of the screen towards the viewer (so the front glass is at z = +t/2 and the back at -t/2). The back's
// own tables (`sheet`, and everything in `back`) are written as the back is seen FROM THE BACK, upright: x to the
// right as you look at it. The two differ by the sign of x.
//
// THE CAMERA is a pinhole on the axis through the body's centre, `camDist` stage px in front of the plane z = 0, and
// the body's centre sits half a thickness BEHIND that plane. So whichever face is turned to the viewer lies in the
// plane itself and is drawn at exactly 1:1 -- which is what lets the stage draw a face's QML content directly, with
// no transform at all, while the phone rests, and under the SAME projection (faceMatrix) while it turns.
//
//   skin(name)                 a skin's table; an unknown name is `generic`
//   layout(skin, W, H, rs, o)  everything in STAGE px for a stage of W x H at `rs` device px per stage px: the body's
//                              box, the display, the back's sheet (all with their edges on whole device pixels), the
//                              centre, the half extents, the px-per-mm of each axis, the camera
//   basis(turn, nod)           the body's axes in the stage's space for `turn` revolutions about its vertical axis
//                              (0 the front, 0.5 the back) and a nod of `nod` degrees about the horizontal one
//   faceMatrix(lay, b, rect, back)   the 4x4 (row-major, for Qt.matrix4x4) that takes a face's own item
//                              coordinates -- an item placed at `rect` -- to where the turned body carries them
//   facing(b)                  +1 the front is turned to the viewer, -1 the back
//   keys(skin, lay)            what stands proud of the frame as the shader's rows [y0, y1, side, kind] in px from the centre
//   zones(skin, lay, face)     the hit zones in stage px: { power, volup, voldown, cable }
// =============================================================================

// A key's `side`: +1 the right frame (seen from the front), -1 the left.
// `kind`: what stands PROUD of the frame there (the shader's bump; what a wall looks like is the frame's own texture,
// tools/bridge/make_decor.py): 1 a bar with square ends, 4 the painted slider (a pill, less proud), 5 a pill, 6 a round
// key (y0..y1 its diameter). `hz` is a key's half extent across the frame's thickness, mm (default a third of it).
// `press` names the parts whose press moves the key (default its own id).
var KEY_PROUD = 1;
var KEY_SLIDER = 4;
var KEY_PILL = 5;
var KEY_ROUND = 6;

var SKINS = {
    // The user's phone: REDMAGIC 10S Pro, silver "Moonlight" with the transparent back. 163.42 x 76.14 x 8.9 mm: a flat
    // satin aluminium frame with a small rounded edge and SHARP corners, flat glass both sides, no camera bump, the
    // selfie camera under the display (no cut-out). Every number is measured off the user's own photos of the phone
    // (feedback/phone_photos/: the top-down back rectified to millimetres, the four sides, the front); nothing of a
    // photo is copied -- tools/bridge/make_decor.py draws it all from these.
    "redmagic-10s-pro-moonlight": {
        w: 76.14, h: 163.42, t: 8.9,
        corner: 3.1,            // the outline's corner radius
        edge: 0.85,             // the frame's rounded edge towards each glass
        // the display's corner is the outline's, less how far in it lies (corners nested in corners: 3.1 - 2.2)
        display: { w: 71.7, h: 158.5, r: 0.9 },
        lip: 1.0,               // the frame's rim round each glass
        slit: { w: 13.0, h: 0.34 },     // the earpiece: a slit between the front glass and the frame's top
        // back view: where a back face's items would lie (the lined plate, inside its drawn frame, right of the wordmark
        // and clear of the mark at its foot). The popup puts nothing there: the back is the phone's own back.
        sheet: { x0: -19.8, y0: -22.6, x1: 28.6, y1: 71.6, r: 1.0 },
        keyProud: 0.42,
        // back view: what lies under the back glass (mm from the centre, x to the right AS THE BACK IS SEEN). Read off the
        // top-down photo rectified by the mirror border, which is the same width all round (the phone's outline in that
        // photo is its frame seen a little from below the middle, and stands 0.9 mm too far out at the head).
        back: {
            kind: "redmagic10s",
            // the mirror border under the glass's edge: its inner outline, its tab beside the slider; and the dark pill
            // over the two screws at the foot
            chrome: { x0: -34.27, y0: -77.91, x1: 34.27, y1: 77.91, r: 0.9 },
            tabLeft: { y0: 8.4, y1: 30.7, x: -32.5, ramp: 1.8 },
            footPill: { x0: -8.2, y0: 74.2, x1: 8.2, y1: 77.95 },
            // the knurled sheet between the parts: its points' pitch; towards the mirror border at the head and at the
            // right it dips under the border (`dipTop` / `dipRight` in from the border's edge: flat and bare; then `slope`
            // wide the fall, where the points give out)
            knurl: { pitch: 1.07, dipTop: 0.45, dipRight: 0.5, slope: 0.42, drop: 0.2 },
            // the two camera boxes (the lower one the wider) and their lenses. The boxes are ONE piece of metal, a hair
            // DEEPER than the knurled sheet round them (`boxDrop` mm under it), their edges tight (`boxBevel`); where the
            // two meet the lower one stands `boxRidge` mm over the upper: a ridge in the metal, no gap (the knurl does
            // not run through)
            boxes: [
                { x0: -31.3, y0: -77.91, x1: -17.4, y1: -64.04 },
                { x0: -33.05, y0: -64.04, x1: -15.7, y1: -48.4 }
            ],
            boxDrop: 0.07, boxBevel: 0.07, boxRidge: 0.05,
            lenses: [
                // r the black disc; `bezel` in from there the turned ring ends; `glass` the lens itself. With its collar a
                // lens is 6.63 across its radius (the user's close-up: 0.3 mm short of its box at either side)
                { x: -24.4, y: -71.2, r: 6.43, bezel: 5.7, glass: 3.45 },
                { x: -24.4, y: -55.6, r: 6.43, bezel: 5.7, glass: 3.45 }
            ],
            collar: 0.2,            // the bright ring that joins each lens's box to the glass (make_decor.py draws it this wide)
            // the blue pane beside them: its left corners turn round the lamp and the macro camera, its right ones are
            // wide too; its foot steps up at the left; it is cut round the screws on its edge
            pane: { x0: -13.9, y0: -76.5, x1: 31.45, y1: -48.2, step: { x0: 4.7, x1: 7.3, y: -50.17 }, rLeft: 4.7, rTopRight: 3.5, rFootRight: 4.6 },
            flash: { x: -8.4, y: -72.0, ring: 4.1, rim: 2.07, lamp: 1.3 },
            macro: { x: -8.4, y: -55.33, ring: 4.1, glass: 2.3, eye: 1.0 },
            // the X: the striped field (flush with the pane; its right side steps in near the foot, on a 45 degree
            // slant from `bite.y0` down to `bite.y1`), the window sunk in it (ring upon ring), the emblem
            field: { x0: -3.0, y0: -73.7, x1: 29.5, y1: -52.3, r: 2.6, bite: { x: 28.67, y0: -56.97, y1: -56.14 } },
            window: { x0: 3.9, y0: -71.17, x1: 26.77, y1: -55.07, r: 2.5 },
            emblem: { x: 15.5, y: -62.67, ux: 1.175, uy: 1.06 },
            // the brushed duct across (its foot a step lower at the left; at the right its head rises to the screw there,
            // round the pane's corner and `gap` clear of it: the knurled sheet runs on in that slit), the fan in it (the
            // turned housing out to r, the open ring in to `well`, the hub, the red eye), the chip's badge on it
            duct: { x0: -34.27, y0: -47.6, x1: 34.27, y1: -28.3, step: { x0: -15.0, x1: -12.7, y: -26.3 }, rise: { y: -50.0, gap: 0.6 } },
            fan: { x: -24.55, y: -38.46, r: 6.4, well: 5.05, hub: 3.95, eye: 1.43 },
            // (`frame`: the roughened border all round it, which parts the flame from the duct; `sunk`: how far the
            // roughened metal lies under the untouched, over a slope `bevel` wide)
            badge: { x0: 15.2, y0: -45.66, x1: 26.8, y1: -33.93, frame: 0.13, sunk: 0.02, bevel: 0.08, strip: { y0: -32.57, y1: -31.31 } },
            // the lined plate: the lines turn at the seam; its drawn frame, the wordmark up its left, the mark at its foot
            // (what is printed on it is drawn line by line in make_decor.py, from the user's close-ups)
            plate: { y0: -28.3, seam: -0.3, pitch: 0.57 },
            wordmark: { x: -24.78, y0: -17.29, y1: 13.35, cap: 2.41, text: "REDMAGIC" },
            mark: { x: -24.69, y: 69.9, w: 7.48, h: 10.83 },
            // the window's rings and the field's stripes: their pitch (measured across the lines), and how much of a ring's
            // inward step its corner radius gives up (1: plain offsets, whose corners turn sharp; the phone's stay round)
            finePitch: 0.41, fieldPitch: 0.375, ringTurn: 0.27,
            // [x, y, hidden]: `hidden` 1 = half under the mirror border
            screws: [[-32.8, -76.2, 0], [-6.5, -76.2, 0], [5.2, -77.5, 1], [32.5, -76.2, 0], [-14.3, -61.7, 0], [33.0, -51.75, 0],
                     [-4.5, -48.9, 0], [-33.65, -49.7, 1], [-17.05, -31.3, 0], [30.3, -31.57, 0], [-33.8, -29.8, 1],
                     [-33.6, 63.6, 1], [-33.4, 76.8, 1], [33.3, 62.7, 1], [33.3, 76.8, 1], [-6.86, 76.1, 0], [6.5, 76.1, 0]]
        },
        // what stands proud of the frame (the right side, seen from the front)
        keys: [
            { id: "volume", press: ["volup", "voldown"], side: 1, y0: -27.5, y1: -7.7, kind: KEY_PILL, hz: 1.18 },
            { id: "power", side: 1, y0: -1.8, y1: 3.8, kind: KEY_ROUND, hz: 2.8 },
            { id: "magic", side: 1, y0: 15.25, y1: 23.95, kind: KEY_SLIDER, hz: 1.5 }
        ],
        // what each wall of the frame carries (the frame's texture; mm along the wall, from the centre: y down the side
        // walls, x across the end walls AS THE FRONT IS SEEN)
        walls: {
            right: [
                { kind: "trigger", a: -76.0, b: -61.0 }, { kind: "antenna", at: -54.5 }, { kind: "vent", a: -49.0, b: -33.3 },
                { kind: "rocker", a: -27.5, b: -7.7, hz: 1.18 }, { kind: "power", at: 1.0, r: 2.8 }, { kind: "slider", a: 14.0, b: 24.0 },
                { kind: "antenna", at: 28.0 }, { kind: "mic", at: 46.0 }, { kind: "trigger", a: 61.0, b: 76.0 }
            ],
            left: [{ kind: "antenna", at: -61.5 }, { kind: "vent", a: -49.0, b: -33.3 }, { kind: "antenna", at: -28.5 }],
            top: [
                // (`off`: mm from the wall's middle, the front glass's side negative: the head's speaker sits a little towards
                // the screen, its microphone more so)
                { kind: "mic", at: -28.8, off: -1.4 }, { kind: "antenna", at: -27.5 }, { kind: "grille", a: -17.8, b: -5.3, n: 6, off: -0.4 },
                { kind: "ir", at: 9.9 }, { kind: "jack", at: 16.0 }, { kind: "antenna", at: 28.25 }
            ],
            bottom: [
                { kind: "sim", a: -29.3, b: -14.6 }, { kind: "mic", at: -12.8 }, { kind: "antenna", at: -10.55 },
                { kind: "usb", at: 0.0, w: 9.6 }, { kind: "antenna", at: 10.55 }, { kind: "grille", a: 17.8, b: 30.3, n: 6 }
            ]
        },
        port: { x: 0, w: 9.6 },         // the USB-C port on the bottom edge
        // the materials' own colours (not themed: this is the object's paint)
        frame: [0.80, 0.81, 0.83],
        backBase: [0.66, 0.76, 0.86],
        bezel: [0.022, 0.023, 0.028],
        accent: [0.86, 0.10, 0.12]      // the slider key's red
    },
    // Any other device: a current flagship drawn from what its maker publishes (iPhone 18 Pro in Glacier, the 17 Pro's
    // body: 150.0 x 71.9 x 8.75 mm, a one-piece aluminium shell, a camera PLATEAU across the head that stands proud of
    // the back, three lenses proud of the plateau, a glass panel let into the back below it). No maker's mark is drawn:
    // this skin stands for every phone that has none of its own. The plateau's and the lenses' heights are a forum's
    // caliper figures (2.55 and 1.88 mm), not the maker's.
    "generic": {
        w: 71.9, h: 150.0, t: 8.75,
        corner: 10.6,
        edge: 1.6,
        display: { w: 69.1, h: 147.2, r: 9.2 },
        lip: 0.7,
        sheet: { x0: -27.9, y0: -22.0, x1: 27.9, y1: 62.0, r: 7.0 },
        keyProud: 0.4,
        // back view (mm from the centre, x to the right AS THE BACK IS SEEN)
        back: {
            kind: "plateau",
            // the plateau: a rounded slab `h` proud of the back, its top edge rounded by `edge`; each lens stands
            // `ringH` further, a ring of the shell's metal round its glass (r its outer radius, `glass` the pane's)
            plateau: { x0: -33.4, y0: -72.6, x1: 33.4, y1: -37.4, r: 9.0, h: 2.55, edge: 0.7 },
            ringH: 1.88, ringEdge: 0.35,
            lenses: [
                { x: -21.9, y: -64.1, r: 7.7, glass: 6.5 },
                { x: -21.9, y: -45.9, r: 7.7, glass: 6.5 },
                { x: -5.9, y: -55.0, r: 7.7, glass: 6.5 }
            ],
            flash: { x: 24.6, y: -65.2, r: 2.7 },
            lidar: { x: 24.6, y: -44.8, r: 2.5 },
            mic: { x: 24.6, y: -55.0, r: 0.45 },
            // the glass panel in the back, under the plateau
            panel: { x0: -27.9, y0: -27.5, x1: 27.9, y1: 62.0, r: 7.0 },
            screws: []
        },
        // (seen from the front: the side key at the right; the action key and the volume pair at the left)
        keys: [
            { id: "volup", side: -1, y0: -33.2, y1: -23.2, kind: KEY_PILL, hz: 1.25 },
            { id: "voldown", side: -1, y0: -19.6, y1: -9.6, kind: KEY_PILL, hz: 1.25 },
            { id: "power", side: 1, y0: -30.5, y1: -14.5, kind: KEY_PILL, hz: 1.25 },
            { id: "action", side: -1, y0: -45.6, y1: -39.6, kind: KEY_PILL, hz: 1.25 }
        ],
        walls: {
            right: [{ kind: "antenna", at: -58.0 }, { kind: "rocker", a: -30.5, b: -14.5, hz: 1.25 }, { kind: "antenna", at: 58.0 }],
            left: [{ kind: "antenna", at: -58.0 }, { kind: "rocker", a: -45.6, b: -39.6, hz: 1.25 }, { kind: "rocker", a: -33.2, b: -23.2, hz: 1.25 },
                   { kind: "rocker", a: -19.6, b: -9.6, hz: 1.25 }, { kind: "antenna", at: 58.0 }],
            top: [{ kind: "antenna", at: -22.0 }, { kind: "antenna", at: 22.0 }],
            bottom: [{ kind: "grille", a: -21.0, b: -9.0, n: 5 }, { kind: "usb", at: 0.0, w: 9.0 }, { kind: "mic", at: 9.6 }, { kind: "grille", a: 12.0, b: 21.0, n: 4 }]
        },
        port: { x: 0, w: 9.0 },
        frame: [0.70, 0.76, 0.82],
        backBase: [0.66, 0.74, 0.82],
        bezel: [0.022, 0.023, 0.028],
        accent: [0.70, 0.76, 0.82]
    }
};

function skin(name) {
    return SKINS[name] || SKINS["generic"];
}

// The whole table as JSON: what tools/bridge/make_decor.py reads (through node).
function json() {
    return JSON.stringify(SKINS);
}

function _snap(v, rs) {
    return Math.round(v * rs) / rs;
}

// A size snapped to whole device px whose difference from `outer` is an EVEN number of device px, so the box centred
// in `outer` has both edges on whole pixels.
function _snapInside(v, outer, rs) {
    let n = Math.round(v * rs);
    const o = Math.round(outer * rs);
    if ((o - n) % 2 !== 0)
        n -= 1;
    return n / rs;
}

// `o`: { pxPerMm, top, camDist }. The body is centred across the stage and stands `top` px below its top edge.
function layout(sk, W, H, rs, o) {
    const s = rs > 0 ? rs : 1;
    const ppm = o.pxPerMm;
    const bw = _snap(sk.w * ppm, s);
    const bh = _snap(sk.h * ppm, s);
    const bx = _snap((W - bw) / 2, s);
    const by = _snap(o.top, s);
    const sx = bw / sk.w;
    const sy = bh / sk.h;
    const dw = _snapInside(sk.display.w * sx, bw, s);
    const dh = _snapInside(sk.display.h * sy, bh, s);
    const cx = bx + bw / 2;
    const cy = by + bh / 2;
    // the sheet (the back face's place): its edges snapped where they stand
    const px0 = _snap(cx + sk.sheet.x0 * sx, s);
    const py0 = _snap(cy + sk.sheet.y0 * sy, s);
    const px1 = _snap(cx + sk.sheet.x1 * sx, s);
    const py1 = _snap(cy + sk.sheet.y1 * sy, s);
    const WN = sk.back.window || null;
    const PL = sk.back.plate || null;
    const CL = sk.back.collar || 0;
    const PT = sk.back.plateau || null;
    return {
        rs: s, sx: sx, sy: sy, ppm: ppm,
        body: { x: bx, y: by, w: bw, h: bh },
        display: { x: cx - dw / 2, y: cy - dh / 2, w: dw, h: dh, r: sk.display.r * ppm },
        plate: { x: px0, y: py0, w: px1 - px0, h: py1 - py0, r: sk.sheet.r * ppm },
        cx: cx, cy: cy,
        halfW: bw / 2, halfH: bh / 2, halfT: sk.t * ppm / 2,
        corner: sk.corner * ppm, edge: sk.edge * ppm, keyProud: sk.keyProud * ppm, lip: sk.lip * ppm,
        // the earpiece's slit at the front glass's top: half width, height (0: none)
        slitHalf: sk.slit ? sk.slit.w * sx / 2 : 0, slitH: sk.slit ? sk.slit.h * ppm : 0,
        // as the back is seen, px from the centre: where the fan's ring turns its hues about
        fanX: sk.back.fan ? sk.back.fan.x * sx : 0, fanY: sk.back.fan ? sk.back.fan.y * sy : 0,
        // the back's fine lines, which the shader rules itself (as the back is seen, px from the centre): the window
        // the rings run round [cx, cy, half w, half h], its corner radius, the rings' pitch; below `plateY` the plate's
        // lines, turning at `seamX`, `platePitch` apart. All 0 for a back without them.
        win: WN ? [(WN.x0 + WN.x1) / 2 * sx, (WN.y0 + WN.y1) / 2 * sy, (WN.x1 - WN.x0) / 2 * sx, (WN.y1 - WN.y0) / 2 * sy] : [0, 0, 0, 0],
        winR: WN ? WN.r * ppm : 0, finePitch: (sk.back.finePitch || 0) * ppm,
        fieldPitch: (sk.back.fieldPitch || sk.back.finePitch || 0) * ppm, ringTurn: sk.back.ringTurn || 1,
        plateY: PL ? PL.y0 * sy : 0, seamX: PL ? PL.seam * sx : 0, platePitch: PL ? PL.pitch * ppm : 0,
        // the two main lenses whose collar the glass's print hides from straight above: [x, y, y, radius], and the
        // collar's width (0: this back has none)
        lens: CL ? [sk.back.lenses[0].x * sx, sk.back.lenses[0].y * sy, sk.back.lenses[1].y * sy, sk.back.lenses[0].r * ppm] : [0, 0, 0, 0],
        collar: CL ? CL * ppm : 0,
        // what stands PROUD of the back, in the BODY's own space (x as the front is seen, px from the centre): the
        // plateau [cx, cy, half w, half h], [corner, height, edge radius, the lenses' further height], and up to three
        // lenses [x, y, r, edge radius]. All 0 for a flat back.
        plateau: PT ? [-(PT.x0 + PT.x1) / 2 * sx, (PT.y0 + PT.y1) / 2 * sy, (PT.x1 - PT.x0) / 2 * sx, (PT.y1 - PT.y0) / 2 * sy] : [0, 0, 0, 0],
        plateauB: PT ? [PT.r * ppm, PT.h * ppm, PT.edge * ppm, (sk.back.ringH || 0) * ppm] : [0, 0, 0, 0],
        rings: [0, 1, 2].map(i => PT && sk.back.lenses[i] ? [-sk.back.lenses[i].x * sx, sk.back.lenses[i].y * sy, sk.back.lenses[i].r * ppm, (sk.back.ringEdge || 0) * ppm] : [0, 0, 0, 0]),
        camDist: o.camDist
    };
}

// The body's axes (columns) in the stage's space. Turning is about the body's own vertical axis; the nod tips the
// whole turned body about the stage's horizontal axis (its top towards the viewer for a positive nod).
function basis(turn, nodDeg) {
    const th = turn * 2 * Math.PI;
    const c = Math.cos(th), s = Math.sin(th);
    const ph = nodDeg * Math.PI / 180;
    const cp = Math.cos(ph), sp = Math.sin(ph);
    // The turn brings the body's RIGHT side (seen from the front: the side with the keys) past the viewer on the way
    // to the back: ex = (c, 0, s), ey = (0, 1, 0), ez = (-s, 0, c). Then the nod, Rx(ph): y' = y cp - z sp, z' = y sp + z cp.
    function rx(v) {
        return [v[0], v[1] * cp - v[2] * sp, v[1] * sp + v[2] * cp];
    }
    return { ex: rx([c, 0, s]), ey: rx([0, 1, 0]), ez: rx([-s, 0, c]) };
}

var IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

// The homography of one face. `rect` is where the face's item stands in the stage ({x, y}); `back` picks the back
// glass (whose content is laid out as seen from the back: its x runs against the body's). `lift` is how far the
// body's centre is brought towards the viewer (px).
function faceMatrix(lay, b, rect, back, lift) {
    const D = lay.camDist;
    const t2 = lay.halfT;
    const sgn = back ? -1 : 1;
    const ex = [b.ex[0] * sgn, b.ex[1] * sgn, b.ex[2] * sgn];
    const ez = [b.ez[0] * sgn, b.ez[1] * sgn, b.ez[2] * sgn];
    const ey = b.ey;
    const cz = -t2 + (lift || 0);
    const lx = rect.x - lay.cx;
    const ly = rect.y - lay.cy;
    // the world position of the item's origin, and of a step along each of its axes
    const p0x = lay.cx + ex[0] * lx + ey[0] * ly + ez[0] * t2;
    const p0y = lay.cy + ex[1] * lx + ey[1] * ly + ez[1] * t2;
    const p0z = cz + ex[2] * lx + ey[2] * ly + ez[2] * t2;
    const camX = lay.cx, camY = lay.cy;
    // X w = D Px - camX Pz ;  Y w = D Py - camY Pz ;  w = D - Pz   (all affine in the item's u, v)
    let r0 = [D * ex[0] - camX * ex[2], D * ey[0] - camX * ey[2], D * p0x - camX * p0z];
    let r1 = [D * ex[1] - camY * ex[2], D * ey[1] - camY * ey[2], D * p0y - camY * p0z];
    const r3 = [-ex[2], -ey[2], D - p0z];
    // the item itself is placed at rect.x, rect.y by its own x / y: take that translation out again
    r0 = [r0[0] - rect.x * r3[0], r0[1] - rect.x * r3[1], r0[2] - rect.x * r3[2]];
    r1 = [r1[0] - rect.y * r3[0], r1[1] - rect.y * r3[1], r1[2] - rect.y * r3[2]];
    const k = 1 / D;
    return [r0[0] * k, r0[1] * k, 0, r0[2] * k,
            r1[0] * k, r1[1] * k, 0, r1[2] * k,
            0, 0, 1, 0,
            r3[0] * k, r3[1] * k, 0, r3[2] * k];
}

function facing(b) {
    return b.ez[2] >= 0 ? 1 : -1;
}

// How wide the turned body's shadow is: its width seen edge-on is its thickness. And how tall, for a body that is
// tipped (at rest and in a plain turn: its own height).
// Up to 4 rows for the shader: [y0, y1 (px from the centre), side, kind + its half extent across the frame's
// thickness in tenths of the kind's unit (kind + hz mm / 10)]; the rest are empty (kind 0).
function keys(sk, lay) {
    const out = [];
    for (let i = 0; i < 4; i++) {
        const k = sk.keys[i];
        const hz = k ? (k.hz !== undefined ? k.hz : 0.17 * sk.t) : 0;
        out.push(k ? [k.y0 * lay.sy, k.y1 * lay.sy, k.side, k.kind + Math.min(hz, 4.9) / 10] : [0, 0, 0, 0]);
    }
    return out;
}

function _answers(k, id) {
    return k.id === id || (k.press !== undefined && k.press.indexOf(id) >= 0);
}

// Which of the rows a part's press moves: -1 when the skin has no such key.
function keyRow(sk, id) {
    for (let i = 0; i < sk.keys.length && i < 4; i++)
        if (_answers(sk.keys[i], id))
            return i;
    return -1;
}

// The stretch of the frame a part takes: its own key's, or its half of a key two parts share (a rocker).
function _key(sk, id) {
    for (let i = 0; i < sk.keys.length; i++) {
        const k = sk.keys[i];
        if (k.id === id)
            return k;
        if (k.press !== undefined && k.press.indexOf(id) >= 0) {
            const n = k.press.length, at = k.press.indexOf(id), step = (k.y1 - k.y0) / n;
            return { id: id, side: k.side, y0: k.y0 + at * step, y1: k.y0 + (at + 1) * step, kind: k.kind };
        }
    }
    return null;
}

// The hit zones. A key seen front-on is a bump a pixel or two proud of the frame, so its zone is a band beside the
// frame, at least `minPx` tall; on the back face the keys stand on the other side.
function zones(sk, lay, face) {
    const out = {};
    const side = face === "back" ? -1 : 1;
    const reach = 16, inside = 5, minPx = 20;
    function band(y0, y1, keySide) {
        let a = lay.cy + y0 * lay.sy, b = lay.cy + y1 * lay.sy;
        if (b - a < minPx) {
            const m = (a + b) / 2;
            a = m - minPx / 2;
            b = m + minPx / 2;
        }
        const sd = side * (keySide || 1);                    // (a key on the left wall, as the front is seen)
        const edge = lay.cx + sd * lay.halfW;
        const x = sd > 0 ? edge - inside : edge - reach;
        return { x: x, y: a, w: reach + inside, h: b - a };
    }
    const up = _key(sk, "volup"), down = _key(sk, "voldown");
    if (up && down) {
        // the two halves share the rocker's middle; each takes the room it needs away from it
        const a = band(up.y0, up.y1, up.side), c = band(down.y0, down.y1, down.side);
        const mid = lay.cy + up.y1 * lay.sy;
        out.volup = { x: a.x, y: Math.min(a.y, mid - minPx), w: a.w, h: mid - Math.min(a.y, mid - minPx) };
        out.voldown = { x: c.x, y: mid, w: c.w, h: Math.max(c.y + c.h, mid + minPx) - mid };
    }
    const pw = _key(sk, "power");
    if (pw)
        out.power = band(pw.y0, pw.y1, pw.side);
    const pwid = Math.max(sk.port.w * lay.sx + 16, 44);
    out.cable = { x: lay.cx + sk.port.x * lay.sx * side - pwid / 2, y: lay.body.y + lay.body.h - 4, w: pwid, h: 30 };
    return out;
}
