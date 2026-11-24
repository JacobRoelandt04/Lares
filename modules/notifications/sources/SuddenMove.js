.pragma library
.import "../../stocks/data/Markets.js" as Markets
.import "../../stocks/data/StocksFormat.js" as Fmt
.import "SourceFormat.js" as F

// =============================================================================
// SuddenMove.js -- the stocks' `sudden` alert kind, as pure decisions (SOURCES.md, "Stocks").
//
// A move of >= X % within Y minutes, intraday (both params, with per-symbol overrides in stocks.jsonc), market
// hours only, once per symbol per direction per session; rich body: the move on a small chart. The dayMove /
// above / below alerts are separate (Markets.evalAlerts).
//
//   paramsFor(sudden, symbol)            { pct, minutes } for the symbol, or null (stocks.jsonc says `false`)
//   windowOf(q, nowMs, minutes)          the quote's closes inside the window, oldest first, ending with the live price
//   evaluate(q, params, nowMs)           { up, down }: each null or the move that qualifies
//   latchDay(q, nowMs) / latchKey(sym, dir)   the once-per-session memory
//   pruneLatches(latches, nowMs)         drop the days that are over
//   daySeries(q, nowMs)                  the day so far { t, c }, the live price last
//   facts(q, move, params, nowMs, opts)  what StockMoveBody draws (the whole day, not the window)
//   merge(day, fine, fromMs, toMs)       the 1-minute points of the span in place of the 5-minute ones
//   text(label, move, q)                 { title, body }
//
// THE MOVE is measured from the extreme: the price now against the LOWEST close of the window (a surge) or the HIGHEST
// (a drop) -- "up at least X % within Y minutes" is "now is X % over the low of the last Y minutes". The window is
// only today's regular session (a spark's pre-market is cut out by the parser): a gap at the open is not a sudden
// move, and a slow climb (4 % over three hours) is not either. No move is judged outside market hours: a quote's own
// session says whether it is open (Markets.marketState), in the exchange's own time.
// No Qt, no clock: every "now" is an argument.
// =============================================================================

// stocks.jsonc's defaults (StocksConfig._sudden has the same numbers; the cases keep them equal).
var DEFAULT_PCT = 3;
var DEFAULT_MINUTES = 30;

function _num(v) {
    return typeof v === "number" && isFinite(v);
}

// `sudden` is the config's normalised block ({ pct, minutes, bySymbol }); anything else is "the defaults".
function paramsFor(sudden, symbol) {
    var s = sudden && typeof sudden === "object" ? sudden : {};
    var pct = _num(s.pct) && s.pct > 0 ? s.pct : DEFAULT_PCT;
    var minutes = _num(s.minutes) && s.minutes > 0 ? s.minutes : DEFAULT_MINUTES;
    var by = s.bySymbol && typeof s.bySymbol === "object" ? s.bySymbol : {};
    var e = by[symbol];
    if (e === undefined) {
        var up = String(symbol).toUpperCase();
        for (var k in by)
            if (Object.prototype.hasOwnProperty.call(by, k) && String(k).toUpperCase() === up)
                e = by[k];
    }
    if (e === false)
        return null;
    if (e && typeof e === "object") {
        if (_num(e.pct) && e.pct > 0)
            pct = e.pct;
        if (_num(e.minutes) && e.minutes > 0)
            minutes = e.minutes;
    }
    return { pct: pct, minutes: minutes };
}

function windowOf(q, nowMs, minutes) {
    var start = q && q.session && _num(q.session.start) ? q.session.start : -Infinity;
    var lo = Math.max(nowMs - minutes * 60000, start);
    var t = [], c = [];
    var sp = q ? q.spark : null;
    if (sp && sp.t && sp.c)
        for (var i = 0; i < sp.t.length && i < sp.c.length; i++)
            if (sp.t[i] >= lo && sp.t[i] <= nowMs && _num(sp.c[i])) {
                t.push(sp.t[i]);
                c.push(sp.c[i]);
            }
    // The live price is the last point: a spark's last bar can be minutes old.
    if (q && _num(q.price) && _num(q.timeMs) && q.timeMs >= lo && q.timeMs <= nowMs) {
        if (t.length > 0 && t[t.length - 1] >= q.timeMs) {
            c[c.length - 1] = q.price;
        } else {
            t.push(q.timeMs);
            c.push(q.price);
        }
    }
    return { t: t, c: c };
}

function _move(w, at, dir) {
    var n = w.c.length - 1;
    var from = w.c[at];
    var to = w.c[n];
    return { dir: dir, pct: Math.abs((to - from) / from * 100), from: from, to: to,
             fromMs: w.t[at], toMs: w.t[n], minutes: Math.max(1, Math.round((w.t[n] - w.t[at]) / 60000)) };
}

// The day so far as { t, c }: the regular session's closes up to `nowMs`, the live price the last point (the spark's
// last bar can be minutes old). A copy: the quote's own arrays are never handed out.
function daySeries(q, nowMs) {
    var t = [], c = [];
    var sp = q ? q.spark : null;
    if (sp && sp.t && sp.c)
        for (var i = 0; i < sp.t.length && i < sp.c.length; i++)
            if (sp.t[i] <= nowMs && _num(sp.c[i])) {
                t.push(sp.t[i]);
                c.push(sp.c[i]);
            }
    if (q && _num(q.price) && _num(q.timeMs) && q.timeMs <= nowMs) {
        if (t.length > 0 && t[t.length - 1] >= q.timeMs) {
            c[c.length - 1] = q.price;
        } else {
            t.push(q.timeMs);
            c.push(q.price);
        }
    }
    return { t: t, c: c };
}

// What StockMoveBody draws (its header lists the fields). `move` is evaluate()'s (a sudden move) or null (an alert:
// `opts.kind` "above" | "below" | "dayMove" and `opts.level`). The axis runs from the session's open to `nowMs`; the
// least price span is twice the rule's percentage (a sudden move) or 2 % (an alert), so a small move looks small.
function facts(q, move, params, nowMs, opts) {
    var day = daySeries(q, nowMs);
    var o = opts || {};
    var kind = move ? "sudden" : (o.kind || "dayMove");
    var start = q && q.session && _num(q.session.start) ? q.session.start : (day.t.length ? day.t[0] : nowMs);
    var prev = q && _num(q.prevClose) ? q.prevClose : null;
    var last = day.c.length ? day.c[day.c.length - 1] : (q ? q.price : NaN);
    var dir = move ? move.dir : (prev !== null && _num(last) && last < prev ? "down" : "up");
    return { t: day.t, c: day.c, prevClose: prev, sessionStart: start, nowMs: nowMs, kind: kind, dir: dir,
             fromMs: move ? move.fromMs : null, toMs: move ? move.toMs : null,
             level: _num(o.level) ? o.level : null,
             minSpanPct: move && params ? 2 * params.pct : 2 };
}

// The day with the 1-minute points of [fromMs, toMs] in place of its 5-minute ones (outside the span stays as it was).
// Sorted by time; the live price (the day's last point) stays the last point, whatever the fine answer ends with.
// `fine` empty or null: the day as it is.
function merge(day, fine, fromMs, toMs) {
    var dt = day && day.t ? day.t : [], dc = day && day.c ? day.c : [];
    var out = { t: dt.slice(), c: dc.slice() };
    if (!fine || !fine.t || !fine.c || !dt.length)
        return out;
    var liveT = dt[dt.length - 1], liveC = dc[dc.length - 1];
    var pts = [];
    for (var i = 0; i < dt.length; i++)
        if (dt[i] < fromMs || dt[i] > toMs)
            pts.push({ t: dt[i], c: dc[i] });
    var got = 0;
    for (var j = 0; j < fine.t.length && j < fine.c.length; j++)
        if (fine.t[j] >= fromMs && fine.t[j] <= toMs && fine.t[j] < liveT && _num(fine.c[j])) {
            pts.push({ t: fine.t[j], c: fine.c[j] });
            got++;
        }
    if (got === 0)
        return out;
    pts.sort(function (a, b) { return a.t - b.t; });
    // the live price: the last point, once
    while (pts.length && pts[pts.length - 1].t >= liveT)
        pts.pop();
    pts.push({ t: liveT, c: liveC });
    out.t = pts.map(function (p) { return p.t; });
    out.c = pts.map(function (p) { return p.c; });
    return out;
}

function evaluate(q, params, nowMs) {
    var out = { up: null, down: null };
    if (!q || !params || !_num(q.price))
        return out;
    if (Markets.marketState(q, nowMs) !== "open")
        return out;
    var w = windowOf(q, nowMs, params.minutes);
    var n = w.c.length - 1;
    if (n < 1)
        return out;
    var last = w.c[n];
    var lo = Infinity, hi = -Infinity, loAt = -1, hiAt = -1;
    for (var i = 0; i < n; i++) {
        if (w.c[i] < lo) {
            lo = w.c[i];
            loAt = i;
        }
        if (w.c[i] > hi) {
            hi = w.c[i];
            hiAt = i;
        }
    }
    if (lo > 0 && (last - lo) / lo * 100 >= params.pct)
        out.up = _move(w, loAt, "up");
    if (hi > 0 && (hi - last) / hi * 100 >= params.pct)
        out.down = _move(w, hiAt, "down");
    return out;
}

// ---------------------------------------------------------------- once per symbol, direction and session

function latchKey(sym, dir) {
    return String(sym) + "|" + dir;
}

// The session's day, in the exchange's own time ("2026-10-21").
function latchDay(q, nowMs) {
    return Markets.dayKey(nowMs, q && _num(q.gmtoffset) ? q.gmtoffset : 0);
}

// Latches of days before yesterday are no use: a session is a day.
function pruneLatches(latches, nowMs) {
    var keep = F.dayKey(nowMs - 3 * 86400000);
    var out = {};
    for (var k in latches)
        if (Object.prototype.hasOwnProperty.call(latches, k) && String(latches[k]) >= keep)
            out[k] = latches[k];
    return out;
}

// ---------------------------------------------------------------- the words

// "NVDA jumped 4.2% in 25 min", "Now 123.45 USD, was 118.20 USD . +1.20% today".
function text(label, move, q) {
    var pct = (Math.round(move.pct * 10) / 10).toFixed(1) + "%";
    var verb = move.dir === "up" ? "jumped" : "dropped";
    var now = Fmt.price(q.price, q.currency, q.priceHint);
    var was = Fmt.price(move.from, q.currency, q.priceHint);
    var day = _num(q.changePct) ? " · " + Fmt.pct(q.changePct) + " today" : "";
    return { title: label + " " + verb + " " + pct + " in " + move.minutes + " min",
             body: "Now " + now + ", was " + was + day };
}
