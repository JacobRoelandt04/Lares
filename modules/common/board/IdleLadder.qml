pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// IdleLadder.qml -- the popup's idle ladder as a state: alive while the pointer is active, calm
// after `calmAfterMs` without it, halt after `haltAfterMs`; a closed popup is halt. A board module's service (which polls at the rates the state
// names) and its mock own one each (SiliconService, SiliconMock). The four times below are silicon's tuned constants; a module that wants others
// sets them where it declares its ladder.
//
//   open          the popup is open (the owner binds it)
//   calmAfterMs / haltAfterMs   when it goes calm, and halts
//   statsHaltedMs / batteryHaltedMs   once halted (and closed, for the battery), how often the service reads (SiliconModel.cadence;
//                 the battery's is rounded to a whole number of the stats' beats)
// The four times are the module's constants, tuned on the silicon mockup's Motion tab: a halted popup reads its figures every 2 s and
// the battery every 5 s, which is also how often the battery is read with the popup closed.
//   level         "alive" | "calm" | "halt"
//   touch()       pointer activity, or a fact the scene plays, in a live popup: back to alive
//
// A TOUCH WINS OVER `open`. Only a live popup touches (SiliconPopup._touch and its wakes; a parked or a gone one does not), so a
// touch is proof that somebody is looking, and `open` is second-hand: in the shell it is the OR of the screens' flags, written
// through the frames' registry. A flag that stayed behind -- false over an open popup, or true through a close and a reopen on
// another screen, where no edge comes -- would leave the ladder at halt with the pointer moving over a popup that has stopped
// (the power saving measure triggered permanently, feedback/silicon.md). The timers still run a touch down to
// halt, and the service's cadence follows `open`, so a stray touch from a popup on its way out costs nothing.
// =============================================================================
Item {
    id: root

    property bool open: false
    property int calmAfterMs: 10000
    property int haltAfterMs: 30000
    property int statsHaltedMs: 2000
    property int batteryHaltedMs: 5000
    readonly property string level: root._state

    function touch() {
        root._state = "alive";
        calm.restart();
        halt.restart();
    }

    property string _state: "halt"

    onOpenChanged: {
        if (root.open) {
            root._state = "alive";
            calm.restart();
            halt.restart();
        } else {
            calm.stop();
            halt.stop();
            root._state = "halt";
        }
    }

    Timer { id: calm; interval: root.calmAfterMs; onTriggered: root._state = "calm" }
    Timer { id: halt; interval: root.haltAfterMs; onTriggered: root._state = "halt" }
}
