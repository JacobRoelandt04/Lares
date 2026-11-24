#version 440

// =============================================================================
// shadow_box.frag
//
// Draws a ShadowBox: a rounded box with an outward bevel and an inward inset
// shadow, from a signed distance field, one fragment at a time.
//
// A Canvas painting the same thing as ~25 concentric filled rings has three
// costs the SDF does not: every repaint runs on the CPU (and, in Cooperative
// mode, on the render thread inside the frame); the result is a texture at
// item resolution, so it goes soft under any scale transform and its ring
// strokes over-accumulate on curved corners; and a newly created canvas can be
// presented before its first paint has landed.
//
// Bands, by depth (px inward from the box edge; negative is outside):
//
//   depth < -bevelWidth            transparent
//   -bevelWidth <= depth < 0       surface -> bevel     (outward rim)
//   0 <= depth < shadowWidth       shadow  -> background (inset), tinted
//   depth >= shadowWidth           background
//
// Inside the shadow band the remaining strength is
//     edgeAlpha * (1 - ease(depth / shadowWidth)) ^ falloff
// so at edgeAlpha = 1, falloff = 1 it is the unmodified easing curve.
//
// The tint: left of `boundaryX` the shadow starts from `progressColor`
// instead of `shadowColor`, crossing over inside a feather of +-featherHalf.
// Only which colour the falloff starts from changes, so the carve reads the
// same on both sides.
//
// WITH A TAIL (`hasTail` = 1) the tint is a BAND instead of a fill: it starts
// at `tailX` and ends at `boundaryX`, both crossings the same feather wide.
// That is what a box says while it is working on something whose progress
// nobody can report -- a language model writing a tool call -- where a fill
// would have to be cut back to nothing every time it reached the end. A
// determinate fraction keeps the fill: supplying no tail draws the fill alone.
//
// This file draws whatever the two boundaries say, on the frame it is told,
// and it has no notion of a state. The consequence belongs to whoever hands
// it the numbers: BOTH EDGES AND THE COLOUR MAY ONLY BE SWAPPED ON A FRAME
// WHERE NOTHING IS PAINTED, because a boundary that moves 375 px between two
// frames is 375 px of colour appearing or vanishing in 16 ms. ShadowBox's
// `shadowProgressMinPx` is where that goes wrong most easily: it is a floor
// under `boundaryX`, i.e. a RESTING mark, and a host that leaves it in place
// while a band runs paints the mark's whole width in one frame at every wrap.
//
// Corners: the box has four independent radii. cornerN = 2 is a circular
// corner and uses the exact rounded-box distance. Any other value draws a
// superellipse corner |x|^n + |y|^n = r^n through a pseudo-distance that is
// exact along the axes and a few percent short at 45 degrees -- the same
// order of error as bezier rings, whose inner rings are not true parallel
// curves either.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    // Geometry. The effect item is the box grown by `margin` on every side,
    // so the box itself spans [0, boxW] x [0, boxH] in the coordinates below.
    float margin;
    float boxW;
    float boxH;
    vec4  radii;            // TL, TR, BR, BL
    float bevelWidth;
    float shadowWidth;
    float cornerN;
    float edgeAlpha;
    float falloff;

    vec4  surfaceColor;
    vec4  bevelColor;
    vec4  shadowColor;
    vec4  backgroundColor;
    vec4  bevelEasing;      // CSS cubic-bezier x1, y1, x2, y2
    vec4  shadowEasing;

    // Progress tint. hasProgress is 0 or 1.
    float hasProgress;
    float boundaryX;        // centre of the LEADING crossover, px
    float featherHalf;      // half the crossover width, px
    vec4  progressColor;

    // The band's trailing edge. hasTail is 0 or 1; at 0 nothing below reads
    // `tailX` and the tint is the plain fill. One feather serves
    // both edges: by the time the tail leaves the left of the box the lead is
    // long past `progressBlendEnd`, so the feather is the active one already.
    float hasTail;
    float tailX;            // centre of the TRAILING crossover, px

    // 1 = the box stands proud of the surface instead of being carved into
    // it: the bands trade sides. The shadow falls OUTSIDE the edge (a drop
    // shadow on the surface, `shadowWidth` wide, strongest at the edge) and
    // the bevel is a highlight INSIDE it (`bevelWidth` wide, brightest at
    // the edge, easing into the plateau colour). Same colours, same
    // easings, spreads tuned separately by the host.
    float raised;

    // Raised only. 1 = the drop shadow is COVERAGE, not paint: shadowColor
    // at `strength` alpha, blended to transparent, instead of an opaque mix
    // toward surfaceColor. Over a ground that IS surfaceColor the two are
    // the same arithmetic -- src*s + surface*(1-s) either way -- so a
    // resting box is pixel-identical; the difference is that anything else
    // sliding beneath the box shows through the falloff instead of meeting
    // a surface-coloured apron.
    float shadowToAlpha;
};

// CSS cubic-bezier easing: solve x for t by Newton, then read y. Same
// solver as logo_relief.frag, net_glyph.frag and weather_glyph.frag, so the
// curves match to the same tolerance.
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

// Signed distance to the rounded box (negative inside). Per-corner radius is
// picked by quadrant. Shrinking the box by t gives the same set as shrinking
// each radius by t and clamping at 0 -- which is exactly how the bands' inner
// outlines are built.
float boxDist(vec2 p) {
    vec2 b = 0.5 * vec2(boxW, boxH);
    vec2 c = p - b;
    float r = c.x < 0.0 ? (c.y < 0.0 ? radii.x : radii.w)
                        : (c.y < 0.0 ? radii.y : radii.z);
    r = min(r, min(b.x, b.y));
    vec2 q = abs(c) - b + r;
    vec2 qp = max(q, vec2(0.0));
    float corner;
    if (abs(cornerN - 2.0) < 1e-3) {
        corner = length(qp);
    } else {
        // Normalised by the larger component before the power, so both
        // ratios stay in [0, 1] and pow() cannot overflow. On raw pixel
        // distances it does from n ~ 30 upward, and the infinity it produces
        // discards an r-wide band along every edge, bevel included.
        float s = max(max(qp.x, qp.y), 1e-6);
        corner = s * pow(pow(qp.x / s, cornerN) + pow(qp.y / s, cornerN), 1.0 / cornerN);
    }
    return min(max(q.x, q.y), 0.0) + corner - r;
}

void main() {
    vec2 pos = qt_TexCoord0 * vec2(boxW + 2.0 * margin, boxH + 2.0 * margin) - margin;
    float depth = -boxDist(pos);

    // One device pixel, in depth units, whatever transform the item is
    // under. fwidth is what keeps the edge exactly one pixel soft at 2.4x
    // zoom instead of 2.4 pixels soft.
    float aa = max(fwidth(depth), 1e-4);

    // Outer coverage: the outermost band's outside edge, antialiased.
    float outerW = raised > 0.5 ? shadowWidth : bevelWidth;
    float cov = smoothstep(-outerW - 0.5 * aa, -outerW + 0.5 * aa, depth);
    if (cov <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    if (raised > 0.5) {
        // Drop shadow outside: full strength at the edge, eased away from
        // it over shadowWidth, on the surface.
        float t = clamp(-depth / max(shadowWidth, 1e-3), 0.0, 1.0);
        float fs = ease(t, shadowEasing);
        float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);
        // Premultiplied throughout (Qt hands color uniforms over that way),
        // so "shadowColor at strength alpha" is one multiply.
        vec4 outer = shadowToAlpha > 0.5
            ? shadowColor * strength
            : mix(surfaceColor, shadowColor, strength);
        // Highlight inside: the bevel colour at the edge, easing into the
        // plateau over bevelWidth.
        float fb = ease(clamp(depth / max(bevelWidth, 1e-3), 0.0, 1.0), bevelEasing);
        vec4 inner = mix(bevelColor, backgroundColor, fb);
        if (depth >= bevelWidth) inner = backgroundColor;
        float seamR = smoothstep(-0.5 * aa, 0.5 * aa, depth);
        fragColor = mix(outer, inner, seamR) * cov * qt_Opacity;
        return;
    }

    // Bevel band.
    float fb = ease(clamp((depth + bevelWidth) / max(bevelWidth, 1e-3), 0.0, 1.0), bevelEasing);
    vec4 bevel = mix(surfaceColor, bevelColor, fb);

    // Shadow band.
    float fs = ease(clamp(depth / max(shadowWidth, 1e-3), 0.0, 1.0), shadowEasing);
    float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);
    vec4 src = shadowColor;
    if (hasProgress > 0.5) {
        float t = smoothstep(boundaryX - featherHalf, boundaryX + featherHalf, pos.x);
        if (hasTail > 0.5) {
            // Inside the band both ramps are satisfied; outside either edge
            // one of them is zero. Kept as its own expression rather than
            // folded into the line below: mix(S, P, 1 - t) and mix(P, S, t)
            // differ in the last bit, and a fill without a tail must stay
            // bit-identical.
            float tt = smoothstep(tailX - featherHalf, tailX + featherHalf, pos.x);
            src = mix(shadowColor, progressColor, tt * (1.0 - t));
        } else {
            src = mix(progressColor, shadowColor, t);
        }
    }
    vec4 inner = mix(backgroundColor, src, strength);
    if (depth >= shadowWidth) inner = backgroundColor;

    // The bevel/shadow seam at depth 0 is a real edge in the design (light
    // rim outside, dark inset inside); antialias it rather than step it.
    float seam = smoothstep(-0.5 * aa, 0.5 * aa, depth);
    vec4 col = mix(bevel, inner, seam);

    // Qt hands `color` uniforms over PREMULTIPLIED, so every mix above was
    // already in premultiplied space and the result goes out as it is. A
    // second multiply here would darken any translucent colour twice.
    fragColor = col * cov * qt_Opacity;
}
