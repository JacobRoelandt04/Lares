.pragma library

// The spec of config/wiki.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/wiki.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    askAt: ["int", 5, 0, 1000],
    batchSize: ["int", 30, 1, 200],
    rolloverHour: ["int", 4, 0, 12],
    seenMs: ["int", 5000, 0, 600000],
    dwellMs: ["int", 15000, 1000, 3600000],
    quickNextMs: ["int", 4000, 0, 600000],
    ollamaUrl: ["text", "http://localhost:11434", { re: "^https?://", like: "http://localhost:11434" }],
    jev: ["bool", true],
    jevKey: ["text", "", { secret: true }],           // the Jev judge's API key: read by tools/wiki only (lib/env.py), never by the shell's QML
    notesRoot: ["path", "~/Documents/Notes"],
    notesFolder: ["text", "Wiki", { re: "^(?!\\.{1,2}$)[^/]+$", like: "Wiki" }],
    show: { calendar: ["bool", true], notifications: ["bool", true], lock: ["bool", true], launcher: ["bool", true] },
    families: ["map", {}, ["bool", undefined], { keys: ["history", "geography", "people", "visual-arts", "performing-arts", "literature", "philosophy", "society",
        "physical-sciences", "life-sciences", "earth", "technology", "everyday", "arch-installed", "arch-discovery", "wikipedia-cs", "arch-tips", "other-wikis"] }],
    askAgainHours: ["num", 24, 1, 720],
    jevCapUsd: ["num", 0.04, 0, 10],
    models: { write: ["text", ""], judge: ["text", ""] },
    sources: {
        wikipedia: ["bool", true],
        arch: ["bool", true],
        archTips: ["bool", true],
        gentoo: ["bool", true],
        kernel: ["bool", true],
        freedesktop: ["bool", true]
    }
};
