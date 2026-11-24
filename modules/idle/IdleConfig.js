.pragma library

// =============================================================================
// IdleConfig.js -- idle.jsonc (IdleConfig.qml reads the file), as the soft idle engine reads it.
//
//   {
//       "dimAfter": 120,     soft: seconds without input until the laptop panel dims; 0 = never
//       "deepAfter": 180,    seconds without input until the deeper step; 0 = never
//       "dimLevel": 0.7,     how bright the dimmed panel LOOKS, as a fraction of how bright it looked: on the OSD's own brightness curve
//                            (modules/osd/data/OsdKinds.js, gamma 2: 0.7 is about half the raw value), 0.01 .. 1
//       "deepLevel": 0.5,    the same for the deeper step (about a quarter of the raw value); never above dimLevel.
//                            SOFT NEVER GOES DARK: both steps are never below raw 1 and never above where the panel is; a panel
//                            you set to 0 yourself stays at 0 (soft never raises it)
//       "ddcDim": null,      dim the EXTERNAL displays over DDC too (DdcDim), at the same times: true | false; absent: only on a machine with
//                            no laptop panel (a desktop)
//       "ddcDimLevel": 0.35, the dimmed display's own brightness figure as a share of what it was, 0 .. 1 (an LCD at 0 is still lit)
//       "ddcDeepLevel": 0,   the same for the deeper step; never above ddcDimLevel
//       "awayAfter": 300,    with an external output connected: seconds with the focus on another output until the laptop
//                            panel dims (to dimLevel); 0 = never
//       "panel": "eDP",      the laptop panel: an output whose name starts with this
//       "script": "~/.config/hypr/scripts/brightness.sh",    the user's own brightness script: soft gives the brightness back with
//                                                            its --resume
//       "stateFile": "/tmp/idle_backlight_value",            where that script keeps the brightness it saved: soft saves the full
//                                                            raw value there before it dims, so --resume restores it exactly
//       "brightnessctl": "brightnessctl"                     the program soft reads and sets the brightness with
//       "zeroIsBlack": {"nvidia_0": false},                  where raw 0 turns the panel black, per backlight device (the shell's table: the
//                                                            raw intel_backlight yes, nvidia_0 no); where it does not, "dark" is the lowest
//                                                            value AND a black veil over the panel (lid closed, sleep fade)
//       "lidRestore": 2.5,   hard idle with the lid closed: the seconds the panel takes to come back to its brightness when the lid
//                            opens (it climbs the brightness keys' perceived curve, evenly in how bright it looks); 0 = at once
//       "sleepFade": true,   the screen falls asleep before the machine does and wakes after it (modules/idle/sleep, SLEEP.md): once the
//                            lock's veil has appeared the panel dims to 0 along the same curve while the sleep veil closes, and only
//                            then may the machine sleep; it climbs back at the same pace when it wakes (an unlock skips the rest)
//       "sleepFadeTime": 1.5,     the seconds of that fall, and of the climb back, 0.3 .. 3 (the fall is cut to fit logind's wait)
//       "sleepFallTime": 1.5,     the fall alone (the screen going dark as the machine sleeps), same range; absent = sleepFadeTime
//       "sleepClimbTime": 1.5,    the climb alone (the screen coming back after the resume), same range; absent = sleepFadeTime
//       "sleepFadeStrength": 1,   the sleep veil's dream -- defocus, colour split, the picture sinking -- 0 .. 1; 0 = no veil at all
//       "contentIgnore": [...]    programs whose request to keep the screen on is NOT content (ContentHold): exact names, any case, matched against a
//                                 ScreenSaver D-Bus holder's application name, a window's class and a logind inhibitor's `who`. The default list is
//                                 FreeRDP's SDL client (it inhibits for its whole life) and KDE Connect's daemon (its "Inhibit screensaver"
//                                 plugin holds for as long as a phone is CONNECTED -- for a phone always in reach, for ever: the user's auto
//                                 mode stuck on "org.kdeconnect.daemon is playing video", 2026-11-19); [] ignores nothing. Your list replaces the default
//   }
//
// The seconds are hypridle's own unit, and the defaults are the steps of the user's hypridle.conf (120 / 180). Every key is
// optional: a missing key, or a value of the wrong kind, takes the default; a number out of range is clamped (1 s .. a day; 0 is
// "off" for the three timers). Nothing here touches the machine -- the engine (SoftIdle.qml) does, from what this returns.
// =============================================================================

var DAY = 86400;

function defaults(home) {
    var h = typeof home === "string" ? home : "";
    return {
        dimAfterS: 120,
        deepAfterS: 180,
        dimLevel: 0.7,
        deepLevel: 0.5,
        ddcDim: null,
        ddcDimLevel: 0.35,
        ddcDeepLevel: 0,
        awayAfterS: 300,
        panel: "eDP",
        script: h + "/.config/hypr/scripts/brightness.sh",
        stateFile: "/tmp/idle_backlight_value",
        brightnessctl: "brightnessctl",
        lidRestoreS: 2.5,
        sleepFade: true,
        sleepFadeTimeS: 1.5,
        sleepFallTimeS: 1.5,
        sleepClimbTimeS: 1.5,
        sleepFadeStrength: 1,
        contentIgnore: ["sdl-freerdp3", "sdl-freerdp", "com.freerdp.client.sdl3", "com.freerdp.client.sdl", "org.kdeconnect.daemon"]
    };
}

// A list of names: the strings in it, trimmed, empty ones dropped; a value of the wrong kind is the default (an empty list is a list).
function _names(v, def) {
    if (!(v instanceof Array))
        return def;
    var out = [];
    for (var i = 0; i < v.length; i++) {
        if (typeof v[i] === "string" && v[i].trim() !== "")
            out.push(v[i].trim());
    }
    return out;
}

function _seconds(v, def) {
    if (typeof v !== "number" || !isFinite(v))
        return def;
    if (v <= 0)
        return 0;
    return Math.min(DAY, Math.max(1, v));
}

// A level: a fraction of how bright the panel looked, 0.01 .. 1 (1 is "no dimming"); a value of the wrong kind is the default.
function _level(v, def) {
    if (typeof v !== "number" || !isFinite(v))
        return def;
    return Math.min(1, Math.max(0.01, v));
}

// A length of time in seconds, 0 .. 30 (0 is "at once"); a value of the wrong kind is the default.
function _span(v, def) {
    if (typeof v !== "number" || !isFinite(v))
        return def;
    return Math.min(30, Math.max(0, v));
}

// A number in lo .. hi; a value of the wrong kind is the default.
function _range(v, def, lo, hi) {
    if (typeof v !== "number" || !isFinite(v))
        return def;
    return Math.min(hi, Math.max(lo, v));
}

// { "<device>": true | false }: the entries of the right kind (idle.jsonc `zeroIsBlack`: where raw 0 turns that backlight's panel black)
function _flags(v) {
    var out = {};
    if (v === null || typeof v !== "object" || Array.isArray(v))
        return out;
    for (var k in v)
        if (typeof v[k] === "boolean")
            out[k] = v[k];
    return out;
}

function _text(v, def) {
    return typeof v === "string" && v.trim() !== "" ? v.trim() : def;
}

// "~/x" -> "<home>/x"
function _expand(p, home) {
    if (p === "~")
        return home;
    if (p.indexOf("~/") === 0)
        return home + p.substring(1);
    return p;
}

// raw: the parsed idle.jsonc (anything); home: the user's home directory. -> the settings the engine runs on.
function parse(raw, home) {
    var h = typeof home === "string" ? home : "";
    var d = defaults(h);
    var o = raw !== null && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
    var dim = _level(o.dimLevel, d.dimLevel);
    var ddcDim = _range(o.ddcDimLevel, d.ddcDimLevel, 0, 1);
    // the one time (the key that was there first) is what each way takes when it has no key of its own
    var fade = _range(o.sleepFadeTime, d.sleepFadeTimeS, 0.3, 3);
    return {
        dimAfterS: _seconds(o.dimAfter, d.dimAfterS),
        deepAfterS: _seconds(o.deepAfter, d.deepAfterS),
        dimLevel: dim,
        // the deeper step is never brighter than the dimmed one
        deepLevel: Math.min(dim, _level(o.deepLevel, d.deepLevel)),
        ddcDim: typeof o.ddcDim === "boolean" ? o.ddcDim : d.ddcDim,
        ddcDimLevel: ddcDim,
        ddcDeepLevel: Math.min(ddcDim, _range(o.ddcDeepLevel, d.ddcDeepLevel, 0, 1)),
        awayAfterS: _seconds(o.awayAfter, d.awayAfterS),
        panel: _text(o.panel, d.panel),
        script: _expand(_text(o.script, d.script), h),
        stateFile: _expand(_text(o.stateFile, d.stateFile), h),
        brightnessctl: _expand(_text(o.brightnessctl, d.brightnessctl), h),
        zeroIsBlack: _flags(o.zeroIsBlack),
        lidRestoreS: _span(o.lidRestore, d.lidRestoreS),
        sleepFade: typeof o.sleepFade === "boolean" ? o.sleepFade : d.sleepFade,
        sleepFadeTimeS: fade,
        sleepFallTimeS: _range(o.sleepFallTime, fade, 0.3, 3),
        sleepClimbTimeS: _range(o.sleepClimbTime, fade, 0.3, 3),
        sleepFadeStrength: _range(o.sleepFadeStrength, d.sleepFadeStrength, 0, 1),
        contentIgnore: _names(o.contentIgnore, d.contentIgnore)
    };
}
