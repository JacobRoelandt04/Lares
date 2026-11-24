.pragma library
.import "Markets.js" as Markets

// =============================================================================
// Portfolio.js -- the portfolio engine: config actions + market data -> every
// figure the popup shows. Pure, no Qt.
// Contract: docs/stocks.md.
//
//     compute(input)                    -> Portfolio
//     valueSeries(input, portfolio, r)  -> { days, t, value, invested }
//                                          (1D / 5D: { t, value, invested, intraday, base, tzOffsetSec })
//     intradayValue(input, portfolio)   -> { t, v, base }
//     sortRows(rows, key, ascending), validateAction(a)
//
// SPLIT-ADJUSTED UNITS. Yahoo's daily closes AND dividend amounts are already
// divided by every later split (NVDA's 2020 dividend reads 0.004 = 0.16 / 40),
// so the engine converts each action the same way -- shares x the product of
// the splits AFTER its day, price / it -- and works in those units throughout.
// A split's own day is post-split: an action on it is not scaled.
//
// THE TIMELINE of one holding is its actions (file order kept within a day)
// and its dividends on their ex-dates, a dividend BEFORE that day's actions:
// shares bought on the ex-date get none, shares sold on it still do.
//
// AVERAGE COST in three layers, carried side by side: native (the quote's own
// unit, fees in), EUR at that day's FX, and real = EUR x HICP(latest) /
// HICP(month). A buy adds n p + f to each; a sell realises (n p - f) - avg x n
// per layer and takes avg x n off the basis; an over-sell is an `errors` line
// and is skipped; shares reaching zero close the position (a later buy
// reopens it; what was realised stays). Fees live INSIDE cost and proceeds,
// so a total never subtracts them again.
//
// FX is euro per unit of the major currency (<CCY>EUR=X): a day's rate is the
// close of the nearest trading day at or before it (a Sunday trade takes
// Friday's), the first close before the history starts. Minor units (GBp)
// carry their scale (0.01) beside the rate. HICP: a month after the last
// published one deflates by 1, before the first by the first, and a missing
// month in between carries the previous one forward.
//
// DAY GAIN includes the day's FX move: S (price fxNow - prevClose fxPrev);
// shares bought today are measured from their buy price instead.
// =============================================================================

var EPS = 1e-9;

// -----------------------------------------------------------------------------
// Day series: sorted days and values, read at the nearest day <= a day.
// -----------------------------------------------------------------------------

function _daySeries(chart) {
    var days = [], vals = [];
    if (!chart || !chart.t)
        return { days: days, vals: vals };
    var off = chart.meta ? chart.meta.gmtoffset : 0;
    for (var i = 0; i < chart.t.length; i++) {
        var v = chart.c[i];
        if (typeof v !== "number" || !isFinite(v))
            continue;
        var d = Markets.barDay(chart.t[i], off);
        var n = days.length;
        if (n && days[n - 1] === d) {
            vals[n - 1] = v;                // a live bar on a closed bar's day: the later wins
            continue;
        }
        if (n && d < days[n - 1])
            continue;
        days.push(d);
        vals.push(v);
    }
    return { days: days, vals: vals };
}

function _idxAt(days, day) {
    if (!days.length || day < days[0])
        return -1;
    var lo = 0, hi = days.length - 1;
    while (lo < hi) {
        var mid = (lo + hi + 1) >> 1;
        if (days[mid] <= day)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

function _at(series, day) {
    if (!series.days.length)
        return NaN;
    var i = _idxAt(series.days, day);
    return series.vals[i < 0 ? 0 : i];
}

// -----------------------------------------------------------------------------
// Context: FX series (lazy), HICP, withholding
// -----------------------------------------------------------------------------

function _ctx(input) {
    var hicp = input.hicp || {};
    var months = Object.keys(hicp).sort();
    return {
        input: input,
        now: input.nowMs,
        w: (typeof input.withholding === "number" && isFinite(input.withholding)) ? input.withholding : 0.30,
        fx: {},
        hicp: hicp,
        months: months,
        latest: months.length ? hicp[months[months.length - 1]] : NaN
    };
}

function _fxAt(ctx, code, day) {
    if (!code || code === "EUR")
        return 1;
    var f = ctx.input.fx && ctx.input.fx[code];
    if (!f)
        return NaN;
    if (!ctx.fx[code])
        ctx.fx[code] = _daySeries(f.hist);
    var v = _at(ctx.fx[code], day);
    if (isFinite(v))
        return v;
    return (typeof f.now === "number") ? f.now : NaN;
}

function _hicpAt(ctx, month) {
    var ms = ctx.months;
    if (month <= ms[0])
        return ctx.hicp[ms[0]];
    return ctx.hicp[ms[_idxAt(ms, month)]];
}

// Today's euros per euro of `day`.
function _defl(ctx, day) {
    if (!ctx.months.length)
        return 1;
    return ctx.latest / _hicpAt(ctx, String(day).substring(0, 7));
}

// -----------------------------------------------------------------------------
// One holding's timeline
// -----------------------------------------------------------------------------

function _fmtN(n) {
    return String(Math.round(n * 1e6) / 1e6);
}

function _replay(h, ctx, errors) {
    var input = ctx.input;
    var sym = String(h.symbol || "");
    var label = h.alias || sym;
    var q = input.quotes ? input.quotes[sym] : null;
    var hist = input.history ? input.history[sym] : null;
    var meta = hist && hist.meta ? hist.meta : null;
    var raw = (q && q.currency) || (meta && meta.currency) || "EUR";
    var cur = Markets.normCurrency(raw);
    var off = (q && typeof q.gmtoffset === "number") ? q.gmtoffset : (meta ? meta.gmtoffset : 0);

    var splits = [], ev = [];
    if (hist) {
        for (var s = 0; s < (hist.splits || []).length; s++) {
            var sp = hist.splits[s];
            if (sp.num > 0 && sp.den > 0)
                splits.push({ day: Markets.barDay(sp.t, off), f: sp.num / sp.den });
        }
        for (var d = 0; d < (hist.dividends || []).length; d++) {
            var dv = hist.dividends[d];
            if (typeof dv.amount === "number" && isFinite(dv.amount))
                ev.push({ div: true, day: Markets.barDay(dv.t, off), ord: d, amount: dv.amount });
        }
    }
    var acts = h.actions || [];
    for (var i = 0; i < acts.length; i++) {
        var why = validateAction(acts[i]);
        if (why) {
            errors.push(label + ": action " + (i + 1) + " skipped, " + why);
            continue;
        }
        ev.push({ div: false, day: acts[i].date, ord: i, a: acts[i] });
    }
    ev.sort(function (x, y) {
        if (x.day !== y.day)
            return x.day < y.day ? -1 : 1;
        if (x.div !== y.div)
            return x.div ? -1 : 1;
        return x.ord - y.ord;
    });

    var k = cur.scale;
    var st = { sym: sym, label: label, q: q, hist: hist, meta: meta, raw: raw, code: cur.code,
               scale: k, off: off, S: 0, bN: 0, bE: 0, bR: 0, rE: 0, rR: 0, divE: 0, divR: 0,
               fees: 0, bought: 0, boughtR: 0, net: 0, closedOn: "", trades: [], dividendEvents: [],
               steps: [], nActs: 0 };
    for (var e = 0; e < ev.length; e++) {
        var x = ev[e];
        if (x.div) {
            if (st.S <= EPS)
                continue;
            var fxd = _fxAt(ctx, cur.code, x.day);
            var netN = st.S * x.amount * (1 - ctx.w);
            var netE = netN * k * fxd;
            st.divE += netE;
            st.divR += netE * _defl(ctx, x.day);
            st.dividendEvents.push({ date: x.day, perShare: x.amount, shares: st.S, net: netE });
            continue;
        }
        var a = x.a;
        var F = 1;
        for (var f = 0; f < splits.length; f++)
            if (splits[f].day > a.date)
                F *= splits[f].f;
        var n = a.shares, p = a.price, fee = a.fees || 0;
        var nA = n * F, pA = p / F;
        var fx = _fxAt(ctx, cur.code, a.date);
        var dfl = _defl(ctx, a.date);
        var feeE = fee * k * fx;
        var eur;
        if (a.type === "buy") {
            var costN = n * p + fee;
            eur = costN * k * fx;
            st.bN += costN;
            st.bE += eur;
            st.bR += eur * dfl;
            st.bought += eur;
            st.boughtR += eur * dfl;
            st.net += eur;
            st.S += nA;
            st.closedOn = "";
        } else {
            if (nA > st.S * (1 + EPS) + EPS) {
                errors.push(label + ": sell of " + _fmtN(n) + " on " + a.date + " is more than the "
                            + _fmtN(st.S / F) + " held; skipped");
                continue;
            }
            var procN = n * p - fee;
            eur = procN * k * fx;
            var part = Math.min(1, nA / st.S);
            var cN = st.bN * part, cE = st.bE * part, cR = st.bR * part;
            st.net -= eur;
            st.rE += eur - cE;
            st.rR += eur * dfl - cR;
            st.bN -= cN;
            st.bE -= cE;
            st.bR -= cR;
            st.S -= nA;
            if (st.S <= EPS * Math.max(1, nA)) {
                st.S = 0;
                st.bN = 0;
                st.bE = 0;
                st.bR = 0;
                st.closedOn = a.date;
            }
        }
        st.fees += feeE;
        st.nActs++;
        st.trades.push({ type: a.type, date: a.date, shares: n, price: p, fees: fee,
                         comment: a.comment ? String(a.comment) : "", sharesAdj: nA, priceAdj: pA,
                         fx: fx, eur: eur });
        st.steps.push({ day: a.date, S: st.S, net: st.net });
    }
    return st;
}

function _lastTwo(hist) {
    var c = hist && hist.c ? hist.c : [];
    return { last: c.length ? c[c.length - 1] : NaN, prev: c.length > 1 ? c[c.length - 2] : NaN };
}

function _num(v) {
    return typeof v === "number" && isFinite(v);
}

// The replay's state at `nowMs` -> Holding.
function _holding(st, ctx, cfg) {
    var q = st.q, now = ctx.now, k = st.scale;
    var lt = _lastTwo(st.hist);
    var price = q && _num(q.price) ? q.price : lt.last;
    var prev = q && _num(q.prevClose) ? q.prevClose : lt.prev;
    var fxNow = 1, fxPrev = 1;
    if (st.code !== "EUR") {
        var f = ctx.input.fx ? ctx.input.fx[st.code] : null;
        var today0 = Markets.dayKey(now, st.off);
        fxNow = f && _num(f.now) ? f.now : _fxAt(ctx, st.code, today0);
        fxPrev = f && _num(f.prev) ? f.prev : fxNow;
    }
    var S = st.S;
    var value = S > 0 ? S * price * k * fxNow : 0;

    // Shares bought today start the day at their buy price.
    var today = Markets.dayKey(now, st.off);
    var tb = 0, tbE = 0;
    for (var i = 0; i < st.trades.length; i++) {
        var t = st.trades[i];
        if (t.type === "buy" && t.date === today) {
            tb += t.sharesAdj;
            tbE += t.sharesAdj * t.priceAdj * k * t.fx;
        }
    }
    if (tb > S) {
        tbE = tb > 0 ? tbE * S / tb : 0;
        tb = S;
    }
    var baseline = S > 0 ? (S - tb) * prev * k * fxPrev + tbE : 0;
    var dayGain = S > 0 ? value - baseline : 0;

    var unrealised = S > 0 ? value - st.bE : 0;
    var unrealisedReal = S > 0 ? value - st.bR : 0;
    var total = unrealised + st.rE + st.divE;
    var totalReal = unrealisedReal + st.rR + st.divR;
    var name = (q && q.name) || (st.meta && st.meta.name) || st.sym;
    return {
        symbol: st.sym,
        alias: cfg.alias ? String(cfg.alias) : "",
        label: st.label,
        name: name,
        currency: st.raw,
        shares: S,
        avgCostNative: S > 0 ? st.bN / S : 0,
        price: price,
        prevClose: prev,
        change: q && _num(q.change) ? q.change : price - prev,
        changePct: q && _num(q.changePct) ? q.changePct : (prev ? (price - prev) / prev * 100 : 0),
        value: value,
        prevValue: baseline,
        dayGain: dayGain,
        dayPct: baseline ? dayGain / baseline * 100 : 0,
        unrealised: unrealised,
        unrealisedReal: unrealisedReal,
        realised: st.rE,
        realisedReal: st.rR,
        dividends: st.divE,
        dividendsReal: st.divR,
        fees: st.fees,
        bought: st.bought,
        boughtReal: st.boughtR,
        total: total,
        totalReal: totalReal,
        totalPct: st.bought ? total / st.bought * 100 : 0,
        totalPctReal: st.boughtR ? totalReal / st.boughtR * 100 : 0,
        closedOn: S > 0 ? "" : st.closedOn,
        state: q ? Markets.marketState(q, now) : "closed",
        trades: st.trades,
        dividendEvents: st.dividendEvents
    };
}

var SUM_KEYS = ["value", "prevValue", "dayGain", "unrealised", "unrealisedReal", "realised",
                "realisedReal", "dividends", "dividendsReal", "fees", "bought", "boughtReal",
                "total", "totalReal"];

function compute(input) {
    var ctx = _ctx(input || {});
    var errors = [];
    var out = { asOfMs: ctx.now, holdings: [], closed: [], errors: errors, anyHeldOpen: false,
                hicpLatest: ctx.months.length ? ctx.months[ctx.months.length - 1] : "" };
    for (var s = 0; s < SUM_KEYS.length; s++)
        out[SUM_KEYS[s]] = 0;
    var missingFx = {};
    var list = ctx.input.holdings || [];
    for (var i = 0; i < list.length; i++) {
        var cfg = list[i] || {};
        if (!cfg.symbol) {
            errors.push("holding " + (i + 1) + " has no symbol; skipped");
            continue;
        }
        var st = _replay(cfg, ctx, errors);
        if (!st.nActs) {
            errors.push(st.label + ": no valid actions; skipped");
            continue;
        }
        if (st.code !== "EUR" && !(ctx.input.fx && ctx.input.fx[st.code]) && !missingFx[st.code]) {
            missingFx[st.code] = true;
            errors.push("no " + st.code + " to EUR rate yet: " + st.code + " holdings are not counted");
        }
        var hd = _holding(st, ctx, cfg);
        (hd.shares > 0 ? out.holdings : out.closed).push(hd);
        for (var k = 0; k < SUM_KEYS.length; k++) {
            var v = hd[SUM_KEYS[k]];
            if (_num(v))
                out[SUM_KEYS[k]] += v;
        }
        if (hd.shares > 0 && hd.state === "open" && Markets.isMarketType(st.q))
            out.anyHeldOpen = true;
    }
    out.dayPct = out.prevValue ? out.dayGain / out.prevValue * 100 : 0;
    out.totalPct = out.bought ? out.total / out.bought * 100 : 0;
    out.totalPctReal = out.boughtReal ? out.totalReal / out.boughtReal * 100 : 0;
    return out;
}

// -----------------------------------------------------------------------------
// Value vs invested (the summary chart). `invested` is NET INVESTED (a
// stepped line, so the gap between value and invested is the gain): every buy's cost with its fees minus every sell's proceeds net of
// fees, each in EUR at its day's FX, dividends not in it. It steps on action
// days and goes below zero once more has come out than went in.
//
//   "1M" "6M" "YTD"   business days, forward-filled (a holiday repeats the
//                     last close), the live figures last
//   "1Y" "5Y" "ALL"   the first day, then Fridays, then the live figures
//   "1D"              today's intraday value (intradayValue's grid, 5 min; the
//                     bar's own from local midnight once a holding traded today):
//                     the holdings as they are NOW at every point, so value -
//                     `base` is the day gain and value - invested the total
//                     gain at every point; `invested` is today's net invested,
//                     flat (a trade has a day, not a time); `base` = the
//                     start-of-day value (Portfolio.prevValue)
//   "5D"              five days of 15-min points (input.spark5d, the 5d
//                     spark of the holdings and their FX pairs) on a shared
//                     grid; shares and net invested REPLAYED for each point's
//                     day, FX per point from the pair's own 5d spark;
//                     `base` = the value at the first point
//
// The intraday ranges return { t, value, invested, intraday: true, base,
// tzOffsetSec } (no `days`; t is each slot's start, the live value last);
// the daily ones { days, t, value, invested }.
// -----------------------------------------------------------------------------

function _addMonths(day, n) {
    var y = +day.substring(0, 4), m = +day.substring(5, 7) - 1 + n, d = +day.substring(8, 10);
    y += Math.floor(m / 12);
    m = ((m % 12) + 12) % 12;
    var last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    return Markets.dayKey(Date.UTC(y, m, Math.min(d, last)), 0);
}

function _localOffset(input) {
    if (typeof input.tzOffsetSec === "number")
        return input.tzOffsetSec;
    return -new Date(input.nowMs).getTimezoneOffset() * 60;
}

// Every configured holding's replay, with its daily closes (the summary's
// runs; closed positions count, their flows are in `invested`).
function _runs(ctx) {
    var runs = [];
    var list = ctx.input.holdings || [];
    for (var i = 0; i < list.length; i++) {
        if (!list[i] || !list[i].symbol)
            continue;
        var st = _replay(list[i], ctx, []);
        if (!st.steps.length)
            continue;
        st.closes = _daySeries(st.hist);
        st.ptr = -1;
        runs.push(st);
    }
    return runs;
}

function _investedNow(runs) {
    var inv = 0;
    for (var j = 0; j < runs.length; j++)
        inv += runs[j].net;
    return inv;
}

// The replay's last step on or before `day` ({ S: 0, net: 0 } before the first).
function _stepAt(st, day) {
    var s = null;
    for (var i = 0; i < st.steps.length && st.steps[i].day <= day; i++)
        s = st.steps[i];
    return s || { S: 0, net: 0 };
}

function valueSeries(input, portfolio, range) {
    var ctx = _ctx(input || {});
    if (range === "1D" || range === "5D")
        return _intradaySeries(ctx, portfolio, range);
    var out = { days: [], t: [], value: [], invested: [] };
    var today = Markets.dayKey(ctx.now, _localOffset(ctx.input));
    var runs = _runs(ctx), first = "";
    for (var i = 0; i < runs.length; i++)
        if (!first || runs[i].steps[0].day < first)
            first = runs[i].steps[0].day;
    if (!runs.length)
        return out;
    var start = range === "1M" ? _addMonths(today, -1)
              : range === "6M" ? _addMonths(today, -6)
              : range === "YTD" ? today.substring(0, 4) + "-01-01"
              : range === "1Y" ? _addMonths(today, -12)
              : range === "5Y" ? _addMonths(today, -60)
              : first;
    if (start < first)
        start = first;
    var weekly = range === "1Y" || range === "5Y" || range === "ALL";
    var sample = function (day) {
        var val = 0, inv = 0;
        for (var r = 0; r < runs.length; r++) {
            var h = runs[r];
            while (h.ptr + 1 < h.steps.length && h.steps[h.ptr + 1].day <= day)
                h.ptr++;
            if (h.ptr < 0)
                continue;
            var S = h.steps[h.ptr].S;
            inv += h.steps[h.ptr].net;
            if (S > 0) {
                var c = _at(h.closes, day);
                var fx = _fxAt(ctx, h.code, day);
                if (_num(c) && _num(fx))
                    val += S * c * h.scale * fx;
            }
        }
        out.days.push(day);
        out.t.push(Markets.dayMs(day));
        out.value.push(val);
        out.invested.push(inv);
    };
    var firstSample = true;
    for (var d = start; d < today; d = Markets.addDays(d, 1)) {
        var wd = Markets.weekday(d);
        if (wd === 0 || wd === 6)
            continue;
        if (weekly && wd !== 5 && !firstSample)
            continue;
        sample(d);
        firstSample = false;
    }
    // The live point: today's prices and FX, exactly the summary's figures.
    var p = portfolio || compute(input);
    out.days.push(today);
    out.t.push(ctx.now);
    out.value.push(p.value);
    out.invested.push(_investedNow(runs));
    return out;
}

// -----------------------------------------------------------------------------
// The intraday engine (1D, 5D and the bar's sparkline). The grid is the union
// of the `slotMs` slots any line's spark has a point in, so a night between
// two markets' sessions takes no room. At each slot a line is its last spark
// point before the slot's END, `pre(day)` before its first; its currency the
// same from the pair's spark and `fxPre(day)`. `S(day)` and `net(day)` are the
// line's shares and net invested on the slot's day in its own exchange's zone.
// -----------------------------------------------------------------------------

var SLOT_MS = 5 * 60000;
var BAR_MAJOR_SHARE = 0.25;     // the share of the portfolio the open markets must hold for the bar's chart to start (_todayFrom)
var SLOT_5D_MS = 15 * 60000;
var NO_SPARK = { t: [], c: [] };

function _gridValue(lines, slotMs, fromMs) {
    var slots = {};
    for (var i = 0; i < lines.length; i++)
        for (var k = 0; k < lines[i].sp.t.length; k++)
            slots[Math.floor(lines[i].sp.t[k] / slotMs) * slotMs] = true;
    var grid = Object.keys(slots).map(Number).sort(function (a, b) { return a - b; });
    if (fromMs > 0)
        grid = grid.filter(function (s) { return s + slotMs > fromMs; });
    var out = { t: [], value: [], invested: [] };
    for (var g = 0; g < grid.length; g++) {
        var edge = grid[g] + slotMs;
        var v = 0, inv = 0;
        for (var h = 0; h < lines.length; h++) {
            var x = lines[h];
            while (x.i + 1 < x.sp.t.length && x.sp.t[x.i + 1] < edge)
                x.i++;
            while (x.fi + 1 < x.fxSp.t.length && x.fxSp.t[x.fi + 1] < edge)
                x.fi++;
            var day = Markets.dayKey(grid[g], x.off);
            var S = x.S(day);
            inv += x.net(day);
            if (S > 0) {
                var price = x.i >= 0 ? x.sp.c[x.i] : x.pre(day);
                var fx = x.fi >= 0 ? x.fxSp.c[x.fi] : x.fxPre(day);
                if (_num(price) && _num(fx))
                    v += S * price * x.scale * fx;
            }
        }
        out.t.push(grid[g]);
        out.value.push(v);
        out.invested.push(inv);
    }
    return out;
}

function _const(v) {
    return function () { return v; };
}

// Today on the 5-min grid, the holdings as they are now: each symbol
// forward-filled from its previous close, each currency from its previous FX
// close. The last point is the portfolio's own value, so the bar and the
// summary agree.
function _todayLines(input, p) {
    var lines = [];
    for (var i = 0; i < (p.holdings || []).length; i++) {
        var hd = p.holdings[i];
        var q = input.quotes ? input.quotes[hd.symbol] : null;
        var cur = Markets.normCurrency(hd.currency);
        var f = cur.code !== "EUR" && input.fx ? input.fx[cur.code] : null;
        var fxPrev = cur.code === "EUR" ? 1 : (f && _num(f.prev) ? f.prev : (f && _num(f.now) ? f.now : NaN));
        lines.push({ S: _const(hd.shares), net: _const(0), scale: cur.scale, off: 0,
                     sp: q && q.spark ? q.spark : NO_SPARK, pre: _const(hd.prevClose),
                     fxSp: f && f.spark ? f.spark : NO_SPARK, fxPre: _const(fxPrev), i: -1, fi: -1 });
    }
    return lines;
}

// Five days on the 15-min grid, replayed: a line per configured holding, its
// shares and net invested for each point's day; before its first 5d point the
// close of the day before (the history), the FX close of the day before.
function _fiveDayLines(ctx, runs) {
    var sp5 = ctx.input.spark5d || {};
    var lines = [];
    for (var i = 0; i < runs.length; i++) {
        var st = runs[i];
        var q5 = sp5[st.sym];
        var fq5 = st.code !== "EUR" ? sp5[Markets.fxSymbol(st.code)] : null;
        var sp = q5 && q5.spark ? q5.spark : NO_SPARK;
        lines.push({
            S: (function (s) { return function (day) { return _stepAt(s, day).S; }; })(st),
            net: (function (s) { return function (day) { return _stepAt(s, day).net; }; })(st),
            scale: st.scale, off: st.off, sp: sp,
            pre: (function (s, first) {
                return function (day) {
                    var c = _at(s.closes, Markets.addDays(day, -1));
                    return _num(c) ? c : first;
                };
            })(st, sp.c.length ? sp.c[0] : NaN),
            fxSp: fq5 && fq5.spark ? fq5.spark : NO_SPARK,
            fxPre: (function (s) {
                return function (day) { return _fxAt(ctx, s.code, Markets.addDays(day, -1)); };
            })(st),
            i: -1, fi: -1 });
    }
    return lines;
}

function _intradaySeries(ctx, portfolio, range, todayOnly) {
    var input = ctx.input;
    var p = portfolio || compute(input);
    var runs = _runs(ctx);
    var g = range === "1D" ? _gridValue(_todayLines(input, p), SLOT_MS, todayOnly ? _todayFrom(input, p) : 0)
                           : _gridValue(_fiveDayLines(ctx, runs), SLOT_5D_MS);
    var out = { t: g.t, value: g.value, invested: g.invested, intraday: true, base: 0,
                tzOffsetSec: _localOffset(input) };
    var n = out.value.length;
    var investedNow = _investedNow(runs);
    if (range === "1D") {
        for (var k = 0; k < n; k++)
            out.invested[k] = investedNow;
        out.base = p.prevValue || 0;
    }
    if (n) {
        out.value[n - 1] = p.value;
        out.invested[n - 1] = investedNow;
        if (range === "5D")
            out.base = out.value[0];
    }
    return out;
}

// Where the BAR's 1D grid starts: today's local midnight once any holding has traded today, else 0 (the last session(s),
// as they are). A market that has not opened yet holds its last close from the first slot on: its previous session is not
// today's chart. The popup's 1D keeps joining yesterday's US session to today's Europe (its ticks name the day at the join);
// the bar's 22 x 12 sparkline has no ticks, and with US listings in pre-market a chart from yesterday's 15:30 would have their session's
// moves standing over today's: a high point plummeting down at the very start messes up the scaling of the rest of the chart
// (4833 at 15:30, 4733 by 16:15, today's 4735 -> 4753 squashed under it).
function _todayFrom(input, p) {
    var off = _localOffset(input);
    var start = Markets.dayMs(Markets.dayKey(input.nowMs, off)) - off * 1000;
    if (!isFinite(start))
        return 0;
    // THE CHART OPENS WITH THE MARKET THAT CARRIES IT: two hours after the US open on a +4 % day the European session's hours,
    // the American holdings standing at their last close, would take two thirds of 22 px and the move one (a chart two thirds
    // flat with the move a spike on the right third). Each holding that has traded today OPENS at its first point of today; the
    // chart starts at the open by which the markets open hold BAR_MAJOR_SHARE of the portfolio's value at the last close. One
    // market, or the earliest holding being a big one, and this is the first open of the day. A small market that
    // opens first is not what the chart is about: its moves are in the first point's value (it starts from them), not in a
    // lead-in. A market that opens LATER still holds its last close until it does -- the lead-in is honest -- and nothing is
    // dropped between sessions (the grid is the union of the slots anyone traded in).
    var opened = [], total = 0;
    for (var i = 0; i < (p.holdings || []).length; i++) {
        var hd = p.holdings[i];
        if (_num(hd.prevValue) && hd.prevValue > 0)
            total += hd.prevValue;
        var q = input.quotes ? input.quotes[hd.symbol] : null;
        var t = q && q.spark ? q.spark.t : null;
        if (!t)
            continue;
        for (var k = 0; k < t.length; k++)
            if (t[k] >= start) {
                opened.push({ t: t[k], w: _num(hd.prevValue) && hd.prevValue > 0 ? hd.prevValue : 0 });
                break;
            }
    }
    if (!opened.length)
        return 0;
    opened.sort(function (a, b) { return a.t - b.t; });
    var held = 0;
    for (var j = 0; j < opened.length; j++) {
        held += opened[j].w;
        if (total > 0 && held >= BAR_MAJOR_SHARE * total)
            return opened[j].t;
    }
    return start;
}

// The bar's sparkline: the 1D series as { t, v, base }.
function intradayValue(input, portfolio) {
    var s = _intradaySeries(_ctx(input || {}), portfolio, "1D", true);
    return { t: s.t, v: s.value, base: s.base };
}

// -----------------------------------------------------------------------------
// Rows
// -----------------------------------------------------------------------------

var SORT_FIELD = { value: "value", day: "changePct", total: "totalPct" };

// key "value" | "day" | "total" | "name" (anything else sorts by name).
// `ascending` true: smallest / A first; false: largest / Z first; left out:
// the key's own direction (numbers largest first, names A-Z). A row without
// the figure goes last in BOTH directions, and ties keep their order in both
// (a descending sort is not an ascending one reversed).
function sortRows(rows, key, ascending) {
    var list = (rows || []).map(function (r, i) { return { r: r, i: i }; });
    var field = SORT_FIELD[key];
    var dir = (ascending === undefined || ascending === null ? !field : !!ascending) ? 1 : -1;
    list.sort(function (a, b) {
        if (!field) {
            var la = String(a.r.label || a.r.symbol || "").toLowerCase();
            var lb = String(b.r.label || b.r.symbol || "").toLowerCase();
            if (la !== lb)
                return (la < lb ? -1 : 1) * dir;
            return a.i - b.i;
        }
        var va = a.r[field], vb = b.r[field];
        var ha = _num(va), hb = _num(vb);
        if (ha !== hb)
            return ha ? -1 : 1;
        if (ha && va !== vb)
            return (va - vb) * dir;
        return a.i - b.i;
    });
    return list.map(function (x) { return x.r; });
}

// "" when the action is usable, else the reason in the user's terms.
function validateAction(a) {
    if (!a || typeof a !== "object")
        return "not an object";
    if (a.type !== "buy" && a.type !== "sell")
        return "type must be \"buy\" or \"sell\"";
    if (typeof a.date !== "string" || !isFinite(Markets.dayMs(a.date)))
        return "date must be a real day as \"YYYY-MM-DD\"";
    if (typeof a.shares !== "number" || !isFinite(a.shares) || a.shares <= 0)
        return "shares must be a number above 0";
    if (typeof a.price !== "number" || !isFinite(a.price) || a.price < 0)
        return "price must be a number, 0 or more";
    if (a.fees !== undefined && a.fees !== null
            && (typeof a.fees !== "number" || !isFinite(a.fees) || a.fees < 0))
        return "fees must be a number, 0 or more";
    if (a.comment !== undefined && a.comment !== null && typeof a.comment !== "string")
        return "comment must be text";
    return "";
}
