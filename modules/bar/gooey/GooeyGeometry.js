.pragma library

// =============================================================================
// GooeyGeometry.js -- the shape of the gooey surface, with no Qt in it.
//
// fieldShape(bodies, params, state, dtMs) turns boxes into what
// shaders/gooey_field.frag draws: every body's corners (an ellipse per corner,
// with its own centre inset), the FILLETS that join bodies, the SEAMS laid over
// lines two bodies share, and the tiles the field is drawn in. It is pure apart
// from `state`, which it returns updated: how far each join has settled.
//
// A BODY (input): { id, x0, y0, x1, y1, rx, ry (or r), radii, mobile, stick, parent, peer, host, square, free, join }
//   rx, ry   its free-corner radii (a popup's surface tension, a bar's radius)
//   radii    [tl, tr, br, bl], per corner: a number (a circular corner) or
//            [rx, ry]. Replaces rx/ry for that body (the RADIUS OVERRIDE: a round
//            body larger than 40 px, a rounded FOOT only). A corner of 0 is
//            square, so a neighbour of it may round across the whole side, as
//            beside a `square` one: [0, 0, r, r] on a body w wide and h tall is a
//            foot of two w/2 x min(r, h) quarter ellipses.
//   free     a body related to NOTHING here (the launcher's flourish, its
//            droplets): no snapping, no joins, no fillets, no seams, no flares,
//            and it caps no channel. It is drawn as its own box and corners; its
//            only relation is the field's smooth group (GooeyField.smoothMask).
//   square   [tl, tr, br, bl] corners drawn SQUARE (a bar's corners on the
//            screen's edge: a bar is never rounded on
//            a side flush with the screen). A free corner whose neighbour
//            along one of its sides is square may round across that WHOLE
//            side instead of half of it: a 6 px bar ending mid-screen rounds
//            from its face all the way down to the screen's edge.
//   mobile   may be drawn stretched to meet a facing face (popups; not bars)
//   stick    the box a popup is open at, which its joins resist following (how
//            far out the popup is along the joined bar scales the resistance)
//   parent   the id of the popup it hangs from (a secondary)
//   peer     the id of a body it MELTS with side by side (PEERS)
//   host     the id of the bar a popup hangs from: only that bar's ends draw
//            its ends flush (SNAPPING). Unset: every bar's (a pose built by
//            hand, with no bar to hang from).
//   skyBox   { x0, y0, x1, y1 } on a BAR: the body beyond the screen's edge its outer face lies on (THE SKY). The bar then
//            relates to that virtual body as a bar does to a wider one it hangs under -- concave fillets where its ends meet
//            the edge's line -- and nothing else changes. The sky is made here, once per distinct box, never an output.
//   wallJoin the screen edge a popup hangs from ("top" | "right" | "bottom" |
//            "left"), set by the engine on its primaries (not on a secondary or
//            the lane): the popup's joins with a perpendicular bar it RESTS
//            FLUSH against are that bar's own corner travelling with its foot
//            (THE WALL JOIN). Unset: every join is the ordinary one.
//
// ---- HOST AND GUEST ------------------------------------------------------------
// A bar hosts a popup and a parent popup hosts its child. Two bars, or a bar
// and a child, relate only where they touch; two popups never. The HOST's pieces -- a bar's corners
// and flares -- settle (SETTLING) and scale with how much guest there is yet
// (PRESENCE px of its smaller side; BAR_PRESENCE for a bar), so a bar's corner never changes in the
// frame a popup appears. The GUEST's own pieces follow its box at once, so
// nothing trails behind a popup that has moved on.
//
// ---- PEERS ---------------------------------------------------------------------
// Two popups on ONE bar, side by side -- thePopup and the notifications lane
// beside it -- melt like a popup and its bar: a body that names another as its
// `peer` is related to it along the bar with no host and no guest. Nothing
// snaps, sticks, flares or settles between peers (their places are the
// engine's, and nothing may be drawn where a body is not): the relation's
// weight is a CONTACT weight of the gap alone, 1 - smoothstep(0, PEER_CONTACT,
// gap) (`peerWeight`), times the presence of the smaller of the two, so it
// comes in over the last pixel and a half of an approach and never in one frame.
// What it draws is the ordinary join, along the axis the two are side by side on:
//   - at the end both hang from (the bar's face) the ends are flush: both
//     corners there are square and there is no S (the bar's own joins already
//     square them);
//   - at the FREE end, an S-join: a fillet in the concave corner between the
//     shorter body's foot and the taller one's side, and the taller one's own
//     corner below it -- one S-curve, solved like any other (JOINS), tightening
//     as the two feet come level and one straight foot when they are;
//   - a SEAM over the contact line once the two touch (the two antialiased
//     faces meeting on a line leave a half-covered row), zipping in from the
//     middle over the last PEER_SEAM px of gap -- never a bridge across a gap
//     the eye can see.
// The channel the two leave on the bar's face while they are apart is closed by
// the FACING FILLETS of their two joins with the bar: a C that flattens away as
// the gap closes, whose fillets then lie inside the other body.
//
// A LANE and the popups it melts with are kept apart by the engine (`laneClip`,
// `lanePlace`, below): the relation never has to draw two peers overlapping. The
// same for the OSD (`yieldPlace`, `pushPlace`, THE OSD SLOT below), which names a
// LIST of peers: `peer` is one id (the lane's string) or an array
// of ids, kept as `peers`, and a body that lies flush against several melts with each.
//
// ---- THE SKY ---------------------------------------------------------------------
// The islands meet the screen's edge with the same gooey rounded corners as if
// there were one gigantic popup above them off-screen. A bar that carries a `skyBox` has that popup: a virtual, immobile body
// beyond the edge its outer face lies on, touching the bar's face along the whole of it. The bar-with-bar relation (a touch) then
// draws what it draws where a bar hangs under a wider one: a concave fillet in each corner between the narrower body's
// side and the wider one's face, so an island that ends mid-edge flares into the edge, and one that ends AT the screen's corner
// flares off-screen where nothing shows it. The sky is related to the bars that carry its box and to NOTHING else: not to a popup
// (snapDistance would drag one that hangs 40 px off the edge up to it), not to another sky. It takes no shader slot (the Field
// draws `bodies` as returned, and the sky is not among them), only its fillets and seams are drawn. A bar with no area is no
// body, so the sky is gone with its last bar, and a bar thinner than BAR_PRESENCE has it only in part (the touch's weight is scaled
// by the bar's presence, like any join).
//
// THE BORDER'S END (`params.skyOutset`, the border's width): the sky's face and the bar's face on it move out by the border's width (skyOut), so the
// ring of the shell's border comes to the screen's edge at no thickness (never ending in a 3 px thick bar).
//
// ---- BARS IN A CORNER ----------------------------------------------------------
// Two bars meeting at a screen corner are ONE L, whichever of them the corner
// square was given to: a side bar starting under the top bar and a side bar
// running through the corner square cover the same pixels and draw the same
// outline. Where the overlap of two bars is a whole END of one of them (it
// spans that bar's thickness and reaches exactly one of its ends), that bar is
// drawn short of it -- the one running along y first, so the square goes to the
// top or bottom bar -- and the pair TOUCHES. The touch relation then draws the
// inner corner: a fillet of blendRadius, the corners on the shared line square
// and a seam over it. Bars are static, so none of it settles or waits for
// presence. Bars that do not reach each other, or cross mid-span, draw nothing.
//
// A bar's corners at an end that lies on another bar's face are COVERED: not
// free, and square from the start. No rule may treat them as a corner still
// rounding in -- a guest's end drawn short of it, a join hanging off its
// tangent -- because there is no air there to do it over. (The solid-end rule
// did exactly that: it drew a popup growing out of the corner a fraction of a
// pixel under the top bar, a hairline of wallpaper for a frame.)
//
// ---- RELATIONS ---------------------------------------------------------------
// Along an axis `a` (y: one above the other; x: one beside the other; `b` is the
// other axis) the UPPER body U starts and ends before the LOWER one D, the gap
// g = D.a0 - U.a1 is at most snapDistance, and their spans on b overlap or come
// within snapDistance. A negative gap is penetration: a child inset into its
// parent.
//
// ---- SNAPPING ------------------------------------------------------------------
// A popup's face within snapDistance of a bar's face it overlaps along b is
// DRAWN moved to it (its content keeps the real box): all the way within
// attachDistance, letting go smoothly by snapDistance. That is the
// "wall snap", and it closes the hole a popup 9 px under a perpendicular bar
// would leave. A popup beside a bar's END is never pulled. An END of a popup
// within flushSnap of the bar's end along b is drawn flush with it, letting go
// by twice that: a popup a pixel or two off a bar's end is one straight edge,
// not an S with a sub-pixel step in it -- the ends of the bar it HANGS FROM
// (`host`), where the engine places a rest box's end on the bar's end anyway. Not
// a bar it merely rests against: there the end is its FAR face, an out-extent the
// content sizes and the engine cannot place, and a manager whose foot crosses a
// side bar's end on every resize would have its drawn foot held on that end, up to 3 px
// off its box -- the surface stalling and then jumping while its rows moved on, and
// a foot resting 5 px past the end drawn 1.3 px short of its box. There the S
// draws the join, as it does at any other delta, flat to one edge at 0. An end
// pulled flush makes ONE corner with the bar's end (END CORNER, below). An end
// that is not pulled but would land on a bar's corner that is still rounded (the corner squares over the guest's
// PRESENCE) is drawn at the corner's tangent instead, which unwraps as the corner
// squares: there is nothing under it until then. A bar's end that another bar
// COVERS (BARS IN A CORNER) leaves no air, so no end is drawn back from it and no
// end corner is made with it: the music popup in the corner of two bars would be drawn
// 1.3 px off the top bar by the side bar's end, a row of air the width of the
// popup. Children never snap.
//
// ---- END CORNER -------------------------------------------------------------------
// A popup's end pulled onto its bar's end is one corner with it -- one ellipse
// tangent to the popup's far face and to the bar's side (endCorner). With the
// popup fully present it is the popup's own corner over its whole side (its
// corner on the line is square there), never turning tighter at its tip than half
// the blend radius: a surface-tension corner is long and shallow, and cut off at
// its side it would be a point. (Half the BAR's radius is a point again on a
// round-capped slim bar: a 6 px bar of radius 3 lets the tip turn at 1.5.) Where the side is too short for that the corner is
// round, never narrower: narrower, its tip on the far face turns tighter still
// (3.9 at 7 px of popup). With the popup a sliver it is the bar's own corner,
// reached through the sliver on top of it; in between the bar's corner carries
// the lower part of the curve and the popup's end is drawn where the curve
// crosses the shared line. A popup's end that stepped down onto a bar's corner
// with a shelf between them, and a hairline of popup over the corner's air, are
// the two ways a plain tangent rule shows at a bar's end. The corner is laid
// over what the join at that end resolves to, by how far the end is pulled.
//
// A body with no area is not drawn (`solid`): the shader's coverage draws a box
// of zero height as a half-covered row. It still rests on its bar -- a popup at
// no height lies ON the bar's face -- so its joins let go on their settle clock
// instead of in one frame.
//
// ---- JOINS -----------------------------------------------------------------------
// At each END of an overlapping relation (along b) the outline crosses the shared
// line from the INNER body (whose end lies within the other's span) to the OUTER
// one, |delta| apart. The crossing is an S-curve of two pieces: the outer body's
// corner (convex) and a FILLET (concave) on the inner body's side; the inner
// body's corner on the line is sharp. Each piece has a ceiling along b: the
// corner's own radius, and blendRadius plus any stretch for the fillet.
//
// When |delta| is at least the two ceilings together, both pieces are quarter
// ellipses at their ceilings with a straight run between them. When it is less,
// the S TIGHTENS instead of pinching: both pieces keep their full height along
// a, and leave their side tangentially but meet each other at an angle theta
// < 90 degrees, sharing the tangent there -- a reverse curve of two elliptical
// arcs whose b-offsets add up to |delta|. So a popup 10 px off a bar's end is a
// gentle S, never two sharp corners, and it straightens continuously to one edge
// at delta 0.
//
// A FLUSH end (delta 0) has no S: the outer corner is as sharp as the inner
// one, and is claimed so the moment the relation is found. Left to the joint
// pass, a join solved first at that corner's other end (a top bar with a side
// bar under each end) took the corner for free and its quarter outranked the
// claim: a scoop of air at the screen edge above one of the side bars.
//
// DOWN THE SIDE the fillet is also a piece of a second S, whose partner is the
// inner body's FAR corner at that end: from the line to the inner body's far
// face. The fillet's ceiling along a is max(blendRadius, the inner body's
// radius) plus stretch. When the side is shorter than both ceilings together
// (a popup just opening or nearly closed) that S tightens the same way, so a
// five-pixel popup is one long S from the bar to its foot, not a flat fillet
// meeting a flat corner in a hairpin. The fillet hangs off the inner body's own
// face, never across a residual gap. While that S is tight, a popup's far corner
// may take the whole side (its corner on the line is square) -- as much as keeps
// its tip from turning tighter than half the blend radius: a surface-tension
// corner is long and shallow, and the S met it near its point in an elbow.
//
// CLAIMS. A corner is ONE ellipse, however many joins shape it, so one claim wins
// it whole: the piece of the TIGHTEST S (its angle short of a quarter turn, by
// the join's weight) -- a loose S's straight run takes whatever corner is there,
// while a tight S's fillet was solved for exactly its own piece and is detached
// from any other -- and among equally tight ones the piece that cuts the least
// AREA away. (How far a flat ellipse's arc runs along a face is ill-conditioned:
// a hundredth of a pixel of height moved it seven pixels, and a join a popup's
// width away out-ranked the S its corner was solved for.) The music popup's far
// corner is both the top bar's S down its side and the side bar's S along its
// foot, and it lost the tight one to the loose one: a notch of up to 3.9 px.
// Sharpness is the largest claim; plain radius limits cap the result. A void
// flare's limit is not one of them: an S's outer piece is SOLVED against it (the
// joint pass takes it as the corner's ceiling) and then taken whole, because a
// tight piece's semi-axis is larger than its reach and a cap at resolve cut what
// its fillet was solved to meet (a 1-3 px shelf whenever another bar's end was
// within snapDistance of a popup hanging past its bar's end).
//
// FACING FILLETS. Two fillets on ONE face running toward each other across the
// free stretch between them -- the corner's fillet under a top bar and a
// popup's join a few pixels down the side bar, closing the channel between the
// popup and the top bar -- would cross in a cusp once their reaches add up to
// more than the stretch. They share it instead, in proportion to their reach:
// both stay quarter ellipses tangent to the face and meet on it in one smooth C,
// which flattens away as the channel closes. The share comes in with the weaker
// join's weight and blends out over the quarter pixel in which the two faces
// close (where a touching seam covers the line whole), so nothing steps. A
// guest's face still parting from the host's line (the popup's top a fraction
// of a pixel under the top bar) is on that line as far as its join reaches, and
// the share fades with the offset over the same CONTACT range: cut off at a
// hundredth of a pixel instead, the channel's end jumped between one C and two
// crossing arcs, five pixels apart, in the frame the face crossed it. And the
// share comes in only where there is a cusp to prevent (over CROSS px): where
// the two really CROSS above the face -- each is thickest at its own vertex, so
// if one is thinner there than the other already is at that point, the other
// covers the whole stretch -- or where one's arc leaves the body behind the
// other's vertex within that body's far-corner rounding, and would cut into the
// round corner (a popup 12 px wide rising on the side bar under the corner's
// 20 px fillet). An arc that leaves the body further out crosses its flat far
// face: the guest's own shape, nothing to share. A popup a few px tall ending a
// quarter of a pixel short of the side bar is that case: the corner's fillet is
// 17 px deep at the popup's vertex, the popup 2 px tall with a 1 px corner, and
// sharing the stretch squeezed the corner of two bars -- to 6.6 x 20 for the
// whole flat tail of a close while the share was taken whatever the depth, and
// still for one frame at each end of every open and close (18-31 px of air past
// the outline at popup heights of 0.7-4.4 px) while it came in with the shallower
// fillet's depth over PRESENCE. The depth (how far a fillet can stand off the
// face: no further than its side is long) is what both are measured with.
//
// THE WALL JOIN: the concave rounded corner of the popup that connects to the right
// bar is the exact same as the rounded corner that is created between the two bars,
// with no sticky behaviour at this attachment: that corner just slides up, seamlessly
// into the bar corner.
// A popup that hangs from one bar and RESTS FLUSH against a bar across its edge (the
// notifications manager under the top bar, against the right bar) meets that bar at
// its foot in a concave corner, and at rest that corner is drawn exactly like the one
// the two bars make with each other: a circle of blendRadius. While the popup opens
// and closes a join like any other would be an S -- stretched toward where the
// popup will be (STICK: up to stretchMax down the bar and sideStretch of that along the
// foot), as long along the foot as the popup's own surface-tension corner there (the
// S's partner, 200 px at a few px of height), and grown in with the popup's presence --
// so for the whole of every open and close a long, shallow meniscus would run from the foot
// down the bar and lie back along it (136 x 15 at 5 px of popup, 200 x 37 at 24, 134 x
// 76 at 133, 35 x 34 at 280; the bars' own corner is 20 x 20), a different corner from
// the bars' that only becomes theirs at the very end. So the foot's corner IS the
// bars' corner, travelling: at no height it is the corner of the two bars, and as the
// foot goes down the bar's face it goes with it, the same circle in every frame, and
// on the way back it slides up and becomes the bars' corner again. The same fillet,
// not a second mechanism: the joint is solved as usual (`sJoint`; a foot within two
// corners of the bar's end, or a foot shorter than two corners, still tightens its S),
// with these three changes at the foot's end of the relation, all by `wall` (0..1):
//   - no resistance (`st`): the fillet's tip stays on the foot;
//   - its ceiling along the foot is blendRadius, not the far corner's radius (`fillA`);
//   - its weight is the contact alone, not the popup's presence along the bar (`wI`):
//     from the first sliver of popup it is the whole fillet and the popup's corner on
//     the bar is square, because the bars' corner is already there at no height and
//     the popup's join with it must be that corner and nothing less. (The bars' own
//     fillet is still drawn at the top and costs nothing: every point of it below the
//     foot lies outside the bars' disc and so outside this one, the same disc moved
//     down, and above the foot it lies inside the popup.)
// `wall` is how flush the popup RESTS against that bar -- its open box (`stick`), else
// the box it is -- eased in over twice snapDistance of the gap (THE ARRIVAL, below), so a
// popup that opens toward a wall it will not rest against, or one that rests anywhere
// but flush (the engine places every rest within snapDistance flush: GooeyEngine THE
// WALL), keeps its ordinary join; and it only exists for a body that names the edge
// it hangs from (`wallJoin`: the engine's primaries; not a secondary, not the lane). Only
// the foot's end changes: the popup's join with its own bar, its far corner, every other
// relation are the ordinary ones.
//
// THE ARRIVAL (the host's verifier). The manager opening while a toast is up: the lane
// yields and holds the manager's face off the bar by its own edge until it has gone
// (laneClip clips the stick box with the box, so the rest gap IS the face's gap), and the
// manager reaches the bar while its foot is still 50 px short of its rest. With `wall`
// switching on over the last 1.5 px (CONTACT) the join would form as the stretched
// fillet (`st` 30 px) and, the frame the face touched, become the circle: the corner's
// reach went 42 rows -> 15 in ONE frame (51 -> 17 in three at 60 steps to the open, 34 in
// one at 24 frames). The weight eases in with the face's real gap over twice
// snapDistance (100 px), which is longer than the join's own onset (the face's pull
// begins ~17 px out): by the time the join first forms the wall's terms are already 0.9
// of the circle's, so it forms AS the circle, growing in with the pull, and there is no
// meniscus to relax. Measured on the manager arriving mid-open (the reach is the
// rows below the foot the outline stays within 0.7 px of the bar): the largest step of
// the reach between two frames, by the length of the ease, is 17.85 rows at 12 px, 16.65 at
// 17, 7.85 at 30, 3.25 at 50, 1.55 at 75, 0.90 at 100 -- a relaxation of the stretched
// meniscus steps 2.4.
// A popup whose rest is flush has gap 0 from its first frame and no arrival (the circle
// from the first frame); one with no stick box (a migration, a retarget)
// eases by its own box, where the plain terms ARE the circle's for a full-size popup.
//
// STICK. While a popup opens or closes, the tip of a fillet on the bar resists
// moving with the popup's side: at stickiness 1 it stays where the tip will be
// when the popup is open and the fillet stretches (up to stretchMax, and by
// sideStretch of that down the side); at 0 it moves rigidly with the side. It
// is the same on all four edges: the stretch belongs to the guest, and is scaled
// by how far out the guest is ALONG THE BAR IT IS JOINED TO -- a popup closing
// on a side bar shrinks along that bar, so its join there shrinks with it.
//
// VOIDS. When D's span has left U's span along b (a popup crossing the gap
// between two bars), each keeps a FLARE at the end facing the other: a quarter
// fillet pointing along the shared line, shrinking and turning back into a
// convex corner over snapDistance of separation. At the moment the spans stop
// overlapping the flares are the pieces they were an instant earlier.
//
// THE POCKET: the `U` shape is pushed out towards where the new corner is made and
// naturally melts into it, scaling and translating freely in two dimensions. A channel between a guest's
// face and a facing face -- a label rising beside its strip toward the bar, a popup
// sliding along the top bar toward a side bar -- CAPPED at one end by a third body
// joined to both (the strip; the corner of the two bars) ends there in a C: the
// cap's two fillets facing each other across the gap. Flattening that C in place as the gap
// closes would bring the corner the guest makes with the face at the channel's
// OPEN end only with the join at contact (a bar and a child join at 0.5 px of
// gap, in one frame). So the channel closes like a zipper from the capped end.
// Within `pocketReach` of drawn gap (default twice the blend radius):
//   - a fill (a seam across the gap) runs from the cap toward the open end, `z` of
//     the way: 1 - 1.5u + 0.5u^3 of the gap's fraction u -- no speed at the start,
//     near proportional after, 1 at contact;
//   - the front IS the C: the two fillets the field draws at the cap, moved along the
//     channel by the fill's travel (at no travel they are that C -- a C grown in from
//     nothing would let the fill's square end cut through it, a crease);
//   - over the last blend radius of travel (from where the morph stands at no travel,
//     so a channel shorter than that still leaves the cap as its C) the fillet on the
//     face that RUNS ON morphs into the fillet the join draws at contact, its vertex
//     staying on the front, and the guest's two corners there into theirs -- both from
//     the same pose solved with the guest moved flush (a second fieldShape, the pocket
//     off) -- so the shape at contact is the same on both sides of the hand-over;
//   - the fillet on the face that ENDS gives way as the flat room ahead of it runs out
//     (over one reach), and that body's corner on the channel squares to the room left;
//   - the pocket runs down to contact itself and its fillets withdraw into the contact
//     join over the last quarter pixel of gap (stopped at 0.5 px, it would hand over to a
//     slit of air; dropped in one frame, a whole corner's fillet would vanish at once).
// Not between PEERS (their places are the engine's, and a fill across a gap the eye
// can see is a bridge: PEERS), and not where the closing body's corners at the open
// end are another join's (a child hanging under a parent that slides into a side
// bar: that join is solved for the corner as it is, and morphing it alone would detach
// the two) -- unless that join's S is LOOSE there and its other body still: a straight
// run lies between the S's pieces, so the corner is free (an island's end corner is the
// outer piece of the S its slim side bar makes at the island's other end; refused, the
// tray's label lost its pocket whenever it reached past the island's end).
//
// SETTLING. The host's weight in every relation, and its flare in every void,
// may rise at once but only falls by dt/settleMs per frame, so a bar's corner
// that lets go of a popup relaxes instead of snapping back.
//
// SOLID. Nothing a join draws may lie over the air a corner leaves: a face on
// the shared line stops at its corner's own reach along b (its radius while the
// corner is free, the joint's `off` once it is shaped), and a seam's ends, a
// fillet's vertex and its reach along the other body's face all stop there.
//
// SEAMS. Where U and D touch along the shared line their interiors only MEET
// there, which draws a half-covered row -- so a thin rectangle is laid over the
// overlap, placed on the RESOLVED corners: it lies only where both bodies are
// solid across its depth, and near an end that thins (a lens-shaped popup's end,
// an end corner crossing the line) it steps down to thinner seams rather than
// stopping short. As the faces part (a popup letting go of a bar) the seam
// withdraws from both ends inward over NECK px of gap, so the parting never shows
// as a full-length hairline and never shuts air in. That holds for a channel open
// at both ends; one CAPPED at an end by a third body -- the slot between a popup
// and the side bar under a top bar, closed at its top by that bar and the
// corner's C -- is a pocket the moment a neck crosses it in the middle, so there
// the neck zips from the capped end instead (a hole the height of the slot while
// a popup's end closes on a side bar: 89 px2 at 3.5 px of gap, up to
// 178 without the zip). Touching void flares get one where both are solid. Fillets bleed across
// the line only while the faces touch.
//
// Between two BARS the seam reaches BAR_SEAM into each, not BLEED. Coverage is
// the distance over its screen-space gradient, and the GPU takes that gradient
// across a 2 x 2 pixel block: a shallow seam leaves the union's distance with a
// step within a pixel of a flush end on the screen's edge, which reads as a
// steeper gradient there. Where a side bar meets the top bar the screen's last
// column came out 5 % transparent for two rows (the right edge only: which
// column of a block the edge pixel is depends on its parity). Bars are solid
// far deeper than that, so the deeper seam only flattens their interior.
// =============================================================================

const CORNER_TL = 0, CORNER_TR = 1, CORNER_BR = 2, CORNER_BL = 3;
const EPS = 1e-6;
const TINY = 0.05;      // gooey_field.frag's: a corner smaller than this is square
const BLEED = 1.5;
const PRESENCE = 8;     // px of guest over which the host's joins come in
// ...and for a BAR (an immobile body) the same ramp is this long: a bar's joints are the bars' own corners, the same circle as a
// popup's with the bar it hangs from (the joints take the popup's rounding), and the 6 px outlet is thinner than
// PRESENCE, so over 8 px its joint was 27/32 of a popup's. Over 2 px an outlet is whole up to a frame scale of 3, and a bar eased away
// by the bars toggle still lets its joints go over its last 2 px.
const BAR_PRESENCE = 2;
const NECK = 4;         // px of gap over which a parting seam withdraws
const BAR_SEAM = 6;     // px a seam between two bars reaches into each (SEAMS)
const CONTACT = 1.5;    // px of gap over which a join comes in (`contact`)
const TOUCH_REACH = 1.5;   // px past 0.5 of gap over which a child's touch of a bar comes in (`touchWeight`)
const PEER_CONTACT = 1.5;   // px of gap over which a PEER join comes in (PEERS)
const PEER_SEAM = 0.5;      // px of gap over which a peer seam zips in (PEERS)
const POCKET_TIGHTEN = 0.5;   // the most of a pocket's reach a corner longer than its channel tightens over before the zip (THE POCKET)
const POCKET_SQUARE = 2;      // the corners of room over which a pocket's open-end corner squares (THE POCKET)
const POCKET_ARRIVE = 0.75;   // the pocket's front's speed as it reaches the open end, in channels per gap fraction (THE POCKET)
const CROSS = 1;        // px by which two facing fillets cross over which their share comes in

function smoothstep(e0, e1, x) {
    if (e1 <= e0)
        return x < e0 ? 0 : 1;
    const t = Math.max(0, Math.min(1, (x - e0) / (e1 - e0)));
    return t * t * (3 - 2 * t);
}

function clamp01(v) {
    return Math.max(0, Math.min(1, v));
}

function lerp(a, b, t) {
    return a + (b - a) * t;
}

// PEERS (header): how much two peers are joined at a gap of `g` px -- 1 touching,
// 0 from PEER_CONTACT on, continuous in between.
function peerWeight(g) {
    return 1 - smoothstep(0, PEER_CONTACT, Math.max(0, g));
}

// A child's touch of a bar by its gap: 1 from 0.5 px apart to any penetration, out over TOUCH_REACH beyond that (touchOnly, in the relations).
function touchWeight(g) {
    return g <= 0.5 ? 1 : 1 - smoothstep(0.5, 0.5 + TOUCH_REACH, g);
}

// ---- Surface tension (per axis) ------------------------------
// A popup that is still small is rounder than one at rest; its corners are
// squished into ellipses when a side is too short for them. `full*` is the size
// it is heading for, in screen axes.
function squish(size, r) {
    const threshold = 0.75, power = 1.2, minLimit = 0.05;
    if (!(r > 0) || !(size > 0))
        return 0;
    const ratio = size / (r * 2);
    if (ratio >= threshold)
        return Math.min(r, size / 2);
    const eased = Math.pow(ratio / threshold, power);
    return Math.min(r * (minLimit + eased * (1 - minLimit)), size / 2);
}

function tensionRadii(w, h, fullW, fullH, maxR) {
    w = Math.max(0, w);
    h = Math.max(0, h);
    let dyn = maxR;
    if (fullW > 0 && fullH > 0) {
        const inflation = clamp01(Math.min(w / fullW, h / fullH));
        dyn = maxR + (Math.max(fullW, fullH) / 2 - maxR) * Math.pow(1 - inflation, 2);
    }
    return { rx: squish(w, dyn), ry: squish(h, dyn) };
}

// ---- The S-curve ----------------------------------------------------------------
// Two pieces crossing |delta| along b. Piece k may reach Bk along b and hk along
// a. Each is an elliptical arc (a circle of radius rk = hk / sin(theta_k) with b
// scaled by sk = Bk / hk) that leaves its side tangentially and turns through
// theta_k; the two share their tangent where they meet, sk tan(theta_k) equal,
// and their b-offsets Bk tan(theta_k / 2) add up to |delta|. At theta 90 degrees
// each is a quarter ellipse Bk x hk.
//
// A piece: { eb, ea } semi-axes along b and a, { ib, ia } its centre's inset
// from the vertex it hangs off (along b from the side, along a from the shared
// line), `off` how far along b it reaches, and `th` the angle it turns through
// (a quarter turn when it is loose: CLAIMS ranks the tighter).
function quarterPiece(B, h) {
    return { eb: B, ea: h, ib: B, ia: h, off: B, th: Math.PI / 2 };
}

function arcPiece(theta, B, h) {
    const s = Math.max(Math.sin(theta), 1e-4);
    return { eb: B / s, ea: h / s, ib: B / s, ia: h, off: B * Math.tan(theta / 2), th: theta };
}

function sCurve(delta, B1, h1, B2, h2) {
    const ok1 = B1 > 1e-3 && h1 > 1e-3;
    const ok2 = B2 > 1e-3 && h2 > 1e-3;
    if (delta < 1e-3 || (!ok1 && !ok2))
        return [null, null];
    const cap = (ok1 ? B1 : 0) + (ok2 ? B2 : 0);
    if (delta >= cap)
        return [ok1 ? quarterPiece(B1, h1) : null, ok2 ? quarterPiece(B2, h2) : null];
    if (!ok2)
        return [arcPiece(2 * Math.atan(delta / B1), B1, h1), null];
    if (!ok1)
        return [null, arcPiece(2 * Math.atan(delta / B2), B2, h2)];
    const s1 = B1 / h1, s2 = B2 / h2;
    function theta2Of(t1) {
        return Math.atan(s1 * Math.tan(t1) / s2);
    }
    let lo = 0, hi = Math.PI / 2;
    for (let i = 0; i < 40; i++) {
        const mid = 0.5 * (lo + hi);
        const f = B1 * Math.tan(mid / 2) + B2 * Math.tan(theta2Of(mid) / 2) - delta;
        if (f > 0)
            hi = mid;
        else
            lo = mid;
    }
    const t1 = 0.5 * (lo + hi);
    return [arcPiece(t1, B1, h1), arcPiece(theta2Of(t1), B2, h2)];
}

// ---- The joint ------------------------------------------------------------------
// At one end of a join the fillet is a piece of TWO S-curves at once: ACROSS the
// shared line (partner: the outer body's corner, `delta` away) and DOWN the
// inner body's side (partner: that body's far corner, `side` away). Solving them
// one after the other -- fitting the fillet to one S and then bending it toward
// the other -- moves its tip away from the corner that was solved for it, and
// the join reads as DETACHED. So one ellipse is solved for both: it crosses the
// line at theta_A and the side face at theta_D, and each partner takes the angle
// that shares its tangent.
//
//   s = HB / HA (the fillet's own aspect), rho = HA / min(sin thA, sin thD)
//   reach along b  = s rho (sin thD - cos thA),  centre b = s rho sin thD
//   reach along a  =   rho (sin thA - cos thD),  centre a =   rho sin thA
//   semi-axes      = (s rho, rho)
//
// At thD = 90 degrees that is exactly arcPiece(thA, HB, HA), at thA = 90 exactly
// the down-side piece, and with both at 90 the quarter HB x HA -- so a join with
// room on both sides is unchanged. The two angles are found by nested bisection:
// each residual (what the pair still has to cover, along b and down a) rises
// with its own angle.
// The joint's solve, its pieces as module functions of their numbers: QV4 makes every closure anew on each call and inlines
// nothing, and the bisections below evaluate them up to ~600 times a joint. The arithmetic is the closures' own, operation for
// operation (sin(thA) taken once per solveD is the same number every time it was taken).
//   s = HB / HA; okO / okF: the outer / far corner is there; geom(thA, thD) is the fillet's ellipse at those angles.
const SJ_HALF = Math.PI / 2;
function sjTanAt(th) {
    return Math.tan(Math.min(th, SJ_HALF - 1e-9));
}
function sjThetaO(thA, s, okO, BO, hO) {
    return okO ? Math.atan(s * sjTanAt(thA) * hO / BO) : SJ_HALF;
}
function sjThetaF(thD, s, okF, BF, hF) {
    return okF ? Math.atan(sjTanAt(thD) * hF / (s * BF)) : SJ_HALF;
}
// How far the pair still has to cover down the side (leftA) and along the line (leftB), for a pair of angles; `sA` is sin(thA).
function sjLeftA(sA, thD, side, HA, s, okF, BF, hF) {
    const sD = Math.sin(thD);
    const rho = HA / Math.max(Math.min(sA, sD), 1e-4);
    return Math.max(0, rho * (sA - Math.cos(thD)))
        + (okF ? BF * Math.tan(sjThetaF(thD, s, okF, BF, hF) / 2) : 0) - side;
}
function sjLeftB(thA, thD, delta, HA, s, okO, BO, hO) {
    const sA = Math.sin(thA), sD = Math.sin(thD);
    const rho = HA / Math.max(Math.min(sA, sD), 1e-4);
    return Math.max(0, s * rho * (sD - Math.cos(thA)))
        + (okO ? BO * Math.tan(sjThetaO(thA, s, okO, BO, hO) / 2) : 0) - delta;
}
// For this thA, how far down the side the pair reaches.
function sjSolveD(thA, side, HA, s, okF, BF, hF) {
    if (!(side > 1e-3))
        return 1e-4;
    const sA = Math.sin(thA);
    if (sjLeftA(sA, SJ_HALF, side, HA, s, okF, BF, hF) <= 0)
        return SJ_HALF;
    let lo = 0, hi = SJ_HALF;
    for (let i = 0; i < 24; i++) {
        const mid = 0.5 * (lo + hi);
        if (sjLeftA(sA, mid, side, HA, s, okF, BF, hF) > 0)
            hi = mid;
        else
            lo = mid;
    }
    return 0.5 * (lo + hi);
}
function sJoint(delta, side, HB, HA, BO, hO, BF, hF) {
    const none = { fillet: null, corner: null, far: null };
    if (!(delta > 1e-3) || !(HB > 1e-3) || !(HA > 1e-3))
        return none;
    const HALF = SJ_HALF;
    const s = HB / HA;
    const okO = BO > 1e-3 && hO > 1e-3;
    const okF = BF > 1e-3 && hF > 1e-3 && side < 1e8;
    let thA = HALF, thD = sjSolveD(HALF, side, HA, s, okF, BF, hF);
    if (sjLeftB(HALF, thD, delta, HA, s, okO, BO, hO) > 0) {
        let lo = 0, hi = HALF;
        for (let i = 0; i < 24; i++) {
            const mid = 0.5 * (lo + hi);
            if (sjLeftB(mid, sjSolveD(mid, side, HA, s, okF, BF, hF), delta, HA, s, okO, BO, hO) > 0)
                hi = mid;
            else
                lo = mid;
        }
        thA = 0.5 * (lo + hi);
        thD = sjSolveD(thA, side, HA, s, okF, BF, hF);
    }
    // geom(thA, thD)
    const sA = Math.sin(thA), sD = Math.sin(thD);
    const rho = HA / Math.max(Math.min(sA, sD), 1e-4);
    const g = { rb: s * rho * (sD - Math.cos(thA)), ra: rho * (sA - Math.cos(thD)),
                cb: s * rho * sD, ca: rho * sA, eb: s * rho, ea: rho };
    const cOut = okO ? arcPiece(sjThetaO(thA, s, okO, BO, hO), BO, hO) : null;
    const dFar = okF ? arcPiece(sjThetaF(thD, s, okF, BF, hF), BF, hF) : null;
    return {
        fillet: { rb: Math.max(0, g.rb), ra: Math.max(0, g.ra), cb: g.cb, ca: g.ca, eb: g.eb, ea: g.ea },
        corner: cOut,
        // The far corner, swapped out of the down frame into the relation's.
        far: dFar ? { eb: dFar.ea, ea: dFar.eb, ib: dFar.ia, ia: dFar.ib, th: dFar.th } : null,
        thA: thA, thD: thD
    };
}

// ---- The end corner ---------------------------------------------------------------
// A guest whose end is drawn onto a host's end (a popup flush with its bar's end)
// makes ONE corner with it: an ellipse tangent to the guest's far face and to the
// host's side, Rb along b and Ra along a from the far face. `p` is the host's
// weight, `h` the guest's extent along a, (rHb, rHa) the host's free radii,
// (rb, ra) the guest's and R the blend radius, whose half is the tip's floor
// `rho` -- not the host's radius, which a bar may have set to half a thickness
// of a few px.
//
// With the guest fully present it is the guest's own corner over its whole side
// but a bleed (its corner on the line is square here), and never turns tighter
// at its tip than `rho`: a surface-tension corner (rb much longer than ra) keeps
// its length along the far face and takes more of the side, or, where the side
// is too short for that, gives up length until it is round. With no guest it is
// the host's own corner, reached through the sliver of guest on top of it:
// Ra = h + rHa. In
// between the two are interpolated, and while Ra is longer than the guest's side
// the corner crosses the shared line `dm` short of the host's end, where the
// guest's end is drawn and the host's corner carries the rest of the curve.
function endCorner(p, h, rHb, rHa, rb, ra, span, R) {
    h = Math.max(0, h);
    const rho = Math.min(0.5 * R, h);
    // Short of the line by a bleed where the side allows: the seam over the
    // shared line runs out to the end only where the guest is solid there.
    const side = Math.max(0.5 * h, h - BLEED);
    const Ra1 = Math.min(side, Math.max(ra, Math.sqrt(Math.max(0, rho * rb))));
    // Its tip on the side turns at Ra1^2 / Rb1 and its tip on the far face at
    // Rb1^2 / Ra1: lengthened to rho on the side, but never narrower than round,
    // or a side too short for rho turns the far-face tip tighter still (3.9 at 7
    // px of popup, where the side's tip would have been 7).
    const Rb1 = rho > EPS ? Math.min(rb, Math.max(Ra1, Ra1 * Ra1 / rho)) : 0;
    const Rb = Math.max(0, Math.min(lerp(rHb, Rb1, p), 0.5 * span));
    const Ra = lerp(h + rHa, Ra1, p);
    const over = Ra - h;
    const dm = over > EPS && Ra > EPS ? Rb * (1 - Math.sqrt(Math.max(0, 1 - (over / Ra) * (over / Ra)))) : 0;
    return { Rb: Rb, Ra: Ra, dm: dm };
}

// ---- Two fillets facing each other ------------------------------------------------
// How thick a fillet stands off its face at `s` along it from its vertex: a
// quarter ellipse `r` along the face and `T` off it, T at the vertex, 0 at r.
function filletThickness(T, r, s) {
    if (!(r > 1e-6) || !(T > 0) || s >= r)
        return 0;
    if (s <= 0)
        return T;
    const u = 1 - s / r;
    return T * (1 - Math.sqrt(Math.max(0, 1 - u * u)));
}

// (FACING FILLETS, header.) A fillet runs along two faces: the shared line (b,
// from the inner body's end outward) and the inner body's side (a, from the
// line away). Pairs on one line, on the same side of it, running toward each
// other from nominal ends that are apart, split the stretch between their
// vertices. Two side faces never pair: the S down a body's side already sees its
// far corner. Returns per join the largest ceilings { b, a } its fillet may take.
function facingCaps(joins, R, sideStretch) {
    const caps = joins.map(() => ({ b: Infinity, a: Infinity }));
    const faces = [];
    for (let n = 0; n < joins.length; n++) {
        const j = joins[n];
        // The weight the fillet is drawn at (an end corner takes over from it).
        const w = j.wI * (1 - j.kC);
        if (!(w > 1e-4) || !(j.delta > 1e-3))
            continue;
        const vertB = j.iEnd - j.dir * j.insI;
        const along = j.axis === "y";
        const ceilB = R + j.st, ceilA = j.fillA + j.st * sideStretch;
        // `depth`: the most the fillet can stand off that face -- down the inner
        // body's side (no further than the side is long) off the line, along the
        // line (no further than the S has to cross) off the side.
        // Along the shared line: a line of constant a, from the end outward.
        // `body`: how far the body BEHIND the vertex stands off that face (the
        // inner body along a off the line; the outer body along b off the side),
        // and `bodyR` the rounding of its far corner there.
        faces.push({ n: n, which: "b", horiz: along, c: j.va, end: j.iEnd, v: vertB, dir: j.dir, side: j.dirA,
                     w: w, ceil: ceilB, depth: Math.min(ceilA, Math.max(0, j.side)), body: Math.max(0, j.side), bodyR: j.raI });
        // Down the inner body's side: a line of constant b, from the line away.
        faces.push({ n: n, which: "a", horiz: !along, c: vertB, end: j.va, v: j.va, dir: j.dirA, side: j.dir,
                     w: w, ceil: ceilA, depth: Math.min(ceilB, j.delta), body: j.delta, bodyR: j.rbO });
    }
    for (let p = 0; p < faces.length; p++) {
        for (let q = p + 1; q < faces.length; q++) {
            const F = faces[p], G = faces[q];
            // On one line: a guest's face lies up to its contact range off the
            // host's (a popup still parting from the top bar), and the share
            // fades out over that range with the join itself -- a cut-off here
            // flipped the corner between shared and crossed in one frame.
            const off = Math.abs(F.c - G.c);
            if (F.n === G.n || (F.which === "a" && G.which === "a") || F.horiz !== G.horiz
                || off >= CONTACT || F.side !== G.side || F.dir !== -G.dir)
                continue;
            const apart = (G.end - F.end) * F.dir;
            if (!(apart > 0))
                continue;
            const room = (G.v - F.v) * F.dir;
            const rf = F.w * F.ceil, rg = G.w * G.ceil;
            if (rf + rg <= room || !(room > 0))
                continue;
            // In with the weaker join's weight; out as the stretch closes, over
            // the quarter pixel a touching seam takes to cover the line whole;
            // and in only where there is a cusp to prevent (header): the two
            // CROSS above the face (at its own vertex each is thicker than the
            // other is there), or one's arc leaves the body behind the other's
            // vertex within that body's far-corner rounding (it would cut into
            // the round corner). Past the rounding the arc crosses a flat face
            // -- the guest's own shape -- and a share only takes material the
            // guest does not cover: a popup a few px tall beside the corner of
            // two bars squeezed the corner's fillet for a frame at each end of
            // every open and close.
            const tf = F.w * F.depth, tg = G.w * G.depth;
            const cross = Math.min(tg - filletThickness(tf, rf, room), tf - filletThickness(tg, rg, room));
            // (One that does not reach the other's vertex, or a body with no
            // extent -- a popup at the first frame of its open -- leaves no
            // corner to cut into.)
            const edge = (t, r, X) => {
                const at = filletThickness(t, r, room), past = at - X.body;
                return smoothstep(0, CROSS, at) * smoothstep(0, CROSS, X.body)
                    * smoothstep(-X.bodyR - CROSS, -X.bodyR, past) * (1 - smoothstep(X.bodyR, X.bodyR + CROSS, past));
            };
            const need = Math.max(smoothstep(0, CROSS, cross), edge(tf, rf, G), edge(tg, rg, F));
            const k = Math.min(F.w, G.w) * smoothstep(0, 0.25, apart) * (1 - smoothstep(0, CONTACT, off)) * need;
            for (const [X, rx, ry] of [[F, rf, rg], [G, rg, rf]]) {
                const drawn = lerp(rx, room * rx / (rx + ry), k);
                caps[X.n][X.which] = Math.min(caps[X.n][X.which], drawn / X.w);
            }
        }
    }
    return caps;
}

// ---- The wall join ------------------------------------------------------------------
// (THE WALL JOIN, header.) How much of a popup's join with `H` is the wall's:
// 1 when the popup RESTS flush against H -- the box it is open at (`stick`, while
// it opens and closes) or else the box it is, touching H's face along `axis` --
// 0 from `reach` px off it (twice snapDistance: THE ARRIVAL, header), smooth in between. Only a popup that hangs from
// an edge (`wallJoin`) has one, only with a bar on a face ACROSS that edge (a bar
// along its own edge is its host: the relation runs along the edge), and only
// the bar's own faces count -- a popup resting 12..50 px short of a wall is the
// engine's to place flush (THE WALL), so this never has to guess at a gap.
function wallWeight(H, Gb, axis, n, reach) {
    if (!Gb.wallJoin || H.mobile || Gb.parent || H.free || Gb.free)
        return 0;
    const hostAxis = (Gb.wallJoin === "top" || Gb.wallJoin === "bottom") ? "y" : "x";
    if (axis === hostAxis)
        return 0;
    const rest = Gb.stick || Gb.box;
    const g = n > 0 ? aLo(rest, axis) - aHi(H.box, axis) : aLo(H.box, axis) - aHi(rest, axis);
    return 1 - smoothstep(0, reach, Math.max(0, g));
}

// Which END of a wall relation (along b, the bar's own axis) is the popup's
// FOOT: the end farthest from the edge it hangs from. The relation runs along
// `axis`, so b is the other one: down a side bar for a popup hanging from the
// top (+1) or up it from the bottom (-1), along the top bar for one hanging
// from the left (+1) or the right (-1).
function wallFoot(edge, axis) {
    if (axis === "x")
        return edge === "top" ? 1 : -1;
    return edge === "left" ? 1 : -1;
}

// ---- Axis helpers ----------------------------------------------------------------
// Along axis "y" a box's a-span is its y-span and its b-span its x-span; along
// "x" the other way round. A corner is named by which end of b and of a it sits
// at (-1 low, +1 high).
function aLo(box, axis) { return axis === "y" ? box.y0 : box.x0; }
function aHi(box, axis) { return axis === "y" ? box.y1 : box.x1; }
function bLo(box, axis) { return axis === "y" ? box.x0 : box.y0; }
function bHi(box, axis) { return axis === "y" ? box.x1 : box.y1; }

// Which END of `box` along `axis` the overlap `I` is (-1 low, +1 high), or 0
// when it is not a whole end: it must cover the box's full span across the
// axis and reach exactly one of its ends.
const CAP_EPS = 1e-3;
function capEnd(box, I, axis) {
    if (Math.abs(bLo(I, axis) - bLo(box, axis)) > CAP_EPS || Math.abs(bHi(I, axis) - bHi(box, axis)) > CAP_EPS)
        return 0;
    const lo = Math.abs(aLo(I, axis) - aLo(box, axis)) <= CAP_EPS;
    const hi = Math.abs(aHi(I, axis) - aHi(box, axis)) <= CAP_EPS;
    return lo === hi ? 0 : (lo ? -1 : 1);
}

function cornerIndex(sx, sy) {
    return sy < 0 ? (sx < 0 ? CORNER_TL : CORNER_TR) : (sx < 0 ? CORNER_BL : CORNER_BR);
}
// cornerIndex with the sides named along the relation (one call: QV4 inlines nothing).
function cornerOf(axis, bSide, aSide) {
    const sx = axis === "y" ? bSide : aSide, sy = axis === "y" ? aSide : bSide;
    return sy < 0 ? (sx < 0 ? CORNER_TL : CORNER_TR) : (sx < 0 ? CORNER_BL : CORNER_BR);
}

// ---- The shape ------------------------------------------------------------------
// THE BORDER'S END. The shell's border is a ring OUTSIDE the surface (the field's shader), `w` wide along the outline, and an island's end flares
// into the screen's edge through the sky's fillet: tangent to the edge's line, where the ring is `w` thick measured straight down -- so the ring
// would end on the screen's edge in a stub `w` thick. With the sky's face, and the bar's face on it, `w` OFF the screen the
// fillet is tangent to a line `w` beyond the edge, the ring's inner curve is tangent to the edge itself, and the ring comes to the screen at no
// thickness at all, `w` of the vertical run delaying where the curve starts. The surface the screen shows is the same but for the curve's start; the
// border stays `w` thick everywhere. `skyBox` names its edge by the face it shares with the bar.
function skyOut(s, w) {
    const sb = s.skyBox;
    const x0 = Math.min(s.x0, s.x1), x1 = Math.max(s.x0, s.x1), y0 = Math.min(s.y0, s.y1), y1 = Math.max(s.y0, s.y1);
    const on = (a, b) => Math.abs(a - b) <= 0.5;
    const o = Object.assign({}, s);
    const k = Object.assign({}, sb);
    if (on(sb.y1, y0)) { o.y0 = y0 - w; o.y1 = y1; k.y1 = sb.y1 - w; }
    else if (on(sb.y0, y1)) { o.y1 = y1 + w; o.y0 = y0; k.y0 = sb.y0 + w; }
    else if (on(sb.x1, x0)) { o.x0 = x0 - w; o.x1 = x1; k.x1 = sb.x1 - w; }
    else if (on(sb.x0, x1)) { o.x1 = x1 + w; o.x0 = x0; k.x0 = sb.x0 + w; }
    else return s;
    o.skyBox = k;
    return o;
}

function spanGap(u0, u1, d0, d1) {
    return Math.max(d0 - u1, u0 - d1, 0);
}
// A body with no extent along a lies ON a face rather than before or past
// it: a popup whose height has gone to nothing still rests on its bar, so its
// joins let go on their own clock instead of vanishing in one frame.
function ordered(U, D, axis) {
    const Y = axis === "y";
    const u0 = Y ? U.y0 : U.x0, u1 = Y ? U.y1 : U.x1, d0 = Y ? D.y0 : D.x0, d1 = Y ? D.y1 : D.x1;
    const uThin = u1 - u0 <= EPS, dThin = d1 - d0 <= EPS;
    if (uThin && dThin)
        return false;
    return (u0 < d0 - EPS || (uThin && u0 <= d0 + EPS))
        && (u1 < d1 - EPS || (dThin && u1 <= d1 + EPS));
}
function aExtent(box, axis) {
    return axis === "y" ? box.y1 - box.y0 : box.x1 - box.x0;
}

// ---- The seams' solid tests (SEAMS, header) -------------------------------------------------------
// (Module functions, not closures of fieldShape: they read nothing of it, and QV4 makes every inner function anew on each call.
// Loops are counted, never `for (... of ...)`: in QV4 an iterator step costs ~15 times a counted one.)
const SEAM_LEVELS = [1, 0.7, 0.5, 0.35, 0.25, -1];
// Where along b a body is solid at the a-coordinate c0 -- and at c1 too, when one is given -- on its RESOLVED corners: { lo, hi },
// empty (lo > hi) where it is not solid at all.
function solidSpan(body, axis, c0, c1) {
    const X = axis === "y", d = body.drawn, two = c1 !== undefined;
    const r = { lo: X ? d.x0 : d.y0, hi: X ? d.x1 : d.y1 };
    const a0 = X ? d.y0 : d.x0, a1 = X ? d.y1 : d.x1;
    if (c0 < a0 - 1e-6 || c0 > a1 + 1e-6 || (two && (c1 < a0 - 1e-6 || c1 > a1 + 1e-6)))
        return { lo: Infinity, hi: -Infinity };
    for (let sb = -1; sb <= 1; sb += 2) {
        let del = 0;
        for (let sa = -1; sa <= 1; sa += 2) {
            const k = cornerOf(axis, sb, sa);
            const eb = X ? body.ex[k] : body.ey[k], ea = X ? body.ey[k] : body.ex[k];
            const ib = X ? body.ix[k] : body.iy[k], ia = X ? body.iy[k] : body.ix[k];
            if (Math.min(eb, ea) < TINY || Math.min(ib, ia) < TINY)
                continue;
            let qa = ia - (sa < 0 ? c0 - a0 : a1 - c0);
            if (!(qa <= 0)) {
                const t = qa / ea;
                del = Math.max(del, t >= 1 ? ib : Math.max(0, ib - eb * Math.sqrt(1 - t * t)));
            }
            if (two) {
                qa = ia - (sa < 0 ? c1 - a0 : a1 - c1);
                if (!(qa <= 0)) {
                    const t = qa / ea;
                    del = Math.max(del, t >= 1 ? ib : Math.max(0, ib - eb * Math.sqrt(1 - t * t)));
                }
            }
        }
        if (sb < 0)
            r.lo += del;
        else
            r.hi -= del;
    }
    return r;
}
// Whether a body thins near an end: solid across a0..a1 over less of b than at the one on the shared line (lineSide +1: a1).
function seamThins(X, axis, a0, a1, lineSide) {
    const deep = solidSpan(X, axis, a0, a1), flat = solidSpan(X, axis, lineSide > 0 ? a1 : a0);
    return deep.lo > flat.lo + 0.05 || deep.hi < flat.hi - 0.05;
}
// How thick a body is at `b` along its b-span, measured from its face on the
// shared line (`lineSide` +1: its high a-face), on its resolved corners: 0
// where the corner on that face has cut the face itself away.
function thicknessAt(body, axis, b, lineSide) {
    const X = axis === "y", d = body.drawn;
    const ext = X ? d.y1 - d.y0 : d.x1 - d.x0;
    const lo = X ? d.x0 : d.y0, hi = X ? d.x1 : d.y1;
    if (b < lo || b > hi)
        return 0;
    const sb = b - lo <= hi - b ? -1 : 1;
    const dist = sb < 0 ? b - lo : hi - b;
    const kl = cornerOf(axis, sb, lineSide);
    const lEb = X ? body.ex[kl] : body.ey[kl], lEa = X ? body.ey[kl] : body.ex[kl];
    const lIb = X ? body.ix[kl] : body.iy[kl], lIa = X ? body.iy[kl] : body.ix[kl];
    if (Math.min(lEb, lEa) >= TINY && Math.min(lIb, lIa) >= TINY) {
        const qb = lIb - dist;
        if (qb > 0 && (qb / lEb) * (qb / lEb) + (lIa / lEa) * (lIa / lEa) > 1)
            return 0;
    }
    const kf = cornerOf(axis, sb, -lineSide);
    const fEb = X ? body.ex[kf] : body.ey[kf], fEa = X ? body.ey[kf] : body.ex[kf];
    const fIb = X ? body.ix[kf] : body.iy[kf], fIa = X ? body.iy[kf] : body.ix[kf];
    if (!(Math.min(fEb, fEa) >= TINY && Math.min(fIb, fIa) >= TINY))
        return ext;
    const qb = fIb - dist;
    if (qb <= 0)
        return ext;
    const qaMax = qb >= fEb ? 0 : fEa * Math.sqrt(1 - (qb / fEb) * (qb / fEb));
    return Math.max(0, ext - Math.max(0, fIa - qaMax));
}

// ---- The bodies' corners at the start (fieldShape) --------------------------------------------------
// A free corner's neighbour along x and along y (TL's: TR along the top, BL down the left).
const ALONG_X = [CORNER_TR, CORNER_TL, CORNER_BL, CORNER_BR];
const ALONG_Y = [CORNER_BL, CORNER_BR, CORNER_TR, CORNER_TL];
// A corner's own radius from the override list (`radii`): axis a of corner k.
function overrideRadius(ov, k, a) {
    const v = ov[k];
    const n = Number(Array.isArray(v) ? v[a] : v);
    return isFinite(n) ? Math.max(0, n) : 0;
}
// A corner's free radius along one axis: none when square, up to the whole side beside a flat neighbour (`along`), else half of it.
function cornerFree(sq, k, ov, cR, r0, flat, along, len) {
    return sq[k] ? 0 : Math.min(ov ? cR[k] : r0, flat[along[k]] ? len : len / 2);
}
// What the joins claim of one corner, before any has (CLAIMS).
function freshClaim() {
    return { piece: null, tight: 0, area: Infinity, sharp: 0, sharpBy: {}, limX: Infinity, limY: Infinity, voidX: Infinity, voidY: Infinity };
}
// THE SKY (header): the key of a distinct `skyBox`.
function skyKeyOf(b) {
    return Number(b.x0).toFixed(2) + "," + Number(b.y0).toFixed(2) + "," + Number(b.x1).toFixed(2) + "," + Number(b.y1).toFixed(2);
}

// ---- fieldShape's helpers of no state of its own (module functions: QV4 makes an inner function anew on every call) ----
// Two bodies touching corner to corner are a void seen along EITHER axis:
// the popup beside the bar's end along the bar, or below the bar's end
// along the end. Only one may flare. The spans must be further apart along
// b than the faces are along a, and on a tie (within half a pixel) the
// relation runs along the host's LONGER face -- a top bar flares along the
// bar, not down its 40 px end.
function voidOwner(Ub, axis, g, gA) {
    const own = gA - g;
    if (own > 0.5)
        return true;
    if (own < -0.5)
        return false;
    return (bHi(Ub, axis) - bLo(Ub, axis)) >= (aHi(Ub, axis) - aLo(Ub, axis));
}
// Host and guest, by kind. A bar hosts everything; a popup only its own
// child. A bar and another bar, or a bar and a child (a wide child clamped
// against a side bar), relate only where they touch: nothing snaps, flares,
// stretches or settles between them. A body that names another as its peer
// is related to it once, with that one in the host's seat (PEERS).
function hosts(H, Gb) {
    if (H.free || Gb.free)
        return false;
    // THE SKY (header): it hosts the bars that carry its box, and nothing else; nothing else is hosted by it.
    if (H.sky)
        return !Gb.mobile && !Gb.sky && Gb.skyKey === H.skyKey;
    if (Gb.sky)
        return false;
    if (Gb.parent && Gb.parent === H.id)
        return true;
    if (Gb.peer && Gb.peer === H.id)
        return true;
    if (Gb.peers.length > 0 && Gb.peers.indexOf(H.id) >= 0)
        return true;
    return !H.mobile;
}
function presenceSpan(body) {
    return body.mobile ? PRESENCE : BAR_PRESENCE;
}
function presence(body) {
    return smoothstep(0, presenceSpan(body), Math.min(body.box.x1 - body.box.x0, body.box.y1 - body.box.y0)) * body.join;
}
// (1b, in fieldShape) A child's drawn end, `u` into its parent, when the parent's face is drawn moved by M (hostU: where the bar
// clamps it).
function followU(u, M, hostU) {
    if (M < 0) {
        if (u >= 0)
            return u + M * (u <= -M ? 1 : Math.max(0, 1 - (u + M) / (-2 * M)));
        if (u > hostU && hostU < 0)
            return hostU + (u - hostU) * Math.max(0, (M - hostU) / -hostU);
        return u;
    }
    if (M > 0)
        return u + M * Math.max(0, 1 - Math.abs(u) / (2 * M));
    return u;
}
function spanOverlap(A, B, axis) {
    return Math.min(aHi(A, axis), aHi(B, axis)) - Math.max(aLo(A, axis), aLo(B, axis));
}
// Along axis `relAxis`, the body's free radius along b or along a (at
// `corner`, when given: a covered corner has none).
function freeAlong(body, relAxis, which, corner) {
    if (corner !== undefined && body.covered[corner])
        return 0;
    const alongX = which === "b" ? relAxis === "y" : relAxis === "x";
    if (corner !== undefined && body.perCorner)
        return alongX ? body.fRx[corner] : body.fRy[corner];
    return alongX ? body.freeRx : body.freeRy;
}
// A plain radius limit on one axis of a corner (both its semi-axis and its
// inset).
function limitRadius(body, corner, relAxis, which, value) {
    const alongX = which === "b" ? relAxis === "y" : relAxis === "x";
    const c = body.claims[corner];
    const v = Math.max(0, value);
    if (alongX)
        c.limX = Math.min(c.limX, v);
    else
        c.limY = Math.min(c.limY, v);
}
// A VOID's limit on one axis of a corner: the room a flare leaves the
// corner it grows out of. Kept apart from the plain limits because the
// corner may also be the outer piece of an S (a popup hanging past one bar's
// end with another bar's end within snapDistance): the joint is SOLVED
// against it (2b), so its piece reaches no further than the flare allows
// and is taken whole. Capped at resolve instead -- the piece's semi-axis is
// larger than its reach once the S is tight -- it lost the part its partner
// fillet was solved to meet: a 2.5 px shelf in the S, from the moment the
// other bar came within snapDistance (where the flare's weight is still 0).
function limitVoid(body, corner, relAxis, which, value) {
    const alongX = which === "b" ? relAxis === "y" : relAxis === "x";
    const c = body.claims[corner];
    const v = Math.max(0, value);
    if (alongX)
        c.voidX = Math.min(c.voidX, v);
    else
        c.voidY = Math.min(c.voidY, v);
}
// How much of the body a corner cuts away: what decides between two claims
// on a corner that are equally tight (CLAIMS). The AREA outside the ellipse
// within its inset box, not how far its arc runs along each face, which on a
// surface-tension corner (87 x 6.5) is ill-conditioned.
// cornerArea's primitive of the quarter circle, in radii.
function cornerPrim(u) {
    return 0.5 * (u * Math.sqrt(Math.max(0, 1 - u * u)) + Math.asin(Math.min(1, u)));
}
function cornerArea(ex, ey, ix, iy) {
    if (!(ex > 1e-6) || !(ey > 1e-6))
        return 0;
    const px = Math.min(1, ix / ex), py = Math.min(1, iy / ey);
    // The ellipse's quarter toward the corner, clipped to the box, in radii.
    const u0 = Math.min(px, Math.sqrt(Math.max(0, 1 - py * py)));
    const inside = py * u0 + (px > u0 ? cornerPrim(px) - cornerPrim(u0) : 0);
    return ix * iy - ex * ey * inside;
}
// A corner that is one piece of an S-curve (or, piece null, a sharp
// corner), weighted from the free corner.
// `aware`: the piece was solved against what is LEFT of this corner after
// every sharp claim, so it is already the right size. A piece from another
// join (the far corner of a fillet running down this body's side) was not,
// and is cut by the sharp claims like the free corner is.
function shapeCorner(body, corner, relAxis, piece, w, aware, tag) {
    if (w <= 1e-4)
        return;
    const c = body.claims[corner];
    if (!piece) {
        // A sharp corner: the largest claim decides how sharp. Which relation
        // asked is kept, so an end corner can tell its own join's claim from
        // another's.
        c.sharp = Math.max(c.sharp, w);
        const t = tag || "";
        c.sharpBy[t] = Math.max(c.sharpBy[t] || 0, w);
        return;
    }
    const fb = freeAlong(body, relAxis, "b", corner), fa = freeAlong(body, relAxis, "a", corner);
    const eb = lerp(fb, piece.eb, w), ea = lerp(fa, piece.ea, w);
    const ib = lerp(fb, piece.ib, w), ia = lerp(fa, piece.ia, w);
    const X = relAxis === "y";
    const ex = X ? eb : ea, ey = X ? ea : eb, ix = X ? ib : ia, iy = X ? ia : ib;
    const area = cornerArea(ex, ey, ix, iy);
    const tight = piece.th === undefined ? 0 : w * (Math.PI / 2 - piece.th);
    if (tight > c.tight + 1e-6 || (tight >= c.tight - 1e-6 && area < c.area)) {
        c.tight = Math.max(c.tight, tight);
        // The winning claim is taken WHOLE: it is one half of an S-curve,
        // and its partner fillet was solved for exactly these numbers.
        c.area = area;
        c.piece = { ex: ex, ey: ey, ix: ix, iy: iy, aware: !!aware };
    }
}
// How deep a seam may reach into a body across its face: no deeper than it
// is solid there (a popup two pixels tall is not 1.5 px deep past its
// rounded foot).
function solidDepth(body, axis) {
    return Math.min(BLEED, Math.max(0, aExtent(body.drawn, axis) - freeAlong(body, axis, "a")));
}
// How far along b past its vertex a flare of reach s and height ea is at
// least `depth` solid (negative: a rounded corner of radius -s ends that
// far before the end).
function flareSolid(s, ea, depth) {
    if (s <= 0)
        return s;
    if (ea <= depth)
        return 0;
    const t = (ea - depth) / ea;
    return s * (1 - Math.sqrt(Math.max(0, 1 - t * t)));
}
// Two bodies that join where they meet (either hosts the other) and that do.
function joinedAt(A, B) {
    if (!(hosts(A, B) || hosts(B, A)))
        return false;
    const a = A.drawn, b = B.drawn;
    return Math.max(a.x0 - b.x1, b.x0 - a.x1, a.y0 - b.y1, b.y0 - a.y1) <= 0.5;
}
function isPeer(A, B) {
    return (!!A.peer && A.peer === B.id) || (!!B.peer && B.peer === A.id)
        || A.peers.indexOf(B.id) >= 0 || B.peers.indexOf(A.id) >= 0;
}

// THE LOCAL NAMES. In QV4 a call to a function of this file from inside another costs ~60 ns -- the name is looked up in
// the library's scope each time -- and ~35 through a local name (measured). fieldShape makes a few thousand such calls a
// frame, so it hands the library's functions to its body as parameters OF THE SAME NAMES: every call in the body and in its
// inner functions reads a local. Nothing else differs (the same functions are called). A function the body starts to call
// joins both lists, or it is simply found the slow way.
function fieldShape(src, params, state, dtMs) {
    return fieldShapeWith(src, params, state, dtMs,
        smoothstep, clamp01, lerp, peerWeight, touchWeight, quarterPiece, sJoint, endCorner, facingCaps, wallWeight,
        wallFoot, aLo, aHi, bLo, bHi, capEnd, cornerOf, skyOut, spanGap, ordered, aExtent, solidSpan, seamThins,
        thicknessAt, overrideRadius, cornerFree, freshClaim, skyKeyOf, voidOwner, hosts, presenceSpan, presence, followU,
        spanOverlap, freeAlong, limitRadius, limitVoid, shapeCorner, solidDepth, flareSolid, joinedAt, isPeer, tiles);
}
function fieldShapeWith(src, params, state, dtMs,
    smoothstep, clamp01, lerp, peerWeight, touchWeight, quarterPiece, sJoint, endCorner, facingCaps, wallWeight,
    wallFoot, aLo, aHi, bLo, bHi, capEnd, cornerOf, skyOut, spanGap, ordered, aExtent, solidSpan, seamThins,
    thicknessAt, overrideRadius, cornerFree, freshClaim, skyKeyOf, voidOwner, hosts, presenceSpan, presence, followU,
    spanOverlap, freeAlong, limitRadius, limitVoid, shapeCorner, solidDepth, flareSolid, joinedAt, isPeer, tiles) {
    const R = Math.max(0, params.blendRadius);
    const attachD = Math.max(0, params.attachDistance);
    const snapD = Math.max(attachD + EPS, params.snapDistance);
    const stickiness = clamp01(params.stickiness === undefined ? 0 : params.stickiness);
    const stretchMax = Math.max(0, params.stretchMax || 0);
    const sideStretch = Math.max(0, params.sideStretch === undefined ? 1 : params.sideStretch);
    const settleMs = Math.max(0, params.settleMs || 0);
    const flushSnap = Math.max(0, params.flushSnap === undefined ? 3 : params.flushSnap);
    // THE POCKET (header): the gap within which a capped channel zips shut; 0: never.
    const pocketReach = Math.max(0, params.pocketReach === undefined ? 2 * R : params.pocketReach);
    const prev = state || {};
    const prevRel = prev.rel || {};
    const prevVoid = prev.void || {};
    const dt = Math.max(0, dtMs || 0);

    // Bodies, ordered and clamped. Every corner starts as a plain rounded
    // corner (ellipse semi-axes = inset = the free radii).
    const bodies = [];
    // THE SKY (header): one virtual body per distinct `skyBox`, after every real body (so their indices are what they were).
    // THE BORDER'S END (header, `skyOutset`): a bar with a sky and the sky's inner face both move OUT by the border's width.
    const outset = Math.max(0, params.skyOutset || 0);
    const mapped = src.map(s => (outset > 0 && s && s.skyBox ? skyOut(s, outset) : s));
    const items = mapped.slice();
    const skyMade = {};
    for (let m = 0; m < mapped.length; m++) {
        const s = mapped[m];
        if (!s || !s.skyBox)
            continue;
        const k = skyKeyOf(s.skyBox);
        if (skyMade[k])
            continue;
        skyMade[k] = true;
        items.push({ id: "sky:" + k, x0: s.skyBox.x0, y0: s.skyBox.y0, x1: s.skyBox.x1, y1: s.skyBox.y1, r: 0, mobile: false,
                     square: [true, true, true, true], isSky: true });
    }
    for (let i = 0; i < items.length; i++) {
        const s = items[i];
        const x0 = Math.min(s.x0, s.x1), x1 = Math.max(s.x0, s.x1);
        const y0 = Math.min(s.y0, s.y1), y1 = Math.max(s.y0, s.y1);
        const w = x1 - x0, h = y1 - y0;
        const r0x = Math.max(0, s.rx !== undefined ? s.rx : (s.r || 0));
        const r0y = Math.max(0, s.ry !== undefined ? s.ry : (s.r || 0));
        const rx = Math.min(r0x, w / 2), ry = Math.min(r0y, h / 2);
        // Per corner: square ones none; a free one beside a square one along
        // a side may take the whole of that side (TL's neighbours: TR along
        // the top, BL down the left).
        const sq = s.square || [false, false, false, false];
        // THE RADIUS OVERRIDE (header, `radii`): each corner its own radii, a
        // corner of none square for the rule above.
        const ov = Array.isArray(s.radii) && s.radii.length === 4 ? s.radii : null;
        const cRx = ov ? [overrideRadius(ov, 0, 0), overrideRadius(ov, 1, 0), overrideRadius(ov, 2, 0), overrideRadius(ov, 3, 0)] : null;
        const cRy = ov ? [overrideRadius(ov, 0, 1), overrideRadius(ov, 1, 1), overrideRadius(ov, 2, 1), overrideRadius(ov, 3, 1)] : null;
        const flat = ov ? [sq[0] || (cRx[0] < TINY && cRy[0] < TINY), sq[1] || (cRx[1] < TINY && cRy[1] < TINY),
                           sq[2] || (cRx[2] < TINY && cRy[2] < TINY), sq[3] || (cRx[3] < TINY && cRy[3] < TINY)] : sq;
        const fRx = [cornerFree(sq, 0, ov, cRx, r0x, flat, ALONG_X, w), cornerFree(sq, 1, ov, cRx, r0x, flat, ALONG_X, w),
                     cornerFree(sq, 2, ov, cRx, r0x, flat, ALONG_X, w), cornerFree(sq, 3, ov, cRx, r0x, flat, ALONG_X, w)];
        const fRy = [cornerFree(sq, 0, ov, cRy, r0y, flat, ALONG_Y, h), cornerFree(sq, 1, ov, cRy, r0y, flat, ALONG_Y, h),
                     cornerFree(sq, 2, ov, cRy, r0y, flat, ALONG_Y, h), cornerFree(sq, 3, ov, cRy, r0y, flat, ALONG_Y, h)];
        const orx = ov ? Math.max(...cRx) : r0x, ory = ov ? Math.max(...cRy) : r0y;
        bodies.push({
            id: s.id !== undefined ? String(s.id) : ("b" + i),
            r0x: orx, r0y: ory,
            box: { x0: x0, y0: y0, x1: x1, y1: y1 },
            drawn: { x0: x0, y0: y0, x1: x1, y1: y1 },
            freeRx: ov ? Math.min(orx, w / 2) : rx, freeRy: ov ? Math.min(ory, h / 2) : ry,
            // An overridden body's corners are their own (freeAlong).
            perCorner: !!ov,
            // Each corner's own free radii (the square rule, above).
            fRx: fRx, fRy: fRy,
            // A corner another bar covers (BARS IN A CORNER), or one on the
            // screen's edge: not free, square.
            covered: sq.slice(),
            ex: [fRx[0], fRx[1], fRx[2], fRx[3]], ey: [fRy[0], fRy[1], fRy[2], fRy[3]],
            ix: [fRx[0], fRx[1], fRx[2], fRx[3]], iy: [fRy[0], fRy[1], fRy[2], fRy[3]],
            // What every join CLAIMS of each corner, resolved once at the end
            // (CLAIMS): the tightest S's piece wins WHOLE, sharpness is the largest
            // claim, and plain radius limits (void flares) cap the result. A
            // tight S-curve piece has semi-axes LARGER than the free radius and
            // reaches less only because its centre lies further in, so combining
            // claims number by number threw the arc away and left its partner
            // fillet meeting nothing -- the join looked detached.
            claims: [freshClaim(), freshClaim(), freshClaim(), freshClaim()],
            mobile: s.mobile !== false,
            stick: s.stick || null,
            parent: s.parent ? String(s.parent) : "",
            // One id (the lane's popups name "lane") or a list (the OSD melts with
            // every neighbour it touches, THE OSD SLOT): `peer` is the one, `peers` the list.
            peer: s.peer && !Array.isArray(s.peer) ? String(s.peer) : "",
            peers: Array.isArray(s.peer) ? s.peer.map(String) : [],
            host: s.host ? String(s.host) : "",
            wallJoin: s.wallJoin ? String(s.wallJoin) : "",
            // THE ATTRACTION LETS GO AT REST (the void, 2b): 1 attracted, 0 let go; the engine's clock.
            attract: s.attract === undefined ? 1 : clamp01(s.attract),
            free: s.free === true,
            // How far this body's joins are in, 0 .. 1 (1 unless it says otherwise): a body that stops being free comes to its bar by this, not in one frame (THE WAY HOME, GooeyEngine).
            join: s.join === undefined ? 1 : clamp01(s.join),
            sky: s.isSky === true,
            skyKey: s.isSky === true ? String(s.id).slice(4) : (s.skyBox ? skyKeyOf(s.skyBox) : "")
        });
    }

    // ---- 0. Bars that overlap touch instead -------------------------------------
    // (BARS IN A CORNER, header.) The overlap is given to one of the two: the
    // bar whose whole END it is is drawn short of it, so the pair TOUCHES and
    // the touch relation draws the inner corner. Preferring the bar that runs
    // along y gives the square to the top or bottom bar, which is how a side
    // bar leaves it when it is laid out to start at the thickness.
    for (let i = 0; i < bodies.length; i++) {
        for (let j = 0; j < bodies.length; j++) {
            const A = bodies[i], B = bodies[j];
            if (i === j || A.mobile || B.mobile || A.free || B.free)
                continue;
            const ix0 = Math.max(A.box.x0, B.box.x0), iy0 = Math.max(A.box.y0, B.box.y0);
            const ix1 = Math.min(A.box.x1, B.box.x1), iy1 = Math.min(A.box.y1, B.box.y1);
            if (ix1 - ix0 <= CAP_EPS || iy1 - iy0 <= CAP_EPS)
                continue;
            const I = { x0: ix0, y0: iy0, x1: ix1, y1: iy1 };
            let cap = null;
            for (let ai = 0; ai < 2; ai++) {
                const axis = ai === 0 ? "y" : "x";
                for (let xi = 0; xi < 2; xi++) {
                    const X = xi === 0 ? B : A;
                    const end = capEnd(X.box, I, axis);
                    if (end !== 0 && !cap)
                        cap = { X: X, axis: axis, end: end };
                }
            }
            if (!cap)
                continue;
            const X = cap.X, k = cap.axis + (cap.end < 0 ? "0" : "1");
            const v = cap.end < 0 ? aHi(I, cap.axis) : aLo(I, cap.axis);
            X.box[k] = v;
            X.drawn[k] = v;
            X.freeRx = Math.min(X.r0x, (X.box.x1 - X.box.x0) / 2);
            X.freeRy = Math.min(X.r0y, (X.box.y1 - X.box.y0) / 2);
        }
    }
    // A bar whose end lies on another bar's face has no free corners there:
    // whatever the rules below do with a corner that is still rounding in (a
    // guest's end drawn short of it, a join hanging off its tangent), there is
    // no air to do it over.
    for (let xi = 0; xi < bodies.length; xi++) {
        const X = bodies[xi], xb = X.box;
        if (X.mobile || X.free)
            continue;
        for (let yi = 0; yi < bodies.length; yi++) {
            const Y = bodies[yi], yb = Y.box;
            if (X === Y || Y.mobile || Y.free)
                continue;
            for (let ai = 0; ai < 2; ai++) {
                const along = ai === 0;     // axis "y": b is x, a is y; "x": the other way round
                if ((along ? yb.x0 : yb.y0) > (along ? xb.x0 : xb.y0) + CAP_EPS || (along ? yb.x1 : yb.y1) < (along ? xb.x1 : xb.y1) - CAP_EPS)
                    continue;
                const axis = along ? "y" : "x";
                if (Math.abs((along ? xb.y0 : xb.x0) - (along ? yb.y1 : yb.x1)) <= CAP_EPS)
                    X.covered[cornerOf(axis, -1, -1)] = X.covered[cornerOf(axis, 1, -1)] = true;
                if (Math.abs((along ? xb.y1 : xb.x1) - (along ? yb.y0 : yb.x0)) <= CAP_EPS)
                    X.covered[cornerOf(axis, -1, 1)] = X.covered[cornerOf(axis, 1, 1)] = true;
            }
        }
    }

    // Weight settling: rise at once, fall by dt / settleMs.
    const nextRel = {}, nextVoid = {};
    let settling = false;
    function settledWeight(prevMap, key, target) {
        if (settleMs > 0 && prevMap[key] !== undefined && prevMap[key] > target)
            return Math.max(target, prevMap[key] - dt / settleMs);
        return target;
    }
    function settle(map, prevMap, key, target) {
        const w = settledWeight(prevMap, key, target);
        if (w > target + 1e-3)
            settling = true;
        if (w > 1e-4)
            map[key] = w;
        return w;
    }

    function attachWeight(g) {
        if (g <= attachD)
            return 1;
        return 1 - smoothstep(attachD, snapD, g);
    }



    // The length over which a body's joins come in (PRESENCE, BAR_PRESENCE for a bar).
    // THE CROSS-ISLAND SECONDARY (header). The bar a popup chain HANGS FROM: its root's `host`.
    function rootHost(body) {
        let b = body;
        for (let n = 0; b && b.parent && n < 8; n++) {
            let up = undefined;
            for (let q = 0; q < bodies.length; q++)
                if (bodies[q].id === b.parent) {
                    up = bodies[q];
                    break;
                }
            b = up;
        }
        return b ? b.host : "";
    }
    // A child that meets a bar its chain does not hang from -- the clock's wiki card reaching under the next island -- is attached to
    // that bar as a primary is: pulled to its face and joined to it by the same weights, so it (dis)connects through the whole motion.
    function crossBar(H, Gb) {
        return !!Gb.parent && !H.mobile && !H.sky && !H.free && rootHost(Gb) !== "" && rootHost(Gb) !== H.id;
    }

    // ---- 1. Snapping, on the real boxes -------------------------------------
    // Every move of one face keeps the largest pull on it.
    const moves = [];
    for (let i = 0; i < bodies.length; i++)
        moves.push({ x0: 0, y0: 0, x1: 0, y1: 0 });
    // Every end drawn flush with a host's end, so the host's corner there can be
    // held to the room it left; and how far short of its end each shaped corner
    // leaves its face on the shared line (a piece's reach along b).
    const endCuts = [];
    const shortOf = {};
    function noteShort(body, corner, v) {
        const k = body.id + "|" + corner;
        if (shortOf[k] === undefined || v < shortOf[k])
            shortOf[k] = v;
    }
    // Every guest end pulled onto a host's end: the one corner the two make there
    // (endCorner) and how far it is pulled (k), applied over what the joins at
    // that end resolve to.
    const cEnds = [];
    function pullFace(m, k, v, face) {
        if (Math.abs(v) > Math.abs(m[k])) {
            m[k] = v;
            m[k + "F"] = face;
        }
    }
    for (let i = 0; i < bodies.length; i++) {
        for (let j = 0; j < bodies.length; j++) {
            const H = bodies[i], Gb = bodies[j];
            if (i === j || H.mobile || H.sky || !Gb.mobile || (Gb.parent && !crossBar(H, Gb)) || H.free || Gb.free)
                continue;
            for (let ai = 0; ai < 2; ai++) {
                const axis = ai === 0 ? "y" : "x";
                for (let ni = 0; ni < 2; ni++) {
                    const n = ni === 0 ? 1 : -1;
                    // n +1: the guest lies beyond the host's high face; -1: before its low face.
                    if (n > 0 ? !ordered(H.box, Gb.box, axis) : !ordered(Gb.box, H.box, axis))
                        continue;
                    const g = n > 0 ? aLo(Gb.box, axis) - aHi(H.box, axis) : aLo(H.box, axis) - aHi(Gb.box, axis);
                    if (g > snapD || g <= -1)
                        continue;
                    const ov = Math.min(bHi(H.box, axis), bHi(Gb.box, axis)) - Math.max(bLo(H.box, axis), bLo(Gb.box, axis));
                    if (ov <= 0)
                        continue;
                    const pull = attachWeight(Math.max(0, g)) * smoothstep(0, Math.max(attachD, EPS), ov) * Gb.join;
                    if (g > 0)
                        pullFace(moves[j], axis === "y" ? (n > 0 ? "y0" : "y1") : (n > 0 ? "x0" : "x1"), -n * g * pull,
                                 n > 0 ? aHi(H.box, axis) : aLo(H.box, axis));
                    // Only the ends of the bar the guest hangs from (`host`, SNAPPING).
                    if (flushSnap > 0 && !Gb.parent && (!Gb.host || Gb.host === H.id)) {
                        // Flush with the host's end -- with its SOLID end. The
                        // host's corner comes in over the guest's PRESENCE, so for
                        // the first pixels of a popup it is still rounded, and a
                        // guest drawn out to the host's own end hangs over the air
                        // that corner leaves. An end that is not pulled onto the
                        // host's end but lands on its corner is taken back to the
                        // corner's tangent, which unwraps as the corner squares.
                        const rkey = (n > 0 ? H.id + "|" + Gb.id : Gb.id + "|" + H.id) + "|" + axis;
                        const wEnd = clamp01(settledWeight(prevRel, rkey, attachWeight(Math.max(0, g)) * presence(Gb)));
                        const gSpan = bHi(Gb.box, axis) - bLo(Gb.box, axis);
                        // ...and only where the guest is AGAINST this host's face:
                        // one letting go of it, or held against another bar a span
                        // away (a popup passing 30 px off the left bar's side
                        // while it hangs from the top one), rests on nothing of
                        // this host's and keeps its own ends.
                        const rest = 1 - smoothstep(0, 1.5, Math.max(0, g * (1 - pull)));
                        const aSideH = n > 0 ? 1 : -1;
                        const hG = aExtent(Gb.box, axis) + Math.max(0, g) * pull;
                        for (let dir = -1; dir <= 1; dir += 2) {
                            // A corner another bar covers (BARS IN A CORNER) is square
                            // and leaves no air: no end is drawn back from it.
                            const corner = cornerOf(axis, dir, aSideH);
                            const cut = Math.min(freeAlong(H, axis, "b", corner) * (1 - wEnd), 0.4 * gSpan) * pull * rest;
                            const hEnd = dir > 0 ? bHi(H.box, axis) : bLo(H.box, axis);
                            const gEnd = dir > 0 ? bHi(Gb.box, axis) : bLo(Gb.box, axis);
                            const k = pull * (1 - smoothstep(flushSnap, 2 * flushSnap, Math.abs(hEnd - gEnd)));
                            // Pulled onto the host's end, the two make ONE corner
                            // (endCorner) and the guest's end is drawn where it
                            // crosses the shared line -- unless another bar covers
                            // that corner, and the end is simply flush.
                            const kC = H.covered[corner] ? 0 : k * rest;
                            const ec = kC > 1e-4 ? endCorner(wEnd, hG, freeAlong(H, axis, "b", corner), freeAlong(H, axis, "a", corner),
                                                             freeAlong(Gb, axis, "b"), freeAlong(Gb, axis, "a"), gSpan, R) : null;
                            const reach = ec ? ec.dm * pull * rest : 0;
                            let move = (hEnd - gEnd - dir * reach) * k;
                            // Wherever an end lands short of that pull -- simply near
                            // the host's end -- one that would sit ON the corner is
                            // taken back to the corner's tangent: there is nothing
                            // under it there until the corner has squared.
                            const room = dir * (hEnd - (gEnd + move));
                            if (room >= 0 && room < cut)
                                move -= dir * (cut - room) * (1 - kC);
                            if (ec)
                                cEnds.push({ H: H, G: Gb, axis: axis, dir: dir, aSideH: aSideH, ec: ec, h: hG, k: kC, rkey: rkey });
                            pullFace(moves[j], axis === "y" ? (dir > 0 ? "x1" : "x0") : (dir > 0 ? "y1" : "y0"), move,
                                     hEnd - dir * lerp(cut, reach, kC));
                            if (dir * (hEnd - (gEnd + move)) >= -1e-6)
                                endCuts.push({ i: i, j: j, dir: dir, axis: axis, w: pull * rest, corner: corner });
                        }
                    }
                }
            }
        }
    }
    for (let i = 0; i < bodies.length; i++) {
        const d = bodies[i].drawn, m = moves[i];
        d.x0 += m.x0;
        d.y0 += m.y0;
        d.x1 += m.x1;
        d.y1 += m.y1;
    }

    // ---- 1b. Children follow the side they hang from --------------------------------
    // A popup whose face is drawn stretched toward a bar takes its child's ends
    // with it, or the child's join with it breaks apart. The map has to be
    // MONOTONE -- a drawn end may never move backwards while the real one moves
    // forwards -- so an end inside the parent by less than the stretch takes the
    // whole move and lets go over twice it, and an end already hanging past the
    // parent's side has its hang SCALED into the gap the stretch leaves, never
    // flipped. An end clamped at the bar stays where it is (followU).
    for (let j = 0; j < bodies.length; j++) {
        const C = bodies[j];
        if (!C.parent || C.free)
            continue;
        let pi = -1;
        for (let q = 0; q < bodies.length; q++)
            if (bodies[q].id === C.parent) {
                pi = q;
                break;
            }
        if (pi < 0 || bodies[pi].free)
            continue;
        const P = bodies[pi], pm = moves[pi];
        // The side they share: the axis their spans overlap LEAST on is the one
        // they meet across, so the ends that follow are on the other.
        const aAxis = spanOverlap(C.box, P.box, "y") <= spanOverlap(C.box, P.box, "x") ? "y" : "x";
        const lo = aAxis === "y" ? "x0" : "y0", hi = aAxis === "y" ? "x1" : "y1";
        if (pm[lo])
            C.drawn[lo] = P.box[lo] + followU(C.box[lo] - P.box[lo], pm[lo],
                                              (pm[lo + "F"] === undefined ? P.box[lo] : pm[lo + "F"]) - P.box[lo]);
        if (pm[hi])
            C.drawn[hi] = P.box[hi] - followU(P.box[hi] - C.box[hi], -pm[hi],
                                              P.box[hi] - (pm[hi + "F"] === undefined ? P.box[hi] : pm[hi + "F"]));
    }

    // ---- 2. Relations and joins, on the drawn boxes -----------------------------
    const fillets = [];
    const seams = [];
    const seamReqs = [];
    const joins = [];

    // A fillet in (b, a) coordinates: vertex, rect extents (signed), ellipse
    // centre and semi-axes, bleeds toward the faces it joins.
    function pushFillet(axis, vb, va, rb, ra, cb, ca, eb, ea, bleedB, bleedA, key) {
        if (Math.abs(rb) < 0.05 || Math.abs(ra) < 0.05)
            return;
        if (axis === "y")
            fillets.push({ vx: vb, vy: va, ex: rb, ey: ra, kx: cb, ky: ca, krx: eb, kry: ea,
                           bx: bleedB, by: bleedA, key: key });
        else
            fillets.push({ vx: va, vy: vb, ex: ra, ey: rb, kx: ca, ky: cb, krx: ea, kry: eb,
                           bx: bleedA, by: bleedB, key: key });
    }
    // A fillet from a piece hanging off vertex (vb, va), reaching `dirB` along b
    // and `dirA` along a, scaled by `k` about the vertex.
    function pieceFillet(axis, vb, va, dirB, dirA, piece, k, bleedB, bleedA, key) {
        if (!piece || k <= 1e-4)
            return;
        pushFillet(axis, vb, va,
                   dirB * piece.off * k, dirA * piece.ia * k,
                   vb + dirB * piece.ib * k, va + dirA * piece.ia * k,
                   piece.eb * k, piece.ea * k, bleedB, bleedA, key);
    }
    // Place the joint's fillet, and give the inner body's far corner the partner
    // piece the same solve produced.
    function sideFillet(axis, vb, va, dirB, dirA, joint, body, farCorner, w, bleedB, bleedA, reachB, key) {
        if (!joint || !joint.fillet || w <= 1e-4)
            return;
        const f = joint.fillet;
        // It runs along the OTHER body's face: it stops where that face stops
        // being solid (a corner of its own still rounded there).
        pushFillet(axis, vb, va, dirB * Math.min(f.rb * w, Math.max(0, reachB)), dirA * f.ra * w,
                   vb + dirB * f.cb * w, va + dirA * f.ca * w, f.eb * w, f.ea * w, bleedB, bleedA, key);
        if (joint.far)
            shapeCorner(body, farCorner, axis, joint.far, w);
    }
    // Is the channel between U and D (the gap a0..a1 across the line, along
    // `axis`) closed at its end `bEnd` (side -1: its low end, +1: its high end)
    // by a third body: one whose drawn box spans the gap across and reaches
    // that end from beyond it -- the top bar over the slot between a popup and
    // the side bar under it.
    function channelCapped(U, D, axis, bEnd, side, a0, a1) {
        const lo = Math.min(a0, a1), hi = Math.max(a0, a1);
        for (const X of bodies) {
            if (X === U || X === D || X.free)
                continue;
            const x = X.drawn;
            if (!(x.x1 - x.x0 > EPS && x.y1 - x.y0 > EPS))
                continue;
            if (aLo(x, axis) > lo + EPS || aHi(x, axis) < hi - EPS)
                continue;
            if (side < 0 ? (bLo(x, axis) < bEnd - EPS && bHi(x, axis) >= bEnd - EPS)
                         : (bHi(x, axis) > bEnd + EPS && bLo(x, axis) <= bEnd + EPS))
                return true;
        }
        return false;
    }
    // `key` names the two bodies it lies between, "<upper id>|<lower id>", as a fillet's key starts (for a reader that sorts the
    // shape by body: ReelCast).
    function pushSeam(axis, b0, b1, a0, a1, key) {
        if (b1 - b0 < 0.05 || a1 - a0 < 0.05)
            return;
        if (axis === "y")
            seams.push({ x0: b0, y0: a0, x1: b1, y1: a1, key: key });
        else
            seams.push({ x0: a0, y0: b0, x1: a1, y1: b1, key: key });
    }

    for (let i = 0; i < bodies.length; i++) {
        for (let j = 0; j < bodies.length; j++) {
            if (i === j || !hosts(bodies[i], bodies[j]))
                continue;
            const H = bodies[i], Gb = bodies[j];
            // PEERS: side by side, no host and no guest (header).
            const peer = (!!Gb.peer && Gb.peer === H.id) || (Gb.peers.length > 0 && Gb.peers.indexOf(H.id) >= 0);
            const touchOnly = !peer && !H.mobile && (!Gb.mobile || (!!Gb.parent && !crossBar(H, Gb)));
            // Two immobile bodies are related once (the lower index hosts) -- the sky, last of all, hosts its bars.
            if (!H.mobile && !Gb.mobile && i > j && !H.sky)
                continue;
            const pG = presence(Gb);
            const snapped = !H.mobile && Gb.mobile && (!Gb.parent || crossBar(H, Gb));
            for (let ai = 0; ai < 2; ai++) {
                const axis = ai === 0 ? "y" : "x";
                for (let ni = 0; ni < 2; ni++) {
                    const n = ni === 0 ? 1 : -1;
                    const U = n > 0 ? H : Gb, D = n > 0 ? Gb : H;
                    const Ub = U.drawn, Db = D.drawn;
                    if (!ordered(Ub, Db, axis))
                        continue;
                    const key = U.id + "|" + D.id + "|" + axis;
                    const L = aHi(Ub, axis);
                    const g = aLo(Db, axis) - L;
                    const u0 = bLo(Ub, axis), u1 = bHi(Ub, axis);
                    const d0 = bLo(Db, axis), d1 = bHi(Db, axis);
                    const gA = spanGap(u0, u1, d0, d1);

                    // The weight of the relation, from the REAL gap when a face was
                    // snapped (a snapped face is attached), else from what is drawn.
                    const realG = aLo(D.box, axis) - aHi(U.box, axis);
                    let target = 0;
                    if (peer)
                        target = gA <= 0 ? peerWeight(g) : 0;
                    else if (touchOnly)
                        // A child follows its parent's drawn ends (step 1b), and the parent's end is drawn past a bar's face by the
                        // corner it makes with it (endCorner's `dm`: 1.7 px at a frame scale of 1.25, where the 6 px slim bar is 4.8
                        // frame px): the child's own gap to that bar is then -1.7 on the DRAWN boxes while the boxes it asked for
                        // touch it, and a test on the drawn gap alone left the toasts nudged under silicon with no join to the slim bar.
                        //
                        // THE TOUCH IS A RANGE, NOT A POINT (the weather's detail at `end` would otherwise snap in
                        // place). A touch of `|gap| <= 0.5` alone would relate a child that rose to a bar's face and went through it on its OutBack (7 px) to
                        // the bar for the one frame it crossed the line, let go (160 ms settle) while it stood inside the bar, and relate it AGAIN
                        // at full weight the frame it came back to 0.5 px -- the bar's end corner squared and the S beside it re-solved in one frame
                        // (4.7 -> 9.5 px of reach), where the void under the island's end turned from a pointed hook into a round end. It is related
                        // from a short way off (TOUCH_REACH, in with the gap) and for as long as it stands INSIDE the bar's face (`ordered` ends
                        // it when it no longer reaches past the bar): the snapped relations above already hold a penetration at full weight.
                        //
                        // AND IT COMES IN WITH WHAT THE TWO SHARE (or the same detail clicks mechanically): a child that rises
                        // INTO a bar on its OutBack (7 px past the island's face) also lies BESIDE the bar's end, across it, by as much as
                        // it has gone in -- a second relation along the other axis whose fillet (the island's end side into the child's top,
                        // 20 px where the first one's is 17) would be drawn whole the frame the child crossed the face. A child's touch is
                        // weighted by how far the two overlap along it, over PRESENCE px.
                        target = gA <= 0 ? Math.max(touchWeight(g), Gb.parent ? touchWeight(realG) : 0)
                                           * (Gb.mobile ? smoothstep(0, PRESENCE, Math.min(u1, d1) - Math.max(u0, d0)) : 1) : 0;
                    else if (g <= snapD && gA <= snapD)
                        target = (snapped ? attachWeight(Math.max(0, realG)) : (1 - smoothstep(0, attachD, Math.max(0, g)))) * Gb.join;
                    if (target <= 0 && (peer || prevRel[key] === undefined))
                        continue;
                    // Peers: one weight for both, the contact weight times the
                    // presence of the smaller of the two, never settling.
                    const wP = peer ? target * Math.min(presence(H), pG) : 0;
                    const wH = peer ? wP : settle(nextRel, prevRel, key, target * pG);
                    // The guest's own pieces follow its box at once, but they still
                    // come in with how much guest there is ALONG this bar: a popup
                    // whose height has gone to nothing keeps no flare on a side bar.
                    const wG = peer ? wP : target * smoothstep(0, presenceSpan(Gb), bHi(Gb.box, axis) - bLo(Gb.box, axis));
                    // THE WALL JOIN: a popup resting flush against a bar across its edge
                    // joins it from its first sliver -- the fillet at its foot is the bars'
                    // corner and has no presence to wait for -- so the relation is not
                    // skipped for want of one (a 0.02 px popup drew none: the corner came
                    // in at 0.05 px of height, a shift of that much).
                    const wallW = snapped ? wallWeight(H, Gb, axis, n, 2 * snapD) * Gb.join : 0;
                    if (wH <= 1e-4 && wG <= 1e-4 && !(wallW > 0 && target > 0))
                        continue;
                    // Joins -- fillets AND the corners they replace -- only near
                    // contact. A face still being pulled toward a bar (a residual
                    // gap) keeps its own rounded corners; squaring them there drew a
                    // wedge of wallpaper with a sharp end between popup and bar. A
                    // peer's weight is its contact already.
                    const contact = peer ? 1 : 1 - smoothstep(0, CONTACT, Math.max(0, g));
                    const wfH = wH * contact, wfG = wG * contact;
                    const touch = 1 - smoothstep(0, 0.25, Math.max(0, g));
                    // ...and the end of that relation that is its foot.
                    const wallDir = wallW > 0 ? wallFoot(Gb.wallJoin, axis) : 0;

                    if (gA <= 0 && d0 < u1 && d1 > u0) {
                        // Overlapping spans: an S at each end.
                        for (let di = 0; di < 2; di++) {
                            const dir = di === 0 ? 1 : -1;
                            const uEnd = dir > 0 ? u1 : u0;
                            const dEnd = dir > 0 ? d1 : d0;
                            const delta = dir * (dEnd - uEnd);
                            const innerIsD = delta <= 0;
                            const I = innerIsD ? D : U, O = innerIsD ? U : D;
                            const iEnd = innerIsD ? dEnd : uEnd;
                            const dirA = innerIsD ? 1 : -1;
                            // The fillet hangs off the inner body's own face, or
                            // where the other body's face enters it (an inset child).
                            const va = innerIsD ? Math.max(L, aLo(Db, axis)) : Math.min(L, aLo(Db, axis));
                            const side = innerIsD ? aHi(Db, axis) - va : va - aLo(Ub, axis);
                            // An end pulled onto the host's end is the end corner's
                            // (cEnds). While that corner still reaches past the line
                            // (dm) the S there gives way to it; once it does not, the S
                            // IS that end, and the guest's far corner in it is the end
                            // corner's, so the two are the same shape where they meet.
                            let ce = null;
                            if (snapped) {
                                ce = undefined;
                                for (let q = 0; q < cEnds.length; q++) {
                                    const c = cEnds[q];
                                    if (c.H === H && c.G === Gb && c.axis === axis && c.dir === dir) {
                                        ce = c;
                                        break;
                                    }
                                }
                            }
                            // The inner body's FAR corner at this end -- the partner
                            // of the S down its side -- by its own radii: a bar's
                            // corner on the screen's edge (or under another bar) is
                            // square and stays so. Its body's free radius instead
                            // gave a side bar's end, where a popup against it hangs
                            // past it, a round 20 px notch on the screen's edge.
                            const farC = cornerOf(axis, dir, dirA);
                            let raI = freeAlong(I, axis, "a", farC), rbI = freeAlong(I, axis, "b", farC);
                            if (ce && I === Gb) {
                                raI = lerp(raI, Math.min(ce.ec.Ra, ce.h), ce.k);
                                rbI = lerp(rbI, ce.ec.Rb, ce.k);
                            }
                            let st = 0;
                            if (!touchOnly && !peer && I === Gb && I.stick) {
                                // How far out the guest is ALONG THIS BAR, not overall:
                                // a popup on a side bar that is closing has its height
                                // going to zero, and a join on that bar must go with it.
                                const stickEnd = dir > 0 ? bHi(I.stick, axis) : bLo(I.stick, axis);
                                const openLen = bHi(I.stick, axis) - bLo(I.stick, axis);
                                const out = openLen > EPS ? clamp01((bHi(I.box, axis) - bLo(I.box, axis)) / openLen) : 0;
                                st = Math.min(stretchMax, out * stickiness * Math.max(0, dir * (stickEnd - iEnd)));
                            }
                            // THE WALL JOIN. The popup's FOOT meeting the bar it rests
                            // flush against is not a join that holds on to the popup:
                            // it is the bars' own corner (blendRadius, circular, in
                            // full from the first sliver of popup) travelling with the
                            // foot -- no resistance (st), none of the popup's own
                            // surface-tension reach along the foot (fillA), no
                            // presence ramp (wI): at no height the foot is the corner
                            // of the two bars, and the corner is the bars' own the
                            // whole way down and back.
                            const wall = wallW > 0 && dir === wallDir && I === Gb ? wallW : 0;
                            if (wall > 0)
                                st *= 1 - wall;
                            const fillA = wall > 0 ? lerp(Math.max(R, raI), R, wall) : Math.max(R, raI);
                            const wOfI = I === H ? wfH : wfG, wOfO = O === H ? wfH : wfG;
                            const wI = wall > 0 ? lerp(wOfI, target * contact, wall) : wOfI;
                            // The inner body's corner ON the line is sharp; that
                            // claim is made now, because ANOTHER join may square the
                            // corner this one is about to treat as convex (a popup
                            // touching a side bar, with a child hanging under it).
                            // The joints are solved once every such claim is in. A
                            // peer's squares with the CONTACT alone -- the fillet still
                            // comes in with presence -- or a lane a few pixels tall,
                            // its inflated corner running a hundred pixels along its
                            // foot, left a notch between that corner and the fillet.
                            const wSq = peer ? target : wI;
                            shapeCorner(I, cornerOf(axis, dir, innerIsD ? -1 : 1), axis, null, wSq, false, key);
                            // How far short of this end the inner body's face
                            // reaches: its corner is squared only as the join comes
                            // in, and until then there is no material out to the end.
                            // A peer's corner there may be square already -- two
                            // popups on one bar are each squared on the bar's face by
                            // their own join with it, made before this one (bars come
                            // first) -- and drawing it short of that end put an S
                            // half-way down thePopup's side while the lane came in.
                            const innerCorner = cornerOf(axis, dir, innerIsD ? -1 : 1);
                            const squared = peer ? Math.max(wSq, I.claims[innerCorner].sharp) : wI;
                            const insI = freeAlong(I, axis, "b", innerCorner) * (1 - squared);
                            noteShort(I, cornerOf(axis, dir, innerIsD ? -1 : 1), insI);
                            // Ends that are flush (and square) leave no S at all: the
                            // outer corner is as sharp as the inner one, and says so
                            // now, before any joint is solved against it. Claimed only
                            // in the joint pass, a join solved EARLIER at the corner's
                            // other end (a top bar with a side bar under each end)
                            // took it for free and its quarter won over the claim --
                            // a scoop of air at the screen edge above the side bar.
                            if (Math.abs(delta) + insI <= 1e-3)
                                shapeCorner(O, cornerOf(axis, dir, innerIsD ? 1 : -1), axis, null, peer ? target : wOfO, false, key);
                            joins.push({
                                axis: axis, dir: dir, delta: Math.abs(delta) + insI, side: side,
                                insI: insI, oEnd: innerIsD ? uEnd : dEnd,
                                I: I, O: O, iEnd: iEnd, va: va, dirA: dirA, st: st, raI: raI, rbI: rbI, fillA: fillA,
                                cornerO: cornerOf(axis, dir, innerIsD ? 1 : -1),
                                cornerFar: farC,
                                // The outer body's corner at this end, along b: the
                                // rounding of what lies behind the fillet's vertex on
                                // the inner body's side (FACING FILLETS).
                                rbO: freeAlong(O, axis, "b", cornerOf(axis, dir, innerIsD ? 1 : -1)),
                                wI: wI, wO: wOfO, ce: ce, kC: ce && ce.ec.dm > EPS ? ce.k : 0,
                                // The room the guest's far corner leaves on its side for
                                // its corner on the line.
                                hOcap: ce && O === Gb ? Math.max(0, ce.h - lerp(freeAlong(Gb, axis, "a"), Math.min(ce.ec.Ra, ce.h), ce.k)) : Infinity,
                                // Back into the inner body no further than it is solid
                                // behind the vertex: its extent along b less the end still
                                // rounding in and the corner at its other end on the line.
                                // A popup two pixels tall in the corner of two bars bled
                                // through its own foot there, a spur under the popup.
                                bleedB: Math.min(BLEED, Math.max(0, bHi(I.drawn, axis) - bLo(I.drawn, axis) - insI
                                                                 - freeAlong(I, axis, "b", cornerOf(axis, -dir, innerIsD ? -1 : 1)))),
                                bleedA: g < 0 ? BLEED : BLEED * touch * Math.min(1, solidDepth(O, axis) / BLEED),
                                key: key + (innerIsD ? "|in" : "|over") + dir
                            });
                        }
                        // A seam where the two faces lie on one line (a penetrating,
                        // inset child overlaps its parent in area), withdrawing from
                        // the ends as they part. Its ends are placed once every
                        // corner is resolved (seamReqs). Between peers only once they
                        // touch: nothing pulls a peer's face to the line, so a seam
                        // over a gap would be a bridge the eye can see.
                        // (Not over the sky's contact line: the sky is never drawn, so no row there is half covered.)
                        if (g >= -0.5 && g <= (peer ? PEER_SEAM : NECK) && !U.sky && !D.sky) {
                            const b0 = Math.max(u0, d0), b1 = Math.min(u1, d1);
                            const n0 = 0.5 * (b1 - b0) * (peer ? smoothstep(0, PEER_SEAM, Math.max(0, g))
                                                               : smoothstep(0.25, NECK, Math.max(0, g)));
                            // A neck whose channel is CAPPED at one end zips from
                            // that end (SEAMS: a capped channel).
                            let s0 = b0 + n0, s1 = b1 - n0;
                            if (!peer && n0 > 0) {
                                const capLo = channelCapped(U, D, axis, b0, -1, L, aLo(Db, axis));
                                const capHi = channelCapped(U, D, axis, b1, 1, L, aLo(Db, axis));
                                if (capLo !== capHi) {
                                    s0 = capLo ? b0 : b0 + 2 * n0;
                                    s1 = capLo ? b1 - 2 * n0 : b1;
                                }
                            }
                            // Between two bars the seam reaches BAR_SEAM into each (SEAMS).
                            const depth = !U.mobile && !D.mobile ? BAR_SEAM : BLEED;
                            seamReqs.push({ axis: axis, U: U, D: D, b0: s0, b1: s1, L: L, Dlo: aLo(Db, axis),
                                            dU: Math.min(depth, aExtent(U.drawn, axis)), dD: Math.min(depth, aExtent(D.drawn, axis)) });
                        }
                    } else if (!touchOnly && !peer && Math.abs(g) <= 0.5 && voidOwner(Ub, axis, g, gA)) {
                        // Not overlapping (including spans that just touch, gA 0):
                        // spans apart along b, flares toward each other, relaxing
                        // into convex corners over snapDistance.
                        //
                        // THE ATTRACTION LETS GO AT REST (gradually, not instantly, once the popup has concluded its motions): the flare belongs to the motion. The weather
                        // popup's corner and the left island's, a full-weight relation up to snapDistance apart, would stay flared for as long as the
                        // popup stood there. `Gb.attract` is the engine's clock, 1 in motion, eased to 0 once a body has landed. Bodies whose
                        // spans really touch are one shape, not an attraction, and keep the join.
                        const letGo = lerp(1, Gb.attract, smoothstep(0, flushSnap, gA));
                        const dir = d0 >= u1 ? 1 : -1;
                        const uEnd = dir > 0 ? u1 : u0;
                        const dEnd = dir > 0 ? d0 : d1;
                        const vkey = key + "|void" + dir;
                        const fade = (1 - smoothstep(0, snapD, gA)) * letGo;
                        const wvS = settle(nextVoid, prevVoid, vkey, fade * pG) * wH;
                        const wvT = fade * wG;
                        const wvU = U === H ? wvS : wvT, wvD = D === H ? wvS : wvT;
                        const cU = cornerOf(axis, dir, 1);
                        const cD = cornerOf(axis, -dir, -1);
                        const rUb = freeAlong(U, axis, "b");
                        const sU = lerp(-rUb, R, wvU);
                        limitVoid(U, cU, axis, "b", Math.max(0, -sU));
                        const eaU = Math.min(R, Math.max(0, L - aLo(Ub, axis) - freeAlong(U, axis, "a")));
                        if (sU > 0)
                            pieceFillet(axis, uEnd, L, dir, -1, quarterPiece(sU, eaU), 1, BLEED, 0, vkey + "|U");
                        const rDb = freeAlong(D, axis, "b");
                        const sD = lerp(-rDb, R, wvD);
                        limitVoid(D, cD, axis, "b", Math.max(0, -sD));
                        const raD = freeAlong(D, axis, "a");
                        const eaD = Math.max(0, Math.min(raD, aExtent(Db, axis) - raD));
                        if (sD > 0)
                            pieceFillet(axis, dEnd, aLo(Db, axis), -dir, 1, quarterPiece(sD, eaD), 1, BLEED, 0, vkey + "|D");
                        // Where both sides are solid on the line, a seam.
                        const depU = solidDepth(U, axis), depD = solidDepth(D, axis);
                        const reachU = flareSolid(sU, eaU, depU), reachD = flareSolid(sD, eaD, depD);
                        const lo = dir > 0 ? Math.max(u0 + rUb, d0 - reachD) : Math.max(d0 + rDb, u0 - reachU);
                        const hi = dir > 0 ? Math.min(u1 + reachU, d1 - rDb) : Math.min(d1 + reachD, u1 - rUb);
                        pushSeam(axis, lo, hi, L - depU, aLo(Db, axis) + depD, key);
                    }
                }
            }
        }
    }

    // ---- 2c (defined; run after the corners resolve) ---------------------------------
    // The body capping the channel between U and D at its end `bEnd` (side -1 its low
    // end, +1 its high end), or null: channelCapped's test, the body itself.
    function channelCap(U, D, axis, bEnd, side, a0, a1) {
        const lo = Math.min(a0, a1), hi = Math.max(a0, a1);
        for (const X of bodies) {
            if (X === U || X === D || X.free)
                continue;
            const x = X.drawn;
            if (!(x.x1 - x.x0 > EPS && x.y1 - x.y0 > EPS))
                continue;
            if (aLo(x, axis) > lo + EPS || aHi(x, axis) < hi - EPS)
                continue;
            if (side < 0 ? (bLo(x, axis) < bEnd - EPS && bHi(x, axis) >= bEnd - EPS)
                         : (bHi(x, axis) > bEnd + EPS && bLo(x, axis) <= bEnd + EPS))
                return X;
        }
        return null;
    }
    // THE POCKET'S CHANNELS (header), found BEFORE the joints are solved (2b), from the drawn boxes and the joins as collected.
    // The corner a front squares at the open end -- E's on the channel, to the room the front leaves it -- is a VOID limit
    // (limitVoid), so every joint that corner is a piece of is SOLVED against it. Squared after the solve (it was, at 2c), a
    // corner that is the outer half of the cap's own S came apart from the fillet it was solved to meet: the weather's detail at
    // `end` rising under the centre island 9.5 px past the popup's end (the island's end corner IS that S, 32 px of ellipse over a
    // 9.5 px channel) drew a 3 px shelf at the front, and was capped from 32 to 9.5 in the one frame the pocket began.
    function pocketChannels() {
        const out = [];
        for (let i = 0; i < bodies.length; i++) {
            for (let j = 0; j < bodies.length; j++) {
                const X = bodies[i], Gb = bodies[j];
                // The guest moves; the face it closes on is a bar's or its host's.
                if (i === j || !Gb.mobile || X.free || Gb.free || isPeer(X, Gb) || !hosts(X, Gb))
                    continue;
                for (let ai = 0; ai < 2; ai++) {
                    const axis = ai === 0 ? "y" : "x";
                    for (let ni = 0; ni < 2; ni++) {
                        const n = ni === 0 ? 1 : -1;
                        const U = n > 0 ? X : Gb, D = n > 0 ? Gb : X;
                        const Ub = U.drawn, Db = D.drawn;
                        if (!ordered(Ub, Db, axis))
                            continue;
                        const L = aHi(Ub, axis), Dl = aLo(Db, axis);
                        const g = Dl - L;
                        // Down to contact itself: the relation's own join comes in over
                        // the last pixels (from TOUCH_REACH for a bar and a child, over CONTACT
                        // otherwise) while its seam is still withdrawing, so a pocket that
                        // stopped there handed over to a slit of air (74 px^2 of it).
                        if (!(g > 1e-3) || g >= pocketReach)
                            continue;
                        const u0 = bLo(Ub, axis), u1 = bHi(Ub, axis), d0 = bLo(Db, axis), d1 = bHi(Db, axis);
                        const b0 = Math.max(u0, d0), b1 = Math.min(u1, d1);
                        if (!(b1 - b0 > 1))
                            continue;
                        const capLo = channelCap(U, D, axis, b0, -1, L, Dl);
                        const capHi = channelCap(U, D, axis, b1, 1, L, Dl);
                        if (!capLo === !capHi)
                            continue;
                        const C = capLo || capHi;
                        if (!joinedAt(C, U) || !joinedAt(C, D))
                            continue;
                        const dir = capLo ? 1 : -1;            // toward the open end
                        const bCap = capLo ? b0 : b1, bOpen = capLo ? b1 : b0;
                        const len = Math.abs(bOpen - bCap);
                        // The body whose face ENDS at the open end, and the one that runs on.
                        const E = dir > 0 ? (u1 <= d1 ? U : D) : (u0 >= d0 ? U : D);
                        const F = E === U ? D : U;
                        // E's corners at the open end: the one on the channel squares to
                        // the room the front leaves it, and both become the contact pose's.
                        const eCh = cornerOf(axis, dir, E === D ? -1 : 1), eFar = cornerOf(axis, dir, E === D ? 1 : -1);
                        // Those corners must be the pocket's family's alone (the face, the
                        // cap): one that is the convex half of ANOTHER join's S -- a child
                        // hanging under a parent that slides into a side bar -- was solved
                        // with that join's fillet, and morphing it alone detached the two
                        // (78 px of a fillet hanging in a cut corner). No pocket there. But a corner is an S's only while the S is
                        // tight: loose, a straight run lies between the two pieces and the corner is free to square -- where the S is a
                        // still body's. That holds at both of an S's corners: the FAR corner down E's side (the sky's flare down an
                        // island's end: the weather's detail under the island), and the OUTER corner along E's face (a slim side bar
                        // under an island's start makes an S whose outer piece is the island's END corner, a whole island away: the
                        // tray's label wider than the island past its strip lost its pocket at the frame its end passed the island's,
                        // and found it again as it settled -- the hole the user saw flicker; tools/dev/tray_pocket_probe.sh). Along E's
                        // face the S reaches at most its fillet's ceiling, R + st (`HB` in the joint pass), plus that corner. One with a
                        // body that moves (a toast stack's join with the popup beside it) stays refused: its pieces are re-solved every
                        // frame and a pocket at its far corner shut 632 px of air in.
                        const family = Y => Y === F || Y === C;
                        const looseFar = J => !J.O.mobile && J.fillA + J.st * sideStretch
                            + Math.max(J.raI, freeAlong(J.I, J.axis, "a", J.cornerFar)) <= J.side + 1e-6;
                        const looseOut = J => !J.I.mobile && R + J.st + freeAlong(J.O, J.axis, "b", J.cornerO) <= J.delta + 1e-6;
                        if (joins.some(J => (J.O === E && (J.cornerO === eCh || J.cornerO === eFar) && !family(J.I) && !looseOut(J))
                                         || (J.I === E && (J.cornerFar === eCh || J.cornerFar === eFar) && !family(J.O) && !looseFar(J))))
                            continue;
                        // How far the zip has run: 0 at pocketReach with no speed (it leaves
                        // the cap gently), 1 at contact -- z = 1 - (a u + (3 - 2a) u^2 + (a - 2) u^3) of the gap's
                        // fraction u, with a = POCKET_ARRIVE its speed as it arrives. (A smoothstep, a = 0, ran the front
                        // 79 % of the way while the gap was still 12 of 40 px and left the corner's morph a few frames at
                        // the very end; a = 1.5, the steepest end there is, closed the last pixels of a 70 px channel and
                        // grew its corner in under a pixel of gap -- the weather detail's "mechanical click". 0.75 halves
                        // that and its steepest stretch, 1.35, is the lowest of the family.)
                        //
                        // E's corner on the channel squares as the room the front leaves it runs out, and never reaches past the
                        // front (its air over the fill drew a ledge): in proportion to the room over the last POCKET_SQUARE corners of
                        // it, so it is whole where the front sets out and square where it arrives. Capped to the room itself, it went
                        // within the last few px of gap -- the weather detail's 70 px channel lost the island's end corner in 5 px of gap,
                        // two frames of the open. A corner LONGER than the channel (the same detail 9.5 px past the popup's end: the
                        // island's end corner is the cap's own S, 32 px of ellipse) first tightens to the channel's length while the
                        // front waits at the cap (POCKET_TIGHTEN of the reach, as much of it as the corner is longer), and the zip runs
                        // on the rest: capped to the channel at once, it went from 32 to 9.5 px in the frame the pocket began.
                        const u = clamp01((g - 0.5) / Math.max(EPS, pocketReach - 0.5));
                        const ceil = freeAlong(E, axis, "b", eCh);
                        const pre = ceil > len ? POCKET_TIGHTEN * clamp01((ceil - len) / Math.max(ceil, EPS)) : 0;
                        const uz = clamp01(u / Math.max(EPS, 1 - pre));
                        const A = POCKET_ARRIVE;
                        const z = 1 - (A * uz + (3 - 2 * A) * uz * uz + (A - 2) * uz * uz * uz);
                        const front = bCap + dir * z * len;
                        const travel = z * len, room = Math.max(0, len - travel);
                        const span = Math.min(len, POCKET_SQUARE * Math.max(ceil, R));
                        limitVoid(E, eCh, axis, "b", ceil > len ? room + (ceil - len) * smoothstep(1 - pre, 1, u)
                                                                : ceil * Math.min(1, room / Math.max(span, EPS)));
                        out.push({ i: i, j: j, axis: axis, n: n, U: U, D: D, L: L, Dl: Dl, g: g, C: C, dir: dir, bCap: bCap, bOpen: bOpen, len: len,
                                   E: E, F: F, eCh: eCh, eFar: eFar, front: front, travel: travel, room: room });
                    }
                }
            }
        }
        return out;
    }
    function pockets(chans, srcList, prm, prevState, dtMs) {
        const flushOf = {};
        for (const ch of chans) {
            const { j, axis, n, U, D, L, Dl, g, C, dir, bCap, bOpen, len, E, F, eCh, eFar, front, travel, room } = ch;
            const Gb = bodies[j];
            const eLine = E === U ? L : Dl, fLine = F === U ? L : Dl;
            const toE = E === U ? -1 : 1;           // across, from F's face toward E's
            // The morph into the contact corner, over the last R of travel -- from
            // where it stands at no travel, so a channel shorter than R (a popup 12 px
            // wide) still leaves the cap as the C there.
            const qOf = r => 1 - smoothstep(0, Math.max(R, EPS), r);
            const q0 = qOf(len);
            const q = q0 < 1 - EPS ? clamp01((qOf(room) - q0) / (1 - q0)) : 1;
            // The C at the cap, as the field draws it: the two fillets whose
            // vertex is the cap's face on each side of the gap, running into the
            // channel. The front is that C, moved along it -- at no travel it IS
            // the C (grown in from nothing instead, the fill's square end cut
            // through the C for the first pixels: a crease).
            const Xb = axis === "y";
            const fb_ = f => Xb ? f.vx : f.vy, fa_ = f => Xb ? f.vy : f.vx;
            const eb_ = f => Xb ? f.ex : f.ey, ea_ = f => Xb ? f.ey : f.ex;
            const capFillet = (line, across) => fillets.find(f => String(f.key).indexOf("pocket|") !== 0
                && Math.abs(fb_(f) - bCap) < 0.5 && Math.abs(fa_(f) - line) < 0.5
                && eb_(f) * dir > 0 && ea_(f) * across > 0) || null;
            const cF = capFillet(fLine, toE), cE = capFillet(eLine, -toE);
            if (!cF && !cE)
                continue;
            // The pose at contact: the guest moved flush, the pocket off.
            const fk = j + "|" + axis + "|" + n;
            if (!flushOf[fk]) {
                const moved = JSON.parse(JSON.stringify(srcList));
                const realG = aLo(D.box, axis) - aHi(U.box, axis);
                const sh = (Gb === D ? -1 : 1) * Math.max(0, realG);
                const s = moved[j];
                if (axis === "y") { s.y0 += sh; s.y1 += sh; } else { s.x0 += sh; s.x1 += sh; }
                if (s.stick) {
                    if (axis === "y") { s.stick.y0 += sh; s.stick.y1 += sh; } else { s.stick.x0 += sh; s.stick.x1 += sh; }
                }
                flushOf[fk] = fieldShape(moved, Object.assign({}, prm, { pocketReach: 0 }),
                                         JSON.parse(JSON.stringify(prevState || {})), dtMs);
            }
            const flush = flushOf[fk];
            const endKey = U.id + "|" + D.id + "|" + axis + (E === D ? "|in" : "|over") + dir;
            const target = flush.fillets.find(f => f.key === endKey) || null;
            const ei = bodies.indexOf(E), fb = flush.bodies[ei];
            const Xa = axis === "y";
            // (E's corner ON the channel is squared by the void limit, solved with every S it is a piece of: lerped here
            // as well, after the solve, it came apart from the cap's own S -- a kink at the front.)
            if (fb) {
                for (const kc of [eFar]) {
                    E.ex[kc] = lerp(E.ex[kc], fb.ex[kc], q);
                    E.ey[kc] = lerp(E.ey[kc], fb.ey[kc], q);
                    E.ix[kc] = lerp(E.ix[kc], fb.ix[kc], q);
                    E.iy[kc] = lerp(E.iy[kc], fb.iy[kc], q);
                }
            }
            // The fill, cap to front, into each body as deep as it is solid -- and into E only where E's face is: under the
            // corner E has on the channel (it may reach past the front) the fill stops on the line, or it drew a ledge of
            // surface over the corner's air.
            const dU = Math.min(BLEED, solidDepth(U, axis)), dD = Math.min(BLEED, solidDepth(D, axis));
            const dE = E === U ? dU : dD, dF = E === U ? dD : dU;
            const fa = Math.min(bCap - dir * BLEED, front), fz = Math.max(bCap - dir * BLEED, front);
            const eSolid = bOpen - dir * (Xb ? E.ix[eCh] : E.iy[eCh]);
            // The two OVERLAP across the channel (the part with E's bleed is the whole depth): two boxes that only met on
            // the line drew it half covered, a hairline down the fill.
            if (travel > 0.05) {
                pushSeam(axis, fa, fz, E === U ? L : L - dF, E === U ? Dl + dF : Dl, endKey);
                const sEnd = dir > 0 ? Math.min(front, eSolid) : Math.max(front, eSolid);
                const sa = Math.min(bCap - dir * BLEED, sEnd), sz = Math.max(bCap - dir * BLEED, sEnd);
                if (sz > sa)
                    pushSeam(axis, sa, sz, L - dU, Dl + dD, endKey);
            }
            // The fillets stay whole down to contact, where the pocket ends: what it hands over to IS the contact join's
            // fillet (the target, from the flush pose), whole by then. (Withdrawn over the last quarter pixel of gap, they
            // gave way to a join still coming in on its own contact clock, its vertex short of the end by the corner it had
            // not yet squared: a 10 px^2 dip at 0.2 px of gap.)
            // A cap fillet moved to the front (its vertex and its ellipse), and
            // drawn scaled about its vertex by `w` -- the size test made on what is
            // finally drawn.
            const moved = (c, key) => {
                const f = { vx: c.vx, vy: c.vy, ex: c.ex, ey: c.ey, kx: c.kx, ky: c.ky, krx: c.krx, kry: c.kry,
                            bx: c.bx, by: c.by, key: key };
                const sh = front - bCap;
                if (Xb) { f.vx += sh; f.kx += sh; } else { f.vy += sh; f.ky += sh; }
                return f;
            };
            const put = (f, w) => {
                f.ex *= w; f.ey *= w; f.krx *= w; f.kry *= w;
                f.kx = f.vx + (f.kx - f.vx) * w;
                f.ky = f.vy + (f.ky - f.vy) * w;
                if (Math.abs(f.ex) >= 0.05 && Math.abs(f.ey) >= 0.05)
                    fillets.push(f);
            };
            // The C on the front: on E's face, withdrawing as that face ends (it
            // may not hang past where E's corner starts to curve away)...
            if (cE) {
                // Whole while the face ahead of the front is flat for its reach, then
                // giving way over one reach. A face with no flat room at all (a popup
                // 12 px wide, its corner across the whole top) gives it that one reach
                // of travel from the start: the copy is the cap's fillet at no travel
                // (a ratio of the two rooms there was a ratio of two 1e-5s -- 0.57).
                const insE = Xa ? E.ix[eCh] : E.iy[eCh];
                const reachE = Math.max(EPS, Math.abs(eb_(cE)));
                const fit = clamp01((Math.max(len - insE, reachE) - travel) / reachE);
                put(moved(cE, "pocket|" + endKey + "|E"), fit * (1 - q));
            }
            // ...and on F's face, becoming the corner at contact. The SHAPE
            // morphs; the vertex stays on the front (it reaches the target's as
            // the front reaches the open end). Moved ahead of the front it left air
            // between the fill's end and the fillet: a hook of wallpaper at the face.
            if (cF) {
                const f = moved(cF, "pocket|" + endKey + "|F");
                if (target && q > 0) {
                    for (const key of ["ex", "ey", "krx", "kry", "bx", "by"])
                        f[key] = lerp(f[key], target[key], q);
                    f.kx = f.vx + lerp(f.kx - f.vx, target.kx - target.vx, q);
                    f.ky = f.vy + lerp(f.ky - f.vy, target.ky - target.vy, q);
                }
                put(f, 1);
            }
        }
    }

    // ---- 3. Output -----------------------------------------------------------------
    const maxF = params.maxFillets || 24;
    let outFillets = fillets;
    if (fillets.length > maxF)
        outFillets = fillets.slice().sort((p, q) => Math.abs(q.ex * q.ey) - Math.abs(p.ex * p.ey)).slice(0, maxF);

    // THE POCKET'S CHANNELS, before the joints are solved against the corners they square (pocketChannels).
    const pocketChans = pocketReach > 0 ? pocketChannels() : [];

    // ---- 2b. The joints, now that every sharp claim is in ------------------------
    // The outer corner a fillet meets may have been squared by another join (a
    // popup touching a side bar). Its ceilings here are what is LEFT of it, so
    // the fillet is solved for the corner it will really meet -- solving against
    // the free corner and squaring it afterwards is what left the two detached.
    const caps = facingCaps(joins, R, sideStretch);
    for (let n = 0; n < joins.length; n++) {
        const j = joins[n];
        const cO = j.O.claims[j.cornerO];
        const keepO = 1 - clamp01(cO.sharp);
        // A void's room on that corner (limitVoid), along b and along a.
        const voidB = j.axis === "y" ? cO.voidX : cO.voidY, voidA = j.axis === "y" ? cO.voidY : cO.voidX;
        // The fillet's ceilings, shared with a fillet facing it on one face
        // (FACING FILLETS).
        const HB = Math.min(R + j.st, caps[n].b);
        const HA = Math.min(j.fillA + j.st * sideStretch, caps[n].a);
        // The far corner's ceiling down the side: its own radius -- and, while the
        // S down a guest's side is tight enough to meet it, enough of that side
        // (its corner on the line is square, so the whole side is its to take)
        // that the far corner's tip never turns tighter than half the blend
        // radius where the S meets it. A surface-tension corner is long and
        // shallow, and met by the S at an angle it made an elbow there.
        const tipA = Math.min(Math.max(0, j.side), Math.max(j.raI, Math.sqrt(0.5 * R * j.rbI)));
        const farA = j.I.mobile ? lerp(lerp(j.raI, tipA, smoothstep(0, PRESENCE, j.side)), j.raI,
                                       smoothstep(0.9 * (HA + tipA), HA + tipA, j.side)) : j.raI;
        const joint = sJoint(j.delta, j.side, HB, HA,
                             Math.min(freeAlong(j.O, j.axis, "b", j.cornerO) * keepO, voidB),
                             Math.min(freeAlong(j.O, j.axis, "a", j.cornerO) * keepO, j.hOcap, voidA),
                             Math.max(j.raI, farA), j.rbI);
        shapeCorner(j.O, j.cornerO, j.axis, joint.corner, j.wO, true);
        const insO = lerp(freeAlong(j.O, j.axis, "b", j.cornerO), joint.corner ? joint.corner.off : 0, j.wO);
        noteShort(j.O, j.cornerO, insO);
        // The join hangs off the inner body's face where that face still REACHES
        // the line, not off its nominal end: a corner still rounded there leaves
        // the vertex in the air, and the fillet with it.
        const vertB = j.iEnd - j.dir * j.insI;
        sideFillet(j.axis, vertB, j.va, j.dir, j.dirA, joint, j.I, j.cornerFar, j.wI * (1 - j.kC),
                   j.bleedB, j.bleedA, j.dir * (j.oEnd - j.dir * insO - vertB), j.key);
        if (j.ce && j.I === j.ce.G && joint.fillet && joint.far && j.wI * (1 - j.kC) > 1e-4)
            j.ce.sFar = true;
    }

    // A guest drawn flush with a host's end rests on material only if the host's
    // corner is no wider than the room left between the two ends -- which is what
    // the cut in phase 1 left it. Measured on the DRAWN boxes, so it holds
    // however the faces were pulled, and only where the corner's own shape does
    // not already come out that far by itself.
    for (const c of endCuts) {
        const H = bodies[c.i], Gb = bodies[c.j];
        const hEnd = c.dir > 0 ? bHi(H.box, c.axis) : bLo(H.box, c.axis);
        const gEnd = c.dir > 0 ? bHi(Gb.drawn, c.axis) : bLo(Gb.drawn, c.axis);
        const room = lerp(freeAlong(H, c.axis, "b", c.corner), Math.max(0, c.dir * (hEnd - gEnd)), c.w);
        const sh = shortOf[H.id + "|" + c.corner];
        if (sh === undefined || sh > room + 1e-6)
            limitRadius(H, c.corner, c.axis, "b", room);
    }

    // Resolve every corner's claims: the winning piece (or the free radii),
    // scaled by how sharp the sharpest claim asked for, then capped by any
    // plain radius limit.
    for (const b of bodies) {
        for (let k = 0; k < 4; k++) {
            const c = b.claims[k];
            const keep = 1 - clamp01(c.sharp);
            const px = c.piece;
            const k2 = px && px.aware ? 1 : keep;
            const frx = b.covered[k] ? 0 : b.fRx[k], fry = b.covered[k] ? 0 : b.fRy[k];
            // A joint's piece was solved against the void's room already.
            const limX = px && px.aware ? c.limX : Math.min(c.limX, c.voidX);
            const limY = px && px.aware ? c.limY : Math.min(c.limY, c.voidY);
            b.ex[k] = Math.min(limX, (px ? px.ex : frx) * k2);
            b.ey[k] = Math.min(limY, (px ? px.ey : fry) * k2);
            b.ix[k] = Math.min(limX, (px ? px.ix : frx) * k2);
            b.iy[k] = Math.min(limY, (px ? px.iy : fry) * k2);
        }
    }

    // The end corners, over whatever the joins at those ends resolved to, by how
    // far each end is pulled onto its host's end: the guest's corner on the line
    // square, the host's carrying the lower part of the corner while it reaches
    // past the line, and the guest's far corner the rest of it -- unless another
    // relation squares that one (a popup in the corner between two bars).
    for (const c of cEnds) {
        const X = c.axis === "y";
        const toward = (body, k, t, w) => {
            const q = t || { eb: 0, ea: 0, ib: 0, ia: 0 };
            body.ex[k] = lerp(body.ex[k], X ? q.eb : q.ea, w);
            body.ey[k] = lerp(body.ey[k], X ? q.ea : q.eb, w);
            body.ix[k] = lerp(body.ix[k], X ? q.ib : q.ia, w);
            body.iy[k] = lerp(body.iy[k], X ? q.ia : q.ib, w);
        };
        const ec = c.ec;
        // Over the S at this end only while the corner reaches past the line: once
        // it does not, the end is drawn on the host's end and the S there has
        // closed to square -- the same corners -- or, pulled partway, is solving
        // this very corner itself (its far ceilings are this corner's).
        const wS = ec.dm > EPS ? c.k : 0;
        toward(c.G, cornerOf(c.axis, c.dir, -c.aSideH), null, wS);
        toward(c.H, cornerOf(c.axis, c.dir, c.aSideH),
               ec.Ra > c.h + 1e-6 ? { eb: ec.Rb, ea: ec.Ra, ib: ec.Rb, ia: ec.Ra - c.h } : null, wS);
        const far = cornerOf(c.axis, c.dir, c.aSideH);
        let other = 0;
        for (const tag in c.G.claims[far].sharpBy)
            if (tag !== c.rkey)
                other = Math.max(other, c.G.claims[far].sharpBy[tag]);
        const keep = 1 - clamp01(other);
        toward(c.G, far, { eb: ec.Rb * keep, ea: ec.Ra * keep, ib: Math.max(0, ec.Rb - ec.dm) * keep, ia: ec.Ra * keep },
               c.sFar ? wS : c.k);
    }

    // ---- 2c. THE POCKET: a capped channel zips shut from its cap ---------------------
    // (header.) After the corners are resolved, before the seams are placed on them.
    if (pocketChans.length > 0)
        pockets(pocketChans, src, params, prev, dt);

    // The seams over shared lines, on the resolved corners. A seam may lie only
    // where BOTH bodies are solid across its whole depth -- a corner cutting
    // either one near its end leaves the seam's rectangle over the air it cut
    // away, a spur on the outline -- so each end stops where the thinner of the
    // two stops being that solid. Near a thin end (a popup's lens-shaped end, the
    // end corner crossing the line) the seam steps down to thinner levels rather
    // than stopping short: a meeting line under half a pixel of seam still draws
    // a half-covered row.
    for (let qi = 0; qi < seamReqs.length; qi++) {
        const q = seamReqs[qi];
        // A side steps down only if that body is thinner near an end than the
        // seam is deep; the other keeps the seam at its full depth. The last
        // level is as deep as each body is solid half a bleed in from the seam's
        // ends, overlapping a fillet's bleed there: a seam exactly as thick as a
        // lens-thin end covers the meeting row exactly as much as that end does.
        const stepU = seamThins(q.U, q.axis, q.L - q.dU, q.L, 1), stepD = seamThins(q.D, q.axis, q.Dlo, q.Dlo + q.dD, -1);
        const endU = Math.min(thicknessAt(q.U, q.axis, q.b0 + 0.5 * BLEED, 1), thicknessAt(q.U, q.axis, q.b1 - 0.5 * BLEED, 1));
        const endD = Math.min(thicknessAt(q.D, q.axis, q.b0 + 0.5 * BLEED, -1), thicknessAt(q.D, q.axis, q.b1 - 0.5 * BLEED, -1));
        // The previous level (`had` one): its depths and the span its seams cover so far.
        let had = false, pdU = 0, pdD = 0, plo = 0, phi = 0;
        for (let li = 0; li < SEAM_LEVELS.length; li++) {
            const lv = SEAM_LEVELS[li];
            const dU = stepU ? (lv < 0 ? Math.min(q.dU, endU) : q.dU * lv) : q.dU;
            const dD = stepD ? (lv < 0 ? Math.min(q.dD, endD) : q.dD * lv) : q.dD;
            if (had && dU >= pdU - 1e-6 && dD >= pdD - 1e-6)
                continue;
            const su = solidSpan(q.U, q.axis, q.L - dU, q.L);
            const sd = solidSpan(q.D, q.axis, q.Dlo, q.Dlo + dD);
            const lo = Math.max(q.b0, su.lo, sd.lo), hi = Math.min(q.b1, su.hi, sd.hi);
            if (!had || lo < plo - 0.05 || hi > phi + 0.05)
                pushSeam(q.axis, lo, hi, q.L - dU, q.Dlo + dD, q.U.id + "|" + q.D.id);
            plo = had ? Math.min(plo, lo) : lo;
            phi = had ? Math.max(phi, hi) : hi;
            pdU = dU;
            pdD = dD;
            had = true;
        }
    }
    const maxS = params.maxSeams || 24;
    const outSeams = seams.slice(0, maxS);

    // A body with no area has no material: a box of zero height is still a
    // line to the shader's coverage (half a pixel of ink either side of it).
    const outBodies = bodies.filter(b => !b.sky).map(b => ({
        id: b.id,
        x0: b.drawn.x0, y0: b.drawn.y0, x1: b.drawn.x1, y1: b.drawn.y1,
        ex: b.ex, ey: b.ey, ix: b.ix, iy: b.iy,
        solid: b.drawn.x1 - b.drawn.x0 > EPS && b.drawn.y1 - b.drawn.y0 > EPS
    }));

    const margin = 3 + BLEED;
    const rects = [];
    for (const b of outBodies)
        if (b.x1 - b.x0 > 0 && b.y1 - b.y0 > 0)
            rects.push({ x0: b.x0 - margin, y0: b.y0 - margin, x1: b.x1 + margin, y1: b.y1 + margin });
    for (const f of outFillets) {
        const xa = Math.min(f.vx, f.vx + f.ex), xb = Math.max(f.vx, f.vx + f.ex);
        const ya = Math.min(f.vy, f.vy + f.ey), yb = Math.max(f.vy, f.vy + f.ey);
        rects.push({ x0: xa - margin, y0: ya - margin, x1: xb + margin, y1: yb + margin });
    }
    for (const s of outSeams)
        rects.push({ x0: s.x0 - margin, y0: s.y0 - margin, x1: s.x1 + margin, y1: s.y1 + margin });
    const clip = params.clip || { x0: -1e9, y0: -1e9, x1: 1e9, y1: 1e9 };
    let tileList = tiles(rects, clip, params.maxTiles || 48);
    if (params.forceSingleTile && tileList.length > 0) {
        let hx0 = Infinity, hy0 = Infinity, hx1 = -Infinity, hy1 = -Infinity;
        for (const t of tileList) {
            hx0 = Math.min(hx0, t.x0); hy0 = Math.min(hy0, t.y0);
            hx1 = Math.max(hx1, t.x1); hy1 = Math.max(hy1, t.y1);
        }
        tileList = [{ x0: hx0, y0: hy0, x1: hx1, y1: hy1 }];
    }

    // THE SKY (header): a fillet of the sky wholly outside the clip is never seen -- an island ending AT the screen's corner flares
    // off-screen -- and would take one of the field's few fillet slots for nothing. (Taken here, at the end: the joints above are still
    // pushing fillets into the list `outFillets` stands for.)
    const skyClip = params.clip || { x0: -1e9, y0: -1e9, x1: 1e9, y1: 1e9 };
    const shownFillets = outFillets.filter(f => {
        if (String(f.key).indexOf("sky:") < 0)
            return true;
        const xa = Math.min(f.vx, f.vx + f.ex), xb = Math.max(f.vx, f.vx + f.ex), ya = Math.min(f.vy, f.vy + f.ey), yb = Math.max(f.vy, f.vy + f.ey);
        return xb > skyClip.x0 + 0.5 && xa < skyClip.x1 - 0.5 && yb > skyClip.y0 + 0.5 && ya < skyClip.y1 - 0.5;
    });

    return {
        bodies: outBodies,
        fillets: shownFillets,
        seams: outSeams,
        tiles: tileList,
        state: { rel: nextRel, void: nextVoid },
        settling: settling,
        droppedFillets: Math.max(0, fillets.length - maxF),
        droppedSeams: Math.max(0, seams.length - maxS)
    };
}

// ---- The lane ---------------------------------------------------------------------
//
// A LANE is a popup of its own on a bar (the notifications' toast stack) that
// stays out while thePopup comes and goes, and melts with it (PEERS). Where
// thePopup (or its child) will be is where the lane may not be: it sits flush
// beside thePopup's TARGET box instead, on the side facing the lane's own spot,
// else on the other side, else nowhere (blocked). The engine asks this only
// when thePopup's target changes and eases the lane there on one clock; the one
// rule it applies on every frame is `laneClip`.
//
// lanePlace(spot, size, obstacles, limits) -> { a0, a1, side, blocked }
//   spot       { axis: "x" | "y" (the lane's bar's screen axis), a0 (where the
//              lane starts along it at home), c0, c1 (its extent across) }
//   size       { along (its length along the bar), gap (how far it keeps off an
//              obstacle; 0 melts) }
//   obstacles  [{ x0, y0, x1, y1 }] what it must stay out of; only a box with
//              area that shares the lane's band across counts
//   limits     { lo, hi } the stretch of the axis it may occupy
// Obstacles that overlap, or leave between them less room than the lane needs,
// are one cluster. `side` is where the lane went: 0 home, +1 past the cluster's
// high end, -1 before its low end.
function lanePlace(spot, size, obstacles, limits) {
    const X = spot.axis !== "y";
    const len = Math.max(0, size.along || 0), gap = Math.max(0, size.gap || 0);
    const lo = limits.lo, hi = limits.hi;
    const a0h = spot.a0, a1h = spot.a0 + len;
    const iv = [];
    for (const o of obstacles || []) {
        if (!o)
            continue;
        const a0 = X ? Math.min(o.x0, o.x1) : Math.min(o.y0, o.y1);
        const a1 = X ? Math.max(o.x0, o.x1) : Math.max(o.y0, o.y1);
        const c0 = X ? Math.min(o.y0, o.y1) : Math.min(o.x0, o.x1);
        const c1 = X ? Math.max(o.y0, o.y1) : Math.max(o.x0, o.x1);
        if (a1 - a0 <= EPS || c1 - c0 <= EPS || Math.min(c1, spot.c1) - Math.max(c0, spot.c0) <= EPS)
            continue;
        iv.push([a0 - gap, a1 + gap]);
    }
    iv.sort((p, q) => p[0] - q[0]);
    const cl = [];
    for (const v of iv) {
        const last = cl.length ? cl[cl.length - 1] : null;
        if (last && v[0] < last[1] + len - EPS)
            last[1] = Math.max(last[1], v[1]);
        else
            cl.push(v.slice());
    }
    const free = a0 => a0 >= lo - EPS && a0 + len <= hi + EPS
        && cl.every(c => a0 + len <= c[0] + EPS || a0 >= c[1] - EPS);
    if (free(a0h))
        return { a0: a0h, a1: a1h, side: 0, blocked: false };
    // The cluster in the lane's way: the one it overlaps the most at home.
    let c = null, best = -Infinity;
    for (const v of cl) {
        const ov = Math.min(v[1], a1h) - Math.max(v[0], a0h);
        if (ov > best) {
            best = ov;
            c = v;
        }
    }
    if (c) {
        const toward = (a0h + a1h) / 2 >= (c[0] + c[1]) / 2 ? 1 : -1;
        for (const side of [toward, -toward]) {
            const a0 = side > 0 ? c[1] : c[0] - len;
            if (free(a0))
                return { a0: a0, a1: a0 + len, side: side, blocked: false };
        }
    }
    return { a0: a0h, a1: a1h, side: 0, blocked: true };
}

// ---- The lane below the popup ------------------------------------------------------------
//
// THE LANE BELOW. A lane displaced by a
// popup that is LONGER ALONG ITS BAR THAN IT IS OUT OF IT would stand beside a long, shallow box, so it HANGS FROM THE POPUP'S FOOT
// instead: its top flush against the popup's far face, melted to it as a child is (the engine names the popup its `parent`). Its
// length along the bar is kept under the popup: where `home` has it when that lies under the popup, else moved the least that puts
// it under it -- a lane no longer than the popup inside the popup's span, a longer one covering the whole of it -- and within `limits`.
//
// laneBelowPlace(edge, home, popup, obstacles, limits, room) -> { x0, y0, x1, y1 } | null
//   edge       "top" | "right" | "bottom" | "left": the edge the lane's bar and the popup both hang from
//   home       { x0, y0, x1, y1 } the lane at home, on its bar's face
//   popup      { x0, y0, x1, y1 } the popup's TARGET box
//   obstacles  [{ x0, y0, x1, y1 }] what the lane may not be on, the popup left out (its children, the OSD)
//   limits     { lo, hi } the stretch of the bar's axis the lane may occupy (screen px)
//   room       { lo, hi } how far across the bar the lane may reach (screen px: a top lane's y0 >= lo and y1 <= hi)
// null: the popup is not longer along its bar than out of it, does not overlap the lane's home along the bar (it is not what the
// lane is beside), or no box is free below it (out of room, or on an obstacle).
function laneBelowPlace(edge, home, popup, obstacles, limits, room) {
    const H = edge === "top" || edge === "bottom";
    const k0 = H ? "x0" : "y0", k1 = H ? "x1" : "y1", c0 = H ? "y0" : "x0", c1 = H ? "y1" : "x1";
    const pLen = popup[k1] - popup[k0], pOut = popup[c1] - popup[c0];
    if (!(pLen > pOut + EPS))
        return null;
    const hLen = home[k1] - home[k0], hOut = home[c1] - home[c0];
    if (Math.min(popup[k1], home[k1]) - Math.max(popup[k0], home[k0]) <= EPS)
        return null;
    // Along the bar: home's place if it is under the popup, else the nearest that is.
    let a0 = home[k0];
    if (hLen <= pLen)
        a0 = Math.max(popup[k0], Math.min(popup[k1] - hLen, a0));
    else
        a0 = Math.max(popup[k1] - hLen, Math.min(popup[k0], a0));
    a0 = Math.max(limits.lo, Math.min(limits.hi - hLen, a0));
    // Across it: out of the popup's far face (the one away from the bar).
    let o0, o1;
    if (edge === "top" || edge === "left") {
        o0 = popup[c1];
        o1 = o0 + hOut;
    } else {
        o1 = popup[c0];
        o0 = o1 - hOut;
    }
    if (o0 < room.lo - EPS || o1 > room.hi + EPS)
        return null;
    const box = {};
    box[k0] = a0;
    box[k1] = a0 + hLen;
    box[c0] = o0;
    box[c1] = o1;
    for (const o of obstacles || []) {
        if (!o)
            continue;
        const ox0 = Math.min(o.x0, o.x1), ox1 = Math.max(o.x0, o.x1), oy0 = Math.min(o.y0, o.y1), oy1 = Math.max(o.y0, o.y1);
        if (ox1 - ox0 <= EPS || oy1 - oy0 <= EPS)
            continue;
        if (Math.min(ox1, box.x1) - Math.max(ox0, box.x0) > EPS && Math.min(oy1, box.y1) - Math.max(oy0, box.y0) > EPS)
            return null;
    }
    return { x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1 };
}

// laneClip(box, lane, axis, side) -> box
// The part of `box` (a popup's, on this frame) on `side` of the lane's box along
// the lane's bar `axis` -- +1: past the lane's high face -- wherever the two share
// the band across, BOTH with extent there: a body of no height neither clips nor
// is clipped. A box squeezed to nothing is left at no length ON the lane's face,
// so it grows out of that face again. Continuous in both boxes, so a popup
// yielding to the lane never jumps: this is how thePopup's OutBack overshoot, a
// popup opening onto the lane and the lane gliding back through a closing one
// never draw the two over each other.
function laneClip(box, lane, axis, side) {
    if (!box || !lane || !side)
        return box;
    const X = axis !== "y";
    const k0 = X ? "x0" : "y0", k1 = X ? "x1" : "y1";
    const c0 = X ? "y0" : "x0", c1 = X ? "y1" : "x1";
    if (Math.min(box[c1], lane[c1]) - Math.max(box[c0], lane[c0]) <= EPS)
        return box;
    const out = { x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1 };
    if (side > 0) {
        const f = lane[k1];
        if (out[k0] < f) {
            out[k0] = f;
            if (out[k1] < f)
                out[k1] = f;
        }
    } else {
        const f = lane[k0];
        if (out[k1] > f) {
            out[k1] = f;
            if (out[k0] > f)
                out[k0] = f;
        }
    }
    return out;
}

// ---- The OSD slot -------------------------------------------------------------------
//
// The OSD (a transient popup of its own on a bar, GooeyEngine: THE OSD SLOT) lives
// shorter than anything else it meets, so IT yields: it goes to the free place
// nearest its home -- beside a neighbour on either side, past a cluster, or at an
// end of the stretch it may occupy -- and, when there is none, the engine moves the
// lane, then pushes thePopup (`pushPlace`).
//
// yieldPlace(spot, size, obstacles, limits) -> { a0, a1, side, blocked, touching }
//   spot       { axis: "x" | "y" (the OSD's bar's screen axis), a0 (where it starts
//              along it at home), c0, c1 (its extent across) }
//   size       { along (its length along the bar), gap (the keep-off of an obstacle
//              that has none of its own) }
//   obstacles  [{ x0, y0, x1, y1, gap?, id? }] what it must stay out of: `gap` 0 melts
//              (same bar: the engine's peers), blendRadius keeps a perpendicular box
//              apart; only a box with area that shares the OSD's band across counts
//   limits     { lo, hi } the stretch of the axis it may occupy
// Obstacles that overlap, or leave less room between them than the OSD needs, are one
// cluster. The candidates are home, each cluster's two sides and the two limits; the
// answer is the FREE candidate nearest home (a tie goes to the side the OSD is on
// relative to the cluster in its way, as lanePlace does). `side` is -1 / 0 / +1: where
// it went from home. `touching`: the ids of the obstacles it lies flush against (gap 0).
function yieldPlace(spot, size, obstacles, limits) {
    const X = spot.axis !== "y";
    const len = Math.max(0, size.along || 0), gap0 = Math.max(0, size.gap || 0);
    const lo = limits.lo, hi = limits.hi;
    const a0h = spot.a0, a1h = spot.a0 + len;
    const ents = [];
    for (const o of obstacles || []) {
        if (!o)
            continue;
        const a0 = X ? Math.min(o.x0, o.x1) : Math.min(o.y0, o.y1);
        const a1 = X ? Math.max(o.x0, o.x1) : Math.max(o.y0, o.y1);
        const c0 = X ? Math.min(o.y0, o.y1) : Math.min(o.x0, o.x1);
        const c1 = X ? Math.max(o.y0, o.y1) : Math.max(o.x0, o.x1);
        if (a1 - a0 <= EPS || c1 - c0 <= EPS || Math.min(c1, spot.c1) - Math.max(c0, spot.c0) <= EPS)
            continue;
        const g = o.gap === undefined || o.gap === null ? gap0 : Math.max(0, o.gap);
        ents.push({ lo: a0 - g, hi: a1 + g, gap: g, id: o.id === undefined ? "" : String(o.id) });
    }
    ents.sort((p, q) => p.lo - q.lo);
    const cl = [];
    for (const v of ents) {
        const last = cl.length ? cl[cl.length - 1] : null;
        if (last && v.lo < last[1] + len - EPS)
            last[1] = Math.max(last[1], v.hi);
        else
            cl.push([v.lo, v.hi]);
    }
    const free = a0 => a0 >= lo - EPS && a0 + len <= hi + EPS
        && cl.every(c => a0 + len <= c[0] + EPS || a0 >= c[1] - EPS);
    const done = (a0, side, blocked) => {
        const touching = [];
        if (!blocked)
            for (const v of ents)
                if (v.gap <= EPS && v.id !== "" && (Math.abs(a0 + len - v.lo) <= 1e-6 || Math.abs(a0 - v.hi) <= 1e-6)
                        && touching.indexOf(v.id) < 0)
                    touching.push(v.id);
        return { a0: a0, a1: a0 + len, side: side, blocked: blocked, touching: touching };
    };
    if (free(a0h))
        return done(a0h, 0, false);
    // The cluster in its way: the one it overlaps the most at home.
    let toward = 1, best = -Infinity;
    for (const v of cl) {
        const ov = Math.min(v[1], a1h) - Math.max(v[0], a0h);
        if (ov > best) {
            best = ov;
            toward = (a0h + a1h) / 2 >= (v[0] + v[1]) / 2 ? 1 : -1;
        }
    }
    const cands = [lo, hi - len];
    for (const v of cl)
        cands.push(v[0] - len, v[1]);
    let pick = null, pd = Infinity;
    for (const a0 of cands) {
        if (!free(a0))
            continue;
        const d = Math.abs(a0 - a0h);
        const dir = a0 >= a0h ? 1 : -1;
        if (d < pd - EPS || (Math.abs(d - pd) <= EPS && dir === toward && pick !== null && pick.dir !== toward)) {
            pd = d;
            pick = { a0: a0, dir: dir };
        }
    }
    if (!pick)
        return done(a0h, 0, true);
    return done(pick.a0, pick.dir, false);
}

// pushPlace(mover, axis, fixed, gap, limits, side) -> { shift } | null
// The smallest shift of a popup ALONG ITS OWN BAR (`axis`) that clears `fixed` (the OSD's
// box) by `gap`, inside `limits` { lo, hi }. `mover` { box (what must clear: the popup and
// its child), core (the popup's own box, the part that must stay inside the limits) }.
// `side` (+1 / -1, 0 either) is the side of the mover the OSD is on: the popup gives way
// AWAY from it, and never passes through it. 0 shift when they do not meet (no shared band
// across, or no overlap along); null when no shift clears it within the limits.
function pushPlace(mover, axis, fixed, gap, limits, side) {
    const X = axis !== "y";
    const g = Math.max(0, gap || 0);
    const k0 = X ? "x0" : "y0", k1 = X ? "x1" : "y1", c0 = X ? "y0" : "x0", c1 = X ? "y1" : "x1";
    const m = mover.box, core = mover.core || mover.box;
    if (Math.min(m[c1], fixed[c1]) - Math.max(m[c0], fixed[c0]) <= EPS)
        return { shift: 0 };
    const f0 = fixed[k0] - g, f1 = fixed[k1] + g;
    if (Math.min(m[k1], f1) - Math.max(m[k0], f0) <= EPS)
        return { shift: 0 };
    const sd = side || 0, cands = [];
    if (sd >= 0)
        cands.push(f0 - m[k1]);
    if (sd <= 0)
        cands.push(f1 - m[k0]);
    let best = null;
    for (const s of cands) {
        if (core[k0] + s < limits.lo - EPS || core[k1] + s > limits.hi + EPS)
            continue;
        if (best === null || Math.abs(s) < Math.abs(best))
            best = s;
    }
    return best === null ? null : { shift: best };
}

// ---- Tiles ------------------------------------------------------------------------
//
// The field is drawn only where it can be seen: over the union of its
// primitives' boxes grown by the antialiasing. That union is cut into DISJOINT
// axis-aligned tiles by a sweep over y, and the vertex shader places one quad per
// tile. Neighbouring tiles share their edge coordinates exactly, so the
// rasteriser gives every pixel to exactly one of them.
//
// rects: [{x0,y0,x1,y1}]; clip: {x0,y0,x1,y1}; maxTiles. Never more than
// maxTiles: a band that would overflow is merged into its hull, and as a last
// resort the whole union becomes one tile -- that costs fill rate, never
// correctness.
function tiles(rects, clip, maxTiles) {
    // The clipped rects, flat: rect i is (rx0, ry0, rx1, ry1)[i].
    const rx0 = [], ry0 = [], rx1 = [], ry1 = [];
    for (let i = 0; i < rects.length; i++) {
        const r = rects[i];
        const x0 = Math.max(clip.x0, r.x0), x1 = Math.min(clip.x1, r.x1);
        const y0 = Math.max(clip.y0, r.y0), y1 = Math.min(clip.y1, r.y1);
        if (x1 > x0 && y1 > y0) {
            rx0.push(x0);
            ry0.push(y0);
            rx1.push(x1);
            ry1.push(y1);
        }
    }
    const nr = rx0.length;
    if (nr === 0)
        return [];

    // (Sorted by insertion, not Array.sort with a comparator -- every comparison a JS call in QV4. The coordinates here are
    // finite, never NaN (a NaN fails `x1 > x0` above), so the order is the one any sort gives; intervals with one start merge
    // to the same union in any order.)
    const ys = [];
    for (let i = 0; i < nr; i++)
        ys.push(ry0[i], ry1[i]);
    for (let i = 1; i < ys.length; i++) {
        const v = ys[i];
        let k = i - 1;
        while (k >= 0 && ys[k] > v) {
            ys[k + 1] = ys[k];
            k--;
        }
        ys[k + 1] = v;
    }
    const edges = [];
    for (let i = 0; i < ys.length; i++)
        if (edges.length === 0 || ys[i] !== edges[edges.length - 1])
            edges.push(ys[i]);

    // The band [ya, yb] is covered by the rects with y0 <= ya and y1 >= yb: a sweep keeps them (`act`), adding each rect by its
    // y0 (`byY`) and dropping it once it ends -- the same set as a test of every rect, at a few per band instead of all of them.
    const byY = [];
    for (let i = 0; i < nr; i++) {
        let k = i - 1;
        while (k >= 0 && ry0[byY[k]] > ry0[i]) {
            byY[k + 1] = byY[k];
            k--;
        }
        byY[k + 1] = i;
    }
    // A band's intervals are one flat list, [x0, x1, x0, x1, ...], in order.
    const bands = [];
    const ivA = [], ivB = [], act = [];
    let next = 0;
    for (let e = 0; e + 1 < edges.length; e++) {
        const ya = edges[e], yb = edges[e + 1];
        while (next < nr && ry0[byY[next]] <= ya)
            act.push(byY[next++]);
        let live = 0;
        for (let q = 0; q < act.length; q++)
            if (ry1[act[q]] >= yb)
                act[live++] = act[q];
        act.length = live;
        let n = 0;
        for (let q = 0; q < live; q++) {
            const a = rx0[act[q]], b = rx1[act[q]];
            let k = n - 1;
            while (k >= 0 && ivA[k] > a) {
                ivA[k + 1] = ivA[k];
                ivB[k + 1] = ivB[k];
                k--;
            }
            ivA[k + 1] = a;
            ivB[k + 1] = b;
            n++;
        }
        if (n === 0)
            continue;
        const merged = [ivA[0], ivB[0]];
        for (let i = 1; i < n; i++) {
            const last = merged.length - 1;
            if (ivA[i] <= merged[last])
                merged[last] = Math.max(merged[last], ivB[i]);
            else
                merged.push(ivA[i], ivB[i]);
        }
        const prevBand = bands.length ? bands[bands.length - 1] : null;
        if (prevBand && prevBand[1] === ya && sameIntervals(prevBand[2], merged))
            prevBand[1] = yb;
        else
            bands.push([ya, yb, merged]);
    }

    let count = 0;
    for (let i = 0; i < bands.length; i++)
        count += bands[i][2].length / 2;
    while (count > maxTiles) {
        let best = -1, bestN = 1;
        for (let i = 0; i < bands.length; i++)
            if (bands[i][2].length / 2 > bestN) {
                best = i;
                bestN = bands[i][2].length / 2;
            }
        if (best < 0)
            break;
        const iv = bands[best][2];
        bands[best][2] = [iv[0], iv[iv.length - 1]];
        count -= bestN - 1;
    }
    if (count > maxTiles) {
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (let i = 0; i < nr; i++) {
            x0 = Math.min(x0, rx0[i]);
            y0 = Math.min(y0, ry0[i]);
            x1 = Math.max(x1, rx1[i]);
            y1 = Math.max(y1, ry1[i]);
        }
        return [{ x0: x0, y0: y0, x1: x1, y1: y1 }];
    }

    const out = [];
    for (let i = 0; i < bands.length; i++) {
        const m = bands[i][2];
        for (let k = 0; k < m.length; k += 2)
            out.push({ x0: m[k], y0: bands[i][0], x1: m[k + 1], y1: bands[i][1] });
    }
    return out;
}

// Two bands' flat interval lists (tiles) the same.
function sameIntervals(a, b) {
    if (a.length !== b.length)
        return false;
    for (let i = 0; i < a.length; i++)
        if (a[i] !== b[i])
            return false;
    return true;
}

// ---- Easing -------------------------------------------------------------------------
//
// The engine drives each body with ONE progress 0..1 and reads the box off it,
// so the curves live here instead of in a QML Behavior. Index order is what the
// mockup's sliders show; new curves are APPENDED (an index is a saved value).
// 6..8: slow starts for a close that has to be SEEN leaving
// -- the flourish's bridge, where OutBack's face crosses any neck in a frame.
const EASING_NAMES = ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo",
                      "InQuad", "InCubic", "InBack"];

function ease(index, t, overshoot) {
    t = Math.max(0, Math.min(1, t));
    switch (index) {
    case 1: return 1 - Math.pow(1 - t, 3);
    case 2: return 1 - Math.pow(1 - t, 5);
    case 3: {
        // `overshoot` in Qt's own units (Easing.OutBack's `overshoot`, default
        // 1.70158), so a value tuned on a QML Behavior means the same here.
        const s = overshoot === undefined ? 1.70158 : overshoot;
        const u = t - 1;
        return u * u * ((s + 1) * u + s) + 1;
    }
    case 4: return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
    case 5: return t >= 1 ? 1 : 1 - Math.pow(2, -10 * t);
    case 6: return t * t;
    case 7: return t * t * t;
    case 8: {
        // Qt's InBack: a dip below 0 first, `overshoot` as in OutBack.
        const s = overshoot === undefined ? 1.70158 : overshoot;
        return t * t * ((s + 1) * t - s);
    }
    default: return t;
    }
}

// ---- THE OVERSHOOT'S BIAS (GooeyEngine) -------------------------------------
//
// OutBack's swell past 1, as a share of the travel: 4 s^3 / (27 (s + 1)^2), at
// t = 1 - 2 s / (3 (s + 1)). 1.2: 5.29 % at 63.6 % of the clock; 0: none (the
// curve is then OutCubic exactly).
function backPeak(s) {
    if (!(s > 0))
        return 0;
    return 4 * s * s * s / (27 * (s + 1) * (s + 1));
}

// The overshoot (Qt's units, 0..sMax) whose OutBack swells by share `p` of its
// travel. backPeak rises with s, so a bisection.
function backForPeak(p, sMax) {
    if (!(p > 0) || !(sMax > 0))
        return 0;
    if (p >= backPeak(sMax))
        return sMax;
    let lo = 0, hi = sMax;
    for (let i = 0; i < 40; i++) {
        const mid = (lo + hi) / 2;
        if (backPeak(mid) < p)
            lo = mid;
        else
            hi = mid;
    }
    return (lo + hi) / 2;
}

// How far (px) an open whose longest edge travels `travel` px swells past its
// rest: `s0`'s share of the travel while the open is short -- the curve every
// popup always had -- bending into `cap` px as it grows, and into `area / cross`
// px where the popup is wide across its motion (`cross`: crossExtent). What reads
// as "how much moved" is the swell times the extent it drags along: a reel 40 px
// across swells unseen where a list 400 px across moves a slab (the user, round
// 3). A soft minimum of the three, (lin^-n + cap^-n + (area/cross)^-n)^(-1/n),
// `bend` its sharpness (the larger, the later and harder the turn: where two of
// them are equal and the third far, the swell is that value / 2^(1/bend)).
// cap <= 0: the share all the way (the old engine); area <= 0 or no cross: the
// cap alone (round 2's rule).
function biasedPeakPx(travel, s0, cap, bend, cross, area) {
    const lin = backPeak(s0) * Math.max(0, travel);
    if (!(cap > 0) || !(lin > 0))
        return lin;
    const n = Math.max(0.5, bend);
    let sum = Math.pow(lin / cap, n);
    if (area > 0 && cross > 0)
        sum += Math.pow(lin * cross / area, n);
    return lin / Math.pow(1 + sum, 1 / n);
}

// The overshoot (Qt's units) of that open: ONE OutBack with its own s, so the
// open stays one motion whose speed is continuous from its first frame to its
// rest (no "grow, then bounce" seam). In thousandths (a curve's samples are
// cached per overshoot: _easeRange), and s0 itself where the bend moves it by
// less than one, so a short open runs the old curve to the bit.
function biasedOvershoot(travel, s0, cap, bend, cross, area) {
    if (!(cap > 0) || !(travel > 0) || !(s0 > 0))
        return s0;
    const s = Math.round(1000 * backForPeak(biasedPeakPx(travel, s0, cap, bend, cross, area) / travel, s0)) / 1000;
    return Math.abs(s - s0) < 1e-3 ? s0 : s;
}

// The longest way any edge goes from box `a` to box `b`.
function edgeTravel(a, b) {
    if (!a || !b)
        return 0;
    return Math.max(Math.abs(b.x0 - a.x0), Math.abs(b.y0 - a.y0), Math.abs(b.x1 - a.x1), Math.abs(b.y1 - a.y1));
}

// The extent of box `b` ACROSS a run from box `a`: what a swell along the run
// drags with it (biasedPeakPx's area). The run grows ALONG the axis on which `a`
// has the smaller share of `b`'s size -- out of nothing, for a popup out of its
// bar's face (a weather popup that also widens by more than it grows is still a
// vertical open) -- and the cross extent is `b`'s size on the other axis: the
// width of a popup out of a top bar, the height of one out of a side bar. A box
// that opens out of a point on both axes (a tray menu from its row's corner)
// takes its shorter side, and between the two (shares within a quarter of each
// other) the extent eases from one to the other, so no box sits on a step.
function crossExtent(a, b) {
    if (!a || !b)
        return 0;
    const w = Math.abs(b.x1 - b.x0), h = Math.abs(b.y1 - b.y0);
    const rx = w > 0 ? Math.min(1, Math.abs(a.x1 - a.x0) / w) : 1;
    const ry = h > 0 ? Math.min(1, Math.abs(a.y1 - a.y0) / h) : 1;
    const k = Math.max(-1, Math.min(1, (rx - ry) / 0.25));
    const m = Math.min(w, h);
    return k >= 0 ? m + k * (w - m) : m - k * (h - m);
}

// An OutBack overshoot past a zero size is no size, not a negative one -- and it
// is the box WHERE its size reached zero on the way from `from` to `to`. A popup
// closing into its bar closes onto the bar's face and stays there while the
// curve overshoots; collapsing it on its own midpoint instead put a flat box a
// few pixels inside the bar, travelling in and back out over the corner's air for
// the second half of every close. Without the path (`from`, `to` null) there is
// only the midpoint.
function collapseBox(box, from, to) {
    const out = { x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1 };
    for (const [lo, hi] of [["x0", "x1"], ["y0", "y1"]]) {
        if (out[hi] >= out[lo])
            continue;
        let at = (out[lo] + out[hi]) / 2;
        if (from && to) {
            const sa = from[hi] - from[lo], sb = to[hi] - to[lo];
            if (sa > sb)
                at = from[lo] + (to[lo] - from[lo]) * clamp01(sa / (sa - sb));
        }
        out[lo] = at;
        out[hi] = at;
    }
    return out;
}

function lerpBox(a, b, e) {
    return {
        x0: a.x0 + (b.x0 - a.x0) * e,
        y0: a.y0 + (b.y0 - a.y0) * e,
        x1: a.x1 + (b.x1 - a.x1) * e,
        y1: a.y1 + (b.y1 - a.y1) * e
    };
}
