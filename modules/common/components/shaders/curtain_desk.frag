#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_desk.frag -- the desktop's still alone, premultiplied, alpha 0 where the shell covered it: what ThemeWipe's fill is mipmapped from.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D shot;
layout(binding = 2) uniform sampler2D shellThen;
#include "curtain_desk.glsl"

void main() {
    fragColor = curtainDesk(qt_TexCoord0) * qt_Opacity;
}
