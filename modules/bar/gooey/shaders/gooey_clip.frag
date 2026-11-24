#version 440

// =============================================================================
// gooey_clip.frag
//
// Cuts a popup's CONTENT to the outline the gooey field drew that popup with.
//
// GooeyBody clips its content to a RECTANGLE, and the field draws the popup as
// a box whose every corner is cut by its own ellipse. At rest the two differ by
// a 20 px corner and nobody notices; while a popup opens, surface tension
// inflates that corner to half the popup's size, so the content -- tiles, cards,
// a list -- would be drawn across the curve and out onto the wallpaper. This is the
// same distance function the surface itself is drawn with, used as a mask.
//
//   box          the body's DRAWN outline, x0, y0, x1, y1, in the ITEM's pixels.
//                Not the item's own rect: a face the field snapped flush with a
//                bar's end is drawn somewhere else, and the cut follows the ink.
//   ex, ey       the corner ellipse's semi-axes, per corner TL, TR, BR, BL.
//   ix, iy       the ellipse centre's inset from that corner. Equal to the
//                semi-axes for a plain rounded corner; smaller along one axis
//                where the corner is half of an S-curve into a bar.
//   aa           the feather, in the ITEM's units. ONE DEVICE PIXEL: the layer
//                is renderScale times denser, so a device pixel is 1/renderScale
//                of the units measured here. (A body may widen it for its whole
//                outline: the flourish's clipFeather, which culls its text.)
//   inset        how far INSIDE the outline the cut falls, on top of that.
//   lim          a second box, x0, y0, x1, y1, item px, the content is also cut
//                to, with the same feather `aa` inward from each of its edges
//                that lies inside `box`: the flourish cut at the face of the bar
//                it sinks into (GooeyEngine.setFlourishCut). Default far outside
//                the item.
//
// With lim outside the box nothing below runs but the cut above: the bytes of a
// body that does not use it are the bytes before it.
//
// Only what the field ADDS beyond a body -- the fillets where it melts into its
// bar, the seams along a shared face -- is left out, and leaving material out of
// a mask can only cut ink early, never let it escape.
//
// The feather runs INWARD ONLY: smoothstep(-aa, aa, d) is still above zero at
// d = +aa, which draws everything within a pixel OUTSIDE the outline, which is
// the ink this shader exists to stop.
//
// The texel is premultiplied (it comes from the item's layer), so scaling the
// whole vec4 keeps it premultiplied.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float boxW;             // the item's own size, in px
    float boxH;
    float aa;               // feather, item units, inward from the cut
    float inset;            // extra tolerance, item units
    vec4  box;              // the drawn outline: x0, y0, x1, y1
    vec4  ex;               // ellipse semi-axes, TL, TR, BR, BL
    vec4  ey;
    vec4  ix;               // ellipse centre inset from the corner
    vec4  iy;
    vec4  lim;              // a second cut box x0, y0, x1, y1 (item px)
};

layout(binding = 1) uniform sampler2D source;

float sdBox(vec2 p, vec2 lo, vec2 hi) {
    vec2 c = 0.5 * (lo + hi);
    vec2 q = abs(p - c) - 0.5 * (hi - lo);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Signed distance to an axis-aligned ellipse centred on the origin: the usual
// first-order approximation, exact to first order at the boundary, which is
// the only place it is used.
float sdEllipse(vec2 p, vec2 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    // The centre, in radii (gooey_field.frag: k1 is tiny on a huge outline too).
    if (k0 < 1e-4)
        return -min(r.x, r.y);
    return k0 * (k0 - 1.0) / k1;
}

const float TINY = 0.05;

// A corner's cut: its ellipse (semi-axes e, centre inset from the corner)
// removes material only inside the corner's REGION, the rectangle its inset
// spans in from the corner. `s` points to the corner (-1 low, +1 high on each
// axis). A plain rounded corner's region is at most its quadrant, so for every
// body whose corners each keep to their half of a side this is the quadrant
// rule exactly; a corner whose neighbour on a side is square may reach past the
// middle of that side (a popup's end resting on a bar's end rounds over its
// whole side and on into the bar's corner). Where two regions overlap every cut
// applies: the S-curve pieces' insets reach far past their quadrant, but their
// ellipses contain the box there, so they cut nothing new.
float cornerCut(float d, vec2 c, vec2 half_, vec2 s, float ex, float ey, float ix, float iy) {
    if (min(ex, ey) < TINY || min(ix, iy) < TINY)
        return d;
    vec2 q = s * c - (half_ - vec2(ix, iy));
    if (q.x > 0.0 && q.y > 0.0)
        return max(d, sdEllipse(q, vec2(ex, ey)));
    return d;
}

// gooey_field.frag's bodyDist, unchanged.
float bodyDist(vec2 p, vec4 b, vec4 exs, vec4 eys, vec4 ixs, vec4 iys) {
    vec2 lo = b.xy, hi = b.zw;
    float sb = sdBox(p, lo, hi);
    vec2 c = p - 0.5 * (lo + hi);
    vec2 half_ = 0.5 * (hi - lo);
    // The inset is NOT clamped to the box: the centre of a shallow S-curve
    // piece lies far beyond it. The free radii are clamped to half the box
    // where they are computed.
    float d = cornerCut(sb, c, half_, vec2(-1.0, -1.0), exs.x, eys.x, ixs.x, iys.x);
    d = cornerCut(d, c, half_, vec2(1.0, -1.0), exs.y, eys.y, ixs.y, iys.y);
    d = cornerCut(d, c, half_, vec2(1.0, 1.0), exs.z, eys.z, ixs.z, iys.z);
    return cornerCut(d, c, half_, vec2(-1.0, 1.0), exs.w, eys.w, ixs.w, iys.w);
}

// One edge of `lim`: 0 on its line (less the inset), 1 at `aa` inside it.
float edgeRamp(float inside) {
    return smoothstep(0.0, max(aa, 1e-4), inside - inset);
}

void main()
{
    vec2 p = qt_TexCoord0 * vec2(boxW, boxH);
    float d = bodyDist(p, box, ex, ey, ix, iy) + inset;
    float cover = 1.0 - smoothstep(-max(aa, 1e-4), 0.0, d);
    // The second box: only an edge of it that lies inside the first.
    if (lim.x > box.x)
        cover *= edgeRamp(p.x - lim.x);
    if (lim.y > box.y)
        cover *= edgeRamp(p.y - lim.y);
    if (lim.z < box.z)
        cover *= edgeRamp(lim.z - p.x);
    if (lim.w < box.w)
        cover *= edgeRamp(lim.w - p.y);
    fragColor = texture(source, qt_TexCoord0) * cover * qt_Opacity;
}
