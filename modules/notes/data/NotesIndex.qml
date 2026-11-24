pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "NotesScan.js" as S

// =============================================================================
// NotesIndex.qml -- `<root>/.notes.json`: what the notes folder knows about
// itself that the file system does not. It is hidden (never listed) and it
// travels with the folder.
//
//   { version: 1,
//     sort:      { mode: "name"|"modified"|"created"|"size"|"custom", ascending },
//     order:     { <folder key>: [<keys of its direct children> ...] },
//     colors:    { <key>: "<colour KEY>" },          -- "red", never a colour
//     sizes:     { <key>: { w, h, shift } },          -- "" = the browse view
//     firstSeen: { <key>: ms },                       -- birth-time fallback
//     inodes:    { <key>: inode } }                   -- rename detection
//
// Keys MOVE with renames and moves (renameKey), ours and the ones the
// service detects by inode, so a colour, a size and a place in a custom order
// follow the note.
//
// WRITES. Debounced (writeDelayMs), atomic (FileView atomicWrites), after a
// `mkdir -p` of the root (the root may not exist yet: nothing is created
// until there is something to keep). Two kinds of change:
//   - a USER change (sort, order, colour, size, and a key moving or going
//     away that carried any of those) is written;
//   - BOOKKEEPING (inodes, firstSeen) is written only into a file that
//     already exists and is valid: browsing a folder never creates the file,
//     and never overwrites one it could not read.
// A missing file is an empty index. A CORRUPT one (not JSON, wrong version)
// is logged once and kept on disk untouched; memory starts empty, and the
// first user change replaces it.
//
// WATCHED. An outside edit is read after `loaded` (a reload's text arrives
// only then) and replaces memory; `ingested()` tells the service. Our own
// writes echo one fileChanged each: the texts of the last few writes are
// remembered and their echoes dropped -- a stale echo of an earlier write
// reads the NEWER file, which is also one of ours.
//
// `path` is set once, at creation (a FileView is never repointed); the
// service makes a new index for a new root.
// =============================================================================
Scope {
    id: idx

    required property string path
    property int writeDelayMs: 300

    signal ingested

    property var _d: idx._fresh()
    property bool _corrupt: false
    property bool _fileValid: false
    property bool _userDirty: false
    property bool _bookDirty: false
    property var _recent: []
    property bool _dirReady: false
    property bool _loggedCorrupt: false
    property string _lastText: ""
    readonly property string _dir: idx.path.substring(0, idx.path.lastIndexOf("/"))

    readonly property var modes: ["name", "modified", "created", "size", "custom"]

    function _fresh() {
        return {
            version: 1,
            sort: {
                mode: "name",
                ascending: true
            },
            order: {},
            colors: {},
            sizes: {},
            firstSeen: {},
            inodes: {}
        };
    }

    // ---- reading ---------------------------------------------------------------

    function sortMode() {
        return idx._d.sort.mode;
    }
    function sortAscending() {
        return idx._d.sort.ascending;
    }
    function colorOf(key) {
        const c = idx._d.colors[key];
        return typeof c === "string" ? c : "";
    }
    function orderOf(folder) {
        const o = idx._d.order[folder];
        return Array.isArray(o) ? o.slice() : [];
    }
    function sizeOf(key) {
        const z = idx._d.sizes[key];
        return z ? { w: z.w, h: z.h, shift: z.shift } : null;
    }
    function firstSeen(key) {
        const v = idx._d.firstSeen[key];
        return typeof v === "number" ? v : 0;
    }
    function inodeOf(key) {
        const v = idx._d.inodes[key];
        return typeof v === "number" ? v : 0;
    }
    function inodeKeys() {
        return Object.keys(idx._d.inodes);
    }

    // ---- user changes ----------------------------------------------------------
    // Each returns whether anything changed.

    function setSort(mode, ascending) {
        if (idx.modes.indexOf(mode) < 0)
            return false;
        const s = idx._d.sort;
        if (s.mode === mode && s.ascending === !!ascending)
            return false;
        idx._d.sort = {
            mode: mode,
            ascending: !!ascending
        };
        idx._touch(true);
        return true;
    }
    function setColor(key, colorKey) {
        const c = typeof colorKey === "string" ? colorKey : "";
        if (idx.colorOf(key) === c)
            return false;
        if (c === "")
            delete idx._d.colors[key];
        else
            idx._d.colors[key] = c;
        idx._touch(true);
        return true;
    }
    function setOrder(folder, keys) {
        const clean = [];
        const seen = {};
        for (let i = 0; i < (keys || []).length; i++) {
            const k = String(keys[i]);
            if (seen[k] === true || S.parentOf(k) !== folder)
                continue;
            seen[k] = true;
            clean.push(k);
        }
        if (JSON.stringify(clean) === JSON.stringify(idx.orderOf(folder)))
            return false;
        if (clean.length === 0)
            delete idx._d.order[folder];
        else
            idx._d.order[folder] = clean;
        idx._touch(true);
        return true;
    }
    function setSize(key, z) {
        const cur = idx.sizeOf(key);
        if (!z) {
            if (!cur)
                return false;
            delete idx._d.sizes[key];
            idx._touch(true);
            return true;
        }
        const nz = {
            w: Number(z.w) || 0,
            h: Number(z.h) || 0,
            shift: Number(z.shift) || 0
        };
        if (cur && cur.w === nz.w && cur.h === nz.h && cur.shift === nz.shift)
            return false;
        idx._d.sizes[key] = nz;
        idx._touch(true);
        return true;
    }

    // ---- bookkeeping -------------------------------------------------------------

    function noteFirstSeen(key, ms) {
        if (idx.firstSeen(key) > 0)
            return;
        idx._d.firstSeen[key] = ms;
        idx._touch(false);
    }
    function setInode(key, inode) {
        if (idx.inodeOf(key) === inode)
            return;
        idx._d.inodes[key] = inode;
        idx._touch(false);
    }

    // ---- keys moving and going ---------------------------------------------------

    // Everything filed under `oldKey` or below it moves to `newKey`. In its
    // parent's custom order the key keeps its slot when the parent stays the
    // same (a rename) and leaves it when it does not (a move: the new folder
    // does not know it, so it comes first there).
    function renameKey(oldKey, newKey) {
        if (oldKey === newKey || oldKey === "")
            return;
        let user = false;
        const maps = ["colors", "sizes", "firstSeen", "inodes"];
        for (let m = 0; m < maps.length; m++) {
            const M = idx._d[maps[m]];
            const ks = Object.keys(M);
            const moved = {};
            for (let i = 0; i < ks.length; i++) {
                const nk = S.rebase(ks[i], oldKey, newKey);
                if (nk === null)
                    continue;
                moved[nk] = M[ks[i]];
                delete M[ks[i]];
                if (m < 2)
                    user = true;
            }
            Object.assign(M, moved);
        }
        const O = idx._d.order;
        const folders = Object.keys(O);
        const movedO = {};
        for (let i = 0; i < folders.length; i++) {
            const nf = S.rebase(folders[i], oldKey, newKey);
            if (nf === null)
                continue;
            movedO[nf] = O[folders[i]].map(k => {
                const r = S.rebase(k, oldKey, newKey);
                return r === null ? k : r;
            });
            delete O[folders[i]];
            user = true;
        }
        Object.assign(O, movedO);
        const op = S.parentOf(oldKey), np = S.parentOf(newKey);
        const list = O[op];
        if (Array.isArray(list)) {
            const at = list.indexOf(oldKey);
            if (at >= 0) {
                if (op === np)
                    list[at] = newKey;
                else
                    list.splice(at, 1);
                if (list.length === 0)
                    delete O[op];
                user = true;
            }
        }
        idx._touch(user);
    }

    // `key` and everything under it is gone.
    function removeKey(key) {
        if (key === "")
            return;
        let user = false;
        const maps = ["colors", "sizes", "firstSeen", "inodes"];
        for (let m = 0; m < maps.length; m++) {
            const M = idx._d[maps[m]];
            const ks = Object.keys(M);
            for (let i = 0; i < ks.length; i++) {
                if (!S.isSelfOrUnder(ks[i], key))
                    continue;
                delete M[ks[i]];
                if (m < 2)
                    user = true;
            }
        }
        const O = idx._d.order;
        const folders = Object.keys(O);
        for (let i = 0; i < folders.length; i++) {
            if (S.isSelfOrUnder(folders[i], key)) {
                delete O[folders[i]];
                user = true;
            }
        }
        const list = O[S.parentOf(key)];
        if (Array.isArray(list)) {
            const at = list.indexOf(key);
            if (at >= 0) {
                list.splice(at, 1);
                if (list.length === 0)
                    delete O[S.parentOf(key)];
                user = true;
            }
        }
        idx._touch(user);
    }

    // ---- disk ------------------------------------------------------------------------

    // The service saw the root exist: no mkdir is needed before a write.
    function rootExists() {
        idx._dirReady = true;
    }

    function _touch(user) {
        if (user)
            idx._userDirty = true;
        else
            idx._bookDirty = true;
        if (idx._userDirty || (idx._fileValid && !idx._corrupt))
            writeTimer.restart();
    }

    function flush() {
        writeTimer.stop();
        if (!idx._userDirty && !(idx._bookDirty && idx._fileValid && !idx._corrupt))
            return;
        if (!idx._dirReady) {
            mkdir.running = true;
            return;
        }
        const txt = JSON.stringify(idx._d, null, 1) + "\n";
        idx._userDirty = false;
        idx._bookDirty = false;
        const r = idx._recent.slice(-3);
        r.push(txt);
        idx._recent = r;
        idx._corrupt = false;
        idx._fileValid = true;
        file.setText(txt);
    }

    Timer {
        id: writeTimer
        interval: idx.writeDelayMs
        onTriggered: idx.flush()
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", idx._dir]
        running: false
    }
    Connections {
        target: mkdir
        function onExited(exitCode) {
            idx._dirReady = exitCode === 0;
            if (idx._dirReady)
                idx.flush();
            else
                console.log("NotesIndex: could not create " + idx._dir + "; " + idx.path + " is not written");
        }
    }

    // Parse and normalise; null when the text is not an index.
    function _parse(txt) {
        let d;
        try {
            d = JSON.parse(txt);
        } catch (e) {
            return null;
        }
        if (!d || typeof d !== "object" || d.version !== 1)
            return null;
        const out = idx._fresh();
        const s = d.sort || {};
        if (idx.modes.indexOf(s.mode) >= 0)
            out.sort.mode = s.mode;
        if (typeof s.ascending === "boolean")
            out.sort.ascending = s.ascending;
        const obj = v => v && typeof v === "object" && !Array.isArray(v) ? v : {};
        const o = obj(d.order);
        for (const f in o)
            if (Array.isArray(o[f]))
                out.order[f] = o[f].filter(k => typeof k === "string");
        const c = obj(d.colors);
        for (const k in c)
            if (typeof c[k] === "string" && c[k].length > 0)
                out.colors[k] = c[k];
        const z = obj(d.sizes);
        for (const k in z)
            if (z[k] && typeof z[k] === "object")
                out.sizes[k] = {
                    w: Number(z[k].w) || 0,
                    h: Number(z[k].h) || 0,
                    shift: Number(z[k].shift) || 0
                };
        const fs = obj(d.firstSeen);
        for (const k in fs)
            if (typeof fs[k] === "number")
                out.firstSeen[k] = fs[k];
        const ino = obj(d.inodes);
        for (const k in ino)
            if (typeof ino[k] === "number")
                out.inodes[k] = ino[k];
        return out;
    }

    function _onDisk(txt, initial) {
        // Our own write's echo, or the text we already hold (a touch, a
        // second notification): nothing to take in -- and re-reading it would
        // drop a change still waiting to be written.
        if (idx._recent.indexOf(txt) >= 0 || (txt.length > 0 && txt === idx._lastText))
            return;
        if (!txt || txt.length === 0) {
            // Missing (or emptied): nothing to take in. A file we had and
            // that is now gone is written again on the next change.
            if (initial)
                idx._fileValid = false;
            return;
        }
        idx._lastText = txt;
        idx._dirReady = true;
        const d = idx._parse(txt);
        if (d === null) {
            idx._corrupt = true;
            if (!idx._loggedCorrupt) {
                idx._loggedCorrupt = true;
                console.log("NotesIndex: " + idx.path + " is not a version-1 index; it is kept as it is and replaced by the first change");
            }
            return;
        }
        idx._d = d;
        idx._corrupt = false;
        idx._fileValid = true;
        idx._userDirty = false;
        idx._bookDirty = false;
        writeTimer.stop();
        if (!initial)
            idx.ingested();
    }

    FileView {
        id: file
        path: idx.path
        blockLoading: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: file.reload()
        onLoaded: idx._onDisk(file.text(), false)
    }

    Component.onCompleted: idx._onDisk(file.text(), true)
    Component.onDestruction: {
        if (writeTimer.running)
            idx.flush();
        file.waitForJob();
    }
}
