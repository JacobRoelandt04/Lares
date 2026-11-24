pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "../glyphs"
import "Mix.js" as Mix

// =============================================================================
// BarGlyphButton.qml -- one Nerd Font glyph in the bar, the shell's plain icon button.
//
// The bar's glyph buttons (notes, the bell, the placeholders' replacements: theme, LLM, player) share one look and
// this is it: a glyph of `glyphSize` in a square of `glyphSize + 2 * pad`, in the muted ink at rest and the glyph's OWN hover
// hue under the pointer (`hoverInk`: a role of BarHues, the bar's one hue table), with the hand cursor. Nothing else announces
// an affordance (CLAUDE.md, Clutter). The hover eases on the bar's ONE hover clock (GlyphHoverEase).
//
// THE INK is the host's fact, not this item's: `ink` is whatever the module wants to say right now (playing, generating,
// off) and the host builds it from EASED FRACTIONS with Mix.js -- never a `Behavior on color`, because a Behavior cannot
// tell a state change from the theme moving underneath it and would lag every switch (CLAUDE.md, Common mistakes). The
// hover is one more fraction, here, mixed over whatever the host says. NOTHING HERE IS FAINT: a state is a hue of full ink
// (on: the glyph's ON hue, off: the muted ink, in one glyph shape), never a dimmer one.
//
// A glyph swap is instant (text swaps are instant, only presence fades). `glyphRotation` and the default property let a
// host turn the glyph and draw something on it (the player's motion lines): children stand in an item the size of the
// glyph's square, centred on it, that turns with it.
//
// A FLOURISH: the glyph is a PosedGlyph (the plain Text at rest, the same place and size), so a host with a flourish hands
// its pose over (`posing`, `parts`, `shades`) and reads `glyphOrigin` / `glyphSize` to place it; a host with none sets nothing.
//
// The pointer: `clicked(button)` for the left and the right button. NO TIP: a glyph button is as simple as its title.
// =============================================================================
Item {
    id: root

    property string glyph: ""
    property string family: "Symbols Nerd Font"
    property real glyphSize: 18
    // The space round the glyph, both ways: the same 28 px square the notes button is at 18.
    property real pad: 5

    // What the host says the ink is now, and where the pointer takes it.
    property color ink: Theme.textMuted
    property color hoverInk: Theme.accent

    property real glyphRotation: 0
    // a flourish's pose (PosedGlyph): the font's outline moved, while `posing`
    property bool posing: false
    property var parts: []
    property var shades: []
    readonly property point glyphOrigin: glyphText.origin
    property bool pointerCursor: true

    default property alias decoration: decor.data
    readonly property alias area: hit
    readonly property bool hovered: hit.containsMouse
    // The glyph's own item, for a host that places something against it.
    readonly property alias glyphItem: glyphText
    readonly property real hoverF: root._hoverF

    signal clicked(int button)

    implicitWidth: Math.ceil(root.glyphSize + 2 * root.pad)
    implicitHeight: Math.ceil(root.glyphSize + 2 * root.pad)

    property real _hoverF: hit.containsMouse ? 1 : 0
    Behavior on _hoverF {
        GlyphHoverEase {}
    }

    Item {
        id: decor
        anchors.centerIn: parent
        width: Math.ceil(root.glyphSize)
        height: width
        rotation: root.glyphRotation
        transformOrigin: Item.Center

        PosedGlyph {
            id: glyphText
            anchors.centerIn: parent
            text: root.glyph
            family: root.family
            pixelSize: root.glyphSize
            color: Mix.c(root.ink, root.hoverInk, root._hoverF)
            posing: root.posing
            parts: root.parts
            shades: root.shades
        }
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: root.pointerCursor ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: mouse => root.clicked(mouse.button)
    }

}
