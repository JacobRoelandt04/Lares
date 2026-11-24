pragma ComponentBehavior: Bound

import QtQuick
import "../../common/components"
import "../../common/system"

// =============================================================================
// SiliconSounds.qml -- the popup's three tactile sounds (CONTRACT section 11).
//
// The director emits the moments (`cardLatched`, `leverFlipped`, `plugMoved`) from the motions
// themselves, as the part reaches that point, so a sound is never ahead of what is drawn. This plays
// the synthesised click of the part for each (assets/sounds/silicon/, tools/silicon/make_clicks.py)
// through SoundPlayer, at the volume `latchVolume` / `dipVolume` / `plugVolume` gives:
//
//   moment                 file (v = that sound's own take)   volume        take
//   cardLatched(seated)    latch_<v>.wav (both ways)          latchVolume   latchTake
//   leverFlipped(limitOn)  dip_<v>.wav   (both ways)          dipVolume     dipTake
//   plugMoved(plugged)     plug_<v>.wav / plug_out_<v>.wav    plugVolume    plugTake / plugOutTake
//
// A latch and a switch click whichever way they go; a plug does not (a scrape that ENDS in a click is
// a plug going IN), so only the plug has a file of its own for the way out, and a take of its own.
//
// THE VARIANTS. Each sound has three takes, a / b / c (a tick, a soft click, a snap: see
// make_clicks.py), and the four takes say which one each of the FOUR files plays. The volumes and the takes are
// the module's constants, tuned on the silicon mockup's Sounds tab (the picks: 0.2 each, a click being loud
// next to a notification; latch a, dip a, plug c, plug_out a). A take that is none of a, b, c plays a.
//
//   - 0 is silent: no process at all, and a silent moment does not arm the debounce below.
//   - Only while `active` (the popup shown). A sound already sounding when the popup closes finishes
//     (a click is under 62 ms); nothing new starts.
//   - Never in a harness. Every quickshell the tests start is on the offscreen platform and none of them
//     may ever make a sound, yet a probe that loads the popup loads this with it and drives the director.
//     So on the offscreen platform the default player is silent; a probe that wants the real path points
//     `pwPlay` at its stub (an offscreen run on the user's desktop would otherwise reach their speakers).
//   - A moment repeated within `debounceMs` (80 ms) of the last one that PLAYED plays once, per sound:
//     a lever dragged across its middle and back, a plug that bounces. The first one is heard (a sound
//     delayed to see whether another follows would be late), the latch and the plug do not silence
//     each other.
//   - The volume is read when the sound is made, so a change applies to the next one.
//
//   audition(name, on, variant)   the sound of a part ("latch", "dip", "plug"; `on` = seated / limit on /
//                        plugged) NOW, at its configured volume, whether or not the popup is shown and
//                        without the debounce: for a mockup's own "play", the user's run. `variant` ("a" |
//                        "b" | "c") plays that take instead of the chosen one, to compare them. (Still
//                        silent at volume 0 and in a harness.)
// =============================================================================
Item {
    id: root

    property var vm: null                 // a SiliconService or a SiliconMock
    property var director: null           // MotionDirector: its moment signals
    property bool active: false           // the popup is shown: sounds play only then
    // THE VOLUMES, 0 .. 1 (0 is silent: no process at all), and THE TAKES, "a" | "b" | "c", of the four files (<key>_<take>.wav)
    property real latchVolume: 0.2
    property real dipVolume: 0.2
    property real plugVolume: 0.2
    property string latchTake: "a"
    property string dipTake: "a"
    property string plugTake: "c"
    property string plugOutTake: "a"
    // the take each file plays, by the key of `_bases`
    readonly property var variants: ({ latch: root.latchTake, dip: root.dipTake, plug: root.plugTake, plug_out: root.plugOutTake })
    readonly property var variantNames: ["a", "b", "c"]

    // A probe points `pwPlay` at a stub that logs; `soundDir` ends in a slash.
    property string pwPlay: "pw-play"
    property string soundDir: RepoRoot.dir + "/assets/sounds/silicon/"
    property int debounceMs: 80
    readonly property bool _harness: Qt.platform.pluginName === "offscreen" && root.pwPlay === "pw-play"

    visible: false

    // sound -> [file base when the moment is true, file base when it is false]; a base is also its take's key
    readonly property var _bases: ({
            latch: ["latch", "latch"],
            dip: ["dip", "dip"],
            plug: ["plug", "plug_out"]
        })
    // when each sound last PLAYED (ms, wall clock); held here and mutated in place -- never read by a binding
    property var _last: ({})

    function _volume(name) {
        const v = root[name + "Volume"];
        return typeof v === "number" && isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
    }

    // the take a file plays: the one asked for (an audition's), else the chosen one; anything that is not a variant is the first
    function _variant(base, asked) {
        const v = asked !== undefined ? asked : (root.variants ? root.variants[base] : undefined);
        return root.variantNames.indexOf(v) >= 0 ? v : root.variantNames[0];
    }

    function _start(name, on, volume, variant) {
        const base = root._bases[name][on ? 0 : 1];
        player.play(name, root.soundDir + base + "_" + root._variant(base, variant) + ".wav", { volume: volume });
    }

    function _moment(name, on) {
        if (!root.active || root._harness)
            return;
        const volume = root._volume(name);
        if (!(volume > 0))
            return;
        const now = Date.now();
        const gap = now - (root._last[name] === undefined ? -Infinity : root._last[name]);
        // (a clock that stepped back is not "within 80 ms")
        if (gap >= 0 && gap < root.debounceMs)
            return;
        root._last[name] = now;
        root._start(name, on, volume);
    }

    function audition(name, on, variant) {
        const volume = root._volume(name);
        if (!root._harness && volume > 0 && root._bases[name] !== undefined)
            root._start(name, on, volume, variant);
    }

    SoundPlayer {
        id: player
        pwPlay: root.pwPlay
        keys: ["latch", "dip", "plug"]
    }

    Connections {
        target: root.director
        ignoreUnknownSignals: true
        function onCardLatched(seated) {
            root._moment("latch", seated);
        }
        function onLeverFlipped(limitOn) {
            root._moment("dip", limitOn);
        }
        function onPlugMoved(plugged) {
            root._moment("plug", plugged);
        }
    }
}
