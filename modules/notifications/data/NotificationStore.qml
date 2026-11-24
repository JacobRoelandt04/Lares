pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "NotifyPolicy.js" as Policy

// =============================================================================
// NotificationStore.qml -- every notification record, as a model and on disk.
//
// THE MODEL. `model` is a ListModel of rows { uid, rec }, where `rec` is a
// QtObject { property var d } holding the record (CONTRACT "Record"). A row
// is kept BY POINTER for the life of its record: a change re-assigns `d` (a
// new object, never a mutation), so bindings that read it re-evaluate and a
// delegate is created only for a record that is really new (the LlmTranscript
// / StocksViewModel mirror law: a Repeater over a derived array rebuilds every
// delegate on every change). Rows are kept in NotifyPolicy.order() -- group
// order, pins first (newest pin first), then newest -- so a view can read the
// model top to bottom. A re-sort is a ListModel MOVE, which no binding can
// see: read `serial` first in anything that walks the model.
//
// ON DISK. $XDG_STATE_HOME/lares/notifications/history.json =
// { version: 1, records: [...] } in model order. Read once, synchronously, at
// completion; every record read back is `stale` (its live notification and
// callbacks belonged to another process). Written 300 ms after the last change,
// atomically, into a directory made first; a text equal to the last one read
// or written is not written again (the self-write guard). `persistFilter`
// (the service's: transient records and `history: false` rules) decides
// which records are written at all. A file that does not parse is copied to
// history.json.corrupt, named in `lastError`, and the store starts empty.
//
// IMAGES. `imagesDir` (<state>/notifications/images) holds the PNGs the UI
// grabbed of live images (`image.file`). A record's file is deleted with the
// record (`drop`), unless the caller keeps it for an undo window; at load,
// every PNG no record names is deleted. Only files INSIDE imagesDir are ever
// deleted -- an image-path the sender named is the user's file.
// =============================================================================
Item {
    id: root

    property bool persist: true
    property string historyPath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/notifications/history.json"
    // function(record) -> bool: write this record to history.json.
    property var persistFilter: null

    readonly property string imagesDir: root.historyPath.substring(0, root.historyPath.lastIndexOf("/")) + "/images"
    readonly property ListModel model: rows
    readonly property int serial: root._serial
    readonly property int count: root._count
    readonly property bool loaded: root._loaded
    readonly property string lastError: root._lastError

    signal changed()

    function get(uid) {
        const row = root._rows[uid];
        return row ? row.d : null;
    }

    function has(uid) {
        return !!root._rows[uid];
    }

    // Insert or replace. The record object is owned by the store from here:
    // callers never mutate it afterwards (use patch()).
    function put(record) {
        if (!record || typeof record.uid !== "string" || record.uid.length === 0)
            return false;
        const row = root._rows[record.uid];
        if (row) {
            row.d = record;
            root._resort();
        } else {
            const obj = recComp.createObject(root, { d: record });
            root._rows[record.uid] = obj;
            rows.insert(root._indexFor(record), { uid: record.uid, rec: obj });
        }
        root._changedNow();
        return true;
    }

    // A new `d` with `fields` over the old one. False when there is no such
    // record or nothing changed.
    function patch(uid, fields) {
        const row = root._rows[uid];
        if (!row)
            return false;
        const next = Object.assign({}, row.d);
        let diff = false;
        const keys = Object.keys(fields || {});
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (JSON.stringify(next[k]) !== JSON.stringify(fields[k])) {
                next[k] = fields[k];
                diff = true;
            }
        }
        if (!diff)
            return false;
        row.d = next;
        root._resort();
        root._changedNow();
        return true;
    }

    // Remove a record; its grabbed image goes with it unless `keepImage`
    // (the undo window keeps it until the window closes). Returns the record.
    function drop(uid, keepImage) {
        const row = root._rows[uid];
        if (!row)
            return null;
        const d = row.d;
        for (let i = 0; i < rows.count; i++) {
            if (rows.get(i).uid === uid) {
                rows.remove(i);
                break;
            }
        }
        delete root._rows[uid];
        row.destroy();
        if (!keepImage)
            root.deleteImage(d);
        root._changedNow();
        return d;
    }

    // Every record, in model (NotifyPolicy.order) order.
    function all() {
        const out = [];
        for (let i = 0; i < rows.count; i++)
            out.push(rows.get(i).rec.d);
        return out;
    }

    function imageFileFor(uid) {
        return root.imagesDir + "/" + uid + ".png";
    }

    // Delete a record's grabbed image (only ever inside imagesDir).
    function deleteImage(record) {
        const f = record && record.image ? String(record.image.file || "") : "";
        if (f.length === 0 || f.indexOf(root.imagesDir + "/") !== 0)
            return;
        root._rmQueue.push(f);
        root._pumpRm();
    }

    // The first read (idempotent). The store does it at completion; the
    // service calls it first, since onCompleted order is not defined.
    function ensureLoaded() {
        if (root._loaded)
            return;
        if (root.persist)
            root._ingest(file.text());
        root._loaded = true;
        if (root.persist)
            mkdir.running = true;
        else
            root._dirReady = true;
    }

    // Write now (the coalesced write, without waiting).
    function save() {
        root._flush();
    }

    // ---- Private -------------------------------------------------------------
    property var _rows: ({})
    property int _serial: 0
    property int _count: 0
    property bool _loaded: false
    property bool _dirReady: false
    property string _selfWrite: ""
    property string _lastError: ""
    property int _writes: 0
    property int _imagesDeleted: 0
    property var _rmQueue: []

    Component {
        id: recComp
        QtObject {
            property var d: ({})
        }
    }

    ListModel {
        id: rows
    }

    function _changedNow() {
        root._count = rows.count;
        root._serial++;
        root.changed();
        root._scheduleSave();
    }

    function _indexFor(record) {
        const order = Policy.order(root.all().concat([record]));
        for (let i = 0; i < order.length; i++)
            if (order[i].uid === record.uid)
                return i;
        return rows.count;
    }

    // Bring the model into NotifyPolicy.order() with moves (rows keep their
    // objects; a view animates a move, it does not rebuild).
    function _resort() {
        const want = Policy.order(root.all());
        for (let i = 0; i < want.length; i++) {
            if (rows.get(i).uid === want[i].uid)
                continue;
            for (let j = i + 1; j < rows.count; j++) {
                if (rows.get(j).uid === want[i].uid) {
                    rows.move(j, i, 1);
                    break;
                }
            }
        }
    }

    function _scheduleSave() {
        if (!root.persist || !root._loaded)
            return;
        writeTimer.restart();
    }

    function _serialize() {
        const out = [];
        const recs = root.all();
        for (let i = 0; i < recs.length; i++) {
            const r = recs[i];
            if (r.transient)
                continue;
            if (root.persistFilter && !root.persistFilter(r))
                continue;
            out.push(r);
        }
        return JSON.stringify({ version: 1, records: out }, null, 1) + "\n";
    }

    function _flush() {
        if (!root.persist || !root._loaded)
            return;
        if (!root._dirReady) {
            writeTimer.restart();
            return;
        }
        writeTimer.stop();
        const txt = root._serialize();
        if (txt === root._selfWrite)
            return;
        root._selfWrite = txt;
        root._writes++;
        file.setText(txt);
    }

    function _valid(r) {
        return r && typeof r === "object" && typeof r.uid === "string" && r.uid.length > 0
            && (r.origin === "dbus" || r.origin === "shell") && typeof r.summary === "string";
    }

    function _ingest(txt) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        root._selfWrite = t;
        if (t.trim().length === 0)
            return;
        let o = null;
        try {
            o = JSON.parse(t);
        } catch (e) {
            o = null;
        }
        if (!o || typeof o !== "object" || !Array.isArray(o.records)) {
            root._lastError = "history.json does not parse; it was copied to history.json.corrupt and the history starts empty";
            backup.command = ["cp", "-f", "--", root.historyPath, root.historyPath + ".corrupt"];
            backup.running = true;
            root._selfWrite = "";
            return;
        }
        const recs = [];
        for (let i = 0; i < o.records.length; i++) {
            const r = o.records[i];
            if (!root._valid(r) || root._rows[r.uid])
                continue;
            const d = Object.assign({}, r, { stale: true });
            recs.push(d);
            root._rows[d.uid] = recComp.createObject(root, { d: d });
        }
        const sorted = Policy.order(recs);
        for (let i = 0; i < sorted.length; i++)
            rows.append({ uid: sorted[i].uid, rec: root._rows[sorted[i].uid] });
        root._count = rows.count;
        root._serial++;
    }

    // Every PNG in imagesDir that no record names goes.
    function _sweepOrphans(listing) {
        const keep = {};
        const recs = root.all();
        for (let i = 0; i < recs.length; i++)
            if (recs[i].image && recs[i].image.file)
                keep[recs[i].image.file] = true;
        const names = String(listing || "").split("\n");
        for (let i = 0; i < names.length; i++) {
            const n = names[i].trim();
            if (n.length === 0 || !/\.png$/.test(n))
                continue;
            const f = root.imagesDir + "/" + n;
            if (!keep[f])
                root._rmQueue.push(f);
        }
        root._pumpRm();
    }

    function _pumpRm() {
        if (rm.running || root._rmQueue.length === 0)
            return;
        const files = root._rmQueue;
        root._rmQueue = [];
        root._imagesDeleted += files.length;
        rm.command = ["rm", "-f", "--"].concat(files);
        rm.running = true;
    }

    Timer {
        id: writeTimer
        interval: 300
        onTriggered: root._flush()
    }

    FileView {
        id: file
        path: root.persist ? root.historyPath : ""
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", root.imagesDir]
        running: false
    }
    Connections {
        target: mkdir
        function onExited() {
            root._dirReady = true;
            lister.running = true;
        }
    }

    Process {
        id: lister
        command: ["ls", "-1", "--", root.imagesDir]
        running: false
        stdout: StdioCollector {
            id: listOut
        }
    }
    Connections {
        target: lister
        function onExited() { root._sweepOrphans(listOut.text); }
    }

    Process {
        id: rm
        running: false
    }
    Connections {
        target: rm
        function onExited() { root._pumpRm(); }
    }

    Process {
        id: backup
        running: false
    }

    Component.onCompleted: root.ensureLoaded()
}
