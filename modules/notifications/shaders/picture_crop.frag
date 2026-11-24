#version 440
// =============================================================================
// picture_crop.frag -- a texture cut to a rounded rectangle, showing a centred
// part of it (PictureBand.qml). image_round.frag's cut (see its header for the
// distance and the coverage), with the texture coordinate mapped onto the part
// that is shown: `uvOff` is where the part starts and `uvScale` how much of the
// picture it covers, both as shares of the whole. A picture whose aspect does
// not fit the band is COVERED -- scaled until it fills the box, the overflow
// cropped equally at both ends -- and never stretched.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    float radius;
    float uvOffX;
    float uvOffY;
    float uvScaleX;
    float uvScaleY;
};
layout(binding = 1) uniform sampler2D source;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 hb = 0.5 * vec2(boxW, boxH);
    vec2 p = (qt_TexCoord0 - 0.5) * vec2(boxW, boxH);
    float px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-4);
    float r = clamp(radius, 0.0, min(hb.x, hb.y));
    float d = sdRoundBox(p, hb, r);
    float cover = clamp(0.5 - d / px, 0.0, 1.0);
    vec2 uv = vec2(uvOffX, uvOffY) + qt_TexCoord0 * vec2(uvScaleX, uvScaleY);
    fragColor = texture(source, uv) * cover * qt_Opacity;
}
