pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/system"

// =============================================================================
// BatterySource.qml -- the battery crossing its low-charge line, or reaching
// full. BatteryData already decides when (`eventLowCharge`, `eventFullyCharged`:
// its thresholds, once per crossing); this only turns the event into a card.
// The card is drawn on the pack the charge limit leaves (`target`: the backend's
// `targetPercent`, 100 when it has none): full at 80 with the limit on, as the
// bar's track is.
//
//   signal request(var req)    one partial CONTRACT section 1 request
//
// `live: false` has no sysfs: simulate(event, percent) is the event.
// `backend` hands in the shell's own battery reader (the silicon battery
// adapter in the shell; a BatteryData in a standalone host). With none, the
// source stays silent unless the host asks for a reader of its own
// (`ownBackend`): see THE FALLBACK below.
// =============================================================================
Item {
    id: root

    property bool live: true
    property var backend: null

    signal request(var req)

    function _event(event, percent) {
        root.request({
            kind: "battery",
            key: "battery",
            source: "external",
            battery: { percent: Math.max(0, Math.min(100, Math.round(percent))), event: event,
                       target: root._data && root._data.targetPercent > 0 ? root._data.targetPercent : 100 }
        });
    }

    function simulate(event, percent) {
        root._event(event, percent);
    }

    // THE FALLBACK. A source with no backend can build a service of its own (a BatteryData). SHELL-HOSTED
    // (CONTRACT section 4): the backend is the shell's one BatteryData, injected, and a null one means the
    // feature is ABSENT -- a hosted source never builds a service of its own -- said once in the log,
    // because it is a wiring fault, not a state.
    // THE BATTERY IS THE ONE WITH A COST: a BatteryData reads the EC's _BST every second (the EC-wedge
    // law), so this source builds one only when the host asks (`ownBackend: true`, a standalone
    // host) -- never by default, never in a hosted shell, which hands in the silicon battery adapter.
    // The default matters at CREATION: a host that injects the adapter through a binding that has no
    // value yet (an object a Loader is still making) finds this Loader already active, and a
    // BatteryData is built for the instant before the adapter arrives.
    property bool ownBackend: false
    property bool shellHosted: false
    // How many services this source has built for itself (a probe reads it; nothing binds to it).
    property int builds: 0
    Component.onCompleted: {
        if (root.shellHosted && root.live && root.backend === null)
            console.warn("OsdService: shell-hosted but the battery source got no backend; it stays absent (it does not build its own BatteryData)");
    }

    Loader {
        id: loader
        active: root.live && root.backend === null && !root.shellHosted && root.ownBackend
        sourceComponent: BatteryData {}
        onLoaded: root.builds++
    }
    readonly property var _data: root.backend !== null ? root.backend : loader.item

    Connections {
        target: root.live ? root._data : null
        ignoreUnknownSignals: true
        function onEventLowCharge() { root._event("low", root._data.percent); }
        function onEventFullyCharged() { root._event("full", root._data.percent); }
    }
}
