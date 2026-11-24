pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "SiliconSparks.js" as Sp

// =============================================================================
// SiliconBarSparks.qml -- the charge burst of the bar button: a handful of tiny round dots leaving the
// pill's outline, slow, with a high drag, never stretched, that shimmer as they die (the maths, and the
// words of the brief, are in SiliconSparks.js).
//
// NOTHING RUNS AT REST. The clock is a FrameAnimation that runs only while a burst is alive (and not
// while a theme crossfade holds its still picture), so between bursts the item asks for no frame and
// costs nothing; a burst is a second and a half once per plug-in. The dots are plain Rectangles --
// no layer, no canvas -- on whole-device-pixel-free positions the way a drifting thing wants them.
//
// A host draws it over the pill, in the pill's own (screen) frame, with the pill's size as this item's:
//
//     SiliconBarSparks { width: face.width; height: face.height; color: Theme.batteryCharge }
//     sparks.burst()          one burst (`seed`, a number, makes it a still: the harness's)
//
// `live` false (a harness) stops the clock: the host writes `age` itself.
// =============================================================================
Item {
    id: sparks

    property color color: Theme.batteryCharge
    // The look; the defaults are SiliconSparks.DEFAULTS and a host overrides one by name.
    property var look: ({})

    // ---- time ----
    property bool live: true               // false: a harness holds the clock and writes `age`
    property real age: 0                   // ms since the burst began
    property bool _alive: false
    property var _parts: []
    readonly property real _endMs: Sp.endOf(sparks._parts)
    readonly property bool active: sparks._alive
    signal finished()

    // what a probe reads: the particles (their phase and frequency), their count, the dots, and whether the clock runs
    readonly property var particles: sparks._parts
    readonly property int count: sparks._parts.length
    readonly property bool clockRunning: clock.running
    readonly property var dots: {
        const n = rep.count, out = [];
        for (let i = 0; i < n; i++)
            out.push(rep.itemAt(i));
        return out;
    }

    function burst(seed) {
        const rnd = seed === undefined || seed === null ? Math.random : Sp.seeded(seed);
        sparks._parts = Sp.spawn(sparks.width, sparks.height, sparks.look, rnd);
        sparks.age = 0;
        sparks._alive = true;
    }

    // The particles' states at `age`: one array, rebuilt once a tick (an array of the same length, so
    // the Repeater keeps its delegates and only their bindings run).
    readonly property var _states: {
        const a = sparks.age;
        return sparks._parts.map(q => Sp.stateAt(q, a, sparks.look));
    }

    // The burst is over when its clock passes its longest life. (Decided here, from the age, and not in a handler of `active`:
    // a handler that writes what its own property reads is a binding loop.)
    onAgeChanged: {
        if (sparks._alive && sparks.age >= sparks._endMs) {
            sparks._alive = false;
            sparks.finished();
        }
    }

    // The one clock. A theme crossfade is a still picture faded out: whatever keeps moving under it is a
    // second copy of itself for the length of the fade, so the burst holds still through it.
    FrameAnimation {
        id: clock
        running: sparks.live && sparks.active && !Theme.crossfading
        onTriggered: sparks.age += clock.frameTime * 1000
    }

    Repeater {
        id: rep
        model: sparks._parts.length
        Rectangle {
            id: dot
            required property int index
            readonly property var s: sparks._states[dot.index]
            visible: !!dot.s && dot.s.alpha > 0.004
            x: dot.s ? dot.s.x - dot.s.size / 2 : 0
            y: dot.s ? dot.s.y - dot.s.size / 2 : 0
            width: dot.s ? dot.s.size : 0
            height: width
            radius: width / 2
            antialiasing: true
            color: sparks.color
            opacity: dot.s ? dot.s.alpha : 0
        }
    }
}
