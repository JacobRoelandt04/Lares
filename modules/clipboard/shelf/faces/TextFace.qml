pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"

// =============================================================================
// TextFace.qml -- a copied piece of prose: its first lines, elided.
//
// Faces share one contract (ClipCard hands it in): `rec` the record, `fw` x
// `fh` the room, `lines` how many lines the style gives this kind (less one
// when a pinned title took the first). Only the head of a long text is laid
// out -- a 16 KB copy costs the same as a short one.
// =============================================================================
Item {
    id: face

    property var rec: null
    property real fw: 0
    property real fh: 0
    property int lines: 5

    readonly property string head: {
        const t = face.rec ? String(face.rec.text || "") : "";
        return t.slice(0, 80 * Math.max(1, face.lines)).replace(/^\s+/, "");
    }

    Text {
        x: 0
        y: 0
        width: face.fw
        height: Math.min(face.fh, Math.ceil(lineHeight * face.lines))
        text: face.head
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: Math.max(1, face.lines)
        elide: Text.ElideRight
        color: Theme.textPrimary
        font.family: "Inter"
        font.pixelSize: 12
        lineHeight: 16
        lineHeightMode: Text.FixedHeight
    }
}
