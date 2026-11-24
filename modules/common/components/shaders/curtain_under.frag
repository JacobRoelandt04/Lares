#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_under.frag -- the live curtain's lower half: the desktop as it was, under the live shell (ThemeWipe.qml; the line is
// curtain_reveal.glsl). What it does not draw shows the live desktop through the window, which is the whole reveal.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;       // the window, in item px
    vec2 origin;     // where the reveal starts, in item px
    float progress;  // 0 = the old world covers everything, 1 = nothing of it is left
    float soft;      // the feather of the front, in item px
    float seed;
    float style;     // 0 radial, 1 peel, 2 louvres
};
layout(binding = 1) uniform sampler2D shot;        // the output as it was
layout(binding = 2) uniform sampler2D shellThen;   // the shell alone, in the frame of `shot`
layout(binding = 3) uniform sampler2D shotFill;    // the still at a quarter size, mipmapped, premultiplied: alpha 0 where the shell covered it
#include "curtain_reveal.glsl"
#include "curtain_desk.glsl"

// Each level behind the one before: the nearest level that has anything here decides, and a hole of any size closes.
vec4 fill(vec2 uv) {
    vec4 f = vec4(0.0);
    for (int i = 0; i < 5; i++) {
        vec4 s = texture(shotFill, uv, 2.0 * float(i));
        f += s * (1.0 - f.a);
    }
    return f.a > 0.0 ? vec4(f.rgb / f.a, 1.0) : vec4(0.0);
}

void main() {
    vec4 c = curtainDesk(qt_TexCoord0);
    if (c.a <= 0.0)
        c = fill(qt_TexCoord0);
    float sh;
    float a = curtainShade(qt_TexCoord0 * size, c, sh);
    fragColor = c * a * qt_Opacity;
}
