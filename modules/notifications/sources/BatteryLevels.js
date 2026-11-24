.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// BatteryLevels.js -- what the battery has to say, as pure decisions (SOURCES.md, "Battery").
//
// The levels (SourceSettings): 8 % Critical + Hibernate; 3 % Critical + Hibernate, sticky,
// breaks do-not-disturb; ONE key, each level replacing the one before; withdrawn when charging starts. Extras:
// "charged to 80 %" (the EC's charge limit, or 100) and a fast-drain warning when the discharge stays far above
// the usual for N minutes.
//
//   sortLevels(levels)                 highest first
//   scaleLevels(levels, target)        the levels on a pack that stops at `target`: 8 % of an 80 % pack is 6
//   share(percent, target)             the charge as a part of that pack, 0..100 (what a card's rail shows)
//   newState() / step(st, r, levels)   which level fires, whether the card goes: ONCE PER DISCHARGE
//   levelText(level, idx, n, pct, minLeft) / limitText(pct) / drainText(fastW, usualW)
//   newDrain(usualW, nowMs) / drainStep(st, s, p)   the fast drain: the draw far above the usual, for minutes
//
// A level is { pct, urgency, hibernate, timeoutMs?, breakDnd, title? }. A reading is { percent, status } with the
// kernel's own words for the status ("Discharging", "Charging", "Full", "Not charging", "" = no pack).
//
// STEPS NEVER GO BACKWARDS (CLAUDE.md, "Steps never go backwards; notch lists never flap"): the deepest level of
// a discharge is a high-water mark. A reading that flickers 15, 16, 15 posts once; the next discharge, after the
// pack has been out of "Discharging" and back, starts again from nothing.
//
// THE DRAIN'S "USUAL" IS EASED BY TIME (CLAUDE.md, "A smoothing window counted in samples is a different lag at
// every poll rate"): an exponential with a constant in minutes, applied with the REAL interval between readings,
// so the figure lags the same at 1 s polling and at 5 s. A draw that is anomalous is HELD OUT of it (the usual of
// a runaway process must not become the process), and a gap in the readings (a suspend, a stall) starts the
// stretch again instead of counting as time spent high.
// No Qt, no clock: every "now" is an argument.
// =============================================================================

function sortLevels(levels) {
    var l = Array.isArray(levels) ? levels.slice() : [];
    l.sort(function (a, b) { return b.pct - a.pct; });
    return l;
}

// THE CHARGE LIMIT: the 15 % line changes in proportion when the limit is engaged or not. With the
// limit on, the pack's whole range ends at the limit, so a line stands at the same share of it. Every other field stays; nothing goes under 1 %.
function scaleLevels(levels, target) {
    var t = target > 0 && target <= 100 ? target : 100;
    return levels.map(function (l) { return Object.assign({}, l, { pct: Math.max(1, Math.round(l.pct * t / 100)) }); });
}

function share(percent, target) {
    var t = target > 0 && target <= 100 ? target : 100;
    return Math.max(0, Math.min(100, Math.round(percent * 100 / t)));
}

function newState() {
    return { fired: -1 };
}

// `levels` sorted highest first. -> { post: the index of a NEW deeper level, or -1; withdraw: the card goes }
function step(st, r, levels) {
    var out = { post: -1, withdraw: false };
    if (!r || r.status === undefined || r.status === "")
        return out;
    if (r.status !== "Discharging") {
        if (st.fired >= 0) {
            out.withdraw = true;
            st.fired = -1;
        }
        return out;
    }
    var idx = -1;
    for (var i = 0; i < levels.length; i++)
        if (r.percent <= levels[i].pct)
            idx = i;
    if (idx > st.fired) {
        out.post = idx;
        st.fired = idx;
    }
    return out;
}

function _name(idx, n) {
    if (idx === 0)
        return "Battery low";
    return idx === n - 1 ? "Battery critical" : "Battery very low";
}

// "Battery low", "15 % . about 1 h 12 min left" -- the title is a state that stays true while the card is up
// (the rail shows the live figure), the body the reading it was posted at.
function levelText(level, idx, n, percent, minutesLeft) {
    var left = minutesLeft > 0 ? " · about " + F.duration(minutesLeft) + " left" : " left";
    return { title: level.title ? String(level.title) : _name(idx, n), body: Math.round(percent) + " %" + left };
}

function limitText(percent) {
    var p = Math.round(percent);
    return { title: "Charged to " + p + " %", body: p < 100 ? "Held at the charge limit" : "" };
}

// ---------------------------------------------------------------- the fast drain

var FAST_TAU_MS = 60000;     // "now" is the last minute's draw, not one noisy reading
var GAP_MS = 180000;         // readings further apart than this are not one stretch
var CALM = 1.25;             // back under this many times the usual ends it

// `usualW` > 0: the draw this machine is known to have (kept across restarts); `nowMs` is then a
// warmed-up state. 0: nothing learnt yet.
function newDrain(usualW, nowMs, warmupMin) {
    var known = usualW > 0;
    return { usualW: known ? usualW : 0, fastW: 0, lastMs: 0,
             firstMs: known ? nowMs - warmupMin * 60000 : 0, highSince: 0, fired: false };
}

// s = { nowMs, watts, discharging }, p = { factor, minW, minutes, tauMin, warmupMin }
// -> { fire: bool, clear: bool }
function drainStep(st, s, p) {
    var out = { fire: false, clear: false };
    if (!s.discharging || !(s.watts > 0)) {
        out.clear = st.fired;
        st.lastMs = 0;
        st.highSince = 0;
        st.fastW = 0;
        st.fired = false;
        return out;
    }
    var dt = st.lastMs > 0 ? s.nowMs - st.lastMs : 0;
    st.lastMs = s.nowMs;
    if (dt > GAP_MS) {
        st.highSince = 0;
        st.fastW = 0;
        dt = 0;
    }
    if (st.firstMs === 0)
        st.firstMs = s.nowMs;
    if (st.fastW <= 0 || dt === 0)
        st.fastW = s.watts;
    else
        st.fastW += (1 - Math.exp(-dt / FAST_TAU_MS)) * (s.watts - st.fastW);
    var high = st.usualW > 0 && st.fastW >= p.minW && st.fastW > p.factor * st.usualW;
    if (!high) {
        if (st.usualW <= 0)
            st.usualW = s.watts;
        else
            st.usualW += (1 - Math.exp(-dt / (p.tauMin * 60000))) * (s.watts - st.usualW);
        st.highSince = 0;
        if (st.fired && st.fastW < CALM * st.usualW) {
            st.fired = false;
            out.clear = true;
        }
        return out;
    }
    if (st.highSince === 0)
        st.highSince = s.nowMs;
    if (!st.fired && s.nowMs - st.highSince >= p.minutes * 60000 && s.nowMs - st.firstMs >= p.warmupMin * 60000) {
        st.fired = true;
        out.fire = true;
    }
    return out;
}

// "31 W, about 3 times the usual 10 W" -- the ratio to the nearest half.
function drainText(fastW, usualW) {
    var ratio = usualW > 0 ? Math.round(fastW / usualW * 2) / 2 : 0;
    return Math.round(fastW) + " W" + (ratio > 0 ? ", about " + ratio + " times the usual " + Math.round(usualW) + " W" : "");
}
