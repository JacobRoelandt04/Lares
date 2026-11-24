.pragma library

// =============================================================================
// PowerMath.js -- the battery's maths (derived from modules/common/system/BatteryData.qml, which stays untouched) as
// pure functions silicon's service and its cases share.
// No Qt, no clock of its own: the caller says what time it is.
//
//   parseUevent(text)                 power_supply uevent -> a sample
//   newState()                        the smoothing's memory (a plain object the caller holds)
//   step(state, sample, nowMs, opts)  feed one sample; -> { events: [...], acChanged }
//   figures(state, sample, opts)      time left / to full, signed watts, condition
//   normalised(signedW, overheadW)    the flow without this popup's own draw
//   targetPct(opts) / atTarget(s, opts)   the charge the pack stops at, and whether it is AT it (full, or held at the limit)
//   scaledPct(pct, opts) / lowLine(opts)  a line of a whole pack on a pack that stops at its limit: 15 % of an 80 % pack is 12
//
// WHAT IT DOES.
//   * The time estimate divides by an AVERAGE of the flow, and the average is TIME-BASED: an exponential one,
//     `smoothTauS` seconds long, whatever the cadence the samples arrive at (1 s with the popup alive, 2 s calm, 5 s
//     halted or closed -- `SiliconService._cad`). An average of the last 30 SAMPLES would be 30 s at one cadence
//     and 150 s at another: after a load change the figure would trail what btop shows (`energy_now / power_now`, no
//     smoothing at all) by up to two and a half minutes, and the longer the popup had been shut the worse. Each sample
//     moves the average by `1 - exp(-dt / tau)` of its distance to it, `dt` being the time since the average last
//     moved, so a stretch with no sample (a suspend) counts as the sample that ends it, and the stretch of a spike
//     held out counts from where the spike began (the time before it was not the spike's).
//   * A SUSTAINED spike is left out: a sample more than `spikeThresholdW` (8) above the average is held out until the
//     rise has lasted `spikeMinDurationMs` (6 s). Opening the popup is itself a spike (the particles cost power) and an
//     estimate that drops the moment you look at it is an estimate of the popup, not of the battery. Only a short rise
//     is the popup's; one that outlasts the hold is the load, and from then on the average is the plain exponential's.
//   * Time left = energy now / smoothed W; to full = the energy still missing / smoothed W.
//     "to full" runs to the CHARGE LIMIT while one is set (80 % of the pack's full energy),
//     because the pack stops there and "full" would never come.
//   * The average starts afresh when the flow changes regime (charging, discharging,
//     neither): a window of charging samples kept after an unplug would call any
//     rise on a replug a spike for 20 s; a different regime is a different average.
//   * Events (`step`, one place):
//       chargeStart   the status became Charging
//       chargeStop    the status left Charging and the pack is NOT at its target: charging was cut short (an unplug)
//       chargeDone    the status left Charging and the pack IS at its target: charging COMPLETED (the bar's success, never its red)
//       full          the pack ARRIVED at its target: `atTarget` false -> true after a charge, whatever flowed at the crossing
//                     (asking for the percentage to cross with under 0.5 W flowing would never fire for a pack that still
//                     draws power at the crossing). ONCE per charge: `state.charge` is "" -> "running" (a reading
//                     that charges) -> "told"; a plug-in at the target charged nothing and says nothing, the limit's
//                     Full <-> Not charging flap is no edge, and a top-up the EC gives a sagging pack (79, 80) stays told
//                     until the pack has really left: on battery, or two points under the target (lifting the limit is that too).
//       low           the percentage crossed DOWN through the low line, which is `lowChargeThreshold` OF THE TARGET: with the
//                     limit on, the pack's empty-to-full runs to 80, so 15 % of it is 12 (the bar's track is scaled the same way).
//   * acChanged, from the mains flag (the first reading says nothing).
//   * STALLED (`state.stalled`, `figures.stalled`): the kernel says Charging and nothing flows -- under `stallW` (0.5) for `stallMs` (30 s) running --
//     on a pack more than two points short of its target. `acpi` words it "charging at zero rate - will never fully charge". Seen on
//     2026-11-04: a pack drained to 0 % on a charger that could not feed the machine as well; the EC kept saying Charging for nine minutes
//     while the percentage FELL (the input went to the load). The status alone is not the fact, so the caption and the notifier ask this.
//     A flow that comes back, or any other status, clears it at once.
// =============================================================================

var DEFAULTS = {
    smoothTauS: 15,           // the average's time constant, seconds: the lag a 30-sample mean has at 1 Hz, at every cadence
    spikeThresholdW: 8,
    spikeMinDurationMs: 6000,
    lowChargeThreshold: 15,   // of the target (`lowLine`)
    stallW: 0.5,              // "Charging" with less than this flowing is not charging ...
    stallMs: 30000,           // ... once it has lasted this long (a plug-in's first second and a taper's dip are not a stall)
    limitPct: 100             // the charge limit in force (100 = none)
};

function _opts(o) {
    var out = {};
    var k;
    for (k in DEFAULTS)
        out[k] = DEFAULTS[k];
    if (o) {
        for (k in o) {
            if (o[k] !== undefined && o[k] !== null)
                out[k] = o[k];
        }
    }
    return out;
}

function _int(kv, key) {
    var n = parseInt(kv[key] || "", 10);
    return isNaN(n) ? null : n;
}

// power_supply's uevent is KEY=VALUE lines; energy is in uWh, power in uW, voltage in uV.
// -> null when there is nothing to read (an empty text, no battery).
function parseUevent(text) {
    var kv = {};
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var at = lines[i].indexOf("=");
        if (at > 0)
            kv[lines[i].substring(0, at)] = lines[i].substring(at + 1).trim();
    }
    if (kv.POWER_SUPPLY_CAPACITY === undefined && kv.POWER_SUPPLY_STATUS === undefined)
        return null;
    var uWh = function (key) { var n = _int(kv, key); return n === null ? 0 : n / 1e6; };
    var pct = _int(kv, "POWER_SUPPLY_CAPACITY");
    return {
        present: kv.POWER_SUPPLY_PRESENT === undefined || kv.POWER_SUPPLY_PRESENT === "1",
        status: kv.POWER_SUPPLY_STATUS || "",
        pct: pct === null ? 0 : pct,
        cycles: _int(kv, "POWER_SUPPLY_CYCLE_COUNT") || 0,
        energyNowWh: uWh("POWER_SUPPLY_ENERGY_NOW"),
        energyFullWh: uWh("POWER_SUPPLY_ENERGY_FULL"),
        energyFullDesignWh: uWh("POWER_SUPPLY_ENERGY_FULL_DESIGN"),
        powerNowW: uWh("POWER_SUPPLY_POWER_NOW"),
        voltageNowV: uWh("POWER_SUPPLY_VOLTAGE_NOW")
    };
}

function newState() {
    return {
        smoothedW: 0,
        primed: false,            // the average exists (a new regime starts without one)
        updatedMs: 0,             // when it last moved
        inSpike: false,
        spikeStartMs: 0,
        kind: "",
        lastPct: -1,
        lastStatus: "",
        lastAc: null,
        lastAt: false,            // the last reading was at the target
        stallSinceMs: 0,          // when "Charging with nothing flowing" began (0: it is not)
        stalled: false,           // ... and has lasted `stallMs`
        charge: ""                // "" | "running" | "told": see `step`
    };
}

// The charge the pack stops at: the limit while one is set, else 100.
function targetPct(opts) {
    var o = _opts(opts);
    return o.limitPct > 0 && o.limitPct < 100 ? o.limitPct : 100;
}

// The pack is AT ITS TARGET now: full, or held at the charge limit (the kernel says "Full" at 100 and "Not charging" with
// the percentage at the limit). A pack still drawing power to get there is not -- the same rule as the `full` event, which
// fires when the percentage crosses into the target with next to no power flowing.
function atTarget(s, opts) {
    if (!s)
        return false;
    return s.status === "Full" || (s.status === "Not charging" && s.pct >= targetPct(opts));
}

// A line drawn on a whole pack, on the pack the limit leaves: the same share of the target. Never under 1: a line of 0 % is no line.
function scaledPct(pct, opts) {
    return Math.max(1, Math.round(pct * targetPct(opts) / 100));
}

// The charge the pack counts as low at.
function lowLine(opts) {
    return scaledPct(_opts(opts).lowChargeThreshold, opts);
}

// The flow's regime: what the status says is happening to the pack.
function kindOf(status) {
    if (status === "Charging")
        return "charging";
    if (status === "Discharging")
        return "discharging";
    return "idle";
}

// One watt sample into the average (the clock is handed in and the window is a time
// constant). A sample held out as a spike changes nothing: the average has not moved, so the next sample that is let in
// carries the whole stretch since the spike began (its `dt`), which is what makes the lag the same at every cadence:
// from then on the average is the exponential's, as if the rise had never been held out.
function pushSample(state, w, nowMs, o) {
    var baseline = state.primed ? state.smoothedW : w;
    if (w - baseline > o.spikeThresholdW) {
        if (!state.inSpike) {
            state.inSpike = true;
            state.spikeStartMs = nowMs;
        }
        if (nowMs - state.spikeStartMs < o.spikeMinDurationMs)
            return false;
    } else {
        state.inSpike = false;
    }
    if (!state.primed) {
        state.smoothedW = w;
        state.primed = true;
    } else {
        var dtS = Math.max(0, nowMs - Math.max(state.updatedMs, state.spikeStartMs)) / 1000;
        state.smoothedW += (1 - Math.exp(-dtS / o.smoothTauS)) * (w - state.smoothedW);
    }
    state.updatedMs = nowMs;
    return true;
}

// Feed one sample ({status, pct, ac, powerNowW}); `ac` is the mains flag or null when unread.
// -> { events: ["chargeStart"|"chargeStop"|"full"|"low", ...], acChanged: true|false|null }
// acChanged is the new value of the flag when it CHANGED, null otherwise.
function step(state, s, nowMs, opts) {
    var o = _opts(opts);
    var events = [];
    var acChanged = null;
    var kind = kindOf(s.status);
    if (state.kind !== "" && kind !== state.kind) {
        state.primed = false;
        state.smoothedW = 0;
        state.inSpike = false;
    }
    state.kind = kind;
    pushSample(state, Math.abs(s.powerNowW), nowMs, o);

    var target = targetPct(o);
    var at = atTarget(s, o);
    if (state.lastStatus !== "" && state.lastStatus !== s.status) {
        if (s.status === "Charging")
            events.push("chargeStart");
        else if (state.lastStatus === "Charging")
            events.push(at ? "chargeDone" : "chargeStop");
    }
    state.lastStatus = s.status;

    // what the charge has told so far: one arrival, one `full`
    if (s.status === "Discharging" || (state.charge === "told" && s.pct < target - 1))
        state.charge = "";
    if (s.status === "Charging" && state.charge === "")
        state.charge = "running";
    if (at && !state.lastAt && state.charge === "running") {
        events.push("full");
        state.charge = "told";
    }
    state.lastAt = at;

    // Charging with nothing flowing, running: the clock is the caller's, like every other here
    if (s.status === "Charging" && Math.abs(s.powerNowW) < o.stallW && s.pct < target - 2) {
        if (state.stallSinceMs === 0)
            state.stallSinceMs = nowMs;
        state.stalled = nowMs - state.stallSinceMs >= o.stallMs;
    } else {
        state.stallSinceMs = 0;
        state.stalled = false;
    }

    var low = lowLine(o);
    if (state.lastPct >= 0 && state.lastPct > low && s.pct <= low)
        events.push("low");
    state.lastPct = s.pct;

    if (typeof s.ac === "boolean") {
        if (state.lastAc !== null && state.lastAc !== s.ac)
            acChanged = s.ac;
        state.lastAc = s.ac;
    }
    return { events: events, acChanged: acChanged };
}

// Minutes (a real number) or null. The estimate needs a flow to divide by.
function minutesLeft(state, s) {
    if (s.status !== "Discharging" || !(state.smoothedW > 0.1) || !(s.energyNowWh > 0))
        return null;
    return s.energyNowWh * 60 / state.smoothedW;
}

// Minutes to full, or to the limit while one is set. null when nothing is charging, when there
// is nothing to divide by, or when the pack is already at or past its target.
function minutesToFull(state, s, opts) {
    var o = _opts(opts);
    if (s.status !== "Charging" || !(state.smoothedW > 0.1) || !(s.energyFullWh > 0))
        return null;
    var limited = o.limitPct > 0 && o.limitPct < 100;
    var target = limited ? s.energyFullWh * o.limitPct / 100 : s.energyFullWh;
    var missing = target - s.energyNowWh;
    return missing > 0 ? missing * 60 / state.smoothedW : null;
}

// The pack's flow signed (charging +, discharging -, anything else 0).
function signedW(s) {
    if (s.status === "Charging")
        return s.powerNowW;
    if (s.status === "Discharging")
        return -s.powerNowW;
    return 0;
}

// What the flow would be without this popup's own draw: the popup spends `overheadW` that the
// pack either supplies (discharging: less is drawn without it) or does not get to store
// (charging: more would go in). Never past zero, so it cannot invent a flow the other way, and
// nothing at all while nothing flows.
function normalised(signed, overheadW) {
    var o = overheadW > 0 ? overheadW : 0;
    if (signed < 0)
        return Math.min(0, signed + o);
    if (signed > 0)
        return signed + o;
    return 0;
}

function figures(state, s, opts) {
    var o = _opts(opts);
    var signed = signedW(s);
    var avg = s.status === "Charging" ? state.smoothedW : (s.status === "Discharging" ? -state.smoothedW : 0);
    var limited = o.limitPct > 0 && o.limitPct < 100;
    return {
        signedW: signed,
        avgSignedW: avg,
        minutesLeft: minutesLeft(state, s),
        minutesToFull: minutesToFull(state, s, o),
        toLimit: limited && s.status === "Charging",
        stalled: state.stalled === true && s.status === "Charging",
        atTarget: atTarget(s, o),
        conditionPct: s.energyFullDesignWh > 0 ? Math.round(s.energyFullWh / s.energyFullDesignWh * 1000) / 10 : 100
    };
}
