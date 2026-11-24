import QtQuick

// =============================================================================
// AerialTap.qml -- a vm for probes (tools/dev/aerial_panels_probe.sh): the SAME members as AerialMock / AerialService (facts follow `src`),
// and every intent is RECORDED (`log`: { n: name, a: [arguments] }) and then forwarded to `src`, so a panel's click is proved by the call
// the data layer would have received. GENERATED from the contract's list of intents (docs/contracts/aerial.md section 2): a new intent is
// added here by hand. `leaked` is a probe's handle for the secret-is-not-kept check (a panel must never write into it).
// =============================================================================
Item {
    id: tap

    property var src: null
    property var log: []
    property string leaked: ""
    // a probe's way to say a fact differs (an override replaces that fact whole, whatever `src` says)
    property var override: ({})
    property bool live: true
    property bool popupOpen: false
    readonly property real serial: tap.src ? tap.src.serial : 0
    readonly property var helper: tap.override.helper !== undefined ? tap.override.helper : (tap.src ? tap.src.helper : null)
    readonly property var wifi: tap.override.wifi !== undefined ? tap.override.wifi : (tap.src ? tap.src.wifi : null)
    readonly property var wired: tap.override.wired !== undefined ? tap.override.wired : (tap.src ? tap.src.wired : null)
    readonly property var hotspot: tap.override.hotspot !== undefined ? tap.override.hotspot : (tap.src ? tap.src.hotspot : null)
    readonly property var bt: tap.override.bt !== undefined ? tap.override.bt : (tap.src ? tap.src.bt : null)
    readonly property var proton: tap.override.proton !== undefined ? tap.override.proton : (tap.src ? tap.src.proton : null)
    readonly property var catalog: tap.override.catalog !== undefined ? tap.override.catalog : (tap.src ? tap.src.catalog : null)
    readonly property var health: tap.override.health !== undefined ? tap.override.health : (tap.src ? tap.src.health : null)
    readonly property var rates: tap.override.rates !== undefined ? tap.override.rates : (tap.src ? tap.src.rates : null)
    readonly property var usage: tap.override.usage !== undefined ? tap.override.usage : (tap.src ? tap.src.usage : null)
    readonly property var speed: tap.override.speed !== undefined ? tap.override.speed : (tap.src ? tap.src.speed : null)
    readonly property var airplane: tap.override.airplane !== undefined ? tap.override.airplane : (tap.src ? tap.src.airplane : null)
    readonly property var errors: tap.override.errors !== undefined ? tap.override.errors : (tap.src ? tap.src.errors : null)
    readonly property var config: tap.override.config !== undefined ? tap.override.config : (tap.src ? tap.src.config : null)

    signal osd(string kind, var payload)
    signal secret(string uuid, string text)
    signal failed(string id, string text)

    Connections {
        target: tap.src
        function onSecret(uuid: string, text: string): void { tap.secret(uuid, text); }
        function onFailed(id: string, text: string): void { tap.failed(id, text); }
        function onOsd(kind: string, payload: var): void { tap.osd(kind, payload); }
    }

    function _rec(n: string, a: var): void {
        tap.log = tap.log.concat([{ n: n, a: Array.prototype.slice.call(a) }]);
    }

    function scan(): void {
        tap._rec("scan", []);
        if (tap.src)
            tap.src.scan();
    }
    function connect(key, opts): void {
        tap._rec("connect", [key, opts]);
        if (tap.src)
            tap.src.connect(key, opts);
    }
    function disconnect(): void {
        tap._rec("disconnect", []);
        if (tap.src)
            tap.src.disconnect();
    }
    function forget(uuid): void {
        tap._rec("forget", [uuid]);
        if (tap.src)
            tap.src.forget(uuid);
    }
    function setRadio(on): void {
        tap._rec("setRadio", [on]);
        if (tap.src)
            tap.src.setRadio(on);
    }
    function setAutoconnect(uuid, on): void {
        tap._rec("setAutoconnect", [uuid, on]);
        if (tap.src)
            tap.src.setAutoconnect(uuid, on);
    }
    function setPriority(uuid, n): void {
        tap._rec("setPriority", [uuid, n]);
        if (tap.src)
            tap.src.setPriority(uuid, n);
    }
    function revealSecret(uuid): void {
        tap._rec("revealSecret", [uuid]);
        if (tap.src)
            tap.src.revealSecret(uuid);
    }
    function updateProfile(uuid, patch): void {
        tap._rec("updateProfile", [uuid, patch]);
        if (tap.src)
            tap.src.updateProfile(uuid, patch);
    }
    function mergeDoubles(keepUuid, dropUuids): void {
        tap._rec("mergeDoubles", [keepUuid, dropUuids]);
        if (tap.src)
            tap.src.mergeDoubles(keepUuid, dropUuids);
    }
    function addNetwork(ssid, security, password): void {
        tap._rec("addNetwork", [ssid, security, password]);
        if (tap.src)
            tap.src.addNetwork(ssid, security, password);
    }
    function setTrusted(uuidOrKey, on): void {
        tap._rec("setTrusted", [uuidOrKey, on]);
        if (tap.src)
            tap.src.setTrusted(uuidOrKey, on);
    }
    function setPowersave(on): void {
        tap._rec("setPowersave", [on]);
        if (tap.src)
            tap.src.setPowersave(on);
    }
    function connectWired(iface): void {
        tap._rec("connectWired", [iface]);
        if (tap.src)
            tap.src.connectWired(iface);
    }
    function disconnectWired(iface): void {
        tap._rec("disconnectWired", [iface]);
        if (tap.src)
            tap.src.disconnectWired(iface);
    }
    function startHotspot(): void {
        tap._rec("startHotspot", []);
        if (tap.src)
            tap.src.startHotspot();
    }
    function stopHotspot(): void {
        tap._rec("stopHotspot", []);
        if (tap.src)
            tap.src.stopHotspot();
    }
    function configureHotspot(o): void {
        tap._rec("configureHotspot", [o]);
        if (tap.src)
            tap.src.configureHotspot(o);
    }
    function setBtPowered(on): void {
        tap._rec("setBtPowered", [on]);
        if (tap.src)
            tap.src.setBtPowered(on);
    }
    function btSearch(): void {
        tap._rec("btSearch", []);
        if (tap.src)
            tap.src.btSearch();
    }
    function btVisible(): void {
        tap._rec("btVisible", []);
        if (tap.src)
            tap.src.btVisible();
    }
    function btConnect(a): void {
        tap._rec("btConnect", [a]);
        if (tap.src)
            tap.src.btConnect(a);
    }
    function btDisconnect(a): void {
        tap._rec("btDisconnect", [a]);
        if (tap.src)
            tap.src.btDisconnect(a);
    }
    function btPair(a): void {
        tap._rec("btPair", [a]);
        if (tap.src)
            tap.src.btPair(a);
    }
    function btCancelPair(a): void {
        tap._rec("btCancelPair", [a]);
        if (tap.src)
            tap.src.btCancelPair(a);
    }
    function btTrust(a, on): void {
        tap._rec("btTrust", [a, on]);
        if (tap.src)
            tap.src.btTrust(a, on);
    }
    function btBlock(a, on): void {
        tap._rec("btBlock", [a, on]);
        if (tap.src)
            tap.src.btBlock(a, on);
    }
    function btForget(a): void {
        tap._rec("btForget", [a]);
        if (tap.src)
            tap.src.btForget(a);
    }
    function btRename(a, name): void {
        tap._rec("btRename", [a, name]);
        if (tap.src)
            tap.src.btRename(a, name);
    }
    function btSetProfile(a, profile): void {
        tap._rec("btSetProfile", [a, profile]);
        if (tap.src)
            tap.src.btSetProfile(a, profile);
    }
    function btAnswer(rid, accept, value): void {
        tap._rec("btAnswer", [rid, accept, value]);
        if (tap.src)
            tap.src.btAnswer(rid, accept, value);
    }
    function vpnConnect(o): void {
        tap._rec("vpnConnect", [o]);
        if (tap.src)
            tap.src.vpnConnect(o);
    }
    function vpnDisconnect(): void {
        tap._rec("vpnDisconnect", []);
        if (tap.src)
            tap.src.vpnDisconnect();
    }
    function vpnSet(key, value): void {
        tap._rec("vpnSet", [key, value]);
        if (tap.src)
            tap.src.vpnSet(key, value);
    }
    function setAutoTunnel(on): void {
        tap._rec("setAutoTunnel", [on]);
        if (tap.src)
            tap.src.setAutoTunnel(on);
    }
    function refreshCatalog(): void {
        tap._rec("refreshCatalog", []);
        if (tap.src)
            tap.src.refreshCatalog();
    }
    function testPad(id): void {
        tap._rec("testPad", [id]);
        if (tap.src)
            tap.src.testPad(id);
    }
    function openPortal(): void {
        tap._rec("openPortal", []);
        if (tap.src)
            tap.src.openPortal();
    }
    function armSpeedTest(): void {
        tap._rec("armSpeedTest", []);
        if (tap.src)
            tap.src.armSpeedTest();
    }
    function runSpeedTest(): void {
        tap._rec("runSpeedTest", []);
        if (tap.src)
            tap.src.runSpeedTest();
    }
    function cancelSpeedTest(): void {
        tap._rec("cancelSpeedTest", []);
        if (tap.src)
            tap.src.cancelSpeedTest();
    }
    function setAirplane(on): void {
        tap._rec("setAirplane", [on]);
        if (tap.src)
            tap.src.setAirplane(on);
    }
    function dismissError(id): void {
        tap._rec("dismissError", [id]);
        if (tap.src)
            tap.src.dismissError(id);
    }
    function touch(): void {
        tap._rec("touch", []);
        if (tap.src)
            tap.src.touch();
    }
    function refresh(): void {
        tap._rec("refresh", []);
        if (tap.src)
            tap.src.refresh();
    }
}
