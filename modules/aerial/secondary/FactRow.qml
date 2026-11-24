import QtQuick

// =============================================================================
// FactRow.qml -- one fact: its name at the left in muted ink, its value at the right in primary ink, a fixed column between them so
// the values of a card start on one edge (the name takes `labelWidth`). A value that is empty takes no row (the row collapses by
// geometry: nothing is announced that is not known).
// =============================================================================
Item {
    id: row

    property PanelStyle look: null
    property string label: ""
    property string value: ""
    property real labelWidth: 96
    property bool wrapValue: true
    property int tone: 0

    readonly property bool shown: row.value !== ""
    width: parent ? parent.width : 0
    implicitHeight: row.shown ? Math.ceil(Math.max(nameText.implicitHeight, valueText.implicitHeight)) : 0
    visible: row.shown

    PText {
        id: nameText
        look: row.look
        tone: 1
        text: row.label
        width: row.labelWidth - 8
        elide: Text.ElideRight
    }
    PText {
        id: valueText
        look: row.look
        tone: row.tone
        text: row.value
        x: row.labelWidth
        width: Math.max(0, row.width - row.labelWidth)
        wrapMode: row.wrapValue ? Text.WrapAnywhere : Text.NoWrap
        elide: row.wrapValue ? Text.ElideNone : Text.ElideRight
    }
}
