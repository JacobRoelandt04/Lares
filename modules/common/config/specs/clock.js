.pragma library

// The spec of config/clock.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/clock.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SOUND = d => ["path", d];
var SPEC = {
    open: ["word", "auto", ["auto", "calendar", "timers", "last"]],
    seconds: ["word", "hover", ["hover", "always", "never"]],
    timers: {
        snoozeMin: ["num", 9, 1, 120],
        sounds: { countdown: SOUND("alarm-clock-elapsed.oga"), pomodoro: SOUND("complete.oga"), alarm: SOUND("alarm-clock-elapsed.oga") },
        volume: ["num", -1, -1, 1],
        ringSec: ["int", 60, 1, 3600],
        soundUnderDnd: ["bool", true],
        countdownMin: ["num", 5, 0.1, 1440, { start: true }],
        focusMin: ["num", 25, 1, 240, { start: true }],
        shortMin: ["num", 5, 1, 120, { start: true }],
        longMin: ["num", 30, 1, 240, { start: true }],
        missedHours: ["num", 12, 0, 168]
    },
    look: { secondarySide: ["word", "end", ["start", "end", "far"]] }
};
