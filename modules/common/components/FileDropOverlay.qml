pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import "../theme"

// =============================================================================
// FileDropOverlay.qml -- what a surface shows while a file hovers it.
//
// A carved square grows out of the centre -- fill translucent, bevel and inset
// shadow at full strength, so what appears is an EDGE drawn onto the content
// rather than a card over it -- with the drop glyph in the middle casting its
// shadow down through the box onto what is below. Every drop target in the
// shell (the LLM popup's attach drop among them) uses it, so they all look the
// same.
//
// The host owns the DropArea (it knows its own geometry and what it accepts)
// and drives this with ONE eased presence fraction, `presence` (0..1):
// scale and opacity move together on it. `refuse()` gives a short sideways
// shake -- the answer to a drop that was not accepted.
// =============================================================================
Item {
    id: overlay

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    property real presence: 0
    property real radius: 14
    property string glyph: "\uF019"
    property color surfaceColor: Theme.surface
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color glyphColor: Theme.textPrimary
    property color glyphShadowColor: Theme.shadowDeep
    property real fillAlpha: 0.55

    visible: overlay.presence > 0.01 || shake.running
    opacity: overlay.presence
    scale: 0.86 + 0.14 * overlay.presence
    transformOrigin: Item.Center

    function refuse() {
        shake.restart();
    }

    property real _dx: 0
    transform: Translate {
        x: overlay._dx
    }
    SequentialAnimation {
        id: shake
        NumberAnimation {
            target: overlay
            property: "_dx"
            to: -8
            duration: 45
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            target: overlay
            property: "_dx"
            to: 7
            duration: 70
            easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            target: overlay
            property: "_dx"
            to: -4
            duration: 60
            easing.type: Easing.InOutQuad
        }
        NumberAnimation {
            target: overlay
            property: "_dx"
            to: 0
            duration: 50
            easing.type: Easing.OutQuad
        }
    }

    ShadowBox {
        anchors.fill: parent
        baseWidth: overlay.width
        baseHeight: overlay.height
        baseRadius: overlay.radius
        surfaceColor: "transparent"
        bevelColor: overlay.bevelColor
        shadowColor: overlay.shadowColor
        backgroundColor: Qt.rgba(overlay.surfaceColor.r, overlay.surfaceColor.g, overlay.surfaceColor.b, overlay.fillAlpha)
        bevelWidth: 1.5
        shadowWidth: 5
    }

    // The glyph's shadow: a blurred dark copy sunk below it, so the mark
    // reads as floating at the box's height.
    Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: 7
        text: overlay.glyph
        font.family: "Symbols Nerd Font"
        font.pixelSize: 46
        color: overlay.glyphShadowColor
        opacity: 0.4
        layer.enabled: true
        layer.textureSize: dev.texSize(width, height)
        layer.effect: MultiEffect {
            blurEnabled: true
            blur: 0.7
            blurMax: 16
        }
    }
    Text {
        anchors.centerIn: parent
        text: overlay.glyph
        font.family: "Symbols Nerd Font"
        font.pixelSize: 46
        color: overlay.glyphColor
    }
}
