.pragma library

// =============================================================================
// GlyphOutline.js -- a bar glyph's font outline as data a flourish can pose (PosedGlyph draws what this returns).
//
// A glyph's parts are checked in as contours in FONT UNITS (y up, the pen on the baseline at x = 0), made from the installed
// font by tools/dev/flourish_parts.py: a contour is a list of ["M",x,y] ["L",x,y] ["Q",cx,cy,x,y] segments. A pose moves each
// part with a function [x, y] -> [x, y] in font units, and `emit` writes the moved contours as ONE SVG path in the glyph's
// pixels, from the pen origin (ox, oy) the Text puts the glyph at, k px per font unit. A part keeps its holes (a contour wound
// the other way): one part, one path, so a hole stays a hole under the winding rule.
//
// The easings are the motion's own (a pose is a pure function of its clock): each takes 0..1 and returns the eased value.
// =============================================================================

function clamp01(x) {
    return x < 0 ? 0 : (x > 1 ? 1 : x);
}
// 0..1 across [a, b]
function seg(x, a, b) {
    return clamp01((x - a) / (b - a));
}
function smooth(a, b, x) {
    const t = seg(x, a, b);
    return t * t * (3 - 2 * t);
}
function outCubic(x) {
    const t = 1 - clamp01(x);
    return 1 - t * t * t;
}
function inQuad(x) {
    const t = clamp01(x);
    return t * t;
}
function outQuad(x) {
    const t = clamp01(x);
    return t * (2 - t);
}
// Qt's InOutQuad
function inOutQuad(x) {
    const t = clamp01(x);
    return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
}
function inCubic(x) {
    const t = clamp01(x);
    return t * t * t;
}
// overshoots by about 10 % at s = 1.70158 (Qt's OutBack), more with s
function outBack(x, s) {
    const t = clamp01(x) - 1;
    return 1 + t * t * ((s + 1) * t + s);
}

// a turn of (x, y) about (cx, cy) by `a` radians, counter-clockwise in font space (y up)
function turn(x, y, cx, cy, a) {
    const c = Math.cos(a), s = Math.sin(a), dx = x - cx, dy = y - cy;
    return [cx + c * dx - s * dy, cy + s * dx + c * dy];
}

function same(x, y) {
    return [x, y];
}

// `contours` through `fn` into one SVG path string in px (y down): k px per font unit, the pen origin at (ox, oy)
function emit(contours, fn, k, ox, oy) {
    let d = "";
    for (let i = 0; i < contours.length; ++i) {
        const c = contours[i];
        for (let j = 0; j < c.length; ++j) {
            const sg = c[j];
            let n = "";
            for (let m = 1; m < sg.length; m += 2) {
                const p = fn(sg[m], sg[m + 1]);
                n += " " + (ox + p[0] * k).toFixed(3) + " " + (oy - p[1] * k).toFixed(3);
            }
            d += sg[0] + n;
        }
        d += " Z ";
    }
    return d;
}

// A polygon ([[x, y], ...], font units) as one contour of line segments
function polygon(pts) {
    const c = [["M", pts[0][0], pts[0][1]]];
    for (let i = 1; i < pts.length; ++i)
        c.push(["L", pts[i][0], pts[i][1]]);
    return c;
}

// The part of a convex polygon at or above the line y = yc (Sutherland-Hodgman against one edge): what shows above a rim.
function clipAbove(pts, yc) {
    const out = [];
    for (let i = 0; i < pts.length; ++i) {
        const a = pts[i], b = pts[(i + 1) % pts.length];
        const ina = a[1] >= yc, inb = b[1] >= yc;
        if (ina)
            out.push(a);
        if (ina !== inb) {
            const f = (yc - a[1]) / (b[1] - a[1]);
            out.push([a[0] + (b[0] - a[0]) * f, yc]);
        }
    }
    return out;
}

// A rounded rectangle as a polygon (each corner three chords: at a glyph's size a corner is under a pixel), wound like the
// font's outer contours (clockwise, y up) or, `hole`, the other way.
function roundRect(x0, y0, x1, y1, r, hole) {
    const pts = [];
    const corner = (cx, cy, a0) => {
        for (let i = 0; i <= 3; ++i) {
            const a = (a0 - 30 * i) * Math.PI / 180;
            pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
        }
    };
    // clockwise from the top-left corner's top: top-right, bottom-right, bottom-left, top-left
    corner(x1 - r, y1 - r, 90);
    corner(x1 - r, y0 + r, 0);
    corner(x0 + r, y0 + r, -90);
    corner(x0 + r, y1 - r, -180);
    return hole ? pts.reverse() : pts;
}
