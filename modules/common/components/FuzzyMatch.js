.pragma library

// =============================================================================
// FuzzyMatch.js -- fzf-style fuzzy matching, pure.
//
//   match(query, text)            -> null | { score, indices }
//   best(query, fields, weights)  -> null | { score, field, indices }
//   bestScore(query, fields, weights) -> null | score   (best()'s number, for a RANKING: no matched positions)
//
// The query is split on whitespace and EVERY term has to be found in the
// text as a subsequence, case-insensitively ("vsc" finds Visual Studio Code,
// "lo w" finds LibreOffice Writer). Each term is aligned by a small dynamic
// programme that maximises: a point per matched character, a bonus where it
// starts a word (the text's start, after a separator, a lower->upper camel
// step) and for each character that follows the previous match directly,
// less a penalty for every gap (the first skipped character costs more than
// the ones after it). So "code" lands on "Code" rather than on the letters
// scattered through "Collection of desktop". Higher is better; `indices` are
// the matched positions in the text, sorted and unique, for accent letters.
//
// A term that is not a subsequence is rejected by indexOf before any
// alignment; the alignment is one row per term character over the POSITIONS OF THAT
// CHARACTER in a prepared text (word-start bonuses, memoised: a launcher's texts do not
// change between keystrokes) -- sparse, so a 2 KB clipboard text costs a tenth of what a
// cell per position would (it gives the straight programme's scores and
// positions). Measured warm over 112 apps x 3 fields: 1.45 ms
// per keystroke for "libre off", 2.4 ms for "e o", where nearly every text
// holds both letters (the budget is half a 120 Hz frame).
// `best` scores several fields of one item (name, generic name, keywords)
// with a weight each and keeps the highest.
// =============================================================================

var SCORE_MATCH = 16;
var BONUS_START = 10;
var BONUS_BOUNDARY = 8;
var BONUS_CAMEL = 7;
var BONUS_CONSECUTIVE = 8;
var PENALTY_GAP_START = 3;
var PENALTY_GAP_EXTEND = 1;

// Separators, as char codes: space - _ . / ( ) : + ,
var _SEP = {
    32: 1,
    45: 1,
    95: 1,
    46: 1,
    47: 1,
    40: 1,
    41: 1,
    58: 1,
    43: 1,
    44: 1
};

// Per text, once for all its terms: lower-case codes and each position's
// word-start bonus (the text's start, after a separator, a lower->upper step).
function _prepare(text) {
    var n = text.length;
    var lower = text.toLowerCase();
    var codes = new Int32Array(n), bonus = new Int32Array(n);
    for (var j = 0; j < n; j++) {
        codes[j] = lower.charCodeAt(j);
        if (j === 0) {
            bonus[j] = BONUS_START;
            continue;
        }
        var p = text.charCodeAt(j - 1), c = text.charCodeAt(j);
        if (_SEP[p]) {
            bonus[j] = BONUS_BOUNDARY;
            continue;
        }
        // A camel step: the previous character a lower-case letter (it is
        // its own lower form and has an upper one), this one upper-case (its
        // lower form differs).
        var prevLower = codes[j - 1] === p && text.charAt(j - 1).toUpperCase() !== text.charAt(j - 1);
        bonus[j] = prevLower && codes[j] !== c ? BONUS_CAMEL : 0;
    }
    return {
        n: n,
        lower: lower,
        codes: codes,
        bonus: bonus
    };
}

// A launcher's texts do not change between keystrokes, so a prepared text is
// kept (bounded: the whole memo goes when it outgrows a machine's worth).
var _memo = {}, _memoSize = 0;
function _prepared(text) {
    var P = _memo[text];
    if (P)
        return P;
    if (_memoSize > 4096) {
        _memo = {};
        _memoSize = 0;
    }
    P = _prepare(text);
    _memo[text] = P;
    _memoSize++;
    return P;
}

// Scratch, grown on demand and reused: an alignment allocates nothing but its answer. SPARSE: a row of the programme only has a
// value where the text holds that term character, so a row is the LIST of those positions (`_pos`), their scores (`_score`) and the
// entry of the previous row each came from (`_back`); `_row` marks where each row starts. The straight programme (one cell per text
// position per term character, O(m*n)) is the definition, and this must give
// its scores and its indices, ties included. On a 2 KB clipboard text a common letter is ~10 % of the
// positions, a rarer one less, and the engine's per-cell cost is what a straight alignment pays for on every keystroke.
var _pos = new Int32Array(0), _score = new Float64Array(0), _back = new Int32Array(0);
var _row = new Int32Array(0);
function _scratch(size, rows) {
    if (_pos.length < size) {
        _pos = new Int32Array(size * 2);
        _score = new Float64Array(size * 2);
        _back = new Int32Array(size * 2);
    }
    if (_row.length < rows + 1)
        _row = new Int32Array(rows * 2 + 2);
}

// One term against a prepared text: the best alignment, or null. Row i holds the positions of term[i]; a position's value is the
// best predecessor in row i-1 -- the position right before it (the consecutive bonus) or any position two or more before, whose
// gap penalty is 3 for the first skipped character and 1 for each after it: (score + position) of the predecessor is what a gap
// compares, so the best gap predecessor up to j-2 is a running maximum over the previous row (the EARLIEST on a tie, as the
// straight programme's carry keeps the older one on `>`). `wantIdx` false skips the matched positions (a ranking needs the score).
function _term(term, P, wantIdx) {
    var m = term.length, n = P.n;
    if (m === 0 || m > n)
        return null;
    // Cheap reject first: most texts do not contain the term at all.
    for (var q = 0, at0 = 0; q < m; q++) {
        at0 = P.lower.indexOf(term.charAt(q), at0);
        if (at0 < 0)
            return null;
        at0++;
    }
    var NEG = -1e9;
    var bonus = P.bonus, lower = P.lower;
    _scratch(m * n, m);
    var pos = _pos, score = _score, back = _back, row = _row;
    var top = 0;
    for (var i = 0; i < m; i++) {
        var ch = term.charAt(i);
        row[i] = top;
        var pFrom = i > 0 ? row[i - 1] : 0, pTo = row[i];            // the previous row's entries: [pFrom, pTo)
        var pc = pFrom, pk = pFrom;                                   // pc: the consecutive candidate, pk: the gap candidates
        var gapAdj = NEG, gapAt = -1;
        for (var j = lower.indexOf(ch); j >= 0 && j < n; j = lower.indexOf(ch, j + 1)) {
            var own = SCORE_MATCH + bonus[j];
            if (i === 0) {
                pos[top] = j;
                score[top] = own;
                back[top] = -1;
                top++;
                continue;
            }
            var bestPrev = NEG, bestK = -1;
            while (pc < pTo && pos[pc] < j - 1)
                pc++;
            if (pc < pTo && pos[pc] === j - 1 && score[pc] > NEG / 2) {
                bestPrev = score[pc] + BONUS_CONSECUTIVE;
                bestK = pc;
            }
            while (pk < pTo && pos[pk] <= j - 2) {
                if (score[pk] > NEG / 2 && score[pk] + pos[pk] > gapAdj) {
                    gapAdj = score[pk] + pos[pk];
                    gapAt = pk;
                }
                pk++;
            }
            if (gapAt >= 0) {
                var carry = gapAdj - PENALTY_GAP_START - (j - 2);
                if (carry > bestPrev) {
                    bestPrev = carry;
                    bestK = gapAt;
                }
            }
            pos[top] = j;
            if (bestK >= 0) {
                score[top] = bestPrev + own;
                back[top] = bestK;
            } else {
                score[top] = NEG;
                back[top] = -1;
            }
            top++;
        }
    }
    var lastFrom = row[m - 1], bestE = -1, bestS = NEG / 2;
    for (var e = lastFrom; e < top; e++)
        if (score[e] > bestS) {
            bestS = score[e];
            bestE = e;
        }
    if (bestE < 0)
        return null;
    if (!wantIdx)
        return {
            score: bestS,
            indices: null
        };
    var idx = new Array(m);
    for (var t = m - 1, at = bestE; t >= 0; t--) {
        idx[t] = pos[at];
        at = back[at];
    }
    return {
        score: bestS,
        indices: idx
    };
}

function _terms(query) {
    return String(query || "").toLowerCase().split(/\s+/).filter(function (s) {
        return s.length > 0;
    });
}

// The terms of the last query asked, kept: a ranking asks the same query once per record and field.
var _qLast = null, _qTerms = null;
function _termsOf(query) {
    if (query === _qLast && _qTerms !== null)
        return _qTerms;
    _qTerms = _terms(query);
    _qLast = query;
    return _qTerms;
}

function match(query, text) {
    var terms = _terms(query);
    var t = String(text || "");
    if (terms.length === 0 || t.length === 0)
        return null;
    var P = null, total = 0, seen = {};
    for (var i = 0; i < terms.length; i++) {
        // Reject on the cheap test before preparing anything.
        if (t.length < terms[i].length)
            return null;
        if (!P)
            P = _prepared(t);
        var r = _term(terms[i], P, true);
        if (!r)
            return null;
        total += r.score;
        for (var k = 0; k < r.indices.length; k++)
            seen[r.indices[k]] = true;
    }
    var indices = Object.keys(seen).map(Number).sort(function (a, b) {
        return a - b;
    });
    return {
        score: total,
        indices: indices
    };
}

function best(query, fields, weights) {
    var out = null;
    for (var f = 0; f < fields.length; f++) {
        var r = match(query, fields[f]);
        if (!r)
            continue;
        var w = weights && weights[f] !== undefined ? weights[f] : 1;
        var s = r.score * w;
        if (!out || s > out.score)
            out = {
                score: s,
                field: f,
                indices: r.indices
            };
    }
    return out;
}

// best() for a RANKING: only the score of the best field (or null), no matched positions -- no index arrays, no `seen` set, no sort.
// The same number best() gives.
function bestScore(query, fields, weights) {
    var terms = _termsOf(query);
    if (terms.length === 0)
        return null;
    var out = null;
    for (var f = 0; f < fields.length; f++) {
        var t = String(fields[f] || "");
        if (t.length === 0)
            continue;
        var P = null, total = 0, ok = true;
        for (var i = 0; i < terms.length; i++) {
            if (t.length < terms[i].length) {
                ok = false;
                break;
            }
            if (!P)
                P = _prepared(t);
            var r = _term(terms[i], P, false);
            if (!r) {
                ok = false;
                break;
            }
            total += r.score;
        }
        if (!ok)
            continue;
        var w = weights && weights[f] !== undefined ? weights[f] : 1;
        var sc = total * w;
        if (out === null || sc > out)
            out = sc;
    }
    return out;
}
