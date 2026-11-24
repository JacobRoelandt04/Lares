pragma ComponentBehavior: Bound

import QtQuick
import "Markets.js" as Markets

// =============================================================================
// YahooSource.qml -- spark, chart, history and search from Yahoo Finance.
//
// Two lanes, one curl each: `fg` for what a person is waiting on (the detail
// chart, a search), `bg` for the cadence (spark, history, FX). Every URL is
// Markets.js's (exactly as captured in modules/stocks/data/fixtures/urls.tsv); every
// answer is parsed by Markets.js. Callbacks: cb(error, parsed).
//
//   spark(symbols, nowMs, cb, range, prePost)
//                                      { SYM: Quote }, chunked at 20 per call;
//                                      range "1D" (default, the cadence's, bg)
//                                      or "5D" (the summary's, fg: someone waits);
//                                      prePost: with the extended hours (Quote.ext)
//   fineSpark(sym, nowMs, cb)          { t, c }: today's regular session at 1-minute bars, on a third lane whose 429
//                                      never reaches the service's backoff
//   chart(sym, range, nowMs, cb, prePost, background)
//                                      Chart, decimated to <= 320 points; prePost:
//                                      1D spans the extended hours; background: behind what someone waits on
//   history(sym, fromDay, toMs, cb)    Chart (daily, events)
//   search(q, cb)                      [{ symbol, name, exchDisp, typeDisp, quoteType }]
// =============================================================================
Item {
    id: root

    property string curl: "curl"
    readonly property bool busy: fg.busy || bg.busy
    readonly property bool fgBusy: fg.busy
    signal rateLimited()

    function spark(symbols, nowMs, cb, range, prePost) {
        const urls = Markets.sparkUrls(symbols, range, prePost);
        const lane = range === "5D" ? fg : bg;
        if (urls.length === 0) { cb("", {}); return; }
        const merged = {};
        let left = urls.length, firstErr = "";
        for (let i = 0; i < urls.length; i++) {
            lane.get("spark|" + urls[i], urls[i], function (e, text) {
                if (e) { if (!firstErr || e === "429") firstErr = e; }
                else {
                    const part = Markets.parseSpark(text, nowMs, { prePost: !!prePost });
                    for (const s in part) merged[s] = part[s];
                }
                if (--left === 0) cb(firstErr, merged);
            }, lane === fg);
        }
    }

    // One symbol's day at 1-minute bars, on a lane of its own: a 429 here is NOT the service's (no backoff step, no
    // delay of the cadence); the caller just gets no answer. cb(error, { t, c } | null).
    function fineSpark(sym, nowMs, cb) {
        const url = Markets.fineSparkUrl(sym);
        fine.get("fine|" + url, url, function (e, text) {
            if (e) { cb(e, null); return; }
            const all = Markets.parseSpark(text, nowMs);
            const q = all[sym] || all[Object.keys(all)[0]];
            cb(q && q.spark && q.spark.t.length > 0 ? "" : "unreadable 1-minute spark for " + sym,
               q && q.spark && q.spark.t.length > 0 ? q.spark : null);
        }, false);
    }

    function chart(sym, range, nowMs, cb, prePost, background) {
        const url = Markets.chartUrl(sym, range, prePost);
        fg.get("chart|" + url, url, function (e, text) {
            if (e) { cb(e, null); return; }
            const c = Markets.parseChart(text, nowMs);
            cb(c ? "" : "unreadable chart for " + sym, c ? Markets.decimate(c, 320) : null);
        }, !background);
    }

    function history(sym, fromDay, toMs, cb) {
        const url = Markets.historyUrl(sym, fromDay, toMs);
        bg.get("history|" + sym, url, function (e, text) {
            if (e) { cb(e, null); return; }
            const c = Markets.parseChart(text, toMs);
            cb(c ? "" : "unreadable history for " + sym, c);
        }, false);
    }

    function search(q, cb) {
        const url = Markets.searchUrl(q);
        fg.get("search|" + url, url, function (e, text) {
            cb(e, e ? [] : Markets.parseSearch(text));
        }, true);
    }

    function cancel() { fg.cancel(); bg.cancel(); fine.cancel(); }

    StocksFetch { id: fg; curl: root.curl; onRateLimited: root.rateLimited() }
    StocksFetch { id: bg; curl: root.curl; onRateLimited: root.rateLimited() }
    // The 1-minute spark's lane: its 429 is not forwarded (see fineSpark).
    StocksFetch { id: fine; curl: root.curl }
}
