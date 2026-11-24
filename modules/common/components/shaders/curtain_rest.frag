#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_rest.frag -- a live item in a window of its own, the other side of the live curtain's line: what is left of it where curtain_ghost.frag's old copy has gone
// (ThemeCrossfade, a pill over the shell). The two add up to the old copy on the old side and the live item on the new, with nothing of the new under the old.
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
    vec4 place;      // the item on the screen, in the wipe's item px: x, y, width, height
};
layout(binding = 1) uniform sampler2D source;
#include "curtain_reveal.glsl"

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    vec4 unshaded = c;
    float sh;
    float a = curtainShade(place.xy + qt_TexCoord0 * place.zw, c, sh);
    fragColor = unshaded * (1.0 - a) * qt_Opacity;
}
