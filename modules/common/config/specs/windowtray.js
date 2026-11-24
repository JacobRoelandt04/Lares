.pragma library

// The spec of config/windowtray.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/windowtray.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    follow: ["word", "screen", ["screen", "focus"]],
    stripSuffix: ["bool", true],
    rewrites: ["list", [], { re: ["text", undefined, { req: true }], to: ["text", undefined, { req: true }] }],
    terminalClasses: ["list", ["kitty", "Alacritty", "foot", "footclient", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "org.kde.konsole", "konsole", "XTerm",
        "URxvt", "st-256color", "terminator", "com.gexperts.Tilix", "gnome-terminal-server", "org.gnome.Terminal", "org.gnome.Ptyxis", "xfce4-terminal", "rio",
        "cool-retro-term"], ["text", undefined]],
    terminalTitleMs: ["int", 150, 0, 2000],
    trayOrder: ["list", [], ["text", undefined]],
    trayHide: ["list", [], ["text", undefined]],
    trayRename: ["map", {}, ["text", undefined]],
    openOn: ["word", "hover", ["hover", "click"]],
    closeOnLeave: ["bool", true],
    closeOnActivate: ["bool", true],
    trayPassive: ["word", "faint", ["faint", "hide"]],
    attention: ["word", "peek", ["peek", "off"]],
    desktopText: ["text", "Desktop"],
    trayIconMode: ["word", "ink", ["ink", "colour"]]
};
