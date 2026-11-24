pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/StocksFormat.js" as F
import "data/StockSeries.js" as SS
import "../common/scroll"

// =============================================================================
// StockDetail.qml -- one stock, in the engine's secondary popup.
//
//   header card   56 px engraved logo (the link to Yahoo's quote page), name,
//                 exchange / currency / market state, the price in the stock's
//                 OWN currency and the day's change, the watchlist star; while
//                 the chart is scrubbed the price slot reads the scrubbed point
//                 and the chart draws the hairline and its dot there
//                 range chips 1D 5D 1M 6M YTD 1Y 5Y MAX (a sideways swipe over
//                 them steps the range: StockRangeChips), and the chart: trade
//                 markers, the dashed average-cost line, 1D's prev-close
//                 baseline, faint volume (StockSeries.detailSpec)
//   stats card    twelve figures and the 52-week groove; missing is "—"
//   position      (held or closed only) the position and every transaction
//
// CONTRACT (bar_structure.md, the secondary): the engine assigns
// `secondaryKey` = { symbol, from } and keeps `secondaryCutout` (the part the primary covers) up to
// date. THE NEXT STOCK IS SWAPPED IN PLACE (`secondarySwapsInPlace`; a blank flash would hide the smooth morph): the engine leaves this content in view and `curtain` takes what it says out and back,
// the facts changing at the bottom, while the chart, its card and the range chips stay and the chart morphs. Sized through
// implicitWidth / implicitHeight only. The detail is a STATIC size per kind of stock, so a long holding scrolls inside its own container and not the
// entire secondary content: the position card's transaction list has a viewport of three rows and a peek, whatever
// the stock holds, and scrolls inside it (title and summary lines stay put, newest transaction first); nothing else
// as the last resort.
//
// THE CUTOUT, ON ANY SIDE. An inset secondary lies under its primary along
// the face it hangs from: a band across the top when it hangs below (far on a
// top bar), down one side when it hangs beside (start / end). The band is
// read from the cutout itself -- the edge it touches, and whether it runs
// across (wider than tall) or down -- so this knows nothing of the host's bar
// or side. Nothing is laid out under it: the body starts one padding past
// the band, and the band is ADDED to the implicit size, so the part the
// primary does not cover is the detail at its own size.
//
// THE WHEEL HAS ONE READER (CLAUDE.md: two readers of one wheel event). The
// body's ScrollDressing keeps its fade bands and its notch but reads no wheel;
// a MouseArea over the body reads every event. It is offered to the range
// chips first when it lands on the chips OR THE CHART -- one band from the
// chips' top to the chart's foot (the graph is where the fingers
// are) -- or while they hold a sideways gesture:
// they take a sideways gesture whole, drift and all. Anything else latches its
// axis until the fingers lift (the zero-delta event) or `gestureIdleEndMs`:
// vertical scrolls the body (or, when the fingers began over a transaction list that has more to show,
// that list) a notch per 120 units, sideways is nobody's.
//
// The service is told what is on screen (`watchDetail(sym, range)`) so it can
// fetch the chart and the stats and refresh 1D / 5D every minute; the last
// range used is the service's (`detailRange`), so the next detail opens on it.
// =============================================================================
Item {
    id: root

    property var service: null
    property string fontFamily: "Inter"
    property real detailWidth: 504
    property real maxHeight: 960
    property real chartHeight: 180
    property real logoSize: 56
    property real padding: 12
    property real cardPadding: 12
    property real radius: 14
    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1
    property real flashPeak: 0.22
    property real flashPad: 3
    property int gestureIdleEndMs: 260
    property real axisLead: 1.2

    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
    // What the chart SHOWS: a ready chart, the skeleton while one loads, an
    // error's empty plot. Every change of it is a MORPH -- another range,
    // another stock (while the detail slides), the data landing, a refresh --
    // except the first picture, a jump. Ranges have different slot counts
    // (1D ~100, 1Y ~250, MAX ~340): the chart morphs them by place, not by
    // index (morphResample), and draws its bars as one path so a change of
    // count builds no delegates (barsAsPath) -- together what lets the morph
    // run inside the slide.
    //
    // ONE CLICK, ONE MORPH: the cached picture followed by a second morph to the fresh data would be two morphs for one click, and a small delay on
    // change is cheaper than the second. A chip's range with a fresher answer on its way keeps the picture on screen for that answer, for
    // `freshHoldMs` at most, and then shows what there is. Only within a stock: under another stock's name the old picture would be a false one.
    readonly property var _skel: SS.skeletonSpec({ id: "price" })
    // What the picture shows, one object written once: the spec reads the holding and the range too, and read live they
    // redraw the OLD chart with the NEW stock's marks before the morph has begun.
    property var _view: null
    readonly property var _shown: root._view ? root._view.chart : null
    readonly property string _shownSymbol: root._view ? root._view.symbol : ""
    property int freshHoldMs: 700
    property string _holdKey: ""
    property bool _holdOut: false
    Timer {
        id: freshHold
        interval: root.freshHoldMs
        onTriggered: {
            root._holdOut = true;
            root._present();
        }
    }
    function _present() {
        const c = root.chart, s = root.service, key = root.symbol + "|" + root.range;
        if (key !== root._holdKey) {
            root._holdKey = key;
            root._holdOut = false;
            freshHold.stop();
        }
        if (root._shown !== null && root._shownSymbol === root.symbol && !root._holdOut && s && s.chartPending(root.symbol, root.range)) {
            if (!freshHold.running)
                freshHold.start();
            return;
        }
        freshHold.stop();
        const next = c && (c.state === "ready" || c.state === "error") ? c : root._skel;
        const v = root._view, view = { chart: next, symbol: root.symbol, holding: root.position, range: root.range };
        if (v && next === v.chart) {
            if (view.symbol !== v.symbol || view.holding !== v.holding || view.range !== v.range)
                root._view = view;
            return;
        }
        if (v === null)
            chartView.jump(() => {
                root._view = view;
            });
        else
            chartView.morph(() => {
                root._view = view;
            });
    }
    // (a turn later: the range and the fetch it starts are read in the same change)
    onChartChanged: Qt.callLater(root._present)
    onPositionChanged: Qt.callLater(root._present)

    // What this content shows; `secondaryKey` is what it was last asked for.
    property var _key: null
    function secondarySwapsInPlace(key) {
        return true;
    }
    onSecondaryKeyChanged: {
        const k = root.secondaryKey;
        if (!root._key || !k || k.symbol === root._key.symbol)
            root._key = k;
        else
            curtain.swap(() => root._key = root.secondaryKey);
    }
    SwapCurtain {
        id: curtain
    }
    readonly property string symbol: root._key ? (root._key.symbol || "") : ""
    readonly property string range: root.service && root.service.detailRange ? root.service.detailRange : "1D"

    // The part the primary covers is not ours to draw in: a band on the edge
    // the cutout touches (see the header). A cutout that is not a band on an
    // edge (none, or one caught mid-open at a degenerate size) reserves nothing.
    readonly property var _band: {
        const r = root.secondaryCutout;
        const b = { top: 0, bottom: 0, left: 0, right: 0 };
        if (!(r.width > 0) || !(r.height > 0))
            return b;
        // A band that does not start at an edge ends at the opposite one. Not
        // measured against this item's own size: that size is made of the
        // band (a loop through the engine).
        const across = r.width >= r.height;
        if (across && r.y <= 0.5)
            b.top = r.y + r.height;
        else if (across)
            b.bottom = r.height;
        else if (r.x <= 0.5)
            b.left = r.x + r.width;
        else
            b.right = r.width;
        return b;
    }
    readonly property real _top: Math.ceil(root._band.top)
    readonly property real _bottom: Math.ceil(root._band.bottom)
    readonly property real _left: Math.ceil(root._band.left)
    readonly property real _right: Math.ceil(root._band.right)

    implicitWidth: root._left + root.detailWidth + root._right
    implicitHeight: root._top + root._bottom + root.naturalHeight
    // The detail's own height: its content, capped -- WITHOUT the band the
    // primary covers. The popup decides the overhang from this, and the band
    // is written by the engine in reaction to that overhang; reading the live
    // height there closed a loop through the engine (a "binding loop" on the
    // popup's _detailLonger). Nothing the engine writes reaches this value.
    readonly property real naturalHeight: Math.round(Math.min(root.maxHeight,
                                                              root.padding + column.implicitHeight + root.padding))

    // ---- the facts (serials first: a new arrival re-reads) ----------------------------
    readonly property var chart: {
        const s = root.service;
        if (!s || !root.symbol)
            return null;
        void s.chartSerial;
        return s.chart(root.symbol, root.range);
    }
    readonly property var stats: {
        const s = root.service;
        if (!s || !root.symbol)
            return null;
        void s.statsSerial;
        return s.stats(root.symbol);
    }
    readonly property var position: {
        const s = root.service;
        if (!s || !root.symbol)
            return null;
        void s.portfolio;
        return s.position(root.symbol);
    }
    // Yahoo's decimals for this quote (2; 4 for a stock near a euro).
    readonly property int priceHint: root.quote && typeof root.quote.priceHint === "number" ? root.quote.priceHint : 2
    // The quote: the service's live one, else the chart's own meta.
    readonly property var quote: {
        const s = root.service;
        const q = s && s.quotes && root.symbol ? s.quotes[root.symbol] : null;
        if (q)
            return q;
        return root.chart && root.chart.meta ? root.chart.meta : null;
    }

    // ---- telling the service what is on screen ----------------------------------------
    function _watch() {
        if (root.service && root.symbol)
            root.service.watchDetail(root.symbol, root.range);
    }
    onSymbolChanged: root._watch()
    onRangeChanged: root._watch()
    Component.onCompleted: {
        root._watch();
        root._present();
    }
    Component.onDestruction: {
        if (root.service)
            root.service.unwatchDetail();
    }

    // ---- the chart spec, colours resolved here ------------------------------------------
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
            color: root._role(s.role || s.color)
        }));
    }
    readonly property var spec: {
        const v = root._view, c = v ? v.chart : null;
        if (c === root._skel)
            return root._skel;
        if (!c || c.state !== "ready" || !c.t || c.t.length === 0)
            return null;
        return SS.detailSpec(c, v.holding, {
            range: v.range,
            plotPx: Math.max(120, chartView.width - 2 * chartView.padding - 48)
        });
    }

    // The picture's own move for the header: its last close against the range's
    // first point (the chart's spec), with the stock and range the picture is
    // of -- a header whose stock has moved on ignores it. And the largest move
    // the picture holds, which sizes the header's slots before anything is hovered.
    readonly property var headFig: {
        const sp = root.spec, v = root._view;
        if (!sp || sp.skeleton || !v || !isFinite(sp.change) || !isFinite(sp.changePct))
            return null;
        return { symbol: v.symbol, range: v.range, change: sp.change, pct: sp.changePct };
    }
    readonly property var headBound: {
        const sp = root.spec;
        if (!sp || sp.skeleton || !isFinite(sp.first) || sp.first === 0)
            return null;
        let m = 0;
        for (const v of sp.readout || [])
            if (typeof v === "number" && isFinite(v))
                m = Math.max(m, Math.abs(v - sp.first));
        return { abs: m, pct: 100 * m / Math.abs(sp.first) };
    }

    // The hovered slot of the price line: its close, its time, and what the
    // range's move is measured from (1D: the previous close).
    readonly property var scrub: {
        const sp = root.spec;
        const i = chartView.hoverIndex;
        if (!sp || sp.skeleton || i < 0)
            return null;
        // A real close only. Over a stretch the line merely joins (dashed)
        // it is the nearest real close on either side; past the day's first
        // or last print there is none (the hairline goes).
        const r = sp.readout || [];
        const ok = k => k >= 0 && k < r.length && typeof r[k] === "number" && isFinite(r[k]);
        let j = i;
        if (!ok(i)) {
            let a = i - 1, b = i + 1;
            while (a >= 0 && !ok(a))
                a--;
            while (b < r.length && !ok(b))
                b++;
            if (a < 0 || b >= r.length)
                return null;
            j = i - a <= b - i ? a : b;
        }
        return {
            v: r[j],
            t: sp.t ? sp.t[j] : null,
            base: sp.first
        };
    }

    // ---- the body -----------------------------------------------------------------------
    // THE VIEWPORT IS THE PADDED BOX, not the popup: it stops one padding
    // short of every edge, so a card scrolled to the foot ends 12 px above the
    // popup's rounded foot instead of running flat into its corners, and the
    // fade bands (the surface colour) stay well inside the corner curves
    // (CLAUDE.md: content that scrolls to a rounded foot; a fade band over a
    // clip rectangle pokes out of a rounded host). The clip keeps `_slack`
    // outside the cards on every side: a carved box draws its bevel outside
    // its rect, and a clip on that line would shear it.
    readonly property real _slack: 2
    Flickable {
        id: detailFlick
        objectName: "stockDetailFlick"
        x: root._left + root.padding - root._slack
        y: root._top + root.padding - root._slack
        width: root.detailWidth - 2 * (root.padding - root._slack)
        height: Math.max(0, root.height - root._top - root._bottom - 2 * (root.padding - root._slack))
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: column.implicitHeight + 2 * root._slack

        Column {
            id: column
            x: root._slack
            y: root._slack
            width: root.detailWidth - 2 * root.padding
            spacing: root.padding

            // Header + chips + chart, one carved card.
            Item {
                id: headCard
                width: column.width
                height: Math.round(root.cardPadding + header.implicitHeight + root.cardPadding
                                   + chipsRow.height + 6 + root.chartHeight + root.cardPadding)

                ShadowBox {
                    anchors.fill: parent
                    baseRadius: root.radius
                    surfaceColor: Theme.surface
                    bevelColor: Theme.bevel
                    shadowColor: Theme.border
                    backgroundColor: Theme.listBox
                    bevelWidth: root.cardBevelWidth
                    shadowWidth: root.cardShadowWidth
                    shadowFalloff: root.cardShadowFalloff
                }

                StockDetailHeader {
                    id: header
                    objectName: "stockDetailHeader"
                    opacity: curtain.shown
                    x: root.cardPadding
                    y: root.cardPadding
                    width: headCard.width - 2 * root.cardPadding
                    height: implicitHeight
                    service: root.service
                    symbol: root.symbol
                    quote: root.quote
                    fontFamily: root.fontFamily
                    logoSize: root.logoSize
                    titleSize: root.titleSize
                    bodySize: root.bodySize
                    figureSize: root.figureSize
                    scrub: root.scrub
                    range: root.range
                    fig: root.headFig
                    bound: root.headBound
                    ext: root.service && root.service.extended && root.symbol ? root.service.extended[root.symbol] || null : null
                }

                StockRangeChips {
                    id: chipsRow
                    objectName: "detailRangeChips"
                    x: root.cardPadding
                    y: header.y + header.height + root.cardPadding
                    width: implicitWidth
                    height: Math.ceil(root.figureSize * 1.6)
                    maxWidth: headCard.width - 2 * root.cardPadding
                    chipPad: 12
                    // The body's reader offers it every event (below).
                    wheelEnabled: false
                    ranges: ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "MAX"]
                    current: root.range
                    fontFamily: root.fontFamily
                    pixelSize: root.figureSize
                    onPicked: r => {
                        if (root.service)
                            root.service.detailRange = r;
                    }
                }

                TimelineChart {
                    id: chartView
                    objectName: "stockDetailChart"
                    x: root.cardPadding - 6
                    y: chipsRow.y + chipsRow.height + 6
                    width: headCard.width - 2 * root.cardPadding + 12
                    height: root.chartHeight
                    boxed: false
                    padding: 6
                    fontFamily: root.fontFamily
                    figureSize: root.figureSize - 1
                    surfaceColor: Theme.listBox
                    fillColor: Theme.listBox
                    series: root.spec ? root._resolve(root.spec.series) : []
                    thresholds: root.spec ? root._resolve(root.spec.thresholds) : []
                    gradientStops: root.spec ? root._resolve(root.spec.gradientStops) : []
                    xTicks: root.spec && root.spec.xTicks ? root.spec.xTicks : []
                    yMinSpan: root.spec && root.spec.yMinSpan ? root.spec.yMinSpan : 0
                    yFormat: v => F.price(v, "", root.priceHint)
                    areaFade: 1
                    // The hairline and its dots follow the pointer -- through a
                    // range change under a still pointer too -- wherever the
                    // readout has a price (`scrub`).
                    markerFollowsPointer: true
                    // Every range edge to edge (a short one stopped half a
                    // slot short of each side).
                    spanEnds: true
                    markerIndex: root.scrub ? chartView.hoverIndex : -1
                    // Loading is the skeleton; an empty plot is an error's.
                    emptyText: root._shown && root._shown.state === "error" ? (root._shown.error || "No chart") : ""
                    skeleton: root._shown === root._skel
                    morphResample: true
                    barsAsPath: true
                    // A gain turning into a loss passes through the faint grey, not brown.
                    morphColorVia: Theme.textFaint
                }
                // A trade marker explains itself: the hovered slot's mark, if any.
                readonly property var _mark: {
                    const m = root.spec && root.spec.marks ? root.spec.marks : [];
                    const i = chartView.hoverIndex;
                    if (i < 0)
                        return null;
                    for (let k = 0; k < m.length; k++)
                        if (m[k] && m[k].i === i)
                            return m[k];
                    return null;
                }
                Item {
                    id: markAnchor
                    x: chartView.x + (chartView.hoverIndex >= 0 ? chartView.xFor(chartView.hoverIndex) : 0) - 4
                    y: chartView.y + (isFinite(chartView.hoverY) ? chartView.hoverY : 0) - 4
                    width: 8
                    height: 8
                }
                HoverTip {
                    anchorItem: markAnchor
                    overlayItem: overlay
                    show: !!headCard._mark
                    delayMs: 0
                    fontFamily: root.fontFamily
                    text: headCard._mark ? (headCard._mark.text || headCard._mark.comment || "") : ""
                }
            }

            StockStatsGrid {
                id: statsGrid
                opacity: curtain.shown
                width: column.width
                height: implicitHeight
                stats: root.stats
                quote: root.quote
                priceHint: root.priceHint
                fontFamily: root.fontFamily
                cardPadding: root.cardPadding
                radius: root.radius
                bodySize: root.bodySize
                figureSize: root.figureSize
                bevelWidth: root.cardBevelWidth
                shadowWidth: root.cardShadowWidth
                shadowFalloff: root.cardShadowFalloff
            }

            StockPosition {
                id: positionCard
                opacity: curtain.shown
                visible: !!root.position
                width: column.width
                height: root.position ? implicitHeight : 0
                holding: root.position
                priceHint: root.priceHint
                service: root.service
                fontFamily: root.fontFamily
                cardPadding: root.cardPadding
                radius: root.radius
                bodySize: root.bodySize
                figureSize: root.figureSize
                bevelWidth: root.cardBevelWidth
                shadowWidth: root.cardShadowWidth
                shadowFalloff: root.cardShadowFalloff
                flashPeak: root.flashPeak
                flashPad: root.flashPad
            }
        }
    }
    ScrollDressing {
        id: dressing
        anchors.fill: detailFlick
        flick: detailFlick
        ground: Theme.surface
        fadeHeight: 18
        wheelEnabled: false
    }

    // ---- the one wheel reader (see the header) ------------------------------------------
    property string _axis: ""
    // Whose a vertical read is, latched with its axis: "trades" (the position's transaction list, when the
    // fingers began over it and it has more to show) or "body".
    property string _owner: ""
    Timer {
        id: wheelIdle
        interval: root.gestureIdleEndMs
        onTriggered: {
            root._axis = "";
            root._owner = "";
        }
    }
    // The range's swipe band: the header card's width, from the chips' top to
    // the chart's foot.
    function _overTrades(x, y) {
        if (!positionCard.visible || !positionCard.tradesScrollable)
            return false;
        const p = wheelReader.mapToItem(positionCard.tradesViewport, x, y);
        return p.x >= 0 && p.x <= positionCard.tradesViewport.width && p.y >= 0 && p.y <= positionCard.tradesViewport.height;
    }
    function _overRange(x, y) {
        const p = wheelReader.mapToItem(headCard, x, y);
        return p.x >= 0 && p.x <= headCard.width && p.y >= chipsRow.y && p.y <= chartView.y + chartView.height;
    }
    function _wheel(ev) {
        const x = ev.x, y = ev.y, ad = ev.angleDelta, pd = ev.pixelDelta, phase = ev.phase;
        const dx = ad.x !== 0 ? ad.x : pd.x * 2.5;
        const dy = ad.y !== 0 ? ad.y : pd.y * 2.5;
        if (dx === 0 && dy === 0) {
            chipsRow.wheel(ev);
            // The lift (a coast, when the fingers were moving) or fingers put
            // back (a catch) reaches the body's engine: it is the body's
            // whenever a vertical read was latched, and a catch is harmless
            // on an idle engine.
            const zero = { pixelDelta: Qt.point(0, 0), angleDelta: Qt.point(0, 0), phase: phase };
            if (root._axis === "y") {
                (root._owner === "trades" ? positionCard.tradesScroller : dressing).wheel(zero);
            } else if (phase === Qt.ScrollBegin) {
                // Fingers put back with no read latched: whichever engine is coasting is the one that stops.
                dressing.wheel(zero);
                positionCard.tradesScroller.wheel(zero);
            }
            wheelIdle.stop();
            root._axis = "";
            root._owner = "";
            return false;
        }
        if ((chipsRow.gestureActive || root._overRange(x, y)) && chipsRow.wheel(ev))
            return true;
        wheelIdle.restart();
        if (root._axis === "") {
            if (Math.abs(dy) > Math.abs(dx) * root.axisLead) {
                root._axis = "y";
                root._owner = root._overTrades(x, y) ? "trades" : "body";
            } else if (Math.abs(dx) > Math.abs(dy) * root.axisLead)
                root._axis = "x";
        }
        // Sideways (or not decided yet) is nobody's here: passed on, and
        // its drift scrolls nothing.
        if (root._axis !== "y")
            return false;
        // The body's engine (a notch glides, fingers follow, their lift coasts); it
        // also tells the host (`wheeled`). Only the y component: a vertical read's
        // drift scrolls nothing sideways.
        (root._owner === "trades" ? positionCard.tradesScroller : dressing)
            .wheel({ pixelDelta: Qt.point(0, pd.y), angleDelta: Qt.point(0, ad.y), phase: phase });
        return true;
    }
    WheelArea {
        id: wheelReader
        objectName: "stockDetailWheel"
        anchors.fill: detailFlick
        turned: ev => ev.accepted = root._wheel(ev)
    }

    Item {
        id: overlay
        anchors.fill: parent
        z: 10
    }
}
