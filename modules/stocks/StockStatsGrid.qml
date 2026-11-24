pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/StocksFormat.js" as F

// =============================================================================
// StockStatsGrid.qml -- the twelve figures under the detail's chart.
//
//   Open        High        Low
//   Prev close  Volume      Avg vol
//   Mkt cap     P/E         EPS
//   Div yield   Beta        52w range
//   [ the 52-week groove: the price between the year's low and high ]
//
// The groove has no labels of its own: the "52w range" figure above it
// already says what its ends are.
//
// Yahoo's own numbers (open, high, low, prev close, volume, 52w) are
// formatted here; CNBC's (avg vol, market cap, P/E, EPS, yield, beta) are
// its own strings, shown as they come. Anything missing is "—", never a
// zero. The groove is carved; the price is a raised dot standing in it.
// =============================================================================
Item {
    id: grid

    property var stats: null
    property var quote: null
    property int priceHint: 2
    property string fontFamily: "Inter"
    property real cardPadding: 12
    property real radius: 14
    property int bodySize: 12
    property int figureSize: 11
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real shadowFalloff: 1
    property int columns: 3

    function _num(v) {
        return typeof v === "number" && isFinite(v);
    }
    readonly property string currency: grid.quote ? (grid.quote.currency || "") : ""
    function _p(v) {
        return grid._num(v) ? F.price(v, "", grid.priceHint) : "\u2014";
    }
    function _s(v) {
        return (typeof v === "string" && v.length > 0) ? v : "\u2014";
    }

    // Facts only: label + text (no colour in the model).
    readonly property var cells: {
        const s = grid.stats || {};
        return [
            { label: "Open", text: grid._p(s.open) },
            { label: "High", text: grid._p(s.high) },
            { label: "Low", text: grid._p(s.low) },
            { label: "Prev close", text: grid._p(s.prevClose) },
            { label: "Volume", text: grid._num(s.volume) ? F.volume(s.volume) : "\u2014" },
            { label: "Avg vol", text: grid._s(s.avgVol) },
            { label: "Mkt cap", text: grid._s(s.mcap) },
            { label: "P/E", text: grid._s(s.pe) },
            { label: "EPS", text: grid._s(s.eps) },
            { label: "Div yield", text: grid._s(s.divYield) },
            { label: "Beta", text: grid._s(s.beta) },
            { label: "52w range", text: grid._num(s.w52Lo) && grid._num(s.w52Hi) ? F.price(s.w52Lo, "", grid.priceHint) + " \u2013 " + F.price(s.w52Hi, "", grid.priceHint) : "\u2014" }
        ];
    }

    readonly property real _lineH: Math.ceil(grid.bodySize * 1.4)
    readonly property real _cellH: 2 * grid._lineH + 2
    readonly property int _rows: Math.ceil(grid.cells.length / grid.columns)
    readonly property real _grooveH: 8
    implicitHeight: Math.round(grid.cardPadding + grid._rows * grid._cellH + (grid._rows - 1) * 6
                               + grid.cardPadding + grid._grooveH + grid.cardPadding)

    ShadowBox {
        anchors.fill: parent
        baseRadius: grid.radius
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: grid.bevelWidth
        shadowWidth: grid.shadowWidth
        shadowFalloff: grid.shadowFalloff
    }

    readonly property real _cellW: (grid.width - 2 * grid.cardPadding) / grid.columns
    Repeater {
        model: grid.cells.length
        delegate: Item {
            id: cell
            required property int index
            readonly property var c: grid.cells[cell.index]
            x: Math.round(grid.cardPadding + (cell.index % grid.columns) * grid._cellW)
            y: Math.round(grid.cardPadding + Math.floor(cell.index / grid.columns) * (grid._cellH + 6))
            width: Math.round(grid._cellW) - 8
            height: grid._cellH
            Text {
                x: 0
                y: 0
                width: parent.width
                height: grid._lineH
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: cell.c ? cell.c.label : ""
                color: Theme.textMuted
                font.family: grid.fontFamily
                font.pixelSize: grid.figureSize
            }
            Text {
                x: 0
                y: grid._lineH + 2
                width: parent.width
                height: grid._lineH
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: cell.c ? cell.c.text : ""
                color: cell.c && cell.c.text === "\u2014" ? Theme.textFaint : Theme.textPrimary
                font.family: grid.fontFamily
                font.pixelSize: grid.bodySize
                font.bold: true
            }
        }
    }

    // ---- the 52-week groove ----------------------------------------------------------------
    readonly property var _w52: {
        const s = grid.stats || {};
        const lo = s.w52Lo, hi = s.w52Hi;
        const p = grid.quote && grid._num(grid.quote.price) ? grid.quote.price : NaN;
        if (!grid._num(lo) || !grid._num(hi) || hi <= lo || !grid._num(p))
            return null;
        return { f: Math.max(0, Math.min(1, (p - lo) / (hi - lo))) };
    }
    Item {
        id: groove
        x: grid.cardPadding
        y: grid.cardPadding + grid._rows * grid._cellH + (grid._rows - 1) * 6 + grid.cardPadding
        width: grid.width - 2 * grid.cardPadding
        height: grid._grooveH
        opacity: grid._w52 ? 1 : 0.5

        ShadowBox {
            anchors.fill: parent
            baseRadius: height / 2
            surfaceColor: Theme.listBox
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.panelSunk
            bevelWidth: 1
            shadowWidth: 2
        }
        ShadowBox {
            visible: !!grid._w52
            x: grid._w52 ? Math.round(grid._w52.f * (groove.width - width)) : 0
            y: -2
            width: groove.height + 4
            height: groove.height + 4
            baseRadius: width / 2
            raised: true
            surfaceColor: Theme.panelSunk
            bevelColor: Theme.accentBevel
            shadowColor: Theme.buttonShadow
            backgroundColor: Theme.accent
            bevelWidth: 1
            shadowWidth: 2
        }
    }
}
