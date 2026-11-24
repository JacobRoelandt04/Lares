pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import "LlmPathComplete.js" as Complete

// =============================================================================
// LlmPathCompleter.qml
//
// One directory listing, for the prompt's "@" path completion. It
// draws nothing -- the LlmAttachmentLoader shape: a headless worker whose
// proof is what it publishes.
//
// WHY FolderListModel AND NOT A PROCESS (measured). Quickshell.Io has no
// directory type, so the alternative to `Qt.labs.folderlistmodel` is an `ls`
// through a Process. The model wins on every number that matters here: the
// scan runs OFF the UI thread (assigning `folder` returns in 3 ms,
// and a 16 ms timer's worst gap during a 191 ms / 26 811-entry scan was
// 17 ms), a repoint resets `count` to 0 synchronously so a stale directory is
// never read, and a directory that does not exist settles synchronously at
// status Null.
//
// ONE SCAN PER DIRECTORY, AND THE KEYSTROKES FILTER IN JS. `nameFilters`
// looks like the per-keystroke filter and must never be used as one: each
// write is another asynchronous Loading->Ready round trip, so the answer
// arrives after the keystroke that asked for it (200 writes cost 39 ms of
// main-thread time and a burst of contradictory intermediate counts).
// Filtering the cached name array instead is 0.5 ms over 5 334 names and
// 1.9 ms over 26 811 -- and it is SYNCHRONOUS, which is what a completion
// has to be.
//
// THE SNAPSHOT IS A PLAIN JS ARRAY, not the model. `get(i, role)` is a
// per-call round trip into the model; the completion walks the whole list on
// every keystroke, so it walks an array of `{ name, isDir }` built once when
// the directory became Ready. `fileIsDir` follows symlinks (QFileInfo does),
// which is the bash-correct answer for the trailing "/": /usr/lib64 is a link
// to a directory and completes as one.
//
// ONE STRAY SCAN AT CONSTRUCTION, and it is the model's not ours:
// FolderListModel's unset `folder` is the process's WORKING DIRECTORY, and it
// starts reading it in its constructor -- before any binding of ours is
// applied. Setting `folder` to "" afterwards settles it at Null; the cost is
// one off-thread listing of the directory quickshell was started in, once per
// composer, and nothing reads its result.
//
// THE CACHE IS PER SESSION, NOT FOREVER. Directories visited while one token
// is being typed are kept (walking down a path costs one scan per level, and
// walking back up costs nothing), and `reset()` -- which the composer calls
// the moment the token is gone -- drops them, so the next "@" sees the
// filesystem as it is now rather than as it was an hour ago.
//
//     LlmPathCompleter { id: completer }
//     completer.dir = "/usr/share";           // at most one scan
//     Complete.decide(completer.entries, "fo") // synchronous, every keystroke
// =============================================================================
Item {
    id: root

    // ---- Contract ---------------------------------------------------------
    // The directory to list: an absolute path, no trailing slash (except "/").
    // "" means nothing is being completed.
    property string dir: ""
    // "idle" | "loading" | "ready" | "nodir".
    //
    // "ready" MEANS THE SNAPSHOT IS IN HAND, not that the model says Ready.
    // Measured: the model keeps its PREVIOUS Ready while a newly assigned
    // folder has not yet been applied, so a status read straight off it says
    // "ready" with the new directory's entries still empty -- and a Tab in
    // that instant would answer "no such name" for a directory that is right
    // there. Keyed on the cache, status and `entries` cannot disagree.
    readonly property string status: root.dir.length === 0 ? "idle"
        : (root._cache[root.dir] !== undefined ? "ready"
        : (root._nodir === root.dir ? "nodir" : "loading"))
    // [{ name, isDir }] for `dir`, or [] while it is loading or absent.
    readonly property var entries: root._cache[root.dir] !== undefined ? root._cache[root.dir] : []
    // The user's home, for "~" and for a bare "@".
    readonly property string home: Quickshell.env("HOME") || ""

    // How many directories' listings are kept at once. Eight is a deep path
    // plus its siblings; the ninth drops the oldest.
    property int cacheSize: 8
    // How long a directory may take to answer before it is treated as one
    // that is not there. A local listing of 26 811 entries took 191 ms.
    property int stallMs: 1500

    // Drop every listing. The composer calls this when the token goes away,
    // so a completion never answers from a directory it read minutes ago.
    function reset() {
        root._cache = ({});
        root._order = [];
        root.dir = "";
        root._want = "";
    }

    visible: false

    // ---- The one listing --------------------------------------------------
    property var _cache: ({})
    property var _order: []
    // WHAT THE MODEL IS BEING ASKED FOR, which is not always what is being
    // completed: a cached directory asks for nothing. It is a property of its
    // own rather than a binding on `_cache` so that filling the cache cannot
    // re-enter the model's own status handler.
    property string _want: ""
    // The model's Null for the directory we asked for: there is no such
    // directory.
    property string _nodir: ""
    readonly property string _wantUrl: root._want.length === 0 ? "" : Complete.folderUrl(root._want)
    // IS THE MODEL ACTUALLY ON THE DIRECTORY WE ASKED FOR? Every status this
    // file believes has to pass this first. Measured: assigning a new
    // `folder` emits countChanged(0) while `status` is STILL the previous
    // directory's Ready, so a snapshot taken on that signal would cache an
    // EMPTY listing for a directory full of files -- and, being cached, it
    // would never be asked again. The read-back of `folder` is byte-identical to what
    // was assigned, double encoding and all (also measured), so comparing
    // them is exact.
    function _atWant() {
        return root._want.length > 0 && String(flm.folder) === root._wantUrl;
    }
    onDirChanged: {
        root._nodir = "";
        root._want = (root.dir.length === 0 || root._cache[root.dir] !== undefined) ? "" : root.dir;
        if (root._want.length > 0)
            stall.restart();
        else
            stall.stop();
    }

    // THE NET UNDER ALL OF IT. Every "is this listing ours" test above is an
    // agreement with a model that answers on its own thread; if one of them
    // is ever wrong the completion would sit at "loading" forever, which
    // looks like a Tab that does nothing and reads like a hang. So a
    // directory that has produced no listing by now is treated as one that
    // does not exist: the completion answers "nothing here" instead of
    // waiting, and if the listing does arrive later the cache overrides this
    // on the next keystroke.
    Timer {
        id: stall
        interval: root.stallMs
        onTriggered: if (root._want.length > 0 && root._cache[root._want] === undefined)
            root._nodir = root._want;
    }

    FolderListModel {
        id: flm
        // The double encode survives QUrl's one decode -- see
        // LlmPathComplete.js's header.
        folder: root._wantUrl
        showDirs: true
        showFiles: true
        showHidden: true
        showDotAndDotDot: false
        showOnlyReadable: false
        sortField: FolderListModel.Name
        // `nameFilters` is deliberately never written -- see the header.
        onStatusChanged: {
            if (root._atWant() && flm.status === FolderListModel.Null)
                root._nodir = root._want;
            root._snapshot();
        }
        onCountChanged: root._snapshot()
    }

    function _snapshot() {
        if (!root._atWant() || flm.status !== FolderListModel.Ready)
            return;
        const d = root._want;
        if (root._cache[d] !== undefined)
            return;
        const out = [];
        for (let i = 0; i < flm.count; i++)
            out.push({ name: String(flm.get(i, "fileName")), isDir: !!flm.get(i, "fileIsDir") });
        // A NEW OBJECT, never the old one mutated: assigning a `var`
        // property the SAME reference back does not notify, so the entries
        // binding would keep its stale (empty) answer and the completion
        // would find nothing in a directory it had just read.
        const c = {};
        const o = root._order.slice();
        o.push(d);
        while (o.length > root.cacheSize)
            o.shift();
        for (let k = 0; k < o.length; k++)
            if (o[k] !== d && root._cache[o[k]] !== undefined)
                c[o[k]] = root._cache[o[k]];
        c[d] = out;
        root._order = o;
        root._cache = c;
    }
}
