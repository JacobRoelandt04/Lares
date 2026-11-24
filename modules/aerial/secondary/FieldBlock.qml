import QtQuick

// =============================================================================
// FieldBlock.qml -- a labelled field: the name in muted figure-size ink over a PanelField. Collapses by geometry when `shown` is
// false (a Column keeps the gap of a visible child of zero height, so a hidden block also takes none: the host's spacing is the gap
// BETWEEN blocks, and a block with no height has none -- see `shown` users, which are always Columns with `spacing`).
// =============================================================================
Item {
    id: block

    property PanelStyle look: null
    property string label: ""
    property bool shown: true
    property alias text: edit.text
    property alias placeholder: edit.placeholder
    property alias secret: edit.secret
    property alias revealed: edit.revealed
    property alias inputMethodHints: edit.inputMethodHints
    property alias validator: edit.validator
    property alias fieldObjectName: edit.objectName
    readonly property alias field: edit

    signal accepted()
    signal edited(string text)

    width: parent ? parent.width : 0
    implicitHeight: block.shown ? Math.ceil(lab.implicitHeight + 3 + edit.implicitHeight) : 0
    visible: block.shown

    PText {
        id: lab
        look: block.look
        tone: 1
        small: true
        text: block.label
    }
    PanelField {
        id: edit
        look: block.look
        y: Math.ceil(lab.implicitHeight) + 3
        onAccepted: block.accepted()
        onEdited: t => block.edited(t)
    }
}
