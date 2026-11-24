#version 440
// silicon_board_probe's mechanism ladder, rung one: no texture, a flat colour in a cached layer.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
};
void main() {
    fragColor = vec4(0.2, 0.6, 0.3, 1.0) * qt_Opacity;
}
