pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// SwitchRow.qml -- one on/off setting: its name at the left (a hover tip says what it is), the
// shell's GrooveToggle at the right, and under them, in the muted figure size, the one thing the
// person should know before flipping it. The toggle is bound to the FACT by the host (`checked`):
// it only asks (`toggled`), so a refused write leaves it where it was.
// =============================================================================
Item {
    id: row

    property SecondaryStyle look: null
    property Item overlay: null
    property string title: ""
    property string tip: ""
    property string hint: ""
    property bool checked: false

    signal toggled(bool checked)

    readonly property alias toggle: toggle

    readonly property string _family: row.look ? row.look.fontFamily : "Inter"
    readonly property real _headHeight: 22

    implicitHeight: Math.ceil(row._headHeight + (row.hint.length > 0 ? hintText.implicitHeight : 0))

    TipLabel {
        look: row.look
        overlay: row.overlay
        tip: row.tip
        text: row.title
        maxWidth: toggle.x - 12
        anchors.verticalCenter: head.verticalCenter
    }

    Item {
        id: head
        width: row.width
        height: row._headHeight
    }

    // The BALL is the toggle's salient ink, and it overhangs the groove's end by (ball - groove) / 2:
    // the toggle stands that far in from the column's edge, so its ball -- not its groove -- is
    // what lies on the margin the selectors' tracks and the figures end on.
    GrooveToggle {
        id: toggle
        x: row.width - width - (ballSize - grooveThickness) / 2
        y: Math.round((row._headHeight - height) / 2)
        checked: row.checked
        onToggled: c => row.toggled(c)
    }

    Text {
        id: hintText
        y: row._headHeight
        width: row.width
        visible: row.hint.length > 0
        height: visible ? implicitHeight : 0
        text: row.hint
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Theme.textMuted
        font.family: row._family
        font.pixelSize: row.look ? row.look.figureSize : 11
    }
}
