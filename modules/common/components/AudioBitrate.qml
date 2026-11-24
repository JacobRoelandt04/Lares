pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// AudioBitrate.qml
//
// A FILE'S AVERAGE BITRATE: the bytes of its audio stream, times eight, over its
// duration -- the one steady number a file has. MPD's own `bitrate:` is what the
// decoder is reading at THIS moment, so it moves through the song (5xx at one
// second, 1005 at the next, on a FLAC) and never agrees with a player that shows
// the file's figure (Auxio on the phone shows a lower value).
//
// WHY THE STREAM'S BYTES AND NOT THE FILE'S SIZE. The figure wanted is the
// file's size minus its tags and headers, over the duration. A FLAC here carries
// an 80 KB cover and a Vorbis comment block, an mp3 an ID3 tag and a picture; the
// size of the AUDIO PACKETS is that figure exactly, without guessing how big the
// tags are. `ffprobe -show_entries packet=size` lists them (one line each, the
// sum is the payload); the `bit_rate` of a FLAC stream is "N/A" and the
// container's `format.bit_rate` counts the picture, which is why neither is used.
//
// ONE PROCESS AT A TIME, THE NEWEST WANTED WINS, a small cache by path: the same
// idiom as AudioTags, and nothing runs unless `active` (a viewer is looking at
// the figure). A stream or a file ffprobe cannot read ends `failed`, and the
// host falls back to the live reading rather than to a blank.
// =============================================================================
Item {
    id: root

    // Nothing runs unless this is true.
    property bool active: false
    // ABSOLUTE path of the file; empty asks nothing. A url (a radio stream) has
    // no average and is `failed` at once.
    property string path: ""
    // The song's length in seconds, from the daemon (the file is not asked).
    property real duration: 0
    property string ffprobe: "ffprobe"
    property int cacheSize: 24
    property bool debug: false

    // kbps, 0 until the answer for the current path is in (or when it failed).
    readonly property int kbps: root._result && root._result.kbps > 0 ? root._result.kbps : 0
    // The read finished and has no figure to give: the caller falls back.
    readonly property bool failed: root._result !== null && root._result.kbps <= 0
    // Wanted and not here yet.
    readonly property bool pending: root.active && root.path.length > 0 && root._result === null

    property var _cache: ({})          // "path\0duration" -> { kbps }
    property var _order: []
    property string _running: ""       // the key being read

    function _keyOf(p, d) { return p + "\u0000" + Math.round(d * 1000); }
    readonly property string _key: root.path.length > 0 && root.duration > 0
                                   ? root._keyOf(root.path, root.duration) : ""
    readonly property var _result: {
        if (root.path.length === 0)
            return null;
        if (/^[a-z][a-z0-9+.-]*:\/\//i.test(root.path))
            return ({ kbps: 0 });
        if (root._key === "")
            return null;
        return root._cache[root._key] !== undefined ? root._cache[root._key] : null;
    }

    on_KeyChanged: root._pump()
    onActiveChanged: root._pump()
    Component.onCompleted: root._pump()

    function _pump() {
        if (!root.active || root._running.length > 0)
            return;
        const k = root._key;
        if (k === "" || root._cache[k] !== undefined || /^[a-z][a-z0-9+.-]*:\/\//i.test(root.path))
            return;
        root._running = k;
        root._wantPath = root.path;
        root._wantDuration = root.duration;
        // argv, not a shell line: every album title is a path with spaces.
        _proc.command = [root.ffprobe, "-v", "error", "-select_streams", "a:0",
                         "-show_entries", "packet=size", "-of", "csv=p=0", root.path];
        _proc.running = true;
        _deadline.restart();
        if (root.debug)
            console.log("AudioBitrate: reading " + root.path);
    }
    property string _wantPath: ""
    property real _wantDuration: 0

    // ffprobe's exit code and the packet sizes -> kbps (0: no figure).
    // Public so a headless probe can feed it a fixture.
    function parse(code, text, duration) {
        if (code !== 0 || !(duration > 0))
            return 0;
        const lines = String(text || "").split("\n");
        let bytes = 0;
        for (let i = 0; i < lines.length; i++) {
            const n = parseInt(lines[i], 10);
            if (isFinite(n) && n > 0)
                bytes += n;
        }
        if (bytes <= 0)
            return 0;
        return Math.round(bytes * 8 / duration / 1000);
    }

    function _put(key, result) {
        const c = ({});
        const keys = Object.keys(root._cache);
        for (let i = 0; i < keys.length; i++)
            c[keys[i]] = root._cache[keys[i]];
        c[key] = result;
        const order = root._order.slice();
        const at = order.indexOf(key);
        if (at >= 0)
            order.splice(at, 1);
        order.push(key);
        while (order.length > Math.max(1, root.cacheSize))
            delete c[order.shift()];
        root._cache = c;
        root._order = order;
    }

    function _onExited(code, text) {
        const key = root._running;
        root._running = "";
        _deadline.stop();
        if (key.length === 0)
            return;
        root._put(key, { kbps: root.parse(code, text, root._wantDuration) });
        root._pump();
    }

    // A Process whose program does not exist emits neither `started` nor `exited`
    // (CLAUDE.md), and a read of a file on a stalled mount never ends: the figure is
    // given up after `deadlineMs` and the host falls back to the live reading.
    property int deadlineMs: 8000
    Timer {
        id: _deadline
        interval: root.deadlineMs
        repeat: false
        onTriggered: {
            _proc.running = false;
            root._onExited(124, "");
        }
    }
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
