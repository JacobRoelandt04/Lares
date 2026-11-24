pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/glyphs"
import "../common/components/Mix.js" as Mix

// =============================================================================
// AudioGlyphButton.qml -- a Nerd Font glyph that is a button, in the bar's language: always shown, in the muted ink at rest, the audio
// pair's hover hue (BarHues.audioHover) under the pointer on the bar's ONE hover clock (GlyphHoverEase), the hand. Nothing else announces
// it. `on` holds it in the accent, a state worth showing (a muted output's crossed speaker, a running test tone). A danger glyph's hover
// is the error colour. A tip only where the glyph cannot say it.
// =============================================================================
Item {
    id: btn

    property string glyph: ""
    property bool on: false
    property bool danger: false
    property string tip: ""
    property Item overlayItem: null
    property real size: 15
    property string fontFamily: "Inter"
    signal clicked

    implicitWidth: 24
    implicitHeight: 24
    opacity: btn.enabled ? 1 : 0.45

    property real _hover: area.containsMouse && btn.enabled ? 1 : 0
    Behavior on _hover {
        GlyphHoverEase {}
    }
    Text {
        anchors.centerIn: parent
        text: btn.glyph
        font.family: "Symbols Nerd Font"
        font.pixelSize: btn.size
        font.bold: false
        color: Mix.c(btn.on ? Theme.accent : Theme.textMuted, btn.danger ? Theme.error : BarHues.audioHover, btn._hover)
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: btn.clicked()
    }
    HoverTip {
        show: area.containsMouse && btn.tip !== ""
        anchorItem: btn
        overlayItem: btn.overlayItem
        text: btn.tip
        fontFamily: btn.fontFamily
    }
}
