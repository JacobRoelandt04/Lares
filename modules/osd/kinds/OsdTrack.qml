pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// OsdTrack.qml -- a track change (MPD): the cover (RoundedImage, a carved tile
// with a note while it has none), the title and the artist. No state glyph and
// no button (a pause glyph would look like a button and do
// nothing): the whole card is the control, a click anywhere on it opens the
// player (`activated`, which the owner turns into the player popup).
//
//   h     cover | title over artist
//   v     cover / title / artist, centred, text wrapped at word
//         boundaries only: the card grows to its longest word (`wantW`, up to
//         the style's cardMaxW) and a word past that elides on one line
//   pill  small cover | title over artist   (the pill takes no input)
// =============================================================================
Item {
    id: root

    property string kind: "track"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()
    // A click anywhere on the card: the owner opens the player and lets the OSD go.
    signal activated()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property var t: root.p.track ? root.p.track : ({})
    readonly property bool vert: root.orientation === "v"
    readonly property bool isPill: root.orientation === "pill"
    readonly property real padX: root.isPill ? root.style.pillPad : root.style.pad
    readonly property real cover: root.isPill ? root.style.pillCover : root.vert ? root.style.coverV : root.style.coverH
    readonly property real coverRadius: root.isPill ? 8 : root.style.coverRadius

    OsdWords {
        id: words
        family: root.style.textFont
        titlePx: root.style.titlePx
        detailPx: root.style.detailPx
    }
    readonly property real wantW: root.vert
        ? Math.max(words.title(titleText.text), words.detail(artistText.text)) + 2 * root.style.pad : 0

    // ---- the cover ------------------------------------------------------------
    Item {
        id: coverBox
        width: root.cover
        height: root.cover
        x: root.vert ? Math.round((root.width - width) / 2) : Math.round(root.padX)
        y: root.vert ? Math.round(root.stackTop) : Math.round((root.height - height) / 2)

        // The empty tile: carved, a note in it.
        ShadowBox {
            anchors.fill: parent
            visible: art.status !== Image.Ready
            baseRadius: root.coverRadius
            surfaceColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.panelSunk
            bevelWidth: 1
            shadowWidth: 3
        }
        OsdGlyph {
            anchors.centerIn: parent
            visible: art.status !== Image.Ready
            osd: root.style
            glyph: "\u{F075A}"
            size: Math.round(root.cover * 0.42)
            color: Theme.textFaint
        }
        RoundedImage {
            id: art
            anchors.fill: parent
            radius: root.coverRadius
            asynchronous: true
            // a decode cap (constant under layout), as large again as the glass magnifies
            sourceSize: Qt.size(Math.round(256 * Math.max(1, root.renderScale)), Math.round(256 * Math.max(1, root.renderScale)))
            source: root.t.art ? root.t.art : ""
        }
    }

    // ---- the words ------------------------------------------------------------
    readonly property real stackH: root.cover + root.style.gap + titleText.height + 2 + artistText.height
    readonly property real stackTop: Math.round((root.height - root.stackH) / 2)
    readonly property real textLeft: coverBox.x + coverBox.width + root.style.cardGap
    readonly property real textRight: root.width - root.padX

    Text {
        id: titleText
        text: root.t.title ? root.t.title : ""
        color: Theme.textPrimary
        font.family: root.style.textFont
        font.pixelSize: root.isPill ? root.style.pillTextPx + 1 : root.style.titlePx
        font.bold: true
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && words.title(text) <= width ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 2 : 1
        x: root.vert ? Math.round(root.style.pad) : Math.round(root.textLeft)
        width: root.vert ? root.width - 2 * root.style.pad : Math.round(root.textRight - root.textLeft)
        y: root.vert ? Math.round(root.stackTop + root.cover + root.style.gap)
                     : Math.round((root.height - (height + 2 + artistText.height)) / 2)
    }
    Text {
        id: artistText
        text: root.t.artist ? root.t.artist : ""
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.isPill ? root.style.pillTextPx : root.style.detailPx
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && words.detail(text) <= width ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 2 : 1
        x: titleText.x
        width: titleText.width
        y: Math.round(titleText.y + titleText.height + 2)
    }

    // The whole card is the control. Nothing announces it but the pointer: the hand. The pill takes no input.
    MouseArea {
        anchors.fill: parent
        enabled: root.interactive && !root.isPill
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            root.activated();
            root.touched();
        }
    }
}
