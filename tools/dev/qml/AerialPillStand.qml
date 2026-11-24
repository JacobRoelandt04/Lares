import QtQuick

// =============================================================================
// AerialPillStand.qml -- a stand-in AerialService for the harnesses that put the bar's pill (AerialBarButton) in a cell: it holds the facts the pill
// reads (wifi, wired, hotspot, bt, proton, health, airplane, rates; `serial`), and `net(o)` / `setBt(o)` set them from a few words:
//   net:  { radio (true), connected (true), bars (0..4), portal, fault ("warn" | "error"), wired (a cable carries), wiredDevice (a jack exists),
//           noWifi, hotspot, vpn (a tunnel up), publicNet (the joined network is Public), airplane }
//   setBt: { on, blocked, connected, devices: [{ address, name, connected, battery (-1 none), parts }] }
// No process, no file, no bus: it is data. (The real AerialMock is for mockups; a probe of the pill wants one fact at a time.)
// =============================================================================
QtObject {
    id: stand

    property real serial: 1
    property var wifi: ({ present: true, radioOn: true, hardBlocked: false, networks: [{ key: "home", ssid: "home", connected: true, signalBand: 1, trusted: true }], active: null })
    property var wired: ({ jacks: [] })
    property var hotspot: ({ active: false })
    property var bt: ({ present: true, powered: true, hardBlocked: false, softBlocked: false, devices: [] })
    property var proton: ({ state: "down" })
    property var health: ({ pads: [] })
    property var airplane: ({ on: false })
    property var rates: ({ iface: "", rxBps: 0, txBps: 0, atMs: 0 })

    function net(o: var): void {
        const radio = o.radio === undefined ? true : !!o.radio;
        const connected = o.connected === undefined ? true : !!o.connected;
        const bars = o.bars === undefined ? 3 : o.bars;
        stand.wifi = { present: !o.noWifi, radioOn: radio, hardBlocked: false,
                       networks: connected && !o.noWifi ? [{ key: "home", ssid: "home", connected: true, signalBand: 4 - bars, trusted: !o.publicNet }] : [], active: null };
        stand.wired = { jacks: o.wiredDevice || o.wired ? [{ iface: "enp1", kind: "rj45", connected: !!o.wired, carrier: !!o.wired }] : [] };
        stand.hotspot = { active: !!o.hotspot };
        stand.proton = { state: o.vpn ? "up" : "down" };
        stand.health = { pads: o.fault ? [{ id: "net", state: o.fault === "error" ? "fail" : "warn" }] : (o.portal ? [{ id: "net", state: "warn" }] : []) };
        stand.airplane = { on: !!o.airplane };
        stand.serial++;
    }

    function setBt(o: var): void {
        stand.bt = { present: true, powered: !!o.on, hardBlocked: !!o.blocked, softBlocked: false,
                     devices: o.devices ? o.devices : (o.connected ? [{ address: "AA:00:00:00:00:01", name: "d", connected: true, battery: -1, parts: null }] : []) };
        stand.serial++;
    }
}
