pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../components"
import "../system"
import "../components/JsonComments.js" as JsonComments

// =============================================================================
// LocaleConfig.qml -- how this shell writes times and dates.
//
// One small JSON file, read by path: `config/locale.jsonc` (or the older places ConfigFile still reads), or its
// example (.examples/locale.jsonc) when the user has not written one. The lock screen's
// clock reads it, and the clock module can share it, which is why it
// lives in common/ and is a plain Item handed in as a property rather than a
// singleton (a mockup or a probe passes its own).
//
//   { "timeFormat": "HH:mm", "dateFormat": "dddd d MMMM" }
//
// Formats are Qt's (Qt.formatDateTime): 24 h "HH:mm" by default. A key that is missing or not a
// string falls back to the built-in default, a file that does not parse is
// ignored whole (the example, then the defaults, answer instead).
//
// TWO ConfigFiles, each on its own static path: a FileView loads synchronously
// on its FIRST path only, so one view repointed from locale.jsonc to the
// example would hand back the previous file's bytes (CLAUDE.md). Both watch
// their file, so an edit is picked up without a restart.
// =============================================================================
Item {
    id: root

    visible: false

    property string path: RepoRoot.dir + "/config/locale.jsonc"
    property string examplePath: RepoRoot.dir + "/.examples/locale.jsonc"

    readonly property string defaultTimeFormat: "HH:mm"
    readonly property string defaultDateFormat: "dddd d MMMM"

    readonly property string timeFormat: root._pick("timeFormat", root.defaultTimeFormat)
    readonly property string dateFormat: root._pick("dateFormat", root.defaultDateFormat)

    // Which file answered: "user", "example" or "defaults" (a probe reads it).
    readonly property string source: root._user ? "user" : (root._example ? "example" : "defaults")

    // The formatted text of an instant (epoch ms).
    function formatTime(ms) {
        return Qt.formatDateTime(new Date(ms), root.timeFormat);
    }
    function formatDate(ms) {
        return Qt.formatDateTime(new Date(ms), root.dateFormat);
    }

    property var _user: null
    property var _example: null

    function _parse(text) {
        try {
            const o = JSON.parse(JsonComments.strip(text));
            return o !== null && typeof o === "object" && !Array.isArray(o) ? o : null;
        } catch (e) {
            return null;
        }
    }
    function _pick(key, dflt) {
        for (const o of [root._user, root._example]) {
            if (o && typeof o[key] === "string" && o[key].length > 0)
                return o[key];
        }
        return dflt;
    }

    ConfigFile {
        id: userFile
        path: root.path
        onLoaded: root._user = root._parse(userFile.text())
        onLoadFailed: root._user = null
    }
    ConfigFile {
        id: exampleFile
        path: root.examplePath
        onLoaded: root._example = root._parse(exampleFile.text())
        onLoadFailed: root._example = null
    }
    // blockLoading reads at the first assignment, before the handlers exist:
    // take what is there now.
    Component.onCompleted: {
        root._user = root._parse(userFile.text());
        root._example = root._parse(exampleFile.text());
    }
}
