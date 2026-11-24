// =============================================================================
// CarvedPath.js
//
// The shell's carved groove, painted on a Canvas: many concentric strokes from
// the outer bevel inwards, each one a ring of the carve at depth `d` -- the
// light rim outside the edge (d < 0), the inset shadow inside it (0 <= d < sw)
// and the core after that. Whatever the path is, the line and the dots on it
// union into one carved shape with a continuous inset shadow and no seam,
// because every ring of every piece is drawn before the next ring inwards.
//
// Workspaces and GrooveTrack both paint with it, so they paint the same
// pixels, float operation for float operation.
//
// Not `.pragma library`: Qt.rgba lives on the QML global object, which a
// shared library context does not have (Mix.js says the same).
// =============================================================================

// CSS cubic-bezier(x1, y1, x2, y2) easing evaluated at x, Newton's method on
// the x polynomial. `easing` is [x1, y1, x2, y2].
function ease(x, easing) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
        let t2 = t * t;
        let mt = 1 - t;
        let mt2 = mt * mt;
        let bx = 3 * mt2 * t * easing[0] + 3 * mt * t2 * easing[2] + t2 * t;
        let dbx = 3 * mt2 * easing[0] + 6 * mt * t * (easing[2] - easing[0]) + 3 * t2 * (1 - easing[2]);
        if (Math.abs(dbx) < 1e-6) break;
        let dt = (bx - x) / dbx;
        t -= dt;
        if (Math.abs(dt) < 1e-5) break;
    }
    t = Math.max(0, Math.min(1, t));
    let t2 = t * t;
    let mt = 1 - t;
    let mt2 = mt * mt;
    return 3 * mt2 * t * easing[1] + 3 * mt * t2 * easing[3] + t2 * t;
}

function lerpColor(c1, c2, f) {
    return Qt.rgba(
        c1.r + (c2.r - c1.r) * f,
        c1.g + (c2.g - c1.g) * f,
        c1.b + (c2.b - c1.b) * f,
        c1.a + (c2.a - c1.a) * f
    );
}

// The depths of the rings, outermost first: the bevel's outer edge, then
// every quarter pixel down to the end of the inset shadow.
function ringDs(bw, sw) {
    let step = 0.25;
    let dVals = [];
    dVals.push(-bw);
    for (let d = -bw + step; d <= sw; d += step) {
        dVals.push(d);
    }
    if (dVals[dVals.length - 1] < sw - 0.01) {
        dVals.push(sw);
    }
    return dVals;
}

// The colour of the ring at depth d.
//   pal: { surface, bevel, shadow, core, bevelEasing, shadowEasing }
function ringColor(d, bw, sw, pal) {
    if (d < 0) {
        let f = Math.max(0, Math.min(1, (d + bw) / Math.max(0.001, bw)));
        f = ease(f, pal.bevelEasing);
        return lerpColor(pal.surface, pal.bevel, f);
    } else if (d < sw) {
        let f = Math.max(0, Math.min(1, d / Math.max(0.001, sw)));
        f = ease(f, pal.shadowEasing);
        return lerpColor(pal.shadow, pal.core, f);
    }
    return pal.core;
}

// Paints the carve. For every ring, outermost first, it sets the ring's
// colour as both fill and stroke style and calls
//     trace(ctx, rLine, rDot)
// where rLine / rDot are that ring's half-width for the line and radius for a
// dot (either may be 0: skip it). The caller strokes and fills its own path:
// the order of the canvas calls is the caller's, so each module paints exactly
// the pixels its own order gives.
//   g: { bw, sw, halfLine, halfDot }
function paintCarve(ctx, g, pal, trace) {
    let dVals = ringDs(g.bw, g.sw);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    for (let i = 0; i < dVals.length; i++) {
        let d = dVals[i];
        let color = ringColor(d, g.bw, g.sw, pal);
        let rLine = Math.max(0, g.halfLine - d);
        let rDot = Math.max(0, g.halfDot - d);
        if (rLine <= 0 && rDot <= 0) continue;
        ctx.fillStyle = color;
        ctx.strokeStyle = color;
        trace(ctx, rLine, rDot);
    }
}
