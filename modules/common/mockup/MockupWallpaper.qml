pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../components"
import "../components/JsonComments.js" as JsonComments
import "../system"
import "../theme"

// =============================================================================
// MockupWallpaper.qml -- the picture a mockup's stage stands on: the desktop's own wallpaper for the theme and
// mode on show, as themectl's `wallpaper` target reads it (shell.jsonc `theme.wallpapers.<theme>.<mode>`: a path or
// a list of paths, `~` taken, absolute otherwise), read hot. Of a list, the slot's current pick in themectl's bag
// (~/.local/state/theme/wallpaper-bag.json, read hot too), or the first when the bag has none. `WALL` wins when set
// (the sheet's and the gates' fixed gradient). A theme and mode shell.jsonc names no picture for gives "" and the
// stage's own colour shows.
//
// One reader for every mockup that stands on the wallpaper (bar, power, shell, windowtray, weather_popup): they
// each kept a copy of the file names, which went stale the day the pictures moved.
//
//   MockupWallpaper { id: wall }      Image { source: wall.source }
// =============================================================================
Item {
    id: root

    visible: false

    readonly property string override: Quickshell.env("WALL") || ""
    // file:// URL of the picture, or "" when there is none.
    readonly property string source: root.override !== "" ? root.override : root._fromConfig
    // the picture's file name alone (a panel's caption).
    readonly property string fileName: root.source === "" ? "" : decodeURIComponent(root.source.split("/").pop())

    readonly property string _home: Quickshell.env("HOME") || ""
    readonly property string _stateHome: Quickshell.env("XDG_STATE_HOME") || (root._home + "/.local/state")
    property var _wallpapers: ({})
    property var _picks: ({})
    readonly property string _fromConfig: {
        const byTheme = root._wallpapers[Theme.themeName];
        const slot = byTheme && typeof byTheme === "object" ? byTheme[Theme.mode] : undefined;
        const list = typeof slot === "string" ? [slot] : (slot && typeof slot === "object" && typeof slot.length === "number" ? slot : []);
        const abs = [];
        for (let i = 0; i < list.length; i++) {
            const p = list[i];
            if (typeof p !== "string" || p.length === 0)
                continue;
            const a = p.startsWith("~/") ? root._home + p.slice(1) : p;
            if (a.startsWith("/"))
                abs.push(a);
        }
        if (abs.length === 0)
            return "";
        const pick = root._picks[Theme.themeName + "." + Theme.mode];
        return "file://" + (typeof pick === "string" && abs.indexOf(pick) >= 0 ? pick : abs[0]);
    }

    function _read(t: string): void {
        let w = {};
        try {
            const obj = JSON.parse(JsonComments.strip(t));
            const th = obj && typeof obj === "object" ? obj.theme : null;
            if (th && typeof th === "object" && th.wallpapers && typeof th.wallpapers === "object")
                w = th.wallpapers;
        } catch (e) {
            // a shell.jsonc that does not parse names no picture here; the shell says why
        }
        root._wallpapers = w;
    }

    // themectl's bag: per "<theme>.<mode>" slot its `last`, the picture on screen. Anything unreadable is no pick.
    function _readBag(t: string): void {
        let picks = {};
        try {
            const slots = JSON.parse(t).slots;
            for (const k in slots)
                if (slots[k] && typeof slots[k].last === "string")
                    picks[k] = slots[k].last;
        } catch (e) {
            // no bag yet: the first of each list
        }
        root._picks = picks;
    }

    ConfigFile {
        id: file
        path: RepoRoot.dir + "/config/shell.jsonc"
        onLoaded: root._read(file.text())
        onLoadFailed: root._wallpapers = {}
    }
    FileView {
        id: bagFile
        path: root._stateHome + "/theme/wallpaper-bag.json"
        blockLoading: true
        printErrors: false
        watchChanges: true
        onFileChanged: bagFile.reload()
        onTextChanged: root._readBag(bagFile.text())
    }
    Component.onCompleted: {
        root._read(file.text());
        root._readBag(bagFile.text());
    }
}
