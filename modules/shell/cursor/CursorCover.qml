import QtQuick

// =============================================================================
// CursorCover -- keeps a window's pointer the plain arrow while ShellCursor.hover is off: one per window of the shell, filling it, above
// everything in it. With `hover` on it is not there and each item decides its own cursor.
//
// Qt 6.12 takes the window's cursor from the topmost VISIBLE item under the pointer that has one, enabled or not (CLAUDE.md, EVERY
// MouseArea OWNS AN ARROW CURSOR FROM BIRTH). So this area is disabled (it takes no press, wheel or hover; it draws nothing) and still
// decides the cursor of everything under it: no item has to know of the setting.
//
//   hidden   the pointer is not shown at all (the bridge's free look: GooeyEngine.pointerHidden). Decided HERE, since nothing under the
//            cover can.
//
// The switch is `visible`, never `cursorShape: undefined`: a reset area's cursor reads Arrow, and QQuickMouseArea ignores a shape equal to
// the one it reads, so the way back from the reset to Arrow would do nothing.
// =============================================================================
MouseArea {
    id: cursorCover

    property bool hidden: false

    enabled: false
    acceptedButtons: Qt.NoButton
    z: 200000
    visible: !ShellCursor.hover
    cursorShape: cursorCover.hidden ? Qt.BlankCursor : Qt.ArrowCursor
}
