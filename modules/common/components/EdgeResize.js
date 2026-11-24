.pragma library

// =============================================================================
// EdgeResize.js -- a popup resized by one of its free edges, like a window:
// the grabbed edge follows the pointer, the opposite edge stays where it is.
//
// Everything is in the bar's SCREEN axes: `along` is x on a top/bottom bar
// and y on a left/right bar; `out` is the popup's extent away from the bar
// face. The host reports its room (GooeyEngine `hostRoom`):
//   { edge, center, lo, hi, out, a0, a1, wallLo, wallHi, snap, restAt }
// center -- where the popup's centre sits with no shift; lo/hi -- the usable
// limits along the bar; out -- the most it may extend from the face; a0/a1 --
// the box's ACTUAL along edges (the host may have clamped it at an end, or
// moved it flush against a wall or onto its bar's end); wallLo/wallHi/snap --
// whether a bar stands at lo / hi and how near it a box is put against it
// (wallSnap). Where the host will REST a box is the host's to say
// (`room.restAt(along, shift)`): nothing here mirrors its placement.
// The popup is described by its along size, out size and `shift` (its centre
// minus `center`), and the result keeps its box inside [lo, hi] so the host's
// clamp never has to engage mid-drag.
// =============================================================================

// The grip under a content-local point: {along: -1|0|1, out: 0|1} or null.
// Free edges: the two along edges and the far edge (opposite the bar).
function gripAt(x, y, w, h, edge, band, corner) {
    var vertical = edge === "left" || edge === "right";
    // Local coordinates rotated into (along, out-from-face).
    var a = vertical ? y : x;
    var A = vertical ? h : w;
    var o;
    var O = vertical ? w : h;
    if (edge === "top") o = y;
    else if (edge === "bottom") o = h - y;
    else if (edge === "left") o = x;
    else o = w - x;
    var nearFar = o >= O - band;
    var nearFarCorner = o >= O - corner;
    var nearLo = a <= band, nearHi = a >= A - band;
    var nearLoC = a <= corner, nearHiC = a >= A - corner;
    if (nearFarCorner && nearLoC) return { along: -1, out: 1 };
    if (nearFarCorner && nearHiC) return { along: 1, out: 1 };
    if (nearFar) return { along: 0, out: 1 };
    if (nearLo && o > band) return { along: -1, out: 0 };
    if (nearHi && o > band) return { along: 1, out: 0 };
    return null;
}

// The cursor for a grip, by NAME ("ver" | "hor" | "bdiag" | "fdiag" | ""):
// a library script has no Qt enums, the QML side maps the names.
function cursorFor(g, edge) {
    if (!g) return "";
    var vertical = edge === "left" || edge === "right";
    if (g.along === 0) return vertical ? "hor" : "ver";
    if (g.out === 0) return vertical ? "ver" : "hor";
    // Which screen corner is grabbed: "/" (bottom-left, top-right) or "\".
    var corner;
    if (edge === "top") corner = g.along < 0 ? "bl" : "br";
    else if (edge === "bottom") corner = g.along < 0 ? "tl" : "tr";
    else if (edge === "left") corner = g.along < 0 ? "tr" : "br";
    else corner = g.along < 0 ? "tl" : "bl";
    return (corner === "bl" || corner === "tr") ? "bdiag" : "fdiag";
}

// Pointer travel in screen px (dx, dy) since the press -> the new size.
//   start = { along, out, a0, a1 }   (along/out sizes and the along edges at press)
//   room  = hostRoom (lo, hi, out, center)
//   lim   = { minAlong, minOut, symmetric }
// symmetric: the popup grows about its centre -- the grabbed along edge
// follows the pointer and the opposite one mirrors it, so a resize never
// moves the popup (its place is a deliberate move's: move() below). The
// edges step by whole pixels each, so the centre keeps its own phase.
// Returns { along, out, shift, a0, a1 }. The EDGES are whole pixels -- not
// the shift: an odd width centred on a rounded shift puts both edges on half
// pixels, and a box whose edge alternates between x.0 and x.5 as the width
// grows makes everything in it jitter (measured: 330.5, 330.0, 330.5 ...).
// The shift keeps whatever half pixel the whole-pixel edges need.
function apply(g, start, dx, dy, edge, room, lim) {
    var vertical = edge === "left" || edge === "right";
    var da = vertical ? dy : dx;
    var dOut;
    if (edge === "top") dOut = dy;
    else if (edge === "bottom") dOut = -dy;
    else if (edge === "left") dOut = dx;
    else dOut = -dx;
    var lo = room && isFinite(room.lo) ? room.lo : -1e9;
    var hi = room && isFinite(room.hi) ? room.hi : 1e9;
    var maxOut = room && room.out > 0 ? room.out : 1e9;
    var center = room ? room.center : 0;
    var a0 = start.a0, a1 = start.a1;
    if (lim.symmetric && g.along !== 0) {
        // the grabbed edge's travel outwards (negative: inwards), the same at both edges
        var grow = Math.round(g.along < 0 ? -da : da);
        grow = Math.max(grow, Math.ceil((lim.minAlong - (start.a1 - start.a0)) / 2));
        grow = Math.min(grow, Math.max(0, Math.floor(Math.min(start.a0 - lo, hi - start.a1))));
        a0 = start.a0 - grow;
        a1 = start.a1 + grow;
    } else if (g.along < 0)
        a0 = Math.max(lo, Math.min(start.a1 - lim.minAlong, start.a0 + da));
    else if (g.along > 0)
        a1 = Math.min(hi, Math.max(start.a0 + lim.minAlong, start.a1 + da));
    a0 = Math.round(a0);
    a1 = Math.round(a1);
    var out = start.out;
    if (g.out)
        out = Math.round(Math.max(lim.minOut, Math.min(maxOut, start.out + dOut)));
    return {
        along: a1 - a0,
        out: out,
        shift: (a0 + a1) / 2 - center,
        a0: a0,
        a1: a1
    };
}

// A deliberate move along the bar (a grip of its own): the box keeps its
// size and slides by the pointer's travel, inside [lo, hi], whole pixels.
//   start  apply()'s start; da  the pointer's travel along the bar
function move(start, da, room) {
    var lo = room && isFinite(room.lo) ? room.lo : -1e9;
    var hi = room && isFinite(room.hi) ? room.hi : 1e9;
    var center = room ? room.center : 0;
    var along = start.a1 - start.a0;
    var a0 = Math.round(Math.max(lo, Math.min(hi - along, start.a0 + da)));
    var a1 = a0 + along;
    return {
        along: along,
        out: start.out,
        shift: (a0 + a1) / 2 - center,
        a0: a0,
        a1: a1
    };
}

// THE WALL, a resize's half. The host rests a box whose end stops
// 0 < gap < snap short of a perpendicular bar flush against it by MOVING the
// box (GooeyEngine `_flushPlace`), and places a drag where it was let go -- so a
// drag released in that zone slid the whole popup by the gap, the edge the
// user held included. The drag's owner takes the gap itself instead: the
// DRAGGED along edge, released inside the zone of a wall at its own end, goes
// onto the wall -- a resize, the held edge still -- and the host then finds the
// box flush and moves nothing. The walls are the host's: `room.wallLo` /
// `room.wallHi` say a bar stands at `lo` / `hi` (lo..hi otherwise ends at the
// screen's edge, where the host snaps nothing), `room.snap` its reach; a room
// without them snaps nothing.
//   g      the grip
//   start  the drag's start (apply's `start`)
//   r      apply()'s result at the release
// Returns apply()'s shape with that edge on the wall, or null: no wall there,
// the edge outside the zone or already flush, the edge not moved (a click on
// a grip is not a resize), or a grip that moves no along edge.
function wallSnap(g, start, r, room) {
    if (!g || !start || !r || !room || !(room.snap > 0) || g.along === 0 || !isFinite(room.center))
        return null;
    var eps = 1e-6;
    var a0 = r.a0, a1 = r.a1, gap;
    if (g.along < 0) {
        gap = a0 - room.lo;
        if (room.wallLo !== true || a0 === start.a0 || !(gap > eps && gap < room.snap))
            return null;
        a0 = room.lo;
    } else {
        gap = room.hi - a1;
        if (room.wallHi !== true || a1 === start.a1 || !(gap > eps && gap < room.snap))
            return null;
        a1 = room.hi;
    }
    return {
        along: a1 - a0,
        out: r.out,
        shift: (a0 + a1) / 2 - room.center,
        a0: a0,
        a1: a1
    };
}
