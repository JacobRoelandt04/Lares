#version 440
// =============================================================================
// theme_hole.frag -- ThemeCrossfade's still picture with holes cut out of it.
//
// A theme switch shows a picture of the frame before, faded out over the new
// palette. A THEME ISLAND (ThemeIsland.qml) is a moving thing that carries its
// own old->new colours through the fade, so the picture must not show it: this
// draws the picture's texture times a mask that is 0 inside each island's shape
// (a rounded box; a disc is a box with radius = half its side) and 1 outside.
//
// The live island lies UNDER the picture and is opaque in its shape, so the
// edge is feathered INWARD, one device pixel (`px`, in item units): the ring of
// picture that is half transparent lies over island pixels, never over the
// ground outside it (a feather that straddled the edge would show the new
// palette's ground as a one-pixel ring). Premultiplied in, premultiplied out.
//
// A HARD hole (`holeH` 1: a rectangle snapped to whole device pixels, where there is no partial coverage to feather) is 0 or 1 by the
// pixel's centre. A feather is wrong for it: the half-transparent ring of picture lies over the island's own blend, not over the
// new scene alone, and adds a share of the old picture to it -- a one-pixel line, measured at 20 levels at the fade's third.
//
// A hole with a zero half-size is not there.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    float px;
    vec4 holeA;   // centre x, centre y, half width, half height (item units)
    vec4 holeB;
    vec4 holeC;
    vec4 holeD;
    vec4 holeR;   // the corner radius of A, B, C, D
    vec4 holeH;   // 1: a hard edge (no feather), per hole
};
layout(binding = 1) uniform sampler2D src;

float keep(vec2 p, vec4 h, float r, float hard) {
    if (h.z <= 0.0 || h.w <= 0.0)
        return 1.0;
    float rr = min(r, min(h.z, h.w));
    vec2 q = abs(p - h.xy) - (h.zw - vec2(rr));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    if (hard > 0.5)
        return d < -0.25 * px ? 0.0 : 1.0;
    return clamp(1.0 + d / max(px, 1e-4), 0.0, 1.0);
}

void main() {
    vec2 p = qt_TexCoord0 * vec2(boxW, boxH);
    float a = keep(p, holeA, holeR.x, holeH.x) * keep(p, holeB, holeR.y, holeH.y) * keep(p, holeC, holeR.z, holeH.z) * keep(p, holeD, holeR.w, holeH.w);
    fragColor = texture(src, qt_TexCoord0) * (a * qt_Opacity);
}
