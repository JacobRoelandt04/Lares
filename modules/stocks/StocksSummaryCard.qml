pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/StocksFormat.js" as F
import "data/StockSeries.js" as SS
import "../common/scroll"

// =============================================================================
// StocksSummaryCard.qml -- the portfolio at a glance, the popup's first card.
//
//   Portfolio  updated 11:02                Day    +€123.45   +0.84%
//   €18,100.80                       Total gain  +€1,234.56   +7.31%
//   Value vs invested                  1D 5D 1M 6M YTD 1Y 5Y ALL
//   [ the chart: value (line + area) over invested (step)          ]
//   [ AEX  +0.42%    BEL 20  -0.10%    S&P 500  +0.33%  (rolling)   ]
//
// Every figure sits in its own slot as wide as its template (StocksFormat),
// right-aligned, so nothing moves when a digit does. The total (the portfolio's value, at the left) is a
// plain Text: it changes at the poll's pace, nothing sits beside it that its width could move, and the
// font's own kerning is what a big figure wants. DigitCells would put every digit in a cell as wide as the
// widest, which spreads "€18,100.80" apart in Audiowide (no tabular figures): a number that does not tick beside
// other text is a plain Text.
//
// THE REAL FLIP. Hovering the total gain asks the service for real figures
// (`realHover`): every gain figure in the popup and the detail swaps its text
// and its label word at once ("Total gain" -> "Real gain"), and a pale pill
// flashes behind every figure that flipped (GainFlash, on the service's one
// `realFlash` clock). The same hover shows the breakdown tip. The service
// lingers 80 ms on the last leave, so moving from one gain figure to another
// never flashes nominal.
//
// THE NOTE BESIDE THE TITLE says when the figures on show were fetched, faint, like the weather's ("updated 11:02"); when
// they cannot be trusted it says why in the warn colour instead ("offline, from 08:02", "stale, from ...", "rate limited,
// retry ..."): one fact, said once. It is TAKEN when the service publishes figures (`updated`), so it changes with them and
// never a turn before (a fetch lands, the figures follow a 0 ms timer later: figures change together), and when a failure
// says so (offline, rate limited), which publishes nothing: then on the next turn, when the service has written the whole
// failure (`retryAtMs` follows `rateLimited`). No clock of its own.
//
// SCRUBBING. Over the chart the hairline and a dot on each line follow the
// pointer (the chart's markerIndex is its hoverIndex, on slots that have a
// value), and the chart's title line becomes the readout -- the point's date
// (its time on 1D / 5D) · the value · the invested -- in fixed slots, swapped
// at once and back on leave. The range chips step with a sideways swipe
// (StockRangeChips) over them or the chart: one band from the chips' top to
// the chart's foot, across the card, reads it (`rangeSwipe`).
// =============================================================================
Item {
    id: card

    property var service: null
    property var popup: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property real cardPadding: 12
    property real radius: 14
    property real chartHeight: 96
    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11
    property real totalSize: 24
    property int cycleMs: 4000
    property int rollMs: 420
    property int staggerMs: 90
    property int hoverDwellMs: 400
    property int releaseGraceMs: 250
    property real flashPeak: 0.22
    property real flashPad: 3
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real shadowFalloff: 1
    // Two figure lines and the room a roll travels in (RollingCells rolls as
    // far as its delegate's free room: (42 - 33) / 2 = 4 px each way).
    property real stripHeight: 42

    readonly property var _p: card.service ? card.service.portfolio : null
    readonly property bool _ready: !!card._p && !(card.service && card.service.loading)
    readonly property bool real: !!card.service && card.service.showReal
    // The real flip's flash, 0..1: the service's one clock.
    readonly property real flash: card.service && typeof card.service.realFlash === "number" ? card.service.realFlash : 0

    // StockSeries hands colours as ROLES; the theme is resolved here, in the
    // binding, so a switch re-resolves (a themed colour never sits in a model).
    function _role(r) {
        switch (r) {
        case "gain":
            return Theme.stockGain;
        case "loss":
            return Theme.stockLoss;
        case "buy":
            return Theme.stockBuy;
        case "sell":
            return Theme.stockSell;
        case "faint":
            return Theme.textFaint;
        case "accent":
            return Theme.accent;
        default:
            return Theme.textMuted;
        }
    }
    function _resolve(list) {
        return (list || []).map(s => Object.assign({}, s, {
            color: card._role(s.role || s.color)
        }));
    }
    // The axis in whole euros, thousands as k: "€40k", "€12.5k", "€800".
    function _axisMoney(v) {
        const a = Math.abs(v);
        const s = v < 0 ? "\u2212" : "";
        if (a >= 1e6)
            return s + "\u20AC" + (a / 1e6).toFixed(a % 1e6 === 0 ? 0 : 1) + "M";
        if (a >= 1e3)
            return s + "\u20AC" + (a / 1e3).toFixed(a % 1e3 === 0 ? 0 : 1) + "k";
        return s + "\u20AC" + Math.round(a);
    }
    function _num(v) {
        return typeof v === "number" && isFinite(v) ? v : 0;
    }

    readonly property real dayGain: card._num(card._p ? card._p.dayGain : 0)
    readonly property real dayPct: card._num(card._p ? card._p.dayPct : 0)
    // THE TOP-RIGHT FIGURE FOLLOWS THE RANGE. On 5D, 1M, 6M, YTD, 1Y and 5Y it is what the portfolio gained over
    // that range (StockSeries.rangeMove: the value's change less the money put in meanwhile), labelled with
    // the range's name; on 1D it is the day, and on ALL too (ALL's figure is the total gain, the line below).
    // It belongs to the picture the chart shows (`_move`, written where the chart's spec is), so while a range
    // loads the old figure and its old label stay together.
    property var _move: null                    // { range, change, pct } or null (the day's figure)
    readonly property string topLabel: card._move ? card._move.range : "Day"
    readonly property real topGain: card._move ? card._num(card._move.change) : card.dayGain
    readonly property real topPct: card._move ? card._num(card._move.pct) : card.dayPct
    readonly property real totalGain: card._num(card._p ? (card.real ? card._p.totalReal : card._p.total) : 0)
    readonly property real totalPct: card._num(card._p ? (card.real ? card._p.totalPctReal : card._p.totalPct) : 0)

    // ---- slots -------------------------------------------------------------------------
    TextMetrics {
        id: moneySlot
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
        font.bold: true
        text: F.signedMoneyTemplate(Math.max(888.88, Math.abs(card.totalGain), Math.abs(card.dayGain), Math.abs(card.topGain)))
    }
    TextMetrics {
        id: pctSlot
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
        font.bold: true
        text: F.pctTemplate(Math.max(88.88, Math.abs(card.totalPct), Math.abs(card.dayPct), Math.abs(card.topPct)))
    }
    readonly property real moneyW: Math.ceil(moneySlot.advanceWidth)
    readonly property real pctW: Math.ceil(pctSlot.advanceWidth)
    readonly property real figGap: 8

    readonly property real _lineH: Math.ceil(Math.max(card.bodySize, card.figureSize) * 1.4)
    readonly property real _headH: Math.max(card._lineH * 2 + 4, card._lineH + 4 + card.totalSize * 1.25)

    implicitHeight: Math.round(card.cardPadding + card._headH + card.cardPadding
                               + card._lineH + 4 + card.chartHeight + card.cardPadding
                               + card.stripHeight + card.cardPadding)

    ShadowBox {
        anchors.fill: parent
        baseRadius: card.radius
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: card.bevelWidth
        shadowWidth: card.shadowWidth
        shadowFalloff: card.shadowFalloff
    }

    // ---- the head: value on the left, day and total on the right ---------------------
    Text {
        id: titleText
        x: card.cardPadding
        y: card.cardPadding
        height: card._lineH
        verticalAlignment: Text.AlignVCenter
        text: "Portfolio"
        color: Theme.textMuted
        font.family: card.fontFamily
        font.pixelSize: card.bodySize
    }
    // THE NOTE (header): when the figures on show were fetched, or why they cannot be trusted.
    Text {
        id: statusText
        objectName: "stocksStatus"
        readonly property var n: card._note
        readonly property bool fresh: !!statusText.n && !statusText.n.configError && !statusText.n.offline && !statusText.n.rateLimited && !statusText.n.stale
        x: titleText.x + titleText.width + 8
        y: titleText.y
        height: card._lineH
        verticalAlignment: Text.AlignVCenter
        text: {
            const n = statusText.n;
            if (!n || n.loading)
                return "";
            const at = n.at > 0 ? Qt.formatDateTime(new Date(n.at), "HH:mm") : "";
            if (n.configError)
                return "stocks.jsonc has an error";
            if (n.offline)
                return "offline" + (at ? ", from " + at : "");
            if (n.rateLimited)
                return "rate limited" + (n.retryAtMs > 0 ? ", retry " + Qt.formatDateTime(new Date(n.retryAtMs), "HH:mm") : "");
            if (n.stale)
                return "stale" + (at ? ", from " + at : "");
            return at ? "updated " + at : "";
        }
        color: statusText.fresh ? Theme.textFaint : Theme.warn
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
    }
    // The service's state as the note shows it, in one object (a note read off live flags would see the new `stale` a turn
    // before the new figures and their time).
    property var _note: null
    function _takeNote(): void {
        const s = card.service;
        card._note = !s ? null : {
            at: s.fetchedAtMs,
            loading: s.loading === true,
            offline: s.offline === true,
            configError: s.configError ? String(s.configError) : "",
            stale: s.stale === true,
            rateLimited: s.rateLimited === true,
            retryAtMs: s.retryAtMs || 0
        };
    }
    function _failed(): void {
        if (card.service && (card.service.offline || card.service.rateLimited))
            Qt.callLater(card._takeNote);
    }
    onServiceChanged: card._takeNote()
    Connections {
        target: card.service
        ignoreUnknownSignals: true
        function onUpdated() {
            card._takeNote();
        }
        function onOfflineChanged() {
            card._failed();
        }
        function onConfigErrorChanged() {
            card._takeNote();
        }
        function onRateLimitedChanged() {
            card._failed();
        }
        function onRetryAtMsChanged() {
            card._failed();
        }
    }
    Text {
        id: totalText
        objectName: "summaryTotal"
        x: card.cardPadding
        y: titleText.y + titleText.height + 2
        text: card._ready ? F.money(card._num(card._p.value)) : "—"
        font.family: card.fontFamily
        font.pixelSize: card.totalSize
        font.bold: true
        color: Theme.textPrimary
    }

    // Right block: two lines of label + money + pct, every figure in a slot.
    Item {
        id: figures
        readonly property real w: card.moneyW + card.figGap + card.pctW
        x: card.width - card.cardPadding - labelW - card.figGap - w
        y: card.cardPadding
        width: labelW + card.figGap + w
        height: 2 * card._lineH + 4
        readonly property real labelW: Math.ceil(Math.max(dayLabelM.advanceWidth, gainLabelM.advanceWidth, realLabelM.advanceWidth))

        TextMetrics {
            id: dayLabelM
            font.family: card.fontFamily
            font.pixelSize: card.bodySize
            text: "Day"
        }
        TextMetrics {
            id: gainLabelM
            font.family: card.fontFamily
            font.pixelSize: card.bodySize
            text: "Total gain"
        }
        TextMetrics {
            id: realLabelM
            font.family: card.fontFamily
            font.pixelSize: card.bodySize
            text: "Real gain"
        }

        Repeater {
            model: 2
            delegate: Item {
                id: line
                required property int index
                readonly property bool isTotal: line.index === 1
                readonly property real money: line.isTotal ? card.totalGain : card.topGain
                readonly property real pct: line.isTotal ? card.totalPct : card.topPct
                readonly property color tone: line.money < 0 ? Theme.stockLoss : Theme.stockGain
                x: 0
                y: line.index * (card._lineH + 4)
                width: figures.width
                height: card._lineH

                Text {
                    objectName: line.isTotal ? "summaryGainWord" : ""
                    x: 0
                    width: figures.labelW
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: line.isTotal ? (card.real ? "Real gain" : "Total gain") : card.topLabel
                    color: Theme.textMuted
                    font.family: card.fontFamily
                    font.pixelSize: card.bodySize
                }
                Text {
                    id: moneyText
                    x: figures.labelW + card.figGap
                    width: card.moneyW
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: card._ready ? F.signedMoney(line.money) : "—"
                    color: card._ready ? line.tone : Theme.textFaint
                    font.family: card.fontFamily
                    font.pixelSize: card.figureSize
                    font.bold: true
                    // The day's figures do not flip; the total's do.
                    GainFlash {
                        objectName: line.isTotal ? "summaryGainFlash" : ""
                        target: moneyText
                        strength: line.isTotal && card._ready ? card.flash : 0
                        peak: card.flashPeak
                        hPad: card.flashPad
                    }
                }
                Text {
                    id: pctText
                    x: figures.labelW + card.figGap + card.moneyW + card.figGap
                    width: card.pctW
                    height: parent.height
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: card._ready ? F.pct(line.pct) : ""
                    color: line.tone
                    font.family: card.fontFamily
                    font.pixelSize: card.figureSize
                    font.bold: true
                    GainFlash {
                        target: pctText
                        strength: line.isTotal && card._ready ? card.flash : 0
                        peak: card.flashPeak
                        hPad: card.flashPad
                    }
                }
            }
        }

        // The total gain line: the real flip and the breakdown tip, one hover.
        MouseArea {
            id: gainHover
            objectName: "summaryGainHover"
            x: 0
            y: card._lineH + 4
            width: figures.width
            height: card._lineH
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
            onContainsMouseChanged: {
                if (card.service)
                    card.service.realHover("summary-total", gainHover.containsMouse);
            }
        }
        HoverTip {
            anchorItem: gainHover
            overlayItem: card.overlayItem
            show: gainHover.containsMouse && card._ready
            side: "below"
            fontFamily: card.fontFamily
            contentPadding: 8
            // Two columns: the words, and the figures right-aligned in theirs.
            contentComponent: Component {
                Row {
                    spacing: 14
                    Column {
                        spacing: 2
                        Repeater {
                            model: card.breakdown.length
                            delegate: Text {
                                required property int index
                                text: card.breakdown[index].label
                                color: Theme.textMuted
                                font.family: card.fontFamily
                                font.pixelSize: card.figureSize
                            }
                        }
                    }
                    Column {
                        id: valueCol
                        spacing: 2
                        Repeater {
                            model: card.breakdown.length
                            delegate: Text {
                                required property int index
                                anchors.right: valueCol.right
                                text: card.breakdown[index].value
                                color: Theme.textPrimary
                                font.family: card.fontFamily
                                font.pixelSize: card.figureSize
                                font.bold: true
                            }
                        }
                    }
                }
            }
        }
    }

    // The total gain, taken apart: facts only ({ label, value } strings).
    readonly property var breakdown: card._breakdown()
    function _breakdown() {
        const p = card._p;
        if (!p)
            return [];
        const r = card.real;
        return [
            { label: "Unrealised", value: F.signedMoney(card._num(r ? p.unrealisedReal : p.unrealised)) },
            { label: "Realised", value: F.signedMoney(card._num(r ? p.realisedReal : p.realised)) },
            { label: "Dividends, net", value: F.signedMoney(card._num(r ? p.dividendsReal : p.dividends)) },
            { label: "Fees (included above)", value: F.money(card._num(p.fees)) },
            { label: r ? "Bought, in today's euros" : "Bought", value: F.money(card._num(r ? p.boughtReal : p.bought)) }
        ];
    }

    // ---- the chart ------------------------------------------------------------------------
    // What the chart is to show: the range's series, or the skeleton while a
    // range loads (5D's own fetch).
    readonly property var _skel: SS.skeletonSpec({ id: "value" })
    readonly property var _live: {
        if (card._chartLoading)
            return card._skel;
        const s = card.service ? card.service.summarySeries : null;
        if (!s || !s.t || s.t.length === 0)
            return null;
        // The plot's width from the chart's own box (not its px0: that follows
        // the axis labels, which follow this spec) less a nominal label column.
        return SS.summarySpec(s, { range: card.service.summaryRange,
                                   plotPx: Math.max(120, chart.width - 2 * chart.padding - 48) });
    }
    // What it SHOWS: every change is a morph (a range, a refresh, 5D's data
    // landing), the first picture a jump. Ranges differ in slot count (1D
    // intraday, weekly ALL): the chart morphs them by place (morphResample).
    property var _spec: null
    on_LiveChanged: card._present()
    Component.onCompleted: {
        card._present();
        card._takeNote();
    }
    function _present() {
        const next = card._live;
        if (next === card._spec)
            return;
        if (next && !next.skeleton) {
            card._invWas = next.investedShown === true;
            const r = card.service.summaryRange;
            const mv = r === "1D" || r === "ALL" ? null : SS.rangeMove(card.service.summarySeries);
            card._move = mv ? { range: r, change: mv.change, pct: mv.pct } : null;
        }
        if (card._spec === null)
            chart.jump(() => {
                card._spec = next;
            });
        else
            chart.morph(() => {
                card._spec = next;
            });
    }
    readonly property bool _chartLoading: !!card.service && card.service.summaryLoading === true
    // The skeleton keeps the title the last real range had.
    property bool _invWas: true
    readonly property bool _investedShown: !!card._spec && (card._spec.skeleton ? card._invWas
                                                                                : card._spec.investedShown === true)
    readonly property string range: card.service ? (card.service.summaryRange || "1M") : "1M"
    function _seriesOf(id) {
        const list = card._spec ? card._spec.series : [];
        for (let k = 0; k < list.length; k++)
            if (list[k].id === id)
                return list[k];
        return null;
    }
    // The hovered point: its time, value and invested -- null over a slot
    // with no value (the rest of an intraday session), as the detail's.
    readonly property var scrub: {
        const sp = card._spec;
        const i = chart.hoverIndex;
        if (!sp || sp.skeleton || i < 0)
            return null;
        const val = card._seriesOf("value");
        const inv = card._seriesOf("invested");
        const v = val && val.values ? val.values[i] : null;
        if (typeof v !== "number" || !isFinite(v))
            return null;
        const w = inv && inv.values ? inv.values[i] : null;
        return {
            t: sp.t ? sp.t[i] : null,
            v: v,
            inv: typeof w === "number" && isFinite(w) ? w : null
        };
    }
    readonly property bool scrubbing: !!card.scrub
    function _dateFormat(r) {
        return r === "1D" ? "hh:mm" : r === "5D" ? "ddd hh:mm" : "d MMM yyyy";
    }

    // The readout's slots. The date slot is the widest the range's format can
    // print (every weekday, every month, digits at their widest), so nothing
    // moves while the pointer scrubs; a range change is a new layout anyway.
    // The money slots are the template of the largest magnitude the
    // portfolio has. The chips beside it make room for the WIDEST range's
    // readout, so they never move on a range change.
    FontMetrics {
        id: readM
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
    }
    FontMetrics {
        id: readBoldM
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
        font.bold: true
    }
    // { "1D": w, "5D": w, other: w } at the current font.
    readonly property var _dateSlots: {
        void readM.font;
        const widest = (fmt, dates) => dates.reduce((w, d) => Math.max(w, Math.ceil(readM.advanceWidth(Qt.formatDateTime(d, fmt).replace(/\d/g, "8")))), 0);
        const months = [], days = [];
        for (let k = 0; k < 12; k++)
            months.push(new Date(2026, k, 28, 18, 58));
        for (let k = 0; k < 7; k++)
            days.push(new Date(2026, 0, 5 + k, 18, 58));
        return {
            "1D": widest("hh:mm", days.slice(0, 1)),
            "5D": widest("ddd hh:mm", days),
            other: widest("d MMM yyyy", months)
        };
    }
    readonly property real _dateW: card._dateSlots[card.range] || card._dateSlots.other
    readonly property real _dateWMax: Math.max(card._dateSlots["1D"], card._dateSlots["5D"], card._dateSlots.other)
    readonly property real _readMoneyW: {
        void readBoldM.font;
        const p = card._p;
        const m = Math.max(88888.88, p ? Math.abs(card._num(p.value)) : 0, p ? Math.abs(card._num(p.bought)) : 0);
        return Math.ceil(readBoldM.advanceWidth(F.moneyTemplate(m)));
    }
    readonly property real _sepW: {
        void readM.font;
        return Math.ceil(readM.advanceWidth(" · "));
    }
    readonly property real _readoutW: card._dateW + 2 * card._sepW + 2 * card._readMoneyW
    readonly property real _readoutWMax: card._dateWMax + 2 * card._sepW + 2 * card._readMoneyW

    Text {
        id: chartTitle
        objectName: "summaryChartTitle"
        visible: !card.scrubbing
        x: card.cardPadding
        y: card.cardPadding + card._headH + card.cardPadding
        height: card._lineH
        verticalAlignment: Text.AlignVCenter
        // The invested line is left out where it would flatten the value
        // (StockSeries' rule), and the title says what is drawn.
        text: card._investedShown || !card._spec ? "Value vs invested" : "Value"
        color: Theme.textMuted
        font.family: card.fontFamily
        font.pixelSize: card.figureSize
    }
    // The readout, in the title's place while the chart is scrubbed.
    Item {
        id: readout
        objectName: "summaryReadout"
        visible: card.scrubbing
        x: card.cardPadding
        y: chartTitle.y
        width: card._readoutW
        height: card._lineH
        Text {
            id: readDate
            objectName: "summaryReadDate"
            x: 0
            width: card._dateW
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            text: card.scrub && card.scrub.t ? Qt.formatDateTime(new Date(card.scrub.t), card._dateFormat(card.range)) : ""
            color: Theme.textMuted
            font.family: card.fontFamily
            font.pixelSize: card.figureSize
        }
        Text {
            x: card._dateW
            width: card._sepW
            height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "·"
            color: Theme.textFaint
            font.family: card.fontFamily
            font.pixelSize: card.figureSize
        }
        Text {
            objectName: "summaryReadValue"
            x: card._dateW + card._sepW
            width: card._readMoneyW
            height: parent.height
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: card.scrub ? F.money(card.scrub.v) : ""
            color: card._role(card._spec ? card._spec.role : "gain")
            font.family: card.fontFamily
            font.pixelSize: card.figureSize
            font.bold: true
        }
        // The invested figure (and its separator) only where the chart draws
        // the invested line; the chips keep their place either way.
        Text {
            visible: card._investedShown
            x: card._dateW + card._sepW + card._readMoneyW
            width: card._sepW
            height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "·"
            color: Theme.textFaint
            font.family: card.fontFamily
            font.pixelSize: card.figureSize
        }
        Text {
            objectName: "summaryReadInvested"
            visible: card._investedShown
            x: card._dateW + 2 * card._sepW + card._readMoneyW
            width: card._readMoneyW
            height: parent.height
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: card.scrub && card.scrub.inv !== null ? F.money(card.scrub.inv) : ""
            color: Theme.textMuted
            font.family: card.fontFamily
            font.pixelSize: card.figureSize
            font.bold: true
        }
    }
    StockRangeChips {
        id: chips
        objectName: "summaryRangeChips"
        x: card.width - card.cardPadding - width
        y: chartTitle.y
        width: implicitWidth
        height: card._lineH
        // Room left beside the readout; the chips' air gives way first.
        maxWidth: card.width - 2 * card.cardPadding - card._readoutWMax - 8
        chipPad: 10
        // The band below reads the wheel for them.
        wheelEnabled: false
        ranges: ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "ALL"]
        current: card.range
        fontFamily: card.fontFamily
        pixelSize: card.figureSize
        onPicked: r => {
            if (card.service)
                card.service.summaryRange = r;
        }
    }

    TimelineChart {
        id: chart
        objectName: "summaryChart"
        x: card.cardPadding - 6
        y: chartTitle.y + chartTitle.height + 4
        width: card.width - 2 * card.cardPadding + 12
        height: card.chartHeight
        boxed: false
        padding: 6
        fontFamily: card.fontFamily
        figureSize: card.figureSize - 1
        surfaceColor: Theme.listBox
        fillColor: Theme.listBox
        series: card._spec ? card._resolve(card._spec.series) : []
        thresholds: card._spec ? card._resolve(card._spec.thresholds) : []
        gradientStops: card._spec ? card._resolve(card._spec.gradientStops) : []
        xTicks: card._spec && card._spec.xTicks ? card._spec.xTicks : []
        skeleton: !!card._spec && card._spec.skeleton === true
        morphResample: true
        barsAsPath: true
        // A gain turning into a loss passes through the faint grey, not brown.
        morphColorVia: Theme.textFaint
        yMinSpan: card._spec && card._spec.yMinSpan ? card._spec.yMinSpan : 0
        yFormat: v => card._axisMoney(v)
        // Three ticks in 96 px (five sit 16 px apart and read as a ladder).
        // `yTicks` is a target SPAN count that the axis pads to nice steps:
        // two spans of 1 / 2.5 / 5 give three ticks for the usual shapes, four
        // at worst when the data straddles a step.
        yTicks: 2
        yNiceSteps: [1, 2.5, 5]
        // The hairline and the dots follow the pointer -- through a range
        // change under a still pointer too -- on slots with a value.
        markerFollowsPointer: true
        // Every range edge to edge: the 24-point month and the 54-week year
        // stopped half a slot (9.5 / 4.2 px) short of each side.
        spanEnds: true
        markerIndex: card.scrubbing ? chart.hoverIndex : -1
        emptyText: card.service && card.service.loading ? "" : "No history yet"
        areaFade: 1
    }

    // The range's swipe band: the chips and the chart, one area. Sideways goes
    // to the chips, anything else is passed on (and the chart's own hover,
    // under it, is untouched: this reads no hover).
    WheelArea {
        id: rangeSwipe
        objectName: "summaryRangeSwipe"
        x: 0
        y: chips.y
        width: card.width
        height: chart.y + chart.height - chips.y
        turned: ev => ev.accepted = chips.wheel(ev)
    }

    // ---- the indices ----------------------------------------------------------------------
    StocksIndexStrip {
        id: strip
        x: card.cardPadding
        y: chart.y + chart.height + card.cardPadding
        width: card.width - 2 * card.cardPadding
        height: card.stripHeight
        service: card.service
        popup: card.popup
        fontFamily: card.fontFamily
        figureSize: card.figureSize
        cycleMs: card.cycleMs
        rollMs: card.rollMs
        staggerMs: card.staggerMs
        hoverDwellMs: card.hoverDwellMs
        releaseGraceMs: card.releaseGraceMs
    }

    function stripCell(sym) {
        return strip.cellFor(sym);
    }
}
