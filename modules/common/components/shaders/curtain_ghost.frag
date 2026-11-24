#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_ghost.frag -- a layer effect: an island's OLD copy, cut by the live curtain's line (ThemeIsland.wipeEffect). The island's rect is a hole
// in the old shell's picture, the live thing shows new under this copy, and the copy goes by the same function of the same pixel as everything
// else in the old world (curtain_reveal.glsl). `place` turns this item's texture coordinate into the window's item px.
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
    vec4 place;      // the item in the window, item px: x, y, width, height
};
layout(binding = 1) uniform sampler2D source;
#include "curtain_reveal.glsl"

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    float sh;
    float a = curtainShade(place.xy + qt_TexCoord0 * place.zw, c, sh);
    fragColor = c * a * qt_Opacity;
}
