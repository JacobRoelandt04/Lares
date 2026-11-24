pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../components"
import "../components/JsonComments.js" as JsonComments
import "ConfigCheck.js" as Check

// =============================================================================
// JsonConfig.qml -- one hand-edited config/<name>.jsonc, READ HOT through its spec (specs/<name>.js, ConfigCheck.js).
//
//   name        the file's name without .jsonc
//   spec        its SPEC
//   configPath  set once (a FileView is never repointed); the default is the user's own file
//   settings    every key at what the file says, or at its default: never null, every key always there. Right from the first time it
//               is read (the file is read then, synchronously): what a Loader or a window decides as it is built is decided on it.
//               A key the spec reads at the start (`start`) keeps the value it had then, the very same object.
//   problems    what in the file was refused (ConfigCheck; ConfigWatch is what tells the user)
//   lastError   "" or why the last read was refused as a whole: the previous settings stand
//   present     there is a file
//   serial      bumps on every accepted read
//
// A value that is wrong is left out and its default stands; a file that does not parse keeps the previous settings (a typo in the middle
// of an edit changes nothing). `live: false` reads no file and `apply(obj)` sets the object (a probe, a mockup).
// =============================================================================
Item {
    id: root

    property bool live: true
    required property string name
    required property var spec
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/" + root.name + ".jsonc"

    readonly property var settings: root._state.settings
    readonly property var problems: root._state.problems
    readonly property string lastError: root._error
    readonly property bool present: root._present
    readonly property int serial: root._serial

    signal changed()

    function reload(): void {
        if (root.live)
            fv.reload();
    }

    // Set the object (no file).
    function apply(obj: var): void {
        root._take(Check.read(root.spec, obj));
    }

    // The state from a text: { settings, problems } or null when it does not parse (lastError says why).
    function _read(txt: string): var {
        if (txt.trim().length === 0)
            return Check.read(root.spec, {});
        const r = Check.parse(txt, JsonComments.locate);
        if (r.error) {
            root._error = root.name + ".jsonc line " + r.error.line + ", column " + r.error.column + ": " + r.error.reason + " -- the previous settings are kept";
            return null;
        }
        if (!Check.isObject(r.value)) {
            root._error = root.name + ".jsonc: the top level is not an object -- the previous settings are kept";
            return null;
        }
        return Check.read(root.spec, r.value);
    }

    // THE FIRST STATE, from a binding: the candidates of ConfigFile read by blocking views of their own (ShellConfig's StartView), so whoever
    // asks first -- a Loader, a window being built, before the event loop has run -- has the file's answer. `_take` replaces it for good.
    property var _state: {
        for (const v of [startJsonc, startJson, startOldJsonc, startOldJson]) {
            const t = root.live && v.path !== "" ? v.text() : "";
            if (t.trim().length === 0)
                continue;
            const r = Check.parse(t, null);
            return Check.read(root.spec, r.error || !Check.isObject(r.value) ? {} : r.value);
        }
        return Check.read(root.spec, {});
    }
    readonly property var _startPaths: JsonComments.configPaths(root.configPath)
    component StartView: FileView {
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }
    StartView { id: startJsonc; path: root._startPaths.jsonc || "" }
    StartView { id: startJson; path: root._startPaths.json || "" }
    StartView { id: startOldJsonc; path: root._startPaths.oldJsonc || "" }
    StartView { id: startOldJson; path: root._startPaths.oldJson || "" }
    property string _error: ""
    property bool _present: false
    property int _serial: 0
    property string _text: ""
    property bool _ready: false

    // what the file said first: the keys that are read at the start stay at it
    property var _start: null

    function _take(state: var): void {
        root._state = state;
        root._serial++;
        root.changed();
    }

    function _apply(txt: string, exists: bool): void {
        if (root._ready && txt === root._text && root._present === exists)
            return;
        const first = !root._ready;
        if (first)
            root._start = root._state.settings;
        root._ready = true;
        root._text = txt;
        root._present = exists && txt.length > 0;
        root._error = "";
        const r = root._read(root._present ? txt : "");
        if (root._error !== "")
            console.warn("JsonConfig: " + root._error);
        if (!r)
            return;
        for (const p of r.problems)
            console.warn("JsonConfig: " + root.name + ".jsonc: " + Check.pathWords(p.path) + " " + p.why + " -- its default is used");
        Check.keepStart(root.spec, root._start, r.settings);
        // the first load says what the first read already said: no change of anything
        if (first && JSON.stringify(r.settings) === JSON.stringify(root._state.settings)) {
            root._serial++;
            return;
        }
        root._take(r);
    }

    ConfigFile {
        id: fv
        path: root.configPath
        watchChanges: root.live
        onLoaded: if (root.live) root._apply(fv.text(), true)
        onLoadFailed: if (root.live) root._apply("", false)
    }
}
