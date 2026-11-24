import QtQuick

import "../../common/theme"

// =============================================================================
// ChoiceField.qml -- a one-of-few fact. With two or more options it is a ChoiceBar; with ONE it is not a choice, so it is plain body text (no
// selector, no accent).
// =============================================================================
Item {
    id: field

    property var options: []
    property string current: ""
    property string fontFamily: "Inter"
    property real fontSize: 11
    property real bodySize: 12

    signal chosen(string key)

    ChoiceBar {
        anchors.fill: parent
        visible: field.options.length > 1
        options: field.options
        current: field.current
        fontFamily: field.fontFamily
        fontSize: field.fontSize
        onChosen: k => field.chosen(k)
    }
    Text {
        visible: field.options.length <= 1
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        elide: Text.ElideRight
        text: field.options.length ? field.options[0].label : ""
        color: Theme.textPrimary
        font.family: field.fontFamily
        font.pixelSize: field.bodySize
    }
}
