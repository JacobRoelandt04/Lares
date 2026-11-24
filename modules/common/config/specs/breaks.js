.pragma library

// The spec of config/breaks.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/breaks.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    enabled: ["bool", true],
    durationMin: ["num", 50, 1, 600],
    pauseMin: ["num", 5, 0.1, 120],
    idleGraceSec: ["num", 30, 1, 3600],
    rewindPower: ["num", 2, 0.25, 8],
    stepSec: ["num", 60, 1, 3600],
    stepEaseMs: ["num", 700, 0, 5000],
    hiddenMin: ["num", 10, 0, 540]
};
