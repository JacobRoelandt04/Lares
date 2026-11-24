pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../common/components"
import "../common/components/JsonComments.js" as JsonComments
import "IdleConfig.js" as Cfg
import "../common/system"

// =============================================================================
// IdleConfig.qml -- the user's idle.jsonc, READ HOT: soft idle's times and levels, the laptop panel, the brightness script,
// the lid's climb and the sleep fade (IdleConfig.js has every key; .examples/idle.jsonc documents them).
//
// Path: $XDG_CONFIG_HOME/quickshell/config/idle.jsonc (`configPath`, set once: a FileView is never repointed); ConfigFile reads the
// .jsonc first and the .json when there is none. Every key is optional, so a missing file IS the defaults. `//` and `/* */`
// comments are allowed. A file that does not parse keeps the previous settings (a typo in the middle of an edit must not dim the
// panel at once) and `lastError` names the line and column.
//
//   raw        what the file says, {} when absent: IdleService.config, which IdleConfig.js reads
//   settings   what that comes to (IdleConfig.js parse): every value, the defaults filled in
//
// `live: false` reads no file and `apply(obj)` sets the object (a probe).
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/idle.jsonc"

    readonly property var raw: root._raw
    readonly property var settings: Cfg.parse(root._raw, Quickshell.env("HOME") || "")
    readonly property string lastError: root._lastError
    readonly property bool present: root._present
    // Bumps on every change of `raw`.
    readonly property int serial: root._serial
    // the file has been read once (or there is none): what is decided at the start (IdleService's `start`) waits for this. Raised LAST, after
    // `raw` holds what was read (a flag raised before the data hands the start the empty settings).
    readonly property bool applied: root._landed
    property bool _landed: false

    // the table of PanelBacklight (where raw 0 is black) follows idle.jsonc, live or applied
    onSettingsChanged: PanelBacklight.zeroOverrides = root.settings.zeroIsBlack

    function reload(): void {
        if (root.live)
            fv.reload();
    }

    // A pure parse: { raw, error, parsed }.
    function parseText(txt: string): var {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { raw: {}, error: "", parsed: true };
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { raw: null, parsed: false,
                     error: (at ? "idle.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "idle.jsonc: " + e.message) + " -- the previous settings are kept" };
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj))
            return { raw: null, parsed: false, error: "idle.jsonc: the top level is not an object -- the previous settings are kept" };
        return { raw: obj, error: "", parsed: true };
    }

    // Set the object (no file).
    function apply(obj: var): void {
        root._applied = true;
        root._raw = obj && typeof obj === "object" && !Array.isArray(obj) ? obj : {};
        root._serial++;
        root._landed = true;
    }

    property var _raw: ({})
    property string _lastError: ""
    property bool _present: false
    property int _serial: 0
    property string _text: ""
    property bool _applied: false

    function _apply(txt: string, exists: bool): void {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._text && root._present === exists)
            return;
        root._applied = true;
        root._text = t;
        root._present = exists && t.length > 0;
        const r = root.parseText(root._present ? t : "");
        root._lastError = r.error;
        if (r.error.length > 0)
            console.warn("IdleConfig: " + r.error);
        if (r.parsed) {
            root._raw = r.raw;
            root._serial++;
        }
        root._landed = true;
    }

    // Always created (a FileView takes its path once and is never repointed); a not-live config simply does not listen to it.
    ConfigFile {
        id: fv
        path: root.configPath
        watchChanges: root.live
        onLoaded: if (root.live) root._apply(fv.text(), true)
        onLoadFailed: if (root.live) root._apply("", false)
    }
    Component.onCompleted: {
        PanelBacklight.zeroOverrides = root.settings.zeroIsBlack;
        if (!root.live) {
            root._applied = true;
            root._landed = true;
            return;
        }
        const t = fv.text();
        root._apply(t, t.length > 0);
    }
}
