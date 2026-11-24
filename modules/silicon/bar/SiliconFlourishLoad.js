.pragma library

// =============================================================================
// SiliconFlourishLoad.js -- WHEN THE BAR ICON FLOURISHES ON THE CPU'S LOAD (a PROPOSAL, feedback/
// silicon.md "Bar icon flourish": "the leaf after a heavy-load session clears, the bolt as one starts, the scales while the
// load swings"). Pure: one reading in, "" or the event out.
//
//   start   the load has stood at or above `heavyAt` for `holdMs`: a heavy session has begun
//   clear   after a session, the load has stood at or below `calmAt` for `holdMs`: it is over
//   swing   the load has gone back and forth `swings` times by at least `swingDelta` within `swingWindowMs` (and no session
//           is on, so a swing is not a session's own wobble): the machine is being worked in bursts
//
// A hold, not an edge: a spike that is gone in a reading starts nothing, and a session that dips for a moment does not end.
// Each event has its own cooldown. A reading is `load` 0..1 at `nowMs`; the state is the caller's, one per bar button.
// =============================================================================

var DEFAULTS = {
    heavyAt: 0.7,
    calmAt: 0.25,
    holdMs: 8000,
    swingDelta: 0.3,
    swings: 3,
    swingWindowMs: 20000,
    cooldownMs: 30000
};

function opts(o) {
    var r = {};
    for (var k in DEFAULTS)
        r[k] = o && o[k] !== undefined ? o[k] : DEFAULTS[k];
    return r;
}

function newState() {
    return { phase: "calm", heavySince: -1, calmSince: -1, ref: null, dir: 0, flips: [], lastSwing: -1e15, lastStart: -1e15, lastClear: -1e15 };
}

function step(st, load, nowMs, o) {
    var p = opts(o);
    if (typeof load !== "number" || !isFinite(load))
        return "";
    // session start / end
    if (st.phase === "calm") {
        if (load >= p.heavyAt) {
            if (st.heavySince < 0)
                st.heavySince = nowMs;
            if (nowMs - st.heavySince >= p.holdMs) {
                st.phase = "heavy";
                st.heavySince = -1;
                st.flips = [];
                st.ref = null;
                st.dir = 0;
                if (nowMs - st.lastStart >= p.cooldownMs) {
                    st.lastStart = nowMs;
                    return "start";
                }
            }
        } else {
            st.heavySince = -1;
        }
    } else {
        if (load <= p.calmAt) {
            if (st.calmSince < 0)
                st.calmSince = nowMs;
            if (nowMs - st.calmSince >= p.holdMs) {
                st.phase = "calm";
                st.calmSince = -1;
                st.ref = load;
                st.dir = 0;
                if (nowMs - st.lastClear >= p.cooldownMs) {
                    st.lastClear = nowMs;
                    return "clear";
                }
            }
        } else {
            st.calmSince = -1;
        }
        return "";
    }
    // swings, outside a session: a reversal is a move of `swingDelta` against the direction the load was going
    if (st.ref === null) {
        st.ref = load;
        return "";
    }
    var d = load - st.ref;
    if (st.dir === 0) {
        if (Math.abs(d) >= p.swingDelta) {
            st.dir = d > 0 ? 1 : -1;
            st.ref = load;
        }
    } else if (st.dir === 1) {
        if (load > st.ref) {
            st.ref = load;
        } else if (st.ref - load >= p.swingDelta) {
            st.flips.push(nowMs);
            st.dir = -1;
            st.ref = load;
        }
    } else {
        if (load < st.ref) {
            st.ref = load;
        } else if (load - st.ref >= p.swingDelta) {
            st.flips.push(nowMs);
            st.dir = 1;
            st.ref = load;
        }
    }
    st.flips = st.flips.filter(function (t) { return nowMs - t <= p.swingWindowMs; });
    if (st.flips.length >= p.swings && nowMs - st.lastSwing >= p.cooldownMs) {
        st.lastSwing = nowMs;
        st.flips = [];
        return "swing";
    }
    return "";
}
