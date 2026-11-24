pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// LogTailBody.qml -- the tail of a journal on a card (the failed-unit card's rich body).
//
//   lines      the tail, oldest first: the last one is the newest and stands in the primary colour, the rest muted
//   hostCard   handed in by the card
//
// A box carved into the card's own ground, in the shell's terminal face (Consolas), the newest line at the foot as
// `journalctl -n` prints it -- the line that says why a unit failed is nearly always the last, and a card clamps its body
// text from the top. A line is cut at the box's edge, never wrapped (a log line is a row of fields). A drop-in: sized by
// its own implicitHeight and a width it is given; text and one ShadowBox, so no layer, no canvas, no decoded image.
// =============================================================================
Item {
    id: root

    property var lines: []
    property var hostCard: null

    readonly property int _pad: 8
    readonly property int _lineH: Math.ceil(fm.height)
    // The box's own height, and 2 px of room above and below for the bevel it draws outside its edge.
    readonly property int _boxH: root.lines.length > 0 ? root.lines.length * root._lineH + 2 * root._pad : 0
    implicitHeight: root._boxH > 0 ? root._boxH + 4 : 0

    FontMetrics {
        id: fm
        font.family: "Consolas"
        font.pixelSize: 11
    }

    ShadowBox {
        x: 0
        y: 2
        width: root.width
        height: root._boxH
        visible: root._boxH > 0
        baseRadius: 8
        surfaceColor: Theme.listBox
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    Column {
        x: root._pad
        y: 2 + root._pad
        width: root.width - 2 * root._pad
        Repeater {
            model: root.lines
            Text {
                id: ln
                required property int index
                required property string modelData
                width: parent ? parent.width : 0
                height: root._lineH
                text: ln.modelData
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                color: ln.index === root.lines.length - 1 ? Theme.textPrimary : Theme.textMuted
                font.family: "Consolas"
                font.pixelSize: 11
            }
        }
    }
}
