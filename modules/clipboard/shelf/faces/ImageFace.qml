pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// ImageFace.qml -- a copied image: its thumbnail (<stateDir>/thumbs/<thumb>),
// rounded, cropped to the card or fitted inside it. Without a thumbnail (the
// image is past the store's `thumbsMax`, or the store had no PIL) a neutral
// placeholder with the pixel size stands in -- and it stands in while the
// thumbnail decodes, which is asynchronous (the notification manager's way:
// a file on disk, `asynchronous: true`, a fixed `sourceSize`). The picture
// FADES IN when it lands (`shown`, one clock; presence fade, `fadeMs`), and a
// face that is handed another record starts from the placeholder again (the
// card pool reuses faces: a fraction snaps, it never fades out of the last
// record's state).
//
// THE THUMBNAIL IS DECODED ONCE, large (`sourceSize` is a constant): a size
// bound to the layout re-decodes on every step and the image is blank until
// each lands (CLAUDE.md, the image law). The rounding is the shell's own
// image_round shader reading the captured image, which is how "crop" works:
// the capture carries the Image's fill mode, a texture provider would not.
// =============================================================================
Item {
    id: face

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    property var rec: null
    property real fw: 0
    property real fh: 0
    property string stateDir: ""
    // "crop" or "fit" (ClipStyle.thumbFit).
    property string fit: "crop"
    property real radius: 8
    // The presence fade of the picture landing (ClipStyle.presenceMs).
    property int fadeMs: 160

    readonly property bool hasThumb: !!face.rec && !!face.rec.thumb && face.stateDir !== ""
    readonly property string source: face.hasThumb ? "file://" + face.stateDir + "/thumbs/" + face.rec.thumb : ""
    readonly property real aspect: face.rec && face.rec.w > 0 && face.rec.h > 0 ? face.rec.w / face.rec.h : 1
    readonly property bool crop: face.fit !== "fit"
    // The drawn rect, on whole pixels.
    readonly property int dw: face.crop || face.aspect >= face.fw / Math.max(1, face.fh) ? Math.floor(face.fw) : Math.floor(face.fh * face.aspect)
    readonly property int dh: face.crop || face.aspect < face.fw / Math.max(1, face.fh) ? Math.floor(face.fh) : Math.floor(face.fw / face.aspect)
    readonly property bool ready: face.hasThumb && raw.status === Image.Ready
    // 0 = the placeholder alone, 1 = the picture. Driven by the decode, never by a binding that a
    // reused face would ease backwards.
    property real shown: 0

    NumberAnimation {
        id: fadeIn
        target: face
        property: "shown"
        from: 0
        to: 1
        duration: face.fadeMs
        easing.type: Easing.OutCubic
    }
    // A picture that was in memory when the face was built is simply there.
    Component.onCompleted: {
        if (face.ready) {
            fadeIn.stop();
            face.shown = 1;
        }
    }
    onReadyChanged: {
        if (face.ready) {
            fadeIn.restart();
        } else {
            fadeIn.stop();
            face.shown = 0;
        }
    }

    // Under the picture: it is what shows until the picture lands, and the picture fades in over it.
    Rectangle {
        visible: face.shown < 1
        opacity: 1 - face.shown
        x: 0
        y: 0
        width: face.fw
        height: face.fh
        radius: face.radius
        color: Theme.panelSunk
        Text {
            x: Math.floor((parent.width - width) / 2)
            y: Math.floor(parent.height / 2 - height) + 2
            text: ""
            font.family: "Symbols Nerd Font"
            font.pixelSize: 22
            color: Theme.textFaint
            opacity: Math.max(0, 1 - 2 * face.shown)
        }
        Text {
            x: Math.floor((parent.width - width) / 2)
            y: Math.floor(parent.height / 2) + 6
            text: face.rec && face.rec.w > 0 ? face.rec.w + " × " + face.rec.h : ""
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textMuted
            opacity: Math.max(0, 1 - 2 * face.shown)
        }
    }

    Item {
        id: holder
        x: Math.floor((face.fw - face.dw) / 2)
        y: Math.floor((face.fh - face.dh) / 2)
        width: face.dw
        height: face.dh

        Image {
            id: raw
            width: holder.width
            height: holder.height
            source: face.source
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true
            // a cap, constant under layout (a resize must not re-decode), and as large again as the glass magnifies
            sourceSize.width: Math.round(512 * Math.max(1, dev.value))
            sourceSize.height: Math.round(512 * Math.max(1, dev.value))
            fillMode: face.crop ? Image.PreserveAspectCrop : Image.Stretch
        }
        ShaderEffectSource {
            id: grab
            anchors.fill: parent
            sourceItem: raw
            hideSource: true
            visible: false
            textureSize: Qt.size(Math.max(1, holder.width * 2 * Math.max(1, dev.value)), Math.max(1, holder.height * 2 * Math.max(1, dev.value)))
        }
        ShaderEffect {
            anchors.fill: parent
            visible: face.ready
            opacity: face.shown
            property variant source: grab
            property real boxW: width
            property real boxH: height
            property real radius: face.radius
            fragmentShader: "../../../common/components/shaders/image_round.frag.qsb"
        }
    }
}
