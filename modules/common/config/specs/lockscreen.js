.pragma library

// The spec of config/lockscreen.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/lockscreen.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var VEILS = ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"];
var SPEC = {
    veil: ["word", "random", ["random"].concat(VEILS)],
    veils: ["list", VEILS, ["word", undefined, VEILS]],
    idleSeconds: ["num", 30, 0.1, null],
    fps: ["num", 60, 1, null],
    batteryFpsRatio: ["num", 0.5, 0, 1],
    blurInMs: ["num", 250, 1, null],
    veilRiseMs: ["num", 1200, 0, null],
    unlockHoldMs: ["num", 600, 0, null],
    unlockMs: ["num", 400, 0, null],
    face: ["word", "auto", ["auto", "on", "off"]],
    keyringPassword: ["bool", true],
    faceRearmCooldownMs: ["num", 5000, 0, null],
    fallbackDelayMs: ["num", 2000, 0, null],
    bootFallbackDelayMs: ["num", 30000, 0, null],
    handoverGraceMs: ["num", 3000, 0, null],
    greetingName: ["text", ""],
    popupBand: ["list", ["battery", "weather", "updates", "screen"], ["word", undefined, ["battery", "weather", "updates", "screen"]]],
    popupFoot: ["list", ["music", "wiki"], ["word", undefined, ["music", "wiki"]]],
    greeting: ["word", "boot", ["boot", "always", "never"]],
    faceWhen: ["list", ["boot", "resume", "return", "ask"], ["word", undefined, ["boot", "resume", "return", "ask"]]],
    lockedControls: ["list", ["idle", "volume", "player"], ["word", undefined, ["idle", "volume", "player"]]],
    obscure: ["list", [], { "class": ["text", undefined], title: ["text", undefined] }, { sample: true }]
};
