.pragma library

// Material Design glyphs of the Symbols Nerd Font the notifications module
// draws (codepoints looked up in /usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf
// by glyph name, md-<name>), in one place so a glyph is chosen once.

var family = "Symbols Nerd Font";

var bell = "\u{F009A}";
var bellSleep = "\u{F00A0}";      // toasts held back: do not disturb, fullscreen, sharing, locked
var pin = "\u{F0403}";
var pinOff = "\u{F0404}";
var trayDown = "\u{F0120}";       // file into the manager
var trash = "\u{F0A7A}";          // delete
var reply = "\u{F045A}";
var more = "\u{F01D8}";           // dots-horizontal: the overflow menu
var chevronDown = "\u{F0140}";
var magnify = "\u{F0349}";      // the query in place of the title

// A shell source's default glyph, by sourceId (a post may carry its own).
var sources = {
    clock: "\u{F051B}",           // timer-outline
    stocks: "\u{F012A}",          // chart-line
    launcher: "\u{F08C6}",        // application
    llm: "\u{F06A9}",             // robot
    battery: "\u{F0083}",         // battery-alert
    update: "\u{F06B0}",          // update
    network: "\u{F05A9}",         // wifi
    bluetooth: "\u{F00AF}",       // bluetooth
    auth: "\u{F033E}",            // lock
    notifications: "\u{F009A}"    // bell
};

// True when an appIcon string is a glyph rather than an icon name or path:
// one code point from a Private Use Area (BMP E000-F8FF, planes 15-16).
function isGlyph(s) {
    if (!s || s.length > 2)
        return false;
    const cp = s.codePointAt(0);
    return (cp >= 0xE000 && cp <= 0xF8FF) || cp >= 0xF0000;
}
