.pragma library

// =============================================================================
// VeilBag.js -- which veil this lock shows: a SHUFFLE BAG, so a veil is never starved: each veil is
// guaranteed a window in which it shows.
//
// A ROUND is a fresh random permutation of the enabled veils; a lock takes the next one off the front. The bag is persisted
// (LockRoot keeps it in the lock's state dir), so the order survives a restart of the lock and of the shell. The guarantees:
//   - inside a round every veil comes exactly once, so any N consecutive locks that start with a round show all N veils;
//   - a new round never starts with the veil the previous round ended on (two locks in a row never look the same), which is what makes
//     the longest wait for one veil 2N-2 locks in between (last of this round, then first of the next - the same veil, at most);
//     any 2N-1 consecutive locks show every veil;
//   - the list in lockscreen.jsonc changing under a bag in use RECONCILES it: a veil taken out of the list leaves the round at once, a
//     veil put into it is inserted at a random place among those still to come (so it shows up within this round, not after it).
//
// State: { round: [names the round started from], remaining: [names still to come], last: "the veil shown last" }.
// Everything is pure: `rnd` is a function returning a number in [0, 1) (Math.random in the lock, a script in the cases).
// =============================================================================

function _isName(n) {
    return typeof n === "string" && n !== "";
}

function _uniq(list) {
    var out = [];
    if (!list || typeof list.length !== "number")
        return out;
    for (var i = 0; i < list.length; i++)
        if (_isName(list[i]) && out.indexOf(list[i]) < 0)
            out.push(list[i]);
    return out;
}

function _int(rnd, n) {
    return Math.min(n - 1, Math.floor(rnd() * n));
}

function empty() {
    return { round: [], remaining: [], last: "" };
}

// The state file's text -> a state. Anything unreadable is an empty bag (a first lock, a half-written file): the lock must come up.
function parse(text) {
    var o = null;
    try {
        o = JSON.parse(String(text));
    } catch (e) {
        return empty();
    }
    if (o === null || typeof o !== "object")
        return empty();
    return { round: _uniq(o.round), remaining: _uniq(o.remaining), last: _isName(o.last) ? o.last : "" };
}

function serialize(state) {
    return JSON.stringify({ round: state.round, remaining: state.remaining, last: state.last });
}

// A fresh round: a Fisher-Yates shuffle of `names`, whose first is not `last` unless there is no other.
function _newRound(names, last, rnd) {
    var bag = names.slice();
    for (var i = bag.length - 1; i > 0; i--) {
        var j = _int(rnd, i + 1);
        var t = bag[i];
        bag[i] = bag[j];
        bag[j] = t;
    }
    _notFirst(bag, last, rnd);
    return bag;
}

// bag[0] must not be `last`: swap it with a random later one.
function _notFirst(bag, last, rnd) {
    if (bag.length > 1 && bag[0] === last) {
        var k = 1 + _int(rnd, bag.length - 1);
        var t = bag[0];
        bag[0] = bag[k];
        bag[k] = t;
    }
}

// The next veil. `state` is the bag as it was kept, `names` the veils enabled now (any list: junk and repeats are dropped).
// -> { name, state }; `name` is "" when `names` holds no name at all.
function draw(state, names, rnd) {
    var want = _uniq(names);
    var s = state || empty();
    if (want.length === 0)
        return { name: "", state: { round: [], remaining: [], last: s.last || "" } };
    var last = _isName(s.last) ? s.last : "";
    var round = _uniq(s.round).filter(function (n) { return want.indexOf(n) >= 0; });
    var remaining = _uniq(s.remaining).filter(function (n) { return round.indexOf(n) >= 0; });
    // a veil put into the list since: it joins this round, somewhere among the veils still to come
    for (var i = 0; i < want.length; i++) {
        if (round.indexOf(want[i]) < 0) {
            round.push(want[i]);
            remaining.splice(_int(rnd, remaining.length + 1), 0, want[i]);
        }
    }
    if (remaining.length === 0) {
        round = want.slice();
        remaining = _newRound(want, last, rnd);
    } else {
        _notFirst(remaining, last, rnd);
    }
    var name = remaining.shift();
    return { name: name, state: { round: round, remaining: remaining, last: name } };
}
