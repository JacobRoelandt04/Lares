pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "popup"

// =============================================================================
// MuxKeepBody.qml -- the keep prompt toast's rich body: one line, the guard's clock.
//
//   Going back in 1:47
//
// A VIEW of MuxKeepPrompt (`prompt`): the figure is the prompt's own `countdownText` (the guard's clock, ticking on the
// second) and it shows once the prompt says so (`figureShown`: the helper's shortened window has landed, so the line never
// flashes the long boot window down to the prompt's). The line's height is reserved from the first frame, so the card does
// not grow when the figure arrives; the figure sits in a slot of fixed width (FigureSlot: a digit more or less moves
// nothing) and the line fades in as ONE eased fraction (160 ms).
//
// Drop-in rules as the card's other rich bodies (UpdateNudgeBody): sized by its own implicitHeight, a width it is given, no
// assumption about the host beyond `hostCard`'s optional font; the two sizes are the card's own body size.
// =============================================================================
Item {
    id: root

    property var prompt: null
    property var hostCard: null

    readonly property string fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
    readonly property int textSize: root.hostCard && root.hostCard._bodySize ? root.hostCard._bodySize : 12

    readonly property bool figureShown: !!root.prompt && root.prompt.figureShown === true
    readonly property string figureText: root.prompt ? String(root.prompt.countdownText) : ""

    property real _fp: root.figureShown ? 1 : 0
    Behavior on _fp {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    implicitHeight: Math.ceil(Math.max(label.implicitHeight, slot.implicitHeight))

    Row {
        id: row
        opacity: root._fp
        spacing: 5
        Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            text: "Going back in"
            textFormat: Text.PlainText
            color: Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: root.textSize
        }
        FigureSlot {
            id: slot
            anchors.verticalCenter: parent.verticalCenter
            text: root.figureText
            template: "0:00"
            align: Text.AlignLeft
            fontFamily: root.fontFamily
            pixelSize: root.textSize
        }
    }
}
