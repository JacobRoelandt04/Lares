.pragma library

// =============================================================================
// DdcDimRules.js -- dimming an external display over DDC while nobody touches the machine: the rules, with no Qt in them (DdcDim.qml runs
// them, tools/dev/ddc_dim_cases.js holds them to a table).
//
// A DDC WRITE IS SLOW (about 0.3 s on a quick monitor, seconds on a slow one) and one lane carries them all, so a level is ONE write, never a
// fade of many. THE FIGURE IS THE DISPLAY'S OWN (0 .. max, what its on-screen menu says), not the laptop panel's gamma ladder: `ddcDimLevel`
// and `ddcDeepLevel` are shares of the figure it stood at. 0 is allowed -- an LCD at 0 is still lit and read.
//
// WHAT IS GIVEN BACK is the figure read FRESH right before the first dim (the display's own buttons move it behind our back), written to the
// state file before the dim is sent, under the display's identity (make, model, serial), not its connector: a display switched off while
// dimmed keeps its dimmed figure, and gets its own back whenever it comes, on whatever connector, in whatever run of the shell.
// =============================================================================

var FULL = 0;
var DIM = 1;
var DEEP = 2;

// Does the shell dim the external displays on this machine? `setting`: idle.jsonc `ddcDim` (true | false | null = the machine decides: only
// where there is no laptop panel to dim). `scanned`: the panel has been looked for; unknown is no.
function applies(setting, scanned, panelThere) {
    if (setting === true || setting === false)
        return setting;
    return scanned === true && panelThere === false;
}

// The figure of `level` for a display that stood at `full`.
function target(full, level, s) {
    var share = level === DEEP ? s.ddcDeepLevel : level === DIM ? s.ddcDimLevel : 1;
    return Math.max(0, Math.min(full, Math.round(full * share)));
}

// The figure to give back: what it was, moved by whatever the hand has done to the dimmed figure since (a brightness key is also the input
// that ends the idleness, and its step may land before the give-back does).
function give(entry, goal, max) {
    var d = goal >= 0 && entry.wrote >= 0 ? goal - entry.wrote : 0;
    return Math.max(0, Math.min(max > 0 ? max : 100, entry.full + d));
}

// One display, one look. `want`: the level; `e`: what is saved for it ({ full, wrote, level, giving? } or null); `f`: its facts
// { present, state, busy, pending, goal, max, fresh }. -> { act, ... }:
//   "none"                     nothing to do                     "wait"    something is out; its end is another look
//   "retry"                    it failed: ask again later        "read"    ask it for its figure (the one to give back)
//   "dim"  { full, value }     save `full`, then set `value`     "set"     { full, value } another level of a dimmed display
//   "give" { value }           set its own figure back           "settled" it has it back: forget the entry
function next(want, e, f, s) {
    if (want === FULL && !e)
        return { act: "none" };
    if (!f.present || f.state === "unknown" || f.state === "probing")
        return { act: "wait" };
    if (f.state === "unsupported")
        return { act: "none" };
    if (f.state === "failing")
        return { act: "retry" };
    if (want === FULL) {
        if (e.giving === undefined)
            return { act: "give", value: give(e, f.goal, f.max) };
        return { act: f.pending || f.busy ? "wait" : "settled" };
    }
    if (!e) {
        if (f.busy || f.pending)
            return { act: "wait" };
        if (!f.fresh)
            return { act: "read" };
        // at 0 there is nothing to dim, and a figure nobody knows is not one to give back
        if (!(f.goal > 0))
            return { act: "none" };
        return { act: "dim", full: f.goal, value: target(f.goal, want, s) };
    }
    // Idle again while its own figure is on the way back: that figure (or what the hand made of it) is the one to come back to.
    var full = e.giving !== undefined && f.goal >= 0 ? f.goal : e.full;
    if (e.giving === undefined && e.level === want)
        return { act: "none" };
    return { act: "set", full: full, value: target(full, want, s) };
}

// How long until a display that failed is asked again: 2 s doubling to 60 s.
function retryMs(n) {
    return Math.min(60000, 2000 * Math.pow(2, Math.max(0, Math.min(10, n))));
}

// The state file: { "<make|model|serial>": { full, wrote, level } }; anything else in it is dropped.
function parseState(text) {
    var out = {};
    var o = null;
    try {
        o = JSON.parse(String(text || ""));
    } catch (e) {
        return out;
    }
    if (o === null || typeof o !== "object")
        return out;
    for (var k in o) {
        var v = o[k];
        if (v && typeof v === "object" && typeof v.full === "number" && v.full > 0 && typeof v.wrote === "number")
            out[k] = { full: Math.round(v.full), wrote: Math.round(v.wrote), level: v.level === DEEP ? DEEP : DIM };
    }
    return out;
}
function stateText(saved) {
    var o = {};
    for (var k in saved)
        o[k] = { full: saved[k].full, wrote: saved[k].wrote, level: saved[k].level };
    return JSON.stringify(o);
}
