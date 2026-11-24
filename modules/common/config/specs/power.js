.pragma library

// The spec of config/power.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/power.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var IDS = ["sleep", "poweroff", "reboot", "hibernate", "logout", "lock"];
var SPEC = {
    items: ["list", IDS, ["word", undefined, IDS], { start: true }],
    rest: ["word", "lock", IDS, { start: true }],
    commands: ["map", {}, ["argv", undefined], { keys: ["sleep", "poweroff", "reboot", "hibernate", "logout"] }],
    waitForFlourish: ["bool", true],
    leftClickFires: ["bool", false]
};
