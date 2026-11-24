pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// VinylSleeve.qml
//
// The album's sleeve, drawn by shaders/vinyl_sleeve.frag: printed card with
// the record's ring pressed into it, the print split along the edges, chewed
// corners, and one open edge the record comes out of.
//
// Like VinylDisc this file owns only what the sleeve IS. Where it flies in
// from, how far it overshoots and when it leaves is VinylStage's business --
// the sleeve is moved by plain x / rotation on the item, because its motion is
// in the plane and needs no camera.
//
// `openingRight` is false by default: the mouth is on the left. The record is
// revealed by the sleeve sliding off to the right, so the mouth has to face the
// middle of the stage. It is a property so the mouth can be mirrored.
// =============================================================================
Item {
    id: root

    property string albumArt: ""
    property bool openingRight: false

    // Wear, in px at the sleeve's own scale.
    property real coverInset: 2
    property real edgeWear: 9.5
    property real cornerWear: 12
    // The record's impression. It is the one mark everybody recognises on a
    // sleeve, which is exactly why it wants to be at the edge of visibility:
    // read as a shape rather than as a stamp. `ringWear` is the emboss the light
    // catches, `ringInk` is how much ink the rim has also taken off.
    property real ringWear: 0.25
    property real ringInk: 0.025
    property real ringRadius: 0.96      // of the sleeve's half-width
    property real scratches: 0.9
    property real grain: 0.16
    property real fade: 0.14

    // Where the wear lives. A sleeve is handled by its rim and pulled out of a
    // shelf by a corner, so grain, scuffs and abrasion are all multiplied by a
    // shaped centre-to-edge mask rather than laid on evenly: `wearBias` is how
    // much of the front is spared (0 = even weathering, 1 = only the
    // rim wears at all) and `wearShape` how abruptly it climbs on the way out.
    property real wearBias: 0.82
    property real wearShape: 3.0

    property color cardColor: "#D8D2C4"
    property color cardEdgeColor: "#BDB6A6"
    property color printTint: "#FFFFFF"

    // The same key light the record uses, so both objects agree about the room.
    property vector3d lightDir: Qt.vector3d(-0.45, 0.72, 0.52)
    property real lightIntensity: 0.9
    property real gloss: 0.35
    property real ambient: 0.42

    // Decorrelates two sleeves that are on screen at the same time -- the one
    // leaving and the one arriving must not wear identically.
    property real seed: 0.37

    // How big the cover is actually decoded, by the same rule as the record's
    // label and for the same reason -- see HOW BIG THE LABEL IS ACTUALLY
    // DECODED in VinylDisc.qml. The sleeve's ShaderEffect fills this item, so
    // the item's own size IS the drawn size and there is nothing to work back
    // from: 440 px in `player`, 103 px in `mini`, both decoded at 768 square.
    // Doubled for headroom, rounded up to a power of two, capped at 768.
    // `player` takes 768; `mini` takes 256, nine times fewer texels.
    property real coverTexOversample: 2
    property int coverTexMax: 768
    readonly property int coverTexPx: {
        const drawn = Math.max(root.width, root.height) * root.coverTexOversample;
        return Math.min(root.coverTexMax,
                        Math.pow(2, Math.ceil(Math.log2(Math.max(64, drawn)))));
    }

    Image {
        id: coverImage
        source: root.albumArt
        visible: false
        asynchronous: true
        mipmap: true
        smooth: true
        cache: true
        sourceSize.width: root.coverTexPx
        sourceSize.height: root.coverTexPx
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        fragmentShader: "shaders/vinyl_sleeve.frag.qsb"
        blending: true

        property vector2d res: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
        property real seed: root.seed
        property real coverInset: root.coverInset

        property real edgeWear: root.edgeWear
        property real cornerWear: root.cornerWear
        property real ringWear: root.ringWear
        property real ringRadius: root.ringRadius
        property real scratches: root.scratches
        property real grain: root.grain
        property real fade: root.fade
        property real ringInk: root.ringInk
        property real wearBias: root.wearBias
        property real wearShape: root.wearShape

        property color cardColor: root.cardColor
        property color cardEdgeColor: root.cardEdgeColor
        property color printTint: root.printTint

        property vector4d lightDir: Qt.vector4d(root.lightDir.x, root.lightDir.y, root.lightDir.z, root.lightIntensity)
        property real gloss: root.gloss
        property real ambient: root.ambient

        property real hasCover: (root.albumArt !== "" && coverImage.status === Image.Ready) ? 1 : 0
        property real openingSide: root.openingRight ? 1 : 0

        property variant coverTex: coverImage
    }
}
