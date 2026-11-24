#version 440

// =============================================================================
// well_cut.frag
//
// The swipe WELL (SwipeVerbCard's carved box, drawn once into a layer) cut to
// what the face does not cover: the uncovered band, AND the wedges the face's
// own rounded corners leave open on the edge it leads with. A straight clip at
// the face's edge would leave those wedges to the ground, and
// the ground is lighter than the well: a pale corner round every rounded
// corner of a swiped card. The face is transparent there, so
// the well belongs there.
//
// Everything is in the layer item's own units.
//
//   size    the layer item (w, h)
//   face    the face's drawn rect in that frame (x, y, w, h)
//   radius  the face's corner radius
//   side    +1: the band lies to the LEFT of the face (the card moved right),
//           -1: to its right
//   reach   how far past the leading edge the wedges extend into the face's
//           span (the corner's radius plus its rim: past it the face's own
//           edge is a straight line and the well has nothing to show)
//   tail    the length over which the wedges' far end fades out (a hard end
//           would leave the well's own top rim stopping short along the face's
//           edge, where the corner has all but met it)
//   inset   how far under the face's outline the well runs (the face's rim is
//           a ramp to alpha and must meet the well, not the ground)
//   aa      one device pixel: the feather, taken INWARD only
//
// The texel is premultiplied (a layer's texture), so scaling the whole vec4
// keeps it premultiplied.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;
    vec4  face;
    float radius;
    float side;
    float reach;
    float tail;
    float inset;
    float aa;
};

layout(binding = 1) uniform sampler2D source;

float sdRoundBox(vec2 p, vec2 h, float r)
{
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main()
{
    vec2 p = qt_TexCoord0 * size;
    vec2 h = 0.5 * face.zw;
    float r = min(radius, min(h.x, h.y));
    float d = sdRoundBox(p - (face.xy + h), h, r);
    float a = max(aa, 0.0001);
    // Outside the face's outline (less the inset): 1. Feathered inward.
    float outside = smoothstep(-inset - a, -inset, d);
    // Beyond the leading edge: the band (always) and the wedges (to `reach`).
    float lead = side > 0.0 ? face.x : face.x + face.z;
    float u = side > 0.0 ? lead - p.x : p.x - lead;
    float t = clamp((u + reach) / max(tail, a), 0.0, 1.0);
    float within = u >= 0.0 ? 1.0 : t * t * (3.0 - 2.0 * t);
    fragColor = texture(source, qt_TexCoord0) * (outside * within * qt_Opacity);
}
