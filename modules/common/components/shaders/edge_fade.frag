#version 440

// =============================================================================
// edge_fade.frag
//
// Fades a finished rendering out toward its edges, so whatever the host
// clips against never cuts anything hard. Used as a `layer.effect` over the
// phase rail's particle layer (canvas + bloom together), where sparks thrown
// past the status card's clip edge would end in a straight line.
//
// One mask over the whole texture, not a per-particle rule: a spark's trail
// and its bloom halo dim together, and nothing the particles are drawn over
// is touched, because only this layer passes through here.
//
// Geometry, in the layer's texture coordinates (0..1 across the layer):
//
//   edges.x   left   line where alpha reaches zero
//   edges.y   top       "
//   edges.z   right     "
//   edges.w   bottom    "
//   fade.x    width of the fade inward from the left and right lines
//   fade.y    width of the fade inward from the top and bottom lines
//
// Alpha is 0 on each line and smoothsteps to 1 at line + fade (inward); the
// four sides multiply, so a corner fades on both axes. Two fade widths, one
// per axis, because the layer is not square and the same number of pixels
// is a different fraction of each side.
//
// The texel is premultiplied (it is a layer texture), so scaling the whole
// vec4 by the factor keeps it premultiplied.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec4  edges;            // left, top, right, bottom (texcoord)
    vec2  fade;             // x, y fade widths (texcoord)
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 uv = qt_TexCoord0;
    // A zero fade must still be a step, not undefined smoothstep bounds.
    vec2 f = max(fade, vec2(1e-5));

    float factor = smoothstep(edges.x, edges.x + f.x, uv.x)
                 * smoothstep(edges.y, edges.y + f.y, uv.y)
                 * (1.0 - smoothstep(edges.z - f.x, edges.z, uv.x))
                 * (1.0 - smoothstep(edges.w - f.y, edges.w, uv.y));

    fragColor = texture(source, uv) * factor * qt_Opacity;
}
