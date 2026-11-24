pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// PickRow.qml -- one row of a list you pick from: a title and a muted line under it at the left, a figure at the right, a chevron
// when it opens something. The whole row is the hit area (the hand cursor and a short fade of the sunk fill are all that announce it).
// =============================================================================
Item {
    id: row

    property PanelStyle look: null
    property string title: ""
    property string sub: ""
    property string figure: ""
    property int figureTone: 1
    property bool chevron: false
    property bool selected: false
    property color ground: Theme.listBox

    signal clicked()

    readonly property bool hovered: area.containsMouse
    property real _hover: row.hovered ? 1 : 0
    Behavior on _hover {
        NumberAnimation { duration: row.look ? row.look.fadeMs : 160 }
    }

    width: parent ? parent.width : 0
    implicitHeight: row.sub !== "" ? 38 : 30

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: Mix.c(row.ground, Theme.panelSunk, Math.max(row._hover, row.selected ? 1 : 0))
    }
    PText {
        look: row.look
        x: 8
        y: row.sub !== "" ? 3 : Math.round((row.height - implicitHeight) / 2)
        width: parent.width - 16 - rightText.width - (row.chevron ? 16 : 0)
        elide: Text.ElideRight
        text: row.title
    }
    PText {
        look: row.look
        tone: 1
        small: true
        x: 8
        y: 20
        width: parent.width - 16 - rightText.width - (row.chevron ? 16 : 0)
        elide: Text.ElideRight
        visible: row.sub !== ""
        text: row.sub
    }
    PText {
        id: rightText
        look: row.look
        tone: row.figureTone
        small: true
        x: parent.width - 8 - implicitWidth - (row.chevron ? 16 : 0)
        y: Math.round((row.height - implicitHeight) / 2)
        text: row.figure
    }
    Chevron {
        visible: row.chevron
        x: parent.width - 20
        y: Math.round((row.height - height) / 2)
        size: 12
        rotation: -90
        color: Theme.textMuted
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.clicked()
    }
}
