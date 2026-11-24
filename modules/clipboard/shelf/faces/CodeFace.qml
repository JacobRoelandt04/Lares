pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"

// =============================================================================
// CodeFace.qml -- a copied piece of code: its first lines, indentation kept,
// one record line per row, cut at the card's edge (never wrapped: wrapped
// code is not code). Consolas Bold 12, the terminal's face.
// =============================================================================
Item {
    id: face

    property var rec: null
    property real fw: 0
    property real fh: 0
    property int lines: 6

    readonly property string head: {
        const t = face.rec ? String(face.rec.text || "") : "";
        const src = t.slice(0, 160 * Math.max(1, face.lines)).replace(/\t/g, "    ").split("\n");
        const out = [];
        // Blank lines at the head say nothing about the code.
        let i = 0;
        while (i < src.length - 1 && src[i].trim() === "")
            i++;
        for (; i < src.length && out.length < Math.max(1, face.lines); i++)
            out.push(src[i].replace(/\r$/, "").slice(0, 90));
        return out.join("\n");
    }

    Text {
        x: 0
        y: 0
        width: face.fw
        height: Math.min(face.fh, Math.ceil(lineHeight * face.lines))
        text: face.head
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        maximumLineCount: Math.max(1, face.lines)
        // Cut at the face's edge. `elide` does nothing to unwrapped multi-line text, and without a clip a
        // long line runs on over the next card, plainly visible once this card is lifted above it.
        clip: true
        color: Theme.textPrimary
        font.family: "Consolas"
        font.bold: true
        font.pixelSize: 12
        lineHeight: 16
        lineHeightMode: Text.FixedHeight
    }
}
