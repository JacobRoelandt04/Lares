#version 440
// =============================================================================
// lock_kawase_down.frag -- one DOWNSAMPLE pass of Hyprland's dual-Kawase blur,
// ported so the lock's blur-in can be the SAME blur the compositor applies to
// the lock (session_lock_blur) and the handover between them is invisible.
//
// Matched to the test Hyprland (size 10, passes 4): the taps sit
// `halfpixel * radius` from the centre, `halfpixel` being half a texel of the
// DESTINATION of the pass.
//
// Coordinates are normalised, so the same uv reads the source at the centre of
// the destination texel whatever the two sizes are.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 halfpixel;
    float radius;
};
layout(binding = 1) uniform sampler2D src;

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 o = halfpixel * radius;
    vec4 s = texture(src, uv) * 4.0;
    s += texture(src, uv + vec2(-o.x, -o.y));
    s += texture(src, uv + vec2(o.x, o.y));
    s += texture(src, uv + vec2(o.x, -o.y));
    s += texture(src, uv + vec2(-o.x, o.y));
    fragColor = vec4(s.rgb / 8.0, 1.0);
}
