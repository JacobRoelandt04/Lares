#version 440
// =============================================================================
// fade_band.frag -- one of ScrollDressing's edge fades, cut to a rounded
// outline (the popup's) that the band itself does not follow.
//
// A band lies over its host's clip RECTANGLE, but the host is drawn with
// rounded corners: a foot band that ends closer to a corner than that
// corner's radius puts its opaque end outside the curve (the notes grid's
// foot, 12 px above a 20 px corner -- more while the popup's tension
// inflates it). So the band is drawn only inside the outline, feathered
// INWARD and one device pixel further in: two antialiased shapes over the
// same edge add their partial ink, so a band that merely stopped AT the
// curve would still thicken the host's own edge pixels (measured: alpha 176 ->
// 188 on the corner's rim). The pixel size comes from a linear coordinate.
//
// Colour along the band's axis: c0 up to rampFrom, c1 from rampTo, mixed
// between (premultiplied). That also draws the opaque lead of a band.
//
// THE GROUND UNDER A POURED TINT IS NOT ONE COLOUR. A popup whose content declares a surfaceTint (a coloured
// note) has the engine pour that colour across its join with the bar: within `rampReach` of a joined face the
// surface is  (base * w + tint) / (1 + w),  w = (1 - d / reach)^2  (gooey_field.frag tintMix; d the depth from the
// nearest joined face). A band that fades into the plain tint over that zone paints a different colour than the
// surface it lies on -- a hard-edged rectangle in the corner where the foot meets the bar. With `rampReach` > 0 the
// band's colour is that surface, computed the way the field computes it: c0/c1 name the tint (one of them is
// transparent, so the band's weight is their alpha), `rampBase` the untinted surface, `rampSides` which faces of
// the outline are joined (left, top, right, bottom: 0 or 1). rampReach 0 draws the band in its plain colours.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    vec4 c0;
    vec4 c1;
    float horizontal;
    float rampFrom;
    float rampTo;
    vec4 outline;   // x, y, w, h in item units
    vec4 radii;     // tl, tr, br, bl (y down)
    vec4 rampBase;  // the untinted surface (premultiplied)
    vec4 rampSides; // joined faces: left, top, right, bottom
    float rampReach;
};

float sdCornerBox(vec2 p, vec2 b, vec4 r) {
    float rr = p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
    vec2 q = abs(p) - b + rr;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

void main() {
    vec2 p = qt_TexCoord0 * vec2(boxW, boxH);
    float s = horizontal > 0.5 ? p.x : p.y;
    vec4 col = mix(c0, c1, clamp((s - rampFrom) / max(rampTo - rampFrom, 1e-4), 0.0, 1.0));
    if (rampReach > 0.0) {
        vec2 lo = p - outline.xy;
        vec2 hi = outline.xy + outline.zw - p;
        float dj = 1e9;
        if (rampSides.x > 0.5) dj = min(dj, lo.x);
        if (rampSides.y > 0.5) dj = min(dj, lo.y);
        if (rampSides.z > 0.5) dj = min(dj, hi.x);
        if (rampSides.w > 0.5) dj = min(dj, hi.y);
        float t = 1.0 - clamp(max(dj, 0.0) / rampReach, 0.0, 1.0);
        float w = t * t;
        vec3 tint = c0.rgb + c1.rgb;   // one of the two is transparent: the band's weight is the other's alpha
        float a = mix(c0.a, c1.a, clamp((s - rampFrom) / max(rampTo - rampFrom, 1e-4), 0.0, 1.0));
        col = vec4((rampBase.rgb * w + tint) / (1.0 + w) * a, a);
    }
    vec2 hb = 0.5 * outline.zw;
    vec4 r = clamp(radii, vec4(0.0), vec4(min(hb.x, hb.y)));
    float px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-4);
    float d = sdCornerBox(p - (outline.xy + hb), hb, r) + px;
    float cover = clamp(-d / px, 0.0, 1.0);
    fragColor = col * cover * qt_Opacity;
}
