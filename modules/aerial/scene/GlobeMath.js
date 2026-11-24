.pragma library

.import "../../common/board/IsoCore.js" as Core

// =============================================================================
// GlobeMath.js -- the globe's arithmetic, ONE copy for the lights, the picking and the probe; globe.frag does the same by itself (the probe's marker holds the two to each
// other). No Qt here: it runs under node. The sphere's polar axis is the board's y; the globe's own frame (local) has x east, y north, z toward longitude 0; the world is
// Ry(theta) of it, theta = 45 deg + turn, so longitude 0 faces the viewer at turn 0 and east runs to the right of the picture.
// =============================================================================

var R = Core.R;
var U = Core.U;
var C = Core.C;
var DEG = Math.PI / 180;
// +1: east is to the right (the probe's `lonflip` arm makes it -1)
var LON_SIGN = 1;

// where the globe stands (mm): over the lens cap with a gap for the beam
var GAP = 3.2;
var RADIUS_SHARE = 0.9;          // the sphere's radius as a share of LENS.globe

// THE SIZE, against what the user saw: the globe's radius ON SCREEN in round 1 (its mm size under round 1's camera, 4.58 px/mm at the popup's 760 design px: 41 px) is the unit. At rest it
// stands REST_SHARE (1.3) of that, while used it grows to GROWN_OVER_REST (2) times its rest size, into the air. Neither follows the camera's zoom (round 2 zoomed the card 1.7x; the globe
// stayed the size the user asked for), so the factors on the mm radius are derived from the camera's scale. The sphere stands on its beam over the lens and GROWS FROM ITS FOOT (the
// lens-side point stays, the centre rises with the radius): a growing globe takes the air over it and shoves nothing.
var ROUND1_PX_PER_MM = 4.58, REST_SHARE = 1.3, GROWN_OVER_REST = 2.0;
function restOf(cam) {
    return REST_SHARE * ROUND1_PX_PER_MM / Math.max(cam.s, 1e-3);
}
function grownOf(cam) {
    return restOf(cam) * GROWN_OVER_REST;
}
// the tilt: the largest angle (rad) of the vertical swipe's second state. At 60 deg the south pole leans toward the viewer by 25 deg and the north pole, up on the screen, is just behind
// the rim: never upside down. 
var TILT_MAX = 60 * DEG;
function radiusMm(G, f) {
    return G.LENS.globe * RADIUS_SHARE * (f === undefined ? 1 : f);
}
function centreMm(G, f) {
    var A = G.ANCHORS.globe;
    return [A[0], A[1] + GAP + radiusMm(G, f), A[2]];
}
// the globe's place on the item: centre px, radius px, and the lens cap's px
function frameOf(G, cam, f) {
    var c = Core.project(centreMm(G, f), cam);
    var lens = Core.project(G.ANCHORS.globe, cam);
    return { cx: c.x, cy: c.y, rp: radiusMm(G, f) * cam.s, lensX: lens.x, lensY: lens.y };
}
// the largest factor <= f (and at least `lo`) whose rim stays `margin` px under the item's top edge (the popup's own edge): the top of the sphere is linear in f
function fitFactor(G, cam, f, margin, lo) {
    var a = frameOf(G, cam, 0), b = frameOf(G, cam, 1);
    var slope = (b.cy - b.rp) - (a.cy - a.rp);       // px the top edge moves up (negative) per unit of f
    if (slope >= -1e-6)
        return f;
    var fMax = (margin - (a.cy - a.rp)) / slope;
    return Math.max(lo === undefined ? 0 : lo, Math.min(f, fMax));
}
function dirOf(lat, lon) {
    var la = lat * DEG, lo = LON_SIGN * lon * DEG, cl = Math.cos(la);
    return [cl * Math.sin(lo), Math.sin(la), cl * Math.cos(lo)];
}
function toWorld(v, turn) {
    var th = Math.PI / 4 + turn, cs = Math.cos(th), sn = Math.sin(th);
    return [v[0] * cs + v[2] * sn, v[1], -v[0] * sn + v[2] * cs];
}
// the tilt (rad) of the whole sphere about the camera's right axis; positive leans the north pole away from the viewer (globe.frag rotR is the same arithmetic)
function tilt(v, a) {
    if (!a)
        return v;
    var c = Math.cos(a), s = Math.sin(a), d = Core.dot(R, v);
    var x = [R[1] * v[2] - R[2] * v[1], R[2] * v[0] - R[0] * v[2], R[0] * v[1] - R[1] * v[0]];
    return [v[0] * c - x[0] * s + R[0] * d * (1 - c), v[1] * c - x[1] * s + R[1] * d * (1 - c), v[2] * c - x[2] * s + R[2] * d * (1 - c)];
}
// a point of the sphere -> item px; depth > 0 is the visible hemisphere
function project(fr, lat, lon, turn, tiltRad) {
    var w = tilt(toWorld(dirOf(lat, lon), turn), tiltRad);
    return { x: fr.cx + fr.rp * Core.dot(w, R), y: fr.cy - fr.rp * Core.dot(w, U), depth: Core.dot(w, C) };
}
// the light of a "fastest" server: just under the sphere, on the beam
function footPoint(G, cam) {
    var A = G.ANCHORS.globe, p = Core.project([A[0], A[1] + GAP * 0.55, A[2]], cam);
    return { x: p.x, y: p.y };
}
// a light's size (design px) by its server count against the largest
function sizeOf(servers, maxServers) {
    return 2.2 + 2.6 * Math.sqrt(Math.max(0, servers) / Math.max(1, maxServers));
}
