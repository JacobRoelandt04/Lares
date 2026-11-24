pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// PanelCard.qml -- one carved container of an aerial panel: a ShadowBox (inset shadow inside the edge, light bevel outside) holding a
// column of blocks 12 px from every edge. Its height is its content's. A block that comes and goes collapses BY GEOMETRY as well as by
// `visible` (a Column does not hear a child whose `visible` flips under a hidden ancestor). The card never switches its OWN `visible` on
// its content's height (the content reads its effective visibility: a loop); only the box it draws is hidden when it holds nothing.
// =============================================================================
Item {
    id: card

    property PanelStyle look: null
    default property alias content: column.data
    readonly property real innerWidth: Math.max(0, card.width - 2 * card.pad)
    readonly property real pad: card.look ? card.look.cardPadding : 12
    // an empty card takes no room (a block of nothing is not a card)
    readonly property bool filled: column.implicitHeight > 0

    width: parent ? parent.width : 0
    implicitHeight: card.filled ? Math.ceil(column.implicitHeight + 2 * card.pad) : 0

    ShadowBox {
        anchors.fill: parent
        visible: card.filled
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
        spacing: card.look ? card.look.rowGap : 8
    }
}
