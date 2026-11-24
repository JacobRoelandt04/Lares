.pragma library

// The spec of config/notes.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/notes.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    root: ["path", "~/Documents/Notes", { start: true }],
    openAt: ["word", "last", ["last", "root", "new"]],
    escape: ["word", "close", ["close", "back"]],
    confirmDelete: ["bool", true],
    newName: ["text", "Untitled", { re: "^[^/]+$", like: "Untitled" }],
    linkClick: ["word", "ctrl", ["ctrl", "click"]]
};
