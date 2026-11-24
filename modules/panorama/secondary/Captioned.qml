import QtQuick

import "../../common/theme"

// =============================================================================
// Captioned.qml -- a caption (muted, figure size: the aerial panels' field label) over a control, with an optional `note` on the right in faint
// ink. It collapses to nothing by its HEIGHT when `shown` is false (a positioner hears a size change, never a `visible` flip under a hidden
// ancestor), and the host's content steps to the final height in one turn: nothing here animates a height (the engine eases the box).
// =============================================================================
Item {
    id: root

    property string title: ""
    property string note: ""
    property bool noteMuted: false
    property bool shown: true
    property bool half: false                      // one of two columns in the FactGrid (else the whole row)
    property string fontFamily: "Inter"
    property real figureSize: 11
    property real gap: 12                          // above the caption (the space between two blocks)
    property real captionGap: 6                    // between the caption and the control
    default property alias content: body.data

    readonly property real _capH: root.title !== "" ? Math.ceil(capMetrics.height) : 0
    readonly property real _bodyH: body.childrenRect.height
    implicitHeight: root.shown ? Math.ceil(root.gap + root._capH + (root._capH > 0 ? root.captionGap : 0) + root._bodyH) : 0
    height: implicitHeight
    clip: !root.shown

    FontMetrics {
        id: capMetrics
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    Text {
        y: root.gap
        width: root.width
        elide: Text.ElideRight
        text: root.title
        color: Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
        font.bold: true
        visible: root.shown
    }
    Text {
        y: root.gap
        x: root.width - width
        text: root.note
        color: root.noteMuted ? Theme.textFaint : Theme.textMuted
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
        visible: root.shown && root.note !== ""
    }
    Item {
        id: body
        y: root.gap + root._capH + (root._capH > 0 ? root.captionGap : 0)
        width: root.width
        visible: root.shown
    }
}
