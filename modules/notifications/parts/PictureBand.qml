import QtQuick

// =============================================================================
// PictureBand.qml -- a notification's picture: the card's full width, at the
// picture's OWN aspect ratio, its height held between `minHeight` and
// `maxHeight`.
//
// The height follows the picture (width x aspect) inside its bounds (a band of
// `min(maxHeight, width * aspect)` with the image stretched over it would squash
// any picture taller than the cap: a 16:9 screenshot at the manager's 372 px, a
// region screenshot of a window), and a picture
// that falls outside them is COVERED: scaled until it fills the box and cropped
// equally at both ends -- the middle of a tall one, the middle of a very wide
// one -- never stretched. The crop is the texture coordinate of the shader
// (shaders/picture_crop.frag, image_round.frag's cut with a uv window), so the
// Image is sampled as a texture provider: no layer, no FBO, nothing resampled.
//
// The Image is never drawn itself (opacity 0 keeps it in the scene graph so its
// texture follows a load that lands later), and it can still be grabbed whole:
// `image` is exposed for the card's PNG grab, which must save the picture as it
// IS, not as the band shows it. `sourceSize` is the host's business (decode
// once, large: a new one is a new decode and a blank band).
// =============================================================================
Item {
    id: band

    property alias source: img.source
    property alias sourceSize: img.sourceSize
    property alias asynchronous: img.asynchronous
    readonly property alias status: img.status
    readonly property alias image: img
    property real radius: 8
    property real minHeight: 72
    property real maxHeight: 240

    readonly property bool _ready: img.status === Image.Ready && img.implicitWidth > 0 && img.implicitHeight > 0
    // The picture's height at this width, and the band's: the first clamped into the bounds (never above the cap
    // should the host hand a minimum over it).
    readonly property real naturalHeight: band._ready ? band.width * img.implicitHeight / img.implicitWidth : 0
    readonly property real shownHeight: band._ready
        ? Math.round(Math.min(band.maxHeight, Math.max(Math.min(band.minHeight, band.maxHeight), band.naturalHeight))) : 0
    // The share of the picture the box shows, each way: one of them is less than 1 when the aspect is out of bounds.
    readonly property real _u: band._ready && band.shownHeight > 0
        ? Math.min(1, band.width * img.implicitHeight / (band.shownHeight * img.implicitWidth)) : 1
    readonly property real _v: band._ready && band.naturalHeight > 0 ? Math.min(1, band.shownHeight / band.naturalHeight) : 1

    height: band.shownHeight

    Image {
        id: img
        anchors.fill: parent
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
        property real radius: band.radius
        property real uvOffX: (1 - band._u) / 2
        property real uvOffY: (1 - band._v) / 2
        property real uvScaleX: band._u
        property real uvScaleY: band._v
        fragmentShader: "../shaders/picture_crop.frag.qsb"
    }
}
