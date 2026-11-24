pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "Portfolio.js" as Portfolio
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// StocksConfig.qml -- the user's stocks.jsonc, READ ONLY, hot-reloaded.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/stocks.jsonc (overridable: `configPath`).
// Template and schema: .examples/stocks.jsonc at the config root. `//` and
// `/* */` comments are allowed outside strings (JsonComments.js). Nothing in this shell writes the file
// (`blockWrites`).
//
// `config` is the file normalised, every key defaulted:
//   { currency: "EUR", inflation: { geo: "BE" }, dividendWithholding: 0.30,
//     indices: [{ symbol, alias, label }], alertHysteresis: 0.005,
//     detailMemoryMin: 10, refreshSec: { open: 60, closed: 300 }, extendedHours: true,
//     quoteUrl: "https://finance.yahoo.com/quote/{symbol}", look: { secondarySide: "end" },
//     alerts: [{ symbol, above, below, dayMove }]     (null where absent),
//     sudden: { pct, minutes, bySymbol: { SYM: { pct?, minutes? } | false } }
//                       the `sudden` alert kind (modules/notifications/sources, StocksNotifier): a move of
//                       at least `pct` % within `minutes` minutes, intraday, market hours only; per symbol
//                       a value of its own, or `false` for none. Defaults 3 % within 30 minutes.
//     holdings: [{ symbol, alias, label, image (file URL or ""), isin, cnbc,
//                  actions: [{ type, date, shares, price, fees, comment }] }] }
//
// Mistakes are a line in `lastError`, never a warning and never a crash: a
// bad action or holding is dropped and named, a bad value takes its default
// and is named. A file that does not PARSE keeps the last good config (a typo
// in the middle of an edit must not blank the portfolio) and says so. A
// missing file is not an error: `present` is false and the portfolio empty.
//
// `parseText(txt)` is the same normalisation as a pure call ({ config,
// errors, parsed }) -- the mock doctors text through it for bad-config.
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/stocks.jsonc"

    readonly property var defaultIndices: [
        { symbol: "^BFX", alias: "BEL 20" }, { symbol: "^AEX", alias: "AEX" },
        { symbol: "^STOXX50E", alias: "Euro Stoxx 50" }, { symbol: "^GSPC", alias: "S&P 500" },
        { symbol: "^IXIC", alias: "Nasdaq" }, { symbol: "EURUSD=X", alias: "EUR/USD" }]

    property var config: root.parseText("").config
    property string lastError: ""
    property bool present: false
    // The file has been read (or found missing) at least once.
    property bool ready: false

    function reload() { fv.reload(); }

    // ---- The file ------------------------------------------------------------
    property string _raw: ""
    property bool _applied: false

    ConfigFile {
        id: fv
        path: root.configPath
        // Each read of the file in force, and the file appearing or going, arrive as one of these; _apply parses only when the
        // bytes changed.
        onLoaded: root._apply(fv.text(), true)
        onLoadFailed: root._apply("", false)
    }

    Component.onCompleted: {
        const t = fv.text();
        if (t) root._apply(t, true);
    }

    function _apply(txt, exists) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._raw && root.present === exists) return;
        root._applied = true;
        root._raw = t;
        root.present = exists && t.length > 0;
        const r = root.parseText(t);
        if (!r.parsed && root.ready && root.present) {
            // Keep the last good config; say why the edit was not taken.
            root.lastError = r.errors.join("; ");
            root.ready = true;
            return;
        }
        root.config = r.config;
        root.lastError = r.errors.join("; ");
        root.ready = true;
    }

    // ---- Normalisation (pure) ------------------------------------------------
    function parseText(txt) {
        const errors = [];
        let obj = null;
        let parsed = true;
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length > 0) {
            try {
                obj = JSON.parse(JsonComments.strip(t));
            } catch (e) {
                parsed = false;
                // Qt's JSON.parse names no position ("Parse error", nothing
                // else), so the scanner finds the first error in the file as
                // written.
                const at = JsonComments.locate(t);
                errors.push((at ? "stocks.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "stocks.jsonc: " + e.message)
                            + " — the last good version is kept");
            }
            if (obj !== null && (typeof obj !== "object" || Array.isArray(obj))) {
                errors.push("stocks.jsonc: the top level is not an object");
                obj = null;
            }
        }
        const o = obj || {};
        const cfg = {};

        cfg.currency = "EUR";
        if (o.currency !== undefined && o.currency !== "EUR")
            errors.push("currency: only \"EUR\" is supported, using EUR");

        let geo = "BE";
        if (o.inflation !== undefined) {
            const g = o.inflation && typeof o.inflation === "object" ? o.inflation.geo : undefined;
            if (typeof g === "string" && /^[A-Z]{2}$/.test(g)) geo = g;
            else errors.push("inflation.geo: not a two-letter country code, using BE");
        }
        cfg.inflation = { geo: geo };

        cfg.dividendWithholding = root._fraction("dividendWithholding", o.dividendWithholding, 0.30, errors);
        cfg.alertHysteresis = root._fraction("alertHysteresis", o.alertHysteresis, 0.005, errors);
        cfg.detailMemoryMin = root._range("detailMemoryMin", o.detailMemoryMin, 10, 0, 1440, errors);
        const rs = o.refreshSec && typeof o.refreshSec === "object" ? o.refreshSec : {};
        if (o.refreshSec !== undefined && rs !== o.refreshSec) errors.push("refreshSec: not an object, using the defaults");
        // the floors are Yahoo's: a faster poll is answered 429
        cfg.refreshSec = { open: root._range("refreshSec.open", rs.open, 60, 30, 3600, errors),
                           closed: root._range("refreshSec.closed", rs.closed, 300, 60, 86400, errors) };
        cfg.extendedHours = true;
        if (o.extendedHours !== undefined) {
            if (typeof o.extendedHours === "boolean") cfg.extendedHours = o.extendedHours;
            else errors.push("extendedHours: not true or false, using true");
        }
        cfg.quoteUrl = "https://finance.yahoo.com/quote/{symbol}";
        if (o.quoteUrl !== undefined) {
            if (typeof o.quoteUrl === "string" && /^https?:\/\/.*\{symbol\}/.test(o.quoteUrl)) cfg.quoteUrl = o.quoteUrl;
            else errors.push("quoteUrl: not an http(s) address with {symbol} in it, using Yahoo's");
        }
        const look = o.look && typeof o.look === "object" ? o.look : {};
        cfg.look = { secondarySide: "end" };
        if (look.secondarySide !== undefined) {
            if (["start", "end", "far"].indexOf(look.secondarySide) >= 0) cfg.look.secondarySide = look.secondarySide;
            else errors.push("look.secondarySide: not \"start\", \"end\" or \"far\", using \"end\"");
        }

        cfg.indices = root._indices(o.indices === undefined ? root.defaultIndices : o.indices, errors);
        cfg.alerts = root._alerts(o.alerts, errors);
        cfg.sudden = root._sudden(o.sudden, errors);
        cfg.holdings = root._holdings(o.holdings, errors);
        return { config: cfg, errors: errors, parsed: parsed };
    }

    function _fraction(key, v, dflt, errors) {
        if (v === undefined) return dflt;
        if (typeof v === "number" && isFinite(v) && v >= 0 && v < 1) return v;
        errors.push(key + ": not a fraction between 0 and 1, using " + dflt);
        return dflt;
    }

    function _range(key, v, dflt, lo, hi, errors) {
        if (v === undefined) return dflt;
        if (typeof v === "number" && isFinite(v) && v >= lo && v <= hi) return v;
        errors.push(key + ": not a number from " + lo + " to " + hi + ", using " + dflt);
        return dflt;
    }

    function _symbol(v) {
        return (typeof v === "string" && v.trim().length > 0) ? v.trim() : "";
    }

    function _indices(list, errors) {
        if (!Array.isArray(list)) { errors.push("indices: not a list, using the defaults"); list = root.defaultIndices; }
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            const sym = typeof e === "string" ? root._symbol(e) : (e && typeof e === "object" ? root._symbol(e.symbol) : "");
            if (!sym) { errors.push("indices[" + i + "]: needs a symbol"); continue; }
            const alias = (e && typeof e === "object" && typeof e.alias === "string") ? e.alias : "";
            out.push({ symbol: sym, alias: alias, label: alias || sym });
        }
        return out;
    }

    function _alerts(list, errors) {
        if (list === undefined) return [];
        if (!Array.isArray(list)) { errors.push("alerts: not a list"); return []; }
        const out = [];
        const num = function (x) { return typeof x === "number" && isFinite(x); };
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            const sym = e && typeof e === "object" ? root._symbol(e.symbol) : "";
            if (!sym) { errors.push("alerts[" + i + "]: needs a symbol"); continue; }
            const a = { symbol: sym, above: null, below: null, dayMove: null };
            let any = false;
            for (const k of ["above", "below", "dayMove"]) {
                if (e[k] === undefined) continue;
                if (num(e[k]) && e[k] > 0) { a[k] = e[k]; any = true; }
                else errors.push("alerts[" + i + "] (" + sym + "): " + k + " is not a positive number");
            }
            if (!any) { errors.push("alerts[" + i + "] (" + sym + "): needs above, below or dayMove"); continue; }
            out.push(a);
        }
        return out;
    }

    // `sudden`: the thresholds of the sudden-move alert, globally and per symbol. A symbol's entry is an object
    // with a `pct` and / or `minutes` of its own (the rest is the global's), or `false`: no sudden alerts for it.
    function _sudden(v, errors) {
        const out = { pct: 3, minutes: 30, bySymbol: {} };
        if (v === undefined) return out;
        if (!v || typeof v !== "object" || Array.isArray(v)) {
            errors.push("sudden: not an object, using the defaults");
            return out;
        }
        const pct = function (x, where) {
            if (typeof x === "number" && isFinite(x) && x > 0 && x <= 100) return x;
            errors.push(where + ": not a percentage above 0 and up to 100");
            return null;
        };
        const mins = function (x, where) {
            if (typeof x === "number" && isFinite(x) && x >= 1 && x <= 390) return x;
            errors.push(where + ": not a number of minutes from 1 to 390 (a trading day)");
            return null;
        };
        if (v.pct !== undefined) { const p = pct(v.pct, "sudden.pct"); if (p !== null) out.pct = p; }
        if (v.minutes !== undefined) { const m = mins(v.minutes, "sudden.minutes"); if (m !== null) out.minutes = m; }
        const by = v.bySymbol;
        if (by !== undefined && (!by || typeof by !== "object" || Array.isArray(by))) {
            errors.push("sudden.bySymbol: not an object");
        } else if (by !== undefined) {
            for (const sym in by) {
                const e = by[sym];
                const name = root._symbol(sym);
                if (!name) continue;
                if (e === false) { out.bySymbol[name] = false; continue; }
                if (!e || typeof e !== "object" || Array.isArray(e)) {
                    errors.push("sudden.bySymbol." + name + ": not an object or false");
                    continue;
                }
                const o = {};
                if (e.pct !== undefined) { const p = pct(e.pct, "sudden.bySymbol." + name + ".pct"); if (p !== null) o.pct = p; }
                if (e.minutes !== undefined) { const m = mins(e.minutes, "sudden.bySymbol." + name + ".minutes"); if (m !== null) o.minutes = m; }
                out.bySymbol[name] = o;
            }
        }
        return out;
    }

    function _holdings(list, errors) {
        if (list === undefined) return [];
        if (!Array.isArray(list)) { errors.push("holdings: not a list"); return []; }
        const out = [];
        const seen = {};
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            const sym = e && typeof e === "object" ? root._symbol(e.symbol) : "";
            if (!sym) { errors.push("holdings[" + i + "]: needs a symbol"); continue; }
            if (seen[sym]) { errors.push(sym + ": listed twice, the second entry is ignored"); continue; }
            seen[sym] = true;
            const str = function (k) { return typeof e[k] === "string" && e[k].trim().length > 0 ? e[k].trim() : ""; };
            const h = {
                symbol: sym, alias: str("alias"), label: str("alias") || sym,
                image: root._imageUrl(str("image")), isin: str("isin"), cnbc: str("cnbc"),
                actions: []
            };
            const acts = Array.isArray(e.actions) ? e.actions : [];
            if (e.actions !== undefined && !Array.isArray(e.actions))
                errors.push(sym + ": actions is not a list");
            for (let j = 0; j < acts.length; j++) {
                const a = acts[j];
                const why = (a && typeof a === "object") ? Portfolio.validateAction(a) : "not an object";
                if (why) { errors.push(sym + " action " + (j + 1) + ": " + why); continue; }
                h.actions.push({
                    type: a.type, date: a.date, shares: a.shares, price: a.price,
                    fees: (typeof a.fees === "number" && isFinite(a.fees)) ? a.fees : 0,
                    comment: typeof a.comment === "string" ? a.comment : ""
                });
            }
            out.push(h);
        }
        return out;
    }

    // A relative image path is relative to the config file's own directory.
    function _imageUrl(p) {
        if (!p) return "";
        if (p.indexOf("file://") === 0) return p;
        let abs = p;
        if (p.charAt(0) === "~") abs = Quickshell.env("HOME") + p.substring(1);
        else if (p.charAt(0) !== "/") abs = root.configPath.substring(0, root.configPath.lastIndexOf("/") + 1) + p;
        return "file://" + abs;
    }
}
