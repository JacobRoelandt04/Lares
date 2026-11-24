pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// UndoDrainButton.qml
//
// A RaisedButton that turns into Undo for a while: "Clear all" is pressed, the
// host clears and calls arm(), the words swap AT ONCE to "Undo", and the undo
// window drains away in the button's own shading until it runs out (expired)
// or is taken (undoClicked). `drain` (1 -> 0) is exposed so a host can show the
// same clock elsewhere.
//
// THE DRAIN IS SHADOWBOX'S PROGRESS SWEEP, IN THE BUTTON'S INSET. ShadowBox
// ignores progress on a raised box (its shader draws the tint only in a carved
// box's inset shadow), so the button carries a second, CARVED ShadowBox over
// its face with every colour transparent but the progress colour: what it
// draws is the sweep a carved header shows -- the band from the left edge up
// to the boundary, strongest at the rim and easing inward, crossing over on
// the same 12 px feather while it runs, but crisp to the end where a header's
// resting mark goes soft (see the restatement on the box) -- laid inside the
// raised button's rim, over its highlight: the carved headers' sweep in the
// button's own material, receding right to left as the window closes. On the
// accent variant the band is the deep shadow (`drainColor`).
//
// THE WORDS NEVER SPILL OUT OF THE PLATE: a host that brings the button in or
// out on its width (ManagerHeader) gets RaisedButton's label fade as the plate
// narrows past them.
//
// THE WIDTH NEVER MOVES. The button reserves the wider of its two words, so
// swapping "Clear all" for "Undo" moves nothing around it. The words are
// measured with FontMetrics whose own `font` is read inside the helper
// (CLAUDE.md: advanceWidth() in a binding captures nothing on its own), plus
// the pixel Qt adds to a bold it synthesizes, and the result is whole pixels.
//
// THE CLOCK IS THE WALL'S. The undo window it shows is the service's
// (`undoMs` from the clear), which runs on Date.now(); a NumberAnimation would
// run on Qt Quick's animation clock, which leads or lags the wall (a stalled
// frame holds it back), and the button would offer Undo after the service had
// closed the window, or give up before it. So the drain is recomputed from the
// deadline on every frame while it runs, and nothing runs at rest.
//
//   arm(leftMs)    enter the undo state; leftMs defaults to drainMs. A host
//                  that re-creates the button inside a window that is already
//                  running (the popup closed and reopened) passes what is left.
//   disarm()       back to the normal state at once, no signal.
//   clicked()      pressed in the normal state.
//   undoClicked()  pressed while undoing; the button has already disarmed.
//   expired()      the drain ran out; the button has already disarmed.
// =============================================================================
Item {
    id: root

    property string text: "Clear"
    property string undoText: "Undo"
    property int drainMs: 10000
    property color surfaceColor: Theme.surface
    property bool accent: false
    property string fontFamily: "Inter"
    property real fontPixelSize: 12
    property bool shadowToAlpha: false
    // The sweep's colour. On the accent plateau an accent band would not
    // show, and textOnAccent is the theme's surface -- a light glow in light
    // mode, a dark band in dark -- so it is the deep shadow there: an inset
    // shadow sweeping, in both.
    property color drainColor: root.accent ? Theme.shadowDeep : Theme.accent
    // How far the band reaches in from the rim, and how strong it is there:
    // the carved header's inset width, softer at the edge -- at 4 / 0.9 it
    // draws a stroke round the button (a focus ring), at 9 / 0.5 a haze.
    property real drainWidth: 7
    property real drainEdgeAlpha: 0.6

    readonly property bool undoing: root._undoing
    readonly property real drain: root._drain

    signal clicked()
    signal undoClicked()
    signal expired()

    function arm(leftMs) {
        const left = leftMs === undefined ? root.drainMs : Math.max(0, Math.min(root.drainMs, leftMs));
        root._endAt = Date.now() + left;
        root._drain = root.drainMs > 0 ? left / root.drainMs : 0;
        root._undoing = true;
        if (left <= 0)
            root._expire();
    }

    function disarm() {
        root._undoing = false;
        root._drain = 0;
    }

    implicitWidth: Math.ceil(button.implicitWidth)
    implicitHeight: button.implicitHeight

    property bool _undoing: false
    property real _drain: 0
    property double _endAt: 0
    // Presence: the band fades in with the swap and out with it.
    property real _inkF: root._undoing ? 1 : 0
    Behavior on _inkF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    FontMetrics {
        id: fm
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
        font.bold: true
    }
    // What the system matched for that font: a face with no bold of its own
    // (Audiowide) comes back in its Regular style.
    FontInfo {
        id: matched
        font: fm.font
    }
    // Reading `fm.font` here is the dependency: a re-measure happens after
    // the font object changed, not with the first answer for ever. A bold Qt
    // has to SYNTHESIZE lays a line out one pixel wider than its advances,
    // which FontMetrics does not count (measured on Audiowide at 12 px:
    // "Clear all" 53.91 advance, 54.91 laid out; "Undo" 34.91, 35.91) -- the
    // button would then grow a pixel for the longer word and the swap would
    // move it.
    function _advance(s) {
        const f = fm.font;
        if (!(f.pixelSize > 0))
            return 0;
        const synthetic = f.bold && !/bold|black|heavy/i.test(matched.styleName);
        return fm.advanceWidth(s) + (synthetic ? 1 : 0);
    }
    readonly property real _reserve: Math.ceil(Math.max(root._advance(root.text),
                                                        root._advance(root.undoText)))

    function _expire() {
        root.disarm();
        root.expired();
    }

    FrameAnimation {
        running: root._undoing
        onTriggered: {
            const left = root._endAt - Date.now();
            if (left <= 0) {
                root._expire();
                return;
            }
            root._drain = root.drainMs > 0 ? left / root.drainMs : 0;
        }
    }

    RaisedButton {
        id: button
        anchors.fill: parent
        text: root._undoing ? root.undoText : root.text
        accent: root.accent
        fontFamily: root.fontFamily
        fontPixelSize: root.fontPixelSize
        minWidth: root._reserve + button.horizontalPadding * 2
        surfaceColor: root.surfaceColor
        plateauColor: Theme.buttonPlateau
        plateauHoverColor: Theme.buttonPlateauHover
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        accentColor: Theme.accent
        accentHoverColor: Theme.accentHover
        accentBevelColor: Theme.accentBevel
        shadowToAlpha: root.shadowToAlpha
        onClicked: {
            if (!root._undoing) {
                root.clicked();
                return;
            }
            root.disarm();
            root.undoClicked();
        }

        ShadowBox {
            anchors.fill: parent
            visible: root._inkF > 0
            opacity: root._inkF
            baseRadius: button.radius
            surfaceColor: "transparent"
            bevelColor: "transparent"
            backgroundColor: "transparent"
            shadowColor: "transparent"
            bevelWidth: 0
            shadowWidth: root.drainWidth
            shadowEdgeAlpha: root.drainEdgeAlpha
            shadowProgress: root._drain
            shadowProgressColor: root.drainColor
            // A CLOCK, NOT A MARK: one shape all the way down, crisp at the
            // end. ShadowBox's own parked shape (a 12 px glow at 0.55 of the
            // strength, for a resting mark) would dissolve the last ~15 % of
            // a 60-76 px button's drain into nothing, so the parked half
            // restates the drain's own.
            progressIdleFeatherPx: 1.5
            progressIdleWidth: root.drainWidth
            progressActiveWidth: root.drainWidth
            progressIdleEdgeAlpha: root.drainEdgeAlpha
            progressIdleFalloff: 1
        }
    }
}
