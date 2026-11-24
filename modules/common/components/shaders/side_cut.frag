#version 440

// =============================================================================
// side_cut.frag
//
// A DISPLACED SwipeVerbCard's face (its layer's texture), cut to its host's
// outline and faded out along the side it is moving to (SideFade).
//
// Every length is in the item units of the SideFade's frame, so the numbers
// mean what the host's layout means whatever the stage's zoom:
//
//   layerRect   the face's layer item in the frame (x, y, w, h)
//   box         the host's RESTING outline at its live size (w <= 0: none)
//   radii       its corners: top-left, top-right, bottom-right, bottom-left
//   rest        the card at rest in the frame (its face's resting rect)
//   lines       the host's rectangular clip lines (left x, right x)
//   sides       1 where a side fades (x: left, y: right)
//   margin      how far INSIDE the outline the cut falls (the host's own
//               antialiased rim reaches that far in)
//   lead        fully clear from the cut line inward
//   rimPx       how far a resting card draws outside its rect (a carved bevel)
//   fadeLen     the long ramp after the lead
//   disp        the face's drawn offset (px, + = right)
//   cardRadius  the card's own corner radius
//   aa          one device pixel, in item units: the cut's feather
//
// THE CUT. Nothing is drawn outside the outline shrunk by `margin` (a signed
// distance, feathered INWARD only: smoothstep(-aa, 0, d)), nor past the
// host's clip lines. Where the outline's corners reach into a row, the row's
// cut follows the curve -- per pixel row, not one constant for the strip.
//
// THE ZERO LINE of a row is where its cut lies: the outline's edge at that
// row, never outside the host's clip line. Two ramps run in from it, both 0
// on it and for `lead` beyond:
//
//   short  up to the RESTING card's own edge in that row (its rounded corner
//          and its rim included): always on while the card is displaced, so a
//          card pushed to the cut is gone before it -- and nothing a resting
//          card draws lies under it, so a card displaced by a pixel changes by
//          a pixel's worth, never by a step.
//   long   `fadeLen` long (the list's own fade is 34), on with a STRENGTH that grows
//          with the displacement, |disp| / fadeLen -- a fade is a distance from
//          the rest, as ScrollDressing's is a distance from the end.
//
// alpha = cover x short x (1 - s (1 - long)). Only the side the card moves to
// fades; a card at rest is never drawn through here (SwipeVerbCard layers its
// face only while it is displaced).
//
// The texel is premultiplied (a layer's texture), so scaling the whole vec4
// keeps it premultiplied.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  layerRect;
    vec4  box;
    vec4  radii;
    vec4  rest;
    vec2  lines;
    vec2  sides;
    float margin;
    float lead;
    float rimPx;
    float fadeLen;
    float disp;
    float cardRadius;
    float aa;
};

layout(binding = 1) uniform sampler2D source;

// Signed distance to a rounded rectangle centred on the origin, negative
// inside. `h` is the half-size; `r` the corner radius for this quadrant.
float sdRoundBox(vec2 p, vec2 h, float r)
{
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// The left and right edge of a rounded rectangle (x, y, w, h; radii tl, tr,
// br, bl) at row y; an empty span for a row outside it.
vec2 rowSpan(vec4 b, vec4 rr, float y)
{
    float x0 = b.x;
    float x1 = b.x + b.z;
    float y0 = b.y;
    float y1 = b.y + b.w;
    if (y < y0 || y > y1)
        return vec2(1e6, -1e6);
    float hm = 0.5 * min(b.z, b.w);
    float tl = min(rr.x, hm);
    float tr = min(rr.y, hm);
    float br = min(rr.z, hm);
    float bl = min(rr.w, hm);
    float l = x0;
    float r = x1;
    if (y < y0 + tl) {
        float dy = y0 + tl - y;
        l = x0 + tl - sqrt(max(0.0, tl * tl - dy * dy));
    } else if (y > y1 - bl) {
        float dy = y - (y1 - bl);
        l = x0 + bl - sqrt(max(0.0, bl * bl - dy * dy));
    }
    if (y < y0 + tr) {
        float dy = y0 + tr - y;
        r = x1 - tr + sqrt(max(0.0, tr * tr - dy * dy));
    } else if (y > y1 - br) {
        float dy = y - (y1 - br);
        r = x1 - br + sqrt(max(0.0, br * br - dy * dy));
    }
    return vec2(l, r);
}

void main()
{
    vec2 p = layerRect.xy + qt_TexCoord0 * layerRect.zw;

    // ---- the cut ------------------------------------------------------------
    float cover = 1.0;
    vec2 span = vec2(-1e6, 1e6);
    if (box.z > 0.0 && box.w > 0.0) {
        // The outline shrunk by the margin: offsetting a signed distance
        // shrinks half-size and radius alike, so the row spans take the
        // shrunk box and radii to agree with it exactly.
        vec4 b = vec4(box.xy + margin, box.zw - 2.0 * margin);
        vec4 rr = max(radii - vec4(margin), vec4(0.0));
        vec2 h = 0.5 * b.zw;
        vec2 q = p - (b.xy + h);
        float r = q.x < 0.0 ? (q.y < 0.0 ? rr.x : rr.w) : (q.y < 0.0 ? rr.y : rr.z);
        r = min(r, min(h.x, h.y));
        cover = 1.0 - smoothstep(-max(aa, 0.0001), 0.0, sdRoundBox(q, h, r));
        span = rowSpan(b, rr, p.y);
    }
    // The host's clip lines: whole pixels, and pixel centres lie on halves,
    // so a plain step cuts exactly where the host's own clip does.
    cover *= step(lines.x, p.x) * step(p.x, lines.y);

    // ---- the zero lines and the two ramps -----------------------------------
    float zl = max(lines.x, span.x);
    float zr = min(lines.y, span.y);
    // The resting card's own edge in this row (its slack rows take the
    // nearest row of the card), less the rim it draws outside itself.
    float ry = clamp(p.y, rest.y + 0.5, rest.y + rest.w - 0.5);
    vec2 own = rowSpan(rest, vec4(cardRadius), ry) + vec2(-rimPx, rimPx);
    float L = max(fadeLen, 0.0001);
    float s = clamp(abs(disp) / L, 0.0, 1.0);
    // A resting card that OVERHANGS its zero line (the lane narrowing from
    // its far edge while it closes, the content anchored at the near one)
    // leaves the short ramp no room: it would collapse to its 1 px floor and
    // cut the card. There the long ramp takes over at full strength, eased in
    // over the last pixel of room so the switch cannot pop.

    float a = cover;
    if (sides.x > 0.5 && disp < 0.0) {
        float d = p.x - zl - lead;
        float sl = own.x - zl - lead;
        float shortRamp = clamp(d / max(1.0, sl), 0.0, 1.0);
        float longRamp = clamp(d / L, 0.0, 1.0);
        a *= shortRamp * (1.0 - max(s, clamp(1.0 - sl, 0.0, 1.0)) * (1.0 - longRamp));
    }
    if (sides.y > 0.5 && disp > 0.0) {
        float d = zr - lead - p.x;
        float sl = zr - lead - own.y;
        float shortRamp = clamp(d / max(1.0, sl), 0.0, 1.0);
        float longRamp = clamp(d / L, 0.0, 1.0);
        a *= shortRamp * (1.0 - max(s, clamp(1.0 - sl, 0.0, 1.0)) * (1.0 - longRamp));
    }

    fragColor = texture(source, qt_TexCoord0) * (a * qt_Opacity);
}
