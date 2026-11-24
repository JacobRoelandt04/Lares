pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// CoverThumbs.qml
//
// A SMALL COPY OF EVERY COVER, kept on disk, so that no view ever decodes a
// full-size one.
//
// WHY IT EXISTS (measured). The covers in `~/Music/Albums`
// are the artists' own scans: 1400 to 5000 px square, up to 28 MB, and Qt decodes
// a JPEG in FULL however small `sourceSize` is -- twelve of them took 526 ms at
// sourceSize 256 and 587 ms at 512, the same either way, ~44 ms each. Every
// asynchronous Image of the process shares ONE reader thread, and the pictures that
// were queued last are read first, so the library's dozen rows (queued after the
// vinyl's label) are decoded BEFORE the label, and the OSD's card, which decodes
// one cover when it opens, shows ~5 frames (42 ms at 120 Hz) without its picture.
// The same twelve as 768 px thumbnails: 27 ms in all. The images are not slow
// because they come out of the audio files (the embedded ones are 1280 px and
// already cheaper); they are slow because they are huge, and every popup open
// decodes them again.
//
// SO IT IS A CACHE, LIKE THE OS'S FILE MANAGER ONE. One `ffmpeg` scale per source
// file -- 768 px on the long side (the biggest decode any consumer asks for: the
// sleeve's cap), a q3 JPEG, ~30-100 KB -- written to
// `$XDG_CACHE_HOME/lares/audio-thumbs/<hash>-<mtime>.jpg`, `hash` of the
// source's absolute path and `mtime` the source's own, in seconds. The name IS the
// validity: a cover that was replaced has another mtime, so the thumb of the old one
// is not the answer for it. A second session costs one `ls` of that directory for the
// whole library and one `stat` per batch of covers asked about -- nothing is scaled
// again.
//
// A SOURCE THAT CANNOT BE SCALED ANSWERS ONCE. A file ffmpeg cannot read gets a
// zero-byte `<hash>-<mtime>.none` and is handed out as itself; a
// source that is not there at all gets nothing written (a fixture, a moved album).
//
// IT NEVER MAKES A VIEW WAIT. `thumbFor` is synchronous: a source with no thumb yet
// is answered AS ITSELF (the original) and
// `resolved` fires when the thumb exists, so the host rewrites its records once.
// The want list is a STACK (the newest ask runs first, so the song under the needle
// is scaled before the rest of a long queue) and capped; one process at a time, at
// `nice 19`.
//
//   thumbFor(url)   `file://...` (percent-encoded) in, the thumb's url out, or the
//                   same url while there is none. Anything that is not a file url
//                   comes back unchanged.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // Nothing runs unless this is true -- not even the directory listing.
    property bool active: false

    property string cacheDir: (Quickshell.env("XDG_CACHE_HOME")
                               || ((Quickshell.env("HOME") || "") + "/.cache"))
                              + "/lares/audio-thumbs"

    // The long side of a thumb, px. 768 is the largest texture any view asks for
    // (VinylSleeve.coverTexMax); the library and the OSD ask for less.
    property int size: 768
    property string ffmpeg: "ffmpeg"
    // Un-answered wants kept. The shelf registers every album at once; only the
    // newest this many survive, and the rest are asked again by the next reseat.
    property int maxPending: 96
    property bool debug: false

    // The directory has been read, so `thumbFor` answers from what is there.
    readonly property bool ready: root._indexReady
    readonly property bool working: root._running.length > 0

    // A source's thumb now exists. `path` is the source's ABSOLUTE path, `url` the
    // thumb's url.
    signal resolved(string path, string url)

    function thumbFor(url) {
        const path = root.pathOf(url);
        if (path.length === 0) return url;
        const h = root.hashOf(path);
        const have = root._index[h];
        if (have !== undefined) {
            if (root._checked[h] !== true) root._check(path, h);
            return have.name.length > 0 ? root._urlOf(have.name) : url;
        }
        root.want(path);
        return url;
    }

    function want(path) {
        if (!path || !root.active) return;
        const p = String(path);
        if (root._index[root.hashOf(p)] !== undefined) return;
        const w = root._wanted.slice();
        const at = w.indexOf(p);
        if (at >= 0) w.splice(at, 1);
        w.push(p);
        while (w.length > Math.max(1, root.maxPending)) w.shift();
        root._wanted = w;
        root._pump();
    }

    // `file:///a%20b/c.jpg` -> `/a b/c.jpg`; "" for anything that is not a file url.
    function pathOf(url) {
        const s = String(url || "");
        if (s.indexOf("file://") !== 0) return "";
        try {
            return decodeURIComponent(s.substring(7));
        } catch (e) {
            return "";
        }
    }

    // FNV-1a twice over the same bytes with different offset bases, as AudioArt's:
    // 64 bits of hex, a collision every never for a library of thousands.
    function hashOf(path) {
        const s = String(path);
        let a = 0x811c9dc5;
        let b = 0x01000193;
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i);
            a = Math.imul(a ^ c, 0x01000193) >>> 0;
            b = Math.imul(b ^ c, 0x85ebca6b) >>> 0;
        }
        return root._hex8(a) + root._hex8(b);
    }

    // ======================================================================
    // INTERNALS
    // ======================================================================

    // hash -> { name: "<hash>-<mtime>.jpg" | "" (none), mtime: n }; absent for a
    // source nobody has asked about.
    property var _index: ({})
    property var _checked: ({})       // hash -> true: its mtime was compared this session
    property var _toCheck: []         // [{ path, hash }] waiting for the next batch
    property var _wanted: []          // paths, oldest first; the newest runs next
    property string _running: ""
    property bool _indexReady: false
    property bool _listing: false
    property int _known: 0
    // NOTHING RUNS BEFORE THE OBJECT IS FINISHED (AudioArt's rule): a listing
    // started from `active: true` assigned above `cacheDir:` reads an empty path.
    property bool _started: false

    onActiveChanged: if (root.active) root._readIndex()
    onCacheDirChanged: {
        root._index = ({});
        root._checked = ({});
        root._known = 0;
        root._indexReady = false;
        root._readIndex();
    }
    Component.onCompleted: {
        root._started = true;
        root._readIndex();
    }

    function _log(m) {
        if (root.debug) console.log("CoverThumbs: " + m);
    }
    function _hex8(n) {
        let s = (n >>> 0).toString(16);
        while (s.length < 8) s = "0" + s;
        return s;
    }
    function _urlOf(name) {
        return "file://" + encodeURI(root.cacheDir + "/" + name)
            .replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    // ---- The directory, read once -----------------------------------------
    function _readIndex() {
        if (!root._started || !root.active || root.cacheDir.length === 0) return;
        if (root._listing || root._indexReady) return;
        root._listing = true;
        _lister.command = ["sh", "-c", 'mkdir -p "$1" 2>/dev/null; ls -1 "$1" 2>/dev/null',
                           "sh", root.cacheDir];
        _lister.running = true;
    }

    // `<hash>-<mtime>.jpg` is a thumb, `<hash>-<mtime>.none` an answer that there
    // can be none, `.part` a write that was killed (nobody's answer).
    function _takeIndex(text) {
        const lines = String(text || "").split("\n");
        const idx = ({});
        let known = 0;
        for (let i = 0; i < lines.length; i++) {
            const name = lines[i].trim();
            const dot = name.lastIndexOf(".");
            const dash = name.indexOf("-");
            if (dot <= 0 || dash <= 0 || dash > dot) continue;
            const ext = name.substring(dot + 1);
            if (ext !== "jpg" && ext !== "none") continue;
            const h = name.substring(0, dash);
            const mt = parseInt(name.substring(dash + 1, dot));
            // Two generations of one source (a crash between the write and the sweep)
            // keep the newer; `_check` settles which is right.
            const old = idx[h];
            if (old !== undefined && old.mtime > mt) continue;
            idx[h] = { name: ext === "jpg" ? name : "", mtime: isFinite(mt) ? mt : 0 };
        }
        const keys = Object.keys(idx);
        for (let k = 0; k < keys.length; k++)
            if (idx[keys[k]].name.length > 0) known++;
        root._index = idx;
        root._known = known;
        root._listing = false;
        root._indexReady = true;
        root._log("cache holds " + known + " thumbs");
        root._pump();
    }

    // ---- Is a thumb still the source's thumb? ------------------------------
    // The answer is given at once from the name; the source's mtime is read for a
    // batch of them in one `stat` and a thumb that is out of date is dropped and asked
    // for again. Once per source per session.
    function _check(path, h) {
        const c = root._checked;
        c[h] = true;        // in place: a plain map nobody binds to
        root._toCheck.push({ path: path, hash: h });
        _checkTimer.restart();
    }
    Timer {
        id: _checkTimer
        interval: 250
        repeat: false
        onTriggered: root._runCheck()
    }
    function _runCheck() {
        if (!root.active || root._toCheck.length === 0) return;
        if (_checker.running) {
            _checkTimer.restart();
            return;
        }
        root._checking = root._toCheck;
        root._toCheck = [];
        const argv = ["sh", "-c",
                      'for f; do printf "%s\\t%s\\n" "$(stat -c %Y -- "$f" 2>/dev/null || echo 0)" "$f"; done', "sh"];
        for (let i = 0; i < root._checking.length; i++) argv.push(root._checking[i].path);
        _checker.command = argv;
        _checker.running = true;
    }
    property var _checking: []
    function _onChecked(text) {
        const lines = String(text || "").split("\n");
        const now = ({});
        for (let i = 0; i < lines.length; i++) {
            const tab = lines[i].indexOf("\t");
            if (tab <= 0) continue;
            now[lines[i].substring(tab + 1)] = parseInt(lines[i].substring(0, tab));
        }
        let idx = null;
        const w = [];
        for (let i = 0; i < root._checking.length; i++) {
            const e = root._checking[i];
            const mt = now[e.path];
            const have = root._index[e.hash];
            // A source that is gone (0) keeps what it has: nothing to compare with.
            if (mt === undefined || !(mt > 0) || have === undefined || have.mtime === mt) continue;
            if (idx === null) idx = Object.assign({}, root._index);
            delete idx[e.hash];
            w.push(e.path);
        }
        root._checking = [];
        if (idx === null) return;
        root._index = idx;
        for (let j = 0; j < w.length; j++) root.want(w[j]);
    }

    // ---- One scale at a time ------------------------------------------------
    // $1 source, $2 cache directory, $3 hash, $4 size. Prints the mtime it wrote
    // (the thumb is `<hash>-<mtime>.jpg`), `none` for a source ffmpeg could not
    // read, `gone` for one that is not there (nothing is written for that).
    readonly property string _script:
        'src="$1"; dir="$2"; h="$3"; [ -f "$src" ] || { printf gone; exit 0; }; ' +
        'm=$(stat -c %Y -- "$src" 2>/dev/null) || m=0; b="$dir/$h-$m"; mkdir -p "$dir" 2>/dev/null; ' +
        'if nice -n 19 ' + root.ffmpeg + ' -v error -y -i "$src" -frames:v 1 ' +
        '-vf "scale=w=\'min($4,iw)\':h=\'min($4,ih)\':force_original_aspect_ratio=decrease" ' +
        '-q:v 3 -f image2 "$b.part" 2>/dev/null && [ -s "$b.part" ]; then ' +
        'find "$dir" -maxdepth 1 -name "$h-*" ! -name "$h-$m.*" -delete 2>/dev/null; ' +
        'mv -f "$b.part" "$b.jpg"; printf %s "$m"; ' +
        'else rm -f "$b.part"; : > "$b.none"; printf none; fi'

    function _pump() {
        if (!root.active || !root._indexReady || root._running.length > 0) return;
        let p = "";
        const w = root._wanted.slice();
        while (w.length > 0) {
            const cand = w.pop();
            if (root._index[root.hashOf(cand)] === undefined) { p = cand; break; }
        }
        root._wanted = w;
        if (p.length === 0) return;
        root._running = p;
        _worker.command = ["sh", "-c", root._script, "sh", p, root.cacheDir, root.hashOf(p), String(root.size)];
        _worker.running = true;
        root._log("scaling " + p);
    }

    function _onScaled(code, text) {
        const path = root._running;
        root._running = "";
        if (path.length === 0) return;
        const out = String(text || "").trim();
        const h = root.hashOf(path);
        const idx = Object.assign({}, root._index);
        let name = "";
        if (code === 0 && /^[0-9]+$/.test(out)) {
            name = h + "-" + out + ".jpg";
            idx[h] = { name: name, mtime: parseInt(out) };
            root._known++;
        } else {
            // `none` and `gone` alike: nothing better than the source is coming, and
            // for this session it is not asked again.
            idx[h] = { name: "", mtime: 0 };
        }
        root._index = idx;
        const c = root._checked;
        c[h] = true;
        if (name.length > 0) root.resolved(path, root._urlOf(name));
        root._pump();
    }

    // ---- The children ---------------------------------------------------------
    Process {
        id: _lister
        running: false
        stdout: StdioCollector {
            id: _listOut
        }
    }
    Connections {
        target: _lister
        function onExited(code) {
            root._takeIndex(code === 0 ? _listOut.text : "");
        }
    }
    Process {
        id: _checker
        running: false
        stdout: StdioCollector {
            id: _checkOut
        }
    }
    Connections {
        target: _checker
        function onExited(code) {
            root._onChecked(code === 0 ? _checkOut.text : "");
        }
    }
    Process {
        id: _worker
        running: false
        stdout: StdioCollector {
            id: _workOut
        }
    }
    Connections {
        target: _worker
        function onExited(code) {
            root._onScaled(code, _workOut.text);
        }
    }
}
