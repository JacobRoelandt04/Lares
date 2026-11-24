pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// CalendarConfig.qml
//
// Loads / hot-reloads the user's calendar feed list from a JSON file.
// Default path: $XDG_CONFIG_HOME/quickshell/config/calendars.jsonc
//                 (falls back to $HOME/.config/quickshell/config/calendars.jsonc)
//
// Expected file shape:
//
//   {
//     "pollIntervalMs": 900000,           // optional — default 15min
//     "weekStart": 1,                     // optional — 0=Sun, 1=Mon (default)
//     "calendars": [
//       {
//         "id":    "personal",
//         "name":  "Personal",
//         "color": "#1E66F5",
//         "url":   "https://calendar.proton.me/.../calendar.ics?...",
//         "pollIntervalMs": 600000,       // optional override per-feed
//         "remind": true                  // optional: false, or minutes before (1 .. 1440)
//       },
//       ...
//     ]
//   }
//
// If the file is missing (or goes) or is unparseable, `entries` is [] and `available` is
// false — the test harness can then fall back to MockCalendarData. A key the file does not
// give (or gives out of range) is at its default: a hot reload that removed one puts it back.
// A feed with no colour is "" (the reader draws it in the theme's text colour).
// =============================================================================
Item {
    id: root

    // --- Configurable paths ---
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME")
            || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/calendars.jsonc"

    // --- Public state ---
    readonly property bool available: entries.length > 0
    property var entries: []                 // [{id, name, color, url, pollIntervalMs, remind}]
    readonly property int defaultPollIntervalMs: 900000      // 15 min
    readonly property int defaultWeekStart: 1                // Monday
    property int pollIntervalMs: root.defaultPollIntervalMs
    property int weekStart: root.defaultWeekStart
    property string lastError: ""

    signal configChanged()

    ConfigFile {
        id: fv
        path: root.configPath
        onLoaded: root._parse(fv.text())
        onLoadFailed: root._missing()
    }

    function reload() {
        fv.reload();
    }

    // A poll interval from the file: a positive number, at least a minute (a 1 ms poll would hammer the feed's server); anything
    // else is 0, "not given", and the next level's value applies.
    function _poll(v) {
        return typeof v === "number" && v > 0 ? Math.max(60000, Math.round(v)) : 0;
    }

    // `remind`: true | false | minutes before, 1 .. 1440; anything else is true (as notifications.jsonc's leadMin says).
    function _remind(v) {
        return v === false || (typeof v === "number" && v >= 1 && v <= 1440) ? v : true;
    }

    // No file (or it was deleted): no feeds, every default, and no error -- a missing file is not one.
    function _missing() {
        root.entries = [];
        root.pollIntervalMs = root.defaultPollIntervalMs;
        root.weekStart = root.defaultWeekStart;
        root.lastError = "";
        root.configChanged();
    }

    function _parse(txt) {
        if (!txt || txt.length === 0) {
            root.entries = [];
            root.pollIntervalMs = root.defaultPollIntervalMs;
            root.weekStart = root.defaultWeekStart;
            root.lastError = "empty config";
            root.configChanged();
            return;
        }
        try {
            let obj = JSON.parse(JsonComments.strip(txt));
            let cals = Array.isArray(obj.calendars) ? obj.calendars : [];
            let cleaned = [];
            const poll = root._poll(obj.pollIntervalMs) || root.defaultPollIntervalMs;
            for (let i = 0; i < cals.length; i++) {
                let c = cals[i];
                if (!c || !c.url) continue;
                cleaned.push({
                    id:    c.id    || ("cal" + i),
                    name:  c.name  || ("Calendar " + (i+1)),
                    color: typeof c.color === "string" ? c.color : "",
                    url:   c.url,
                    pollIntervalMs: root._poll(c.pollIntervalMs) || poll,
                    remind: root._remind(c.remind)
                });
            }
            root.entries = cleaned;
            root.pollIntervalMs = poll;
            root.weekStart = Number.isInteger(obj.weekStart) && obj.weekStart >= 0 && obj.weekStart <= 6 ? obj.weekStart : root.defaultWeekStart;
            root.lastError = "";
            root.configChanged();
        } catch (e) {
            root.entries = [];
            root.lastError = "parse error: " + e;
            root.configChanged();
        }
    }

    Component.onCompleted: {
        // First read: ConfigFile loads at its creation, before this handler exists: parse what is there now.
        let t = fv.text();
        if (t) _parse(t);
    }
}
