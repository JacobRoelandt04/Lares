pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/system"

import "NotesScan.js" as S

// =============================================================================
// NotesService.qml -- the notes module's data layer: the notes under `root`
// as one flat ListModel of facts, the ops that change the tree, the metadata
// file, search, the file-manager portal and the watch that keeps it all live.
// No visual items; it lives bar-side (NotesStore) and survives the popup.
//
// THE TREE. A note is a text file (by MIME: text/*, or an empty file); a
// GROUP is a folder, nested to any depth; a FOREIGN note is a symlink to a
// text file elsewhere (always an absolute link). Hidden names are never
// listed, nor is anything that is not text, a folder or a link to text; a
// broken link is listed, `broken: true`. The title is the file name with
// ".md" hidden (every other extension stays: "script.py").
//
// THE MODEL. `entries` has one row per listed entry at ALL depths (see the
// roles below), changed IN PLACE by key -- setProperty/set, append, remove,
// never a reset -- so a delegate keeps its identity through a rename (the
// row's key changes, the row stays). `serial` bumps on every change to the
// rows or to what orders them (sort, custom order, colour, size); a binding
// that walks the model or calls children() reads it first. children(key)
// is the display order of one folder: groups MIXED with notes, sorted by the
// global mode, custom order per folder (unknown keys first).
//
// THE OPS. Each returns an op id at once; `opDone(id, ok, result, error)`
// follows when the op is finished AND the model shows it (a created note's
// row exists when opDone says its key). Every op runs through NotesFileOps,
// one shell at a time; names never clash (Obsidian suffix, verified moves);
// a group an op empties is removed. Renames and moves -- ours, and outside
// ones found by inode -- carry the key's colour, size and custom-order slot,
// and emit entryRenamed(old, new) for the entry AND every row under it
// (open editors follow their exact key).
//
// THE WATCH. `active` scans at once and watches: inotifywait -r over the
// root (hidden paths excluded, so a .git inside is never watched) and a
// second, NON-recursive one over the folders the foreign notes live in (a
// note in ~ must not put all of ~ under watch); events are gathered for
// `watchDelayMs` and only the folders they touched are rescanned -- their
// direct children, plus the whole of a folder met for the first time (a
// folder renamed is recognised by inode and its rows move with it). `watching`
// says the root's watches are established (a scan follows that moment, so
// nothing between the first scan and the watch is missed).
//
// Everything that is a path is injectable: `root` (tests and the mockup use
// temp roots; the module passes ~/Documents/Notes) and `portalHelper`.
//
// A QtObject rather than a Scope: a Scope's default property is `children`,
// and `children(key)` is this API's. So every part is held by a property.
// =============================================================================
QtObject {
    id: svc

    // ---- Wiring --------------------------------------------------------------
    // Absolute; set once (a new root rebuilds everything). Need not exist yet:
    // the first op that writes creates it.
    property string root: ""
    property bool active: false
    // The name of a note that has none.
    property string newName: "Untitled"
    readonly property string untitled: S.sanitize(svc.newName) || "Untitled"
    property string portalHelper: RepoRoot.dir + "/tools/notes/portal_pick.py"
    property int watchDelayMs: 150
    property int searchDelayMs: 150

    // ---- State -----------------------------------------------------------------
    readonly property bool ready: svc._ready
    readonly property bool watching: svc._watching
    readonly property alias entries: rowsModel
    readonly property int serial: svc._serial
    readonly property string canonicalRoot: svc._canon
    // { ms, applyMs, dirs, entries, mimed, headed } of the last scan that
    // landed: ms from the first tool to the model updated; applyMs the part
    // spent in JS on this thread (parsing and the model).
    property string sortMode: "name"
    property bool sortAscending: true

    // Row roles (facts only; a colour is a KEY, never a colour):
    //   key parentKey name title ext kind isGroup isLink broken realPath
    //   linkTarget mime size mtimeMs btimeMs inode depth colorKey head childCount
    // ext: without its dot ("md"); kind: "markdown" (.md .markdown .txt) or
    // "text" ("" for a group); realPath: absolute, resolved (a link's target);
    // linkTarget: the link as written ("" for a non-link); size / mtimeMs of
    // a link are its TARGET's, of a group the sum / the newest of the notes
    // under it; btimeMs: birth time, or when the key was first seen where the
    // file system has none; head: the first <= 4096 bytes, decoded ("" for
    // groups and broken links); childCount: listed direct children.

    signal opDone(int id, bool ok, var result, string error)
    signal picked(var absPaths)
    signal searchDone(string query, var keys)
    signal entryRenamed(string oldKey, string newKey)

    // =========================================================================
    //  Reading
    // =========================================================================

    // The keys of `parentKey`'s direct children, in display order.
    function children(parentKey) {
        const p = parentKey || "";
        // The cache is one object MUTATED IN PLACE: children() is called from
        // bindings, and a binding that assigns a property it reads is a
        // binding loop (CLAUDE.md's counting-instrument law). Reading
        // `_serial` is what makes the binding follow changes.
        const cc = svc._childCache;
        if (cc.serial !== svc._serial) {
            cc.map = {};
            cc.serial = svc._serial;
        }
        const hit = cc.map[p];
        if (hit)
            return hit.slice();
        const rows = [];
        for (const k in svc._rows)
            if (svc._rows[k].parentKey === p)
                rows.push(svc._rows[k]);
        const keys = S.sortKeys(rows, svc.sortMode, svc.sortAscending, svc._idx ? svc._idx.orderOf(p) : []);
        cc.map[p] = keys;
        return keys.slice();
    }
    // A plain copy of the row, or null.
    function entry(key) {
        const r = svc._rows[key];
        return r ? Object.assign({}, r) : null;
    }
    function colorOf(key) {
        return svc._idx ? svc._idx.colorOf(key) : "";
    }
    // {w, h, shift} or null; key "" is the browse view.
    function sizeOf(key) {
        return svc._idx ? svc._idx.sizeOf(key) : null;
    }

    // =========================================================================
    //  Metadata
    // =========================================================================

    function setSort(mode, ascending) {
        svc._sortGuard = true;
        svc.sortMode = mode;
        svc.sortAscending = !!ascending;
        svc._sortGuard = false;
        svc._persistSort();
    }
    onSortModeChanged: {
        if (!svc._sortGuard)
            svc._persistSort();
    }
    onSortAscendingChanged: {
        if (!svc._sortGuard)
            svc._persistSort();
    }
    function _persistSort() {
        if (svc._idx)
            svc._idx.setSort(svc.sortMode, svc.sortAscending);
        svc._bump();
    }

    function setColor(key, colorKey) {
        if (!svc._idx || !svc._rows[key])
            return;
        if (!svc._idx.setColor(key, colorKey || ""))
            return;
        svc._setRole(key, "colorKey", svc._idx.colorOf(key));
        svc._bump();
    }
    function setCustomOrder(parentKey, keys) {
        if (svc._idx && svc._idx.setOrder(parentKey || "", keys || []))
            svc._bump();
    }
    function setSize(key, sizeObjOrNull) {
        if (svc._idx && svc._idx.setSize(key || "", sizeObjOrNull))
            svc._bump();
    }

    // =========================================================================
    //  Ops -- each returns an op id; opDone(id, ok, result, error) follows.
    // =========================================================================

    // result: the new note's key. "" -> `untitled`; ".md" is appended.
    function createNote(parentKey, baseName, text) {
        const p = parentKey || "";
        return svc._op(() => {
            if (!svc._isFolder(p))
                return svc._fail("parent");
            const base = S.sanitize(baseName) || svc.untitled;
            return {
                step: {
                    script: ops.createScript,
                    args: [svc._rootPath, S.absOf(svc._rootPath, p), base, ".md"],
                    stdin: String(text === undefined || text === null ? "" : text)
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(t.E || "create", [p]);
                    return svc._ok(S.join(p, t.N), [p]);
                }
            };
        });
    }

    // Keeps the note's extension (a trailing copy of it in the new name is
    // not doubled: "tool" and "tool.py" both give "tool.py"); a link renames
    // only the link. result: the new key.
    function renameEntry(key, newBaseName) {
        return svc._op(() => {
            const r = svc._rows[key];
            if (!r)
                return svc._fail("missing");
            let base = S.sanitize(newBaseName);
            const ext = r.isGroup ? "" : S.splitExt(r.name).ext;
            if (ext.length > 0 && base.length > ext.length && base.substring(base.length - ext.length).toLowerCase() === ext.toLowerCase())
                base = base.substring(0, base.length - ext.length).trim();
            if (base.length === 0)
                return svc._fail("name");
            if (base + ext === r.name)
                return svc._ok(key, []);
            const p = r.parentKey;
            return {
                step: {
                    script: ops.renameScript,
                    args: [svc._rootPath, S.absOf(svc._rootPath, key), S.absOf(svc._rootPath, p), base, ext]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(svc._mvError(t.E), [p]);
                    const nk = S.join(p, t.N);
                    svc._renameEverywhere(key, nk);
                    return svc._ok(nk, r.isGroup ? [p, svc._deep(nk)] : [p]);
                }
            };
        });
    }

    // result: the new key. Refuses the entry itself or anything under it as
    // the destination (error "cycle"); a group this empties is removed.
    function moveEntry(key, destParentKey) {
        const dest = destParentKey || "";
        return svc._op(() => {
            const r = svc._rows[key];
            if (!r)
                return svc._fail("missing");
            if (S.isSelfOrUnder(dest, key))
                return svc._fail("cycle");
            if (!svc._isFolder(dest))
                return svc._fail("parent");
            if (r.parentKey === dest)
                return svc._ok(key, []);
            const src = r.parentKey;
            const nm = r.isGroup ? { base: r.name, ext: "" } : S.splitExt(r.name);
            return {
                step: {
                    script: ops.moveScript,
                    args: [svc._rootPath, S.absOf(svc._rootPath, key), S.absOf(svc._rootPath, dest), nm.base, nm.ext, S.absOf(svc._rootPath, src)]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(svc._mvError(t.E), [src, dest]);
                    const nk = S.join(dest, t.N);
                    svc._renameEverywhere(key, nk);
                    svc._removeKeys(t.R, false);
                    const again = [dest, svc._survivor(src, t.R)];
                    if (r.isGroup)
                        again.push(svc._deep(nk));
                    return svc._ok(nk, again);
                }
            };
        });
    }

    // A new group ("Group", + suffix) in the target's folder, the target and
    // the dragged entry moved into it; the group takes the target's slot in
    // that folder's custom order. result: the group's key.
    function makeGroup(targetKey, draggedKey) {
        return svc._op(() => {
            const t = svc._rows[targetKey], d = svc._rows[draggedKey];
            if (!t || !d)
                return svc._fail("missing");
            if (targetKey === draggedKey)
                return svc._fail("cycle");
            const P = t.parentKey;
            if (S.isSelfOrUnder(P, draggedKey))
                return svc._fail("cycle");
            const tn = t.isGroup ? { base: t.name, ext: "" } : S.splitExt(t.name);
            const dn = d.isGroup ? { base: d.name, ext: "" } : S.splitExt(d.name);
            const dsrc = d.parentKey;
            const A = k => S.absOf(svc._rootPath, k);
            return {
                step: {
                    script: ops.groupScript,
                    args: [svc._rootPath, A(P), A(targetKey), tn.base, tn.ext, A(draggedKey), dn.base, dn.ext, A(dsrc)]
                },
                done: res => {
                    const g = svc._tags(res);
                    if (!g.G)
                        return svc._fail(g.E || "mkdir", [P]);
                    const gk = S.join(P, g.G);
                    if (g.T) {
                        if (svc._idx)
                            svc._idx.setOrder(P, svc._idx.orderOf(P).map(k => k === targetKey ? gk : k));
                        svc._renameEverywhere(targetKey, S.join(gk, g.T));
                    }
                    if (g.D)
                        svc._renameEverywhere(draggedKey, S.join(gk, g.D));
                    svc._removeKeys(g.R, false);
                    if (!g.T || !g.D)
                        return svc._fail(g.E || "move", [P, svc._survivor(dsrc, g.R)]);
                    if (svc._idx)
                        svc._idx.setOrder(gk, [S.join(gk, g.T), S.join(gk, g.D)]);
                    return svc._ok(gk, [P, svc._survivor(dsrc, g.R)]);
                }
            };
        });
    }

    // Notes and groups under the root go to the trash (`gio trash`). A LINK
    // is refused ("foreign"): a foreign note is only ever unlinked.
    function trashEntry(key) {
        return svc._op(() => {
            const r = svc._rows[key];
            if (!r)
                return svc._fail("missing");
            if (r.isLink)
                return svc._fail("foreign");
            return svc._removeOp(ops.trashScript, key);
        });
    }
    // Links only ("notlink" otherwise); the target is never touched.
    function unlinkEntry(key) {
        return svc._op(() => {
            const r = svc._rows[key];
            if (!r)
                return svc._fail("missing");
            if (!r.isLink)
                return svc._fail("notlink");
            return svc._removeOp(ops.unlinkScript, key);
        });
    }

    // A dropped file. result: { key, existed }. A file under the root is
    // just its key; the same real file already linked anywhere is that link;
    // anything else becomes an absolute link in `destParentKey` (Obsidian
    // suffix on a clash). Only text (text/*, or empty): error "type".
    function addForeign(absPath, destParentKey) {
        const dest = destParentKey || "";
        const src = String(absPath || "");
        return svc._op(() => {
            if (src.charAt(0) !== "/")
                return svc._fail("path");
            if (!svc._isFolder(dest))
                return svc._fail("parent");
            return {
                step: {
                    script: ops.foreignCheckScript,
                    args: [src]
                },
                done: res => {
                    const c = svc._checked(res.out);
                    if (!c.P)
                        return svc._fail(c.E || "missing");
                    if (!S.isNote(c.M, c.headOk, S.baseOf(c.P)))
                        return svc._fail("type");
                    const real = c.P;
                    const rel = svc._canon ? S.relOf(svc._canon, real) : null;
                    if (rel !== null && rel !== "" && !S.isHiddenRel(rel))
                        return svc._ok({ key: rel, existed: true }, svc._rows[rel] ? [] : [S.parentOf(rel)]);
                    for (const k in svc._rows) {
                        const r = svc._rows[k];
                        if (r.isLink && r.realPath === real)
                            return svc._ok({ key: k, existed: true }, []);
                    }
                    const nm = S.splitExt(S.baseOf(src));
                    const base = S.sanitize(nm.base) || svc.untitled;
                    return {
                        step: {
                            script: ops.foreignLinkScript,
                            args: [svc._rootPath, real, S.absOf(svc._rootPath, dest), base, nm.ext]
                        },
                        done: res2 => {
                            const t = svc._tags(res2);
                            if (!t.N)
                                return svc._fail(t.E || "link", [dest]);
                            return svc._ok({ key: S.join(dest, t.N), existed: false }, [dest]);
                        }
                    };
                }
            };
        });
    }

    // The clipboard's PNG into <root>/.attachments. result: its absolute path.
    function saveClipboardImage() {
        const stamp = Qt.formatDateTime(new Date(), "yyyyMMdd-HHmmss");
        return svc._op(() => {
            const dir = svc._rootPath + "/.attachments";
            return {
                step: {
                    script: ops.pasteScript,
                    args: [dir, stamp]
                },
                done: res => {
                    const t = svc._tags(res);
                    if (!t.N)
                        return svc._fail(t.E || "paste");
                    return svc._ok(dir + "/" + t.N, []);
                }
            };
        }, true);
    }

    // The FileChooser portal at the entry's REAL folder (a note's folder, a
    // foreign note's target folder, a group itself). Files picked there come
    // back as picked(absPaths) and as the op's result; a cancel is error
    // "cancel". One at a time ("busy").
    // The folder a note is IN, as the notes see it: a foreign note's link
    // in its folder under the root (the menu's "Show in file manager").
    // `real`: the folder of the file the link points at instead (the tile's
    // link glyph, "where does this really live").
    function showInFileManager(key, real) {
        const id = svc._newId();
        const r = svc._rows[key];
        let folder = "";
        if (r) {
            const own = S.absOf(svc._rootPath, key);
            const path = real && !r.broken ? r.realPath : own;
            folder = r.isGroup ? path : (path.substring(0, path.lastIndexOf("/")) || "/");
        }
        if (!r)
            svc._later(id, false, null, "missing");
        else if (portal.running)
            svc._later(id, false, null, "busy");
        else {
            svc._portalId = id;
            portal.command = ["setpriv", "--pdeathsig", "TERM", "--", svc.portalHelper, folder];
            portal.running = true;
        }
        return id;
    }

    // The file a note lives in, for whatever reads files (the LLM's "Send to LLM"): the real
    // path -- a link's target -- or "" for a group, a broken link and a key nobody knows.
    function filePathOf(key) {
        const r = svc._rows[key];
        return (r && !r.isGroup && !r.broken && r.realPath) ? String(r.realPath) : "";
    }

    // Title and content, all depths, debounced; searchDone(query, keys):
    // title matches first, then notes whose text matches (through links).
    function search(query) {
        svc._searchQuery = String(query === undefined || query === null ? "" : query);
        searchTimer.restart();
    }

    // =========================================================================
    //  Internals
    // =========================================================================

    readonly property string _rootPath: svc._normRoot(svc.root)
    property bool _ready: false
    property bool _watching: false
    property int _serial: 0
    property string _canon: ""
    property var _lastScan: null
    property var _rows: ({})
    property var _pos: null
    property var _order: []
    property var _ownMt: ({})
    property var _fp: ({})
    property var _fcache: ({})
    property var _linkByReal: ({})
    readonly property var _childCache: ({
            serial: -1,
            map: {}
        })
    property bool _sortGuard: false
    property int _opSeq: 0
    property NotesIndex _idx: null
    property bool _fullQueued: false

    function _normRoot(r) {
        let s = String(r || "");
        while (s.length > 1 && s.charAt(s.length - 1) === "/")
            s = s.substring(0, s.length - 1);
        return s;
    }
    function _bump() {
        svc._serial += 1;
    }
    function _isFolder(k) {
        return k === "" || (svc._rows[k] !== undefined && svc._rows[k].isGroup);
    }

    // Every part is held by a property (see the header: no default list).
    readonly property NotesFileOps _ops: NotesFileOps {
        id: ops
    }
    readonly property ListModel _rowsModel: ListModel {
        id: rowsModel
    }
    readonly property Component _indexComp: Component {
        id: indexComp
        NotesIndex {}
    }

    // ---- ops plumbing --------------------------------------------------------------

    function _newId() {
        svc._opSeq += 1;
        return svc._opSeq;
    }
    function _ok(result, rescan) {
        return {
            ok: true,
            result: result,
            error: "",
            rescan: rescan || []
        };
    }
    function _fail(error, rescan) {
        return {
            ok: false,
            result: null,
            error: error,
            rescan: rescan || []
        };
    }
    function _mvError(code) {
        return code === "2" ? "missing" : code === "3" ? "full" : code === "4" ? "move" : (code || "move");
    }
    // An op's NUL records by tag: { N, G, T, D, P, M, E: first value, R: [...] }.
    function _tags(res) {
        const out = {
            R: []
        };
        const recs = S.splitZ(res.out, res.text);
        for (let i = 0; i < recs.length; i++) {
            const s = recs[i];
            if (s === null || s.length === 0)
                continue;
            const tag = s.charAt(0), v = s.substring(1);
            if (tag === "R")
                out.R.push(v);
            else if (out[tag] === undefined)
                out[tag] = v;
        }
        return out;
    }
    // addForeign's check: "P<real>\0M<mime>\0" and then the file's first
    // 4096 bytes. -> { P, M, E, headOk }.
    function _checked(u8) {
        const out = {
            M: "",
            headOk: false
        };
        let at = 0;
        for (let n = 0; n < 2 && at < u8.length; n++) {
            let e = at;
            while (e < u8.length && u8[e] !== 0)
                e++;
            const d = S.decode(u8, at, e, false);
            if (d.ok && d.text.length > 0)
                out[d.text.charAt(0)] = d.text.substring(1);
            at = e + 1;
        }
        if (out.P !== undefined)
            out.headOk = S.headOf(u8, Math.min(at, u8.length), u8.length).ok;
        return out;
    }

    // The topmost folder of `dir`'s chain that the op did NOT remove.
    function _survivor(dir, removed) {
        let d = dir;
        while (d !== "" && (removed || []).indexOf(d) >= 0)
            d = S.parentOf(d);
        return d;
    }
    function _later(id, ok, result, error) {
        Qt.callLater(() => svc.opDone(id, ok, result, error));
    }

    // An op job: `start()` runs when the job's turn comes (after any scan
    // queued before it, so the model it validates against is current) and
    // returns an outcome or { step, done }; `done(res)` does the same. The
    // outcome's `rescan` folders are rescanned before opDone.
    function _op(start, noScan) {
        const id = svc._newId();
        if (!svc._ready && noScan !== true)
            svc._queueFull();
        const job = {
            h: null,
            scan: null,
            out: null
        };
        const settle = o => {
            if (o.step) {
                job.h = o.done;
                return o.step;
            }
            job.out = o;
            if (o.rescan.length > 0 && svc._rootPath.length > 0) {
                job.scan = svc._scanJob(o.rescan);
                return job.scan.next(null);
            }
            svc.opDone(id, o.ok, o.result, o.error);
            return null;
        };
        job.next = res => {
            if (res === null)
                return settle(svc._rootPath.length > 0 ? start() : svc._fail("root"));
            if (job.scan) {
                const s = job.scan.next(res);
                if (s)
                    return s;
                svc.opDone(id, job.out.ok, job.out.result, job.out.error);
                return null;
            }
            return settle(job.h(res));
        };
        ops.enqueue(job, false);
        return id;
    }

    function _removeOp(script, key) {
        const p = svc._rows[key].parentKey;
        return {
            step: {
                script: script,
                args: [svc._rootPath, S.absOf(svc._rootPath, key), S.absOf(svc._rootPath, p)]
            },
            done: res => {
                const t = svc._tags(res);
                if (t.E !== undefined)
                    return svc._fail(t.E, [p]);
                svc._removeKeys([key].concat(t.R), false);
                return svc._ok(key, [svc._survivor(p, t.R)]);
            }
        };
    }

    // ---- the model ----------------------------------------------------------------

    // key -> row index, from `_order` (the model's keys in row order, kept
    // beside it: rebuilding from rowsModel.get(i) costs 5 ms per 500 rows).
    function _posMap() {
        if (svc._pos === null) {
            const m = {};
            const o = svc._order;
            for (let i = 0; i < o.length; i++)
                m[o[i]] = i;
            svc._pos = m;
        }
        return svc._pos;
    }
    function _setRole(key, role, value) {
        const r = svc._rows[key];
        if (!r || r[role] === value)
            return;
        r[role] = value;
        const i = svc._posMap()[key];
        if (i !== undefined)
            rowsModel.setProperty(i, role, value);
    }

    // `from` and every row under it become `to` (+ the rest): in place, in
    // the index, and announced -- the entry first, then its descendants.
    function _renameEverywhere(from, to) {
        if (from === to || from === "")
            return;
        const moved = [];
        for (const k in svc._rows) {
            const nk = S.rebase(k, from, to);
            if (nk !== null)
                moved.push([k, nk]);
        }
        moved.sort((a, b) => a[0].length - b[0].length);
        const pos = svc._posMap();
        const rows = svc._rows;
        const own = svc._ownMt;
        for (let i = 0; i < moved.length; i++) {
            const k = moved[i][0], nk = moved[i][1];
            const r = rows[k];
            delete rows[k];
            delete svc._fp[k];
            const ch = {
                key: nk,
                parentKey: S.parentOf(nk),
                depth: S.depthOf(nk)
            };
            if (k === from) {
                ch.name = S.baseOf(nk);
                ch.title = S.titleOf(ch.name, r.isGroup);
                ch.ext = S.extOf(ch.name, r.isGroup);
                ch.kind = S.kindOf(ch.name, r.isGroup);
            }
            if (!r.isLink && svc._canon.length > 0) {
                const nr = S.absOf(svc._canon, nk);
                if (svc._fcache[r.realPath])
                    svc._fcache[nr] = svc._fcache[r.realPath];
                ch.realPath = nr;
            }
            Object.assign(r, ch);
            rows[nk] = r;
            if (own[k] !== undefined) {
                own[nk] = own[k];
                delete own[k];
            }
            const at = pos[k];
            if (at !== undefined) {
                rowsModel.set(at, ch);
                svc._order[at] = nk;
            }
        }
        svc._pos = null;
        if (svc._idx)
            svc._idx.renameKey(from, to);
        if (moved.length === 0)
            svc.entryRenamed(from, to);
        for (let i = 0; i < moved.length; i++)
            svc.entryRenamed(moved[i][0], moved[i][1]);
        svc._recomputeGroups();
        svc._bump();
    }

    // Rows for `keys` and everything under them go; so does their metadata
    // unless `keepIndex` (a scan that could not read everything).
    function _removeKeys(keys, keepIndex) {
        if (!keys || keys.length === 0)
            return;
        const gone = [];
        for (const k in svc._rows)
            for (let j = 0; j < keys.length; j++)
                if (S.isSelfOrUnder(k, keys[j])) {
                    gone.push(k);
                    break;
                }
        const pos = svc._posMap();
        const at = gone.map(k => pos[k]).filter(i => i !== undefined).sort((a, b) => b - a);
        for (let i = 0; i < at.length; i++) {
            rowsModel.remove(at[i], 1);
            svc._order.splice(at[i], 1);
        }
        for (let i = 0; i < gone.length; i++) {
            delete svc._rows[gone[i]];
            delete svc._ownMt[gone[i]];
            delete svc._fp[gone[i]];
        }
        svc._pos = null;
        if (svc._idx && !keepIndex)
            for (let j = 0; j < keys.length; j++)
                svc._idx.removeKey(keys[j]);
        svc._recomputeGroups();
        svc._bump();
    }

    // childCount, and a group's size (sum) and mtime (newest) over the notes
    // under it (its own mtime when it holds none).
    function _recomputeGroups() {
        const agg = {};
        const rows = svc._rows;
        for (const k in rows)
            if (rows[k].isGroup)
                agg[k] = {
                    n: 0,
                    size: 0,
                    mt: -1
                };
        for (const k in rows) {
            const r = rows[k];
            if (r.parentKey !== "" && agg[r.parentKey])
                agg[r.parentKey].n += 1;
            if (r.isGroup)
                continue;
            let p = r.parentKey;
            while (p !== "") {
                const a = agg[p];
                if (a) {
                    a.size += r.size;
                    if (r.mtimeMs > a.mt)
                        a.mt = r.mtimeMs;
                }
                p = S.parentOf(p);
            }
        }
        for (const k in agg) {
            const a = agg[k];
            svc._setRole(k, "childCount", a.n);
            svc._setRole(k, "size", a.size);
            svc._setRole(k, "mtimeMs", a.mt >= 0 ? a.mt : (svc._ownMt[k] || 0));
        }
    }

    // ---- scanning ----------------------------------------------------------------------

    // Scan requests -> the smallest set of { rel, deep } that covers them.
    // A request is a folder key (SHALLOW: its direct children -- what an
    // event in that folder can have changed) or { deep: key } (everything
    // under it). A deep folder covers itself and everything under it; a
    // shallow one covers only itself.
    function _reduceDirs(reqs) {
        const byRel = {};
        for (let i = 0; i < reqs.length; i++) {
            const q = reqs[i];
            const deep = typeof q === "object" && q !== null;
            const rel = (deep ? q.deep : q) || "";
            if (S.isHiddenRel(rel))
                continue;
            byRel[rel] = byRel[rel] === true || deep;
        }
        const rels = Object.keys(byRel).sort((a, b) => S.depthOf(a) - S.depthOf(b) || a.length - b.length);
        const out = [];
        for (let i = 0; i < rels.length; i++) {
            const rel = rels[i];
            let covered = false;
            for (let j = 0; j < out.length && !covered; j++)
                covered = out[j].deep && S.isSelfOrUnder(rel, out[j].rel);
            if (!covered)
                out.push({
                    rel: rel,
                    deep: byRel[rel]
                });
        }
        return out;
    }
    function _deep(key) {
        return {
            deep: key
        };
    }

    function _queueFull() {
        if (svc._fullQueued || svc._rootPath.length === 0)
            return;
        svc._fullQueued = true;
        ops.enqueue(svc._scanJob([svc._deep("")]), false);
    }

    // A scan job: find -> find again, deep, for folders a shallow scan met
    // for the first time -> link targets -> MIME (uncached) -> heads
    // (uncached) -> apply. MIME and heads are cached by (mtime, size) of the
    // real file, so a rescan of an unchanged folder runs find alone.
    function _scanJob(rels) {
        const job = {
            phase: 0,
            rels: svc._reduceDirs(rels),
            t0: 0,
            token: S.freshToken(),
            mimed: 0,
            headed: 0
        };
        job.next = res => svc._scanStep(job, res);
        return job;
    }

    function _scanStep(job, res) {
        if (job.phase === 0) {
            job.phase = 1;
            job.t0 = Date.now();
            job.js = 0;
            job.findCode = 0;
            job.sections = [];
            job.cands = {};
            job.links = [];
            for (let i = 0; i < job.rels.length; i++)
                if (job.rels[i].rel === "" && job.rels[i].deep)
                    svc._fullQueued = false;
            return {
                script: ops.scanScript,
                args: [svc._rootPath].concat(job.rels.map(r => (r.deep ? "D" : "S") + r.rel))
            };
        }
        if (job.phase === 1 || job.phase === 5) {
            const t = Date.now();
            if (res.code !== 0)
                job.findCode = res.code;
            const p = S.parseFind(res.out, res.text);
            if (p.canon)
                job.canon = p.canon;
            job.sections = job.sections.concat(p.sections);
            const canon = job.canon || svc._canon || svc._rootPath;
            // Folders a shallow scan meets for the first time -- moved in from
            // outside, made by another program -- are scanned whole next. A
            // folder whose inode a row already has is a rename: its rows move
            // with it, nothing under it needs reading.
            const known = {};
            if (job.phase === 1)
                for (const k in svc._rows)
                    if (svc._rows[k].isGroup)
                        known[svc._rows[k].inode] = true;
            const fresh = [];
            for (let s = 0; s < p.sections.length; s++) {
                const sec = p.sections[s];
                for (let i = 0; i < sec.recs.length; i++) {
                    const c = svc._candidate(sec.recs[i], canon);
                    if (!c || job.cands[c.key])
                        continue;
                    job.cands[c.key] = c;
                    if (c.isLink)
                        job.links.push(c);
                    if (job.phase === 1 && !sec.deep && c.isGroup && !svc._rows[c.key] && known[c.inode] !== true)
                        fresh.push("D" + c.key);
                }
            }
            job.js += Date.now() - t;
            if (fresh.length > 0) {
                job.phase = 5;
                return {
                    script: ops.scanScript,
                    args: [svc._rootPath].concat(fresh)
                };
            }
            if (job.links.length > 0) {
                job.phase = 2;
                return {
                    script: ops.linkScript,
                    args: job.links.map(c => c.abs)
                };
            }
            return svc._mimeStep(job);
        }
        if (job.phase === 2) {
            const L = S.parseLinks(res.out, job.links.length, res.text);
            for (let i = 0; i < job.links.length; i++) {
                const c = job.links[i];
                c.realPath = L.real[i] || "";
                if (c.broken)
                    continue;
                const st = L.stat[c.abs];
                if (!st) {
                    // Gone between find and stat.
                    c.broken = true;
                    c.fileLike = false;
                    continue;
                }
                c.size = st.size;
                c.mtimeMs = st.mtimeMs;
                c.birthMs = st.birthMs;
                c.stamp = st.mtRaw + "/" + st.size;
            }
            return svc._mimeStep(job);
        }
        if (job.phase === 3) {
            const m = S.parseMime(res.out, job.mimeList.length);
            for (let i = 0; i < job.mimeList.length; i++) {
                const c = job.mimeList[i];
                // No answer (file(1) failed or the output ran short): not
                // cached, so the next scan asks again.
                if (!m[i]) {
                    delete svc._fcache[c.realPath];
                    continue;
                }
                svc._fcache[c.realPath] = {
                    stamp: c.stamp,
                    mime: m[i],
                    head: "",
                    headOk: false,
                    headStamp: ""
                };
            }
            job.mimed = job.mimeList.length;
            return svc._headStep(job);
        }
        if (job.phase === 4) {
            const h = S.parseHeads(res.out, job.token);
            for (let i = 0; i < job.headList.length; i++) {
                const c = job.headList[i];
                const e = svc._fcache[c.realPath];
                if (!e)
                    continue;
                const hd = h[c.abs];
                e.head = hd ? hd.text : "";
                e.headOk = hd ? hd.ok : false;
                e.headStamp = c.stamp;
            }
            job.headed = job.headList.length;
            svc._applyScan(job);
            return null;
        }
        return null;
    }

    function _candidate(rec, canon) {
        const c = {
            key: rec.key,
            abs: S.absOf(svc._rootPath, rec.key),
            isGroup: false,
            isLink: false,
            broken: false,
            fileLike: false,
            realPath: S.absOf(canon, rec.key),
            linkTarget: "",
            size: rec.size,
            mtimeMs: rec.mtimeMs,
            birthMs: rec.birthMs,
            inode: rec.inode,
            stamp: rec.mtRaw + "/" + rec.size
        };
        if (rec.y === "d") {
            c.isGroup = true;
            c.size = 0;
            return c;
        }
        if (rec.y === "f") {
            c.fileLike = true;
            return c;
        }
        if (rec.y !== "l" || rec.Y === "d")
            return null;
        c.isLink = true;
        c.linkTarget = rec.link;
        if (rec.Y === "f") {
            c.fileLike = true;
            return c;
        }
        if (rec.Y === "N" || rec.Y === "L" || rec.Y === "?") {
            c.broken = true;
            c.size = 0;
            return c;
        }
        return null;
    }

    function _mimeStep(job) {
        const need = [];
        for (const k in job.cands) {
            const c = job.cands[k];
            if (!c.fileLike)
                continue;
            const e = svc._fcache[c.realPath];
            if (!e || e.stamp !== c.stamp)
                need.push(c);
        }
        if (need.length === 0)
            return svc._headStep(job);
        job.phase = 3;
        job.mimeList = need;
        return {
            script: ops.mimeScript,
            args: [],
            stdin: need.map(c => c.abs).join("\u0000") + "\u0000"
        };
    }

    function _headStep(job) {
        const need = [];
        for (const k in job.cands) {
            const c = job.cands[k];
            if (!c.fileLike)
                continue;
            const e = svc._fcache[c.realPath];
            if (e && S.needsHead(e.mime, S.baseOf(c.key)) && e.headStamp !== c.stamp)
                need.push(c);
        }
        if (need.length === 0) {
            svc._applyScan(job);
            return null;
        }
        job.phase = 4;
        job.headList = need;
        return {
            script: ops.headScript,
            args: [job.token],
            stdin: need.map(c => c.abs).join("\u0000") + "\u0000"
        };
    }

    function _typeOf(r) {
        return r.isGroup ? "d" : r.isLink ? "l" : "f";
    }

    function _applyScan(job) {
        const t0 = Date.now();
        if (job.canon)
            svc._canon = job.canon;
        const canon = svc._canon;
        // What this scan speaks for: everything under a deep folder, the
        // direct children of a shallow one (what went away under a vanished
        // child goes with it: _removeKeys and renames take whole subtrees).
        const deepSubs = [];
        const shallowSubs = {};
        let partial = job.findCode !== 0;
        let rootSeen = false, rootExists = false;
        for (let s = 0; s < job.sections.length; s++) {
            const sec = job.sections[s];
            if (sec.deep)
                deepSubs.push(sec.rel);
            else
                shallowSubs[sec.rel] = true;
            if (!sec.exists)
                partial = true;
            if (sec.rel === "") {
                rootSeen = rootSeen || sec.deep;
                rootExists = sec.exists;
            } else if (sec.exists) {
                rootExists = true;
            }
        }
        if (job.sections.length === 0)
            partial = true;
        const inSubs = k => {
            if (shallowSubs[S.parentOf(k)] === true)
                return true;
            for (let i = 0; i < deepSubs.length; i++)
                if (S.isUnder(k, deepSubs[i]))
                    return true;
            return false;
        };

        // What the scan lists, with the cached facts.
        const listed = {};
        for (const k in job.cands) {
            const c = job.cands[k];
            if (c.fileLike) {
                const e = svc._fcache[c.realPath];
                if (!e || !S.isNote(e.mime, e.headOk, S.baseOf(c.key)))
                    continue;
                c.mime = e.mime;
                c.head = e.head;
            } else {
                c.mime = c.isGroup ? "inode/directory" : "";
                c.head = "";
            }
            listed[k] = c;
        }
        // Everything under the scanned folders is dropped from the listed set
        // when its parent is not listed (a folder that failed to read).
        for (const k in listed)
            if (S.parentOf(k) !== "" && !listed[S.parentOf(k)] && inSubs(S.parentOf(k)))
                delete listed[k];

        // Renames by inode: a key that went and a key that came with the
        // same inode (and kind) is the same entry under a new name.
        const known = {};
        for (const k in svc._rows)
            if (inSubs(k))
                known[k] = {
                    inode: svc._rows[k].inode,
                    t: svc._typeOf(svc._rows[k])
                };
        if (svc._idx) {
            const ik = svc._idx.inodeKeys();
            for (let i = 0; i < ik.length; i++)
                if (known[ik[i]] === undefined && inSubs(ik[i]))
                    known[ik[i]] = {
                        inode: svc._idx.inodeOf(ik[i]),
                        t: "?"
                    };
        }
        const byInode = {};
        for (const k in listed)
            if (known[k] === undefined && listed[k].inode > 0) {
                const n = listed[k].inode;
                (byInode[n] = byInode[n] || []).push(k);
            }
        const vanished = Object.keys(known).filter(k => listed[k] === undefined).sort((a, b) => S.depthOf(a) - S.depthOf(b));
        const pairs = [];
        const used = {};
        for (let i = 0; i < vanished.length; i++) {
            const o = known[vanished[i]];
            const cs = byInode[o.inode];
            if (!cs || o.inode <= 0)
                continue;
            for (let j = 0; j < cs.length; j++) {
                if (used[cs[j]] === true)
                    continue;
                const t = svc._typeOf(listed[cs[j]]);
                if (o.t !== "?" && o.t !== t)
                    continue;
                used[cs[j]] = true;
                pairs.push([vanished[i], cs[j]]);
                break;
            }
        }
        const applied = [];
        let changed = false;
        for (let i = 0; i < pairs.length; i++) {
            let cur = pairs[i][0];
            for (let j = 0; j < applied.length; j++) {
                const r = S.rebase(cur, applied[j][0], applied[j][1]);
                if (r !== null)
                    cur = r;
            }
            if (cur === pairs[i][1])
                continue;
            svc._renameEverywhere(cur, pairs[i][1]);
            applied.push([cur, pairs[i][1]]);
            changed = true;
        }

        // Gone: rows under the scanned folders the scan did not list, and
        // index keys there that no rename claimed.
        const goneRows = [];
        for (const k in svc._rows)
            if (inSubs(k) && listed[k] === undefined)
                goneRows.push(k);
        if (goneRows.length > 0) {
            svc._removeKeys(goneRows, partial);
            changed = true;
        }
        if (svc._idx && !partial) {
            const ik = svc._idx.inodeKeys();
            for (let i = 0; i < ik.length; i++)
                if (inSubs(ik[i]) && listed[ik[i]] === undefined && !svc._rows[ik[i]])
                    svc._idx.removeKey(ik[i]);
        }

        // New and changed rows.
        const now = Date.now();
        const pos = svc._posMap();
        const keys = Object.keys(listed);
        const added = [];
        for (let i = 0; i < keys.length; i++) {
            const c = listed[keys[i]];
            // Unchanged since the last scan (same file, same facts -- the head
            // and type are cached by the stamp): skip the row. Building and
            // comparing every row is most of a rescan.
            const fp = c.stamp + "\u0001" + c.inode + "\u0001" + c.linkTarget + "\u0001" + c.realPath + "\u0001" + c.broken + "\u0001" + c.birthMs + "\u0001" + c.mime;
            const old = svc._rows[c.key];
            if (old && svc._fp[c.key] === fp)
                continue;
            svc._fp[c.key] = fp;
            if (c.isGroup)
                svc._ownMt[c.key] = c.mtimeMs;
            if (!old) {
                added.push(c.key);
                continue;
            }
            const row = svc._rowFor(c, canon, now);
            const ch = {};
            let any = false;
            for (const role in row) {
                if (c.isGroup && (role === "size" || role === "mtimeMs" || role === "childCount"))
                    continue;
                if (old[role] !== row[role]) {
                    ch[role] = row[role];
                    old[role] = row[role];
                    any = true;
                }
            }
            if (any) {
                const at = pos[c.key];
                if (at !== undefined)
                    rowsModel.set(at, ch);
                changed = true;
            }
        }
        // New rows, a folder before what is in it.
        added.sort((a, b) => S.depthOf(a) - S.depthOf(b) || (a < b ? -1 : 1));
        for (let i = 0; i < added.length; i++) {
            const c = listed[added[i]];
            const row = svc._rowFor(c, canon, now);
            svc._rows[c.key] = row;
            rowsModel.append(row);
            svc._order.push(c.key);
            pos[c.key] = svc._order.length - 1;
            changed = true;
        }
        svc._recomputeGroups();

        // Bookkeeping: inodes for rename detection, first-seen where there
        // is no birth time.
        if (svc._idx) {
            for (let i = 0; i < keys.length; i++) {
                const c = listed[keys[i]];
                svc._idx.setInode(c.key, c.inode);
            }
            if (rootExists)
                svc._idx.rootExists();
        }
        svc._updateLinks();

        // Prune the MIME/head cache after a full scan.
        if (rootSeen && !partial) {
            const seen = {};
            for (const k in job.cands)
                seen[job.cands[k].realPath] = true;
            for (const p in svc._fcache)
                if (seen[p] !== true)
                    delete svc._fcache[p];
        }

        svc._lastScan = {
            ms: Date.now() - job.t0,
            applyMs: job.js + Date.now() - t0,
            dirs: job.rels.slice(),
            entries: Object.keys(listed).length,
            mimed: job.mimed,
            headed: job.headed
        };
        if (changed)
            svc._bump();
        if (rootSeen && !svc._ready)
            svc._ready = true;
        if (rootExists)
            svc._ensureRootWatch();
    }

    function _rowFor(c, canon, now) {
        const name = S.baseOf(c.key);
        let bt = c.birthMs;
        if (!(bt > 0) && svc._idx) {
            bt = svc._idx.firstSeen(c.key);
            if (!(bt > 0)) {
                bt = now;
                svc._idx.noteFirstSeen(c.key, now);
            }
        }
        return {
            key: c.key,
            parentKey: S.parentOf(c.key),
            name: name,
            title: S.titleOf(name, c.isGroup),
            ext: S.extOf(name, c.isGroup),
            kind: S.kindOf(name, c.isGroup),
            isGroup: c.isGroup,
            isLink: c.isLink,
            broken: c.broken,
            realPath: c.isLink ? (c.realPath || "") : S.absOf(canon, c.key),
            linkTarget: c.linkTarget,
            mime: c.mime || "",
            size: c.isGroup ? 0 : c.size,
            mtimeMs: c.mtimeMs,
            btimeMs: bt || 0,
            inode: c.inode,
            depth: S.depthOf(c.key),
            colorKey: svc._idx ? svc._idx.colorOf(c.key) : "",
            head: c.isGroup || c.broken ? "" : (c.head || ""),
            childCount: 0
        };
    }

    // ---- watching ------------------------------------------------------------------------

    property var _pending: ({})

    // A folder an event touched: its direct children are rescanned (`deep`:
    // everything under it).
    function _queueDir(d, deep) {
        if (d === null || S.isHiddenRel(d))
            return;
        svc._pending[d] = svc._pending[d] === true || deep === true;
        if (!watchTimer.running)
            watchTimer.start();
    }
    readonly property Timer _watchTimer: Timer {
        id: watchTimer
        interval: svc.watchDelayMs
        onTriggered: {
            const p = svc._pending;
            svc._pending = {};
            const reqs = Object.keys(p).map(d => p[d] ? svc._deep(d) : d);
            if (reqs.length > 0 && svc.active)
                ops.enqueue(svc._scanJob(reqs), false);
        }
    }

    function _onRootEvent(data) {
        let s = String(data);
        if (s.charAt(0) === "\n")
            s = s.substring(1);
        const sp = s.indexOf(" ");
        if (sp < 0)
            return;
        const ev = s.substring(0, sp);
        let path = s.substring(sp + 1);
        const self = path.charAt(path.length - 1) === "/";
        path = svc._normRoot(path);
        const rel = S.relOf(svc._rootPath, path);
        if (rel === null)
            return;
        if (self || ev.indexOf("_SELF") >= 0)
            svc._queueDir(rel === "" ? "" : S.parentOf(rel));
        else if (!S.isHiddenRel(rel))
            svc._queueDir(S.parentOf(rel));
    }
    function _onForeignEvent(data) {
        let s = String(data);
        if (s.charAt(0) === "\n")
            s = s.substring(1);
        const sp = s.indexOf(" ");
        if (sp < 0)
            return;
        const path = svc._normRoot(s.substring(sp + 1));
        const ks = svc._linkByReal[path];
        if (!ks)
            return;
        for (let i = 0; i < ks.length; i++)
            svc._queueDir(S.parentOf(ks[i]));
    }

    // The link index (real path -> link keys) and the foreign folders to
    // watch: where the listed links' targets live, outside the root.
    property var _foreignDirs: []
    function _updateLinks() {
        const by = {};
        const dirs = {};
        for (const k in svc._rows) {
            const r = svc._rows[k];
            if (!r.isLink || !r.realPath)
                continue;
            (by[r.realPath] = by[r.realPath] || []).push(k);
            if (r.broken)
                continue;
            const d = r.realPath.substring(0, r.realPath.lastIndexOf("/")) || "/";
            if (svc._canon && S.relOf(svc._canon, d) !== null)
                continue;
            dirs[d] = true;
        }
        svc._linkByReal = by;
        const list = Object.keys(dirs).sort();
        if (JSON.stringify(list) !== JSON.stringify(svc._foreignDirs)) {
            svc._foreignDirs = list;
            svc._restartForeign();
        }
    }

    readonly property var _watchEvents: ["-e", "create,close_write,moved_from,moved_to,delete,delete_self,move_self"]
    function _ere(s) {
        return s.replace(/[.[\]()*+?{}|^$\\]/g, "\\$&");
    }
    function _ensureRootWatch() {
        if (!svc.active || rootWatch.running || svc._rootPath.length === 0)
            return;
        rootWatch.command = ["setpriv", "--pdeathsig", "TERM", "--", "inotifywait", "-m", "-r", "--no-newline",
            "--format", "%e %w%f%0", "--exclude", "^" + svc._ere(svc._rootPath) + "/(.*/)?\\."].concat(svc._watchEvents).concat(["--", svc._rootPath]);
        rootWatch.running = true;
    }
    property bool _foreignRestart: false
    function _restartForeign() {
        if (foreignWatch.running) {
            svc._foreignRestart = true;
            foreignWatch.running = false;
            return;
        }
        if (!svc.active || svc._foreignDirs.length === 0)
            return;
        foreignWatch.command = ["setpriv", "--pdeathsig", "TERM", "--", "inotifywait", "-m", "--no-newline", "-q",
            "--format", "%e %w%f%0"].concat(svc._watchEvents).concat(["--"]).concat(svc._foreignDirs);
        foreignWatch.running = true;
    }

    readonly property Process _rootWatch: Process {
        id: rootWatch
        running: false
        stdout: SplitParser {
            splitMarker: "\u0000"
            onRead: data => svc._onRootEvent(data)
        }
        stderr: SplitParser {
            onRead: data => {
                if (String(data).indexOf("Watches established") >= 0 && !svc._watching) {
                    svc._watching = true;
                    // What changed between the first scan and this moment.
                    svc._queueDir("", true);
                }
            }
        }
    }
    readonly property Connections _rootWatchExit: Connections {
        target: rootWatch
        function onExited() {
            svc._watching = false;
        }
    }
    readonly property Process _foreignWatch: Process {
        id: foreignWatch
        running: false
        stdout: SplitParser {
            splitMarker: "\u0000"
            onRead: data => svc._onForeignEvent(data)
        }
    }
    readonly property Connections _foreignWatchExit: Connections {
        target: foreignWatch
        function onExited() {
            // A restart stops the old watcher first; the new one starts here.
            // An exit nobody asked for (a folder vanished under it) waits for
            // the next change of the folder list instead of looping.
            if (!svc._foreignRestart)
                return;
            svc._foreignRestart = false;
            if (svc.active && svc._foreignDirs.length > 0)
                Qt.callLater(svc._restartForeign);
        }
    }

    onActiveChanged: svc._activate()
    function _activate() {
        if (svc.active && svc._rootPath.length > 0) {
            svc._queueFull();
            svc._ensureRootWatch();
            svc._restartForeign();
        } else {
            watchTimer.stop();
            svc._pending = {};
            rootWatch.running = false;
            foreignWatch.running = false;
            svc._watching = false;
        }
    }

    // ---- search --------------------------------------------------------------------------

    property string _searchQuery: ""
    property string _searchRunning: ""
    property bool _searchAgain: false
    readonly property Timer _searchTimer: Timer {
        id: searchTimer
        interval: svc.searchDelayMs
        onTriggered: svc._startSearch()
    }
    function _startSearch() {
        const q = svc._searchQuery;
        if (q.length === 0) {
            svc.searchDone(q, []);
            return;
        }
        if (grep.running) {
            svc._searchAgain = true;
            grep.running = false;
            return;
        }
        svc._searchRunning = q;
        grep.command = ["setpriv", "--pdeathsig", "TERM", "--", "sh", "-c",
            "exec </dev/null\ncd -- \"$1\" 2>/dev/null || exit 2\nexec grep -RilFZ --exclude-dir=\".*\" --exclude=\".*\" -- \"$2\" *", "sh", svc._rootPath, q];
        grep.running = true;
    }
    function _finishSearch() {
        if (svc._searchAgain) {
            svc._searchAgain = false;
            svc._startSearch();
            return;
        }
        const q = svc._searchRunning;
        if (q !== svc._searchQuery)
            return;
        const lq = q.toLowerCase();
        const byTitle = [];
        for (const k in svc._rows)
            if (svc._rows[k].title.toLowerCase().indexOf(lq) >= 0)
                byTitle.push(k);
        byTitle.sort(S.natCompare);
        const seen = {};
        for (let i = 0; i < byTitle.length; i++)
            seen[byTitle[i]] = true;
        const found = S.splitZ(S.bytesOf(grepOut.data));
        const byText = [];
        for (let i = 0; i < found.length; i++) {
            const k = found[i];
            if (k === null || seen[k] === true || !svc._rows[k] || svc._rows[k].isGroup)
                continue;
            seen[k] = true;
            byText.push(k);
        }
        byText.sort(S.natCompare);
        svc.searchDone(q, byTitle.concat(byText));
    }
    readonly property Process _grep: Process {
        id: grep
        running: false
        stdout: StdioCollector {
            id: grepOut
        }
    }
    readonly property Connections _grepExit: Connections {
        target: grep
        function onExited() {
            svc._finishSearch();
        }
    }

    // ---- the portal ------------------------------------------------------------------------

    property int _portalId: 0
    readonly property Process _portal: Process {
        id: portal
        running: false
        stdout: StdioCollector {
            id: portalOut
        }
    }
    readonly property Connections _portalExit: Connections {
        target: portal
        function onExited(exitCode) {
            const id = svc._portalId;
            svc._portalId = 0;
            if (exitCode === 0) {
                const paths = S.splitZ(S.bytesOf(portalOut.data)).filter(p => p !== null && p.length > 0);
                svc.picked(paths);
                svc.opDone(id, true, paths, "");
            } else {
                svc.opDone(id, false, null, exitCode === 1 ? "cancel" : "portal");
            }
        }
    }

    // ---- the index, and a root --------------------------------------------------------------

    function _ingestIndex() {
        svc._sortGuard = true;
        svc.sortMode = svc._idx.sortMode();
        svc.sortAscending = svc._idx.sortAscending();
        svc._sortGuard = false;
        for (const k in svc._rows)
            svc._setRole(k, "colorKey", svc._idx.colorOf(k));
        // firstSeen may have changed under the rows: compare them all next scan.
        svc._fp = {};
        svc._bump();
    }
    readonly property Connections _indexIngest: Connections {
        target: svc._idx
        function onIngested() {
            svc._ingestIndex();
        }
    }

    property string _builtFor: ""
    function _build() {
        if (svc._rootPath === svc._builtFor)
            return;
        if (svc._idx) {
            svc._idx.flush();
            svc._idx.destroy();
            svc._idx = null;
        }
        // A NEW root is a new model; this is the one reset.
        if (svc._builtFor.length > 0) {
            rowsModel.clear();
            svc._order = [];
            svc._rows = {};
            svc._ownMt = {};
            svc._fp = {};
            svc._fcache = {};
            svc._pos = null;
            svc._ready = false;
            svc._canon = "";
            rootWatch.running = false;
            foreignWatch.running = false;
        }
        svc._builtFor = svc._rootPath;
        if (svc._rootPath.length === 0)
            return;
        svc._idx = indexComp.createObject(svc, {
            path: svc._rootPath + "/.notes.json"
        }) as NotesIndex;
        svc._ingestIndex();
        svc._activate();
    }
    on_RootPathChanged: svc._build()
    Component.onCompleted: svc._build()
}
