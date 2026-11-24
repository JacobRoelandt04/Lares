.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// ThermalThrottle.js -- the CPU held back by HEAT for a long while, as pure decisions (SOURCES.md, "Later sources").
//
// The question is "is a heavy load keeping the CPU too hot to run at full speed?", so the reading is TIME, not events. The
// kernel counts every thermal throttle event of every logical CPU in
// /sys/devices/system/cpu/cpu*/thermal_throttle/{core,package}_throttle_count -- and that is the wrong number: each logical
// CPU keeps its OWN view of the package's counter (this machine's 22 read 1239 ... 6702), so one package event is counted
// ~22 times and a core event twice (one per hyperthread), and a blip at low load raises the count by hundreds while nothing
// is slow. Beside each count the kernel keeps `{core,package}_throttle_total_time_ms`, the milliseconds it was throttled; on
// this machine every one of them reads 0 while the counts stand in the thousands, so the events that
// raise the count are not time spent slow. That is what this card reads.
//
//   parse(text)                        `grep -H "" <files>` -> { "cpu0/thermal_throttle/package_throttle_total_time_ms": 0, ... }
//   newState() / step(st, times, nowMs, cfg)   -> { fire, clear, fraction, share, runSec }
//   text(share, runSec)                { title, body }
//
// PER POLL the throttled time is the MAX advance over the files (never their sum: they are views of the same events, so
// summing 22 of them reads a 25 ms event as half a second); the share of the poll it covers is `fraction`. HOT is a fraction
// of at least `minFraction`; the card is for heat that SUSTAINS -- hot in EVERY poll for `sustainSec` seconds, one cool poll
// starts the count again. At most one card per `cooldownMin`, and it goes after `quietMin` minutes that were not hot.
//
// FILE BY FILE, never merged: a CPU that is taken offline (a suspend does it) takes its files away, and when it comes back
// its counters -- thousands of ms -- would be an enormous "advance". A file that was not in the last reading is a baseline
// of its own; one that went down (a reset) is no time; the first reading is a baseline of everything.
//
// NOT THIS CARD'S: power-limit throttling (an artificial ceiling -- the power profile, PL1/PL2, a charger or battery cap).
// No power-limit counter is read, only the thermal ones, so a CPU held at a profile's ceiling says nothing here. (The kernel
// adds a throttle's duration when that throttle ENDS -- as its source reads, unverified here, where no throttle has lasted;
// a load that sits AT the limit toggles it, which is time as it happens, while one throttle that never lets go would reach
// the counter only when it does.) No Qt, no clock.
// =============================================================================

function parse(text) {
    var out = {};
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^(.+):(\d+)\s*$/.exec(lines[i].trim());
        if (m)
            out[m[1]] = Number(m[2]);
    }
    return out;
}

function newState() {
    return { last: null, lastAt: 0, runSince: null, runMs: 0, hotAt: null, postedAt: null, active: false };
}

// The most any ONE file advanced since the last reading, in ms: the longest view of the throttled time.
function _worst(prev, times) {
    var worst = 0;
    for (var path in times) {
        if (!Object.prototype.hasOwnProperty.call(times, path) || !Object.prototype.hasOwnProperty.call(prev, path))
            continue;
        var gain = times[path] - prev[path];
        if (gain > worst)
            worst = gain;
    }
    return worst;
}

// cfg = { minFraction, sustainSec, cooldownMin, quietMin }
// -> { fire, clear, fraction: this poll's share, share: the run's mean share, runSec: how long it has been hot }
function step(st, times, nowMs, cfg) {
    var out = { fire: false, clear: false, fraction: 0, share: 0, runSec: 0 };
    var prev = st.last;
    var prevAt = st.lastAt;
    st.last = times;
    st.lastAt = nowMs;
    if (prev === null)
        return out;
    var span = nowMs - prevAt;
    if (!(span > 0)) {
        // the clock stood still or went back: nothing to judge, and no run to trust
        st.runSince = null;
        return out;
    }
    var worst = Math.min(_worst(prev, times), span);
    out.fraction = worst / span;
    if (out.fraction >= cfg.minFraction) {
        if (st.runSince === null) {
            // the run begins where this poll's interval began
            st.runSince = prevAt;
            st.runMs = 0;
        }
        st.runMs += worst;
        st.hotAt = nowMs;
    } else {
        st.runSince = null;
        st.runMs = 0;
    }
    var held = st.runSince === null ? 0 : nowMs - st.runSince;
    out.runSec = Math.round(held / 1000);
    out.share = held > 0 ? Math.min(1, st.runMs / held) : 0;
    if (held >= cfg.sustainSec * 1000 && (st.postedAt === null || nowMs - st.postedAt >= cfg.cooldownMin * 60000)) {
        st.postedAt = nowMs;
        st.active = true;
        out.fire = true;
    }
    if (st.active && !out.fire && st.hotAt !== null && nowMs - st.hotAt >= cfg.quietMin * 60000) {
        st.active = false;
        out.clear = true;
    }
    return out;
}

// "75 s", "2 min", "1 h 5 min"
function _span(sec) {
    return sec < 120 ? sec + " s" : F.duration(sec / 60);
}

// share 0..1 (said in steps of 5 %: it is an average of the run), runSec the seconds it has been hot
function text(share, runSec) {
    return { title: "The CPU is too hot to run at full speed",
             body: "Slowed down by heat for " + Math.round(Math.max(0, Math.min(1, share)) * 20) * 5 + " % of the last " + _span(runSec) };
}
