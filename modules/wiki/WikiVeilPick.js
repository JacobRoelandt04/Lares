.pragma library

// =============================================================================
// WikiVeilPick.js -- which veil an article with no picture gets. Pure.
//
//   of(key) -> { pattern, seed: [a, b, c, d], t0 }
//
// `key` is the article's id. The pattern, the four seed numbers (0..1, what the
// shader builds its terrain, lattice offset or sources from) and the veil time
// it starts at all come from a hash of the key and nothing else: the same
// article is the same picture on every card, on every machine, after every
// restart, with no state kept anywhere. A thumbnail is that picture at `t0`.
//
// FNV-1a over the key's UTF-16 units, then mulberry32 for the stream: 32-bit
// integer arithmetic only (Math.imul), so node and QV4 agree to the bit
// (tools/dev/wiki_veil_cases.js holds both to one table).
// =============================================================================

var NAMES = ["contours", "links", "ripples", "maze", "cells"];

function hash(key) {
    const s = String(key === undefined || key === null ? "" : key);
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = Math.imul(h, 0x01000193);
    }
    return h >>> 0;
}

function _stream(a) {
    let state = a >>> 0;
    return function () {
        state = (state + 0x6D2B79F5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function of(key) {
    const next = _stream(hash(key));
    const pattern = NAMES[Math.min(NAMES.length - 1, Math.floor(next() * NAMES.length))];
    const seed = [next(), next(), next(), next()];
    // A start well inside what a 32-bit float still resolves to a millisecond.
    return { pattern: pattern, seed: seed, t0: Math.round(next() * 600 * 1000) / 1000 };
}
