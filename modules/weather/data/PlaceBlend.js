.pragma library

// =============================================================================
// PlaceBlend.js -- the arithmetic of a LOCATION MORPH (feedback/weather.md "morph transitions when changing
// locations"). Pure functions; WeatherPopup owns the clock and the cards own what they draw.
//
//   PB.placeKey(model)                  the place a model speaks for ("" for none)
//   PB.samePlace(a, b)                  whether two models are the same place
//   PB.facts(from, to, e, rules)        the picture between two sets of facts at the eased fraction e
//
// A card builds its facts once per model: plain objects, arrays, strings and numbers (never a colour). Between two
// places the picture MOVES: every number that drives a position, a length or an angle goes from the old place's value
// to the new one's (`facts`), and every word swaps at once, the shell's text rule. `rules` says which numbers are not
// plain lengths:
//
//   zero      keys whose null means "none, zero long": a bar that has no value draws as nothing, so a value that comes
//             from nothing GROWS from 0 and one that goes to nothing SHRINKS to 0 (without it the bar would jump)
//   cyclic    { key: period }: an angle (wind direction, 360) or a phase (the moon, 1) goes the SHORT way round
//   discrete  keys that are a category, not a quantity (a trend's sign): the new place's, at once
//   sentinel  keys where a negative number says "none" (a band index of -1): the new place's, at once, because half way
//             between "none" and band 3 is not a band
//
// A key is matched by NAME at any depth, so a card lists the names it knows. Whatever is not a number is the target's;
// a row or an item the old picture does not have is the target's own, with its `zero` keys growing from 0. At e = 1
// the answer is the target itself, value for value.
// =============================================================================

// The place a model speaks for. The name alone is not enough (two saved places may share one), the coordinates alone
// are not either (the current location's name changes as the place is looked up): coordinates to a hundredth of a
// degree (~1 km) when the model has them, else the name.
function placeKey(model) {
    const loc = model && model.location ? model.location : null;
    if (!loc)
        return "";
    if (typeof loc.lat === "number" && typeof loc.lon === "number" && isFinite(loc.lat) && isFinite(loc.lon))
        return loc.lat.toFixed(2) + "," + loc.lon.toFixed(2);
    return typeof loc.name === "string" ? loc.name : "";
}
function samePlace(a, b) {
    return placeKey(a) === placeKey(b);
}
// Whether a model change is a MORPH: another place, or the same place whose DATA changed (a fetch landed: the cache the place
// was shown from gives way to the fresh forecast, the radar moves on). The service counts data arrivals in `dataSerial`
// (a rebuild for the clock does not count); a model without one -- a mock's -- is the same data whenever it is the same place.
function morphs(a, b) {
    if (!samePlace(a, b))
        return true;
    return _num(a.dataSerial) && _num(b.dataSerial) && a.dataSerial !== b.dataSerial;
}

function _num(v) {
    return typeof v === "number" && isFinite(v);
}
function _has(set, k) {
    return !!set && k !== undefined && Object.prototype.hasOwnProperty.call(set, k) && !!set[k];
}

function _leaf(a, b, e, k, r) {
    const bn = _num(b);
    const an = _num(a);
    if (bn) {
        if (_has(r.discrete, k))
            return b;
        if (an) {
            if (_has(r.sentinel, k) && (a < 0 || b < 0))
                return b;
            if (_has(r.cyclic, k)) {
                const p = r.cyclic[k];
                let d = (b - a) % p;
                if (d > p / 2) d -= p;
                if (d < -p / 2) d += p;
                const v = (a + d * e) % p;
                return v < 0 ? v + p : v;
            }
            return a * (1 - e) + b * e;
        }
        // From nothing (null, or an item the old picture lacked).
        if (_has(r.zero, k) && (a === null || a === undefined))
            return b * e;
        return b;
    }
    if ((b === null || b === undefined) && an && _has(r.zero, k))
        return a * (1 - e);
    return b;
}

function facts(from, to, e, rules, key) {
    const r = rules || {};
    if (to === null || to === undefined)
        return _leaf(from, to, e, key, r);
    if (typeof to !== "object")
        return _leaf(from, to, e, key, r);
    if (to instanceof Array) {
        const out = new Array(to.length);
        const f = from instanceof Array ? from : null;
        for (let i = 0; i < to.length; i++)
            out[i] = facts(f && i < f.length ? f[i] : undefined, to[i], e, r, key);
        return out;
    }
    const out = {};
    const f = from && typeof from === "object" ? from : null;
    for (const k in to)
        out[k] = facts(f ? f[k] : undefined, to[k], e, r, k);
    return out;
}

// For a number that is a bar's length in a card that keeps its columns as plain numbers: `a` to `b`, either side
// null for "none" (zero long).
function bar(a, b, e) {
    const x = _num(a) ? a : 0;
    const y = _num(b) ? b : 0;
    return x * (1 - e) + y * e;
}

// A direction in degrees (or any angle of period `p`, default 360) from `a` to `b` the short way round; null on either
// side is the other side's (a direction that appears or goes does not turn).
function angle(a, b, e, p) {
    const period = p || 360;
    if (!_num(a) || !_num(b))
        return b;
    return _leaf(a, b, e, "a", { cyclic: { a: period } });
}
