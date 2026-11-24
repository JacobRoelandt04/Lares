pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// StockMoveBody.qml -- a stock's day on a small chart, the card's rich body (sudden moves and the plain alerts).
//
//   facts   ONE object, so a re-feed (the 1-minute sharpening) is one write:
//     t, c          the day so far: ms times and closes, oldest first, the live price last (gaps stay gaps)
//     prevClose     yesterday's close: the dashed baseline
//     sessionStart  the day's open (ms): the left end of the time axis
//     nowMs         the right end of the axis, never less than an hour after the open (so a card a few minutes after the
//                   open is not three points stretched wide)
//     kind          "sudden" | "above" | "below" | "dayMove"
//     dir           "up" | "down": the sign colour of what is emphasised (sudden) or of the whole line (the alerts: the day's)
//     fromMs, toMs  sudden: the span of the move, drawn over the faint day in the sign colour with a soft fill under it
//     level         above / below: the alert's price, a second dashed line in the accent
//     minSpanPct    the least price span the box's height stands for, in % of prevClose (a small move looks small)
//   hostCard        handed in by the card (its font)
//
// Under the line two figures in the card's own face: sudden -- the move's start time centred at its x and now at the
// right; the alerts -- the open at the left and now at the right. They never overlap and never leave the box. Times
// are the user's local zone. Ink on the card: no box, no layer, no canvas; one Sparkline (CurveRenderer shapes). A
// drop-in: sized by implicitHeight, the width it is given, no assumption about the host beyond `hostCard`'s font.
// =============================================================================
Item {
    id: root

    property var facts: null
    property var hostCard: null

    readonly property string fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
    readonly property int metaSize: root.hostCard && root.hostCard._metaSize ? root.hostCard._metaSize : 11
    readonly property int labelSize: Math.max(9, root.metaSize - 1)

    readonly property var _f: root.facts ? root.facts : ({})
    readonly property bool _sudden: root._f.kind === "sudden"
    readonly property bool _levelKind: root._f.kind === "above" || root._f.kind === "below"
    readonly property real _from: root._f.sessionStart !== undefined ? Number(root._f.sessionStart) : NaN
    // One hour at least: the line of a young day covers only the left part.
    readonly property real _to: isFinite(root._from) ? Math.max(Number(root._f.nowMs), root._from + 3600000) : NaN
    readonly property color _sign: root._f.dir === "down" ? Theme.stockLoss : Theme.stockGain

    readonly property int chartHeight: 34
    readonly property int labelGap: 3
    readonly property int labelHeight: Math.ceil(fm.height)

    implicitHeight: root.chartHeight + root.labelGap + root.labelHeight

    function _hhmm(ms) {
        return isFinite(ms) ? Qt.formatTime(new Date(ms), "HH:mm") : "";
    }

    FontMetrics {
        id: fm
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
    }
    TextMetrics {
        id: leftM
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        text: root._sudden ? root._hhmm(root._f.fromMs) : root._hhmm(root._f.sessionStart)
    }
    TextMetrics {
        id: nowM
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        text: root._hhmm(root._f.nowMs)
    }
    readonly property int _leftW: Math.ceil(leftM.advanceWidth)
    readonly property int _nowW: Math.ceil(nowM.advanceWidth)
    readonly property int _gapMin: 6
    readonly property int _nowX: Math.max(0, Math.round(root.width) - root._nowW)
    // The left label: centred on the move's start (sudden) or flush left (the alerts), then kept inside the box and
    // clear of `now`.
    readonly property int _leftX: {
        const want = root._sudden ? Math.round(chart.xAt(root._f.fromMs) - root._leftW / 2) : 0;
        return Math.max(0, Math.min(want, root._nowX - root._gapMin - root._leftW));
    }

    Sparkline {
        id: chart
        width: root.width
        height: root.chartHeight
        values: root._f.c || []
        times: root._f.t || null
        timeFrom: root._from
        timeTo: root._to
        baselineValue: root._f.prevClose !== undefined && root._f.prevClose !== null ? Number(root._f.prevClose) : NaN
        rangeMinSpan: root._f.minSpanPct > 0 && root._f.prevClose > 0 ? root._f.minSpanPct / 100 * root._f.prevClose : 0
        rangePad: 0.1
        lineWidth: root._sudden ? 1.25 : 1.5
        color: root._sudden ? Theme.textFaint : root._sign
        emphasisFrom: root._sudden ? Number(root._f.fromMs) : NaN
        emphasisTo: root._sudden ? Number(root._f.toMs) : NaN
        emphasisColor: root._sign
        emphasisWidth: 1.75
        emphasisFill: root._sudden ? 0.18 : 0
        endDot: 2.25
        endDotColor: root._sign
        levelValue: root._levelKind && root._f.level !== undefined && root._f.level !== null ? Number(root._f.level) : NaN
        levelColor: Theme.accent
    }

    Text {
        x: root._leftX
        y: root.chartHeight + root.labelGap
        text: leftM.text
        color: Theme.textFaint
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        textFormat: Text.PlainText
    }
    Text {
        x: root._nowX
        y: root.chartHeight + root.labelGap
        text: nowM.text
        color: Theme.textFaint
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
        textFormat: Text.PlainText
    }
}
