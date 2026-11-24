.pragma library

// A case file of this directory (make_cases.py) as the quote StocksNotifier / the stocks service holds it, its session opening at
// `baseMs`: { symbol, currency, priceHint, prevClose, price, timeMs, changePct, gmtoffset, session, spark: { t, c } }.
// Shared by the node cases, the probe and the sheet, so all three mean the same day.
var MIN = 60000;

function quoteOf(c, baseMs) {
    return { symbol: c.symbol, currency: c.currency, priceHint: c.priceHint, prevClose: c.prevClose, gmtoffset: -18000,
             price: c.live, timeMs: baseMs + c.nowMin * MIN, changePct: (c.live - c.prevClose) / c.prevClose * 100,
             session: { start: baseMs, end: baseMs + 390 * MIN, preStart: baseMs - 300 * MIN, postEnd: baseMs + 600 * MIN },
             spark: { t: c.bars.map(function (b) { return baseMs + b[0] * MIN; }), c: c.bars.map(function (b) { return b[1]; }) } };
}

// Today's regular session at 1-minute bars for the span [fromMs, toMs] of a case's day (what the fine fetch answers): the
// 5-minute line interpolated per minute with a small deterministic wiggle, ending at the live price.
function fineOf(q, fromMs, toMs) {
    var t = [], c = [];
    var bt = q.spark.t, bc = q.spark.c;
    var at = function (x) {
        if (x <= bt[0]) return bc[0];
        for (var i = 1; i < bt.length; i++)
            if (x <= bt[i]) return bc[i - 1] + (bc[i] - bc[i - 1]) * (x - bt[i - 1]) / (bt[i] - bt[i - 1]);
        return q.price;
    };
    var start = Math.ceil(fromMs / MIN) * MIN;
    for (var x = start, k = 0; x < toMs; x += MIN, k++) {
        t.push(x);
        c.push(at(x) * (1 + 0.0012 * Math.sin(k * 1.7 + 0.3)));
    }
    return { t: t, c: c };
}
