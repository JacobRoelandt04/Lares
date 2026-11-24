#version 440
// =============================================================================
// image_round.frag -- a texture cut to a rounded rectangle (RoundedImage.qml).
//
// The distance is the exact one of a rounded box, in item units, and the
// size of one device pixel comes from the derivative of a LINEAR coordinate
// (p.x), never of the composed distance: a derivative of a min/max of
// distances depends on how the 2x2 quads pair up, and the curve would
// re-rasterise differently every time the image moved one pixel.
//
// Coverage is the box-filter area of the pixel: 0.5 - d / pixel. That is
// right here, and not the bleed CLAUDE.md warns about, because the shape's
// straight edges ARE the item's edges: nothing is ever drawn outside the
// quad, and a pixel centre half a pixel inside the edge gets full ink, so the
// image keeps its outermost row and column. Only the corners are cut, each
// by the same circle measured from pixel centres -- a whole-pixel box gives
// four identical corners.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    float radius;
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
    fragColor = texture(source, qt_TexCoord0) * cover * qt_Opacity;
}
