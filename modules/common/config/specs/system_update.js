.pragma library

// The spec of config/system_update.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/system_update.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    icon: {
        accentAt: ["int", 1, 1, null],
        warnAt: ["int", 30, 1, null],
        errorAt: ["int", 150, 1, null]
    },
    check: {
        everyMin: ["num", 15, 0, 1440],
        staleMin: ["num", 5, 0, 1440],
        official: ["bool", true],
        aur: ["bool", true],
        flatpak: ["bool", true]
    },
    view: ["word", "quiet", ["quiet", "normal", "verbose", "last"]],
    list: {
        groupMin: ["either", 3, ["int", undefined, 0, 0], ["int", undefined, 2, 20]],
        open: ["list", [], ["text", undefined]]
    },
    run: { flags: ["list", ["--sudoloop"], ["text", undefined, { re: "^--?[A-Za-z][A-Za-z0-9-]*(=[A-Za-z0-9_.,-]+)?$", like: "--devel" }]] }
};
