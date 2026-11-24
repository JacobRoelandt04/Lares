pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// SwitchRow.qml -- one on / off setting: its name at the left, the shell's GrooveToggle at the right and, under them in the muted
// figure size, the one thing the person should know. The toggle is bound to the FACT by the host (`checked`) and only asks
// (`toggled`), so a refused write leaves it where it was.
// =============================================================================
Item {
    id: row

    property PanelStyle look: null
    property string title: ""
    property string hint: ""
    property bool checked: false
    property color ground: Theme.listBox

    signal toggled(bool checked)

    readonly property alias toggle: toggle
    readonly property real _head: 24

    width: parent ? parent.width : 0
    implicitHeight: Math.ceil(row._head + (row.hint !== "" ? hintText.implicitHeight : 0))

    PText {
        look: row.look
        text: row.title
        width: toggle.x - 12
        elide: Text.ElideRight
        y: Math.round((row._head - implicitHeight) / 2)
    }
    GrooveToggle {
        id: toggle
        // the BALL is the ink that overhangs the groove: the ball, not the groove, lies on the column's edge
        x: row.width - width - (ballSize - grooveThickness) / 2
        y: Math.round((row._head - height) / 2)
        checked: row.checked
        surfaceColor: row.ground
        onToggled: c => row.toggled(c)
    }
    PText {
        id: hintText
        look: row.look
        tone: 1
        small: true
        y: row._head
        width: row.width
        shown: row.hint !== ""
        text: row.hint
        wrapMode: Text.WordWrap
    }
}
