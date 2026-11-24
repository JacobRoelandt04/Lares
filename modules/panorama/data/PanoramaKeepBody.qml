pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"

// =============================================================================
// PanoramaKeepBody.qml -- the keep toast's rich body: one line, the countdown.
//
//   Reverting in 12 s
//
// A VIEW of PanoramaKeepPrompt (`prompt`): the figure is the prompt's `secondsLeft`, ticking on the second from the deadline
// the service set when the toast reached the glass. The line's height is reserved from the first frame (the card does not grow
// when the figure arrives), the figure sits in DigitCells (a digit more or less moves nothing beside it), and the line fades
// in as ONE eased fraction (160 ms) once the countdown runs. The card's own body size and font, as the other rich bodies
// (MuxKeepBody).
// =============================================================================
Item {
    id: root

    property var prompt: null
    property var hostCard: null

    readonly property string fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
    readonly property int textSize: root.hostCard && root.hostCard._bodySize ? root.hostCard._bodySize : 12
    readonly property bool running: !!root.prompt && root.prompt.secondsLeft >= 0

    property real _fp: root.running ? 1 : 0
    Behavior on _fp {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    implicitHeight: Math.ceil(label.implicitHeight)

    Row {
        opacity: root._fp
        spacing: 4
        Text {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            text: "Reverting in"
            textFormat: Text.PlainText
            color: Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: root.textSize
        }
        DigitCells {
            anchors.verticalCenter: parent.verticalCenter
            text: root.running ? String(root.prompt.secondsLeft) : "0"
            fontFamily: root.fontFamily
            pixelSize: root.textSize
            bold: false
            color: Theme.textMuted
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "s"
            textFormat: Text.PlainText
            color: Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: root.textSize
        }
    }
}
