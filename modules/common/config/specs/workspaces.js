.pragma library

// The spec of config/workspaces.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/workspaces.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    shown: ["list", [1, 2, 3, 4], ["int", undefined, 1, 20], { min: 1, max: 10 }],
    scope: ["word", "all", ["all", "screen"]]
};
