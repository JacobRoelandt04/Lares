import QtQuick

// =============================================================================
// ClockTimer.qml -- a single-shot Timer on a StaggerClock: the same words (`interval`, `restart()`,
// `stop()`, `running`, `triggered`) and a different clock, so a wave's own bookkeeping (the head has
// landed, the wave is over, the leavers are gone) is paced by what was DRAWN, as its rows are.
//
// `interval` is in clock milliseconds. A wall-clock BACKSTOP (three intervals and 700 ms) fires it anyway,
// so a clock that never ticks (a window nobody presents) cannot leave a list half built for ever.
// =============================================================================
Item {
    id: ct
    visible: false
    property var clock: null
    property int interval: 0
    readonly property bool running: ct._running
    signal triggered()

    property bool _running: false
    property real _due: 0

    function restart() {
        ct.stop();
        if (!ct.clock) { ct.triggered(); return; }
        ct._due = ct.clock.now + ct.interval;
        ct._running = true;
        ct.clock.hold();
        backstop.interval = ct.interval * 3 + 700;
        backstop.restart();
    }
    function start() { ct.restart(); }
    function stop() {
        if (!ct._running) return;
        ct._running = false;
        backstop.stop();
        if (ct.clock) ct.clock.release();
    }
    function _fire() {
        ct.stop();
        ct.triggered();
    }
    Connections {
        target: ct.clock
        enabled: ct._running
        function onNowChanged() {
            if (ct.clock.now >= ct._due) ct._fire();
        }
    }
    Timer {
        id: backstop
        repeat: false
        onTriggered: if (ct._running) ct._fire()
    }
    Component.onDestruction: ct.stop()
}
