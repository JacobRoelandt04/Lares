.pragma library

// The spec of config/snapshots.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/snapshots.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    enabled: ["bool", true],
    rule: {
        minPackages: ["int", 40, 1, 9999],
        critical: ["list", undefined, ["text", undefined]],
        criticalAlso: ["list", [], ["text", undefined]]
    },
    keep: ["int", 5, 1, 50],
    minFreeGB: ["num", 10, 1, 500],
    maxAddedGB: ["num", 15, 1, 500],
    maxMinutes: ["num", 15, 1, 120],
    prime: ["bool", true],
    exclude: ["list", [], ["path", undefined]],
    onFail: ["word", "stop", ["stop", "continue"]],
    offsite: {
        enabled: ["bool", false],
        folder: ["text", "/my-files/Lares snapshots", { re: "^/my-files/.+", like: "/my-files/Lares snapshots" }],
        machine: ["text", ""],
        onBattery: ["bool", false],
        metered: ["bool", false],
        everyHours: ["num", 24, 1, 720],
        afterUpdate: ["bool", true]
    }
};
