.pragma library

// =============================================================================
// StocksFormat.js -- every figure the stocks module prints, and the template
// that sizes its slot (CLAUDE.md "figures never jitter": a slot is as wide as
// its template at the current font, never as the text in it).
//
//     price(v, currency, hint)   "1,497.40 EUR", "124.95 GBp"   (hint = priceHint digits, 2)
//     money(v)                   "€18,100.80"
//     signedMoney(v)             "+€12.30", "−€12.30"
//     pct(v)                     "+0.84%", "−0.49%"             (v in PERCENT units)
//     volume(v)                  "1.2M", "74.6K"
//     shares(v)                  "1,500", "12.5"
//
// A minus is U+2212 (as wide as the plus in every face used here); a figure
// that rounds to zero carries no sign ("0.00%", "€0.00"), so "−0.00%" never
// shows. Anything not a finite number prints as DASH.
//
// TEMPLATES. `<name>Template(v, ...)` is the same text with every digit an
// "8" (the widest digit, as WeatherSeries' templates) and the sign a "+":
// pass the largest magnitude the slot must hold (`pctTemplate(88.88)`); with
// no value a default magnitude is used.
// =============================================================================

var DASH = "—";
var MINUS = "−";

function _ok(v) {
    return typeof v === "number" && isFinite(v);
}

// |v| to `dp` decimals with thousands grouping; the sign is the caller's.
function _grouped(v, dp) {
    var s = Math.abs(v).toFixed(dp);
    var dot = s.indexOf(".");
    var ip = dot < 0 ? s : s.substring(0, dot);
    var frac = dot < 0 ? "" : s.substring(dot);
    var out = "";
    while (ip.length > 3) {
        out = "," + ip.substring(ip.length - 3) + out;
        ip = ip.substring(0, ip.length - 3);
    }
    return ip + out + frac;
}

function _isZero(v, dp) {
    return Math.abs(v) < 0.5 * Math.pow(10, -dp);
}

function _digits(hint) {
    return (typeof hint === "number" && hint >= 0 && hint <= 8) ? Math.round(hint) : 2;
}

function price(v, currency, hint) {
    if (!_ok(v))
        return DASH;
    var dp = _digits(hint);
    var s = (v < 0 && !_isZero(v, dp) ? MINUS : "") + _grouped(v, dp);
    return currency ? s + " " + currency : s;
}

function money(v) {
    if (!_ok(v))
        return DASH;
    return (v < 0 && !_isZero(v, 2) ? MINUS : "") + "€" + _grouped(v, 2);
}

function signedMoney(v) {
    if (!_ok(v))
        return DASH;
    if (_isZero(v, 2))
        return "€" + _grouped(0, 2);
    return (v < 0 ? MINUS : "+") + "€" + _grouped(v, 2);
}

function pct(v) {
    if (!_ok(v))
        return DASH;
    if (_isZero(v, 2))
        return "0.00%";
    return (v < 0 ? MINUS : "+") + _grouped(v, 2) + "%";
}

var VOLUME_UNITS = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];

function volume(v) {
    if (!_ok(v))
        return DASH;
    var a = Math.abs(v);
    for (var i = 0; i < VOLUME_UNITS.length; i++) {
        // 999,950 would round to "1000.0K": it takes the next unit up
        if (a >= VOLUME_UNITS[i][0] * 0.99995) {
            var x = a / VOLUME_UNITS[i][0];
            return (v < 0 ? MINUS : "") + x.toFixed(1) + VOLUME_UNITS[i][1];
        }
    }
    return (v < 0 ? MINUS : "") + _grouped(a, 0);
}

// Whole shares as integers, fractions to at most 4 decimals, zeros trimmed.
function shares(v) {
    if (!_ok(v))
        return DASH;
    var s = _grouped(v, 4);
    if (s.indexOf(".") >= 0)
        s = s.replace(/0+$/, "").replace(/\.$/, "");
    return (v < 0 && s !== "0" ? MINUS : "") + s;
}

// ---- templates -------------------------------------------------------------

function _tmpl(s) {
    return String(s).replace(/[0-9]/g, "8").replace(MINUS, "+");
}

function priceTemplate(v, currency, hint) {
    return _tmpl(price(_ok(v) ? v : 8888.88, currency, hint));
}

function moneyTemplate(v) {
    return _tmpl(money(_ok(v) ? v : 88888.88));
}

function signedMoneyTemplate(v) {
    return _tmpl(signedMoney(_ok(v) && !_isZero(v, 2) ? Math.abs(v) : 88888.88));
}

function pctTemplate(v) {
    return _tmpl(pct(_ok(v) && !_isZero(v, 2) ? Math.abs(v) : 88.88));
}

function volumeTemplate(v) {
    return _tmpl(volume(_ok(v) ? v : 888.8e6));
}

function sharesTemplate(v) {
    return _tmpl(shares(_ok(v) ? v : 8888));
}
