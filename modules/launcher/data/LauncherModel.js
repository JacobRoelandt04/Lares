.pragma library

.import "../../common/components/FuzzyMatch.js" as Fuzzy

// =============================================================================
// LauncherModel.js -- the launcher's orders, as pure functions over records.
//
// A RECORD is the row's facts (LauncherService builds them; no colour in any
// of them): { key, kind, name, genericName, keywords, favorite, frecency, ... }.
//
//   natCompare(a, b)                  names: natural, case-insensitive, total
//   sortKeys(recs, mode, ascending)   one level's keys, no query:
//       "default"  favourites, then launched by frecency, then never-launched
//                  A-Z (favourites among themselves by frecency, then A-Z)
//       "name"     A-Z (ascending false: Z-A)
//       "recent"   frecency, highest first; never-launched after, A-Z
//   rank(query, recs, weights)        [{ key, score, field, nameIndices }]:
//       every record whose name / real name (a renamed record's own) /
//       generic name / keywords match, by score; ties by favourite, then
//       frecency, then name -- whatever the sort
//   slug(s)                           a systemd unit name part
//   shellQuote(argv)                  argv as one line a shell would read back
// =============================================================================

// A name's lower-case chunks (digit runs and the rest) and which are digits,
// memoised: a sort compares each name ~2 log n times, and chunking it on
// every compare costs 4.6 us a call -- 3.4 ms to sort 104 apps (the
// memo is what a launcher's unchanging names want, FuzzyMatch's rule).
var _memo = {}, _memoSize = 0;
function _prep(s) {
    let p = _memo[s];
    if (p !== undefined)
        return p;
    const chunks = s.toLowerCase().match(/[0-9]+|[^0-9]+/g) || [];
    const digit = chunks.map(c => {
        const k = c.charCodeAt(0);
        return k >= 48 && k <= 57;
    });
    p = { chunks: chunks, digit: digit };
    if (_memoSize > 4000) {
        _memo = {};
        _memoSize = 0;
    }
    _memo[s] = p;
    _memoSize++;
    return p;
}
function natCompare(a, b) {
    const sa = String(a || ""), sb = String(b || "");
    if (sa === sb)
        return 0;
    const pa = _prep(sa), pb = _prep(sb);
    const ca = pa.chunks, cb = pb.chunks;
    const n = Math.min(ca.length, cb.length);
    for (let i = 0; i < n; i++) {
        const x = ca[i], y = cb[i];
        if (x === y)
            continue;
        if (pa.digit[i] && pb.digit[i]) {
            const xs = x.replace(/^0+(?=.)/, ""), ys = y.replace(/^0+(?=.)/, "");
            if (xs.length !== ys.length)
                return xs.length < ys.length ? -1 : 1;
            if (xs !== ys)
                return xs < ys ? -1 : 1;
            continue;
        }
        const c = x.localeCompare(y);
        if (c !== 0)
            return c < 0 ? -1 : 1;
        return x < y ? -1 : 1;
    }
    if (ca.length !== cb.length)
        return ca.length < cb.length ? -1 : 1;
    return sa === sb ? 0 : (sa < sb ? -1 : 1);
}

// Name, then key: the order is total, so a re-sort never swaps equals.
function _byName(a, b) {
    return natCompare(a.name, b.name) || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
}
function _byFrecency(a, b) {
    return (b.frecency - a.frecency) || _byName(a, b);
}

function sortKeys(recs, mode, ascending) {
    const rs = recs.slice();
    if (mode === "name") {
        const dir = ascending === false ? -1 : 1;
        rs.sort((a, b) => dir * _byName(a, b));
    } else if (mode === "recent") {
        rs.sort((a, b) => {
            const la = a.frecency > 0, lb = b.frecency > 0;
            if (la !== lb)
                return la ? -1 : 1;
            return _byFrecency(a, b);
        });
    } else {
        rs.sort((a, b) => {
            if (a.favorite !== b.favorite)
                return a.favorite ? -1 : 1;
            const la = a.frecency > 0, lb = b.frecency > 0;
            if (la !== lb)
                return la ? -1 : 1;
            return _byFrecency(a, b);
        });
    }
    return rs.map(r => r.key);
}

// weights: { name, realName, genericName, keywords }. `name` is the title
// the row shows; a RENAMED record's real name is searched too, one step
// below it (search finds both names, the title ranks first), and
// not at all for a record that was not renamed (it is the name). The
// keywords are one field (the list joined by spaces, so a term can only
// match inside one keyword or at a keyword start). nameIndices are the
// NAME's own matched positions (for the accent letters) whichever field
// scored best -- [] when the name does not match the query at all.
function rank(query, recs, weights) {
    const q = String(query || "").trim();
    if (q.length === 0)
        return [];
    const w = weights || {};
    const ws = [w.name === undefined ? 1 : w.name,
                w.realName === undefined ? 0.9 : w.realName,
                w.genericName === undefined ? 0.8 : w.genericName,
                w.keywords === undefined ? 0.6 : w.keywords];
    const fieldNames = ["name", "realName", "genericName", "keywords"];
    const hits = [];
    for (let i = 0; i < recs.length; i++) {
        const r = recs[i];
        const fields = [r.name || "", r.renamed === true ? (r.realName || "") : "", r.genericName || "", (r.keywords || []).join(" ")];
        const b = Fuzzy.best(q, fields, ws);
        if (b === null)
            continue;
        const own = b.field === 0 ? b : Fuzzy.match(q, fields[0]);
        hits.push({
            key: r.key,
            score: b.score,
            field: fieldNames[b.field] || "name",
            nameIndices: own ? own.indices.slice() : [],
            rec: r
        });
    }
    hits.sort((a, b) => {
        if (a.score !== b.score)
            return b.score - a.score;
        if (a.rec.favorite !== b.rec.favorite)
            return a.rec.favorite ? -1 : 1;
        return _byFrecency(a.rec, b.rec);
    });
    return hits.map(h => ({
                key: h.key,
                score: h.score,
                field: h.field,
                nameIndices: h.nameIndices
            }));
}

function slug(s) {
    let t = String(s || "").replace(/[^A-Za-z0-9:_.-]+/g, "_").replace(/^[._-]+/, "");
    if (t.length > 64)
        t = t.substring(0, 64);
    return t.length > 0 ? t : "item";
}

function _quote(a) {
    const s = String(a);
    if (s.length > 0 && /^[A-Za-z0-9_\-+=:,.\/@%^]+$/.test(s))
        return s;
    return "'" + s.replace(/'/g, "'\\''") + "'";
}
function shellQuote(argv) {
    return (argv || []).map(_quote).join(" ");
}
