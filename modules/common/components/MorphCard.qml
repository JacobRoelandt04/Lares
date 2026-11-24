pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// MorphCard.qml -- a tile on its way to becoming the whole page, or back
// (LevelMorph.js has the arithmetic, MorphClock the clock).
//
// A phone opens an app by growing its icon into the screen; notes opens a
// note or a group that way, and the launcher its folders. The host places
// this card every frame -- LevelMorph.cardRect, from the tile's rect to the
// page's and back -- and hands it `grow`, the same eased fraction: 0 is the
// tile as its grid draws it, 1 is indistinguishable from the page's own
// surface (its fill is the host's ground, its corners the host's corners, no
// bevel, no shadow), which is what lets the host drop the card on the last
// frame without a seam.
//
//   face        a Component: the tile's own face (its title and preview, a
//               group's minis, a row's icon and name), created with no
//               arguments -- it binds its own data (the host's `facts`, read
//               through this card's id). Drawn at the TILE's size, pinned to
//               the card's top-left corner as it grows, faded by `faceF`.
//               Any shape of tile: a landscape note, a wide short row.
//   facts       what the face shows (the host's entry), for the face to read
//   raised      the tile stands proud (a button's drop shadow) rather than
//               being carved into its ground
//   tileColor   the tile's fill; the card's goes to `groundColor` with grow
//   radii       the host's corners ([tl, tr, br, bl]) the card's must become
//   fill        (read) the card's fill on this frame, for a face drawn on it
//   edgeMinPx   the thinnest the bevel and the shadow are ever drawn, 1
//   minRadius   the least a corner is ever rounded, 8 (the tile's own when
//               that is smaller)
//
// THE EDGE FADES, IT DOES NOT THIN OUT. A bevel and shadow that ran down to
// nothing with `grow` -- 1.5 px and 5 px times (1 - grow) -- would be a band
// under a pixel: a line the antialiasing paints a different amount of on
// every frame the card's fractional position crosses a pixel, a subpixel thin
// line near the end of the animation that micro-flickers when the back is
// scrubbed through it. Under `edgeMinPx` the band holds that width
// and its colour fades instead, to nothing at grow 1 -- the same ink an
// antialiased thin band shows on a pixel-aligned edge, with no thin band to
// flicker. The corners keep `minRadius` for the same stretch: a host whose
// corners are square (a corner hanging from the bar, a group's well) would take
// the card's to 0 over the second half of the morph, a rounded card going
// square before it is the page; the fade hides what it lands on.
// =============================================================================
Item {
    id: card

    property Component face: null
    property var facts: null
    property real grow: 0
    property real faceF: 1
    property real tileW: 100
    property real tileH: 70
    property real tileRadius: 12
    property bool raised: true
    property color tileColor: Theme.buttonPlateau
    property color groundColor: Theme.surface
    property var radii: [0, 0, 0, 0]
    property real edgeMinPx: 1
    property real minRadius: 8

    readonly property color fill: Mix.c(card.tileColor, card.groundColor, card.grow)
    function _r(k) {
        const floor = Math.min(card.tileRadius, card.minRadius);
        return card.tileRadius + (Math.max(card.radii[k] || 0, floor) - card.tileRadius) * card.grow;
    }

    // The bands as they shrink (nominal px, 0 at grow 1) and the share of
    // their ink that is left once none is allowed under `edgeMinPx`.
    readonly property real _bevelNom: (card.raised ? 1.5 : 1) * (1 - card.grow)
    readonly property real _shadowNom: (card.raised ? 5 : 3) * (1 - card.grow)
    readonly property real bevelPx: Math.max(card._bevelNom, card.edgeMinPx)
    readonly property real shadowPx: Math.max(card._shadowNom, card.edgeMinPx)
    readonly property real bevelInk: Math.min(1, card._bevelNom / card.edgeMinPx)
    readonly property real shadowInk: Math.min(1, card._shadowNom / card.edgeMinPx)
    // The rim fades toward what it sits on: the plateau (raised: inside the
    // edge), or nothing (carved: outside it, over the page).
    readonly property color _bevel: Mix.c(card.raised ? Theme.buttonBevel : Theme.bevel,
                                          card.raised ? card.fill : Qt.rgba(Theme.bevel.r, Theme.bevel.g, Theme.bevel.b, 0),
                                          1 - card.bevelInk)

    ShadowBox {
        anchors.fill: parent
        baseWidth: card.width
        baseHeight: card.height
        baseRadius: card.tileRadius
        topLeftRadius: card._r(0)
        topRightRadius: card._r(1)
        bottomRightRadius: card._r(2)
        bottomLeftRadius: card._r(3)
        raised: card.raised
        shadowToAlpha: true
        surfaceColor: "transparent"
        bevelColor: card._bevel
        shadowColor: card.raised ? Theme.buttonShadow : Theme.border
        shadowEdgeAlpha: card.shadowInk
        backgroundColor: card.fill
        bevelWidth: card.bevelPx
        shadowWidth: card.shadowPx
    }

    Loader {
        x: 0
        y: 0
        width: card.tileW
        height: card.tileH
        opacity: card.faceF
        visible: card.faceF > 0.001
        sourceComponent: card.face
    }
}
