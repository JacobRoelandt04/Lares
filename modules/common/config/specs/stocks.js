.pragma library

// The spec of config/stocks.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/stocks.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    currency: ["word", "EUR", ["EUR"]],
    inflation: { geo: ["text", "BE", { re: "^[A-Z]{2}$", like: "BE" }] },
    dividendWithholding: ["num", 0.30, 0, 0.999],
    indices: ["list", [
        { symbol: "^BFX", alias: "BEL 20" }, { symbol: "^AEX", alias: "AEX" }, { symbol: "^STOXX50E", alias: "Euro Stoxx 50" },
        { symbol: "^GSPC", alias: "S&P 500" }, { symbol: "^IXIC", alias: "Nasdaq" }, { symbol: "EURUSD=X", alias: "EUR/USD" }
    ], ["either", undefined, ["text", undefined], ["obj", undefined, { symbol: ["text", undefined, { req: true }], alias: ["text", undefined] }]]],
    detailMemoryMin: ["num", 10, 0, 1440],
    refreshSec: { open: ["num", 60, 30, 3600], closed: ["num", 300, 60, 86400] },
    extendedHours: ["bool", true],
    quoteUrl: ["text", "https://finance.yahoo.com/quote/{symbol}", { re: "^https?://.*\\{symbol\\}", like: "https://finance.yahoo.com/quote/{symbol}" }],
    look: { secondarySide: ["word", "end", ["start", "end", "far"]] },
    alertHysteresis: ["num", 0.005, 0, 1],
    alerts: ["list", [], {
        symbol: ["text", undefined, { req: true }],
        above: ["num", undefined, 0, null],
        below: ["num", undefined, 0, null],
        dayMove: ["num", undefined, 0, null]
    }],
    sudden: {
        pct: ["num", 3, 0, 100],
        minutes: ["num", 30, 1, 390],
        bySymbol: ["map", {}, ["either", undefined, ["bool", undefined], ["obj", undefined, { pct: ["num", undefined, 0, 100], minutes: ["num", undefined, 1, 390] }]]]
    },
    holdings: ["list", [], {
        symbol: ["text", undefined, { req: true }],
        alias: ["text", undefined],
        image: ["path", undefined],
        isin: ["text", undefined],
        cnbc: ["text", undefined],
        actions: ["list", undefined, {
            type: ["word", undefined, ["buy", "sell"], { req: true }],
            date: ["text", undefined, { re: "^\\d{4}-\\d{2}-\\d{2}$", like: "2025-05-28", req: true }],
            shares: ["num", undefined, 0, null, { req: true }],
            price: ["num", undefined, 0, null, { req: true }],
            fees: ["num", undefined, 0, null],
            comment: ["text", undefined]
        }]
    }]
};
