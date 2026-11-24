#version 440

// =============================================================================
// gooey_field.frag
//
// The bars and every popup as ONE surface, drawn as the HARD union of three
// kinds of primitive that GooeyGeometry.js works out every frame:
//
//   BODIES   a box whose every corner is cut by its own ELLIPSE: semi-axes
//            (x, y), centre inset (u, v) from the corner. A plain rounded
//            corner has the inset equal to the semi-axes. A corner that is half
//            of a short S-curve has a smaller inset along one axis, so its arc
//            leaves the side tangentially and meets the face at an angle -- the
//            angle the other half of the S picks up. An ellipse cuts only
//            inside its corner's region (the rectangle its inset spans), so a
//            corner whose neighbour is square may round over the whole side.
//   FILLETS  the concave piece where two bodies join: a rectangle from a
//            vertex V to V + e, minus an ellipse (centre and semi-axes given).
//            Its arc is tangent to the side it runs down and meets the face at
//            the S-curve's angle (a right angle, for a full-size fillet).
//   SEAMS    thin rectangles laid over a line two bodies share, so their
//            interiors OVERLAP there. Two shapes whose interiors only meet on
//            a line leave a half-covered row along it -- the hairline v1's
//            smooth union existed to avoid.
//
// Fillet rectangles are grown by a bleed toward the faces they join (per
// fillet, per axis: a void flare has open air on one side and must not bleed
// into it), for the same reason as the seams.
//
// Why explicit geometry and not a smooth union (v1): a pointwise blend of
// two distances cannot be anisotropic -- its fillet is a circle whatever room
// the join has. The shapes the bar needs are not circles: a join a few pixels
// wide and forty tall, a fillet stretched along the bar while its popup opens,
// a fillet no taller than a popup that is itself five pixels tall.
//
// NO ARRAYS, NO LOOPS OVER THEM. A local GLSL array built from uniforms and
// indexed by a loop counter cannot be split by the compiler when the loop has a
// data-dependent exit, so iris puts it in SCRATCH MEMORY: every fragment
// dispatch copied 240 floats out with one memory send each, BEFORE any early-out
// could skip them (measured: 240:10 spills:fills, and the cost stayed flat
// however many fillets a pixel really touched). So every primitive is evaluated
// on its own named uniform, under guards nested by the counts -- flat guards let
// the compiler hoist the pulls back out. The block is generated, because there
// are 12 + 24 + 24 of them.
//
// COVERAGE is centred on the edge and one device pixel wide at any zoom: the
// distance divided by its own screen-space gradient, capped at the linear
// pixel size (a kink's derivatives overshoot it; see main). The ellipse distance is
// the usual first-order approximation, k0 (k0 - 1) / k1, exact to first order
// at the boundary for any semi-axes, which is the only place it is used.
//
// TINT. Up to three bodies may carry a colour of their own (a note's colour on
// its popup); the rest are the surface colour. The colour is poured, not cut:
// every covered pixel takes the colours of the groups near it, weighted by how
// much farther than the nearest group each one's BOX is -- (1 - x / reach)^2,
// 0 from `reach` on. The distances are taken OUTSIDE each box only (0 inside):
// inside a popup the share of the bar's colour then depends on the distance
// from the bar alone, so the ramp is one band along the face, `reach` deep on
// each side of it, also down the popup's free sides (the signed distance there
// is near 0 and took the ramp twice as deep); in a fillet it is the 45-degree
// line between the two faces, and round a corner a circle. Monotone, no step,
// and a body's interior past `reach` is exactly its colour.
// Only coverage decides the shape; the tint never moves an edge. Which bodies
// carry a tint is three floats in the uniform block's padding (the block the
// counts are in); the colours arrive as varyings from the vertex shader, so the
// block pulls no uniform the evaluation above did not already. With no tint it
// is one branch not taken: the untinted output is unchanged.
//
// THE SMOOTH GROUP. Bodies whose bit is set in smoothMask leave the hard union
// and its box early-out, and blend with EACH OTHER by the classic quadratic
// smooth-min of radius smoothK, chained in slot order; the group's distance then
// joins the rest by the hard min. That is the metaball neck: two members a gap g
// apart are joined while g < k/2, the neck narrows to a point at exactly k/2 and
// is gone from there. The neck narrows only where
// a face CURVES away: between two flat faces both distances are constant along
// them, so any pointwise blend is a membrane as wide as the faces that tears
// across its whole width at k/2 (measured: 178 of its 195 px gone within one
// pixel of gap). smin's gradient is a convex mix of its two, never steeper, so the capped
// coverage holds; a member is skipped only when its box lies a whole k behind
// the group, where smin returns the group's distance exactly. GooeyField tiles
// each member's box grown by k/4 (smin never undercuts the min by more).
//
// THE RIPPLE. One body -- always slot 0 (GooeyField puts it there) -- has one
// face displaced by an analytic height field h(s), s along the face: a bulge and
// up to three damped dispersive packets from smoothed sources, with their
// reflections in the bar's ends as unrolled image sources (rippleOrders, nested),
// tapered off round end corners and floored by tanh so a trough leaves the bar a
// pixel. Troughs remove the bar's OWN material, which no union term could. The
// moving side's distance is taken along the face's normal and divided by
// sqrt(1 + h'^2) with h' analytic: a unit gradient however steep the flank (a
// capped column distance would antialias it vertically, sharper than a pixel).
// Its early-out box is grown by the crest bound, and it is evaluated LAST, after
// every other body, so that box can skip it against them. Everything that
// depends on time alone is reduced per frame in GooeyRipple.js -- the JS twin of
// rippleFaceAt, term for term -- and h is exactly 0 from Tend on, when the field
// draws its idle bytes again.
//
// THE NECK. While the launcher's confirm flourish pulls out of the closing
// launcher the group is not a blend of the two: it is an EXPLICIT bridge (neckBridge) --
// the card and the launcher each blended to a neck of two capsules on their own
// radii, never to each other -- so the card keeps its corners, the waist is
// where the pose puts it and its corners are as round as the radii say. Its
// 17 numbers are aliased onto the ripple's lanes (the two are never on
// together). With the neck off every lane reads 0 and the field draws the same
// bytes.
//
// THE PACKED LANES. Neither adds a member to the uniform block: the fillet
// bleeds g0..g23 only use x and y, and g0..g11 lie inside the fragment shader's
// PUSH window on iris, so the group's and the ripple's 24 numbers live in their
// z and w (@@PACK, named by #define; tools/dev/gooey_field_ubo.py has the numbers).
// Both off, every lane reads 0 and every body takes the plain chain:
// the same bytes. The cost is SIMD32: iris compiles it only with its
// scheduler at the last resort ("mode none"), and any added code -- even this
// file's evaluation reordered with neither feature -- fails its register
// allocation; SIMD8 and SIMD16 remain.
//
// THE SHELL'S EDGE. A SHADOW under everything the field draws and a BORDER round it,
// both off unless a host asks (GooeyField.shadowReach / borderWidth), and both
// nothing but the field's own signed distance d read a second way.
//   SHADOW   The vertex shader keeps the shadow's tiles in the first half of the tile list and
//            the shape's in the second (the mesh draws them in that order), and tells a
//            fragment which it is by the sign of vTile. A shadow tile is the SAME field
//            read a second way (a halo: one band round the outline, with no drop-shadow
//            offset), so the shadow follows every body in motion -- popups, the
//            flourish's card, the droplets, the ripples, the lane, the OSD -- because it is
//            made of the same d. Its ink is the colour times a smooth fall from 1 at the
//            edge to 0 at `reach` (shadowParam.z). It is drawn before the shape, so the shape
//            lands on top (premultiplied: shape * cov + shadow * (1 - cov)), and its tiles
//            leave out the shape's deep inside (GooeyField), where it would be covered.
//            Its SHAPE is the bodies' smooth union (groupBit) and the SKY's fillets, exact:
//            fillets between bodies and seams are left out, because such a fillet only rounds a
//            corner the surface is drawn with, and read as the shadow's shape it left a dimple at
//            the middle of every arc; a sky fillet (an island's flare into the screen's edge) is
//            the shape itself, taken as drawn, so the band keeps its thickness round the curve.
//   BORDER   A ring just OUTSIDE the surface, 0 < d < w, in the border colour (borderColor,
//            its width shadowParam.w; 0 is off). Outside, d is the exact distance to the
//            union (the min of the primitives' own distances is exact there), so the ring
//            is `w` wide everywhere along the outline, round every concave join and fillet.
//            Inside, d is only a LOWER BOUND on the depth (a fillet's bleed, a seam, two
//            bodies sharing a face each have an inner edge of their own that min() cannot
//            tell from the outline): an inside ring drew a band along every join. Outside
//            there is nothing to confuse, and the screen's edge needs no mask: a bar flush
//            with it has its top face's ring off the screen, and the rings of its sides run
//            to the edge and stop with the window.
//
// THE AURA. The shadow's halo can LIGHT UP with a few hues flowing round the outline, under large slow value noise (a siri-like look), for an event the shell chooses. It is the shadow tile's
// ink read once more -- nothing in the shape's tiles -- and it costs a rest frame ONE test: shadowShape.z, the aura's level, is
// 0 until a host plays one, and the whole branch (the body routing, the perimeter, the noise, the palette) is behind it.
//   LEVEL, TIME   shadowShape.z (0 .. 1, the envelope times the strength) and .w (seconds, the host's one clock)
//   REACH         shadowParam.x: how far the halo reaches (px past the surface, plus the border)
//   PALETTE       auraC0..C3.rgb, four hues round a cycle
//   GROUPS        auraC3.w is a mask of the bodies of GROUP A (the centre island and all that hangs from it, a popup's secondary with
//                 its popup); auraC0.w and auraC1.w the ink shown of group A and of the rest (1 1 all, 1 0 group A alone, 0 1 the rest
//                 alone; between them while a group is handed over, GooeyEngine._auraGroups). Each pixel belongs to the group whose body
//                 is nearer, a soft HAND-OVER (auraHand), and the shares gate the ink by it (auraGate).
//   LOOPS         a coordinate is one loop round one outline, and there are three: group A's, the frame's (auraFrame: the bars of the rest),
//                 and the CHAIN's: the largest popup of the rest with what hangs from it (auraChain, auraChainMid.w its mask). A popup hanging
//                 from a slim bar is a loop of its own because the frame's cannot serve it: a coordinate on a rectangle 1500 px
//                 away runs fast and grazes the screen's edges there, a rainbow on the popup's side. Each pixel's COLOUR is mixed from the
//                 loops by the same hand-over: by the RATIO of the two box distances, not their difference, so the band is an angle round
//                 the point where two loops meet and widens with the distance from it -- a fixed 20 px band was a seam out of every junction,
//                 where the two loops' hues part linearly with the distance (each runs along its own face) and the band crossed that
//                 difference in 20 px however far out.
//   COORDINATE    where the pixel stands round a loop, 0 .. 1 clockwise from the top-left corner of the loop's rectangle (the bounding box
//                 of its bodies): outside the rectangle its nearest point on the outline, inside it the point where the ray from the
//                 loop's middle (auraMid, auraChainMid) through the pixel leaves the rectangle. A function of the position alone and
//                 continuous everywhere but at the middle, which lies under a body (a pixel of the frame's halo never comes near
//                 the screen's middle), so a joint between two bodies of a loop is nothing to it, and no line of the plane is special.
//                 A whole number of waves go round (the frame's auraC2.w; group A's and the chain's through THE JOIN), so the palette
//                 closes on itself.
//   THE JOIN      where group A's or the chain's bodies touch the frame's (the OSD on a slim bar, a popup or a toast stack under a side
//                 island, the continuous bar on the side bars), two unrelated hues met at the hand-over and drew a seam out of each junction
//                 (the user, round 5: the mic card's corners). So such a loop's hue (auraJoinA, auraJoinC; GooeyAura.joinOf) is the FRAME's
//                 at its two junctions and runs between them round its free arc, as the outline of the whole surface does: down the bar,
//                 round the popup, back on the bar -- from the junction the frame's coordinate comes from, so its waves flow on, with a
//                 whole number of its own added (auraJoinU). A loop that touches the frame nowhere is its own plain loop.
//   NOISE         value noise ON THE SCREEN, AURA_CELL px to a cell, drifting with time; it warps the hue, brightens and dims the waves
//                 and breathes the reach. Not on the coordinate: where a loop's coordinate runs fast the reach would run as fast (the
//                 user's "very narrow localized gradient"); on the screen its slope is the same whatever the popup's length. Two
//                 octaves, no integer maths (GLSL 1.20).
//   THE COVE      the aura reads its own distance: d with each of the sky's flares' two ENDS smooth-unioned into the rest (the bodies' own
//                 smooth union, dBody) instead of the hard min (auraCoveEnds). A flare ends ON the screen's edge, so past it the nearest point of the outline is that end,
//                 and the exact d has a crease where the end and the island's side are equally near -- a parabola out of the cove, a
//                 dark seam in a glow of d (the user: "some darker line ... not present in the bar joint corners"; the joints are the
//                 bodies' smooth union). The blend's radius is the joints' (AURA_COVE) times how far the two gradients turn from each
//                 other: nothing where the arc's end on the island's own side meets that side tangentially, the whole radius across
//                 the right angle where the crease starts. The shadow keeps the exact d; the cost is behind the aura's test.
//
// THE REEL PASS (`REEL_PASS`, baked a second time as gooey_reel.frag.qsb: tools/dev/bake_shaders.sh, the QSB-VARIANT line below). The field
// draws its ring and its halo only OUTSIDE its union, and a reel-slot body (the power / idle reel's strip, the tray's strip, its label and
// its menus) over an open popup is inside it: no ring, no halo, no fillet where the strip leaves the bar -- a card that reads as painted
// on. The reel pass is THIS FILE compiled with REEL_PASS and drawn as an overlay over the popups' content and under the strip's
// (ReelCast.qml), on the SAME shape of the same frame (GooeyField hands ReelCast every shape it draws: the same bodies, fillets and seams,
// in another order): what the field would draw of the reel group and the bars it hangs from if the popup were not there.
//   THE CLASSES   the bodies come sorted: the first reelR are the reel GROUP (the strip, then its levels), the next reelB the BARS near
//                 it, the rest the POPUPS under it; the fillets likewise, the first reelFM the group's and its bars' own (both ends
//                 in the union), the rest the popups'; the seams are the union's alone.
//   THE UNION     d is the field's distance to the group and its bars and nothing else, through the same functions: the hard min, the
//                 fillets and the seams in a shape tile (the FILL, coverage, and the RING, 0 < d < w); the bodies' smooth union in a
//                 halo tile (the HALO, the shadow's fall, term for term).
//   THE SHARE     the ring and the halo are the REEL's alone -- the bar's underside has neither over a popup that hangs from it -- so
//                 both are weighted by the reel's share of the union: the weight a smooth-min of radius reelBlend (the fillets' own
//                 size) gives the group's distance against the bars', 1/2 + (dBars - dGroup) / (2 reelBlend), clamped. On the strip's
//                 free sides it is 1; along a fillet it falls from 1 where the arc leaves the strip to 0 where it lands on the bar,
//                 so the ring curves out with the joint and is gone where it is the bar's; on a side where the strip is one with a
//                 bar (the reel at an island's end, on the slim bar) there is nothing to weight: no outline, no ring.
//   THE CUT       everything is multiplied by the popups' own drawn coverage (their bodies and fillets, the field's own coverage ramp):
//                 where the group leaves the popup the field's ring and halo take over on the same line.
//   THE INK       the ring and the halo are also multiplied by the ink of the nearest body of the group (its content's fade: in with
//                 an open, out with the merge into the bar); the fill is not -- it is the surface, as the field's is.
// Nothing here is compiled into the field: every line is behind REEL_PASS, and the field's pack is the same bytes with or without it.
// QSB-VARIANT: gooey_reel REEL_PASS
// =============================================================================

layout(location = 0) in vec2 vPos;
layout(location = 1) in float vTile;
// The tint colours (premultiplied) and their reach, from the vertex shader.
layout(location = 2) in vec4 vTintA;
layout(location = 3) in vec4 vTintB;
layout(location = 4) in vec4 vTintC;
layout(location = 5) in float vTintReach;
layout(location = 0) out vec4 fragColor;

// @@UBO-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    float shadowTiles;
    vec4  fieldColor;
    float bodyCount;
    float filletCount;
    float seamCount;
    float tileCount;
    float showTiles;
    float tintIdA, tintIdB, tintIdC;
    vec4  b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11;
    vec4  x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11;
    vec4  y0, y1, y2, y3, y4, y5, y6, y7, y8, y9, y10, y11;
    vec4  u0, u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11;
    vec4  v0, v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11;
    vec4  f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11;
    vec4  f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23;
    vec4  k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, k10, k11;
    vec4  k12, k13, k14, k15, k16, k17, k18, k19, k20, k21, k22, k23;
    vec4  g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11;
    vec4  g12, g13, g14, g15, g16, g17, g18, g19, g20, g21, g22, g23;
    vec4  s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
    vec4  s12, s13, s14, s15, s16, s17, s18, s19, s20, s21, s22, s23;
    vec4  shadowColor, borderColor, shadowParam, shadowShape;
    vec4  auraC0, auraC1, auraC2, auraC3, auraRect, auraFrame, auraChain, auraMid, auraChainMid, auraJoinA, auraJoinC;
    vec4  t0, t1, t2, t3, t4, t5, t6, t7;
    vec4  t8, t9, t10, t11, t12, t13, t14, t15;
    vec4  t16, t17, t18, t19, t20, t21, t22, t23;
    vec4  t24, t25, t26, t27, t28, t29, t30, t31;
    vec4  t32, t33, t34, t35, t36, t37, t38, t39;
    vec4  t40, t41, t42, t43, t44, t45, t46, t47;
    vec4  t48, t49, t50, t51, t52, t53, t54, t55;
    vec4  t56, t57, t58, t59, t60, t61, t62, t63;
    vec4  t64, t65, t66, t67, t68, t69, t70, t71;
    vec4  t72, t73, t74, t75, t76, t77, t78, t79;
    vec4  t80, t81, t82, t83, t84, t85, t86, t87;
    vec4  t88, t89, t90, t91, t92, t93, t94, t95;
    vec4  tintA, tintB, tintC;
    float tintReach;
};
// @@UBO-END
// @@PACK-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
#define smoothMask g0.z
#define smoothK g0.w
#define rippleMode g1.z
#define rippleCrest g1.w
#define rippleOrders g2.z
#define rippleFloor g2.w
#define rippleSrc0q g3.z
#define rippleSrc0r g3.w
#define rippleSrc0a g4.z
#define rippleSrc0p g4.w
#define rippleSrc1q g5.z
#define rippleSrc1r g5.w
#define rippleSrc1a g6.z
#define rippleSrc1p g6.w
#define rippleSrc2q g7.z
#define rippleSrc2r g7.w
#define rippleSrc2a g8.z
#define rippleSrc2p g8.w
#define rippleInvSigma g9.z
#define rippleK g9.w
#define rippleA2 g10.z
#define rippleBulgeAt g10.w
#define rippleBulgeAmp g11.z
#define rippleBulgeInv g11.w
#define rippleSrc0 vec4(rippleSrc0q, rippleSrc0r, rippleSrc0a, rippleSrc0p)
#define rippleSrc1 vec4(rippleSrc1q, rippleSrc1r, rippleSrc1a, rippleSrc1p)
#define rippleSrc2 vec4(rippleSrc2q, rippleSrc2r, rippleSrc2a, rippleSrc2p)
#define neckB rippleCrest
#define neckAx rippleOrders
#define neckAy rippleFloor
#define neckMux rippleSrc0q
#define neckMuy rippleSrc0r
#define neckLx rippleSrc0a
#define neckLy rippleSrc0p
#define neckMlx rippleSrc1q
#define neckMly rippleSrc1r
#define neckRA rippleSrc1a
#define neckQU rippleSrc1p
#define neckRL rippleSrc2q
#define neckQL rippleSrc2r
#define neckKA rippleSrc2a
#define neckKB rippleSrc2p
#define neckKMid rippleInvSigma
#define neckKJoin rippleK
#define neckA vec2(neckAx, neckAy)
#define neckMu vec2(neckMux, neckMuy)
#define neckL vec2(neckLx, neckLy)
#define neckMl vec2(neckMlx, neckMly)
// @@PACK-END

float sdBox(vec2 p, vec2 lo, vec2 hi) {
    vec2 c = 0.5 * (lo + hi);
    vec2 q = abs(p - c) - 0.5 * (hi - lo);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Signed distance to an axis-aligned ellipse centred on the origin.
float sdEllipse(vec2 p, vec2 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    // At the centre the approximation reads 0 (on the outline): it is inside.
    // Tested on k0, the distance in radii: k1 is also tiny on the OUTLINE of
    // an ellipse a few thousand px across (a tight S's fillet, which is one
    // near-flat arc), and reading that as the centre dropped the fillet whole.
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

// One body folded into the running distance. Rounding only removes material,
// so a body can never be nearer than its box: skip it when the box already loses.
float withBody(float d, vec2 p, vec4 b, vec4 exs, vec4 eys, vec4 ixs, vec4 iys) {
    if (sdBox(p, b.xy, b.zw) >= d)
        return d;
    return min(d, bodyDist(p, b, exs, eys, ixs, iys));
}

// One device pixel, as main works it out.
float fieldPx = 1.0;

// One fillet (rect from V to V + e, grown by its bleed, minus an ellipse).
// PAST THE RECT, IN THE ELLIPSE, the piece's nearest point is where its arc ends on the rect's edge, sqrt(dr^2 + de^2) away (the arc
// meets that edge at about a right angle: exact for a full fillet, and for a short S's the angle is a degree or two off). max(dr, -de)
// there is only a lower bound, and the BORDER reads d at w off the outline: the ring of a fillet's arc runs on past the arc's end, w
// further round its concentric circle, and stops on the rect's own line, half a pixel from the ring of the corner below it -- a
// spur on the outer edge of the ring at the middle of every S. Only the ring reads d that far out, so the sharper distance is taken 1.5 px off the outline and
// beyond: the antialiasing there reads d over one pixel and a neighbour's difference, so the surface's own coverage stays the same bytes.
float withFillet(float d, vec2 p, vec4 f, vec4 k, vec4 g) {
    vec2 v = f.xy;
    vec2 e = f.zw;
    if (abs(e.x) < TINY || abs(e.y) < TINY)
        return d;
    vec2 s = sign(e);
    vec2 back = v - s * g.xy;
    vec2 lo = min(back, v + e);
    vec2 hi = max(back, v + e);
    float dr = sdBox(p, lo, hi);
    if (dr >= d)
        return d;
    float de = sdEllipse(p - k.xy, max(k.zw, vec2(TINY)));
    if (dr > 0.0 && de < 0.0 && max(dr, -de) > 1.5 * fieldPx)
        return min(d, length(vec2(dr, de)));
    return min(d, max(dr, -de));
}

// THE SKY in a SHADOW tile (header, THE SHELL'S EDGE): the EXACT distance to an island's flare into the screen's edge, so the
// shadow is one band of the same thickness round the curve. withFillet's max(rect, -ellipse) is right on
// the outline and inside, but outside it is only a lower bound: in the cove, past the arc's quarter, it reads ~10 px where the
// flare is 28 away, and the halo would draw a blob there. Inside the flare: that same value. In the quadrant of the ellipse's centre
// that faces the vertex: the distance to the arc. Anywhere else the nearest point is one of the arc's ends, (V.x, C.y) and
// (C.x, V.y) -- the faces beyond them are the island's side and the screen's edge, covered or off the screen.
float skyFillet(vec2 p, vec4 f, vec4 k, vec4 g) {
    vec2 v = f.xy;
    vec2 e = f.zw;
    if (abs(e.x) < TINY || abs(e.y) < TINY)
        return 1e9;
    vec2 s = sign(e);
    vec2 back = v - s * g.xy;
    float dr = sdBox(p, min(back, v + e), max(back, v + e));
    float de = sdEllipse(p - k.xy, max(k.zw, vec2(TINY)));
    if (dr <= 0.0 && de >= 0.0)
        return max(dr, -de);
    vec2 q = (p - k.xy) * sign(v - k.xy);
    if (q.x >= 0.0 && q.y >= 0.0)
        return abs(de);
    return min(length(p - vec2(v.x, k.y)), length(p - vec2(k.x, v.y)));
}

// ---- THE SMOOTH GROUP --------------------------------------------------------
// The classic quadratic smooth-min, radius k. Its gradient is a convex mix of the
// two it blends (weights in [0, 1] summing to 1), so it is never steeper than
// they are and the capped-gradient coverage in main holds.
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// THE SHADOW'S UNION FILLETS ONLY WHAT IS CONCAVE (feedback/general.md "Secondary popup shadow issue at seam"). The plain smooth-min
// lowers the distance wherever two bodies' distances agree, and under the seam of a popup and its flush secondary (their feet on one
// line, the union's outline one straight foot) they agree all the way down: the fillet's k/4 came out as a dark spot under the seam.
// A fillet belongs where the union is CONCAVE between the two bodies: where the way from one's nearest point to the other's runs
// OUTSIDE both. Its middle `m` is tested against both boxes: a cove (a popup's side under a bar's face), a step (a shorter popup
// beside a taller secondary), a gap between two bodies all have it out by half their offsets and keep the whole fillet once that is a
// pixel; two feet on one line have it ON a foot (0) and get none, and bodies laid over each other (a travel's two slots) none either.
// A body is its BOX here (its nearest point a clamp; a corner's ellipse only moves it a little), and the running union carries the
// nearer body's box. Where the weight is 1 the sum is the plain smin's to the bit; the shape's own tiles keep the plain smin.
float sdBoxOut(vec2 p, vec4 b) {
    return length(p - clamp(p, b.xy, b.zw));
}
float sminFaces(float a, inout vec4 ba, float b, vec4 bb, vec2 p, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    vec2 m = 0.5 * (clamp(p, ba.xy, ba.zw) + clamp(p, bb.xy, bb.zw));
    float w = clamp(min(sdBoxOut(m, ba), sdBoxOut(m, bb)), 0.0, 1.0);
    float r = min(a, b) - h * h * k * 0.25 * w;
    ba = a < b ? ba : bb;
    return r;
}

// Bit i of the group's mask (inv = 2^-i, a literal): 1 when body i blends. In a SHADOW tile (vTile < 0,
// THE SHELL'S EDGE) every body does: the shadow is the smooth union of the bodies (radius smoothK, which
// GooeyField sets to its shadowBlend when no group of its own is out), so a concave corner and a narrow gap
// between two bodies are rounded and a little darker, as a blurred shadow is, instead of a crease where the
// nearest face changes -- and ONLY those: two faces that continue one another (a secondary's foot on its
// popup's) get no fillet (sminFaces).
float groupBit(float mask, float inv) {
    if (vTile < 0.0)
        return 1.0;
    float q = floor(mask * inv);
    return q - 2.0 * floor(q * 0.5);
}

// One body into the hard-min chain -- skipped when its box already loses, as
// withBody -- or into the smooth group, skipped when its box is a whole blend
// radius behind the group's distance (smin returns that distance EXACTLY then,
// so the skip changes nothing).
// With a NECK drawn (neckB > 0, which a ripple's lane also is: only with no ripple), slot neckB - 1 is side B and goes to dsB whole,
// never skipped; the one other member is side A in ds (smin into the empty 1e9
// is that member's own distance). With no neck neckB is 0, no slot is B, and the
// group chain is the plain one.
float withGroup(float d, inout float ds, inout float dsB, inout vec4 gds, float grp, float slot, vec2 p, vec4 b, vec4 exs, vec4 eys, vec4 ixs, vec4 iys) {
    float sb = sdBox(p, b.xy, b.zw);
    bool isB = rippleMode < 0.5 && neckB == slot;
    if (grp > 0.5 ? (!isB && sb >= ds + smoothK) : sb >= d)
        return d;
    float e = bodyDist(p, b, exs, eys, ixs, iys);
    if (grp > 0.5) {
        if (isB)
            dsB = min(dsB, e);
        else if (vTile < 0.0)
            ds = sminFaces(ds, gds, e, b, p, smoothK);
        else
            ds = smin(ds, e, smoothK);
        return d;
    }
    return min(d, e);
}

// ---- THE NECK ----------------------------------------------------------------
// Exact signed distance to the uneven capsule (iq): the tangent cone between a
// circle of radius ra at pa and one of rb at pb, both ends round. A circle that
// holds the other (|ra - rb| >= the length) is a cone with its slope held just
// short of a right angle: it lies inside a body by then.
float sdUnevenCapsule(vec2 p, vec2 pa, vec2 pb, float ra, float rb) {
    vec2 ba = pb - pa;
    float h = max(length(ba), 1e-3);
    vec2 ax = ba / h;
    vec2 q = p - pa;
    vec2 l = vec2(abs(dot(q, vec2(-ax.y, ax.x))), dot(q, ax));
    float b = clamp((ra - rb) / h, -0.999, 0.999);
    float a = sqrt(1.0 - b * b);
    float k = dot(l, vec2(-b, a));
    if (k < 0.0)
        return length(l) - ra;
    if (k > a * h)
        return length(l - vec2(0.0, h)) - rb;
    return dot(l, vec2(a, b)) - ra;
}

// One capsule of the neck, cut where its wide circle ends: the half-space
// beyond the circle's far point (distance r from the wide end along the axis)
// is kept, the circle and the part before it are not. The wide end is only
// where the cone comes from; it lies INSIDE its body, and a body's blend with
// a shape inside it is not nothing (smin lowers the distance wherever the two
// are within k of each other, over the body's other edges too: a bump on the
// card's top and sides). Cut like this the neck meets its body in a flat face
// a whole blend radius deep inside it, which no blend reaches.
float neckArm(vec2 p, vec2 wide, vec2 tip, float rw, float rt) {
    vec2 ba = tip - wide;
    float t = dot(p - wide, ba) / max(length(ba), 1e-3);
    return max(sdUnevenCapsule(p, wide, tip, rw, rt), rw - t);
}

// The bridge between side A (the card, distance dA) and side B (the launcher,
// dB): two arms from each body to the waist, blended by kMid into the neck N;
// each body joined to N on its own radius and never to the other; the two
// sides joined by a small radius that only rounds where they meet. Every term
// is a smin or a max, so the gradient stays a convex mix of unit ones.
float neckBridge(vec2 p, float dA, float dB) {
    float n = smin(neckArm(p, neckA, neckMu, neckRA, neckQU),
                   neckArm(p, neckL, neckMl, neckRL, neckQL), neckKMid);
    return smin(smin(dA, n, neckKA), smin(dB, n, neckKB), neckKJoin);
}

// ---- THE RIPPLE ---------------------------------------------------------------
// One damped packet from one (image) source, x = s - q along the face: its
// height and its slope. d is the source's SMOOTHED distance (no V at the source
// point), the envelope rides at the group speed (src.y = c t) and the carrier
// carries its own phase (src.w), so crests run through the envelope.
// src = (q0, c t, amplitude, phase).
vec2 ripplePacket(float x, vec4 src) {
    float d = sqrt(x * x + rippleA2);
    float u = d - src.y;
    float v = u * rippleInvSigma;
    float env = src.z * exp(-v * v);
    float arg = rippleK * u + src.w;
    float cs = cos(arg);
    float dh = env * (-2.0 * v * rippleInvSigma * cs - rippleK * sin(arg));
    return vec2(env * cs, dh * x / max(d, 1e-4));
}

// One impact source with its reflections: the images of the bar's two ends
// (Neumann, same sign), unrolled by reflection order and nested by the count
// GooeyRipple.imageCount decided -- no loop, no array.
vec2 rippleSource(float s, vec4 src, float L0, float L1) {
    float W = L1 - L0;
    float q = src.x;
    vec2 hh = ripplePacket(s - q, src);
    if (rippleOrders > 0.5) {
        hh += ripplePacket(s - (2.0 * L0 - q), src) + ripplePacket(s - (2.0 * L1 - q), src);
        if (rippleOrders > 1.5) {
            hh += ripplePacket(s - (q - 2.0 * W), src) + ripplePacket(s - (q + 2.0 * W), src);
            if (rippleOrders > 2.5) {
                hh += ripplePacket(s - (2.0 * L0 - q - 2.0 * W), src) + ripplePacket(s - (2.0 * L1 - q + 2.0 * W), src);
                if (rippleOrders > 3.5)
                    hh += ripplePacket(s - (q - 4.0 * W), src) + ripplePacket(s - (q + 4.0 * W), src);
            }
        }
    }
    return hh;
}

float smoothUp(float x) {
    float t = clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
float smoothUpSlope(float x) {
    float t = clamp(x, 0.0, 1.0);
    return 6.0 * t * (1.0 - t);
}

// The moving face's displacement at s: (h, 1 / sqrt(1 + h'^2)). The bulge and
// the three sources, tapered to nothing over a round end -- flat over the end
// corner's own reach e (its region, where the corner's ellipse would cut a
// crest off with a step) and back to whole over as far again; a square end
// (e = 0) keeps its wave to the end -- and floored softly (tanh) so a trough
// never takes the bar below its last pixel. Everything time-dependent (damping,
// the onset, the fade window) is folded into the lanes per frame.
vec2 rippleFaceAt(float s, float L0, float L1, float e0, float e1) {
    float xb = s - rippleBulgeAt;
    float h = rippleBulgeAmp * exp(-xb * xb * rippleBulgeInv);
    float hs = -2.0 * xb * rippleBulgeInv * h;
    vec2 hh = vec2(h, hs);
    if (rippleSrc0.z != 0.0)
        hh += rippleSource(s, rippleSrc0, L0, L1);
    if (rippleSrc1.z != 0.0)
        hh += rippleSource(s, rippleSrc1, L0, L1);
    if (rippleSrc2.z != 0.0)
        hh += rippleSource(s, rippleSrc2, L0, L1);
    float T = 1.0, Ts = 0.0;
    if (e0 > TINY) {
        float x = (s - L0 - e0) / e0;
        T = smoothUp(x);
        Ts = smoothUpSlope(x) / e0;
    }
    if (e1 > TINY) {
        float x = (L1 - e1 - s) / e1;
        float T1 = smoothUp(x);
        Ts = Ts * T1 - T * smoothUpSlope(x) / e1;
        T *= T1;
    }
    h = hh.x * T;
    hs = hh.y * T + hh.x * Ts;
    float m = rippleFloor;
    if (h < 0.0) {
        if (m > 0.0) {
            float th = 1.0 - 2.0 / (exp(-2.0 * h / m) + 1.0);
            h = -m * th;
            hs *= 1.0 - th * th;
        } else {
            h = 0.0;
            hs = 0.0;
        }
    }
    return vec2(h, inversesqrt(1.0 + hs * hs));
}

// The rippling body (slot 0) into the chain or the group. Its early-out box is
// grown by the crest bound on the moving face, so a crest the box does not
// contain is never skipped. Its moving side's distance is the displaced face's,
// taken along the face's normal and divided by sqrt(1 + h'^2) -- a unit
// gradient however steep the flank, so the coverage ramp stays one pixel wide
// across the edge (capped, a column distance would be SHARPER there).
float withRipple(float d, inout float ds, float grp, vec2 p, vec4 b, vec4 exs, vec4 eys, vec4 ixs, vec4 iys) {
    // The moving face, one-hot in the box's order: x0 (left), y0 (top), x1 (right), y1 (bottom).
    vec4 F = vec4(equal(vec4(rippleMode - 1.0), vec4(2.0, 0.0, 3.0, 1.0)));
    vec4 grown = b + rippleCrest * F * vec4(-1.0, -1.0, 1.0, 1.0);
    float sg = sdBox(p, grown.xy, grown.zw);
    if (grp > 0.5 ? sg >= ds + smoothK : sg >= d)
        return d;
    bool alongX = F.y + F.w > 0.5;
    float L0 = alongX ? b.x : b.y;
    float L1 = alongX ? b.z : b.w;
    // The end corners' reach along the face (ix / iy: TL TR BR BL).
    float e0 = dot(F, vec4(iys.x, ixs.x, iys.y, ixs.w));
    float e1 = dot(F, vec4(iys.w, ixs.y, iys.z, ixs.z));
    vec2 hn = rippleFaceAt(clamp(alongX ? p.x : p.y, L0, L1), L0, L1, e0, e1);
    // The box's four side distances (outside positive), the moving one displaced.
    vec4 sd = vec4(b.x - p.x, b.y - p.y, p.x - b.z, p.y - b.w);
    sd = mix(sd, (sd - hn.x) * hn.y, F);
    float qx = max(sd.x, sd.z), qy = max(sd.y, sd.w);
    float e = length(max(vec2(qx, qy), 0.0)) + min(max(qx, qy), 0.0);
    vec2 c = p - 0.5 * (b.xy + b.zw);
    vec2 half_ = 0.5 * (b.zw - b.xy);
    e = cornerCut(e, c, half_, vec2(-1.0, -1.0), exs.x, eys.x, ixs.x, iys.x);
    e = cornerCut(e, c, half_, vec2(1.0, -1.0), exs.y, eys.y, ixs.y, iys.y);
    e = cornerCut(e, c, half_, vec2(1.0, 1.0), exs.z, eys.z, ixs.z, iys.z);
    e = cornerCut(e, c, half_, vec2(-1.0, 1.0), exs.w, eys.w, ixs.w, iys.w);
    if (grp > 0.5) {
        ds = smin(ds, e, smoothK);
        return d;
    }
    return min(d, e);
}

// One body's box distance, into the group of the tint it carries (or the
// untinted rest). The box, not the rounded body: the weight needs a distance
// that is continuous, not the outline, and a corner's cut changes nothing at a
// join (the corners there are square) or far from one (the weight is whole).
void tintRoute(float i, vec4 b, vec2 p, inout vec3 dT, inout float dR) {
    float e = sdBox(p, b.xy, b.zw);
    if (tintIdA == i)
        dT.x = min(dT.x, e);
    else if (tintIdB == i)
        dT.y = min(dT.y, e);
    else if (tintIdC == i)
        dT.z = min(dT.z, e);
    else
        dR = min(dR, e);
}

float tintWeight(float x, float reach) {
    float t = 1.0 - clamp(x / reach, 0.0, 1.0);
    return t * t;
}

// A tint over the surface colour (both premultiplied), by the groups' weights.
// One group at a time, so no more than one colour is live at once.
vec4 tintMix(vec4 base, vec3 dT, float dR) {
    dR = max(dR, 0.0);
    dT = max(dT, vec3(0.0));
    float m = min(dR, min(dT.x, min(dT.y, dT.z)));
    float reach = max(vTintReach, 1.0);
    float w = tintWeight(dR - m, reach);
    vec4 acc = base * w;
    float sum = w;
    w = tintWeight(dT.x - m, reach);
    acc += (base * (1.0 - vTintA.a) + vTintA) * w;
    sum += w;
    if (tintIdB > -0.5) {
        w = tintWeight(dT.y - m, reach);
        acc += (base * (1.0 - vTintB.a) + vTintB) * w;
        sum += w;
    }
    if (tintIdC > -0.5) {
        w = tintWeight(dT.z - m, reach);
        acc += (base * (1.0 - vTintC.a) + vTintC) * w;
        sum += w;
    }
    return acc / sum;
}

// ---- THE AURA (header) -------------------------------------------------------------------------
// The bit of a body in a mask of slots (inv = 2^-i, a literal).
bool auraBit(float mask, float inv) {
    float q = floor(mask * inv);
    return q - 2.0 * floor(q * 0.5) > 0.5;
}

// One body's box distance into its loop: x group A's, y the frame's, z the chain's.
void auraRoute(float inv, vec4 b, vec2 p, inout vec3 dL) {
    float e = sdBox(p, b.xy, b.zw);
    if (auraBit(auraC3.w, inv))
        dL.x = min(dL.x, e);
    else if (auraBit(auraChainMid.w, inv))
        dL.z = min(dL.z, e);
    else
        dL.y = min(dL.y, e);
}

float auraHash(vec2 c) {
    return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

float auraValue(vec2 x) {
    vec2 i = floor(x);
    vec2 f = x - i;
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(auraHash(i), auraHash(i + vec2(1.0, 0.0)), f.x),
               mix(auraHash(i + vec2(0.0, 1.0)), auraHash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Px to a cell of the noise (header, NOISE): the reach's second octave is 1 / 1.7 of it.
const float AURA_CELL = 520.0;

// Large and slow: two octaves of value noise, 0 .. 1 around 0.5.
float auraNoise(vec2 x) {
    return 0.65 * auraValue(x) + 0.35 * auraValue(x * 2.07 + 17.3);
}

// Where a point ON a rectangle's outline (b, from its centre; h its half size) stands along it: 0 .. 1, clockwise from the top-left
// corner. Two faces' formulas agree at a corner.
float auraAlong(vec2 b, vec2 h) {
    float dT = b.y + h.y;
    float dR = h.x - b.x;
    float dB = h.y - b.y;
    float dL = b.x + h.x;
    float m = min(min(dT, dR), min(dB, dL));
    float s;
    if (m == dT)
        s = b.x + h.x;
    else if (m == dR)
        s = 2.0 * h.x + dT;
    else if (m == dB)
        s = 2.0 * h.x + 2.0 * h.y + dR;
    else
        s = 4.0 * h.x + 2.0 * h.y + dB;
    return s / (4.0 * (h.x + h.y));
}

// Where p stands round a loop (header, COORDINATE), 0 .. 1: r its rectangle, c its middle, inside r.
float auraPerim(vec2 p, vec4 r, vec2 c) {
    vec2 h = max(0.5 * (r.zw - r.xy), vec2(0.5));
    vec2 m = r.xy + h;
    vec2 q = p - m;
    if (abs(q.x) < h.x && abs(q.y) < h.y) {
        vec2 o = c - m;
        vec2 v = q - o;
        vec2 e = (h - o * sign(v)) / max(abs(v), vec2(0.001));
        q = o + v * min(e.x, e.y);
    }
    return auraAlong(clamp(q, -h, h), h);
}

// THE JOIN (header): a loop's hue, in cycles, at s (its coordinate). J = (s_a, +-share, U_a, U_b): from the junction at s_a the free arc
// runs `share` of the loop (clockwise for +) and the hue rises from U_a to U_b along it; round the rest of the loop -- the arc the loop
// rests on, under the bars -- it rises on to U_a plus the next whole number, so the loop closes on itself. [0, 1, 0, n]: the plain loop
// of n waves.
float auraJoinU(float s, vec4 J) {
    float share = max(abs(J.y), 1e-4);
    float t = fract(sign(J.y) * (s - J.x));
    if (t <= share)
        return J.z + (J.w - J.z) * (t / share);
    return J.w + (J.z + ceil(J.w - J.z - 1e-4) - J.w) * ((t - share) / max(1.0 - share, 1e-4));
}

// A loop's colour at p: round the cycle of its waves (its join's hue, J), travelling and warped by the noise (phase).
vec3 auraHue(vec2 p, vec4 r, vec2 c, vec4 J, float phase) {
    float x = fract(auraJoinU(auraPerim(p, r, c), J) + phase) * 4.0;
    vec4 w = vec4(abs(x), abs(x - 1.0), abs(x - 2.0), abs(x - 3.0));
    w = max(1.0 - min(w, 4.0 - w), 0.0);
    w = w * w * (3.0 - 2.0 * w);
    return auraC0.rgb * w.x + auraC1.rgb * w.y + auraC2.rgb * w.z + auraC3.rgb * w.w;
}

// Px (the field's) over which the aura's distance blends the rest into a flare's end where their gradients stand at a right angle: the
// shadow's own blend radius at the bars' joints (ShellConfig.shadowBlend), so a cove falls off as a joint does (header, THE COVE).
const float AURA_COVE = 12.0;

// The rest of the field beyond the flares, for the cove (header, THE COVE): (its distance, its gradient). The bodies' smooth union,
// before the flares came in (dBody), and its gradient from a quad's differences: the union is smooth wherever two bodies meet (the
// shadow's blend), so the weight it gives each end turns smoothly too. (The loops' box distances stood for it until round 5: their min
// creases where a popup's face and its island's end are equally near, and the weight jumped there -- a dark line out of every pocket
// a popup leaves past an island's end.)
//
// The gradient is taken in p's own frame: dFdx / dFdy run along the WINDOW's axes, and the window's y runs the other way from the field's
// on this renderer (GL draws into a texture bottom-up) -- read raw, the gradient pointed up where the field's distance grows down, and
// every end's weight in a pocket came out wrong. The field is drawn axis-aligned at one scale (the engine's, never rotated: a side
// bar turns its content, not the field), so p's own derivatives need only say which way each window axis runs. (The whole 2 x 2 solve
// cost iris SIMD16 its top-down schedule.)
vec3 auraCoveRest(float dBody) {
    vec2 g = vec2(dFdx(dBody) * sign(dFdx(vPos.x)), dFdy(dBody) * sign(dFdy(vPos.y)));
    return vec3(dBody, g / max(length(g), 1e-6));
}

// One flare's two ends (where its arc meets the island's side and the screen's edge, skyFillet) smooth-unioned into the rest, each
// by AURA_COVE times how far its gradient turns from the rest's: none where the two coincide (the arc's end on the island's own
// side, tangent to it), the whole radius across a right angle (the far end against the side: the crease).
float auraCoveEnds(float acc, vec2 p, vec4 f, vec4 k, vec3 rest) {
    if (abs(f.z) < TINY || abs(f.w) < TINY)
        return acc;
    vec2 a1 = p - vec2(f.x, k.y);
    vec2 a2 = p - vec2(k.x, f.y);
    float l1 = length(a1);
    float l2 = length(a2);
    float k1 = AURA_COVE * clamp(1.0 - dot(rest.yz, a1 / max(l1, 1e-6)), 0.001, 1.0);
    float k2 = AURA_COVE * clamp(1.0 - dot(rest.yz, a2 / max(l2, 1e-6)), 0.001, 1.0);
    return min(acc, min(smin(rest.x, l1, k1), smin(rest.x, l2, k2)));
}

// Px that keep THE HAND-OVER's ratio finite at the surface: there the band is about this wide, and it widens with the distance.
const float AURA_HAND = 8.0;

// THE HAND-OVER (header, LOOPS): the share of the loop whose box is `near` against the one at `far`, by the ratio of the two: half each on
// the bisector, all of it where (far - near) is half of (far + near) or more -- a band of about 53 degrees round a junction.
float auraHand(float near, float far) {
    float a = max(near, 0.0), b = max(far, 0.0);
    return smoothstep(-0.5, 0.5, (b - a) / (a + b + AURA_HAND));
}

// THE GROUPS (header, GROUPS): the ink at p and group A's share of its colour, from the ink shown of each group (eA, eR) and group A's
// hand-over weight wA. Each group's colour follows its own ink, so the rest fades in with its own hue while a group is handed over. At the
// three settled modes exactly the old cut: (1, 1) gate 1 and A's share wA; (1, 0) wA and 1; (0, 1) 1 - wA and 0.
vec2 auraGate(float eA, float eR, float wA) {
    float gate = (eA >= 1.0 && eR >= 1.0) ? 1.0 : eA * wA + eR * (1.0 - wA);
    // (a GPU divides by a reciprocal: wA / wA is not always 1, so group A alone takes its whole share by name)
    return vec2(gate, eR <= 0.0 ? 1.0 : (gate > 0.0 ? eA * wA / gate : 0.0));
}

// The aura laid over the shadow's own ink `base` (both premultiplied) at p, d its distance to the surface, dL its distances to the loops.
vec4 auraInk(vec2 p, float d, vec4 base, vec3 dL) {
    float wA = auraHand(dL.x, min(dL.y, dL.z));
    vec2 gs = auraGate(auraC0.w, auraC1.w, wA);
    float gate = gs.x;
    if (gate < 0.003)
        return base;
    float t = shadowShape.w;
    vec2 np = p / AURA_CELL;
    float n1 = auraNoise(np + vec2(0.21 * t, -0.13 * t));
    float n2 = auraNoise(np * 1.7 + vec2(-0.17 * t, 0.11 * t) + 31.7);
    float phase = 0.8 * (n1 - 0.5) - 0.2 * t;
    // Whose colour: group A's share (all of it when A alone is drawn, none when the rest is), then the chain's in what is left.
    float shA = gs.y;
    float wC = auraHand(dL.z, dL.y);
    float shC = (1.0 - shA) * wC;
    float shF = (1.0 - shA) * (1.0 - wC);
    vec3 col = vec3(0.0);
    if (shA > 0.003)
        col += shA * auraHue(p, auraRect, auraMid.xy, auraJoinA, phase);
    if (shC > 0.003)
        col += shC * auraHue(p, auraChain, auraChainMid.xy, auraJoinC, phase);
    if (shF > 0.003)
        col += shF * auraHue(p, auraFrame, auraMid.zw, vec4(0.0, 1.0, 0.0, auraC2.w), phase);
    // The brightness and the reach follow the second noise: waves that come and go.
    float bright = mix(0.4, 1.0, smoothstep(0.25, 0.75, n2));
    float R = shadowParam.x * (0.7 + 0.6 * n2);
    float f = clamp(1.0 - max(d, 0.0) / R, 0.0, 1.0);
    float a = min(shadowShape.z * gate * bright * f * f * (3.0 - 2.0 * f), 0.92);
    return vec4(col * a, a) + base * (1.0 - a);
}

#ifdef REEL_PASS
// ---- THE REEL PASS (header) --------------------------------------------------------------------
// @@REELPACK-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
#define reelR g1.z
#define reelB g1.w
#define reelFM g2.z
#define reelBlend g2.w
#define reelInk0 g3.z
#define reelInk1 g3.w
#define reelInk2 g4.z
#define reelInk3 g4.w
// @@REELPACK-END

// One body into its class's distance (header, THE CLASSES): dC = (the group's, its bars', the popups'). The group and the bars by the
// hard min in a shape tile and by the field's smooth-min in a halo tile (groupBit: a shadow tile blends every body); the popups always
// by the hard min, with their fillets (THE CUT is their drawn surface). `a` is the body's ink, kept for the nearest of the group.
void reelBody(float i, float a, vec2 p, vec4 b, vec4 exs, vec4 eys, vec4 ixs, vec4 iys, inout vec3 dC, inout float ink) {
    float e = bodyDist(p, b, exs, eys, ixs, iys);
    float k = max(smoothK, 0.001);
    if (i < reelR) {
        if (e < dC.x)
            ink = a;
        dC.x = vTile < 0.0 ? smin(dC.x, e, k) : min(dC.x, e);
    } else if (i < reelR + reelB) {
        dC.y = vTile < 0.0 ? smin(dC.y, e, k) : min(dC.y, e);
    } else {
        dC.z = min(dC.z, e);
    }
}

// One fillet: the union's own (the first reelFM; a shape tile's alone, as in the field) or a popup's.
void reelFillet(float i, vec2 p, vec4 f, vec4 k, vec4 g, inout float d, inout float dP) {
    if (i < reelFM) {
        if (vTile >= 0.0)
            d = withFillet(d, p, f, k, g);
    } else {
        dP = withFillet(dP, p, f, k, g);
    }
}

void main() {
    vec2 p = vPos;
    float px = length(vec2(dFdx(p.x), dFdy(p.x)));
    float deep = -2.0 * px;
    fieldPx = px;
    vec3 dC = vec3(1e9);
    float ink = 0.0;
    float d = 1e9;
    float dP = 1e9;
// @@REELEVAL-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
    int nb = int(bodyCount + 0.5);
    if (nb > 0) {
        reelBody(0.0, reelInk0, p, b0, x0, y0, u0, v0, dC, ink);
        if (nb > 1) {
            reelBody(1.0, reelInk1, p, b1, x1, y1, u1, v1, dC, ink);
        if (nb > 2) {
            reelBody(2.0, reelInk2, p, b2, x2, y2, u2, v2, dC, ink);
        if (nb > 3) {
            reelBody(3.0, reelInk3, p, b3, x3, y3, u3, v3, dC, ink);
        if (nb > 4) {
            reelBody(4.0, 0.0, p, b4, x4, y4, u4, v4, dC, ink);
        if (nb > 5) {
            reelBody(5.0, 0.0, p, b5, x5, y5, u5, v5, dC, ink);
        if (nb > 6) {
            reelBody(6.0, 0.0, p, b6, x6, y6, u6, v6, dC, ink);
        if (nb > 7) {
            reelBody(7.0, 0.0, p, b7, x7, y7, u7, v7, dC, ink);
    }}}}}}}}
    d = vTile < 0.0 ? smin(dC.x, dC.y, max(smoothK, 0.001)) : min(dC.x, dC.y);
    dP = dC.z;
    int nf = int(filletCount + 0.5);
    if (nf > 0) {
        reelFillet(0.0, p, f0, k0, g0, d, dP);
        if (nf > 1) {
            reelFillet(1.0, p, f1, k1, g1, d, dP);
        if (nf > 2) {
            reelFillet(2.0, p, f2, k2, g2, d, dP);
        if (nf > 3) {
            reelFillet(3.0, p, f3, k3, g3, d, dP);
        if (nf > 4) {
            reelFillet(4.0, p, f4, k4, g4, d, dP);
        if (nf > 5) {
            reelFillet(5.0, p, f5, k5, g5, d, dP);
        if (nf > 6) {
            reelFillet(6.0, p, f6, k6, g6, d, dP);
        if (nf > 7) {
            reelFillet(7.0, p, f7, k7, g7, d, dP);
        if (nf > 8) {
            reelFillet(8.0, p, f8, k8, g8, d, dP);
        if (nf > 9) {
            reelFillet(9.0, p, f9, k9, g9, d, dP);
        if (nf > 10) {
            reelFillet(10.0, p, f10, k10, g10, d, dP);
        if (nf > 11) {
            reelFillet(11.0, p, f11, k11, g11, d, dP);
    }}}}}}}}}}}}
    int ns = vTile < 0.0 ? 0 : int(seamCount + 0.5);
    if (ns > 0) {
        d = min(d, sdBox(p, s0.xy, s0.zw));
        if (ns > 1) {
            d = min(d, sdBox(p, s1.xy, s1.zw));
        if (ns > 2) {
            d = min(d, sdBox(p, s2.xy, s2.zw));
        if (ns > 3) {
            d = min(d, sdBox(p, s3.xy, s3.zw));
        if (ns > 4) {
            d = min(d, sdBox(p, s4.xy, s4.zw));
        if (ns > 5) {
            d = min(d, sdBox(p, s5.xy, s5.zw));
        if (ns > 6) {
            d = min(d, sdBox(p, s6.xy, s6.zw));
        if (ns > 7) {
            d = min(d, sdBox(p, s7.xy, s7.zw));
    }}}}}}}}
// @@REELEVAL-END

    // THE CUT (header): the popups' coverage, the field's own ramp.
    float gP = min(length(vec2(dFdx(dP), dFdy(dP))), px);
    float cut = clamp(0.5 - dP / max(gP, 0.25 * px), 0.0, 1.0);
    // THE SHARE (header), on the distances outside each (inside either, that one's is 0).
    float share = clamp(0.5 + (max(dC.y, 0.0) - max(dC.x, 0.0)) / (2.0 * max(reelBlend, 1.0)), 0.0, 1.0);
    share = share * share * (3.0 - 2.0 * share);
    d = max(d, deep);

    // A HALO tile: the shadow's fall (the field's, below) and the reel's share of it, OUTSIDE the union only. The field's halo lies
    // under its whole shape, which covers it; this one lies under a fill that ends with THE CUT, and along that line (a popup's edge
    // crossing a strip) a halo under the fill showed through the two ramps as a hairline down the strip. Nor may it darken a bar.
    if (vTile < 0.0) {
        float u = clamp((1.0 - (d - shadowShape.x) / shadowParam.z) / max(shadowShape.y, 0.001), 0.0, 1.0);
        vec4 sh = shadowColor * (u * u * (3.0 - 2.0 * u));
        fragColor = sh * (share * ink * cut * clamp(0.5 + d / px, 0.0, 1.0) * qt_Opacity);
        return;
    }

    // A SHAPE tile: the fill and the ring (the field's, below).
    float g = min(length(vec2(dFdx(d), dFdy(d))), px);
    float cov = clamp(0.5 - d / max(g, 0.25 * px), 0.0, 1.0);
    vec4 col = fieldColor * cov;
    if (shadowParam.w > 0.0) {
        float covB = clamp(0.5 - (d - shadowParam.w) / max(g, 0.25 * px), 0.0, 1.0);
        col += borderColor * (max(covB - cov, 0.0) * share * ink);
    }
    fragColor = col * (cut * qt_Opacity);
}
#else
void main() {
    vec2 p = vPos;
    float d = 1e9;
    float px = length(vec2(dFdx(p.x), dFdy(p.x)));
    // Two pixels inside, nothing more can change the coverage: the rest is
    // skipped and d clamped there (a clamped neighbour only steepens |grad d|,
    // and full coverage stays full).
    float deep = -2.0 * px;
    fieldPx = px;

// @@EVAL-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
    int nb = int(bodyCount + 0.5);
    float ds = 1e9;
    float dsB = 1e9;
    vec4 gds = vec4(0.0);
    bool rip = rippleMode > 0.5;
    if (nb > 0 && !rip)
        d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 1.0), 1.0, p, b0, x0, y0, u0, v0);
    if (nb > 1) {
        d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.5), 2.0, p, b1, x1, y1, u1, v1);
        if (nb > 2) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.25), 3.0, p, b2, x2, y2, u2, v2);
        if (nb > 3) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.125), 4.0, p, b3, x3, y3, u3, v3);
        if (nb > 4) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.0625), 5.0, p, b4, x4, y4, u4, v4);
        if (nb > 5) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.03125), 6.0, p, b5, x5, y5, u5, v5);
        if (nb > 6) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.015625), 7.0, p, b6, x6, y6, u6, v6);
        if (nb > 7) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.0078125), 8.0, p, b7, x7, y7, u7, v7);
        if (nb > 8) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.00390625), 9.0, p, b8, x8, y8, u8, v8);
        if (nb > 9) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.001953125), 10.0, p, b9, x9, y9, u9, v9);
        if (nb > 10) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.0009765625), 11.0, p, b10, x10, y10, u10, v10);
        if (nb > 11) {
            d = withGroup(d, ds, dsB, gds, groupBit(smoothMask, 0.00048828125), 12.0, p, b11, x11, y11, u11, v11);
    }}}}}}}}}}}
    if (nb > 0 && rip)
        d = withRipple(d, ds, groupBit(smoothMask, 1.0), p, b0, x0, y0, u0, v0);
    if (neckB > 0.5 && !rip)
        ds = neckBridge(p, ds, dsB);
    d = min(d, ds);

    int nf = (d < deep || vTile < 0.0) ? 0 : int(filletCount + 0.5);
    if (nf > 0) {
        if (d >= deep) d = withFillet(d, p, f0, k0, g0);
        if (nf > 1) {
            if (d >= deep) d = withFillet(d, p, f1, k1, g1);
        if (nf > 2) {
            if (d >= deep) d = withFillet(d, p, f2, k2, g2);
        if (nf > 3) {
            if (d >= deep) d = withFillet(d, p, f3, k3, g3);
        if (nf > 4) {
            if (d >= deep) d = withFillet(d, p, f4, k4, g4);
        if (nf > 5) {
            if (d >= deep) d = withFillet(d, p, f5, k5, g5);
        if (nf > 6) {
            if (d >= deep) d = withFillet(d, p, f6, k6, g6);
        if (nf > 7) {
            if (d >= deep) d = withFillet(d, p, f7, k7, g7);
        if (nf > 8) {
            if (d >= deep) d = withFillet(d, p, f8, k8, g8);
        if (nf > 9) {
            if (d >= deep) d = withFillet(d, p, f9, k9, g9);
        if (nf > 10) {
            if (d >= deep) d = withFillet(d, p, f10, k10, g10);
        if (nf > 11) {
            if (d >= deep) d = withFillet(d, p, f11, k11, g11);
        if (nf > 12) {
            if (d >= deep) d = withFillet(d, p, f12, k12, g12);
        if (nf > 13) {
            if (d >= deep) d = withFillet(d, p, f13, k13, g13);
        if (nf > 14) {
            if (d >= deep) d = withFillet(d, p, f14, k14, g14);
        if (nf > 15) {
            if (d >= deep) d = withFillet(d, p, f15, k15, g15);
        if (nf > 16) {
            if (d >= deep) d = withFillet(d, p, f16, k16, g16);
        if (nf > 17) {
            if (d >= deep) d = withFillet(d, p, f17, k17, g17);
        if (nf > 18) {
            if (d >= deep) d = withFillet(d, p, f18, k18, g18);
        if (nf > 19) {
            if (d >= deep) d = withFillet(d, p, f19, k19, g19);
        if (nf > 20) {
            if (d >= deep) d = withFillet(d, p, f20, k20, g20);
        if (nf > 21) {
            if (d >= deep) d = withFillet(d, p, f21, k21, g21);
        if (nf > 22) {
            if (d >= deep) d = withFillet(d, p, f22, k22, g22);
        if (nf > 23) {
            if (d >= deep) d = withFillet(d, p, f23, k23, g23);
    }}}}}}}}}}}}}}}}}}}}}}}}

    int ns = (d < deep || vTile < 0.0) ? 0 : int(seamCount + 0.5);
    if (ns > 0) {
        d = min(d, sdBox(p, s0.xy, s0.zw));
        if (ns > 1) {
            d = min(d, sdBox(p, s1.xy, s1.zw));
        if (ns > 2) {
            d = min(d, sdBox(p, s2.xy, s2.zw));
        if (ns > 3) {
            d = min(d, sdBox(p, s3.xy, s3.zw));
        if (ns > 4) {
            d = min(d, sdBox(p, s4.xy, s4.zw));
        if (ns > 5) {
            d = min(d, sdBox(p, s5.xy, s5.zw));
        if (ns > 6) {
            d = min(d, sdBox(p, s6.xy, s6.zw));
        if (ns > 7) {
            d = min(d, sdBox(p, s7.xy, s7.zw));
        if (ns > 8) {
            d = min(d, sdBox(p, s8.xy, s8.zw));
        if (ns > 9) {
            d = min(d, sdBox(p, s9.xy, s9.zw));
        if (ns > 10) {
            d = min(d, sdBox(p, s10.xy, s10.zw));
        if (ns > 11) {
            d = min(d, sdBox(p, s11.xy, s11.zw));
        if (ns > 12) {
            d = min(d, sdBox(p, s12.xy, s12.zw));
        if (ns > 13) {
            d = min(d, sdBox(p, s13.xy, s13.zw));
        if (ns > 14) {
            d = min(d, sdBox(p, s14.xy, s14.zw));
        if (ns > 15) {
            d = min(d, sdBox(p, s15.xy, s15.zw));
        if (ns > 16) {
            d = min(d, sdBox(p, s16.xy, s16.zw));
        if (ns > 17) {
            d = min(d, sdBox(p, s17.xy, s17.zw));
        if (ns > 18) {
            d = min(d, sdBox(p, s18.xy, s18.zw));
        if (ns > 19) {
            d = min(d, sdBox(p, s19.xy, s19.zw));
        if (ns > 20) {
            d = min(d, sdBox(p, s20.xy, s20.zw));
        if (ns > 21) {
            d = min(d, sdBox(p, s21.xy, s21.zw));
        if (ns > 22) {
            d = min(d, sdBox(p, s22.xy, s22.zw));
        if (ns > 23) {
            d = min(d, sdBox(p, s23.xy, s23.zw));
    }}}}}}}}}}}}}}}}}}}}}}}}
// @@EVAL-END
    d = max(d, deep);

    // A SHADOW tile (header): the ink falls smoothly from the edge to `reach` and is drawn
    // under the shape. d there is the field at the shifted point; inside the shape it is
    // clamped at `deep` and the ink is whole -- under the shape, where nothing shows it.
    // shadowShape.x (SPREAD) moves where the fall starts (the shadow's shape grown by it, px) and
    // shadowShape.y (SOFTNESS, 0 .. 1) how much of the reach it takes: 1 falls over all of it, less
    // holds the ink whole for the rest and falls over the outer part only. (0, 1) is the plain
    // fall, to the bit: d - 0 is d and a division by 1 is exact.
    if (vTile < 0.0) {
// @@SKY-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
        float dBody = d;
        int nsk = d > deep ? int(fract(filletCount) * 64.0 + 0.5) : 0;
        if (nsk > 0) {
            d = min(d, skyFillet(p, f0, k0, g0));
            if (nsk > 1) {
                d = min(d, skyFillet(p, f1, k1, g1));
            if (nsk > 2) {
                d = min(d, skyFillet(p, f2, k2, g2));
            if (nsk > 3) {
                d = min(d, skyFillet(p, f3, k3, g3));
        }}}}
        d = max(d, deep);
// @@SKY-END
        float u = clamp((1.0 - (d - shadowShape.x) / shadowParam.z) / max(shadowShape.y, 0.001), 0.0, 1.0);
        vec4 sh = shadowColor * (u * u * (3.0 - 2.0 * u));
        if (shadowShape.z > 0.0) {
// @@AURA-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
        vec3 dAura = vec3(1e9);
        if (nb > 0) {
            auraRoute(1.0, b0, p, dAura);
            if (nb > 1) {
                auraRoute(0.5, b1, p, dAura);
            if (nb > 2) {
                auraRoute(0.25, b2, p, dAura);
            if (nb > 3) {
                auraRoute(0.125, b3, p, dAura);
            if (nb > 4) {
                auraRoute(0.0625, b4, p, dAura);
            if (nb > 5) {
                auraRoute(0.03125, b5, p, dAura);
            if (nb > 6) {
                auraRoute(0.015625, b6, p, dAura);
            if (nb > 7) {
                auraRoute(0.0078125, b7, p, dAura);
            if (nb > 8) {
                auraRoute(0.00390625, b8, p, dAura);
            if (nb > 9) {
                auraRoute(0.001953125, b9, p, dAura);
            if (nb > 10) {
                auraRoute(0.0009765625, b10, p, dAura);
            if (nb > 11) {
                auraRoute(0.00048828125, b11, p, dAura);
        }}}}}}}}}}}}
        float dA = d;
        int nskA = int(fract(filletCount) * 64.0 + 0.5);
        if (nskA > 0) {
            vec3 rest = auraCoveRest(dBody);
            dA = auraCoveEnds(dA, p, f0, k0, rest);
            if (nskA > 1) {
                dA = auraCoveEnds(dA, p, f1, k1, rest);
                if (nskA > 2) {
                    dA = auraCoveEnds(dA, p, f2, k2, rest);
                if (nskA > 3) {
                    dA = auraCoveEnds(dA, p, f3, k3, rest);
            }}}
        }
// @@AURA-END
            sh = auraInk(p, dA, sh, dAura);
        }
        if (showTiles > 0.5)
            sh = mix(sh, vec4(0.5 + 0.5 * cos(6.28318 * ((-1.0 - vTile) * 0.137 + vec3(0.0, 0.33, 0.67))), 1.0), 0.45);
        fragColor = sh * qt_Opacity;
        return;
    }

    // |grad d| is capped at the pixel's own size (a unit-gradient distance
    // never has more): across a KINK -- the inner diagonal of a square corner,
    // the crease outside two bodies' union -- a 2x2 quad's differences
    // straddle it and read up to sqrt(2), which drew the three pixels of every
    // square corner whose quad fell that way at 0.85 (the notch at the screen's
    // corner of a full-width bar), and put 0.15 of ink outside a crease.
    float g = min(length(vec2(dFdx(d), dFdy(d))), px);
    float cov = clamp(0.5 - d / max(g, 0.25 * px), 0.0, 1.0);

    vec4 col = fieldColor;
// @@TINT-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)
    if (tintIdA > -0.5 && cov > 0.0) {
        vec3 dT = vec3(1e9);
        float dR = 1e9;
        if (nb > 0) {
            tintRoute(0.0, b0, p, dT, dR);
            if (nb > 1) {
                tintRoute(1.0, b1, p, dT, dR);
            if (nb > 2) {
                tintRoute(2.0, b2, p, dT, dR);
            if (nb > 3) {
                tintRoute(3.0, b3, p, dT, dR);
            if (nb > 4) {
                tintRoute(4.0, b4, p, dT, dR);
            if (nb > 5) {
                tintRoute(5.0, b5, p, dT, dR);
            if (nb > 6) {
                tintRoute(6.0, b6, p, dT, dR);
            if (nb > 7) {
                tintRoute(7.0, b7, p, dT, dR);
            if (nb > 8) {
                tintRoute(8.0, b8, p, dT, dR);
            if (nb > 9) {
                tintRoute(9.0, b9, p, dT, dR);
            if (nb > 10) {
                tintRoute(10.0, b10, p, dT, dR);
            if (nb > 11) {
                tintRoute(11.0, b11, p, dT, dR);
        }}}}}}}}}}}}
        col = tintMix(col, dT, dR);
    }
// @@TINT-END
    if (showTiles > 0.5) {
        vec3 hue = 0.5 + 0.5 * cos(6.28318 * (vTile * 0.137 + vec3(0.0, 0.33, 0.67)));
        col = mix(col, vec4(hue, 1.0), 0.45);
    }
    // The BORDER (header): the ring's outer edge is the same one-pixel ramp at d = w, drawn under the
    // surface's own (cov, so the ring shows only where the surface does not).
    if (shadowParam.w > 0.0) {
        float covB = clamp(0.5 - (d - shadowParam.w) / max(g, 0.25 * px), 0.0, 1.0);
        col = col * cov + borderColor * max(covB - cov, 0.0);
        fragColor = col * qt_Opacity;
        return;
    }
    // Colour uniforms arrive premultiplied.
    fragColor = col * cov * qt_Opacity;
}
#endif
