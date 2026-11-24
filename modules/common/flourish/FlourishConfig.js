.pragma library

// =============================================================================
// FlourishConfig.js -- the random flourishes' settings (shell.jsonc `oled.flourishes`), the pool rule and the shuffle bag. Pure
// functions, no Qt: it loads under node.
//
//   "oled": { "enabled": true,        THE care's one switch (the pixel shift and these flourishes): see enabledOf
//             "flourishes": {
//       "idle": true,                 a flourish now and then while nobody has touched the machine for a minute
//       "active": true,               ... and, more rarely, while someone works
//       "idleEveryS": [120, 240],     the wait between two while idle, seconds: drawn evenly from [min, max] for each
//       "activeEveryS": [600, 1200],  ... while working
//       "glyphs": { "power": true, "power.hibernate": false, "bell": true }
//   } }
//
// THE POOL. Every flourish of the shell names itself: a GROUP (a bar module: "power", "idleReel", "update", "weather", "bell",
// "player", "silicon") and, in a group of several glyphs (a reel), the GLYPH ("power.sleep", "idleReel.mug"). `glyphs` switches them: a
// "group.glyph" key wins over its "group" key, and a flourish with neither key takes its own default -- DECORATIVE ones are in (a
// motion that means nothing: the reels, the archive, the weather icon), the ones that MEAN something stay event-only (the bell rings for a new
// notification, the disc spins for a new song, silicon's glyph moves for a profile change). A new flourish joins by naming itself:
// nothing here or in the scheduler lists the glyphs.
// =============================================================================

var DEFAULTS = { idle: true, active: true, idleEveryS: [120, 240], activeEveryS: [600, 1200] };
// the least and the most a wait may be, seconds
var MIN_S = 10;
var MAX_S = 86400;

// THE OLED CARE'S SWITCH: `oled.enabled` of shell.jsonc. On unless it is exactly false; anything else that is not a boolean is on and a
// problem. `raw`: the file's `oled` as written (anything). Returns { enabled, problem } (problem "" when none).
function enabledOf(raw) {
    if (raw === undefined || raw === null || typeof raw !== "object" || Array.isArray(raw) || raw.enabled === undefined)
        return { enabled: true, problem: "" };
    if (typeof raw.enabled === "boolean")
        return { enabled: raw.enabled, problem: "" };
    return { enabled: true, problem: "oled.enabled must be true or false, not " + JSON.stringify(raw.enabled) };
}

// `raw`: the file's `oled.flourishes` as written (anything). Returns { idle, active, idleEveryS, activeEveryS, glyphs, problems }:
// every value checked, a bad one replaced by its default and named in `problems` (shell.jsonc's own words).
function parse(raw) {
    var out = { idle: DEFAULTS.idle, active: DEFAULTS.active, idleEveryS: DEFAULTS.idleEveryS.slice(),
                activeEveryS: DEFAULTS.activeEveryS.slice(), glyphs: {}, problems: [] };
    if (raw === undefined || raw === null)
        return out;
    if (typeof raw !== "object" || Array.isArray(raw)) {
        out.problems.push("oled.flourishes must be an object");
        return out;
    }
    var bools = ["idle", "active"];
    for (var i = 0; i < bools.length; i++) {
        var b = bools[i];
        if (raw[b] === undefined)
            continue;
        if (typeof raw[b] === "boolean")
            out[b] = raw[b];
        else
            out.problems.push("oled.flourishes." + b + " must be true or false, not " + JSON.stringify(raw[b]));
    }
    var ranges = ["idleEveryS", "activeEveryS"];
    for (var j = 0; j < ranges.length; j++) {
        var r = ranges[j];
        if (raw[r] === undefined)
            continue;
        var v = raw[r];
        if (typeof v === "number" && isFinite(v))
            v = [v, v];
        if (!Array.isArray(v) || v.length !== 2 || typeof v[0] !== "number" || typeof v[1] !== "number" || !isFinite(v[0]) || !isFinite(v[1])) {
            out.problems.push("oled.flourishes." + r + " must be [min, max] in seconds, not " + JSON.stringify(raw[r]));
            continue;
        }
        var lo = Math.max(MIN_S, Math.min(MAX_S, Math.min(v[0], v[1])));
        var hi = Math.max(MIN_S, Math.min(MAX_S, Math.max(v[0], v[1])));
        out[r] = [lo, hi];
    }
    if (raw.glyphs !== undefined) {
        if (raw.glyphs === null || typeof raw.glyphs !== "object" || Array.isArray(raw.glyphs)) {
            out.problems.push("oled.flourishes.glyphs must be an object of true / false, not " + JSON.stringify(raw.glyphs));
        } else {
            var keys = Object.keys(raw.glyphs);
            for (var k = 0; k < keys.length; k++) {
                var g = raw.glyphs[keys[k]];
                // the network pill's group was `network` before aerial (round 10): an old key counts as `aerial` unless the file names aerial itself
                var key = keys[k].replace(/^network(?=$|\.)/, "aerial");
                if (typeof g === "boolean")
                    out.glyphs[key] = key === keys[k] || out.glyphs[key] === undefined ? g : out.glyphs[key];
                else
                    out.problems.push("oled.flourishes.glyphs." + keys[k] + " must be true or false, not " + JSON.stringify(g));
            }
        }
    }
    return out;
}

// The key a flourish is known by: "group" or "group.glyph" ("" for one that names no group: it never plays at random).
function keyOf(group, glyph) {
    if (!group)
        return "";
    return glyph ? group + "." + glyph : group;
}

// Is the flourish in the pool: its "group.glyph" key, else its "group" key, else its own default (decorative or not).
function enabled(cfg, group, glyph, decorative) {
    if (!group)
        return false;
    var g = cfg && cfg.glyphs ? cfg.glyphs : {};
    var full = keyOf(group, glyph);
    if (glyph && Object.prototype.hasOwnProperty.call(g, full))
        return g[full] === true;
    if (Object.prototype.hasOwnProperty.call(g, group))
        return g[group] === true;
    return decorative === true;
}

// The wait before the next one, ms: even over [min, max] seconds of the mode's range. `u` 0..1 (Math.random() in the shell).
function waitMs(cfg, idle, u) {
    var r = idle ? cfg.idleEveryS : cfg.activeEveryS;
    return Math.round((r[0] + (r[1] - r[0]) * u) * 1000);
}

// A shuffled copy of `keys` (Fisher-Yates on `rnd`, 0..1), never starting with `last` when there is another to start with.
function shuffle(keys, last, rnd) {
    var a = keys.slice();
    for (var i = a.length - 1; i > 0; i--) {
        var j = Math.floor(rnd() * (i + 1));
        if (j > i)
            j = i;
        var t = a[i];
        a[i] = a[j];
        a[j] = t;
    }
    if (a.length > 1 && a[0] === last) {
        var s = 1 + Math.floor(rnd() * (a.length - 1));
        if (s >= a.length)
            s = a.length - 1;
        var u = a[0];
        a[0] = a[s];
        a[s] = u;
    }
    return a;
}

// The signature of a set of keys (order-free): a bag made for another set is refilled.
function signature(keys) {
    return keys.slice().sort().join("|");
}
