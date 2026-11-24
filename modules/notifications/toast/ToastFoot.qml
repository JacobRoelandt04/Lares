pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components/Mix.js" as Mix

// "+N more" under the toast stack: the notifications the stack pushed into
// the manager while it was full. The words are the link (no glyph, no box):
// faint at rest, the accent and the hand cursor on hover, and a click opens
// the manager where they are. Where it sits and whether it is there are the
// stack's (NotificationToast, THE FOOT): this is only the words.
Item {
    id: foot

    property int count: 0
    property string fontFamily: "Inter"
    property int fontPixelSize: 11
    // The hover's colour fade (the stack passes the style's footHoverMs).
    property int hoverMs: 120
    signal clicked()

    implicitHeight: Math.ceil(label.implicitHeight) + 4

    property real hoverF: area.containsMouse ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: foot.hoverMs
            easing.type: Easing.OutCubic
        }
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: "+" + foot.count + " more"
        textFormat: Text.PlainText
        color: Mix.c(Theme.textFaint, Theme.accent, foot.hoverF)
        font.family: foot.fontFamily
        font.pixelSize: foot.fontPixelSize
    }
    MouseArea {
        id: area
        anchors.fill: label
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: foot.clicked()
    }
}
