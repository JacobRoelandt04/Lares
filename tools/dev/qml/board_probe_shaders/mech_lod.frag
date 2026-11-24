#version 440
// silicon_board_probe's mechanism ladder: the same read at an EXPLICIT level (textureLod: GLSL 1.30+ / ES 3.00 natively, GL_EXT_shader_texture_lod
// in ES 1.00, which Mesa's ES context does not offer and NVIDIA's does): what the silicon board's silkscreen read did.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
layout(binding = 1) uniform sampler2D silk;
void main() {
    vec3 t = textureLod(silk, qt_TexCoord0, 2.0).rgb;
    fragColor = vec4(0.25 + 0.5 * t, 1.0) * qt_Opacity;
}
