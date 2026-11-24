pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// PanelCard.qml -- one carved container of a silicon panel: a ShadowBox (inset shadow inside the
// edge, light bevel outside) holding a column of blocks 12 px from every edge. Its height is its
// content's, so a block that is not there (a feature the kernel lacks) takes nothing.
//
// A block that comes and goes must collapse BY GEOMETRY as well as by `visible`: a Column does not
// hear a child whose `visible` flips under a hidden ancestor, and it still counts the gap of a
// visible child of zero height.
// =============================================================================
Item {
    id: card

    property SecondaryStyle look: null
    default property alias content: column.data
    // The column inside the padding: blocks are placed in it by the host.
    readonly property real innerWidth: Math.max(0, card.width - 2 * card.pad)
    readonly property real pad: card.look ? card.look.cardPadding : 12

    implicitHeight: Math.ceil(column.implicitHeight + 2 * card.pad)

    ShadowBox {
        anchors.fill: parent
        baseRadius: card.look ? card.look.radius : 14
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: card.look ? card.look.cardBevelWidth : 1
        shadowWidth: card.look ? card.look.cardShadowWidth : 3
        shadowFalloff: card.look ? card.look.cardShadowFalloff : 1
    }

    Column {
        id: column
        x: card.pad
        y: card.pad
        width: card.innerWidth
        spacing: card.look ? card.look.gap : 12
    }
}
