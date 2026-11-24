pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"

// =============================================================================
// NotificationSound.qml -- the one sound a notification may make.
//
//   play(rec, want)   want = { suppress, file, name, rule, spec }
//     suppress  the sender's `suppress-sound` hint: silent, whatever else
//     rule      an app/source rule's `sound`: "none", or a path that comes before everything below
//     spec      a shell post's `sound`: "none" (its default) = silent but for a rule's path,
//               "default" = the urgency's sound, else a path
//     file      the `sound-file` hint (a path)
//     name      the `sound-name` hint (a freedesktop sound-theme name:
//               <soundDir>/<name>.oga / .ogg / .wav)
//   then the config's `sounds.<urgency>` list. Every path may start with `~/`. How loud: the config's
//   `soundVolume` (0 .. 1; -1 the stream's own level).
//
// THE FIRST FILE THAT EXISTS WINS, and none existing is silence: the user's
// sound files are theirs to add, and mako's own sound file never existed.
// Existence is asked of the filesystem once per sound (one `find` over the
// candidates, which prints only the files that exist, in order) -- never
// cached, so a file added while the shell runs is heard the next time.
//
// Silent under DND, always (`dnd`), whatever broke through it.
// =============================================================================
Item {
    id: root

    property var config: null
    property bool dnd: false
    property string soundDir: "/usr/share/sounds/freedesktop/stereo/"
    property string pwPlay: "pw-play"

    // What was last started ("" none) and why nothing played, for probes.
    readonly property string lastPlayed: root._lastPlayed
    readonly property string lastSkipped: root._lastSkipped

    function expand(p) {
        const s = String(p || "");
        if (s === "~" || s.indexOf("~/") === 0)
            return Quickshell.env("HOME") + s.substring(1);
        return s;
    }

    // The candidates, best first; [] = silent. The user's rule beats the
    // sender's hints and a post that asks for none; a rule of "none" silences everything.
    function candidates(rec, want) {
        const w = want || {};
        if (w.suppress || w.rule === "none")
            return [];
        const out = [];
        if (w.rule)
            out.push(root.expand(w.rule));
        if (w.spec === "none")
            return out;
        if (w.spec && w.spec !== "default")
            out.push(root.expand(w.spec));
        if (w.file)
            out.push(root.expand(w.file));
        if (w.name) {
            const base = root.soundDir + String(w.name);
            out.push(base + ".oga", base + ".ogg", base + ".wav");
        }
        const urg = rec && rec.urgency ? rec.urgency : "normal";
        const list = root.config && root.config.sounds && Array.isArray(root.config.sounds[urg])
            ? root.config.sounds[urg] : [];
        for (let i = 0; i < list.length; i++)
            out.push(root.expand(list[i]));
        return out.filter(p => p.length > 0 && p.charAt(0) === "/");
    }

    function play(rec, want) {
        if (root.dnd) {
            root._lastSkipped = "dnd";
            return;
        }
        const c = root.candidates(rec, want);
        if (c.length === 0) {
            root._lastSkipped = "silent";
            return;
        }
        if (probe.running) {
            root._queued = c;
            return;
        }
        root._probe(c);
    }

    // ---- Private -------------------------------------------------------------
    property string _lastPlayed: ""
    property string _lastSkipped: ""
    property var _queued: null

    function _probe(c) {
        // find prints the paths that are regular files, in the order given,
        // and complains (on stderr, unread) about the rest.
        probe.command = ["find", "-L"].concat(c).concat(["-maxdepth", "0", "-type", "f", "-print"]);
        probe.running = true;
    }

    SoundPlayer {
        id: player
        pwPlay: root.pwPlay
    }

    Process {
        id: probe
        running: false
        stdout: StdioCollector {
            id: probeOut
        }
    }
    Connections {
        target: probe
        function onExited() {
            const first = String(probeOut.text || "").split("\n")[0].trim();
            if (first.length > 0) {
                root._lastPlayed = first;
                const vol = root.config ? root.config.soundVolume : -1;
                player.play("spare", first, vol >= 0 && vol <= 1 ? { volume: vol } : {});
            } else {
                root._lastSkipped = "missing";
            }
            if (root._queued) {
                const q = root._queued;
                root._queued = null;
                root._probe(q);
            }
        }
    }
}
