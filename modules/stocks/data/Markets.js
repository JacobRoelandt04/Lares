.pragma library

// =============================================================================
// Markets.js -- everything about the market sources that is pure strings and
// numbers: URLs, parsers, currencies, CNBC symbology, the trading clock, the
// fetch cadence and the alert latches. No Qt, so it runs under node. Contract:
// docs/stocks.md (percent units, ms times, days
// "YYYY-MM-DD" in the exchange's own zone).
//
// URLS ARE BUILT BYTE FOR BYTE AS CAPTURED (modules/stocks/data/fixtures/urls.tsv):
// the fake curl serves by exact URL, so one reordered parameter is a miss.
// Symbols are encoded like the capture tool's `urllib.parse.quote(s, safe="")`
// (RFC 3986 strict: `!'()*` encoded too, which encodeURIComponent leaves).
//
// DAYS OF A BAR. A daily/weekly/monthly bar sits at the session's LOCAL start
// (00:00 for FX and the monthly bars, 09:00 in Europe, 09:30 in New York),
// but the only offset a chart carries is the CURRENT one (`gmtoffset`), which
// is an hour off for every bar on the other side of a DST change: a winter
// capture reads a summer midnight bar as 23:00 the day before. `barDay` adds
// an hour before taking the date, which no session start is near.
// =============================================================================

var MIN_MS = 60000;
var HOUR_MS = 3600000;
var DAY_MS = 86400000;

var SPARK_MAX = 20;         // 27 symbols -> HTTP 400
var Y1 = "https://query1.finance.yahoo.com";
var Y2 = "https://query2.finance.yahoo.com";
var CNBC = "https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol";
var EUROSTAT = "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/prc_hicp_minr";

// The detail's ranges: [Yahoo range, interval]. Points: stock.md "Measured facts".
var RANGES = {
    "1D": ["1d", "5m"], "5D": ["5d", "15m"], "1M": ["1mo", "60m"],
    "6M": ["6mo", "1d"], "YTD": ["ytd", "1d"], "1Y": ["1y", "1d"],
    "5Y": ["5y", "1wk"], "MAX": ["max", "1mo"]
};
var RANGE_KEYS = ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "MAX"];

var MARKET_TYPES = { EQUITY: true, ETF: true, INDEX: true, MUTUALFUND: true };

// -----------------------------------------------------------------------------
// Days
// -----------------------------------------------------------------------------

function _pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

// ms -> "YYYY-MM-DD" at a fixed offset (seconds east of UTC, Yahoo's unit).
function dayKey(ms, gmtoffsetSec) {
    var d = new Date(ms + (gmtoffsetSec || 0) * 1000);
    return d.getUTCFullYear() + "-" + _pad2(d.getUTCMonth() + 1) + "-" + _pad2(d.getUTCDate());
}

// The day of a daily-or-coarser bar (header: one hour of DST slack).
function barDay(ms, gmtoffsetSec) {
    return dayKey(ms + HOUR_MS, gmtoffsetSec);
}

// "YYYY-MM-DD" -> ms of its UTC midnight (NaN when malformed).
function dayMs(day) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ""));
    if (!m)
        return NaN;
    var y = +m[1], mo = +m[2], d = +m[3];
    var t = Date.UTC(y, mo - 1, d);
    var back = new Date(t);
    if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d)
        return NaN;                         // 2025-02-30 is not a day
    return t;
}

function addDays(day, n) {
    return dayKey(dayMs(day) + n * DAY_MS, 0);
}

// 0 = Sunday .. 6 = Saturday.
function weekday(day) {
    return new Date(dayMs(day)).getUTCDay();
}

// -----------------------------------------------------------------------------
// Currencies and symbols
// -----------------------------------------------------------------------------

// Minor-unit quotes: London in pence, Johannesburg in cents, Tel Aviv in agorot.
function normCurrency(c) {
    var s = String(c || "");
    if (s === "GBp" || s === "GBX")
        return { code: "GBP", scale: 0.01 };
    if (s === "ZAc" || s === "ZAC")
        return { code: "ZAR", scale: 0.01 };
    if (s === "ILA")
        return { code: "ILS", scale: 0.01 };
    return { code: s, scale: 1 };
}

// Euro per unit of `code` (a minor unit is normalised first).
function fxSymbol(code) {
    var c = normCurrency(code).code;
    if (!c || c === "EUR")
        return null;
    return c + "EUR=X";
}

function isFxSymbol(sym) {
    return /=X$/.test(String(sym || ""));
}

// Yahoo suffix -> CNBC country suffix, verified by tools/stocks/verify_cnbc_map.sh.
// .CO .ST .T .HK .VI answer nothing in any form tried: null,
// and the holding's `cnbc` key is the way out. Amsterdam ETFs map but CNBC
// does not know them (code != 0): parseCnbc makes that a row of nulls.
var CNBC_SUFFIX = {
    AS: "NL", BR: "BE", PA: "FR", DE: "DE", L: "GB", SW: "CH", MI: "IT",
    MC: "ES", HE: "FI", OL: "NO", LS: "PT", TO: "CA"
};
var CNBC_SPECIAL = { "^GSPC": ".SPX", "EURUSD=X": "EUR=" };

function cnbcSymbol(yahoo, override) {
    if (typeof override === "string" && override !== "")
        return override;
    var s = String(yahoo || "");
    if (s === "")
        return null;
    if (CNBC_SPECIAL.hasOwnProperty(s))
        return CNBC_SPECIAL[s];
    if (s.charAt(0) === "^")
        return "." + s.substring(1);
    if (isFxSymbol(s))
        return null;
    var dot = s.lastIndexOf(".");
    if (dot > 0) {
        var cc = CNBC_SUFFIX[s.substring(dot + 1)];
        return cc ? s.substring(0, dot) + "-" + cc : null;
    }
    // Bare US listing; a share class is a dash at Yahoo and a dot at CNBC.
    if (/^[A-Z0-9]{1,6}(-[A-Z])?$/.test(s))
        return s.replace("-", ".");
    return null;
}

// -----------------------------------------------------------------------------
// URLs
// -----------------------------------------------------------------------------

function enc(s) {
    return encodeURIComponent(String(s)).replace(/[!'()*]/g, function (ch) {
        return "%" + ch.charCodeAt(0).toString(16).toUpperCase();
    });
}

// Chunks of <= 20, first occurrence kept, order kept. `range` "1D" (the
// default: 1d / 5m, the cadence's) or "5D" (5d / 15m, the summary's 5D).
// `prePost` asks for the extended sessions too (the pre/post-market call: US
// listings only, and only its `ext` is read -- during pre-market the day it
// answers has no regular point yet, so its spark is not the day's).
function sparkUrls(symbols, range, prePost) {
    var r = RANGES[range === "5D" ? "5D" : "1D"];
    var seen = {}, list = [];
    for (var i = 0; i < (symbols || []).length; i++) {
        var s = String(symbols[i] || "");
        if (s === "" || seen[s])
            continue;
        seen[s] = true;
        list.push(s);
    }
    var out = [];
    for (var j = 0; j < list.length; j += SPARK_MAX)
        out.push(Y1 + "/v7/finance/spark?symbols="
                 + list.slice(j, j + SPARK_MAX).map(enc).join(",")
                 + "&range=" + r[0] + "&interval=" + r[1]
                 + (prePost ? "&includePrePost=true" : ""));
    return out;
}

// One symbol's day at one-minute bars (a sudden-move card sharpens its span with it): the spark endpoint, 1d / 1m,
// regular session only (measured 2026-11-21: NVDA, 388 points, 8 KB). Parsed by parseSpark.
function fineSparkUrl(sym) {
    return Y1 + "/v7/finance/spark?symbols=" + enc(sym) + "&range=1d&interval=1m";
}

// The mock's 1-minute day: a captured day of 1-minute bars (`fine`, its open at `fineStartMs`) laid onto a quote's own 5-minute
// day (`base`, its open at `baseStartMs`): the base line, interpolated at each minute, times the fine day's own wiggle about
// its 5-minute line. A bar of the base's range only (the mock's walk past the capture stays 5-minute).
function fineOnto(fine, base, fineStartMs, baseStartMs) {
    var at = function (t, c, x) {
        if (!t.length) return NaN;
        if (x <= t[0]) return c[0];
        for (var i = 1; i < t.length; i++)
            if (x <= t[i]) return c[i - 1] + (c[i] - c[i - 1]) * (x - t[i - 1]) / (t[i] - t[i - 1]);
        return c[c.length - 1];
    };
    var a5t = [], a5c = [];
    for (var i = 0; i < fine.t.length; i++)
        if (Math.round((fine.t[i] - fineStartMs) / 60000) % 5 === 0) { a5t.push(fine.t[i]); a5c.push(fine.c[i]); }
    var t = [], c = [];
    var last = base.t.length ? base.t[base.t.length - 1] : -Infinity;
    for (var j = 0; j < fine.t.length; j++) {
        var tt = fine.t[j] - fineStartMs + baseStartMs;
        if (tt > last) break;
        var ref = at(a5t, a5c, fine.t[j]);
        var b = at(base.t, base.c, tt);
        if (!isFinite(ref) || !isFinite(b) || ref === 0) continue;
        t.push(tt);
        c.push(b * fine.c[j] / ref);
    }
    return { t: t, c: c };
}

// `prePost` (a listing with extended sessions) takes them on 1D only: the
// day's axis runs from the pre-market's start to the post-market's end.
function chartUrl(sym, range, prePost) {
    var r = RANGES[range] || RANGES["1D"];
    return Y1 + "/v8/finance/chart/" + enc(sym) + "?range=" + r[0] + "&interval=" + r[1]
            + (prePost && r[0] === "1d" ? "&includePrePost=true" : "")
            + "&events=div%2Csplit";
}

// Daily closes from `fromDay` (the caller subtracts its week of slack) to
// `toMs`. An FX pair has no events and is asked without them, as captured.
function historyUrl(sym, fromDay, toMs) {
    var p1 = Math.floor(dayMs(fromDay) / 1000);
    var p2 = Math.floor(toMs / 1000);
    return Y1 + "/v8/finance/chart/" + enc(sym) + "?period1=" + p1 + "&period2=" + p2
            + "&interval=1d" + (isFxSymbol(sym) ? "" : "&events=div%2Csplit");
}

function searchUrl(q) {
    return Y2 + "/v1/finance/search?q=" + enc(q) + "&quotesCount=8&newsCount=0";
}

function cnbcUrl(list) {
    return CNBC + "?symbols=" + enc((list || []).join("|"))
            + "&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json";
}

function hicpUrl(geo) {
    return EUROSTAT + "?format=JSON&geo=" + enc(geo || "BE")
            + "&coicop18=TOTAL&unit=I15&sinceTimePeriod=1996-01";
}

// A stock's page: `template` with {symbol} (stocks.jsonc quoteUrl), Yahoo's by default.
function quoteUrl(sym, template) {
    return String(template || "https://finance.yahoo.com/quote/{symbol}").split("{symbol}").join(enc(sym));
}

// -----------------------------------------------------------------------------
// Parsers. Each takes the parsed JSON or its text; a shape it cannot read is
// null ({} / [] for the collections), never a throw.
// -----------------------------------------------------------------------------

function _json(j) {
    if (typeof j === "string") {
        try {
            return JSON.parse(j);
        } catch (e) {
            return null;
        }
    }
    return j || null;
}

function _num(v) {
    return (typeof v === "number" && isFinite(v)) ? v : null;
}

function _sec(v) {
    return (typeof v === "number" && isFinite(v)) ? v * 1000 : null;
}

// Yahoo's `meta` -> Quote (no spark). `prevClose` is the session's previous
// close: `previousClose` where Yahoo gives it, `chartPreviousClose` only for a
// 1d range (for longer ranges that is the close before the RANGE), else
// derived from Yahoo's own day percentage.
function _quoteFromMeta(m, nowMs) {
    var price = _num(m.regularMarketPrice);
    var prev = _num(m.previousClose);
    if (prev === null && m.range === "1d")
        prev = _num(m.chartPreviousClose);
    if (prev === null && price !== null && _num(m.regularMarketChangePercent) !== null)
        prev = price / (1 + m.regularMarketChangePercent / 100);
    var ctp = m.currentTradingPeriod || {};
    var pre = ctp.pre || {}, reg = ctp.regular || {}, post = ctp.post || {};
    var q = {
        symbol: String(m.symbol || ""),
        name: String(m.longName || m.shortName || m.symbol || ""),
        shortName: String(m.shortName || m.longName || m.symbol || ""),
        exchange: String(m.exchangeName || ""),
        fullExchange: String(m.fullExchangeName || m.exchangeName || ""),
        currency: String(m.currency || ""),
        type: String(m.instrumentType || ""),
        priceHint: _num(m.priceHint) !== null ? m.priceHint : 2,
        prePost: m.hasPrePostMarketData === true,
        price: price,
        prevClose: prev,
        change: (price !== null && prev !== null) ? price - prev : null,
        changePct: (price !== null && prev) ? (price - prev) / prev * 100
                                            : _num(m.regularMarketChangePercent),
        dayHigh: _num(m.regularMarketDayHigh),
        dayLow: _num(m.regularMarketDayLow),
        volume: _num(m.regularMarketVolume),
        w52Hi: _num(m.fiftyTwoWeekHigh),
        w52Lo: _num(m.fiftyTwoWeekLow),
        timeMs: _sec(m.regularMarketTime),
        tz: String(m.exchangeTimezoneName || ""),
        gmtoffset: _num(m.gmtoffset) !== null ? m.gmtoffset : 0,
        session: {
            preStart: _sec(pre.start !== undefined ? pre.start : reg.start),
            start: _sec(reg.start),
            end: _sec(reg.end),
            postEnd: _sec(post.end !== undefined ? post.end : reg.end)
        },
        state: "closed"
    };
    q.state = marketState(q, nowMs === undefined ? Date.now() : nowMs);
    return q;
}

// { SYM: Quote }. Spark answers out of request order: keyed by symbol.
//
// `opts.prePost` (an answer asked with includePrePost): each point is placed
// by its time against the quote's regular session -- before its start is
// pre-market, from its end on post-market -- `spark` keeps the regular ones
// and `ext` is the extended move (extOf). Without it nothing is classified:
// a regular answer's last print can sit exactly on the session's end.
function parseSpark(json, nowMs, opts) {
    var j = _json(json), out = {};
    var res = j && j.spark && j.spark.result;
    if (!res)
        return out;
    for (var i = 0; i < res.length; i++) {
        var r = res[i], resp = r && r.response && r.response[0];
        if (!resp || !resp.meta)
            continue;
        var q = _quoteFromMeta(resp.meta, nowMs);
        if (!q.symbol)
            q.symbol = String(r.symbol || "");
        var ts = resp.timestamp || [];
        var cl = (resp.indicators && resp.indicators.quote && resp.indicators.quote[0]
                  && resp.indicators.quote[0].close) || [];
        var t = [], c = [];
        for (var k = 0; k < ts.length && k < cl.length; k++) {
            if (_num(cl[k]) === null)
                continue;
            t.push(ts[k] * 1000);
            c.push(cl[k]);
        }
        q.spark = { t: t, c: c };
        if (opts && opts.prePost) {
            var sp = splitSessions(q, t, c, nowMs);
            q.spark = { t: sp.regular.t, c: sp.regular.c };
            q.ext = extOf(q, sp);
        }
        out[r.symbol || q.symbol] = q;
    }
    return out;
}

function _rangeKey(yahooRange) {
    for (var k in RANGES)
        if (RANGES[k][0] === yahooRange)
            return k;
    return String(yahooRange || "");
}

function _events(obj, fn) {
    var out = [];
    for (var k in (obj || {})) {
        var e = obj[k];
        if (e && typeof e.date === "number")
            out.push(fn(e));
    }
    out.sort(function (a, b) { return a.t - b.t; });
    return out;
}

// The day's sessions from a chart's `tradingPeriods` (the answered day's, where
// `currentTradingPeriod` is TODAY's even for yesterday's data): { preStart,
// start, end, postEnd } in ms, the last day listed; null when absent. Yahoo
// sends an object of pre / regular / post lists with includePrePost, a bare
// list of regular periods without.
function _periods(tp) {
    if (!tp)
        return null;
    var last = function (list) {
        var flat = [];
        (Array.isArray(list) ? list : []).forEach(function (d) {
            (Array.isArray(d) ? d : [d]).forEach(function (x) { if (x) flat.push(x); });
        });
        return flat.length ? flat[flat.length - 1] : null;
    };
    var reg = Array.isArray(tp) ? last(tp) : last(tp.regular);
    if (!reg || _num(reg.start) === null || _num(reg.end) === null)
        return null;
    var pre = Array.isArray(tp) ? null : last(tp.pre), post = Array.isArray(tp) ? null : last(tp.post);
    return { preStart: pre && _num(pre.start) !== null ? pre.start * 1000 : reg.start * 1000,
             start: reg.start * 1000, end: reg.end * 1000,
             postEnd: post && _num(post.end) !== null ? post.end * 1000 : reg.end * 1000 };
}

// Chart; points whose close is null are dropped from every array together.
// `periods` is the answered day's sessions (_periods).
function parseChart(json, nowMs) {
    var j = _json(json);
    var r = j && j.chart && j.chart.result && j.chart.result[0];
    if (!r || !r.meta)
        return null;
    var m = r.meta;
    var q = (r.indicators && r.indicators.quote && r.indicators.quote[0]) || {};
    var ts = r.timestamp || [];
    var ch = { symbol: String(m.symbol || ""), range: _rangeKey(m.range),
               t: [], o: [], h: [], l: [], c: [], v: [],
               prevClose: _num(m.chartPreviousClose),
               meta: _quoteFromMeta(m, nowMs), dividends: [], splits: [],
               periods: _periods(m.tradingPeriods) };
    for (var i = 0; i < ts.length; i++) {
        var c = q.close ? q.close[i] : null;
        if (_num(c) === null)
            continue;
        ch.t.push(ts[i] * 1000);
        ch.c.push(c);
        ch.o.push(q.open && _num(q.open[i]) !== null ? q.open[i] : c);
        ch.h.push(q.high && _num(q.high[i]) !== null ? q.high[i] : c);
        ch.l.push(q.low && _num(q.low[i]) !== null ? q.low[i] : c);
        ch.v.push(q.volume && _num(q.volume[i]) !== null ? q.volume[i] : 0);
    }
    var ev = r.events || {};
    ch.dividends = _events(ev.dividends, function (e) {
        return { t: e.date * 1000, amount: e.amount };
    });
    ch.splits = _events(ev.splits, function (e) {
        return { t: e.date * 1000, num: e.numerator, den: e.denominator };
    });
    return ch;
}

function parseSearch(json) {
    var j = _json(json), out = [];
    var qs = (j && j.quotes) || [];
    for (var i = 0; i < qs.length; i++) {
        var q = qs[i];
        if (!q || !q.symbol || q.isYahooFinance === false)
            continue;
        out.push({ symbol: String(q.symbol),
                   name: String(q.longname || q.shortname || q.symbol),
                   exchDisp: String(q.exchDisp || q.exchange || ""),
                   typeDisp: String(q.typeDisp || ""),
                   quoteType: String(q.quoteType || "") });
    }
    return out;
}

function _str(v) {
    return (typeof v === "string" && v !== "") ? v : null;
}

// { cnbcSym: {mcap, pe, eps, divYield, beta, avgVol} } in CNBC's own strings.
// An unknown symbol (code != 0) is a row of nulls, so "asked, nothing there"
// reads apart from "not asked".
function parseCnbc(json) {
    var j = _json(json), out = {};
    var fq = j && j.FormattedQuoteResult && j.FormattedQuoteResult.FormattedQuote;
    if (!fq)
        return out;
    if (!Array.isArray(fq))
        fq = [fq];
    for (var i = 0; i < fq.length; i++) {
        var r = fq[i];
        if (!r || !r.symbol)
            continue;
        var ok = r.code === 0 || r.code === "0";
        out[r.symbol] = {
            mcap: ok ? _str(r.mktcapView) : null,
            pe: ok ? _str(r.pe) : null,
            eps: ok ? _str(r.eps) : null,
            divYield: ok ? _str(r.dividendyield) : null,
            beta: ok ? _str(r.beta) : null,
            avgVol: ok ? _str(r.tendayavgvol) : null
        };
    }
    return out;
}

// Eurostat JSON-stat -> { "YYYY-MM": index }. The flat value index is the
// row-major position over `id`/`size`; every dimension but time has one member.
function parseHicp(json) {
    var j = _json(json), out = {};
    if (!j || !j.value || !j.id || !j.size || !j.dimension || !j.dimension.time)
        return out;
    var ti = j.id.indexOf("time");
    if (ti < 0)
        return out;
    var stride = 1;
    for (var k = ti + 1; k < j.size.length; k++)
        stride *= j.size[k];
    var idx = j.dimension.time.category.index || {};
    for (var period in idx) {
        var v = j.value[String(idx[period] * stride)];
        if (typeof v === "number" && isFinite(v))
            out[period] = v;
    }
    return out;
}

// -----------------------------------------------------------------------------
// The trading clock
// -----------------------------------------------------------------------------

// An exchange's clock. A chart carries ONE offset (`gmtoffset`, the exchange's at the response) and the zone's name
// (`tz`); the offset an hour or a day AWAY from the response is the same plus or minus the hour the zone's DST rule
// adds. The rules known here are the ones the user's exchanges follow (US/Canada, Europe and the UK, Australia's
// southern states, New Zealand); any other zone is taken as fixed. Transitions are taken at the zone's current
// offset, which is off by at most an hour on a Sunday night when no market is open.
// tools/dev/dst_audit_cases.js K1-K3.
var _EU_NOT = { "Europe/Moscow": 1, "Europe/Istanbul": 1, "Europe/Minsk": 1, "Europe/Kaliningrad": 1, "Europe/Volgograd": 1,
                "Europe/Samara": 1, "Europe/Simferopol": 1, "Europe/Kirov": 1, "Europe/Astrakhan": 1, "Europe/Saratov": 1,
                "Europe/Ulyanovsk": 1 };
var _US = { "America/New_York": 1, "America/Chicago": 1, "America/Denver": 1, "America/Los_Angeles": 1, "America/Toronto": 1,
            "America/Vancouver": 1, "America/Halifax": 1, "America/Detroit": 1, "America/Edmonton": 1, "America/Winnipeg": 1 };
var _AU = { "Australia/Sydney": 1, "Australia/Melbourne": 1, "Australia/Hobart": 1, "Australia/Canberra": 1, "Australia/Adelaide": 1 };

function _dstRule(tz) {
    tz = String(tz || "");
    if (_US[tz]) return "us";
    if (tz.indexOf("Europe/") === 0 && !_EU_NOT[tz]) return "eu";
    if (_AU[tz]) return "au";
    if (tz === "Pacific/Auckland") return "nz";
    return "";
}

// Day of the month of the nth Sunday (n = -1: the last) of a month (0-based), UTC calendar.
function _sunday(year, month, n) {
    if (n > 0) {
        var first = new Date(Date.UTC(year, month, 1)).getUTCDay();
        return 1 + (7 - first) % 7 + (n - 1) * 7;
    }
    var last = new Date(Date.UTC(year, month + 1, 0));
    return last.getUTCDate() - last.getUTCDay();
}

// 1 while the zone's DST is in force at `ms`, 0 otherwise; `std` is the zone's offset in seconds (see above).
function _dstAt(rule, ms, std) {
    var y = new Date(ms).getUTCFullYear(), so = std * 1000;
    switch (rule) {
    case "us":
        return ms >= Date.UTC(y, 2, _sunday(y, 2, 2)) + 2 * HOUR_MS - so && ms < Date.UTC(y, 10, _sunday(y, 10, 1)) + HOUR_MS - so ? 1 : 0;
    case "eu":
        return ms >= Date.UTC(y, 2, _sunday(y, 2, -1), 1) && ms < Date.UTC(y, 9, _sunday(y, 9, -1), 1) ? 1 : 0;
    case "au":
        return ms < Date.UTC(y, 3, _sunday(y, 3, 1)) + 2 * HOUR_MS - so || ms >= Date.UTC(y, 9, _sunday(y, 9, 1)) + 2 * HOUR_MS - so ? 1 : 0;
    case "nz":
        return ms < Date.UTC(y, 3, _sunday(y, 3, 1)) + 2 * HOUR_MS - so || ms >= Date.UTC(y, 8, _sunday(y, 8, -1)) + 2 * HOUR_MS - so ? 1 : 0;
    }
    return 0;
}

// The exchange's UTC offset in seconds at `ms`, given the quote's offset as of `refMs` (when it was read).
function offsetAt(q, ms, refMs) {
    var base = q && q.gmtoffset ? q.gmtoffset : 0;
    var rule = q ? _dstRule(q.tz) : "";
    if (!rule || !isFinite(ms) || !isFinite(refMs))
        return base;
    return base + 3600 * (_dstAt(rule, ms, base) - _dstAt(rule, refMs, base));
}

// From Yahoo's current trading period; an exchange with no pre-market has a
// pre period of zero length, so it is never "pre".
// A day's points by session, against the quote's regular session's time of
// day (in the exchange's own time, so yesterday's points place too; `refMs` is when the quote was read, parseSpark's
// now): before
// its start pre, from its end on post. { pre, regular, post: { t, c } }.
function splitSessions(q, t, c, refMs) {
    var out = { pre: { t: [], c: [] }, regular: { t: [], c: [] }, post: { t: [], c: [] } };
    var s = q && q.session;
    // each instant in the exchange's clock OF ITS OWN DAY: a Friday bar read on the Monday after the exchange's DST change
    var ref = isFinite(refMs) ? refMs : (t && t.length ? t[t.length - 1] : 0);
    var tod = function (ms) { return ((ms + offsetAt(q, ms, ref) * 1000) % 86400000 + 86400000) % 86400000; };
    var ok = s && _num(s.start) !== null && _num(s.end) !== null;
    var st = ok ? tod(s.start) : 0, en = ok ? tod(s.end) : 0;
    for (var i = 0; i < t.length; i++) {
        var k = !ok ? "regular" : (tod(t[i]) < st ? "pre" : (tod(t[i]) >= en ? "post" : "regular"));
        out[k].t.push(t[i]);
        out[k].c.push(c[i]);
    }
    return out;
}

// The extended-hours move Yahoo shows under the price: pre-market while the
// session has not opened (its last print against the last close), after
// hours from the close until the next pre-market (the day's last post print
// against that close). Nothing while the regular session runs, and nothing
// for a listing without extended sessions. { kind: "pre" | "post", price,
// base, change, changePct, timeMs } or null.
function extOf(q, sp) {
    if (!q || !q.prePost || _num(q.price) === null || q.state === "open")
        return null;
    var kind = null, list = null;
    if (q.state === "pre" && sp.pre.t.length > 0 && sp.post.t.length === 0) {
        kind = "pre";
        list = sp.pre;
    } else if (q.state !== "pre" && sp.post.t.length > 0) {
        kind = "post";
        list = sp.post;
    }
    if (!kind)
        return null;
    var price = list.c[list.c.length - 1], base = q.price;
    return { kind: kind, price: price, base: base, change: price - base,
             changePct: base ? (price - base) / base * 100 : 0, timeMs: list.t[list.t.length - 1] };
}

// Which extended moves are shown now: { SYM: ext } of those still true of the
// quote's session at `nowMs` -- a pre-market move while it is pre-market, an
// after-hours one from the close until the next pre-market (Yahoo's own).
function extVisible(ext, quotes, nowMs) {
    var out = {};
    for (var s in (ext || {})) {
        var e = ext[s], q = quotes && quotes[s];
        if (!e || !q)
            continue;
        var st = marketState(q, nowMs);
        if ((e.kind === "pre" && st === "pre") || (e.kind === "post" && st !== "open" && st !== "pre"))
            out[s] = e;
    }
    return out;
}

// The symbols whose extended move is worth asking for at `nowMs`: listings
// with extended sessions that are not in their regular one.
function extSymbols(symbols, quotes, nowMs) {
    return (symbols || []).filter(function (s) {
        var q = quotes && quotes[s];
        return !!q && q.prePost === true && marketState(q, nowMs) !== "open";
    });
}

function marketState(q, nowMs) {
    var s = q && q.session;
    if (!s || s.start === null || s.end === null || s.start === undefined)
        return "closed";
    var pre = s.preStart !== null && s.preStart !== undefined ? s.preStart : s.start;
    var post = s.postEnd !== null && s.postEnd !== undefined ? s.postEnd : s.end;
    if (nowMs >= s.start && nowMs < s.end)
        return "open";
    if (nowMs >= pre && nowMs < s.start)
        return "pre";
    if (nowMs >= s.end && nowMs < post)
        return "post";
    return "closed";
}

// Equities, funds and indices drive the cadence; FX and crypto trade ~24 h
// and would keep it awake for ever.
function isMarketType(q) {
    var t = typeof q === "string" ? q : (q && q.type);
    return MARKET_TYPES[String(t || "").toUpperCase()] === true;
}

function _isWeekendAt(ms, off) {
    var wd = new Date(ms + (off || 0) * 1000).getUTCDay();
    return wd === 0 || wd === 6;
}

// The next regular open after `nowMs`, predicted from the session Yahoo last
// gave: the same local time on the next weekday (holidays are not known; the
// cap and the re-check at that open absorb them).
function _nextOpen(q, nowMs, refMs) {
    var s = q.session, o0 = offsetAt(q, s.start, refMs);
    // whole days carry the session's UTC time; the exchange's clock may have moved an hour since (a Sunday change)
    var at = function (raw) { return raw - (offsetAt(q, raw, refMs) - o0) * 1000; };
    var raw = s.start, t = raw;
    while (t <= nowMs) {
        raw += DAY_MS;
        t = at(raw);
    }
    for (var k = 0; k < 7 && _isWeekendAt(t, offsetAt(q, t, refMs)); k++) {
        raw += DAY_MS;
        t = at(raw);
    }
    return t;
}

// The last regular close at or before `nowMs` (weekends skipped, holidays not known).
function lastClose(q, nowMs) {
    var e = q.session.end;
    while (e > nowMs)
        e -= DAY_MS;
    for (var k = 0; k < 7 && _isWeekendAt(e, q.gmtoffset); k++)
        e -= DAY_MS;
    return e;
}

var CLOSE_SETTLE_MS = 2 * MIN_MS;     // Yahoo's closing print lands after the bell
var STALE_OPEN_MS = 30 * MIN_MS;      // opening the popup over an older cache fetches
var IDLE_CAP_MS = 6 * HOUR_MS;

// ms until the next spark fetch (stock.md "Cadence"):
//   any market-type quote open  -> every openMs (popup open) / closedMs
//   all closed                  -> once at the last close + 2 min, then idle
//                                  until the predicted next open, cap 6 h;
//                                  with the popup open, a cache older than
//                                  30 min is fetched at once.
function nextFetchDelay(o) {
    var quotes = o.quotes || {}, now = o.nowMs;
    var last = o.lastFetchMs || 0;
    var openMs = o.openMs > 0 ? o.openMs : MIN_MS;
    var closedMs = o.closedMs > 0 ? o.closedMs : 5 * MIN_MS;
    if (!last)
        return 0;
    var anyOpen = false, latest = -Infinity, nextOpen = Infinity;
    for (var sym in quotes) {
        var q = quotes[sym];
        if (!isMarketType(q) || !q.session || q.session.start === null || q.session.start === undefined)
            continue;
        if (marketState(q, now) === "open")
            anyOpen = true;
        latest = Math.max(latest, lastClose(q, now));
        nextOpen = Math.min(nextOpen, _nextOpen(q, now, last));
    }
    if (anyOpen)
        return Math.max(0, last + (o.popupOpen ? openMs : closedMs) - now);
    if (isFinite(latest) && last < latest + CLOSE_SETTLE_MS)
        return Math.max(0, latest + CLOSE_SETTLE_MS - now);
    if (o.popupOpen && now - last > STALE_OPEN_MS)
        return 0;
    return Math.max(0, Math.min(nextOpen - now, IDLE_CAP_MS));
}

// -----------------------------------------------------------------------------
// Alerts: above / below / dayMove, once per crossing.
//
// A latch is keyed by symbol|kind|level, so editing a level re-arms it and a
// reordered file keeps it. above/below re-arm once the price has moved back
// past the level by `hysteresis` (a fraction); dayMove fires once per session
// day and re-arms on the next `dayKey` (a string, or a function of the quote).
// "*" applies an alert to every quote passed. Returns NEW latches.
// -----------------------------------------------------------------------------

function evalAlerts(alerts, quotes, latches, hysteresis, dayKeyArg) {
    var h = (typeof hysteresis === "number" && hysteresis >= 0) ? hysteresis : 0.005;
    var next = {}, fire = [];
    for (var lk in (latches || {}))
        next[lk] = latches[lk];
    quotes = quotes || {};
    for (var i = 0; i < (alerts || []).length; i++) {
        var a = alerts[i];
        if (!a || !a.symbol)
            continue;
        var syms = a.symbol === "*" ? Object.keys(quotes) : [a.symbol];
        for (var s = 0; s < syms.length; s++) {
            var q = quotes[syms[s]];
            if (!q || typeof q.price !== "number" || !isFinite(q.price))
                continue;
            var kinds = ["above", "below", "dayMove"];
            for (var k = 0; k < kinds.length; k++) {
                var kind = kinds[k], level = a[kind];
                if (typeof level !== "number" || !isFinite(level))
                    continue;
                var key = syms[s] + "|" + kind + "|" + level;
                var hit = false;
                if (kind === "above") {
                    if (next[key] && q.price < level * (1 - h))
                        delete next[key];
                    hit = !next[key] && q.price >= level;
                    if (hit) next[key] = true;
                } else if (kind === "below") {
                    if (next[key] && q.price > level * (1 + h))
                        delete next[key];
                    hit = !next[key] && q.price <= level;
                    if (hit) next[key] = true;
                } else {
                    var day = typeof dayKeyArg === "function" ? dayKeyArg(q) : String(dayKeyArg || "");
                    var pct = typeof q.changePct === "number" ? q.changePct : NaN;
                    hit = next[key] !== day && Math.abs(pct) >= Math.abs(level);
                    if (hit) next[key] = day;
                }
                if (hit)
                    fire.push({ index: i, symbol: syms[s], kind: kind, level: level,
                                price: q.price, changePct: q.changePct });
            }
        }
    }
    return { fire: fire, latches: next };
}

// -----------------------------------------------------------------------------
// decimate: at most `max` points, in buckets counted back from the LAST point
// so the live price is always the last one: t and c of a bucket's last point,
// o of its first, h/l its extremes, v its sum.
// -----------------------------------------------------------------------------

function decimate(chart, max) {
    if (!chart || !chart.t || max < 1 || chart.t.length <= max)
        return chart;
    var n = chart.t.length, k = Math.ceil(n / max);
    var out = {};
    for (var f in chart)
        out[f] = chart[f];
    out.t = []; out.o = []; out.h = []; out.l = []; out.c = []; out.v = [];
    var start = n - Math.floor((n - 1) / k) * k - k;   // first bucket may be short
    for (var b = start; b < n; b += k) {
        var lo = Math.max(0, b), hi = b + k - 1;
        var hh = -Infinity, ll = Infinity, vv = 0;
        for (var i = lo; i <= hi; i++) {
            hh = Math.max(hh, chart.h ? chart.h[i] : chart.c[i]);
            ll = Math.min(ll, chart.l ? chart.l[i] : chart.c[i]);
            vv += chart.v ? (chart.v[i] || 0) : 0;
        }
        out.t.push(chart.t[hi]);
        out.o.push(chart.o ? chart.o[lo] : chart.c[lo]);
        out.h.push(hh);
        out.l.push(ll);
        out.c.push(chart.c[hi]);
        out.v.push(vv);
    }
    return out;
}
