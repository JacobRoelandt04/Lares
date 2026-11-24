import QtQuick

import "../theme"

// =============================================================================
// TrayInk.qml -- an icon, drawn as its alpha in one ink, or as it is.
//
//   TrayInk { source: item.iconSource; size: 18; ink: Theme.textMuted; renderScale: 1 }
//
// `mode` "ink" (default): `ink * alpha`, so a light-on-dark panel icon from a
// theme made for another bar reads on eva-light, and a state is a colour the
// host mixes (hover -> accent, attention -> warn, passive -> faint) with Mix.js
// and hands here. "colour": the image as the theme drew it.
//
// THE IMAGE IS THE TEXTURE PROVIDER, NO LAYER: a ShaderEffect samples the Image
// directly (shaders/icon_ink.frag). A layer would be an FBO at the item's own
// pixel size, resampled under any scale. `sourceSize` is `size * renderScale`,
// the device pixels the icon covers, so nothing is resampled and a host that
// shows the bar at another scale passes it in. Place the item on whole pixels
// (the host's job); the item itself is `Math.round(size)` square.
//
// Changing `source` (nm-applet's animation changes ONE icon url, never a model)
// loads the next image; the old one stays drawn until it is ready -- an Image
// keeps its texture while a new source loads.
// =============================================================================
Item {
    id: root

    property url source
    property real size: 16
    // "ink" | "colour"
    property string mode: "ink"
    property color ink: Theme.textPrimary
    property real renderScale: 1
    // Load off the GUI thread (a themed icon is a file or a provider's pixmap).
    property bool asynchronous: false

    readonly property bool ready: img.status === Image.Ready

    implicitWidth: Math.round(root.size)
    implicitHeight: Math.round(root.size)

    Image {
        id: img
        // Sampled by the effect below. Not `visible: false` in the scene graph's
        // sense: an invisible Image still provides its texture.
        visible: false
        source: root.source
        sourceSize: Qt.size(Math.max(1, Math.ceil(root.implicitWidth * root.renderScale)),
                            Math.max(1, Math.ceil(root.implicitHeight * root.renderScale)))
        fillMode: Image.PreserveAspectFit
        asynchronous: root.asynchronous
        smooth: true
        cache: true
    }
    ShaderEffect {
        anchors.fill: parent
        visible: img.status === Image.Ready
        property variant source: img
        property real inkMode: root.mode === "colour" ? 0 : 1
        property color ink: root.ink
        fragmentShader: "shaders/icon_ink.frag.qsb"
    }
}
