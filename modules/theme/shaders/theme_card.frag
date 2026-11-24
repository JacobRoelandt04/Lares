#version 440
// The theme card's face, a held texture, cut to its rounded box per device pixel: the tilt turns it, and an edge baked into the texture would be resampled.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    float radius;
    float inset;
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 p = qt_TexCoord0 * vec2(boxW, boxH);
    vec2 c = 0.5 * vec2(boxW, boxH);
    vec2 q = abs(p - c) - (c - vec2(inset)) + vec2(radius);
    float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float px = length(vec2(dFdx(p.x), dFdy(p.x)));
    float cover = clamp(0.5 - d / px, 0.0, 1.0);
    fragColor = texture(source, qt_TexCoord0) * cover * qt_Opacity;
}
