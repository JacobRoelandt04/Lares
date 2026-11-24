pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

// =============================================================================
// MockupTabPill -- a pill in a tab strip.
//
// Not bold when current: a weight change would change its width and shuffle
// the strip on every click. `marked` appends a * (a tab holding a value
// that differs from the file defaults); `small` is the sub-tab size.
// =============================================================================
Rectangle {
    id: pill

    property string text: ""
    property bool current: false
    property bool marked: false
    property bool small: false
    signal clicked()

    implicitWidth: pillLabel.implicitWidth + (pill.small ? 16 : 22)
    implicitHeight: pill.small ? 24 : 30
    radius: height / 2
    color: pill.current ? "#4480F4" : pillHover.hovered ? "#E1E4EB" : "#EAEDF5"
    border.color: pill.current ? "#4480F4" : "#CED1D7"
    border.width: 1

    Label {
        id: pillLabel
        anchors.centerIn: parent
        text: pill.text + (pill.marked ? " *" : "")
        color: pill.current ? "#EAEDF5" : "#5D5D5F"
        font.family: "Audiowide"
        font.pixelSize: pill.small ? 13 : 14
    }
    HoverHandler {
        id: pillHover
    }
    TapHandler {
        onTapped: pill.clicked()
    }
}
