pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// AudioRenameField.qml -- a device's name, being edited. Enter keeps it, Escape leaves it; empty gives the device its own name back. The popup asks for the
// keyboard while this exists (its `keyboardFocusRequest`).
// =============================================================================
Item {
    id: field

    property string text: ""
    property string fontFamily: "Inter"
    property real fontSize: 12
    signal accepted(string text)
    signal cancelled

    ShadowBox {
        anchors.fill: parent
        baseRadius: 6
        surfaceColor: Theme.panelSunk
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 2
    }
    TextInput {
        id: input
        objectName: "renameInput"
        x: 8
        width: parent.width - 16
        anchors.verticalCenter: parent.verticalCenter
        text: field.text
        font.family: field.fontFamily
        font.pixelSize: field.fontSize
        color: Theme.textPrimary
        selectionColor: Theme.accent
        selectedTextColor: Theme.textOnAccent
        clip: true
        focus: true
        selectByMouse: true
        Component.onCompleted: {
            input.forceActiveFocus();
            input.selectAll();
        }
        onAccepted: field.accepted(input.text)
        Keys.onEscapePressed: field.cancelled()
    }
}
