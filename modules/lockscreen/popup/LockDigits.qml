pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// LockDigits.qml -- the clock's figures: fixed slots that still read as a group.
//
// DigitCells gives every digit the widest digit's cell, so a lone "1" sits in a
// slot as wide as a "4" and "16:06" reads "1 6:06". Here the slots stay FIXED
// (nothing moves when a digit changes) but are tighter and lean on the colon:
//
//   - a slot is as wide as the widest digit that can stand there: for "HH:mm"
//     the hour's tens are 0-2, the minute's tens 0-5, the units 0-9;
//   - digits before the colon are right-aligned in their slots, digits after it
//     left-aligned, so the two halves hug the colon and any gap falls to the
//     outside, where the centred group hides it.
// Any other shape of text (another format) falls back to the widest digit for
// every slot, aligned the same way. The width depends on the text's SHAPE only.
//
// TWO LAYOUTS (`anchored`, the default):
//   anchored  the colon stands at the block's centre; the hour digits are packed
//             right-to-left from it and the minute digits left-to-right, each at
//             its natural advance (plus `colonGap`). Groups read tight ("11:11"
//             is not "1 1:1 1"); the block's width is fixed by the text's shape,
//             the colon and the hours never move on a minute change, and only
//             digits on the OUTER side of a changed digit can shift (minute tens
//             1 -> 2 moves the units) -- once a minute, on a clock that changes
//             once a minute.
//   slots     the layout above: nothing ever moves, narrow digits leave gaps.
//
// A DIGIT THAT CHANGES ROLLS: the old figure rises
// out and fades over the first half of its roll, the new one rises in from
// below over the second half -- presence, never two figures over each other.
// Changed digits cascade right to left, `staggerMs` apart, as an odometer
// carries ("09:59" -> "10:00": the units first, the hour's tens last). ONE
// clock (`_rollT`, ms since the change); every slot's phase is a function of
// it. A change of the text's SHAPE (its length) is a change of what is shown
// and swaps at once. Held still while the theme crossfades.
// =============================================================================
Item {
    id: root

    property string text: ""
    property string fontFamily: "Audiowide"
    property real pixelSize: 40
    property color color: Theme.textPrimary
    property bool anchored: true
    property real colonGap: 0
    // The roll: on/off, one digit's length, the cascade's step, how far a figure travels.
    property bool rolling: true
    property int rollMs: 420
    property int staggerMs: 70
    property real rollDistance: Math.round(root.pixelSize * 0.18)

    FontMetrics {
        id: fm
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
    }
    readonly property real _inkZoom: 8
    FontMetrics {
        id: inkFm
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize * root._inkZoom
    }
    // The metrics' own font is read inside the helper: advanceWidth() alone
    // captures nothing.
    function _adv(chars) {
        const f = fm.font;
        let w = 0;
        for (const c of chars)
            w = Math.max(w, fm.advanceWidth(c));
        return Math.ceil(w);
    }
    function _isDigit(c) {
        return c >= "0" && c <= "9";
    }

    readonly property bool _hhmm: /^\d\d:\d\d$/.test(root.text)
    readonly property var _sets: ["012", "0123456789", "012345", "0123456789"]
    // { x, w, c } per character, left to right; the colon is its own advance.
    readonly property var _cells: root.anchored && root.text.indexOf(":") > 0 ? root._anchoredCells() : root._slotCells()
    // The colon at the centre, digits packed outward from it.
    function _anchoredCells() {
        const f = fm.font;
        const colon = root.text.indexOf(":");
        const nb = colon, na = root.text.length - colon - 1;
        const dmax = root._adv("0123456789");
        const cw = Math.ceil(fm.advanceWidth(":"));
        const side = Math.max(nb, na) * dmax + root.colonGap;
        const out = new Array(root.text.length + 1);
        out[colon] = { x: side, w: cw, c: ":", before: true, natural: true };
        let r = side - root.colonGap;
        for (let i = colon - 1; i >= 0; i--) {
            const w = Math.ceil(fm.advanceWidth(root.text[i]));
            r -= w;
            out[i] = { x: r, w: w, c: root.text[i], before: true, natural: true };
        }
        let l = side + cw + root.colonGap;
        for (let i = colon + 1; i < root.text.length; i++) {
            const w = Math.ceil(fm.advanceWidth(root.text[i]));
            out[i] = { x: l, w: w, c: root.text[i], before: false, natural: true };
            l += w;
        }
        out[root.text.length] = { x: 2 * side + cw, w: 0, c: "", before: false };
        return out;
    }
    function _slotCells() {
        const f = fm.font;
        const out = [];
        let x = 0, digit = 0;
        const colon = root.text.indexOf(":");
        for (let i = 0; i < root.text.length; i++) {
            const c = root.text[i];
            let w;
            if (root._isDigit(c)) {
                w = root._adv(root._hhmm ? root._sets[digit] : "0123456789");
                digit++;
            } else {
                w = Math.ceil(fm.advanceWidth(c));
            }
            out.push({ x: x, w: w, c: c, before: colon < 0 || i < colon });
            x += w;
        }
        out.push({ x: x, w: 0, c: "", before: false });
        return out;
    }

    // The figures' INK, left and right, in the block's own coordinates: the
    // first and last glyph's tight bounds, not their advances (Audiowide's side
    // bearings differ from digit to digit, so a block centred by its advances
    // sits off by the bearings' difference). The metrics' font is read inside
    // the helper, so the answer follows the face.
    function _inkOf(i) {
        const f = fm.font;
        const cell = root._cells[i];
        const f2 = inkFm.font;
        // Measured at 8x and scaled back: tightBoundingRect rounds its bounds
        // outward to whole pixels, which at 104 px is up to a pixel of error a side.
        const r8 = inkFm.tightBoundingRect(cell.c);
        const r = { x: r8.x / root._inkZoom, width: r8.width / root._inkZoom };
        const x = Math.round(cell.x + (cell.natural ? 0 : root._isDigit(cell.c)
            ? (cell.before ? cell.w - Math.ceil(fm.advanceWidth(cell.c)) : 0)
            : (cell.w - Math.ceil(fm.advanceWidth(cell.c))) / 2));
        return { l: x + r.x, r: x + r.x + r.width };
    }
    readonly property var ink: {
        const n = root.text.length;
        if (n === 0)
            return { l: 0, r: root.implicitWidth };
        const a = root._inkOf(0), b = root._inkOf(n - 1);
        return { l: a.l, r: b.r };
    }
    // How far the ink's middle is from the block's middle (positive: right).
    readonly property real inkOffset: (root.ink.l + root.ink.r) / 2 - root.implicitWidth / 2

    implicitWidth: root._cells[root._cells.length - 1].x
    implicitHeight: Math.ceil(fm.height)

    // ---- the roll ----------------------------------------------------------------------
    // Where a glyph sits in its cell, by its advance (as _inkOf places it).
    function _xOf(cell) {
        const f = fm.font;
        if (!cell)
            return 0;
        const adv = Math.ceil(fm.advanceWidth(cell.c));
        return Math.round(cell.x + (cell.natural ? 0 : root._isDigit(cell.c)
            ? (cell.before ? cell.w - adv : 0)
            : (cell.w - adv) / 2));
    }
    // What was shown, and per slot what it rolls from: { from, fromX, roll, delay }.
    // Built in the text's change handler from cells computed THERE (the bound
    // `_cells` may not have re-run yet inside the same change).
    property string _shown: ""
    property var _shownCells: []
    property var _plan: []
    property real _rollT: 1e9
    function _replan() {
        const cells = root.anchored && root.text.indexOf(":") > 0 ? root._anchoredCells() : root._slotCells();
        const old = root._shown, oldCells = root._shownCells;
        const same = root.rolling && old.length === root.text.length;
        const plan = new Array(root.text.length);
        let rank = 0;
        for (let i = root.text.length - 1; i >= 0; i--) {
            const to = root.text[i], from = same ? old[i] : to;
            const roll = same && from !== to && root._isDigit(from) && root._isDigit(to);
            plan[i] = { from: from, fromX: roll ? root._xOf(oldCells[i]) : 0, roll: roll, delay: roll ? rank * root.staggerMs : 0 };
            if (roll)
                rank++;
        }
        root._shown = root.text;
        root._shownCells = cells;
        root._plan = plan;
        if (rank > 0) {
            rollClock.to = root.rollMs + (rank - 1) * root.staggerMs;
            rollClock.duration = rollClock.to;
            rollClock.restart();
        } else {
            rollClock.stop();
            root._rollT = 1e9;
        }
    }
    onTextChanged: root._replan()
    onAnchoredChanged: root._replan()
    Component.onCompleted: root._replan()
    NumberAnimation {
        id: rollClock
        target: root
        property: "_rollT"
        from: 0
        paused: running && Theme.crossfading
    }

    Repeater {
        model: root.text.length
        delegate: Item {
            id: slot
            required property int index
            readonly property var cell: root._cells[slot.index] || ({ x: 0, w: 0, c: "", before: true })
            readonly property var step: root._plan[slot.index] || null
            readonly property bool rollingNow: slot.step !== null && slot.step.roll && slot.ph < 1
            // 0 -> 1 over this digit's roll; 1 = at rest
            readonly property real ph: slot.step && slot.step.roll ? Math.max(0, Math.min(1, (root._rollT - slot.step.delay) / Math.max(1, root.rollMs))) : 1
            // the old figure accelerates away over the first half, the new one settles in over the second
            readonly property real eOut: Math.pow(Math.min(1, slot.ph * 2), 2)
            readonly property real eIn: 1 - Math.pow(1 - Math.max(0, slot.ph * 2 - 1), 3)

            Text {
                id: ch
                text: slot.cell.c
                color: root.color
                font.family: root.fontFamily
                font.pixelSize: root.pixelSize
                x: Math.round(slot.cell.x + (slot.cell.natural ? 0 : slot.cell.c >= "0" && slot.cell.c <= "9"
                    ? (slot.cell.before ? slot.cell.w - ch.implicitWidth : 0)
                    : (slot.cell.w - ch.implicitWidth) / 2))
                y: slot.rollingNow ? (1 - slot.eIn) * root.rollDistance : 0
                opacity: slot.rollingNow ? slot.eIn : 1
                visible: opacity > 0
            }
            Text {
                visible: slot.rollingNow && slot.ph < 0.5
                text: slot.step ? slot.step.from : ""
                color: root.color
                font.family: root.fontFamily
                font.pixelSize: root.pixelSize
                x: slot.step ? slot.step.fromX : 0
                y: -slot.eOut * root.rollDistance
                opacity: 1 - slot.eOut
            }
        }
    }
}
