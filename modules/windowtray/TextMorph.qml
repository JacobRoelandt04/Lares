pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "TextDiff.js" as TextDiff

// =============================================================================
// TextMorph.qml -- a line of text that, when it changes, moves only what
// changed.
//
//   TextMorph {
//       text: window.shownTitle
//       key: window.cls                  // a new key WITH the text = a whole replacement
//       fontFamily: "Inter"; pixelSize: 12; color: Theme.textPrimary
//       maxWidth: 360; ground: Theme.surface
//   }
//
// AT REST it is ONE plain Text (`Text.PlainText`), nothing animating, no Timer
// running: the cost of a title nobody is changing is that of the Text itself.
//
// THE PLAN of a change is TextDiff.diffPlan(shown, next): the common prefix
// (it stands still), the old and the new middle, the common tail (it slides).
// A change of `key` together with the text is a whole replacement (prefix and
// tail empty): the app changed, the title is a different thing.
//
// ONE CLOCK, `u`, 0 -> 1 over `durationMs` (OutCubic, one NumberAnimation);
// everything below is a function of it:
//   - the tail's x is lerp(tailOld, tailNew, u);
//   - the width the cell asks for is lerp(wOld, wNew, u), so the strip around
//     it follows the same motion;
//   - `drift` (default): the old middle lifts `driftPx` and fades over the
//     first 60 % of the clock (outF), the new one settles in from `driftPx`
//     below over the last 60 % (inF), so the two are never both at full
//     opacity; `wipe`: a front sweeps the gap left to right, the new middle
//     revealed behind it, the old one ahead of it, the front softened by a
//     veil of the ground colour that is gone when the front arrives; `swap`:
//     no motion at all.
//   BOTH MIDDLES ARE CLIPPED TO THE LIVE GAP, [where they start, the tail's x]
//   (plus a slack of a quarter of the type size that covers the ink a kerned
//   neighbour overlaps and that is handed from the old middle to the new one
//   along the clock), so a change that shrinks the text never lets the tail
//   slide over an old middle that is still visible.
//
// THE HANDOVER IS PIXEL-IDENTICAL. The last morph frame and the plain Text
// that replaces it draw the same pixels, because the pieces stand where the
// plain Text's glyphs stand: a piece's x is the advance of everything before
// it measured WITH its own first letter in (pre + X[0]) less that letter's
// own advance, which keeps the kerning between the last letter before the
// piece and its first (the pieces' own widths miss
// it: 0.7 px on the tail). The two middles each have their own offset (the
// old middle's first letter and the new one's kern differently against the
// prefix). Measured with hidden Texts of the very same face, never
// FontMetrics (a synthesized bold is laid out wider). Nothing is rounded: the
// plain Text's glyphs stand at fractional x. Baselines are aligned, not tops:
// a piece without the fallback glyph that raises the whole line's ascent
// ("◐ x" against "x") would otherwise sit higher than it does in the whole.
//
// A MORPH ALWAYS PLAYS OUT. Nothing cancels, reverses, replans or skips a morph in
// flight. A change that arrives while one runs is QUEUED, and only the LATEST
// text (with its key) is kept: `text` and `key` already hold it, so the queue
// is nothing but a second look at them when the clock ends. The morph that
// follows starts from what is shown to that latest text (if it differs; a key
// change with it is a whole replacement, as always). A burst of changes is
// therefore the running morph, then ONE morph to where the burst ended, and
// the texts in between are never shown. `keyFrom` / `replacing` describe the
// RUNNING morph only: a key written meanwhile belongs to the queued one.
// THE ONE EXCEPTION is a theme crossfade, which is a still picture of the frame
// before: anything that keeps moving under it is a second copy of itself. A
// morph in flight when one starts lands on its target at once, and the queued
// text SWAPS (the same rule as any change during a crossfade: it is not held
// for the crossfade's end). A change of the face (`fontFamily`, `pixelSize`,
// `bold`) lands a morph the same way, for a technical reason: the plan was
// measured in the old face and cannot be played in the new.
//
// WHEN IT DOES NOT MORPH (the change is a plain swap, instantly):
//   - `mode: "swap"`, a zero duration, or a theme crossfade in progress;
//   - the SHAPING GUARD (_shapesApart): a ligature or a contextual form
//     spanning a piece boundary (Inter's "->" arrow), or a colour emoji a piece
//     would place at a fraction of a pixel, swaps. Plain kerning does not: the
//     offsets below carry it exactly (a path's slash tightens by a pixel before
//     every name);
//   - `endFade` 0 (ElideRight) and either text does not fit `maxWidth`.
//
// THE END. A text wider than the cell (`maxWidth`, or a `holdWidth` cell the
// text outgrew) is clipped at the cell and its last `endFade` px dissolve into
// `ground` -- the reel's fog: an opaque band whose gradient is alpha-matched to
// the ground. The band is as strong as the text is over the edge (0 at a
// whole fit, 1 from 2 px over), so a morph that crosses the cell's width
// brings it in on the clock instead of popping. `endFade` 0 elides at the
// right instead ("…"), and morphs only when both texts fit.
//
// The width is whole pixels at rest, ceil(min(maxWidth, text)); on the clock
// it is ceil(lerp(wOld, wNew, u)) between the two (never narrower than the
// text, so the morph clips nothing; the ends are the same whole pixels).
// `holdWidth` freezes it where it is while the host keeps a strip open around
// it: the text still changes inside, the end fade covers the overflow.
//
// THE REST STATE IS u = outF = inF = 1: a host that drifts its icon on the
// same clock keeps the previous app's icon on a layer that is gone at rest
// (opacity 1 - outF, y = -d*outF) and the current one on a layer that is
// settled (opacity inF, y = d*(1 - inF)); a morph starts at 0 and runs to 1
// and a swap never leaves 1.
//
// DECIDED ONCE PER TURN. `text` and `key` are two properties a host writes in
// two statements; the decision waits for a 0 ms Timer so it sees both (a
// title change that lands before its key would otherwise be planned as a diff
// inside the old app).
// =============================================================================
Item {
    id: root

    // ---- in --------------------------------------------------------------
    property string text: ""
    property string fontFamily: "Inter"
    property int pixelSize: 12
    property bool bold: false
    property color color: Theme.textPrimary
    // 0 = unlimited.
    property real maxWidth: 0
    // px of the end faded into `ground` when the text is cut; 0 = ElideRight.
    property real endFade: 24
    // What the end fades into: the surface the text stands on.
    property color ground: Theme.surface
    // "drift" | "wipe" | "swap"
    property string mode: "drift"
    property int durationMs: 220
    property real driftPx: 3
    // The wipe's front: how wide its veil is, at most.
    property real wipeSoftPx: 10
    // The widest a pair of letters may change width at a piece boundary and
    // still be taken for a kern, in ems (see _shapesApart).
    property real kernMax: 0.125
    // true: implicitWidth stays where it is.
    property bool holdWidth: false
    // A change of key together with the text = a whole replacement.
    property var key: ""

    // ---- out -------------------------------------------------------------
    readonly property bool morphing: root._morphing
    // The clock: 1 at rest, 0 -> 1 through a morph (already eased).
    readonly property real u: root._u
    // The share of the clock in which the old middle is still leaving while the new
    // one already arrives (drift). 0: the old is gone at half way and only then
    // does the new come (no two words on one place, but an empty instant between).
    property real overlap: 0.2
    readonly property real _half: 0.5 + Math.max(0, Math.min(1, root.overlap)) / 2
    readonly property real outF: Math.max(0, Math.min(1, root._u / root._half))
    readonly property real inF: Math.max(0, Math.min(1, (root._u - (1 - root._half)) / root._half))
    // True while the morph in flight is a whole replacement (the key changed with
    // the text), and the key it came from: a host drifts what the key names (the
    // window title's app mark) on outF / inF of exactly that morph. A key written
    // while it runs waits for the next one and changes neither.
    readonly property bool replacing: root._morphing && root._keyFrom !== root._keyShown
    readonly property var keyFrom: root._keyFrom
    // The text ends wider than the cell it will have.
    readonly property bool truncated: root._natTarget > root._targetCell + 0.01

    implicitWidth: root.holdWidth ? root._heldW : root._baseW
    implicitHeight: Math.ceil(ref.implicitHeight)

    // ---- state -----------------------------------------------------------
    property bool _complete: false
    property string _shown: ""            // what the plain Text draws
    property var _keyShown: ""            // the key of the shown (or in-flight) text
    property bool _morphing: false
    property real _u: 1
    property string _from: ""
    property string _to: ""
    property var _keyFrom: ""
    property string _pre: ""
    property string _oldMid: ""
    property string _newMid: ""
    property string _tail: ""
    // Where the pieces stand in the old and the new string (fractional px).
    property real _midOldX: 0
    property real _midNewX: 0
    property real _tailOldX: 0
    property real _tailNewX: 0
    // The two whole strings' natural widths.
    property real _natFrom: 0
    property real _natTo: 0

    readonly property real _cap: root.maxWidth > 0 ? root.maxWidth : 1e9
    readonly property real _wFrom: Math.ceil(Math.min(root._cap, root._natFrom))
    readonly property real _wTo: Math.ceil(Math.min(root._cap, root._natTo))
    readonly property real _baseW: root._morphing
        ? Math.ceil(root._wFrom + (root._wTo - root._wFrom) * root._u)
        : Math.ceil(Math.min(root._cap, shownSize.implicitWidth))
    // The width asked for just before a hold, kept while it lasts.
    property real _heldW: 0
    Binding {
        target: root
        property: "_heldW"
        value: root._baseW
        when: !root.holdWidth || root._heldW <= 0
        restoreMode: Binding.RestoreNone
    }
    // The text's width as it stands (or is heading), and how far it goes over
    // the cell: the end fade's strength.
    readonly property real _natNow: root._morphing
        ? root._natFrom + (root._natTo - root._natFrom) * root._u
        : shownSize.implicitWidth
    readonly property real _natTarget: root._morphing ? root._natTo : shownSize.implicitWidth
    // The cell the text ends in (a hold included): over it, it is cut.
    readonly property real _targetCell: root.holdWidth ? root._heldW : Math.ceil(Math.min(root._cap, root._natTarget))
    readonly property real _over: root._natNow - root.width
    readonly property real _bandOpacity: root.endFade > 0 ? Math.max(0, Math.min(1, root._over / 2)) : 0
    readonly property bool _clipOn: root._over > 0.01

    // ---- the pieces' places on the clock ---------------------------------------
    readonly property int _slack: Math.ceil(root.pixelSize * 0.25)
    readonly property int _pad: Math.ceil(root.pixelSize)
    readonly property real _refBase: ref.baselineOffset
    readonly property real _gs: Math.min(root._midOldX, root._midNewX)
    readonly property real _tailX: root._tailOldX + (root._tailNewX - root._tailOldX) * root._u
    readonly property real _front: root._gs + (root._tailX - root._gs) * root._u
    readonly property bool _wipe: root.mode === "wipe"
    // Each middle's clip, [left, right]: the gap, with the slack the old one
    // hands to the new one along the clock (so the first frame draws the old
    // string exactly and the last the new one).
    readonly property real _oldL: root._wipe ? root._front - root._slack * (1 - root._u) : root._gs - root._slack
    readonly property real _oldR: root._tailX + root._slack * (1 - root._u)
    readonly property real _newL: root._gs - root._slack * root._u
    readonly property real _newR: (root._wipe ? root._front : root._tailX) + root._slack * root._u

    // ---- the decision ------------------------------------------------------------
    onTextChanged: root._ask()
    onKeyChanged: root._ask()
    function _ask() {
        if (!root._complete) {
            root._shown = root.text;
            root._keyShown = root.key;
            return;
        }
        defer.restart();
    }
    Timer {
        id: defer
        interval: 0
        onTriggered: root._evaluate()
    }
    Component.onCompleted: {
        root._shown = root.text;
        root._keyShown = root.key;
        root._complete = true;
    }
    onFontFamilyChanged: root._endMorph()
    onPixelSizeChanged: root._endMorph()
    onBoldChanged: root._endMorph()
    Connections {
        target: Theme
        function onCrossfadingChanged() {
            if (Theme.crossfading)
                root._endMorph();
        }
    }

    // A morph in flight is not touched: the latest `text` / `key` wait where they
    // are, and _endMorph() looks at them again when it lands.
    function _evaluate() {
        if (root._morphing)
            return;
        const want = root.text;
        const keyed = root.key !== root._keyShown;
        if (want === root._shown) {
            root._keyShown = root.key;
            return;
        }
        if (root.mode === "swap" || root.durationMs <= 0 || Theme.crossfading) {
            root._swapTo(want);
            return;
        }
        const pl = keyed
            ? { pre: "", oldMid: root._shown, newMid: want, tail: "" }
            : TextDiff.diffPlan(root._shown, want);
        if (!pl || !root._begin(pl, root._shown, want))
            root._swapTo(want);
    }

    // ---- the morph -----------------------------------------------------------------
    // The advance of `s` in the face, as the plain Text lays it out. A call:
    // never from a binding (it would keep its first answer).
    function _adv(s) {
        scratch.text = s;
        return scratch.implicitWidth;
    }
    function _first(s) {
        return s === "" ? "" : TextDiff.graphemes(s)[0];
    }

    // THE SHAPING GUARD, for one string cut into pre + mid + tail: can the
    // pieces be drawn apart and look like the whole?
    //   - at each boundary the pair of letters either side must not change
    //     width by more than `kernMax` of the type size: that is a kern (Inter
    //     tightens "f" and a slash before a lowercase letter by a whole pixel
    //     at 12 px, and a path has a slash before every name) and the offsets
    //     below carry it exactly; a bigger change is a ligature or a contextual
    //     form, which the pieces would draw as the letters they are on their
    //     own (Inter's "->" and "=>" arrows, 2 px and 4.4 px at 12 px);
    //   - a colour emoji is laid down on whole pixels, so a piece holding one
    //     must stand where the whole puts it (the same baseline): an emoji's
    //     own line sits higher than the text's, and the piece alone would be
    //     placed at a fraction.
    function _shapesApart(whole, pre, mid, tail) {
        const tol = root.kernMax * root.pixelSize;
        const pairs = [];
        if (pre !== "" && mid !== "")
            pairs.push([pre, mid]);
        if (mid !== "" && tail !== "")
            pairs.push([mid, tail]);
        if (mid === "" && pre !== "" && tail !== "")
            pairs.push([pre, tail]);
        for (const p of pairs) {
            const g = TextDiff.graphemes(p[0]);
            const a = g[g.length - 1];
            const b = root._first(p[1]);
            if (Math.abs(root._adv(a + b) - root._adv(a) - root._adv(b)) > tol)
                return false;
        }
        scratch.text = whole;
        const base = scratch.baselineOffset;
        for (const piece of [pre, mid, tail]) {
            if (piece === "" || !root._hasEmoji(piece))
                continue;
            scratch.text = piece;
            if (Math.abs(scratch.baselineOffset - base) > 0.01)
                return false;
        }
        return true;
    }
    function _hasEmoji(s) {
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            if ((c >= 0xD83C && c <= 0xD83E) || (c >= 0x2300 && c <= 0x23FF) || (c >= 0x2600 && c <= 0x27BF)
                    || (c >= 0x2B00 && c <= 0x2BFF) || c === 0xFE0F)
                return true;
        }
        return false;
    }

    // false: the change is not one to morph (nothing has been written).
    function _begin(pl, from, to) {
        const pre = pl.pre, om = pl.oldMid, nm = pl.newMid, tl = pl.tail;
        const natFrom = root._adv(from);
        const natTo = root._adv(to);
        if (root.endFade <= 0 && (natFrom > root._cap + 0.01 || natTo > root._cap + 0.01))
            return false;
        if (!root._shapesApart(from, pre, om, tl) || !root._shapesApart(to, pre, nm, tl))
            return false;
        // Where each piece stands in its own string.
        const o0 = root._first(om), n0 = root._first(nm), t0 = root._first(tl);
        const offs = f => pre === "" ? 0 : root._adv(pre + f) - root._adv(f);
        let xo = om !== "" ? offs(o0) : null;
        let xn = nm !== "" ? offs(n0) : null;
        if (xo === null)
            xo = xn;
        if (xn === null)
            xn = xo;
        const tOld = tl === "" ? natFrom : root._adv(pre + om + t0) - root._adv(t0);
        const tNew = tl === "" ? natTo : root._adv(pre + nm + t0) - root._adv(t0);
        // The plan first, the clock last.
        root._natFrom = natFrom;
        root._natTo = natTo;
        root._pre = pre;
        root._oldMid = om;
        root._newMid = nm;
        root._tail = tl;
        root._midOldX = xo;
        root._midNewX = xn;
        root._tailOldX = tOld;
        root._tailNewX = tNew;
        root._from = from;
        root._to = to;
        root._keyFrom = root._keyShown;
        root._keyShown = root.key;
        root._u = 0;
        root._morphing = true;
        clock.from = 0;
        clock.to = 1;
        clock.duration = root.durationMs;
        clock.start();
        return true;
    }
    NumberAnimation {
        id: clock
        target: root
        property: "_u"
        easing.type: Easing.OutCubic
        onFinished: root._endMorph()
    }
    // Land on the target, now, and look at what was queued meanwhile: the next
    // morph (or swap) starts in this same turn, so no frame draws the rest in
    // between.
    function _endMorph() {
        if (!root._morphing)
            return;
        clock.stop();
        root._shown = root._to;
        root._morphing = false;
        root._u = 1;
        root._evaluate();
    }
    function _swapTo(s) {
        root._shown = s;
        root._keyShown = root.key;
        root._u = 1;
    }

    // ---- what a probe reads ----------------------------------------------------------
    function debugState() {
        const piece = (face, clip) => ({
            text: face.text,
            x: (clip ? clip.x : 0) + face.x,
            y: face.y,
            opacity: face.opacity,
            visible: face.visible && (clip ? clip.width > 0 : true),
            clipL: clip ? clip.x : face.x,
            clipR: clip ? clip.x + clip.width : face.x + face.width
        });
        return {
            morphing: root._morphing, u: root._u, mode: root.mode, shown: root._shown,
            from: root._from, to: root._to, width: root.implicitWidth,
            keyFrom: root._keyFrom, keyShown: root._keyShown, replacing: root.replacing,
            truncated: root.truncated, slack: root._slack,
            gs: root._gs, tailX: root._tailX, tailOldX: root._tailOldX, tailNewX: root._tailNewX,
            midOldX: root._midOldX, midNewX: root._midNewX, front: root._front,
            clipOn: root._clipOn, band: bandRect.visible ? bandRect.opacity : 0,
            pre: piece(preFace, null),
            oldMid: piece(oldFace, oldClip),
            newMid: piece(newFace, newClip),
            tail: piece(tailFace, null)
        };
    }
    function debugPlan() {
        return { pre: root._pre, oldMid: root._oldMid, newMid: root._newMid, tail: root._tail };
    }
    // A probe holds the clock where it asks, then lets it go (the last morph
    // frame cannot otherwise be caught: the handover is in the same tick).
    function debugSeek(v) {
        if (!root._morphing)
            return;
        clock.stop();
        root._u = v;
    }
    function debugRelease() {
        root._endMorph();
    }

    // ---- drawing -----------------------------------------------------------------------
    component Face: Text {
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
        font.bold: root.bold
        color: root.color
    }
    // A clip as tall as the box plus its padding: glyphs a fallback font
    // raises above the line are not cut by the gap, only by the cell's end.
    component GapClip: Item {
        clip: true
        y: -root._pad
        height: root.implicitHeight + 2 * root._pad
    }

    // The measuring Texts: hidden, the face of the real ones.
    Face { id: ref; visible: false; text: "x" }
    Face { id: scratch; visible: false }
    Face { id: shownSize; visible: false; text: root._shown }

    Item {
        id: box
        y: -root._pad
        width: root.width
        height: root.implicitHeight + 2 * root._pad
        clip: root._clipOn

        Item {
            id: content
            y: root._pad

            // At rest, and for every swap: the plain Text.
            Face {
                id: plainFace
                objectName: "tmPlain"
                visible: !root._morphing
                x: 0
                y: root._refBase - plainFace.baselineOffset
                text: root._shown
                elide: root.endFade > 0 ? Text.ElideNone : Text.ElideRight
                width: root.endFade > 0 ? shownSize.implicitWidth : root.width
            }

            Face {
                id: preFace
                objectName: "tmPre"
                visible: root._morphing && preFace.text !== ""
                x: 0
                y: root._refBase - preFace.baselineOffset
                text: root._pre
            }
            GapClip {
                id: oldClip
                visible: root._morphing && oldFace.text !== "" && (root._wipe || root.outF < 1)
                x: root._oldL
                width: Math.max(0, root._oldR - root._oldL)
                Face {
                    id: oldFace
                    objectName: "tmOldMid"
                    x: root._midOldX - oldClip.x
                    y: root._pad + root._refBase - oldFace.baselineOffset - (root._wipe ? 0 : root.driftPx * root.outF)
                    opacity: root._wipe ? 1 : 1 - root.outF
                    text: root._oldMid
                }
            }
            GapClip {
                id: newClip
                visible: root._morphing && newFace.text !== "" && (root._wipe || root.inF > 0)
                x: root._newL
                width: Math.max(0, root._newR - root._newL)
                Face {
                    id: newFace
                    objectName: "tmNewMid"
                    x: root._midNewX - newClip.x
                    y: root._pad + root._refBase - newFace.baselineOffset + (root._wipe ? 0 : root.driftPx * (1 - root.inF))
                    opacity: root._wipe ? 1 : root.inF
                    text: root._newMid
                }
            }
            // The wipe's veil: ground over the front, strongest mid-morph,
            // none at either end, inside the gap and nowhere else.
            GapClip {
                id: veilClip
                visible: root._morphing && root._wipe && veilBar.width > 0
                x: root._gs
                width: Math.max(0, root._tailX - root._gs)
                readonly property real amp: 4 * root._u * (1 - root._u)
                Rectangle {
                    id: veilBar
                    y: 0
                    height: parent.height
                    width: Math.min(root.wipeSoftPx, veilClip.width)
                    x: root._front - root._gs - veilBar.width / 2
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, 0) }
                        GradientStop { position: 0.5; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, veilClip.amp) }
                        GradientStop { position: 1; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, 0) }
                    }
                }
            }
            Face {
                id: tailFace
                objectName: "tmTail"
                visible: root._morphing && tailFace.text !== ""
                x: root._tailX
                y: root._refBase - tailFace.baselineOffset
                text: root._tail
            }
        }
    }

    // The fog over a cut end: ground, alpha-matched (a ramp to "transparent"
    // would tint the band grey).
    Rectangle {
        id: bandRect
        visible: root._bandOpacity > 0.004
        opacity: root._bandOpacity
        width: Math.min(root.endFade, root.width)
        height: root.implicitHeight
        x: root.width - bandRect.width
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.rgba(root.ground.r, root.ground.g, root.ground.b, 0) }
            GradientStop { position: 1; color: root.ground }
        }
    }
}
