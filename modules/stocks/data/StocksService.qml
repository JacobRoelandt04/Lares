pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Markets.js" as Markets
import "Portfolio.js" as Portfolio

// =============================================================================
// StocksService.qml -- quotes, history, FX, HICP, the portfolio, the rows.
//
// The contract is docs/stocks.md ("StocksService"); StocksMock has the
// same members. Everything is computed by Markets.js / Portfolio.js; this file
// decides WHEN to fetch, keeps the caches and turns answers into snapshots.
//
// Cadence (Markets.nextFetchDelay): any held / watched / index market open ->
// spark every refreshSec.open (60 s) with the popup open, refreshSec.closed (5 min) shut; all closed -> one fetch
// at the last close + 2 min, then idle until the predicted next open (6 h
// cap); opening the popup over a cache older than 30 min fetches at once. A
// 60 s tick keeps `nowMs`; a tick that arrives more than 5 min late is a
// suspend and refreshes. 429 -> `rateLimited`, backoff 2 min doubling to 1 h,
// the cache stays painted. History (per held / closed symbol and FX pair):
// once from the first action - 7 days, then daily from the last day cached -
// 7 days, merged. HICP at most daily. Detail chart on open / range change,
// every 60 s for 1D / 5D while the popup is open. CNBC on detail open when
// older than 5 min (a market open) / 6 h. The summary's 5D (the 5d spark of the
// holdings and their FX pairs) ONLY while it is shown -- summaryRange "5D" and
// the popup open: on selection, then with every spark while a held market is
// open (older than 55 s); over closed markets once after the last close.
// `summaryLoading` is true until the first 5D data lands (or its fetch fails).
// Extended hours: a listing with them (US) that is not in its regular session
// gets a second spark WITH them after every spark, and on its own every 60 s
// (popup open) / 5 min while one is in pre- or post-market -- only its `ext`
// is kept (during pre-market that answer has no regular point: it is not the
// day's spark). `extended` is what is shown now (Markets.extVisible); the 1D
// detail chart of such a listing is asked with its extended hours.
//
// Caches: $XDG_CACHE_HOME/lares/stocks/{spark.json, spark5d.json, ext.json, history/<slug>.json,
// fx/<CODE>.json, hicp-<geo>.json, charts/<slug>_<RANGE>.json, logos/}, each
// { savedAtMs, data } (data parsed), one FileView per path created once and
// never repointed (CLAUDE.md), read stale-first: the cache paints before any
// fetch and `stale` stays true until a fetch lands.
// =============================================================================
Item {
    id: root

    // ---- status ---------------------------------------------------------------
    property bool popupOpen: false
    readonly property bool loading: root._portfolio === null && Object.keys(root._quotes).length === 0
    property bool offline: false
    property bool stale: true
    property bool rateLimited: false
    property real retryAtMs: 0
    property string lastError: ""
    // The stocks.jsonc part of lastError alone (a parse error or a value out of range); the last good portfolio stays in force.
    readonly property string configError: cfg.lastError
    property real fetchedAtMs: 0
    property real nowMs: Date.now()
    readonly property var config: cfg.config
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/stocks.jsonc"
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/stocks/state.json"
    property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/lares/stocks"
    property string curl: "curl"
    property string python: "python3"
    property bool dryRun: false
    signal updated()
    signal urlOpened(string url)
    function refresh() {
        root._backoffMs = 0;
        root._fetchSpark();
        root._fetchSlow();
    }

    // ---- snapshots ------------------------------------------------------------
    readonly property var quotes: root._quotes
    // { SYM: { kind: "pre" | "post", price, base, change, changePct, timeMs } }
    readonly property var extended: root._extShown
    readonly property var portfolio: root._portfolio
    readonly property var daySpark: root._daySpark
    readonly property var summarySeries: root._summarySeries
    readonly property bool summaryLoading: st.summaryRange === "5D" && root._spark5d === null && !root._spark5dFailed

    // ---- rows -----------------------------------------------------------------
    readonly property ListModel holdingRows: vm.holdingRows
    readonly property ListModel watchRows: vm.watchRows
    readonly property ListModel closedRows: vm.closedRows
    readonly property ListModel searchRows: vm.searchRows
    readonly property ListModel indexRows: vm.indexRows
    property alias sortKey: st.sortKey
    property alias sortAscending: st.sortAscending
    // Today's regular session at 1-minute bars for one symbol (a sudden-move card sharpens its span with it):
    // cb({ t, c }) or cb(null) on any failure. ONE request, never retried, on a lane of its own: a 429 does NOT
    // step the cadence's backoff (it would delay every price for a nicety), and while the service is itself rate-limited
    // none is asked at all.
    function fineSpark(sym, cb) {
        if (root.rateLimited || !sym) { cb(null); return; }
        yahoo.fineSpark(sym, Date.now(), function (e, sp) { cb(e ? null : sp); });
    }

    // One re-sort for the pair; `ascending` left out = the key's own
    // direction (name A-Z, the figures largest first).
    function setSort(key, ascending) {
        if (st.sortKeys.indexOf(key) < 0) return;
        root._sortGuard = true;
        st.sortKey = key;
        st.sortAscending = ascending === undefined || ascending === null ? key === "name" : !!ascending;
        root._sortGuard = false;
        root._rows();
    }
    property alias tab: st.tab
    property alias closedExpanded: st.closedExpanded
    property alias summaryRange: st.summaryRange
    property alias detailRange: st.detailRange

    // ---- watchlist ------------------------------------------------------------
    readonly property var watchlist: st.watchlist
    function isWatched(sym) { return st.watchlist.indexOf(sym) >= 0; }
    function toggleWatch(sym) {
        const w = st.watchlist.slice();
        const i = w.indexOf(sym);
        if (i >= 0) w.splice(i, 1);
        else w.push(sym);
        st.watchlist = w;
        if (i < 0 && !root._quotes[sym]) root._fetchSpark();
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
        root._searchGen++;
        root.searchQuery = "";
        root._searchBusy = false;
        vm.clearSearch();
    }

    // ---- detail ---------------------------------------------------------------
    // A READ, nothing else: bindings call it (the detail's `chart`). Asking for
    // a chart is loadChart()'s job -- it reads a cache file and starts a
    // process, and a fetch can answer synchronously (rate-limited), bumping
    // chartSerial inside the very binding that reads it: the binding loop on
    // StockDetail.chart.
    function chart(sym, range) {
        if (!sym || !range) return null;
        return root._charts[sym + "|" + range] || null;
    }
    // Whether a fresher answer for this chart is on its way (the detail holds a click's morph for it).
    function chartPending(sym, range) {
        return root._chartAsked[sym + "|" + range] === true;
    }
    // Stale-first: the disk cache paints at once, the fetch refreshes it.
    function loadChart(sym, range, background) {
        if (!sym || !range) return;
        const key = sym + "|" + range;
        if (!root._charts[key]) {
            const disk = root._readCache("charts/" + root.slug(sym) + "_" + range + ".json");
            root._charts[key] = disk && disk.data
                ? Object.assign({}, disk.data, { state: "ready", error: "", stale: true, savedAtMs: disk.savedAtMs })
                : { state: "loading", symbol: sym, range: range, error: "" };
            root.chartSerial++;
        }
        root._fetchChart(sym, range, background);
    }
    function stats(sym) {
        const q = root._quotes[sym] || root._searchQuotes[sym];
        if (!q) return null;
        const cn = root._cnbc[root._cnbcSym(sym)] || null;
        const c1 = root._charts[sym + "|1D"];
        let open = null;
        if (c1 && c1.o) for (let i = 0; i < c1.o.length && open === null; i++)
            if (typeof c1.o[i] === "number") open = c1.o[i];
        if (open === null && q.spark && q.spark.c && q.spark.c.length > 0) open = q.spark.c[0];
        const n = function (v) { return typeof v === "number" && isFinite(v) ? v : null; };
        return {
            open: open, high: n(q.dayHigh), low: n(q.dayLow), prevClose: n(q.prevClose),
            volume: n(q.volume), w52Lo: n(q.w52Lo), w52Hi: n(q.w52Hi),
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
        const another = !root._detail || root._detail.symbol !== sym;
        root._detail = { symbol: sym, range: range };
        if (range) st.detailRange = range;
        root.loadChart(sym, range);
        root._fetchCnbc(sym);
        logos.want(sym, true, root._logoOpts(sym));
        if (another) {
            root._prefetchLeft = Markets.RANGE_KEYS.filter(r => r !== range);
            prefetch.interval = root.prefetchDelayMs;
            prefetch.restart();
        }
    }
    function unwatchDetail() {
        root._detail = null;
        prefetch.stop();
    }
    // A detail that stays open has every range to hand, so a click on a chip has a fresh chart and one morph.
    // Once per detail and range: `_fetchChart` keeps its own freshness window, the queue its dedupe. One at a
    // time behind what someone waits on, and only after the detail has stayed: a flick through the rows asks for nothing it does not show.
    property int prefetchDelayMs: 900
    property int prefetchGapMs: 250
    property var _prefetchLeft: []
    Timer {
        id: prefetch
        repeat: true
        onTriggered: root._prefetchNext()
    }
    function _prefetchNext() {
        const d = root._detail;
        if (!d || root.rateLimited || root._prefetchLeft.length === 0) {
            prefetch.stop();
            return;
        }
        prefetch.interval = root.prefetchGapMs;
        if (!yahoo.fgBusy)
            root.loadChart(d.symbol, root._prefetchLeft.shift(), true);
    }
    property int chartSerial: 0
    property int statsSerial: 0

    // ---- logos ----------------------------------------------------------------
    function logoFor(sym, px) { return logos.logoFor(sym, px); }
    function wantLogo(sym, priority) { logos.want(sym, priority, root._logoOpts(sym)); }
    readonly property int logoSerial: logos.serial

    function openQuote(sym) {
        const url = Markets.quoteUrl(sym, cfg.config.quoteUrl);
        if (!root.dryRun) Qt.openUrlExternally(url);
        root.urlOpened(url);
    }
    property var notifier: null
    // The StockMoveBody component an alert card draws its day with (the shell hands it in; null: the words alone).
    property var alertBody: null
    signal alertOpenRequested(string symbol)
    // The notification keys alerts use: the owner's DesktopNotifier lists them.
    readonly property var alertKeys: vm.alertKeys

    // =========================================================================
    // Private
    // =========================================================================
    property var _quotes: ({})
    property var _portfolio: null
    property var _daySpark: null
    property var _summarySeries: null
    property var _input: null
    property var _history: ({})          // SYM -> Chart
    property var _fx: ({})               // CODE -> Chart (the <CODE>EUR=X daily history)
    property var _hicp: ({})
    property var _cnbc: ({})             // cnbcSym -> row
    property var _cnbcAt: ({})           // cnbcSym -> ms
    property var _charts: ({})
    property var _chartAt: ({})
    property var _detail: null
    property var _searchQuotes: ({})
    property bool _searchBusy: false
    property int _searchGen: 0
    property var _searchLru: []          // [{ q, atMs, results }]
    property real _lastSparkMs: 0
    property real _sparkSavedMs: 0
    property real _backoffMs: 0
    property var _slowDoneDay: ({})      // key -> day fetched
    property var _caches: ({})           // path -> FileView
    property bool _dirReady: false
    property real _expectedTickMs: 0
    property real _nextFetchAtMs: 0      // for the probe: when the spark timer fires
    property var _spark5d: null          // { SYM: Quote } the 5d spark, cache or fetch
    property real _spark5dAt: 0          // the last 5d FETCH of this run (0: cache only)
    property bool _spark5dBusy: false
    property bool _spark5dFailed: false
    property bool _sortGuard: false

    StocksConfig { id: cfg; configPath: root.configPath }
    StocksState { id: st; statePath: root.statePath }
    StocksViewModel { id: vm }
    StockLogos { id: logos; dir: root.cacheDir + "/logos"; python: root.python }
    YahooSource { id: yahoo; curl: root.curl; onRateLimited: root._onRateLimited() }
    CnbcSource { id: cnbc; curl: root.curl; onRateLimited: root._onRateLimited() }
    HicpSource { id: hicp; curl: root.curl }

    Component {
        id: cacheViewComp
        FileView { blockLoading: true; atomicWrites: true; printErrors: false; watchChanges: false }
    }

    Process {
        id: mkdirProc
        running: false
        command: ["mkdir", "-p", root.cacheDir + "/history", root.cacheDir + "/fx",
                  root.cacheDir + "/charts", root.cacheDir + "/logos"]
    }
    Connections {
        target: mkdirProc
        function onExited() { root._dirReady = true; root._fetchSpark(); root._fetchSlow(); }
    }

    Timer { id: sparkTimer; onTriggered: root._fetchSpark() }
    // The quotes' cadence while a market is open, with the popup open and shut (stocks.jsonc refreshSec, never under its floors);
    // what is fetched with them (the extended move, the summary's 5D, a 1D / 5D chart) is fresh for that long less a few seconds.
    readonly property real _openMs: cfg.config.refreshSec.open * 1000
    readonly property real _closedMs: cfg.config.refreshSec.closed * 1000
    Timer {
        id: extTimer
        interval: root.popupOpen ? root._openMs : root._closedMs
        repeat: true
        running: root._extLive && !root.rateLimited && cfg.config.extendedHours
        onTriggered: root._fetchExt(false)
    }
    Timer { id: searchTimer; interval: 300; onTriggered: root._runSearch() }
    Timer { id: computeTimer; interval: 0; onTriggered: root._compute() }
    Timer {
        id: tick
        interval: 60000
        repeat: true
        running: true
        onTriggered: root._tick()
    }

    Connections {
        target: cfg
        function onConfigChanged() { root._loadCaches(); root._schedule(); root._fetchSlow(); root._updateExt(); }
        function onLastErrorChanged() { root._composeError(); }
    }
    Connections {
        target: root.notifier
        ignoreUnknownSignals: true
        function onAction(key, id) {
            const sym = vm.alertSymbol(key);
            if (sym && id === "open") root.alertOpenRequested(sym);
        }
    }
    onWatchlistChanged: root._rows()
    onSortKeyChanged: if (!root._sortGuard) root._rows()
    onSortAscendingChanged: if (!root._sortGuard) root._rows()
    onSummaryRangeChanged: { root._series(); root._want5d(); }
    onPopupOpenChanged: {
        if (!root.popupOpen) return;
        root._schedule();
        root._fetchSlow();
        root._want5d();
    }

    Component.onCompleted: {
        root._expectedTickMs = Date.now() + tick.interval;
        root._loadCaches();
        mkdirProc.running = true;
    }

    // The holding's own label (an alias), else the symbol: an alert card's title.
    function _labelOf(sym) {
        const h = (cfg.config.holdings || []).filter(function (x) { return x.symbol === sym; })[0];
        return h ? (h.label || h.alias || sym) : sym;
    }
    function slug(sym) { return String(sym).replace(/[^A-Za-z0-9.\-]/g, "_"); }

    // ---- symbols ------------------------------------------------------------------
    function _holdingSyms() { return (cfg.config.holdings || []).map(function (h) { return h.symbol; }); }
    function _fxCodes() {
        const codes = [];
        const hs = root._holdingSyms();
        for (let i = 0; i < hs.length; i++) {
            const q = root._quotes[hs[i]];
            if (!q) continue;
            const c = Markets.normCurrency(q.currency).code;
            if (c && c !== "EUR" && codes.indexOf(c) < 0) codes.push(c);
        }
        return codes;
    }
    function _sparkSyms() {
        const out = root._holdingSyms().concat(st.watchlist);
        const idx = cfg.config.indices || [];
        for (let i = 0; i < idx.length; i++) out.push(idx[i].symbol);
        const fx = root._fxCodes();
        for (let i = 0; i < fx.length; i++) out.push(Markets.fxSymbol(fx[i]));
        return out;
    }
    function _cnbcSym(sym) {
        const h = (cfg.config.holdings || []).filter(function (x) { return x.symbol === sym; })[0];
        return Markets.cnbcSymbol(sym, h && h.cnbc ? h.cnbc : "") || "";
    }
    function _logoOpts(sym) {
        const h = (cfg.config.holdings || []).filter(function (x) { return x.symbol === sym; })[0];
        return h ? { isin: h.isin, image: h.image } : {};
    }

    // ---- caches -------------------------------------------------------------------
    function _cacheView(rel) {
        const path = root.cacheDir + "/" + rel;
        let v = root._caches[path];
        if (!v) {
            v = cacheViewComp.createObject(root, { path: path });
            root._caches[path] = v;
        }
        return v;
    }
    function _readCache(rel) {
        const v = root._cacheView(rel);
        v.reload();
        let o = null;
        try { o = JSON.parse(v.text() || "null"); } catch (x) { o = null; }
        return o && typeof o === "object" && "data" in o ? o : null;
    }
    function _writeCache(rel, data) {
        if (!root._dirReady) return;
        root._cacheView(rel).setText(JSON.stringify({ savedAtMs: Date.now(), data: data }));
    }

    // Stale-first: everything cached paints before anything is fetched.
    function _loadCaches() {
        const sp = root._readCache("spark.json");
        if (sp && Object.keys(root._quotes).length === 0) {
            root._quotes = sp.data || {};
            root._sparkSavedMs = sp.savedAtMs;
            root.fetchedAtMs = sp.savedAtMs;
            root.stale = true;
        }
        const hs = root._holdingSyms();
        const hist = Object.assign({}, root._history);
        for (let i = 0; i < hs.length; i++) {
            if (hist[hs[i]]) continue;
            const c = root._readCache("history/" + root.slug(hs[i]) + ".json");
            if (c) hist[hs[i]] = c.data;
        }
        root._history = hist;
        const fx = Object.assign({}, root._fx);
        const codes = root._fxCodes();
        for (let i = 0; i < codes.length; i++) {
            if (fx[codes[i]]) continue;
            const c = root._readCache("fx/" + codes[i] + ".json");
            if (c) fx[codes[i]] = c.data;
        }
        root._fx = fx;
        const hc = root._readCache("hicp-" + cfg.config.inflation.geo + ".json");
        if (hc) root._hicp = hc.data || {};
        const ex = root._readCache("ext.json");
        if (ex && Object.keys(root._ext).length === 0) {
            root._ext = ex.data || {};
            root._extShown = cfg.config.extendedHours ? Markets.extVisible(root._ext, root._quotes, root.nowMs) : {};
        }
        const s5 = root._spark5d === null ? root._readCache("spark5d.json") : null;
        if (s5 && s5.data) root._spark5d = s5.data;
        computeTimer.restart();
    }

    // ---- the cadence ----------------------------------------------------------------
    function _schedule() {
        if (root.rateLimited) return;
        const d = Markets.nextFetchDelay({
            quotes: root._quotes, nowMs: Date.now(), popupOpen: root.popupOpen,
            lastFetchMs: root._lastSparkMs, openMs: root._openMs, closedMs: root._closedMs
        });
        sparkTimer.interval = Math.max(0, Math.min(d, 6 * 3600000));
        sparkTimer.restart();
        root._nextFetchAtMs = Date.now() + sparkTimer.interval;
    }

    function _tick() {
        const now = Date.now();
        const late = now - root._expectedTickMs;
        root._expectedTickMs = now + tick.interval;
        root.nowMs = now;
        root._updateExt();
        if (late > 5 * 60000) { root.refresh(); return; }
        if (root.popupOpen && root._detail && (root._detail.range === "1D" || root._detail.range === "5D"))
            root._fetchChart(root._detail.symbol, root._detail.range);
        root._fetchSlow();
    }

    // lastError is composed from its three sources, so one clearing clears it:
    // the config's own, the network's (offline / 429 / a slow fetch), the
    // portfolio engine's.
    property string _netError: ""
    function _composeError() {
        const p = root._portfolio;
        const parts = [cfg.lastError, root._netError, p && p.errors ? p.errors.join("; ") : ""];
        root.lastError = parts.filter(function (x) { return x; }).join("; ");
    }

    // One backoff step per attempt: the other requests of the same burst
    // answering 429 too do not double it again.
    function _onRateLimited() {
        if (root.rateLimited && Date.now() < root.retryAtMs) return;
        root._backoffMs = root._backoffMs > 0 ? Math.min(root._backoffMs * 2, 3600000) : 2 * 60000;
        root.rateLimited = true;
        root.retryAtMs = Date.now() + root._backoffMs;
        root._netError = "Yahoo is rate-limiting (HTTP 429): retrying at "
            + Qt.formatTime(new Date(root.retryAtMs), "HH:mm");
        root._composeError();
        sparkTimer.interval = root._backoffMs;
        sparkTimer.restart();
        root._nextFetchAtMs = root.retryAtMs;
    }

    // ---- the extended hours ------------------------------------------------------------
    property var _ext: ({})
    property var _extShown: ({})
    property real _lastExtMs: 0
    // Is any listing we show in its pre- or post-market (the ext timer's gate)?
    readonly property bool _extLive: {
        const now = root.nowMs;
        return Markets.extSymbols(root._sparkSyms(), root._quotes, now).some(function (s) {
            const st = Markets.marketState(root._quotes[s], now);
            return st === "pre" || st === "post";
        });
    }
    function _updateExt() {
        const next = cfg.config.extendedHours ? Markets.extVisible(root._ext, root._quotes, root.nowMs) : {};
        if (JSON.stringify(next) === JSON.stringify(root._extShown)) return;
        root._extShown = next;
        root._rows();
    }
    // After every spark (at most one a 50 s) and on its own timer; an answer
    // that fails is left alone -- the extended move is extra, never a state.
    function _fetchExt(force) {
        if (!cfg.config.extendedHours) return;
        const now = Date.now();
        if (!force && now - root._lastExtMs < root._openMs * 5 / 6) return;
        const syms = Markets.extSymbols(root._sparkSyms(), root._quotes, now);
        if (syms.length === 0) { root._updateExt(); return; }
        root._lastExtMs = now;
        yahoo.spark(syms, now, function (e, quotes) {
            if (e) return;
            const next = Object.assign({}, root._ext);
            for (const s in quotes)
                if (quotes[s].ext) next[s] = quotes[s].ext;
            root._ext = next;
            root._writeCache("ext.json", next);
            root._updateExt();
        }, "1D", true);
    }

    function _fetchSpark() {
        if (!root._dirReady) return;
        const syms = root._sparkSyms();
        if (syms.length === 0) { root._lastSparkMs = Date.now(); root.stale = false; computeTimer.restart(); return; }
        yahoo.spark(syms, Date.now(), function (e, quotes) {
            if (e === "429") return;                  // _onRateLimited has it
            if (e) {
                root.offline = true;
                root.stale = true;
                root._netError = "offline: " + e;
                root._composeError();
                sparkTimer.interval = 2 * 60000;
                sparkTimer.restart();
                return;
            }
            const now = Date.now();
            root.offline = false;
            root.rateLimited = false;
            root.retryAtMs = 0;
            root._backoffMs = 0;
            root._netError = "";
            root._lastSparkMs = now;
            root.fetchedAtMs = now;
            root.stale = false;
            const merged = Object.assign({}, root._quotes, quotes);
            root._quotes = merged;
            root._writeCache("spark.json", merged);
            // The FX pairs are known only once the quotes say which currencies
            // are held: a first fetch without them asks for them at once.
            const missing = root._fxCodes().map(function (c) { return Markets.fxSymbol(c); })
                .filter(function (s) { return !merged[s]; });
            if (missing.length > 0) yahoo.spark(missing, now, function (e2, fxq) {
                if (e2) return;
                root._quotes = Object.assign({}, root._quotes, fxq);
                root._writeCache("spark.json", root._quotes);
                root._fetchSlow();
                computeTimer.restart();
            });
            root._alerts();
            root._fetchSlow();                   // a new FX currency may have appeared
            computeTimer.restart();
            root._schedule();
            root._want5d();
            root._fetchExt(false);
        });
    }

    // ---- the summary's 5D -------------------------------------------------------------
    // Every holding held now or closed in the last 7 days (config order), then
    // their FX pairs: exactly the captured request (urls.tsv, spark_5d.json).
    function _syms5d() {
        const p = root._portfolio;
        if (!p || !p.holdings) return [];
        const now = Date.now();
        const recent = Markets.addDays(Markets.dayKey(now, -new Date(now).getTimezoneOffset() * 60), -7);
        const keep = {};
        p.holdings.forEach(function (h) { keep[h.symbol] = true; });
        (p.closed || []).forEach(function (h) { if (h.closedOn >= recent) keep[h.symbol] = true; });
        const syms = root._holdingSyms().filter(function (s) { return keep[s]; });
        const fx = [];
        for (let i = 0; i < syms.length; i++) {
            const q = root._quotes[syms[i]];
            const code = q ? Markets.normCurrency(q.currency).code : "";
            if (code && code !== "EUR" && fx.indexOf(code) < 0) fx.push(code);
        }
        return syms.concat(fx.map(function (c) { return Markets.fxSymbol(c); }));
    }
    // Shown, not fetched this run, or stale: a held market open and 55 s old,
    // or all closed and fetched before the last close had settled (2 min).
    function _want5d() {
        if (st.summaryRange !== "5D" || !root.popupOpen || root.rateLimited || root._spark5dBusy || !root._dirReady) return;
        const syms = root._syms5d();
        if (syms.length === 0) return;                // no portfolio yet: _compute calls again
        const now = Date.now();
        if (root._spark5dAt > 0) {
            let open = false, closed = -Infinity;
            for (let i = 0; i < syms.length; i++) {
                const q = root._quotes[syms[i]];
                if (!q || !Markets.isMarketType(q) || !q.session || typeof q.session.end !== "number") continue;
                if (Markets.marketState(q, now) === "open") open = true;
                closed = Math.max(closed, Markets.lastClose(q, now));
            }
            if (open ? now - root._spark5dAt < root._openMs - 5000 : root._spark5dAt >= closed + 120000) return;
        }
        root._spark5dBusy = true;
        root._spark5dFailed = false;
        yahoo.spark(syms, now, function (e, quotes) {
            root._spark5dBusy = false;
            if (e) { root._spark5dFailed = true; return; }   // a 429 is _onRateLimited's
            root._spark5d = quotes;
            root._spark5dAt = Date.now();
            root._writeCache("spark5d.json", quotes);
            root._series();
        }, "5D");
    }

    // History, FX history and HICP: once a day each.
    function _fetchSlow() {
        if (!root._dirReady || root.rateLimited) return;
        const now = Date.now();
        const today = Markets.dayKey(now, -new Date(now).getTimezoneOffset() * 60);
        const due = function (key) { return root._slowDoneDay[key] !== today; };
        const mark = function (key) { const m = Object.assign({}, root._slowDoneDay); m[key] = today; root._slowDoneDay = m; };
        const hs = cfg.config.holdings || [];
        for (let i = 0; i < hs.length; i++) {
            const h = hs[i];
            if (!due("h|" + h.symbol) || h.actions.length === 0) continue;
            // Incremental only over a cache that reaches back to the first
            // action (an edit may have added an older one).
            const cached = root._history[h.symbol];
            const first = h.actions.map(function (a) { return a.date; }).sort()[0];
            const cacheOk = cached && cached.t && cached.t.length > 0 && Markets.dayKey(cached.t[0], 0) <= first;
            const from = cacheOk ? Markets.addDays(Markets.dayKey(cached.t[cached.t.length - 1], 0), -7)
                                 : Markets.addDays(first, -7);
            mark("h|" + h.symbol);
            yahoo.history(h.symbol, from, now, function (e, c) {
                if (e) { root._slowFailed("h|" + h.symbol, e); return; }
                const m = root._merge(cacheOk ? root._history[h.symbol] : null, c);
                const hist = Object.assign({}, root._history);
                hist[h.symbol] = m;
                root._history = hist;
                root._writeCache("history/" + root.slug(h.symbol) + ".json", m);
                computeTimer.restart();
            });
        }
        const codes = root._fxCodes();
        const firstAll = hs.reduce(function (acc, h) {
            const d = h.actions.map(function (a) { return a.date; }).sort()[0];
            return d && (!acc || d < acc) ? d : acc;
        }, "");
        for (let i = 0; i < codes.length; i++) {
            const code = codes[i];
            if (!due("fx|" + code) || !firstAll) continue;
            mark("fx|" + code);
            const cached = root._fx[code];
            const cacheOk = cached && cached.t && cached.t.length > 0 && Markets.dayKey(cached.t[0], 0) <= firstAll;
            const from = cacheOk ? Markets.addDays(Markets.dayKey(cached.t[cached.t.length - 1], 0), -7) : Markets.addDays(firstAll, -7);
            yahoo.history(Markets.fxSymbol(code), from, now, function (e, c) {
                if (e) { root._slowFailed("fx|" + code, e); return; }
                const m = root._merge(cacheOk ? root._fx[code] : null, c);
                const fx = Object.assign({}, root._fx);
                fx[code] = m;
                root._fx = fx;
                root._writeCache("fx/" + code + ".json", m);
                computeTimer.restart();
            });
        }
        const geo = cfg.config.inflation.geo;
        if (due("hicp|" + geo) && hs.length > 0) {
            mark("hicp|" + geo);
            hicp.hicp(geo, function (e, m) {
                if (e) { root._slowFailed("hicp|" + geo, e); return; }
                root._hicp = m;
                root._writeCache("hicp-" + geo + ".json", m);
                computeTimer.restart();
            });
        }
    }
    function _slowFailed(key, e) {
        const m = Object.assign({}, root._slowDoneDay);
        delete m[key];                                // retried on the next tick
        root._slowDoneDay = m;
        if (e !== "429" && !root._netError) { root._netError = key.split("|")[1] + ": " + e; root._composeError(); }
    }

    // An incremental answer over the cached series: cached points before the
    // new first day are kept, the rest replaced; events merged by time.
    function _merge(old, c) {
        if (!old || !old.t || old.t.length === 0) return c;
        const first = c.t.length > 0 ? c.t[0] : Infinity;
        const out = { symbol: c.symbol, range: c.range, prevClose: old.prevClose, meta: c.meta,
                      t: [], o: [], h: [], l: [], c: [], v: [] };
        const keys = ["t", "o", "h", "l", "c", "v"];
        for (let i = 0; i < old.t.length && old.t[i] < first; i++)
            for (let k = 0; k < keys.length; k++) out[keys[k]].push(old[keys[k]][i]);
        for (let i = 0; i < c.t.length; i++)
            for (let k = 0; k < keys.length; k++) out[keys[k]].push(c[keys[k]][i]);
        const ev = function (a, b) {
            const seen = {}, r = [];
            (a || []).concat(b || []).forEach(function (e) { if (!seen[e.t]) { seen[e.t] = true; r.push(e); } });
            return r.sort(function (x, y) { return x.t - y.t; });
        };
        out.dividends = ev(old.dividends, c.dividends);
        out.splits = ev(old.splits, c.splits);
        return out;
    }

    // ---- the portfolio --------------------------------------------------------------
    function _compute() {
        const c = cfg.config;
        const fx = {};
        const codes = root._fxCodes();
        for (let i = 0; i < codes.length; i++) {
            const fq = root._quotes[Markets.fxSymbol(codes[i])];
            fx[codes[i]] = { hist: root._fx[codes[i]] || null, now: fq ? fq.price : null,
                             prev: fq ? fq.prevClose : null, spark: fq ? fq.spark : { t: [], c: [] } };
        }
        const input = { nowMs: Date.now(), withholding: c.dividendWithholding, holdings: c.holdings,
                        quotes: root._quotes, history: root._history, fx: fx, hicp: root._hicp };
        let p = null;
        if (Object.keys(root._quotes).length > 0) {
            try { p = Portfolio.compute(input); }
            catch (x) { p = { errors: ["portfolio: " + x] }; }
            if (p && !p.holdings) { root._portfolio = null; root._netError = p.errors[0]; root._composeError(); return; }
        }
        root._input = input;
        root._portfolio = p;
        root._daySpark = p ? Portfolio.intradayValue(input, p) : null;
        root._series();
        root._want5d();
        root._rows();
        root._composeError();
        const syms = root._holdingSyms().concat(st.watchlist);
        for (let i = 0; i < syms.length; i++) logos.want(syms[i], false, root._logoOpts(syms[i]));
        root.updated();
    }
    function _series() {
        const r = st.summaryRange;
        if (!root._input || !root._portfolio || (r === "5D" && root._spark5d === null)) {
            root._summarySeries = null;
            return;
        }
        const input = r === "5D" ? Object.assign({}, root._input, { spark5d: root._spark5d }) : root._input;
        root._summarySeries = Portfolio.valueSeries(input, root._portfolio, r);
    }
    function _rows() {
        vm.build({ portfolio: root._portfolio, quotes: root._quotes, ext: root._extShown, watchlist: st.watchlist,
                   indices: cfg.config.indices, sortKey: st.sortKey, sortAscending: st.sortAscending,
                   stale: root.stale,
                   loading: root.loading });
    }

    // ---- alerts ---------------------------------------------------------------------
    function _alerts() {
        const c = cfg.config;
        if (!c.alerts || c.alerts.length === 0) return;
        const dayKey = function (q) { return Markets.dayKey(q.timeMs || Date.now(), q.gmtoffset); };
        const r = Markets.evalAlerts(c.alerts, root._quotes, st.alertLatches, c.alertHysteresis, dayKey);
        st.alertLatches = r.latches;
        vm.notifyAlerts(r.fire, root._quotes, root.notifier, { body: root.alertBody, label: root._labelOf, nowMs: Date.now() });
    }

    // ---- detail ---------------------------------------------------------------------
    property var _chartAsked: ({})
    // A fetch's raw error ("curl exit 6: curl: (6) Could not resolve host ...") as the words the chart shows; the raw text
    // goes to the console. A 429 puts the whole service on its backoff (_onRateLimited), which is the "later".
    function _chartErrorWords(e) {
        const m = /^curl exit (\d+)/.exec(String(e));
        const code = m ? Number(m[1]) : -1;
        if (e === "429") return "Too many requests; trying again later";
        if (code === 6 || code === 7) return "No connection";
        if (code === 28) return "The server did not answer in time";
        return "Could not load the chart";
    }
    function _fetchChart(sym, range, background) {
        const key = sym + "|" + range;
        const at = root._chartAt[key] || 0;
        const c = root._charts[key];
        const fresh = c && c.state === "ready" && !c.stale
            && Date.now() - at < ((range === "1D" || range === "5D") ? root._openMs - 5000 : 15 * 60000);
        if (fresh) return;
        root._chartAt[key] = Date.now();
        root._chartAsked[key] = true;
        const q = root._quotes[sym] || root._searchQuotes[sym];
        yahoo.chart(sym, range, Date.now(), function (e, ch) {
            delete root._chartAsked[key];
            const next = Object.assign({}, root._charts);
            if (e) {
                const old = next[key];
                if (!old || old.state !== "ready")
                    next[key] = { state: "error", symbol: sym, range: range, error: root._chartErrorWords(e) };
                console.log("StocksService: chart " + key + ": " + e);
            } else {
                next[key] = Object.assign({}, ch, { state: "ready", error: "", stale: false });
                root._writeCache("charts/" + root.slug(sym) + "_" + range + ".json", ch);
            }
            root._charts = next;
            root.chartSerial++;
        }, !!(q && q.prePost) && cfg.config.extendedHours, background);
    }

    function _fetchCnbc(sym) {
        const cs = root._cnbcSym(sym);
        if (!cs) return;
        const q = root._quotes[sym];
        const maxAge = q && q.state === "open" ? 5 * 60000 : 6 * 3600000;
        if (Date.now() - (root._cnbcAt[cs] || 0) < maxAge) return;
        root._cnbcAt[cs] = Date.now();
        cnbc.quote([cs], function (e, rows) {
            if (e) { delete root._cnbcAt[cs]; return; }
            root._cnbc = Object.assign({}, root._cnbc, rows);
            root.statsSerial++;
        });
    }

    // ---- search ---------------------------------------------------------------------
    function _runSearch() {
        const q = root.searchQuery.trim();
        const gen = ++root._searchGen;
        const now = Date.now();
        const hit = root._searchLru.filter(function (e) { return e.q === q.toLowerCase() && now - e.atMs < 5 * 60000; })[0];
        const done = function (results) {
            if (gen !== root._searchGen) return;
            const want = results.map(function (r) { return r.symbol; })
                .filter(function (s) { return !root._quotes[s] && !root._searchQuotes[s]; });
            const finish = function () {
                if (gen !== root._searchGen) return;
                vm.buildSearch(results, Object.assign({}, root._searchQuotes, root._quotes), root.stale);
                root._searchBusy = false;
                for (let i = 0; i < results.length; i++) logos.want(results[i].symbol, false, {});
            };
            if (want.length === 0) { finish(); return; }
            yahoo.spark(want, Date.now(), function (e, quotes) {
                if (!e) root._searchQuotes = Object.assign({}, root._searchQuotes, quotes);
                finish();
            });
        };
        if (hit) { done(hit.results); return; }
        yahoo.search(q, function (e, results) {
            if (gen !== root._searchGen) return;
            if (e) { root._searchBusy = false; vm.buildSearch([], root._quotes, root.stale); return; }
            const lru = root._searchLru.filter(function (x) { return x.q !== q.toLowerCase(); });
            lru.unshift({ q: q.toLowerCase(), atMs: Date.now(), results: results });
            root._searchLru = lru.slice(0, 20);
            done(results);
        });
    }
}
