.pragma library

// Each source's glyph (Material Design, the Symbols Nerd Font the card draws
// shell glyphs in; codepoints looked up by name in
// /usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf, md-<name>). A post carries
// its glyph as `icon`, which the card draws in the icon column when it is a
// single private-use code point (EntryIcon / NotifyGlyphs.isGlyph) -- the same
// glyphs the card's own table gives update, battery and stocks, plus the later
// sources' that table does not know.

var update = "\u{F06B0}";          // md-update
var battery = "\u{F0083}";         // md-battery_alert
var batteryCharged = "\u{F008A}";  // md-battery_charging_80
var stocks = "\u{F012A}";          // md-chart_line
var stocksUp = "\u{F0535}";        // md-trending_up
var stocksDown = "\u{F0533}";      // md-trending_down
var screenshot = "\u{F0E51}";      // md-monitor_screenshot
var trash = "\u{F0A7A}";           // md-trash_can_outline (an icon-only action)
var usb = "\u{F129E}";             // md-usb_flash_drive
var calendar = "\u{F00F0}";        // md-calendar_clock
var disk = "\u{F02CA}";            // md-harddisk
var units = "\u{F13CE}";           // md-cog_off
var thermal = "\u{F0E01}";         // md-thermometer_alert
