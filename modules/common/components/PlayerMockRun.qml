pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "MpdFidelity.js" as Fid
import "MpdHealth.js" as Health
import "MpdShuffle.js" as Shuffle

// =============================================================================
// PlayerMockRun.qml
//
// A player-shaped object with no daemon behind it: the same surface
// `MpdService` exposes, driven by a clock and a synthetic queue, so the mockup
// can be opened, smoke-tested and grabbed without touching the real MPD -- and
// without a smoke run putting music on.
//
// It is seeded from the REAL library, though. A mock album list invented here
// would drift from what is on disk the moment a record is added, and the whole
// point of the vinyl is the cover art: so one `find` reads the album
// directories and their cover.jpg, and the tracks are synthesised against
// those. Everything that is a fact (the album's name, the artist, the cover's
// path) comes from the disk; only what is a fiction (durations, the order they
// are played in) is made up here.
//
// The surface is deliberately the SERVICE's, not a subset: the popup binds to
// `current`, `elapsed`, `queue`, `albumProgress` and calls `play()`, `seek()`,
// `next()` and the rest without knowing which of the two it has. Anything the
// popup can reach must exist here, or the mockup silently shows a dead control.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // THE SERVICE SURFACE
    // ======================================================================
    readonly property bool connected: true
    property string playState: "stop"          // "play" | "pause" | "stop"
    readonly property bool playing: root.playState === "play"
    property int songId: -1
    property int songPos: -1
    property real duration: 0
    property real elapsed: 0
    property real volume: 0.72
    property bool repeatOn: false
    property bool randomOn: false
    property bool singleOn: false
    property bool consumeOn: false
    property int bitrate: 0

    // ---- the health check's twin (MpdService.health): the mockup stages a cause and the button's
    // outcome; the words are MpdHealth.js's own, so what the mockup shows is what the service says.
    readonly property var _healthOk: ({ kind: "ok", severity: "", title: "", words: "", hint: "", action: null, device: "",
                                        busy: false, busyWords: "", outcome: "", outcomeWords: "", shown: false })
    property var health: root._healthOk
    property bool healthWillWork: true
    // How long the staged action "works" before its outcome (a render holds it in the middle with a long one).
    property int mockActMs: 1400
    function mockProblem(kind) {
        const dac = { id: 1, name: "alsa_output.usb-ACME", desc: "ACME AUDIO DAC PRO", state: "running", error: "", default: true };
        const err = Object.assign({}, dac, { state: "error" });
        const probe = (o) => Object.assign({ pw: "ok", sinks: [dac], procs: { mpd: ["S"], wireplumber: ["S"], pipewire: ["S"] }, wchan: {} }, o || {});
        let f = { down: false, stuck: false, error: false, stalled: false, errorText: "", probe: probe() };
        switch (kind) {
        case "stall": f.stalled = true; break;
        case "device-error": f.stalled = true; f.probe = probe({ sinks: [err] }); break;
        case "device-hung": f.stalled = true; f.probe = probe({ sinks: [err], procs: { mpd: ["S"], wireplumber: ["D"], pipewire: ["S"] }, wchan: { wireplumber: "usb_start_wait_urb" } }); break;
        case "mpd-down": f.down = true; f.probe = probe({ procs: {} }); break;
        case "mpd-stuck": f.stuck = true; f.probe = probe({ procs: { mpd: ["D"], wireplumber: ["S"], pipewire: ["S"] } }); break;
        case "no-sink": f.stalled = true; f.probe = probe({ sinks: [] }); break;
        case "output-error": f.error = true; f.errorText = "Failed to open \"PipeWire\" (pipewire); Failed to connect to PipeWire"; break;
        default: root.health = root._healthOk; return;
        }
        const d = Health.diagnose(f);
        root.health = Object.assign({}, d, { busy: false, busyWords: "", outcome: "", outcomeWords: "", shown: true });
    }
    function healthRun(id) {
        const h = Object.assign({}, root.health, { busy: true, busyWords: "Working on it…" });
        root.health = h;
        _mockAct.restart();
    }
    Timer {
        id: _mockAct
        interval: root.mockActMs
        onTriggered: {
            if (root.healthWillWork)
                root.health = Object.assign({}, root._healthOk, { shown: true, outcome: "ok", outcomeWords: "Playing again." });
            else
                root.health = Object.assign({}, root.health, { busy: false, busyWords: "", outcome: "failed", outcomeWords: "That did not help." });
            _mockClear.restart();
        }
    }
    Timer {
        id: _mockClear
        interval: 3000
        onTriggered: { if (root.health.outcome === "ok") root.health = root._healthOk; else root.health = Object.assign({}, root.health, { outcome: "", outcomeWords: "" }); }
    }
    function healthCheck() {}
    function healthDismiss() { root.health = root._healthOk; }
    property string audioFormat: ""
    property var current: null
    property var fidelity: null
    property var queue: []
    readonly property int queueLength: root.queue.length
    property var albums: []
    property var artists: []
    property var genres: []
    property var recent: []
    property var playlists: []
    property bool libraryLoading: true
    // MpdService.updating's twin: the mock's rescan is its directory walk.
    readonly property bool updating: root.libraryLoading
    readonly property bool libraryLoaded: !root.libraryLoading && root.albums.length > 0
    property real prevRestartSec: 3
    // Shuffle is a MODE over the queue's order, not MPD's own random: the spec
    // asks for a shuffle that spaces artists and albums out, and MPD's random
    // would pick its own order over the top of ours. Turning it on shuffles
    // what is in the queue now, and THE MODE DOES ITS JOB WHERE THE QUEUE IS
    // FILLED: every collection that goes in -- an album, a list, a genre --
    // goes in shuffled, and the queue is then re-spread so what arrived is
    // mixed with what was already waiting. Both halves, as the service has
    // them: the first is what stops a collection that starts playing at once
    // from starting on track 1.
    property bool shuffleMode: false
    // The spacing biases, mirrored from the service so the two shuffles are
    // the same shuffle.
    property int shuffleArtistGap: 3
    property int shuffleAlbumGap: 2
    property int shuffleTries: 40

    // HOW FAR THROUGH THE RECORD ON THE PLATTER, 0..1, and 0 whenever there is
    // no record on it -- THE SERVICE'S RULE, answered the same way, because the
    // mockup is where the flip is judged. `MpdService._findAlbumRun` is
    // where the reasoning is written down; the only differences here are that
    // the mock's paths are absolute and its shelf is already in hand, so the
    // record's length needs no round trip.
    //
    // A rule of "every queue entry sharing the current song's album tag, over
    // itself" would read 1.0 for a single tagged song in a playlist -- a full
    // album, played through, on its last track -- and turn the record over on
    // the first song of a shuffled favourites list.
    property real albumProgress: 0
    property real albumRunCoverage: 0.75
    property real albumRunDensity: 0.8
    property int albumRunGap: 2
    property int albumRunMin: 2
    property string _runKey: ""
    property var _runIds: []
    property int _runTotal: 0
    // Album directory -> the songs in it, from the scan. The service asks the
    // daemon; the mock has already counted the files.
    property var _dirSongs: ({})

    // Everything the run is read off. `songPos` rather than `songId` because
    // `_seat` writes the id first and the position second, and a run read
    // between the two would be read against the wrong song.
    onQueueChanged: root._recomputeAlbumRun()
    onSongPosChanged: root._recomputeAlbumRun()
    onPlayStateChanged: {
        root._recomputeAlbumRun();
        root._elapsedAtMs = Date.now();
    }

    function _albumDirOf(file) {
        const s = String(file || "");
        const head = root.albumsSubdir === "" ? "/" : "/" + root.albumsSubdir + "/";
        const i = s.indexOf(head);
        if (i < 0) return "";
        const rest = s.substring(i + head.length);
        const slash = rest.indexOf("/");
        if (slash < 0) return "";
        return s.substring(0, i + head.length + slash);
    }
    function _albumSizeOf(dir) {
        if (dir === "") return -1;
        const n = root._dirSongs[dir];
        return n === undefined ? -1 : n;
    }
    function _findAlbumRun(q, pos) {
        const cur = q[pos];
        const dir = root._albumDirOf(cur ? cur.file : "");
        if (dir === "") return null;
        const key = root._albumKeyOf(cur);
        if (key === "") return null;
        const n = root._albumSizeOf(dir);
        if (n < 2) return null;
        const mine = i => {
            const s = q[i];
            return !!s && root._albumDirOf(s.file) === dir && root._albumKeyOf(s) === key;
        };
        let a = pos;
        let b = pos;
        for (let i = pos - 1, back = 0; i >= 0 && back <= root.albumRunGap; i--) {
            if (mine(i)) { a = i; back = 0; } else back++;
        }
        for (let j = pos + 1, fwd = 0; j < q.length && fwd <= root.albumRunGap; j++) {
            if (mine(j)) { b = j; fwd = 0; } else fwd++;
        }
        const members = [];
        for (let m = a; m <= b; m++) if (mine(m)) members.push(m);
        const found = members.length;
        if (found < root.albumRunMin) return null;
        if (found < Math.max(root.albumRunMin, Math.ceil(n * root.albumRunCoverage))) return null;
        if (found < (b - a + 1) * root.albumRunDensity) return null;
        const at = members.indexOf(pos);
        const copy = Math.floor(at / n);
        const ids = [];
        for (let c = copy * n; c < members.length && c < copy * n + n; c++)
            ids.push(q[members[c]].id);
        return { key: dir + "\u0000" + key, ids: ids, total: n, local: at - copy * n };
    }
    function _publishRun(local) {
        root.albumProgress = root._runTotal > 0
            ? Math.min(1, (local + 1) / root._runTotal) : 0;
    }
    function _dropRun() {
        root._runKey = "";
        root._runIds = [];
        root._runTotal = 0;
        root.albumProgress = 0;
    }
    function _holdRun(q) {
        if (root._runKey === "") { root.albumProgress = 0; return; }
        for (let i = 0; i < q.length; ++i)
            if (root._runIds.indexOf(q[i].id) >= 0) return;
        root._dropRun();
    }
    function _recomputeAlbumRun() {
        const q = root.queue || [];
        const pos = root.songPos;
        if (root.playState === "stop" || pos < 0 || pos >= q.length) {
            root._holdRun(q);
            return;
        }
        const cur = q[pos];
        const held = cur ? root._runIds.indexOf(cur.id) : -1;
        if (root._runKey !== "" && held >= 0) {
            root._publishRun(held);
            return;
        }
        const run = root._findAlbumRun(q, pos);
        if (!run) { root._dropRun(); return; }
        root._runKey = run.key;
        root._runIds = run.ids;
        root._runTotal = run.total;
        root._publishRun(run.local);
    }

    // ======================================================================
    // THE CLOCK
    //
    // One integrator, as the real service has: the elapsed time is the only
    // thing that moves, and everything else -- the ball, the record's angle --
    // is a reading of it.
    // ======================================================================
    property real speed: 1.0                   // the panel's "run faster" knob

    // THE SAME GATE AS MpdService's (its header says why): the frame clock runs only while
    // something holds it -- a running FrameAnimation makes every window of the process
    // render at vsync. Held by the player popup while it exists (PlayerTickHold). With no
    // holder the position is caught up by the wall clock when something reads it, and a
    // slow Timer carries the song to its end, so the queue still moves on and the OSD's
    // track card still comes, as it does when the daemon plays.
    property var _tickHolders: []
    property int _tickHoldCount: 0
    readonly property int tickHolds: root._tickHoldCount
    readonly property bool ticking: _tick.running
    // When `elapsed` was last written or the state last changed (Date.now(), ms).
    property real _elapsedAtMs: 0
    onElapsedChanged: root._elapsedAtMs = Date.now()

    function holdTick(who) {
        if (!who || root._tickHolders.indexOf(who) >= 0)
            return;
        if (root._tickHolders.length === 0)
            root._catchUp();
        root._tickHolders.push(who);
        root._tickHoldCount = root._tickHolders.length;
    }
    function releaseTick(who) {
        const i = root._tickHolders.indexOf(who);
        if (i < 0)
            return;
        root._tickHolders.splice(i, 1);
        root._tickHoldCount = root._tickHolders.length;
    }
    // The position the wall clock says it is, for the time nothing ran the frame clock.
    function _catchUp() {
        if (_tick.running || root.playState !== "play")
            return;
        const dt = (Date.now() - root._elapsedAtMs) / 1000 * root.speed;
        if (!(dt > 0))
            return;
        const e = root.elapsed + dt;
        root.elapsed = root.duration > 0 ? Math.min(root.duration, e) : e;
    }

    FrameAnimation {
        id: _tick
        running: root.playing && root.duration > 0 && root._tickHoldCount > 0
        onTriggered: {
            root.elapsed = Math.min(root.duration, root.elapsed + frameTime * root.speed);
            if (root.elapsed >= root.duration)
                root.next();
        }
    }
    // The clock-less song's end: once a second, no frames (a Timer's trigger renders nothing).
    Timer {
        interval: 1000
        repeat: true
        running: root.playing && root.duration > 0 && !_tick.running
        onTriggered: {
            root._catchUp();
            if (root.elapsed >= root.duration)
                root.next();
        }
    }

    // ======================================================================
    // THE LIBRARY, READ OFF THE DISK
    // ======================================================================
    property string musicDir: (Quickshell.env("HOME") || "") + "/Music"
    // Only this subdirectory can hold albums. A song in Tracks/ or a playlist
    // carries album tags too, and the daemon will happily group by them --
    // which shows 69 albums for a 38-album disc.
    property string albumsSubdir: "Albums"
    property var _albumDirs: []

    Process {
        id: scan
        running: true
        // One line per album directory: the directory, whether it has a cover,
        // the NAMES of its audio files and their MTIMES, unit-separated. Every
        // one of them, not the first forty: the record's length is what the
        // flip is measured against, so a directory that hands out fewer names
        // than it has songs would be a record the mockup could never turn. The
        // names matter because the Data panel reads the file itself for its
        // tags and its lyrics -- a synthesised path reads as "could not read
        // this file", and a mock that cannot show the feature cannot be used to
        // judge it. The mtimes matter for the same reason: the service carries
        // one per song and a list is entitled to number itself by it.
        command: ["bash", "-c", 'for d in "' + root.musicDir + '/' + root.albumsSubdir + '"/*/; do a=$(ls "$d" 2>/dev/null | grep -iE "\\.(flac|m4a|mp3|ogg|opus)$"); [ -n "$a" ] || continue; n=$(printf "%s\\n" "$a" | wc -l); h=$(printf "%s\\n" "$a" | head -200); f=$(printf "%s\\n" "$h" | paste -sd $\'\\037\'); m=$(printf "%s\\n" "$h" | while IFS= read -r x; do printf "%s%s\\0" "$d" "$x"; done | xargs -0 stat -c "%Y" 2>/dev/null | paste -sd $\'\\037\'); c=""; [ -f "$d/cover.jpg" ] && c="$d/cover.jpg"; printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "${d%/}" "$n" "$c" "$f" "$m"; done']
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._takeAlbumLine(line)
        }
    }

    // ======================================================================
    // THE PICTURE INSIDE THE FILE
    //
    // The same component the service uses, for the same reason: a directory of
    // loose songs has no cover file and every song in it carries its own art,
    // so without this the mock puts a blank vinyl on the turntable for every
    // song of a playlist -- and a mock that cannot show the feature cannot be
    // used to judge it.
    // ======================================================================
    property bool embedArt: true
    property AudioArt _art: AudioArt {
        active: root.embedArt
    }
    Connections {
        target: root._art
        function onResolved(path, url) {
            if (!artSettle.running)
                artSettle.start();
        }
    }
    // At most one rebuild per 60 ms, as the service coalesces its re-seat:
    // thirty-five favourites resolving one every 40 ms must not rebuild the
    // queue thirty-five times -- and a timer RESTARTED on each arrival would
    // show nothing at all until the last of them landed.
    Timer {
        id: artSettle
        interval: 60
        repeat: false
        onTriggered: root._reseatArt()
    }

    // The directory's cover if it has one, else the picture inside the file.
    // The same order the service answers `coverUrlFor` in.
    function _coverOf(file, dirCover) {
        if (dirCover && dirCover.length > 0)
            return dirCover;
        return root.embedArt ? root._art.urlFor(file) : "";
    }
    // The cover file of the album directory a path sits in, "" for a directory
    // that holds none and for a loose song, which is in no album directory.
    function _dirCoverOf(file) {
        const i = String(file).lastIndexOf("/");
        if (i <= 0)
            return "";
        const dir = String(file).substring(0, i);
        for (let a = 0; a < root._albumDirs.length; ++a)
            if (root._albumDirs[a].dir === dir)
                return root._albumDirs[a].dirCover || "";
        return "";
    }

    // Everything already built, told the truth -- the queue, the song under the
    // needle, and the shelf rows whose directory has no cover file. Records are
    // COPIED rather than mutated: a list only redraws when the array it is
    // bound to changes.
    function _reseatArt() {
        const q = root.queue.slice();
        let moved = false;
        for (let i = 0; i < q.length; ++i) {
            const want = root._coverOf(q[i].file, root._dirCoverOf(q[i].file));
            if (want === q[i].coverUrl)
                continue;
            const copy = ({});
            for (const k in q[i])
                copy[k] = q[i][k];
            copy.coverUrl = want;
            q[i] = copy;
            moved = true;
        }
        if (moved) {
            root.queue = q;
            if (root.songPos >= 0 && root.songPos < q.length)
                root.current = q[root.songPos];
        }
        let amoved = false;
        for (let a = 0; a < root._albumDirs.length; ++a) {
            const rec = root._albumDirs[a];
            if ((rec.dirCover || "").length > 0 || (rec.files || []).length === 0)
                continue;
            const url = root._coverOf(rec.dir + "/" + rec.files[0], "");
            if (url === rec.coverUrl)
                continue;
            rec.coverUrl = url;
            amoved = true;
        }
        if (amoved)
            root.albums = root._albumDirs.slice();
        // The lists' pictures, out of the same extractions.
        root._seatLists();
        // Asked last, so extracted next: the song under the needle is the one
        // picture the record is actually wearing.
        if (root.current)
            root._coverOf(root.current.file, root._dirCoverOf(root.current.file));
    }

    // The loose songs -- `~/Music/Tracks` -- which is what the artists shelf
    // holds IN ADDITION to the album artists when the wider scope is asked for,
    // and what the Favorites list IS. Named "<artist> - <title>.<ext>", which is
    // the shape of every file there.
    //
    // READ WITH THEIR MTIMES, one `stat` line per file: `<epoch>\t<abs path>`.
    // The favourites are a download in the order they were favourited, and the
    // mtime is the only thing that says what that order was -- so a mock that
    // handed out the names alone could not show the list numbered the way the
    // real one is.
    property string tracksSubdir: "Tracks"
    // What that directory is called on a row. The service's own property name,
    // because the panel asks `songsOfPlaylist(favoritesName)` and must not have
    // to know which of the two it is holding.
    property string favoritesName: "Favorites"
    // The OTHER lists: one directory per playlist under `Playlists/`, which is
    // what a playlist is on this system. Read for the same reason the loose
    // shelf is -- invented lists would leave `appendPlaylist` nothing real to
    // queue and the panel nothing real to draw. The service's property name.
    property string playlistsSubdir: "Playlists"
    // A list wears up to four of its songs' covers; `listCoverProbe` bounds how
    // many of its songs may be asked for one. The service's numbers.
    property int listCoverCount: 4
    property int listCoverProbe: 12
    property var _playlistDirs: []
    property var _looseFiles: []
    // WHERE A QUEUED SONG CAME FROM, and the place it holds there.
    //
    // A run of songs that came from a LIST is one listening and wears the
    // LIST's header in recently played, not the headers of whatever albums the
    // files happen to be tagged with: a list is a run of loose files from a
    // dozen albums, so grouping it by album breaks one sitting into six
    // headers of one song each. And the number a song wears under that header
    // is its place IN THE LIST, which is why it is recorded WHEN THE LIST IS
    // QUEUED rather than derived from the run afterwards -- shuffle the list in
    // and the play order is not the list's any more, but the numbers still are.
    //
    // file -> { name, index }. A plain map, mutated in place: nothing binds to
    // it. MpdService keeps the same two facts in a sticker, so they survive a
    // restart there; a mock outlives nothing.
    property var _listOrigin: ({})
    property bool artistsIncludeLoose: false
    onArtistsIncludeLooseChanged: root._rebuildArtists()

    // One line per playlist directory: the directory, its audio files by name
    // and their mtimes, unit-separated -- the same shape the album scan uses,
    // because the questions are the same ones.
    Process {
        id: listScan
        running: true
        command: ["bash", "-c", 'for d in "$1"/*/; do [ -d "$d" ] || continue; a=$(ls -1 "$d" 2>/dev/null | grep -iE "\\.(flac|m4a|mp3|ogg|opus)$"); [ -n "$a" ] || continue; f=$(printf "%s\\n" "$a" | paste -sd $\'\\037\'); m=$(printf "%s\\n" "$a" | while IFS= read -r x; do printf "%s%s\\0" "$d" "$x"; done | xargs -0 stat -c "%Y" 2>/dev/null | paste -sd $\'\\037\'); printf "%s\\t%s\\t%s\\n" "${d%/}" "$f" "$m"; done', "bash", root.musicDir + "/" + root.playlistsSubdir]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._takePlaylistLine(line)
        }
    }

    Connections {
        target: listScan
        function onExited() {
            root._seatLists();
        }
    }

    function _takePlaylistLine(line) {
        const parts = String(line).replace(/\n$/, "").split("\t");
        if (parts.length < 2 || parts[0] === "" || parts[1] === "")
            return;
        const dir = parts[0];
        const name = dir.substring(dir.lastIndexOf("/") + 1);
        const list = root._playlistDirs.slice();
        list.push({
            dir: dir,
            name: name,
            uri: root.playlistsSubdir + "/" + name,
            files: parts[1].split("\u001f"),
            mtimes: parts.length > 2 && parts[2] !== "" ? parts[2].split("\u001f") : []
        });
        root._playlistDirs = list;
    }

    Process {
        id: looseScan
        running: true
        command: ["bash", "-c", 'ls -1 "$1" 2>/dev/null | grep -iE "\\.(flac|m4a|mp3|ogg|opus)$" | while IFS= read -r x; do printf "%s/%s\\0" "$1" "$x"; done | xargs -0 stat --printf="%Y\\t%n\\n" 2>/dev/null', "bash", root.musicDir + "/" + root.tracksSubdir]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._takeLooseLine(line)
        }
    }

    Connections {
        target: looseScan
        function onExited() {
            root._rebuildArtists();
            // The scans race, and Favorites is the loose one's answer while
            // the playlist rows are the list one's. Rebuilt from whichever
            // lands last, so any order ends the same.
            root._seatLists();
        }
    }

    function _takeLooseLine(line) {
        const raw = String(line).replace(/\n$/, "");
        const tab = raw.indexOf("\t");
        if (tab < 0)
            return;
        const mtime = parseInt(raw.substring(0, tab), 10) || 0;
        const path = raw.substring(tab + 1);
        const name = path.substring(path.lastIndexOf("/") + 1);
        if (name === "")
            return;
        const sep = name.indexOf(" - ");
        const dot = name.lastIndexOf(".");
        const list = root._looseFiles.slice();
        list.push({
            file: path,
            artist: sep > 0 ? name.substring(0, sep) : "Unknown",
            title: name.substring(sep > 0 ? sep + 3 : 0, dot > 0 ? dot : name.length),
            lastModified: mtime
        });
        root._looseFiles = list;
    }

    Connections {
        target: scan
        // A Connections handler rather than an inline onExited: qmllint cannot
        // see QProcess::ExitStatus and warns on every inline one.
        function onExited() {
            root._finishScan();
        }
    }

    function _takeAlbumLine(line) {
        const parts = line.split("\t");
        if (parts.length < 2 || parts[0] === "")
            return;
        const dir = parts[0];
        const name = dir.substring(dir.lastIndexOf("/") + 1);
        // "<artist> - <album>" is the shape of every directory in this library;
        // anything else keeps the whole name as the album and no artist.
        const sep = name.indexOf(" - ");
        const artist = sep > 0 ? name.substring(0, sep) : "";
        const album = sep > 0 ? name.substring(sep + 3) : name;
        const list = root._albumDirs.slice();
        list.push({
            dir: dir,
            albumArtist: artist,
            album: album,
            songCount: parseInt(parts[1], 10) || 0,
            // The directory's OWN cover file, and the one a row shows. They
            // are the same until the directory has none, and then the shown
            // one is the picture inside the album's first track -- which is
            // what the service hands out for a cover-less directory too.
            dirCover: parts.length > 2 && parts[2] !== "" ? "file://" + parts[2] : "",
            coverUrl: parts.length > 2 && parts[2] !== "" ? "file://" + parts[2] : "",
            // The directory's own audio files, in `ls` order. A queued song
            // points at one of these rather than at a name this file invented,
            // so the Data tab reads real tags and real lyrics off the disk.
            files: parts.length > 3 && parts[3] !== "" ? parts[3].split("\u001f") : [],
            // Their mtimes, in the same order, epoch seconds.
            mtimes: parts.length > 4 && parts[4] !== "" ? parts[4].split("\u001f") : []
        });
        root._albumDirs = list;
    }

    function _finishScan() {
        // The service's extra record fields (MpdService phase 2): length and year.
        for (let d = 0; d < root._albumDirs.length; ++d) {
            root._albumDirs[d].duration = root._albumDuration(root._albumDirs[d]);
            root._albumDirs[d].year = root._albumYear(d);
            root._albumDirs[d].date = String(root._albumDirs[d].year);
        }
        root.albums = root._albumDirs;
        // How long each record is, which is what `albumProgress` is measured
        // against. The service asks the daemon for it one directory at a time;
        // here the scan has already counted the files.
        const sizes = ({});
        for (let s = 0; s < root._albumDirs.length; ++s)
            sizes[root._albumDirs[s].dir] = root._albumDirs[s].songCount;
        root._dirSongs = sizes;
        root._recomputeAlbumRun();
        root._rebuildArtists();
        root.genres = [
            {
                name: "Electronic",
                songCount: 128
            },
            {
                name: "Shoegaze",
                songCount: 96
            },
            {
                name: "Soundtrack",
                songCount: 141
            },
            {
                name: "Rock",
                songCount: 62
            }
        ];
        root._seatLists();
        root.libraryLoading = false;
        if (root.queue.length === 0 && root.albums.length > 0)
            root.loadAlbumIntoQueue(0);
    }

    // The artists shelf, from the album directories and -- when the wider scope
    // is on -- from the loose files as well. An artist who owns no album is
    // marked `loose` and counted in SONGS, because "0 albums" is not what a row
    // about somebody with three singles should say.
    function _rebuildArtists() {
        const byArtist = {};
        for (let i = 0; i < root._albumDirs.length; ++i) {
            const a = root._albumDirs[i].albumArtist || "Unknown";
            const e = byArtist[a] || (byArtist[a] = {
                albums: 0,
                songs: 0,
                duration: 0
            });
            e.albums++;
            e.songs += root._albumDirs[i].songCount || 0;
            e.duration += root._albumDirs[i].duration || 0;
        }
        if (root.artistsIncludeLoose)
            for (let j = 0; j < root._looseFiles.length; ++j) {
                const n = root._looseFiles[j].artist;
                const e2 = byArtist[n] || (byArtist[n] = {
                    albums: 0,
                    songs: 0
                });
                e2.songs++;
            }
        const arts = [];
        for (const k in byArtist)
            arts.push({
                name: k,
                albumCount: byArtist[k].albums,
                songCount: byArtist[k].songs,
                duration: byArtist[k].duration || 0,
                loose: byArtist[k].albums === 0
            });
        arts.sort((x, y) => x.name.localeCompare(y.name));
        root.artists = arts;
    }

    // The lists, off the disk: `Tracks/` read as Favorites, then one row per
    // directory under `Playlists/`. The service's row shape, field for field,
    // including the up-to-four covers a list wears -- a mock that is nearly the
    // shape is a mock that hides a bug until the live run.
    function _makePlaylists() {
        // Favorites first and marked synthetic: it is not a playlist file, it
        // is ~/Music/Tracks read as one.
        const out = [
            {
                name: root.favoritesName,
                uri: root.tracksSubdir,
                kind: "songdir",
                synthetic: true,
                songCount: root._looseFiles.length,
                coverUrls: root._listCoversOf(root._favouriteFiles())
            }
        ];
        for (let i = 0; i < root._playlistDirs.length; ++i) {
            const d = root._playlistDirs[i];
            out.push({
                name: d.name,
                uri: d.uri,
                kind: "songdir",
                synthetic: false,
                songCount: d.files.length,
                coverUrls: root._listCoversOf(root._listFilesOf(d))
            });
        }
        return out;
    }

    // The rows, rewritten only when something they show actually moved. It is
    // called from the two scans AND from every batch of extracted pictures, and
    // a list that redrew for an unchanged array would flicker through a whole
    // favourites list.
    function _seatLists() {
        const want = root._makePlaylists();
        const have = root.playlists || [];
        if (want.length === have.length) {
            let same = true;
            for (let i = 0; i < want.length && same; ++i)
                if (want[i].name !== have[i].name
                    || want[i].songCount !== have[i].songCount
                    || (want[i].coverUrls || []).join("\u0000") !== (have[i].coverUrls || []).join("\u0000"))
                    same = false;
            if (same)
                return;
        }
        root.playlists = want;
    }

    // The first `listCoverCount` DISTINCT pictures among the first
    // `listCoverProbe` files of a list. A loose song's picture comes out of the
    // FILE, one process each, so the first pass usually finds fewer than four
    // and the row gains the rest as they land -- exactly as a record dresses
    // itself when its art arrives late.
    function _listCoversOf(files) {
        const out = [];
        for (let i = 0; i < files.length && i < root.listCoverProbe
                        && out.length < root.listCoverCount; ++i) {
            const u = root._coverOf(files[i], root._dirCoverOf(files[i]));
            if (u.length > 0 && out.indexOf(u) < 0)
                out.push(u);
        }
        return out;
    }

    // A list's files, IN THE LIST'S OWN ORDER, as absolute paths.
    //
    // Favorites is `~/Music/Tracks` ordered by the file's own mtime, NEWEST
    // FIRST: those files were downloaded in the order they were favourited.
    // A playlist directory is ordered by the `NN.` at the head of each name,
    // which is where a downloaded list keeps its order.
    function _favouriteFiles() {
        const l = root._favouritesOrdered();
        const out = [];
        for (let i = 0; i < l.length; ++i)
            out.push(l[i].file);
        return out;
    }
    function _favouritesOrdered() {
        const dec = [];
        for (let i = 0; i < root._looseFiles.length; ++i)
            dec.push({ f: root._looseFiles[i], at: i });
        dec.sort((a, b) => {
            const ta = Number(a.f.lastModified) || 0;
            const tb = Number(b.f.lastModified) || 0;
            return ta === tb ? a.at - b.at : tb - ta;
        });
        const out = [];
        for (let j = 0; j < dec.length; ++j)
            out.push(dec[j].f);
        return out;
    }
    function _listFilesOf(d) {
        const idx = root._listOrderOf(d);
        const out = [];
        for (let i = 0; i < idx.length; ++i)
            out.push(d.dir + "/" + d.files[idx[i]]);
        return out;
    }
    // The indices of `d.files` in the list's order. `ls` already sorted them by
    // name, which is both the fallback and the tiebreak; the number only has to
    // break what the name cannot (a list numbered without leading zeroes).
    function _listOrderOf(d) {
        const dec = [];
        for (let i = 0; i < d.files.length; ++i)
            dec.push({ at: i, n: root._fileNumber(d.files[i]) });
        dec.sort((a, b) => {
            if (a.n !== b.n) {
                if (a.n === 0)
                    return 1;
                if (b.n === 0)
                    return -1;
                return a.n - b.n;
            }
            return a.at - b.at;
        });
        const out = [];
        for (let j = 0; j < dec.length; ++j)
            out.push(dec[j].at);
        return out;
    }
    // The `NN.` at the head of a file's own name, 0 where it carries none.
    // MpdService._fileNumber is the same rule -- the mock is the service's
    // surface, so it has to answer the same.
    function _fileNumber(file) {
        const u = String(file || "");
        const cut = u.lastIndexOf("/");
        const base = cut >= 0 ? u.substring(cut + 1) : u;
        const m = /^\s*(\d{1,3})\s*(?:[.)\-_]\s*|\s+)/.exec(base);
        if (m === null)
            return 0;
        const n = parseInt(m[1], 10);
        return n > 0 ? n : 0;
    }

    function loadLibrary() {
        if (!root.libraryLoading && root.albums.length > 0)
            return;
        scan.running = true;
    }

    // ======================================================================
    // A SYNTHETIC QUEUE
    // ======================================================================
    property int _nextId: 1
    readonly property var _titles: ["Grown", "Blurred", "Told", "Swept", "Held", "Lure", "Bent", "Dawn", "Fold", "Rise", "Still", "Lift"]

    // "3. airiel - Sharron Apple.m4a" -> "Sharron Apple". Everything up to the
    // first " - " is the track number and the artist, both of which the song
    // record already carries.
    function _titleOfFile(name) {
        const dot = name.lastIndexOf(".");
        const stem = dot > 0 ? name.substring(0, dot) : name;
        const sep = stem.indexOf(" - ");
        return sep > 0 ? stem.substring(sep + 3) : stem;
    }

    // The mock's years and lengths are functions of the index, so the album page, the shelf's sort and
    // the queue agree with each other without a table.
    function _albumYear(i) { return 2008 + ((i * 7) % 17); }
    function _trackDur(t) { return 150 + ((t * 71) % 240); }
    function _albumDuration(a) {
        const n = Math.min(10, a.songCount || 0);
        let d = 0;
        for (let t = 0; t < n; ++t) d += root._trackDur(t);
        return d;
    }
    function _makeSong(albumIdx, trackIdx) {
        const a = root.albums[albumIdx];
        const id = root._nextId++;
        // Durations that look like an album's: a few short, a couple long.
        const dur = root._trackDur(trackIdx);
        // The real file where the directory listing reaches; the synthesised
        // one only where it does not (a mock run against a library that is not
        // this one). A real path is what lets the Data tab read real tags.
        const names = a.files || [];
        const real = trackIdx < names.length ? names[trackIdx] : "";
        const flac = real !== "" ? /\.flac$/i.test(real) : ((albumIdx + trackIdx) % 2 === 0);
        const file = real !== "" ? a.dir + "/" + real
            : a.dir + "/" + (trackIdx + 1) + ". " + a.albumArtist + " - " + root._titles[trackIdx % root._titles.length] + (flac ? ".flac" : ".m4a");
        const mts = a.mtimes || [];
        return {
            id: id,
            pos: -1,
            file: file,
            title: real !== "" ? root._titleOfFile(real) : root._titles[trackIdx % root._titles.length],
            artist: a.albumArtist,
            albumArtist: a.albumArtist,
            album: a.album,
            track: trackIdx + 1,
            disc: 1,
            date: String(root._albumYear(albumIdx)),
            genre: "Electronic",
            duration: dur,
            format: flac ? "96000:24:2" : "44100:f:2",
            coverUrl: root._coverOf(file, a.dirCover),
            // The real file's mtime, epoch seconds, 0 for a synthesised name.
            lastModified: trackIdx < mts.length ? (parseInt(mts[trackIdx], 10) || 0) : 0
        };
    }

    // Fills the queue with one album and starts at its first song -- which
    // while the mode is on is a song of the album and not its first track:
    // the collection is shuffled as it goes in, so what starts playing
    // immediately is already part of the draw.
    function loadAlbumIntoQueue(albumIdx) {
        if (albumIdx < 0 || albumIdx >= root.albums.length)
            return;
        // THE WHOLE ALBUM, not a first slice of it: three quarters of the
        // album has to be in the queue before the vinyl treats it as one, so a
        // sixteen-song album queued ten songs deep could never be turned over
        // in the mockup.
        const n = root.albums[albumIdx].songCount;
        const src = [];
        for (let i = 0; i < n; ++i)
            src.push(root._makeSong(albumIdx, i));
        const q = root.shuffleMode && src.length > 1 ? root._shuffled(src) : src;
        for (let j = 0; j < q.length; ++j)
            q[j].pos = j;
        root.queue = q;
        root._seat(0);
    }

    // Appends a second album so a queue crossing an album boundary -- the one
    // case the record's arrival and departure animation exists for -- can be
    // driven from the panel.
    function appendAlbumIdx(albumIdx) {
        if (albumIdx < 0 || albumIdx >= root.albums.length)
            return;
        const n = root.albums[albumIdx].songCount;
        const src = [];
        for (let i = 0; i < n; ++i)
            src.push(root._makeSong(albumIdx, i));
        root._appendSongs(src);
    }

    // The album a song's TAGS claim, keyed as the service keys it. Half of what
    // makes a record: the other half is the directory it is in.
    function _albumKeyOf(song) {
        if (!song || !song.album) return "";
        return (song.albumArtist || song.artist || "") + "\u0000" + song.album;
    }

    // THE RUN A SONG BELONGS TO. The list it was queued from where there was
    // one, the album otherwise -- everything below groups on this and nothing
    // else, so a list and an album are one rule and not two.
    function _runKeyOf(song) {
        if (!song)
            return "";
        const o = song.file ? root._listOrigin[song.file] : null;
        if (o)
            return "list\u0000" + o.name;
        // NO ALBUM IS NOT A RUN. An untagged song groups with nothing, exactly
        // as the service refuses an empty album key: otherwise two loose files
        // by one artist would wear a header over an album that does not exist.
        if (!song.album)
            return "";
        return (song.albumArtist || song.artist || "") + " — " + song.album;
    }
    // The run an ENTRY already on the list belongs to, read back off the entry
    // rather than kept beside it: a field the service does not produce would be
    // a shape the panel could only ever see here.
    function _entryRunKey(e) {
        if (!e || e.kind !== "album")
            return "";
        if (e.list)
            return "list\u0000" + e.list;
        if (!e.album)
            return "";
        return (e.albumArtist || "") + " — " + e.album;
    }
    // The number a song wears under its run's header: its place in the LIST
    // where it came from one, and 0 for an album -- where the number is the
    // track tag and the panel reads that off the song itself.
    function _listNumberOf(song) {
        const o = song && song.file ? root._listOrigin[song.file] : null;
        return o ? o.index : 0;
    }
    // How long the collection IS, which is what "3 of 10" counts against: the
    // list's own song count, or the album's run in the queue.
    function _runSongCount(song, key) {
        if (key.indexOf("list\u0000") === 0) {
            const l = root._playlistNamed(key.substring(5));
            return l ? Math.max(1, Number(l.songCount) || 1) : 1;
        }
        return root._albumSongCount(song.album);
    }
    function _playlistNamed(name) {
        const l = root.playlists || [];
        for (let i = 0; i < l.length; ++i)
            if (l[i].name === name)
                return l[i];
        return null;
    }

    // `recent` is the grouped shape the library draws: newest first, a grouped
    // entry carrying the songs of the run that have played, a song entry being
    // a standalone play. The mock groups the same way the service does -- if
    // the song belongs to the run at the head of the list, it joins it.
    function _notePlayed(song) {
        if (!song)
            return;
        const now = Math.floor(Date.now() / 1000);
        const out = root.recent.slice();
        const key = root._runKeyOf(song);
        if (out.length > 0 && key !== "" && root._entryRunKey(out[0]) === key) {
            const head = out[0];
            for (let i = 0; i < head.songs.length; ++i)
                if (head.songs[i].file === song.file)
                    return;                      // already in it
            head.songs = head.songs.concat([song]);
            head.listIndex = (head.listIndex || []).concat([root._listNumberOf(song)]);
            head.playedAt = now;
            head.songCount = root._runSongCount(song, key);
            head.partial = head.predicted || head.songs.length < head.songCount;
            out[0] = head;
            root.recent = out;
            return;
        }
        // A new run begins when the queue is going to carry on with it.
        const grouped = key !== "" && root._queueContinuesRun(song, key);
        const entry = grouped ? root._runEntry(song, key, now) : {
            kind: "song",
            key: "song\u0000" + song.file,
            playedAt: now,
            song: song
        };
        out.unshift(entry);
        root.recent = out.slice(0, 40);
    }

    // The grouped entry, in the shape MpdService produces, field for field:
    // the library reads one panel, not two, and a mock that is nearly the
    // shape is a mock that hides a bug until the live run.
    //
    // `kind` STAYS "album" FOR A LIST RUN. It is the shape the entry draws in
    // -- a header with its songs under it -- and the panel branches on it, so
    // a third kind would send every list run down the standalone-song path of
    // a panel that does not know the word. WHERE the run came from is a
    // FIELD, `list`, and the album-shaped fields carry the list's own name so
    // that even a panel ignoring it reads the right words.
    function _runEntry(song, key, now) {
        const isList = key.indexOf("list\u0000") === 0;
        const listName = isList ? key.substring(5) : "";
        const l = isList ? root._playlistNamed(listName) : null;
        return {
            kind: "album",
            key: (isList ? "list\u0000" + listName : "album\u0000" + key)
                 + "\u0000" + now,
            playedAt: now,
            albumArtist: isList ? "" : (song.albumArtist || song.artist || ""),
            album: isList ? listName : (song.album || ""),
            coverUrl: song.coverUrl || "",
            songs: [song],
            songCount: root._runSongCount(song, key),
            predicted: true,
            partial: true,
            // The list half. `list` is "" on an album run, which is what tells
            // the two apart; `listCovers` is the 2 x 2 the lists tab wears; and
            // `listIndex` runs parallel to `songs` -- the place each one holds
            // in the list, which is what survives it being played shuffled.
            list: listName,
            listCovers: l ? (l.coverUrls || []) : [],
            listIndex: [root._listNumberOf(song)]
        };
    }

    function _albumSongCount(album) {
        let n = 0;
        for (let i = 0; i < root.queue.length; ++i)
            if (root.queue[i].album === album)
                n++;
        return Math.max(1, n);
    }

    // The prediction: more of this run is still ahead in the queue, so the run
    // is going to happen and the group is worth opening now.
    function _queueContinuesRun(song, key) {
        for (let i = 0; i < root.queue.length; ++i)
            if (root.queue[i].file !== song.file
                && root._runKeyOf(root.queue[i]) === key)
                return true;
        return false;
    }

    function clearRecent() {
        root.recent = [];
    }
    function removeRecent(kind, key) {
        const out = [];
        for (let i = 0; i < root.recent.length; ++i)
            if (!(root.recent[i].kind === kind && root.recent[i].key === key))
                out.push(root.recent[i]);
        root.recent = out;
    }
    function rescanLibrary() {
        root.libraryLoading = true;
        root._albumDirs = [];
        scan.running = true;
        // The lists are read off the disk too, and a rescan is the one thing
        // that can have changed them. Cleared first, because the scan APPENDS.
        root._playlistDirs = [];
        listScan.running = true;
    }

    function _seat(pos) {
        if (pos < 0 || pos >= root.queue.length) {
            root.current = null;
            root.songId = -1;
            root.songPos = -1;
            root.duration = 0;
            root.elapsed = 0;
            root.playState = "stop";
            root.fidelity = null;
            root.bitrate = 0;
            root.audioFormat = "";
            return;
        }
        const s = root.queue[pos];
        root.current = s;
        root.songId = s.id;
        root.songPos = pos;
        root.duration = s.duration;
        root.elapsed = 0;
        root.audioFormat = s.format;
        root.bitrate = s.format.indexOf(":f:") >= 0 ? 320 : 1997;
        root.fidelity = Fid.classify(s.format, root.bitrate, s.file);
        root._notePlayed(s);
    }

    // ======================================================================
    // THE CONTROLS
    // ======================================================================
    function play() {
        if (root.queue.length === 0)
            return;
        if (root.songPos < 0)
            root._seat(0);
        root.playState = "play";
    }
    function pause() {
        if (root.playState === "play") {
            root._catchUp();
            root.playState = "pause";
        }
    }
    function toggle() {
        if (root.playing)
            root.pause();
        else
            root.play();
    }
    function stop() {
        root.playState = "stop";
        root.elapsed = 0;
    }
    function next() {
        const wasPlaying = root.playing;
        if (root.songPos + 1 < root.queue.length)
            root._seat(root.songPos + 1);
        else if (root.repeatOn)
            root._seat(0);
        else {
            root._seat(-1);
            return;
        }
        root.playState = wasPlaying ? "play" : root.playState;
    }
    // The three-second rule: a prev inside the first three seconds steps back,
    // after them it restarts the song you are in. Every player does this and
    // the spec asks for it by name.
    function prev() {
        root._catchUp();
        if (root.prevRestartSec > 0 && root.elapsed > root.prevRestartSec) {
            root.elapsed = 0;
            return;
        }
        if (root.songPos > 0) {
            const wasPlaying = root.playing;
            root._seat(root.songPos - 1);
            root.playState = wasPlaying ? "play" : root.playState;
        } else {
            root.elapsed = 0;
        }
    }
    function seek(sec) {
        root.elapsed = Math.max(0, Math.min(root.duration, sec));
    }
    function seekFrac(f) {
        root.seek(f * root.duration);
    }
    function setVolume(v) {
        root.volume = Math.max(0, Math.min(1, v));
    }
    function setRepeat(b) {
        root.repeatOn = b;
    }
    function setRandom(b) {
        root.randomOn = b;
    }
    function setSingle(b) {
        root.singleOn = b;
    }
    function setConsume(b) {
        root.consumeOn = b;
    }
    function playId(id) {
        for (let i = 0; i < root.queue.length; ++i)
            if (root.queue[i].id === id) {
                root._seat(i);
                root.playState = "play";
                return;
            }
    }
    function removeId(id) {
        const q = [];
        for (let i = 0; i < root.queue.length; ++i)
            if (root.queue[i].id !== id)
                q.push(root.queue[i]);
        for (let i = 0; i < q.length; ++i)
            q[i].pos = i;
        root.queue = q;
    }
    function clearQueue() {
        root.queue = [];
        root._seat(-1);
    }
    function moveQueue(from, to) {
        if (from === to || from < 0 || to < 0 || from >= root.queue.length || to >= root.queue.length)
            return;
        const q = root.queue.slice();
        const s = q.splice(from, 1)[0];
        q.splice(to, 0, s);
        for (let i = 0; i < q.length; ++i)
            q[i].pos = i;
        root.queue = q;
        for (let i = 0; i < q.length; ++i)
            if (q[i].id === root.songId)
                root.songPos = i;
    }
    // ---- Queueing, in the LIST's order --------------------------------------
    //
    // They queue in the same order the service does -- a list resolved
    // through `songsOfPlaylist` and appended in that order, never in the order
    // the directory happens to be in -- so the mockup can show a list being
    // queued, and being queued WRONG.
    // One song added on its own is one song, whatever list it is also a file
    // of: the provenance is dropped rather than left over from a run that has
    // been and gone.
    function appendUri(uri) {
        const song = root._songForFile(uri);
        if (song) {
            delete root._listOrigin[song.file];
            root._appendSongs([song]);
        }
    }
    // A song picked to be heard now: after the current one and onto it, or, with
    // nothing playing, appended and played (the service's `playUriNow`: `next` is
    // refused when stopped).
    function playUriNow(uri) {
        if (root.playState !== "stop") {
            root.playNextUri(uri);
            root.next();
            return;
        }
        const song = root._songForFile(uri);
        if (!song)
            return;
        delete root._listOrigin[song.file];
        root._appendSongs([song]);
        root.playId(song.id);
    }
    function playNextUri(uri) {
        const song = root._songForFile(uri);
        if (!song)
            return;
        if (root.songPos < 0) {
            delete root._listOrigin[song.file];
            root._appendSongs([song]);
            return;
        }
        delete root._listOrigin[song.file];
        const q = root.queue.slice();
        q.splice(root.songPos + 1, 0, song);
        for (let i = 0; i < q.length; ++i)
            q[i].pos = i;
        root.queue = q;
    }

    // The one place resolved songs become queue entries, as `_queueSongs` is in
    // the service. While shuffle is a MODE the collection goes IN shuffled and
    // the queue is then re-spread, so what arrived is mixed with what was
    // already waiting -- the same two halves the service has.
    function _appendSongs(songs, listName) {
        const src = songs || [];
        // The list's own order is the numbering, so it is read off `src`
        // before the mode is allowed to reorder anything.
        for (let n = 0; n < src.length; ++n)
            if (listName && src[n] && src[n].file)
                root._listOrigin[src[n].file] = { name: listName, index: n + 1 };
        const l = root.shuffleMode && src.length > 1
                  ? root._shuffled(src) : src;
        if (l.length === 0)
            return;
        const q = root.queue.slice();
        for (let i = 0; i < l.length; ++i) {
            l[i].pos = q.length;
            q.push(l[i]);
        }
        root.queue = q;
        if (root.shuffleMode)
            root.shuffleQueue();
    }

    // A song record for a path, wherever on the disk it is: the loose shelf, a
    // playlist directory, or an album. Null for a path this mock has not read,
    // which is what a queue command for a file that is not there should do.
    function _songForFile(uri) {
        const path = String(uri || "");
        if (path === "")
            return null;
        for (let i = 0; i < root._looseFiles.length; ++i)
            if (root._looseFiles[i].file === path)
                return root._makeLooseSong(root._looseFiles[i]);
        for (let d = 0; d < root._playlistDirs.length; ++d) {
            const rec = root._playlistDirs[d];
            for (let j = 0; j < rec.files.length; ++j)
                if (rec.dir + "/" + rec.files[j] === path)
                    return root._makePlaylistSong(rec, j);
        }
        for (let a = 0; a < root._albumDirs.length; ++a) {
            const al = root._albumDirs[a];
            const names = al.files || [];
            for (let t = 0; t < names.length; ++t)
                if (al.dir + "/" + names[t] === path)
                    return root._makeSong(a, t);
        }
        return null;
    }

    // One file of a playlist directory -> a song record. "01. Artist - Title"
    // is the shape of every name there; the number is the LIST's, not a track
    // number, so it is stripped from the title and not written into `track`.
    function _makePlaylistSong(d, i) {
        const name = d.files[i];
        const path = d.dir + "/" + name;
        const flac = /\.flac$/i.test(name);
        const dot = name.lastIndexOf(".");
        const stem = dot > 0 ? name.substring(0, dot) : name;
        const body = stem.replace(/^\s*\d{1,3}\s*(?:[.)\-_]\s*|\s+)/, "");
        const sep = body.indexOf(" - ");
        const artist = sep > 0 ? body.substring(0, sep) : "Unknown";
        return {
            id: root._nextId++,
            pos: -1,
            file: path,
            title: sep > 0 ? body.substring(sep + 3) : body,
            artist: artist,
            albumArtist: artist,
            album: "",
            track: 0,
            disc: 1,
            date: "2024",
            genre: "Shoegaze",
            duration: 168 + ((i * 37) % 170),
            format: flac ? "44100:24:2" : "44100:f:2",
            coverUrl: root._coverOf(path, ""),
            lastModified: i < d.mtimes.length ? (parseInt(d.mtimes[i], 10) || 0) : 0
        };
    }
    function appendAlbum(albumArtist, album) {
        for (let i = 0; i < root.albums.length; ++i)
            if (root.albums[i].album === album && root.albums[i].albumArtist === albumArtist) {
                root.appendAlbumIdx(i);
                return;
            }
    }
    function playAlbum(albumArtist, album) {
        for (let i = 0; i < root.albums.length; ++i)
            if (root.albums[i].album === album && root.albums[i].albumArtist === albumArtist) {
                root.loadAlbumIntoQueue(i);
                root.playState = "play";
                return;
            }
    }
    // The album in the queue's place, not started (MpdService's own).
    function loadAlbum(albumArtist, album) {
        for (let i = 0; i < root.albums.length; ++i)
            if (root.albums[i].album === album && root.albums[i].albumArtist === albumArtist) {
                root.stop();
                root.loadAlbumIntoQueue(i);
                return;
            }
    }
    function songsOfAlbum(albumArtist, album, cb) {
        for (let i = 0; i < root.albums.length; ++i)
            if (root.albums[i].album === album && root.albums[i].albumArtist === albumArtist) {
                const n = Math.min(10, root.albums[i].songCount);
                const out = [];
                for (let t = 0; t < n; ++t)
                    out.push(root._makeSong(i, t));
                if (cb)
                    cb(out);
                return;
            }
        if (cb)
            cb([]);
    }
    // ---- the service's library surface, mock side ----
    function albumInfo(albumArtist, album, cb) {
        root.songsOfAlbum(albumArtist, album, songs => {
            let dur = 0;
            const fm = ({});
            const order = [];
            for (let i = 0; i < songs.length; ++i) {
                dur += songs[i].duration;
                const l = Fid.classify(songs[i].format, 0, songs[i].file).label;
                if (l && !fm[l]) { fm[l] = true; order.push(l); }
            }
            if (cb) cb({ songs: songs, duration: dur, discs: 1, year: songs.length ? parseInt(songs[0].date, 10) : 0,
                         genre: songs.length ? songs[0].genre : "", label: "", formats: order, mixed: order.length > 1 });
        });
    }
    function songInfo(uri, cb) {
        const song = root._songForFile(uri);
        if (cb) cb(song ? { song: song, tags: { Title: song.title, Artist: song.artist, Album: song.album, Date: song.date, Genre: song.genre, Track: String(song.track) }, lastModified: "" } : null);
    }
    function searchSongs(q, cb) {
        const t = String(q || "").trim().toLowerCase();
        const out = [];
        if (t !== "")
            for (let i = 0; i < root.albums.length && out.length < 60; ++i) {
                const a = root.albums[i];
                const n = Math.min(10, a.songCount);
                for (let k = 0; k < n && out.length < 60; ++k) {
                    const so = root._makeSong(i, k);
                    if ((so.title + " " + so.artist + " " + so.album).toLowerCase().indexOf(t) >= 0) out.push(so);
                }
            }
        if (cb) cb(out);
    }
    function playNextSongs(songs) {
        const src = songs || [];
        if (src.length === 0) return;
        if (root.songPos < 0) { root._appendSongs(src); return; }
        const q = root.queue.slice();
        q.splice.apply(q, [root.songPos + 1, 0].concat(src));
        for (let i = 0; i < q.length; ++i) q[i].pos = i;
        root.queue = q;
    }
    function playNextAlbum(albumArtist, album) { root.songsOfAlbum(albumArtist, album, songs => root.playNextSongs(songs)); }
    function playArtist(name) {
        root.songsOfArtist(name, songs => {
            root.clearQueue();
            root._appendSongs(songs);
            root.playState = "play";
        });
    }
    function playNextArtist(name) { root.songsOfArtist(name, songs => root.playNextSongs(songs)); }
    function albumsOfArtist(name) {
        const out = [];
        for (let i = 0; i < root.albums.length; ++i) if (root.albums[i].albumArtist === name) out.push(root.albums[i]);
        return out;
    }
    function albumsOfGenre(name, cb) {
        const out = [];
        for (let i = 0; i < root.albums.length; ++i)
            if (root._genreOfAlbum(i) === name)
                out.push(root.albums[i]);
        if (cb)
            cb(out);
    }
    // A stable pretend genre per album, so the same album is always in the
    // same one: a mock that reshuffles its own library is unusable.
    function _genreOfAlbum(i) {
        return root.genres.length === 0 ? "" : root.genres[i % root.genres.length].name;
    }

    function appendGenre(name) {
        root.albumsOfGenre(name, albums => {
            for (let i = 0; i < albums.length; ++i)
                root.appendAlbum(albums[i].albumArtist, albums[i].album);
        });
    }
    function playGenre(name) {
        root.clearQueue();
        root.appendGenre(name);
        root.playState = "play";
    }
    function appendPlaylist(name) {
        root.songsOfPlaylist(name, songs => root._appendSongs(songs, name));
    }
    function playPlaylist(name) {
        root.songsOfPlaylist(name, songs => {
            if (!songs || songs.length === 0)
                return;
            root.queue = [];
            root._appendSongs(songs, name);
            root._seat(0);
            root.playState = "play";
        });
    }

    function songsOfGenre(name, cb) {
        const out = [];
        for (let i = 0; i < Math.min(4, root.albums.length); ++i)
            for (let t = 0; t < 2; ++t)
                out.push(root._makeSong(i, t));
        if (cb)
            cb(out);
    }
    // One loose file -> a song record of the same shape as an album song's.
    // Its cover is the picture inside it: nothing else can be.
    function _makeLooseSong(f) {
        const flac = /\.flac$/i.test(f.file);
        return {
            id: root._nextId++,
            pos: -1,
            file: f.file,
            title: f.title,
            artist: f.artist,
            albumArtist: f.artist,
            album: "",
            track: 0,
            disc: 1,
            date: "2024",
            genre: "Electronic",
            duration: 214,
            format: flac ? "44100:24:2" : "44100:f:2",
            coverUrl: root._coverOf(f.file, ""),
            lastModified: f.lastModified || 0
        };
    }

    // A list's songs, IN THE LIST'S OWN ORDER -- which is the order they are
    // queued in, because every queueing path goes through here.
    function songsOfPlaylist(name, cb) {
        // Favorites IS `~/Music/Tracks`, here as in the service: the real files
        // with their real mtimes, newest first, because that directory was
        // downloaded in the order it was favourited and the mtime is the only
        // thing that says what that order was.
        if (name === root.favoritesName) {
            const l = root._favouritesOrdered();
            const favs = [];
            for (let i = 0; i < l.length; ++i)
                favs.push(root._makeLooseSong(l[i]));
            if (cb)
                cb(favs);
            return;
        }
        for (let d = 0; d < root._playlistDirs.length; ++d) {
            if (root._playlistDirs[d].name !== name)
                continue;
            const rec = root._playlistDirs[d];
            const idx = root._listOrderOf(rec);
            const out = [];
            for (let j = 0; j < idx.length; ++j)
                out.push(root._makePlaylistSong(rec, idx[j]));
            if (cb)
                cb(out);
            return;
        }
        if (cb)
            cb([]);
    }
    function songsOfArtist(name, cb) {
        const out = [];
        for (let i = 0; i < root.albums.length; ++i)
            if (root.albums[i].albumArtist === name)
                for (let t = 0; t < 3; ++t)
                    out.push(root._makeSong(i, t));
        // An artist with no album of their own is only in the loose shelf, and
        // that is where their songs have to come from -- the same rule the
        // service follows when the wider scope is on.
        if (root.artistsIncludeLoose)
            for (let j = 0; j < root._looseFiles.length; ++j) {
                const f = root._looseFiles[j];
                if (f.artist !== name)
                    continue;
                out.push(root._makeLooseSong(f));
            }
        if (cb)
            cb(out);
    }
    function setShuffleMode(on) {
        root.shuffleMode = on;
        if (on)
            root.shuffleQueue();
    }

    // The biased shuffle with this mock's knobs on it, in ONE place: the fill
    // and the re-spread are the same mode and must not be able to disagree.
    function _shuffled(songs) {
        return Shuffle.shuffled(songs || [], {
            minArtistGap: root.shuffleArtistGap,
            minAlbumGap: root.shuffleAlbumGap,
            tries: root.shuffleTries
        });
    }

    // The queue re-spread. The song under the needle is PINNED to the front
    // rather than thrown into the draw, exactly as the service pins it:
    // shuffling it away from under the needle would restart playback, and
    // every player that has ever shipped shuffles what is COMING.
    function shuffleQueue() {
        const src = root.queue || [];
        if (src.length < 2)
            return;
        const head = [];
        const rest = [];
        for (let k = 0; k < src.length; ++k) {
            if (root.songId >= 0 && src[k].id === root.songId)
                head.push(src[k]);
            else
                rest.push(src[k]);
        }
        const q = head.concat(root._shuffled(rest));
        for (let i = 0; i < q.length; ++i)
            q[i].pos = i;
        root.queue = q;
        root.songPos = -1;
        for (let j = 0; j < q.length; ++j)
            if (q[j].id === root.songId)
                root.songPos = j;
    }
    function refresh() {}
}
