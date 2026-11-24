pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// StallTimer.qml -- a one-shot timeout that does not count a freeze of the GUI thread. A plain `Timer` is the wrong clock for a
// watchdog of a sequence that waits on other processes and on the compositor:
//   - a GUI thread blocked for seconds (the shell's start-up warm-up compiles pipelines for 7-12 s with the GUI thread waiting on the
//     render thread) lets a 2.5 s timeout expire without anything having had the chance to answer,
//     and the timeout then fires the moment the thread is back -- the curtain loses its capture to it ("DROPPED: the capture did not
//     finish in 2500 ms", 435 ms after it was asked for);
//   - a timer's interval runs on the animation clock, which is not the wall clock (CLAUDE.md, OFFSCREEN, FRAMES ARE NOT A CLOCK).
// So: the deadline is `interval` of WALL time from start(), plus every stall the heartbeat saw while waiting, up to `maxCreditMs`
// (a freeze that long is something else, and the watchdog is allowed to fire). A stall is a gap between two beats longer than
// `graceMs`; the beat is 25 ms. The API is the part of Timer that the curtain uses: start/restart/stop, `interval`, `triggered`.
// =============================================================================
QtObject {
    id: root

    property int interval: 1000
    // a stall credited to one wait never extends it beyond this
    property int maxCreditMs: 15000
    property int graceMs: 100
    readonly property bool running: root._on
    signal triggered

    property bool _on: false
    property real _t0: 0
    property real _last: 0
    property real _credit: 0

    function restart(): void {
        root._t0 = Date.now();
        root._last = root._t0;
        root._credit = 0;
        root._on = true;
    }
    function start(): void {
        if (!root._on)
            root.restart();
    }
    function stop(): void {
        root._on = false;
    }

    function _check(): void {
        if (!root._on)
            return;
        const now = Date.now();
        const gap = now - root._last;
        root._last = now;
        if (gap > root.graceMs)
            root._credit = Math.min(root.maxCreditMs, root._credit + gap - beat.interval);
        if (now - root._t0 - root._credit >= root.interval) {
            root._on = false;
            root.triggered();
        }
    }

    property Timer _beat: Timer {
        id: beat
        interval: 25
        repeat: true
        running: root._on
        onTriggered: root._check()
    }
}
