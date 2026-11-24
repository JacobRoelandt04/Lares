pragma ComponentBehavior: Bound

import QtQuick
import "../OsdKinds.js" as Kinds

// =============================================================================
// BtSource.qml -- a Bluetooth device connecting or disconnecting, and its battery running low (`btLow`).
//
//   signal request(var req)    one partial CONTRACT section 1 request
//
// The backend is the shell's ONE AerialService (`aerialBackend`): on each `serial` OsdKinds.btRowsOf turns `bt.devices` into rows and
// OsdKinds.diffBt turns two readings into events. The FIRST build is the baseline and says nothing (devices that were connected
// before the shell started are not news), and neither is whatever lands inside `warmupMs` of it: the rows of a service that has just
// started keep arriving (a device is published, then its connected flag), and each of those is a baseline, not an event.
//
// THE BATTERY ARRIVES LATE. bluez publishes no battery until a device has been connected for a moment, and the card wants it; a
// connect event that has none waits `batteryWaitMs` and goes out with whatever the row says by then (-1 if still nothing). A disconnect
// goes out at once.
//
// `btLow` comes from the SERVICE's own `osd(kind, payload)` signal (20 % and 10 %, once per crossing per device: AerialModel.lowBattery),
// `{ address, name, battery }`: a card of its own (kind `btLow`), no notification. The other kinds of that signal are NetSource's.
//
// `live: false` has no Bluetooth: simulateRows(rows) is a reading (rows: id, name, icon, connected, batteryPct, batteryAvailable).
// A source with no backend is ABSENT; it never builds a service of its own.
// =============================================================================
Item {
    id: root

    property bool live: true
    property var backend: null
    property int batteryWaitMs: 1500
    // After the first build the rows are still arriving (bluez publishes devices,
    // then their connected flags): readings inside this window only re-baseline.
    property int warmupMs: 3000

    signal request(var req)

    property var _prev: null
    property double _guardUntil: 0
    property var _held: []      // connect events waiting for a battery figure

    function _observe(rows) {
        const prev = root._prev;
        root._prev = rows;
        if (prev === null) {
            root._guardUntil = Date.now() + root.warmupMs;
            return;
        }
        if (Date.now() < root._guardUntil)
            return;
        const ev = Kinds.diffBt(prev, rows);
        for (let i = 0; i < ev.length; i++) {
            if (ev[i].state === "connected" && ev[i].battery < 0 && root.batteryWaitMs > 0) {
                root._held = root._held.concat([ev[i]]);
                wait.restart();
            } else {
                // A connect still waiting for its battery and already undone:
                // the pair says nothing.
                if (ev[i].state === "disconnected" && root._drop(ev[i].id))
                    continue;
                root._send(ev[i]);
            }
        }
    }

    // Takes a held connect away; true when there was one.
    function _drop(id) {
        const n = root._held.length;
        root._held = root._held.filter(e => e.id !== id);
        return root._held.length < n;
    }

    // The wait is over: every held connect goes out with what its row says now.
    function _flushHeld() {
        const held = root._held;
        root._held = [];
        for (let i = 0; i < held.length; i++)
            root._send(root._withBattery(held[i]));
    }

    function _withBattery(e) {
        const rows = root._prev || [];
        for (let i = 0; i < rows.length; i++)
            if (rows[i].id === e.id)
                return Object.assign({}, e, { battery: rows[i].batteryAvailable ? Math.round(rows[i].batteryPct) : -1 });
        return e;
    }

    function _send(e) {
        root.request({
            kind: "bluetooth",
            key: e.id,
            source: "external",
            bt: { name: e.name, icon: e.icon, battery: e.battery, state: e.state }
        });
    }

    Timer {
        id: wait
        interval: root.batteryWaitMs
        onTriggered: root._flushHeld()
    }

    function simulateRows(rows) {
        root._observe(rows);
    }

    // A source with no backend and no request is absent. SHELL-HOSTED (CONTRACT section 4): the backend is the shell's one service,
    // injected, and a null one means the feature is ABSENT, said once in the log, because it is a wiring fault, not a state.
    property bool shellHosted: false
    // How many services this source has built for itself (a probe reads it): never one.
    readonly property int builds: 0
    Component.onCompleted: {
        if (root.shellHosted && root.live && root.backend === null)
            console.warn("OsdService: shell-hosted but the bluetooth source got no backend; it stays absent (it does not build its own AerialService)");
    }

    Connections {
        target: root.live ? root.backend : null
        ignoreUnknownSignals: true
        function onSerialChanged() {
            root._observe(Kinds.btRowsOf(root.backend.bt));
        }
        function onOsd(kind: string, payload: var) {
            if (kind === "btLow" && payload)
                root.request({ kind: "btLow", key: "btLow:" + String(payload.address || ""), source: "external",
                               bt: { name: String(payload.name || ""), icon: "bluetooth", battery: Math.max(0, Math.min(100, Math.round(Number(payload.battery) || 0))) } });
        }
    }
}
