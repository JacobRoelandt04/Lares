pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components/Mix.js" as Mix

// =============================================================================
// PlusButton.qml -- an "add" affordance as a glyph, not a button: two
// round-capped strokes, the Chevron's weight, in the muted ink. Nothing
// announces it but the pointer -- a short colour fade to the accent and the
// hand cursor -- which is the shell's rule for a control that sits beside a
// title (the timers' presets, the alarms).
// =============================================================================
Item {
    id: plus

    property real size: 14
    property real thickness: 2
    property color color: Theme.textMuted
    property color hoverColor: Theme.accent
    property color disabledColor: Theme.textFaint
    // Extra hit area around the glyph, px.
    property real hitSlack: 6

    signal clicked()

    implicitWidth: Math.ceil(plus.size)
    implicitHeight: Math.ceil(plus.size)

    property real _hoverF: hit.containsMouse && plus.enabled ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    readonly property color _ink: plus.enabled ? Mix.c(plus.color, plus.hoverColor, plus._hoverF) : plus.disabledColor

    Rectangle {
        width: plus.size
        height: plus.thickness
        radius: height / 2
        x: (plus.width - width) / 2
        y: (plus.height - height) / 2
        color: plus._ink
    }
    Rectangle {
        width: plus.thickness
        height: plus.size
        radius: width / 2
        x: (plus.width - width) / 2
        y: (plus.height - height) / 2
        color: plus._ink
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        anchors.margins: -plus.hitSlack
        hoverEnabled: true
        enabled: plus.enabled
        cursorShape: plus.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: plus.clicked()
    }
}
