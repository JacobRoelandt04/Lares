.pragma library

// The spec of config/launcher.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/launcher.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var KINDS = ["colour", "resolution", "percent", "currency", "base", "zone", "date", "timearith", "unit", "math"];
var SPEC = {
    columns: ["int", 2, 1, 8],
    rows: ["int", 9, 1, 40],
    scriptsRoot: ["path", ""],
    flourish: ["word", "", ["", "honey", "syrup", "dew", "classic", "off"]],
    answers: {
        enabled: ["bool", true],
        kinds: ["list", KINDS, ["word", undefined, KINDS]],
        takesEnter: ["bool", true],
        homeCurrency: ["text", "EUR", { re: "^[A-Z]{3}$", like: "EUR" }],
        currencies: ["list", ["USD", "EUR", "GBP", "JPY", "CHF"], ["text", undefined, { re: "^[A-Z]{3}$", like: "USD" }]],
        history: ["int", 20, 0, 200]
    },
    keysFree: ["list", [{ "class": "kitty", title: "yazi" }], { "class": ["text", undefined], title: ["text", undefined] }],
    clickOutsideCloses: ["bool", false],
    keepQuerySec: ["num", 0, 0, 3600],
    hidden: ["list", [], ["text", undefined]]
};
