import QtQuick

// =============================================================================
// TimerClock.qml -- the time the timers run on.
//
// The wall clock, unless a mockup or a probe says otherwise: `scale` runs it
// faster (a 25-minute session in 25 seconds at 60x) and `jump(ms)` moves it
// on at once, the way a suspend does. Changing the scale keeps `now()`
// continuous. Everything that fires on this clock asks `realDelay()` how
// long to actually wait.
// =============================================================================
QtObject {
    id: clock

    property real scale: 1
    property real offsetMs: 0

    signal jumped(real deltaMs)

    property real _anchorReal: Date.now()
    property real _anchorVirt: Date.now()
    property real _lastScale: 1

    function now() {
        return clock._anchorVirt + (Date.now() - clock._anchorReal) * clock.scale + clock.offsetMs;
    }

    // Real milliseconds until `virtualMs` of this clock have passed.
    function realDelay(virtualMs) {
        return virtualMs / Math.max(1e-6, clock.scale);
    }

    function jump(ms) {
        clock.offsetMs += ms;
        clock.jumped(ms);
    }

    onScaleChanged: {
        clock._anchorVirt = clock._anchorVirt + (Date.now() - clock._anchorReal) * clock._lastScale;
        clock._anchorReal = Date.now();
        clock._lastScale = clock.scale;
    }
}
