pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// NewNoteTile.qml -- the grid's first cell: a carved slot with a plus.
//
// Always first, never dragged and never a drop target. A slot rather than a
// button: it is the place a note will be, and the pointer (the plus warming
// to the accent, the hand) is all that says it can be clicked.
// =============================================================================
Item {
    id: tile

    property real radius: 12
    // The plus alone, no slot: on the morph card.
    property bool bare: false
    signal clicked

    property real hoverF: hover.hovered ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    ShadowBox {
        visible: !tile.bare
        anchors.fill: parent
        baseWidth: tile.width
        baseHeight: tile.height
        baseRadius: tile.radius
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Mix.c(Theme.listBox, Theme.panelSunk, tile.hoverF * 0.6)
        bevelWidth: 1
        shadowWidth: 3
    }
    Text {
        anchors.centerIn: parent
        text: "+"
        font.family: "Inter"
        font.pixelSize: 34
        font.weight: Font.Light
        color: Mix.c(Theme.textFaint, Theme.accent, tile.hoverF)
    }
}
