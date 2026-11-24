pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "data"

// =============================================================================
// NotesStore.qml -- everything the notes popup must still know after it
// closes. The popup is content the bar engine builds on open and destroys on
// close (GooeyEngine), so it holds nothing: the view it was in, the folder,
// the open note with its caret and scroll, the documents being edited (with
// their undo), the sizes -- all live here, owned bar-side (NotesBarOwner) or
// by the mockup.
//
// Files go through NotesService (scan, watch, every file operation) and one
// NoteFile per open note's REAL path (a foreign note is edited where it
// lives; its symlink is only its place in the list). A document is written
// 800 ms after the last change (5 s at most while typing), and at once on
// back, on switching note, on a drop, on close and when the store goes away.
//
// A new note is a document with no file until it has text: its first write
// creates the file (NotesService.createNote, Obsidian suffix on a clash,
// `newName` when the title is empty) and from then on it is a note like
// any other.
// =============================================================================
Scope {
    id: store

    property string root: (Quickshell.env("HOME") || "") + "/Documents/Notes"
    property string statePath: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/notes/session.json"
    // The name of a note that has none.
    property alias newName: svc.newName
    // A popup is open: the service scans and watches. COUNTED: in the shell one store serves the popup of every
    // screen, and a flag each popup wrote (true when it opened, false when it closed) would let the first to close
    // stop the watching under the others -- a popup holds the store for as long as it exists.
    property int holders: 0
    readonly property bool active: store.holders > 0
    function hold() {
        store.holders += 1;
    }
    function release() {
        store.holders = Math.max(0, store.holders - 1);
    }
    property int autosaveMs: 800
    property int autosaveMaxMs: 5000
    property int keepOpen: 5
    property var defaultBrowseSize: ({
            w: 560,
            h: 440,
            shift: 0
        })
    property var defaultNoteSize: ({
            w: 420,
            h: 480,
            shift: 0
        })
    readonly property alias service: svc

    // ---- The view ------------------------------------------------------------------------------
    property string view: "browse"
    property string folder: ""
    property string noteKey: ""
    property string query: ""
    property var searchKeys: null
    // A new note that has no file yet, and the folder it will be made in.
    property bool newNote: false
    property string newNoteFolder: ""
    // Where the caret and the scroll were, per note, for reopening.
    property var noteSession: ({})
    property int docSerial: 0

    signal noteOpened(string key)
    signal conflictChanged(string key)

    NotesService {
        id: svc
        root: store.root
        active: store.active
    }

    // ---- Documents ---------------------------------------------------------------------------------
    property var _docs: ({})
    property var _lru: []

    Component {
        id: docComp
        LineDocument {}
    }
    Component {
        id: fileComp
        NoteFile {}
    }

    readonly property string currentId: store.newNote ? "__new__" : store.noteKey
    readonly property var current: store.docSerial >= 0 ? (store._docs[store.currentId] || null) : null

    function entryOf(key) {
        return key ? svc.entry(key) : null;
    }

    function titleOf(key) {
        const e = store.entryOf(key);
        return e ? e.title : "";
    }

    function _makeRecord(id, realPath) {
        const doc = docComp.createObject(store);
        const rec = {
            id: id,
            doc: doc,
            file: null,
            realPath: realPath || "",
            conflict: null,
            problem: "",
            since: 0
        };
        if (realPath) {
            rec.file = fileComp.createObject(store, {
                path: realPath
            });
            const text = rec.file.read();
            doc.load(text === null ? "" : text);
            doc.readOnly = rec.file.invalid;
            if (rec.file.invalid)
                rec.problem = "Read-only: not valid UTF-8 text";
            store._wire(rec);
        } else {
            doc.load("");
        }
        doc.serialChanged.connect(() => store._touched(rec));
        return rec;
    }

    // The file's outside changes and write failures. A failure is kept on the
    // record (`problem`, one line the pane shows) until the next write is issued.
    function _wire(rec) {
        rec.file.externalChange.connect(t => store._external(rec, t));
        rec.file.writeFailed.connect(err => {
            console.warn("notes: write failed for " + rec.realPath + ": " + err);
            rec.problem = "Not saved: " + err;
            store.docSerial++;
        });
    }

    function _remember(rec) {
        const d = Object.assign({}, store._docs);
        d[rec.id] = rec;
        store._docs = d;
        store._lru = [rec.id].concat(store._lru.filter(k => k !== rec.id));
        while (store._lru.length > store.keepOpen) {
            const old = store._lru.pop();
            store._drop(old);
        }
        store.docSerial++;
    }

    function _drop(id) {
        const rec = store._docs[id];
        if (!rec)
            return;
        store.saveNow(rec);
        if (rec.file) {
            rec.file.flush();
            rec.file.destroy();
        }
        rec.doc.destroy();
        const d = Object.assign({}, store._docs);
        delete d[id];
        store._docs = d;
    }

    function openNote(key) {
        const e = svc.entry(key);
        if (!e || e.isGroup || e.broken)
            return false;
        store.saveAll();
        if (store.newNote)
            store._discardNew();
        let rec = store._docs[key];
        if (!rec)
            rec = store._makeRecord(key, e.realPath);
        store._remember(rec);
        store.newNote = false;
        store.noteKey = key;
        store.view = "editor";
        store.docSerial++;
        store.noteOpened(key);
        store.saveSession();
        return true;
    }

    function startNewNote(folderKey) {
        store.saveAll();
        if (store.newNote)
            store._discardNew();
        const rec = store._makeRecord("__new__", "");
        store._remember(rec);
        store.newNote = true;
        store.newNoteFolder = folderKey || "";
        store.noteKey = "";
        store.view = "editor";
        store.docSerial++;
        store.noteOpened("");
    }

    // A new note left without a single character is not a file.
    function _discardNew() {
        const rec = store._docs["__new__"];
        if (rec && rec.doc.text().length > 0)
            store.saveNow(rec);
        else
            store._drop("__new__");
        store.newNote = false;
    }

    // What a popup opens on, told before it is built: "last" is where the store stands, "root" the tiles, "new" a new note (one that
    // holds text and has no file yet IS the new note). A popup that is out, on any screen, keeps what it shows.
    function arriveAt(where) {
        if (where === "last" || store.holders > 0)
            return;
        if (where === "new" && store.newNote && store.current && store.current.doc.text().length > 0)
            return;
        store.saveAll();
        if (store.newNote)
            store._discardNew();
        store.setQuery("");
        store.folder = "";
        store.view = "browse";
        if (where === "new")
            store.startNewNote("");
    }

    function back() {
        store.saveAll();
        if (store.view === "editor") {
            if (store.newNote)
                store._discardNew();
            store.view = "browse";
            const e = store.entryOf(store.noteKey);
            if (e)
                store.folder = e.parentKey;
        } else if (store.query !== "") {
            store.setQuery("");
        } else if (store.folder !== "") {
            const e = store.entryOf(store.folder);
            store.folder = e ? e.parentKey : "";
        }
        store.saveSession();
    }

    // ---- Saving ------------------------------------------------------------------------------------------
    function _touched(rec) {
        if (!rec.doc.dirty)
            return;
        if (!rec.since)
            rec.since = Date.now();
        saveTimer.restart();
        if (Date.now() - rec.since >= store.autosaveMaxMs)
            store.saveNow(rec);
    }

    Timer {
        id: saveTimer
        interval: store.autosaveMs
        onTriggered: store.saveAll()
    }

    function saveAll() {
        for (const id in store._docs)
            store.saveNow(store._docs[id]);
    }

    function saveNow(rec) {
        if (!rec || !rec.doc.dirty || rec.doc.readOnly || rec.conflict)
            return;
        rec.since = 0;
        if (rec.file) {
            if (rec.problem !== "") {
                rec.problem = "";
                store.docSerial++;
            }
            rec.file.write(rec.doc.text());
            rec.doc.markSaved();
            return;
        }
        if (rec.id !== "__new__" || rec.creating)
            return;
        const text = rec.doc.text();
        if (text.length === 0)
            return;
        rec.creating = true;
        const serialAtSave = rec.doc.serial;
        store._op(svc.createNote(store.newNoteFolder, store.pendingTitle, text), (ok, key) => {
            rec.creating = false;
            if (!ok)
                return;
            const e = svc.entry(key);
            const real = e ? e.realPath : (svc.canonicalRoot + "/" + key);
            rec.file = fileComp.createObject(store, {
                path: real
            });
            rec.realPath = real;
            store._wire(rec);
            // What was typed while the file was being made is written now.
            if (rec.doc.serial !== serialAtSave)
                rec.file.write(rec.doc.text());
            rec.doc.markSaved();
            // noteKey BEFORE newNote: while newNote holds, the current id is
            // "__new__"; flipped first it would be "" for a step.
            store._rekey("__new__", key, () => {
                if (store.newNote) {
                    store.noteKey = key;
                    store.newNote = false;
                }
            });
            store.pendingTitle = "";
            store.saveSession();
        });
    }
    // The title typed into a new note before its file exists.
    property string pendingTitle: ""

    // A record changes key (a new note's first save, a rename). The record is
    // held under BOTH keys while `switchCurrent` moves the current id across,
    // so `current` never reads a key that has nothing: removing the old key
    // first would make it null for a step, the editor's document would go null and
    // come back, reloaded, and the keys typed meanwhile would be lost or land
    // elsewhere.
    function _rekey(oldId, newId, switchCurrent) {
        const rec = store._docs[oldId];
        if (!rec) {
            if (switchCurrent)
                switchCurrent();
            return;
        }
        rec.id = newId;
        const both = Object.assign({}, store._docs);
        both[newId] = rec;
        store._docs = both;
        if (switchCurrent)
            switchCurrent();
        const d = Object.assign({}, store._docs);
        delete d[oldId];
        store._docs = d;
        store._lru = store._lru.map(k => k === oldId ? newId : k);
        const s = Object.assign({}, store.noteSession);
        if (s[oldId]) {
            s[newId] = s[oldId];
            delete s[oldId];
            store.noteSession = s;
        }
        store.docSerial++;
    }

    // An outside change: silently reloaded when nothing is unsaved here, a
    // conflict the pane asks about when something is.
    function _external(rec, text) {
        if (!rec.doc.dirty) {
            store._applyText(rec, text);
            return;
        }
        rec.conflict = text;
        store.docSerial++;
        store.conflictChanged(rec.id);
    }

    function _applyText(rec, text) {
        const t = String(text);
        const bom = t.charCodeAt(0) === 0xFEFF;
        const body = bom ? t.substring(1) : t;
        const doc = rec.doc;
        const last = doc.lineCount - 1;
        doc.bom = bom;
        doc.replace(0, 0, last, doc.lines[last].length, body, {
            raw: true,
            keepCaret: true
        });
        doc.setCaret(doc.caret, doc.anchor);
        doc.markSaved();
    }

    function keepMine(id) {
        const rec = store._docs[id];
        if (!rec)
            return;
        rec.conflict = null;
        store.docSerial++;
        store.saveNow(rec);
        store.conflictChanged(id);
    }

    function loadTheirs(id) {
        const rec = store._docs[id];
        if (!rec || rec.conflict === null)
            return;
        const t = rec.conflict;
        rec.conflict = null;
        store._applyText(rec, t);
        store.docSerial++;
        store.conflictChanged(id);
    }

    // ---- Renames (the title is the file name) -------------------------------------------------------------
    function commitTitle(text) {
        const t = String(text || "").trim();
        if (store.newNote) {
            store.pendingTitle = t;
            return;
        }
        const e = store.entryOf(store.noteKey);
        if (!e || t === "" || t === e.title)
            return;
        const oldKey = store.noteKey;
        store.saveAll();
        store._op(svc.renameEntry(oldKey, t), (ok, newKey) => {
            if (ok)
                store._followRename(oldKey, newKey);
        });
    }

    function _followRename(oldKey, newKey) {
        const rec = store._docs[oldKey];
        if (rec) {
            const e = svc.entry(newKey);
            const real = e ? e.realPath : "";
            // A foreign note's real file keeps its path (only the link was
            // renamed); an own note's file moved: new FileView, never a
            // repointed one.
            if (real && real !== rec.realPath) {
                if (rec.file) {
                    rec.file.flush();
                    rec.file.destroy();
                }
                rec.file = fileComp.createObject(store, {
                    path: real
                });
                rec.file.externalChange.connect(t => store._external(rec, t));
                rec.realPath = real;
            }
        }
        store._rekey(oldKey, newKey, () => {
            if (store.noteKey === oldKey)
                store.noteKey = newKey;
        });
        if (store.folder === oldKey || store.folder.indexOf(oldKey + "/") === 0)
            store.folder = newKey + store.folder.substring(oldKey.length);
        store.saveSession();
    }

    Connections {
        target: svc
        function onEntryRenamed(oldKey, newKey) {
            store._followRename(oldKey, newKey);
        }
        function onOpDone(id, ok, result, error) {
            const cb = store._pending[id];
            if (!cb)
                return;
            delete store._pending[id];
            cb(ok, result, error);
        }
        function onSearchDone(q, keys) {
            if (q === store.query)
                store.searchKeys = keys;
        }
        function onPicked(paths) {
            store.dropFiles(paths);
        }
    }

    property var _pending: ({})
    function _op(id, cb) {
        if (id === undefined || id === null || id < 0) {
            cb(false, null, "refused");
            return;
        }
        store._pending[id] = cb;
    }

    // ---- Search -----------------------------------------------------------------------------------------------
    function setQuery(q) {
        store.query = q;
        if (q === "") {
            store.searchKeys = null;
            return;
        }
        svc.search(q);
    }

    // ---- Drops, wikilinks, images -------------------------------------------------------------------------
    // Files dropped on the popup (or picked in the portal): symlinked into
    // the folder being viewed and the first one opened. An image dropped
    // while a note is open is linked into the note instead -- the pane
    // does that before calling here.
    function dropFiles(paths, onRefused) {
        store.saveAll();
        const dest = store.view === "editor" ? (store.entryOf(store.noteKey) ? store.entryOf(store.noteKey).parentKey : store.folder) : store.folder;
        let first = true;
        for (const p of paths) {
            const isFirst = first;
            first = false;
            store._op(svc.addForeign(p, dest), (ok, res, err) => {
                if (!ok) {
                    if (onRefused)
                        onRefused(err);
                    return;
                }
                if (isFirst && res && res.key)
                    Qt.callLater(() => store.openNote(res.key));
            });
        }
    }

    function openWiki(target) {
        const t = String(target).split("#")[0].trim().toLowerCase();
        if (!t)
            return;
        for (let i = 0; i < svc.entries.count; i++) {
            const r = svc.entries.get(i);
            if (!r.isGroup && (r.title.toLowerCase() === t || r.name.toLowerCase() === t)) {
                store.openNote(r.key);
                return;
            }
        }
        const here = store.entryOf(store.noteKey);
        store._op(svc.createNote(here ? here.parentKey : store.folder, String(target).split("#")[0].trim(), ""), (ok, key) => {
            if (ok)
                Qt.callLater(() => store.openNote(key));
        });
    }

    // The clipboard's image, saved into .attachments; cb(absPath).
    function pasteImage(cb) {
        store._op(svc.saveClipboardImage(), (ok, path) => {
            if (ok && path)
                cb(path);
        });
    }

    function realDirOf(key) {
        const e = store.entryOf(key);
        if (!e || !e.realPath)
            return svc.canonicalRoot || store.root;
        return e.realPath.substring(0, e.realPath.lastIndexOf("/"));
    }

    // ---- Sizes --------------------------------------------------------------------------------------------------
    function sizeKeyFor(v) {
        return v === "editor" ? (store.newNote ? "__new__" : store.noteKey) : "";
    }
    // The browse page has ONE size, the default (the grid
    // is not resized); a size stored for it is ignored.
    // Notes keep a size each.
    function sizeFor(key) {
        const s = key === "__new__" || key === "" ? null : svc.sizeOf(key);
        const d = key === "" ? store.defaultBrowseSize : store.defaultNoteSize;
        return s ? {
            w: s.w || d.w,
            h: s.h || d.h,
            shift: s.shift || 0
        } : {
            w: d.w,
            h: d.h,
            shift: 0
        };
    }
    function isDefaultSize(key, s) {
        const d = key === "" ? store.defaultBrowseSize : store.defaultNoteSize;
        return Math.abs(s.w - d.w) < 0.5 && Math.abs(s.h - d.h) < 0.5 && Math.abs(s.shift || 0) < 0.5;
    }
    function setSize(key, s) {
        if (key === "__new__" || key === "")
            return;
        svc.setSize(key, s ? {
            w: Math.round(s.w),
            h: Math.round(s.h),
            // Half pixels kept: whole-pixel edges need them (EdgeResize.js).
            shift: Math.round((s.shift || 0) * 2) / 2
        } : null);
    }

    // ---- Session -------------------------------------------------------------------------------------------------
    FileView {
        id: sessionFile
        path: store.statePath
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", store.statePath.substring(0, store.statePath.lastIndexOf("/"))]
    }

    function rememberPlace(id, caret, anchor, scroll) {
        if (!id)
            return;
        const s = Object.assign({}, store.noteSession);
        s[id] = {
            caret: caret,
            anchor: anchor,
            scroll: scroll
        };
        store.noteSession = s;
        store.saveSession();
    }

    function saveSession() {
        sessionTimer.restart();
    }
    Timer {
        id: sessionTimer
        interval: 300
        onTriggered: {
            const keep = {};
            for (const k of store._lru)
                if (store.noteSession[k])
                    keep[k] = store.noteSession[k];
            if (store.noteSession[store.noteKey])
                keep[store.noteKey] = store.noteSession[store.noteKey];
            const obj = {
                version: 1,
                root: store.root,
                notes: keep
            };
            if (!mkdir.running)
                mkdir.running = true;
            sessionFile.setText(JSON.stringify(obj, null, 1) + "\n");
        }
    }

    Component.onCompleted: {
        try {
            const t = sessionFile.text();
            if (t) {
                const o = JSON.parse(t);
                if (o && o.version === 1 && o.root === store.root)
                    store.noteSession = o.notes || {};
            }
        } catch (e) {
            console.warn("notes: session unreadable, starting fresh");
        }
    }

    // The popup opened (and again when a scan lands): the folder the user left
    // it in is still there, or the root is. Where the user WAS -- the view, the
    // folder, the note -- lives in this object and so lasts as long as the
    // shell does and no longer: it is not written to the session file, because
    // a new shell session (a boot) that opened where the last one stopped would send
    // the user into a group when they expect the root.
    // The file keeps what belongs to a NOTE, not to a visit: the caret and the
    // scroll it was left at.
    function restore() {
        if (store.folder && !svc.entry(store.folder))
            store.folder = "";
    }
    Connections {
        target: svc
        function onReadyChanged() {
            if (svc.ready)
                store.restore();
        }
    }

    Component.onDestruction: {
        store.saveAll();
        for (const id in store._docs)
            if (store._docs[id].file)
                store._docs[id].file.flush();
    }
}
