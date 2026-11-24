.pragma library
.import "Markets.js" as Markets
.import "StocksFormat.js" as Fmt

// =============================================================================
// StockSeries.js -- a Chart (detail) or a value series (summary) as a spec for
// TimelineChart.
//
//     detailSpec(chart, holding, opts)   opts: { range: "1D".."MAX", avgExtends: "auto", maxTicks: 12, plotPx: 456 }
//     summarySpec(series, opts)          opts: { range: "1D" | "5D" | "1M" | "6M" | "YTD" | "1Y" | "5Y" | "ALL", investedExtends: "auto", maxTicks, plotPx }
//     skeletonSpec(opts)                 opts: { id: "price" }  -- the loading picture
//
//     spec = {
//         series: [ { id, kind, values, color: ROLE, width, curve, gradient, range, alpha, glyphs } ],
//         gradientStops: [ { value, color: ROLE } ],     // the gradient line's (one colour, two stops)
//         thresholds: [ { value, label, color: ROLE, extendsAxis } ],
//         xTicks: [ { i, text } ], yMinSpan,
//         marks: [ { i, type, date, text, trades } ],    // what a hovered trade marker says
//         t: [ms | null per slot], role, first, last, change, changePct
//     }
//
// COLOURS ARE ROLES ("gain", "loss", "buy", "sell", "muted", "faint"), never
// colours: the host resolves them to Theme tokens (a themed colour in a model
// regenerates every delegate). Each marks series carries its own role, so a
// host that resolves `color` on every series still draws buys and sells apart.
//
// SLOTS. A slot is a point, except on 1D, where the axis spans the whole
// session in 5-minute slots and a live day fills it from the left (Yahoo's
// 1D); the padding is null. Ticks sit on the first slot of each new period:
// 1D every 2 h, 5D day starts, 1M Mondays, 6M/YTD/1Y month starts, 5Y/MAX
// years, thinned to round steps when there are more than `maxTicks`. A 1D
// grid that crosses a calendar day (the summary's: yesterday's US session,
// then today's Europe) has a tick AT the join, "Thu 09:00".
//
// NO TWO LABELS MEET. A tick closer to the previous kept one than their two
// half-widths plus a gap is dropped; the join tick outranks an ordinary one,
// which yields instead. Widths are estimated (TICK_CHAR_PX a character) at a
// plot of `opts.plotPx` (456, the popup's), so the rule is a fraction of the
// axis and holds for any slot count; a host with another plot width passes it.
// Trade marks sit at the first slot whose day is on or after the trade's and
// on the line (the close there); the tip carries the trade's own price.
//
// ONE PRICE LINE, IN PARTS (detail 1D). The day's axis is its session -- from
// the pre-market's start to the post-market's end for a listing asked with
// its extended hours (the chart's own `periods`) -- in 5-minute slots, and a
// thin stock leaves slots with no trade (Bpost: 6 of 20). Yahoo joins its
// points across them; so does this, and says where it did:
//
//   price     the regular session between neighbouring slots: solid, shaded
//   fill      a join across empty slots: DASHED, nothing under it
//   ext       the pre- and post-market (and their joins to the session):
//             the same colour at EXT_ALPHA, nothing under it
//   extFill   a join across empty slots there: dashed and faint
//
// The parts share `group: "price"`, which is what the chart morphs as one
// line. `readout` is each slot's real close (null where a join was drawn):
// what a scrub reads. Longer ranges have no empty slot (a slot is a point).
// =============================================================================

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var SLOT_1D_MS = 5 * 60000;
// The extended hours' line against the session's, and every dashed join's
// dash (in line widths: 4.5 px on, 3 off at the detail's 1.5).
var EXT_ALPHA = 0.5;
var FILL_DASH = [3, 2];

// Tick label estimate: 7 px a character and 4 px between two labels clear
// Inter at 10 and 11 px by >= 2 px for every label pair the rules make
// (measured with the fonts: "Thu 09:00" 49 / 54 px, "2025" 25 / 28).
var TICK_PLOT_PX = 456;
var TICK_CHAR_PX = 7;
var TICK_GAP_PX = 4;

function _pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

function _ok(v) {
    return typeof v === "number" && isFinite(v);
}

// Local calendar parts of `ms` at a fixed offset (seconds).
function _parts(ms, off) {
    var d = new Date(ms + (off || 0) * 1000);
    return { y: d.getUTCFullYear(), mo: d.getUTCMonth(), d: d.getUTCDate(), wd: d.getUTCDay(),
             h: d.getUTCHours(), mi: d.getUTCMinutes(),
             day: d.getUTCFullYear() + "-" + _pad2(d.getUTCMonth() + 1) + "-" + _pad2(d.getUTCDate()) };
}

// The tick rule per range: a period key per slot, a tick where it changes.
function _tickRule(range) {
    switch (range) {
    case "1D":
        return { key: function (p) { return p.day + "T" + Math.floor(p.h / 2); },
                 text: function (p) { return _pad2(p.h) + ":" + _pad2(p.mi); },
                 steps: [1, 2, 3, 6], unit: function (p) { return p.h / 2; } };
    case "5D":
        return { key: function (p) { return p.day; },
                 text: function (p) { return WEEKDAYS[p.wd]; },
                 steps: [1, 2, 5], unit: function (p) { return p.d; } };
    case "1M":
        return { key: function (p) { return p.day; },
                 need: function (p) { return p.wd === 1; },
                 text: function (p) { return p.d + " " + MONTHS[p.mo]; },
                 steps: [1, 2, 4], unit: function (p) { return p.d; } };
    case "5Y":
    case "MAX":
    case "ALL":
        return { key: function (p) { return String(p.y); },
                 text: function (p) { return String(p.y); },
                 steps: [1, 2, 5, 10, 20], unit: function (p) { return p.y; } };
    default:        // 6M, YTD, 1Y
        return { key: function (p) { return p.y + "-" + p.mo; },
                 text: function (p) { return MONTHS[p.mo]; },
                 steps: [1, 2, 3, 6], unit: function (p) { return p.mo; } };
    }
}

// Drops every tick that would meet the previous kept one (module header); a
// higher `pri` makes the kept one yield instead. Positions as the chart
// places them: slot i of n across the plot, clamped inside it by half a label.
function _spaced(ticks, n, plotPx) {
    var W = plotPx > 0 ? plotPx : TICK_PLOT_PX;
    var span = Math.max(1, n - 1);
    var w = function (t) { return String(t.text).length * TICK_CHAR_PX; };
    var x = function (t) { return Math.max(w(t) / 2, Math.min(W - w(t) / 2, t.i / span * W)); };
    var kept = [];
    for (var k = 0; k < ticks.length; k++) {
        var t = ticks[k], keep = true;
        while (kept.length > 0) {
            var last = kept[kept.length - 1];
            if (x(t) - x(last) >= (w(t) + w(last)) / 2 + TICK_GAP_PX)
                break;
            if ((t.pri || 0) > (last.pri || 0)) {
                kept.pop();
            } else {
                keep = false;
                break;
            }
        }
        if (keep)
            kept.push(t);
    }
    return kept;
}

// parts: [parts | null] per slot. The first slot is never a tick (it is the
// range's own start, not a period's). A year rule over less than two years
// has one tick at most: it takes the months instead.
function _ticks(parts, range, maxTicks, plotPx) {
    if (range === "5Y" || range === "MAX" || range === "ALL") {
        var a = null, b = null;
        for (var q = 0; q < parts.length; q++)
            if (parts[q]) {
                a = a || parts[q];
                b = parts[q];
            }
        if (a && b && (b.y - a.y) * 12 + b.mo - a.mo < 24)
            range = "1Y";
    }
    var rule = _tickRule(range), out = [], prev = null, prevDay = null;
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        if (!p)
            continue;
        var k = rule.key(p);
        if (range === "1D" && prevDay !== null && p.day !== prevDay)
            out.push({ i: i, text: WEEKDAYS[p.wd] + " " + rule.text(p), u: rule.unit(p), pri: 1 });
        else if (prev !== null && k !== prev && (!rule.need || rule.need(p)))
            out.push({ i: i, text: rule.text(p), u: rule.unit(p) });
        prev = k;
        prevDay = p.day;
    }
    var max = maxTicks > 0 ? maxTicks : 12;
    if (out.length > max) {
        var step = rule.steps[rule.steps.length - 1];
        for (var s = 0; s < rule.steps.length; s++)
            if (Math.ceil(out.length / rule.steps[s]) <= max) {
                step = rule.steps[s];
                break;
            }
        out = out.filter(function (t) { return t.pri || Math.round(t.u) % step === 0; });
        if (out.length > max)
            out.length = max;
    }
    return _spaced(out, parts.length, plotPx).map(function (t) { return { i: t.i, text: t.text }; });
}

// ---- detail -----------------------------------------------------------------

// Each point's slot: 1:1, or on 1D the 5-minute grid of the day. The grid
// starts at the answered day's first session (`chart.periods`: the pre-market
// when it was asked for) and runs to its last session's end, so a live day
// fills from the left and a first bar with no trade leaves its slot empty;
// without periods it starts at the first point and runs to today's session's
// end (currentTradingPeriod) when the day is today's.
function _slots(chart, range) {
    var n = chart.t.length, idx = [], total = n;
    if (range !== "1D" || !n) {
        for (var i = 0; i < n; i++)
            idx.push(i);
        return { idx: idx, n: n };
    }
    var per = chart.periods;
    var usePer = per && _ok(per.preStart) && _ok(per.postEnd) && chart.t[0] >= per.preStart
                 && chart.t[0] < per.postEnd;
    var t0 = usePer ? per.preStart : chart.t[0], last = -1;
    for (var k = 0; k < n; k++) {
        var s = Math.max(last + 1, Math.floor((chart.t[k] - t0) / SLOT_1D_MS));
        idx.push(s);
        last = s;
    }
    total = last + 1;
    var ses = chart.meta && chart.meta.session;
    if (usePer)
        total = Math.max(total, Math.round((per.postEnd - t0) / SLOT_1D_MS) + 1);
    else if (ses && _ok(ses.start) && _ok(ses.end) && t0 >= ses.start && t0 < ses.end)
        total = Math.max(total, Math.round((ses.end - t0) / SLOT_1D_MS) + 1);
    return { idx: idx, n: total, t0: t0 };
}

// The price line's parts (see the header): per point its slot and whether it
// is the regular session's; per neighbouring pair a solid join (adjacent
// slots) or a dashed one (empty slots between, filled on the straight line).
function _priceParts(slotOf, closes, regular, n) {
    var parts = { price: _nulls(n), fill: _nulls(n), ext: _nulls(n), extFill: _nulls(n) };
    var any = { price: false, fill: false, ext: false, extFill: false };
    for (var k = 0; k + 1 < closes.length; k++) {
        var a = slotOf[k], b = slotOf[k + 1];
        var inSession = regular[k] && regular[k + 1];
        var key = b === a + 1 ? (inSession ? "price" : "ext") : (inSession ? "fill" : "extFill");
        var list = parts[key];
        for (var i = a; i <= b; i++)
            list[i] = closes[k] + (closes[k + 1] - closes[k]) * (i - a) / (b - a);
        any[key] = true;
    }
    return { parts: parts, any: any };
}

function _nulls(n) {
    var a = [];
    for (var i = 0; i < n; i++)
        a.push(null);
    return a;
}

function _tradeText(tr, currency, hint) {
    var verb = tr.type === "sell" ? "Sold " : "Bought ";
    return verb + Fmt.shares(tr.shares) + " at " + Fmt.price(tr.price, currency, hint) + " on " + tr.date
            + (tr.comment ? " · " + tr.comment : "");
}

var VOLUME_BARS = 120;

// At most `max` bars: each bucket of ceil(n / max) slots becomes its mean at
// the bucket's middle slot, null elsewhere. Fewer slots than `max`: unchanged.
function _bucketVolume(vol, max) {
    var n = vol.length;
    var b = Math.ceil(n / max);
    if (b <= 1)
        return vol;
    var out = _nulls(n);
    for (var s0 = 0; s0 < n; s0 += b) {
        var sum = 0, cnt = 0, end = Math.min(n, s0 + b);
        for (var j = s0; j < end; j++)
            if (_ok(vol[j])) {
                sum += vol[j];
                cnt++;
            }
        if (cnt > 0)
            out[s0 + Math.floor((end - s0 - 1) / 2)] = sum / cnt;
    }
    return out;
}

function detailSpec(chart, holding, opts) {
    opts = opts || {};
    var range = opts.range || (chart && chart.range) || "1D";
    var spec = { series: [], gradientStops: [], thresholds: [], xTicks: [], yMinSpan: 0, marks: [],
                 t: [], role: "gain", first: NaN, last: NaN, change: NaN, changePct: NaN };
    if (!chart || !chart.t || !chart.t.length)
        return spec;
    var off = chart.meta ? chart.meta.gmtoffset : 0;
    var currency = chart.meta ? chart.meta.currency : "";
    var sl = _slots(chart, range);
    var price = _nulls(sl.n), vol = _nulls(sl.n), parts = _nulls(sl.n);
    spec.t = _nulls(sl.n);
    // The regular session's points (1D with periods; everything else is).
    var per = range === "1D" ? chart.periods : null;
    var regular = chart.t.map(function (t) {
        return !per || !_ok(per.start) || !_ok(per.end) || (t >= per.start && t < per.end);
    });
    var vmax = 0, lo = Infinity, hi = -Infinity;
    for (var k = 0; k < chart.t.length; k++) {
        var i = sl.idx[k];
        price[i] = chart.c[k];
        vol[i] = chart.v && _ok(chart.v[k]) ? chart.v[k] : null;
        spec.t[i] = chart.t[k];
        parts[i] = _parts(chart.t[k], off);
        vmax = Math.max(vmax, vol[i] || 0);
        lo = Math.min(lo, chart.c[k]);
        hi = Math.max(hi, chart.c[k]);
    }
    for (var e = 0; e < sl.n; e++)          // 1D's empty session slots still carry their time
        if (!parts[e])
            parts[e] = _parts((sl.t0 !== undefined ? sl.t0 : chart.t[0]) + e * SLOT_1D_MS, off);
    // The move is the session's: the last regular close (the extended hours
    // are drawn, and the header says their own move); a day with no session
    // yet (pre-market) ends on its last point.
    var last = chart.c[chart.c.length - 1];
    for (var r = chart.c.length - 1; r >= 0; r--)
        if (regular[r]) {
            last = chart.c[r];
            break;
        }
    // 1D measures from the previous close. A day whose points all come after
    // the last regular print (pre-market: no session yet today) measures from
    // that print -- Yahoo's meta still names the day before's close then.
    var prevC = chart.prevClose;
    var m0 = chart.meta;
    if (range === "1D" && m0 && _ok(m0.price) && _ok(m0.timeMs) && chart.t[0] > m0.timeMs)
        prevC = m0.price;
    var ref = range === "1D" && _ok(prevC) ? prevC : chart.c[0];
    spec.first = ref;
    spec.last = last;
    spec.change = last - ref;
    spec.changePct = ref ? (last - ref) / ref * 100 : 0;
    spec.role = last >= ref ? "gain" : "loss";

    // Volume is a faint texture in the bottom sixth, on its own range, under
    // the price. A dense range is BUCKETED to at most VOLUME_BARS bars (the
    // bucket's mean, at its middle slot): one 2 px bar per slot on 339 slots
    // overlaps into a solid band that outweighs the price line.
    if (vmax > 0) {
        var bars = _bucketVolume(vol, VOLUME_BARS);
        var bmax = 0;
        for (var q = 0; q < bars.length; q++)
            bmax = Math.max(bmax, bars[q] || 0);
        spec.series.push({ id: "volume", kind: "bars", values: bars, color: "faint",
                           range: [0, bmax * 6], alpha: 0.10 });
    }
    spec.readout = price;
    if (range === "1D") {
        // One line in parts; a single point (nothing to join) is its own price.
        var pp = _priceParts(sl.idx, chart.c, regular, sl.n);
        var line = chart.c.length === 1 ? price : pp.parts.price;
        spec.series.push({ id: "price", kind: "line", values: line, color: spec.role, width: 1.5,
                           curve: "linear", gradient: true, group: "price" });
        if (pp.any.fill)
            spec.series.push({ id: "fill", kind: "line", values: pp.parts.fill, color: spec.role, width: 1.5,
                               curve: "linear", dash: FILL_DASH, group: "price" });
        if (pp.any.ext)
            spec.series.push({ id: "ext", kind: "line", values: pp.parts.ext, color: spec.role, width: 1.5,
                               curve: "linear", alpha: EXT_ALPHA, group: "price" });
        if (pp.any.extFill)
            spec.series.push({ id: "extFill", kind: "line", values: pp.parts.extFill, color: spec.role,
                               width: 1.5, curve: "linear", alpha: EXT_ALPHA, dash: FILL_DASH, group: "price" });
    } else {
        spec.series.push({ id: "price", kind: "line", values: price, color: spec.role, width: 1.5,
                           curve: "linear", gradient: true, group: "price" });
    }
    spec.gradientStops = [{ value: lo, color: spec.role }, { value: hi, color: spec.role }];

    if (range === "1D" && _ok(prevC))
        spec.thresholds.push({ value: prevC, label: "Prev close", color: "muted",
                               extendsAxis: true });
    // The average cost: "auto" draws it only when it lies within half the
    // data's own span of that span (and then extends the axis to it); further
    // out it would squash the price to a line (ASML's 1D at 1,497 against an
    // average of 586), so it is left out. true / false force it, extending or not.
    var avg = holding && holding.shares > 0 ? holding.avgCostNative : NaN;
    if (_ok(avg) && avg > 0) {
        var mode = opts.avgExtends === undefined ? "auto" : opts.avgExtends;
        var slack = 0.5 * (hi - lo);
        if (mode !== "auto" || (avg >= lo - slack && avg <= hi + slack))
            spec.thresholds.push({ value: avg, label: "Avg cost", color: "faint",
                                   extendsAxis: mode !== false });
    }

    // Trades: the first slot whose day is on or after the trade's.
    var trades = holding && holding.trades ? holding.trades : [];
    var firstDay = parts[sl.idx[0]].day;
    var bySlot = {};
    for (var t = 0; t < trades.length; t++) {
        var tr = trades[t];
        if (tr.date < firstDay)
            continue;
        for (var s = 0; s < chart.t.length; s++) {
            var ix = sl.idx[s];
            if (parts[ix].day >= tr.date) {
                (bySlot[ix] = bySlot[ix] || []).push(tr);
                break;
            }
        }
    }
    var buys = _nulls(sl.n), sells = _nulls(sl.n), gb = _nulls(sl.n), gs = _nulls(sl.n);
    var anyBuy = false, anySell = false;
    var slotsWithTrades = Object.keys(bySlot).map(Number).sort(function (a, b) { return a - b; });
    for (var m = 0; m < slotsWithTrades.length; m++) {
        var si = slotsWithTrades[m], list = bySlot[si];
        var type = list[0].type;
        if (type === "sell") {
            sells[si] = price[si];
            gs[si] = "sell";
            anySell = true;
        } else {
            buys[si] = price[si];
            gb[si] = "buy";
            anyBuy = true;
        }
        spec.marks.push({ i: si, type: type, date: list[0].date,
                          text: list.map(function (x) { return _tradeText(x, currency, chart.meta ? chart.meta.priceHint : 2); }).join("\n"),
                          trades: list });
    }
    if (anyBuy)
        spec.series.push({ id: "buys", kind: "marks", values: buys, glyphs: gb, color: "buy" });
    if (anySell)
        spec.series.push({ id: "sells", kind: "marks", values: sells, glyphs: gs, color: "sell" });

    spec.xTicks = _ticks(parts, range, opts.maxTicks, opts.plotPx);
    spec.yMinSpan = Math.abs(last) * 0.01;
    return spec;
}

// ---- summary ----------------------------------------------------------------

// What the portfolio gained over a range, for the summary's top-right figure: the value's
// change from the range's first point to its last, LESS the money put in meanwhile (a share
// bought inside the range is not a gain: the series' own `invested` says what went in), and
// that as a share of what was at stake -- the first value plus what was added. A fully
// sold-down or empty range has no share (0). Null for a series with fewer than two points.
//
// The range's first point is the series' first slot: the first close of the first day of a
// daily range, the first 15-minute slot of 5D (before its first print a line stands at the
// close of the day before). A closed market adds nothing: the last point is its last close.
function rangeMove(series) {
    if (!series || !series.value || !series.invested || series.value.length < 2)
        return null;
    var n = series.value.length;
    var v0 = series.value[0], v1 = series.value[n - 1];
    var i0 = series.invested[0], i1 = series.invested[n - 1];
    if (!_ok(v0) || !_ok(v1) || !_ok(i0) || !_ok(i1))
        return null;
    var added = i1 - i0;
    var change = (v1 - v0) - added;
    var base = v0 + Math.max(0, added);
    return { change: change, pct: base > 0 ? change / base * 100 : 0 };
}

// Value vs invested: the value line coloured by where it ends against what is
// in it, the invested line a faint step (it moves only on a trade). The
// invested line follows the average-cost rule: "auto" draws it only when it
// lies within half the value's own span of that span; further out (a day, a
// month: 14k invested under a 41k value that moved 2k) it would flatten the
// value to a line, so it is left out, `investedShown` says so (the title
// drops "vs invested"), and the value is coloured by its own move over the
// range instead -- the gap to invested is no longer what is drawn. Ticks: 1D
// every 2 h, 5D day starts, 1M Mondays, 6M/YTD/1Y months, 5Y/ALL years, read
// in the series' own zone (`tzOffsetSec` of an intraday series; a daily one
// is by its `days`). 1D adds the dashed start-of-day line (`base`, "Day
// start", like the detail's prev close) and measures `change` from it (the
// day gain); every other range from its first point.
function summarySpec(series, opts) {
    opts = opts || {};
    var range = opts.range || "1M";
    var spec = { series: [], gradientStops: [], thresholds: [], xTicks: [], yMinSpan: 0, marks: [],
                 t: [], role: "gain", first: NaN, last: NaN, change: NaN, changePct: NaN,
                 investedShown: false };
    if (!series || !series.value || !series.value.length)
        return spec;
    var n = series.value.length;
    var val = series.value.slice(), inv = series.invested.slice();
    var lo = Infinity, hi = -Infinity;
    for (var i = 0; i < n; i++) {
        lo = Math.min(lo, val[i]);
        hi = Math.max(hi, val[i]);
    }
    var last = val[n - 1], lastInv = inv[n - 1];
    var dayBase = range === "1D" && _ok(series.base) ? series.base : NaN;
    var ref = _ok(dayBase) ? dayBase : val[0];
    spec.t = series.t.slice();
    spec.first = ref;
    spec.last = last;
    spec.change = last - ref;
    spec.changePct = ref ? (last - ref) / ref * 100 : 0;
    var invLo = Infinity, invHi = -Infinity;
    for (var q = 0; q < n; q++) {
        if (!_ok(inv[q]))
            continue;
        invLo = Math.min(invLo, inv[q]);
        invHi = Math.max(invHi, inv[q]);
    }
    var mode = opts.investedExtends === undefined ? "auto" : opts.investedExtends;
    var slack = 0.5 * (hi - lo);
    spec.investedShown = invLo <= invHi
        && (mode !== "auto" || (invLo <= hi + slack && invHi >= lo - slack));
    spec.role = spec.investedShown ? (last >= lastInv ? "gain" : "loss")
                                   : (last >= ref ? "gain" : "loss");
    if (spec.investedShown)
        spec.series.push({ id: "invested", kind: "line", values: inv, color: "faint", width: 1.25,
                           curve: "step" });
    spec.series.push({ id: "value", kind: "line", values: val, color: spec.role, width: 1.5,
                       curve: "linear", gradient: true });
    spec.gradientStops = [{ value: lo, color: spec.role }, { value: hi, color: spec.role }];
    if (_ok(dayBase))
        spec.thresholds.push({ value: dayBase, label: "Day start", color: "muted", extendsAxis: true });
    var off = _ok(series.tzOffsetSec) ? series.tzOffsetSec : 0;
    var parts = [];
    for (var k = 0; k < n; k++)
        parts.push(series.days && series.days[k] ? _parts(Markets.dayMs(series.days[k]), 0)
                                                 : _parts(series.t[k], off));
    spec.xTicks = _ticks(parts, range, opts.maxTicks, opts.plotPx);
    spec.yMinSpan = Math.abs(last) * 0.01;
    return spec;
}

// The loading picture a chart morphs into while its data is on the way, and
// out of when it lands: one faint line of a plausible shape on its OWN 0..1
// range (so the held axis's grid stays and no figure is claimed), carrying the
// real line's id -- the morph pairs the two by id and reshapes one into the
// other instead of fading them through each other. Static: the morph in and
// out is the motion. `skeleton: true` tells the host to set the chart's
// `skeleton` (grid without labels, the plot where it stood).
var SKELETON_POINTS = 48;
function skeletonSpec(opts) {
    opts = opts || {};
    var vals = [];
    for (var i = 0; i < SKELETON_POINTS; i++) {
        var u = i / (SKELETON_POINTS - 1);
        vals.push(0.42 + 0.09 * Math.sin(u * 2 * Math.PI * 1.15 + 0.5)
                  + 0.04 * Math.sin(u * 2 * Math.PI * 3.3) + 0.08 * u);
    }
    return {
        skeleton: true,
        series: [{ id: opts.id || "price", kind: "line", values: vals, color: "faint", width: 1.5,
                   curve: "linear", gradient: true, range: [0, 1], group: opts.id || "price" }],
        gradientStops: [{ value: 0, color: "faint" }, { value: 1, color: "faint" }],
        thresholds: [], xTicks: [], yMinSpan: 0, marks: [], t: [],
        role: "faint", first: NaN, last: NaN, change: NaN, changePct: NaN, investedShown: false
    };
}

