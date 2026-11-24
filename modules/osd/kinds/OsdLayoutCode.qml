pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// OsdLayoutCode.qml -- the keyboard layout: the two-letter code big ("BE") and
// the layout's name small. Text never rotates: vertically the name wraps
// under the code.
//
//   h     code | name      v   code over the wrapped name      pill  code name
//
// THE CARD IS AS BIG AS WHAT IT SAYS. A fixed extent is a guess at the longest name: vertically
// 110 px for a code and two lines, horizontally 170 for a name that fills 60. Both sizes follow the
// words (`fitW` / `fitH`, which OsdContent reads in place of the style's extent):
//
//   v  height   the code's caps stand `pad` under the top edge, the name's last line ends `pad`
//               over the foot, `gap` between the code's baseline and the name; the name wraps at
//               the width the card ASKS for (not at whatever the host has handed it so far: the
//               engine makes a content before it sizes it), at most three lines
//   h  width    `padX` round the code's slot and the name on ONE line, no wider than layoutHW (a longer
//               name elides there)
//   pill        the capsule's own extent (the pill sizes its box from the style, not from content)
// =============================================================================
Item {
    id: root

    property string kind: "layout"
    property string orientation: "h"
    property var payload: ({})
    property bool interactive: true
    property var style: null
    property real renderScale: 1

    signal userValue(real v)
    signal userToggleMute()
    signal userToggleBoost()
    signal touched()

    readonly property var p: root.payload ? root.payload : ({})
    readonly property bool vert: root.orientation === "v"
    readonly property bool isPill: root.orientation === "pill"
    readonly property string code: root.p.layout && root.p.layout.code ? root.p.layout.code : ""
    readonly property string lname: root.p.layout && root.p.layout.name ? root.p.layout.name : ""
    readonly property real padX: root.isPill ? root.style.pillPad : root.style.pad
    readonly property real codePx: root.isPill ? root.style.pillFigurePx + 4 : root.style.codePx
    readonly property real nameLinePx: root.isPill ? root.style.pillTextPx : root.style.detailPx

    // Two letters in Audiowide, in a slot as wide as the widest pair ("MM"),
    // so "US" -> "BE" does not move the name.
    FontMetrics {
        id: fm
        font.family: root.style.figureFont
        font.pixelSize: root.codePx
        font.bold: true
    }
    OsdWords {
        id: words
        family: root.style.textFont
        titlePx: root.style.titlePx
        detailPx: root.style.detailPx
    }
    // The width a vertical card asks for: its longest word, never broken.
    readonly property real wantW: root.vert
        ? Math.max(Math.ceil(codeText.implicitWidth), words.detail(root.lname)) + 2 * root.style.pad : 0

    readonly property real codeW: {
        const f = fm.font;
        return Math.ceil(fm.advanceWidth("MM")) + 1;
    }
    // Where the code's CAPS stand in its box: its top, and its height. A card whose room is to be equal above and
    // below measures from the ink, not from a line box that carries leading of its own.
    readonly property real capH: {
        const f = fm.font;
        return Math.ceil(fm.tightBoundingRect("EH").height);
    }
    readonly property real capTop: {
        const f = fm.font;
        return Math.max(0, fm.ascent + fm.tightBoundingRect("EH").y);
    }

    // ---- the size the words ask for ------------------------------------------------------------------------
    // v: the width the card is given (OsdContent's rule over wantW), and the name wrapped at it.
    readonly property real askW: Math.max(root.style.layoutVW, Math.min(root.style.cardMaxW, root.wantW))
    readonly property bool nameWraps: words.detail(root.lname) <= root.askW - 2 * root.style.pad
    Text {
        id: nameFit
        visible: false
        width: root.askW - 2 * root.style.pad
        text: root.lname
        font.family: root.style.textFont
        font.pixelSize: root.nameLinePx
        wrapMode: root.nameWraps ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: 3
    }
    readonly property real fitH: root.vert
        ? Math.ceil(root.style.pad + root.capH + root.style.layoutGap + nameFit.height + root.style.pad) : 0
    // h: the code's slot, the gap, the name on one line; no wider than the style's width (it elides there).
    readonly property real fitW: root.vert || root.isPill ? 0
        : Math.min(root.style.layoutHW, Math.ceil(2 * root.padX + root.codeW + root.style.cardGap + words.detailLine(root.lname)))

    Text {
        id: codeText
        text: root.code
        color: Theme.textPrimary
        font.family: root.style.figureFont
        font.pixelSize: root.codePx
        font.bold: true
        // Horizontally the code stands at the padding (its slot is as wide as "MM" so the name does not move
        // between layouts; the slack of a narrower pair goes between the two, not into the card's left margin).
        x: root.vert ? Math.round((root.width - implicitWidth) / 2) : Math.round(root.padX)
        y: root.vert ? Math.round(root.style.pad - root.capTop) : Math.round((root.height - implicitHeight) / 2)
    }
    Text {
        id: nameText
        text: root.lname
        color: Theme.textMuted
        font.family: root.style.textFont
        font.pixelSize: root.nameLinePx
        horizontalAlignment: root.vert ? Text.AlignHCenter : Text.AlignLeft
        wrapMode: root.vert && root.nameWraps ? Text.WordWrap : Text.NoWrap
        elide: Text.ElideRight
        maximumLineCount: root.vert ? 3 : 1
        x: root.vert ? Math.round(root.style.pad) : Math.round(root.padX + root.codeW + root.style.cardGap)
        y: root.vert ? Math.round(root.style.pad + root.capH + root.style.layoutGap) : Math.round((root.height - implicitHeight) / 2)
        width: root.vert ? root.width - 2 * root.style.pad : root.width - root.padX - x
    }
}
