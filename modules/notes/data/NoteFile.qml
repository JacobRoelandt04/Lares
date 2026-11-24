pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components/Utf8.js" as U

// =============================================================================
// NoteFile.qml -- one note's bytes, for the editor. One instance per REAL
// path; `path` is set ONCE (a FileView is never repointed: a second path
// hands back the first file's bytes). A renamed note gets a new NoteFile.
//
// READ. `read()` decodes the file's bytes with the strict UTF-8 decoder and
// returns the text exactly -- a BOM stays as U+FEFF at index 0, CR LF stays,
// a missing final newline stays -- so writing it back is byte-identical. It
// returns null when the file is missing, or INVALID (not UTF-8: Latin-1, a
// binary): an invalid note opens read-only and write() refuses it for ever,
// so nothing we cannot decode is ever written back.
//
// WRITE. `write(text)` is atomic (FileView atomicWrites: a temp file renamed
// over the note; through a symlink it writes the target and keeps the link)
// and on disk when flush() returns.
// A FileView SKIPS A WRITE EQUAL TO THE TEXT IT HOLDS (measured, setText and
// setData alike). That is what the stage-0 note "setText("") writes nothing"
// saw: its view had never read the file, so it held "" and an empty write
// was equal to it. A view that has read the file truncates on setText("")
// like any other write (measured: 0 bytes, through a link too). So the view
// is READ ONCE AT OPEN, blocking, before anything can be written -- and an
// empty text goes through setText like every other text, no Process racing
// the next save. The one case a view cannot write is an empty note that
// does not exist yet: a `set -C` Process creates it (it can never truncate a
// note a later write has already put back). And the skip is harmless where
// the view is behind the disk: the outside text arrives with `loaded` and is
// reported as a change, which is the conflict the editor has to show anyway.
//
// ECHO. Our own write comes back as one fileChanged. Every change is read
// after `loaded` (a reload's new text only arrives then) and compared with
// `_known`, the text we last read or wrote: equal is our echo (or no change)
// and says nothing; anything else is a real outside change and is emitted.
// =============================================================================
Scope {
    id: nf

    property string path: ""
    readonly property bool missing: nf._missing
    readonly property bool invalid: nf._invalid

    signal externalChange(string text)
    signal writeFailed(string error)

    property bool _missing: true
    property bool _invalid: false
    property var _known: null
    property string _frozen: ""
    property FileView _fv: null

    // -> the decoded text, or null when the file is missing or not UTF-8.
    function read() {
        if (!nf._fv || nf._missing)
            return null;
        const r = nf._decode(nf._fv.data());
        nf._invalid = !r.ok;
        if (!r.ok)
            return null;
        nf._known = r.text;
        return r.text;
    }

    // -> true when the write was issued.
    function write(text) {
        if (!nf._fv) {
            nf.writeFailed("closed");
            return false;
        }
        if (nf._invalid) {
            nf.writeFailed("invalid");
            return false;
        }
        const t = String(text);
        nf._known = t;
        if (t.length > 0 || !nf._missing) {
            nf._fv.setText(t);
        } else {
            createEmpty.command = ["sh", "-c", "set -C; : > \"$1\"", "sh", nf._frozen];
            createEmpty.running = true;
        }
        nf._missing = false;
        return true;
    }

    // The last write is on disk when this returns.
    function flush() {
        if (nf._fv)
            nf._fv.waitForJob();
    }

    function _decode(buf) {
        if (!(buf instanceof ArrayBuffer) || buf.byteLength === 0)
            return {
                text: "",
                ok: true
            };
        const d = U.utf8Decoder();
        const t = d.push(new Uint8Array(buf), true);
        return {
            text: t,
            ok: !d.invalid && d.pending === 0
        };
    }

    function _onLoaded() {
        // The first, blocking load can report before _open() has the view.
        if (!nf._fv)
            return;
        nf._missing = false;
        const r = nf._decode(nf._fv.data());
        nf._invalid = !r.ok;
        if (!r.ok)
            return;
        if (r.text === nf._known)
            return;
        nf._known = r.text;
        nf.externalChange(r.text);
    }
    function _onLoadFailed(error) {
        if (error === FileViewError.FileNotFound) {
            nf._missing = true;
            nf._known = null;
        }
    }

    Component {
        id: fvComp
        FileView {
            id: fv
            blockLoading: true
            atomicWrites: true
            watchChanges: true
            printErrors: false
            onFileChanged: fv.reload()
            onLoaded: nf._onLoaded()
            onLoadFailed: error => nf._onLoadFailed(error)
            onSaveFailed: error => nf.writeFailed(FileViewError.toString(error))
        }
    }
    Process {
        id: createEmpty
        running: false
    }
    Connections {
        target: createEmpty
        function onExited(exitCode) {
            if (exitCode !== 0 && nf._known === "")
                nf.writeFailed("create");
        }
    }

    function _open() {
        if (nf._fv || nf.path.length === 0)
            return;
        nf._frozen = nf.path;
        nf._fv = fvComp.createObject(nf, {
            path: nf._frozen
        }) as FileView;
        // The blocking first read. The view must HOLD the file's text before
        // any write can be issued: it skips a write equal to what it holds,
        // and an unread view holds "" -- write("") would do nothing.
        const buf = nf._fv.data();
        nf._missing = !nf._fv.loaded;
        if (nf._missing)
            return;
        const r = nf._decode(buf);
        nf._invalid = !r.ok;
        nf._known = r.ok ? r.text : null;
    }

    onPathChanged: {
        if (nf._fv && nf.path !== nf._frozen)
            console.warn("NoteFile: path is set once (" + nf._frozen + "); make a new NoteFile for " + nf.path);
        else
            nf._open();
    }
    Component.onCompleted: nf._open()
    Component.onDestruction: nf.flush()
}
