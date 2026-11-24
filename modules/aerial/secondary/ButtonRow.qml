import QtQuick

// =============================================================================
// ButtonRow.qml -- buttons side by side, left to right in reading order, wrapping at the card's width. Its height is its content's
// (zero with no visible button, so an empty row takes no gap).
// =============================================================================
Flow {
    id: row
    spacing: 8
    width: parent ? parent.width : 0
}
