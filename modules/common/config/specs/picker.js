.pragma library

// The spec of config/picker.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/picker.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var TABS = ["emoji", "symbols", "nerd"];
var SPEC = {
    tabs: ["list", TABS, ["word", undefined, TABS], { min: 1 }],
    openTab: ["word", "emoji", TABS.concat(["last"])],
    nerdPick: ["word", "glyph", ["glyph", "name"]],
    recents: ["bool", true],
    pick: ["word", "paste", ["paste", "copy"]]
};
