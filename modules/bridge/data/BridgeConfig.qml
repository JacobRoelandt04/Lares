pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "BridgeModel.js" as Model

// =============================================================================
// BridgeConfig.qml -- the user's bridge.jsonc, READ HOT (docs/contracts/bridge.md section 7; .examples/bridge.jsonc has every key).
//
// Path: $XDG_CONFIG_HOME/quickshell/config/bridge.jsonc (`configPath`, set once: a FileView is never repointed); ConfigFile reads the
// .jsonc first and the .json when there is none. Every key is optional, so a missing file IS the defaults. `//` and `/* */`
// comments are allowed. A value of the wrong kind is its default, a number out of range is clamped (BridgeModel.parseConfig); a
// file that does not parse keeps the previous settings (a typo in the middle of an edit must not change the mirror's quality)
// and `lastError` names the line and column.
//
//   settings   the whole config with every value filled in (the tool reads the same file through tools/lib/jsonc.py and clamps
//              the same way; the service only needs files.open, files.usbMount, shots.dir, the mirror quality for a hint)
//   lastError  "" or why the last read was refused
//   present    a file is in force
//   serial     bumps on every accepted read
//
// `live: false` reads no file and `apply(obj)` sets the object (a probe, the mock).
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/bridge.jsonc"

    readonly property var settings: root._settings
    readonly property string lastError: root._lastError
    readonly property bool present: root._present
    readonly property int serial: root._serial

    function reload(): void {
        if (root._fv)
            root._fv.reload();
    }

    // Idempotent: the owner's own completion runs BEFORE this child's, and it may read `settings` first. (Live, the first read is
    // the Loader's own `loaded`; a loader that is not built yet reads nothing here.)
    function ensureLoaded(): void {
        if (root._loaded)
            return;
        root._loaded = true;
        if (root._fv)
            root._firstRead();
    }
    function _firstRead(): void {
        const t = root._fv.text();
        root._apply(t, t.length > 0);
    }

    // Set the object (no file).
    function apply(obj: var): void {
        root._loaded = true;
        root._settings = Model.parseConfig(obj);
        root._serial++;
    }

    // A pure parse of the file's text: { obj, error, parsed }.
    function parseText(txt: string): var {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { obj: {}, error: "", parsed: true };
        let o = null;
        try {
            o = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { obj: null, parsed: false,
                     error: (at ? "bridge.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "bridge.jsonc: " + e.message) + " -- the previous settings are kept" };
        }
        if (o === null || typeof o !== "object" || Array.isArray(o))
            return { obj: null, parsed: false, error: "bridge.jsonc: the top level is not an object -- the previous settings are kept" };
        return { obj: o, error: "", parsed: true };
    }

    // the live file view (null while not live)
    readonly property var _fv: fvLoader.item
    property var _settings: Model.parseConfig({})
    property string _lastError: ""
    property bool _present: false
    property int _serial: 0
    property string _text: ""
    property bool _loaded: false

    function _apply(txt: string, exists: bool): void {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if ((root._serial > 0 || root._lastError !== "") && t === root._text && root._present === (exists && t.length > 0))
            return;
        root._loaded = true;
        root._text = t;
        root._present = exists && t.length > 0;
        const r = root.parseText(root._present ? t : "");
        root._lastError = r.error;
        if (r.error.length > 0)
            console.warn("BridgeConfig: " + r.error);
        if (!r.parsed)
            return;
        root._settings = Model.parseConfig(r.obj);
        root._serial++;
    }

    // Only while live: a not-live config has no file view, and no Process (a ConfigFile holds one for its writes). A FileView takes its
    // path once and is never repointed, so `configPath` is set at creation.
    Loader {
        id: fvLoader
        active: root.live
        sourceComponent: Component {
            ConfigFile {
                id: fv
                path: root.configPath
                watchChanges: true
                onLoaded: root._apply(fv.text(), true)
                onLoadFailed: root._apply("", false)
            }
        }
        onLoaded: root._firstRead()
    }
    Component.onCompleted: root.ensureLoaded()
}
