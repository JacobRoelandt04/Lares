pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/components/LiveMarkdown.js" as LM

// =============================================================================
// LiveMarkdownLine.qml -- one source line of the notes editor.
//
// A pooled delegate of LineViewport: `lineIndex` is set by the viewport and
// the editor fills the rest (editor.fill) -- the line's context, whether it is
// RAW (the caret's line, markers faint, edited natively) or RENDERED, and the
// html. What a line draws beyond its text lives here: the list bullet or the
// task box in the gutter, quote bars, a rule, an image, a rendered table on a
// table's first line, the folded frontmatter chip, a fence's language label.
// Code-fence and callout BACKGROUNDS span several lines and are drawn by the
// editor under the rows.
//
// Raw and rendered keep the same height (a heading keeps its size raw, a
// fence line is always one mono line) so revealing a line only moves it
// sideways; a table is the exception, as in Obsidian.
//
// The TextEdit never takes focus by itself (`activeFocusOnPress: false`) and
// is never flipped read-only (that moves its cursor, CLAUDE.md): only the
// caret's line is focused, by the editor.
// =============================================================================
Item {
    id: row

    property int lineIndex: -1
    property var editor: null

    // Filled by the editor.
    property var ctx: ({
            t: "blank",
            cs: 0
        })
    property bool raw: false
    property var r2s: [0]
    property string fillKey: ""
    property bool programmatic: false
    property string imageUrl: ""
    property bool imageMissing: false
    property var tableRows: []
    property int frontCount: 0

    readonly property alias edit: te
    readonly property string t: row.ctx ? row.ctx.t : "blank"
    readonly property bool isHead: row.t === "head" || row.t === "setext"
    readonly property bool mono: row.t === "fenceOpen" || row.t === "fenceBody" || row.t === "fenceClose" || row.t === "plain" || (row.raw && (row.t === "thead" || row.t === "tdelim" || row.t === "trow" || row.t === "front"))
    readonly property real bodyPx: row.editor ? row.editor.bodySize : 12
    readonly property real fontPx: !row.editor ? 12 : (row.isHead ? Math.round(row.editor.headPx(row.ctx.lv || 1)) : (row.mono ? row.editor.monoSize : row.bodyPx))
    readonly property real sidePad: row.editor ? row.editor.sidePadding : 12
    readonly property real quoteStep: 12
    readonly property int quoteDepth: (row.t === "quote" || row.t === "callout") ? (row.ctx.qd || 1) : 0
    // Rendered lists draw their marker in the gutter; raw lists show it as text.
    readonly property bool listGutter: row.t === "list" && !row.raw
    // One step per nesting level (the parser's `lvl`, not the width the
    // writer's indent happened to have): a sub-point's bullet stands right of
    // its parent's text, so the two levels read as two (not the indent's
    // columns times a space: 2 spaces would be 7 px).
    readonly property real listStep: 22
    readonly property real indentPx: row.t === "list" && row.editor ? Math.min(6, (row.ctx.lvl || 0)) * row.listStep : 0
    readonly property real markerW: row.listGutter ? (row.ctx.task !== null && row.ctx.task !== undefined ? 20 : (row.ctx.ord ? Math.max(18, bulletText.implicitWidth + 6) : 16)) : 0
    readonly property real calloutPad: row.t === "callout" ? 12 : 0
    readonly property real gutter: row.t === "callout" ? row.calloutPad + (row.ctx.coHead && !row.raw ? 20 : 0) : (row.quoteDepth > 0 ? row.quoteDepth * row.quoteStep : (row.listGutter ? row.indentPx + row.markerW : 0))
    readonly property real fencePad: (row.t === "fenceOpen" || row.t === "fenceBody" || row.t === "fenceClose") ? 10 : 0
    readonly property real headTopPad: row.isHead ? Math.round(row.fontPx * 0.45) : 0
    // The editor's row padding (1.5) split into WHOLE pixels, the odd one
    // below: with 1.5 above, every line's text and box started at y + 0.5 --
    // soft glyphs, uneven carved corners, a table header's corner half
    // covered. The row's height is the same.
    readonly property real topPad: row.editor ? Math.floor(row.editor.rowPad) + row.headTopPad : 2
    readonly property real bottomPad: row.editor ? 2 * row.editor.rowPad - Math.floor(row.editor.rowPad) : 2
    readonly property bool collapsed: !row.raw && (row.t === "tdelim" || row.t === "trow" || row.t === "setextU" || (row.t === "front" && row.lineIndex !== 0))
    readonly property bool showTable: row.t === "thead" && !row.raw
    readonly property bool showImage: row.t === "image" && (row.imageUrl !== "" || row.imageMissing)
    readonly property bool showFront: row.t === "front" && !row.raw && row.lineIndex === 0
    readonly property bool textHidden: !row.raw && (row.showTable || row.showFront || row.t === "image" || row.t === "rule")
    readonly property real textH: row.textHidden && !(row.t === "rule") ? 0 : te.contentHeight
    readonly property real imageH: row.showImage ? imageBox.height + (row.textHidden ? 0 : 4) : 0

    implicitHeight: row.collapsed ? 0 : Math.ceil(row.topPad + (row.showTable ? tableBox.height : (row.showFront ? frontChip.height : row.textH)) + row.imageH + row.bottomPad)
    height: row.implicitHeight
    clip: row.collapsed

    // Whole-pixel column widths from the fractions, the last taking the
    // remainder so the row is exactly the table's width.
    function cellWidths(cells) {
        const avail = Math.max(40, row.width - 2 * row.sidePad - 2);
        let used = 0;
        return cells.map((c, k) => {
            if (k === cells.length - 1)
                return Math.max(0, avail - used);
            const w = Math.floor(c.frac * avail);
            used += w;
            return w;
        });
    }

    function setHtml(h) {
        row.programmatic = true;
        te.text = h;
        row.programmatic = false;
    }

    // ---- quote bars -------------------------------------------------------------
    Repeater {
        model: row.t === "quote" ? row.quoteDepth : 0
        delegate: Rectangle {
            required property int index
            x: row.sidePad + index * row.quoteStep
            y: 0
            width: 3
            height: row.height
            radius: 1.5
            color: Mix.c(Theme.surface, Theme.textFaint, 0.45)
        }
    }

    // ---- list gutter: bullet, number or task box -------------------------------
    Text {
        id: bulletText
        visible: row.listGutter && (row.ctx.task === null || row.ctx.task === undefined)
        x: row.sidePad + row.indentPx + (row.ctx.ord ? 0 : 4)
        y: row.topPad
        text: row.ctx.ord ? (row.ctx.num + (String(row.ctx.mk || ".").slice(-1))) : "\u2022"
        font.family: row.editor ? row.editor.fontFamily : "Inter"
        font.pixelSize: row.fontPx
        color: Theme.textMuted
    }
    Item {
        id: taskBox
        objectName: "taskBox"
        readonly property bool on: row.ctx.task === "x"
        visible: row.listGutter && row.ctx.task !== null && row.ctx.task !== undefined
        x: row.sidePad + row.indentPx + 1
        y: Math.round(row.topPad + Math.max(0, ((row.editor ? row.editor.lineBox(row.fontPx) : 16) - 13) / 2))
        width: 13
        height: 13
        ShadowBox {
            anchors.fill: parent
            baseWidth: 13
            baseHeight: 13
            baseRadius: 3.5
            bevelWidth: 1
            shadowWidth: 2.5
            // Carved into the editor's ground, bands easing to alpha
            // (LiveMarkdownEditor "The ground and the carve").
            surfaceColor: "transparent"
            bevelColor: row.editor ? row.editor.carveBevel : Theme.bevel
            shadowColor: row.editor ? row.editor.carveShadowDeep : Theme.shadowDeep
            backgroundColor: taskBox.on ? Theme.accent : (row.editor ? row.editor.sunk(Theme.listBox) : Theme.listBox)
        }
        Text {
            anchors.centerIn: parent
            visible: taskBox.on
            text: "\u2713"
            font.pixelSize: 10
            font.bold: true
            color: Theme.textOnAccent
        }
    }

    // ---- callout head glyph ------------------------------------------------------
    Text {
        visible: row.t === "callout" && !!row.ctx.coHead && !row.raw
        x: row.sidePad + row.calloutPad
        y: row.topPad
        text: row.editor ? row.editor.calloutGlyph(row.ctx.co) : ""
        font.family: "Symbols Nerd Font"
        font.pixelSize: row.fontPx
        color: row.editor ? row.editor.calloutColor(row.ctx.co) : Theme.accent
    }

    // ---- a fence's language, on its opening line ---------------------------------
    Text {
        visible: row.t === "fenceOpen" && !row.raw && text.length > 0
        x: row.sidePad + row.fencePad
        y: row.topPad + Math.round((te.contentHeight - height) / 2)
        text: row.ctx.lang || ""
        font.family: row.editor ? row.editor.fontFamily : "Inter"
        font.pixelSize: 10
        color: Theme.textFaint
    }

    // ---- a coloured span's highlight -----------------------------------------------------
    // On a RENDERED line: faint while the pointer is over a coloured span,
    // strong while it is picked for the colour bar (LiveMarkdownEditor
    // `spanFocus`). Drawn here, under the text, rather than as the edit's own
    // selection, whose selectedTextColor would grey out the very colour
    // being picked. One rect per visual line the span covers.
    readonly property var spanMarks: {
        const ed = row.editor;
        if (!ed || row.raw || row.lineIndex < 0 || row.textHidden)
            return [];
        const out = [];
        const f = ed.spanFocus, h = ed.hoverSpan;
        if (f && f.line === row.lineIndex)
            out.push({
                s0: f.s0,
                s1: f.s1,
                strong: true
            });
        if (h && h.line === row.lineIndex && !(f && f.line === h.line && f.s0 === h.s0))
            out.push({
                s0: h.s0,
                s1: h.s1,
                strong: false
            });
        return out;
    }
    function _markRects(m) {
        if (!m || te.length === 0)
            return [];
        const r0 = LM.toRendered(row.r2s, m.s0), r1 = Math.max(r0, LM.toRendered(row.r2s, m.s1));
        const rects = [];
        let cur = null;
        for (let k = r0; k < r1 && k < r0 + 400; k++) {
            const a = te.positionToRectangle(k), b = te.positionToRectangle(k + 1);
            const x1 = b.y === a.y ? b.x : te.width;
            if (cur && cur.y === a.y)
                cur.x1 = x1;
            else {
                cur = {
                    x0: a.x,
                    x1: x1,
                    y: a.y,
                    h: a.height
                };
                rects.push(cur);
            }
        }
        return rects;
    }
    Repeater {
        model: row.spanMarks
        delegate: Item {
            id: markItem
            required property var modelData
            readonly property var rects: row._markRects(markItem.modelData)
            Repeater {
                model: markItem.rects
                delegate: Rectangle {
                    required property var modelData
                    x: te.x + Math.round(modelData.x0) - 2
                    y: te.y + Math.round(modelData.y)
                    width: Math.round(modelData.x1 - modelData.x0) + 4
                    height: Math.round(modelData.h)
                    radius: 3
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, markItem.modelData.strong ? 0.28 : 0.12)
                }
            }
        }
    }

    // ---- the text --------------------------------------------------------------------
    TextEdit {
        id: te
        x: row.sidePad + row.gutter + row.fencePad
        y: row.topPad
        width: Math.max(1, row.width - x - row.sidePad - row.fencePad)
        visible: !row.textHidden
        textFormat: TextEdit.RichText
        wrapMode: TextEdit.Wrap
        font.family: row.mono ? (row.editor ? row.editor.monoFamily : "Consolas") : (row.editor ? row.editor.fontFamily : "Inter")
        font.pixelSize: row.fontPx
        font.bold: row.isHead || (row.t === "callout" && !!row.ctx.coHead)
        color: row.t === "callout" && !!row.ctx.coHead && !row.raw ? (row.editor ? row.editor.calloutColor(row.ctx.co) : Theme.textPrimary) : Theme.textPrimary
        selectByMouse: false
        activeFocusOnPress: false
        persistentSelection: true
        selectionColor: Mix.c(Theme.surface, Theme.accent, 0.3)
        selectedTextColor: Theme.textPrimary
        tabStopDistance: 4 * (row.editor ? row.editor.spaceWidth : 4)
        cursorVisible: row.raw && activeFocus
        cursorDelegate: Rectangle {
            width: 2
            color: Theme.accent
            // Qt creates a custom cursor item once and never hides it when its
            // TextEdit loses focus: every line the caret has visited keeps one.
            // It shows itself only on the
            // line that has the keyboard.
            visible: row.raw && te.activeFocus
            // Its own clock, so it holds still under a theme crossfade.
            opacity: (row.editor && row.editor.caretOn) || Theme.crossfading ? 1 : 0
        }
        Keys.onPressed: event => {
            if (row.editor)
                row.editor.keyPressed(row, event);
        }
        onTextChanged: {
            if (!row.programmatic && row.editor)
                row.editor.commitLine(row);
        }
    }

    // ---- rule --------------------------------------------------------------------------
    Rectangle {
        visible: row.t === "rule" && !row.raw
        x: row.sidePad
        width: row.width - 2 * row.sidePad
        y: Math.round(row.topPad + te.contentHeight / 2)
        height: 1
        color: row.editor ? row.editor.carveShadow : Theme.border
    }

    // ---- image -------------------------------------------------------------------------
    // The image itself, corners rounded, on no mount (not in a
    // shadowbox container). The box is on whole pixels so the four corners
    // come out identical. Decoded ONCE at a fixed size (RoundedImage.qml says
    // why a sourceSize that follows the width makes it flicker).
    Item {
        id: imageBox
        objectName: "imageBox"
        visible: row.showImage
        readonly property bool ready: img.status === Image.Ready
        readonly property real maxW: Math.max(40, row.width - 2 * row.sidePad)
        readonly property real natW: img.implicitWidth > 0 ? img.implicitWidth : 0
        readonly property real wantW: row.ctx.img && row.ctx.img.width > 0 ? row.ctx.img.width : imageBox.natW
        readonly property int w: Math.round(imageBox.ready ? Math.min(imageBox.maxW, imageBox.wantW) : Math.min(imageBox.maxW, 220))
        readonly property int h: imageBox.ready && imageBox.natW > 0 ? Math.round(imageBox.w * img.implicitHeight / imageBox.natW) : 48
        x: Math.round(row.sidePad)
        y: Math.round(row.topPad + (row.textHidden ? 0 : te.contentHeight + 4))
        width: imageBox.w
        height: imageBox.h
        // The slot while it loads, or where it is missing.
        Rectangle {
            anchors.fill: parent
            visible: !imageBox.ready
            radius: img.radius
            color: row.editor ? row.editor.sunk(Theme.panelSunk) : Theme.panelSunk
        }
        RoundedImage {
            id: img
            anchors.fill: parent
            radius: 8
            source: row.showImage && !row.imageMissing ? row.imageUrl : ""
            asynchronous: true
            cache: true
            // An SVG scales to whatever it is asked for: left at its own size.
            // scale-ok: a decode cap that keeps a huge photo from ballooning, 2x the widest a note shows (and what the glass makes of it at 2x)
            sourceSize.width: /\.svgz?$/i.test(row.imageUrl) ? 0 : 2048
        }
        Text {
            visible: !imageBox.ready
            anchors.centerIn: parent
            width: parent.width - 16
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            text: img.status === Image.Error || row.imageMissing ? "\u25A3  " + ((row.ctx.img && row.ctx.img.alt) || "image not found") : ""
            font.family: row.editor ? row.editor.fontFamily : "Inter"
            font.pixelSize: 10
            color: Theme.textFaint
        }
    }

    // ---- rendered table ----------------------------------------------------------------
    Item {
        id: tableBox
        objectName: "tableBox"
        visible: row.showTable
        x: row.sidePad
        y: row.topPad
        width: Math.min(row.width - 2 * row.sidePad, tableCol.implicitWidth + 2)
        height: tableCol.implicitHeight + 2
        ShadowBox {
            anchors.fill: parent
            baseWidth: tableBox.width
            baseHeight: tableBox.height
            baseRadius: 8
            bevelWidth: 1
            shadowWidth: 3
            surfaceColor: "transparent"
            bevelColor: row.editor ? row.editor.carveBevel : Theme.bevel
            shadowColor: row.editor ? row.editor.carveShadow : Theme.border
            backgroundColor: row.editor ? row.editor.sunk(Theme.listBox) : Theme.listBox
        }
        Column {
            id: tableCol
            objectName: "tableCol"
            x: 1
            y: 1
            Repeater {
                model: row.showTable ? row.tableRows.length : 0
                delegate: Row {
                    id: tr
                    required property int index
                    readonly property var cells: row.tableRows[tr.index] || []
                    readonly property var widths: row.cellWidths(tr.cells)
                    Repeater {
                        model: tr.cells.length
                        delegate: Rectangle {
                            id: cellBox
                            required property int index
                            readonly property var cell: tr.cells[cellBox.index]
                            width: tr.widths[cellBox.index] || 0
                            height: cellText.implicitHeight + 10
                            // The header row is a shade laid over the box, so
                            // the box's inset shadow still shows at its top,
                            // and its outer top corners follow the box's (8,
                            // one pixel in: 7) instead of poking out of them.
                            readonly property real cornerR: tr.index === 0 ? 7 : 0
                            topLeftRadius: cellBox.index === 0 ? cellBox.cornerR : 0
                            topRightRadius: cellBox.index === tr.cells.length - 1 ? cellBox.cornerR : 0
                            antialiasing: true
                            color: tr.index === 0 ? (row.editor ? row.editor.headerShade : Theme.headerBox) : "transparent"
                            Rectangle {
                                visible: tr.index > 0
                                width: parent.width
                                height: 1
                                color: row.editor ? row.editor.carveShadow : Theme.border
                            }
                            Text {
                                id: cellText
                                x: 8
                                y: 5
                                width: cellBox.width - 16
                                textFormat: Text.RichText
                                wrapMode: Text.Wrap
                                horizontalAlignment: cellBox.cell.align === "right" ? Text.AlignRight : (cellBox.cell.align === "center" ? Text.AlignHCenter : Text.AlignLeft)
                                text: cellBox.cell.html
                                font.family: row.editor ? row.editor.fontFamily : "Inter"
                                font.pixelSize: row.bodyPx
                                font.bold: tr.index === 0
                                color: Theme.textPrimary
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- folded frontmatter --------------------------------------------------------------
    Text {
        id: frontChip
        visible: row.showFront
        x: row.sidePad
        y: row.topPad
        text: "properties \u00B7 " + row.frontCount
        font.family: row.editor ? row.editor.fontFamily : "Inter"
        font.pixelSize: 10
        font.letterSpacing: 0.4
        color: Theme.textFaint
    }
}
