import QtQuick
import "../common/components"
import "../common/theme"

// the module's content root
Item {
    id: popup
    property real width0: 100
    property string fontFamily: "Inter"
    property real titleSize: 16     // 16 px at the shell's scale
    property var rules: ({
        "a": 1
    })
    property string rulesText: "{}"
    property string side: "far"
    property string weird: "q"
    property int mode: 0
    property SharedStyle style: SharedStyle {}
    readonly property alias boxA: firstBox
    readonly property alias boxB: secondBox
    readonly property alias part: ownedPart
    readonly property alias holder: sharedHolder
    readonly property alias field: poleField
    implicitWidth: popup.width0

    component Field: OwnedPart {
        size: 4
    }

    SharedBox {
        id: firstBox
        anchors.fill: parent
    }
    SharedBox {
        id: secondBox
        gap: 7
        label: "second"
    }
    OwnedPart {
        id: ownedPart
    }
    SharedHolder {
        id: sharedHolder
    }
    Field {
        id: poleField
    }
}
