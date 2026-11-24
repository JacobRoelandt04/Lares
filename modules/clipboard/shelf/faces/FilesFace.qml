pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "ClipParse.js" as Parse

// =============================================================================
// FilesFace.qml -- copied files: how many, then the names (the uri-list's last
// path segments, decoded), the rest as "+ n more".
// =============================================================================
Item {
    id: face

    property var rec: null
    property real fw: 0
    property real fh: 0
    property int lines: 5

    readonly property var names: Parse.fileNames(face.rec ? face.rec.text : "")
    readonly property int shown: Math.max(0, Math.min(face.names.length, face.lines - 1 - (face.names.length > face.lines - 1 ? 1 : 0)))

    Text {
        id: glyph
        x: 0
        y: 1
        text: face.names.length > 1 ? "" : ""
        font.family: "Symbols Nerd Font"
        font.pixelSize: 13
        color: Theme.textMuted
    }
    Text {
        x: 22
        y: 0
        width: face.fw - 22
        text: face.names.length === 1 ? "1 file" : face.names.length + " files"
        color: Theme.textPrimary
        font.family: "Inter"
        font.pixelSize: 12
        font.bold: true
        lineHeight: 16
        lineHeightMode: Text.FixedHeight
    }
    Column {
        x: 0
        y: 22
        width: face.fw
        Repeater {
            model: face.names.slice(0, face.shown)
            Text {
                required property string modelData
                width: face.fw
                text: modelData
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
                maximumLineCount: 1
                color: Theme.textMuted
                font.family: "Inter"
                font.pixelSize: 12
                lineHeight: 15
                lineHeightMode: Text.FixedHeight
            }
        }
        Text {
            visible: face.names.length > face.shown
            width: face.fw
            text: "+ " + (face.names.length - face.shown) + " more"
            color: Theme.textFaint
            font.family: "Inter"
            font.pixelSize: 11
            lineHeight: 15
            lineHeightMode: Text.FixedHeight
        }
    }
}
