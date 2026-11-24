pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/system"
import "Markets.js" as Markets
import "Portfolio.js" as Portfolio

// =============================================================================
// StocksMock.qml -- the stocks service without a network.
//
// The SAME members as StocksService (docs/stocks.md, "StocksService"):
// the popup, the detail and the bar take ONE `service` and nothing above it
// changes when the mock is swapped for the real one. Everything is computed by
// the same Markets.js / Portfolio.js the real service runs, on the captured
// responses under modules/stocks/data/fixtures/ and the portfolio in
// modules/stocks/data/fixtures/portfolio.jsonc (`configPath`), with the clock pinned to captured.json
// (2026-09-24 11:02 CEST: Europe open, the US before its open).
//
// The mock's own knobs:
//   scenario      one of `scenarios` (market-open is the capture itself)
//   sessionClock  0..1 across the European session of the captured day
//                 (ASML.AS's 09:00..17:30); -1 = the capture's own instant.
//                 nowMs follows it; every spark is cut at nowMs, and a
//                 session running past the capture is continued by a smooth
//                 deterministic walk from its last captured price, so prices,
//                 the portfolio and every figure move with the slider. A
//                 scenario about a time (pre-market, market-closed) sets its
//                 own unless the slider has been set.
//   fireTestAlert()  runs Markets.evalAlerts on a price pushed over the first
//                 `above` alert and notifies through `notifier` (the alert
//                 scenario does it on entry).
//
// Latency is mocked where the UI has a state for it: a chart answers
// {state: "loading"} first and "ready" `answerMs` (180) later (chartSerial bumps), a
// search is busy through its 300 ms debounce, the summary's 5D is
// `summaryLoading` (series null) for `answerMs` after it is first selected in a
// scenario. The loading scenario never answers.
//
// The 5D is modules/stocks/data/fixtures/spark_5d.json, captured at 17:07, AFTER
// captured.json: every series is cut at the clock (at most the capture), and
// a clock past the capture continues with each symbol's own 1d walk (above),
// so the 5D's today is the 1D's today. The watchlist is seeded [MSFT, ABI.BR], in memory only.
//
// Extended hours: a US listing outside its regular session has a pre- or
// post-market move. The capture instant is the US pre-market, market-closed
// (Saturday) is after the close. Their moves are the real ones captured in
// modules/stocks/data/fixtures/r6/ (2026-09-30: AAPL / NVDA / MSFT, a pre-market and
// the whole extended day before it), moved onto the mock's day and scaled to
// its prices -- the pre-market from the last close, the after hours from the
// day's close -- so the 1D chart, the row's tag and the header agree.
//
// Logos come from modules/stocks/data/fixtures/baked/ (index.json as written by
// tools/stocks/stock_logo.py); an absent index gives "" everywhere.
//
// Fixtures are read through one FileView each, created with its path and
// read synchronously (blockLoading), never repointed (CLAUDE.md FileView law).
// =============================================================================
Item {
    id: root

    // ---- status ---------------------------------------------------------------
    property bool popupOpen: false
    readonly property bool loading: root._loading
    property bool offline: false
    property bool stale: false
    property bool rateLimited: false
    property real retryAtMs: 0
    property string lastError: ""
    property string configError: ""
    property real fetchedAtMs: 0
    property real nowMs: root.captureMs
    readonly property var config: root._config
    property string configPath: RepoRoot.dir + "/modules/stocks/data/fixtures/portfolio.jsonc"
    property string statePath: ""
    property string cacheDir: ""
    property string curl: "curl"
    property string python: "python3"
    property bool dryRun: false
    signal updated()
    signal urlOpened(string url)
    function refresh() { root._rebuild(); }

    // ---- snapshots ------------------------------------------------------------
    readonly property var quotes: root._quotes
    readonly property var extended: root._extShown
    readonly property var portfolio: root._portfolio
    readonly property var daySpark: root._daySpark
    readonly property var summarySeries: root._summarySeries

    // ---- rows -----------------------------------------------------------------
    readonly property ListModel holdingRows: vm.holdingRows
    readonly property ListModel watchRows: vm.watchRows
    readonly property ListModel closedRows: vm.closedRows
    readonly property ListModel searchRows: vm.searchRows
    readonly property ListModel indexRows: vm.indexRows
    property string sortKey: "value"
    property bool sortAscending: false
    // The 1-minute day of one symbol (a captured NVDA day laid onto the quote's own: Markets.fineOnto), answered at once; null for a
    // symbol with no quote or the fixture missing.
    function fineSpark(sym, cb) {
        const q = root._quotes ? root._quotes[sym] : null;
        const fx = root._parsed("spark_NVDA_1m", Markets.parseSpark);
        const f = fx && fx.NVDA ? fx.NVDA : null;
        if (!q || !q.spark || !q.session || !f || !f.session) { cb(null); return; }
        const sp = Markets.fineOnto(f.spark, q.spark, f.session.start, q.session.start);
        cb(sp.t.length > 0 ? sp : null);
    }

    function setSort(key, ascending) {
        if (root._sortKeys.indexOf(key) < 0) return;
        root._sortGuard = true;
        root.sortKey = key;
        root.sortAscending = ascending === undefined || ascending === null ? key === "name" : !!ascending;
        root._sortGuard = false;
        root._rebuildRows();
    }
    property string tab: "holdings"
    property bool closedExpanded: false
    property string summaryRange: "1M"
    readonly property bool summaryLoading: root._summaryLoading
    property string detailRange: "1D"

    // ---- watchlist ------------------------------------------------------------
    readonly property var watchlist: root._watchlist
    function isWatched(sym) { return root._watchlist.indexOf(sym) >= 0; }
    function toggleWatch(sym) {
        const w = root._watchlist.slice();
        const i = w.indexOf(sym);
        if (i >= 0) w.splice(i, 1);
        else w.push(sym);
        root._watchlist = w;
    }

    // ---- the real flip --------------------------------------------------------
    readonly property bool showReal: vm.showReal
    function realHover(sourceId, on) { vm.realHover(sourceId, on); }
    // The flip's feedback, ONE clock shared by popup and detail (StocksViewModel).
    readonly property real realFlash: vm.realFlash
    property alias realFlashMs: vm.realFlashMs
    property alias realFlashFloor: vm.realFlashFloor
    property alias realFadeMs: vm.realFadeMs

    // ---- indices strip --------------------------------------------------------
    readonly property var indices: vm.indices
    readonly property var moversOrder: vm.moversOrder

    // ---- search ---------------------------------------------------------------
    property string searchQuery: ""
    readonly property bool searchBusy: root._searchBusy
    function setSearchQuery(q) {
        root.searchQuery = q === undefined || q === null ? "" : String(q);
        if (root.searchQuery.trim().length === 0) { root.clearSearch(); return; }
        root._searchBusy = true;
        searchTimer.restart();
    }
    function clearSearch() {
        searchTimer.stop();
        root.searchQuery = "";
        root._searchBusy = false;
        vm.clearSearch();
    }

    // ---- detail ---------------------------------------------------------------
    // A read (bindings call it); loadChart() asks -- as the service's.
    function chart(sym, range) {
        if (!sym || !range) return null;
        return root._charts[sym + "|" + range] || null;
    }
    function chartPending(sym, range) {
        const c = root._charts[sym + "|" + range];
        return !!c && c.state === "loading";
    }
    function loadChart(sym, range) {
        if (!sym || !range) return;
        const key = sym + "|" + range;
        if (root._charts[key]) return;
        root._charts[key] = { state: "loading", symbol: sym, range: range, error: "" };
        if (!root._loading) {
            root._chartQueue.push(key);
            chartTimer.restart();
        }
        root.chartSerial++;
    }
    function stats(sym) {
        const q = root._quotes[sym];
        if (!q) return null;
        const cn = root._cnbcFor(sym);
        const c1 = root._fixture("chart_" + root.slug(sym) + "_1D");
        let open = null;
        if (c1) {
            const ch = Markets.parseChart(c1);
            if (ch && ch.o) for (let i = 0; i < ch.o.length && open === null; i++)
                if (ch.o[i] !== null && ch.o[i] !== undefined) open = ch.o[i];
        }
        if (open === null && q.spark && q.spark.c && q.spark.c.length > 0) open = q.spark.c[0];
        return {
            open: open, high: root._num(q.dayHigh), low: root._num(q.dayLow),
            prevClose: root._num(q.prevClose), volume: root._num(q.volume),
            w52Lo: root._num(q.w52Lo), w52Hi: root._num(q.w52Hi),
            avgVol: cn ? cn.avgVol : null, mcap: cn ? cn.mcap : null, pe: cn ? cn.pe : null,
            eps: cn ? cn.eps : null, divYield: cn ? cn.divYield : null, beta: cn ? cn.beta : null
        };
    }
    function position(sym) {
        const p = root._portfolio;
        if (!p) return null;
        const lists = [p.holdings || [], p.closed || []];
        for (let l = 0; l < lists.length; l++)
            for (let i = 0; i < lists[l].length; i++)
                if (lists[l][i].symbol === sym) return lists[l][i];
        return null;
    }
    function watchDetail(sym, range) {
        root._detail = { symbol: sym, range: range };
        if (range) root.detailRange = range;
        root.loadChart(sym, range);
    }
    function unwatchDetail() { root._detail = null; }
    property int chartSerial: 0
    property int statsSerial: 0

    // ---- logos ----------------------------------------------------------------
    function logoFor(sym, px) { return logos.logoFor(sym, px); }
    function wantLogo(sym, priority) { }
    readonly property int logoSerial: logos.serial

    function openQuote(sym) {
        const url = Markets.quoteUrl(sym, root.config && root.config.quoteUrl);
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(url);
    }
    property var notifier: null
    // The StockMoveBody component an alert card draws its day with (the shell hands it in; null: the words alone).
    property var alertBody: null
    signal alertOpenRequested(string symbol)
    // The notification keys alerts use: the owner's DesktopNotifier lists them.
    readonly property var alertKeys: vm.alertKeys

    // ---- the mock's own knobs ---------------------------------------------------
    property string scenario: "market-open"
    readonly property var scenarios: ["market-open", "market-closed", "pre-market", "offline",
        "rate-limited", "empty", "mixed-currencies", "split", "dividend", "sell-too-many",
        "bad-config", "alert", "loading"]
    property real sessionClock: -1
    readonly property real captureMs: root._captureMs
    function fireTestAlert() { root._fireAlerts(true); }

    onScenarioChanged: {
        root._spark5dReady = false;
        if (root.scenario === "empty") root._watchlist = [];
        else if (root._watchlist.length === 0) root._watchlist = root._watchSeed;
        root._charts = ({});
        root._rebuild();
        if (root.scenario === "alert") root._fireAlerts(false);
    }
    onSessionClockChanged: { root._charts = ({}); root._rebuild(); }
    onWatchlistChanged: root._rebuildRows()
    onSortKeyChanged: if (!root._sortGuard) root._rebuildRows()
    onSortAscendingChanged: if (!root._sortGuard) root._rebuildRows()
    onSummaryRangeChanged: root._rebuildSeries()

    // =========================================================================
    // Private
    // =========================================================================
    property bool _loading: false
    property bool _summaryLoading: false
    property bool _spark5dReady: false
    readonly property var _sortKeys: ["value", "day", "total", "name"]
    property bool _sortGuard: false
    property var _config: ({ holdings: [], indices: [], alerts: [] })
    property var _quotes: ({})
    property var _portfolio: null
    property var _input: null
    property var _daySpark: null
    property var _summarySeries: null
    readonly property var _watchSeed: ["MSFT", "ABI.BR"]
    property var _watchlist: root._watchSeed
    property bool _searchBusy: false
    property var _charts: ({})
    property var _chartQueue: []
    property var _detail: null
    property var _fixtures: ({})
    property var _ext: ({})
    property var _extShown: ({})
    property var _firedAlerts: []
    property real _captureMs: 0
    property bool _complete: false

    Component { id: fixtureView; FileView { blockLoading: true; printErrors: false } }

    StocksConfig { id: cfgFile; configPath: root.configPath }

    StocksViewModel { id: vm }
    StockLogos { id: logos; dir: RepoRoot.dir + "/modules/stocks/data/fixtures/baked"; fetching: false }
    Timer { id: searchTimer; interval: 300; onTriggered: root._runSearch() }
    // How long a detail chart and the summary's first 5D take to answer (a
    // render can stretch it to show the loading skeleton at rest).
    property int answerMs: 180
    Timer { id: chartTimer; interval: root.answerMs; onTriggered: root._resolveCharts() }
    Timer {
        id: spark5dTimer
        interval: root.answerMs
        onTriggered: {
            if (root._loading) return;
            root._spark5dReady = true;
            root._rebuildSeries();
        }
    }

    Connections {
        target: root.notifier
        ignoreUnknownSignals: true
        function onAction(key, id) {
            const sym = vm.alertSymbol(key);
            if (sym && id === "open") root.alertOpenRequested(sym);
        }
    }
    Connections {
        target: cfgFile
        function onConfigChanged() { if (root._complete) root._rebuild(); }
    }

    Component.onCompleted: {
        const cap = root._fixture("captured");
        root._captureMs = cap && cap.capturedAtMs ? cap.capturedAtMs : Date.now();
        root._complete = true;
        root._rebuild();
    }

    // Every char outside [A-Za-z0-9.-] -> "_" (the cache and fixture slug).
    function slug(sym) { return String(sym).replace(/[^A-Za-z0-9.\-]/g, "_"); }

    function _num(v) { return typeof v === "number" && isFinite(v) ? v : null; }

    function _fixture(name) {
        if (name in root._fixtures) return root._fixtures[name];
        const fv = fixtureView.createObject(root, {
            path: RepoRoot.dir + "/modules/stocks/data/fixtures/" + name + ".json"
        });
        let obj = null;
        const t = fv ? fv.text() : "";
        if (fv) fv.destroy();
        if (t && t.length > 0) {
            try { obj = JSON.parse(t); } catch (e) { obj = null; }
        }
        root._fixtures[name] = obj;
        return obj;
    }

    function _cnbcFor(sym) {
        const j = root._fixture("cnbc");
        if (!j) return null;
        const map = root._fixtures["@cnbc"] || (root._fixtures["@cnbc"] = Markets.parseCnbc(j) || {});
        const h = (root._config.holdings || []).filter(function (x) { return x.symbol === sym; })[0];
        const c = Markets.cnbcSymbol(sym, h && h.cnbc ? h.cnbc : "");
        return c && map[c] ? map[c] : null;
    }

    function _parsed(name, fn) {
        const key = "@" + name;
        if (key in root._fixtures) return root._fixtures[key];
        const j = root._fixture(name);
        const v = j ? fn(j, root._captureMs) : null;
        root._fixtures[key] = v;
        return v;
    }

    // ---- the clock --------------------------------------------------------------
    function _session() {
        const all = root._parsed("spark", Markets.parseSpark) || {};
        const q = all["ASML.AS"];
        return q && q.session ? q.session : { start: root._captureMs - 7200000, end: root._captureMs + 23400000 };
    }

    function _effectiveNow() {
        const s = root._session();
        if (root.sessionClock >= 0)
            return s.start + Math.min(1, root.sessionClock) * (s.end - s.start);
        if (root.scenario === "pre-market") return s.start - 45 * 60000;
        if (root.scenario === "market-closed") return s.end + 42.5 * 3600000;   // Saturday 12:00
        return root._captureMs;
    }

    // A quote at `now`: its spark cut there, continued past the capture while
    // its own session runs, and every derived figure recomputed from it.
    function _quoteAt(q, now) {
        const out = Object.assign({}, q);
        const t0 = (q.spark && q.spark.t) ? q.spark.t : [];
        const c0 = (q.spark && q.spark.c) ? q.spark.c : [];
        const t = [], c = [];
        for (let i = 0; i < t0.length; i++) {
            if (t0[i] > now && t.length > 0) break;
            if (c0[i] === null || c0[i] === undefined) continue;
            t.push(t0[i]); c.push(c0[i]);
        }
        const ses = q.session || null;
        if (ses && t.length > 0 && t[t.length - 1] >= ses.start) {
            const end = Math.min(now, ses.end);
            const last = c[c.length - 1];
            let seed = 0;
            for (let k = 0; k < q.symbol.length; k++) seed += q.symbol.charCodeAt(k);
            // The walk starts after the capture: at the capture's own instant
            // every price is the captured one.
            let tt = t[t.length - 1] + 300000;
            while (tt <= root._captureMs) tt += 300000;
            for (let k = 1; tt <= end; tt += 300000, k++) {
                const w = 0.0045 * (Math.sin(k * 0.21 + seed) - Math.sin(seed))
                        + 0.002 * (Math.sin(k * 0.67 + seed * 2) - Math.sin(seed * 2));
                t.push(tt); c.push(last * (1 + w));
            }
        }
        out.spark = { t: t, c: c };
        if (c.length > 0) {
            out.price = c[c.length - 1];
            out.timeMs = t[t.length - 1];
            if (typeof q.prevClose === "number" && q.prevClose !== 0) {
                out.change = out.price - q.prevClose;
                out.changePct = out.change / q.prevClose * 100;
            }
            // Yahoo's own high/low hold at the capture (they include intra-bar
            // extremes the closes do not); before it, the cut closes; after
            // it, widened by the walk.
            if (t0.length > 0 && t0[0] >= (ses ? ses.start : 0)) {
                const hi = Math.max.apply(null, c), lo = Math.min.apply(null, c);
                const atCapture = now >= root._captureMs;
                out.dayHigh = atCapture && q.dayHigh !== null ? Math.max(q.dayHigh, hi) : hi;
                out.dayLow = atCapture && q.dayLow !== null ? Math.min(q.dayLow, lo) : lo;
            }
        }
        out.state = Markets.marketState(out, now);
        return out;
    }

    // ---- the build ----------------------------------------------------------------
    function _rebuild() {
        if (!root._complete) return;
        const sc = root.scenario;
        const now = root._effectiveNow();
        root.nowMs = now;

        // Config, doctored per scenario.
        let cfg = cfgFile.config;
        let cfgErr = cfgFile.lastError;
        const only = function (syms) {
            return cfg.holdings.filter(function (h) { return syms.indexOf(h.symbol) >= 0; });
        };
        if (sc === "empty") cfg = Object.assign({}, cfg, { holdings: [], alerts: [] });
        else if (sc === "mixed-currencies") cfg = Object.assign({}, cfg, { holdings: only(["ASML.AS", "AAPL", "VOD.L"]) });
        else if (sc === "split") cfg = Object.assign({}, cfg, { holdings: only(["NVDA"]) });
        else if (sc === "dividend") cfg = Object.assign({}, cfg, { holdings: only(["KBC.BR", "AAPL"]) });
        else if (sc === "sell-too-many") {
            cfg = JSON.parse(JSON.stringify(cfg));
            for (let i = 0; i < cfg.holdings.length; i++)
                if (cfg.holdings[i].symbol === "ASML.AS")
                    cfg.holdings[i].actions.push({ type: "sell", date: "2025-09-01", shares: 40, price: 640.00, fees: 7.50, comment: "more than held" });
        } else if (sc === "bad-config") {
            const r = cfgFile.parseText(root._badConfigText());
            cfg = r.config;
            cfgErr = r.errors.join("; ");
        }
        root._config = cfg;
        root.configError = cfgErr;

        // Status per scenario.
        root._loading = sc === "loading";
        root.offline = sc === "offline";
        root.stale = sc === "offline";
        root.rateLimited = sc === "rate-limited";
        root.retryAtMs = sc === "rate-limited" ? now + 4 * 60000 : 0;
        root.fetchedAtMs = sc === "offline" ? now - 3 * 3600000 : (sc === "loading" ? 0 : now);

        if (root._loading) {
            root._quotes = {};
            root._portfolio = null;
            root._input = null;
            root._daySpark = null;
            root._rebuildSeries();
            root.lastError = cfgErr;
            root._rebuildRows();
            root.updated();
            return;
        }

        // Quotes at `now`.
        const all = root._parsed("spark", Markets.parseSpark) || {};
        const quotes = {};
        for (const s in all) quotes[s] = root._quoteAt(all[s], now);
        if (sc === "alert") root._pushOverAlert(quotes, cfg);
        root._quotes = quotes;
        const ext = {};
        for (const s in quotes) {
            const e = root._extMove(s, quotes[s], now);
            if (e) ext[s] = e;
        }
        root._ext = ext;
        root._extShown = Markets.extVisible(ext, quotes, now);

        // Portfolio through the same engine.
        const history = {};
        const fx = {};
        for (let i = 0; i < cfg.holdings.length; i++) {
            const sym = cfg.holdings[i].symbol;
            const hc = root._parsed("history_" + root.slug(sym), Markets.parseChart);
            if (hc) history[sym] = hc;
            const q = quotes[sym];
            const code = q ? Markets.normCurrency(q.currency).code : null;
            const fsym = code ? Markets.fxSymbol(code) : null;
            if (fsym && !(code in fx)) {
                const fq = quotes[fsym];
                fx[code] = {
                    hist: root._parsed("fx_" + root.slug(fsym), Markets.parseChart),
                    now: fq ? fq.price : null, prev: fq ? fq.prevClose : null,
                    spark: fq ? fq.spark : { t: [], c: [] }
                };
            }
        }
        const input = {
            nowMs: now, withholding: cfg.dividendWithholding, holdings: cfg.holdings,
            quotes: quotes, history: history, fx: fx,
            hicp: root._parsed("hicp_BE", Markets.parseHicp) || {}
        };
        const p = Portfolio.compute(input);
        root._input = input;
        root._portfolio = p;
        root._daySpark = Portfolio.intradayValue(input, p);

        // lastError: config first, then the engine, then the scenario's own.
        const errs = [];
        if (cfgErr) errs.push(cfgErr);
        if (p && p.errors && p.errors.length > 0) errs.push(p.errors.join("; "));
        if (sc === "offline") errs.push("offline: query1.finance.yahoo.com could not be reached, showing the last prices");
        if (sc === "rate-limited") errs.push("Yahoo is rate-limiting (HTTP 429): retrying in 4 min");
        root.lastError = errs.join("; ");

        root._rebuildSeries();
        root._rebuildRows();
        root.chartSerial++;
        root.statsSerial++;
        root.updated();
    }

    function _rebuildSeries() {
        const want5d = root.summaryRange === "5D";
        if (want5d && !root._spark5dReady && !root._loading && !spark5dTimer.running) spark5dTimer.start();
        root._summaryLoading = want5d && !root._spark5dReady;
        if (!root._input || !root._portfolio || root._summaryLoading) { root._summarySeries = null; return; }
        const input = want5d ? Object.assign({}, root._input, { spark5d: root._spark5dCut(root.nowMs) }) : root._input;
        root._summarySeries = Portfolio.valueSeries(input, root._portfolio, root.summaryRange);
    }

    // The 5d spark at `now`: cut at min(now, capture), then, past the
    // capture, the 1d walk's own points (the quotes are already at `now`).
    function _spark5dCut(now) {
        const all = root._parsed("spark_5d", Markets.parseSpark) || {};
        const cut = Math.min(now, root._captureMs);
        const out = {};
        for (const s in all) {
            const sp = all[s].spark || { t: [], c: [] };
            const t = [], c = [];
            for (let i = 0; i < sp.t.length && sp.t[i] <= cut; i++) { t.push(sp.t[i]); c.push(sp.c[i]); }
            const live = root._quotes[s] && root._quotes[s].spark ? root._quotes[s].spark : { t: [], c: [] };
            if (now > root._captureMs)
                for (let i = 0; i < live.t.length; i++)
                    if (live.t[i] > root._captureMs) { t.push(live.t[i]); c.push(live.c[i]); }
            out[s] = Object.assign({}, all[s], { spark: { t: t, c: c } });
        }
        return out;
    }

    function _badConfigText() {
        return JSON.stringify({
            currency: "USD",
            dividendWithholding: 1.3,
            holdings: [
                { symbol: "ASML.AS", alias: "ASML", actions: [
                    { type: "buy", date: "2023-03-15", shares: 8, price: 568.00, fees: 7.50 },
                    { type: "hold", date: "2024-11-04", shares: 4, price: 618.20 } ] },
                { symbol: "KBC.BR", actions: [
                    { type: "buy", date: "2022-13-10", shares: 30, price: 53.96 },
                    { type: "buy", date: "2024-02-12", shares: 10, price: 62.98, fees: 7.50 } ] },
                { alias: "no symbol", actions: [] }
            ]
        });
    }

    // ---- rows ---------------------------------------------------------------------
    function _rebuildRows() {
        vm.build({ portfolio: root._portfolio, quotes: root._quotes, ext: root._extShown, watchlist: root._watchlist,
                   indices: root._config.indices, sortKey: root.sortKey, sortAscending: root.sortAscending,
                   stale: root.stale,
                   loading: root._loading });
    }

    // ---- search -------------------------------------------------------------------
    function _lev(a, b) {
        const m = a.length, n = b.length;
        let prev = [];
        for (let j = 0; j <= n; j++) prev.push(j);
        for (let i = 1; i <= m; i++) {
            const cur = [i];
            for (let j = 1; j <= n; j++)
                cur.push(Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)));
            prev = cur;
        }
        return prev[n];
    }

    function _runSearch() {
        const q = root.searchQuery.trim().toLowerCase();
        const names = ["asml", "kbc"];
        let best = names[0], bestD = 1e9;
        for (let i = 0; i < names.length; i++) {
            const d = root._lev(q, names[i]);
            if (d < bestD) { bestD = d; best = names[i]; }
        }
        vm.buildSearch(root._parsed("search_" + best, Markets.parseSearch) || [], root._quotes, root.stale);
        root._searchBusy = false;
    }

    // ---- charts ---------------------------------------------------------------------
    function _resolveCharts() {
        const keys = root._chartQueue;
        root._chartQueue = [];
        if (keys.length === 0) return;
        const next = Object.assign({}, root._charts);
        for (let i = 0; i < keys.length; i++) {
            const parts = keys[i].split("|");
            next[keys[i]] = root._buildChart(parts[0], parts[1]);
        }
        root._charts = next;
        root.chartSerial++;
    }

    function _buildChart(sym, range) {
        const q = root._quotes[sym];
        const now = root.nowMs;
        if (range === "1D") {
            const xd = root._extChart(sym, q, now);
            if (xd) return xd;
            const thin = !q ? root._r6Day(sym) : null;
            if (thin) return thin;
        }
        const fx = root._parsed("chart_" + root.slug(sym) + "_" + range, Markets.parseChart);
        if (fx && range !== "1D" && range !== "5D")
            return Object.assign({}, fx, { state: "ready", error: "", range: range });
        if (range === "1D" || range === "5D") {
            if (fx) return Object.assign({}, root._cut(fx, now, q), { state: "ready", error: "", range: range });
            if (q && q.spark && q.spark.t.length > 0) {
                const c = q.spark.c;
                return { state: "ready", error: "", symbol: sym, range: range, t: q.spark.t,
                         o: c, h: c, l: c, c: c, v: c.map(function () { return 0; }),
                         prevClose: q.prevClose, meta: q, dividends: [], splits: [] };
            }
            return { state: "error", symbol: sym, range: range, error: "no intraday data for " + sym };
        }
        const hist = root._parsed("history_" + root.slug(sym), Markets.parseChart);
        if (!hist || !hist.t || hist.t.length === 0)
            return { state: "error", symbol: sym, range: range, error: "no " + range + " chart for " + sym + " in the fixtures" };
        return Object.assign(root._slice(hist, range, now), { state: "ready", error: "", range: range });
    }

    // ---- the extended hours (see the header) -------------------------------------------
    // The captured extended day for `sym`, moved and scaled onto the mock's:
    // { pre, post: { t, c } (null when none), periods } cut at `now`, or null.
    // Pre-market: today's pre-market only (what Yahoo's 1D shows then), from
    // the last close. Otherwise the last session's day: its pre-market from the
    // close before it, its after hours from its own close.
    function _extParts(sym, q, now) {
        if (!q || !q.prePost || !q.session || !root._num(q.price)) return null;
        const st = Markets.marketState(q, now);
        if (st === "open") return null;
        const pre = st === "pre";
        const ch = root._parsed("r6/chart_" + root.slug(sym) + "_1D_" + (pre ? "prepost" : "yesterday_prepost"),
                                Markets.parseChart);
        if (!ch || !ch.periods || ch.t.length === 0) return null;
        const DAY = 86400000, off = (q.gmtoffset || 0) * 1000;
        const dayOf = function (ms) { return Math.floor((ms + off) / DAY); };
        const target = pre ? q.session.start : q.timeMs;
        if (!root._num(target)) return null;
        const shift = (dayOf(target) - dayOf(ch.periods.start)) * DAY;
        const sp = Markets.splitSessions({ session: ch.periods, gmtoffset: q.gmtoffset }, ch.t, ch.c);
        let regLast = null;
        if (sp.regular.c.length > 0) regLast = sp.regular.c[sp.regular.c.length - 1];
        const kPre = pre ? q.price / ch.meta.price
                         : (root._num(q.prevClose) && root._num(ch.prevClose) ? q.prevClose / ch.prevClose : null);
        const kPost = !pre && regLast ? q.price / regLast : null;
        const move = function (part, k) {
            if (!k || part.t.length === 0) return null;
            const out = { t: [], c: [] };
            for (let i = 0; i < part.t.length; i++) {
                if (part.t[i] + shift > now) break;
                out.t.push(part.t[i] + shift);
                out.c.push(part.c[i] * k);
            }
            return out.t.length ? out : null;
        };
        const per = ch.periods;
        return { pre: move(sp.pre, kPre), post: pre ? null : move(sp.post, kPost),
                 periods: { preStart: per.preStart + shift, start: per.start + shift,
                            end: per.end + shift, postEnd: per.postEnd + shift } };
    }
    function _extMove(sym, q, now) {
        const x = root._extParts(sym, q, now);
        const part = x ? (x.post || (Markets.marketState(q, now) === "pre" ? x.pre : null)) : null;
        if (!part) return null;
        const price = part.c[part.c.length - 1];
        return { kind: x.post ? "post" : "pre", price: price, base: q.price, change: price - q.price,
                 changePct: (price - q.price) / q.price * 100, timeMs: part.t[part.t.length - 1] };
    }
    // The 1D chart with its extended hours: the pre-market alone before the
    // open, else the session's own chart (below) between its moved pre- and
    // post-market.
    function _extChart(sym, q, now) {
        const x = root._extParts(sym, q, now);
        if (!x) return null;
        const pre = Markets.marketState(q, now) === "pre";
        const t = [], c = [], v = [];
        const add = function (part) {
            if (!part) return;
            for (let i = 0; i < part.t.length; i++) { t.push(part.t[i]); c.push(part.c[i]); v.push(0); }
        };
        add(x.pre);
        if (!pre) {
            const fx = root._parsed("chart_" + root.slug(sym) + "_1D", Markets.parseChart);
            const reg = fx ? root._cut(fx, now, q) : (q.spark || { t: [], c: [] });
            for (let i = 0; i < reg.t.length; i++)
                if (reg.t[i] >= x.periods.start && reg.t[i] < x.periods.end) {
                    t.push(reg.t[i]); c.push(reg.c[i]); v.push(reg.v ? reg.v[i] || 0 : 0);
                }
            add(x.post);
        }
        if (t.length === 0) return null;
        return { state: "ready", error: "", symbol: sym, range: "1D", t: t, o: c, h: c, l: c, c: c,
                 v: v, prevClose: q.prevClose, meta: q, periods: x.periods,
                 dividends: [], splits: [] };
    }

    // A symbol the mock has no quote for with a captured day in `r6/` (Bpost:
    // a thin stock, 6 of its 20 bars without a trade): that day moved onto
    // the capture's, as a search result's detail.
    function _r6Day(sym) {
        const ch = root._parsed("r6/chart_" + root.slug(sym) + "_1D", Markets.parseChart);
        if (!ch || !ch.periods || ch.t.length === 0) return null;
        const DAY = 86400000, off = (ch.meta.gmtoffset || 0) * 1000;
        const dayOf = function (ms) { return Math.floor((ms + off) / DAY); };
        const shift = (dayOf(root._captureMs) - dayOf(ch.periods.start)) * DAY;
        const mv = function (v) { return typeof v === "number" ? v + shift : v; };
        const meta = Object.assign({}, ch.meta, {
            timeMs: mv(ch.meta.timeMs),
            session: { preStart: mv(ch.meta.session.preStart), start: mv(ch.meta.session.start),
                       end: mv(ch.meta.session.end), postEnd: mv(ch.meta.session.postEnd) }
        });
        meta.state = Markets.marketState(meta, root.nowMs);
        return Object.assign({}, ch, {
            state: "ready", error: "", range: "1D", meta: meta, t: ch.t.map(mv),
            periods: { preStart: mv(ch.periods.preStart), start: mv(ch.periods.start),
                       end: mv(ch.periods.end), postEnd: mv(ch.periods.postEnd) }
        });
    }

    // A 1D/5D fixture cut at `now`, continued with the quote's own walk.
    function _cut(ch, now, q) {
        const out = { symbol: ch.symbol, prevClose: ch.prevClose, meta: q || ch.meta,
                      dividends: ch.dividends || [], splits: ch.splits || [],
                      t: [], o: [], h: [], l: [], c: [], v: [] };
        for (let i = 0; i < ch.t.length; i++) {
            if (ch.t[i] > now) break;
            out.t.push(ch.t[i]); out.o.push(ch.o[i]); out.h.push(ch.h[i]);
            out.l.push(ch.l[i]); out.c.push(ch.c[i]); out.v.push(ch.v[i]);
        }
        const last = out.t.length > 0 ? out.t[out.t.length - 1] : 0;
        if (q && q.spark) for (let i = 0; i < q.spark.t.length; i++) {
            if (q.spark.t[i] <= last) continue;
            const v = q.spark.c[i];
            out.t.push(q.spark.t[i]); out.o.push(v); out.h.push(v); out.l.push(v); out.c.push(v); out.v.push(0);
        }
        return out;
    }

    // A daily range from the history: 1M 6M YTD 1Y daily, 5Y weekly, MAX monthly.
    function _slice(h, range, now) {
        const d = new Date(now);
        let from = 0;
        if (range === "1M") from = new Date(d.getFullYear(), d.getMonth() - 1, d.getDate()).getTime();
        else if (range === "6M") from = new Date(d.getFullYear(), d.getMonth() - 6, d.getDate()).getTime();
        else if (range === "YTD") from = new Date(d.getFullYear(), 0, 1).getTime();
        else if (range === "1Y") from = new Date(d.getFullYear() - 1, d.getMonth(), d.getDate()).getTime();
        else if (range === "5Y") from = new Date(d.getFullYear() - 5, d.getMonth(), d.getDate()).getTime();
        const bucket = range === "5Y" ? function (t) { return Math.floor((t / 86400000 + 3) / 7); }
                     : range === "MAX" ? function (t) { const x = new Date(t); return x.getFullYear() * 12 + x.getMonth(); }
                     : null;
        const out = { symbol: h.symbol, meta: h.meta, t: [], o: [], h: [], l: [], c: [], v: [], prevClose: null,
                      dividends: (h.dividends || []).filter(function (e) { return e.t >= from; }),
                      splits: (h.splits || []).filter(function (e) { return e.t >= from; }) };
        for (let i = 0; i < h.t.length; i++) {
            if (h.t[i] > now) break;
            if (h.t[i] < from) { out.prevClose = h.c[i]; continue; }
            if (bucket && out.t.length > 0 && bucket(out.t[out.t.length - 1]) === bucket(h.t[i])) {
                const k = out.t.length - 1;
                out.t[k] = h.t[i]; out.c[k] = h.c[i];
                out.h[k] = Math.max(out.h[k], h.h[i]); out.l[k] = Math.min(out.l[k], h.l[i]);
                out.v[k] += h.v[i] || 0;
                continue;
            }
            out.t.push(h.t[i]); out.o.push(h.o[i]); out.h.push(h.h[i]);
            out.l.push(h.l[i]); out.c.push(h.c[i]); out.v.push(h.v[i] || 0);
        }
        return out;
    }

    // ---- alerts -----------------------------------------------------------------------
    function _pushOverAlert(quotes, cfg) {
        const a = (cfg.alerts || []).filter(function (x) { return x.above !== null && quotes[x.symbol]; })[0];
        if (!a) return;
        const q = Object.assign({}, quotes[a.symbol]);
        q.price = a.above * 1.004;
        q.change = q.price - q.prevClose;
        q.changePct = q.change / q.prevClose * 100;
        const c = q.spark.c.slice();
        if (c.length > 0) c[c.length - 1] = q.price;
        q.spark = { t: q.spark.t, c: c };
        quotes[a.symbol] = q;
    }

    function _fireAlerts(push) {
        const cfg = root._config;
        let quotes = root._quotes;
        if (push) { quotes = Object.assign({}, quotes); root._pushOverAlert(quotes, cfg); }
        const now = root.nowMs;
        const dayKey = function (q) { return Markets.dayKey(q.timeMs || now, q.gmtoffset); };
        const r = Markets.evalAlerts(cfg.alerts || [], quotes, {}, cfg.alertHysteresis, dayKey);
        const fire = r && r.fire ? r.fire : [];
        root._firedAlerts = fire;
        vm.notifyAlerts(fire, quotes, root.notifier, { body: root.alertBody, nowMs: now, label: function (sym) {
            const h = (cfg.holdings || []).filter(function (x) { return x.symbol === sym; })[0];
            return h ? (h.label || h.alias || sym) : sym;
        } });
    }
}
