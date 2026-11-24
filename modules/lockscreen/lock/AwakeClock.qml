pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.UPower

// =============================================================================
// AwakeClock.qml -- is anybody there? (contract: LockState.awake, idleSeconds)
//
// `awake` is true for `idleSeconds` after the last input (a key or pointer
// motion on any lock surface: the surfaces call poke()). When it goes false the
// veil eases to still and stops rendering, and the face scan is not re-armed
// until the next `woke`. One idle Timer; poke() restarts it.
//
// `fps` is the veil's frame rate: the configured rate, times batteryFpsRatio
// on battery. `onBattery` is a plain property bound to UPower so a probe can
// assign it (a stub battery) without a UPower service on its bus.
// =============================================================================
Scope {
    id: root

    property real idleSeconds: 30
    property real baseFps: 60
    property real batteryFpsRatio: 0.5
    property bool onBattery: UPower.onBattery

    readonly property real fps: Math.max(1, root.baseFps * (root.onBattery ? root.batteryFpsRatio : 1))
    property bool awake: true

    // The idle -> awake edge: something to re-arm (the face scan), a wake pulse.
    signal woke

    function poke() {
        idle.restart();
        if (!root.awake) {
            root.awake = true;
            root.woke();
        }
    }

    Timer {
        id: idle
        interval: Math.max(1, Math.round(root.idleSeconds * 1000))
        running: true
        onTriggered: root.awake = false
    }
}
