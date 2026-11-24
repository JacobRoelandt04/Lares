.pragma library

// =============================================================================
// InputConfig.js -- shell.jsonc "input" (the mouse: WheelHub, SideSwipe, ScrollFeel), parsed. Every key optional; a value of the wrong kind takes the
// default and is said once (ShellConfig), a number out of its range is clamped.
//
//   "input": {
//       "sideButtons": "both",    which of a mouse's side buttons swipe while held: "both" | "back" | "forward" | "off"
//       "sideClick": true,        a click of one goes one step back / on
//       "sideGain": 1,            how far a swipe goes per px of the hand, 0.2 .. 5
//       "sidePointer": "hold",    the pointer during a swipe: "hold" (hidden, stays where it was) | "free" (goes with the mouse)
//       "notchPx": 120,           how far a list scrolls per wheel notch, px, 20 .. 600
//       "notchMs": 140            how long that takes to ease out, ms, 0 .. 600 (0 = at once)
//   }
// =============================================================================

var DEFAULTS = { sideButtons: "both", sideClick: true, sideGain: 1, sidePointer: "hold", notchPx: 120, notchMs: 140 };
var WORDS = { sideButtons: ["both", "back", "forward", "off"], sidePointer: ["hold", "free"] };
var RANGES = { sideGain: [0.2, 5], notchPx: [20, 600], notchMs: [0, 600] };

// -> { cfg, problems: [words] }
function parse(o) {
    var cfg = Object.assign({}, DEFAULTS), problems = [];
    if (o === undefined || o === null)
        return { cfg: cfg, problems: problems };
    if (typeof o !== "object" || o instanceof Array)
        return { cfg: cfg, problems: ["\"input\" is not an object"] };
    for (var k in o) {
        var v = o[k];
        if (WORDS[k] !== undefined) {
            if (WORDS[k].indexOf(v) >= 0)
                cfg[k] = v;
            else
                problems.push("\"input." + k + "\" is " + JSON.stringify(v) + ", not one of " + WORDS[k].join(", "));
        } else if (RANGES[k] !== undefined) {
            if (typeof v === "number" && isFinite(v))
                cfg[k] = Math.max(RANGES[k][0], Math.min(RANGES[k][1], v));
            else
                problems.push("\"input." + k + "\" is " + JSON.stringify(v) + ", not a number");
        } else if (k === "sideClick") {
            if (typeof v === "boolean")
                cfg[k] = v;
            else
                problems.push("\"input.sideClick\" is " + JSON.stringify(v) + ", not true or false");
        } else {
            problems.push("\"input." + k + "\" is not a key");
        }
    }
    return { cfg: cfg, problems: problems };
}
