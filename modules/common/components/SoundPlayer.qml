pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// SoundPlayer.qml -- play a sound file through PipeWire, one voice per KEY.
//
//   play(key, file, { loop, maxMs, volume })
//        loop    start again each time it ends, until stop() or maxMs has passed
//        volume  0..1, for this play only (pw-play --volume). Absent: the
//                stream's own level, and the command carries no --volume.
//                Anything that is not a positive number (0, NaN, a
//                negative) plays NOTHING -- no process at all -- and leaves
//                a voice that is sounding alone.
//   stop(key)
//   playing(key)
//
// pw-play, because it is already there (the level taps use pw-cat) and it
// needs no QtMultimedia. The pool is one voice per name in `keys`, fixed
// once the player is made; a key nobody named uses the spare, the LAST one.
// A host with sounds of its own names its own: `keys: ["latch", "dip", "plug"]`.
// =============================================================================
Item {
    id: root

    property string pwPlay: "pw-play"
    // The voices, by name; the last is the spare. Set it where the player is declared, not later
    // (a different length rebuilds the pool).
    property var keys: ["countdown", "pomodoro", "alarm", "spare"]
    readonly property string soundDir: "/usr/share/sounds/freedesktop/stereo/"

    function _voice(key) {
        const i = root.keys.indexOf(key);
        return voices.itemAt(i >= 0 ? i : root.keys.length - 1);
    }

    // `--volume=0.2`, or nothing when the play names no volume; null when it names one that is silence
    function _volumeFlags(opts) {
        if (opts.volume === undefined || opts.volume === null)
            return [];
        const v = Math.round(Math.min(1, Number(opts.volume)) * 1000) / 1000;
        return v > 0 ? ["--volume=" + v] : null;
    }

    function play(key, file, opts) {
        const o = opts || {};
        const flags = root._volumeFlags(o);
        if (flags === null)
            return;
        const v = root._voice(key);
        if (v)
            v.start(file.indexOf("/") === 0 ? file : root.soundDir + file, o, flags);
    }

    function stop(key) {
        const v = root._voice(key);
        if (v)
            v.halt();
    }

    function playing(key) {
        const v = root._voice(key);
        return !!v && v.active;
    }

    Repeater {
        id: voices
        model: root.keys.length
        delegate: Item {
            id: voice
            required property int index
            property bool active: false
            property bool loop: false
            property real until: 0
            property string file: ""
            property var flags: []
            property bool _restart: false

            function start(file, opts, flags) {
                voice.file = file;
                voice.flags = flags;
                voice.loop = !!opts.loop;
                voice.until = Date.now() + (opts.maxMs || 60000);
                voice.active = true;
                if (proc.running) {
                    voice._restart = true;
                    proc.signal(15);
                } else {
                    voice._once();
                }
            }
            function halt() {
                voice.active = false;
                voice._restart = false;
                gap.stop();
                if (proc.running)
                    proc.signal(15);
            }
            function _once() {
                proc.command = [root.pwPlay].concat(voice.flags, [voice.file]);
                proc.running = true;
            }

            Process {
                id: proc
                running: false
            }
            Connections {
                target: proc
                function onExited() {
                    if (voice._restart) {
                        // play() while it played: the new sound, from its start.
                        voice._restart = false;
                        voice._once();
                    } else if (voice.active && voice.loop && Date.now() < voice.until) {
                        gap.restart();
                    } else {
                        voice.active = false;
                    }
                }
            }
            // A breath between repeats, so a looping bell is a bell, not a drone.
            Timer {
                id: gap
                interval: 600
                onTriggered: {
                    if (voice.active)
                        voice._once();
                }
            }
        }
    }
}
