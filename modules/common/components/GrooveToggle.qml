pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// GrooveToggle.qml -- an on/off switch in the shell's material: a short
// carved groove with a ball in it, the Workspaces motif at the size of a
// control. Off: the ball rests at the left in the bare groove. On: it rolls
// right and the accent FILLS THE GROOVE BEHIND IT -- the same carve in the
// accent's colours, cut under the ball, as the update popup's rail is. The
// groove never changes colour as a whole: the fill is where the ball has
// been.
//
// One clock: `position` (0..1, eased) places the ball and so the fill's
// edge. It is public so a host can follow the switch with anything of its
// own -- the alarm row fades its time's ink on it -- instead of flipping
// that at the click.
//
// THE BOX IS THE GROOVE, side to side: its carved ends are the item's edges,
// and its bevel paints outside them as every ShadowBox's does -- so a host
// that sets the toggle flush at a margin has its ink ON that margin, not 2 px
// inside it as a box padded for the bevel would put it. The ball rides the
// groove's rounded ends and overhangs them by (ballSize - grooveThickness) / 2,
// as a ball in a groove does; the height keeps the ball's room.
// =============================================================================
Item {
    id: toggle

    property bool checked: false
    signal toggled(bool checked)

    readonly property alias position: toggle._on

    property real trackWidth: 34
    property real grooveThickness: 8
    property real ballSize: 14
    property int moveMs: 180

    // What the toggle stands on: the ground its rim fades into.
    property color surfaceColor: Theme.listBox
    property color grooveColor: Theme.panelSunk
    property color shadowColor: Theme.border
    property color bevelColor: Theme.bevel
    property color onColor: Theme.accent
    property real fillShadowDarken: 1.35
    property color ballColor: Theme.buttonPlateau
    property color ballHoverColor: Theme.buttonPlateauHover
    property color ballShadowColor: Theme.buttonShadow

    implicitWidth: toggle.trackWidth
    implicitHeight: Math.max(toggle.ballSize, toggle.grooveThickness) + 4

    property real _on: toggle.checked ? 1 : 0
    Behavior on _on {
        NumberAnimation {
            duration: toggle.moveMs
            easing.type: Easing.OutCubic
        }
    }
    property real _hover: hit.containsMouse ? 1 : 0
    Behavior on _hover {
        NumberAnimation {
            duration: 120
        }
    }

    readonly property real _x0: toggle.grooveThickness / 2
    readonly property real _x1: toggle.width - toggle.grooveThickness / 2
    readonly property real _cy: toggle.height / 2
    readonly property real _ballX: toggle._x0 + (toggle._x1 - toggle._x0) * toggle._on

    ShadowBox {
        id: groove
        y: Math.round(toggle._cy - toggle.grooveThickness / 2)
        baseWidth: toggle.width
        baseHeight: toggle.grooveThickness
        baseRadius: toggle.grooveThickness / 2
        surfaceColor: toggle.surfaceColor
        backgroundColor: toggle.grooveColor
        bevelColor: toggle.bevelColor
        shadowColor: toggle.shadowColor
        bevelWidth: 1
        shadowWidth: 2.5
    }

    // The fill: the same groove in the accent's colours, cut at the ball's
    // centre -- which the ball covers, so the cut is never seen. The clip
    // starts the bevel's slack (2 px) left of the groove, whose carved end
    // is the item's edge: a clip on that edge would shear the fill's bevel.
    Item {
        x: -2
        y: 0
        width: Math.max(0, toggle._ballX + 2)
        height: toggle.height
        clip: true
        ShadowBox {
            x: groove.x + 2
            y: groove.y
            baseWidth: groove.baseWidth
            baseHeight: groove.baseHeight
            baseRadius: groove.baseRadius
            surfaceColor: toggle.surfaceColor
            backgroundColor: toggle.onColor
            bevelColor: toggle.bevelColor
            shadowColor: Qt.darker(toggle.onColor, toggle.fillShadowDarken)
            bevelWidth: 1
            shadowWidth: 2.5
        }
    }

    // The ball: a raised plateau riding the groove.
    ShadowBox {
        x: Math.round(toggle._ballX - toggle.ballSize / 2)
        y: Math.round(toggle._cy - toggle.ballSize / 2)
        baseWidth: toggle.ballSize
        baseHeight: toggle.ballSize
        baseRadius: toggle.ballSize / 2
        raised: true
        surfaceColor: toggle.grooveColor
        backgroundColor: Mix.c(toggle.ballColor, toggle.ballHoverColor, toggle._hover)
        bevelColor: Theme.buttonBevel
        shadowColor: toggle.ballShadowColor
        shadowToAlpha: true
        bevelWidth: 1
        shadowWidth: 2.5
    }

    MouseArea {
        id: hit
        anchors.fill: parent
        anchors.margins: -4
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: toggle.toggled(!toggle.checked)
    }
}
