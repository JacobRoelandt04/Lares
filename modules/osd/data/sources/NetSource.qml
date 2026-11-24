pragma ComponentBehavior: Bound

import QtQuick
import "../OsdKinds.js" as Kinds

// =============================================================================
// NetSource.qml -- Wi-Fi connected, lost or FAILED, a cable plugged or pulled (wired up / down), a VPN coming up or
// going down, and the tunnel aerial raised BY ITSELF on a Public network (`autoTunnel`). The OSD is the one place these are
// told: nm-applet's and blueman's own toasts are dropped (notifications.jsonc "apps", `drop`), so what they would say --
// "Connection Established" -- is this card.
//
//   signal request(var req)    one partial CONTRACT section 1 request
//
// The backend is the shell's ONE AerialService (`aerialBackend` of the OsdService): its facts change under `serial` (bumped LAST,
// once per publication), OsdKinds.netModelOf folds wifi / wired / proton into a reading and OsdKinds.diffNet turns two readings into
// events. The FIRST build is the baseline and says nothing, and neither does anything inside `warmupMs` of it (the facts fill in as
// the helper answers: the connected network appears AFTER the first build). A signal-strength wobble, a scan, a device appearing say
// nothing: only the connected network changing, a network's failure appearing (the service's own words: "Wrong password"), a wired
// link's `connected` flipping and the tunnel's `up` flipping.
//
// `autoTunnel` comes from the SERVICE's own `osd(kind, payload)` signal (never from a poll of the facts: the service is the one that
// knows it raised the tunnel), `{ country }`, and is a card of its own (kind `autoTunnel`); the other kinds of that signal are
// BtSource's. A mock shell's service is not live and emits none.
//
// `live: false` has no service: simulateModel(model) is a reading
// (`{ networks: [{id, ssid, connected, signal 0..1, failReason}], vpns: [{id, name, up}],
// devices: [{kind, name, connected, networkName}] }`).
// A source with no backend is ABSENT (said once in the log when shell-hosted: a wiring fault), it never builds a service of its own.
// =============================================================================
Item {
    id: root

    property bool live: true
    property var backend: null
    // After the first build the facts are still filling in (the helper answers piece by piece): readings inside this window only re-baseline.
    property int warmupMs: 3000

    signal request(var req)

    property var _prev: null
    property double _guardUntil: 0

    function _observe(model) {
        const prev = root._prev;
        root._prev = model;
        if (prev === null)
            root._guardUntil = Date.now() + root.warmupMs;
        if (Date.now() < root._guardUntil)
            return;
        const ev = Kinds.diffNet(prev, model);
        for (let i = 0; i < ev.length; i++) {
            const e = ev[i];
            if (e.kind === "network") {
                const net = Object.assign({}, e.net);
                if (net.state === "failed")
                    net.reason = net.reasonId || "Connection failed";
                delete net.reasonId;
                root.request({ kind: "network", key: "network", source: "external", net: net });
            }
            else
                root.request({ kind: "vpn", key: "vpn", source: "external", vpn: e.vpn });
        }
    }

    function simulateModel(model) {
        root._observe(model);
    }

    // A source with no backend and no request is absent. SHELL-HOSTED (CONTRACT section 4): the backend is the shell's one service,
    // injected, and a null one means the feature is ABSENT, said once in the log, because it is a wiring fault, not a state.
    property bool shellHosted: false
    // How many services this source has built for itself (a probe reads it): never one.
    readonly property int builds: 0
    Component.onCompleted: {
        if (root.shellHosted && root.live && root.backend === null)
            console.warn("OsdService: shell-hosted but the net source got no backend; it stays absent (it does not build its own AerialService)");
    }

    Connections {
        target: root.live ? root.backend : null
        ignoreUnknownSignals: true
        function onSerialChanged() {
            const b = root.backend;
            root._observe(Kinds.netModelOf({ wifi: b.wifi, wired: b.wired, proton: b.proton }));
        }
        function onOsd(kind: string, payload: var) {
            if (kind === "autoTunnel")
                root.request({ kind: "autoTunnel", key: "autoTunnel", source: "external", tunnel: { country: payload && payload.country ? String(payload.country) : "" } });
        }
    }
}
