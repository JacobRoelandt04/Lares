import QtQuick

// =============================================================================
// RoundedImage.qml -- an Image with rounded corners.
//
// The Image is never drawn itself: a ShaderEffect samples its texture (an
// Image is a texture provider -- no layer, no FBO, nothing resampled) and
// cuts it to a rounded rectangle with an exact distance and a one-pixel
// area coverage (shaders/image_round.frag). Four identical corners need a
// box on whole pixels; the host places it there.
//
// `sourceSize` is the host's business, but it must not follow the displayed
// size: a new sourceSize is a new decode, the image is blank until it lands,
// and a popup being resized re-decodes on every step, which flickers the
// image. Decode once, large; `mipmap`
// makes the downscale clean.
// =============================================================================
Item {
    id: ri

    property alias source: img.source
    property alias sourceSize: img.sourceSize
    property alias asynchronous: img.asynchronous
    property alias cache: img.cache
    readonly property alias status: img.status
    readonly property alias image: img
    property real radius: 8

    implicitWidth: img.implicitWidth
    implicitHeight: img.implicitHeight

    Image {
        id: img
        anchors.fill: parent
        // Sampled by the cut below; opacity 0 (not `visible: false`) keeps
        // it in the scene graph so its texture follows a load that lands later.
        opacity: 0
        smooth: true
        mipmap: true
    }
    ShaderEffect {
        anchors.fill: parent
        visible: img.status === Image.Ready
        property variant source: img
        property real boxW: width
        property real boxH: height
        property real radius: ri.radius
        fragmentShader: "shaders/image_round.frag.qsb"
    }
}
