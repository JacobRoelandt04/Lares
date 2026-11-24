.pragma library
.import "IsoCore.js" as Core

// =============================================================================
// BoardLayout.js -- where a board popup's flat overlays and its zones are, from the SAME camera and the SAME geometry the scene draws with: a caption
// follows its zone because it is placed at a projected board point, never at a number of its own. The board toolkit's helpers; a scene's own layout
// file (silicon's PopupLayout.js) says which zones it has, what a click on a part means and where each part's secondary hangs from.
// Pure, no Qt.
//
//   proj(cam, p)                         a board point [x, y, z] in item px, as [x, y]
//   poly(cam, pts)                       board points as a polygon in item px
//   rectPoly(r, pad)                     an item rect { x, y, w, h } as a polygon, grown by pad
//   footprint(cam, x0, z0, x1, z1, y)    a rectangle on the board's ground (or at height y), as a polygon in item px
//   anchorPx(G, cam, name)               a geometry anchor (G.ANCHORS[name]) in item px
//   inPoly(poly, x, y) / inRegion(polys, x, y)   a point in a CONVEX polygon (either winding) / in any of several
//   zoneAt(regions, x, y, order)         the first zone of `order` (a list of names, `regions`' keys) whose polygons hold the point, or ""
//   groupOf(G, name)                     the group of the part called `name` ("" if none)
//   partBox(G, cam, name)                a part's projected bounding box { x, y, w, h } in item px, or null
//   convexHull(pts)                      the hull of item-px points [x, y]
//
// A ZONE is the part of the popup its swipe and its arrows belong to: the footprint of what it holds on the board, the hologram's plane above it and its
// name plate; a part of no zone is a swipe that does nothing.
// =============================================================================

function proj(cam, p) {
    var q = Core.project(p, cam);
    return [q.x, q.y];
}

function poly(cam, pts) {
    return pts.map(function (p) { return proj(cam, p); });
}

function rectPoly(r, pad) {
    return [[r.x - pad, r.y - pad], [r.x + r.w + pad, r.y - pad], [r.x + r.w + pad, r.y + r.h + pad], [r.x - pad, r.y + r.h + pad]];
}

function footprint(cam, x0, z0, x1, z1, y) {
    return poly(cam, [[x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1]]);
}

function anchorPx(G, cam, name) {
    return proj(cam, G.ANCHORS[name]);
}

// A point is inside a CONVEX polygon (either winding) when it is on one side of every edge.
function inPoly(polygon, x, y) {
    var pos = false, neg = false;
    for (var i = 0; i < polygon.length; i++) {
        var a = polygon[i], b = polygon[(i + 1) % polygon.length];
        var c = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
        if (c > 0)
            pos = true;
        else if (c < 0)
            neg = true;
        if (pos && neg)
            return false;
    }
    return true;
}

function inRegion(polys, x, y) {
    for (var i = 0; i < polys.length; i++) {
        if (inPoly(polys[i], x, y))
            return true;
    }
    return false;
}

function zoneAt(regions, x, y, order) {
    for (var i = 0; i < order.length; i++) {
        if (inRegion(regions[order[i]], x, y))
            return order[i];
    }
    return "";
}

function groupOf(G, name) {
    for (var i = 0; i < G.PARTS.length; i++) {
        if (G.PARTS[i].name === name)
            return G.PARTS[i].group;
    }
    return "";
}

// A board part's bounding box as the camera sees it, item px -- what a hover tip anchors to. null when the geometry has
// no part of that name.
function partBox(G, cam, name) {
    for (var i = 0; i < G.PARTS.length; i++) {
        var p = G.PARTS[i];
        if (p.name !== name)
            continue;
        var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (var k = 0; k < 8; k++) {
            var q = proj(cam, [k & 1 ? p.max[0] : p.min[0], k & 2 ? p.max[1] : p.min[1], k & 4 ? p.max[2] : p.min[2]]);
            x0 = Math.min(x0, q[0]);
            y0 = Math.min(y0, q[1]);
            x1 = Math.max(x1, q[0]);
            y1 = Math.max(y1, q[1]);
        }
        return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }
    return null;
}

function convexHull(pts) {
    var p = pts.slice().sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
    var cross = function (o, a, b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); };
    var lo = [], up = [], i;
    for (i = 0; i < p.length; i++) {
        while (lo.length >= 2 && cross(lo[lo.length - 2], lo[lo.length - 1], p[i]) <= 0)
            lo.pop();
        lo.push(p[i]);
    }
    for (i = p.length - 1; i >= 0; i--) {
        while (up.length >= 2 && cross(up[up.length - 2], up[up.length - 1], p[i]) <= 0)
            up.pop();
        up.push(p[i]);
    }
    lo.pop();
    up.pop();
    return lo.concat(up);
}
