pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// OsdCapture.qml -- a capture's confirmation: a screenshot's thumbnail
// (RoundedImage) or, with none, a carved tile holding the glyph of what
// happened (camera, record, stop, copy), and the words -- "Screenshot copied",
// "Recording started", "Recording stopped".
//
//   h     tile | title over detail         v   tile / title / detail, centred
//   pill  small tile | title over detail
//
// THE THUMBNAIL IS A SIZE YOU CAN READ. A screenshot's tile is `thumbW` x `thumbH` on a horizontal
// bar and `thumbV` wide, at the same proportions, on a vertical one -- and the card is as big as it needs: OsdContent reads `fitW` / `fitH` (the title on one
// line, the file's name under it, the padding, nothing else) in place of the style's extent.
// A recording or a copy has no picture and keeps the small glyph tile (and the style's extent);
// so does the pill, whose box is the style's.
//
//   NOT DISTORTED. The picture keeps its own proportions: a region's 3 : 1 screenshot is not
//   stretched into a 16 : 10 tile (the shader samples the whole texture into whatever box it is
//   given, and `shot.sh region` is the default). It is fitted inside the tile -- the tile is a
//   reserved slot, the picture is centred in what it leaves, and the carved tile shows around it.
//   DECODED ONCE. `sourceSize` is the size the tile is shown at, in device pixels (the owner's
//   renderScale is the engine's scale x the screen's): decoded once at that, never again -- the tile
//   does not resize.
// =============================================================================
Item {
    id: root

    property string kind: "capture"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()
    // A click on a screenshot's card: the owner opens the shot for editing and lets the OSD go.
    signal activated()
    // The trash icon on a screenshot's picture: the owner has the shot trashed (the card is not opened for editing).
    signal trashRequested()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property var c: root.p.capture ? root.p.capture : ({})
    readonly property bool vert: root.orientation === "v"
    readonly property bool isPill: root.orientation === "pill"
    readonly property real padX: root.isPill ? root.style.pillPad : root.style.pad
    // A screenshot with its file: the big tile. Known from the payload, not from the decode: the card does not
    // change size when the picture lands.
    readonly property bool shot: root.c.thumb ? String(root.c.thumb).length > 0 : false

    readonly property string baseName: {
        const s = root.c.path ? String(root.c.path) : "";
        const i = s.lastIndexOf("/");
        return i >= 0 ? s.substring(i + 1) : s;
    }
    readonly property string title: {
        switch (root.c.what) {
        case "shot":
            return root.c.copied === true ? "Screenshot copied" : "Screenshot saved";
        case "rec-start":
            return "Recording started";
        case "rec-stop":
            return "Recording stopped";
        default:
            return "Copied";
        }
    }
    readonly property string detail: root.c.label ? root.c.label : root.baseName
    readonly property string glyph: {
        switch (root.c.what) {
        case "shot":
            return "\u{F0100}";
        case "rec-start":
            return "\u{F044A}";
        case "rec-stop":
            return "\u{F04DB}";
        default:
            return "\u{F018F}";
        }
    }
    readonly property color glyphColor: root.c.what === "rec-start" ? Theme.error : Theme.accent

    OsdWords {
        id: words
        family: root.style.textFont
        titlePx: root.style.titlePx
        detailPx: root.style.detailPx
    }
    readonly property real wantW: root.vert
        ? words.title(root.title) + 2 * root.style.pad : 0

    // ---- the tile ---------------------------------------------------------------------------------------------
    // A picture's tile at its two sizes (the proportions are the horizontal one's); a glyph's.
    readonly property real tileW: {
        if (root.isPill)
            return Math.round(root.style.pillCover * 1.5);
        if (root.shot)
            return root.vert ? root.style.thumbV : root.style.thumbW;
        return root.vert ? root.style.extentOf("capture", "v").w - 2 * root.style.pad : root.style.glyphTileW;
    }
    readonly property real tileH: {
        if (root.isPill)
            return root.style.pillCover;
        if (root.shot)
            return Math.round(root.tileW * root.style.thumbH / root.style.thumbW);
        return root.vert ? Math.round(root.tileW * root.style.glyphTileH / root.style.glyphTileW) : root.style.glyphTileH;
    }
    readonly property real tileR: root.isPill ? 8 : root.style.thumbRadius

    // ---- the size the words and the picture ask for (OsdContent's fitW / fitH; 0 = the style's extent) ----------------
    // The title at its own size, whole: the horizontal card is as wide as the tile, the gaps and this (the file's name
    // under it elides to the same width).
    readonly property real titleLineW: words.titleLine(root.title)
    // The vertical card's text column is the tile's width; what it takes of height is measured, not guessed.
    Text {
        id: titleFit
        visible: false
        width: root.style.thumbV
        text: root.title
        font.family: root.style.textFont
        font.pixelSize: root.style.titlePx
        font.bold: true
        wrapMode: words.title(root.title) <= root.style.thumbV ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: 2
    }
    Text {
        id: detailFit
        visible: false
        width: root.style.thumbV
        text: root.detail.length > 0 ? root.detail : " "
        font.family: root.style.textFont
        font.pixelSize: root.style.detailPx
        elide: Text.ElideMiddle
    }
    readonly property real fitW: !root.shot || root.isPill ? 0
        : root.vert ? 2 * root.style.pad + root.style.thumbV
                    : Math.ceil(2 * root.padX + root.style.thumbW + root.style.cardGap + Math.max(root.titleLineW, root.style.thumbTextMinW))
    readonly property real fitH: !root.shot || root.isPill ? 0
        : root.vert ? Math.ceil(2 * root.style.pad + root.tileH + root.style.gap + titleFit.height + (root.detail.length > 0 ? 2 + detailFit.height : 0))
                    : 2 * root.style.pad + root.tileH

    readonly property real stackH: root.tileH + root.style.gap + titleText.height
        + (detailText.visible ? 2 + detailText.height : 0)
    readonly property real stackTop: Math.round((root.height - root.stackH) / 2)

    Item {
        id: tile
        objectName: "capture-tile"
        width: root.tileW
        height: root.tileH
        x: root.vert ? Math.round((root.width - width) / 2) : Math.round(root.padX)
        y: root.vert ? Math.round(root.stackTop) : Math.round((root.height - height) / 2)

        // The carved tile is the slot: a glyph in it while there is no picture (or none at all), and the
        // frame round a picture that does not fill it.
        ShadowBox {
            anchors.fill: parent
            baseRadius: root.tileR
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.panelSunk
            bevelWidth: 1
            shadowWidth: 3
        }
        OsdGlyph {
            anchors.centerIn: parent
            visible: thumb.status !== Image.Ready
            osd: root.style
            glyph: root.glyph
            size: Math.round(root.tileH * 0.42)
            color: root.glyphColor
        }
        // The picture, fitted in the slot with its own proportions and centred (whole pixels: the corners of a
        // rounded image must be on the grid).
        readonly property real _imgAspect: thumb.image.implicitWidth > 0 && thumb.image.implicitHeight > 0
            ? thumb.image.implicitWidth / thumb.image.implicitHeight : root.tileW / root.tileH
        readonly property real fitImgW: Math.round(Math.min(root.tileW, root.tileH * tile._imgAspect))
        readonly property real fitImgH: Math.round(Math.min(root.tileH, root.tileW / tile._imgAspect))
        RoundedImage {
            id: thumb
            objectName: "capture-image"
            width: tile.fitImgW
            height: tile.fitImgH
            x: Math.round((root.tileW - width) / 2)
            y: Math.round((root.tileH - height) / 2)
            // A picture that fills the slot takes the slot's corner; one with bars round it takes a smaller one.
            radius: tile.fitImgW >= root.tileW - 0.5 && tile.fitImgH >= root.tileH - 0.5 ? root.tileR : Math.min(root.tileR, 4)
            asynchronous: true
            // Decoded ONCE, at the size it is shown (device pixels): never a function of the layout.
            sourceSize: Qt.size(Math.ceil(root.tileW * root.renderScale), Math.ceil(root.tileH * root.renderScale))
            source: root.c.thumb ? root.c.thumb : ""
        }
    }

    // The whole card is the control (clicking the OSD's entry for a screenshot edits it). Nothing announces
    // it but the pointer: the hand. A recording's or a copy's card has nothing to open.
    MouseArea {
        anchors.fill: parent
        enabled: root.interactive && root.shot && !root.isPill
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            root.activated();
            root.touched();
        }
    }

    // THE TRASH ICON: on the picture's top-right corner, always drawn (an icon, not a hidden control). It
    // deletes the shot without opening the editor: declared after the card's own click area, so it is above it. A round
    // backdrop of the surface keeps the glyph readable on any picture; its fade is one fraction (hover), mixed here.
    Item {
        id: trashBtn
        objectName: "capture-trash"
        visible: root.shot && !root.isPill
        readonly property real size: 28
        width: trashBtn.size
        height: trashBtn.size
        x: Math.round(tile.x + tile.width - trashBtn.width - 4)
        y: Math.round(tile.y + 4)
        property real hot: trashArea.containsMouse ? 1 : 0
        Behavior on hot {
            NumberAnimation { duration: root.style.valueEaseMs; easing.type: Easing.OutCubic }
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.surface
            opacity: 0.88 + 0.12 * trashBtn.hot
        }
        OsdGlyph {
            anchors.centerIn: parent
            osd: root.style
            glyph: "\u{F0A7A}"
            size: 16
            color: Mix.c(Theme.textPrimary, Theme.error, trashBtn.hot)
        }
        MouseArea {
            id: trashArea
            anchors.fill: parent
            enabled: root.interactive && trashBtn.visible
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                root.trashRequested();
                root.touched();
            }
        }
    }

    Text {
        id: titleText
        text: root.title
        color: Theme.textPrimary
        font.family: root.style.textFont
        font.pixelSize: root.isPill ? root.style.pillTextPx + 1 : root.style.titlePx
        font.bold: true
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && words.title(text) <= width ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 2 : 1
        x: root.vert ? Math.round(root.style.pad) : Math.round(tile.x + tile.width + root.style.cardGap)
        width: root.vert ? root.width - 2 * root.style.pad : Math.round(root.width - root.padX - x)
        y: root.vert ? Math.round(root.stackTop + root.tileH + root.style.gap)
                     : Math.round((root.height - (height + (detailText.visible ? 2 + detailText.height : 0))) / 2)
    }
    Text {
        id: detailText
        visible: root.detail.length > 0
        text: root.detail
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.isPill ? root.style.pillTextPx : root.style.detailPx
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        elide: Text.ElideMiddle
        x: titleText.x
        width: titleText.width
        y: Math.round(titleText.y + titleText.height + 2)
    }
}
