pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// NetTrafficFigures.qml -- the down and up rates, two lines: a whole-Mbps figure
// and its arrow each (NetTraffic.js says what the figure is).
//
// THE ARROW STANDS RIGHT OF ITS FIGURE (a figure of one
// digit reads badly with the arrow at the far end of room reserved for two more).
// Both figures are right-aligned against ONE column, the arrows', so the units
// digit never moves and a figure that gains a digit grows to the left. What the
// block is as wide as is the host's say (`blockWidth`): the pill widens by half a
// digit per side for each digit the larger figure has (AerialBarButton), and the
// block follows the pill's own eased extent, so the arrows stay glued to the
// pill's middle and nothing here runs a clock of its own for it.
//
// A DIRECTION THAT CARRIES NOTHING (its figure reads 0) is quiet: its arrow and
// figure sit in the faint ink and take the primary ink as it starts. That is
// one eased FRACTION per direction (160 ms), mixed from the two themed colours
// with Mix.js -- never a Behavior on a colour. An arrow also gives one short
// kick (a bob) in its own direction on EVERY reading while its figure is not 0,
// equal to the last or not (the flourish plays on the polling
// interval), and is still otherwise.
// The host decides which reading that is (NetTraffic.js `rxBob`, once per reading,
// on the beat) and calls `bobRx()` / `bobTx()`; a bob is 260 ms, so it always ends
// before the next reading of a one-second beat and a direction never queues two.
//
// The arrows are drawn (DirectionArrow), not typed, so they sit on the same
// pixels in any font.
// =============================================================================
Item {
    id: root

    property int rx: 0
    property int tx: 0
    property bool rxActive: false
    property bool txActive: false
    property string fontFamily: "Inter"
    property real pixelSize: 9

    readonly property real arrowW: 5
    readonly property real arrowH: 7
    readonly property real arrowGap: 2

    readonly property real rowH: Math.ceil(measure.fontHeight)
    // One digit's cell: the widest digit's advance, whole pixels (DigitCells measures it).
    readonly property real digitW: measure.digitW
    // The block at its widest: three digits, the gap, the arrow. The host narrows it a digit at a time.
    readonly property real fullWidth: 3 * root.digitW + root.arrowGap + root.arrowW

    // The block's width now, the host's (it follows the pill's eased extent).
    property real blockWidth: root.fullWidth
    // Where the figures end and the arrow begins.
    readonly property real _figureRight: root.blockWidth - root.arrowW - root.arrowGap

    implicitWidth: root.blockWidth
    implicitHeight: 2 * root.rowH

    // The same measuring DigitCells does (its digit cell), read off one of them.
    DigitCells {
        id: measure
        visible: false
        text: "0"
        fontFamily: root.fontFamily
        pixelSize: root.pixelSize
        bold: false
        readonly property real fontHeight: measure.implicitHeight
    }

    property real _rxF: root.rxActive ? 1 : 0
    property real _txF: root.txActive ? 1 : 0
    Behavior on _rxF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on _txF { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    // One bob: 2 px in the arrow's own direction and back, in WHOLE pixels: the fraction runs on its clock and the arrow
    // sits on the nearest pixel, so a bob is four pictures (+1, +2, +1, 0) and not one a frame -- with no damage regions
    // every picture is a frame of the whole bar window, and a bob a beat would otherwise hold it at vsync for a quarter of
    // the time (13 frames a reading offscreen against 4). A 1.2 px stroke is also crisper on a pixel than between two.
    // `rxKick` / `txKick` are the fraction (0 at rest).
    //
    // THE TIPS NEVER TOUCH. The two arrows bob TOWARD each other (the down arrow of the upper line down, the up arrow of
    // the lower line up) and rest `arrowClearance` = rowH - arrowH (4 px) apart, so two bobs of 2 px close the gap to 0
    // and the arrows would fuse into an hourglass for ~100 ms a beat. A bob that starts
    // while the other arrow bobs -- on the same reading, or with the other still running -- is 1 px (+1, 0): the pair
    // closes at most 3 px of the 4 and a pixel of ground is always between the tips. A bob on its own keeps its 2 px.
    property real rxKick: 0
    property real txKick: 0
    property int _rxAmp: 2
    property int _txAmp: 2
    // The pixels each arrow stands off its rest place now, and the clear rows between the tips (read by a probe).
    readonly property int rxShift: Math.round(root._rxAmp * root.rxKick)
    readonly property int txShift: Math.round(root._txAmp * root.txKick)
    readonly property real arrowClearance: txArrow.y - (rxArrow.y + root.arrowH)
    SequentialAnimation {
        id: rxKickAnim
        NumberAnimation { target: root; property: "rxKick"; to: 1; duration: 110; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "rxKick"; to: 0; duration: 150; easing.type: Easing.InOutQuad }
    }
    SequentialAnimation {
        id: txKickAnim
        NumberAnimation { target: root; property: "txKick"; to: 1; duration: 110; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "txKick"; to: 0; duration: 150; easing.type: Easing.InOutQuad }
    }
    // `together`: the other direction bobs on this very reading (the host knows; the other's animation has not started yet).
    function bobRx(together) {
        root._rxAmp = together || txKickAnim.running ? 1 : 2;
        rxKickAnim.restart();
    }
    function bobTx(together) {
        root._txAmp = together || rxKickAnim.running ? 1 : 2;
        txKickAnim.restart();
    }

    // ---- down, then up ------------------------------------------------------
    DirectionArrow {
        id: rxArrow
        x: root.blockWidth - root.arrowW
        y: Math.round((root.rowH - root.arrowH) / 2) + root.rxShift
        up: false
        ink: Mix.c(Theme.textFaint, Theme.textPrimary, root._rxF)
    }
    DigitCells {
        x: root._figureRight - implicitWidth
        y: 0
        text: String(root.rx)
        fontFamily: root.fontFamily
        pixelSize: root.pixelSize
        bold: false
        color: Mix.c(Theme.textFaint, Theme.textPrimary, root._rxF)
    }
    DirectionArrow {
        id: txArrow
        x: root.blockWidth - root.arrowW
        y: root.rowH + Math.round((root.rowH - root.arrowH) / 2) - root.txShift
        up: true
        ink: Mix.c(Theme.textFaint, Theme.textPrimary, root._txF)
    }
    DigitCells {
        x: root._figureRight - implicitWidth
        y: root.rowH
        text: String(root.tx)
        fontFamily: root.fontFamily
        pixelSize: root.pixelSize
        bold: false
        color: Mix.c(Theme.textFaint, Theme.textPrimary, root._txF)
    }
}
