#version 440
// silicon_board_probe's mechanism ladder: a cached layer that reads the silkscreen texture with a BIAS (texture(s, uv, b): every GLSL version
// has it, no extension) -- the picture is the texture's colour channels, so a driver that cannot sample, cannot layer or draws nothing shows
// as an empty rung.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D silk;
void main() {
    vec3 t = texture(silk, qt_TexCoord0, 2.0).rgb;
    fragColor = vec4(0.25 + 0.5 * t, 1.0) * qt_Opacity;
}
