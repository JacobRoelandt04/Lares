.pragma library

// =============================================================================
// Frecency.js -- how often and how lately, Firefox-style. Pure.
//
//   score(rec, nowMs)   -> number    count x mean(bucket weight of recent)
//   record(rec, nowMs)  -> rec'      one more launch, the newest MAX_RECENT kept
//   normalise(v)        -> rec|null  a record read from state.json, cleaned
//
// A record is { count, recent: [ms, ...] }: `count` every launch ever,
// `recent` the timestamps of the last MAX_RECENT (oldest first). Each recent
// launch weighs by its age -- under 4 days 100, under 14 days 70, under 31
// days 50, under 90 days 30, anything older 10 -- and the score is the count
// times the MEAN weight: an app launched 40 times a year ago still outranks
// one launched once yesterday, until its weights decay (the Firefox
// "frecency" of places.sqlite, sampled over the last ten visits).
//
// The boundaries are strict ("under 4 days"), measured from `nowMs`; a stamp
// from the future (a clock that stepped back) counts as age 0. A record with
// launches but no stamps (hand-edited) weighs as the oldest bucket.
// =============================================================================

var DAY_MS = 86400000;
var MAX_RECENT = 10;
var BUCKETS = [
    { days: 4, weight: 100 },
    { days: 14, weight: 70 },
    { days: 31, weight: 50 },
    { days: 90, weight: 30 }
];
var OLD_WEIGHT = 10;

function weightOf(ageMs) {
    const a = ageMs > 0 ? ageMs : 0;
    for (let i = 0; i < BUCKETS.length; i++)
        if (a < BUCKETS[i].days * DAY_MS)
            return BUCKETS[i].weight;
    return OLD_WEIGHT;
}

function _stamps(v) {
    if (!Array.isArray(v))
        return [];
    const out = [];
    for (let i = 0; i < v.length; i++) {
        const t = Number(v[i]);
        if (isFinite(t) && t > 0)
            out.push(Math.round(t));
    }
    out.sort((a, b) => a - b);
    return out.slice(-MAX_RECENT);
}

function normalise(v) {
    if (!v || typeof v !== "object")
        return null;
    const recent = _stamps(v.recent);
    let count = Math.floor(Number(v.count));
    if (!isFinite(count) || count < 0)
        count = 0;
    if (count < recent.length)
        count = recent.length;
    if (count === 0)
        return null;
    return { count: count, recent: recent };
}

function score(rec, nowMs) {
    const r = normalise(rec);
    if (r === null)
        return 0;
    if (r.recent.length === 0)
        return r.count * OLD_WEIGHT;
    let sum = 0;
    for (let i = 0; i < r.recent.length; i++)
        sum += weightOf(nowMs - r.recent[i]);
    return r.count * sum / r.recent.length;
}

function record(rec, nowMs) {
    const r = normalise(rec) || { count: 0, recent: [] };
    const recent = r.recent.concat([Math.round(nowMs)]);
    return {
        count: r.count + 1,
        recent: recent.slice(-MAX_RECENT)
    };
}
