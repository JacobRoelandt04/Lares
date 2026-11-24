.pragma library

// =============================================================================
// MockTimeline.js -- the machine silicon's mock pretends to be, as PURE FUNCTIONS OF TIME: what a
// sensor would read at `t` ms into a scenario, so the mockup can scrub it, loop it and film it.
// No Qt, no clock. SiliconMock (the same members as SiliconService, over the same view model) turns
// a sample into the input record the view model builds its facts from.
//
//   SCENARIOS                       the names, in the order the mockup's panel lists them
//   durationMs(name)                one loop
//   sample(name, t)                 { cores [16 loads], loadPct, clockMHz, tempC, igpuBusy, dState,
//                                     holders [], smi {..}|null,
//                                     memory { totalKiB, availableKiB, usedFraction },
//                                     battery { status, pct, powerW, energyNowWh, ac } }
//   blocksBetween(name, t0, t1)     the Smart-mode apps that got blocked in (t0, t1]
//   defaultStatus()                 the helper's status for this laptop (HelperProto's normalised shape)
//
// SCENARIOS
//   desk     on the mains, full, idle: a little load, the dGPU asleep, a third of the RAM
//   compile  on the mains, every core busy, the package heating up, the RAM filling
//   game     on battery, the dGPU wakes (D0) for a game: holders, the card's own readouts, a heavy draw
//   unplug   the charger comes out at 5 s and the pack drains (through the 15 % low mark at ~45 s)
//   charge   the charger goes in at 5 s and the pack fills (the charge target at ~55 s)
// The battery runs a time-lapse (a whole discharge in under a minute) so every event can be watched.
// =============================================================================

var SCENARIOS = ["desk", "compile", "game", "unplug", "charge"];
var LOOP_MS = 60000;
var FULL_WH = 59.455;
// This laptop: 24 GB of RAM (MemTotal as the kernel counts it).
var MEM_TOTAL_KIB = 24007296;

function durationMs(name) {
    return LOOP_MS;
}

function _wave(t, period, phase) {
    return 0.5 + 0.5 * Math.sin(2 * Math.PI * t / period + phase);
}

function _clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// 16 cores: 6 P, 8 E, 2 LPE. `lo`..`hi` is the band each one wanders in; P cores lead.
function _cores(t, lo, hi, pBias) {
    var out = [];
    for (var i = 0; i < 16; i++) {
        var bias = i < 6 ? pBias : (i < 14 ? 0 : -pBias);
        var w = _wave(t, 1700 + 230 * i, i * 0.9);
        out.push({ kind: i < 6 ? "P" : (i < 14 ? "E" : "LPE"), load: _clamp(lo + (hi - lo) * w + bias, 0, 1) });
    }
    return out;
}

function _battery(name, t) {
    var cap = FULL_WH;
    if (name === "unplug") {
        if (t < 5000)
            return { status: "Full", pct: 62, powerW: 0, energyNowWh: cap * 0.62, ac: true };
        var p = 62 - 47 * (t - 5000) / 40000;
        p = Math.max(5, p);
        return { status: "Discharging", pct: Math.round(p), powerW: 14 + 1.5 * Math.sin(t / 700), energyNowWh: cap * p / 100, ac: false };
    }
    if (name === "charge") {
        if (t < 5000)
            return { status: "Discharging", pct: 20, powerW: 13 + Math.sin(t / 900), energyNowWh: cap * 0.2, ac: false };
        var q = Math.min(100, 20 + 80 * (t - 5000) / 50000);
        if (q >= 100)
            return { status: "Full", pct: 100, powerW: 0, energyNowWh: cap, ac: true };
        // constant current, then a taper over the last fifth
        var w = q < 80 ? 50 : 50 * (100 - q) / 20 + 2;
        return { status: "Charging", pct: Math.round(q), powerW: w, energyNowWh: cap * q / 100, ac: true };
    }
    if (name === "game")
        return { status: "Discharging", pct: 71, powerW: 52 + 6 * Math.sin(t / 1100), energyNowWh: cap * 0.71, ac: false };
    return { status: "Full", pct: 100, powerW: 0, energyNowWh: cap, ac: true };
}

// RAM per scenario: what a desk, a long compile and a game do to it.
function _memory(name, t) {
    var used = 0.32 + 0.03 * _wave(t, 9000, 0);
    if (name === "compile") {
        var ramp = _clamp(t / 30000, 0, 1);
        used = 0.55 + 0.33 * ramp + 0.01 * _wave(t, 2100, 0);
    } else if (name === "game") {
        used = 0.58 + 0.2 * _clamp((t - 3000) / 25000, 0, 1) + 0.005 * _wave(t, 3300, 0);
    } else if (name === "unplug" || name === "charge") {
        used = 0.36 + 0.02 * _wave(t, 7000, 1);
    }
    var avail = Math.round(MEM_TOTAL_KIB * (1 - used));
    return {
        totalKiB: MEM_TOTAL_KIB, availableKiB: avail, usedFraction: (MEM_TOTAL_KIB - avail) / MEM_TOTAL_KIB
    };
}

function sample(name, t) {
    t = t % LOOP_MS;
    if (t < 0)
        t += LOOP_MS;
    var s = {
        cores: [], loadPct: 0, clockMHz: 800, tempC: 44, igpuBusy: 0.08,
        dState: "D3cold", holders: [], smi: null, memory: _memory(name, t), battery: _battery(name, t)
    };
    var lo = 0.02, hi = 0.09, pb = 0.0, clock = 900, temp = 44;
    if (name === "compile") {
        lo = 0.62; hi = 0.97; pb = 0.03;
        clock = 3200 + 1400 * _wave(t, 2300, 0);
        temp = 58 + 34 * _clamp(t / 30000, 0, 1) + 2 * Math.sin(t / 500);
    } else if (name === "game") {
        lo = 0.25; hi = 0.6; pb = 0.1;
        clock = 2400 + 900 * _wave(t, 1900, 1);
        temp = 66 + 8 * _wave(t, 9000, 0);
    } else if (name === "unplug" || name === "charge") {
        lo = 0.03; hi = 0.16; clock = 1000 + 600 * _wave(t, 2600, 0); temp = 46 + 4 * _wave(t, 8000, 0);
    } else {
        clock = 800 + 500 * _wave(t, 3100, 0);
        temp = 43 + 4 * _wave(t, 11000, 0);
    }
    s.cores = _cores(t, lo, hi, pb);
    var sum = 0;
    for (var i = 0; i < s.cores.length; i++)
        sum += s.cores[i].load;
    s.loadPct = Math.round(sum / s.cores.length * 1000) / 10;
    s.clockMHz = Math.round(clock);
    s.tempC = Math.round(temp * 10) / 10;
    s.igpuBusy = name === "game" ? 0.22 : _clamp(0.05 + 0.1 * _wave(t, 2100, 2), 0, 1);
    if (name === "game" && t >= 3000) {
        s.dState = "D0";
        s.holders = t >= 4000 ? ["steam", "proton"] : ["steam"];
        s.smi = {
            util: Math.round(70 + 25 * _wave(t, 1500, 0)), tempC: Math.round(58 + 14 * _clamp((t - 3000) / 20000, 0, 1)),
            watts: Math.round((45 + 25 * _wave(t, 1500, 0.5)) * 10) / 10,
            vramUsedMB: Math.round(3000 + 3000 * _clamp((t - 3000) / 25000, 0, 1)), vramTotalMB: 8188
        };
    } else if (name === "desk" && t >= 40000 && t < 46000) {
        s.dState = "D0";        // something woke it, nobody uses it
    }
    return s;
}

// Smart-mode blocks that happen in a scenario: [{ atMs, id, comm, pid }].
var BLOCKS = {
    game: [{ atMs: 3200, id: "steam_app_1295660", comm: "cs2", pid: 4301 }],
    compile: [{ atMs: 9000, id: "org.blender.Blender", comm: "blender", pid: 5120 }]
};

function blocksBetween(name, t0, t1) {
    var list = BLOCKS[name] || [];
    var a = t0 % LOOP_MS, b = t1 % LOOP_MS;
    return list.filter(function (e) {
        return a <= b ? (e.atMs > a && e.atMs <= b) : (e.atMs > a || e.atMs <= b);
    });
}

// The helper's status for this laptop (the stand-in's answer over the fixture), normalised.
function defaultStatus() {
    return {
        features: { profile: true, epp: true, turbo: true, governor: true, maxPerfPct: true, caps: true, chargeLimit: true, mux: true },
        values: {
            profile: "balanced", epp: "balance_power", turbo: true, governor: "powersave", maxPerfPct: 100,
            caps: { pl1W: 45, pl2W: 115, zones: { msr: { pl1W: 45, pl2W: 115 }, mmio: { pl1W: 45, pl2W: 115 } } },
            chargeLimit: 100, muxStored: "hybrid"
        },
        lists: {
            profiles: ["quiet", "balanced", "performance"],
            epps: ["performance", "balance_performance", "balance_power", "power"],
            governors: ["performance", "powersave"]
        },
        limits: { capFloorW: 8, capCeilW: { pl1: 45, pl2: 115 }, maxPerfPct: { min: 50, max: 100 }, eppLocked: false },
        paths: {},
        prechecks: { mux: { ok: true, why: "" } },
        mux: { stored: "hybrid", wiringNow: "hybrid", record: null },
        boot: { id: "mock", applied: true }
    };
}
