pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "SourceFormat.js" as F
import "SuddenMove.js" as Sudden

// =============================================================================
// StocksNotifier.qml -- a stock moves fast (source "stocks"; SOURCES.md).
//
// The `sudden` alert kind: a stock you hold or watch that moves at least X % within Y minutes, intraday, while its market
// is open, once per symbol per direction per session. X and Y are stocks.jsonc's (`sudden: { pct, minutes, bySymbol }`,
// a symbol with numbers of its own or `false`); which stocks and whether it speaks at all are notifications.jsonc's
// (`sources.stocks.sudden`, `.scope`). The card: "NVDA jumped 4.2% in 25 min", "Now 123.45 USD, was 118.20 USD . +1.20%
// today", the day on a small chart with the move's span emphasised (StockMoveBody; a 1-minute fetch sharpens the span), Open (the stocks popup on that symbol, through the service's own
// `alertOpenRequested`, which the shell already routes to the focused screen's owner). It has the norm duration of a
// normal card: an alert is not an ask.
//
// The existing alerts (dayMove, above, below: Markets.evalAlerts) stay the stocks service's own; where they are posted
// (StocksViewModel.notifyAlerts) none of them is sticky.
//
// Looked at after every refresh the service finishes (`updated`). The once-per-session memory is sources.json's
// (the exchange's own day), so a restart inside the session does not say it again. The stocks popup open files the
// cards silently (the user is looking at the prices). `stocks` is injected (a StocksService or its mock).
// =============================================================================
SourceBase {
    id: src

    sourceId: "stocks"
    appName: "Stocks"
    glyph: G.stocks
    // keys are "sudden:<symbol>:<up|down>"
    keys: ["sudden"]

    // The StocksService (null: this source is off).
    property var stocks: null
    ready: !!src.stocks
    attended: !!src.stocks && src.stocks.popupOpen === true

    // The clock the quotes are read against (the probes' seam).
    property var nowFn: function () { return Date.now(); }

    // The stocks to judge: what the user holds and watches, only what they hold, or every quote (currencies never).
    function _symbols() {
        const st = src.stocks;
        const q = st.quotes || {};
        const scope = src.settings.scope;
        const out = [];
        const add = function (sym) {
            if (sym && out.indexOf(sym) < 0 && q[sym] && !/=X$/.test(sym))
                out.push(sym);
        };
        if (scope === "all") {
            for (const sym in q)
                add(sym);
            return out;
        }
        const p = st.portfolio;
        const held = p && p.holdings ? p.holdings.map(h => h.symbol)
            : (st.config && st.config.holdings ? st.config.holdings.map(h => h.symbol) : []);
        held.forEach(add);
        if (scope === "portfolio")
            (st.watchlist || []).forEach(add);
        return out;
    }

    function _label(sym) {
        const hs = src.stocks.config && src.stocks.config.holdings ? src.stocks.config.holdings : [];
        for (let i = 0; i < hs.length; i++)
            if (hs[i].symbol === sym)
                return hs[i].label || hs[i].alias || sym;
        return sym;
    }

    function _scan() {
        if (!src.active || !src.settings.sudden)
            return;
        const now = src.nowFn();
        const quotes = src.stocks.quotes || {};
        const syms = src._symbols();
        let latches = src.host.state.get("stocks").latches || {};
        let changed = false;
        for (let i = 0; i < syms.length; i++) {
            const sym = syms[i];
            const q = quotes[sym];
            const params = Sudden.paramsFor(src.stocks.config ? src.stocks.config.sudden : null, sym);
            if (!params)
                continue;
            const mv = Sudden.evaluate(q, params, now);
            const day = Sudden.latchDay(q, now);
            for (const dir of ["up", "down"]) {
                const m = mv[dir];
                const lk = Sudden.latchKey(sym, dir);
                if (!m || latches[lk] === day)
                    continue;
                latches[lk] = day;
                changed = true;
                src._say(sym, m, q, params);
            }
        }
        if (changed)
            src.host.state.put("stocks", { latches: Sudden.pruneLatches(latches, now) });
    }

    function _say(sym, m, q, params) {
        const t = Sudden.text(src._label(sym), m, q);
        const open = () => src.stocks.alertOpenRequested(sym);
        const facts = Sudden.facts(q, m, params, src.nowFn());
        const uid = src.post("sudden:" + F.keyPart(sym) + ":" + m.dir, {
            title: t.title, body: t.body, urgency: "normal",
            icon: m.dir === "up" ? G.stocksUp : G.stocksDown,
            bodyComponent: moveBody, bodyProps: { facts: facts },
            actions: [{ id: "open", label: "Open", run: open }],
            onDefault: open
        });
        src._sharpen(uid, sym, facts);
    }

    // ONE background 1-minute fetch for the move's span, once the card is up: the card is re-fed in place with the span
    // drawn from the finer points. A failed or empty answer leaves the card as it was born; nothing is retried.
    function _sharpen(uid, sym, facts) {
        if (uid === "" || typeof src.stocks.fineSpark !== "function")
            return;
        src.stocks.fineSpark(sym, function (fine) {
            if (!fine || !fine.t || fine.t.length === 0)
                return;
            const day = Sudden.merge({ t: facts.t, c: facts.c }, fine, facts.fromMs, facts.toMs);
            if (day.t.length === facts.t.length && day.t.every((v, i) => v === facts.t[i]))
                return;
            src.update(uid, { bodyProps: { facts: Object.assign({}, facts, { t: day.t, c: day.c }) } });
        });
    }
    Component {
        id: moveBody
        StockMoveBody {}
    }

    Connections {
        target: src.stocks
        ignoreUnknownSignals: true
        function onUpdated() {
            src._scan();
        }
    }
    onActivated: src._scan()
}
