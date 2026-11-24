#version 440

// =============================================================================
// logo_relief.frag
//
// Carves a logo into the shell's surface, following the logo's own contour,
// from ONE baked texture (tools/bake_logo_relief.py) and nothing else.
// No render-to-texture, no blur pass, no geometry: one quad, one sample.
//
// The texture is OPAQUE RGB, not RGBA, and that is load-bearing: Qt uploads an
// image that has alpha as PREMULTIPLIED, so a coverage mask in A would
// multiply the other channels by itself and zero the normal and the ramp
// everywhere outside the mark -- the outer bevel would simply not be there,
// with nothing warning about it. Three channels:
//
//   R,G  the unit normal of the signed distance field, biased to 0..1, always
//        pointing toward the interior of the mark. +G is DOWN.
//   B    one signed ramp with the contour at 0.5, in units of the carve depth:
//        1.0 at the floor, 0.0 one depth outside the edge. The inside half is
//        island-corrected at bake time, so a stroke thinner than the carve is
//        depth-limited rather than swallowed by it.
//
// Because B is locally a plain signed distance either side of the contour, the
// silhouette needs no baked coverage channel: the ramp's screen-space gradient
// gives the distance in device pixels, which antialiases the seam exactly
// under any scale and lets the outer bevel be a runtime fraction of the depth
// instead of a width frozen into the asset.
//
// The bands are ShadowBox's, in ShadowBox's order and with ShadowBox's
// easings -- surface -> bevel outside the edge, shadow -> body inside it -- so
// a carved logo and a carved box read as the same material:
//
//   outside, u = dOut / bevelWidth       mix(surfaceColor, bevelColor, ease(1-u))
//   inside,  t = dIn  / depth            mix(bodyColor,  shadowColor, strength)
//
// with strength = edgeAlpha * (1 - ease(t))^falloff, exactly as the box.
//
// What a box cannot have and a relief must: DIRECTION. A box's inset is
// isotropic because a box is read as a shape, not as a surface; a logo carved
// with an isotropic rim reads as an outlined silhouette instead of something
// cut into the panel. So the inside strength is split between an isotropic
// share (`ambient`, which IS the box's inset) and a lambert term against a
// light that comes from above:
//
//   lam = dot(N, lightDir)     +1 the wall faces the light, -1 it faces away
//
// N points into the mark, so on the mark's TOP wall N points down, away from a
// light above: lam < 0, shadow. On the BOTTOM wall lam > 0 and the wall takes
// the bevel colour instead. That is the same reading as every carved thing in
// the shell -- dark along the top edge, bright along the bottom.
//
// ambient = 1 collapses the whole thing back to ShadowBox's isotropic inset.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    // Carve depth, as a fraction of the depth that was baked in. 1.0 uses the
    // bake; below 1.0 narrows the inset exactly (the ramp is remapped); above
    // 1.0 cannot reach past what was stored and clamps.
    float depthScale;
    // Outer bevel width, as a fraction of the carve depth. Runtime, because
    // the outside half of the ramp is stored over the depth, not over a baked
    // bevel width.
    float bevelWidth;

    // Inset shape, ShadowBox's numbers.
    float edgeAlpha;
    float falloff;

    // Isotropic share of the inset, 0..1. 1 = ShadowBox's isotropic band.
    float ambient;
    // Strength of the lit side relative to the shadowed side.
    float highlightGain;
    // Direction the light comes from, degrees clockwise from straight up.
    float lightAngle;

    vec4  surfaceColor;     // the ground the mark is carved into
    vec4  bevelColor;       // light rim outside the edge / lit wall inside it
    vec4  shadowColor;      // deepest part of the inset
    vec4  bodyColor;        // the floor of the carve

    vec4  bevelEasing;      // CSS cubic-bezier x1, y1, x2, y2
    vec4  shadowEasing;
};

layout(binding = 1) uniform sampler2D src;

// CSS cubic-bezier easing: solve x for t by Newton, then read y. Same solver
// as shadow_box.frag, so the two curves match to the same tolerance.
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

void main() {
    vec3 s = texture(src, qt_TexCoord0).rgb;

    // Signed distance in units of the baked depth: +1 at the floor, -1 one
    // depth outside the edge, 0 on the contour.
    float sd = (s.b - 0.5) * 2.0;
    // One device pixel in those units, whatever transform the item is under.
    // The gradient's LENGTH, not fwidth: fwidth is |dx| + |dy|, which is the
    // length only on an axis-aligned edge and 1.41x it on a diagonal, so the
    // seam on a diagonal comes out 1.4 px wide. The length makes the seam
    // exactly one device pixel in every direction -- what an SVG rasteriser's
    // area coverage gives a straight edge. Far from the contour the ramp is
    // flat and this floors, which the clamps below read as "fully inside" or
    // "fully outside" rather than as a divide by nothing.
    float aa = max(length(vec2(dFdx(sd), dFdy(sd))), 1e-5);
    float cover = clamp(0.5 + sd / aa, 0.0, 1.0);

    // ---- outside: the bevel rim -----------------------------------------
    float bw = max(bevelWidth, 1e-3);
    float u = clamp(-sd / bw, 0.0, 1.0);
    vec4 outer = mix(surfaceColor, bevelColor, ease(1.0 - u, bevelEasing));
    float rim = clamp(0.5 + (sd + bw) / aa, 0.0, 1.0);

    // ---- inside: the inset, lit from above -------------------------------
    float t  = clamp(sd / max(depthScale, 1e-3), 0.0, 1.0);
    float fs = ease(t, shadowEasing);
    float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);

    vec2 n = s.rg * 2.0 - 1.0;
    float a = radians(lightAngle);
    vec2 lightDir = vec2(sin(a), -cos(a));
    float lam = dot(n, lightDir);

    float iso = clamp(ambient, 0.0, 1.0);
    float dark = strength * (iso + (1.0 - iso) * max(0.0, -lam));
    float lit  = strength * (1.0 - iso) * max(0.0, lam) * highlightGain;

    vec4 inner = mix(bodyColor, shadowColor, clamp(dark, 0.0, 1.0));
    inner = mix(inner, bevelColor, clamp(lit, 0.0, 1.0));

    // Colour uniforms arrive PREMULTIPLIED, so every mix above was already in
    // premultiplied space; a second multiply here would darken a translucent
    // colour twice.
    fragColor = mix(outer * rim, inner, cover) * qt_Opacity;
}
