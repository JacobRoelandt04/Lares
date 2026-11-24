pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// AudioArt.qml
//
// The picture INSIDE an audio file, as a url something can point an Image at.
// The second answer to "what does this record look like", after the cover file
// sitting next to it on disk.
//
// WHY IT EXISTS. A directory of one album has a `cover.jpg` and every song in
// it shares that one picture. A directory of loose songs -- `~/Music/Tracks`,
// the favourites -- has no such file and never will: its 35 songs are 35
// different records. Every one of them CARRIES its own art, though; measured
// with ffprobe over this library, the m4a and flac files there each hold an
// `mjpeg` 1280x1280 and even the cover-less `Albums/Loop Hero Soundtrack`
// mp3s hold a `png` 1098x1098. So the art is not missing -- it is one
// directory read away from being shown; without it a playlist of loose songs
// would put a blank vinyl on the turntable for every one of them.
//
// WHY NOT MPD. `albumart` and `readpicture` are exactly this question asked of
// the daemon, and both answer with raw binary inline. Quickshell's Socket
// hands over QStrings, so a JPEG comes through UTF-8 decoding shredded. That
// is why the module reads `cover.jpg` on disk, and why this goes to the
// file on disk too.
//
// SO IT IS AN EXTRACTION, AND IT IS CACHED ON DISK. One `ffmpeg -c copy` per
// file -- measured 38 ms for a 1280x1280 jpeg -- writing the picture into
// `$XDG_CACHE_HOME/lares/audio-art/<hash>.<ext>` under a hash of the
// file's absolute path. A second session costs one `ls` of that directory for
// the WHOLE library, and the listing IS the cache: nothing is re-extracted, so
// the expensive half runs once per file per lifetime.
//
// A FILE WITH NO PICTURE ANSWERS ONCE. It gets a zero-byte `<hash>.none`
// beside the pictures, which the listing reads back as "asked, has none". A
// library of 411 files with nothing in them must not cost 411 processes on
// every launch, and "" is an answer worth remembering exactly as much as a
// picture is.
//
// THE EXTENSION COMES FROM THE CODEC, not from a guess. `image2` with
// `-c copy` writes whatever packet the file holds, so a png packet in a
// `.jpg` would be a file whose name lies -- and Qt's image loader is asked to
// sniff it. One `ffprobe` names the codec, one `case` maps it, and the two
// commands are one shell line because they are one question.
//
// THE WRITE IS ATOMIC. `<hash>.<ext>.part` then `mv`, so a run killed halfway
// -- which is what `tools/dev/smoke.sh` does to everything -- can never leave a
// truncated JPEG in the cache to be handed out forever after.
//
// ONE PROCESS AT A TIME, NEWEST WINS, like AudioTags. The want list is a
// STACK: the song that just started is asked about last and so runs first, and
// the far end of a 527-song queue that was registered in the same breath waits
// its turn. It is capped, and the cap drops the OLDEST want -- a want that is
// still wanted is re-registered by the next `urlFor` for it, and one that is
// not has gone quietly.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // Nothing runs unless this is true -- not even the directory listing. A
    // host that never shows art must never fork.
    property bool active: false

    // Where the extracted pictures live. Keyed by a hash of the source's
    // absolute path, so two libraries on one machine cannot collide and a
    // moved file simply asks again.
    property string cacheDir: (Quickshell.env("XDG_CACHE_HOME")
                               || ((Quickshell.env("HOME") || "") + "/.cache"))
                              + "/lares/audio-art"

    property string ffmpeg: "ffmpeg"
    property string ffprobe: "ffprobe"
    // How many un-answered wants are kept. Reading a long queue registers one
    // per song; only the newest this many survive, and the rest come back the
    // next time somebody asks for them.
    property int maxPending: 32
    property bool debug: false

    // The directory has been read, so `urlFor` can answer from what is already
    // there without forking anything.
    readonly property bool ready: root._indexReady
    readonly property bool working: root._running.length > 0

    // A file's picture is now known. `url` is "" when the file holds none --
    // an answer, not a failure, and the last word on that file.
    signal resolved(string path, string url)

    // The picture of `path` (an ABSOLUTE path), or "" when there is none yet.
    // SYNCHRONOUS and never blocking: an unknown file is registered as wanted
    // and answered "" now, and `resolved` fires when the answer exists.
    function urlFor(path) {
        if (!path) return "";
        const p = String(path);
        const h = root.hashOf(p);
        const have = root._index[h];
        if (have !== undefined)
            return have.length > 0 ? root._urlOf(have) : "";
        root.want(p);
        return "";
    }

    // Ask about `path` without wanting an answer this frame -- what a view
    // that is about to show something calls to get ahead of itself.
    function want(path) {
        if (!path) return;
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

    // Whether the answer for `path` is already known, picture or none. The
    // distinction `urlFor` cannot make on its own: "" is both "no picture" and
    // "not asked yet", and a caller that must not flash a placeholder needs to
    // know which it is holding.
    function isKnown(path) {
        return path ? root._index[root.hashOf(String(path))] !== undefined : false;
    }

    // The cache name of a path, without its extension. FNV-1a twice over the
    // same bytes with different offset bases -- 64 bits of hex, which for a
    // library of a few thousand files is a collision every never. Public
    // so a caller can check that the file it names is the file on disk.
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

    // hash -> the file in the cache directory, "" for a source that holds no
    // picture, absent for one nobody has asked about. The same three-way shape
    // MpdService's cover map has, and for the same reason: "" and absent are
    // different answers.
    property var _index: ({})
    property var _wanted: []        // paths, oldest first; the newest runs next
    property string _running: ""
    property bool _indexReady: false
    property bool _listing: false
    property int _known: 0
    property int _empty: 0
    // NOTHING RUNS BEFORE THE OBJECT IS FINISHED. `active: true` written above
    // `cacheDir:` in the host is assigned first, and a listing started from
    // that assignment reads a `cacheDir` that has not been given its value yet
    // -- measured: the directory listed is the empty string, so the cache
    // comes back empty and every file in it is extracted a second time.
    property bool _started: false

    onActiveChanged: {
        if (root.active) root._readIndex();
    }
    // A cache directory changed under a live object is a different cache: what
    // is known about the old one is not known about this one.
    onCacheDirChanged: {
        root._index = ({});
        root._known = 0;
        root._empty = 0;
        root._indexReady = false;
        root._readIndex();
    }
    Component.onCompleted: {
        root._started = true;
        root._readIndex();
    }

    function _log(m) {
        if (root.debug) console.log("AudioArt: " + m);
    }

    function _hex8(n) {
        let s = (n >>> 0).toString(16);
        while (s.length < 8) s = "0" + s;
        return s;
    }
    function _urlOf(name) {
        // encodeURI leaves `/` alone, which is what a path wants, but it also
        // leaves `#` and `?` -- both of which end a URL's path, and both of
        // which a home directory is allowed to contain.
        return "file://" + encodeURI(root.cacheDir + "/" + name)
            .replace(/#/g, "%23").replace(/\?/g, "%3F");
    }

    // ---- The directory, read once -----------------------------------------
    function _readIndex() {
        if (!root._started || !root.active || root.cacheDir.length === 0) return;
        if (root._listing || root._indexReady) return;
        root._listing = true;
        // The directory is made here rather than by the first extraction, so
        // that the listing of a cache that has never existed is empty instead
        // of an error.
        _lister.command = ["sh", "-c", 'mkdir -p "$1" 2>/dev/null; ls -1 "$1" 2>/dev/null',
                           "sh", root.cacheDir];
        _lister.running = true;
    }

    function _takeIndex(text) {
        const lines = String(text || "").split("\n");
        const idx = ({});
        let known = 0;
        let empty = 0;
        for (let i = 0; i < lines.length; i++) {
            const name = lines[i].trim();
            const dot = name.lastIndexOf(".");
            if (dot <= 0) continue;
            const h = name.substring(0, dot);
            const ext = name.substring(dot + 1);
            // A `.part` is a write that was killed; it is nobody's answer.
            if (ext === "part") continue;
            if (ext === "none") { idx[h] = ""; empty++; continue; }
            idx[h] = name;
            known++;
        }
        root._index = idx;
        root._known = known;
        root._empty = empty;
        root._listing = false;
        root._indexReady = true;
        root._log("cache holds " + known + " pictures, " + empty + " blanks");
        root._pump();
    }

    // ---- One extraction at a time -----------------------------------------

    // $1 source, $2 cache directory, $3 hash. Prints the extension it wrote,
    // or `none`. A shell line rather than an argv because it is two commands
    // and a decision -- but the PATH still arrives as a positional argument,
    // never interpolated, because every apostrophe and bracket in this library
    // is somebody's album title.
    readonly property string _script:
        'b="$2/$3"; ' +
        'mkdir -p "$2" 2>/dev/null; ' +
        'c=$(' + root.ffprobe + ' -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null); ' +
        'case "$c" in mjpeg|jpeg) e=jpg ;; png) e=png ;; bmp) e=bmp ;; gif) e=gif ;; webp) e=webp ;; *) e="" ;; esac; ' +
        'if [ -n "$e" ] && ' + root.ffmpeg + ' -v error -y -i "$1" -map 0:v:0 -c copy -f image2 "$b.part" 2>/dev/null && [ -s "$b.part" ]; then ' +
        'mv -f "$b.part" "$b.$e"; printf %s "$e"; ' +
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
        _worker.command = ["sh", "-c", root._script, "sh", p, root.cacheDir, root.hashOf(p)];
        _worker.running = true;
        root._log("extracting " + p);
    }

    function _onExtracted(code, text) {
        const path = root._running;
        root._running = "";
        if (path.length === 0) return;
        const ext = String(text || "").trim();
        const h = root.hashOf(path);
        const name = (code === 0 && ext.length > 0 && ext !== "none") ? h + "." + ext : "";
        const idx = ({});
        const keys = Object.keys(root._index);
        for (let i = 0; i < keys.length; i++) idx[keys[i]] = root._index[keys[i]];
        idx[h] = name;
        root._index = idx;
        if (name.length > 0) root._known++;
        else root._empty++;
        root.resolved(path, name.length > 0 ? root._urlOf(name) : "");
        // Whatever is wanted NOW starts next, which after a skip through five
        // songs is the fifth one and not the first.
        root._pump();
    }

    // ---- The two children --------------------------------------------------
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
        id: _worker
        running: false
        stdout: StdioCollector {
            id: _workOut
        }
    }
    Connections {
        target: _worker
        function onExited(code) {
            root._onExtracted(code, _workOut.text);
        }
    }
}
