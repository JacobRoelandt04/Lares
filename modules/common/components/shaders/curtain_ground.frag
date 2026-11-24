#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_ground.frag -- the flat OLD ground of a ThemeIsland (IslandGround.qml), lying UNDER the live things that keep moving through the hole.
//
// It has the hole's exact shape: the same rounded box, the same hard test (theme_hole.frag, curtain_over.frag), so the two are complements pixel for pixel and nothing is
// counted twice where they meet, in either path. Under the live curtain (`cut` 1) it goes by the line, the same function of the same pixel as the rest of the old world; under
// the plain fade (`cut` 0) it is whole and the item's opacity is the picture's.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    vec2 origin;
    float progress;
    float soft;
    float seed;
    float style;
    float px1;       // one device pixel, in item px
    float radius;    // the hole's corner radius, in item px
    float cut;       // 1: the line cuts it
    vec4 place;      // the hole in the window, item px: x, y, width, height
    vec4 ground;     // the old surface
};
#include "curtain_reveal.glsl"

void main() {
    vec2 px = place.xy + qt_TexCoord0 * place.zw;
    vec2 h = place.zw * 0.5;
    float rr = min(radius, min(h.x, h.y));
    vec2 q = abs(px - place.xy - h) - (h - vec2(rr));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    if (d >= -0.25 * px1) {
        fragColor = vec4(0.0);
        return;
    }
    vec4 c = vec4(ground.rgb, 1.0);
    float a = 1.0;
    if (cut > 0.5) {
        float sh;
        a = curtainShade(px, c, sh);
    }
    fragColor = c * a * qt_Opacity;
}
