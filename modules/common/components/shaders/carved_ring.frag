#version 440

// =============================================================================
// carved_ring.frag
//
// A groove carved in a circle: the Workspaces groove (CarvedPath.js), bent
// round -- the same bands by depth, the same easings, the same colours:
//
//   depth < -bevelWidth            transparent
//   -bevelWidth <= depth < 0       surface -> bevel     (the rim outside)
//   0 <= depth < shadowWidth       shadow  -> core      (the inset shadow)
//   depth >= shadowWidth           core
//
// where depth is the distance INTO the groove from its edge. The groove is
// the union of four round-capped arc capsules centred at W, N, E and S (the
// clock's loop order, clockwise from the left: the bar's left line, upper
// track, right line, lower track). `gapDeg` opens a gap between them; at 0
// each arc spans its full quarter, the union is exactly an annulus, and
// there is no seam where two arcs meet (inside its own span an arc's
// distance is the ring's, and a cap never reaches below it).
//
// FILLS recolour the core and the inset shadow only -- the rim outside is
// the same in every palette, which is what makes a fill read as the same
// carve in another colour. Two tones (A under B), four slots each; a slot is
// an angular span [start, end] in degrees clockwise from 12 o'clock, any
// unwrapped values, and BOTH its ends are convex heads: ellipses
// `bulge * halfWidth` deep along the groove and `halfWidth` across, their
// tips exactly on `start` and `end`. A slot with end <= start is empty; one
// of 360 or more is the whole ring.
//
// A slot is measured in the frame of the GAP between its two tips (the
// stretch it does not cover), as the union of two parts: everything up to
// the end cap, and everything from the start cap on. Each part is bounded
// along the groove by its cap alone, and across by the carve -- so there is
// no seam where a cap begins (bounding the span along the groove only leaves
// a half-covered pixel row at the cap's base, which reads as a line across
// the fill). The union is SMOOTH (`mergeK`): as a fill comes
// round to its own start, the two caps reach for each other and a neck
// forms between them, the gap closes as a liquid would, and at 360 the
// ring is whole -- with no pop, because the smooth union already covers the
// last notch before the switch.
//
// Uniforms are all named; nothing is an array indexed by a loop counter (an
// indexed local array spills on this GPU -- CLAUDE.md, the gooey field).
// The pixel size is taken from a LINEAR coordinate. Edges antialias the way
// the canvas groove's strokes do, centred on the edge -- that is the carve
// this has to match, and the outermost colour
// is the surface's own, so the half pixel outside the rim shows nothing.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    float itemW;
    float itemH;
    float ringRadius;      // centreline radius, px
    float halfWidth;       // half the groove's width at its edge (depth 0)
    float bevelWidth;
    float shadowWidth;
    float gapDeg;          // gap between the four arcs, degrees
    float bulge;           // fill head depth, as a fraction of halfWidth
    float mergeK;          // smooth-union radius where a fill meets its own start, px
    float bevelStrength;   // 0..1: how far the rim reaches from the ground to the bevel colour

    vec4  surfaceColor;
    vec4  bevelColor;
    vec4  shadowColor;
    vec4  coreColor;
    vec4  bevelEasing;
    vec4  shadowEasing;

    vec4  aCore;
    vec4  aShadow;
    vec4  bCore;
    vec4  bShadow;
    vec4  aStart;          // four slots of tone A: start angles (deg)
    vec4  aEnd;            //                        end angles (deg)
    vec4  bStart;
    vec4  bEnd;
};

const float PI = 3.14159265358979;

float ease(float x, vec4 e) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    float t = x;
    for (int i = 0; i < 8; i++) {
        float mt = 1.0 - t;
        float bx  = 3.0 * mt * mt * t * e.x + 3.0 * mt * t * t * e.z + t * t * t;
        float dbx = 3.0 * mt * mt * e.x + 6.0 * mt * t * (e.z - e.x) + 3.0 * t * t * (1.0 - e.z);
        if (abs(dbx) < 1e-6) break;
        float dt = (bx - x) / dbx;
        t -= dt;
        if (abs(dt) < 1e-5) break;
    }
    t = clamp(t, 0.0, 1.0);
    float mt = 1.0 - t;
    return 3.0 * mt * mt * t * e.y + 3.0 * mt * t * t * e.w + t * t * t;
}

// Angle of p (relative to the centre) in degrees clockwise from 12 o'clock,
// in (-180, 180].
float clockAngle(vec2 c) {
    return degrees(atan(c.x, -c.y));
}

// `a` unwrapped to within 180 of `ref`.
float near(float a, float ref) {
    return a - 360.0 * floor((a - ref + 180.0) / 360.0);
}

// Signed distance to one round-capped arc of the centreline (negative
// inside the groove), centred at `mid` degrees, half-span `halfSpan` degrees.
float arcDist(vec2 c, float r, float ang, float mid, float halfSpan) {
    float a = near(ang, mid);
    if (abs(a - mid) <= halfSpan)
        return abs(r - ringRadius) - halfWidth;
    float endA = radians(mid + sign(a - mid) * halfSpan);
    vec2 e = ringRadius * vec2(sin(endA), -cos(endA));
    return length(c - e) - halfWidth;
}

// Polynomial smooth minimum: min(a, b), rounded over a band of width k.
float smin(float a, float b, float k) {
    if (k <= 0.0)
        return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// One part of a slot, bounded along the groove by a cap: `t` is how far past
// the cap's BASE the point is (px, > 0 beyond it), `v` its offset across the
// centreline. Beyond the base, an ellipse `depth` deep and `ry` across;
// behind it, only the across bound (`ry` lies outside the carve's core, so
// the carve is what really bounds a fill's sides).
float capDist(float t, float v, float depth, float ry) {
    if (t <= 0.0 || depth <= 0.001)
        return t <= 0.0 ? abs(v) - ry : max(t, abs(v) - ry);
    vec2 ab = vec2(depth, ry);
    return (length(vec2(t, v) / ab) - 1.0) * min(ab.x, ab.y);
}

// Signed distance to a fill slot (negative inside), see the header.
float slotDist(float ang, float v, float s, float e, float aa) {
    float span = e - s;
    if (span <= 0.0)
        return 1e6;
    if (span >= 360.0)
        return -1e6;
    float k = PI / 180.0 * ringRadius;          // px per degree
    float depth = bulge * halfWidth;
    float ry = halfWidth + 1.5 * aa;
    // The frame: centred on the gap, so the end tip is below its centre and
    // the start tip (one turn on) above it; the frame's seam is the span's
    // middle, where one part is deep inside and the other far outside.
    float gc = e + 0.5 * (360.0 - span);
    float a = near(ang, gc);
    float dEnd = capDist((a - e) * k + depth, v, depth, ry);
    float dStart = capDist((s + 360.0 - a) * k + depth, v, depth, ry);
    return smin(dEnd, dStart, mergeK);
}

float slotCover(float ang, float v, float s, float e, float aa) {
    float d = slotDist(ang, v, s, e, aa);
    return 1.0 - smoothstep(-0.5 * aa, 0.5 * aa, d);
}

void main() {
    vec2 pos = qt_TexCoord0 * vec2(itemW, itemH);
    vec2 c = pos - 0.5 * vec2(itemW, itemH);
    float r = length(c);
    float ang = clockAngle(c);

    // One device pixel in item units, from a linear coordinate.
    float aa = max(length(vec2(dFdx(pos.x), dFdy(pos.x))), 1e-4);

    float span = 45.0 - 0.5 * gapDeg;
    float dist = min(min(arcDist(c, r, ang, 270.0, span), arcDist(c, r, ang, 0.0, span)),
                     min(arcDist(c, r, ang, 90.0, span), arcDist(c, r, ang, 180.0, span)));
    float depth = -dist;

    // The rim's outer edge.
    float cov = smoothstep(-bevelWidth - 0.5 * aa, -bevelWidth + 0.5 * aa, depth);
    if (cov <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    // Fill coverage per tone; B draws over A.
    float v = r - ringRadius;
    float mA = max(max(slotCover(ang, v, aStart.x, aEnd.x, aa), slotCover(ang, v, aStart.y, aEnd.y, aa)),
                   max(slotCover(ang, v, aStart.z, aEnd.z, aa), slotCover(ang, v, aStart.w, aEnd.w, aa)));
    float mB = max(max(slotCover(ang, v, bStart.x, bEnd.x, aa), slotCover(ang, v, bStart.y, bEnd.y, aa)),
                   max(slotCover(ang, v, bStart.z, bEnd.z, aa), slotCover(ang, v, bStart.w, bEnd.w, aa)));
    vec4 core = mix(mix(coreColor, aCore, mA), bCore, mB);
    vec4 shadow = mix(mix(shadowColor, aShadow, mA), bShadow, mB);

    // Bands.
    float fb = ease(clamp((depth + bevelWidth) / max(bevelWidth, 1e-3), 0.0, 1.0), bevelEasing);
    vec4 bevel = mix(surfaceColor, bevelColor, fb * bevelStrength);
    float fs = ease(clamp(depth / max(shadowWidth, 1e-3), 0.0, 1.0), shadowEasing);
    vec4 inner = mix(shadow, core, fs);
    float seam = smoothstep(-0.5 * aa, 0.5 * aa, depth);
    vec4 col = mix(bevel, inner, seam);

    fragColor = col * cov * qt_Opacity;
}
