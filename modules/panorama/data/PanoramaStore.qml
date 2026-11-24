pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// PanoramaStore.qml -- setups.json, Panorama's ONE store (docs/contracts/panorama.md section 2). One write path: `write(data)`.
//
//   path       <stateDir>/panorama/setups.json (set once: a FileView takes its path once and is never repointed)
//   doc        the parsed store, every top-level key present ({ v, displays, setups, split }); a file that does not parse
//              keeps the previous data and `lastError` says why
//   present    the file exists (`lares panorama-import` made it, or the first Keep)
//   serial     bumps on every accepted read or write
//
// The file is followed (watchChanges): the import writes it while the shell runs. A write is atomic (atomicWrites) and a write
// equal to the text held is skipped by FileView itself (the law), which is fine: nothing changed. `live: false` keeps the data
// in memory only (the mock, a probe).
// =============================================================================
Item {
    id: root

    property bool live: false
    property string path: ""

    readonly property var doc: root._doc
    readonly property bool present: root._present
    readonly property string lastError: root._lastError
    readonly property int serial: root._serial

    function empty(): var {
        return { v: 1, displays: {}, setups: {}, split: {} };
    }

    function write(d: var): void {
        const n = root._normal(d);
        root._doc = n;
        root._serial++;
        if (!root.live || !root._fv)
            return;
        root._mkdir();
        root._fv.setText(JSON.stringify(n, null, 1) + "\n");
        root._present = true;
    }

    // ---- private ----
    property var _doc: root.empty()
    property bool _present: false
    property string _lastError: ""
    property int _serial: 0
    property bool _dirMade: false
    readonly property var _fv: fvLoader.item

    function _normal(d: var): var {
        const o = d && typeof d === "object" ? JSON.parse(JSON.stringify(d)) : {};
        return { v: 1, displays: o.displays || {}, setups: o.setups || {}, split: o.split || {} };
    }

    function _apply(t: string): void {
        const s = String(t || "");
        if (s.trim() === "") {
            root._present = false;
            root._doc = root.empty();
            root._lastError = "";
            root._serial++;
            return;
        }
        try {
            root._doc = root._normal(JSON.parse(s));
            root._present = true;
            root._lastError = "";
            root._serial++;
        } catch (e) {
            root._lastError = "setups.json does not parse (" + e.message + "): the previous setups are kept";
            console.warn("PanoramaStore: " + root._lastError);
        }
    }

    function _mkdir(): void {
        if (root._dirMade)
            return;
        root._dirMade = true;
        const dir = root.path.substring(0, root.path.lastIndexOf("/"));
        if (dir !== "")
            Quickshell.execDetached(["mkdir", "-p", dir]);
    }

    Loader {
        id: fvLoader
        active: root.live && root.path !== ""
        sourceComponent: Component {
            FileView {
                id: fv
                path: root.path
                blockLoading: true
                atomicWrites: true
                watchChanges: true
                printErrors: false
                onFileChanged: fv.reload()
                onLoaded: root._apply(fv.text())
            }
        }
        onLoaded: root._apply(root._fv.text())
    }
}
