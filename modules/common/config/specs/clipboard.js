.pragma library

// The spec of config/clipboard.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/clipboard.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var KEYS = { re: "^[A-Z ]*,[^,]+$", like: "CTRL SHIFT,V" };
var SPEC = {
    maxItems: ["int", 1000, 0, null],
    maxAgeDays: ["num", 30, 0, null],
    maxImageMB: ["num", 25, 0, null],
    maxTotalMB: ["num", 500, 0, null],
    thumbPx: ["int", 320, 1, null],
    thumbsMax: ["int", 48, 0, null],
    textIndexKB: ["num", 16, 1, null],
    secrets: {
        ttlS: ["num", 120, 1, null],
        dropOnLock: ["bool", true],
        dropOnSourceClear: ["bool", true],
        heuristic: ["bool", true],
        threshold: ["num", 0.5, 0, null]
    },
    ignoreApps: ["list", [], ["text", undefined]],
    sealApps: ["list", ["Proton Pass", "proton-pass"], ["text", undefined]],
    pasteKeys: {
        "default": ["text", "CTRL,V", KEYS],
        classes: ["map", {
            "kitty": "CTRL SHIFT,V", "foot": "CTRL SHIFT,V", "Alacritty": "CTRL SHIFT,V", "org.wezfurlong.wezterm": "CTRL SHIFT,V",
            "com.mitchellh.ghostty": "CTRL SHIFT,V"
        }, ["text", undefined, KEYS]]
    },
    reofferOnClose: ["bool", true],
    openOverFullscreen: ["bool", true],
    pasteDelayMs: ["int", 120, 0, null],
    enter: ["word", "paste", ["paste", "copy"]],
    joiner: ["text", "\n"],
    copyOnClose: ["bool", true],
    restoreAtStart: ["bool", true],
    pinnedFirst: ["bool", true],
    openOn: ["word", "all", ["all", "text", "image", "link", "pinned"]],
    undoSec: ["num", 8, 1, 120]
};
