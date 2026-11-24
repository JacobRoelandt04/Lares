.pragma library

// The spec of config/idle.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/idle.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var MODE = d => ["word", d, ["off", "soft", "normal", "hard"]];
var SPEC = {
    dimAfter: ["num", 120, 0, 86400],
    deepAfter: ["num", 180, 0, 86400],
    dimLevel: ["num", 0.7, 0.01, 1],
    deepLevel: ["num", 0.5, 0.01, 1],
    ddcDim: ["bool", null],
    ddcDimLevel: ["num", 0.35, 0, 1],
    ddcDeepLevel: ["num", 0, 0, 1],
    awayAfter: ["num", 300, 0, 86400],
    panel: ["text", "eDP"],
    script: ["path", "~/.config/hypr/scripts/brightness.sh"],
    stateFile: ["path", "/tmp/idle_backlight_value"],
    brightnessctl: ["text", "brightnessctl"],
    zeroIsBlack: ["map", {}, ["bool", undefined]],
    lidRestore: ["num", 2.5, 0, 30],
    sleepFade: ["bool", true],
    sleepFadeTime: ["num", 1.5, 0.3, 3],
    sleepFallTime: ["num", undefined, 0.3, 3],
    sleepClimbTime: ["num", undefined, 0.3, 3],
    sleepFadeStrength: ["num", 1, 0, 1],
    auto: {
        content: MODE("normal"), share: MODE("normal"), update: MODE("soft"), llm: MODE("soft"), timer: MODE("soft"), wiki: MODE("soft"), bridge: MODE("soft"),
        download: MODE("soft"), pkg: MODE("soft"), music: MODE("soft")
    },
    items: ["list", ["off", "soft", "normal", "hard"], ["word", undefined, ["off", "soft", "normal", "hard"]], { start: true }],
    start: ["word", "off", ["off", "soft", "normal", "hard", "last"]],
    download: { minMinutes: ["num", 2, 0, 120], folder: ["path", ""] },
    packages: { minMinutes: ["num", 2, 0, 120] },
    autoTell: ["word", "cinematic", ["cinematic", "quiet"]],
    contentIgnore: ["list", ["sdl-freerdp3", "sdl-freerdp", "com.freerdp.client.sdl3", "com.freerdp.client.sdl", "org.kdeconnect.daemon"], ["text", undefined]]
};
