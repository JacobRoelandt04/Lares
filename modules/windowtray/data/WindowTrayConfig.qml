pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "WindowTrayConfig.js" as Cfg

// =============================================================================
// WindowTrayConfig.qml -- the user's windowtray.jsonc, READ ONLY, hot.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/windowtray.jsonc (`configPath`, set once: a
// FileView is never repointed -- see CLAUDE.md). Every key is optional; `config`
// is WindowTrayConfig.js's merge of the file over the code's defaults, so a
// missing file IS the defaults. .examples/windowtray.jsonc at the config root
// documents every key.
//
//   config   { follow, stripSuffix, rewrites[{re,to}], terminalClasses[], terminalTitleMs, trayOrder[], trayHide[], trayRename{},
//              trayIconMode, trayPassive, attention, openOn, closeOnLeave, closeOnActivate, desktopText }
//
// `//` and `/* */` comments are allowed (JsonComments.strip). A file that does
// not parse keeps the previous config -- a typo in the middle of an edit must
// not reset the user's tray -- and `lastError` names the line and column
// (JsonComments.locate). An entry that cannot work (a regex that does not
// compile, a list of the wrong type) takes the default or is dropped, and
// `warnings` says which.
//
// `live: false` (the mockup, the probes) reads no file: the defaults stand and
// `apply(obj)` merges an object over them.
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/windowtray.jsonc"

    // The merged config; never null.
    readonly property var config: root._config
    // "" when the last read was good.
    readonly property string lastError: root._lastError
    // What the last good read dropped or defaulted, one line each.
    readonly property var warnings: root._warnings
    readonly property bool present: root._present
    // Bumps on every config change (a new object is assigned each time).
    readonly property int serial: root._serial

    function reload() {
        if (root.live)
            fv.reload();
    }

    // The first read (idempotent; a caller that needs the file before its own
    // onCompleted asks for it).
    function ensureLoaded() {
        if (root._applied)
            return;
        if (!root.live) {
            root._applied = true;
            return;
        }
        const t = fv.text();
        root._apply(t, !!t);
    }

    // A pure parse: { config, warnings, error, parsed }.
    function parseText(txt) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0) {
            const d = Cfg.merge({});
            return { config: d.config, warnings: [], error: "", parsed: true };
        }
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { config: null, warnings: [], parsed: false,
                     error: (at ? "windowtray.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "windowtray.jsonc: " + e.message) + " — the previous config is kept" };
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj))
            return { config: null, warnings: [], parsed: false,
                     error: "windowtray.jsonc: the top level is not an object — the previous config is kept" };
        const m = Cfg.merge(obj);
        return { config: m.config, warnings: m.warnings, error: "", parsed: true };
    }

    // Merge an object over the defaults (no file): the mockup's panel and the
    // probes set the config this way.
    function apply(obj) {
        const m = Cfg.merge(obj);
        root._applied = true;
        root._config = m.config;
        root._warnings = m.warnings;
        root._serial++;
    }

    // ---- Private -------------------------------------------------------------
    property var _config: Cfg.merge({}).config
    property string _lastError: ""
    property var _warnings: []
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
        if (r.error.length > 0)
            console.warn("WindowTrayConfig: " + r.error);
        if (!r.parsed)
            return;
        for (let i = 0; i < r.warnings.length; i++)
            console.warn("WindowTrayConfig: " + r.warnings[i]);
        root._config = r.config;
        root._warnings = r.warnings;
        root._serial++;
    }

    // Always created (a FileView takes its path once and is never repointed);
    // a not-live config simply does not listen to it.
    ConfigFile {
        id: fv
        path: root.configPath
        watchChanges: root.live
        onLoaded: if (root.live) root._apply(fv.text(), true)
        onLoadFailed: if (root.live) root._apply("", false)
    }

    Component.onCompleted: root.ensureLoaded()
}
