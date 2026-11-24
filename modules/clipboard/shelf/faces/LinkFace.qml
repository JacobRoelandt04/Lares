pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "ClipParse.js" as Parse

// =============================================================================
// LinkFace.qml -- a copied URL: the domain is what it is, the path is detail.
// The chain glyph is the link's mark (accent); nothing else on the card is.
// =============================================================================
Item {
    id: face

    property var rec: null
    property real fw: 0
    property real fh: 0
    property int lines: 5

    readonly property var parts: Parse.link(face.rec ? face.rec.text : "")

    Text {
        id: glyph
        x: 0
        y: 1
        text: ""
        font.family: "Symbols Nerd Font"
        font.pixelSize: 13
        color: Theme.accent
    }
    Text {
        id: host
        x: 22
        y: 0
        width: face.fw - 22
        text: face.parts.host
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        color: Theme.textPrimary
        font.family: "Inter"
        font.pixelSize: 14
        font.bold: true
        lineHeight: 18
        lineHeightMode: Text.FixedHeight
    }
    Text {
        x: 0
        y: 24
        width: face.fw
        height: Math.min(Math.max(0, face.fh - 24), Math.ceil(15 * Math.max(1, face.lines - 2)))
        // Only the SHOWN text carries break opportunities (a zero-width space after each separator), so a
        // line breaks at "/", "?", "&", "=" and "#" and not through a word; a run with no separator still
        // breaks anywhere (Text.Wrap falls back to it). The stored clip is untouched.
        text: face.parts.path.replace(/([\/?&=#])/g, "$1\u200b")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: Math.max(1, face.lines - 2)
        elide: Text.ElideRight
        color: Theme.textMuted
        font.family: "Inter"
        font.pixelSize: 11
        lineHeight: 15
        lineHeightMode: Text.FixedHeight
    }
}
