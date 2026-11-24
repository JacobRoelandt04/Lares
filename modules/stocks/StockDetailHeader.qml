pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/StocksFormat.js" as F
import "data/Markets.js" as Markets

// =============================================================================
// StockDetailHeader.qml -- who the stock is and what it costs.
//
//   [56 px logo]  ASML Holding N.V.                        1,497.40 EUR  ☆
//                 Amsterdam · EUR · open               +12.40  +0.84%
//
// The engraved logo IS the link to finance.yahoo.com/quote/SYM (the
// icon is the link; the pointer is the only thing that announces it). The
// price is in the stock's OWN currency (pence for London). The star adds or
// removes it from the watchlist.
//
// EXTENDED HOURS. A listing outside its regular session with a pre- or
// post-market move (`ext`, the service's `extended`) has a third line under
// the change, in the same slots: "Pre-market 329.92" / "After hours ..." and
// its % against the last close. The header keeps the logo's height; without
// the line the two lines centre in it (a blank slot centres what remains),
// and the line's presence moves them (one fraction, 160 ms).
//
// THE RANGE'S MOVE. On any range but 1D the change line is the picture's own
// move (`fig`: last close against the range's first point, from the chart's
// spec) with the range's name before it -- "1M  +62.10  +4.36%". 1D keeps
// today's change as the quote has it, unlabelled. A `fig` that belongs to
// another stock is not ours (the old picture stays up while a swap runs).
//
// SCRUB. While the chart is hovered (`scrubIndex` >= 0) the price slot reads
// the hovered point's close and the change line its date and its move from
// the range's first point. The date takes the place of the range's name and
// the amount: ONE slot, as wide as the widest date THIS range prints (1D a
// time and the exchange's offset, 5D / 1M a weekday and a time, the rest a day;
// every weekday and month, digits as 8s), sized before anything is hovered, so it can never reach the
// facts line and nothing moves while hovering; a range switch may.
//
// THE TEXTS' ROOM (the user, 2026-11-23: the title and the facts were cut with
// room to spare). The name shares its line with the PRICE alone and ends at the
// price's slot; the facts line ends at the change line's block. Each yields to
// what is on its own line, never to the widest thing of the other.
// =============================================================================
Item {
    id: head

    property var service: null
    property string symbol: ""
    property var quote: null
    property var scrub: null                  // { v, t, base } while the chart is hovered
    property var ext: null                    // { kind: "pre" | "post", price, changePct } or null
    property string range: "1D"
    // { symbol, range, change, pct } of the picture on screen, or null
    property var fig: null
    // The largest move the picture holds, { abs, pct }: the slots are sized for it
    property var bound: null
    property string fontFamily: "Inter"
    property real logoSize: 56
    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11

    readonly property var q: head.quote
    function _num(v) {
        return typeof v === "number" && isFinite(v);
    }
    readonly property string currency: head.q ? (head.q.currency || "") : ""
    // Yahoo's decimals for this quote (2; 4 for a stock near a euro).
    readonly property int hint: head.q && typeof head.q.priceHint === "number" ? head.q.priceHint : 2
    readonly property bool scrubbing: !!head.scrub
    // the date takes the left part of the change line while scrubbing
    readonly property bool showDate: head.scrubbing && !!head.scrub.t
    readonly property bool useFig: !!head.fig && head.fig.symbol === head.symbol && head.fig.range !== "1D"
    readonly property string figLabel: head.useFig && !head.scrubbing ? head.fig.range : ""
    readonly property real shownPrice: head.scrubbing ? head.scrub.v : (head.q && head._num(head.q.price) ? head.q.price : NaN)
    readonly property real shownChange: {
        if (head.scrubbing)
            return head._num(head.scrub.base) ? head.scrub.v - head.scrub.base : NaN;
        if (head.useFig)
            return head._num(head.fig.change) ? head.fig.change : NaN;
        return head.q && head._num(head.q.change) ? head.q.change : NaN;
    }
    readonly property real shownPct: {
        if (head.scrubbing) {
            const base = head.shownPrice - head.shownChange;
            return base !== 0 ? 100 * head.shownChange / base : 0;
        }
        if (head.useFig)
            return head._num(head.fig.pct) ? head.fig.pct : NaN;
        return head.q && head._num(head.q.changePct) ? head.q.changePct : NaN;
    }
    readonly property bool watched: {
        const s = head.service;
        if (!s || !head.symbol)
            return false;
        void s.watchlist;
        return s.isWatched(head.symbol);
    }

    readonly property real _lineH: Math.ceil(head.bodySize * 1.4)
    // The third line takes what the logo leaves under the two (13 px at 56),
    // so the header is the logo's height with or without it.
    readonly property real _extH: Math.max(Math.ceil(head.figureSize * 1.15), head.logoSize - head._twoH)
    readonly property real _twoH: Math.ceil(head.titleSize * 1.35) + 4 + head._lineH
    implicitHeight: Math.max(head.logoSize, head._twoH + head._extH)
    // The extended line's presence: its opacity and the block's centring.
    // The words it shows are the last ones it had while it fades out.
    property var _extShown: null
    onExtChanged: if (head.ext) head._extShown = head.ext
    Component.onCompleted: head._extShown = head.ext
    property real extF: head.ext ? 1 : 0
    Behavior on extF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    // ---- the logo, the link ------------------------------------------------------------
    property real logoHoverF: logoArea.containsMouse ? 1 : 0
    Behavior on logoHoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    LogoRelief {
        id: logo
        x: 0
        y: Math.round((head.height - head.logoSize) / 2)
        logoSize: head.logoSize
        // The row's reading, a little shallower at 56 px (StockRow).
        surfaceColor: Theme.listBox
        shadowColor: Theme.shadowDeep
        bodyColor: Mix.c(Theme.panelSunk, Theme.border, Theme.mode === "dark" ? 0.35 : 0.85)
        falloff: Theme.mode === "dark" ? 0.8 : 0.4
        ambient: Theme.mode === "dark" ? 0.5 : 1.0
        bevelWidth: 0.2
        highlightGain: 0.85 + 0.35 * head.logoHoverF
        source: {
            const s = head.service;
            if (!s || !head.symbol)
                return "";
            void s.logoSerial;
            return s.logoFor(head.symbol, head.logoSize) || "";
        }
    }
    onSymbolChanged: {
        if (head.service && head.symbol && head.service.wantLogo)
            head.service.wantLogo(head.symbol, 0);
    }
    MouseArea {
        id: logoArea
        objectName: "stockLogoLink"
        x: logo.x
        y: logo.y
        width: head.logoSize
        height: head.logoSize
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (head.service && head.symbol)
                head.service.openQuote(head.symbol);
        }
    }

    // ---- the slots on the right ------------------------------------------------------------
    TextMetrics {
        id: priceM
        font.family: head.fontFamily
        font.pixelSize: head.titleSize
        font.bold: true
        text: F.priceTemplate(head.q && head._num(head.q.w52Hi) ? Math.max(head.q.w52Hi, head.shownPrice || 0) : head.shownPrice, head.currency, head.hint)
    }
    TextMetrics {
        id: pctM
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        font.bold: true
        text: F.pctTemplate(Math.max(88.88, head.bound ? head.bound.pct : 0, head.q && head._num(head.q.changePct) ? Math.abs(head.q.changePct) : 0))
    }
    // The amount's slot: the largest move of the picture (or of today).
    TextMetrics {
        id: absM
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        text: "+" + F.priceTemplate(Math.max(8.88, head.bound ? head.bound.abs : 0, head.q && head._num(head.q.change) ? Math.abs(head.q.change) : 0), "", head.hint)
    }
    // The widest range name ("MAX", "YTD").
    TextMetrics {
        id: labelM
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        text: "MAX"
    }
    TextMetrics {
        id: labelM2
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        text: "YTD"
    }
    FontMetrics {
        id: dateFM
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }
    // The widest date this range's scrub prints (scrubText's formats), at the metrics' own font (read first: the dependency).
    function _dateSlotW(range: string): real {
        void dateFM.font;
        const w = t => Math.ceil(dateFM.advanceWidth(t));
        const days = [], months = [];
        for (let k = 0; k < 7; k++)
            days.push(Qt.formatDateTime(new Date(2026, 0, 5 + k, 18, 58), "ddd"));
        for (let k = 0; k < 12; k++)
            months.push(Qt.formatDateTime(new Date(2026, k, 28, 18, 58), "MMM"));
        let best = 0;
        if (range === "1D") {
            // a time, and the exchange's offset when its clock is not this machine's (scrubText): the offset's own shape, two
            // hour digits for either side of a DST change, minutes only for an exchange that has them
            const q = head.q;
            if (!q || !head._num(q.gmtoffset) || (q.gmtoffset === 0 && !q.tz))
                return w("88:88");
            const mins = Math.abs(q.gmtoffset) % 3600 !== 0 ? ":88" : "";
            return Math.max(w("88:88 UTC+88" + mins), w("88:88 UTC-88" + mins));
        }
        if (range === "5D" || range === "1M") {
            for (const d of days)
                for (const m of months)
                    best = Math.max(best, w(d + " 88 " + m + " 88:88"));
            return best;
        }
        for (const m of months)
            best = Math.max(best, w("88 " + m + " 8888"));
        return best;
    }
    readonly property real starW: 22
    readonly property real priceW: Math.ceil(priceM.advanceWidth)
    readonly property real pctW: Math.ceil(pctM.advanceWidth)
    readonly property real absW: Math.ceil(absM.advanceWidth)
    readonly property real labelW: Math.ceil(Math.max(labelM.advanceWidth, labelM2.advanceWidth))
    readonly property real dateW: head._dateSlotW(head.range)
    // The change line's left part (the range's name and the amount, or the date
    // that takes both) and the whole block. 1D is never labelled: no name slot.
    readonly property real leftW: Math.max(head.dateW, (head.range === "1D" ? 0 : head.labelW + 6) + head.absW)
    readonly property real rightW: Math.max(head.priceW, head.leftW + 8 + head.pctW)
    readonly property real rightX: head.width - head.starW - 6 - head.rightW
    // where each line's right-hand block starts: the price on the name's line, the change on the facts line
    readonly property real priceX: head.width - head.starW - 6 - head.priceW
    readonly property real changeX: head.width - head.starW - 6 - (head.leftW + 8 + head.pctW)

    // ---- name and the facts line -----------------------------------------------------------
    readonly property real textX: head.logoSize + 12
    Text {
        id: nameText
        x: head.textX
        y: Math.round((head.height - head._twoH - head.extF * head._extH) / 2)
        width: head.priceX - 10 - x
        height: Math.ceil(head.titleSize * 1.35)
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: head.q ? (head.q.name || head.q.shortName || head.symbol) : head.symbol
        color: Theme.textPrimary
        font.family: head.fontFamily
        font.pixelSize: head.titleSize
        font.bold: true
    }
    Text {
        id: factsText
        x: head.textX
        y: nameText.y + nameText.height + 4
        width: head.changeX - 10 - x
        height: head._lineH
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: {
            const q = head.q;
            const parts = [head.symbol];
            if (q && (q.fullExchange || q.exchange))
                parts.push(q.fullExchange || q.exchange);
            if (head.currency)
                parts.push(head.currency);
            if (q && q.state)
                parts.push(q.state === "open" ? "open" : q.state === "pre" ? "pre-market" : q.state === "post" ? "after hours" : "closed");
            return parts.join(" · ");
        }
        color: Theme.textMuted
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }

    Text {
        id: priceText
        objectName: "stockDetailPrice"
        x: head.rightX
        y: nameText.y
        width: head.rightW
        height: nameText.height
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: head._num(head.shownPrice) ? F.price(head.shownPrice, head.currency, head.hint) : "—"
        color: head.scrubbing ? Theme.accent : Theme.textPrimary
        font.family: head.fontFamily
        font.pixelSize: head.titleSize
        font.bold: true
    }
    // The scrub's instant in the EXCHANGE's clock, as the chart's axis prints it (the axis reads the quote's gmtoffset; a
    // NYSE bar at 09:30 reads 09:30 on both, not 15:30 here). On 1D, where the time of day is the whole point, an exchange
    // clock that is not this machine's at that instant says so ("09:30 UTC-4"); the dated ranges have no room for it and
    // the facts line names the exchange. The offset is the quote's moved by the zone's DST rule (Markets.offsetAt), so a
    // bar from before the exchange's change reads right (`readMs`: when the quote was read, now unless a test says). tools/dev/dst_audit_cases.js K4.
    function scrubText(t, readMs) {
        const fmt = head.range === "1D" ? "hh:mm" : head.range === "5D" || head.range === "1M" ? "ddd d MMM hh:mm" : "d MMM yyyy";
        const q = head.q;
        if (!q || !head._num(q.gmtoffset) || (q.gmtoffset === 0 && !q.tz))
            return Qt.formatDateTime(new Date(t), fmt);
        const off = Markets.offsetAt(q, t, readMs > 0 ? readMs : Date.now());
        const w = new Date(t + off * 1000);
        const text = Qt.formatDateTime(new Date(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate(), w.getUTCHours(), w.getUTCMinutes()), fmt);
        if (head.range !== "1D" || off === -new Date(t).getTimezoneOffset() * 60)
            return text;
        const a = Math.abs(off), hh = Math.floor(a / 3600), mm = Math.round((a % 3600) / 60);
        return text + " UTC" + (off < 0 ? "-" : "+") + hh + (mm > 0 ? ":" + (mm < 10 ? "0" : "") + mm : "");
    }
    // The scrub's date: the whole left part, right-aligned; the elide is the
    // backstop for a locale that prints more than the template.
    Text {
        id: dateText
        objectName: "stockDetailDate"
        x: head.rightX + head.rightW - head.pctW - 8 - head.leftW
        y: factsText.y
        width: head.leftW
        height: head._lineH
        visible: head.showDate
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideLeft
        text: head.scrubbing && head.scrub.t ? head.scrubText(head.scrub.t) : ""
        color: Theme.textMuted
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }
    Text {
        id: labelText
        objectName: "stockDetailRangeLabel"
        x: head.rightX + head.rightW - head.pctW - 8 - head.absW - 6 - head.labelW
        y: factsText.y
        width: head.labelW
        height: head._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: head.figLabel
        color: Theme.textMuted
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }
    Text {
        id: changeText
        objectName: "stockDetailChange"
        x: head.rightX + head.rightW - head.pctW - 8 - head.absW
        y: factsText.y
        width: head.absW
        height: head._lineH
        visible: !head.showDate
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: {
            if (!head._num(head.shownChange))
                return "";
            return (head.shownChange < 0 ? "\u2212" : "+") + F.price(Math.abs(head.shownChange), "", head.hint);
        }
        color: head.shownChange < 0 ? Theme.stockLoss : Theme.stockGain
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }
    Text {
        x: head.rightX + head.rightW - head.pctW
        y: factsText.y
        width: head.pctW
        height: head._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: head._num(head.shownPct) ? F.pct(head.shownPct) : ""
        color: head.shownPct < 0 ? Theme.stockLoss : Theme.stockGain
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        font.bold: true
    }

    // ---- the extended hours -----------------------------------------------------------------
    Text {
        id: extText
        objectName: "stockDetailExt"
        x: head.textX
        y: factsText.y + factsText.height
        width: head.rightX + head.rightW - head.pctW - 8 - x
        height: head._extH
        opacity: head.extF
        visible: opacity > 0
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideLeft
        text: {
            const e = head._extShown;
            if (!e || !head._num(e.price))
                return "";
            return (e.kind === "pre" ? "Pre-market " : "After hours ") + F.price(e.price, "", head.hint);
        }
        color: Theme.textMuted
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
    }
    Text {
        objectName: "stockDetailExtPct"
        x: head.rightX + head.rightW - head.pctW
        y: extText.y
        width: head.pctW
        height: head._extH
        opacity: head.extF
        visible: opacity > 0
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        readonly property real v: head._extShown && head._num(head._extShown.changePct) ? head._extShown.changePct : NaN
        text: head._num(v) ? F.pct(v) : ""
        color: v < 0 ? Theme.stockLoss : Theme.stockGain
        font.family: head.fontFamily
        font.pixelSize: head.figureSize
        font.bold: true
    }

    // ---- the star ------------------------------------------------------------------------------
    property real starHoverF: starArea.containsMouse ? 1 : 0
    Behavior on starHoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    Text {
        id: star
        x: head.width - head.starW
        y: nameText.y
        width: head.starW
        height: nameText.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: head.watched ? "\uF005" : "\uF006"
        color: head.watched ? Theme.accent : Mix.c(Theme.textFaint, Theme.accent, head.starHoverF)
        font.family: "Symbols Nerd Font"
        font.pixelSize: 15
    }
    MouseArea {
        id: starArea
        objectName: "stockWatchStar"
        anchors.fill: star
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (head.service && head.symbol)
                head.service.toggleWatch(head.symbol);
        }
    }
}
