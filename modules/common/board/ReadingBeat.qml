pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ReadingBeat.qml -- the ONE clock every reading of a board module runs on (silicon's, aerial's).
//
// Readers on timers of their own (stats, battery, nvidia-smi, the overhead meter, the helper's
// status) would drift apart in phase: a slow figure would change in a frame of its own,
// between the fast ones beside it. So there is one repeating Timer at `baseMs`; a reader asks
// for every Nth beat (`serial % n === 0`), so a slow reader lands ON a fast beat and the figures
// that change together are read together.
//
//   baseMs    the beat's period; <= 0 stops it
//   serial    the number of the beat just sent (0 at a restart); incremented BEFORE `beat` is emitted
//   beat(serial)   one beat. A change of `baseMs` keeps the serial running (no extra reading)
//   restart() the phase starts again: serial 0, and beat(0) at once (opening reads everything)
// =============================================================================
Item {
    id: root

    property int baseMs: 1000
    property int serial: 0
    signal beat(int serial)

    function restart() {
        root.serial = 0;
        tick.restart();
        if (root.baseMs > 0)
            root.beat(0);
    }

    Timer {
        id: tick
        interval: Math.max(1, root.baseMs)
        repeat: true
        running: root.baseMs > 0
        onTriggered: {
            root.serial++;
            root.beat(root.serial);
        }
    }
}
