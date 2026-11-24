pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// MorphClock.qml -- the one clock of a level morph (LevelMorph.js).
//
//   mt           linear, 0..1; the host sets it (0 at a morph's start, a
//                harness pins it) and reads it (which end it landed on)
//   me           mt eased OutCubic: what everything drawn follows
//   runTo(t)     run from wherever mt is to t, at the morph's own speed: the
//                duration is morphMs times the distance, so a reversal half
//                way home takes half the time
//   scrubTo(p)   p = the fingers' share of a swipe, 0..1. The clock CHASES
//                the value whose ease is p (so the drawn fraction `me` is
//                under the fingers), but never faster than the morph runs by
//                itself: a scrub that follows the fingers 1:1 finishes a
//                flick in a frame. runTo() afterwards goes on
//                from wherever the chase had got to.
//   stop()       both halt where they are
//   landed()     runTo() arrived (a scrub's chase never lands: the lift
//                decides with runTo)
// =============================================================================
QtObject {
    id: clock

    property int morphMs: 320
    property real mt: 0
    readonly property real me: 1 - Math.pow(1 - clock.mt, 3)

    signal landed

    function runTo(t) {
        clock._scrub.stop();
        clock._run.stop();
        clock._run.from = clock.mt;
        clock._run.to = t;
        clock._run.duration = Math.max(1, Math.round(clock.morphMs * Math.abs(t - clock.mt)));
        clock._run.start();
    }

    function scrubTo(p) {
        const t = 1 - Math.cbrt(1 - p);
        clock._run.stop();
        clock._scrub.stop();
        const d = Math.abs(t - clock.mt);
        if (d < 1e-4)
            return;
        clock._scrub.from = clock.mt;
        clock._scrub.to = t;
        clock._scrub.duration = Math.max(1, Math.round(clock.morphMs * d));
        clock._scrub.start();
    }

    function stop() {
        clock._scrub.stop();
        clock._run.stop();
    }

    property NumberAnimation _run: NumberAnimation {
        target: clock
        property: "mt"
        onFinished: clock.landed()
    }
    property NumberAnimation _scrub: NumberAnimation {
        target: clock
        property: "mt"
    }
}
