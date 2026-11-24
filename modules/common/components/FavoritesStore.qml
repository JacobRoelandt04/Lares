pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// FavoritesStore.qml -- a set of favourite keys kept in a JSON file.
//
//   { "favorites": ["hyprland-git", "linux-zen", ...] }
//
// The file format the system update writes; the launcher keeps its
// own file in the same shape. Keys match exactly.
//
//   path               set ONCE (a FileView is never repointed: a second path
//                      hands back the first file's bytes -- CLAUDE.md). Shell
//                      state: $XDG_STATE_HOME/lares/<module>/favorites.json
//   legacyPath         where the file lived before (the repo's root, until
//                      2026-11-23), set once with `path`, "" for none. While
//                      `path` does not exist and this does, it is COPIED there
//                      once at the start (atomic; the old file is left as it
//                      was) and `LARES favorites moved <old> -> <new>` is logged
//   favorites          the keys, in the file's order (a new array per change)
//   serial             bumps on every change. `isFavorite()` reads it, so a
//                      binding that calls it re-evaluates on its own; a
//                      binding over `favorites` gets the new array anyway
//   isFavorite(key)    O(1)
//   add / remove / toggle(key)
//   favoriteChanged(key, favorite)
//                      for every key whose state changed, whoever changed it:
//                      a toggle here, or the file edited elsewhere (one signal
//                      per key that differs, after the whole set is in place)
//
// WRITE. Atomic: staged to `<path>.tmp` and renamed over the file, so the
// FileView watching the same path never reads half a file. Coalesced: a
// change while a write is in flight marks the save pending and the exit
// handler writes the newest set once more.
//
// SELF-ECHO. Our own rename comes back through the watcher. A read equal to
// the set in memory is that echo (or no change) and does nothing. A read that
// lands while a write is in flight or pending is ALSO ours, just older: the
// file holds a set we have already moved past, and applying it would revert
// the newest toggle for the few milliseconds until the next write lands (two
// quick toggles would flip the second one back and forth). Those reads are
// skipped, and the file is read once more when the last write has exited: it
// holds our set then, unless someone else wrote meanwhile.
// =============================================================================
Scope {
    id: store

    property string path: ""
    property string legacyPath: ""
    readonly property var favorites: store._list
    readonly property int serial: store._serial

    signal favoriteChanged(string key, bool favorite)

    property var _list: []
    // Membership, mutated in place; `_serial` is what announces it. No
    // prototype: a key named "constructor" is a key like any other.
    property var _set: Object.create(null)
    property int _serial: 0

    function isFavorite(key) {
        return store._serial >= 0 && store._set[key] === true;
    }

    function add(key) {
        if (!key || store.isFavorite(key))
            return;
        store._list = store._list.concat([key]);
        store._set[key] = true;
        store._serial++;
        store._write();
        store.favoriteChanged(key, true);
    }

    function remove(key) {
        if (!key || !store.isFavorite(key))
            return;
        store._list = store._list.filter(x => x !== key);
        delete store._set[key];
        store._serial++;
        store._write();
        store.favoriteChanged(key, false);
    }

    function toggle(key) {
        if (store.isFavorite(key))
            store.remove(key);
        else
            store.add(key);
    }

    FileView {
        id: file
        path: store.path
        watchChanges: true
        preload: true
        printErrors: false
        onFileChanged: reload()
        onTextChanged: store._parse(text())
        onLoaded: store._parse(text())
    }

    function _parse(txt) {
        // Our own write, not yet the newest one: see SELF-ECHO above. Nor while the old file is moved in.
        if (saver.running || store._savePending || mover.running)
            return;
        let next = [];
        if (txt && txt.length > 0) {
            try {
                const obj = JSON.parse(txt);
                if (Array.isArray(obj.favorites))
                    next = obj.favorites.filter(x => typeof x === "string");
            } catch (e) {
                next = [];
            }
        }
        const seen = Object.create(null);
        next = next.filter(k => seen[k] === true ? false : (seen[k] = true));
        if (store._sameList(store._list, next))
            return;
        const was = store._set;
        store._list = next;
        store._set = seen;
        store._serial++;
        for (const k in was)
            if (seen[k] !== true)
                store.favoriteChanged(k, false);
        for (const k of next)
            if (was[k] !== true)
                store.favoriteChanged(k, true);
    }

    function _sameList(a, b) {
        if (a.length !== b.length)
            return false;
        for (let i = 0; i < a.length; i++)
            if (a[i] !== b[i])
                return false;
        return true;
    }

    property bool _savePending: false
    Process {
        id: saver
        running: false
        stdinEnabled: true
    }
    // ---- the move from the old place (legacyPath), once, at the start ----
    Process {
        id: mover
        running: false
        stdout: StdioCollector { id: moverOut }
    }
    Connections {
        target: mover
        function onExited() {
            if (moverOut.text.indexOf("moved") >= 0)
                console.log("LARES favorites moved " + store.legacyPath + " -> " + store.path);
            file.reload();
            if (store._savePending) {        // a toggle in the moment of the move: written once the moved set is read
                store._savePending = false;
                Qt.callLater(store._write);
            }
        }
    }
    Component.onCompleted: {
        if (!store.path || !store.legacyPath || store.legacyPath === store.path)
            return;
        mover.command = ["sh", "-c", "[ -e \"$1\" ] && exit 0; [ -f \"$2\" ] || exit 0; mkdir -p \"$(dirname \"$1\")\" && cp \"$2\" \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\" && echo moved",
                         "sh", store.path, store.legacyPath];
        mover.running = true;
    }

    Connections {
        target: saver
        function onExited() {
            if (store._savePending) {
                store._savePending = false;
                store._write();
            } else {
                // The reads skipped while writing: one more, now that the file
                // holds our newest set -- equal, unless someone else wrote.
                file.reload();
            }
        }
    }
    function _write() {
        if (!store.path)
            return;
        if (saver.running || mover.running) {
            store._savePending = true;
            return;
        }
        const json = JSON.stringify({
            favorites: store._list
        }, null, 2) + "\n";
        saver.stdinEnabled = true;
        saver.command = ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1.tmp\" && mv -f \"$1.tmp\" \"$1\"", "sh", store.path];
        saver.running = true;
        saver.write(json);
        saver.stdinEnabled = false;       // EOF -> cat exits -> mv runs
    }
}
