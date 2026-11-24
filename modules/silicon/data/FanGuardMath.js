.pragma library

// =============================================================================
// FanGuardMath.js -- the pure half of FanGuard: what this machine's CPU temperature normally is at a given load, learned.
//
// A BASELINE is { <profile>: { "<bucket>": { n, p90 } } }: for each platform profile and each load BUCKET (the load index,
// SysfsPoller.guardSample, in steps of `width` percent), the number of steady samples seen and an estimate of the 90th percentile of
// the package temperature they read. The estimate is a stochastic quantile tracker -- a sample above it moves it up by 0.9 a step, one
// below it down by 0.1 -- so it needs no histogram, a file of a few hundred bytes holds it, and a hand-written file is easy.
// Its step shrinks with n (to a floor), so a young bucket moves fast and an old one slowly; past `MAX_N` a bucket keeps adapting
// (dust, the season, a new paste) at the floor's rate.
//
//   bucketOf(index, width)                   -> the bucket number, or -1 for no index
//   learn(base, profile, bucket, tempC)      -> a new baseline with the sample taken in (the old one is not changed)
//   expected(base, profile, bucket, minN)    -> { tempC, bucket, n, borrowed } the temperature this load normally reads, or null: the bucket's own
//                                               p90 once it has `minN` samples, else the NEAREST HIGHER bucket's that has (a lower load never
//                                               runs hotter than a higher one: its p90 is an upper bound, so it can only make the guard slower),
//                                               else null -- not enough is known
//   parse(text) / serialize(base)            -> the file's text and back (a bad file is an empty baseline)
// =============================================================================

var MAX_N = 100000;
var FLOOR_STEP = 0.25;      // degrees a sample moves a settled estimate
var FIRST_STEP = 2.0;       // ... and a young one

function bucketOf(index, width) {
    if (typeof index !== "number" || !isFinite(index) || index < 0)
        return -1;
    return Math.floor(index / width);
}

function _copy(base) {
    var out = {};
    Object.keys(base || {}).forEach(function (p) {
        out[p] = {};
        Object.keys(base[p]).forEach(function (b) { out[p][b] = { n: base[p][b].n, p90: base[p][b].p90 }; });
    });
    return out;
}

function learn(base, profile, bucket, tempC) {
    if (bucket < 0 || typeof tempC !== "number" || !isFinite(tempC))
        return base;
    var out = _copy(base);
    if (!out[profile])
        out[profile] = {};
    var rec = out[profile][bucket];
    if (!rec) {
        out[profile][bucket] = { n: 1, p90: tempC };
        return out;
    }
    var step = Math.max(FLOOR_STEP, FIRST_STEP / Math.sqrt(rec.n));
    rec.p90 = Math.round((rec.p90 + (tempC > rec.p90 ? 0.9 : -0.1) * step) * 100) / 100;
    rec.n = Math.min(MAX_N, rec.n + 1);
    return out;
}

function expected(base, profile, bucket, minN) {
    if (bucket < 0 || !base || !base[profile])
        return null;
    var rows = base[profile];
    var keys = Object.keys(rows).map(Number).filter(function (b) { return b >= bucket && rows[b].n >= minN; }).sort(function (a, b) { return a - b; });
    if (keys.length === 0)
        return null;
    var b = keys[0];
    return { tempC: rows[b].p90, bucket: b, n: rows[b].n, borrowed: b !== bucket };
}

function parse(text) {
    var out = {};
    var o = null;
    try {
        o = JSON.parse(text);
    } catch (e) {
        return out;
    }
    if (!o || typeof o !== "object" || !o.profiles || typeof o.profiles !== "object")
        return out;
    Object.keys(o.profiles).forEach(function (p) {
        var rows = o.profiles[p];
        if (!rows || typeof rows !== "object")
            return;
        Object.keys(rows).forEach(function (b) {
            var r = rows[b];
            if (/^\d+$/.test(b) && r && typeof r.n === "number" && r.n > 0 && typeof r.p90 === "number" && r.p90 > 0 && r.p90 < 150) {
                if (!out[p])
                    out[p] = {};
                out[p][b] = { n: Math.min(MAX_N, Math.floor(r.n)), p90: r.p90 };
            }
        });
    });
    return out;
}

function serialize(base) {
    return JSON.stringify({ version: 1, profiles: base }, null, 1) + "\n";
}
