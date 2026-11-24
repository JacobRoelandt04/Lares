.pragma library

// =============================================================================
// IsoCore.js -- the true isometric camera every board shader uses, for QML: placing the scene in its item, placing a live patch and the holograms, and
// hit-testing a click by arithmetic (a ShaderEffect receives no input of its own worth having: CLAUDE.md, "A captured item ...").
// The board toolkit's core; a scene's own camera file (silicon's IsoCamera.js) adds what only that scene's parts need (its fit, its patches).
//
// Screen x = ox + s * dot(P, R), screen y = oy - s * dot(P, U), P in board millimetres.
// The SAME constants are in every shader (CAM_R / CAM_U / CAM_C).
// A camera is { s: px per mm, ox, oy: the board origin in item px }.
// No Qt here; the only .import is by a scene's wrapper.
//
//   project(p, cam)                      board point [x, y, z] -> item px { x, y }
//   onPlane(px, py, cam, y)              item px -> the board point at height y the pixel looks at
//   fitPoints(pts, w, h, margins)        the camera that fits board points into w x h (whole-pixel origin)
//   projectedRect(pts, cam, pad)         the whole-px padded item rect { x, y, w, h } that holds these board points
//   circleExtent(p, r, cam)              the screen ellipse of a horizontal circle: its four extremes { x0, y0, x1, y1 }
//   holoRect(anchor, cam, w, base, h, pad, lens, ink)   the upright hologram plane over an anchor (+ its lens and haze), padded item rect
//   pickBoxes(parts, cam, px, py, frameOf)  the part under a pixel: the camera's ray against every part's box, each in its group's frame
//   lightDir(angleDeg, elevation)        the lamp in view space (Lighting.js's angle + elevation), as a board-space direction
// =============================================================================

var R = [0.70710678, 0.0, -0.70710678];       // screen right
var U = [-0.40824829, 0.81649658, -0.40824829];  // screen up
var C = [0.57735027, 0.57735027, 0.57735027];   // toward the camera

function dot(a, b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

// board point [x, y, z] (mm) -> item px {x, y} for a camera {s, ox, oy}
function project(p, cam) {
    return { x: cam.ox + cam.s * dot(p, R), y: cam.oy - cam.s * dot(p, U) };
}

// item px -> the board point at height y (mm) the pixel looks at
function onPlane(px, py, cam, y) {
    var sx = (px - cam.ox) / cam.s;
    var sy = (cam.oy - py) / cam.s;
    var ro = [sx * R[0] + sy * U[0], sx * R[1] + sy * U[1], sx * R[2] + sy * U[2]];
    // walk along -C to the plane
    var t = (ro[1] - y) / C[1];
    return [ro[0] - C[0] * t, y, ro[2] - C[2] * t];
}

// The camera that fits the board points `pts` into w x h; margins {l, r, t, b} px. Whole-pixel origin. A scene lists the points that must be in view
// (the board's eight corners and whatever stands above it: silicon adds `holoTop` mm of headroom over its two hologram anchors).
function fitPoints(pts, w, h, margins) {
    var m = margins || { l: 12, r: 12, t: 12, b: 12 };
    var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    pts.forEach(function (p) {
        var x = dot(p, R), y = -dot(p, U);
        minX = Math.min(minX, x); maxX = Math.max(maxX, x);
        minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    });
    var s = Math.min((w - m.l - m.r) / (maxX - minX), (h - m.t - m.b) / (maxY - minY));
    var ox = m.l + ((w - m.l - m.r) - s * (maxX - minX)) / 2 - s * minX;
    var oy = m.t + ((h - m.t - m.b) - s * (maxY - minY)) / 2 - s * minY;
    return { s: s, ox: Math.round(ox), oy: Math.round(oy) };
}

// the eight corners of a box { x0, x1, y0, y1, z0, z1 } (the board's: G.BOARD), as board points
function boxCorners(B) {
    var pts = [];
    var xs = [B.x0, B.x1], ys = [B.y0, B.y1], zs = [B.z0, B.z1];
    for (var i = 0; i < 2; i++)
        for (var j = 0; j < 2; j++)
            for (var k = 0; k < 2; k++)
                pts.push([xs[i], ys[j], zs[k]]);
    return pts;
}

// The whole-px item rect (padded `pad` px, default 4) that holds board points `pts` as the camera sees them: a live patch's quad is such a rect over everything the
// part it repaints can reach (its footprint, its highest lift, the shadow it casts from there).
function projectedRect(pts, cam, pad) {
    var p = pad === undefined ? 4 : pad;
    var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    pts.forEach(function (pt) {
        var q = project(pt, cam);
        minX = Math.min(minX, q.x); maxX = Math.max(maxX, q.x);
        minY = Math.min(minY, q.y); maxY = Math.max(maxY, q.y);
    });
    var x0 = Math.floor(minX - p), y0 = Math.floor(minY - p);
    return { x: x0, y: y0, w: Math.ceil(maxX + p) - x0, h: Math.ceil(maxY + p) - y0 };
}

// The upright hologram plane over an anchor: faces the viewer (its normal is C's ground part),
// `w` mm wide, from `base` to `base + h` mm above the anchor. Item px rect (whole px, padded)
// and the plane's own basis, for the holo shader.
function holoRect(anchor, cam, w, base, h, pad, lens, ink) {
    var p = pad === undefined ? 6 : pad;
    var u = [0.70710678, 0, -0.70710678];
    var corners = [[-w / 2, base], [w / 2, base], [w / 2, base + h], [-w / 2, base + h]];
    var minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    corners.forEach(function (c) {
        var q = project([anchor[0] + u[0] * c[0], anchor[1] + c[1], anchor[2] + u[2] * c[0]], cam);
        minX = Math.min(minX, q.x); maxX = Math.max(maxX, q.x);
        minY = Math.min(minY, q.y); maxY = Math.max(maxY, q.y);
    });
    var base0 = project(anchor, cam);
    // include the anchor itself: the projector beam runs from it to the plane
    minY = Math.min(minY, base0.y); maxY = Math.max(maxY, base0.y);
    // and the lens on it: a disc and a ring of `lens` mm lying on the board (G.LENS, via lensReach), whose near half
    // hangs BELOW the anchor by 0.577 of its radius in screen px -- more than a flat pad once the scene is zoomed
    // (a flat pad cuts the CPU's blue ring along the rect's foot at 2x, never at 1x)
    if (lens) {
        var e = circleExtent(anchor, lens, cam);
        minX = Math.min(minX, e.x0); maxX = Math.max(maxX, e.x1);
        minY = Math.min(minY, e.y0); maxY = Math.max(maxY, e.y1);
    }
    // and the projector's haze, which is light and reaches past the plane (CONE_INK, in screen mm about the anchor: mm x scale, never a flat pad)
    if (ink) {
        minX = Math.min(minX, base0.x - ink.side * cam.s); maxX = Math.max(maxX, base0.x + ink.side * cam.s);
        minY = Math.min(minY, base0.y - ink.up * cam.s); maxY = Math.max(maxY, base0.y + ink.down * cam.s);
    }
    var x0 = Math.floor(minX - p), y0 = Math.floor(minY - p);
    return { x: x0, y: y0, w: Math.ceil(maxX + p) - x0, h: Math.ceil(maxY + p) - y0 };
}

// The screen ellipse of a horizontal circle of radius `r` mm about board point `p` (the isometric camera
// foreshortens a ground circle to |U_xz| = 0.577 of its width): its four extremes, as {x0, y0, x1, y1} px.
function circleExtent(p, r, cam) {
    var c = project(p, cam), ry = r * cam.s * Math.sqrt(U[0] * U[0] + U[2] * U[2]);
    return { x0: c.x - r * cam.s, y0: c.y - ry, x1: c.x + r * cam.s, y1: c.y + ry };
}

// Ray-cast the parts a click can mean: the camera's ray (from 600 mm up it, toward the board) against every part's box. Each part lives in its group's frame
// (the package turned and lifted, the card lifted out ...): `frameOf(part, o, d)` moves the ray into it -- it may change the arrays `o` (origin) and `d`
// (direction) in place -- and answers false to leave the part out (a plug that is not there). Returns the nearest part's name, or "".
function pickBoxes(parts, cam, px, py, frameOf) {
    var sx = (px - cam.ox) / cam.s, sy = (cam.oy - py) / cam.s;
    var ro = [sx * R[0] + sy * U[0] + C[0] * 600, sx * R[1] + sy * U[1] + C[1] * 600, sx * R[2] + sy * U[2] + C[2] * 600];
    var rd = [-C[0], -C[1], -C[2]];
    var best = 1e9, name = "";
    parts.forEach(function (p) {
        var o = ro.slice(), d = rd.slice();
        if (frameOf && frameOf(p, o, d) === false)
            return;
        var tn = -1e9, tf = 1e9;
        for (var k = 0; k < 3; k++) {
            var inv = 1 / d[k];
            var t1 = (p.min[k] - o[k]) * inv, t2 = (p.max[k] - o[k]) * inv;
            tn = Math.max(tn, Math.min(t1, t2));
            tf = Math.min(tf, Math.max(t1, t2));
        }
        if (tn <= tf && tn > 0 && tn < best) {
            best = tn;
            name = p.name;
        }
    });
    return name;
}

// The light, tuned the way the shell's other lit objects are (Lighting.js: an angle that sweeps
// the lamp around the view, 0 from the right, 90 from above, and an elevation toward the eye),
// turned into board space. Fixed in VIEW space.
function lightDir(angleDeg, elevation) {
    var e = Math.max(-0.999, Math.min(0.999, elevation));
    var r = Math.sqrt(Math.max(0, 1 - e * e));
    var a = angleDeg * Math.PI / 180;
    var vx = Math.cos(a) * r, vy = Math.sin(a) * r, vz = e;
    return [vx * R[0] + vy * U[0] + vz * C[0], vx * R[1] + vy * U[1] + vz * C[1], vx * R[2] + vy * U[2] + vz * C[2]];
}
