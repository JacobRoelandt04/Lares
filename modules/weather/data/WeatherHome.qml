pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// WeatherHome.qml -- the hometown the shell learned, kept in the state dir.
//
// The fallback of the current location (what it shows while geoclue has no
// fix) is the user's HOMETOWN, which a default location only approximates (the
// user's town is not the default place). With none named, the FIRST ACCEPTED geoclue fix
// names it. This object keeps that one place:
//
//   record   { name, lat, lon, elevation, naming, learnedAtMs } | null
//   naming   how the name was found, so a better one can replace a worse:
//              "saved"   a saved location within nearSavedKm of the fix
//              "kmi"     KMI's cityName for the fix
//              "coords"  "lat, lon" to two decimals, until KMI answers (rename())
//   settled  the file has been read (or found missing): nothing decides before it
//
// learn() writes the record ONCE (a record that exists is never replaced by a
// later fix: a trip must not move the user's home); rename() only upgrades a
// "coords" name. A location marked "home": true in weather.jsonc beats the
// record (WeatherConfig.homeLocation) and the service then learns nothing.
// Delete the file to learn again.
//
// The FileView rule (CLAUDE.md): one FileView, a static path, never repointed;
// a write skips an equal text, so the file is only touched when the record
// changes. The directory is made by `mkdir -p` before the first write.
// =============================================================================
Item {
    id: root

    property string path: ""

    property var record: null
    readonly property bool settled: root._read && root._dirReady
    signal updated()

    property bool _read: false
    property bool _dirReady: false

    function _dir() {
        const i = root.path.lastIndexOf("/");
        return i > 0 ? root.path.slice(0, i) : "";
    }

    // Read once, at completion, synchronously: a file that does not exist fires nothing a service could wait for
    // (CLAUDE.md), and text() of one is "".
    FileView {
        id: view
        path: root.path
        watchChanges: false
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Process {
        id: mkdirProc
        running: false
        command: ["mkdir", "-p", root._dir()]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Connections {
        target: mkdirProc
        function onExited() { root._dirReady = true; }
    }

    Component.onCompleted: {
        root._parse(root.path === "" ? "" : view.text());
        if (root.path === "") {
            root._dirReady = true;
            return;
        }
        mkdirProc.running = true;
    }

    function _parse(txt) {
        let o = null;
        if (txt && txt.trim().length > 0) {
            try { o = JSON.parse(txt); } catch (e) { o = null; }
        }
        const ok = o && typeof o === "object" && typeof o.name === "string" && o.name.length > 0
            && typeof o.lat === "number" && isFinite(o.lat) && typeof o.lon === "number" && isFinite(o.lon);
        root.record = ok ? {
            name: o.name, lat: o.lat, lon: o.lon,
            elevation: typeof o.elevation === "number" && isFinite(o.elevation) ? o.elevation : null,
            naming: typeof o.naming === "string" ? o.naming : "coords",
            learnedAtMs: typeof o.learnedAtMs === "number" ? o.learnedAtMs : 0
        } : null;
        root._read = true;
        root.updated();
    }

    function _write() {
        if (root.path === "" || root.record === null)
            return;
        view.setText(JSON.stringify(root.record, null, 1) + "\n");
    }

    // The first accepted fix. Does nothing when a record exists.
    function learn(name, lat, lon, elevation, naming) {
        if (!root.settled || root.record !== null)
            return false;
        root.record = {
            name: name, lat: lat, lon: lon,
            elevation: typeof elevation === "number" && isFinite(elevation) ? elevation : null,
            naming: naming, learnedAtMs: Date.now()
        };
        root._write();
        root.updated();
        return true;
    }

    // A better name for the learned town: only while it is still "lat, lon".
    function rename(name) {
        if (root.record === null || root.record.naming !== "coords" || !name)
            return false;
        root.record = Object.assign({}, root.record, { name: name, naming: "kmi" });
        root._write();
        root.updated();
        return true;
    }
}
