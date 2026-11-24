pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SideFade.qml -- the side cut and the side fade of a list whose rows can be
// DISPLACED SIDEWAYS (a SwipeVerbCard being swiped, flying off).
//
// A list clips its rows somewhere, and a card slid past that line is cut hard
// there, so the point of the clip is hidden by a fade. ScrollDressing fades the two ENDS
// a list scrolls towards; this fades the two SIDES a row can be pushed out of.
//
// IT DRAWS NOTHING. It is the geometry -- a frame (it fills `target`, the
// rows' strip), the host's outline in that frame, the clip line and the fade's
// lengths -- and the DISPLACED ROW draws the cut and the fade itself, through
// the layer it is while it is off its rest (SideCut, shaders/side_cut.frag):
// a SwipeVerbCard's face (THE LIST), and a RowFlight's clone lifted off such a
// face on its way back to its column (RowFlight, LIFTED OFF A MOVED FACE). So:
//   - a resting row is never touched, and a still list draws exactly what it
//     draws without a SideFade (a ground-coloured band over every resting row
//     would round 1-2 levels differently from the ground it lies on);
//   - the fade can be as long as the list's own (`fadeLength`, 34): it is on
//     the displaced row only, so it may lie over where that row RESTS (bands
//     over every row would have to fit in the padding, 5 px);
//   - the cut follows the host's rounded outline per pixel row (one clip line
//     for the whole strip, taken at the corner, would leave no band at a 30 px
//     radius or a 6 px padding).
//
// THE GEOMETRY, per pixel row, measured from the frame's left and right edges
// (the host's own edges -- the strip spans the host's full width):
//
//   the CUT         the outline shrunk by `cornerMargin` (the host's own
//                   antialiased rim reaches about that far in: measured on a
//                   Rectangle of radius 20, coverage 0.89 at 0.55 px inside the
//                   curve, whole from 0.9), and never outside `clipInset`, the
//                   host's rectangular clip. Nothing is drawn past it.
//   the ZERO LINE   where the cut lies in that row: the straight clip line in a
//                   row clear of any corner, the curve in a corner's rows.
//   `leadPx`        fully clear from the zero line in: the column the cut runs
//                   through never shows the card.
//   the SHORT ramp  from the lead to where a RESTING card begins in that row
//                   (its rounded corner and its `rimPx` rim included): always
//                   on while displaced -- it lies over nothing a resting card
//                   draws, so the first pixel of a swipe changes a pixel's
//                   worth -- and it is what puts the card at 0 before the cut.
//                   Its length is the layout's: 7 px at a 12 px padding, 1 at
//                   a 6 px one, where a pixel of travel dims the card's edge
//                   by up to 0.42 (0.82 in the corner rows of a 4 px padding
//                   at radius 32, where the resting card already overhangs
//                   the outline; measured). Nothing is drawn past the cut at
//                   any padding: a small padding shortens the fade, it never
//                   brings back the poke.
//   the LONG ramp   `fadeLength` from the lead, with a strength that grows
//                   with the displacement, |offset| / fadeLength: a fade is a
//                   distance from the rest, as ScrollDressing's is a distance
//                   from the end.
//
// `outline` is the host's shape in THIS item's coordinates, {x, y, w, h,
// radii: [tl, tr, br, bl]} (ScrollDressing.outline's shape): the RESTING
// radius -- while a gooey popup opens, closes or travels its corners inflate,
// and the engine's own content clip is on for exactly those frames -- at the
// LIVE size, the box as it is drawn this frame (a toast's outline taken from
// its final implicitHeight while the rows' strip follows the live stack would
// cut a held card straight, 6 px in, for four frames). SideCut
// BINDS it, so a displaced row re-cuts on the change itself -- a live outline
// is followed as it moves. null: no outline, the clip line alone.
//
// A host whose rows' corners reach past its own outline at rest (a padding
// smaller than the gap between the two radii) has a resting row that
// overhangs its rim; a displaced one is cut to the outline all the same --
// the overhang itself is the host's layout.
//
// USE. The strip spans the host's full width and exactly the rows' vertical
// clip; the rows are clipped at `clipInset`; every SwipeVerbCard in it gets
// `sideFade: fade`:
//
//     Item {                                      // the host, W wide
//         Item {                                  // the rows' strip
//             id: rowStrip
//             width: parent.width; y: padding - 2; height: ...   // vertical clip
//             Item {                              // the clip
//                 x: fade.clipInset; width: parent.width - 2 * x
//                 height: parent.height; clip: true
//                 SwipeVerbCard { x: padding - fade.clipInset; sideFade: fade; ... }
//             }
//         }
//         SideFade {
//             id: fade
//             target: rowStrip
//             outline: ({ x: 0, y: -rowStrip.y, w: width, h: <the box's live height>,
//                         radii: [r, r, r, r] })
//         }
//         RowFlight {                             // a pin flight, if any
//             sideFade: fade; cloneRadius: <the cards' radius>; ...
//             // begin(key, card, data, card.faceItem) from the card's commit
//         }
//     }
//
// Theme-free: it has no colour. The card fades to nothing, so what shows is
// whatever the host's ground is -- a tint, a melt -- never a second surface.
// =============================================================================
Item {
    id: fade

    // ---- Contract ---------------------------------------------------------
    property Item target: null
    property var outline: null
    // The host's rectangular clip line, from each side (clipInset, whole px):
    // a carved card's bevel needs 2 px of slack past the padding it sits in.
    property real inset: 2
    // How far inside the outline the cut lies (see THE GEOMETRY).
    property real cornerMargin: 1
    // Fully clear from the zero line in.
    property real leadPx: 1
    // How far a resting card draws outside its rect (a carved bevel): the
    // short ramp ends there, so it never touches a resting card.
    property real rimPx: 2
    // The long ramp: the list's own fade length (ScrollDressing.fadeHeight).
    property real fadeLength: 34
    // Which sides fade. Not `left`/`right`: those are Item's own anchor lines.
    property bool leftBand: true
    property bool rightBand: true

    // The host's clip line: a whole pixel, the same on both sides.
    readonly property int clipInset: Math.max(0, Math.round(fade.inset))

    anchors.fill: fade.target
}
