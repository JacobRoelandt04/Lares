import QtQuick

import ".."

// =============================================================================
// ApplyBar.qml -- Discard and Apply (accent) at the popup's foot, glued to the BOX's foot by its host. Its height is the buttons' own, fixed:
// whether the popup has room for it is the host's one step (`implicitHeight` includes it while an edit is staged) and the engine eases the box;
// the bar only fades in and out (`presence`, `style.fadeMs`), never a height.
// =============================================================================
Item {
    id: root

    property bool dirty: false
    property PanoramaStyle style: PanoramaStyle {}
    property string fontFamily: "Inter"

    signal applyClicked()
    signal discardClicked()

    property real presence: root.dirty ? 1 : 0
    Behavior on presence {
        NumberAnimation {
            duration: root.style.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    implicitWidth: 300
    implicitHeight: root.style.buttonHeight
    opacity: root.presence
    visible: root.presence > 0

    Row {
        anchors.right: parent.right
        spacing: 8
        PanoButton {
            text: "Discard"
            height: root.style.buttonHeight
            fontFamily: root.fontFamily
            enabled: root.dirty
            onClicked: root.discardClicked()
        }
        PanoButton {
            objectName: "applyButton"
            text: "Apply"
            accent: true
            height: root.style.buttonHeight
            fontFamily: root.fontFamily
            enabled: root.dirty
            onClicked: root.applyClicked()
        }
    }
}
