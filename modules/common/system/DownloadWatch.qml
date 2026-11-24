pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

import "../components"
import "DownloadRules.js" as Rules

// =============================================================================
// DownloadWatch.qml -- is a file being downloaded into the download folder right now? ONE per shell (ShellServices), read by the
// idle auto layer (IdleAuto: a download asks for soft, so the machine does not suspend under it).
//
// WHAT IT SEES. The folder `xdg-user-dir DOWNLOAD` names (top level only), and in it a partial file a downloader leaves while it
// works that still grows: `*.part` (Firefox, Zen, yt-dlp), `*.crdownload` (Chromium), `*.download`, aria2's `*.aria2` (and the data
// file beside it, written in place), yt-dlp's `*.ytdl` (DownloadRules.js has the table). "Still grows" is a create or a write event
// within `stallMs`: a download that stalls, or is paused with its partial file standing, stops counting after that, and a finished
// or cancelled one at once (the partial file is renamed or deleted). A download that resumes starts again (next paragraph).
//
// ONLY A LONG ONE COUNTS (`minAgeMs`, 2 minutes). A partial file counts once it has grown CONTINUOUSLY that long: its age runs from the
// first write seen, and a stall of `stallMs` or more resets it (a resumed download earns its two minutes again). The user's reason:
// a small download ends before a suspend could hurt it, so it never needs to hold the machine awake.
//
// WHAT IT DOES NOT SEE. A `curl -o` or `wget` to a path outside the folder, a download saved into a subfolder or another folder
// (the browser asks where), a torrent client's own folder, a Flatpak browser whose download folder is another path, and a browser
// that downloads to a hidden temp name (Chromium's own `.com.google.Chrome.*` scratch while it has no `.crdownload` yet).
//
// COST. One `inotifywait -m` on that one folder (the launcher's pattern), parsed per event in JS: no polling, no stat of sizes. The
// kernel merges the writes of a busy download, and the expiry is ONE single-shot timer armed for the earliest due instant (a stall, or
// a young download coming of age). Not watching
// (a mock shell, a probe's default): no process runs.
//
//   watch     watch at all (the host binds the shell being live)
//   dir       the folder; "" asks `xdg-user-dir DOWNLOAD` once (a probe names a private one)
//   active    some download shows life now;  names  who (oldest first);  firstName  the oldest one's name (the words)
// =============================================================================
Item {
    id: root

    property bool watch: false
    property string dir: ""
    property int stallMs: 10000
    // How long a partial file must have grown without a stall before it counts (see the header).
    property int minAgeMs: 120000
    // a new wait (idle.jsonc, read hot) is judged at once, not at the next event
    onMinAgeMsChanged: root._eval()
    // In front of inotifywait: the child dies with the shell however it dies (a probe may pass none).
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]

    readonly property bool active: root._names.length > 0
    readonly property var names: root._names
    readonly property string firstName: root._names.length > 0 ? root._names[0] : ""
    // The folder in force ("" while none is: not asked yet, or it does not exist).
    readonly property string watching: root._dir

    property var _names: []
    property string _dir: ""
    property var _state: Rules.newState()
    // The clock (a probe may pin it: a function returning ms).
    property var clock: null
    function _now(): double {
        return root.clock ? root.clock() : Date.now();
    }

    function _eval(): void {
        const now = root._now();
        Rules.prune(root._state, now, root.stallMs);
        const list = Rules.growing(root._state, now, root.stallMs, root.minAgeMs);
        if (JSON.stringify(list) !== JSON.stringify(root._names))
            root._names = list;
        const left = Rules.untilChange(root._state, now, root.stallMs, root.minAgeMs);
        if (left > 0) {
            expiry.interval = Math.max(50, Math.ceil(left) + 5);
            expiry.restart();
        } else {
            expiry.stop();
        }
    }
    Timer {
        id: expiry
        onTriggered: root._eval()
    }

    // The folder: the one `dir` names, or the user's download folder when it exists and is not the home itself (xdg-user-dir answers
    // $HOME for a folder nobody set).
    function _resolve(): void {
        if (!root.watch) {
            root._dir = "";
            return;
        }
        if (root.dir !== "") {
            root._dir = root.dir;
            return;
        }
        if (!ask.running) {
            ask.running = true;
        }
    }
    onWatchChanged: root._resolve()
    onDirChanged: root._resolve()
    Component.onCompleted: root._resolve()
    Process {
        id: ask
        command: ["sh", "-c", 'd=$(xdg-user-dir DOWNLOAD 2> /dev/null); [ -n "$d" ] && [ "$d" != "$HOME" ] && [ -d "$d" ] && printf "%s\\n" "$d"; exit 0']
        stdout: SplitParser {
            onRead: data => {
                if (String(data) !== "")
                    root._dir = String(data);
            }
        }
    }

    // The stream: events of the folder, one per line.
    SupervisedStream {
        id: stream
        enabled: root.watch && root._dir !== ""
        what: "DownloadWatch: the download folder's watcher"
        command: root._dir === "" ? [] : root.launcher.concat(["inotifywait", "-m", "-q", "-e", "create,modify,moved_to,moved_from,delete",
            "--format", "%e %f", "--", root._dir])
        onLine: text => {
            if (text === "")
                return;
            const changed = Rules.apply(root._state, text, root._now(), root.stallMs);
            if (changed || !root.active)
                root._eval();
        }
    }

    // What stands there already: only the control files (aria2's), whose data file's writes then count.
    Process {
        id: scan
        stdout: SplitParser {
            onRead: data => {
                if (String(data) !== "")
                    Rules.apply(root._state, "CREATE " + String(data), 0, root.stallMs);
            }
        }
        // (marked with time 0: stale at once, so it counts nothing until the data file or the control file is written)
    }
    onWatchingChanged: {
        root._state = Rules.newState();
        root._eval();
        if (root._dir !== "") {
            scan.command = ["find", root._dir, "-maxdepth", "1", "-type", "f", "-name", "*.aria2", "-printf", "%f\\n"];
            scan.running = true;
        }
    }
}
