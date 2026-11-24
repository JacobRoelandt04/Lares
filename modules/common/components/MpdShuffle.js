.pragma library

// =============================================================================
// MpdShuffle.js
//
// The queue shuffle, with the bias every music player has had since the iPod:
// a plain random order puts two songs by the same artist back to back often
// enough that people stop believing it is random. This spreads them.
//
// Two passes, and the split is deliberate:
//   1. Fisher-Yates. Uniform, unbiased, the only source of randomness.
//   2. A repair walk. For each slot in order, if the song there repeats an
//      artist within `minArtistGap` slots behind it (or an album within
//      `minAlbumGap`), swap it with the nearest later song that does not, and
//      give up after `tries` candidates rather than search the whole tail.
//
// Repair AFTER a real shuffle, never a constrained draw: a draw that refuses
// candidates is not uniform over the songs it does accept, and with a queue of
// one artist it cannot terminate at all. Repair degrades instead — a queue that
// cannot satisfy the gaps comes back shuffled, just not spread, and `tries`
// bounds the work at O(n · tries) whatever the input.
//
// A swap can of course break the slot it moved the song TO. That is fine and
// intended: the walk has not reached that slot yet, and it will be repaired in
// its turn. Only slots already passed are stable, which is exactly the region
// the gap rules look back into.
//
// DETERMINISM. `opts.seed` (any finite number) selects a mulberry32 PRNG, so
// the same songs and the same seed give the same order — that is how the gap
// rules are tested. Without a seed it uses Math.random.
//
// EMPTY KEYS NEVER CLASH. A song with no artist tag (the Loop Hero mp3s) would
// otherwise be forced apart from every other untagged song, which would spread
// the one album that has no metadata across the whole queue. Unknown is not a
// value; it is the absence of one.
// =============================================================================

var _DEFAULTS = { minArtistGap: 3, minAlbumGap: 2, tries: 40 };

// A small, fast, well-distributed 32-bit PRNG. Chosen over an LCG because a
// seeded shuffle is a test fixture and a poor generator would put structure in
// the very thing the test is measuring.
function _mulberry32(a) {
    return function () {
        a |= 0;
        a = (a + 0x6D2B79F5) | 0;
        var t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function _opts(opts) {
    opts = opts || {};
    var g = function (k) { return opts[k] === undefined ? _DEFAULTS[k] : Math.max(0, Math.floor(opts[k])); };
    return {
        minArtistGap: g("minArtistGap"),
        minAlbumGap: g("minAlbumGap"),
        tries: g("tries"),
        rng: (typeof opts.seed === "number" && isFinite(opts.seed))
             ? _mulberry32(opts.seed >>> 0) : Math.random
    };
}

// The performing artist is what a listener hears repeat, so `artist` leads and
// `albumArtist` only fills in for a song that has none.
function artistKeyOf(s) {
    if (!s) return "";
    return String(s.artist || s.albumArtist || "").toLowerCase();
}

// An album is only the same album when its artist matches too — two records
// called "Ozean" by different bands are not one album.
function albumKeyOf(s) {
    if (!s) return "";
    var al = String(s.album || "");
    if (!al) return "";
    return (String(s.albumArtist || s.artist || "") + "\u0000" + al).toLowerCase();
}

// Would `cand` sitting at index `i` of `list` break either gap rule? Only the
// slots BEFORE `i` are read, so this is valid mid-repair.
function _clashes(list, i, cand, o) {
    var ak = artistKeyOf(cand);
    var bk = albumKeyOf(cand);
    var back = Math.max(o.minArtistGap, o.minAlbumGap);
    for (var d = 1; d <= back; d++) {
        var j = i - d;
        if (j < 0) break;
        var prev = list[j];
        if (ak && d <= o.minArtistGap && artistKeyOf(prev) === ak) return true;
        if (bk && d <= o.minAlbumGap && albumKeyOf(prev) === bk) return true;
    }
    return false;
}

// The public one. Returns a NEW array; `songs` is not touched.
function shuffled(songs, opts) {
    var o = _opts(opts);
    var out = (songs || []).slice();
    var n = out.length;
    var i, j, t;

    for (i = n - 1; i > 0; i--) {
        j = Math.floor(o.rng() * (i + 1));
        t = out[i]; out[i] = out[j]; out[j] = t;
    }

    if (o.tries <= 0 || n < 3) return out;

    for (i = 1; i < n; i++) {
        if (!_clashes(out, i, out[i], o)) continue;
        var limit = Math.min(n - 1, i + o.tries);
        for (j = i + 1; j <= limit; j++) {
            if (_clashes(out, i, out[j], o)) continue;
            t = out[i]; out[i] = out[j]; out[j] = t;
            break;
        }
    }
    return out;
}

// How many slots still break a rule, split by which one. The measurement the
// repair pass exists to lower — and the only honest way to test it, since a
// seeded shuffle's exact order says nothing about whether the bias worked.
function violationsIn(list, opts) {
    var o = _opts(opts);
    var r = { artist: 0, album: 0, total: 0 };
    for (var i = 1; i < (list || []).length; i++) {
        var s = list[i];
        var ak = artistKeyOf(s);
        var bk = albumKeyOf(s);
        var a = false, b = false;
        for (var d = 1; d <= Math.max(o.minArtistGap, o.minAlbumGap); d++) {
            var j = i - d;
            if (j < 0) break;
            if (ak && d <= o.minArtistGap && artistKeyOf(list[j]) === ak) a = true;
            if (bk && d <= o.minAlbumGap && albumKeyOf(list[j]) === bk) b = true;
        }
        if (a) r.artist++;
        if (b) r.album++;
        if (a || b) r.total++;
    }
    return r;
}
