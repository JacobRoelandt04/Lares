pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// AudioTags.qml
//
// What is actually written INSIDE an audio file: every format-level tag, and
// the lyrics. One `ffprobe` per track, gated so nothing runs unless somebody
// is looking at the answer.
//
// WHY NOT MPD. MPD's `readcomments` does not carry the lyrics. Measured on
// `Tracks/Men I Trust - Show Me How.flac`, whose file holds both a timestamped
// `LYRICS` and an `UNSYNCEDLYRICS`: the daemon answers TITLE, ALBUM, DATE, BPM,
// ISRC, INITIALKEY, RELEASETYPE... and no lyrics of any kind. It keeps the tags
// it indexes, not the tags the file has.
// So the file is read directly, and `ffprobe -show_format` reads every format
// in this library the same way -- 2.7 KB of JSON in ~55 ms per track.
//
// THE LYRICS IN THIS LIBRARY ARE OFTEN TIMED. Measured over all 591 files:
// 169 carry a `LYRICS` tag whose every line begins `[mm:ss.xx]`, 11 carry only
// an `UNSYNCEDLYRICS` block, and 411 carry neither. So a followed, line-by-line
// reading is not a fantasy that would need a network service -- it is in the
// files already, on 29% of them -- and the panel above this file gets both
// shapes plus "there are none", never a faked sync.
//
// KEYS ARE FOLDED TO LOWER CASE, because the same tag is shouted by one format
// and whispered by another: FLAC/Vorbis writes `TITLE`, `LYRICS`, `BPM`, and
// m4a writes `title`, `initialkey`, `date`. A consumer that has to know which
// container it is holding has been handed the container's problem.
//
// ONE PROCESS AT A TIME, NEWEST WINS. A track change while a probe is running
// does not queue a second one: the result that lands is cached and the pump
// starts whatever is wanted THEN. Skipping through five tracks costs at most
// two probes, not five.
//
// THE CACHE IS PER PATH AND SMALL. Skipping back and forth over the last few
// songs -- which is what a queue view invites -- must not re-run a process
// each time. Nothing invalidates it but its own size: a tag edited on disk
// mid-session is not a case worth a file watcher per track.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // Nothing runs unless this is true. The panel binds it to "the Data tab is
    // the one on show": a process per track change for a panel nobody has open
    // is exactly what the gate is for.
    property bool active: false

    // The file to read, as an ABSOLUTE path. Empty asks nothing.
    property string path: ""

    // The reader, and how many results to keep.
    property string ffprobe: "ffprobe"
    property int cacheSize: 6
    property bool debug: false

    // Every format-level tag of `path`, keys folded to lower case. `{}` until
    // a result for the current path exists.
    readonly property var tags: root._result ? root._result.tags : root._noTags

    // { synced: bool, lines: [{t, text}], source: "<tag name>" }
    //
    //   synced   the line times are the file's own, not guessed
    //   t        seconds into the track, or -1 when the block is untimed
    //   text     the line, trimmed; "" is a real entry -- a gap the file put
    //            there, which is what an instrumental passage looks like
    //   lines    empty when the file has no lyrics at all
    readonly property var lyrics: root._result ? root._result.lyrics : root._noLyrics

    // A result -- even an empty one -- exists for the current path.
    readonly property bool ready: root._result !== null
    readonly property bool loading: root._running.length > 0
    // Non-empty when the read itself failed (no ffprobe, no file, no JSON).
    // A file with no tags is not an error: it is an empty result.
    readonly property string error: root._result ? root._result.error : ""

    // ======================================================================
    // INTERNALS
    // ======================================================================
    readonly property var _noTags: ({})
    readonly property var _noLyrics: ({ synced: false, lines: [], source: "" })

    property var _cache: ({})       // path -> { tags, lyrics, error }
    property var _order: []         // paths, oldest first
    property string _running: ""    // the path being probed right now

    // The binding that makes the whole file declarative: the answer for the
    // current path if it is known, null if it is not. `_cache` is REPLACED on
    // every insert rather than mutated, so this re-evaluates.
    readonly property var _result:
        root.path.length > 0 && root._cache[root.path] !== undefined
            ? root._cache[root.path] : null

    onPathChanged: root._pump()
    onActiveChanged: root._pump()
    Component.onCompleted: root._pump()

    function _log(m) {
        if (root.debug)
            console.log("AudioTags: " + m);
    }

    function _pump() {
        if (!root.active || root._running.length > 0)
            return;
        const p = root.path;
        if (p.length === 0 || root._cache[p] !== undefined)
            return;
        root._running = p;
        // argv, not a shell line: a path here holds spaces, apostrophes and
        // brackets, and every one of them is somebody's album title.
        _proc.command = [root.ffprobe, "-v", "quiet", "-print_format", "json",
                         "-show_format", p];
        _proc.running = true;
        root._log("probing " + p);
    }

    function _put(path, result) {
        const c = ({});
        const keys = Object.keys(root._cache);
        for (let i = 0; i < keys.length; i++)
            c[keys[i]] = root._cache[keys[i]];
        c[path] = result;
        const order = root._order.slice();
        const at = order.indexOf(path);
        if (at >= 0)
            order.splice(at, 1);
        order.push(path);
        while (order.length > Math.max(1, root.cacheSize))
            delete c[order.shift()];
        root._cache = c;
        root._order = order;
    }

    function _onExited(code, text) {
        const path = root._running;
        root._running = "";
        if (path.length === 0)
            return;
        root._put(path, root.parse(code, text));
        // The track may have moved on while this ran; whatever is wanted NOW
        // is what starts next.
        root._pump();
    }

    // ---- Parsing (public so a headless probe can feed it a fixture) --------

    // ffprobe's exit code and stdout -> the result object. A non-zero exit is
    // the reader's own complaint (no such file, no ffprobe at all); malformed
    // JSON is the same class of thing and is reported the same way.
    function parse(code, text) {
        const out = { tags: ({}), lyrics: root._noLyrics, error: "" };
        if (code !== 0) {
            out.error = "ffprobe exited " + code;
            return out;
        }
        let doc = null;
        try {
            doc = JSON.parse(String(text || ""));
        } catch (e) {
            out.error = "unreadable ffprobe output";
            return out;
        }
        const fmt = doc && doc.format ? doc.format : null;
        const raw = fmt && fmt.tags ? fmt.tags : ({});
        const keys = Object.keys(raw);
        for (let i = 0; i < keys.length; i++) {
            const k = String(keys[i]).toLowerCase();
            const v = String(raw[keys[i]]);
            // First spelling wins: a file carrying both `BPM` and `bpm` is
            // one tag with one value, and the one written first is the one
            // the container itself would answer with.
            if (out.tags[k] === undefined)
                out.tags[k] = v;
        }
        // The container's own numbers, under names no tag uses, so a caller
        // can show the file itself without a second reader.
        if (fmt) {
            out.tags["_format"] = String(fmt.format_name || "");
            out.tags["_duration"] = String(fmt.duration || "");
            out.tags["_bitrate"] = String(fmt.bit_rate || "");
            out.tags["_filename"] = String(fmt.filename || "");
        }
        out.lyrics = root.parseLyrics(out.tags);
        return out;
    }

    // Which tag holds the lyrics, and in which of the two shapes.
    //
    // A TIMED BLOCK BEATS AN UNTIMED ONE. The 169 files here that have both
    // carry the same words twice; showing the copy that cannot be followed
    // when the followable one is right beside it would be throwing the whole
    // point away.
    function parseLyrics(tags) {
        const keys = Object.keys(tags);
        let synced = null;
        let plain = null;
        for (let i = 0; i < keys.length; i++) {
            const k = keys[i];
            if (k.indexOf("lyric") < 0)
                continue;
            const v = String(tags[k] || "");
            if (v.trim().length === 0)
                continue;
            const lines = root.parseLrc(v);
            if (lines.timed && synced === null)
                synced = { synced: true, lines: lines.lines, source: k };
            else if (!lines.timed && plain === null)
                plain = { synced: false, lines: lines.lines, source: k };
        }
        if (synced)
            return synced;
        if (plain)
            return plain;
        return root._noLyrics;
    }

    // One lyrics blob -> { timed, lines }.
    //
    // LRC: every line may carry one or more `[mm:ss.xx]` stamps before its
    // text, and a stamped line with no text is a GAP the file put there --
    // kept, because it is the only thing that says an instrumental passage is
    // running rather than that the timing has stopped. `[ar:...]`-style LRC
    // metadata is dropped: it is about the file, not about the song.
    function parseLrc(blob) {
        const src = String(blob).replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n");
        const out = [];
        let timed = false;
        for (let i = 0; i < src.length; i++) {
            let rest = src[i];
            const stamps = [];
            for (;;) {
                const m = rest.match(/^\s*\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/);
                if (!m)
                    break;
                stamps.push(parseInt(m[1], 10) * 60 + parseFloat(m[2].replace(":", ".")));
                rest = rest.substring(m[0].length);
            }
            const text = rest.replace(/\s+$/, "").replace(/^\s+/, "");
            if (stamps.length === 0) {
                // An unstamped `[xx:yyy]` line in a stamped file is metadata.
                if (/^\s*\[[a-zA-Z#]+:[^\]]*\]\s*$/.test(rest))
                    continue;
                out.push({ t: -1, text: text });
                continue;
            }
            timed = true;
            for (let s = 0; s < stamps.length; s++)
                out.push({ t: stamps[s], text: text });
        }
        if (timed) {
            // A file may hold one untimed trailer line (a credit); it sorts
            // to the front on t = -1, which would make it the first thing
            // "sung". Timed lines only, in time order.
            const only = [];
            for (let j = 0; j < out.length; j++)
                if (out[j].t >= 0)
                    only.push(out[j]);
            only.sort((a, b) => a.t - b.t);
            return { timed: true, lines: only };
        }
        // An untimed block keeps its own order, and its leading and trailing
        // blank lines are dropped -- they are the tag's padding, not a gap.
        while (out.length > 0 && out[0].text.length === 0)
            out.shift();
        while (out.length > 0 && out[out.length - 1].text.length === 0)
            out.pop();
        return { timed: false, lines: out };
    }

    // ---- The one child ----------------------------------------------------
    Process {
        id: _proc
        running: false
        stdout: StdioCollector {
            id: _out
        }
    }
    Connections {
        target: _proc
        function onExited(code) {
            root._onExited(code, _out.text);
        }
    }
}
