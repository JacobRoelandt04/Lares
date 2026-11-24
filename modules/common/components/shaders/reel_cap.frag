#version 440

// =============================================================================
// reel_cap.frag
//
// Cuts a finished rendering to a rounded-rectangle outline, so the reel's
// icons end where the STRIP ends instead of where its clip rectangle does.
//
// thePopup's content is clipped to a rectangle while the popup itself ends in
// a curve, and an icon on its way out of the strip would show in the two
// corners the shape leaves out -- as ink lying on the wallpaper. Qt's own masking (MultiEffect.maskSource, OpacityMask) never
// took here, so the mask is a shader: one texture in, its alpha multiplied by
// the outline's coverage, out.
//
// Geometry is in PIXELS of the source item, not texture coordinates, so the
// radius means the same thing whatever the item's aspect is:
//
//   boxW, boxH   the item's size
//   radii        top-left, top-right, bottom-right, bottom-left
//   inset        how far INSIDE that outline the cut actually falls
//   pad          per-edge OUTWARD growth of the box (left, top, right, bottom)
//
// `pad` exists for one edge only: the one where the strip meets its bar. There
// is no outline to protect there -- the bar covers it -- and an inset applied
// to it eats a pixel of every icon crossing the join, which reads as a white
// line cut through the icon. Growing the box past that edge takes the cut, the
// feather and the inset off it entirely and leaves the item's own clip to do
// the work.
//
// TWO THINGS THAT WOULD LET INK OUT:
//
//   * a feather that STRADDLES the edge. smoothstep(-aa, aa, d) is still above
//     zero at d = +aa, so everything within `aa` OUTSIDE the box would be drawn
//     at falling opacity. The feather runs inward only: full at -aa, nothing
//     at the boundary itself.
//   * `aa` in the wrong units. This shader measures in the ITEM's own pixels
//     while the texture is `renderScale` times denser, so one DEVICE pixel is
//     1/renderScale of them -- an `aa` of renderScale * 0.75 is, at a magnified
//     stage, several device pixels of bleed rather than a fraction of one.
//
// `inset` is the tolerance on top of that: better to cut an icon a shade early
// than a shade late, since the fog has all but taken it by the time it is
// near the outline anyway. Offsetting a signed distance shrinks the whole
// rounded rectangle uniformly -- half-size AND radius -- which is exactly what
// an inset outline is, so there is nothing else to adjust.
//
// The texel is premultiplied (it comes from a ShaderEffectSource), so scaling
// the whole vec4 keeps it premultiplied.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    vec4  radii;            // tl, tr, br, bl
    // Pixels of feather, in the ITEM's units, running INWARD from the cut.
    // One device pixel is 1/renderScale of these.
    float aa;
    // How far inside the outline the cut falls, in the item's units.
    float inset;
    // Outward growth per edge: left, top, right, bottom. In the item's units.
    vec4 pad;
};

layout(binding = 1) uniform sampler2D source;

// Signed distance to a rounded rectangle centred on the origin, negative
// inside. `h` is the half-size; `r` the corner radius for this quadrant.
float sdRoundBox(vec2 p, vec2 h, float r)
{
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main()
{
    vec2 size = vec2(boxW, boxH);
    // The box, grown outward per edge. Sampling still spans the ITEM, so only
    // the shape the distance is measured against moves.
    vec2 lo = -pad.xy;
    vec2 hi = size + pad.zw;
    vec2 hbox = (hi - lo) * 0.5;
    vec2 p = qt_TexCoord0 * size - (lo + hi) * 0.5;

    // Which corner this pixel belongs to picks the radius.
    float r = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w)
                        : (p.y < 0.0 ? radii.y : radii.z);
    // Never more than half the box, or neighbouring corners eat each other.
    r = min(r, min(hbox.x, hbox.y));

    // Positive `inset` moves the boundary inward: offsetting a signed
    // distance shrinks the shape uniformly.
    float d = sdRoundBox(p, hbox, r) + inset;
    // Feather INWARD only -- nothing at all is drawn at or past the boundary.
    float cover = 1.0 - smoothstep(-max(aa, 0.0001), 0.0, d);

    fragColor = texture(source, qt_TexCoord0) * cover * qt_Opacity;
}
