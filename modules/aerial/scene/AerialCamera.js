.pragma library

.import "../../common/board/IsoCore.js" as Core

// =============================================================================
// AerialCamera.js -- aerial's camera: the board toolkit's isometric core (modules/common/board/IsoCore.js) with what only aerial's parts need on top of it: its fit
// (the board, the plug's reach, the dome's and the globe's air), the live patches' rects (the card with its screw and cables, the DIP switch, the button, the plug), the
// pick (which part a click means, in the frames the groups are in RIGHT NOW) and the live label's affine map (the shield's plane, tilted with the card).
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
function lightDir(angleDeg, elevation) {
    return Core.lightDir(angleDeg, elevation);
}

// The scene's design width and what the stage asks of the engine: the popup at silicon's size (760 design px wide, ratio 1.35 by the owner).
var DESIGN_WIDTH = 760;

// THE FIT (round 3). Across: the board's corners and the plug's reach past the jack decide the scale (the board is the popup's width, as silicon's is). Down: the board's front corner
// plus the margin is the popup's foot. Up: the CLOUD decides -- the signal fan stands on the label's centre (ANCHORS.cloud) and needs CLOUD.top design px above it (AerialGeometry
// CLOUD, design px at 760: they scale with the width), so the popup is as tall as the fan, never as tall as "the board's corners".
function fitPoints(G) {
    var pts = Core.boxCorners(G.BOARD);
    var J = G.JACK, P = G.PLUG;
    pts.push([P.x1 + P.boot + G.CABLE_FADE.len * 0.6, P.y1, J.mouth.zc]);
    return pts;
}
function fit(G, w, h, margins) {
    var f = fitNatural(G, w, margins);
    return { s: f.s, ox: f.ox, oy: f.oy };
}
// the fan's numbers at this width (design px -> item px)
function cloud(G, w) {
    var k = w / DESIGN_WIDTH, C = G.CLOUD;
    return { rBt: C.rBt * k, r: C.r.map(function (v) { return v * k; }), rFringe: C.rFringe * k, span: C.span, top: C.top * k };
}
function fitNatural(G, w, margins) {
    var m = margins || { l: 14, r: 14, t: 12, b: 14 };
    var pts = fitPoints(G);
    var minX = 1e9, maxX = -1e9, maxY = -1e9;
    pts.forEach(function (p) {
        var x = Core.dot(p, R), y = -Core.dot(p, U);
        minX = Math.min(minX, x); maxX = Math.max(maxX, x);
        maxY = Math.max(maxY, y);
    });
    var s = (w - m.l - m.r) / (maxX - minX);
    var ox = Math.round(m.l - s * minX);
    // the origin's y: the cloud's origin stands CLOUD.top below the popup's top edge
    var a = G.ANCHORS.cloud, top = G.CLOUD.top * w / DESIGN_WIDTH;
    var oy = Math.round(top + s * Core.dot(a, U));
    return { s: s, ox: ox, oy: oy, height: Math.ceil(oy + s * maxY + m.b) };
}

// ---- the card's frame (the shader's tiltBy): forward, a point of the card's own frame -> the board's, about the finger end's axis
function tilt(G, p, a) {
    var c = Math.cos(a), s = Math.sin(a), P = G.CARD.pivot;
    var dy = p[1] - P.y, dz = p[2] - P.z;
    return [p[0], P.y + dy * c - dz * s, P.z + dz * c + dy * s];
}
function tiltDir(v, a) {
    var c = Math.cos(a), s = Math.sin(a);
    return [v[0], v[1] * c - v[2] * s, v[2] * c + v[1] * s];
}

// ---- the live patches: the item rect (whole px, padded) that holds everything a moving part can change, and the shadow it casts from there toward `light`
function _shadowed(pts, top, light) {
    var l = light || [0, 1, 0], k = top / Math.max(l[1], 0.02);
    var sx = -l[0] * k, sz = -l[2] * k, out = pts.slice();
    pts.forEach(function (p) {
        out.push([p[0] + sx, 0, p[2] + sz]);
    });
    return out;
}
function _footprint(x0, z0, x1, z1, yTop) {
    var pts = [];
    [[x0, z0], [x1, z0], [x1, z1], [x0, z1]].forEach(function (d) {
        pts.push([d[0], 0, d[1]]);
        pts.push([d[0], yTop, d[1]]);
    });
    return pts;
}
// the card at its highest tilt with its screw out and its coax lying back to the board's edge (its far end rises with the tilt), the standoff and the socket, and the soft edge of the shadow it throws
function cardRect(G, cam, pad, light) {
    var C0 = G.CARD, m = 5, top = 34 + Math.sin(C0.tilt) * C0.h;
    var pts = _footprint(C0.x0 - m, C0.z0 - m + G.COAX.endLz, C0.x0 + C0.w + m, C0.z0 + C0.h + m, top);
    return Core.projectedRect(_shadowed(pts, top, light), cam, pad);
}
function dipRect(G, cam, pad, light) {
    var D = G.DIP;
    return Core.projectedRect(_shadowed(_footprint(D.x0 - 1.5, D.z0 - 1.5, D.x1 + 1.5, D.z1 + 1.5, D.h + D.lever.h), D.h + D.lever.h, light), cam, pad);
}
function btnRect(G, cam, pad, light) {
    var B = G.BTN;
    return Core.projectedRect(_shadowed(_footprint(B.x0 - 1.5, B.z0 - 1.5, B.x1 + 1.5, B.z1 + 1.5, B.h + B.cap.h), B.h + B.cap.h, light), cam, pad);
}
function plugRect(G, cam, pad, light) {
    var J = G.JACK, P = G.PLUG, zc = J.mouth.zc;
    return Core.projectedRect(_shadowed(_footprint(J.x1 - 2, zc - 9, J.x1 + P.travel + 40, zc + 9, P.y1 + 1.4), P.y1 + 1.4, light), cam, pad);
}

// ---- the pick -------------------------------------------------------------------------------
// state: { tilt (rad), screwLift (mm), dipW, dipB (0..1), btnDown (mm), plugIn (0..1) }
function frameOf(G, st) {
    return function (part, o, d) {
        var g = part.group;
        if (g === "card" || g === "pcb") {
            var a = -st.tilt, c = Math.cos(a), s = Math.sin(a), P = G.CARD.pivot;
            var dy = o[1] - P.y, dz = o[2] - P.z;
            o[1] = P.y + dy * c - dz * s;
            o[2] = P.z + dz * c + dy * s;
            var vy = d[1], vz = d[2];
            d[1] = vy * c - vz * s;
            d[2] = vz * c + vy * s;
        } else if (g === "screw") {
            o[1] -= st.screwLift;
        } else if (g === "dipw") {
            o[0] -= st.dipW * G.DIP.travel;
        } else if (g === "dipb") {
            o[0] -= st.dipB * G.DIP.travel;
        } else if (g === "btn") {
            o[1] += st.btnDown;
        } else if (g === "plug") {
            if (st.plugIn < 0.05)
                return false;
            o[0] -= (1 - st.plugIn) * G.PLUG.travel;
        }
        return true;
    };
}
function pickPart(G, cam, px, py, st) {
    var part = Core.pickBoxes(G.PARTS, cam, px, py, frameOf(G, st));
    // THE LATCHES' GROOVES (round 6, the user: "the entire groove, so I can click where the latch could go"): a click on the housing's top inside a lever's track is that
    // lever, wherever the lever stands. The rest of the housing picks nothing (round 2).
    if (part === "dipBody") {
        var g = latchAt(G, cam, px, py);
        if (g !== "")
            return g;
    }
    return part;
}
// the lever whose groove a pixel falls in on the housing's top ("" none): the track runs the lever's whole travel, as deep as the lever plus a little
function latchAt(G, cam, px, py) {
    var D = G.DIP, L = D.lever, p = Core.onPlane(px, py, cam, D.h);
    if (p[0] < D.xOff - 0.3 || p[0] > D.xOff + L.w + D.travel + 0.3)
        return "";
    for (var i = 0; i < D.rows.length; i++)
        if (Math.abs(p[2] - D.rows[i]) <= L.d / 2 + 0.4)
            return i === 0 ? "dipWifi" : "dipBt";
    return "";
}

// ---- the live label's affine map: the shield plane in card-local mm (lx, ly) -> item px, for a camera and a tilt. { a, b, c, d, tx, ty } with x' = a lx + b ly + tx,
// y' = c lx + d ly + ty (the label's own item origin is its corner (LABEL.x0, LABEL.y0): `tx, ty` are the item's top-left in item px)
function labelMap(G, cam, a) {
    var L = G.LABEL, C0 = G.CARD, yTop = C0.yPcb + C0.pcb + G.SHIELD.h + L.h;
    var ex = tiltDir([1, 0, 0], a), ez = tiltDir([0, 0, 1], a);
    var o = tilt(G, [C0.x0 + L.x0, yTop, C0.z0 + L.y0], a);
    var q = Core.project(o, cam);
    return { a: cam.s * Core.dot(ex, R), c: -cam.s * Core.dot(ex, U), b: cam.s * Core.dot(ez, R), d: -cam.s * Core.dot(ez, U), tx: q.x, ty: q.y };
}

// ---- the part's corners where it is drawn right now (a hover highlight's hull): the box's eight corners through the group's frame
function cornersOf(G, part, st) {
    var out = [];
    for (var i = 0; i < 8; i++) {
        var p = [i & 1 ? part.max[0] : part.min[0], i & 2 ? part.max[1] : part.min[1], i & 4 ? part.max[2] : part.min[2]];
        var g = part.group;
        if (g === "card" || g === "pcb")
            p = tilt(G, p, st.tilt);
        else if (g === "screw")
            p[1] += st.screwLift;
        else if (g === "dipw")
            p[0] += st.dipW * G.DIP.travel;
        else if (g === "dipb")
            p[0] += st.dipB * G.DIP.travel;
        else if (g === "btn")
            p[1] -= st.btnDown;
        else if (g === "plug")
            p[0] += (1 - st.plugIn) * G.PLUG.travel;
        out.push(p);
    }
    return out;
}
