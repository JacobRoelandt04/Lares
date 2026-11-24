pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "NotifyPolicy.js" as Policy
import "../../common/components/JsonComments.js" as JsonComments
import "../sources/SourceSettings.js" as SourceSettings

// =============================================================================
// NotificationConfig.qml -- the user's notifications.jsonc, READ ONLY, hot.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/notifications.jsonc (`configPath`, set
// once: a FileView is never repointed -- see CLAUDE.md). Every key is
// optional; `config` is NotifyPolicy.merge() of the file over the code's
// defaults, so a missing file IS the defaults. .examples/notifications.jsonc at
// the config root documents every key.
//
// `//` and `/* */` comments are allowed (JsonComments.strip). A file that does
// not parse keeps the previous config -- a typo in the middle of an edit must
// not reset the user's rules -- and `lastError` names the line and column
// (JsonComments.locate; Qt's JSON.parse names no position). A top level that
// is not an object is the same kind of error.
//
// THE SOURCES' KEYS. `sources.<id>` holds a source's rule keys (NotifyPolicy) AND
// what the source itself does (modules/notifications/sources: the system update's
// nudge, the battery's levels, ...), whose defaults and limits are SourceSettings'.
// The file is applied whatever those keys say -- a source reads its block through
// SourceSettings.resolve, which leaves a bad value at its default -- but the config
// SAYS which keys it ignored: each is a line in `lastError`, "sources.battery.levels[1]:
// not a valid entry, dropped", while `parsed` stays true (the rest of the file is good).
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/notifications.jsonc"

    // The merged config; never null.
    readonly property var config: root._config
    readonly property string lastError: root._lastError
    readonly property bool present: root._present
    // Bumps on every config change (a new object is assigned each time).
    readonly property int serial: root._serial

    function reload() { fv.reload(); }

    // The first read (idempotent; a caller that needs the file before its
    // own onCompleted -- the service -- asks for it).
    function ensureLoaded() {
        if (root._applied)
            return;
        const t = fv.text();
        root._apply(t, !!t);
    }

    // A pure parse, for the probes: { config, error, parsed }.
    function parseText(txt) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { config: Policy.merge({}), error: "", parsed: true };
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { config: null, parsed: false,
                     error: (at ? "notifications.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "notifications.jsonc: " + e.message) + " — the previous config is kept" };
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj))
            return { config: null, parsed: false,
                     error: "notifications.jsonc: the top level is not an object — the previous config is kept" };
        const bad = SourceSettings.resolve(obj.sources).problems;
        return { config: Policy.merge(obj), parsed: true,
                 error: bad.length > 0 ? "notifications.jsonc: " + bad.join("; ") : "" };
    }

    // ---- Private -------------------------------------------------------------
    property var _config: Policy.merge({})
    property string _lastError: ""
    property bool _present: false
    property int _serial: 0
    property string _raw: ""
    property bool _applied: false

    function _apply(txt, exists) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._raw && root._present === exists)
            return;
        root._applied = true;
        root._raw = t;
        root._present = exists && t.length > 0;
        const r = root.parseText(root._present ? t : "");
        root._lastError = r.error;
        if (!r.parsed)
            return;
        root._config = r.config;
        root._serial++;
    }

    ConfigFile {
        id: fv
        path: root.configPath
        onLoaded: root._apply(fv.text(), true)
        onLoadFailed: root._apply("", false)
    }

    Component.onCompleted: root.ensureLoaded()
}
