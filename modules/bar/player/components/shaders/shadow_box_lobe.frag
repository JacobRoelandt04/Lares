#version 440

// =============================================================================
// shadow_box_lobe.frag
//
// A carved box with a second, narrower lobe that can rise out of its TOP edge,
// the two joined by a smooth union -- the fidelity chip and the bitrate that
// grows out of it on hover, as if the chip were the gooey bar and the bitrate
// a gooey popup appearing from it.
//
// It is shadow_box.frag's carved mode and nothing else (no raised mode, no
// progress tint), with the box's signed distance replaced by
//
//     d = smin(dChip, dLobe, joinK)        while a lobe is out,
//     d = dChip                            otherwise,
//
// and the same bands off that distance, so a chip with NO lobe is the very same
// picture a ShadowBox draws.
// The polynomial smooth-min is what makes the joint: where the lobe's side
// meets the chip's top edge the union fills a concave fillet of about joinK/4,
// the inset shadow follows the union's outline round it, and under the lobe the
// chip's top edge simply is not an edge any more.
//
// Coordinates are the CHIP's: its top-left corner is (0, 0), y grows down, so a
// lobe rises into negative y. The effect item is the chip grown by `margin` on
// every side and by `headroom` on top, which is the most the lobe can ever need.
// The lobe box runs from `lobeTop` (negative: its visible top) to `lobeBottom`
// (inside the chip, where the union hides it), `lobeW` wide from `lobeX`.
// `hasLobe` is 0 while the lobe has no height: a signed-distance box of no area
// is still a line, so it is not drawn at all.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    float margin;
    float headroom;
    float chipW;
    float chipH;
    float chipR;

    float hasLobe;
    float lobeX;
    float lobeW;
    float lobeTop;
    float lobeBottom;
    float lobeR;
    float joinK;

    float bevelWidth;
    float shadowWidth;
    float edgeAlpha;
    float falloff;

    vec4  surfaceColor;
    vec4  bevelColor;
    vec4  shadowColor;
    vec4  backgroundColor;
    vec4  bevelEasing;      // CSS cubic-bezier x1, y1, x2, y2
    vec4  shadowEasing;
};

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

// Signed distance to a rounded box given by its corners (negative inside).
float roundBox(vec2 p, vec2 lo, vec2 hi, float rad) {
    vec2 b = 0.5 * (hi - lo);
    vec2 c = p - 0.5 * (hi + lo);
    float r = min(rad, min(b.x, b.y));
    vec2 q = abs(c) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

void main() {
    vec2 pos = qt_TexCoord0 * vec2(chipW + 2.0 * margin, chipH + headroom + 2.0 * margin)
             - vec2(margin, margin + headroom);

    float d = roundBox(pos, vec2(0.0), vec2(chipW, chipH), chipR);
    if (hasLobe > 0.5) {
        float dl = roundBox(pos, vec2(lobeX, lobeTop), vec2(lobeX + lobeW, lobeBottom), lobeR);
        d = smin(d, dl, joinK);
    }
    float depth = -d;

    float aa = max(fwidth(depth), 1e-4);

    float cov = smoothstep(-bevelWidth - 0.5 * aa, -bevelWidth + 0.5 * aa, depth);
    if (cov <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    float fb = ease(clamp((depth + bevelWidth) / max(bevelWidth, 1e-3), 0.0, 1.0), bevelEasing);
    vec4 bevel = mix(surfaceColor, bevelColor, fb);

    float fs = ease(clamp(depth / max(shadowWidth, 1e-3), 0.0, 1.0), shadowEasing);
    float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);
    vec4 inner = mix(backgroundColor, shadowColor, strength);
    if (depth >= shadowWidth) inner = backgroundColor;

    float seam = smoothstep(-0.5 * aa, 0.5 * aa, depth);
    vec4 col = mix(bevel, inner, seam);

    fragColor = col * cov * qt_Opacity;
}
