pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/aerial/data"
import "modules/aerial/data/AerialModel.js" as Model

// =============================================================================
// aerial_service_probe.qml -- AerialService (live) against tools/dev/aerial_helper_stub.py and a fake Bluetooth source, and AerialMock,
// headless. Run by tools/dev/aerial_service_probe.sh (sandbox, private XDG dirs, the stub, private proc files). Never started bare: with no
// AS_OUT it says SKIPPED and quits.
//
// One `AS <check> PASS|FAIL  detail` line per check, then `AS DONE PASS|FAIL`.
// A step is { n, act?, until?, wait?, check?, ms? }: `act` runs once; `until` must turn true within `ms` (else FAIL, with `why()`); `wait` ms
// later `check()` must be true (for "nothing happened" claims).
// =============================================================================
ShellRoot {
    id: root

    readonly property string out: Quickshell.env("AS_OUT") || ""
    readonly property string stub: Quickshell.env("AS_STUB") || ""
    readonly property bool armed: root.out !== "" && root.stub !== ""
    property bool ok: true
    property int fails: 0

    function j(v) { return JSON.stringify(v); }
    function check(name, pass, detail) {
        console.log("AS " + name + " " + (pass ? "PASS" : "FAIL") + "  " + (pass ? "" : detail));
        if (!pass) {
            root.ok = false;
            root.fails++;
        }
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
    function finish() {
        console.log("AS DONE " + (root.ok ? "PASS" : "FAIL"));
        quitTimer.start();
    }

    // ---- files the probe drives ------------------------------------------------------------------------------------------------------
    property string ctlText: ""
    property string wirelessText: ""
    property string netdevText: ""
    FileView { id: ctlFile; path: root.out + "/control.jsonl"; blockWrites: true; printErrors: false; atomicWrites: false }
    FileView { id: logFile; path: root.out + "/stub.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: log2File; path: root.out + "/stub2.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: wlFile; path: root.out + "/proc/wireless"; blockWrites: true; printErrors: false; atomicWrites: false }
    FileView { id: ndFile; path: root.out + "/proc/net_dev"; blockWrites: true; printErrors: false; atomicWrites: false }
    FileView { id: usageJson; path: root.out + "/state/lares/aerial/usage.json"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: trustJson; path: root.out + "/state/lares/aerial/trust.json"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: vpnJson; path: root.out + "/state/lares/aerial/vpn.json"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: openLog; path: root.out + "/open.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: cfgFile; path: root.out + "/config/aerial.jsonc"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }

    function ctl(o) {
        root.ctlText += JSON.stringify(o) + "\n";
        ctlFile.setText(root.ctlText);
    }
    function cmds(name, which) {
        const f = which === 2 ? log2File : logFile;
        f.reload();
        const lines = f.text().split("\n");
        const out = [];
        for (let i = 0; i < lines.length; i++)
            if (lines[i].trim() !== "") {
                const m = JSON.parse(lines[i]);
                if (!name || m.cmd === name || (m.cmd + ":" + m.action) === name)
                    out.push(m);
            }
        return out;
    }
    function setWireless(iface, dbm) {
        root.wirelessText = "Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n"
            + iface + ": 0000   60.  " + dbm + ".  -256        0      0      0      0      0        0\n";
        wlFile.setText(root.wirelessText);
    }
    function setNetdev(iface, rx, tx) {
        root.netdevText = "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
            + "    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n" + iface + ": " + rx + " 99 0 0 0 0 0 0 " + tx + " 50 0 0 0 0 0 0\n";
        ndFile.setText(root.netdevText);
    }

    // ---- the fixtures: what the helper would say ---------------------------------------------------------------------------------------
    function ap(path, bssid, ssid, freq, strength, rsn, flags) {
        return { path: path, bssid: bssid, ssid: ssid, ssidHex: "", freq: freq, width: 80, strength: strength, maxBitrate: 866000, flags: flags === undefined ? 1 : flags, wpaFlags: 0, rsnFlags: rsn, lastSeen: 50, lastSeenMs: 0, mode: 2 };
    }
    function wifiMsg(homeStrength, activeBssid) {
        return { t: "wifi", device: { iface: "wlp47s0", hwAddress: "02:00:00:00:00:01", permHwAddress: "02:00:00:00:00:01", driver: "iwlwifi" },
                 aps: [ap("/a/1", "AA:AA:AA:AA:AA:01", "Home", 5180, homeStrength, 0x108), ap("/a/2", "AA:AA:AA:AA:AA:02", "Home", 2437, 55, 0x108),
                       ap("/a/3", "BB:BB:BB:BB:BB:01", "Cafe", 2412, 45, 0, 0), ap("/a/4", "CC:CC:CC:CC:CC:01", "", 5200, 33, 0x108)],
                 activeAp: activeBssid === undefined ? "AA:AA:AA:AA:AA:01" : activeBssid, scanning: false, lastScan: -1, lastScanMs: 1700000000000 };
    }
    function devicesMsg() {
        return { t: "devices", v: [
            { iface: "wlp47s0", type: "wifi", driver: "iwlwifi", state: "activated", hwAddress: "02:00:00:00:00:01", ip4: { addresses: [{ address: "192.168.1.20", prefix: 24 }], gateway: "192.168.1.1", dns: ["1.1.1.1"] }, ip6: null },
            { iface: "enp46s0", type: "ethernet", driver: "r8169", state: "unavailable", carrier: false, speed: 0, ip4: null, ip6: null },
            { iface: "pvpnksintrf0", type: "ethernet", driver: "dummy", state: "activated", carrier: true, speed: 10000, ip4: { addresses: [{ address: "100.85.0.1", prefix: 32 }], gateway: "", dns: [] }, ip6: null }] };
    }
    function act(uuid, id, type, dev, def, state) { return { uuid: uuid, id: id, type: type, devices: [dev], state: state || "activated", vpn: false, default4: def, default6: false, specific: "", proton: false, killswitch: id.indexOf("pvpn-killswitch") === 0 }; }
    function activeMsg(list) { return { t: "active", v: list }; }
    function profile(uuid, id, ssid, o) { return Object.assign({ uuid: uuid, id: id, type: "802-11-wireless", ssid: ssid, mode: "infrastructure", security: "wpa2", autoconnect: true, priority: 0, timestamp: 1700000000, hidden: false, metered: "unknown" }, o || {}); }
    readonly property var profHome: profile("u-home", "Home", "Home")
    readonly property var profHome1: profile("u-home1", "Home 1", "Home")
    readonly property var profEdu: profile("u-edu", "eduroam", "eduroam", { security: "eap" })
    readonly property var nmMsg: ({ t: "nm", running: true, state: 70, primary: "Home", primaryReal: "Home", connectivity: 4, wirelessEnabled: true, wirelessHardwareEnabled: true, version: "1.58.1" })

    // ---- fake Bluetooth (the shape Quickshell.Bluetooth has) ------------------------------------------------------------------------------
    Component {
        id: fakeDevComp
        QtObject {
            property string address: ""
            property string name: ""
            property string deviceName: ""
            property string icon: "phone"
            property bool connected: false
            property bool paired: false
            property bool bonded: false
            property bool pairing: false
            property bool trusted: false
            property bool blocked: false
            property real battery: 0
            property bool batteryAvailable: false
            property var calls: []
            function connect() { calls.push("connect"); }
            function disconnect() { calls.push("disconnect"); }
            function pair() { calls.push("pair"); }
            function cancelPair() { calls.push("cancelPair"); }
            function forget() { calls.push("forget"); }
        }
    }
    QtObject {
        id: fakeAdapter
        property string name: "laptop"
        property bool enabled: true
        property string state: "Enabled"
        property bool discoverable: false
        property real discoverableTimeout: 0
        property bool discovering: false
        property bool pairable: false
    }
    QtObject {
        id: fakeBt
        property var defaultAdapter: fakeAdapter
        property var devices: []
    }
    function addBtDev(o) {
        const d = fakeDevComp.createObject(root, o);
        fakeBt.devices = fakeBt.devices.concat([d]);
        return d;
    }
    function btDev(address) {
        for (let i = 0; i < fakeBt.devices.length; i++)
            if (fakeBt.devices[i].address === address)
                return fakeBt.devices[i];
        return null;
    }

    // ---- the services under test -----------------------------------------------------------------------------------------------------
    readonly property var stubCmd: ["python3", "-I", root.stub, "--log", root.out + "/stub.log", "--control", root.out + "/control.jsonl", "--scenario", root.out + "/scenario.json"]
    property var osds: []
    property var fails2: []
    property var secrets: []
    property var cues: []
    // the shell's DesktopNotifier, as far as the service uses it: every notify / withdraw, in order
    QtObject {
        id: fakeNotifier
        signal action(string key, string id)
        property var calls: []
        property var gone: []
        function notify(key, spec) { calls.push({ key: key, spec: spec }); }
        function withdraw(key) { gone.push(key); }
    }

    AerialService {
        id: svc
        live: false
        notifier: fakeNotifier
        onCue: part => root.cues = root.cues.concat([part])
        helperCommand: root.stubCmd
        btSource: fakeBt
        upowerEnabled: false
        procWirelessPath: root.out + "/proc/wireless"
        procNetDevPath: root.out + "/proc/net_dev"
        procUptimePath: root.out + "/proc/uptime"
        stateDir: root.out + "/state/lares/aerial"
        configPath: root.out + "/config/aerial.jsonc"
        protonPath: "/usr/bin/true"
        dnsmasqPath: "/usr/bin/true"
        protonCachePath: root.out + "/serverlist.json"
        openCommand: [root.out + "/open_stub.sh"]
        rfkillCommand: ["true"]
        pactlCommand: ["true"]
        commandTimeoutMs: 1500
        scanEveryMs: 60000
        btConnectTimeoutMs: 3000
        onOsd: (kind, payload) => root.osds = root.osds.concat([{ kind: kind, payload: payload }])
        onFailed: (id, text) => root.fails2 = root.fails2.concat([{ id: id, text: text }])
        onSecret: (uuid, text) => root.secrets = root.secrets.concat([{ uuid: uuid, text: text }])
    }
    // a second shell on the SAME state dir: the "later run"
    AerialService {
        id: svc2
        live: false
        helperCommand: ["python3", "-I", root.stub, "--log", root.out + "/stub2.log", "--control", root.out + "/control2.jsonl", "--scenario", root.out + "/scenario.json"]
        btSource: null
        upowerEnabled: false
        procWirelessPath: root.out + "/proc/wireless"
        procNetDevPath: root.out + "/proc/net_dev"
        procUptimePath: root.out + "/proc/uptime"
        stateDir: root.out + "/state/lares/aerial"
        configPath: root.out + "/config/aerial.jsonc"
        protonPath: "/nonexistent/protonvpn"
        dnsmasqPath: "/nonexistent/dnsmasq"
        protonCachePath: root.out + "/serverlist.json"
        commandTimeoutMs: 1500
    }
    // a third shell on the same state dir: a RESTART with the tunnel still up
    AerialService {
        id: svc3
        live: false
        helperCommand: ["python3", "-I", root.stub, "--log", root.out + "/stub3.log", "--control", root.out + "/control3.jsonl", "--scenario", root.out + "/scenario.json"]
        btSource: null
        upowerEnabled: false
        procWirelessPath: root.out + "/proc/wireless"
        procNetDevPath: root.out + "/proc/net_dev"
        procUptimePath: root.out + "/proc/uptime"
        stateDir: root.out + "/state/lares/aerial"
        configPath: root.out + "/config/aerial.jsonc"
        protonPath: "/nonexistent/protonvpn"
        dnsmasqPath: "/nonexistent/dnsmasq"
        protonCachePath: root.out + "/serverlist.json"
        commandTimeoutMs: 1500
    }
    FileView { id: ctl3File; path: root.out + "/control3.jsonl"; blockWrites: true; printErrors: false; atomicWrites: false }
    property string ctl3Text: ""
    function ctl3(o) {
        root.ctl3Text += JSON.stringify(o) + "\n";
        ctl3File.setText(root.ctl3Text);
    }
    FileView { id: ctl2File; path: root.out + "/control2.jsonl"; blockWrites: true; printErrors: false; atomicWrites: false }
    property string ctl2Text: ""
    function ctl2(o) {
        root.ctl2Text += JSON.stringify(o) + "\n";
        ctl2File.setText(root.ctl2Text);
    }
    // a service that is never live: nothing may run
    AerialService {
        id: idleSvc
        live: false
        helperCommand: ["python3", "-I", root.stub, "--log", root.out + "/idle.log", "--control", root.out + "/idle_ctl.jsonl"]
        btSource: fakeBt
        upowerEnabled: false
        stateDir: root.out + "/idle_state"
        configPath: root.out + "/idle_config/aerial.jsonc"
        protonPath: "/usr/bin/true"
    }
    // nothing set at all but the safe stand-ins: the default must be "not live"
    AerialService {
        id: defaultSvc
        btSource: null
        upowerEnabled: false
        stateDir: root.out + "/default_state"
        configPath: root.out + "/default_config/aerial.jsonc"
        helperCommand: ["python3", "-I", root.stub, "--log", root.out + "/default.log"]
    }
    AerialMock {
        id: mock
        live: false
        notifier: fakeNotifier
        onCue: part => root.cues = root.cues.concat([part])
    }
    function toastsFor(key) { return fakeNotifier.calls.filter(c => c.key === key); }

    // ---- the sequencer ---------------------------------------------------------------------------------------------------------------
    property var steps: []
    property int stepAt: 0
    property bool stepStarted: false
    property bool stepPre: false
    property real stepT0: 0
    Timer {
        id: ticker
        interval: 40
        repeat: true
        onTriggered: root.tick()
    }
    function tick() {
        if (root.stepAt >= root.steps.length) {
            ticker.stop();
            root.finish();
            return;
        }
        const s = root.steps[root.stepAt];
        const now = Date.now();
        if (!root.stepStarted && s.pre && !root.stepPre) {
            // a `pre` (the stub's reply table) lands 250 ms before the `act` that needs it: the stub polls its control file
            root.stepPre = true;
            root.stepT0 = now;
            s.pre();
            return;
        }
        if (root.stepPre && !root.stepStarted && now - root.stepT0 < 250)
            return;
        if (!root.stepStarted) {
            root.stepStarted = true;
            root.stepPre = false;
            root.stepT0 = now;
            if (s.act) {
                try {
                    s.act();
                } catch (e) {
                    root.check(s.n, false, "act threw: " + e);
                    root.stepAt++;
                    root.stepStarted = false;
                    return;
                }
            }
        }
        let done = false, pass = false, detail = "";
        try {
            if (s.until) {
                if (s.until()) { done = true; pass = true; }
                else if (now - root.stepT0 > (s.ms || 5000)) { done = true; detail = s.why ? s.why() : "timed out"; }
            } else if (s.wait !== undefined) {
                if (now - root.stepT0 >= s.wait) { done = true; pass = s.check ? s.check() : true; detail = s.why ? s.why() : "the condition did not hold"; }
            } else {
                done = true;
                pass = s.check ? s.check() : true;
                detail = s.why ? s.why() : "";
            }
        } catch (e) {
            done = true;
            detail = "threw: " + e;
        }
        if (done) {
            root.check(s.n, pass, detail);
            root.stepAt++;
            root.stepStarted = false;
        }
    }

    function net(key) {
        const ns = svc.wifi.networks;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].key === key)
                return ns[i];
        return null;
    }
    function profileOf(s, uuid) {
        for (let i = 0; i < s.wifi.profiles.length; i++)
            if (s.wifi.profiles[i].uuid === uuid)
                return s.wifi.profiles[i];
        return null;
    }
    function allFactsJson(s) {
        return JSON.stringify([s.wifi, s.wired, s.hotspot, s.bt, s.proton, s.health, s.rates, s.usage, s.speed, s.airplane, s.errors, s.config]);
    }
    function osdCount(kind) { return root.osds.filter(o => o.kind === kind).length; }
    function failedFor(prefix) { return root.fails2.filter(f => f.id.indexOf(prefix) === 0); }

    // ---- the scenario ---------------------------------------------------------------------------------------------------------------------
    Component.onCompleted: {
        if (!root.armed) {
            console.log("AS DONE SKIPPED (not armed: no AS_OUT / AS_STUB; this file is run by tools/dev/aerial_service_probe.sh)");
            quitTimer.start();
            return;
        }
        const S = [];
        function step(o) { S.push(o); }

        // ---- A. members, parity, inertness
        step({ n: "parity.service", check: () => Model.missingMembers(svc).length === 0, why: () => "service lacks " + root.j(Model.missingMembers(svc)) });
        step({ n: "parity.mock", check: () => Model.missingMembers(mock).length === 0, why: () => "mock lacks " + root.j(Model.missingMembers(mock)) });
        step({ n: "live.default.false", check: () => defaultSvc.live === false && mock.live === false && defaultSvc.helper.state === "off" });
        step({ n: "idle.inert", act: () => { idleSvc.popupOpen = true; idleSvc.scan(); idleSvc.btSearch(); idleSvc.refresh(); }, wait: 800,
               check: () => idleSvc.helper.state === "off" && idleSvc.serial === 0 && fakeAdapter.discovering === false && idleSvc.errors.length === 0, why: () => root.j([idleSvc.helper, idleSvc.serial, fakeAdapter.discovering]) });

        // ---- B. start the real service against the stub; nothing drawn until the stub speaks
        step({ n: "helper.starts", act: () => { svc.live = true; }, until: () => svc.helper.state === "up", why: () => root.j(svc.helper) });
        step({ n: "facts.empty.before.snapshots", check: () => svc.wifi.networks.length === 0 && svc.wifi.active === null });

        // ---- C. snapshots -> facts; trust on the FIRST run
        step({ n: "send.snapshots", act: () => {
            root.setWireless("wlp47s0", -61);
            root.setNetdev("wlp47s0", 1000, 500);
            root.ctl(root.nmMsg);
            root.ctl(root.devicesMsg());
            root.ctl({ t: "profiles", v: [root.profHome, root.profHome1, root.profEdu, { uuid: "u-eth", id: "Wired", type: "802-3-ethernet", ssid: "" }] });
            root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
            root.ctl(root.wifiMsg(80));
        }, until: () => svc.wifi.active !== null && svc.wifi.networks.length === 3, why: () => root.j([svc.wifi.networks.length, svc.wifi.active]) });
        step({ n: "wifi.networks", check: () => root.j(svc.wifi.networks.map(n => n.key)) === root.j(["Cafe", "Home", "hidden:CC:CC:CC:CC:CC:01"]),
               why: () => root.j(svc.wifi.networks.map(n => n.key)) });
        step({ n: "wifi.active.fields", check: () => svc.wifi.active.key === "Home" && svc.wifi.active.band === "5" && svc.wifi.active.channel === 36 && svc.wifi.active.ip4 === "192.168.1.20" && svc.wifi.active.prefix4 === 24 && svc.wifi.active.gateway4 === "192.168.1.1",
               why: () => root.j(svc.wifi.active) });
        step({ n: "doubles", check: () => root.j(root.profileOf(svc, "u-home").doubles) === root.j(["u-home1"]) && root.net("Home").profileUuids.length === 2, why: () => root.j(svc.wifi.profiles) });
        step({ n: "trust.firstrun.all.trusted", until: () => svc.wifi.profiles.length === 3 && svc.wifi.profiles.every(p => p.trusted), why: () => root.j(svc.wifi.profiles.map(p => [p.uuid, p.trusted])) });
        step({ n: "trust.file.written", until: () => { trustJson.reload(); const t = Model.trustFromJson(trustJson.text()); return t !== null && t["u-home"] === true && t["u-eth"] === true; }, why: () => trustJson.text() });

        // ---- D. hysteresis through the service: noise around a band edge never changes the band
        step({ n: "band.start", check: () => root.net("Home").signalBand === 0, why: () => root.j(root.net("Home").signalBand) });
        step({ n: "band.noise.holds", act: () => {
            const seq = [66, 73, 67, 71, 68, 74, 66, 70];
            for (let i = 0; i < seq.length; i++)
                root.ctl(root.wifiMsg(seq[i]));
        }, wait: 900, check: () => root.net("Home").signalBand === 0 && root.net("Home").signal === 70, why: () => root.j([root.net("Home").signalBand, root.net("Home").signal]) });
        step({ n: "band.clear.drop", act: () => root.ctl(root.wifiMsg(40)), until: () => root.net("Home").signalBand === 2 || root.net("Home").signalBand === 1, why: () => root.j(root.net("Home")) });
        step({ n: "band.restore", act: () => root.ctl(root.wifiMsg(80)), until: () => root.net("Home").signalBand === 0, why: () => root.j(root.net("Home").signalBand) });

        // ---- E. popup open: agent on, scan, pads, catalog, link, health -- and the commands each intent sends
        step({ n: "open.popup", act: () => { svc.popupOpen = true; }, until: () => root.cmds("agent").length >= 1 && root.cmds("scan").length >= 1 && root.cmds("pad").length >= 3, why: () => root.j(root.cmds().map(c => c.cmd)) });
        step({ n: "open.agent.on", check: () => root.cmds("agent")[0].on === true });
        step({ n: "open.pads.all.three", check: () => root.j(root.cmds("pad").map(c => c.pad).sort()) === root.j(["dns", "gateway", "net"]), why: () => root.j(root.cmds("pad").map(c => c.pad)) });
        step({ n: "open.pads.testing", check: () => svc.health.pads.filter(p => p.state === "testing").length === 3 || svc.health.pads.filter(p => p.state === "ok").length >= 1, why: () => root.j(svc.health.pads) });
        step({ n: "open.catalog.asked", until: () => root.cmds("catalog").length === 1, why: () => root.j(root.cmds("catalog")) });
        step({ n: "open.proton.asked", until: () => root.cmds("proton:status").length >= 1 && root.cmds("proton:config").length >= 1, why: () => root.j(root.cmds("proton").map(c => c.action)) });
        step({ n: "open.iwlink.once", until: () => root.cmds("iw_link").length === 1 && root.cmds("iw_link")[0].iface === "wlp47s0", why: () => root.j(root.cmds("iw_link")) });
        step({ n: "iwlink.not.per.snapshot", act: () => { root.ctl(root.wifiMsg(79)); root.ctl(root.wifiMsg(81)); }, wait: 500, check: () => root.cmds("iw_link").length === 1, why: () => root.j(root.cmds("iw_link").length) });
        step({ n: "wifi.dbm.from.proc", until: () => svc.wifi.active && svc.wifi.active.dbm === -61, why: () => root.j(svc.wifi.active && svc.wifi.active.dbm) });
        step({ n: "link.event.fills.active", act: () => root.ctl({ t: "link", iface: "wlp47s0", standard: "he", dbm: -50, rxMbps: 1201, txMbps: 960 }), until: () => svc.wifi.active && svc.wifi.active.standard === "Wi-Fi 6" && svc.wifi.active.rateMbps === 1201, why: () => root.j(svc.wifi.active) });
        step({ n: "catalog.not.again.same.mtime", act: () => { svc.popupOpen = false; }, wait: 300, check: () => root.cmds("agent").some(c => c.on === false), why: () => root.j(root.cmds("agent")) });
        step({ n: "catalog.second.open.same", act: () => { svc.popupOpen = true; }, wait: 800, check: () => root.cmds("catalog").length === 1, why: () => root.j(root.cmds("catalog").length) });

        // intents -> commands
        step({ n: "intent.scan", act: () => { svc.scan(); }, until: () => root.cmds("scan").length >= 2 });
        step({ n: "intent.connect.unknown.open", act: () => { svc.connect("Cafe", {}); }, until: () => root.cmds("add_activate").length === 1, why: () => root.j(root.cmds("add_activate")) });
        step({ n: "intent.connect.unknown.fields", check: () => { const c = root.cmds("add_activate")[0]; return c.ssid === "Cafe" && c.security === "open" && c.iface === "wlp47s0" && c.bssid === "BB:BB:BB:BB:BB:01" && c.hidden === false; }, why: () => root.j(root.cmds("add_activate")[0]) });
        step({ n: "intent.connect.known", act: () => { svc.connect("Home", {}); }, until: () => root.cmds("activate").length === 1 && root.cmds("activate")[0].uuid === "u-home", why: () => root.j(root.cmds("activate")) });
        step({ n: "intent.connect.hidden.needs.name", act: () => { svc.connect("hidden:CC:CC:CC:CC:CC:01", {}); }, until: () => root.failedFor("connect:hidden:").length === 1, why: () => root.j(root.fails2) });
        step({ n: "intent.disconnect", act: () => { svc.disconnect(); }, until: () => root.cmds("disconnect_device").length === 1 && root.cmds("disconnect_device")[0].iface === svc.wifi.iface && root.cmds("deactivate").length === 0 });
        step({ n: "intent.forget", act: () => { svc.forget("u-home1"); }, until: () => root.cmds("delete").length === 1 && root.cmds("delete")[0].uuid === "u-home1" });
        step({ n: "intent.setRadio", act: () => { svc.setRadio(false); }, until: () => root.cmds("wifi_enabled").length === 1 && root.cmds("wifi_enabled")[0].on === false });
        step({ n: "intent.autoconnect", act: () => { svc.setAutoconnect("u-edu", false); svc.setPriority("u-edu", 7); }, until: () => root.cmds("update").length === 2, why: () => root.j(root.cmds("update")) });
        step({ n: "intent.update.patches", check: () => root.j(root.cmds("update").map(c => c.patch)) === root.j([{ autoconnect: false }, { priority: 7 }]), why: () => root.j(root.cmds("update").map(c => c.patch)) });
        step({ n: "intent.mergeDoubles", act: () => { svc.mergeDoubles("u-home", ["u-home", "u-home1", "u-x"]); }, until: () => root.cmds("delete").length === 3, why: () => root.j(root.cmds("delete")) });
        step({ n: "intent.vpnSet", act: () => { svc.vpnSet("netshield", "malware-only"); }, until: () => root.cmds("proton:set").length === 1 && root.cmds("proton:set")[0].args.key === "netshield" });
        step({ n: "intent.testPad.one", act: () => { root.padsBefore = root.cmds("pad").length; svc.testPad("dns"); }, until: () => root.cmds("pad").length === root.padsBefore + 1 && root.cmds("pad")[root.padsBefore].pad === "dns" });
        step({ n: "intent.setTrusted.key", act: () => { svc.setTrusted("Home", false); }, until: () => root.profileOf(svc, "u-home") && root.profileOf(svc, "u-home").trusted === false, why: () => root.j(svc.wifi.profiles) });
        step({ n: "intent.setTrusted.back", act: () => { svc.setTrusted("u-home", true); svc.setTrusted("u-home1", true); }, until: () => root.net("Home").trusted === true });
        step({ n: "radio.back.on", act: () => root.ctl({ t: "nm", running: true, wirelessEnabled: true, wirelessHardwareEnabled: true }), wait: 200 });
        step({ n: "secret.signal", pre: () => root.ctl({ ctl: "reply", key: "secrets", reply: { ok: true, error: null, data: { psk: "hunter2" } } }), act: () => {
            svc.revealSecret("u-home");
        }, until: () => root.secrets.length === 1 && root.secrets[0].uuid === "u-home" && root.secrets[0].text === "hunter2", why: () => root.j(root.secrets) });
        step({ n: "secret.never.stored", check: () => root.allFactsJson(svc).indexOf("hunter2") < 0 && JSON.stringify(svc.errors).indexOf("hunter2") < 0 });

        // ---- F. errors on the right part
        step({ n: "error.setup.disconnected", act: () => root.ctl(root.activeMsg([])), until: () => svc.wifi.active === null });
        step({ n: "error.connect.part", pre: () => root.ctl({ ctl: "reply", key: "activate", reply: { ok: false, error: "Secrets were required, but not provided." } }), act: () => {
            svc.connect("Home", {});
        }, until: () => svc.errors.some(e => e.part === "net:Home"), why: () => root.j(svc.errors) });
        step({ n: "error.failed.signal", check: () => root.failedFor("connect:Home").length === 1 && root.failedFor("connect:Home")[0].text.indexOf("Secrets") === 0, why: () => root.j(root.fails2) });
        step({ n: "error.net.state.needsSecret", until: () => root.net("Home").state === "needsSecret" && root.net("Home").failReason.indexOf("Secrets") === 0, why: () => root.j(root.net("Home")) });
        // ---- F2. an error is ONE toast: its words, its way out; a repeat replaces; a dismissed one stays gone; the cue fires each time
        step({ n: "toast.one.each", check: () => root.toastsFor("fail-connect:Home").length === 1 && root.toastsFor("fail-connect:Home")[0].spec.title === "Could not join Home"
                                                 && root.toastsFor("fail-connect:Home")[0].spec.body.indexOf("Secrets") === 0 && root.toastsFor("fail-connect:Home")[0].spec.body.indexOf("Check the password") > 0, why: () => root.j(fakeNotifier.calls) });
        step({ n: "toast.cue.once", check: () => root.cues.filter(c => c === "net:Home").length === 1, why: () => root.j(root.cues) });
        step({ n: "toast.repeat.same.quiet", pre: () => root.ctl({ ctl: "reply", key: "activate", reply: { ok: false, error: "Secrets were required, but not provided." } }), act: () => {
            svc.connect("Home", {});
        }, until: () => root.failedFor("connect:Home").length === 2, why: () => root.j(root.fails2) });
        step({ n: "toast.dismissed.stays.gone", check: () => root.toastsFor("fail-connect:Home").length === 1 && root.cues.filter(c => c === "net:Home").length === 2, why: () => root.j([fakeNotifier.calls, root.cues]) });
        step({ n: "toast.repeat.replaces", pre: () => root.ctl({ ctl: "reply", key: "activate", reply: { ok: false, error: "The access point is out of range." } }), act: () => {
            svc.connect("Home", {});
        }, until: () => root.failedFor("connect:Home").length === 3, why: () => root.j(root.fails2) });
        step({ n: "toast.repeat.one.key", check: () => root.toastsFor("fail-connect:Home").length === 2 && root.toastsFor("fail-connect:Home")[1].spec.body.indexOf("out of range") >= 0
                                                 && fakeNotifier.calls.filter(c => c.key.indexOf("connect:Home") >= 0).map(c => c.key).filter((k, i, a) => a.indexOf(k) === i).length === 1, why: () => root.j(fakeNotifier.calls.map(c => c.key)) });
        step({ n: "error.has.way", check: () => svc.errors.filter(e => e.part === "net:Home")[0].way.length > 0 });
        step({ n: "error.radio.part", pre: () => { root.ctl({ ctl: "reply", key: "wifi_enabled", reply: { ok: false, error: "Wi-Fi is hardware blocked" } }); root.ctl({ t: "nm", running: true, wirelessEnabled: false, wirelessHardwareEnabled: true }); }, act: () => {
            svc.setRadio(true);
        }, until: () => svc.errors.some(e => e.part === "dip.wifi" && e.text === "Wi-Fi is hardware blocked"), why: () => root.j(svc.errors) });
        step({ n: "error.timeout.part", pre: () => { root.ctl({ ctl: "reply", key: "wifi_enabled", reply: { ok: true } }); root.ctl({ ctl: "reply", key: "update", reply: { ok: false, error: "no such profile" } }); }, act: () => {
            svc.setPriority("u-edu", 9);
        }, until: () => svc.errors.some(e => e.part === "mem" && e.text === "no such profile"), why: () => root.j(svc.errors) });
        step({ n: "error.pad.part", pre: () => root.ctl({ ctl: "reply", key: "pad", reply: { ok: false, error: "dns is down" } }), act: () => {
            svc.testPad("dns");
        }, until: () => svc.errors.some(e => e.part === "pad.dns"), why: () => root.j(svc.errors) });
        step({ n: "error.dismiss", act: () => { svc.dismissError("testPad:dns"); }, check: () => !svc.errors.some(e => e.part === "pad.dns") });
        step({ n: "toast.dismiss.withdraws", check: () => fakeNotifier.gone.indexOf("fail-testPad:dns") >= 0 && root.toastsFor("fail-testPad:dns").length === 1, why: () => root.j([fakeNotifier.gone, fakeNotifier.calls.map(c => c.key)]) });
        step({ n: "error.cause.gone.net", pre: () => root.ctl({ ctl: "reply", key: "activate", reply: { ok: true } }), act: () => {
            root.ctl({ ctl: "reply", key: "pad", reply: { ok: true } });
            root.ctl({ t: "nm", running: true, wirelessEnabled: true, wirelessHardwareEnabled: true });
            root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
        }, until: () => !svc.errors.some(e => e.part === "net:Home"), why: () => root.j(svc.errors) });
        step({ n: "toast.cause.gone.withdraws", check: () => fakeNotifier.gone.indexOf("fail-connect:Home") >= 0, why: () => root.j(fakeNotifier.gone) });
        step({ n: "error.cause.gone.radio", check: () => !svc.errors.some(e => e.part === "dip.wifi"), why: () => root.j(svc.errors) });
        step({ n: "error.scan.part", pre: () => root.ctl({ ctl: "reply", key: "scan", reply: { ok: false, error: "scan refused" } }), act: () => {
            svc.scan();
        }, until: () => svc.errors.some(e => e.id === "scan:" && e.text === "scan refused"), why: () => root.j(svc.errors) });

        // ---- G. rates and usage from /proc, no fork; the key change writes the file; a counter that went backwards counts from 0; a reboot
        step({ n: "rates.baseline", wait: 2200 });
        step({ n: "rates.beat", act: () => { root.maxRx = 0; root.setNetdev("wlp47s0", 1000 + 50000, 500 + 10000); }, until: () => svc.rates.iface === "wlp47s0" && root.maxRx > 0, why: () => root.j(svc.rates) });
        step({ n: "dummy.not.the.network", act: () => {
            // Proton's dummy takes the PRIMARY (S0): an ethernet-looking device, default route, carrier -- never "the network"
            root.ctl(root.activeMsg([root.act("u-ks", "pvpn-killswitch", "dummy", "pvpnksintrf0", true), root.act("u-home", "Home", "802-11-wireless", "wlp47s0", false)]));
        }, wait: 1700, check: () => svc.wifi.active && svc.wifi.active.key === "Home" && svc.wired.jacks.every(j => j.iface !== "pvpnksintrf0") && svc.rates.iface === "wlp47s0" && svc.usage.current.key === "Home" && svc.proton.state === "down",
               why: () => root.j([svc.wifi.active && svc.wifi.active.key, svc.wired.jacks, svc.rates, svc.usage.current, svc.proton.state]) });
        step({ n: "back.to.home", act: () => root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)])), wait: 300, check: () => svc.wifi.active !== null });
        step({ n: "usage.counts.deltas", until: () => svc.usage.todayBytes >= 60000, why: () => root.j(svc.usage) });
        step({ n: "usage.attributed.to.network", check: () => svc.usage.byNetwork.length === 1 && svc.usage.byNetwork[0].key === "Home" && svc.usage.current.key === "Home" && svc.usage.current.bytes === svc.usage.todayBytes, why: () => root.j(svc.usage) });
        step({ n: "usage.counter.backwards", act: () => { root.setNetdev("wlp47s0", 700, 100); }, until: () => svc.usage.todayBytes >= 60000 + 800, why: () => root.j(svc.usage.todayBytes) });
        step({ n: "usage.key.change.writes", act: () => {
            root.ctl(root.activeMsg([root.act("u-edu", "eduroam", "802-11-wireless", "wlp47s0", true)]));
        }, until: () => { usageJson.reload(); const t = Model.usageFromJson(usageJson.text()); return Object.keys(t.days).length === 1; }, why: () => usageJson.text() });
        step({ n: "usage.file.holds.bytes", check: () => { usageJson.reload(); const t = Model.usageFromJson(usageJson.text()); const d = t.days[Object.keys(t.days)[0]]; return d.Home >= 60000; }, why: () => usageJson.text() });
        step({ n: "usage.reboot.starts", act: () => {
            // a "reboot": a second shell on the same state dir reads the file; the counters start over
            root.setNetdev("wlp47s0", 5, 5);
            svc2.popupOpen = true;
            svc2.live = true;
        }, until: () => svc2.helper.state === "up", why: () => root.j(svc2.helper) });
        step({ n: "usage.reboot.reads.file", act: () => {
            root.ctl2({ t: "nm", running: true, wirelessEnabled: true, wirelessHardwareEnabled: true });
            root.ctl2(root.devicesMsg());
            root.ctl2({ t: "profiles", v: [root.profHome, root.profEdu] });
            root.ctl2(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
            root.ctl2(root.wifiMsg(80));
        }, until: () => svc2.wifi.active !== null && svc2.usage.todayBytes >= 60000, why: () => root.j([svc2.wifi.active, svc2.usage.todayBytes, usageJson.text()]) });
        step({ n: "usage.reboot.baseline.adds.nothing", wait: 2500, check: () => { const t = Model.usageFromJson(usageJson.text()); let sum = 0; const d = t.days[Object.keys(t.days)[0]]; for (const k in d) sum += d[k]; root.fileToday = sum; return svc2.usage.todayBytes === sum; }, why: () => root.j([svc2.usage.todayBytes, root.fileToday]) });
        step({ n: "usage.reboot.counts.only.new.bytes", act: () => { root.setNetdev("wlp47s0", 105, 5); }, until: () => svc2.usage.todayBytes === root.fileToday + 100, why: () => root.j([svc2.usage.todayBytes, root.fileToday]) });
        step({ n: "trust.later.run.new.profile.public", act: () => {
            root.ctl2({ t: "profiles", v: [root.profHome, root.profEdu, root.profile("u-new", "NewNet", "NewNet", {})] });
        }, until: () => svc2.wifi.profiles.length === 3, why: () => root.j(svc2.wifi.profiles) });
        step({ n: "trust.later.run.old.trusted.new.public", check: () => { const p = id => root.profileOf(svc2, id); return p("u-home").trusted === true && p("u-edu").trusted === true && p("u-new").trusted === false; }, why: () => root.j(svc2.wifi.profiles.map(p => [p.uuid, p.trusted])) });
        step({ n: "svc2.stops", act: () => { svc2.live = false; }, check: () => svc2.helper.state === "off" });

        // ---- G2. the keyring: locked at the start (the boot lock), Proton's own reads are refused; open, they are asked again by themselves
        step({ n: "keyring.locked.is.a.fact", act: () => {
            root.padsBefore = root.cmds("proton:status").length;
            root.ctl({ t: "keyring", locked: true });
        }, until: () => svc.proton.locked === true, why: () => root.j(svc.proton) });
        step({ n: "keyring.locked.asks.nothing", wait: 600, check: () => root.cmds("proton:status").length === root.padsBefore, why: () => root.j(root.cmds("proton").length) });
        step({ n: "keyring.open.asks.again", act: () => {
            root.confBefore = root.cmds("proton:config").length;
            root.ctl({ t: "keyring", locked: false });
        }, until: () => svc.proton.locked === false && root.cmds("proton:status").length === root.padsBefore + 1 && root.cmds("proton:config").length === root.confBefore + 1,
               why: () => root.j([svc.proton, root.cmds("proton").map(c => c.action)]) });

        // ---- H. the auto-tunnel: trusted -> nothing; public + portal -> waits; the portal gone + NET ok -> raises; the OSD
        step({ n: "auto.trusted.no.vpn", act: () => {
            root.ctl({ ctl: "reply", key: "proton:status", reply: { ok: true, data: {} } });
            root.ctl({ t: "pad", id: "net", state: "ok", detail: "online", ms: 100 });
            root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
        }, wait: 1500, check: () => root.cmds("proton:connect").length === 0 && svc.proton.waiting === "" && svc.proton.signedIn === "yes", why: () => root.j([root.cmds("proton:connect"), svc.proton.waiting, svc.proton.signedIn]) });
        step({ n: "auto.public.joined", act: () => {
            // a NEW profile is Public: join Cafe (added after the first run, so untrusted)
            root.ctl({ t: "profiles", v: [root.profHome, root.profHome1, root.profEdu, root.profile("u-cafe", "Cafe", "Cafe", { security: "open" })] });
            root.ctl(root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true)]));
            root.ctl(root.wifiMsg(80, "BB:BB:BB:BB:BB:01"));
        }, until: () => svc.wifi.active && svc.wifi.active.key === "Cafe" && root.net("Cafe").trusted === false && root.net("Cafe").known, why: () => root.j([svc.wifi.active, root.net("Cafe")]) });
        step({ n: "auto.portal.waits", act: () => {
            root.ctl({ t: "portal", present: true, url: "http://portal.example/login" });
            root.ctl({ t: "pad", id: "net", state: "warn", detail: "Log in first", ms: 90 });
        }, wait: 1500, check: () => svc.proton.waiting === "portal" && root.cmds("proton:connect").length === 0, why: () => root.j([svc.proton.waiting, root.cmds("proton:connect"), svc.health]) });
        step({ n: "auto.portal.up.NET.ok.still.waits", act: () => root.ctl({ t: "pad", id: "net", state: "ok", detail: "online", ms: 90 }), wait: 1200, check: () => root.cmds("proton:connect").length === 0 && svc.proton.waiting === "portal", why: () => root.j([root.cmds("proton:connect"), svc.proton.waiting]) });
        step({ n: "auto.raises.after.portal", act: () => root.ctl({ t: "portal", present: false, url: "" }), until: () => root.cmds("proton:connect").length === 1, why: () => root.j([root.cmds("proton:connect"), svc.proton.waiting, svc.health]) });
        step({ n: "auto.raises.once", wait: 1500, check: () => root.cmds("proton:connect").length === 1 });
        step({ n: "auto.tunnel.comes.up", act: () => root.ctl(root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true),
                { uuid: "u-p", id: "ProtonVPN NL#799", type: "wireguard", devices: ["proton0"], state: "activated", vpn: true, default4: false, default6: false }])),
               until: () => svc.proton.state === "up" && svc.proton.server.name === "NL#799" && svc.wifi.active.key === "Cafe", why: () => root.j([svc.proton, svc.wifi.active]) });
        step({ n: "auto.osd.once", until: () => root.osdCount("autoTunnel") === 1, why: () => root.j(root.osds) });
        step({ n: "auto.config.off.honoured", act: () => {
            svc.vpnDisconnect();
            root.ctl(root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true)]));
        }, wait: 1500, check: () => root.cmds("proton:connect").length === 1, why: () => root.j(root.cmds("proton:connect").length) });
        step({ n: "auto.setAutoTunnel.writes.file", act: () => { svc.setAutoTunnel(false); }, until: () => svc.config.autoTunnel === false && svc.proton.autoTunnel === false, why: () => root.j(svc.config) });
        step({ n: "auto.config.file.keeps.comments", check: () => { cfgFile.reload(); return cfgFile.text().indexOf("// the probe") >= 0 && cfgFile.text().indexOf('"autoTunnel": false') >= 0; }, why: () => cfgFile.text() });
        step({ n: "intent.openPortal.uses.the.stub", act: () => { svc.openPortal(); }, until: () => { openLog.reload(); return openLog.text().indexOf("http://") >= 0; }, why: () => openLog.text() });
        step({ n: "auto.setAutoTunnel.back", act: () => { svc.setAutoTunnel(true); }, until: () => svc.config.autoTunnel === true });

        // ---- H2. the globe's toggle: `proton.fastest` is true for a tunnel asked for with Proton's own pick, remembered across a restart
        step({ n: "fast.default.false", check: () => svc.proton.fastest === false });
        step({ n: "fast.connect.sends.and.lands", act: () => { root.padsBefore = root.cmds("proton:connect").length; svc.vpnConnect({}); }, until: () => root.cmds("proton:connect").length === root.padsBefore + 1 && root.cmds("proton:connect")[root.padsBefore].args.country === undefined, why: () => root.j(root.cmds("proton:connect")) });
        step({ n: "fast.connecting.is.fastest", act: () => root.ctl(root.tunnelMsg("NL#800", "activating")), until: () => svc.proton.state === "connecting" && svc.proton.fastest === true, why: () => root.j(svc.proton) });
        step({ n: "fast.up.is.fastest", act: () => root.ctl(root.tunnelMsg("NL#800")), until: () => svc.proton.state === "up" && svc.proton.server.name === "NL#800" && svc.proton.fastest === true, why: () => root.j(svc.proton) });
        step({ n: "fast.state.file", until: () => { vpnJson.reload(); return vpnJson.text().indexOf('"fastestServer":"NL#800"') >= 0; }, why: () => vpnJson.text() });
        step({ n: "fast.restart.same.server.is.fastest", act: () => { svc3.live = true; }, until: () => svc3.helper.state === "up", why: () => root.j(svc3.helper) });
        step({ n: "fast.restart.facts", act: () => {
            root.ctl3({ t: "nm", running: true, wirelessEnabled: true, wirelessHardwareEnabled: true });
            root.ctl3(root.devicesMsg());
            root.ctl3(root.tunnelMsg("NL#800"));
        }, until: () => svc3.proton.state === "up" && svc3.proton.fastest === true, why: () => root.j(svc3.proton) });
        step({ n: "fast.restart.other.server.is.not", act: () => root.ctl3(root.tunnelMsg("NL#12")), until: () => svc3.proton.state === "up" && svc3.proton.server.name === "NL#12" && svc3.proton.fastest === false, why: () => root.j(svc3.proton) });
        step({ n: "fast.svc3.stops", act: () => { svc3.live = false; }, check: () => svc3.helper.state === "off" });
        step({ n: "fast.country.is.not", act: () => { root.padsBefore = root.cmds("proton:connect").length; svc.vpnConnect({ country: "US" }); root.ctl(root.tunnelMsg("US#12")); },
               until: () => root.cmds("proton:connect").length === root.padsBefore + 1 && svc.proton.server.name === "US#12" && svc.proton.state === "up" && svc.proton.fastest === false, why: () => root.j([svc.proton, root.cmds("proton:connect").slice(-1)]) });
        step({ n: "fast.country.clears.file", until: () => { vpnJson.reload(); return vpnJson.text().indexOf('"fastestServer":""') >= 0; }, why: () => vpnJson.text() });
        step({ n: "fast.again", act: () => { svc.vpnConnect({}); root.ctl(root.tunnelMsg("NL#801")); }, until: () => svc.proton.server && svc.proton.server.name === "NL#801" && svc.proton.fastest === true, why: () => root.j(svc.proton) });
        step({ n: "fast.disconnect.is.not", act: () => { svc.vpnDisconnect(); root.ctl(root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true)])); }, until: () => svc.proton.state === "down" && svc.proton.fastest === false, why: () => root.j(svc.proton) });
        step({ n: "fast.disconnect.clears.file", until: () => { vpnJson.reload(); return vpnJson.text().indexOf('"fastestServer":""') >= 0; }, why: () => vpnJson.text() });
        step({ n: "fast.random.is.not.fastest", act: () => { svc.vpnConnect({ random: true }); root.ctl(root.tunnelMsg("NL#802")); }, until: () => svc.proton.state === "up" && svc.proton.server.name === "NL#802", why: () => root.j(svc.proton) });
        step({ n: "fast.random.stays.false", wait: 500, check: () => svc.proton.fastest === false, why: () => root.j(svc.proton) });
        step({ n: "fast.cleanup", act: () => { svc.vpnDisconnect(); root.ctl(root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true)])); }, until: () => svc.proton.state === "down", why: () => root.j(svc.proton) });

        // ---- H3. error tolerance: a pad that failed is asked again by itself, popup open or not, and shows no `testing` while it is
        step({ n: "retest.fail.published", pre: () => { root.ctl({ ctl: "reply", key: "pad", reply: root.padReply("fail") }); }, act: () => {
            svc.popupOpen = false;      // the re-test is the service's own: the popup need not be open
            svc.padRetryFirstMs = 400; svc.padRetryEveryMs = 700;
            root.padsBefore = root.cmds("pad").length;
            root.ctl({ t: "pad", id: "gateway", state: "fail", detail: "192.168.1.1 does not answer", ms: 1000 });
        }, until: () => root.gwPad() === "fail", why: () => root.gwPad() });
        step({ n: "retest.asks.again.by.itself", act: () => { root.gwStates = []; }, until: () => root.cmds("pad").length > root.padsBefore && root.cmds("pad")[root.padsBefore].pad === "gateway", ms: 4000, why: () => root.j(root.cmds("pad").slice(root.padsBefore)) });
        step({ n: "retest.still.failing.stays.fail.no.testing", wait: 1200, check: () => root.gwPad() === "fail" && root.gwStates.indexOf("testing") < 0, why: () => root.j(root.gwStates) });
        step({ n: "retest.keeps.asking.while.it.fails", check: () => root.cmds("pad").length - root.padsBefore >= 2, why: () => root.j(root.cmds("pad").slice(root.padsBefore)) });
        step({ n: "retest.answers.ok", pre: () => { root.ctl({ ctl: "reply", key: "pad", reply: root.padReply("ok") }); }, until: () => root.gwPad() === "ok", ms: 4000, why: () => root.j([root.gwPad(), root.gwStates]) });
        step({ n: "retest.ok.never.showed.testing", check: () => root.gwStates.indexOf("testing") < 0 && root.gwStates.indexOf("ok") >= 0, why: () => root.j(root.gwStates) });
        step({ n: "retest.ok.goes.on.to.the.pads.that.never.ran", wait: 900, check: () => root.cmds("pad").slice(root.padsBefore).map(c => c.pad).indexOf("dns") >= 0, why: () => root.j(root.cmds("pad").slice(root.padsBefore)) });
        step({ n: "retest.stops.when.ok", act: () => { root.padsBefore = root.cmds("pad").length; }, wait: 2200, check: () => root.cmds("pad").length === root.padsBefore, why: () => root.j(root.cmds("pad").slice(root.padsBefore)) });
        step({ n: "retest.users.click.shows.testing", act: () => { root.gwStates = []; svc.testPad("gateway"); }, until: () => root.gwStates.indexOf("testing") >= 0, why: () => root.j(root.gwStates) });
        // a connection change takes the failed pad away with its re-test: nothing is asked for the connection that is gone
        step({ n: "retest.connection.change.setup", pre: () => { root.ctl({ ctl: "reply", key: "pad", reply: root.padReply("fail") }); }, act: () => {
            svc.padRetryFirstMs = 1500;
            root.ctl({ t: "pad", id: "gateway", state: "fail", detail: "x", ms: 1 });
        }, until: () => root.gwPad() === "fail", why: () => root.gwPad() });
        step({ n: "retest.connection.change", act: () => {
            root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
            root.ctl(root.wifiMsg(80, "AA:AA:AA:AA:AA:01"));
        }, until: () => svc.wifi.active && svc.wifi.active.key === "Home" && root.gwPad() === "unknown", why: () => root.j([svc.wifi.active, root.gwPad()]) });
        step({ n: "retest.connection.change.nothing.asked", act: () => { root.padsBefore = root.cmds("pad").length; }, wait: 2400, check: () => root.cmds("pad").length === root.padsBefore, why: () => root.j(root.cmds("pad").slice(root.padsBefore)) });
        step({ n: "retest.restore", pre: () => { root.ctl({ ctl: "reply", key: "pad", reply: { ok: true } }); }, act: () => { svc.padRetryFirstMs = 20000; svc.padRetryEveryMs = 60000; }, wait: 100 });

        // ---- I. health is never tested while the popup is closed
        step({ n: "health.not.while.closed", act: () => {
            svc.popupOpen = false;
        }, wait: 300, check: () => true });
        step({ n: "health.closed.connection.change", act: () => {
            root.padsBefore = root.cmds("pad").length;
            root.ctl(root.activeMsg([root.act("u-home", "Home", "802-11-wireless", "wlp47s0", true)]));
            root.ctl(root.wifiMsg(80, "AA:AA:AA:AA:AA:01"));
        }, wait: 1000, check: () => root.cmds("pad").length === root.padsBefore && svc.health.pads.filter(p => p.id === "net")[0].state === "unknown", why: () => root.j([root.padsBefore, root.cmds("pad").length, svc.health.pads]) });
        step({ n: "health.reopen.tests", act: () => { svc.popupOpen = true; }, until: () => root.cmds("pad").length > root.padsBefore, why: () => root.j(root.cmds("pad").length) });

        // ---- J. the agent and the pairing prompt
        step({ n: "agent.prompt", act: () => root.ctl({ t: "agent", rid: 5, kind: "confirm", device: "AA:BB:CC:00:00:10", code: "123456" }), until: () => svc.bt.prompt !== null && svc.bt.prompt.rid === 5 && svc.bt.prompt.kind === "confirm" && svc.bt.prompt.code === "123456", why: () => root.j(svc.bt.prompt) });
        step({ n: "agent.answer", act: () => { svc.btAnswer(5, true, null); }, until: () => root.cmds("agent_reply").length === 1 && root.cmds("agent_reply")[0].rid === 5 && root.cmds("agent_reply")[0].accept === true && svc.bt.prompt === null, why: () => root.j([root.cmds("agent_reply"), svc.bt.prompt]) });

        // ---- K. Bluetooth: devices, rings, intents, deadlines, low battery
        step({ n: "bt.add.devices", act: () => {
            root.addBtDev({ address: "AA:BB:CC:00:00:01", name: "Earbuds", deviceName: "Earbuds", icon: "audio-headset", connected: true, paired: true, batteryAvailable: true, battery: 0.0 });
            root.addBtDev({ address: "AA:BB:CC:00:00:02", name: "Pixel", icon: "phone", paired: true });
            root.addBtDev({ address: "AA:BB:CC:00:00:03", name: "Stranger", icon: "input-mouse" });
        }, until: () => svc.bt.devices.length === 2, why: () => root.j(svc.bt.devices) });
        step({ n: "bt.rings", check: () => root.j(svc.bt.devices.map(d => [d.address, d.ring, d.kind])) === root.j([["AA:BB:CC:00:00:01", "inner", "earbuds"], ["AA:BB:CC:00:00:02", "middle", "phone"]]), why: () => root.j(svc.bt.devices) });
        step({ n: "bt.present.powered", check: () => svc.bt.present === true && svc.bt.powered === true && svc.bt.name === "laptop" });
        step({ n: "bt.search", act: () => { svc.btSearch(); svc.btVisible(); }, until: () => fakeAdapter.discovering && fakeAdapter.discoverable && svc.bt.searchUntilMs > 0 && svc.bt.visibleUntilMs > 0, why: () => root.j([fakeAdapter.discovering, svc.bt]) });
        step({ n: "bt.search.deadline.is.config", check: () => { const n = Date.now(); return svc.bt.searchUntilMs - n > 3000 && svc.bt.searchUntilMs - n <= 5000 && svc.bt.visibleUntilMs - n > 8000 && svc.bt.visibleUntilMs - n <= 10000 && fakeAdapter.discoverableTimeout === 10; }, why: () => root.j([svc.bt.searchUntilMs - Date.now(), svc.bt.visibleUntilMs - Date.now(), fakeAdapter.discoverableTimeout]) });
        step({ n: "bt.stranger.seen.while.searching", until: () => svc.bt.devices.some(d => d.address === "AA:BB:CC:00:00:03" && d.ring === "outer"), why: () => root.j(svc.bt.devices.map(d => [d.address, d.ring])) });
        step({ n: "bt.search.ends", until: () => !fakeAdapter.discovering && svc.bt.searchUntilMs === 0 && svc.bt.discovering === false && fakeAdapter.discoverable === true, ms: 8000, why: () => root.j([fakeAdapter.discovering, fakeAdapter.discoverable, svc.bt.searchUntilMs]) });
        step({ n: "bt.visible.ends", until: () => !fakeAdapter.discoverable && svc.bt.visibleUntilMs === 0 && svc.bt.discoverable === false, ms: 9000, why: () => root.j([fakeAdapter.discoverable, svc.bt.visibleUntilMs]) });
        step({ n: "bt.intents", act: () => {
            svc.btDisconnect("AA:BB:CC:00:00:01"); svc.btConnect("AA:BB:CC:00:00:02"); svc.btPair("AA:BB:CC:00:00:03"); svc.btTrust("AA:BB:CC:00:00:02", true);
            svc.btBlock("AA:BB:CC:00:00:02", true); svc.btRename("AA:BB:CC:00:00:02", "My Pixel"); svc.btCancelPair("AA:BB:CC:00:00:03"); svc.btForget("AA:BB:CC:00:00:03");
        }, check: () => root.j(root.btDev("AA:BB:CC:00:00:01").calls) === root.j(["disconnect"]) && root.j(root.btDev("AA:BB:CC:00:00:02").calls) === root.j(["connect"]) && root.j(root.btDev("AA:BB:CC:00:00:03").calls) === root.j(["pair", "cancelPair", "forget"])
               && root.btDev("AA:BB:CC:00:00:02").trusted && root.btDev("AA:BB:CC:00:00:02").blocked && root.btDev("AA:BB:CC:00:00:02").name === "My Pixel", why: () => root.j(fakeBt.devices.map(d => d.calls)) });
        step({ n: "bt.intent.unknown.device.fails.on.part", act: () => { svc.btConnect("FF:FF:FF:FF:FF:FF"); }, check: () => svc.errors.some(e => e.part === "bt:FF:FF:FF:FF:FF:FF"), why: () => root.j(svc.errors) });
        step({ n: "bt.connect.that.never.lands.times.out", act: () => { root.btDev("AA:BB:CC:00:00:02").blocked = false; svc.btConnect("AA:BB:CC:00:00:02"); }, until: () => svc.errors.some(e => e.part === "bt:AA:BB:CC:00:00:02" && e.id === "btConnect:AA:BB:CC:00:00:02"), ms: 8000, why: () => root.j(svc.errors) });
        // low battery: 20 / 10, once per crossing, re-armed above 25
        step({ n: "low.setup", act: () => { root.osds = []; const d = root.btDev("AA:BB:CC:00:00:01"); d.connected = true; d.battery = 0.5; }, wait: 300, check: () => root.osdCount("btLow") === 0 });
        step({ n: "low.20.fires", act: () => { root.btDev("AA:BB:CC:00:00:01").battery = 0.19; }, until: () => root.osdCount("btLow") === 1 && root.osds.filter(o => o.kind === "btLow")[0].payload.battery === 19, why: () => root.j(root.osds) });
        step({ n: "low.stays.quiet.same.band", act: () => { root.btDev("AA:BB:CC:00:00:01").battery = 0.15; root.btDev("AA:BB:CC:00:00:01").battery = 0.12; }, wait: 700, check: () => root.osdCount("btLow") === 1, why: () => root.j(root.osds) });
        step({ n: "low.10.fires", act: () => { root.btDev("AA:BB:CC:00:00:01").battery = 0.09; }, until: () => root.osdCount("btLow") === 2 && root.osds.filter(o => o.kind === "btLow")[1].payload.name === "Earbuds", why: () => root.j(root.osds) });
        step({ n: "low.rearm.above.25", act: () => { root.btDev("AA:BB:CC:00:00:01").battery = 0.4; }, wait: 400, check: () => root.osdCount("btLow") === 2 });
        step({ n: "low.fires.again.after.rearm", act: () => { root.btDev("AA:BB:CC:00:00:01").battery = 0.18; }, until: () => root.osdCount("btLow") === 3, why: () => root.j(root.osds) });

        // ---- L. airplane: takes both radios down and gives back exactly what was on
        step({ n: "airplane.on", act: () => {
            root.btDev("AA:BB:CC:00:00:01").battery = 0.9;
            svc.setAirplane(true);
        }, until: () => root.cmds("wifi_enabled").length >= 3 && root.cmds("wifi_enabled")[root.cmds("wifi_enabled").length - 1].on === false && fakeAdapter.enabled === false, why: () => root.j([root.cmds("wifi_enabled"), fakeAdapter.enabled]) });
        step({ n: "airplane.remembered", act: () => root.ctl({ t: "nm", running: true, wirelessEnabled: false, wirelessHardwareEnabled: true }), until: () => svc.airplane.on === true && svc.airplane.remembered.wifi === true && svc.airplane.remembered.bt === true, why: () => root.j([svc.airplane, svc.wifi.radioOn, svc.bt.powered]) });
        step({ n: "airplane.off.gives.back", act: () => { svc.setAirplane(false); }, until: () => fakeAdapter.enabled === true && root.cmds("wifi_enabled")[root.cmds("wifi_enabled").length - 1].on === true, why: () => root.j([fakeAdapter.enabled, root.cmds("wifi_enabled")]) });
        step({ n: "airplane.off.state", act: () => root.ctl({ t: "nm", running: true, wirelessEnabled: true, wirelessHardwareEnabled: true }), until: () => svc.airplane.on === false && svc.airplane.remembered.wifi === false, why: () => root.j(svc.airplane) });
        step({ n: "airplane.memory.wifi.was.off", act: () => {
            root.ctl({ t: "nm", running: true, wirelessEnabled: false, wirelessHardwareEnabled: true });
        }, until: () => svc.wifi.radioOn === false, why: () => root.j(svc.wifi.radioOn) });
        step({ n: "airplane.on.with.wifi.already.off", act: () => { svc.setAirplane(true); }, until: () => fakeAdapter.enabled === false && svc.airplane.remembered.wifi === false && svc.airplane.remembered.bt === true, why: () => root.j([svc.airplane, fakeAdapter.enabled]) });
        step({ n: "airplane.back.keeps.wifi.off", act: () => { svc.setAirplane(false); }, until: () => fakeAdapter.enabled === true && root.cmds("wifi_enabled")[root.cmds("wifi_enabled").length - 1].on === false, why: () => root.j([fakeAdapter.enabled, root.cmds("wifi_enabled").slice(-2)]) });

        // ---- M. the helper dies and comes back
        step({ n: "helper.dies", act: () => root.ctl({ ctl: "exit" }), until: () => svc.helper.state === "failed", why: () => root.j(svc.helper) });
        step({ n: "helper.restarts", until: () => svc.helper.state === "up", ms: 8000, why: () => root.j(svc.helper) });

        // ---- N. the mock: same members, every scenario's facts, its intents, failNext
        step({ n: "mock.live", act: () => { mock.live = true; mock.settleMs = 60; }, check: () => mock.helper.state === "up" });
        const sc = { home: m => m.wifi.networks.length === 7 && m.wifi.active.key === "Home-5G" && m.wifi.networks.filter(n => n.connected).length === 1 && m.wifi.profiles.length === 6,
                     crowd: m => m.wifi.networks.length >= 34 && m.wifi.networks.filter(n => n.hidden).length === 2 && m.wifi.networks.some(n => n.bands.length === 2),
                     airplane: m => m.wifi.radioOn === false && m.bt.powered === false && m.airplane.on === true,
                     hotspot: m => m.hotspot.active === true && m.hotspot.clients.length === 2 && m.wifi.active === null && m.hotspot.uplink === "cable",
                     vpn: m => m.proton.state === "up" && m.proton.server.country === "NL" && m.proton.server.city === "Amsterdam",
                     portal: m => m.health.portal.present === true && m.health.pads[4].state === "warn" && m.wifi.active.key === "Cafe-Free" && m.wifi.active.ip4 !== "",
                     pairing: m => m.bt.prompt !== null && m.bt.prompt.kind === "confirm" && m.bt.devices.some(d => d.pairing),
                     earbuds: m => m.bt.devices.some(d => d.kind === "earbuds" && d.ring === "inner" && d.parts.left === 72 && d.parts.charging === true),
                     nowifi: m => m.wifi.present === false && m.wifi.networks.length === 0 && m.bt.present === false,
                     errors: m => m.errors.length === 3 && m.errors.some(e => e.part === "net:Cafe-Free") };
        for (const name of Object.keys(sc)) {
            step({ n: "mock.scenario." + name, act: () => { mock.scenario = name; }, check: () => sc[name](mock), why: () => root.j([mock.wifi.networks.length, mock.wifi.active, mock.bt.devices.length, mock.errors.length, mock.proton.state]) });
        }
        step({ n: "mock.scenarios.list", check: () => root.j(Object.keys(sc)) === root.j(["home", "crowd", "airplane", "hotspot", "vpn", "portal", "pairing", "earbuds", "nowifi", "errors"]) });
        step({ n: "mock.connect", act: () => { mock.scenario = "home"; mock.connect("Cafe-Free", {}); }, until: () => mock.wifi.active && mock.wifi.active.key === "Cafe-Free", why: () => root.j(mock.wifi.active) });
        step({ n: "mock.failNext", act: () => { mock.failNext = "forget"; mock.forget("u-home"); }, check: () => mock.failNext === "" && mock.errors.some(e => e.id === "forget:u-home") && mock.wifi.profiles.some(p => p.uuid === "u-home"), why: () => root.j(mock.errors) });
        step({ n: "mock.airplane.roundtrip", act: () => { mock.setAirplane(true); }, until: () => mock.airplane.on === true && mock.airplane.remembered.bt === true, why: () => root.j(mock.airplane) });
        step({ n: "mock.airplane.back", act: () => { mock.setAirplane(false); }, until: () => mock.airplane.on === false && mock.wifi.radioOn === true && mock.bt.powered === true, why: () => root.j([mock.airplane, mock.wifi.radioOn, mock.bt.powered]) });
        step({ n: "mock.toast.and.cue", act: () => { fakeNotifier.calls = []; root.cues = []; mock.failNext = "scan"; mock.scan(); }, check: () => root.toastsFor("fail-scan:").length === 1 && root.cues.length === 1 && root.cues[0] === "label", why: () => root.j([fakeNotifier.calls, root.cues]) });
        step({ n: "mock.serial.moves", check: () => mock.serial > 0 });

        root.steps = S;
        ticker.start();
    }
    property var padsBefore: 0
    property var confBefore: 0
    property var gwStates: []
    function tunnelMsg(name, state) { return root.activeMsg([root.act("u-cafe", "Cafe", "802-11-wireless", "wlp47s0", true),
        { uuid: "u-p-" + name, id: "ProtonVPN " + name, type: "wireguard", devices: ["proton0"], state: state || "activated", vpn: true, default4: false, default6: false }]); }
    function gwPad() { const ps = svc.health.pads.filter(p => p.id === "gateway"); return ps.length ? ps[0].state : ""; }
    function padReply(state) {
        const ev = { t: "pad", id: "$pad", detail: "192.168.1.1", ms: 5 };
        return { ok: true, data: { results: [{ id: "gateway", state: state, detail: "", ms: 5 }] }, before: [Object.assign({ state: "testing" }, ev), { sleep: 120 }, Object.assign({ state: state }, ev)] };
    }
    property real fileToday: 0
    property real maxRx: 0
    Connections {
        target: svc
        function onHealthChanged() { root.gwStates = root.gwStates.concat([root.gwPad()]); }
        function onRatesChanged() { root.maxRx = Math.max(root.maxRx, svc.rates.rxBps); }
    }
}
