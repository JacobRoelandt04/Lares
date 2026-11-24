#version 440
// silicon_board_probe's mechanism ladder: the board's other two ES 1.00 hazards in miniature -- a 75-entry local table filled element by
// element (the AO guard) and read by a loop's own arithmetic (`i0 + j - k * n`), with a loop bound taken from a uniform. A driver that cannot do
// either draws nothing: the picture is the table's running product, never zero.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;
};
void main() {
    vec4 R[75];
    for (int q = 0; q < 75; q++)
        R[q] = vec4(0.5 + 0.004 * float(q), 0.8, 0.9, 1.0);
    int n = int(view.x);
    vec4 a = vec4(1.0);
    for (int j = 0; j < n * 2; j++) {
        int k = j >= n ? 1 : 0;
        int i = 7 + j - k * n;
        a *= mix(vec4(1.0), R[i], 0.5 + qt_TexCoord0.x * 0.5);
    }
    fragColor = vec4(a.rgb, 1.0) * qt_Opacity;
}
