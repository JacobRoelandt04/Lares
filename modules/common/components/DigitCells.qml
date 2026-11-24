pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// DigitCells.qml -- a figure that never jitters: every character in a cell of
// its own, every DIGIT cell as wide as the font's widest digit.
//
// Audiowide has no tabular figures, so "11:11" is narrower than "00:00" and a
// running clock set as one Text shivers every second. Here each character is
// its own Text centred in a fixed cell: a digit cell is the widest digit, any
// other character (":" "." " " "h") its own advance. The width depends only
// on the text's SHAPE ("00:00" vs "0:00:00"), never on its digits, and a
// change of shape is a change of what is shown, not a tick.
//
// One Repeater over the text's LENGTH (a number), so a tick changes what the
// cells say without rebuilding them.
//
// A DIGIT THAT CHANGES MAY ROLL (`rolling`, off by default: the cells swap at once).
// It is the lock screen's roll (LockDigits):
// the old figure rises out and fades over the first half of its roll, the new one rises in
// from below over the second -- presence, never two figures over each other -- and changed
// digits cascade right to left, `staggerMs` apart, as an odometer carries ("09:59" ->
// "10:00": the units first, the hour's tens last). ONE clock (`_rollT`, ms since the change)
// and every cell's phase is a function of it, so at rest nothing runs and nothing asks for a
// frame. A change of the text's SHAPE (its length) and a character that is not a digit swap
// at once. Held still while the theme crossfades (a crossfade is a still picture of the
// frame before; whatever keeps moving under it is a second copy of itself).
//
// WITH `proportional` A ROLL MAY ALSO GLIDE (`glide`): the cells' lefts follow the digits, so a figure that changes width pushes
// every figure after it sideways in one frame -- on the bar's clock the seconds' units would stand 4-7 px elsewhere from one frame to the
// next, and the leaving figure would jump to its successor's cell. The glide eases the cells' lefts (and so the width) from the picture that was on show to the new one on the
// roll's own clock (`_rollT`: one clock per motion), the leaving and the arriving figure each centred in the cell as it is at that
// instant, so nothing moves by more than a pixel or so a frame and the kerned figures still land where they were measured.
// =============================================================================
Item {
    id: cells

    property string text: ""
    property string fontFamily: "Audiowide"
    property real pixelSize: 40
    property bool bold: true
    property color color: Theme.textPrimary
    // Extra space on each side of a separator, px.
    property real separatorGap: 0
    // EVERY DIGIT IN ITS OWN ADVANCE instead of the widest digit's (off: every digit gets the widest digit's cell). For the bar's
    // clock, where "1" in a cell of "0"'s width stands 3-4 px from its neighbours: the width then follows the digits, so a host that must not move
    // when a digit changes reserves the widest layout itself and centres the figure in it, on whole pixels.
    property bool proportional: false
    // WITH `proportional`, EACH CELL ITS GLYPH'S EXACT (FRACTIONAL) ADVANCE instead of the advance rounded up (off: rounded up, the
    // clock's arithmetic, which counts in whole-pixel cells). For a STANDALONE figure that must set like a plain Text of the same
    // string (the weather's temperature, the stocks' percentage, the battery's charge): rounded up, every cell is up to a pixel
    // wide of its glyph and "−0.87%" sets 4.5 px wider than the Text, the gaps showing round the sign and the "%". Each glyph
    // still stands on a whole pixel (its own x is rounded), the cells' lefts and the width are fractional: a host rounds where
    // it places the figure.
    property bool exactAdvances: false
    // A rolling change eases the cells' lefts from the old text's to the new one's (see the header). For `proportional` figures; off:
    // the cells' lefts follow the text at once.
    property bool glide: false
    // A glyph's presence, per character of the text, 0..1 (missing entries: 1; off: empty). For a host that brings a figure in a
    // character at a time -- the clock's seconds, each arriving as the room for it opens. Multiplies the roll's own fade.
    property var glyphAlpha: []
    function _alphaOf(i) {
        return i < cells.glyphAlpha.length ? cells.glyphAlpha[i] : 1;
    }
    // The roll of a changed digit: on/off, one digit's length, the cascade's step, how far a figure travels.
    property bool rolling: false
    property int rollMs: 420
    property int staggerMs: 70
    property real rollDistance: Math.round(cells.pixelSize * 0.18)

    FontMetrics {
        id: fm
        font.family: cells.fontFamily
        font.pixelSize: cells.pixelSize
        font.bold: cells.bold
    }

    // Measured with the metrics' own font read INSIDE the helper: an
    // advanceWidth() call alone captures nothing, and would keep its first
    // answer (taken before the family applied) for ever.
    readonly property real digitW: {
        const f = fm.font;
        let w = 0;
        for (let d = 0; d <= 9; d++)
            w = Math.max(w, fm.advanceWidth(String(d)));
        return Math.ceil(w);
    }
    function _isDigit(ch) {
        return ch >= "0" && ch <= "9";
    }
    function cellWidth(ch) {
        const f = fm.font;
        if (cells._isDigit(ch) && !cells.proportional)
            return cells.digitW;
        const adv = fm.advanceWidth(ch);
        return (cells.proportional && cells.exactAdvances ? adv : Math.ceil(adv)) + 2 * cells.separatorGap;
    }
    // Cell lefts of a text: one array, the last entry the whole width.
    function _leftsOf(str: string): var {
        const f = fm.font;
        const out = [];
        let x = 0;
        for (let i = 0; i < str.length; i++) {
            out.push(x);
            x += cells.cellWidth(str[i]);
        }
        out.push(x);
        return out;
    }
    readonly property var _lefts: cells._leftsOf(cells.text)

    // Where the cells stand now: the text's lefts, or -- during a glide -- the ones the roll started from eased toward them.
    property var _from: null
    property real _glideTotal: 1
    readonly property real _g: {
        if (cells._from === null)
            return 1;
        const t = Math.max(0, Math.min(1, cells._rollT / cells._glideTotal));
        return t * t * (3 - 2 * t);
    }
    function _blend(from: var, to: var, g: real): var {
        if (from === null || from.length !== to.length || g >= 1)
            return to;
        const out = new Array(to.length);
        for (let i = 0; i < to.length; i++)
            out[i] = from[i] + (to[i] - from[i]) * g;
        return out;
    }
    readonly property var _pos: cells._blend(cells._from, cells._lefts, cells._g)

    implicitWidth: cells._pos[cells._pos.length - 1]
    implicitHeight: Math.ceil(fm.height)

    // ---- the roll ---------------------------------------------------------------------
    // What was shown, and per cell what it rolls from: { from, roll, delay }. Built in the text's change handler.
    property string _shown: cells.text
    property var _plan: []
    property real _rollT: 1e9
    function _replan() {
        const old = cells._shown;
        const same = cells.rolling && old.length === cells.text.length;
        const plan = new Array(cells.text.length);
        // where the cells stand at this instant (a glide may be under way): the next glide starts from there
        const standing = same && cells.glide ? cells._blend(cells._from, cells._leftsOf(old), cells._g) : null;
        let rank = 0;
        for (let i = cells.text.length - 1; i >= 0; i--) {
            const to = cells.text[i], from = same ? old[i] : to;
            const roll = same && from !== to && cells._isDigit(from) && cells._isDigit(to);
            plan[i] = { from: from, roll: roll, delay: roll ? rank * cells.staggerMs : 0 };
            if (roll)
                rank++;
        }
        cells._shown = cells.text;
        cells._plan = plan;
        if (rank > 0) {
            cells._glideTotal = cells.rollMs + (rank - 1) * cells.staggerMs;
            cells._rollT = 0;
            rollClock.to = cells._glideTotal;
            rollClock.duration = rollClock.to;
            rollClock.restart();
            // after the restart: a restart that stops the running clock first would clear it (onRunningChanged)
            cells._from = standing;
        } else {
            rollClock.stop();
            cells._from = null;
            cells._rollT = 1e9;
        }
    }
    onTextChanged: cells._replan()
    NumberAnimation {
        id: rollClock
        target: cells
        property: "_rollT"
        from: 0
        paused: running && Theme.crossfading
        onRunningChanged: {
            if (!running)
                cells._from = null;
        }
    }

    // Where a cell stands in its roll: 0 -> 1 over the digit's own roll, 1 at rest (no plan, no roll, or landed). Functions, not
    // delegate properties: the glyph and the figure it replaces are separate items and both read the same answer.
    function _phase(i) {
        const st = cells._plan[i];
        return st && st.roll ? Math.max(0, Math.min(1, (cells._rollT - st.delay) / Math.max(1, cells.rollMs))) : 1;
    }
    // the old figure accelerates away over the first half, the new one settles in over the second
    function _eOut(ph) {
        return Math.pow(Math.min(1, ph * 2), 2);
    }
    function _eIn(ph) {
        return 1 - Math.pow(1 - Math.max(0, ph * 2 - 1), 3);
    }

    Repeater {
        model: cells.text.length
        delegate: Text {
            id: ch
            required property int index
            readonly property string c: cells.text.charAt(ch.index)
            readonly property real cellW: (cells._pos[ch.index + 1] || 0) - (cells._pos[ch.index] || 0)
            readonly property real ph: cells._phase(ch.index)
            readonly property bool rolling: ch.ph < 1
            x: Math.round((cells._pos[ch.index] || 0) + (ch.cellW - ch.implicitWidth) / 2)
            y: ch.rolling ? Math.round((1 - cells._eIn(ch.ph)) * cells.rollDistance) : 0
            text: ch.c
            color: cells.color
            opacity: cells._alphaOf(ch.index) * (ch.rolling ? cells._eIn(ch.ph) : 1)
            font.family: cells.fontFamily
            font.pixelSize: cells.pixelSize
            font.bold: cells.bold
        }
    }
    // The figures that are leaving, in an item of their own so that `children` of the cells stays the glyphs (a probe walks it).
    Item {
        id: goneLayer
        Repeater {
            model: cells.text.length
            delegate: Text {
                id: gone
                required property int index
                readonly property real ph: cells._phase(gone.index)
                readonly property real cellW: (cells._pos[gone.index + 1] || 0) - (cells._pos[gone.index] || 0)
                visible: gone.ph < 0.5
                x: Math.round((cells._pos[gone.index] || 0) + (gone.cellW - gone.implicitWidth) / 2)
                y: -Math.round(cells._eOut(gone.ph) * cells.rollDistance)
                text: cells._plan[gone.index] ? cells._plan[gone.index].from : ""
                color: cells.color
                opacity: cells._alphaOf(gone.index) * (1 - cells._eOut(gone.ph))
                font.family: cells.fontFamily
                font.pixelSize: cells.pixelSize
                font.bold: cells.bold
            }
        }
    }
}
