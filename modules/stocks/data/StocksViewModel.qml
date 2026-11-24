pragma ComponentBehavior: Bound

import QtQuick
import "Portfolio.js" as Portfolio
import "StocksFormat.js" as Fmt
import "../../notifications/sources/SuddenMove.js" as Sudden
import "../../notifications/sources/SourceGlyphs.js" as Glyphs

// =============================================================================
// StocksViewModel.qml -- the part of the stocks service the popup READS that
// does not depend on where the data came from. StocksService and StocksMock
// each hold one and expose its members as their own, so the rows, the indices
// strip and the real flip are one implementation.
//
//   build({ portfolio, quotes, watchlist, indices, sortKey, sortAscending, stale, loading })
//   buildSearch(results, quotes, stale)      results: Markets.parseSearch rows
//   clearSearch()
//   realHover(sourceId, on)                  showReal, 80 ms linger on the last leave
//   realFlash                                0..1, the flip's ONE clock (below)
//   notifyAlerts(fire, quotes, notifier)     Markets.evalAlerts' `fire` as desktop
//                                            notifications, "Open" as the action
//   alertSymbol(key)                         the symbol a notification key was for
//
// Alert notifications rotate over `alertKeys` (four): the owner's
// DesktopNotifier lists them in its `keys` so each alert has its own slot and
// two alerts of one burst do not replace each other.
//
// AN ALERT IS NOT AN ASK, so it has the NORM DURATION of its urgency, not an infinite
// notification (it is not something that HAS to be answered). A `timeoutMs: 0` would be turned
// by DesktopNotifier into -1 -- sticky, for the day move, a price above, a price below alike --
// so it leaves the time to the service: the urgency's own (notifications.jsonc
// `timeouts.normal`), or the user's `sources.stocks.timeoutMs` rule. The manager keeps the
// card either way.
//
// realFlash is the feedback for the real flip, one clock for the popup AND the
// detail (every gain figure paints its pill at this fraction; nobody animates
// it again): on showReal false -> true it jumps to 1 and decays to
// `realFlashFloor` over `realFlashMs` (OutCubic), a faint hold while real
// stays on; on true -> false it eases to 0 over `realFadeMs`. One
// NumberAnimation on the one property, re-aimed from wherever it is.
//
// Rows are ListModels with one role `rec`: a QtObject { property var d } kept
// by pointer, only `d` re-assigned (CLAUDE.md, the ListModel-mirror law).
// `d` is a Row (docs/stocks.md) -- facts only, never a colour.
// =============================================================================
Item {
    id: root

    readonly property ListModel holdingRows: ListModel {}
    readonly property ListModel watchRows: ListModel {}
    readonly property ListModel closedRows: ListModel {}
    readonly property ListModel searchRows: ListModel {}
    readonly property ListModel indexRows: ListModel {}
    property var indices: []
    property var moversOrder: []

    readonly property bool showReal: root._showReal
    readonly property real realFlash: root._flash
    property int realFlashMs: 900
    property real realFlashFloor: 0.25
    property int realFadeMs: 160
    function realHover(sourceId, on) {
        const s = Object.assign({}, root._realSources);
        if (on) s[sourceId] = true;
        else delete s[sourceId];
        root._realSources = s;
        if (Object.keys(s).length > 0) {
            realLinger.stop();
            root._showReal = true;
        } else {
            realLinger.restart();
        }
    }

    function row(kind, sym, h, label, quotes, stale) {
        const q = (quotes && quotes[sym]) || null;
        return {
            key: kind + ":" + sym, kind: kind, symbol: sym,
            label: label || (h ? h.label : sym),
            name: h && h.name ? h.name : (q ? (q.shortName || q.name || sym) : sym),
            currency: h ? h.currency : (q ? q.currency : ""),
            exchDisp: q ? (q.fullExchange || q.exchange || "") : "",
            typeDisp: q ? (q.type || "") : "",
            price: h ? h.price : (q ? q.price : null),
            // Yahoo's decimals for the quote (2; 4 for a stock near a euro, FX).
            priceHint: q && typeof q.priceHint === "number" ? q.priceHint : 2,
            change: h ? h.change : (q ? q.change : null),
            changePct: h ? h.changePct : (q ? q.changePct : null),
            state: h ? h.state : (q ? q.state : "closed"),
            stale: !!stale,
            shares: h ? h.shares : 0,
            value: h ? h.value : null,
            total: h ? h.total : null, totalReal: h ? h.totalReal : null,
            totalPct: h ? h.totalPct : null, totalPctReal: h ? h.totalPctReal : null,
            realised: h ? h.realised : null, realisedReal: h ? h.realisedReal : null,
            spark: { v: q && q.spark ? q.spark.c : [], base: q ? q.prevClose : null },
            // The pre- / post-market move while it is shown (Markets.extVisible).
            ext: kind !== "index" && root._ext[sym] ? root._ext[sym] : null
        };
    }

    // Yahoo pads some short names and appends a class letter after the padding
    // ("EURO STOXX 50                 I"): the letter goes, the runs collapse.
    function cleanName(s) {
        return String(s || "").replace(/\s{2,}[A-Za-z]\s*$/, "").replace(/\s+/g, " ").trim();
    }

    property var _ext: ({})
    function build(o) {
        root._ext = o.ext || {};
        const p = o.portfolio;
        const quotes = o.quotes || {};
        const loading = !!o.loading;
        const hold = p ? (p.holdings || []).map(function (h) { return root.row("holding", h.symbol, h, "", quotes, o.stale); }) : [];
        const closed = p ? (p.closed || []).map(function (h) { return root.row("closed", h.symbol, h, "", quotes, o.stale); }) : [];
        const watch = loading ? [] : (o.watchlist || []).map(function (s) { return root.row("watch", s, null, "", quotes, o.stale); });
        const idx = (loading ? [] : (o.indices || [])).map(function (e) {
            const q = quotes[e.symbol];
            return root.row("index", e.symbol, null, e.alias || root.cleanName(q ? q.shortName : "") || e.symbol,
                            quotes, o.stale);
        });
        root._sync(root.holdingRows, Portfolio.sortRows(hold, o.sortKey, o.sortAscending));
        root._sync(root.closedRows, Portfolio.sortRows(closed, o.sortKey, o.sortAscending));
        root._sync(root.watchRows, Portfolio.sortRows(watch, o.sortKey, o.sortAscending));
        root._sync(root.indexRows, idx);
        root.indices = idx;
        const order = idx.map(function (r, i) { return i; });
        order.sort(function (a, b) {
            const x = Math.abs(idx[a].changePct || 0), y = Math.abs(idx[b].changePct || 0);
            return y - x || a - b;
        });
        root.moversOrder = order;
        root._lastQuotes = quotes;
        root._lastStale = !!o.stale;
        if (root._searchResults.length > 0) root.buildSearch(root._searchResults, quotes, o.stale);
    }

    function buildSearch(results, quotes, stale) {
        root._searchResults = results || [];
        const q = quotes || root._lastQuotes;
        const rows = root._searchResults.map(function (s) {
            const r = root.row("search", s.symbol, null, s.symbol, q, stale === undefined ? root._lastStale : stale);
            if (!q[s.symbol]) r.name = s.name || s.symbol;
            r.exchDisp = s.exchDisp || r.exchDisp;
            r.typeDisp = s.typeDisp || r.typeDisp;
            return r;
        });
        root._sync(root.searchRows, rows);
    }

    function clearSearch() {
        root._searchResults = [];
        root._sync(root.searchRows, []);
    }

    readonly property var alertKeys: ["stocks-alert-0", "stocks-alert-1", "stocks-alert-2", "stocks-alert-3"]
    // `opts` (all optional): { body: the StockMoveBody component the card draws the day with, label: sym -> the holding's label,
    // nowMs }. The notifier carries the body to the shell's service only; the notify-send path says the words alone.
    function notifyAlerts(fire, quotes, notifier, opts) {
        const o = opts || {};
        for (let i = 0; i < fire.length; i++) {
            const f = fire[i];
            const q = (quotes && quotes[f.symbol]) || {};
            const label = o.label ? o.label(f.symbol) : f.symbol;
            const price = function (v) { return Fmt.price(v, q.currency, q.priceHint); };
            const what = f.kind === "above" ? "rose above " + price(f.level)
                       : f.kind === "below" ? "fell below " + price(f.level)
                       : "moved " + Fmt.pct(f.changePct) + " today";
            const key = root.alertKeys[root._alertNext];
            root._alertNext = (root._alertNext + 1) % root.alertKeys.length;
            root._alertSyms[key] = f.symbol;
            const up = f.kind === "above" ? true : f.kind === "below" ? false : !(f.changePct < 0);
            const spec = {
                title: label + " " + what,
                body: "Now " + price(f.price) + ", " + Fmt.pct(f.changePct) + " today",
                actions: [{ id: "open", label: "Open" }]
            };
            if (o.body) {
                const now = typeof o.nowMs === "number" ? o.nowMs : Date.now();
                spec.icon = up ? Glyphs.stocksUp : Glyphs.stocksDown;
                spec.bodyComponent = o.body;
                spec.bodyProps = { facts: Sudden.facts(q, null, null, now, { kind: f.kind, level: f.kind === "dayMove" ? null : f.level }) };
            }
            if (notifier) notifier.notify(key, spec);
        }
    }
    function alertSymbol(key) { return root._alertSyms[key] || ""; }

    // ---- Private ---------------------------------------------------------------
    property int _alertNext: 0
    property var _alertSyms: ({})
    property bool _showReal: false
    property real _flash: 0
    property var _realSources: ({})
    property var _searchResults: []
    property var _lastQuotes: ({})
    property bool _lastStale: false

    on_ShowRealChanged: {
        flashAnim.stop();
        if (root._showReal) {
            root._flash = 1;
            flashAnim.to = root.realFlashFloor;
            flashAnim.duration = root.realFlashMs;
        } else {
            flashAnim.to = 0;
            flashAnim.duration = root.realFadeMs;
        }
        flashAnim.from = root._flash;
        flashAnim.start();
    }
    NumberAnimation {
        id: flashAnim
        target: root
        property: "_flash"
        easing.type: Easing.OutCubic
    }

    Timer {
        id: realLinger
        interval: 80
        onTriggered: root._showReal = Object.keys(root._realSources).length > 0
    }

    Component { id: recComp; QtObject { property var d: ({}) } }

    // One QtObject per row kept by pointer, only `d` re-assigned; a new
    // delegate only for a row that is really new.
    function _sync(model, arr) {
        while (model.count > arr.length) {
            const rec = model.get(model.count - 1).rec;
            model.remove(model.count - 1);
            if (rec) rec.destroy();
        }
        for (let i = 0; i < arr.length; i++) {
            if (i < model.count) model.get(i).rec.d = arr[i];
            else model.append({ rec: recComp.createObject(root, { d: arr[i] }) });
        }
    }
}
