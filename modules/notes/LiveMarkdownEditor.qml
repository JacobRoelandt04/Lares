pragma ComponentBehavior: Bound

import QtQuick
import QtQml
import Quickshell
import Quickshell.Io

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/components/LiveMarkdown.js" as LM
import "../common/components/Markdown.js" as Md
import "../common/components/EditKeys.js" as EK

// =============================================================================
// LiveMarkdownEditor.qml -- an Obsidian-style live-preview markdown editor.
//
// The document is a LineDocument (lines + their own endings, one replace()
// primitive, undo). Each source line is one LiveMarkdownLine in a
// LineViewport (only what is on screen exists). The line holding the caret --
// and every line a selection touches -- is RAW: all of its characters, markers
// drawn faint, edited natively by its own TextEdit; every other line is
// RENDERED, markers omitted, with a map back to source columns.
//
// WHO DOES WHAT.
//   * Typing (and dead keys, AltGr, an input method) goes to the caret line's
//     TextEdit natively. Its onTextChanged diffs the TextEdit's text against
//     the model (raw text == source) and hands the difference to
//     doc.replace(); unchanged characters always come from the model, so
//     nothing the TextEdit normalises can reach the file.
//   * Everything that crosses lines or changes structure is ours, in
//     keyPressed(): Enter (list and quote continuation), Backspace/Delete at a
//     line's edge, caret movement (so there is ONE selection model -- the
//     document's -- not one per TextEdit), Tab, clipboard, undo, formatting.
//   * The mouse is ours too (one MouseArea over the rows): caret, drag
//     selection with edge auto-scroll, word and line selection, task boxes,
//     and Ctrl+click on links.
//
// The inline TITLE (the note's file name) is the viewport's header: a plain
// TextEdit above line 0 that Enter / Down leave into the body and Up on the
// first line climbs back into; it commits on leaving.
// =============================================================================
FocusScope {
    id: ed

    // ---- Contract ------------------------------------------------------------------
    property LineDocument doc: null
    // "markdown" (live preview) or "text" (plain, monospace, highlighted by
    // `language` when Markdown.js knows it).
    property string kind: "markdown"
    property string language: ""
    // The folder of the note's REAL file: relative image paths resolve there.
    property string realDir: ""
    property string homeDir: Quickshell.env("HOME") || ""
    property string title: ""
    property bool titleEditable: true
    property string titlePlaceholder: "Untitled"
    // What opens a link: "ctrl" (Ctrl+click) or "click" (a plain one does too; in the line being edited it puts the caret).
    property string linkClick: "ctrl"
    property string fontFamily: "Inter"
    property string monoFamily: "Consolas"
    property real bodySize: 12
    property real monoSize: 12
    property real titleSize: 22
    property real headScale: 1.0
    property real sidePadding: 12
    property real rowPad: 1.5
    property real lineHeightPct: 125
    property real titleGap: 8
    property bool colourBarEnabled: true
    readonly property alias viewport: vp
    readonly property alias titleItem: titleEdit
    readonly property bool hasSelection: ed.doc !== null && (ed.doc.anchor.line !== ed.doc.caret.line || ed.doc.anchor.col !== ed.doc.caret.col)

    signal escapePressed
    signal titleCommitted(string text)
    signal linkOpened(string href)
    signal wikiOpened(string target)
    signal pasteImageRequested

    // ---- Palette (strings for LiveMarkdown.js) ------------------------------------
    readonly property var mdPalette: ({
            faint: String(Theme.textFaint),
            muted: String(Theme.textMuted),
            link: String(Theme.accent),
            // Translucent (#AARRGGBB): inline code and keys are carved into
            // whatever ground the note has, with no re-render when it changes.
            codeBg: String(Mix.carve(Theme.surface, Theme.mdCode, Theme.shadowDeep)),
            codeFg: String(Theme.textPrimary),
            mark: String(Theme.mdMark),
            kbdBg: String(Mix.carve(Theme.surface, Theme.headerBox, Theme.shadowDeep)),
            named: {
                red: String(Theme.mdRed),
                orange: String(Theme.mdOrange),
                yellow: String(Theme.mdYellow),
                green: String(Theme.mdGreen),
                teal: String(Theme.mdTeal),
                blue: String(Theme.mdBlue),
                purple: String(Theme.mdPurple),
                pink: String(Theme.mdPink),
                gray: String(Theme.mdGray)
            },
            code: {
                kw: String(Theme.ansiBrightMagenta),
                str: String(Theme.ansiGreen),
                num: String(Theme.ansiYellow),
                com: String(Theme.textFaint),
                fn: String(Theme.ansiBlue),
                type: String(Theme.ansiCyan),
                op: String(Theme.textMuted),
                var: String(Theme.ansiBrightCyan),
                punc: String(Theme.textMuted)
            }
        })
    property int themeSerial: 0
    onMdPaletteChanged: {
        ed.themeSerial++;
        ed.refreshAll();
    }

    // ---- State -----------------------------------------------------------------------
    property var ctx: []
    property var rawSet: ({})
    property bool focusBody: false
    property real goalX: -1
    property int _lastKey: 0
    property bool ctrlHeld: false
    property bool caretOn: true
    property var _fenceCache: ({})
    property int _fenceSerial: 0
    property int _lastRunsSerial: 0
    property var blockRects: []
    property var _dragScene: null
    property int _clicks: 0
    property var _clickAt: null

    // ---- Metrics ------------------------------------------------------------------------
    FontMetrics {
        id: fm
        font.family: ed.fontFamily
        font.pixelSize: ed.bodySize
    }
    FontMetrics {
        id: fmMono
        font.family: ed.monoFamily
        font.pixelSize: ed.monoSize
    }
    // advanceWidth() in a binding captures nothing: read the font first.
    readonly property real spaceWidth: {
        const f = fm.font;
        return fm.advanceWidth(" ");
    }
    readonly property real avgChar: fm.averageCharacterWidth
    readonly property real monoChar: {
        const f = fmMono.font;
        return fmMono.advanceWidth("0");
    }

    function headPx(level) {
        return Md.headPx(ed.bodySize, level, ed.headScale);
    }
    // The height of one text line at `px`, with the editor's line height.
    function lineBox(px) {
        return Math.ceil(fm.height * (px / ed.bodySize) * ed.lineHeightPct / 100);
    }

    function calloutColor(kind) {
        switch (String(kind || "")) {
        case "tip":
        case "hint":
        case "important":
        case "abstract":
        case "summary":
        case "tldr":
            return Theme.mdTeal;
        case "success":
        case "check":
        case "done":
            return Theme.mdGreen;
        case "question":
        case "help":
        case "faq":
            return Theme.mdYellow;
        case "warning":
        case "caution":
        case "attention":
            return Theme.mdOrange;
        case "failure":
        case "fail":
        case "missing":
        case "danger":
        case "error":
        case "bug":
            return Theme.mdRed;
        case "example":
            return Theme.mdPurple;
        case "quote":
        case "cite":
            return Theme.mdGray;
        }
        return Theme.mdBlue;
    }
    function calloutGlyph(kind) {
        switch (String(kind || "")) {
        case "tip":
        case "hint":
        case "important":
            return "\uF0EB";
        case "abstract":
        case "summary":
        case "tldr":
            return "\uF0F6";
        case "info":
            return "\uF05A";
        case "todo":
            return "\uF14A";
        case "success":
        case "check":
        case "done":
            return "\uF00C";
        case "question":
        case "help":
        case "faq":
            return "\uF059";
        case "warning":
        case "caution":
        case "attention":
            return "\uF071";
        case "failure":
        case "fail":
        case "missing":
            return "\uF00D";
        case "danger":
        case "error":
            return "\uF0E7";
        case "bug":
            return "\uF188";
        case "example":
            return "\uF0CA";
        case "quote":
        case "cite":
            return "\uF10D";
        }
        return "\uF040";
    }
    function namedColour(name) {
        const k = "md" + name.charAt(0).toUpperCase() + name.substring(1);
        return Theme[k] !== undefined ? Theme[k] : Theme.textPrimary;
    }

    // ---- The document ------------------------------------------------------------------------
    Connections {
        target: ed.doc
        function onReplaced(from, removed, inserted) {
            ed._onReplaced(from, removed, inserted);
        }
        function onReloaded() {
            ed._reload();
        }
        // A caret that moved with no edit in the same turn is navigation (an
        // arrow, a click, a drag, an undo that went elsewhere): not writing.
        function onCaretChanged() {
            if (!ed._editTurn)
                ed._setWriting(false);
        }
    }
    onDocChanged: ed._reload()
    onKindChanged: ed._reload()
    Component.onCompleted: {
        titleEdit.text = ed.title;
        ed._reload();
    }
    onTitleChanged: {
        if (!titleEdit.activeFocus)
            titleEdit.text = ed.title;
    }

    function _opts() {
        return {
            kind: ed.kind
        };
    }

    // Bumped on every (re)load and part of every row's fill key: line revs
    // count from 1 in EVERY LineDocument, so a pooled row filled for one
    // note's line 4 would have the same key as the next note's line 4 and never be
    // refilled -- the second note opened would show lines of the first.
    property int _loadSerial: 0

    function _reload() {
        if (!ed.doc)
            return;
        ed._loadSerial++;
        // Another note, or this one read again: nothing is being written.
        ed._writing = false;
        writeIdle.stop();
        yieldAnim.stop();
        ed.footYield = 0;
        ed.spanFocus = null;
        ed.hoverSpan = null;
        ed.ctx = LM.contextAll(ed.doc.lines, ed._opts());
        ed._fenceCache = {};
        ed.rawSet = {};
        ed.goalX = -1;
        vp.pinned = -1;
        vp.count = ed.doc.lineCount;
        vp.reset();
        ed._updateBlocks();
    }

    function _onReplaced(from, removed, inserted) {
        ed._noteEdit();
        // Columns moved: a hovered span is found again when the pointer moves.
        ed.hoverSpan = null;
        const upd = LM.contextUpdate(ed.doc.lines, ed.ctx, from, from + removed, from + inserted, ed._opts());
        ed.ctx = upd.ctx;
        ed._fenceCache = {};
        vp.count = ed.doc.lineCount;
        if (vp.pinned >= ed.doc.lineCount)
            vp.pinned = ed.doc.lineCount - 1;
        ed._computeRawSet();
        vp.linesChanged(from, removed, inserted);
        ed.refreshAll();
    }

    // ---- Filling a row -------------------------------------------------------------------

    function _sig(c) {
        if (c._sig === undefined)
            c._sig = c.t + "/" + c.cs + "/" + (c.lv || 0) + "/" + (c.task === null || c.task === undefined ? "-" : c.task) + "/" + (c.qd || 0) + "/" + (c.co || "") + (c.coHead ? "h" : "") + "/" + (c.lang || "") + "/" + (c.hin ? c.hin.length : 0) + "/" + (c.ord ? c.num : "") + "/" + (c.lvl || 0);
        return c._sig;
    }

    // The code runs for a line of a fence (or of a plain-text file).
    function _codeRuns(i, c) {
        if (ed.kind === "text")
            return Md.highlight(ed.doc.lines[i], ed.language).filter(r => r.text.length > 0);
        if (c.t !== "fenceBody")
            return null;
        let open = i;
        while (open > 0 && ed.ctx[open].t === "fenceBody")
            --open;
        let close = i;
        while (close < ed.ctx.length && ed.ctx[close].t === "fenceBody")
            ++close;
        const key = open + ":" + close + ":" + ed.doc.revs.slice(open, close).join(",");
        let hit = ed._fenceCache[open];
        if (!hit || hit.key !== key) {
            hit = {
                key: key,
                serial: ++ed._fenceSerial,
                runs: LM.fenceRuns(ed.doc.lines, open, close, c.lang || "")
            };
            ed._fenceCache[open] = hit;
        }
        ed._lastRunsSerial = hit.serial;
        return hit.runs[i - open - 1] || [];
    }

    function _lh(html) {
        return html.replace('<div style="white-space:pre-wrap">', '<div style="white-space:pre-wrap; line-height:' + ed.lineHeightPct + '%">');
    }

    function _tableLines(i) {
        let e = i + 1;
        while (e < ed.ctx.length && (ed.ctx[e].t === "tdelim" || ed.ctx[e].t === "trow"))
            ++e;
        return e;
    }

    function _tableRows(i, width) {
        const end = ed._tableLines(i);
        const rows = [];
        const c = ed.ctx[i];
        const cols = c.cols || 1;
        const lines = [i];
        for (let k = i + 2; k < end; ++k)
            lines.push(k);
        const cells = lines.map(k => {
            const a = Md.cellsOf(ed.doc.lines[k]);
            while (a.length < cols)
                a.push("");
            return a.slice(0, cols);
        });
        // Column widths from the longest cell, within the available width.
        const nat = [];
        for (let col = 0; col < cols; ++col) {
            let m = 3;
            for (const r of cells)
                m = Math.max(m, r[col].length);
            nat.push(Math.min(60, m) * ed.avgChar + 16);
        }
        // Columns as FRACTIONS of the table's width: the row lays them out at
        // its live width, so a popup resized after the fill never pushes a
        // column past the table (the header row poked out on a narrow popup).
        const avail = Math.max(80, width - 2 * ed.sidePadding - 2);
        const fit = Md.fitColumns(nat, nat.map(() => 48), avail, 0);
        for (const r of cells)
            rows.push(r.map((cell, col) => ({
                            html: LM.cellHtml(cell, ed.mdPalette, {
                                monoFamily: ed.monoFamily
                            }),
                            frac: (fit[col] || nat[col]) / avail,
                            align: (c.align && c.align[col]) || ""
                        })));
        return rows;
    }

    function fill(row) {
        const i = row.lineIndex;
        if (i < 0 || !ed.doc || i >= ed.doc.lineCount)
            return;
        const c = ed.ctx[i] || {
            t: "blank",
            cs: 0
        };
        const raw = ed.kind === "text" || !!ed.rawSet[i];
        let key = ed._loadSerial + ":" + ed.doc.revs[i] + "|" + ed._sig(c) + "|" + raw + "|" + ed.themeSerial;
        const runs = ed._codeRuns(i, c);
        if (runs)
            key += "|r" + (ed.kind === "text" ? "" : ed._lastRunsSerial);
        if (c.t === "thead" && !raw) {
            const end = ed._tableLines(i);
            key += "|" + ed.doc.revs.slice(i, end).join(",");
        }
        if (c.t === "front" && i === 0)
            key += "|" + ed.ctx.filter(x => x.t === "front").length;
        if (c.t === "image")
            key += "|i" + ed._imgSerial;
        if (row.fillKey === key)
            return ed._applySelection(row);
        const line = ed.doc.lines[i];
        const opt = {
            monoFamily: ed.monoFamily,
            codeRuns: runs
        };
        row.ctx = c;
        row.raw = raw;
        if (raw) {
            row.setHtml(ed._lh(LM.rawHtml(line, c, ed.mdPalette, opt)));
            row.r2s = null;
        } else {
            const r = LM.renderLine(line, c, ed.mdPalette, opt);
            row.setHtml(ed._lh(r.html));
            row.r2s = r.r2s;
        }
        const url = c.t === "image" && c.img ? LM.resolveSrc(c.img.src, ed.realDir, ed.homeDir) : "";
        const seen = url ? ed._imageState(url) : "";
        row.imageUrl = seen === "ok" ? url : "";
        row.imageMissing = seen === "missing";
        row.tableRows = c.t === "thead" && !raw ? ed._tableRows(i, row.width) : [];
        if (c.t === "front" && i === 0) {
            let n = 0;
            for (let k = 1; k < ed.ctx.length && ed.ctx[k].t === "front"; ++k)
                ++n;
            row.frontCount = Math.max(0, n - 1);
        }
        row.fillKey = key;
        ed._applySelection(row);
    }

    function refreshAll() {
        for (const row of vp.assignedItems())
            ed.fill(row);
        ed._updateBlocks();
    }

    // ---- Raw set and selection ---------------------------------------------------------

    function _selRange() {
        const a = ed.doc.anchor, b = ed.doc.caret;
        return ed.doc.cmp(a, b) <= 0 ? [a, b] : [b, a];
    }

    function _computeRawSet() {
        const set = {};
        if (ed.doc && ed.focusBody && ed.kind !== "text") {
            const r = ed._selRange();
            let lo = r[0].line, hi = r[1].line;
            // A table, the frontmatter and a setext pair reveal as a whole.
            const T = k => ed.ctx[k] ? ed.ctx[k].t : "";
            while (lo > 0 && (T(lo) === "tdelim" || T(lo) === "trow"))
                --lo;
            if (T(hi) === "thead" || T(hi) === "tdelim" || T(hi) === "trow")
                while (T(hi + 1) === "tdelim" || T(hi + 1) === "trow")
                    ++hi;
            if (T(lo) === "front")
                lo = 0;
            if (T(hi) === "front")
                while (T(hi + 1) === "front")
                    ++hi;
            if (T(lo) === "setextU" && lo > 0)
                --lo;
            if (T(hi) === "setext" && T(hi + 1) === "setextU")
                ++hi;
            for (let i = lo; i <= hi; ++i)
                set[i] = true;
            // A span picked for the colour bar keeps its line rendered.
            if (ed.spanFocus && ed._spanFocusValid())
                delete set[ed.spanFocus.line];
        }
        ed.rawSet = set;
    }

    // ---- Coloured spans without their markup ------------------------------------------------
    // Colouring from the bar shows the colour at once, not
    // the <span> it wrote; the markup appears only when the caret goes back
    // into the text. A span can be PICKED (`spanFocus`, source columns of its
    // text): its line stays rendered while the selection is exactly that
    // text, the row paints the pick under the text (so the colour stays
    // visible), the colour bar sits on it, and the keyboard goes to a key
    // sink here rather than to a rendered line's TextEdit (text typed there
    // would never reach the document). Colouring picks the span it made or
    // rewrote; a click on a coloured span of a rendered line picks it, the
    // pointer over one tints it faintly (`hoverSpan`). A second click on the
    // picked span, any key, or any other caret move leaves the pick.
    property var spanFocus: null
    property var hoverSpan: null
    // The spans of line i: {s0, s1} = their text, in source columns.
    function spansOf(i) {
        if (!ed.doc || i < 0 || i >= ed.doc.lineCount)
            return [];
        const line = ed.doc.lines[i];
        const out = [];
        const re = /<span style="[^"]*">((?:(?!<span)[\s\S])*?)<\/span>/g;
        let m;
        while ((m = re.exec(line)) !== null) {
            const s0 = m.index + m[0].length - m[1].length - 7;
            out.push({
                line: i,
                s0: s0,
                s1: s0 + m[1].length
            });
        }
        return out;
    }
    function _spanAt(i, col) {
        for (const sp of ed.spansOf(i))
            if (col >= sp.s0 && col <= sp.s1 && sp.s1 > sp.s0)
                return sp;
        return null;
    }
    function _spanFocusValid() {
        const f = ed.spanFocus;
        if (!f || !ed.doc || !ed.hasSelection)
            return false;
        const r = ed._selRange();
        return r[0].line === f.line && r[1].line === f.line && r[0].col === f.s0 && r[1].col === f.s1;
    }
    function pickSpan(line, s0, s1) {
        ed.spanFocus = {
            line: line,
            s0: s0,
            s1: s1
        };
        ed.doc.setCaret({
            line: line,
            col: s1
        }, {
            line: line,
            col: s0
        });
        ed.afterCaretMove(false, false);
    }
    function leaveSpan() {
        if (!ed.spanFocus)
            return;
        ed.spanFocus = null;
        ed._computeRawSet();
        ed.refreshAll();
        const row = vp.delegateFor(ed.doc.caret.line);
        if (row) {
            row.edit.forceActiveFocus();
            ed._applySelection(row);
        }
    }
    // The first key while a span is picked: out of the pick, then the key
    // does what it does on the line with the markup shown.
    function _spanKey(e) {
        const k = e.key;
        if (k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_Meta || k === Qt.Key_AltGr)
            return;
        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
        const doc = ed.doc;
        const r = ed._selRange();
        ed.leaveSpan();
        e.accepted = true;
        if (k === Qt.Key_Escape) {
            doc.setCaret(r[1]);
            ed.afterCaretMove(false, false);
            return;
        }
        if (!doc.readOnly && !ctrl && (k === Qt.Key_Backspace || k === Qt.Key_Delete || (e.text.length > 0 && e.text.charCodeAt(0) >= 32))) {
            doc.breakUndoGroup();
            const text = k === Qt.Key_Backspace || k === Qt.Key_Delete ? "" : e.text;
            const end = doc.replace(r[0].line, r[0].col, r[1].line, r[1].col, text, {
                kind: text ? "type" : "del"
            });
            doc.setCaret(end);
            ed.afterCaretMove(true, false);
            return;
        }
        const row = vp.delegateFor(doc.caret.line);
        e.accepted = false;
        if (row)
            ed.keyPressed(row, e);
    }
    Item {
        id: spanKeys
        Keys.onPressed: e => ed._spanKey(e)
    }

    function _applySelection(row) {
        const i = row.lineIndex;
        if (!row.raw || !ed.doc) {
            row.edit.deselect();
            return;
        }
        const r = ed._selRange();
        const lo = r[0], hi = r[1];
        const isCaret = i === ed.doc.caret.line;
        if (lo.line === hi.line && lo.col === hi.col) {
            row.edit.deselect();
            if (isCaret)
                row.edit.cursorPosition = Math.min(ed.doc.caret.col, row.edit.length);
            return;
        }
        if (i < lo.line || i > hi.line) {
            row.edit.deselect();
            return;
        }
        const len = row.edit.length;
        const a = i === lo.line ? lo.col : 0;
        const b = i === hi.line ? hi.col : len;
        if (isCaret) {
            const caretCol = ed.doc.caret.col;
            const other = caretCol === a ? b : a;
            row.edit.select(Math.min(other, len), Math.min(caretCol, len));
        } else {
            row.edit.select(Math.min(a, len), Math.min(b, len));
        }
    }

    // After the caret or the selection moved: which lines are raw, who has
    // focus, what is on screen.
    function afterCaretMove(scroll, keepGoal) {
        if (!ed.doc)
            return;
        if (!keepGoal)
            ed.goalX = -1;
        if (ed.spanFocus && !ed._spanFocusValid())
            ed.spanFocus = null;
        ed.focusBody = true;
        ed.caretOn = true;
        vp.pinned = ed.doc.caret.line;
        ed._computeRawSet();
        vp.relayout();
        ed.refreshAll();
        const row = vp.delegateFor(ed.doc.caret.line);
        if (row) {
            if (ed.spanFocus)
                spanKeys.forceActiveFocus();
            else if (!row.edit.activeFocus)
                row.edit.forceActiveFocus();
            ed._applySelection(row);
            if (scroll) {
                const rect = row.edit.positionToRectangle(Math.min(ed.doc.caret.col, row.edit.length));
                vp.ensureVisible(ed.doc.caret.line, row.edit.y + rect.y, row.edit.y + rect.y + rect.height);
            }
        }
        ed._updateColourBar();
    }

    function setCaret(pos, anchor, scroll) {
        ed.doc.setCaret(pos, anchor);
        ed.afterCaretMove(scroll !== false, false);
    }

    function focusTitle(atEnd) {
        ed._setWriting(false);
        ed.focusBody = false;
        ed._computeRawSet();
        ed.refreshAll();
        titleEdit.forceActiveFocus();
        titleEdit.cursorPosition = atEnd === false ? 0 : titleEdit.length;
        vp.flick.contentY = 0;
        ed._updateColourBar();
    }

    function focusBodyAt(pos) {
        ed.doc.setCaret(pos || {
            line: 0,
            col: 0
        });
        ed.afterCaretMove(true, false);
    }

    // ---- Committing typed text -----------------------------------------------------------

    function commitLine(row) {
        if (!ed.doc || ed.doc.readOnly || !row.raw || row.lineIndex < 0)
            return;
        if (row.edit.inputMethodComposing)
            return;
        const i = row.lineIndex;
        const now = row.edit.getText(0, row.edit.length);
        const src = ed.doc.lines[i];
        const shown = src.replace(/\r/g, "\u240D");
        if (now === shown)
            return;
        let p = 0;
        while (p < shown.length && p < now.length && shown.charCodeAt(p) === now.charCodeAt(p))
            ++p;
        let s = 0;
        while (s < shown.length - p && s < now.length - p && shown.charCodeAt(shown.length - 1 - s) === now.charCodeAt(now.length - 1 - s))
            ++s;
        const inserted = now.substring(p, now.length - s).replace(/[\u2028\u2029]/g, "\n");
        const removedLen = shown.length - s - p;
        const k = ed._lastKey;
        const kind = k === Qt.Key_Backspace ? "del" : (k === Qt.Key_Delete ? "fdel" : (removedLen === 0 && inserted.length > 0 ? "type" : ""));
        const cur = row.edit.cursorPosition;
        const end = ed.doc.replace(i, p, i, p + removedLen, inserted, {
            kind: kind,
            keepCaret: true
        });
        const pos = inserted.indexOf("\n") >= 0 ? end : {
            line: i,
            col: cur
        };
        ed.doc.setCaret(pos);
        ed._lastKey = 0;
        ed.afterCaretMove(true, false);
    }

    // ---- Keys ---------------------------------------------------------------------------------

    function keyPressed(row, e) {
        if (!ed.doc)
            return;
        ed._lastKey = e.key;
        ed.caretOn = true;
        if (ed._pre)
            ed._clearPreedit();
        if (e.key === Qt.Key_Control) {
            ed.ctrlHeld = true;
            return;
        }
        const mods = e.modifiers;
        const ctrl = (mods & Qt.ControlModifier) !== 0;
        const shift = (mods & Qt.ShiftModifier) !== 0;
        const doc = ed.doc;
        const accept = () => {
            e.accepted = true;
        };

        if (e.matches(StandardKey.Undo)) {
            if (doc.undo())
                ed.afterCaretMove(true, false);
            return accept();
        }
        if (e.matches(StandardKey.Redo) || (ctrl && e.key === Qt.Key_Y)) {
            if (doc.redo())
                ed.afterCaretMove(true, false);
            return accept();
        }
        if (e.matches(StandardKey.Copy)) {
            if (ed.hasSelection)
                Quickshell.clipboardText = doc.selectedText();
            return accept();
        }
        if (e.matches(StandardKey.Cut)) {
            if (ed.hasSelection && !doc.readOnly) {
                Quickshell.clipboardText = doc.selectedText();
                ed._deleteSelection("");
            }
            return accept();
        }
        if (e.matches(StandardKey.Paste)) {
            ed.paste();
            return accept();
        }
        if (e.matches(StandardKey.SelectAll)) {
            const last = doc.lineCount - 1;
            doc.setCaret({
                line: last,
                col: doc.lines[last].length
            }, {
                line: 0,
                col: 0
            });
            ed.afterCaretMove(false, false);
            return accept();
        }
        if (e.key === Qt.Key_Escape) {
            if (ed.hasSelection) {
                doc.setCaret(doc.caret);
                ed.afterCaretMove(false, false);
            } else {
                ed.escapePressed();
            }
            return accept();
        }
        const wrap = {
            [Qt.Key_B]: ["**", false],
            [Qt.Key_I]: ["*", false],
            [Qt.Key_X]: ["~~", true]
        }[e.key];
        if (ctrl && wrap && shift === wrap[1]) {
            ed.wrapSelection(wrap[0], wrap[0]);
            return accept();
        }
        if (ctrl && !shift && e.key === Qt.Key_K) {
            ed.insertLink();
            return accept();
        }

        if (ed._readline(e))
            return accept();

        switch (e.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            ed._enter(shift);
            return accept();
        case Qt.Key_Backspace:
            if (ed._backspace(ctrl))
                accept();
            return;
        case Qt.Key_Delete:
            if (ed._delete())
                accept();
            return;
        case Qt.Key_Left:
        case Qt.Key_Right:
        case Qt.Key_Up:
        case Qt.Key_Down:
        case Qt.Key_Home:
        case Qt.Key_End:
        case Qt.Key_PageUp:
        case Qt.Key_PageDown:
            ed._move(e.key, shift, ctrl);
            return accept();
        case Qt.Key_Tab:
        case Qt.Key_Backtab:
            ed._tab(e.key === Qt.Key_Backtab || shift);
            return accept();
        }
        // Printable over a selection: replace it ourselves (it may span lines).
        if (e.text.length > 0 && !ctrl && ed.hasSelection && e.text.charCodeAt(0) >= 32) {
            ed._replaceSelection(e.text, "");
            return accept();
        }
    }

    // The terminal's editing keys (EditKeys.js) on the caret's own LINE of the document. Ctrl+A stays "select all", Ctrl+K
    // inserts a link and Ctrl+Backspace is _backspace's (it joins lines and takes a list marker first): none of the three
    // comes here. A word kill never crosses a line, and at a line's edge it does nothing (Backspace/Delete join lines).
    function _readline(e) {
        const action = EK.actionOf(e.key, e.modifiers, true);
        if (action === null || (e.key === Qt.Key_Backspace && (e.modifiers & Qt.ControlModifier)))
            return false;
        const doc = ed.doc;
        const c = doc.caret;
        switch (action) {
        case "lineEnd":
            ed._move(Qt.Key_End, false, false);
            return true;
        case "lineStart":
            ed._move(Qt.Key_Home, false, false);
            return true;
        case "wordBack":
            ed._move(Qt.Key_Left, false, true);
            return true;
        case "wordForward":
            ed._move(Qt.Key_Right, false, true);
            return true;
        }
        if (doc.readOnly)
            return true;
        if (ed.hasSelection) {
            ed._deleteSelection("");
            return true;
        }
        const p = EK.plan(action, doc.lines[c.line], c.col, c.col, c.col);
        if (p.to > p.from) {
            doc.replace(c.line, p.from, c.line, p.to, "", {
                kind: ""
            });
            ed.afterCaretMove(true, false);
        }
        return true;
    }

    function keyReleased(e) {
        if (e.key === Qt.Key_Control)
            ed.ctrlHeld = false;
    }

    function _replaceSelection(text, kind) {
        const r = ed._selRange();
        ed.doc.breakUndoGroup();
        ed.doc.replace(r[0].line, r[0].col, r[1].line, r[1].col, text, {
            kind: kind
        });
        ed.afterCaretMove(true, false);
    }

    function _deleteSelection(kind) {
        ed._replaceSelection("", kind || "");
    }

    function paste() {
        if (!ed.doc || ed.doc.readOnly)
            return;
        const t = Quickshell.clipboardText;
        if (t && t.length > 0) {
            ed.doc.breakUndoGroup();
            ed._replaceSelection(String(t).replace(/[\u2028\u2029]/g, "\n"), "");
            ed.doc.breakUndoGroup();
        } else {
            ed.pasteImageRequested();
        }
    }

    // Insert text at the caret (replacing a selection) -- an attached image link.
    function insertText(text) {
        ed._replaceSelection(text, "");
    }

    // An image link on a line of its own: the caret's line when it is empty, else a new line below it (an image
    // line renders only when the line holds nothing else), the caret left after it on a fresh empty line.
    function insertImageLine(md) {
        if (!ed.doc || ed.doc.readOnly)
            return;
        const doc = ed.doc;
        doc.breakUndoGroup();
        if (ed.hasSelection)
            ed._deleteSelection("");
        const c = doc.caret;
        const line = doc.lines[c.line];
        if (line.trim() === "") {
            doc.replace(c.line, 0, c.line, line.length, md + "\n");
        } else {
            doc.replace(c.line, line.length, c.line, line.length, "\n" + md + "\n");
        }
        doc.breakUndoGroup();
        ed.afterCaretMove(true, false);
    }

    // ---- Dictation ------------------------------------------------------------------------------
    // The notes popup's dictation contract lands here. Text is committed through the same
    // doc.replace() path as a paste (the caret's line is raw, so a rendered line never takes it); the
    // PREEDIT is never in the document: it is put into the caret line's TextEdit under its
    // `programmatic` guard (the model is never told), underlined by a bar per visual line that is a
    // child of that TextEdit (it scrolls with it), and taken out again before anything else happens
    // (a key, a click, the next preedit, a commit).
    readonly property bool dictationActive: ed.doc !== null && !ed.doc.readOnly && ed.activeFocus && (titleEdit.activeFocus ? ed.titleEditable : ed.focusBody)
    property var _pre: null
    Component {
        id: preeditBar
        Rectangle {
            height: 1
            color: Theme.accent
        }
    }

    function _dictationTarget() {
        if (titleEdit.activeFocus)
            return { te: titleEdit, row: null };
        const row = vp.delegateFor(ed.doc.caret.line);
        return row && row.raw && row.edit.activeFocus ? { te: row.edit, row: row } : null;
    }

    // A row's TextEdit is RICH text, and `insert` on it reads its argument as HTML (round 8, the user's "while I was speaking
    // there was more text than there should have been"): the SPACE every piece after a word starts with was dropped, so the clear of
    // the old preedit found other text than it had put in, left it standing and the next one went in beside it -- the live words
    // stacked ("alphaw0 w1w0 beta") until the commit rewrote the line --, and "&", "<" and ">" of speech were markup. So the text
    // goes in as HTML that reads as itself (a space at either end as a no-break one, which is not collapsed), what came in is MEASURED
    // (the edit's length before and after), and the clear looks for the preedit by that place and size, comparing plain text with the
    // no-break spaces read as spaces. A title edit is plain text and takes the words as they are.
    function _preeditHtml(t) {
        let h = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        if (h.charAt(0) === " ")
            h = "&nbsp;" + h.substring(1);
        if (h.length > 1 && h.charAt(h.length - 1) === " ")
            h = h.substring(0, h.length - 1) + "&nbsp;";
        return h;
    }

    // Takes the shown preedit out. Only what is still there is removed (a refresh of the line rebuilds its text and takes the
    // preedit with it: the range is then past the text or holds other words, and nothing is touched).
    function _clearPreedit() {
        const p = ed._pre;
        ed._pre = null;
        if (!p || !p.te)
            return;
        for (const b of p.bars)
            if (b)
                b.destroy();
        const te = p.te;
        const end = p.pos + p.len;
        if (end <= te.length && te.getText(p.pos, end).replace(/\u00a0/g, " ") === p.text) {
            if (p.row)
                p.row.programmatic = true;
            te.remove(p.pos, end);
            if (p.row)
                p.row.programmatic = false;
            te.cursorPosition = p.pos;
        }
    }

    // true: the words are shown (or taken away, for ""), false: there was nothing to show them in (the contract answers it)
    function dictationPreedit(text) {
        ed._clearPreedit();
        const t = String(text || "").replace(/[\r\n\u2028\u2029]+/g, " ");
        if (t === "")
            return true;
        if (!ed.dictationActive)
            return false;
        const tg = ed._dictationTarget();
        if (!tg)
            return false;
        const te = tg.te;
        const col = tg.row ? Math.min(ed.doc.caret.col, te.length) : te.cursorPosition;
        const before = te.length;
        if (tg.row)
            tg.row.programmatic = true;
        te.insert(col, te.textFormat === TextEdit.RichText ? ed._preeditHtml(t) : t);
        if (tg.row)
            tg.row.programmatic = false;
        const len = te.length - before;       // what really came in
        if (len <= 0)
            return false;
        te.cursorPosition = col;
        const bars = [];
        let y0 = null, x0 = 0, xe = 0, h = 0;
        for (let k = col; k <= col + len; k++) {
            const a = te.positionToRectangle(k);
            if (y0 !== null && (k === col + len || a.y !== y0)) {
                bars.push(preeditBar.createObject(te, { x: x0, y: y0 + h - 1, width: Math.max(1, Math.round(xe - x0)) }));
                y0 = null;
            }
            if (k === col + len)
                break;
            const b = te.positionToRectangle(k + 1);
            if (y0 === null) {
                y0 = a.y;
                x0 = a.x;
                h = a.height;
            }
            xe = b.y === a.y ? b.x : te.width;
        }
        ed._pre = { te: te, row: tg.row, pos: col, len: len, text: t, bars: bars };
        return true;
    }

    // The text before the caret on its line (dictation's spacing: a piece after a word gets its space).
    function dictationBefore() {
        if (titleEdit.activeFocus)
            return titleEdit.text.substring(0, titleEdit.cursorPosition);
        const c = ed.doc.caret;
        return String(ed.doc.lines[c.line] || "").substring(0, c.col);
    }

    // true: the text is in the note; false: nothing took it (the service then keeps it for the clipboard, never counts it delivered)
    function dictationCommit(text) {
        ed._clearPreedit();
        const t = String(text || "").replace(/[\u2028\u2029]/g, "\n");
        if (t === "" || !ed.dictationActive)
            return false;
        if (titleEdit.activeFocus) {
            titleEdit.insert(titleEdit.cursorPosition, t.replace(/[\n\/]+/g, " "));
            return true;
        }
        ed.doc.breakUndoGroup();
        ed._replaceSelection(t, "");
        ed.doc.breakUndoGroup();
        return true;
    }

    function _lineStartPrefix(i) {
        const c = ed.ctx[i];
        const line = ed.doc.lines[i];
        if (c.t === "list") {
            const lead = line.match(/^[ \t]*/)[0];
            let mk = c.mk;
            if (c.ord) {
                const delim = c.mk.slice(-1);
                mk = (c.num + 1) + delim;
            }
            return lead + mk + " " + (c.task !== null && c.task !== undefined ? "[ ] " : "");
        }
        if (c.t === "quote" || c.t === "callout") {
            const m = line.match(/^(?: {0,3}>[ ]?)+/);
            return m ? m[0] : "> ";
        }
        return null;
    }

    // Enter splits the line at the caret (a list or quote continues). Shift+Enter, as in VS Code, opens a NEW EMPTY
    // line below the caret's line and moves there: the text after the caret stays where it was.
    function _enter(shift) {
        const doc = ed.doc;
        if (doc.readOnly)
            return;
        doc.breakUndoGroup();
        if (ed.hasSelection)
            ed._deleteSelection("");
        const c = doc.caret;
        const x = ed.ctx[c.line];
        const line = doc.lines[c.line];
        if (shift) {
            const end = line.length;
            doc.replace(c.line, end, c.line, end, "\n");
            doc.breakUndoGroup();
            ed.afterCaretMove(true, false);
            return;
        }
        if (ed.kind === "markdown" && (x.t === "list" || x.t === "quote" || x.t === "callout")) {
            const content = line.substring(x.cs);
            if (content.trim() === "" && c.col >= x.cs) {
                // An empty item ends the list (or the quote).
                doc.replace(c.line, 0, c.line, line.length, "");
                ed.afterCaretMove(true, false);
                return;
            }
            const prefix = ed._lineStartPrefix(c.line);
            doc.replace(c.line, c.col, c.line, c.col, "\n" + prefix);
        } else {
            doc.replace(c.line, c.col, c.line, c.col, "\n");
        }
        doc.breakUndoGroup();
        ed.afterCaretMove(true, false);
    }

    // Returns true when handled (the TextEdit must not also act).
    function _backspace(ctrl) {
        const doc = ed.doc;
        if (doc.readOnly)
            return true;
        if (ed.hasSelection) {
            ed._deleteSelection("del");
            return true;
        }
        const c = doc.caret;
        if (c.col === 0) {
            if (c.line === 0) {
                if (ed.titleEditable)
                    ed.focusTitle(true);
                return true;
            }
            const prevLen = doc.lines[c.line - 1].length;
            doc.replace(c.line - 1, prevLen, c.line, 0, "", {
                kind: "del"
            });
            ed.afterCaretMove(true, false);
            return true;
        }
        const x = ed.ctx[c.line];
        if (ed.kind === "markdown" && x.t === "list" && c.col === x.cs && x.cs > 0) {
            // At an item's content start: the marker goes, the text stays.
            doc.replace(c.line, 0, c.line, x.cs, "", {
                kind: ""
            });
            ed.afterCaretMove(true, false);
            return true;
        }
        if (ctrl) {
            const w = ed._wordLeft(c);
            doc.replace(w.line, w.col, c.line, c.col, "", {
                kind: ""
            });
            ed.afterCaretMove(true, false);
            return true;
        }
        return false;
    }

    function _delete() {
        const doc = ed.doc;
        if (doc.readOnly)
            return true;
        if (ed.hasSelection) {
            ed._deleteSelection("fdel");
            return true;
        }
        const c = doc.caret;
        if (c.col >= doc.lines[c.line].length) {
            if (c.line < doc.lineCount - 1) {
                doc.replace(c.line, c.col, c.line + 1, 0, "", {
                    kind: "fdel"
                });
                ed.afterCaretMove(true, false);
            }
            return true;
        }
        return false;
    }

    function _tab(back) {
        const doc = ed.doc;
        if (doc.readOnly)
            return;
        const c = doc.caret;
        const x = ed.ctx[c.line];
        if (ed.kind === "markdown" && x.t === "list") {
            const line = doc.lines[c.line];
            const unit = line.charAt(0) === "\t" ? "\t" : (x.ord ? "   " : "  ");
            doc.breakUndoGroup();
            if (!back) {
                doc.replace(c.line, 0, c.line, 0, unit, {
                    keepCaret: true
                });
                doc.setCaret({
                    line: c.line,
                    col: c.col + unit.length
                });
            } else {
                const lead = line.match(/^[ \t]*/)[0];
                const cut = lead.charAt(0) === "\t" ? 1 : Math.min(lead.length, unit === "\t" ? 1 : unit.length);
                if (cut > 0) {
                    doc.replace(c.line, 0, c.line, cut, "", {
                        keepCaret: true
                    });
                    doc.setCaret({
                        line: c.line,
                        col: Math.max(0, c.col - cut)
                    });
                }
            }
            ed.afterCaretMove(true, false);
            return;
        }
        if (!back)
            ed._replaceSelection("\t", "type");
    }

    // ---- Formatting ----------------------------------------------------------------------------

    function wrapSelection(open, close) {
        const doc = ed.doc;
        if (!doc || doc.readOnly)
            return;
        doc.breakUndoGroup();
        if (!ed.hasSelection) {
            const c = doc.caret;
            doc.replace(c.line, c.col, c.line, c.col, open + close);
            doc.setCaret({
                line: c.line,
                col: c.col + open.length
            });
            ed.afterCaretMove(true, false);
            return;
        }
        const r = ed._selRange();
        const lo = r[0], hi = r[1];
        // Already wrapped exactly (one line): unwrap.
        if (lo.line === hi.line) {
            const line = doc.lines[lo.line];
            if (line.substring(lo.col - open.length, lo.col) === open && line.substring(hi.col, hi.col + close.length) === close) {
                doc.beginCompound();
                doc.replace(hi.line, hi.col, hi.line, hi.col + close.length, "");
                doc.replace(lo.line, lo.col - open.length, lo.line, lo.col, "");
                doc.endCompound();
                doc.setCaret({
                    line: hi.line,
                    col: hi.col - open.length
                }, {
                    line: lo.line,
                    col: lo.col - open.length
                });
                ed.afterCaretMove(true, false);
                return;
            }
        }
        doc.beginCompound();
        for (let i = hi.line; i >= lo.line; --i) {
            const len = doc.lines[i].length;
            const a = i === lo.line ? lo.col : 0;
            const b = i === hi.line ? hi.col : len;
            if (b <= a)
                continue;
            doc.replace(i, b, i, b, close);
            doc.replace(i, a, i, a, open);
        }
        doc.endCompound();
        // The wrapped text stays selected, so the same key unwraps it again.
        doc.setCaret({
            line: hi.line,
            col: Math.min(doc.lines[hi.line].length, hi.col + open.length)
        }, {
            line: lo.line,
            col: lo.col + open.length
        });
        ed.afterCaretMove(true, false);
    }

    // Colour the selection. When it already IS a colour span's text (the
    // words inside the tags, or the whole span with them), that span's
    // colour is rewritten -- picking a second colour must not nest a second
    // span. The empty name takes the colour away (and the span, when it
    // carried nothing else).
    function colourSelection(name) {
        const doc = ed.doc;
        if (!doc || doc.readOnly)
            return;
        const r = ed._selRange();
        const lo = r[0], hi = r[1];
        if (ed.hasSelection && lo.line === hi.line) {
            const line = doc.lines[lo.line];
            const sel = line.substring(lo.col, hi.col);
            let span = null;
            const mo = /<span style="([^"]*)">$/.exec(line.substring(0, lo.col));
            if (mo && line.substring(hi.col, hi.col + 7) === "</span>")
                span = {
                    open: lo.col - mo[0].length,
                    openEnd: lo.col,
                    close: hi.col,
                    style: mo[1]
                };
            const mw = /^<span style="([^"]*)">([\s\S]*)<\/span>$/.exec(sel);
            if (!span && mw && mw[2].indexOf("<span") < 0)
                span = {
                    open: lo.col,
                    openEnd: lo.col + sel.indexOf(">") + 1,
                    close: hi.col - 7,
                    style: mw[1]
                };
            if (span) {
                const decls = span.style.split(";").map(d => d.trim()).filter(d => d && !/^color\s*:/i.test(d));
                if (name)
                    decls.unshift("color:" + name);
                const style = decls.join("; ");
                const l = lo.line;
                doc.breakUndoGroup();
                doc.beginCompound();
                let innerStart, innerEnd;
                if (!style) {
                    doc.replace(l, span.close, l, span.close + 7, "");
                    doc.replace(l, span.open, l, span.openEnd, "");
                    innerStart = span.open;
                    innerEnd = span.close - (span.openEnd - span.open);
                } else {
                    const tag = '<span style="' + style + '">';
                    doc.replace(l, span.open, l, span.openEnd, tag);
                    innerStart = span.open + tag.length;
                    innerEnd = span.close + tag.length - (span.openEnd - span.open);
                }
                doc.endCompound();
                // Picked: the colour shows at once, the markup does not.
                if (style)
                    ed.pickSpan(l, innerStart, innerEnd);
                else {
                    doc.setCaret({
                        line: l,
                        col: innerEnd
                    }, {
                        line: l,
                        col: innerStart
                    });
                    ed.afterCaretMove(true, false);
                }
                return;
            }
        }
        if (name) {
            ed.wrapSelection('<span style="color:' + name + '">', "</span>");
            const r2 = ed._selRange();
            if (ed.hasSelection && r2[0].line === r2[1].line && ed._spanAt(r2[0].line, r2[0].col))
                ed.pickSpan(r2[0].line, r2[0].col, r2[1].col);
        }
    }

    function insertLink() {
        const doc = ed.doc;
        if (!doc || doc.readOnly)
            return;
        doc.breakUndoGroup();
        const r = ed._selRange();
        const label = ed.hasSelection && r[0].line === r[1].line ? doc.lines[r[0].line].substring(r[0].col, r[1].col) : "";
        doc.replace(r[0].line, r[0].col, r[1].line, r[1].col, "[" + label + "]()");
        // caret inside the (): ready for the URL
        doc.setCaret({
            line: r[0].line,
            col: r[0].col + label.length + 3
        });
        ed.afterCaretMove(true, false);
    }

    function toggleTask(i) {
        const c = ed.ctx[i];
        if (!c || c.t !== "list" || c.task === null || c.task === undefined || ed.doc.readOnly)
            return;
        ed.doc.breakUndoGroup();
        ed.doc.replace(i, c.tcol, i, c.tcol + 1, c.task === "x" ? " " : "x", {
            keepCaret: true
        });
        ed.doc.breakUndoGroup();
        ed.refreshAll();
    }

    // ---- Caret movement ------------------------------------------------------------------------

    function _isWord(ch) {
        return /[A-Za-z0-9_]/.test(ch) || ch.charCodeAt(0) > 127;
    }

    function _prevPos(c) {
        if (c.col > 0) {
            const line = ed.doc.lines[c.line];
            let k = c.col - 1;
            const cc = line.charCodeAt(k);
            if (cc >= 0xDC00 && cc <= 0xDFFF && k > 0)
                --k;
            return {
                line: c.line,
                col: k
            };
        }
        if (c.line > 0)
            return {
                line: c.line - 1,
                col: ed.doc.lines[c.line - 1].length
            };
        return c;
    }

    function _nextPos(c) {
        const line = ed.doc.lines[c.line];
        if (c.col < line.length) {
            let k = c.col + 1;
            const cc = line.charCodeAt(c.col);
            if (cc >= 0xD800 && cc <= 0xDBFF && k < line.length)
                ++k;
            return {
                line: c.line,
                col: k
            };
        }
        if (c.line < ed.doc.lineCount - 1)
            return {
                line: c.line + 1,
                col: 0
            };
        return c;
    }

    function _wordLeft(c) {
        if (c.col === 0)
            return ed._prevPos(c);
        const line = ed.doc.lines[c.line];
        let k = c.col;
        while (k > 0 && !ed._isWord(line.charAt(k - 1)))
            --k;
        while (k > 0 && ed._isWord(line.charAt(k - 1)))
            --k;
        return {
            line: c.line,
            col: k
        };
    }

    function _wordRight(c) {
        const line = ed.doc.lines[c.line];
        if (c.col >= line.length)
            return ed._nextPos(c);
        let k = c.col;
        while (k < line.length && !ed._isWord(line.charAt(k)))
            ++k;
        while (k < line.length && ed._isWord(line.charAt(k)))
            ++k;
        return {
            line: c.line,
            col: k
        };
    }

    function _isCollapsed(i) {
        return vp.heightOf(i) <= 0.01;
    }

    // Row-local text position of a source column (raw: identity).
    function _toRow(row, col) {
        return row.raw ? Math.min(col, row.edit.length) : LM.toRendered(row.r2s, col);
    }
    function _toSource(row, pos) {
        return row.raw ? pos : LM.toSource(row.r2s, pos);
    }

    // The row for line j as it will look once the caret is on it: RAW. The
    // caret is placed in that layout, so it lands under the column it came
    // from after the line reveals its markers.
    function _rawRowFor(j) {
        vp.ensureVisible(j);
        const rj = vp.delegateFor(j);
        if (rj && !rj.raw && ed.kind === "markdown") {
            const set = Object.assign({}, ed.rawSet);
            set[j] = true;
            ed.rawSet = set;
            ed.fill(rj);
        }
        return rj;
    }

    function _vertical(c, dir, page) {
        let row = vp.delegateFor(c.line);
        if (!row)
            return c;
        const te = row.edit;
        const rect = te.positionToRectangle(ed._toRow(row, c.col));
        if (ed.goalX < 0)
            ed.goalX = te.mapToItem(vp.contentItem, rect.x, 0).x;
        if (page) {
            const targetY = te.mapToItem(vp.contentItem, 0, rect.y).y + dir * vp.height * 0.9;
            const j = Math.max(0, Math.min(ed.doc.lineCount - 1, vp.indexAt(targetY)));
            const rj = ed._rawRowFor(j);
            if (!rj)
                return {
                    line: j,
                    col: 0
                };
            const lp = rj.edit.mapFromItem(vp.contentItem, ed.goalX, targetY);
            return {
                line: j,
                col: ed._toSource(rj, rj.edit.positionAt(lp.x, Math.max(1, Math.min(rj.edit.contentHeight - 1, lp.y))))
            };
        }
        // Which visual line of the row the caret is on. The line height adds
        // room BELOW each line, so the row's height says nothing about
        // whether there is another line: count them.
        const n = Math.max(1, te.lineCount);
        const step = te.contentHeight / n;
        const cur = Math.max(0, Math.min(n - 1, Math.floor((rect.y + rect.height / 2) / step)));
        const target = cur + dir;
        if (!row.textHidden && target >= 0 && target < n) {
            const lx = te.mapFromItem(vp.contentItem, ed.goalX, 0).x;
            return {
                line: c.line,
                col: ed._toSource(row, te.positionAt(lx, target * step + step / 2))
            };
        }
        let j = c.line + dir;
        while (j >= 0 && j < ed.doc.lineCount && ed._isCollapsed(j))
            j += dir;
        if (j < 0) {
            if (ed.titleEditable) {
                ed.focusTitle(true);
                return null;
            }
            return {
                line: 0,
                col: 0
            };
        }
        if (j >= ed.doc.lineCount) {
            const last = ed.doc.lineCount - 1;
            return {
                line: last,
                col: ed.doc.lines[last].length
            };
        }
        const rj = ed._rawRowFor(j);
        if (!rj || rj.textHidden)
            return {
                line: j,
                col: dir < 0 ? ed.doc.lines[j].length : 0
            };
        const lx = rj.edit.mapFromItem(vp.contentItem, ed.goalX, 0).x;
        const nj = Math.max(1, rj.edit.lineCount);
        const sj = rj.edit.contentHeight / nj;
        const yy = dir < 0 ? (nj - 1) * sj + sj / 2 : sj / 2;
        return {
            line: j,
            col: ed._toSource(rj, rj.edit.positionAt(lx, yy))
        };
    }

    function _visualEdge(c, toEnd) {
        const row = vp.delegateFor(c.line);
        if (!row || !row.raw)
            return {
                line: c.line,
                col: toEnd ? ed.doc.lines[c.line].length : 0
            };
        const rect = row.edit.positionToRectangle(Math.min(c.col, row.edit.length));
        const p = row.edit.positionAt(toEnd ? row.edit.width + 10 : -10, rect.y + rect.height / 2);
        return {
            line: c.line,
            col: p
        };
    }

    function _move(key, shift, ctrl) {
        const doc = ed.doc;
        let c = doc.caret;
        const r = ed._selRange();
        let keepGoal = false;
        switch (key) {
        case Qt.Key_Left:
            c = !shift && ed.hasSelection ? r[0] : (ctrl ? ed._wordLeft(c) : ed._prevPos(c));
            break;
        case Qt.Key_Right:
            c = !shift && ed.hasSelection ? r[1] : (ctrl ? ed._wordRight(c) : ed._nextPos(c));
            break;
        case Qt.Key_Up:
        case Qt.Key_Down:
            c = ed._vertical(c, key === Qt.Key_Up ? -1 : 1, false);
            keepGoal = true;
            break;
        case Qt.Key_PageUp:
        case Qt.Key_PageDown:
            c = ed._vertical(c, key === Qt.Key_PageUp ? -1 : 1, true);
            keepGoal = true;
            break;
        case Qt.Key_Home:
            c = ctrl ? {
                line: 0,
                col: 0
            } : ed._visualEdge(c, false);
            break;
        case Qt.Key_End:
            if (ctrl) {
                const last = doc.lineCount - 1;
                c = {
                    line: last,
                    col: doc.lines[last].length
                };
            } else {
                c = ed._visualEdge(c, true);
            }
            break;
        }
        if (c === null)
            return;
        doc.setCaret(c, shift ? doc.anchor : c);
        ed.afterCaretMove(true, keepGoal);
    }

    // ---- The mouse ----------------------------------------------------------------------------------

    // Where a point (in the editor's own coordinates) lands.
    function hitTest(x, y) {
        const p = ed.mapToItem(vp.contentItem, x, y);
        if (vp.header && p.y < vp.headSpace)
            return {
                title: true,
                pos: titleEdit.positionAt(titleEdit.mapFromItem(vp.contentItem, p.x, p.y).x, titleEdit.mapFromItem(vp.contentItem, p.x, p.y).y)
            };
        if (!ed.doc || ed.doc.lineCount === 0)
            return null;
        let i = vp.indexAt(p.y);
        while (i > 0 && ed._isCollapsed(i))
            --i;
        const row = vp.delegateFor(i);
        if (!row)
            return {
                line: i,
                col: 0
            };
        const out = {
            line: i,
            col: 0,
            row: row
        };
        const rp = row.mapFromItem(vp.contentItem, p.x, p.y);
        if (row.listGutter && row.ctx.task !== null && row.ctx.task !== undefined) {
            const bx = row.sidePad + row.indentPx - 3, by = row.topPad - 3;
            if (rp.x >= bx && rp.x <= bx + 20 && rp.y >= by && rp.y <= by + 20)
                out.checkbox = true;
        }
        if (row.showTable) {
            // Which table line: the header, or the n-th body row (the
            // delimiter line is not a row).
            const col = row.children;
            const ty = rp.y - row.topPad;
            let acc = 0, k = 0;
            const rows = row.tableRows;
            const rh = rows.length ? (row.implicitHeight - row.topPad - row.bottomPad) / rows.length : 0;
            k = rh > 0 ? Math.max(0, Math.min(rows.length - 1, Math.floor(ty / rh))) : 0;
            out.line = k === 0 ? i : i + 1 + k;
            out.col = ed.ctx[out.line] ? ed.ctx[out.line].cs : 0;
            out.table = true;
            return out;
        }
        if (row.textHidden) {
            out.col = 0;
            return out;
        }
        const tp = row.edit.mapFromItem(vp.contentItem, p.x, p.y);
        const pos = row.edit.positionAt(tp.x, tp.y);
        out.col = ed._toSource(row, pos);
        const href = row.raw ? ed._linkAtSource(i, out.col) : row.edit.linkAt(tp.x, tp.y);
        if (href)
            out.href = href;
        return out;
    }

    function _linkAtSource(i, col) {
        const c = ed.ctx[i];
        if (!c)
            return "";
        const sp = LM.inlineSpans(ed.doc.lines[i], c.cs || 0, ed.doc.lines[i].length, c.hin || [], ed.mdPalette);
        for (const s of sp.styles)
            if ((s.k === "link" || s.k === "wiki" || (s.k === "html" && s.href)) && col >= s.s && col <= s.e)
                return s.href;
        for (const a of sp.atoms)
            if (a.kind === "img" && col >= a.s && col <= a.e && a.href)
                return a.href;
        return "";
    }

    // A click on the hit `h` opens its link.
    function _opensLink(h, ctrl, shift) {
        return !!h.href && (ctrl || (ed.linkClick === "click" && !shift && !!h.row && !h.row.raw));
    }

    function _open(href) {
        if (!href || href === "#")
            return;
        if (href.indexOf("wiki:") === 0)
            ed.wikiOpened(decodeURIComponent(href.substring(5)));
        else
            ed.linkOpened(href);
    }

    function _selectWordAt(h) {
        const line = ed.doc.lines[h.line];
        let a = h.col, b = h.col;
        const w = ed._isWord(line.charAt(a)) || (a > 0 && ed._isWord(line.charAt(a - 1)));
        if (w) {
            while (a > 0 && ed._isWord(line.charAt(a - 1)))
                --a;
            while (b < line.length && ed._isWord(line.charAt(b)))
                ++b;
        } else if (b < line.length) {
            ++b;
        }
        ed.doc.setCaret({
            line: h.line,
            col: b
        }, {
            line: h.line,
            col: a
        });
        ed.afterCaretMove(false, false);
    }

    function _press(m) {
        ed.forceActiveFocus();
        const h = ed.hitTest(m.x, m.y);
        if (!h)
            return;
        if (h.title) {
            ed.focusTitle(true);
            titleEdit.cursorPosition = h.pos;
            return;
        }
        if (ed._opensLink(h, (m.modifiers & Qt.ControlModifier) !== 0, (m.modifiers & Qt.ShiftModifier) !== 0)) {
            ed._open(h.href);
            return;
        }
        if (h.checkbox) {
            ed.toggleTask(h.line);
            return;
        }
        if (!(m.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) && h.row && !h.row.raw && !h.table) {
            const sp = ed._spanAt(h.line, h.col);
            const f = ed.spanFocus;
            if (sp && !(f && f.line === sp.line && f.s0 === sp.s0 && ed._spanFocusValid())) {
                ed._clicks = 0;
                ed.pickSpan(sp.line, sp.s0, sp.s1);
                return;
            }
        }
        // Click counting: double selects a word, triple the line.
        const now = Date.now();
        const near = ed._clickAt && Math.abs(ed._clickAt.x - m.x) < 5 && Math.abs(ed._clickAt.y - m.y) < 5 && now - ed._clickAt.t < 450;
        ed._clicks = near ? ed._clicks + 1 : 1;
        ed._clickAt = {
            x: m.x,
            y: m.y,
            t: now
        };
        if (ed._clicks === 2) {
            ed._selectWordAt(h);
            return;
        }
        if (ed._clicks >= 3) {
            const next = h.line + 1 < ed.doc.lineCount ? {
                line: h.line + 1,
                col: 0
            } : {
                line: h.line,
                col: ed.doc.lines[h.line].length
            };
            ed.doc.setCaret(next, {
                line: h.line,
                col: 0
            });
            ed.afterCaretMove(false, false);
            return;
        }
        const shift = (m.modifiers & Qt.ShiftModifier) !== 0;
        ed.doc.setCaret({
            line: h.line,
            col: h.col
        }, shift ? ed.doc.anchor : undefined);
        ed.afterCaretMove(false, false);
        ed._dragScene = ed.mapToItem(null, m.x, m.y);
        autoScroll.begin(ed);
    }

    function _drag(m) {
        if (!ed._dragScene)
            return;
        ed._dragScene = ed.mapToItem(null, m.x, m.y);
        const h = ed.hitTest(m.x, m.y);
        if (h && !h.title) {
            ed.doc.setCaret({
                line: h.line,
                col: h.col
            }, ed.doc.anchor);
            ed.afterCaretMove(false, false);
        }
        autoScroll.at(ed._dragScene.y);
    }

    function _release() {
        ed._dragScene = null;
        autoScroll.end();
        ed._updateColourBar();
    }

    // SelectionAutoScroll moved the content under a still pointer.
    function autoScrollReapply() {
        if (!ed._dragScene)
            return;
        const p = ed.mapFromItem(null, ed._dragScene.x, ed._dragScene.y);
        const h = ed.hitTest(p.x, p.y);
        if (h && !h.title) {
            ed.doc.setCaret({
                line: h.line,
                col: h.col
            }, ed.doc.anchor);
            ed.afterCaretMove(false, false);
        }
    }

    // ---- The ground and the carve ----------------------------------------------------------------
    // What the editor is drawn on: the host's surface, which a coloured note
    // tints. Every carved box in the document (fences, callouts, tables,
    // checkboxes) is carved into THIS: its bevel and inset shadow are
    // translucent shades that ease to alpha (Mix.carve against the plain
    // surface, so over the plain surface they are the theme's opaque
    // colours), and its fill is that carve resolved over the ground. A box
    // whose bands ease into Theme.surface draws a ring of the untinted
    // surface round every checkbox of a coloured note.
    property color ground: Theme.surface
    // The host's rounded outline in this item's coordinates, for the scroll
    // fades (ScrollDressing.outline); null: plain bands.
    property var outline: null
    // The ground is a poured tint's ramp near the host's join with the bar (ScrollDressing.surfaceRamp); null: one colour.
    property var surfaceRamp: null
    // Room kept free left and right of the TITLE only: the notes popup puts
    // its back chevron and its reset button there, on the title's first line
    // (the back button sits left of the title, with no row of its own).
    property real titleLeftInset: 0
    property real titleRightInset: 0
    // The centre of the title's first line, from the top of this item at
    // scroll 0: where the host centres what it puts beside the title.
    readonly property real titleLineCentre: Math.round(vp.topPadding + titleMetrics.height / 2)
    FontMetrics {
        id: titleMetrics
        font: titleEdit.font
    }
    readonly property color carveBevel: Mix.carve(Theme.surface, Theme.bevel, Theme.buttonBevel)
    readonly property color carveShadow: Mix.carve(Theme.surface, Theme.border, Theme.shadowDeep)
    readonly property color carveShadowDeep: Mix.carve(Theme.surface, Theme.shadowDeep, Theme.shadowDeep)
    // A table's header row over the table's own fill (the design language's
    // "a shade darker than the box it sits in"), translucent.
    readonly property color headerShade: Mix.carve(Theme.listBox, Theme.headerBox, Theme.shadowDeep)
    function sunk(target) {
        return Mix.sunk(Theme.surface, target, Theme.shadowDeep, ed.ground);
    }

    // ---- Block backgrounds (code fences, callouts) --------------------------------------------

    function _updateBlocks() {
        if (!ed.doc || ed.ctx.length === 0) {
            ed.blockRects = [];
            return;
        }
        const first = Math.max(0, vp.indexAt(vp.flick.contentY - 40));
        const last = Math.min(ed.ctx.length - 1, vp.indexAt(vp.flick.contentY + vp.height + 40));
        let s = first;
        // Walk back to the start of a block the viewport begins inside.
        while (s > 0 && (ed.ctx[s].t === "fenceBody" || ed.ctx[s].t === "fenceClose" || (ed.ctx[s].t === "callout" && !ed.ctx[s].coHead)))
            --s;
        const out = [];
        let i = s;
        while (i <= last && out.length < 12) {
            const t = ed.ctx[i].t;
            if (t === "fenceOpen") {
                let e = i + 1;
                while (e < ed.ctx.length && ed.ctx[e].t === "fenceBody")
                    ++e;
                if (e < ed.ctx.length && ed.ctx[e].t === "fenceClose")
                    ++e;
                out.push({
                    y: vp.yOf(i),
                    h: vp.yOf(e) - vp.yOf(i),
                    kind: "code",
                    co: ""
                });
                i = e;
                continue;
            }
            if (t === "callout" && ed.ctx[i].coHead) {
                let e = i + 1;
                while (e < ed.ctx.length && ed.ctx[e].t === "callout" && !ed.ctx[e].coHead)
                    ++e;
                out.push({
                    y: vp.yOf(i),
                    h: vp.yOf(e) - vp.yOf(i),
                    kind: "callout",
                    co: ed.ctx[i].co
                });
                i = e;
                continue;
            }
            ++i;
        }
        ed.blockRects = out;
    }

    // ---- Views ---------------------------------------------------------------------------------

    Item {
        id: titleHost
        // Whole pixels: every row below is placed after this block, and a
        // fractional title height put the whole note on half pixels (text
        // soft, carved corners uneven, a table header's corner half-covered:
        // RECT tableBox y 270.5).
        height: Math.ceil(titleEdit.contentHeight + ed.titleGap)
        TextEdit {
            id: titleEdit
            Keys.forwardTo: [titleEditKeys]
            EditKeys {
                id: titleEditKeys
                target: titleEdit
                selectAll: true
            }
            x: ed.sidePadding + ed.titleLeftInset
            width: Math.max(1, titleHost.width - 2 * ed.sidePadding - ed.titleLeftInset - ed.titleRightInset)
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            font.family: ed.fontFamily
            font.pixelSize: ed.titleSize
            font.bold: true
            color: Theme.textPrimary
            selectByMouse: true
            selectionColor: Mix.c(Theme.surface, Theme.accent, 0.3)
            selectedTextColor: Theme.textPrimary
            readOnly: !ed.titleEditable
            activeFocusOnPress: false
            cursorDelegate: Rectangle {
                width: 2
                color: Theme.accent
                // Only while the title has the keyboard (see LiveMarkdownLine).
                visible: titleEdit.activeFocus
                opacity: ed.caretOn || Theme.crossfading ? 1 : 0
            }
            Keys.onPressed: event => {
                ed.caretOn = true;
                if (ed._pre)
                    ed._clearPreedit();
                switch (event.key) {
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Down:
                case Qt.Key_Tab:
                    event.accepted = true;
                    ed.focusBodyAt({
                        line: 0,
                        col: 0
                    });
                    return;
                case Qt.Key_Escape:
                    event.accepted = true;
                    ed.escapePressed();
                    return;
                }
                // A file name has no line breaks and no slashes.
                if (event.text === "/" || event.text === "\u0000") {
                    event.accepted = true;
                }
            }
            onActiveFocusChanged: {
                if (!activeFocus) {
                    // a standing dictation preedit is no part of the title (the focus left with the words still underlined in it)
                    ed._clearPreedit();
                    ed.titleCommitted(titleEdit.text);
                }
            }
        }
        Text {
            x: titleEdit.x
            visible: titleEdit.length === 0 && !titleEdit.inputMethodComposing
            text: ed.titlePlaceholder
            font: titleEdit.font
            color: Theme.textFaint
        }
    }

    LineViewport {
        id: vp
        anchors.fill: parent
        header: titleHost
        topPadding: 4
        headerGap: 0
        bottomPadding: Math.max(24, vp.height * 0.35)
        delegate: rowComponent
        estimate: (i, w) => ed._estimate(i, w)
        estimateRange: (w, from, to) => ed._estimateRange(w, from, to)
        onAssigned: (item, index) => ed.fill(item)
        onLaidOut: ed._updateBlocks()
    }

    Component {
        id: rowComponent
        LiveMarkdownLine {
            editor: ed
            Keys.onReleased: event => ed.keyReleased(event)
        }
    }

    // Block backgrounds, under the rows. An Instantiator, not a Repeater: the
    // boxes live in the viewport's underlay, and a Repeater insists its
    // delegates stay its siblings.
    Instantiator {
        model: 12
        delegate: ShadowBox {
            id: blockBox
            required property int index
            readonly property var r: ed.blockRects[blockBox.index] || null
            parent: vp.underlay
            visible: blockBox.r !== null
            x: ed.sidePadding - (blockBox.r && blockBox.r.kind === "callout" ? 0 : 0)
            y: blockBox.r ? blockBox.r.y : 0
            width: vp.width - 2 * ed.sidePadding
            height: blockBox.r ? Math.max(0, blockBox.r.h) : 0
            baseWidth: blockBox.width
            baseHeight: blockBox.height
            baseRadius: 8
            bevelWidth: 1
            shadowWidth: 3
            // Carved into whatever the ground is -- a coloured note tints it --
            // so every band is a translucent shade (Mix.carve), equal to the
            // opaque colours over the plain surface.
            surfaceColor: "transparent"
            bevelColor: ed.carveBevel
            shadowColor: ed.carveShadow
            backgroundColor: blockBox.r && blockBox.r.kind === "callout" ? Mix.c(ed.sunk(Theme.listBox), ed.calloutColor(blockBox.r.co), 0.1) : ed.sunk(Theme.panelSunk)
            shadowProgress: blockBox.r && blockBox.r.kind === "callout" ? 1 : -1
            shadowProgressColor: blockBox.r && blockBox.r.kind === "callout" ? ed.calloutColor(blockBox.r.co) : Theme.accent
        }
    }

    // ---- The foot fade steps aside for the line being written ------------------------------------
    // The caret's line is kept 12 px inside the viewport's foot (ensureVisible),
    // which is inside the 24 px foot fade: the line being written would sit half
    // under the band. While the user WRITES and that line is under the band,
    // the band fades out (`footYield`, 160 ms); when the writing stops -- an
    // idle pause, a caret that moved without an edit, a wheel -- or the line is
    // no longer under it, the band fades back in. Not writing,
    // or a line above the band: the yield is 0 and the band is the distance's.
    readonly property real footFadeHeight: 24
    property real footYield: 0
    property bool _writing: false
    // An edit and the caret moves it makes share one turn of the event loop.
    property bool _editTurn: false
    property int writeIdleMs: 2000

    function _noteEdit() {
        ed._editTurn = true;
        Qt.callLater(() => {
            ed._editTurn = false;
        });
        ed._writing = true;
        writeIdle.restart();
        ed._syncYield();
    }
    function _setWriting(on) {
        if (ed._writing === on)
            return;
        ed._writing = on;
        if (!on)
            writeIdle.stop();
        ed._syncYield();
    }
    // Asked after the turn's layout (rows measured, the scroll made), once.
    function _syncYield() {
        yieldSync.restart();
    }
    // Whether the caret's visual line reaches into the foot band, and the
    // band is on at all (content lies below the viewport).
    function _caretUnderFoot() {
        if (!ed.doc || !ed.focusBody)
            return false;
        const fl = vp.flick;
        if (fl.contentHeight - fl.height - fl.contentY < 0.5)
            return false;
        const line = ed.doc.caret.line;
        const row = vp.delegateFor(line);
        if (!row)
            return false;
        const rect = row.edit.positionToRectangle(Math.min(ed.doc.caret.col, row.edit.length));
        const bottom = vp.yOf(line) + row.edit.y + rect.y + rect.height - fl.contentY;
        return bottom > fl.height - ed.footFadeHeight;
    }
    function _yieldTo(v) {
        if (yieldAnim.running ? yieldAnim.to === v : ed.footYield === v)
            return;
        yieldAnim.stop();
        yieldAnim.from = ed.footYield;
        yieldAnim.to = v;
        yieldAnim.start();
    }
    Timer {
        id: yieldSync
        interval: 0
        onTriggered: ed._yieldTo(ed._writing && ed._caretUnderFoot() ? 1 : 0)
    }
    Timer {
        id: writeIdle
        interval: ed.writeIdleMs
        onTriggered: ed._setWriting(false)
    }
    NumberAnimation {
        id: yieldAnim
        target: ed
        property: "footYield"
        duration: 160
        easing.type: Easing.OutCubic
    }
    // The scroll moves the line under the band or out from it.
    Connections {
        target: vp.flick
        function onContentYChanged() {
            if (ed._writing)
                ed._syncYield();
        }
    }

    // The fades take the ground the editor sits on: the text runs out under
    // the host's back chevron instead of behind it.
    ScrollDressing {
        anchors.fill: vp
        flick: vp.flick
        fadeHeight: ed.footFadeHeight
        footYield: ed.footYield
        onWheeled: ed._setWriting(false)
        ground: ed.ground
        surfaceRamp: ed.surfaceRamp
        outline: ed.outline ? {
            x: ed.outline.x - vp.x,
            y: ed.outline.y - vp.y,
            w: ed.outline.w,
            h: ed.outline.h,
            radii: ed.outline.radii
        } : null
    }

    SelectionAutoScroll {
        id: autoScroll
        flickable: vp.flick
    }

    MouseArea {
        id: mouseLayer
        anchors.fill: vp
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.IBeamCursor
        onPressed: m => ed._press(m)
        onPositionChanged: m => {
            if (mouseLayer.pressed)
                ed._drag(m);
        }
        onReleased: ed._release()
        onCanceled: ed._release()
    }

    // The pointer says what a click will do: a hand over a task box, and over
    // a link while Ctrl is held (a plain click places the caret).
    HoverHandler {
        id: hover
        onPointChanged: ed._updateHoverCursor()
        onHoveredChanged: ed._updateHoverCursor()
        cursorShape: ed._hoverShape
    }
    property int _hoverShape: Qt.IBeamCursor
    onCtrlHeldChanged: ed._updateHoverCursor()
    function _updateHoverCursor() {
        if (!hover.hovered) {
            ed._hoverShape = Qt.IBeamCursor;
            ed.hoverSpan = null;
            return;
        }
        const h = ed.hitTest(hover.point.position.x, hover.point.position.y);
        const sp = h && h.row && !h.row.raw && !h.table && !h.title ? ed._spanAt(h.line, h.col) : null;
        const cur = ed.hoverSpan;
        if (!sp !== !cur || (sp && (sp.line !== cur.line || sp.s0 !== cur.s0 || sp.s1 !== cur.s1)))
            ed.hoverSpan = sp;
        ed._hoverShape = h && (h.checkbox || sp || ed._opensLink(h, ed.ctrlHeld, false)) ? Qt.PointingHandCursor : Qt.IBeamCursor;
        mouseLayer.cursorShape = ed._hoverShape;
    }

    // Caret blink: its own clock, stopped under a theme crossfade.
    Timer {
        interval: 530
        repeat: true
        running: ed.activeFocus && !Theme.crossfading
        onTriggered: ed.caretOn = !ed.caretOn
    }

    // ---- Selection colour bar -----------------------------------------------------------------
    property bool _barWanted: false
    property real _barX: 0
    property real _barY: 0
    property real barF: ed._barWanted ? 1 : 0
    Behavior on barF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    function _updateColourBar() {
        if (!ed.colourBarEnabled || !ed.doc || !ed.hasSelection || ed._dragScene || ed.kind !== "markdown" || !ed.focusBody) {
            ed._barWanted = false;
            return;
        }
        const r = ed._selRange();
        const row = vp.delegateFor(r[0].line);
        if (!row) {
            ed._barWanted = false;
            return;
        }
        const at = row.raw ? r[0].col : LM.toRendered(row.r2s, r[0].col);
        const rect = row.edit.positionToRectangle(Math.min(at, row.edit.length));
        const p = row.edit.mapToItem(ed, rect.x, rect.y);
        ed._barX = Math.max(4, Math.min(ed.width - colourBar.width - 4, p.x - 8));
        ed._barY = p.y - colourBar.height - 6 < 0 ? p.y + rect.height + 6 : p.y - colourBar.height - 6;
        ed._barWanted = true;
    }

    Item {
        id: colourBar
        readonly property var swatches: ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray", ""]
        visible: ed.barF > 0.01
        opacity: ed.barF
        x: ed._barX
        y: ed._barY
        z: 10
        width: barRow.implicitWidth + 12
        height: 26
        ShadowBox {
            anchors.fill: parent
            baseWidth: colourBar.width
            baseHeight: colourBar.height
            baseRadius: 13
            raised: true
            bevelWidth: 1.5
            shadowWidth: 5
            // Floats over the text: its shadow falls to alpha.
            shadowToAlpha: true
            surfaceColor: Theme.surface
            bevelColor: Theme.buttonBevel
            shadowColor: Theme.buttonShadow
            backgroundColor: Theme.buttonPlateau
        }
        Row {
            id: barRow
            x: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            Repeater {
                model: colourBar.swatches
                // The last dot is empty: it takes the colour away.
                delegate: Rectangle {
                    id: sw
                    required property string modelData
                    width: 14
                    height: 14
                    radius: 7
                    color: sw.modelData ? ed.namedColour(sw.modelData) : "transparent"
                    border.width: swHover.hovered ? 2 : (sw.modelData ? 0 : 1)
                    border.color: sw.modelData ? Theme.textOnAccent : Theme.textFaint
                    Rectangle {
                        visible: !sw.modelData
                        anchors.centerIn: parent
                        width: 1.5
                        height: 12
                        rotation: 45
                        color: Theme.textFaint
                    }
                    HoverHandler {
                        id: swHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        gesturePolicy: TapHandler.WithinBounds
                        onTapped: ed.colourSelection(sw.modelData)
                    }
                }
            }
            Item {
                width: 4
                height: 1
            }
            Repeater {
                model: [["B", "**"], ["I", "*"], ["S", "~~"]]
                delegate: Text {
                    id: fmtBtn
                    required property var modelData
                    width: 14
                    horizontalAlignment: Text.AlignHCenter
                    text: fmtBtn.modelData[0]
                    font.family: ed.fontFamily
                    font.pixelSize: 12
                    font.bold: fmtBtn.modelData[0] === "B"
                    font.italic: fmtBtn.modelData[0] === "I"
                    font.strikeout: fmtBtn.modelData[0] === "S"
                    color: fmtHover.hovered ? Theme.accent : Theme.textMuted
                    HoverHandler {
                        id: fmtHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        gesturePolicy: TapHandler.WithinBounds
                        onTapped: ed.wrapSelection(fmtBtn.modelData[1], fmtBtn.modelData[1])
                    }
                }
            }
        }
    }

    // ---- Local images: exist before Image loads them ------------------------------------------
    // An Image pointed at a missing file prints a warning on every load of the
    // note; a note linking an image that moved is the user's business, not a
    // log line. So a local source is looked at first (one `test -r` for all
    // that are waiting, cached per path); remote sources load directly.
    property var _imgStates: ({})
    property int _imgSerial: 0
    property var _imgQueue: []
    function _imageState(url) {
        if (!/^file:/.test(url))
            return "ok";
        const st = ed._imgStates[url];
        if (st)
            return st;
        ed._imgStates[url] = "pending";
        ed._imgQueue.push(url);
        Qt.callLater(ed._checkImages);
        return "pending";
    }
    function _checkImages() {
        if (imgCheck.running || ed._imgQueue.length === 0)
            return;
        imgCheck.batch = ed._imgQueue.splice(0);
        imgCheck.command = ["sh", "-c", 'for f; do if [ -r "$f" ]; then echo 1; else echo 0; fi; done', "sh"].concat(imgCheck.batch.map(u => decodeURIComponent(u.replace(/^file:\/\//, ""))));
        imgCheck.running = true;
    }
    Process {
        id: imgCheck
        property var batch: []
        stdout: StdioCollector {
            id: imgOut
        }
    }
    Connections {
        target: imgCheck
        function onExited(code) {
            const res = imgOut.text.split("\n");
            imgCheck.batch.forEach((u, k) => ed._imgStates[u] = res[k] === "1" ? "ok" : "missing");
            imgCheck.batch = [];
            ed._imgSerial++;
            ed.refreshAll();
            ed._checkImages();
        }
    }

    // ---- Estimates ------------------------------------------------------------------------------

    // The batch form: every metric read ONCE, then plain JS per row.
    function _estimateRange(w, from, to) {
        const out = new Array(Math.max(0, to - from));
        if (!ed.doc)
            return out.fill(0);
        const lines = ed.doc.lines, ctx = ed.ctx, rawSet = ed.rawSet;
        const side = ed.sidePadding, rowPad = ed.rowPad, body = ed.bodySize, mono = ed.monoSize;
        const fmH = fm.height, pct = ed.lineHeightPct / 100, avgBody = ed.avgChar, avgMono = ed.monoChar;
        const lhOf = px => Math.ceil(fmH * (px / body) * pct);
        const headPxs = [0, 1, 2, 3, 4, 5, 6].map(l => l ? ed.headPx(l) : body);
        const lhBody = lhOf(body), lhMono = lhOf(mono);
        for (let i = from; i < to; ++i) {
            const c = ctx[i] || {
                t: "blank"
            };
            const t = c.t;
            const raw = rawSet[i] === true;
            if (!raw && (t === "tdelim" || t === "trow" || t === "setextU" || (t === "front" && i !== 0))) {
                out[i - from] = 0;
                continue;
            }
            const head = t === "head" || t === "setext";
            const isMono = t === "fenceOpen" || t === "fenceBody" || t === "fenceClose" || t === "plain";
            const px = head ? headPxs[c.lv || 1] : (isMono ? mono : body);
            const lh = head ? lhOf(px) : (isMono ? lhMono : lhBody);
            const pad = 2 * rowPad + (head ? Math.round(px * 0.45) : 0);
            if (!raw && t === "image") {
                out[i - from] = pad + 64;
                continue;
            }
            if (!raw && t === "thead") {
                let rows = 1;
                for (let k = i + 2; k < ctx.length && ctx[k].t === "trow"; ++k)
                    ++rows;
                out[i - from] = pad + rows * (lhBody + 10) + 2;
                continue;
            }
            const avg = isMono ? avgMono : avgBody * (px / body);
            const avail = Math.max(40, w - 2 * side - (t === "list" ? 24 : 0) - (t === "quote" ? 12 * (c.qd || 1) : 0) - (isMono ? 20 : 0));
            const perLine = Math.max(1, Math.floor(avail / Math.max(1, avg)));
            out[i - from] = pad + Math.max(1, Math.ceil(lines[i].length / perLine)) * lh;
        }
        return out;
    }

    function _estimate(i, w) {
        if (!ed.doc || i >= ed.doc.lineCount)
            return 0;
        const c = ed.ctx[i] || {
            t: "blank"
        };
        const raw = !!ed.rawSet[i];
        const t = c.t;
        if (!raw && (t === "tdelim" || t === "trow" || t === "setextU" || (t === "front" && i !== 0)))
            return 0;
        const head = t === "head" || t === "setext";
        const mono = t === "fenceOpen" || t === "fenceBody" || t === "fenceClose" || t === "plain";
        const px = head ? ed.headPx(c.lv || 1) : (mono ? ed.monoSize : ed.bodySize);
        const lh = ed.lineBox(px);
        const pad = 2 * ed.rowPad + (head ? Math.round(px * 0.45) : 0);
        if (!raw && t === "image")
            return pad + 64;
        if (!raw && t === "thead") {
            let rows = 1;
            for (let k = i + 2; k < ed.ctx.length && ed.ctx[k].t === "trow"; ++k)
                ++rows;
            return pad + rows * (lh + 10) + 2;
        }
        const avg = mono ? ed.monoChar : ed.avgChar * (px / ed.bodySize);
        const avail = Math.max(40, w - 2 * ed.sidePadding - (t === "list" ? 24 : 0) - (t === "quote" ? 12 * (c.qd || 1) : 0) - (mono ? 20 : 0));
        const perLine = Math.max(1, Math.floor(avail / Math.max(1, avg)));
        const n = Math.max(1, Math.ceil(ed.doc.lines[i].length / perLine));
        return pad + n * lh;
    }

    // ---- Session -------------------------------------------------------------------------------

    function scrollState() {
        const top = vp.indexAt(vp.flick.contentY);
        return {
            line: top,
            off: vp.flick.contentY - vp.yOf(top)
        };
    }
    function restoreScroll(s) {
        if (!s || s.line === undefined)
            return;
        vp.relayout();
        vp.flick.contentY = Math.max(0, vp.yOf(Math.min(s.line, Math.max(0, ed.doc.lineCount - 1))) + (s.off || 0));
    }
}
