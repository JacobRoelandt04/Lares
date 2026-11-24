pragma ComponentBehavior: Bound

import QtQuick
import "../../common/theme"
import "../../common/components" as Common
import "../../common/components/Mix.js" as Mix

// =============================================================================
// MonthHeader.qml
//
// Bottom-of-calendar label + nav controls:
//   - Left:  "<MonthName> <Year>".
//   - Right: prev / next chevrons -- emit step(±1), or step(±12) while
//            `yearModifier` is held: the modifier turns every month step
//            into a year step, here as on the swipe and PgUp/PgDn.
//            Left of them, only while `todayShown`, the way back to today:
//            emits returnToToday(). It fades in and out beside the arrows
//            and never moves them.
// =============================================================================
Item {
    id: root

    property int viewYear:  (new Date()).getFullYear()
    property int viewMonth: (new Date()).getMonth()

    property color textColor:   Theme.textPrimary
    property color hoverColor:  Theme.accent

    property int monthLabelPxSize: 16
    property string fontFamily: "Audiowide"
    property int yearModifier: Qt.ControlModifier
    // The host's call: today is neither on screen nor selected.
    property bool todayShown: false

    signal step(int months)
    signal returnToToday()

    implicitHeight: 40
    implicitWidth: 300

    readonly property var _monthNames: [
        "January","February","March","April","May","June",
        "July","August","September","October","November","December"
    ]

    Row {
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        Text {
            text: root._monthNames[root.viewMonth]
            color: root.textColor
            font.pixelSize: root.monthLabelPxSize
            font.family: root.fontFamily
            font.bold: true
        }
        Text {
            text: root.viewYear
            color: root.textColor
            font.pixelSize: root.monthLabelPxSize
            font.family: root.fontFamily
            font.bold: true
        }
    }

    component NavChevron: Item {
        id: nav
        // -1 = previous (points left), +1 = next (points right).
        required property int dir
        width: 28
        height: 28

        // The hover is a fraction, eased; the colour is a mix of the two
        // themed ends, so nothing here runs a clock of its own on a colour.
        property real _hoverF: hit.containsMouse ? 1 : 0
        Behavior on _hoverF {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }

        Common.Chevron {
            x: Math.round((nav.width - width) / 2)
            y: Math.round((nav.height - height) / 2)
            rotation: nav.dir < 0 ? 90 : -90
            color: Mix.c(root.textColor, root.hoverColor, nav._hoverF)
        }
        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => root.step(nav.dir * ((mouse.modifiers & root.yearModifier) ? 12 : 1))
        }
    }

    // Back to today: a calendar glyph (md-calendar_today), placed by x at the
    // arrows' left so its presence moves nothing.
    Item {
        id: todayBtn
        objectName: "monthHeaderToday"
        width: 28
        height: 28
        x: Math.round(navRow.x - navRow.spacing - width)
        y: Math.round((root.height - height) / 2)

        property real _shownF: root.todayShown ? 1 : 0
        Behavior on _shownF {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        property real _hoverF: todayHit.containsMouse ? 1 : 0
        Behavior on _hoverF {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        opacity: todayBtn._shownF
        visible: todayBtn._shownF > 0.001
        enabled: root.todayShown

        Text {
            x: Math.round((todayBtn.width - implicitWidth) / 2)
            y: Math.round((todayBtn.height - implicitHeight) / 2)
            text: "\u{F00F6}"
            color: Mix.c(root.textColor, root.hoverColor, todayBtn._hoverF)
            font.family: "Symbols Nerd Font"
            font.pixelSize: 15
        }
        MouseArea {
            id: todayHit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.returnToToday()
        }
    }

    Row {
        id: navRow
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        NavChevron {
            dir: -1
        }
        NavChevron {
            dir: 1
        }
    }
}
