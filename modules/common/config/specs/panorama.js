.pragma library

// The spec of config/panorama.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/panorama.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    keepSeconds: ["int", 15, 5, 60],
    identifyDelayMs: ["int", 250, 0, 2000],
    toasts: { newDisplay: ["bool", true], unplug: ["bool", true] },
    openTab: ["word", "situation", ["situation", "displays", "presets", "last"]],
    cast: ["bool", false],
    castQuality: {
        res: ["text", "1920x1080", { re: "^\\d{3,5}x\\d{3,5}$", like: "1920x1080" }],
        fps: ["int", 30, 10, 60],
        bitrate: ["text", "8M", { re: "^\\d+[MK]$", like: "8M" }],
        audio: ["bool", true]
    },
    portLabels: ["map", {}, ["text", undefined], { keys: ["laptop", "hdmi", "usbc", "displaylink", "dvi", "vga", "virtual", "cast", "other"] }]
};
