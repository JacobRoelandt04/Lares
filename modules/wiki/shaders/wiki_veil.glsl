// =============================================================================
// wiki_veil.glsl -- what every wiki veil shares: the uniform block, the pattern
// coordinate, the clearing, the ONE shading and the mask. Included by each
// wiki_veil_<name>.frag (the bake rebakes them when this file is newer).
//
// A WIKI VEIL is the picture of an article that has none: a slow pattern in the
// card's own material, drawn on the well's floor. Every veil is a HEIGHT FIELD
// (grooves cut into the floor, plateaus standing on it) and hands this file two
// things per pixel: how far below the surface it is (`depth`, 0..1) and the
// height's gradient in item px (`slope`). `veilShade` lights that the way the
// shell lights a carved logo -- one light from above, the wall toward the
// light in shadow, the wall away from it catching the bevel -- so five
// patterns are one material.
//
// COLOUR. Ground, bevel, shadow and deep are Theme tokens the host
// resolves; `cDeep` already carries the trace of the family's hue, and it is
// reached only where the shadow is deepest (a category's colour lives in the
// inset shadow).
//
// THE CLEARING. A disc where the floor is flat (the subject's logo is carved
// there): depth and slope fall to nothing inside `clearing.z` and come back
// over `clearing.w`. A fine ring is cut where the flat ends, so the plate reads
// as made, not as a hole in the pattern.
//
// VALID FOR EVERY TARGET the bake makes (GLSL ES 1.00 and 1.20 included): loops
// with constant bounds, no arrays, no integer arithmetic beyond loop counters,
// no bit operations, no textureLod.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float time;         // veil seconds
    vec2  size;         // item px

    vec4  seed;         // four numbers 0..1 from the article's id
    vec4  frame;        // zoom (item px per pattern px), corner radius px, relief gain, -
    vec4  light;        // toward-light x, y (unit, y down), lit gain, shadow gain
    vec4  clearing;     // centre x, y (item px), flat radius, fade width (0 = none)
    vec4  grade;        // ambient: the share of a wall's shade that does not ask where the light is, -, -, -
    vec4  p0;           // the pattern's own numbers
    vec4  p1;

    vec4  cGround;
    vec4  cBevel;
    vec4  cShadow;      // the carve's mid shade (border)
    vec4  cDeep;        // its deepest (shadowDeep with the family's hue in it)
};

const float TAU = 6.28318530718;

// Hashes with no trigonometry (Dave Hoskins): the same on every driver.
float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// One device pixel in item px, and half of one in pattern px. Set by veilCoord(), which every
// veil calls first (a linear coordinate's derivatives, taken before any branch).
float veilPx;
float veilHalf;

// The pattern's coordinate: pattern px, origin at the item's centre.
vec2 veilCoord() {
    vec2 ip = qt_TexCoord0 * size;
    veilPx = max(length(vec2(dFdx(ip.x), dFdy(ip.x))), 1e-4);
    veilHalf = 0.5 * veilPx / frame.x;
    return (qt_TexCoord0 - 0.5) * size / frame.x;
}

// A groove's cross-section at `d` px from its centre line, half-width `w`, `deep` px deep:
// x = how deep (0..1), y = dh/dd (the height falls to the centre), both AVERAGED OVER THE
// PIXEL across the groove -- the profile (1 - u^2)^2 has a closed integral, and its slope's
// mean is the height's difference over the pixel. A groove's two walls are a pixel or so
// each: sampled at the pixel's centre, a line at a shallow angle comes out dashed (lit wall,
// shadowed wall, lit wall, row by row).
float veilGrooveH(float u) {
    u = clamp(u, -1.0, 1.0);
    float k = 1.0 - u * u;
    return k * k;
}
float veilGrooveI(float u) {
    u = clamp(u, -1.0, 1.0);
    float u2 = u * u;
    return u * (1.0 - u2 * (0.6666667 - 0.2 * u2));
}
vec2 veilGroove(float d, float w, float deep) {
    float a = (d - veilHalf) / w;
    float b = (d + veilHalf) / w;
    return vec2(w * (veilGrooveI(b) - veilGrooveI(a)), deep * (veilGrooveH(a) - veilGrooveH(b))) / (2.0 * veilHalf);
}

// 0 inside the clearing, 1 outside it.
float veilClear(vec2 ip) {
    if (clearing.w <= 0.0)
        return 1.0;
    return smoothstep(clearing.z, clearing.z + clearing.w, length(ip - clearing.xy));
}

// The lit colour of a point `depth` below the surface whose height changes by
// `slope` (item px per item px), premultiplied by the mask.
vec4 veilShade(float depth, vec2 slope) {
    vec2 ip = qt_TexCoord0 * size;
    float amp = veilClear(ip);
    depth *= amp;
    slope *= amp;
    // the plate's ring: a fine groove where the flat ends
    if (clearing.w > 0.0) {
        vec2 rv = ip - clearing.xy;
        float rl = max(length(rv), 1e-3);
        vec2 g = veilGroove(rl - clearing.z, 1.6, 0.9);
        depth = max(depth, g.x * 0.8);
        slope += g.y * rv / rl;
    }

    // A cut's shade has two shares, as a carved logo's has: an even one that follows the DEPTH
    // (a cut is darker than the surface whichever way it runs: without it a groove along the
    // light is not there at all) and one that asks which way the wall faces.
    float steep = length(slope);
    float toward = dot(slope, light.xy) / max(steep, 1e-5);     // 1: the wall on the light's side, in shadow
    steep *= frame.z;
    float sh = clamp((grade.x * clamp(depth, 0.0, 1.0) + (1.0 - grade.x) * steep * max(toward, 0.0)) * light.w, 0.0, 1.0);
    float lit = clamp(steep * max(-toward, 0.0) * light.z, 0.0, 1.0);

    vec3 col = mix(cGround.rgb, mix(cShadow.rgb, cDeep.rgb, sh * sh), sh);
    col = mix(col, cBevel.rgb, lit);

    // dither against banding: interleaved gradient noise
    // (in the item's own device pixels, not the window's: the same article is the same picture wherever its card stands)
    float dn = fract(52.9829189 * fract(dot(floor(ip / veilPx), vec2(0.06711056, 0.00583715)))) - 0.5;
    col += dn / 255.0;

    // the rounded mask, feathered inward
    float a = 1.0;
    if (frame.y > 0.0) {
        vec2 q = abs(ip - 0.5 * size) - (0.5 * size - frame.y);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - frame.y;
        a = clamp(-d / veilPx, 0.0, 1.0);
    }
    return vec4(col * a, a) * qt_Opacity;
}
