.pragma library

// The spec of config/screentime.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/screentime.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    dayStartHour: ["int", 4, 0, 23],
    weekStart: ["int", 1, 1, 7],
    sessionBreakMin: ["int", 5, 0, 1440],
    maxBackdateS: ["int", 900, 0, 86400],
    flushS: ["int", 300, 1, 86400],
    checkS: ["int", 60, 1, 86400],
    digest: ["bool", true],
    ignore: ["list", [], ["text", undefined]],
    aliases: ["map", {}, ["text", undefined]],
    names: ["map", {}, ["text", undefined]],
    terminals: ["list", ["kitty", "foot", "Alacritty", "com.mitchellh.ghostty", "org.wezfurlong.wezterm", "org.kde.konsole"], ["text", undefined]]
};
