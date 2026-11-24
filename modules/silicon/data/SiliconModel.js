.pragma library
.import "SiliconFormat.js" as Fmt
.import "PowerMath.js" as Pm
.import "CardwireParse.js" as CardwireParse
.import "HelperProto.js" as Proto

// =============================================================================
// SiliconModel.js -- silicon's pure half: the shapes of the facts, the config's seeds and its
// validation, the cardwire-mode -> step mapping of CONTRACT section 6, tweak detection, the
// words of the captions. No Qt: SiliconViewModel.qml wraps it.
//
//   normalizeConfig(obj)               -> { config, warnings }   (every key optional, seeds as defaults)
//   stepOf(cwMode, wiring)             cardwire Mode + the MUX wiring -> the scene's STEP order
//   cwOfStep(step)                     the other way (null for dGPU-only: that is the MUX)
//   availableSteps(modes, wiring, mux) which steps the zone offers (dGPU-only wiring offers all four)
//   stepFrom(step, dir, steps)         the next step in a direction, or null
//   nextProfile(target, dir, profiles) / planGpuMode(step, opts, g, target)   what an arrow / a click does
//   heldAboveLimit(battery) / heldNote(battery)   the pack held above its limit on the mains (the limit does not drain), and its words
//   linkedPatch(config, name, status)  what a profile applies (its linked values)
//   tweaked(name, config, status)      do the live values differ from the profile's own
//   bootPlan(config, status, stored) / bootDecide(plan, text, last, pending)   the boot profile (`defaultProfile`): what to store, and
//                                      whether to ask now (the service and the mock both follow them)
//   buildFacts(inputs)                 -> { cpu, cores, igpu, gpu, memory, battery, helper }
//   buildCaption(facts, ctx)           -> { cpu, gpu, battery, cpuError, gpuError, batteryError }
//   cadence(level, open, idle[, guardMs]) -> { baseMs, stats, battery, status, overhead, guard }: the reading beat and each reader's count
//                                         (`idle` is the IdleLadder, whose statsHaltedMs / batteryHaltedMs it reads)
//   buildFigures(battery, memory, now) -> the board's display strings; buildMemory(memory) -> what its RAM draws
//   sinceFull(battery, now)            -> { text, nextMs }: the since-full display, 0 while the pack is at its target
//   osdProfile / osdGpu / osdLimit     the OSD requests (kind "power") for a change made outside the popup
//   osdAfterMuxRefused(step, why)      ... and for the mode asked for after a restart that could not be set
//   muxRemainingMs(mux, nowMs, uptimeMs)   the keep prompt's countdown by HELPER_PROTOCOL.md's rule
//   afterMuxPlan(after, gpu, busy)     what to do with the mode asked for after a way back from dGPU-only
//
// FACTS of the card in the bar: `gpu.inUse`: the card is working (awake with a real user, wired as the display, or driving the external
// display on its HDMI connector).
//
// FACTS of the MUX prompt and the Smart apps (CONTRACT section 11): `gpu.ignoredApps` (the ids of the Smart apps the
// user chose "never ask again" for, persisted) and `ignored` on every `gpu.policies[]` row; on `gpu.mux` the
// record's own clock -- `deadlineBootId`, `deadlineUptimeMs` (the boot guard's deadline, in time since boot) and
// `bootId` (this boot) -- which `muxRemainingMs` turns into the keep prompt's countdown -- and the helper's two windows,
// `bootWindowS` and `promptWindowS` (the constants above: the words of the prompt, not a setting).
//
// FACTS of the way back and the memory: `gpu.mux.afterMode` (the step wanted once the way back from dGPU-only has been
// restarted: 0 Integrated, 1 Smart, 2 Hybrid, or null -- a way back is ONE MUX request for Hybrid, and the mode after it
// rides with it, persisted by SiliconState) and `memory { totalKiB, availableKiB, usedFraction }`
// (null while unknown), read from /proc/meminfo at the stats cadence.
//
// FACTS of the pack's last full: on `battery`, `atTarget` (the pack is full, or held at the charge limit, right
// now: the since-full display then reads 0), and `lastFullMs` is the LATER of the service's own record and UPower's
// charge history (`lastFullSource` says which: "upower" | "own" | "", `upowerWhy` is why UPower's history is not
// there when it is not: "" otherwise).
//
// FACT of the display: `display.hdmi` -- an external display is connected to the NVIDIA card's HDMI-A connector,
// and ONLY that one (a DisplayLink dock and the iGPU's DP outputs never count; DrmRules.nvidiaHdmi has the rule). The input is
// `display { hdmi }` (DrmWatch's, or SiliconMock's knob); absent, it reads false.
//
// FACTS carry NO colours (CONTRACT section 2); the three targets are the scene's order, not the
// kernel's and not cardwire's:
//   profile      0 Quiet, 1 Balanced, 2 Performance
//   gpu step     0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only   (CONTRACT section 6)
//   cardwire     0 Integrated, 1 Hybrid, 2 Manual, 3 Smart
// =============================================================================

// The members SiliconService and SiliconMock BOTH have (CONTRACT section 2, plus what the popup needs
// beyond it): each source must declare every one, so the mock cannot
// drift from the service it stands in for.
var MEMBERS = {
    props: ["cpu", "cores", "igpu", "gpu", "memory", "display", "battery", "helper", "caption", "tuningTarget",
            "profileTarget", "gpuModeTarget", "chargeLimitTarget", "profileIndex", "gpuMode",
            "config", "configWarnings", "configError", "popupOpen", "idleState",
            "readingSerial", "readingMs", "readingAtMs", "bootProfile"],
    signals: ["batteryEvent", "acChanged", "gpuPowerChanged", "writeRefused", "appBlocked", "osd"],
    intents: ["stepProfile", "setProfile", "setTuning", "resetTuning", "setChargeLimit", "stepGpuMode",
              "setGpuMode", "setCardwireConfig", "setAppPolicy", "ignoreApp", "muxRequest", "muxRebootNow",
              "muxKeep", "muxCancel", "muxPromptShown", "markMuxOutcomeSeen", "touch", "refresh"]
};

var PROFILES = ["quiet", "balanced", "performance"];
// Energy preference from the thriftiest to the keenest. `default` is an alias of
// balance_performance on this CPU and is never offered.
var EPP_ORDER = ["power", "balance_power", "balance_performance", "performance"];
var GOVERNORS = ["powersave", "performance", "schedutil", "ondemand", "conservative", "userspace"];
var STEP = { INTEGRATED: 0, SMART: 1, HYBRID: 2, DGPU: 3 };
var CW = { INTEGRATED: 0, HYBRID: 1, MANUAL: 2, SMART: 3 };

// The MUX's two windows are the ROOT HELPER's, fixed in it (helpers/silicon_helper/src/mux.rs: BOOT_WINDOW_MS and
// PROMPT_WINDOW_MS) -- a root helper reads nothing of the user's, so no config file can change them. The shell only
// mirrors them: to word its keep prompt, and to simulate a guard (SiliconMock). They are facts (`gpu.mux.bootWindowS`,
// `gpu.mux.promptWindowS`) and must equal mux.rs's two constants.
var MUX_BOOT_WINDOW_S = 300;      // a new wiring waits this long after the boot for a click on Keep
var MUX_PROMPT_WINDOW_S = 120;    // ... and, once the keep prompt is on screen, this long from that moment

// --- the config (silicon.jsonc) ---------------------------------------------------------------

// What each profile applies. Quiet = power + turbo off; Balanced = balance_power + turbo on;
// Performance = performance + turbo on; all powersave. null = keep the firmware's value: for the
// caps and the maximum performance that is the firmware's ceiling, written on every switch (a
// switch ends a tweak); for EPP, turbo and the governor it means "leave alone".
var PROFILE_SEEDS = {
    quiet:       { epp: "power",         turbo: false, governor: "powersave", maxPerfPct: null, pl1W: null, pl2W: null },
    balanced:    { epp: "balance_power", turbo: true,  governor: "powersave", maxPerfPct: null, pl1W: null, pl2W: null },
    performance: { epp: "performance",   turbo: true,  governor: "powersave", maxPerfPct: null, pl1W: null, pl2W: null }
};

// `defaultProfile`: the profile the laptop comes up in (bootPlan), or null -- nothing stored, the firmware's own.
var DEFAULT_PROFILE_SPEC = { t: "enum", values: PROFILES, nullable: true };

var PROFILE_SPEC = {
    epp:        { t: "enum", values: EPP_ORDER, nullable: true },
    turbo:      { t: "bool", nullable: true },
    governor:   { t: "enum", values: GOVERNORS, nullable: true },
    maxPerfPct: { t: "int", min: 1, max: 100, nullable: true },
    pl1W:       { t: "num", min: 1, max: 400, nullable: true },
    pl2W:       { t: "num", min: 1, max: 400, nullable: true }
};

// ---- the reading beat -------------------------------------------------------------------------------------
// Every reader runs on ONE beat of `baseMs`; each asks for every Nth beat (0 = not read), so the slow ones land ON a fast
// one and the figures that change together are read together. A period that is not a whole number of beats is ROUNDED to
// the nearest (at least one) here, and nowhere else.
function wholeBeats(periodMs, baseMs) {
    var n = Math.round(periodMs / baseMs);
    return n < 1 ? 1 : n;
}

// The beat and the counts for the popup's state: `level` is the idle ladder's ("alive" | "calm" | "halt"), `open` the popup's,
// `idle` the ladder's halted periods (IdleLadder: statsHaltedMs, batteryHaltedMs). Alive 1 s; calm 2 s; halted the stats' halted period, the
// battery's a whole number of those; closed the battery's halted period alone. The helper's status (the minute's backstop
// open, five minutes closed: it walks the machine and reads the MUX through the EC) and the overhead meter (never faster
// than once a second) are counted in the same beats. A bare number is the period in ms.
function cadence(level, open, idle, guardMs) {
    var base;
    var stats = 1;
    var battery = 1;
    var statusMs = open ? 60000 : 300000;
    if (!open) {
        base = idle.batteryHaltedMs;
        stats = 0;
    } else if (level === "alive") {
        base = 1000;
    } else if (level === "calm") {
        base = 2000;
    } else {
        base = idle.statsHaltedMs;
        battery = wholeBeats(idle.batteryHaltedMs, base);
    }
    return { baseMs: base, stats: stats, battery: battery, status: wholeBeats(statusMs, base),
             overhead: stats > 0 ? wholeBeats(1000, base) : 0, guard: wholeBeats(guardMs || 5000, base) };
}

// Seeds for the groups that are not profiles. The overhead coefficients are UNCALIBRATED seeds (watts per second of the shell's
// CPU time and of its GPU render time) until tools/silicon/calibrate_overhead.sh has measured them. The idle ladder's times and the sounds are the module's constants
// (IdleLadder, SiliconSounds), tuned in the silicon mockup, not groups of the file; an older file's `idle` and `sounds` load with one
// warning each, as `mux` does.
var GROUP_SPEC = {
    overhead: {
        wPerCpuSec: { t: "num", min: 0, max: 50, dflt: 2.0 },
        wPerGpuSec: { t: "num", min: 0, max: 50, dflt: 5.0 }
    },
    // The dGPU's holders the popup does not ask about (CardwireParse.lsofHolders): process names (the kernel's comm, matched whole and
    // without regard to case). The list is the whole truth: a name removed from it counts as a user of the card again.
    gpu: {
        askWhenBusy: { t: "bool", dflt: true },         // a step that blocks apps on the card asks first
        blockedNotice: { t: "bool", dflt: true },       // a card for an app that was kept off it
        ignoredHolders: { t: "names", max: 64, dflt: CardwireParse.IGNORED_HOLDERS }
    },
    // The profile a plug switches to, null = none (SiliconService._onPlug).
    onPower: {
        ac: { t: "enum", values: PROFILES, nullable: true, dflt: null },
        battery: { t: "enum", values: PROFILES, nullable: true, dflt: null }
    },
    // The profile a running system update is held at, null = not held (SystemUpdateHold).
    holds: {
        systemUpdate: { t: "enum", values: ["performance", "balanced"], nullable: true, dflt: "performance" }
    },
    // The charge the pack counts as low at (PowerMath.lowLine).
    battery: {
        lowAt: { t: "int", min: 5, max: 50, dflt: 15 }
    },
    fans: {
        guard: { t: "bool", dflt: true },
        resumeKick: { t: "bool", dflt: true }
    },
    look: {
        // "eva" is the old name of "material" (the look was renamed 2026-11-21): still read, as material, with no warning.
        family: { t: "enum", values: ["material", "blueprint"], dflt: "material", aliases: { eva: "material" } },
        // Where every secondary the popup opens hangs: away from the bar ("far"), or along it ("start", "end"). The
        // engine's own words for the side of a child; it depends on how the shell is finally assembled, so it is a setting.
        secondarySide: { t: "enum", values: ["far", "start", "end"], dflt: "far" }
    }
};

// The defaults of one group of keys (a nested group is a group of its own, never a shared object).
function _defaults(spec) {
    var out = {};
    Object.keys(spec).forEach(function (k) {
        out[k] = spec[k].t === "group" ? _defaults(spec[k].spec) : spec[k].t === "names" ? spec[k].dflt.slice() : spec[k].dflt;
    });
    return out;
}

function defaultConfig() {
    var c = { defaultProfile: null, profiles: {}, sounds: true, interactionBoost: false };
    PROFILES.forEach(function (p) { c.profiles[p] = JSON.parse(JSON.stringify(PROFILE_SEEDS[p])); });
    Object.keys(GROUP_SPEC).forEach(function (g) { c[g] = _defaults(GROUP_SPEC[g]); });
    return c;
}

// One value against its spec -> { ok: true, value } | { ok: false, why }. A rule that is not
// enforced here is a config value outside its range that gets accepted.
function checkValue(spec, v) {
    if (v === null && spec.nullable)
        return { ok: true, value: null };
    if (spec.t === "bool")
        return typeof v === "boolean" ? { ok: true, value: v } : { ok: false, why: "not true or false" };
    if (spec.t === "enum")
        return (typeof v === "string" && spec.values.indexOf(spec.aliases && spec.aliases[v] ? spec.aliases[v] : v) >= 0)
            ? { ok: true, value: spec.aliases && spec.aliases[v] ? spec.aliases[v] : v }
            : { ok: false, why: "not one of " + spec.values.join(", ") };
    if (spec.t === "names") {
        if (!Array.isArray(v))
            return { ok: false, why: "not a list of names" };
        if (v.length > spec.max)
            return { ok: false, why: "more than " + spec.max + " names" };
        var names = [];
        for (var i = 0; i < v.length; i++) {
            if (typeof v[i] !== "string" || v[i].trim() === "")
                return { ok: false, why: "entry " + i + " is not a name" };
            if (names.indexOf(v[i].trim()) < 0)
                names.push(v[i].trim());
        }
        return { ok: true, value: names };
    }
    if (spec.t === "int" || spec.t === "num") {
        if (typeof v !== "number" || !isFinite(v))
            return { ok: false, why: "not a number" };
        if (spec.t === "int" && v !== Math.floor(v))
            return { ok: false, why: "not a whole number" };
        if (v < spec.min || v > spec.max)
            return { ok: false, why: "outside " + spec.min + " to " + spec.max };
        return { ok: true, value: v };
    }
    return { ok: false, why: "unknown rule" };
}

function _obj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// One group of keys: known keys checked against `spec`, the rest named once.
function _group(path, src, spec, out, warnings) {
    if (!_obj(src)) {
        warnings.push(path + ": not an object, using the defaults");
        return;
    }
    Object.keys(src).forEach(function (k) {
        if (!spec.hasOwnProperty(k)) {
            warnings.push(path + "." + k + ": unknown key, ignored");
            return;
        }
        if (spec[k].t === "group") {
            _group(path + "." + k, src[k], spec[k].spec, out[k], warnings);
            return;
        }
        var r = checkValue(spec[k], src[k]);
        if (r.ok)
            out[k] = r.value;
        else
            warnings.push(path + "." + k + ": " + JSON.stringify(src[k]) + " is " + r.why + ", keeping " + JSON.stringify(out[k]));
    });
}

// The parsed JSON of silicon.jsonc (or null for no file) -> { config, warnings }. Every key is
// optional with its seed as the default; a bad value is ignored with ONE warning of its own, the
// others stand. Idempotent: normalizeConfig(config).config equals config.
function normalizeConfig(obj) {
    var warnings = [];
    var cfg = defaultConfig();
    if (obj === null || obj === undefined)
        return { config: cfg, warnings: warnings };
    if (!_obj(obj)) {
        warnings.push("the top level is not an object, using the defaults");
        return { config: cfg, warnings: warnings };
    }
    Object.keys(obj).forEach(function (k) {
        if (k === "defaultProfile") {
            var dp = checkValue(DEFAULT_PROFILE_SPEC, obj[k]);
            if (dp.ok)
                cfg.defaultProfile = dp.value;
            else
                warnings.push("defaultProfile: " + JSON.stringify(obj[k]) + " is " + dp.why + ", keeping " + JSON.stringify(cfg.defaultProfile));
        } else if (k === "profiles") {
            if (!_obj(obj.profiles)) {
                warnings.push("profiles: not an object, using the defaults");
                return;
            }
            Object.keys(obj.profiles).forEach(function (p) {
                if (PROFILES.indexOf(p) < 0) {
                    warnings.push("profiles." + p + ": unknown profile, ignored");
                    return;
                }
                _group("profiles." + p, obj.profiles[p], PROFILE_SPEC, cfg.profiles[p], warnings);
            });
        } else if (GROUP_SPEC.hasOwnProperty(k)) {
            _group(k, obj[k], GROUP_SPEC[k], cfg[k], warnings);
        } else if (k === "sounds" && typeof obj.sounds === "boolean") {
            cfg.sounds = obj.sounds;
        } else if (k === "interactionBoost") {
            // the shell asks lares-boost.service for a GPU / CPU floor while a motion runs (BoostClient); off unless exactly true
            if (typeof obj.interactionBoost === "boolean")
                cfg.interactionBoost = obj.interactionBoost;
            else
                warnings.push("interactionBoost: " + JSON.stringify(obj.interactionBoost) + " is not true or false, keeping false");
        } else if (k === "idle" || k === "sounds") {
            // an older file's groups: the ladder's times and how the sounds are made are the module's constants (IdleLadder, SiliconSounds)
            warnings.push(k + ": moved -- the module's own constants (the silicon mockup tunes them); ignored");
        } else if (k === "mux") {
            // an older file's key: the helper that decides the windows never reads it
            warnings.push("mux: removed -- the MUX's windows (" + MUX_BOOT_WINDOW_S / 60 + " minutes after the boot, " + MUX_PROMPT_WINDOW_S / 60
                          + " minutes after the prompt) are the root helper's and no file can change them; ignored");
        } else {
            warnings.push(k + ": unknown key, ignored");
        }
    });
    // Two relations no single value can break.
    PROFILES.forEach(function (p) {
        var c = cfg.profiles[p];
        if (c.pl1W !== null && c.pl2W !== null && c.pl1W > c.pl2W) {
            warnings.push("profiles." + p + ": pl1W (" + c.pl1W + ") is above pl2W (" + c.pl2W + "), both ignored");
            c.pl1W = null;
            c.pl2W = null;
        }
    });
    return { config: cfg, warnings: warnings };
}

// --- GPU modes: cardwire's enum and the scene's step -------------------------------------------

// cardwire Mode + the MUX wiring -> the step the user sees (0 Integrated, 1 Smart, 2 Hybrid,
// 3 dGPU-only). The wiring decides first: with the panel wired to the NVIDIA card the answer is
// 3 whatever cardwire says. cardwire's 2 Manual is not in this machine's AvailableModes; if it is
// ever reported the zone shows Hybrid and the caption names it. An unreadable mode is Hybrid too
// (the laptop's own wiring), with `gpu.present` telling the popup to grey the zone.
function stepOf(cwMode, wiring) {
    if (wiring === "dgpu")
        return STEP.DGPU;
    if (cwMode === CW.INTEGRATED)
        return STEP.INTEGRATED;
    if (cwMode === CW.SMART)
        return STEP.SMART;
    return STEP.HYBRID;
}

// A step -> the cardwire Mode that makes it; null for dGPU-only, which is the MUX's, not cardwire's.
function cwOfStep(step) {
    if (step === STEP.INTEGRATED)
        return CW.INTEGRATED;
    if (step === STEP.SMART)
        return CW.SMART;
    if (step === STEP.HYBRID)
        return CW.HYBRID;
    return null;
}

// The steps the zone offers, ascending. `modes` is cardwire's AvailableModes, never a fixed list. In dGPU-only
// wiring cardwire refuses 0 and 3, and that is NOT a reason to refuse them here: the way out is one MUX request
// (for Hybrid) and every step below dGPU-only is somewhere the laptop can be after that restart, so all four are
// offered (the mode wanted rides with the request: planGpuMode, afterMuxPlan). dGPU-only is offered only where the
// firmware has a MUX, and without one there is no way back at all.
function availableSteps(modes, wiring, muxAvailable) {
    var out = [];
    if (wiring === "dgpu") {
        if (muxAvailable)
            out.push(STEP.INTEGRATED, STEP.SMART, STEP.HYBRID);
        out.push(STEP.DGPU);
        return out;
    }
    (modes || []).forEach(function (m) {
        var s = stepOf(m, "hybrid");
        if (out.indexOf(s) < 0)
            out.push(s);
    });
    if (out.length > 0 && muxAvailable)
        out.push(STEP.DGPU);
    out.sort(function (a, b) { return a - b; });
    return out;
}

// The next step in `dir` (-1 / +1) among `steps`, or null at an end.
function stepFrom(step, dir, steps) {
    if (!steps || steps.length === 0 || (dir !== -1 && dir !== 1))
        return null;
    var at = steps.indexOf(step);
    if (at < 0) {
        // Not offered (e.g. cardwire's Manual shown as Hybrid): move from where it would sit.
        var cand = dir > 0 ? steps.filter(function (s) { return s > step; })[0]
                           : steps.filter(function (s) { return s < step; }).pop();
        return cand === undefined ? null : cand;
    }
    var to = at + dir;
    return to >= 0 && to < steps.length ? steps[to] : null;
}

// --- profiles and tuning ---------------------------------------------------------------------------

// THE LIMIT STOPS CHARGING; IT DOES NOT DRAIN. This laptop's firmware knows two limits, 80 and 100: \_SB.ATKD.SRSC(80) sets the EC's
// charge window to 80/80 and nothing else (docs/silicon.md, the charge limit), and nothing in
// its tables discharges the pack toward it on the mains. A pack at 94 % stays there with the limit switched on: the limit
// holds it, it does not bring it down. `battery` here is the facts' battery: true when the pack is on the mains,
// neither charging nor discharging, with a limit on and more than a point above it -- held, and staying there until the charger goes.
function heldAboveLimit(bat) {
    return !!bat && bat.present === true && bat.ac === true && bat.limitOn === true
        && bat.status !== "Charging" && bat.status !== "Discharging" && bat.pct > bat.limitPct + 1;
}
// The same fact as a sentence for a hover tip, "" while it is not so.
function heldNote(bat) {
    if (!heldAboveLimit(bat))
        return "";
    return "Held at " + Math.round(bat.pct) + " %. The " + bat.limitPct + " % limit stops charging; it does not drain the pack, so it stays here until the charger is unplugged.";
}

// The profile one step from `target` (an index) in `dir`, among the kernel's `profiles` (names). The
// three profiles are a CYCLE (from each mode the others can be reached):
// Quiet -> Balanced -> Performance -> Quiet one way, the other the other, so no step meets an end.
// A profile the kernel does not offer is stepped over; null when there is no other one to go to.
function nextProfile(target, dir, profiles) {
    var n = PROFILES.length, have = profiles || [];
    for (var k = 1; k < n; k++) {
        var to = (((target + (dir > 0 ? k : -k)) % n) + n) % n;
        if (have.indexOf(PROFILES[to]) >= 0)
            return to;
    }
    return null;
}

// What setGpuMode(step, opts) does, from the GPU facts `g`, the step the scene is aimed at, and the
// facts' own words: { action: "none" | "refuse" | "mux" | "reaim" | "cardwire", why, want, after, cw }.
//   mux       dGPU-only, or the way back from it: a request the helper records, applied by a restart. The way
//             back is one request for Hybrid whichever step was asked, and `after` is that step (the mode wanted
//             once the laptop is back: set through cardwire then, afterMuxPlan);
//   cancelmux a queued dGPU-only request is withdrawn (the helper's `cancel`), THEN `cw` is written as a cardwire step
//   reaim     the way back is already queued: only `after` changes, nothing is asked of the helper;
//   cardwire  a Mode written to the daemon (Integrated 0, Smart 3, Hybrid 1);
//   refuse    not offered, no cardwire, or Integrated / Smart with apps on the card and no confirmation
//             (cardwire blocks only NEW opens, so the apps keep running; the popup lists them first). Not asked
//             in dGPU-only wiring: the apps on the card there are the compositor's own, and the mode is applied
//             after the restart, where the same rule is asked (afterMuxPlan "apply" goes through here).
function planGpuMode(step, opts, g, targetStep) {
    if (!g.present)
        return { action: "refuse", why: "GPU modes need cardwire: " + g.why };
    if (g.steps.indexOf(step) < 0)
        return { action: "refuse", why: "That GPU mode is not available" };
    if (step === targetStep && !g.mux.pending)
        return { action: "none" };
    if (step === STEP.DGPU)
        return { action: "mux", want: "dgpu" };
    if (g.wiring === "dgpu") {
        if (g.mux.pending && g.mux.want === "hybrid")
            return step === targetStep ? { action: "none" } : { action: "reaim", after: step };
        return { action: "mux", want: "hybrid", after: step };
    }
    if ((step === STEP.INTEGRATED || step === STEP.SMART) && g.holders.length > 0 && !(opts && opts.confirmHolders))
        return { action: "refuse", why: "Apps are using the dGPU (" + g.holders.join(", ") + "); confirm to block it for new ones" };
    // Hybrid wiring with a dGPU-only request on file: the firmware is written at SHUTDOWN only, so until then the request is
    // a record the helper can withdraw (`cancel`, from Queued only). A step away from it withdraws it first, then goes
    // through cardwire as any step does; an `applied` record was written at shutdown already and is refused.
    if (g.wiring !== "dgpu" && g.mux.pending && g.mux.want === "dgpu") {
        if (g.mux.state !== "queued")
            return { action: "refuse", why: "The dGPU-only switch is already written; it can be undone after the restart" };
        return { action: "cancelmux", cw: cwOfStep(step) };
    }
    return { action: "cardwire", cw: cwOfStep(step) };
}

// What to do with the mode asked for after a way back from dGPU-only, from the facts alone. `after` is a step 0..2 or
// null (nothing asked); `busy` is true while a MUX write is on its way (its answer has not changed the facts yet, so the
// absence of a request means nothing). The answers:
//   none    nothing was asked
//   keep    the request is queued (or written and awaiting the boot guard), or an answer is still to come, or the helper
//           has not answered yet (at login the record is UNKNOWN, not absent: nothing is forgotten on a guess), or
//           cardwire is not up yet at the login that follows the restart
//   apply   the restart is over -- the panel wired as hybrid again, the record kept -- and cardwire is there: set `step`
//           through cardwire ONCE, and clear it (`planGpuMode` and the holders rule are the normal step's)
//   clear   nothing is coming (the request was cancelled, refused, replaced by dGPU only, failed, or the laptop is
//           already where it was asked to be): forget it, a forgotten request must never apply at some later restart
function afterMuxPlan(after, gpu, busy) {
    if (after === null || after === undefined)
        return { action: "none" };
    if (busy || !gpu.mux.available)
        return { action: "keep" };
    var m = gpu.mux;
    if (m.pending)
        return m.want === "hybrid" ? { action: "keep" } : { action: "clear" };
    if (m.want === "hybrid" && m.state === "kept" && gpu.wiring === "hybrid") {
        if (!gpu.present || gpu.steps.length === 0)
            return { action: "keep" };
        return after === gpu.step ? { action: "clear" } : { action: "apply", step: after };
    }
    return { action: "clear" };
}

function profileIndex(name) {
    var i = PROFILES.indexOf(name);
    return i < 0 ? 1 : i;
}

// The kernel's profile list in the scene's order, limited to the three silicon knows.
function orderedProfiles(list) {
    return PROFILES.filter(function (p) { return (list || []).indexOf(p) >= 0; });
}

// The kernel's EPP list from thriftiest to keenest; a name this file does not know keeps the
// kernel's order, after the known ones.
function orderedEpps(list) {
    var l = list || [];
    return EPP_ORDER.filter(function (e) { return l.indexOf(e) >= 0; })
        .concat(l.filter(function (e) { return EPP_ORDER.indexOf(e) < 0; }));
}

function _clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

// What switching to profile `name` applies (CONTRACT: the profile's linked values from the
// config) -> { patch, notes }. A value the kernel does not offer is left out with a note; a
// number outside the kernel's range is brought into it. Null in the config:
//   epp / turbo / governor   not written (a tweak of those survives a switch);
//   maxPerfPct               the kernel's maximum;
//   pl1W / pl2W              "firmware": back to the ceiling the firmware set.
// So a switch ends every tweak the helper can undo. EPP is left out where the profile's governor
// is performance (the kernel fixes it there).
function linkedPatch(config, name, status) {
    var c = config.profiles[name];
    var notes = [];
    var patch = { profile: name };
    if (!c || !status)
        return { patch: patch, notes: notes };
    var f = status.features, L = status.lists, lim = status.limits;
    if (c.governor !== null && f.governor) {
        if (L.governors.indexOf(c.governor) >= 0)
            patch.governor = c.governor;
        else
            notes.push("the kernel offers no governor " + c.governor);
    }
    var gov = patch.governor !== undefined ? patch.governor : status.values.governor;
    if (c.epp !== null && f.epp && gov !== "performance") {
        if (L.epps.indexOf(c.epp) >= 0)
            patch.epp = c.epp;
        else
            notes.push("the kernel offers no energy preference " + c.epp);
    }
    if (c.turbo !== null && f.turbo)
        patch.turbo = c.turbo;
    if (f.maxPerfPct && lim.maxPerfPct)
        patch.maxPerfPct = c.maxPerfPct !== null ? _clamp(c.maxPerfPct, lim.maxPerfPct.min, lim.maxPerfPct.max) : lim.maxPerfPct.max;
    if (f.caps && lim.capCeilW !== null && lim.capFloorW !== null) {
        patch.pl1W = c.pl1W !== null ? _clamp(c.pl1W, lim.capFloorW, lim.capCeilW.pl1) : "firmware";
        patch.pl2W = c.pl2W !== null ? _clamp(c.pl2W, lim.capFloorW, lim.capCeilW.pl2) : "firmware";
        if (patch.pl1W !== "firmware" && patch.pl2W !== "firmware" && patch.pl1W > patch.pl2W)
            patch.pl1W = patch.pl2W;
    }
    return { patch: patch, notes: notes };
}

// Do the live values differ from what the profile applies? Only what the profile would write
// counts, so a null (leave alone) never makes a profile look tweaked. A knob that reads "mixed"
// (the policies disagree) is a tweak.
function tweaked(name, config, status) {
    if (!status || !status.features.profile)
        return false;
    var want = linkedPatch(config, name, status).patch;
    var v = status.values;
    var caps = v.caps || {};
    var ceil = status.limits.capCeilW;
    if (want.governor !== undefined && v.governor !== want.governor)
        return true;
    if (want.epp !== undefined && !status.limits.eppLocked && v.epp !== want.epp)
        return true;
    if (want.turbo !== undefined && v.turbo !== want.turbo)
        return true;
    if (want.maxPerfPct !== undefined && v.maxPerfPct !== want.maxPerfPct)
        return true;
    var capWant = function (w, ceilKey) { return w === "firmware" ? (ceil ? ceil[ceilKey] : undefined) : w; };
    var w1 = capWant(want.pl1W, "pl1"), w2 = capWant(want.pl2W, "pl2");
    if (typeof w1 === "number" && typeof caps.pl1W === "number" && Math.abs(caps.pl1W - w1) > 0.5)
        return true;
    if (typeof w2 === "number" && typeof caps.pl2W === "number" && Math.abs(caps.pl2W - w2) > 0.5)
        return true;
    return false;
}

// --- the boot profile ------------------------------------------------------------------------
// `defaultProfile` (silicon.jsonc) is the profile the laptop COMES UP in. The root helper keeps a boot set (`set-boot`, its
// boot.json) that silicon-boot.service applies early in every boot, before the login screen; the shell only STORES there the
// named profile's linked values -- the very arguments a switch to it applies (linkedPatch) -- and never applies a profile at its
// own start (the profile must not change to the default only when the shell launches). No key
// stores nothing and clears nothing.
//   bootPlan(config, status, stored) -> { want, action, words, patch, notes, why }
//     status   the helper's (null until it has answered: it says what the profile applies on this kernel)
//     stored   HelperProto.parseBootSet of the boot set's text
//     action   "off"     no defaultProfile: nothing to store
//              "wait"    the helper has not answered
//              "refuse"  this kernel cannot take the profile's values (`why`: the helper's own rule, asked locally)
//              "same"    the stored boot set already holds `words`
//              "store"   `set-boot` with `patch` (`words`: the arguments as the helper stores them)
function bootPlan(config, status, stored) {
    var want = config && typeof config.defaultProfile === "string" ? config.defaultProfile : null;
    if (want === null)
        return { want: null, action: "off", words: [], patch: null, notes: [], why: "" };
    if (!status)
        return { want: want, action: "wait", words: [], patch: null, notes: [], why: "waiting for the silicon helper" };
    var lp = linkedPatch(config, want, status);
    var words = Proto.applyWords(lp.patch);
    var v = Proto.validatePatch(lp.patch, status);
    if (!v.ok)
        return { want: want, action: "refuse", words: words, patch: lp.patch, notes: lp.notes, why: v.why };
    if (stored && stored.ok && Proto.sameApply(stored.apply, words))
        return { want: want, action: "same", words: words, patch: lp.patch, notes: lp.notes, why: "" };
    return { want: want, action: "store", words: words, patch: lp.patch, notes: lp.notes, why: "" };
}

// What to do with a plan: ONE ask per difference. An attempt is remembered (`last`: { memo, why }) against the profile, its arguments
// and the stored set's TEXT; the same want over the same file is not asked again, so a failure stands (state "failed", its why) until
// the config or the file changes, or the shell restarts -- never a retry per status read. A stored set that matches forgets the
// attempt (a later difference is a new one), and so does a key taken out.
//   bootDecide(plan, text, last, pending) -> { state, why, send, last, fresh }
//     state   "off" | "waiting" | "storing" | "stored" | "failed";  send: ask `set-boot` now;  fresh: a failure decided now (its one log line)
//     pending a set-boot is on its way (its answer decides)
function bootDecide(plan, text, last, pending) {
    if (plan.action === "off")
        return { state: "off", why: "", send: false, last: null, fresh: false };
    if (plan.action === "wait")
        return { state: "waiting", why: plan.why, send: false, last: last, fresh: false };
    if (pending)
        return { state: "storing", why: "", send: false, last: last, fresh: false };
    if (plan.action === "same")
        return { state: "stored", why: "", send: false, last: null, fresh: false };
    var memo = plan.want + "\n" + plan.words.join(" ") + "\n" + String(text);
    if (last && last.memo === memo)
        return { state: "failed", why: last.why !== "" ? last.why : "the helper said it stored the boot set, but it does not read back as asked",
                 send: false, last: last, fresh: false };
    if (plan.action === "refuse")
        return { state: "failed", why: plan.why, send: false, last: { memo: memo, why: plan.why }, fresh: true };
    return { state: "storing", why: "", send: true, last: { memo: memo, why: "" }, fresh: false };
}

// --- the facts ---------------------------------------------------------------------------------------

function _n(v) {
    return typeof v === "number" && isFinite(v) ? v : null;
}

// A policy row with its `ignored` flag (the cardwire client's row is never changed in place).
function _withIgnored(row, ignored) {
    var out = {};
    Object.keys(row || {}).forEach(function (k) { out[k] = row[k]; });
    out.ignored = ignored;
    return out;
}

// The input record the service (or the mock) hands over:
//   nowMs, config (normalised), helper { installed, ok, why }, status (HelperProto.normaliseStatus) | null,
//   sensors { clockMHz, loadPct, tempC, cores [{kind, load}], igpuBusy },
//   cardwire { present, asked, why, mode, modes, dState, holders, blocked, policies, config } (`asked`: cardwire has been asked and
//   its answer is a fact; false = "not yet", which `gpu.known` repeats; absent = a source that never asks, known),
//   (helper's `answered` is the same word for the helper),
//   smi { util, tempC, watts, vramUsedMB, vramTotalMB } | null,
//   battery { sample (PowerMath.parseUevent) | null, figures (PowerMath.figures) | null, ac, limitPct },
//   overheadW, lastFullMs (the service's own record), upower { ms, ok, why } | null (UpowerHistory: the newest moment
//   UPower's charge history had the pack full, 0 when none, and why it could not say when it could not), hold { source,
//   profile, reason } | null, muxOutcomeSeenAt,
//   ignoredApps [app id] (the Smart apps the user chose "never ask again" for; optional),
//   afterMuxMode (0 | 1 | 2 | null: the step asked for with a way back from dGPU-only, SiliconState's),
//   memory (SysfsParse.parseMeminfo's answer | null),
//   display { hdmi } (optional: an external display on the NVIDIA card's HDMI-A connector; false when absent),
//   muxWindows { bootS, promptS } (optional: SiliconMock's pretend guard; the service's are the helper's constants)
function buildFacts(inp) {
    var st = inp.status;
    var cfg = inp.config;
    var v = st ? st.values : {};
    var f = st ? st.features : { profile: false, epp: false, turbo: false, governor: false, maxPerfPct: false, caps: false, chargeLimit: false, mux: false };
    var L = st ? st.lists : { profiles: [], epps: [], governors: [] };
    var lim = st ? st.limits : { capFloorW: null, capCeilW: null, maxPerfPct: null, eppLocked: false };
    var caps = v.caps || {};
    var sens = inp.sensors || {};
    var helperOk = !!(inp.helper && inp.helper.ok && st);

    var cpu = {
        present: helperOk && f.profile,
        profile: typeof v.profile === "string" ? v.profile : "",
        profiles: orderedProfiles(L.profiles),
        epp: typeof v.epp === "string" ? v.epp : "",
        eppChoices: orderedEpps(L.epps),
        eppLocked: lim.eppLocked,
        turbo: v.turbo === true,
        governor: typeof v.governor === "string" ? v.governor : "",
        governors: L.governors.slice(),
        maxPerfPct: _n(v.maxPerfPct),
        maxPerfRange: lim.maxPerfPct ? { min: lim.maxPerfPct.min, max: lim.maxPerfPct.max } : { min: null, max: null },
        pl1W: _n(caps.pl1W),
        pl2W: _n(caps.pl2W),
        capFloorW: lim.capFloorW,
        capCeilW: lim.capCeilW ? { pl1: lim.capCeilW.pl1, pl2: lim.capCeilW.pl2 } : { pl1: null, pl2: null },
        capsWritable: f.caps && lim.capCeilW !== null,
        features: { profile: f.profile, epp: f.epp, turbo: f.turbo, governor: f.governor, maxPerfPct: f.maxPerfPct, caps: f.caps },
        tweaked: helperOk && typeof v.profile === "string" ? tweaked(v.profile, cfg, st) : false,
        heldBy: inp.hold ? String(inp.hold.source) : "",
        clockMHz: _n(sens.clockMHz),
        loadPct: _n(sens.loadPct),
        tempC: _n(sens.tempC)
    };

    var cw = inp.cardwire || {};
    var smi = inp.smi || null;
    var ignored = Array.isArray(inp.ignoredApps)
        ? inp.ignoredApps.filter(function (a) { return typeof a === "string" && a !== ""; }) : [];
    var rec = st ? st.mux.record : null;
    var after = _n(inp.afterMuxMode);
    after = after === 0 || after === 1 || after === 2 ? after : null;
    var muxAvailable = !!(st && f.mux);
    var wiring = st ? (st.mux.wiringNow || st.mux.stored || "hybrid") : "hybrid";
    var modes = Array.isArray(cw.modes) ? cw.modes.slice() : [];
    var dState = typeof cw.dState === "string" ? cw.dState : "";
    var cwCfg = cw.config || {};
    var gpu = {
        present: cw.present === true,
        why: cw.present === true ? "" : String(cw.why || "cardwire is not running"),
        mode: _n(cw.mode),
        modes: modes,
        // The step is a FACT only once both what decides it have answered: cardwire's mode and the helper's wiring. Before that it is
        // the Hybrid fallback of `stepOf`, a guess a host must not draw (the bar's card showed Hybrid for the first seconds of a
        // boot back to Integrated). A source that does not say (a mock, a probe) is known.
        known: (cw.asked !== false) && !(inp.helper && inp.helper.answered === false),
        step: stepOf(_n(cw.mode), wiring),
        steps: cw.present === true ? availableSteps(modes, wiring, muxAvailable) : [],
        wiring: wiring,
        dState: dState,
        awake: dState === "D0",
        util: smi ? _n(smi.util) : null,
        tempC: smi ? _n(smi.tempC) : null,
        watts: smi ? _n(smi.watts) : null,
        vramUsedMB: smi ? _n(smi.vramUsedMB) : null,
        vramTotalMB: smi ? _n(smi.vramTotalMB) : null,
        holders: Array.isArray(cw.holders) ? cw.holders.slice() : [],
        blockedApps: Array.isArray(cw.blocked) ? cw.blocked.slice() : [],
        // every row says whether the user chose "never ask again" for it; `ignoredApps` is the persisted
        // list itself (an ignored app may not be a row: only apps seen or chosen are)
        policies: (Array.isArray(cw.policies) ? cw.policies : []).map(function (p) { return _withIgnored(p, ignored.indexOf(p.id) >= 0); }),
        ignoredApps: ignored.slice(),
        config: {
            batteryAutoSwitch: cwCfg.batteryAutoSwitch === true,
            batteryAutoSwitchMode: _n(cwCfg.batteryAutoSwitchMode) === null ? 0 : cwCfg.batteryAutoSwitchMode,
            externalDisplayAutoSwitch: cwCfg.externalDisplayAutoSwitch === true,
            nvidiaBlock: cwCfg.nvidiaBlock === true
        },
        mux: {
            available: muxAvailable,
            state: rec ? String(rec.state || "") : "",
            pending: !!(rec && (rec.state === "queued" || rec.state === "applied")),
            want: rec ? String(rec.want || "") : "",
            from: rec ? String(rec.from || "") : "",
            why: rec ? String(rec.why || "") : "",
            deadlineMs: rec && _n(rec.deadlineMs) !== null ? rec.deadlineMs : null,
            deadlineBootId: rec && typeof rec.deadlineBootId === "string" ? rec.deadlineBootId : "",
            deadlineUptimeMs: rec && _n(rec.deadlineUptimeMs) !== null ? rec.deadlineUptimeMs : null,
            bootId: st && st.boot && typeof st.boot.id === "string" ? st.boot.id : "",
            bootWindowS: _n((inp.muxWindows || {}).bootS) !== null ? inp.muxWindows.bootS : MUX_BOOT_WINDOW_S,
            promptWindowS: _n((inp.muxWindows || {}).promptS) !== null ? inp.muxWindows.promptS : MUX_PROMPT_WINDOW_S,
            afterMode: after,
            stored: st ? st.mux.stored : null,
            wiringNow: st ? st.mux.wiringNow : null,
            prechecks: st ? { ok: st.prechecks.mux.ok, why: st.prechecks.mux.why } : { ok: true, why: "" },
            outcomeSeen: !rec || !(typeof rec.requestedAtMs === "number") || (inp.muxOutcomeSeenAt || 0) >= rec.requestedAtMs
        }
    };
    // WORKING, not merely awake: an awake card with nobody on it is idle, and `holders` already leaves the session's own plumbing out
    // (CardwireParse.lsofHolders). The list is read on a beat, so it can outlive the card's sleep: asleep is never in use. In dGPU-only
    // wiring the card IS the display, whoever is on it -- and in Hybrid it is working too while it drives a display on its own HDMI
    // connector: the compositor that draws there is plumbing to `holders`, so without this the bar's glyph read idle (faint) with an
    // external display lit by the card (feedback/silicon.md "Gpu glyph faint when dgpu awake").
    var display = { hdmi: !!(inp.display && inp.display.hdmi === true) };
    gpu.inUse = gpu.awake && (wiring === "dgpu" || gpu.holders.length > 0 || display.hdmi);

    var b = inp.battery || {};
    var s = b.sample || null;
    var fig = b.figures || null;
    var limitPct = _n(b.limitPct);
    var limitOn = limitPct !== null && limitPct > 0 && limitPct < 100;
    var signed = fig ? fig.signedW : 0;
    var ownFullMs = _n(inp.lastFullMs) === null ? 0 : inp.lastFullMs;
    var up = inp.upower || null;
    var upFullMs = up && _n(up.ms) !== null && up.ms > 0 ? up.ms : 0;
    var battery = {
        present: !!s && s.present,
        pct: s ? s.pct : 0,
        status: s ? s.status : "",
        ac: typeof b.ac === "boolean" ? b.ac : (s ? s.status === "Charging" || s.status === "Full" : false),
        wattsReal: signed,
        wattsAvg: fig ? fig.avgSignedW : 0,
        wattsNormalised: Pm.normalised(signed, inp.overheadW),
        overheadW: _n(inp.overheadW) === null ? 0 : inp.overheadW,
        minutesLeft: fig ? fig.minutesLeft : null,
        minutesToFull: fig ? fig.minutesToFull : null,
        toLimit: fig ? fig.toLimit : false,
        stalled: fig ? fig.stalled === true : false,
        conditionPct: fig ? fig.conditionPct : 100,
        cycles: s ? s.cycles : 0,
        lastFullMs: Math.max(ownFullMs, upFullMs),
        lastFullSource: upFullMs > ownFullMs ? "upower" : (ownFullMs > 0 ? "own" : ""),
        upowerWhy: up && up.ok !== true && typeof up.why === "string" ? up.why : "",
        atTarget: fig ? fig.atTarget === true : false,
        limitOn: limitOn,
        limitPct: limitPct === null ? 100 : limitPct,
        limitAvailable: f.chargeLimit && limitPct !== null
    };

    var mem = inp.memory || null;
    var memory = {
        totalKiB: mem ? _n(mem.totalKiB) : null,
        availableKiB: mem ? _n(mem.availableKiB) : null,
        usedFraction: mem ? _n(mem.usedFraction) : null
    };

    var helper = {
        installed: !!(inp.helper && inp.helper.installed),
        ok: helperOk,
        why: inp.helper ? String(inp.helper.why || "") : "no helper",
        features: { profile: f.profile, epp: f.epp, turbo: f.turbo, governor: f.governor, maxPerfPct: f.maxPerfPct, caps: f.caps, chargeLimit: f.chargeLimit, mux: f.mux }
    };

    return {
        cpu: cpu,
        cores: Array.isArray(sens.cores) ? sens.cores.map(function (c) { return { kind: c.kind, load: _n(c.load) === null ? 0 : c.load }; }) : [],
        igpu: { busy: _n(sens.igpuBusy) },
        gpu: gpu,
        memory: memory,
        display: display,
        battery: battery,
        helper: helper
    };
}

// The keep prompt's countdown, by HELPER_PROTOCOL.md's rule. The guard decides on TIME SINCE BOOT (a wall clock steps
// early in a boot when NTP corrects it), so:
//   - while the record's deadline counts in THIS boot, what is left is its uptime deadline minus the shell's own
//     /proc/uptime (`uptimeMs`, null when it cannot be read);
//   - a record still awaiting a keep in ANOTHER boot is past its deadline -- the guard reverts it at once: 0;
//   - with no boot to compare (a record in the older shape, a status with no boot id) the wall-clock deadline stands in,
//     for display only.
// null = no deadline (the record is not awaiting a keep). Never negative.
function muxRemainingMs(mux, nowMs, uptimeMs) {
    if (!mux || mux.state !== "awaiting-keep")
        return null;
    if (mux.deadlineBootId !== "" && mux.bootId !== "") {
        if (mux.deadlineBootId !== mux.bootId)
            return 0;
        if (_n(mux.deadlineUptimeMs) !== null && _n(uptimeMs) !== null)
            return Math.max(0, mux.deadlineUptimeMs - uptimeMs);
    }
    if (_n(mux.deadlineMs) !== null && _n(nowMs) !== null)
        return Math.max(0, mux.deadlineMs - nowMs);
    return null;
}

// --- captions -----------------------------------------------------------------------------------------
// One line per zone, text swaps instant. The popup owns the colour (an error is the popup's
// error colour); these are the words. Titles say what is happening NOW.

function holdLabel(source) {
    if (source === "system-update")
        return "the system update";
    if (source === "llm")
        return "the language model";
    return String(source).replace(/[-_]+/g, " ");
}

function _list(names) {
    if (names.length <= 3)
        return names.join(", ");
    return names.slice(0, 2).join(", ") + " and " + (names.length - 2) + " more";
}

function buildCaption(facts, errors) {
    var e = errors || {};
    var cpu = facts.cpu, gpu = facts.gpu, bat = facts.battery, hp = facts.helper;
    var out = { cpu: "", gpu: "", battery: "", cpuError: e.cpu || "", gpuError: e.gpu || "", batteryError: e.battery || "" };

    if (!hp.ok) {
        // a name and its reason (the popup sets "a · b" as a head over a tail; a sentence would not fit)
        out.cpu = "Profile unknown · " + (hp.installed ? hp.why : "silicon-helper is not installed");
    } else if (cpu.profile !== "") {
        var bits = [Fmt.profileLabel(cpu.profile)];
        if (cpu.heldBy !== "")
            bits.push("held by " + holdLabel(cpu.heldBy));
        else if (cpu.tweaked)
            bits.push("tweaked");
        out.cpu = bits.join(" · ");
    }

    if (!gpu.present) {
        out.gpu = "Mode unknown · " + gpu.why;
    } else {
        var mode = Fmt.gpuStepLabel(gpu.step);
        var g = [mode];
        if (gpu.mode === CW.MANUAL && gpu.wiring !== "dgpu")
            g.push("cardwire is in Manual mode");
        else if (gpu.step === STEP.INTEGRATED)
            g.push("dGPU off");
        else if (gpu.step === STEP.DGPU)
            g.push("always on");
        else if (gpu.holders.length > 0)
            g.push("in use by " + _list(gpu.holders));
        else if (gpu.awake && facts.display && facts.display.hdmi)
            g.push("driving the external display");
        else if (gpu.dState !== "")
            g.push(gpu.awake ? "dGPU awake" : "dGPU asleep");
        if (gpu.mux.pending) {
            // where it is going: dGPU only, or the way back and the mode wanted once it is done
            var goingTo = gpu.mux.want === "dgpu" ? STEP.DGPU : (gpu.mux.afterMode !== null ? gpu.mux.afterMode : STEP.HYBRID);
            g.push(Fmt.gpuStepLabel(goingTo) + " after the next restart");
        }
        out.gpu = g.join(" · ");
    }

    if (bat.present) {
        if (bat.status === "Charging") {
            var t = Fmt.minutes(bat.minutesToFull);
            if (bat.stalled)
                out.battery = "Plugged in · no charge is reaching the pack";
            else
                out.battery = t === Fmt.DASH ? "Charging" : "Charging · " + t + " to " + (bat.toLimit ? bat.limitPct + " %" : "full");
        } else if (bat.status === "Discharging") {
            var l = Fmt.minutes(bat.minutesLeft);
            out.battery = l === Fmt.DASH ? "On battery" : "On battery · " + l + " left";
        } else if (bat.ac) {
            if (heldAboveLimit(bat))
                out.battery = "Held at " + Math.round(bat.pct) + " % · the limit stops charging, it does not drain";
            else
                out.battery = bat.limitOn ? "Plugged in · limited to " + bat.limitPct + " %" : "Full";
        } else {
            out.battery = Fmt.DASH;
        }
    }
    return out;
}

// --- the board's figures ----------------------------------------------------------------------
// What the isometric board prints: the battery's and the memory's facts as the DISPLAY STRINGS SiliconScene.figures
// takes (the grammar and the cell counts are SiliconFormat.js's seg* functions).
//
//   buildFigures(battery, memory, nowMs) -> { watts, wattsRaw, time, timeMode, sinceFull, condition, cycles, ram }
//     watts       the figure the popup shows: the flow less this popup's own draw (battery.wattsNormalised)
//     wattsRaw    the measured flow, which a hover over the watts display swaps in
//     time        the minutes left, or to full -- to the limit while it is limited -- as H:MM; --:-- while the
//                 estimate has none yet, and when there is nothing to count
//     timeMode    "left" (on battery, and whenever there is no estimate to give: full, held at the limit, idle on the
//                 mains, a status nobody knows -- the display then says --:-- under its TIME LEFT label, it does not
//                 go dark) | "full" (charging to 100 %) | "limit" (charging to the charge limit) | "" (no pack at all)
//     sinceFull   how long ago the pack was last full, in the unit the cells hold ("" until it has been): 0 while it IS
//                 (`sinceFull()`)
//     condition   what the pack holds now against new, whole percent, no unit (board text); cycles likewise
//     ram         the memory in use, GiB
//   A pack that is not there leaves every battery string "" (blank cells), whatever the facts say. `nowMs` is the
//   wall clock the caller reads from ONE BoundaryClock: `Fmt.segSince(ms, nowMs).nextMs` is when sinceFull changes.
//   The total charge is not here on purpose: the bar's own icon and the pack's cells carry it.
function buildFigures(bat, mem, nowMs) {
    var b = bat || {};
    var out = { watts: "", wattsRaw: "", time: "", timeMode: "", sinceFull: "", condition: "", cycles: "",
                ram: mem && _n(mem.totalKiB) !== null && _n(mem.availableKiB) !== null ? Fmt.segGiB(mem.totalKiB - mem.availableKiB) : "--" };
    if (b.present !== true)
        return out;
    out.watts = Fmt.segWatts(b.wattsNormalised);
    out.wattsRaw = Fmt.segWatts(b.wattsReal);
    if (b.status === "Charging") {
        out.timeMode = b.toLimit ? "limit" : "full";
        out.time = Fmt.segTime(b.minutesToFull);
    } else {
        // full, held at the limit, idle, a status nobody knows: the label stays and the dashes say there is nothing to count
        out.timeMode = "left";
        out.time = Fmt.segTime(b.status === "Discharging" ? b.minutesLeft : null);
    }
    out.sinceFull = sinceFull(b, nowMs).text;
    out.condition = _n(b.conditionPct) === null ? "--" : String(Math.round(b.conditionPct));
    out.cycles = _n(b.cycles) === null ? "--" : String(Math.max(0, Math.min(9999, Math.round(b.cycles))));
    return out;
}

// The since-full display: how long ago the pack was last full -- 0 while it IS at its target (full, or held at the limit:
// it is full now, so it reads 0.0h and counts from the moment it stops being) -- as { text, nextMs }, the unit and the
// instant the text changes being SiliconFormat.segSince's. A pack at its target has nothing to wake a clock for (-1).
function sinceFull(bat, nowMs) {
    var b = bat || {};
    if (b.atTarget === true)
        return { text: Fmt.segSince(nowMs, nowMs).text, nextMs: -1 };
    return Fmt.segSince(b.lastFullMs, nowMs);
}

// -> { usedFraction } (0..1), or null while the memory has not been read.
function buildMemory(mem) {
    if (!mem || _n(mem.usedFraction) === null)
        return null;
    return { usedFraction: Math.max(0, Math.min(1, mem.usedFraction)) };
}

// --- the OSD requests of a change made outside the popup ---------------------------------------------
// OsdBus.show's `power` kind (modules/osd: not user-pressed, shown like any event, routed to the OSD by
// default): { kind, source, key, glyph, title, detail, colorToken, ms }. `colorToken` names a Theme token
// (the card resolves it, the node cases check every one against themes/eva.json). The glyphs are Symbols
// Nerd Font Material Design names, checked against the installed font: the profiles are the bar button's
// own (leaf, scale_balance, lightning_bolt), the GPU modes say where the picture is made -- memory (the
// CPU's own graphics), creation (the sparkles: Smart decides), vector_combine (both), expansion_card (the
// card) -- and the charge limit is battery_heart (a battery looked after).

var OSD_PROFILE_GLYPH = { quiet: "\u{F032A}", balanced: "\u{F05D1}", performance: "\u{F140B}" };
var OSD_PROFILE_TOKEN = { quiet: "profileQuiet", balanced: "profileBalanced", performance: "profilePerformance" };
var OSD_GPU_GLYPH = ["\u{F035B}", "\u{F0674}", "\u{F0558}", "\u{F08AE}"];
var OSD_GPU_TOKEN = ["gpuIntegrated", "gpuSmart", "gpuHybrid", "gpuDgpu"];
var OSD_LIMIT_GLYPH = "\u{F120F}";

function osdProfile(name) {
    return {
        kind: "power", source: "silicon", key: "silicon-profile", glyph: OSD_PROFILE_GLYPH[name] || OSD_PROFILE_GLYPH.balanced,
        title: Fmt.profileLabel(name), detail: "Power profile", colorToken: OSD_PROFILE_TOKEN[name] || "", ms: 2000
    };
}

function osdGpu(step) {
    return {
        kind: "power", source: "silicon", key: "silicon-gpu", glyph: OSD_GPU_GLYPH[step] || OSD_GPU_GLYPH[STEP.HYBRID],
        title: Fmt.gpuStepLabel(step), detail: "GPU mode", colorToken: OSD_GPU_TOKEN[step] || "", ms: 2000
    };
}

// The mode asked for with a way back from dGPU-only could not be set once the laptop was back (cardwire refused,
// or apps were already using the card): nobody is looking, so the pill says it, and says why. Same key as osdGpu's,
// so it replaces the pill of a mode change instead of stacking on it.
// A step away from a queued dGPU-only request withdrew it.
function osdMuxCancelled(step) {
    return {
        kind: "power", source: "silicon", key: "silicon-gpu", glyph: OSD_GPU_GLYPH[step] || OSD_GPU_GLYPH[STEP.HYBRID],
        title: Fmt.gpuStepLabel(step), detail: "dGPU-only switch cancelled", colorToken: OSD_GPU_TOKEN[step] || "", ms: 3000
    };
}

function osdAfterMuxRefused(step, why) {
    var w = String(why === undefined || why === null ? "" : why).trim();
    var short = w.length > 110 ? w.slice(0, 107).replace(/\s+\S*$/, "") + "..." : w;
    return {
        kind: "power", source: "silicon", key: "silicon-gpu", glyph: OSD_GPU_GLYPH[step] || OSD_GPU_GLYPH[STEP.HYBRID],
        title: Fmt.gpuStepLabel(step) + " was not set", detail: short !== "" ? short : "The laptop stays on Hybrid",
        colorToken: "", ms: 7000
    };
}

function osdLimit(limitPct) {
    var on = limitPct > 0 && limitPct < 100;
    return {
        kind: "power", source: "silicon", key: "silicon-limit", glyph: OSD_LIMIT_GLYPH,
        title: on ? "Charge limit " + limitPct + " %" : "Charge limit off", detail: "Battery",
        colorToken: on ? "batteryCharge" : "batteryIdle", ms: 2000
    };
}
