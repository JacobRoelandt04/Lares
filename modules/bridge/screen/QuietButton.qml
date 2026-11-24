pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// QuietButton.qml -- a button with no plate: words that are the control. Muted ink at rest, a short colour fade to the
// accent on hover and the hand cursor -- nothing else announces it (the shell's rule for a control that is rare or secondary:
// "Unmount", "Send files", "Unpair").
//
//   text         the words
//   inkColor     at rest;  hoverColor  under the pointer;  faintColor  while `available` is false
//   Colours are properties so a face painted on a fixed ground (the phone's back plate, which is not themed) hands its own.
//   bold         the words' weight
//   available    false: faint, no hand, a click does nothing (not `enabled`: a disabled item hears no hover, and a tip
//                that says WHY it is unavailable has to be heard)
//   tip          what it says on hover, also while it is unavailable (the reason), in `overlayItem` (HoverTip)
//
// The fade is a FRACTION mixed with Mix.js, never a colour animation (the theme is one clock).
// =============================================================================
Item {
    id: btn

    property string text: ""
    property string fontFamily: "Inter"
    property real fontPixelSize: 12
    property bool bold: false
    property color inkColor: Theme.textMuted
    property color hoverColor: Theme.accent
    property color faintColor: Theme.textFaint
    property int hoverMs: 120
    property int alignment: Text.AlignLeft
    property bool available: true
    property string tip: ""
    property Item overlayItem: null

    signal clicked

    implicitWidth: Math.ceil(label.implicitWidth)
    implicitHeight: Math.ceil(label.implicitHeight) + 8

    property real _hoverF: area.containsMouse && btn.available ? 1 : 0
    Behavior on _hoverF {
        NumberAnimation {
            duration: btn.hoverMs
            easing.type: Easing.OutCubic
        }
    }

    Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        horizontalAlignment: btn.alignment
        elide: Text.ElideRight
        text: btn.text
        color: btn.available ? Mix.c(btn.inkColor, btn.hoverColor, btn._hoverF) : btn.faintColor
        font.family: btn.fontFamily
        font.pixelSize: btn.fontPixelSize
        font.bold: btn.bold
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: btn.available ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (btn.available)
                btn.clicked();
        }
    }
    HoverTip {
        anchorItem: btn
        overlayItem: btn.overlayItem
        text: btn.tip
        show: area.containsMouse && btn.tip !== ""
    }
}
