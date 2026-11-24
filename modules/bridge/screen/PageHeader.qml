pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// PageHeader.qml -- the chrome of a page that grew out of a tile: a back chevron and the page's title (16 bold). The whole
// strip is the way back; the pointer is the only announcement (the hand cursor and a short fade of the chevron to the accent).
//
//   title, fontFamily, style    the words; the BridgeStyle (every number is read from it)
//   back()                      a click anywhere on the strip
//
// The chrome belongs to its page: it is drawn inside the page, so it moves, scales and fades with it.
// =============================================================================
Item {
    id: header

    property string title: ""
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}

    signal back

    implicitHeight: header.style.pageHeaderHeight

    property real _hoverF: area.containsMouse ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: header.style.hoverMs
            easing.type: Easing.OutCubic
        }
    }

    Chevron {
        id: chevron
        x: 0
        y: Math.round((header.height - height) / 2)
        size: header.style.chevronSize
        rotation: 90
        color: Mix.c(Theme.textMuted, Theme.accent, header._hoverF)
    }
    Text {
        id: titleText
        x: chevron.width + header.style.headerGap
        anchors.verticalCenter: parent.verticalCenter
        text: header.title
        color: Theme.textPrimary
        font.family: header.fontFamily
        font.pixelSize: header.style.titleSize
        font.bold: true
    }
    MouseArea {
        id: area
        x: -header.style.headerHitSlack
        width: chevron.width + header.style.headerGap + titleText.implicitWidth + 2 * header.style.headerHitSlack
        height: header.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: header.back()
    }
}
