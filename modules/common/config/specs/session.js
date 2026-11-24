.pragma library

// The spec of config/session.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/session.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var AFTER = ["ask", "ask-critical", "auto", "off"];
var SPEC = {
    enabled: ["bool", false],
    afterLogout: ["word", "ask", AFTER],
    afterReboot: ["word", "ask", AFTER],
    afterCrash: ["word", "ask", ["ask", "off"]],
    maxAgeHours: ["num", 168, 0, null],
    run: ["list", [], ["text", undefined]],
    type: ["list", [], ["text", undefined]],
    apps: ["map", {}, {
        launch: ["argv", undefined],
        selfRestore: ["bool", undefined],
        slow: ["bool", undefined],
        skip: ["bool", undefined],
        why: ["text", undefined],
        folders: ["any", undefined]
    }],
    skipClasses: ["list", [], ["text", undefined]],
    terminals: ["list", undefined, ["text", undefined], { hidden: true }],
    claude: ["word", "resume", ["resume", "fresh", "type"]],
    presets: { claude: ["word", "fresh", ["fresh", "resume"]], confirmReplace: ["bool", true] },
    keep: ["int", 5, 1, 100],
    resultToast: ["word", "always", ["always", "needs", "off"]],
    windowTimeoutMs: ["int", 10000, 0, null],
    appTimeoutMs: ["int", 30000, 0, null],
    closeTimeoutMs: ["int", 8000, 0, null]
};
