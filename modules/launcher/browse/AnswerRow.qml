pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."
import "../../common/components/Mix.js" as Mix
import "AnswerKinds.js" as AK

// =============================================================================
// AnswerRow.qml -- the launcher's quick answer (math, currency, units ...): ONE row with the app rows' geometry, in
// the first slot of the list while an answer exists. The popup does not resize; the hits move down a row.
//
//   | glyph |  VALUE                      alt   value |
//   |       |  expr  detail               alt   value |
//
// The glyph is the kind's (AnswerKinds); the colour kind shows a small carved swatch in its place and names the
// theme token it is nearest to ("≈ accent", CIEDE2000 on the settled palette) before its detail. The value is in the
// figure face, the expr muted, the detail faint, one line, elided together; up to three alts are plain text that copies
// itself on click (the pointer is the only mark: a colour fade and the hand). A click on the row copies the main
// form. The row's carve (the app rows' highlight) shows while it is `selected`.
//
// `answer` is the service's answer object (LauncherAnswers) or null; the row keeps showing the LAST one while it fades
// out (160 ms, the house presence) and swaps a pending answer for its landed one in place, instantly. `copied` makes
// the expr slot say "Copied" (an instant swap). Facts only come in: no colour is carried through a model.
// =============================================================================
Item {
    id: row

    property var answer: null
    property LauncherTune tune: null
    property bool selected: false
    property bool copied: false

    // A click: the main form / an alt's (`keepOpen`: with Shift, the launcher stays, as on an app row).
    signal copyMain(bool keepOpen)
    signal copyAlt(string text, bool keepOpen)
    // The pointer moved over the row (the grid's mouse moves the highlight too).
    signal pointerMoved

    readonly property bool present: !!row.answer
    property var _a: null
    onAnswerChanged: {
        if (row.answer)
            row._a = row.answer;
    }

    readonly property string _face: row.tune ? row.tune.fontFamily : "Inter"
    readonly property real _inset: row.tune ? row.tune.rowInset : 6
    readonly property real _icon: row.tune ? row.tune.iconSize : 40
    readonly property real _gap: row.tune ? row.tune.iconGap : 10
    readonly property real _altShare: row.tune ? row.tune.answerAltShare : 0.42
    readonly property int _fadeMs: row.tune ? row.tune.answerFadeMs : 160

    // ---- presence and the carve -------------------------------------------------------------------------
    property real presence: row.present ? 1 : 0
    Behavior on presence {
        NumberAnimation {
            duration: row._fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real selF: row.selected ? 1 : 0
    Behavior on selF {
        NumberAnimation {
            duration: row.tune ? row.tune.glideMs : 120
            easing.type: Easing.OutCubic
        }
    }
    visible: row.presence > 0.001
    opacity: row.presence

    // ---- the palette the colour kind is judged on (read on the settled theme, never bound live) ------------------
    property var _palette: []
    function _readPalette() {
        const t = [["surface", Theme.surface], ["panel", Theme.panelSunk], ["border", Theme.border], ["deep shadow", Theme.shadowDeep], ["text", Theme.textPrimary], ["muted text", Theme.textMuted], ["faint text", Theme.textFaint], ["accent", Theme.accent], ["ok", Theme.ok], ["warn", Theme.warn], ["error", Theme.error], ["core", Theme.catCore], ["extra", Theme.catExtra], ["multilib", Theme.catMultilib], ["aur", Theme.catAur], ["flatpak", Theme.catFlatpak]];
        const out = [];
        for (let i = 0; i < t.length; i++)
            out.push({
                name: t[i][0],
                rgb: [t[i][1].r, t[i][1].g, t[i][1].b]
            });
        row._palette = out;
    }
    Component.onCompleted: row._readPalette()
    Connections {
        target: Theme
        function onSettled() {
            row._readPalette();
        }
    }
    readonly property var _near: row._a && row._a.swatch ? AK.nearest(row._a.swatch, row._palette) : null

    // ---- the well (the same carve as the list's highlight) -------------------------------------------------------
    ShadowBox {
        visible: row.selF > 0.01
        opacity: row.selF
        width: row.width
        height: row.height
        baseWidth: row.width
        baseHeight: row.height
        baseRadius: row.tune ? row.tune.wellRadius : 10
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.panelSunk
        bevelWidth: 1
        shadowWidth: 3
    }

    // The click of the whole row; the alts sit above it.
    MouseArea {
        id: rowArea
        objectName: "answerArea"
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => row.copyMain((mouse.modifiers & Qt.ShiftModifier) !== 0)
        onPositionChanged: row.pointerMoved()
    }

    // ---- the mark: the kind's glyph, or the colour's swatch -------------------------------------------------------
    readonly property bool _isColour: !!row._a && !!row._a.swatch
    readonly property real _swatch: row.tune ? row.tune.answerSwatch : 28
    Text {
        id: glyph
        objectName: "answerGlyph"
        visible: !row._isColour
        x: row._inset + Math.round((row._icon - width) / 2)
        y: Math.round((row.height - height) / 2)
        text: AK.glyphOf(row._a ? row._a.kind : "")
        font.family: "Symbols Nerd Font"
        font.pixelSize: row.tune ? row.tune.answerGlyphSize : 18
        color: Mix.c(Theme.textMuted, Theme.accent, row.selF)
    }
    ShadowBox {
        id: swatch
        objectName: "answerSwatch"
        visible: row._isColour
        x: row._inset + Math.round((row._icon - row._swatch) / 2)
        y: Math.round((row.height - row._swatch) / 2)
        width: row._swatch
        height: row._swatch
        baseWidth: row._swatch
        baseHeight: row._swatch
        baseRadius: row.tune ? row.tune.answerSwatchRadius : 8
        // The ground it is carved in is the row's: the well while selected, the surface when not.
        surfaceColor: Mix.c(Theme.surface, Theme.panelSunk, row.selF)
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: row._isColour ? row._a.swatch : "transparent"
        bevelWidth: 1
        shadowWidth: 2
    }

    // ---- the text -------------------------------------------------------------------------------------------------
    readonly property real _textX: row._inset + row._icon + row._gap
    readonly property real _altW: row._a && row._a.alts.length > 0 ? Math.round(row.width * row._altShare) : 0
    readonly property real _textW: Math.max(0, row.width - row._textX - row._inset - (row._altW > 0 ? row._altW + row._gap : 0))
    FontMetrics {
        id: valueFm
        font.family: row._face
        font.pixelSize: row.tune ? row.tune.answerValueSize : 16
        font.bold: true
    }
    FontMetrics {
        id: subFm
        font.family: row._face
        font.pixelSize: row.tune ? row.tune.answerSubSize : 11
    }
    readonly property real _lineGap: row.tune ? row.tune.answerLineGap : 2
    readonly property real _blockH: Math.ceil(valueFm.height) + row._lineGap + Math.ceil(subFm.height)
    readonly property real _blockY: Math.round((row.height - row._blockH) / 2)

    Text {
        id: valueText
        objectName: "answerValue"
        x: row._textX
        y: row._blockY
        width: row._textW
        height: Math.ceil(valueFm.height)
        text: row._a ? row._a.value : ""
        elide: Text.ElideRight
        font: valueFm.font
        color: Theme.textPrimary
    }
    // The expr (or "Copied") muted, the detail faint: one line, elided together.
    // An expr that only repeats the value (a colour typed as its hex) says nothing: left out, with its separator.
    readonly property string _expr: row.copied ? "Copied"
        : (row._a && row._a.expr && String(row._a.expr).toLowerCase() !== String(row._a.value).toLowerCase() ? row._a.expr : "")
    readonly property string _tail: {
        const parts = [];
        if (row._near)
            parts.push("≈ " + row._near.name);
        if (row._a && row._a.detail)
            parts.push(row._a.detail);
        return parts.join(" · ");
    }
    Text {
        id: subText
        objectName: "answerSub"
        x: row._textX
        y: row._blockY + Math.ceil(valueFm.height) + row._lineGap
        width: row._textW
        height: Math.ceil(subFm.height)
        textFormat: Text.StyledText
        text: "<font color=\"" + (row.copied ? Theme.accent.toString() : Theme.textMuted.toString()) + "\">" + AK.esc(row._expr) + "</font>" + (row._tail !== "" ? "<font color=\"" + Theme.textFaint.toString() + "\">" + (row._expr !== "" ? " \u00B7 " : "") + AK.esc(row._tail) + "</font>" : "")
        elide: Text.ElideRight
        font: subFm.font
        color: Theme.textMuted
    }

    // ---- the alts: plain text, each copies itself ---------------------------------------------------------------
    readonly property real _altLineH: Math.ceil(subFm.height) + (row.tune ? row.tune.answerAltGap : 1)
    Column {
        id: alts
        objectName: "answerAlts"
        visible: row._altW > 0
        x: row.width - row._inset - row._altW
        width: row._altW
        spacing: 0
        y: Math.round((row.height - (row._a ? row._a.alts.length : 0) * row._altLineH) / 2)
        Repeater {
            model: row._a ? row._a.alts.length : 0
            delegate: Item {
                id: alt
                required property int index
                readonly property var d: row._a && alt.index < row._a.alts.length ? row._a.alts[alt.index] : null
                width: alts.width
                height: row._altLineH
                property real hoverF: altArea.containsMouse ? 1 : 0
                Behavior on hoverF {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
                Text {
                    objectName: "answerAlt"
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    textFormat: Text.StyledText
                    text: alt.d ? AK.altText(alt.d, Theme.textFaint.toString()) : ""
                    elide: Text.ElideRight
                    font: subFm.font
                    color: Mix.c(Theme.textMuted, Theme.accent, alt.hoverF)
                }
                MouseArea {
                    id: altArea
                    objectName: "answerAltArea"
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => {
                        if (alt.d)
                            row.copyAlt(alt.d.copy, (mouse.modifiers & Qt.ShiftModifier) !== 0);
                    }
                    onPositionChanged: row.pointerMoved()
                }
            }
        }
    }
}
