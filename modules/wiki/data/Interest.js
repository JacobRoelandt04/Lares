.pragma library
.import "../../common/components/MpdShuffle.js" as Shuffle

// =============================================================================
// Interest.js -- what the wiki module learns about the reader. Pure, loads under node.
// Contract: docs/contracts/wiki.md.
//
// DISCOUNTED THOMPSON SAMPLING, TWO LEVELS. Level one is the family
// (Physics, History, ...), level two the topic inside a family. Every arm keeps
// a Beta(alpha, beta) posterior built from the events below; nothing is ever
// ruled out (the cap) and old taste fades (the half-life).
//
//   EVENTS  { f: family, t: topic, k: kind, w: weight, at: ms, band?: 0..1 }
//     open +1.0   more +1.5   less -1.5   dwell +0.25   quick_next -0.25
//     follow +0.4   knew 0 (popularity only)   seen 0 (exposure, see below)
//
//   DISCOUNT  d(e) = 2^( -(now - e.at) / H ),  H = halfLifeMs (90 days).
//     An event exactly one half-life old weighs 0.5; a stamp from the future
//     (a clock that stepped back) counts as age 0.
//
//   POSTERIOR of one arm (alpha0 = beta0 = 1, a weak prior):
//     alpha = alpha0 + sum over events with w*d > 0 of  w * d
//     beta  = beta0  + sum over events with w*d < 0 of -w * d
//                    + seenBeta * sum over "seen" events of d          (0.3)
//   A "knew" event touches neither: it moves the popularity target only. A
//   "seen" event is an exposure: an arm that is shown a lot and never opened
//   drifts down, by 0.3 per showing.
//
//   SHARES  sampleShares(): `draws` Thompson draws (one theta ~ Beta per arm,
//   the arm with the largest theta wins), share = wins / draws. Beta(a, b) is
//   X / (X + Y) with X ~ Gamma(a), Y ~ Gamma(b), Marsaglia-Tsang with the
//   injected rng. Posteriors that are all equal (no evidence anywhere) answer
//   the uniform share EXACTLY instead of a noisy count: that is what lets an
//   empty history reproduce the deepen priors to the last digit.
//
//   CAP  capShares(): the exact limit of clamp-and-renormalise. The shares q
//   are   q_i = w_i * clamp(t_i, m, R*m)   with the ONE level m > 0 at which
//   they sum to 1 (bisection; the sum is monotone in m). So max/min <= R holds
//   to the last digit, every arm keeps a floor above zero, and a vector that
//   is already inside the ratio comes back unchanged (m then sits anywhere on
//   a flat stretch and the clamp does nothing).
//     * plain (discover, ratio 4):  w_i = 1, t_i = raw share.
//     * with `priors` (deepen, ratio 2): w_i = prior_i (normalised), t_i = raw
//       share * n, i.e. the TILT the evidence gives an arm (1 = neutral). The
//       cap is on the tilts, so it is relative to the priors, and no evidence
//       (tilt 1 everywhere) gives the priors themselves.
//     * PINNED arms (the computing guest): left out of the cap, then appended
//       at k * FLOOR, floor = the smallest share among the capped others, and
//       everything renormalised:  q_i / (1 + k*floor)  and  k*floor / (1 + k*floor).
//       k = 1 puts the guest exactly level with the least-liked family, so it
//       comes up as rarely as the reader's least favourite and never more,
//       whatever it earned. (A pinned arm's raw share is ignored.)
//
//   PICK  pickFamily() does NOT take the arg-max of one Thompson draw (that
//   cannot be capped): it draws a family from the CAPPED shares, so the cap
//   bounds how often anything comes up. `available` (families that have unseen
//   entries) is applied BEFORE the sampling and the cap, so the shares are
//   always "of what can be shown now".
//
//   POPULARITY per family: a target band in [0.1, 1] (0 obscure, 1 famous).
//     target = (K*0.5 + sum u_j * band_j) / (K + sum u_j)   over open/more events
//              carrying a band, u_j = w_j * d_j, K = popPriorWeight (2)
//              - knewStep * sum d over knew events                    (0.1 each)
//   clamped to [knewFloor, 1]. `less` does not move it (it is about the
//   family, not about how famous the article was).
//   popularityWeight(band, target) = max(0.2, exp(-((band - target)/0.35)^2)).
// =============================================================================

var DAY_MS = 86400000;

var WEIGHTS = { open: 1.0, more: 1.5, less: -1.5, dwell: 0.25, quick_next: -0.25,
                follow: 0.4, knew: 0, seen: 0 };

var DEFAULTS = {
    halfLifeMs: 90 * DAY_MS,
    priorAlpha: 1,
    priorBeta: 1,
    seenBeta: 0.3,
    draws: 400,
    maxEvents: 400,
    minEvidence: 3,        // discounted showings before an open rate is worth saying
    ratio: 4,              // family cap (discover 4, deepen 2)
    topicRatio: 4,
    popPrior: 0.5,
    popPriorWeight: 2,
    popWidth: 0.35,
    popFloor: 0.2,
    knewStep: 0.1,
    knewFloor: 0.1
};

// ---- rng ---------------------------------------------------------------------

// The PRNG of MpdShuffle (mulberry32), so a seeded test and a seeded probe use
// one generator across the shell. Every random function below takes `rng`, a
// function returning [0, 1); Math.random is only the documented default for a
// caller that passes none.
function seeded(seed) {
    return Shuffle._mulberry32(seed >>> 0);
}

function _rngOf(rng) {
    return typeof rng === "function" ? rng : Math.random;
}

function _normal(rng) {
    const u1 = 1 - rng();               // (0, 1], so the log is finite
    const u2 = rng();
    return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

// Marsaglia-Tsang, shape >= 1; shape < 1 by the boost  G(a) = G(a+1) * U^(1/a).
function gammaSample(shape, rng) {
    if (!(shape > 0))
        return 0;
    if (shape < 1) {
        const g = gammaSample(shape + 1, rng);
        return g * Math.pow(1 - rng(), 1 / shape);
    }
    const d = shape - 1 / 3, c = 1 / Math.sqrt(9 * d);
    for (let i = 0; i < 100; i++) {
        const x = _normal(rng);
        let v = 1 + c * x;
        if (v <= 0)
            continue;
        v = v * v * v;
        const u = 1 - rng(), x2 = x * x;
        if (u < 1 - 0.0331 * x2 * x2)
            return d * v;
        if (Math.log(u) < 0.5 * x2 + d * (1 - v + Math.log(v)))
            return d * v;
    }
    return d;
}

function betaSample(a, b, rng) {
    const x = gammaSample(a, rng), y = gammaSample(b, rng);
    const s = x + y;
    return s > 0 ? x / s : 0.5;
}

// ---- config and events ---------------------------------------------------------

// Fills every knob from DEFAULTS and carries the tab's own fields:
//   families [ids | {id, topics, kind}], guest id|null, priors {id: share}|null.
function resolve(cfg) {
    if (cfg && cfg._resolved)
        return cfg;
    const c = { _resolved: true };
    for (const k in DEFAULTS) {
        const v = cfg ? Number(cfg[k]) : NaN;
        c[k] = (cfg && cfg[k] !== null && cfg[k] !== undefined && cfg[k] !== "" && isFinite(v)) ? v : DEFAULTS[k];
    }
    c.families = cfg && Array.isArray(cfg.families) ? cfg.families : [];
    c.guest = cfg && cfg.guest ? cfg.guest : null;
    c.priors = cfg && cfg.priors ? cfg.priors : null;
    return c;
}

function _ids(list) {
    const out = [];
    for (let i = 0; i < (list ? list.length : 0); i++) {
        const f = list[i];
        const id = typeof f === "string" ? f : (f && f.id);
        if (id !== undefined && id !== null && id !== "")
            out.push(String(id));
    }
    return out;
}

function _famObj(c, id) {
    for (let i = 0; i < c.families.length; i++)
        if (c.families[i] && (c.families[i] === id || c.families[i].id === id))
            return typeof c.families[i] === "string" ? { id: id } : c.families[i];
    return null;
}

function newState() {
    return { events: [] };
}

function _event(ev) {
    if (!ev || typeof ev !== "object" || typeof ev.f !== "string" || ev.f === "")
        return null;
    if (!Object.prototype.hasOwnProperty.call(WEIGHTS, ev.k))
        return null;
    const at = Number(ev.at);
    if (!isFinite(at) || at <= 0)
        return null;
    let w = Number(ev.w);
    if (ev.w === null || ev.w === undefined || ev.w === "" || !isFinite(w))
        w = WEIGHTS[ev.k];
    const e = { f: ev.f, t: typeof ev.t === "string" ? ev.t : "", k: ev.k, w: w, at: Math.round(at) };
    const band = Number(ev.band);
    if (ev.band !== null && ev.band !== undefined && ev.band !== "" && isFinite(band))
        e.band = Math.max(0, Math.min(1, band));
    return e;
}

function _events(state) {
    return state && Array.isArray(state.events) ? state.events : [];
}

// Appends one event and keeps the newest maxEvents. Pure: a new state comes back.
function record(state, ev, cfg) {
    const c = resolve(cfg);
    const e = _event(ev);
    let list = _events(state).slice();
    if (e)
        list.push(e);
    if (list.length > c.maxEvents)
        list = list.slice(list.length - c.maxEvents);
    return { events: list };
}

// A state read from state.json (hand-edited, older, half written) made safe:
// bad events dropped, weights defaulted, oldest first, bounded.
function normalise(v, cfg) {
    const c = resolve(cfg);
    const src = v && typeof v === "object" ? _events(v) : [];
    const list = [];
    for (let i = 0; i < src.length; i++) {
        const e = _event(src[i]);
        if (e)
            list.push({ e: e, i: i });
    }
    list.sort(function (a, b) { return (a.e.at - b.e.at) || (a.i - b.i); });
    const out = list.map(function (x) { return x.e; });
    return { events: out.length > c.maxEvents ? out.slice(out.length - c.maxEvents) : out };
}

// ---- discount and posterior ----------------------------------------------------

function discount(atMs, nowMs, halfLifeMs) {
    let age = nowMs - atMs;
    if (!(age > 0))
        age = 0;
    return Math.pow(2, -age / halfLifeMs);
}

// arm -> { a, b, seen, open }; level 1 keys by family, level 2 by topic of `family`.
function _tally(events, now, c, level, family) {
    const out = {};
    for (let i = 0; i < events.length; i++) {
        const e = events[i];
        if (level === 2 && e.f !== family)
            continue;
        const arm = level === 1 ? e.f : e.t;
        if (arm === undefined || arm === null || arm === "")
            continue;
        const d = discount(e.at, now, c.halfLifeMs);
        let s = out[arm];
        if (!s)
            s = out[arm] = { a: c.priorAlpha, b: c.priorBeta, seen: 0, open: 0 };
        if (e.k === "seen") {
            s.b += c.seenBeta * d;
            s.seen += d;
            continue;
        }
        if (e.k === "knew")
            continue;
        const x = e.w * d;
        if (x > 0)
            s.a += x;
        else if (x < 0)
            s.b -= x;
        if (e.k === "open")
            s.open += d;
    }
    return out;
}

// { alpha, beta } of a family, or of one topic inside it.
function posterior(state, family, topic, now, cfg) {
    const c = resolve(cfg);
    const hasTopic = topic !== undefined && topic !== null && topic !== "";
    const s = _tally(_events(state), now, c, hasTopic ? 2 : 1, family)[hasTopic ? topic : family];
    return s ? { alpha: s.a, beta: s.b } : { alpha: c.priorAlpha, beta: c.priorBeta };
}

// How often the reader opens what this family shows: discounted opens over
// discounted showings, or null while there are fewer than minEvidence showings
// (a rate over two showings would be a guess dressed as a fact).
function openRate(state, family, now, cfg) {
    const c = resolve(cfg);
    const s = _tally(_events(state), now, c, 1)[family];
    if (!s || s.seen < c.minEvidence)
        return null;
    return Math.min(1, s.open / s.seen);
}

// ---- shares --------------------------------------------------------------------

// Win frequency of each arm over `draws` Thompson draws. arms: ids or {id}.
function sampleShares(state, families, now, rng, draws, cfg) {
    const c = resolve(cfg);
    return _thompson(_ids(families), _tally(_events(state), now, c, 1), c, _rngOf(rng), draws > 0 ? draws : c.draws);
}

function _thompson(arms, tally, c, rng, draws) {
    const n = arms.length, out = {};
    if (n === 0)
        return out;
    const A = [], B = [];
    let same = true;
    for (let i = 0; i < n; i++) {
        const t = tally[arms[i]];
        A.push(t ? t.a : c.priorAlpha);
        B.push(t ? t.b : c.priorBeta);
        if (A[i] !== A[0] || B[i] !== B[0])
            same = false;
    }
    if (same || n === 1) {
        for (let i = 0; i < n; i++)
            out[arms[i]] = 1 / n;
        return out;
    }
    const wins = [];
    for (let i = 0; i < n; i++)
        wins.push(0);
    for (let k = 0; k < draws; k++) {
        let best = -1, bi = 0;
        for (let i = 0; i < n; i++) {
            const th = betaSample(A[i], B[i], rng);
            if (th > best) {
                best = th;
                bi = i;
            }
        }
        wins[bi]++;
    }
    for (let i = 0; i < n; i++)
        out[arms[i]] = wins[i] / draws;
    return out;
}

// q_i = w_i * clamp(t_i, m, R m), the level m at which they sum to 1, then / sum.
function _solveClamp(t, w, R) {
    let W = 0;
    for (let i = 0; i < w.length; i++)
        W += w[i];
    let lo = 0, hi = 1 / W;
    for (let it = 0; it < 100; it++) {
        const m = (lo + hi) / 2;
        let s = 0;
        for (let i = 0; i < t.length; i++)
            s += w[i] * Math.min(R * m, Math.max(m, t[i]));
        if (s < 1)
            lo = m;
        else
            hi = m;
    }
    const q = [];
    let S = 0;
    for (let i = 0; i < t.length; i++) {
        q.push(w[i] * Math.min(R * hi, Math.max(hi, t[i])));
        S += q[i];
    }
    for (let i = 0; i < q.length; i++)
        q[i] /= S;
    return q;
}

// p {id: raw share} -> {id: share}: sum 1, max/min <= ratio, every arm > 0.
// pinned {id: k} (true = 1): held out, then put at k * the smallest share.
// priors {id: share}: the cap is on the tilt relative to them (see the header).
function capShares(p, ratio, pinned, priors) {
    const R = ratio > 1 ? ratio : 1;
    const free = [], pins = [], out = {};
    let id;
    for (id in p)
        if (!(pinned && pinned[id]))
            free.push(id);
    if (pinned)
        for (id in pinned)
            if (pinned[id])
                pins.push(id);
    const n = free.length;
    if (n === 0) {
        for (let i = 0; i < pins.length; i++)
            out[pins[i]] = 1 / pins.length;
        return out;
    }
    const t = [], w = [];
    let T = 0, PW = 0;
    for (let i = 0; i < n; i++) {
        const v = Number(p[free[i]]);
        t.push(isFinite(v) && v > 0 ? v : 0);
        T += t[i];
    }
    for (let i = 0; i < n; i++)
        t[i] = T > 0 ? t[i] / T : 1 / n;
    if (priors) {
        for (let i = 0; i < n; i++) {
            const v = Number(priors[free[i]]);
            w.push(isFinite(v) && v > 0 ? v : 1 / n);
            PW += w[i];
        }
        for (let i = 0; i < n; i++) {
            w[i] /= PW;
            t[i] *= n;
        }
    } else {
        for (let i = 0; i < n; i++)
            w.push(1);
    }
    const q = _solveClamp(t, w, R);
    let floor = q[0];
    for (let i = 1; i < n; i++)
        floor = Math.min(floor, q[i]);
    let total = 1;
    const ks = [];
    for (let i = 0; i < pins.length; i++) {
        const k = pinned[pins[i]] === true ? 1 : Number(pinned[pins[i]]);
        ks.push(isFinite(k) && k > 0 ? k : 1);
        total += ks[i] * floor;
    }
    for (let i = 0; i < n; i++)
        out[free[i]] = q[i] / total;
    for (let i = 0; i < pins.length; i++)
        out[pins[i]] = ks[i] * floor / total;
    return out;
}

// The capped shares of one tab over the families that can be shown now.
// `cfg` is a tab config (see tabConfig): families, guest, ratio, priors.
function tabShares(state, available, now, rng, cfg) {
    const c = resolve(cfg);
    const ids = _ids(c.families);
    const avail = _set(available);
    const arms = [];
    let pin = null;
    for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        if (avail && !avail[id])
            continue;
        if (id === c.guest) {
            pin = {};
            pin[id] = 1;
        } else {
            arms.push(id);
        }
    }
    const raw = _thompson(arms, _tally(_events(state), now, c, 1), c, _rngOf(rng), c.draws);
    let pri = null;
    if (c.priors) {
        pri = {};
        for (let i = 0; i < arms.length; i++)
            pri[arms[i]] = c.priors[arms[i]];
    }
    return capShares(raw, c.ratio, pin, pri);
}

function _set(list) {
    if (!list)
        return null;
    const s = {};
    for (let i = 0; i < list.length; i++)
        s[list[i]] = true;
    return s;
}

// Draws one arm by its share; `order` fixes which arm owns which stretch of [0,1).
function _draw(shares, order, u) {
    let acc = 0, last = null;
    for (let i = 0; i < order.length; i++) {
        if (shares[order[i]] === undefined)
            continue;
        acc += shares[order[i]];
        last = order[i];
        if (u < acc)
            return order[i];
    }
    return last;
}

function _orderOf(shares, c) {
    const ids = _ids(c.families);
    return ids.filter(function (id) { return shares[id] !== undefined; });
}

function _oneIn(p) {
    return p > 0 ? Math.max(1, Math.round(1 / p)) : 0;
}

// { p, oneIn, openRate } for the why-tip.
function whyFor(state, family, now, shares, cfg) {
    const p = shares && shares[family] !== undefined ? shares[family] : 0;
    return { p: p, oneIn: _oneIn(p), openRate: openRate(state, family, now, cfg) };
}

// -> { family, p, oneIn, openRate } | null (nothing available)
function pickFamily(state, available, now, rng, cfg) {
    const c = resolve(cfg);
    const r = _rngOf(rng);
    const shares = tabShares(state, available, now, r, c);
    const order = _orderOf(shares, c);
    if (order.length === 0)
        return null;
    const fam = _draw(shares, order, r());
    const why = whyFor(state, fam, now, shares, c);
    return { family: fam, p: why.p, oneIn: why.oneIn, openRate: why.openRate };
}

// The same machinery one level down: topics of `family`, cap `topicRatio`.
// -> { topic, p, oneIn } | null
function pickTopic(state, family, topics, now, rng, cfg) {
    const c = resolve(cfg);
    const r = _rngOf(rng);
    const arms = [];
    const seenT = {};
    for (let i = 0; i < (topics ? topics.length : 0); i++) {
        const t = topics[i] === null || topics[i] === undefined ? "" : String(topics[i]);
        if (!seenT[t]) {
            seenT[t] = true;
            arms.push(t);
        }
    }
    if (arms.length === 0)
        return null;
    const raw = _thompson(arms, _tally(_events(state), now, c, 2, family), c, r, c.draws);
    const shares = capShares(raw, c.topicRatio);
    const topic = _draw(shares, arms, r());
    return { topic: topic, p: shares[topic], oneIn: _oneIn(shares[topic]) };
}

// ---- tab config and the batch planner -------------------------------------------

// families.json (+ "discover" | "deepen") -> the flat config the picks read:
//   discover: the thirteen plus the guest at the end, cap 4, no priors;
//   deepen:   the source families with their prior shares, cap 2.
function tabConfig(fam, tab) {
    if (tab === "deepen") {
        const list = (fam && fam.deepen) || [];
        const priors = {};
        let sum = 0;
        for (let i = 0; i < list.length; i++)
            sum += list[i].share > 0 ? list[i].share : 0;
        for (let i = 0; i < list.length; i++)
            priors[list[i].id] = sum > 0 ? (list[i].share > 0 ? list[i].share : 0) / sum : 1 / list.length;
        return { families: list, guest: null, ratio: 2, priors: priors };
    }
    const list = ((fam && fam.discover) || []).slice();
    const guest = fam && fam.guest ? fam.guest : null;
    if (guest)
        list.push(guest);
    return { families: list, guest: guest ? guest.id : null, ratio: 4, priors: null };
}

function _topicsOf(c, id) {
    const f = _famObj(c, id);
    return f && Array.isArray(f.topics) ? f.topics : [];
}

function _kindOf(c, id) {
    const f = _famObj(c, id);
    if (f && f.kind)
        return f.kind;
    return id === "arch-tips" ? "tips" : "article";
}

// n picks for a batch, each a fresh Thompson sample: [{ family, topic, kind,
// band, why: { p, oneIn, openRate, topicP, via } }]. `band` is the family's
// popularity target, for the tool's candidate scoring. The guest is in the
// running at its pinned share.
function planBatch(state, tabCfg, n, now, rng) {
    const c = resolve(tabCfg);
    const r = _rngOf(rng);
    const out = [];
    for (let i = 0; i < n; i++) {
        const pf = pickFamily(state, null, now, r, c);
        if (!pf)
            break;
        const pt = pickTopic(state, pf.family, _topicsOf(c, pf.family), now, r, c);
        out.push({
            family: pf.family,
            topic: pt ? pt.topic : "",
            kind: _kindOf(c, pf.family),
            band: popularityTarget(state, pf.family, now, c),
            why: { p: pf.p, oneIn: pf.oneIn, openRate: pf.openRate,
                   topicP: pt ? pt.p : 1, via: pf.family === c.guest ? "guest" : "thompson" }
        });
    }
    return out;
}

// ---- popularity ------------------------------------------------------------------

function popularityTarget(state, family, now, cfg) {
    const c = resolve(cfg);
    const ev = _events(state);
    let num = c.popPriorWeight * c.popPrior, den = c.popPriorWeight, knew = 0;
    for (let i = 0; i < ev.length; i++) {
        const e = ev[i];
        if (e.f !== family)
            continue;
        const d = discount(e.at, now, c.halfLifeMs);
        if ((e.k === "open" || e.k === "more") && typeof e.band === "number") {
            const u = Math.max(0, e.w) * d;
            num += u * e.band;
            den += u;
        } else if (e.k === "knew") {
            knew += d;
        }
    }
    const t = num / den - c.knewStep * knew;
    return Math.max(c.knewFloor, Math.min(1, t));
}

function popularityWeight(band, target, cfg) {
    const c = resolve(cfg);
    if (typeof band !== "number" || !isFinite(band))
        return 1;                       // unknown fame is not a reason to hold it back
    const z = (band - target) / c.popWidth;
    return Math.max(c.popFloor, Math.exp(-z * z));
}

// ---- the shared weighted pick ------------------------------------------------------

// w_i = max(0.05, s_i)^2, normalised; the first i whose cumulative weight is
// above u. Python reads the same table (tools/wiki/lib/candidates.py).
function weightedPick(scores, u) {
    const n = scores ? scores.length : 0;
    if (n === 0)
        return -1;
    const w = [];
    let total = 0;
    for (let i = 0; i < n; i++) {
        const s = Number(scores[i]);
        const v = Math.max(0.05, isFinite(s) ? s : 0);
        w.push(v * v);
        total += w[i];
    }
    let acc = 0;
    for (let i = 0; i < n; i++) {
        acc += w[i] / total;
        if (acc > u)
            return i;
    }
    return n - 1;
}
