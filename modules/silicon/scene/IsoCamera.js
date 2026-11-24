.pragma library

.import "../../common/board/IsoCore.js" as Core

// =============================================================================
// IsoCamera.js -- silicon's camera: the board toolkit's isometric core (modules/common/board/IsoCore.js: project, onPlane, circleExtent, holoRect, lightDir,
// the fit and the pick as functions of any scene's points and parts) with what only silicon's parts need on top of it -- its fit (the board and the two
// hologram anchors), its name-plate room, the live patches' rects (the package's, the card's), the integrated beam and its ghost of the card, the package's
// frame, and its pick (which part a click means, with the groups' frames of right now).
//
// Screen x = ox + s * dot(P, R), screen y = oy - s * dot(P, U), P in board millimetres.
// The SAME constants are in every shader (silicon_board.frag CAM_R / CAM_U / CAM_C).
// No Qt here: it runs under node (a QML `.import` aside).
// =============================================================================

var R = Core.R;
var U = Core.U;
var C = Core.C;
function project(p, cam) {
    return Core.project(p, cam);
}
function onPlane(px, py, cam, y) {
    return Core.onPlane(px, py, cam, y);
}
function circleExtent(p, r, cam) {
    return Core.circleExtent(p, r, cam);
}
function holoRect(anchor, cam, w, base, h, pad, lens, ink) {
    return Core.holoRect(anchor, cam, w, base, h, pad, lens, ink);
}
function lightDir(angleDeg, elevation) {
    return Core.lightDir(angleDeg, elevation);
}

// The camera that fits the scene into w x h: the board's eight corners and, above the two
// hologram anchors, `holoTop` mm of headroom; margins {l, r, t, b} px. Whole-pixel origin.
function fit(G, w, h, margins, holoTop) {
    var pts = Core.boxCorners(G.BOARD);
    var top = holoTop === undefined ? 58 : holoTop;
    ["cpuHolo", "gpuHolo"].forEach(function (a) {
        var p = G.ANCHORS[a];
        pts.push([p[0], p[1] + top, p[2]]);
    });
    return Core.fitPoints(pts, w, h, margins);
}

// How much room a name plate needs above the top edge of its hologram's plane, px: the plate's text foot stands `plateGap` (4, SiliconPopup) above
// the plane and the TALLEST plate -- the GPU's, its head, its figures row and its tail row all open -- is 55 px high in Inter (head 16 bold: 20, figures 11:
// 2 + 14, tail 12: 4 + 15) and 57 in the user's Audiowide, which sets the number. The popup keeps its padding above that plate and not a pixel more: what the
// camera's fit left above it is trimmed. A plate at rest is lower than that (a head alone, a head and its tail), and a state that needs more rows than this
// reserves is clamped at the padding by the popup, i.e. pressed into its hologram's top by the difference.
// 62, not the exact 61 (Audiowide's 57 + 4): a camera 5 px up lands one pixel of the package's edge (386, 328 at 1x) on a float edge, and the live patch and the cached
// board then differ there by 14..53 levels (1 px, only while the patch is up). 62 keeps that pixel off the edge and a pixel of room.
var PLATE_ROOM = 62;

// The camera at a given WIDTH, with the height the scene needs (the popup's `implicitHeight`): the fit of 760 x 560, scaled by
// the width alone -- the scale and the board's horizontal place are exactly what fit() gave there -- and `height` is where
// the board's front corner ends plus the bottom margin, so nothing below it is blank.
// The top is the fit's too, less what is blank above the tallest name plate (PLATE_ROOM): `oy` and `height` both lose that room, so the board
// and everything on it rise by it and the popup is that much shorter. It reads no height of its own: the popup binds its height to this one.
function fitNatural(G, w, margins, holoTop) {
    var m = margins || { l: 12, r: 12, t: 12, b: 12 };
    var cam = fit(G, w, w * 560 / 760, m, holoTop);
    var B = G.BOARD, maxY = -1e9, minY = 1e9;
    for (var i = 0; i < 2; i++)
        for (var j = 0; j < 2; j++)
            for (var k = 0; k < 2; k++) {
                var y = project([i ? B.x1 : B.x0, j ? B.y1 : B.y0, k ? B.z1 : B.z0], cam).y;
                maxY = Math.max(maxY, y);
                minY = Math.min(minY, y);
            }
    var top = minY;
    ["cpuHolo", "gpuHolo"].forEach(function (a) {
        top = Math.min(top, holoRect(G.ANCHORS[a], cam, HOLO.w, HOLO.base, HOLO.h, 0).y - PLATE_ROOM);
    });
    var trim = Math.max(0, Math.floor(top - m.t));
    return { s: cam.s, ox: cam.ox, oy: cam.oy - trim, height: Math.ceil(maxY + m.b) - trim };
}

// The item rect (whole px, padded) that holds everything a moving package can change: the CPU
// zone's footprint, the package at its highest lift, and the shadow it casts from there toward
// `light` (board space, toward the lamp; the scene's tunable light moves that shadow). The live
// patch's quad.
function patchRect(G, cam, pad, light) {
    var Z = G.ZONE, e = Z.half;
    // the package's highest point: its top lifted all the way (it turns inside the zone square)
    var top = G.PKG.substrate.h + G.PKG.base.h + G.PKG.tileH + G.PKG.lift;
    // where a point that high casts its shadow on the board: a low lamp casts it far, and the rect
    // grows with it (the scene clamps the rect to itself)
    var l = light || [0, 1, 0], k = top / Math.max(l[1], 0.02);
    var sx = -l[0] * k, sz = -l[2] * k;
    var pts = [];
    [[-e, -e], [e, -e], [e, e], [-e, e]].forEach(function (d) {
        pts.push([Z.cx + d[0], 0, Z.cz + d[1]]);
        pts.push([Z.cx + d[0], top, Z.cz + d[1]]);
        pts.push([Z.cx + d[0] + sx, 0, Z.cz + d[1] + sz]);
    });
    return Core.projectedRect(pts, cam, pad);
}

// How far the card rises as it leaves (MotionScripts.CARD_OUT_MM: the two must stay equal).
var CARD_LIFT_MAX = 34;
var CARD_SOFT_MM = 7;

// The item rect (whole px, padded) that holds everything a moving CARD can change: its footprint with the I/O bracket and the bracket's
// lip, the card at its highest lift (the parts on it stand 7 mm over the PCB, the bracket's flange 13.6 over the board), the dissolving
// noise, and the shadow it casts from there toward `light`. The live card patch's quad (see patchRect).
function cardRect(G, cam, pad, light) {
    var C = G.CARD, B = G.BRACKET;
    // the footprint grown by the reach of the contact darkening and the shadow's soft edge, mm (the pad is whole pixels on top)
    var m = CARD_SOFT_MM;
    var x0 = C.x0 - m, x1 = B.lip.x1 + m, z0 = C.z0 - m, z1 = C.z1 + m;
    var top = Math.max(B.y1, C.rest + C.pcb + 7.0) + CARD_LIFT_MAX;
    var l = light || [0, 1, 0], k = top / Math.max(l[1], 0.02);
    var sx = -l[0] * k, sz = -l[2] * k;
    var pts = [];
    [[x0, z0], [x1, z0], [x1, z1], [x0, z1]].forEach(function (d) {
        pts.push([d[0], 0, d[1]]);
        pts.push([d[0], top, d[1]]);
        pts.push([d[0] + sx, 0, d[1] + sz]);
    });
    return Core.projectedRect(pts, cam, pad);
}

// The CPU's and the GPU's hologram planes: `w` mm wide, from `base` to `base + h` mm above their anchor. The scene's holoRect calls, the zones' regions and the
// plates' place (PopupLayout.js: a plate hugs the top edge of its plane) take it from here (the plate and the click region read it too).
var HOLO = { w: 52, base: 10, h: 48 };

// How far the projector's haze (holo_common.glsl coneHaze: a cone from the anchor up to `hTop`, widening, its density fading with height and out
// over the last 10 mm) still shows ink, measured from the shader's own arithmetic: the SCREEN mm about the anchor's screen point where the final
// alpha (light theme, the default beam strength 1.8, the ring phase at its brightest) is still 4 levels of 255 -- 1 mm margin on each. `up` is
// screen mm above the anchor, `side` either side of it, `down` below. The haze outgrows the plane at the CPU's top (hTop is the plane's top: the
// haze reaches 52.5 mm up where the plane's own top is 47.4), so a rect cut at the plane's top and a flat pad would cut the haze with a hard edge.
// Re-measure these when the shader's haze changes.
var CONE_INK = { cpu: { side: 21.5, up: 56, down: 1.5 }, gpu: { side: 15.5, up: 37, down: 1.5 } };

// How far from its centre a ring of radius r (a lens's: HoloLayer's lensGlow draws a thin ring at r falling off
// over `ringFall` and a soft disc of radius `disc` x r) still shows ink, in mm: a Gaussian is under 2 % of its
// peak (5 levels of 255 on a flat ground) sqrt(ln 40) = 1.9 falloffs out. G is the geometry (G.LENS).
function ringReach(G, r) {
    return r + 1.9 * G.LENS.ringFall;
}
function lensReach(G, r) {
    return Math.max(ringReach(G, r), r * G.LENS.disc * 1.82);        // the disc: exp(-(d / (disc r))^2) is 2 % of 0.55 at 1.82 disc radii
}

// ---- the integrated beam and its ghost of the card -----------------------------------------------------------------
// The numbers the beam shares with holo_beam.glsl: HoloLayer hands them to the shader as uniforms (r3hHover, r3hBeam), so the shader has no copy of
// them and beamRect widens by the same ones. `hover` / `bob`: how high the ghost floats above the card's place, mm (a mean and the slow bob
// about it); the fan is `thick0` mm thick at the tile and `thick1` more at the card; `arch` the mm the beam rises in the middle. (Its fade-out at
// the die mirrors its fade-in at the tile: BEAM_RAMP and SceneGeometry.LENS.fanBack in the shader, 1 + fanBack the far end of its reach here.)
var BEAM = { hover: 1.6, bob: 0.7, thick0: 2.0, thick1: 2.2, arch: 9 };

// The parts of the real card the ghost draws: all of group "card" but its I/O bracket (the iGPU's ghost has no I/O shield; the dGPU's card keeps it). SceneGeometry is the one source: a part moved or resized there moves here.
function ghostParts(G) {
    return G.PARTS.filter(function (p) {
        return p.group === "card" && p.cluster !== "bracket";
    });
}

// One part as the shader's row of cells (a box is a row of one; a part that is not there is a row of none, which the shader skips):
// r = the first cell's rectangle [x0, z0, x1, z1], step = the step between cells [x, z], n = the counts [x, z], y = [bottom, top], shape 1 = a cylinder.
function ghostRow(p) {
    if (!p)
        return { r: [0, 0, 0, 0], step: [0, 0], n: [0, 0], y: [0, 0], shape: 0, skip: 0 };
    var shape = p.shape === "cylY" ? 1 : 0;
    if (p.row) {
        // the cells the row leaves out (`skip`: an index or a list), as a mask the shader reads without bit operations (GLSL 1.20): the sum of 2^i
        var sk = p.row.skip === undefined ? [] : [].concat(p.row.skip), mask = 0;
        sk.forEach(function (i) { mask += Math.pow(2, i); });
        return { r: [p.min[0], p.min[2], p.min[0] + p.row.cell[0], p.min[2] + p.row.cell[2]], step: [p.row.pitch[0], p.row.pitch[1]], n: [p.row.n[0], p.row.n[1]],
                 y: [p.min[1], p.min[1] + p.row.cell[1]], shape: shape, skip: mask };
    }
    return { r: [p.min[0], p.min[2], p.max[0], p.max[2]], step: [0, 0], n: [1, 1], y: [p.min[1], p.max[1]], shape: shape, skip: 0 };
}

// The ghost's parts by the role the shader gives them (G needs PARTS and CARD): the PCB, the die's substrate and the die, the four GDDR chips, the
// heatsink's base and fins, the VRM's chokes and MOSFETs, the capacitors and the MLCCs, and the gold fingers' band. `used` names the parts the roles
// take: a card part that is not one of them is a part the ghost would silently leave out.
var GHOST_ROLES = { pcb: "cardPcb", sub: "gpuSubstrate", die: "gpuDie", gddr0: "gddr0", gddr1: "gddr1", gddr2: "gddr2", gddr3: "gddr3", sink: "sinkBase",
                    fins: "sinkFins", chokes: "vrmChokes", fets: "vrmFets", caps: "capsCard", mlcc: "mlccCard" };
function ghostSet(G) {
    var by = {}, used = [], out = { fingers: G.CARD.fingers, gddr: [], used: used };
    ghostParts(G).forEach(function (p) {
        by[p.name] = p;
    });
    for (var role in GHOST_ROLES) {
        used.push(GHOST_ROLES[role]);
        if (role.indexOf("gddr") === 0)
            out.gddr.push(ghostRow(by[GHOST_ROLES[role]]));
        else
            out[role] = ghostRow(by[GHOST_ROLES[role]]);
    }
    return out;
}

// The box the ghost hangs in, board mm: the footprint of its parts and, from the lowest face to the highest, the height of them lifted by the
// hover (and its bob) -- y0 / y1; ry0 / ry1 are the same with the card at rest. `pad` mm more on every side (the outline's width, the faint halo).
function ghostBox(G, pad) {
    var ps = ghostParts(G), p = pad || 0, b = { x0: 1e9, z0: 1e9, x1: -1e9, z1: -1e9, y0: 1e9, y1: -1e9 };
    ps.forEach(function (q) {
        b.x0 = Math.min(b.x0, q.min[0]); b.x1 = Math.max(b.x1, q.max[0]);
        b.z0 = Math.min(b.z0, q.min[2]); b.z1 = Math.max(b.z1, q.max[2]);
        b.y0 = Math.min(b.y0, q.min[1]); b.y1 = Math.max(b.y1, q.max[1]);
    });
    return { x0: b.x0 - p, z0: b.z0 - p, x1: b.x1 + p, z1: b.z1 + p, y0: b.y0 + BEAM.hover - BEAM.bob, y1: b.y1 + BEAM.hover + BEAM.bob, ry0: b.y0, ry1: b.y1 };
}

// where the beam lands: the middle of the ghost's die at the die's top, with the card at rest (the shader adds the hover)
function ghostDie(G) {
    var d = G.PARTS.filter(function (p) {
        return p.name === "gpuDie";
    })[0];
    return [(d.min[0] + d.max[0]) / 2, d.max[1], (d.min[2] + d.max[2]) / 2];
}

// The points the integrated beam can light, board mm: the fan from just behind the tile to the die, `reach` x its half width and half thickness
// out (a Gaussian across and through it: 1.3 widths and 1.23 thicknesses out it is 2 % of its peak), the arch it rises in, and the ghost's box.
function beamEnvelope(G, anchor, target, arch) {
    var pts = [], L = G.LENS;
    var dx = target[0] - anchor[0], dz = target[2] - anchor[2], len = Math.max(Math.hypot(dx, dz), 1e-6), ux = dx / len, uz = dz / len;
    var ar = arch === undefined ? BEAM.arch : arch;
    var ceil = 16 + ar;                                                 // the fan is integrated through a slab this tall
    var qs = [-L.fanBack];
    for (var i = 0; i <= 20; i++)
        qs.push(i / 20);
    qs.push(1 + L.fanBack);                                             // the beam is gone this far past the die: its fade-in mirrored
    // the die's top, at the lowest and the highest the ghost hovers: the axis ends there
    [target[1] + BEAM.hover - BEAM.bob, target[1] + BEAM.hover + BEAM.bob].forEach(function (yEnd) {
        qs.forEach(function (q) {
            var qc = Math.max(0, Math.min(1, q)), W = (L.fanW0 + L.fanW1 * qc) * 1.3, H = (BEAM.thick0 + BEAM.thick1 * qc) * 1.23;
            var ya = anchor[1] + (yEnd - anchor[1]) * qc + ar * 4 * qc * (1 - qc);
            [-1, 1].forEach(function (side) {
                [-1, 1].forEach(function (up) {
                    pts.push([anchor[0] + ux * len * q - uz * W * side, Math.max(0, Math.min(ceil, ya + H * up)), anchor[2] + uz * len * q + ux * W * side]);
                });
            });
        });
    });
    var b = ghostBox(G, 3);
    [b.x0, b.x1].forEach(function (x) {
        [b.y0, b.y1].forEach(function (y) {
            [b.z0, b.z1].forEach(function (z) {
                pts.push([x, y, z]);
            });
        });
    });
    return pts;
}

// The item rect (whole px) the integrated beam's hologram covers: its envelope (the fan from the graphics tile -- where the package's turn and
// lift put it -- to the ghost's die, and the ghost hanging over the card's place, hover and tallest part included) and the tile's lens (a disc and
// a ring around the anchor, drawn on the board; padded in mm from the shader's own radii). Everything in mm, so it holds at every scale of the
// scene; two px more all round for the antialiased edge.
function beamRect(G, cam, anchor, target) {
    var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    function take(e) {
        minX = Math.min(minX, e.x0); maxX = Math.max(maxX, e.x1);
        minY = Math.min(minY, e.y0); maxY = Math.max(maxY, e.y1);
    }
    beamEnvelope(G, anchor, target).forEach(function (p) {
        var q = project(p, cam);
        take({ x0: q.x, x1: q.x, y0: q.y, y1: q.y });
    });
    take(circleExtent(anchor, lensReach(G, G.LENS.beam), cam));
    var x0 = Math.floor(minX - 2), y0 = Math.floor(minY - 2);
    return { x: x0, y: y0, w: Math.ceil(maxX + 2) - x0, h: Math.ceil(maxY + 2) - y0 };
}

// Where a point of the CPU package (board space, the package at rest) is once the package is
// turned `turn` rad and lifted `lift` mm: the shader's own frame (silicon_shader_gen.js maps the
// world into the package with rotYAbout(p - lift, -turn); this is its inverse).
function pkgPoint(G, p, turn, lift) {
    var c = Math.cos(turn || 0), s = Math.sin(turn || 0), dx = p[0] - G.ZONE.cx, dz = p[2] - G.ZONE.cz;
    return [G.ZONE.cx + c * dx - s * dz, p[1] + (lift || 0), G.ZONE.cz + s * dx + c * dz];
}

// Ray-cast the parts a click can mean (the same boxes, the same groups' frames as the shader:
// the package at `pkgTurn` rad and `pkgLift` mm, the card at `cardLift`, ...). Returns the part's
// name or "".
function pick(G, cam, px, py, state) {
    var st = state || {};
    return Core.pickBoxes(G.PARTS, cam, px, py, function (p, o, d) {
        if (p.group === "pkg") {
            o[1] -= st.pkgLift || 0;
            var a = -(st.pkgTurn || 0), c = Math.cos(a), s = Math.sin(a);
            var dx = o[0] - G.ZONE.cx, dz = o[2] - G.ZONE.cz;
            var d0 = d[0], d2 = d[2];
            o[0] = G.ZONE.cx + c * dx - s * dz;
            o[2] = G.ZONE.cz + s * dx + c * dz;
            d[0] = c * d0 - s * d2;
            d[2] = s * d0 + c * d2;
        } else if (p.group === "card") {
            o[1] -= st.cardLift || 0;
        } else if (p.group === "plug") {
            if ((st.plugIn === undefined ? 1 : st.plugIn) < 0.5)
                return false;
        } else if (p.group === "hdmi") {
            if ((st.hdmiIn === undefined ? 0 : st.hdmiIn) < 0.5)          // the HDMI plug is a pick only while it is (mostly) in the port
                return false;
        } else if (p.group === "lever") {
            o[0] -= (st.lever || 0) * (G.LEVER.xHigh - G.LEVER.xLow);
        } else if (p.group === "lock" || p.group === "shackle") {
            if ((st.lock === undefined ? 0 : st.lock) < 0.5)      // the lock is not a pick unless the state says it is there
                return false;
        }
        return true;
    });
}
