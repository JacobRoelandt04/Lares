pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/StocksFormat.js" as F

// =============================================================================
// StockPosition.qml -- what the user holds of this stock, and how they got it.
//
//   Position                                     Total gain  +€1,234.56 +7.3%
//   12 shares · avg 1,122.10 EUR · value €17,968.80
//   realised €0.00 · net dividends €41.20 · fees €7.50 (in the gains)
//   ─────────────────────────────────────────────────────────────
//   2024-03-11  Buy   10 × 880.00 EUR   fees 3.50      (newest first)
//               "first tranche, after the Q4 call"
//   ...
//
// THE TRANSACTIONS SCROLL, THE REST DOES NOT, AND THE LIST'S ROOM IS A STATIC SIZE: the title and subtitle stay anchored, and a stock
// with more holdings than fit scrolls them within the holdings container, not the entire secondary content.
// The list's viewport is `tradeRows` rows and a `tradesPeek` of the next, whatever the stock holds -- one trade or forty
// -- so the card, and the secondary around it, never change height with the trades, and a fourth row's top says there
// is more. It scrolls in its own viewport (newest first) and the host (StockDetail) reads its wheel through
// `tradesScroller` (one wheel reader per box: CLAUDE.md, "two readers of one wheel event").
//
// THE DATE AND TYPE SLOTS ARE MEASURED, NOT GUESSED. A fixed 78 and 36 px is Inter's width; in
// Audiowide (no tabular figures, a wide face) "2024-03-11" is wider than 78 and the Buy text -- the next
// slot -- would be drawn over the end of the date. Each slot is the widest string it can hold (the widest
// digit for a date, the wider of "Buy" / "Sell" for the type) plus a gap, from FontMetrics of its own
// font, so the layout follows whatever face the shell wears without turning the dates monospace.
//
// The total gain is a GAIN FIGURE: hovering it asks for real figures, which
// swaps its text and its label word with every other gain figure at once, and
// a pale pill flashes behind its money and its % (GainFlash, `realFlash`).
// Trade prices are as entered (the currency Yahoo quotes); Buy is stockBuy,
// Sell is stockSell -- not gain/loss green and red, which mean something else.
// =============================================================================
Item {
    id: pos
    objectName: "stockPosition"

    property var holding: null
    property var service: null
    property int priceHint: 2
    property string fontFamily: "Inter"
    property real cardPadding: 12
    property real radius: 14
    property int bodySize: 12
    property int figureSize: 11
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real shadowFalloff: 1
    property real flashPeak: 0.22
    property real flashPad: 3
    // The list's viewport: this many whole rows (the first rows, a comment makes one taller) and this share of the next, so
    // a list with more shows where it goes on. Three is what the user holds on most stocks.
    property int tradeRows: 3
    property real tradesPeek: 0.6
    property real tradeGap: 6

    readonly property var h: pos.holding
    readonly property bool real: !!pos.service && pos.service.showReal
    readonly property real flash: pos.service && typeof pos.service.realFlash === "number" ? pos.service.realFlash : 0
    readonly property string currency: pos.h ? (pos.h.currency || "") : ""
    function _num(v) {
        return typeof v === "number" && isFinite(v) ? v : 0;
    }
    readonly property real gain: pos.h ? pos._num(pos.real ? pos.h.totalReal : pos.h.total) : 0
    readonly property real gainPct: pos.h ? pos._num(pos.real ? pos.h.totalPctReal : pos.h.totalPct) : 0
    // Newest first (the engine's list is in the order the trades were applied: oldest first).
    readonly property var trades: pos.h && pos.h.trades ? pos.h.trades.slice().reverse() : []

    readonly property real _lineH: Math.ceil(pos.bodySize * 1.4)
    // Everything but the list: the card's own lines and both paddings.
    readonly property real _chrome: Math.round(pos.cardPadding + pos._lineH + 6 + 2 * pos._lineH + 2 + pos.cardPadding
                                                    + pos.cardPadding)
    // The list as it asks, and as shown (whole pixels: a clip edge on a half pixel shimmers).
    readonly property real tradesNaturalHeight: tradesCol.implicitHeight
    // The viewport: static, on whole pixels (a clip edge on a half pixel shimmers).
    readonly property real tradesViewHeight: Math.ceil(pos.tradeRows * (pos._lineH + pos.tradeGap) + pos.tradesPeek * pos._lineH)
    readonly property bool tradesScrollable: pos.tradesNaturalHeight > pos.tradesViewHeight + 0.5
    // The list's viewport, in this item's coordinates, and its scroll engine (for the host's wheel reader).
    readonly property alias tradesViewport: tradesFlick
    readonly property alias tradesScroller: tradesDressing
    implicitHeight: pos._chrome + pos.tradesViewHeight

    // The slots of a trade row, widest-string wide (see the header). A call to advanceWidth() captures
    // nothing, so each reads the metrics' own `font` first: that read is the dependency, and it guarantees
    // the re-measure comes after the font changed (CLAUDE.md, FontMetrics.advanceWidth in a binding).
    FontMetrics { id: dateFm; font.family: pos.fontFamily; font.pixelSize: pos.figureSize }
    FontMetrics { id: typeFm; font.family: pos.fontFamily; font.pixelSize: pos.figureSize; font.bold: true }
    readonly property real _dateSlot: {
        const f = dateFm.font;
        let wide = 0;
        for (const d of "0123456789")
            wide = Math.max(wide, dateFm.advanceWidth(d));
        return Math.ceil(8 * wide + 2 * dateFm.advanceWidth("-")) + 12;
    }
    // +1: a synthesized bold (a face with no bold) lays out a pixel wider than the metrics say.
    readonly property real _typeSlot: {
        const f = typeFm.font;
        return Math.ceil(Math.max(typeFm.advanceWidth("Buy"), typeFm.advanceWidth("Sell"))) + 1 + 10;
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: pos.radius
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: pos.bevelWidth
        shadowWidth: pos.shadowWidth
        shadowFalloff: pos.shadowFalloff
    }

    Text {
        id: title
        x: pos.cardPadding
        y: pos.cardPadding
        height: pos._lineH
        verticalAlignment: Text.AlignVCenter
        text: pos.h && pos.h.shares > 0 ? "Position" : "Closed position"
        color: Theme.textPrimary
        font.family: pos.fontFamily
        font.pixelSize: pos.bodySize
        font.bold: true
    }

    // The gain: label word + money + pct, right-aligned, one hover.
    Row {
        id: gainRow
        x: pos.width - pos.cardPadding - width
        y: pos.cardPadding
        height: pos._lineH
        spacing: 8
        Text {
            objectName: "positionGainWord"
            height: gainRow.height
            verticalAlignment: Text.AlignVCenter
            text: pos.real ? "Real gain" : "Total gain"
            color: Theme.textMuted
            font.family: pos.fontFamily
            font.pixelSize: pos.bodySize
        }
        Text {
            id: gainMoney
            height: gainRow.height
            verticalAlignment: Text.AlignVCenter
            text: F.signedMoney(pos.gain)
            color: pos.gain < 0 ? Theme.stockLoss : Theme.stockGain
            font.family: pos.fontFamily
            font.pixelSize: pos.figureSize
            font.bold: true
            GainFlash {
                objectName: "positionGainFlash"
                target: gainMoney
                strength: pos.flash
                peak: pos.flashPeak
                hPad: pos.flashPad
            }
        }
        Text {
            id: gainPct
            height: gainRow.height
            verticalAlignment: Text.AlignVCenter
            text: F.pct(pos.gainPct)
            color: pos.gain < 0 ? Theme.stockLoss : Theme.stockGain
            font.family: pos.fontFamily
            font.pixelSize: pos.figureSize
            font.bold: true
            GainFlash {
                target: gainPct
                strength: pos.flash
                peak: pos.flashPeak
                hPad: pos.flashPad
            }
        }
    }
    MouseArea {
        id: gainHover
        objectName: "positionGainHover"
        anchors.fill: gainRow
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
        onContainsMouseChanged: {
            if (pos.service)
                pos.service.realHover("detail-position", gainHover.containsMouse);
        }
    }

    Text {
        id: line1
        x: pos.cardPadding
        y: title.y + title.height + 6
        width: pos.width - 2 * pos.cardPadding
        height: pos._lineH
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: {
            const h = pos.h;
            if (!h)
                return "";
            const parts = [];
            if (h.shares > 0) {
                parts.push(F.shares(h.shares) + " shares");
                parts.push("avg " + F.price(pos._num(h.avgCostNative), pos.currency, pos.priceHint));
                parts.push("value " + F.money(pos._num(h.value)));
            } else {
                parts.push(h.closedOn ? "sold out " + h.closedOn : "sold out");
            }
            return parts.join(" · ");
        }
        color: Theme.textPrimary
        font.family: pos.fontFamily
        font.pixelSize: pos.figureSize
    }
    Text {
        id: line2
        x: pos.cardPadding
        y: line1.y + line1.height + 2
        width: pos.width - 2 * pos.cardPadding
        height: pos._lineH
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: {
            const h = pos.h;
            if (!h)
                return "";
            return "realised " + F.signedMoney(pos._num(pos.real ? h.realisedReal : h.realised))
                + " · net dividends " + F.money(pos._num(pos.real ? h.dividendsReal : h.dividends))
                + " · fees " + F.money(pos._num(h.fees)) + " (in the gains)";
        }
        color: Theme.textMuted
        font.family: pos.fontFamily
        font.pixelSize: pos.figureSize
    }

    Rectangle {
        x: pos.cardPadding
        y: line2.y + line2.height + pos.cardPadding / 2
        width: pos.width - 2 * pos.cardPadding
        height: 1
        color: Theme.border
    }

    // The list's viewport: a clip on whole pixels, no bevel inside it to shear. Driven by the host's wheel
    // reader, never by the Flickable itself (interactive: false).
    Flickable {
        id: tradesFlick
        objectName: "positionTradesFlick"
        x: pos.cardPadding
        y: line2.y + line2.height + pos.cardPadding
        width: pos.width - 2 * pos.cardPadding
        height: pos.tradesViewHeight
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: pos.tradesNaturalHeight
        Column {
            id: tradesCol
            width: tradesFlick.width
            spacing: pos.tradeGap
            Repeater {
                model: pos.trades.length
                delegate: Item {
                    id: trade
                    required property int index
                    readonly property var t: pos.trades[trade.index] || null
                    readonly property bool buy: !!trade.t && trade.t.type === "buy"
                    width: tradesCol.width
                    height: pos._lineH + (commentText.text.length > 0 ? commentText.implicitHeight + 1 : 0)
                    Text {
                        id: dateText
                        x: 0
                        y: 0
                        width: pos._dateSlot
                        height: pos._lineH
                        verticalAlignment: Text.AlignVCenter
                        text: trade.t ? trade.t.date : ""
                        color: Theme.textMuted
                        font.family: pos.fontFamily
                        font.pixelSize: pos.figureSize
                    }
                    Text {
                        id: typeText
                        x: dateText.width
                        y: 0
                        width: pos._typeSlot
                        height: pos._lineH
                        verticalAlignment: Text.AlignVCenter
                        text: trade.buy ? "Buy" : "Sell"
                        color: trade.buy ? Theme.stockBuy : Theme.stockSell
                        font.family: pos.fontFamily
                        font.pixelSize: pos.figureSize
                        font.bold: true
                    }
                    Text {
                        x: typeText.x + typeText.width
                        y: 0
                        width: trade.width - x
                        height: pos._lineH
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                        text: {
                            const t = trade.t;
                            if (!t)
                                return "";
                            let s = F.shares(pos._num(t.shares)) + " \u00D7 " + F.price(pos._num(t.price), pos.currency, pos.priceHint);
                            if (pos._num(t.fees) > 0)
                                s += " · fees " + F.price(t.fees, pos.currency);
                            if (pos._num(t.eur) !== 0)
                                s += " · " + F.money(Math.abs(t.eur));
                            return s;
                        }
                        color: Theme.textPrimary
                        font.family: pos.fontFamily
                        font.pixelSize: pos.figureSize
                    }
                    Text {
                        id: commentText
                        x: typeText.x
                        y: pos._lineH + 1
                        width: trade.width - x
                        wrapMode: Text.Wrap
                        text: trade.t && trade.t.comment ? trade.t.comment : ""
                        visible: text.length > 0
                        color: Theme.textFaint
                        font.family: pos.fontFamily
                        font.pixelSize: pos.figureSize
                        font.italic: true
                    }
                }
            }
        }
    }
    ScrollDressing {
        id: tradesDressing
        anchors.fill: tradesFlick
        flick: tradesFlick
        ground: Theme.listBox
        fadeHeight: 14
        wheelEnabled: false
    }
}
