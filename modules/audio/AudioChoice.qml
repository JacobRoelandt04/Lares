pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix

// =============================================================================
// AudioChoice.qml -- what pavucontrol's combo boxes are: a short label and the current value in a carved field with a chevron. A click asks the popup for
// its one menu (`picked`); this owns no list.
// =============================================================================
Item {
    id: chip

    property string label: ""
    property string value: ""
    property string tip: ""
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property real fontSize: 11
    property color ground: Theme.listBox
    property real maxWidth: 240
    signal picked(Item from)

    readonly property real _labelW: labelMetrics.advanceWidth
    readonly property real _valueW: Math.min(valueMetrics.advanceWidth, chip.maxWidth - chip._labelW - 34)
    implicitWidth: Math.ceil(Math.min(chip.maxWidth, chip._labelW + chip._valueW + (chip.label !== "" ? 6 : 0) + 32))
    implicitHeight: 24
    opacity: chip.enabled ? 1 : 0.55

    TextMetrics {
        id: labelMetrics
        font.family: chip.fontFamily
        font.pixelSize: chip.fontSize
        text: chip.label
    }
    TextMetrics {
        id: valueMetrics
        font.family: chip.fontFamily
        font.pixelSize: chip.fontSize
        text: chip.value
    }

    property real _hover: area.containsMouse && chip.enabled ? 1 : 0
    Behavior on _hover {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    ShadowBox {
        anchors.fill: parent
        baseRadius: 7
        surfaceColor: chip.ground
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 2
    }
    Text {
        id: labelText
        x: 9
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        visible: chip.label !== ""
        font.family: chip.fontFamily
        font.pixelSize: chip.fontSize
        color: Theme.textFaint
    }
    Text {
        x: chip.label !== "" ? 9 + Math.ceil(chip._labelW) + 6 : 9
        width: chip.width - x - 22
        anchors.verticalCenter: parent.verticalCenter
        text: chip.value
        elide: Text.ElideRight
        font.family: chip.fontFamily
        font.pixelSize: chip.fontSize
        color: Mix.c(Theme.textPrimary, Theme.accent, chip._hover)
    }
    Chevron {
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        size: 11
        thickness: 1.6
        color: Mix.c(Theme.textFaint, Theme.accent, chip._hover)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: chip.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: chip.picked(chip)
    }
    HoverTip {
        show: area.containsMouse && chip.tip !== ""
        anchorItem: chip
        overlayItem: chip.overlayItem
        text: chip.tip
        fontFamily: chip.fontFamily
    }
}
