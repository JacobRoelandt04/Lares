.pragma library
.import "Interest.js" as Interest

// =============================================================================
// WikiPool.js -- the day, the slots and the refill latch. Pure, loads under node.
// Contract: docs/contracts/wiki.md.
//
//   dayKey(nowMs, rolloverHour = 4)      "YYYY-MM-DD" of the wiki day
//   unseen(rows, seen)                   the index rows not yet seen
//   rollSlot(slot, day, seen)            the slot as it stands on `day`
//   pickForSlot(tab, rows, ..., cfg)     { id, family, topic, why } -- a day's pick
//   nextFor(tab, rows, ..., cfg, cur)    the same, never `cur` (on-demand next)
//   needsRefill(unseen, ask, now, cfg)   { ask, latch } -- the "process 30 more?" ask
//   refillAnswered(latch, unseen, now)   the latch once the user said yes
//   refillLater(latch, unseen, now)      the latch once the user said "Later" (asks again after reaskMs)
//   seenDue(visibleMs, cfg)              has it been on screen long enough
//
// THE DAY ROLLS AT 04:00 LOCAL, and "04:00 local" is read off the wall clock,
// never by subtracting four hours of milliseconds: on the night the clocks go
// forward (2026-03-29) 02:00Z minus four hours is 23:00 the evening before, so
// the new day would start an hour late; on the night they go back (10-25) the
// repeated hour would put 03:59 CET into the new day. The wall-clock hour and
// minute decide, and a local time before the rollover belongs to the day
// before.
//
// ADVANCE ONLY WHEN SEEN. A day's article that was never seen carries over to
// the next day (same id, new day); a seen one is done for good and the slot
// asks for a new pick. Within the day the slot is never touched: "next" is an
// ask, not a roll.
//
// THE REFILL LATCH. A latch is { latchedAt: count|null, at: ms, answered, later }. `later`: the user pressed "Later" at `at` -- the ask is
// closed until `reaskMs` have passed (the count dropping does not bring it back sooner: they said later), then it comes again.
// The ask fires once when the unseen count first reaches askAt (5). It fires
// AGAIN only when the count dropped below the latched count (the user is
// using up the last ones) or when 24 h passed with no answer. An answered
// ask stays quiet until the pool has risen above askAt and dropped again;
// rising above askAt clears the latch. Evaluating the same numbers twice never
// asks twice (the caller stores the latch that comes back).
// =============================================================================

var HOUR_MS = 3600000;
var ROLLOVER_HOUR = 4;

var DEFAULTS = {
    rolloverHour: ROLLOVER_HOUR,
    askAt: 5,
    reaskMs: 24 * HOUR_MS,
    seenMs: 5000
};

function _c(cfg) {
    const out = {};
    for (const k in DEFAULTS) {
        const v = cfg ? Number(cfg[k]) : NaN;
        out[k] = (cfg && cfg[k] !== null && cfg[k] !== undefined && cfg[k] !== "" && isFinite(v)) ? v : DEFAULTS[k];
    }
    return out;
}

function _two(n) {
    return (n < 10 ? "0" : "") + n;
}

// The wiki day of an instant, in local time.
function dayKey(nowMs, rolloverHour) {
    const h = rolloverHour === undefined || rolloverHour === null ? ROLLOVER_HOUR : rolloverHour;
    const d = new Date(nowMs);
    let y = d.getFullYear(), m = d.getMonth(), day = d.getDate();
    if (d.getHours() * 60 + d.getMinutes() < h * 60) {
        const prev = new Date(y, m, day - 1, 12);      // noon: no DST edge on the way
        y = prev.getFullYear();
        m = prev.getMonth();
        day = prev.getDate();
    }
    return y + "-" + _two(m + 1) + "-" + _two(day);
}

function unseen(rows, seen) {
    const out = [];
    const s = seen || {};
    for (let i = 0; i < (rows ? rows.length : 0); i++)
        if (rows[i] && !s[rows[i].id])
            out.push(rows[i]);
    return out;
}

// -> { day, id, shownMs, why }; id === null means "this slot needs a new pick".
function rollSlot(slot, day, seen) {
    if (!slot || !slot.id)
        return { day: day, id: null, shownMs: 0, why: null };
    if (slot.day === day)
        return { day: slot.day, id: slot.id, shownMs: slot.shownMs || 0, why: slot.why || null };
    if (!(seen && seen[slot.id]))
        return { day: day, id: slot.id, shownMs: slot.shownMs || 0, why: slot.why || null };
    return { day: day, id: null, shownMs: 0, why: null };
}

// ---- picking ---------------------------------------------------------------------

// `families` is families.json (its "discover" / "deepen" are read) or an
// already built tab config (Interest.tabConfig).
function _tabCfg(families, tab, cfg) {
    const tc = families && Array.isArray(families.families) ? families : Interest.tabConfig(families, tab);
    const out = {};
    for (const k in tc)
        if (k !== "_resolved")
            out[k] = tc[k];
    if (cfg)                                    // the interest knobs (draws, halfLifeMs, ...)
        for (const k in cfg)
            if (out[k] === undefined)
                out[k] = cfg[k];
    return Interest.resolve(out);
}

// The judge's score for a row (0.5 when it has none) times how well its fame
// suits the reader's target; both are in [0, 1], the product feeds weightedPick.
function _scoreOf(row, target) {
    const jev = typeof row.jevScore === "number" && isFinite(row.jevScore) ? row.jevScore : 0.5;
    return Interest.popularityWeight(row.popularityBand, target === undefined ? 0.5 : target) * jev;
}

function _pick(tab, rows, seen, interest, families, now, rng, cfg, excludeId) {
    const c = _tabCfg(families, tab, cfg);
    const r = typeof rng === "function" ? rng : Math.random;
    const pool = unseen(rows, seen).filter(function (row) { return row.id !== excludeId; });
    if (pool.length === 0)
        return { id: null, family: null, topic: null, why: null };

    // The interest is sampled again over what can be shown right now.
    const byFam = {}, avail = [];
    for (let i = 0; i < pool.length; i++) {
        const f = pool[i].family;
        if (!byFam[f]) {
            byFam[f] = [];
            avail.push(f);
        }
        byFam[f].push(pool[i]);
    }
    const pf = Interest.pickFamily(interest, avail, now, r, c);
    if (!pf) {                                  // rows of families this tab no longer knows: still shown, by score alone
        const row = pool[Interest.weightedPick(pool.map(function (x) { return _scoreOf(x, 0.5); }), r())];
        return { id: row.id, family: row.family, topic: row.topic || "", why: { p: 0, oneIn: 0, openRate: null } };
    }
    const famRows = byFam[pf.family];
    const topics = famRows.map(function (row) { return row.topic || ""; });
    const pt = Interest.pickTopic(interest, pf.family, topics, now, r, c);
    const cand = pt ? famRows.filter(function (row) { return (row.topic || "") === pt.topic; }) : famRows;

    const target = Interest.popularityTarget(interest, pf.family, now, c);
    const row = cand[Interest.weightedPick(cand.map(function (x) { return _scoreOf(x, target); }), r())];
    return { id: row.id, family: pf.family, topic: pt ? pt.topic : "",
             why: { p: pf.p, oneIn: pf.oneIn, openRate: pf.openRate } };
}

// The day's article for a tab: an unseen row, family first, then topic, then a
// popularity- and score-weighted row. Deterministic under a fixed rng.
function pickForSlot(tab, rows, seen, interest, families, now, rng, cfg) {
    return _pick(tab, rows, seen, interest, families, now, rng, cfg, null);
}

// On-demand "next": the same pick, never the card on screen (the caller marks
// that one seen).
function nextFor(tab, rows, seen, interest, families, now, rng, cfg, currentId) {
    return _pick(tab, rows, seen, interest, families, now, rng, cfg, currentId);
}

// ---- refill ----------------------------------------------------------------------

function needsRefill(unseenCount, askState, now, cfg) {
    const c = _c(cfg);
    const l = askState && typeof askState === "object" ? askState : null;
    const latched = l && typeof l.latchedAt === "number" ? l.latchedAt : null;
    const cleared = { latchedAt: null, at: 0, answered: false, later: false };
    if (unseenCount > c.askAt)
        return { ask: false, latch: cleared };
    const fresh = { latchedAt: unseenCount, at: now, answered: false, later: false };
    if (latched === null)
        return { ask: true, latch: fresh };
    const keep = { latchedAt: latched, at: l.at || 0, answered: l.answered === true, later: l.later === true };
    if (keep.answered)
        return { ask: false, latch: keep };
    if (keep.later)
        return now - keep.at >= c.reaskMs ? { ask: true, latch: fresh } : { ask: false, latch: keep };
    if (unseenCount < latched)
        return { ask: true, latch: fresh };
    if (now - keep.at >= c.reaskMs)
        return { ask: true, latch: fresh };
    return { ask: false, latch: keep };
}

// The user said yes (the notification's default action, or Start batch).
function refillAnswered(latch, unseenCount, now) {
    const at = latch && typeof latch.latchedAt === "number" ? latch.latchedAt : unseenCount;
    return { latchedAt: at, at: now, answered: true, later: false };
}

// The user said "Later": the ask is closed for reaskMs from now.
function refillLater(latch, unseenCount, now) {
    const at = latch && typeof latch.latchedAt === "number" ? latch.latchedAt : unseenCount;
    return { latchedAt: at, at: now, answered: false, later: true };
}

function seenDue(visibleMs, cfg) {
    return visibleMs >= _c(cfg).seenMs;
}
