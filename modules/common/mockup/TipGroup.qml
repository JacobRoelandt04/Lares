pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// TipGroup -- a heading that separates one group of parameters from the next.
//
// A rule, the group's title and an optional blurb. ParamList and ColorList
// emit one automatically from the first entry of each `group`; a custom page
// places them by hand between its own rows.
// =============================================================================
ColumnLayout {
    id: group

    property string title: ""
    property string blurb: ""

    Layout.fillWidth: true
    Layout.topMargin: 8
    spacing: 2

    Rectangle {
        Layout.fillWidth: true
        Layout.bottomMargin: 3
        implicitHeight: 1
        color: "#CED1D7"
    }
    Label {
        text: group.title
        color: "#5D5D5F"
        font.family: "Audiowide"
        font.pixelSize: 15
        font.bold: true
    }
    Label {
        text: group.blurb
        visible: text.length > 0
        color: "#8A8A8C"
        font.family: "Audiowide"
        font.pixelSize: 13
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }
}
