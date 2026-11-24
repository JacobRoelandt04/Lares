pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// DeviceName.qml -- the device's name as the screen's heading (16 bold, centred), and the way to the other devices: a click
// opens the device menu (the owner's FloatingMenu in the overlay). The hand cursor and a short fade of the ink to the accent
// are the only announcement; the small chevron after the name is drawn only when there is more than one device to go to.
//
//   name         the heading
//   more         more than one device exists: the chevron is drawn
//   opened()     a click: the host opens its menu at this item
// =============================================================================
Item {
    id: heading

    property string name: ""
    property bool more: false
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}

    signal opened

    implicitHeight: Math.ceil(nameText.implicitHeight)

    property real _hoverF: area.containsMouse ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: heading.style.hoverMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property real _chevronRoom: heading.more ? chevron.width + heading.style.headerGap : 0
    readonly property real _textW: Math.min(Math.ceil(nameText.implicitWidth), Math.max(0, heading.width - heading._chevronRoom))
    readonly property real _blockW: heading._textW + heading._chevronRoom
    readonly property real _blockX: Math.round((heading.width - heading._blockW) / 2)

    Text {
        id: nameText
        x: heading._blockX
        width: heading._textW
        elide: Text.ElideRight
        text: heading.name
        color: Mix.c(Theme.textPrimary, Theme.accent, heading._hoverF)
        font.family: heading.fontFamily
        font.pixelSize: heading.style.nameSize
        font.bold: true
    }
    Chevron {
        id: chevron
        visible: heading.more
        x: heading._blockX + heading._textW + heading.style.headerGap
        y: Math.round(nameText.y + (nameText.height - height) / 2) + 1
        size: heading.style.chevronSize
        color: Mix.c(Theme.textFaint, Theme.accent, heading._hoverF)
    }
    MouseArea {
        id: area
        x: heading._blockX - heading.style.headerHitSlack
        width: heading._blockW + 2 * heading.style.headerHitSlack
        height: heading.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: heading.opened()
    }
}
