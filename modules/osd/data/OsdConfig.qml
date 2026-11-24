pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "OsdKinds.js" as Kinds

// =============================================================================
// OsdConfig.qml -- the user's osd.jsonc, READ ONLY, hot.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/osd.jsonc (`configPath`, set once: a
// FileView is never repointed -- see CLAUDE.md). Every key is optional;
// `config` is OsdKinds.mergeConfig() of the file over the code's defaults, so
// a missing file IS the defaults. .examples/osd.jsonc at the config root
// documents every key (CONTRACT section 9).
//
// `//` and `/* */` comments are allowed (JsonComments.strip). A file that does
// not parse keeps the previous config -- a typo in the middle of an edit must
// not reset the user's routes -- and `lastError` names the line and column
// (JsonComments.locate; Qt's JSON.parse names no position). A top level that
// is not an object is the same kind of error.
//
// `live: false` (the mockup, the probes) reads no file: the defaults stand and
// `apply(obj)` merges an object over them, so a probe's routes are set without
// a file on disk.
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/osd.jsonc"

    // The merged config; never null.
    readonly property var config: root._config
    readonly property string lastError: root._lastError
    readonly property bool present: root._present
    // Bumps on every config change (a new object is assigned each time).
    readonly property int serial: root._serial

    function reload() {
        if (root.live)
            fv.reload();
    }

    // The first read (idempotent; a caller that needs the file before its own
    // onCompleted -- the service -- asks for it).
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

    // A pure parse: { config, error, parsed }.
    function parseText(txt) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { config: Kinds.mergeConfig({}), error: "", parsed: true };
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return { config: null, parsed: false,
                     error: (at ? "osd.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "osd.jsonc: " + e.message) + " — the previous config is kept" };
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj))
            return { config: null, parsed: false,
                     error: "osd.jsonc: the top level is not an object — the previous config is kept" };
        return { config: Kinds.mergeConfig(obj), error: "", parsed: true };
    }

    // Merge an object over the defaults (no file): the mockup's Kinds tab and
    // the probes set routes this way.
    function apply(obj) {
        root._applied = true;
        root._config = Kinds.mergeConfig(obj);
        root._serial++;
    }

    // ---- Private -------------------------------------------------------------
    property var _config: Kinds.mergeConfig({})
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
        if (r.error.length > 0)
            console.warn("OsdConfig: " + r.error);
        if (!r.parsed)
            return;
        root._config = r.config;
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
