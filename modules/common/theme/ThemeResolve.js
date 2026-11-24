.pragma library

// =============================================================================
// ThemeResolve.js -- how a theme file's values become colours.
//
// THE OTHER COPY of tools/theme/themectl's resolver (Python). The shell and the desktop's programs read one
// theme file, so they must read it the same way: tools/dev/themectl_resolver_parity.sh resolves one fixture
// theme (every op, an alias chain, a cycle, the bad inputs) through both and demands the same answer for
// every key. Change one of the two and change the other.
//
//   A value is  "#RGB" | "#RRGGBB" | "#AARRGGBB" (QML's order)  a colour
//               "@name"                                        another key's value
//               "@name lighten|darken|alpha n"                 that value, recipe applied; n in 0..1:
//                                                              lighten/darken move the HSL lightness by n, alpha sets the alpha
//               anything else (a number, a font)               passed through as it is
//   The keys are  L0 (the defaults declared in Theme.qml) < `common` < the mode's block.
//   A colour is [r, g, b, a], each 0..255 (integers).
//
// WHAT HAS TO STAY IDENTICAL, because the two copies run the same arithmetic on IEEE doubles: the order of the operations
// of the HSL conversion, and the rounding -- floor(x * 255 + 0.5), NEVER Math.round / Python's round() (the latter rounds
// half to even: 2.5 -> 2, where this gives 3). `alpha 0.00980392156862745` is 2.5 exactly and tells them apart.
// A key that has an L0 default is a COLOUR token: a theme value for it that is not a colour is an error, and so is any
// failure to resolve it; it then takes its L0 value (resolved through L0 alone).
// =============================================================================

var OPS = ["lighten", "darken", "alpha"];
var NUM = /^([0-9]+(\.[0-9]*)?|\.[0-9]+)$/;
var HEX = /^[0-9a-fA-F]{8}$/;

function parseColor(s) {
    if (typeof s !== "string")
        return null;
    var h = s.trim();
    if (h.charAt(0) !== "#")
        return null;
    h = h.substring(1);
    if (h.length === 3)
        h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
    if (h.length === 6)
        h = "ff" + h;
    if (h.length !== 8 || !HEX.test(h))
        return null;
    return [parseInt(h.substring(2, 4), 16), parseInt(h.substring(4, 6), 16), parseInt(h.substring(6, 8), 16), parseInt(h.substring(0, 2), 16)];
}

function _rnd(x) {
    return Math.floor(x + 0.5);
}

function _hsl(r, g, b) {
    var mx = Math.max(r, g, b);
    var mn = Math.min(r, g, b);
    var l = (mx + mn) / 2;
    if (mx === mn)
        return [0, 0, l];
    var d = mx - mn;
    var s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    var h;
    if (mx === r)
        h = (g - b) / d + (g < b ? 6 : 0);
    else if (mx === g)
        h = (b - r) / d + 2;
    else
        h = (r - g) / d + 4;
    return [h / 6, s, l];
}

function _hue(p, q, t) {
    if (t < 0)
        t += 1;
    if (t > 1)
        t -= 1;
    if (t < 1 / 6)
        return p + (q - p) * 6 * t;
    if (t < 1 / 2)
        return q;
    if (t < 2 / 3)
        return p + (q - p) * (2 / 3 - t) * 6;
    return p;
}

function _rgb(h, s, l) {
    if (s === 0)
        return [l, l, l];
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    var p = 2 * l - q;
    return [_hue(p, q, h + 1 / 3), _hue(p, q, h), _hue(p, q, h - 1 / 3)];
}

// One recipe op on [r, g, b, a].
function recipe(c, op, n) {
    if (op === "alpha")
        return [c[0], c[1], c[2], _rnd(n * 255)];
    var hsl = _hsl(c[0] / 255, c[1] / 255, c[2] / 255);
    var l = op === "lighten" ? hsl[2] + n : hsl[2] - n;
    l = Math.min(1, Math.max(0, l));
    var rgb = _rgb(hsl[0], hsl[1], l);
    return [_rnd(rgb[0] * 255), _rnd(rgb[1] * 255), _rnd(rgb[2] * 255), c[3]];
}

// One key -> { c: [r, g, b, a] } | { v: value } | null (a sentence was written to errs[0]). `seen` is the chain so far (a
// cycle guard); `keyMap` (optional, QML only) turns an alias target the panel spells by its own property name into a token.
function _res(key, raw, seen, errs, keyMap) {
    if (seen.indexOf(key) >= 0) {
        errs[0] = "\"" + key + "\" aliases in a circle";
        return null;
    }
    var chain = seen.concat([key]);
    if (!Object.prototype.hasOwnProperty.call(raw, key)) {
        errs[0] = "\"" + key + "\" is not defined";
        return null;
    }
    var v = raw[key];
    if (typeof v === "string" && v.charAt(0) === "@") {
        var body = v.substring(1).trim();
        var parts = body.length > 0 ? body.split(/\s+/) : [];
        if (parts.length === 0) {
            errs[0] = "\"" + key + "\" is an empty alias";
            return null;
        }
        var base = _res(keyMap ? keyMap(parts[0]) : parts[0], raw, chain, errs, keyMap);
        if (base === null)
            return null;
        if (parts.length === 1)
            return base;
        if (parts.length !== 3 || OPS.indexOf(parts[1]) < 0 || !NUM.test(parts[2])) {
            errs[0] = "\"" + key + "\" is \"" + v + "\": expected \"@name\" or \"@name lighten|darken|alpha n\"";
            return null;
        }
        var n = parseFloat(parts[2]);
        if (n > 1) {
            errs[0] = "\"" + key + "\": the amount " + parts[2] + " is outside 0..1";
            return null;
        }
        if (base.c === undefined) {
            errs[0] = "\"" + key + "\": \"" + parts[0] + "\" is not a colour, " + parts[1] + " cannot apply";
            return null;
        }
        return { c: recipe(base.c, parts[1], n) };
    }
    var c = parseColor(v);
    if (c !== null)
        return { c: c };
    return { v: v };
}

function _isObject(x) {
    return x !== null && typeof x === "object" && !Array.isArray(x);
}

// L0 < common < the mode's block, as one map.
function merged(l0, common, block) {
    var raw = {};
    var srcs = [l0, common, block];
    for (var i = 0; i < srcs.length; i++) {
        if (!_isObject(srcs[i]))
            continue;
        for (var k in srcs[i])
            raw[k] = srcs[i][k];
    }
    return raw;
}

// -> the value of one key as [r, g, b, a] for a colour (its L0 value when it failed), the raw value for anything else,
// null when there is none; errs (optional array) collects the sentence. Same answer as resolveAll(...).values[key].
function resolveOne(key, l0, common, block, keyMap, errs) {
    var raw = merged(l0, common, block);
    var e = [""];
    var r = _res(key, raw, [], e, keyMap);
    var isColourToken = Object.prototype.hasOwnProperty.call(l0, key);
    if (r !== null && isColourToken && r.c === undefined) {
        e[0] = "\"" + key + "\" is \"" + r.v + "\", not a colour";
        r = null;
    }
    if (r === null) {
        if (errs)
            errs.push(e[0]);
        if (isColourToken) {
            var e2 = [""];
            r = _res(key, l0, [], e2, keyMap);
            if (r !== null && r.c === undefined)
                r = null;
        }
    }
    if (r === null)
        return null;
    return r.c !== undefined ? r.c : r.v;
}

// -> { values: { key: [r, g, b, a] | raw value }, errors: { key: sentence } } for every key of the merged map.
function resolveAll(l0, common, block, keyMap) {
    var raw = merged(l0, common, block);
    var keys = Object.keys(raw).sort();
    var values = {};
    var errors = {};
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var e = [""];
        var r = _res(key, raw, [], e, keyMap);
        var isColourToken = Object.prototype.hasOwnProperty.call(l0, key);
        if (r !== null && isColourToken && r.c === undefined) {
            e[0] = "\"" + key + "\" is \"" + r.v + "\", not a colour";
            r = null;
        }
        if (r === null) {
            errors[key] = e[0];
            if (isColourToken) {
                var e2 = [""];
                r = _res(key, l0, [], e2, keyMap);
                if (r !== null && r.c === undefined)
                    r = null;
            }
        }
        if (r !== null)
            values[key] = r.c !== undefined ? r.c : r.v;
    }
    return { values: values, errors: errors };
}
