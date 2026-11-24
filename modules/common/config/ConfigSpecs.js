.pragma library
.import "specs/aerial.js" as Aerial
.import "specs/airplay.js" as Airplay
.import "specs/audio.js" as Audio
.import "specs/breaks.js" as Breaks
.import "specs/bridge.js" as Bridge
.import "specs/calendars.js" as Calendars
.import "specs/clipboard.js" as Clipboard
.import "specs/clock.js" as Clock
.import "specs/idle.js" as Idle
.import "specs/launcher.js" as Launcher
.import "specs/llm.js" as Llm
.import "specs/locale.js" as Locale
.import "specs/lockscreen.js" as Lockscreen
.import "specs/notes.js" as Notes
.import "specs/notifications.js" as Notifications
.import "specs/osd.js" as Osd
.import "specs/panorama.js" as Panorama
.import "specs/picker.js" as Picker
.import "specs/player.js" as Player
.import "specs/power.js" as Power
.import "specs/privacy.js" as Privacy
.import "specs/screentime.js" as Screentime
.import "specs/session.js" as Session
.import "specs/shell.js" as Shell
.import "specs/silicon.js" as Silicon
.import "specs/snapshots.js" as Snapshots
.import "specs/stocks.js" as Stocks
.import "specs/system_update.js" as SystemUpdate
.import "specs/weather.js" as Weather
.import "specs/wiki.js" as Wiki
.import "specs/windowtray.js" as Windowtray
.import "specs/workspaces.js" as Workspaces

// ConfigSpecs.js -- every spec by its file's name (ConfigCheck.js has the grammar). A new spec is one import and one line here; the gate
// tools/dev/config_spec_check.js fails one that is missing.

var SPECS = {
    "aerial": Aerial.SPEC,
    "airplay": Airplay.SPEC,
    "audio": Audio.SPEC,
    "breaks": Breaks.SPEC,
    "bridge": Bridge.SPEC,
    "calendars": Calendars.SPEC,
    "clipboard": Clipboard.SPEC,
    "clock": Clock.SPEC,
    "idle": Idle.SPEC,
    "launcher": Launcher.SPEC,
    "llm": Llm.SPEC,
    "locale": Locale.SPEC,
    "lockscreen": Lockscreen.SPEC,
    "notes": Notes.SPEC,
    "notifications": Notifications.SPEC,
    "osd": Osd.SPEC,
    "panorama": Panorama.SPEC,
    "picker": Picker.SPEC,
    "player": Player.SPEC,
    "power": Power.SPEC,
    "privacy": Privacy.SPEC,
    "screentime": Screentime.SPEC,
    "session": Session.SPEC,
    "shell": Shell.SPEC,
    "silicon": Silicon.SPEC,
    "snapshots": Snapshots.SPEC,
    "stocks": Stocks.SPEC,
    "system_update": SystemUpdate.SPEC,
    "weather": Weather.SPEC,
    "wiki": Wiki.SPEC,
    "windowtray": Windowtray.SPEC,
    "workspaces": Workspaces.SPEC
};

function specOf(name) {
    return Object.prototype.hasOwnProperty.call(SPECS, name) ? SPECS[name] : null;
}

function names() {
    return Object.keys(SPECS);
}
