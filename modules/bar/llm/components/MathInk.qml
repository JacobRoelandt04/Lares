import QtQuick

import "../../../common/theme"

// =============================================================================
// MathInk.qml -- a formula's picture, drawn as its alpha in ONE ink.
//
//   MathInk { source: result.url; ink: Theme.textPrimary; pw: result.w; ph: result.h }
//
// The picture MathRender made has no colour: white, with the formula's coverage as its alpha. This
// multiplies it by a colour in `shaders/icon_ink.frag` (the tray icons' ink shader), so the ink is a
// live binding to the text it sits in: a light/dark switch moves the colour and re-renders nothing,
// and a transcript with fifty formulas pays for no picture on a switch.
//
// The Image is the texture provider (no layer, no FBO resampled under a scale): `sourceSize` is the
// size it is SHOWN at in device pixels (`renderScale` x the logical size), which is the size the
// worker rendered it at, so nothing is resampled. `pw` x `ph` are the picture's logical size; the item
// is that size, and a host that must fit it to a width scales the ITEM (`scale`), never the source.
// =============================================================================
Item {
    id: root

    property url source
    property color ink: Theme.textPrimary
    property real pw: 1
    property real ph: 1
    property real renderScale: 1
    // Whether the picture is up (a host shows its fallback until then).
    readonly property bool ready: img.status === Image.Ready

    implicitWidth: root.pw
    implicitHeight: root.ph
    width: root.pw
    height: root.ph

    Image {
        id: img
        visible: false          // sampled by the effect: an invisible Image still provides its texture
        source: root.source
        sourceSize: Qt.size(Math.max(1, Math.round(root.pw * root.renderScale)),
                            Math.max(1, Math.round(root.ph * root.renderScale)))
        fillMode: Image.Stretch
        smooth: true
        cache: true
        asynchronous: false
    }
    ShaderEffect {
        anchors.fill: parent
        visible: img.status === Image.Ready
        property variant source: img
        property real inkMode: 1
        property color ink: root.ink
        fragmentShader: "../../../common/components/shaders/icon_ink.frag.qsb"
    }
}
