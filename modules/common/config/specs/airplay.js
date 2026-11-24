.pragma library

// The spec of config/airplay.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/airplay.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    powersave: ["bool", true],
    graceSec: ["num", 60, 0, 3600],
    delay: ["either", "auto", ["word", "auto", ["auto"]], ["num", undefined, 0, 60000]],
    delayExtraMs: ["num", 0, -60000, 60000]
};
