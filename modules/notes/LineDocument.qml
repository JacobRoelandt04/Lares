import QtQuick

// =============================================================================
// LineDocument.qml -- the notes editor's text model.
//
// The source of truth for an open note: an array of lines, each with its OWN
// line ending, so a file is written back byte for byte however it was made
// (CRLF, mixed endings, no final newline, a BOM). The views never hold the
// text; they show lines of this and send edits back through ONE primitive,
// replace(). Undo and redo are replaces too, recorded with the exact bytes
// they removed, so undoing across a mixed-ending file restores the endings.
//
//   lines[i]  the text of line i (no terminator)
//   eols[i]   "\n", "\r\n", or "" -- only the LAST line has "", and it may
//             be empty ("a\n" is ["a", ""])
//   bom       a U+FEFF that opened the file (never seen by the caret)
//
// A lone CR inside a line is text, not a break: only "\n" breaks, and a CR
// right before it belongs to the break. That is the one rule load, replace
// and undo all use.
//
// Positions are {line, col}; col is a UTF-16 index into lines[line].
// Mutating arrays emit nothing a binding can see, so `serial` bumps on every
// change and `replaced(from, removedCount, insertedCount)` tells a view which
// lines to rebuild.
// =============================================================================
QtObject {
    id: doc

    property bool readOnly: false
    property bool bom: false
    property string dominantEol: "\n"
    property var lines: [""]
    property var eols: [""]
    // Per-line revision: a view caches a line's rendering by it.
    property var revs: [0]
    property int lineCount: 1
    property int serial: 0
    property int savedSerial: 0
    readonly property bool dirty: serial !== savedSerial
    property var caret: ({ line: 0, col: 0 })
    property var anchor: ({ line: 0, col: 0 })

    // Undo: typing merges while it continues on one line within this window.
    property int coalesceMs: 1000
    property int undoLimit: 1000
    property int undoBytesLimit: 4 * 1024 * 1024

    signal replaced(int from, int removedCount, int insertedCount)
    signal reloaded

    property int _rev: 0
    property var _undo: []
    property var _redo: []
    property int _undoCount: 0
    property int _redoCount: 0
    property int _undoBytes: 0
    // Compound edits (wrapping a multi-line selection is one replace per
    // line): every record made between beginCompound() and endCompound()
    // becomes ONE undo step.
    property int _groupDepth: 0
    property var _group: null

    // ---- Load / save ------------------------------------------------------------

    function load(text) {
        let t = String(text === undefined || text === null ? "" : text);
        doc.bom = t.charCodeAt(0) === 0xFEFF;
        if (doc.bom)
            t = t.substring(1);
        const parsed = doc._parse(t);
        doc.lines = parsed.lines;
        doc.eols = parsed.eols;
        doc.revs = parsed.lines.map(() => ++doc._rev);
        doc.lineCount = doc.lines.length;
        let crlf = 0, lf = 0;
        for (const e of parsed.eols) {
            if (e === "\r\n")
                crlf++;
            else if (e === "\n")
                lf++;
        }
        doc.dominantEol = crlf > lf ? "\r\n" : "\n";
        doc._undo = [];
        doc._redo = [];
        doc._undoCount = 0;
        doc._redoCount = 0;
        doc._undoBytes = 0;
        doc.caret = { line: 0, col: 0 };
        doc.anchor = { line: 0, col: 0 };
        doc.serial++;
        doc.savedSerial = doc.serial;
        doc.reloaded();
    }

    function text() {
        let out = doc.bom ? "\uFEFF" : "";
        const n = doc.lines.length;
        const parts = new Array(n * 2);
        for (let i = 0; i < n; ++i) {
            parts[2 * i] = doc.lines[i];
            parts[2 * i + 1] = doc.eols[i];
        }
        return out + parts.join("");
    }

    function markSaved() {
        doc.savedSerial = doc.serial;
    }

    // "a\r\nb\n" -> lines ["a", "b", ""], eols ["\r\n", "\n", ""]
    function _parse(t) {
        const pieces = t.split("\n");
        const lines = new Array(pieces.length);
        const eols = new Array(pieces.length);
        for (let i = 0; i < pieces.length; ++i) {
            let p = pieces[i];
            if (i < pieces.length - 1) {
                if (p.length > 0 && p.charCodeAt(p.length - 1) === 13) {
                    p = p.substring(0, p.length - 1);
                    eols[i] = "\r\n";
                } else {
                    eols[i] = "\n";
                }
            } else {
                eols[i] = "";
            }
            lines[i] = p;
        }
        return {
            lines: lines,
            eols: eols
        };
    }

    // ---- Positions ------------------------------------------------------------------

    function clampPos(p) {
        const l = Math.max(0, Math.min(doc.lines.length - 1, p ? p.line : 0));
        const c = Math.max(0, Math.min(doc.lines[l].length, p ? p.col : 0));
        return {
            line: l,
            col: c
        };
    }

    function cmp(a, b) {
        return a.line !== b.line ? a.line - b.line : a.col - b.col;
    }

    function lineText(i) {
        return i >= 0 && i < doc.lines.length ? doc.lines[i] : "";
    }

    // The text between two positions with the file's own line endings.
    function _tRange(l0, c0, l1, c1) {
        if (l0 === l1)
            return doc.lines[l0].substring(c0, c1);
        let s = doc.lines[l0].substring(c0) + doc.eols[l0];
        for (let k = l0 + 1; k < l1; ++k)
            s += doc.lines[k] + doc.eols[k];
        return s + doc.lines[l1].substring(0, c1);
    }

    // The same range for the clipboard: every ending as "\n".
    function rangeText(a, b) {
        const p = doc.cmp(a, b) <= 0 ? [doc.clampPos(a), doc.clampPos(b)] : [doc.clampPos(b), doc.clampPos(a)];
        return doc._tRange(p[0].line, p[0].col, p[1].line, p[1].col).replace(/\r\n/g, "\n");
    }

    function selectedText() {
        return doc.rangeText(doc.anchor, doc.caret);
    }

    function hasSelection() {
        return doc.cmp(doc.anchor, doc.caret) !== 0;
    }

    function setCaret(pos, anchorPos) {
        doc.caret = doc.clampPos(pos);
        doc.anchor = anchorPos === undefined ? doc.caret : doc.clampPos(anchorPos);
    }

    // ---- The one mutation ------------------------------------------------------------

    // Replace [(l0,c0), (l1,c1)) with `str`. Newlines in `str` become the
    // document's dominant ending unless opt.raw (undo/redo hand in the exact
    // bytes they recorded). opt.kind: "type" | "del" | "fdel" | "" (never
    // merged). Returns the end of the inserted text; the caret goes there
    // unless opt.keepCaret.
    function replace(l0, c0, l1, c1, str, opt) {
        if (doc.readOnly)
            return {
                line: l0,
                col: c0
            };
        const o = opt || {};
        let a = doc.clampPos({
            line: l0,
            col: c0
        });
        let b = doc.clampPos({
            line: l1,
            col: c1
        });
        if (doc.cmp(a, b) > 0) {
            const t = a;
            a = b;
            b = t;
        }
        let ins = String(str === undefined || str === null ? "" : str);
        if (!o.raw)
            ins = ins.replace(/\r\n/g, "\n").replace(/\n/g, doc.dominantEol);
        const removed = doc._tRange(a.line, a.col, b.line, b.col);
        if (removed.length === 0 && ins.length === 0)
            return a;
        const caretBefore = doc.caret;
        const anchorBefore = doc.anchor;
        const end = doc._splice(a.line, a.col, b.line, b.col, ins);
        if (!o.keepCaret)
            doc.setCaret(end);
        if (!o.noUndo)
            doc._record({
                l0: a.line,
                c0: a.col,
                insEnd: end,
                ins: ins,
                rem: removed,
                caretBefore: caretBefore,
                anchorBefore: anchorBefore,
                caretAfter: doc.caret,
                anchorAfter: doc.anchor,
                kind: o.kind || "",
                time: Date.now()
            });
        return end;
    }

    function _splice(l0, c0, l1, c1, ins) {
        const parsed = doc._parse(ins);
        const k = parsed.lines.length - 1;
        const head = doc.lines[l0].substring(0, c0);
        const tail = doc.lines[l1].substring(c1);
        const lastEol = doc.eols[l1];
        const newLines = parsed.lines.slice();
        const newEols = parsed.eols.slice();
        newLines[0] = head + newLines[0];
        newLines[k] = newLines[k] + tail;
        newEols[k] = lastEol;
        const newRevs = newLines.map(() => ++doc._rev);
        const removedCount = l1 - l0 + 1;
        doc.lines.splice(l0, removedCount, ...newLines);
        doc.eols.splice(l0, removedCount, ...newEols);
        doc.revs.splice(l0, removedCount, ...newRevs);
        doc.lineCount = doc.lines.length;
        doc.serial++;
        doc.replaced(l0, removedCount, newLines.length);
        return {
            line: l0 + k,
            col: (k === 0 ? c0 : 0) + parsed.lines[k].length
        };
    }

    // ---- Undo ------------------------------------------------------------------------------

    function _cost(r) {
        if (r.parts) {
            let c = 64;
            for (const q of r.parts)
                c += doc._cost(q);
            return c;
        }
        return (r.ins.length + r.rem.length) * 2 + 64;
    }

    function beginCompound() {
        if (doc._groupDepth++ === 0)
            doc._group = [];
    }

    function endCompound() {
        if (doc._groupDepth === 0 || --doc._groupDepth > 0)
            return;
        const g = doc._group;
        doc._group = null;
        if (!g || g.length === 0)
            return;
        doc._record({
            parts: g,
            caretBefore: g[0].caretBefore,
            anchorBefore: g[0].anchorBefore,
            caretAfter: doc.caret,
            anchorAfter: doc.anchor,
            kind: "",
            time: Date.now()
        });
    }

    function _record(r) {
        if (doc._group && !r.parts) {
            doc._group.push(r);
            return;
        }
        doc._redo = [];
        doc._redoCount = 0;
        const prev = doc._undo.length ? doc._undo[doc._undo.length - 1] : null;
        if (prev && r.kind && prev.kind === r.kind && r.time - prev.time < doc.coalesceMs && doc._merge(prev, r)) {
            doc._undoCount = doc._undo.length;
            return;
        }
        doc._undo.push(r);
        doc._undoBytes += doc._cost(r);
        while (doc._undo.length > doc.undoLimit || (doc._undoBytes > doc.undoBytesLimit && doc._undo.length > 1))
            doc._undoBytes -= doc._cost(doc._undo.shift());
        doc._undoCount = doc._undo.length;
    }

    // Typing continues the previous step when it lands exactly where that one
    // ended, on the same line, and does not start a new word; backspace and
    // delete runs merge the same way.
    function _merge(p, r) {
        if (r.kind === "type") {
            if (r.rem.length || r.ins.indexOf("\n") >= 0 || p.ins.indexOf("\n") >= 0)
                return false;
            if (r.l0 !== p.insEnd.line || r.c0 !== p.insEnd.col)
                return false;
            const last = p.ins.charAt(p.ins.length - 1);
            if (/\s/.test(r.ins.charAt(0)) && last !== "" && !/\s/.test(last))
                return false;
            doc._undoBytes -= doc._cost(p);
            p.ins += r.ins;
            p.insEnd = r.insEnd;
        } else if (r.kind === "del") {
            if (r.ins.length || p.ins.length)
                return false;
            const rEnd = doc._endOf(r.l0, r.c0, r.rem);
            if (rEnd.line !== p.l0 || rEnd.col !== p.c0)
                return false;
            doc._undoBytes -= doc._cost(p);
            p.rem = r.rem + p.rem;
            p.l0 = r.l0;
            p.c0 = r.c0;
            p.insEnd = {
                line: r.l0,
                col: r.c0
            };
        } else if (r.kind === "fdel") {
            if (r.ins.length || p.ins.length || r.l0 !== p.l0 || r.c0 !== p.c0)
                return false;
            doc._undoBytes -= doc._cost(p);
            p.rem = p.rem + r.rem;
        } else {
            return false;
        }
        p.caretAfter = r.caretAfter;
        p.anchorAfter = r.anchorAfter;
        p.time = r.time;
        doc._undoBytes += doc._cost(p);
        return true;
    }

    // Where a text inserted at (l, c) would end.
    function _endOf(l, c, s) {
        const parts = s.split("\n");
        const k = parts.length - 1;
        let last = parts[k];
        return {
            line: l + k,
            col: (k === 0 ? c : 0) + last.length
        };
    }

    function undo() {
        if (doc.readOnly || !doc._undo.length)
            return false;
        const r = doc._undo.pop();
        doc._undoBytes -= doc._cost(r);
        const parts = r.parts ? r.parts.slice().reverse() : [r];
        for (const q of parts)
            doc._splice(q.l0, q.c0, q.insEnd.line, q.insEnd.col, q.rem);
        doc.caret = doc.clampPos(r.caretBefore);
        doc.anchor = doc.clampPos(r.anchorBefore);
        doc._redo.push(r);
        doc._undoCount = doc._undo.length;
        doc._redoCount = doc._redo.length;
        return true;
    }

    function redo() {
        if (doc.readOnly || !doc._redo.length)
            return false;
        const r = doc._redo.pop();
        for (const q of (r.parts ? r.parts : [r])) {
            const remEnd = doc._endOf(q.l0, q.c0, q.rem);
            doc._splice(q.l0, q.c0, remEnd.line, remEnd.col, q.ins);
        }
        doc.caret = doc.clampPos(r.caretAfter);
        doc.anchor = doc.clampPos(r.anchorAfter);
        doc._undo.push(r);
        doc._undoBytes += doc._cost(r);
        doc._undoCount = doc._undo.length;
        doc._redoCount = doc._redo.length;
        return true;
    }

    // An edit that must not merge with what came before (a paste, a toggle).
    function breakUndoGroup() {
        if (doc._undo.length)
            doc._undo[doc._undo.length - 1].time = 0;
    }
}
