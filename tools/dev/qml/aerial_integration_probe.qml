pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/aerial/data"
import "modules/aerial/popup"

// =============================================================================
// aerial_integration_probe.qml -- the REAL AerialService (live) on the REAL tools/aerial/aerial-helper, which talks to a FAKE
// NetworkManager + BlueZ on a private bus (tools/aerial/fake_nm.py, driven by tools/dev/aerial_integration_world.py), with stub iw / ping /
// protonvpn on PATH. Run by tools/dev/aerial_integration_probe.sh (sandbox, private XDG dirs); never started bare: with no AI_OUT it says
// SKIPPED and quits.
//
// One `AI <check> PASS|FAIL  detail` line per check, `AI time <name> <ms>` for a fake change -> the service's fact, `AI info ...`, then
// `AI DONE PASS|FAIL`. A step is { n, act?, until?, ms?, why?, check?, wait?, tm? }: `act` runs once; `until` must turn true within `ms`
// (else FAIL, `why()` says what was seen); then `check()` (if any) is the verdict; `wait` ms later `check()` must hold (for "nothing
// happened" claims); `tm` prints the time from `act` to the `until`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string out: Quickshell.env("AI_OUT") || ""
    readonly property string bus: Quickshell.env("AI_BUS") || ""
    readonly property string url: Quickshell.env("AI_URL") || ""
    readonly property string repo: Quickshell.env("AI_ROOT") || ""
    readonly property bool armed: root.out !== "" && root.bus !== "" && root.url !== "" && root.repo !== ""
    property bool ok: true

    function j(v) { return JSON.stringify(v); }
    function check(name, pass, detail) {
        console.log("AI " + name + " " + (pass ? "PASS" : "FAIL") + "  " + (pass ? "" : detail));
        if (!pass)
            root.ok = false;
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
    function finish() {
        console.log("AI DONE " + (root.ok ? "PASS" : "FAIL"));
        quitTimer.start();
    }

    // ---- the world's files -------------------------------------------------------------------------------------------------------------
    property string ctlText: ""
    property int ctlN: 0
    FileView { id: ctlFile; path: root.out + "/control.jsonl"; blockWrites: true; printErrors: false; atomicWrites: false }
    FileView { id: ansFile; path: root.out + "/answers.jsonl"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: argvFile; path: root.out + "/stub/argv.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: iwFile; path: root.out + "/stub/iw.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    FileView { id: wlFile; path: root.out + "/proc/wireless"; blockWrites: true; printErrors: false; atomicWrites: false }
    FileView { id: ndFile; path: root.out + "/proc/net_dev"; blockWrites: true; printErrors: false; atomicWrites: false }

    // one control line to the world; returns its number
    function send(o) {
        root.ctlN++;
        root.ctlText += JSON.stringify(Object.assign({ n: root.ctlN }, o)) + "\n";
        ctlFile.setText(root.ctlText);
        return root.ctlN;
    }
    function fk(o) { return root.send({ fake: o }); }
    function ans(n) {
        ansFile.reload();
        const lines = ansFile.text().split("\n");
        for (let i = 0; i < lines.length; i++)
            if (lines[i].trim() !== "") {
                const m = JSON.parse(lines[i]);
                if (m.n === n)
                    return m.a;
            }
        return null;
    }
    // the fake's state, polled until `pred(state)`; one ask at a time, one every 200 ms
    function stUntil(pred) {
        const c = { n: 0, at: 0, last: null };
        return () => {
            if (c.n === 0 && Date.now() - c.at > 200) {
                c.n = root.fk({ op: "state" });
                c.at = Date.now();
            }
            if (c.n === 0)
                return false;
            const a = root.ans(c.n);
            if (a === null)
                return false;
            c.n = 0;
            c.last = a.state;
            root.lastState = a.state;
            return pred(a.state) === true;
        };
    }
    property var lastState: null
    function lines(file) {
        file.reload();
        return file.text().split("\n").filter(l => l.trim() !== "");
    }
    function argvCount(word) { return root.lines(argvFile).filter(l => JSON.parse(l)[0] === word).length; }
    function iwCount(word) { return root.lines(iwFile).filter(l => l.indexOf(word) >= 0).length; }
    function setWireless(iface, dbm) {
        wlFile.setText("Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n"
            + iface + ": 0000   60.  " + dbm + ".  -256        0      0      0      0      0        0\n");
    }
    function setNetdev(iface, rx, tx) {
        ndFile.setText("Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
            + "    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n" + iface + ": " + rx + " 99 0 0 0 0 0 0 " + tx + " 50 0 0 0 0 0 0\n");
    }

    // ---- the Bluetooth source (what Quickshell.Bluetooth would say; the adapter has NO address and no RSSI: those come from BlueZ) -------
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
            function connect() {}
            function disconnect() {}
            function pair() {}
            function cancelPair() {}
            function forget() {}
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

    // ---- the service under test ----------------------------------------------------------------------------------------------------------
    property var osds: []
    property bool watchActive: false
    property bool dropped: false
    property int wifiPubs: 0
    // the shell's DesktopNotifier as far as the service uses it
    QtObject {
        id: fakeNotifier
        signal action(string key, string id)
        property var calls: []
        property var gone: []
        function notify(key, spec) { calls.push({ key: key, spec: spec }); }
        function withdraw(key) { gone.push(key); }
    }
    property var cues: []

    AerialService {
        id: svc
        live: false
        notifier: fakeNotifier
        onCue: part => root.cues = root.cues.concat([part])
        helperCommand: ["setpriv", "--pdeathsig", "TERM", "--", "python3", "-I", root.repo + "/tools/aerial/aerial-helper", "--bus-address", root.bus, "--check-url", root.url + "/nm-check.txt"]
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
        commandTimeoutMs: 8000
        scanEveryMs: 60000
        stationsEveryMs: 500
        btConnectTimeoutMs: 3000
        onOsd: (kind, payload) => root.osds = root.osds.concat([{ kind: kind, payload: payload }])
        onWifiChanged: {
            root.wifiPubs++;
            if (root.watchActive && svc.wifi.active === null)
                root.dropped = true;
        }
    }

    // ---- THE POPUP ON THE REAL SERVICE (round 4): the label's wipe to chrome was proven on a mock and never played on the desktop. The real popup reads the real service's
    // facts here, and every drawn frame of the tunnel's rise is read (`tun`): how many frames the label spent between paper and chrome, and every flip of `label.vpn`.
    property var tun: ({ on: false, between: 0, flips: [], last: -1, maxStep: 0 })
    Window {
        id: popWin
        width: 764
        height: 650
        visible: root.armed
        color: "#EAEDF5"
        AerialPopup {
            id: pop
            service: svc
            sizeScale: 1
            renderScale: 1
            entranceEnabled: false
            soundsEnabled: false
        }
        onAfterAnimating: {
            const t = root.tun;
            if (!t.on)
                return;
            const c = pop.scene.labelItem.chrome;
            if (c > 0.02 && c < 0.98)
                t.between++;
            if (t.last >= 0)
                t.maxStep = Math.max(t.maxStep, Math.abs(c - t.last));
            t.last = c;
        }
    }
    readonly property bool popVpn: !!pop.scene.state && !!pop.scene.state.label && pop.scene.state.label.vpn === true
    onPopVpnChanged: if (root.tun.on) root.tun.flips.push((root.popVpn ? "up" : "down") + "@" + pop.scene.labelItem.chrome.toFixed(2))
    function tunBegin(): void {
        root.tun = { on: true, between: 0, flips: [], last: pop.scene.labelItem.chrome, maxStep: 0 };
    }

    // ---- the sequencer -------------------------------------------------------------------------------------------------------------------
    property var steps: []
    property int stepAt: 0
    property bool stepStarted: false
    property real stepT0: 0
    Timer { id: ticker; interval: 40; repeat: true; onTriggered: root.tick() }
    function tick() {
        if (root.stepAt >= root.steps.length) {
            ticker.stop();
            root.finish();
            return;
        }
        const s = root.steps[root.stepAt];
        const now = Date.now();
        if (!root.stepStarted) {
            root.stepStarted = true;
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
                if (s.until()) {
                    done = true;
                    pass = s.check ? s.check() === true : true;
                    detail = s.why ? s.why() : "the check did not hold";
                    if (s.tm)
                        console.log("AI time " + s.tm + " " + (now - root.stepT0));
                } else if (now - root.stepT0 > (s.ms || 6000)) {
                    done = true;
                    detail = "timed out: " + (s.why ? s.why() : "");
                }
            } else if (s.wait !== undefined) {
                if (now - root.stepT0 >= s.wait) {
                    done = true;
                    pass = s.check ? s.check() === true : true;
                    detail = s.why ? s.why() : "the condition did not hold";
                }
            } else {
                done = true;
                pass = s.check ? s.check() === true : true;
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

    // ---- helpers over the facts ------------------------------------------------------------------------------------------------------------
    function net(key) {
        const ns = svc.wifi.networks;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].key === key)
                return ns[i];
        return null;
    }
    function prof(name) {
        const ps = svc.wifi.profiles;
        for (let i = 0; i < ps.length; i++)
            if (ps[i].name === name)
                return ps[i];
        return null;
    }
    function stProf(st, id) {
        for (let i = 0; i < st.profiles.length; i++)
            if (st.profiles[i].id === id)
                return st.profiles[i];
        return null;
    }
    function pad(id) {
        const ps = svc.health.pads;
        for (let i = 0; i < ps.length; i++)
            if (ps[i].id === id)
                return ps[i];
        return null;
    }
    function padState(id) { const p = root.pad(id); return p ? p.state : ""; }
    function osdCount(kind) { return root.osds.filter(o => o.kind === kind).length; }
    function errFor(part) { return svc.errors.filter(e => e.part === part); }
    function btDev(address) {
        for (let i = 0; i < svc.bt.devices.length; i++)
            if (svc.bt.devices[i].address === address)
                return svc.bt.devices[i];
        return null;
    }
    property int profilesBefore: 0
    property int stProfilesBefore: 0
    property bool knownBefore: false
    property int agentN: 0
    property int iwBefore: 0
    property real rssKb: 0
    property int rssN: 0

    // ---- the scenario ----------------------------------------------------------------------------------------------------------------------
    Component.onCompleted: {
        if (!root.armed) {
            console.log("AI DONE SKIPPED (not armed: no AI_OUT / AI_BUS / AI_URL; this file is run by tools/dev/aerial_integration_probe.sh)");
            quitTimer.start();
            return;
        }
        const S = [];
        function step(o) { S.push(o); }
        // a change in the WORLD (a stub file, the check URL) lands before the next step asks about it: the world polls its control file every 30 ms
        function world(n, o) { S.push({ n: n, act: () => root.send(o), wait: 150 }); }
        const ADDR = "AA:BB:CC:00:00:01";

        // ---- the service comes up on the fake machine -------------------------------------------------------------------------------------
        step({ n: "start.facts", act: () => {
            root.setWireless("wlp47s0", -52);
            root.setNetdev("wlp47s0", 1000, 500);
            svc.live = true;
            svc.popupOpen = true;
        }, until: () => svc.helper.state === "up" && svc.wifi.present && svc.wifi.networks.length >= 8 && svc.wifi.active !== null && svc.wifi.country !== "" && svc.wifi.profiles.length >= 10,
            ms: 30000, tm: "startToFacts", why: () => root.j(svc.helper) + " present=" + svc.wifi.present + " nets=" + svc.wifi.networks.length + " active=" + root.j(svc.wifi.active) + " country=" + svc.wifi.country });
        step({ n: "card.driver.firmware.country", check: () => svc.wifi.iface === "wlp47s0" && svc.wifi.driver === "iwlwifi" && svc.wifi.firmware === "89.7f2a5b3e.0 ty-a0-gf-a0-89.ucode" && svc.wifi.country === "BE" && svc.wifi.mac === "02:AE:00:00:00:06",
            why: () => root.j({ iface: svc.wifi.iface, driver: svc.wifi.driver, fw: svc.wifi.firmware, country: svc.wifi.country, mac: svc.wifi.mac }) });
        step({ n: "scan.list.dual-band", check: () => { const n = root.net("HomeNet-AP"); return n && n.bands.length === 2 && n.bands[0] === "2.4" && n.bands[1] === "5" && n.aps.length === 2 && n.connected && n.state === "connected" && n.known; },
            why: () => root.j(root.net("HomeNet-AP")) });
        step({ n: "scan.list.hidden-key", check: () => { const n = root.net("hidden:02:AE:00:00:01:06"); return n && n.hidden === true && n.ssid === ""; },
            why: () => root.j(svc.wifi.networks.map(n => n.key)) });
        step({ n: "scan.list.bands-and-security", check: () => { const sae = root.net("SAE-Only"), open = root.net("Campus-Open"), edu = root.net("eduroam"), cafe = root.net("Cafe-WiFi"), na = root.net("Neighbour-A");
            return sae && sae.security === "wpa3" && sae.bands.join() === "6" && open && open.security === "open" && edu && edu.security === "eap" && cafe && cafe.known && na && !na.known; },
            why: () => root.j(svc.wifi.networks.map(n => [n.key, n.security, n.bands.join("/"), n.known])) });
        step({ n: "scan.list.doubles", check: () => { const a = root.prof("HomeNet-AP"), b = root.prof("HomeNet-AP 1"); return a && b && a.doubles.indexOf(b.uuid) >= 0 && b.doubles.indexOf(a.uuid) >= 0; },
            why: () => root.j([root.prof("HomeNet-AP"), root.prof("HomeNet-AP 1")]) });
        step({ n: "facts.hotspot.wired.proton", check: () => svc.hotspot.available && svc.hotspot.uuid !== "" && svc.hotspot.ssid === "laptop-hotspot" && svc.wired.jacks.length === 1 && svc.wired.jacks[0].iface === "enp46s0" && !svc.wired.jacks[0].carrier && svc.proton.installed,
            why: () => root.j([svc.hotspot, svc.wired, svc.proton.installed]) });
        step({ n: "pads.after.open", until: () => root.padState("gateway") === "ok" && root.padState("dns") === "ok" && root.padState("net") === "ok", ms: 8000, why: () => root.j(svc.health.pads) });
        step({ n: "no.errors.so.far", check: () => svc.errors.length === 0, why: () => root.j(svc.errors) });
        step({ n: "scan.finds.the-late-arrival", act: () => svc.scan(), until: () => root.net("Late-Arrival") !== null, ms: 8000, why: () => root.j(svc.wifi.networks.map(n => n.key)) });

        // ---- the Bluetooth facts Quickshell lacks, from BlueZ's own properties ----------------------------------------------------------------------
        step({ n: "bt.address.from.bluez", act: () => {
            fakeBt.devices = [fakeDevComp.createObject(root, { address: ADDR, name: "Buds", icon: "audio-headset", paired: true, bonded: true })];
            root.fk({ op: "bt_dev_add", address: ADDR, name: "Buds", paired: true, rssi: -61 });
        }, until: () => svc.bt.address === "02:AE:00:00:00:2A" && root.btDev(ADDR) !== null && root.btDev(ADDR).rssi === -61, ms: 6000, tm: "btRssi",
            why: () => root.j([svc.bt.address, root.btDev(ADDR)]) });
        step({ n: "bt.rssi.follows", act: () => root.fk({ op: "bt_dev", address: ADDR, rssi: -55 }), until: () => root.btDev(ADDR).rssi === -55, ms: 4000, tm: "btRssiChange", why: () => root.j(root.btDev(ADDR)) });
        step({ n: "bt.rssi.gone.when.discovery.stops", act: () => root.fk({ op: "bt_dev", address: ADDR, rssi: null }), until: () => root.btDev(ADDR).rssi === 0, ms: 4000, why: () => root.j(root.btDev(ADDR)) });
        step({ n: "bt.hardblock.from.rfkill", act: () => {
            root.send({ write: "rfkill/rfkill0/hard", text: "1\n" });
            root.fk({ op: "bt_adapter", powerState: "off-blocked" });
        }, until: () => svc.bt.hardBlocked === true, ms: 6000, tm: "btHardBlock", why: () => root.j([svc.bt.hardBlocked, svc.bt.softBlocked]) });
        step({ n: "bt.hardblock.released.is.soft", act: () => root.send({ write: "rfkill/rfkill0/hard", text: "0\n" }), until: () => svc.bt.hardBlocked === false && svc.bt.softBlocked === true, ms: 6000, why: () => root.j([svc.bt.hardBlocked, svc.bt.softBlocked]) });
        step({ n: "bt.unblocked", act: () => root.fk({ op: "bt_adapter", powerState: "on" }), until: () => svc.bt.softBlocked === false && svc.bt.hardBlocked === false, ms: 6000, why: () => root.j([svc.bt.hardBlocked, svc.bt.softBlocked]) });

        // ---- connect a saved network: the existing profile is activated, no new one is made --------------------------------------------------------
        step({ n: "fake.profiles.counted", act: () => {}, until: root.stUntil(st => { root.stProfilesBefore = st.profiles.length; return true; }), ms: 4000, why: () => "no state" });
        // (round 4) the saved profile is BOUND TO AN INTERFACE THIS MACHINE NO LONGER HAS, as every profile nmcli made on the user's machine is (the card is wlp46s0 or
        // wlp47s0 by the day): the real NetworkManager refuses it on the device ("mismatching interface name"), so the helper takes the dead name off first
        step({ n: "saved.profile.bound.to.a.dead.interface", act: () => { root.fk({ op: "profile_bind", id: "Cafe-WiFi", ifname: "wlp46s0" }); },
            until: root.stUntil(st => { const p = root.stProf(st, "Cafe-WiFi"); return p && p.ifname === "wlp46s0"; }), ms: 4000, why: () => root.j(root.lastState && root.stProf(root.lastState, "Cafe-WiFi")) });
        step({ n: "connect.saved", act: () => {
            root.profilesBefore = svc.wifi.profiles.length;
            svc.connect("Cafe-WiFi");
        }, until: () => root.net("Cafe-WiFi").connected && svc.wifi.active !== null && svc.wifi.active.ssid === "Cafe-WiFi", ms: 8000, tm: "connectSaved",
            why: () => root.j([root.net("Cafe-WiFi"), svc.wifi.active, svc.errors]) });
        step({ n: "connect.saved.unbound.the.dead.name", act: () => {}, until: root.stUntil(st => { const p = root.stProf(st, "Cafe-WiFi"); return p && p.ifname === ""; }), ms: 4000,
            why: () => root.j(root.lastState && root.stProf(root.lastState, "Cafe-WiFi")) });
        step({ n: "connect.saved.no.new.profile", act: () => {}, until: root.stUntil(st => st.profiles.length === root.stProfilesBefore && st.log.some(l => l[0] === "activate")), ms: 4000,
            why: () => "before " + root.stProfilesBefore + " fake " + (root.lastState ? root.lastState.profiles.length : "?") });
        step({ n: "connect.saved.facts.no.drop", check: () => svc.wifi.profiles.length === root.profilesBefore && svc.errors.length === 0, why: () => root.j([svc.wifi.profiles.length, svc.errors]) });

        // ---- dBm and usage on the connected network ---------------------------------------------------------------------------------------------------
        step({ n: "usage.base", act: () => root.setWireless("wlp47s0", -47), until: () => svc.wifi.active !== null && svc.wifi.active.dbm === -47, ms: 4000, why: () => root.j(svc.wifi.active) });
        step({ n: "usage.counted.for.the.network", act: () => root.setNetdev("wlp47s0", 5001000, 2000500),
            until: () => svc.usage.current.key === "Cafe-WiFi" && svc.usage.current.bytes >= 6000000 && svc.usage.todayBytes >= 6000000 && svc.usage.byNetwork.some(b => b.key === "Cafe-WiFi" && b.today >= 6000000) && svc.rates.iface === "wlp47s0",
            ms: 5000, why: () => root.j([svc.usage.current, svc.usage.todayBytes, svc.usage.byNetwork, svc.rates]) });

        // ---- disconnect ----------------------------------------------------------------------------------------------------------------------------------
        step({ n: "disconnect", act: () => svc.disconnect(), until: () => svc.wifi.active === null && root.net("Cafe-WiFi").state === "idle", ms: 6000, tm: "disconnect", why: () => root.j([svc.wifi.active, root.net("Cafe-WiFi")]) });

        // ---- a secured stranger: needsSecret, then the password, with a portal in the way -> the auto-tunnel WAITS, then raises -----------------------
        step({ n: "stranger.needs.secret", act: () => {
            root.profilesBefore = svc.wifi.profiles.length;
            svc.connect("Neighbour-A");
        }, until: () => root.net("Neighbour-A").state === "needsSecret", ms: 4000, why: () => root.j(root.net("Neighbour-A")) });
        step({ n: "stranger.no.profile.yet", act: () => {}, until: root.stUntil(st => !st.profiles.some(p => p.id === "Neighbour-A")), ms: 3000, why: () => root.j(root.lastState && root.lastState.profiles.map(p => p.id)) });
        world("portal.http.set", { http: "portal" });
        step({ n: "stranger.connects.with.password", act: () => svc.connect("Neighbour-A", { password: "fake-na-psk" }),
            until: () => root.net("Neighbour-A").connected && root.net("Neighbour-A").known, ms: 10000, tm: "connectStranger", why: () => root.j([root.net("Neighbour-A"), svc.errors]) });
        step({ n: "stranger.profile.made.public", check: () => svc.wifi.profiles.length === root.profilesBefore + 1 && root.net("Neighbour-A").trusted === false, why: () => root.j([svc.wifi.profiles.length, root.profilesBefore, root.net("Neighbour-A").trusted]) });
        step({ n: "auto.waits.for.the.portal", until: () => svc.proton.waiting === "portal" && svc.health.portal.present === true && root.padState("net") === "warn", ms: 10000, why: () => root.j([svc.proton, svc.health]) });
        step({ n: "auto.portal.not.raised", wait: 1500, check: () => svc.proton.state === "down" && root.argvCount("connect") === 0, why: () => root.j([svc.proton.state, root.argvCount("connect")]) });
        step({ n: "auto.signed.in", check: () => svc.proton.signedIn === "yes" && svc.proton.installed, why: () => root.j(svc.proton) });

        world("login.done.http.online", { http: "online" });
        step({ n: "auto.raises.after.the.login", act: () => {
            root.dropped = false;
            root.watchActive = true;
            svc.testPad("net");
        }, until: () => svc.proton.state === "up" && svc.proton.server !== null, ms: 15000, tm: "autoTunnel", why: () => root.j([svc.proton, svc.health.pads, root.argvCount("connect")]) });
        step({ n: "auto.osd.once", check: () => root.osdCount("autoTunnel") === 1 && svc.proton.waiting === "", why: () => root.j([root.osds, svc.proton.waiting]) });
        step({ n: "auto.tunnel.is.the.fastest.pick", until: () => svc.proton.fastest === true, ms: 6000, why: () => root.j(svc.proton) });
        step({ n: "auto.connect.argv.once", check: () => root.argvCount("connect") === 1, why: () => "connects " + root.argvCount("connect") });

        // ---- Proton by hand, the pvpn-killswitch dummy holding NetworkManager's primary for a moment: the Wi-Fi fact never drops ---------------
        step({ n: "proton.disconnect", act: () => svc.vpnDisconnect(), until: () => svc.proton.state === "down" && svc.proton.fastest === false, ms: 8000, why: () => root.j(svc.proton) });
        step({ n: "proton.not.raised.again.after.a.user.drop", wait: 1500, check: () => svc.proton.state === "down" && root.argvCount("connect") === 1, why: () => root.j([svc.proton.state, root.argvCount("connect")]) });
        step({ n: "proton.connect.by.hand", act: () => { root.tunBegin(); svc.vpnConnect({ country: "NL" }); }, until: () => svc.proton.state === "up", ms: 12000, tm: "protonConnect", why: () => root.j([svc.proton, svc.errors]) });
        step({ n: "proton.by.country.is.not.the.fastest", check: () => svc.proton.state === "up" && svc.proton.fastest === false, why: () => root.j(svc.proton) });
        step({ n: "tunnel.wipes.the.label.on.the.real.service", wait: 1600, check: () => pop.scene.labelItem.chrome === 1 && root.tun.between >= 8 && root.tun.maxStep < 0.34,
            why: () => "chrome=" + pop.scene.labelItem.chrome + " " + root.j(root.tun) });
        step({ n: "wifi.never.dropped.under.the.dummy.primary", act: () => { root.watchActive = false; }, check: () => root.dropped === false && svc.wifi.active !== null && svc.wifi.active.ssid === "Neighbour-A" && svc.usage.current.key === "Neighbour-A",
            why: () => "dropped=" + root.dropped + " " + root.j([svc.wifi.active && svc.wifi.active.ssid, svc.usage.current]) });
        step({ n: "proton.stub.connect.twice", check: () => root.argvCount("connect") === 2, why: () => "connects " + root.argvCount("connect") });

        // ---- a wrong password: failed, with an error on the network's part; then the right one on the SAME profile -------------------------------
        step({ n: "wrong.password.fails", act: () => svc.connect("Neighbour-B", { password: "wrong" }),
            until: () => root.net("Neighbour-B").state === "failed" && root.errFor("net:Neighbour-B").length === 1, ms: 10000, tm: "wrongPassword", why: () => root.j([root.net("Neighbour-B"), svc.errors]) });
        step({ n: "wrong.password.says.so", check: () => /password/i.test(root.net("Neighbour-B").failReason) && /password/i.test(root.errFor("net:Neighbour-B")[0].text), why: () => root.j([root.net("Neighbour-B").failReason, svc.errors]) });
        step({ n: "wrong.password.one.toast", check: () => fakeNotifier.calls.filter(c => c.spec.title === "Could not join Neighbour-B").length === 1
                                                         && root.cues.filter(c => c === "net:Neighbour-B").length === 1, why: () => root.j([fakeNotifier.calls, root.cues]) });
        step({ n: "known.new.password.connects", act: () => {
            root.knownBefore = root.net("Neighbour-B").known;
            root.profilesBefore = svc.wifi.profiles.length;
            svc.connect("Neighbour-B", { password: "fake-nb-psk" });
        }, until: () => root.net("Neighbour-B").connected, ms: 10000, tm: "knownNewPassword", why: () => root.j([root.net("Neighbour-B"), svc.errors, root.knownBefore]) });
        step({ n: "known.new.password.was.the.known.path", check: () => root.knownBefore === true && svc.wifi.profiles.length === root.profilesBefore, why: () => "known=" + root.knownBefore + " profiles " + svc.wifi.profiles.length + "/" + root.profilesBefore });
        step({ n: "known.new.password.stored", act: () => {}, until: root.stUntil(st => { const p = root.stProf(st, "Neighbour-B"); return p && p.psk === "fake-nb-psk"; }), ms: 4000, why: () => root.j(root.lastState && root.stProf(root.lastState, "Neighbour-B")) });
        step({ n: "wrong.password.toast.withdrawn", check: () => fakeNotifier.gone.some(k => k.indexOf("Neighbour-B") >= 0), why: () => root.j(fakeNotifier.gone) });
        step({ n: "wrong.password.error.cleared.by.connecting", check: () => root.errFor("net:Neighbour-B").length === 0, why: () => root.j(svc.errors) });

        // ---- profile edits: the EAP password, power saving ---------------------------------------------------------------------------------------
        step({ n: "edit.eap.password.and.powersave", act: () => {
            svc.updateProfile(root.prof("eduroam").uuid, { eap: { password: "new-eap-pass" } });
            svc.setPowersave(true);
        }, until: root.stUntil(st => st.eapPasswords.eduroam === "new-eap-pass" && root.stProf(st, "Neighbour-B").powersave === 3), ms: 5000, why: () => root.j(root.lastState && [root.lastState.eapPasswords, root.stProf(root.lastState, "Neighbour-B")]) });
        step({ n: "powersave.is.a.fact", until: () => svc.wifi.powersave === true, ms: 4000, why: () => "powersave=" + svc.wifi.powersave });

        // ---- doubles merged, a profile forgotten --------------------------------------------------------------------------------------------------
        step({ n: "merge.doubles", act: () => {
            root.profilesBefore = svc.wifi.profiles.length;
            svc.mergeDoubles(root.prof("HomeNet-AP 1").uuid, [root.prof("HomeNet-AP").uuid]);
        }, until: () => svc.wifi.profiles.length === root.profilesBefore - 1 && root.prof("HomeNet-AP") === null && root.prof("HomeNet-AP 1").doubles.length === 0, ms: 5000, why: () => root.j(svc.wifi.profiles.map(p => p.name)) });
        step({ n: "forget", act: () => svc.forget(root.prof("Cafe-WiFi").uuid), until: () => root.prof("Cafe-WiFi") === null && root.net("Cafe-WiFi").known === false, ms: 5000, tm: "forget", why: () => root.j(root.prof("Cafe-WiFi")) });
        step({ n: "forget.in.the.fake", act: () => {}, until: root.stUntil(st => root.stProf(st, "Cafe-WiFi") === null), ms: 4000, why: () => root.j(root.lastState && root.lastState.profiles.map(p => p.id)) });

        // ---- timing: a change in the fake -> the service's fact -------------------------------------------------------------------------------------
        step({ n: "fake.ap.appears", act: () => root.fk({ op: "ap_add", ap: { ssid: "Zeta-Net", bssid: "02:AE:00:00:01:20", freq: 2412, width: 20, strength: 40, maxBitrate: 130000, security: "wpa2", psk: "zzz" } }),
            until: () => root.net("Zeta-Net") !== null, ms: 4000, tm: "apAdd", why: () => root.j(svc.wifi.networks.map(n => n.key)) });
        step({ n: "fake.ap.strength", act: () => root.fk({ op: "ap_strength", bssid: "02:AE:00:00:01:20", strength: 90 }), until: () => root.net("Zeta-Net").signal === 90, ms: 4000, tm: "apStrength", why: () => root.j(root.net("Zeta-Net")) });
        step({ n: "fake.ap.goes", act: () => root.fk({ op: "ap_remove", bssid: "02:AE:00:00:01:20" }), until: () => root.net("Zeta-Net") === null, ms: 4000, tm: "apRemove", why: () => root.j(svc.wifi.networks.map(n => n.key)) });
        step({ n: "fake.cable.plugged", act: () => root.fk({ op: "set_carrier", iface: "enp46s0", on: true }), until: () => svc.wired.jacks[0].carrier === true, ms: 4000, tm: "carrier", why: () => root.j(svc.wired) });
        step({ n: "fake.cable.unplugged", act: () => root.fk({ op: "set_carrier", iface: "enp46s0", on: false }), until: () => svc.wired.jacks[0].carrier === false, ms: 4000, why: () => root.j(svc.wired) });

        // ---- the hotspot: configure, start, a station with a lease, only while the popup is open --------------------------------------------------
        step({ n: "hotspot.configure.saves.without.starting", act: () => svc.configureHotspot({ ssid: "lares-spot", password: "hotspot-pass-1", band: "a" }),
            until: root.stUntil(st => { const p = root.stProf(st, "Hotspot"); return p && p.ssid === "lares-spot" && p.psk === "hotspot-pass-1" && p.band === "a"; }), ms: 5000, why: () => root.j(root.lastState && root.stProf(root.lastState, "Hotspot")) });
        step({ n: "hotspot.not.started.by.configure", check: () => svc.hotspot.active === false && svc.hotspot.state === "off", why: () => root.j(svc.hotspot) });
        step({ n: "hotspot.profile.bound.to.a.dead.interface", act: () => { root.fk({ op: "profile_bind", id: "Hotspot", ifname: "wlp46s0" }); },
            until: root.stUntil(st => { const p = root.stProf(st, "Hotspot"); return p && p.ifname === "wlp46s0"; }), ms: 4000, why: () => root.j(root.lastState && root.stProf(root.lastState, "Hotspot")) });
        step({ n: "hotspot.starts", act: () => {
            root.send({ write: "stub/iw_station.txt", text: "Station 02:ae:00:00:00:51 (on wlp47s0)\n\tinactive time:\t40 ms\n\tsignal:  \t-55 [-57, -55] dBm\n\tconnected time:\t120 seconds\n"
                + "Station 02:ae:00:00:00:52 (on wlp47s0)\n\tinactive time:\t900 ms\n\tsignal:  \t-71 [-73, -71] dBm\n\tconnected time:\t9 seconds\n" });
            root.send({ write: "leases/dnsmasq-wlp47s0.leases", text: "1795200000 02:ae:00:00:00:51 10.42.0.23 pixel-8 01:02:ae:00:00:00:51\n1795200100 02:ae:00:00:00:52 10.42.0.31 * *\n" });
            svc.startHotspot();
        }, until: () => svc.hotspot.active === true, ms: 10000, tm: "hotspotStart", why: () => root.j([svc.hotspot, svc.errors]) });
        step({ n: "hotspot.clients.with.names", until: () => svc.hotspot.clients.length === 2, ms: 6000, why: () => root.j(svc.hotspot.clients) });
        step({ n: "hotspot.clients.fields", check: () => { const a = svc.hotspot.clients.find(c => c.mac === "02:AE:00:00:00:51"), b = svc.hotspot.clients.find(c => c.mac === "02:AE:00:00:00:52");
            return a && a.ip === "10.42.0.23" && a.name === "pixel-8" && a.dbm === -55 && b && b.ip === "10.42.0.31" && b.name === "" && b.dbm === -71; }, why: () => root.j(svc.hotspot.clients) });
        step({ n: "hotspot.client.leaves", act: () => root.send({ write: "stub/iw_station.txt", text: "Station 02:ae:00:00:00:51 (on wlp47s0)\n\tsignal:  \t-60 [-62, -60] dBm\n\tconnected time:\t125 seconds\n" }),
            until: () => svc.hotspot.clients.length === 1 && svc.hotspot.clients[0].dbm === -60, ms: 4000, tm: "hotspotClientLeaves", why: () => root.j(svc.hotspot.clients) });
        step({ n: "hotspot.popup.closed.clears.and.stops.asking", act: () => {
            svc.popupOpen = false;
            root.iwBefore = -1;
        }, until: () => svc.hotspot.clients.length === 0, ms: 3000, why: () => root.j(svc.hotspot.clients) });
        step({ n: "hotspot.no.questions.while.closed", act: () => { root.iwBefore = root.iwCount("station dump"); }, wait: 1800, check: () => root.iwCount("station dump") === root.iwBefore && svc.hotspot.clients.length === 0,
            why: () => "iw station dumps " + root.iwBefore + " -> " + root.iwCount("station dump") });
        step({ n: "hotspot.popup.reopened.asks.again", act: () => { svc.popupOpen = true; }, until: () => svc.hotspot.clients.length === 1, ms: 6000, why: () => root.j(svc.hotspot.clients) });
        step({ n: "hotspot.stops", act: () => svc.stopHotspot(), until: () => svc.hotspot.active === false && svc.hotspot.clients.length === 0, ms: 8000, why: () => root.j(svc.hotspot) });

        // ---- the hotspot displaced the connection: back on a saved network, for the pads and the agent ---------------------------------------------------
        step({ n: "reconnect.after.hotspot", act: () => svc.connect("Neighbour-B"), until: () => root.net("Neighbour-B").connected && svc.wifi.active !== null, ms: 10000, why: () => root.j([root.net("Neighbour-B"), svc.hotspot.active, svc.errors]) });

        // ---- the pairing agent's confirm round trip, through bt.prompt and btAnswer ----------------------------------------------------------------------
        step({ n: "agent.registered.while.open", act: () => {}, until: root.stUntil(st => st.agent !== null), ms: 6000, why: () => root.j(root.lastState && root.lastState.agent) });
        step({ n: "agent.confirm.asks", act: () => { root.agentN = root.fk({ op: "bt_request", kind: "confirm", device: ADDR, passkey: 123456 }); },
            until: () => svc.bt.prompt !== null && svc.bt.prompt.kind === "confirm", ms: 6000, tm: "agentPrompt", why: () => root.j(svc.bt.prompt) });
        step({ n: "agent.confirm.prompt.fields", check: () => svc.bt.prompt.code === "123456" && svc.bt.prompt.address === ADDR && svc.bt.prompt.rid > 0, why: () => root.j(svc.bt.prompt) });
        step({ n: "agent.confirm.accept.reaches.bluez", act: () => svc.btAnswer(svc.bt.prompt.rid, true), until: () => root.ans(root.agentN) !== null && svc.bt.prompt === null, ms: 6000, why: () => root.j([root.ans(root.agentN), svc.bt.prompt]) });
        step({ n: "agent.confirm.accepted", check: () => root.ans(root.agentN).ok === true, why: () => root.j(root.ans(root.agentN)) });
        step({ n: "agent.pin.round.trip", act: () => { root.agentN = root.fk({ op: "bt_request", kind: "pin", device: ADDR }); }, until: () => svc.bt.prompt !== null && svc.bt.prompt.kind === "pin", ms: 6000, why: () => root.j(svc.bt.prompt) });
        step({ n: "agent.pin.answer.value", act: () => svc.btAnswer(svc.bt.prompt.rid, true, "4321"), until: () => root.ans(root.agentN) !== null, ms: 6000, check: () => root.ans(root.agentN).ok === true && root.ans(root.agentN).value === "4321", why: () => root.j(root.ans(root.agentN)) });
        step({ n: "agent.reject", act: () => { root.agentN = root.fk({ op: "bt_request", kind: "confirm", device: ADDR, passkey: 654321 }); }, until: () => svc.bt.prompt !== null, ms: 6000, why: () => root.j(svc.bt.prompt) });
        step({ n: "agent.reject.reaches.bluez", act: () => svc.btAnswer(svc.bt.prompt.rid, false), until: () => root.ans(root.agentN) !== null, ms: 6000, check: () => root.ans(root.agentN).ok === false && /Rejected/.test(root.ans(root.agentN).error), why: () => root.j(root.ans(root.agentN)) });

        // ---- the pads --------------------------------------------------------------------------------------------------------------------------------------
        world("pad.ping.stub.fails", { write: "stub/pingfail", text: "" });
        step({ n: "pad.gateway.fails", act: () => svc.testPad("gateway"), until: () => root.padState("gateway") === "fail", ms: 6000, why: () => root.j(root.pad("gateway")) });
        world("pad.ping.stub.back", { rm: "stub/pingfail" });
        step({ n: "pad.gateway.recovers", act: () => svc.testPad("gateway"), until: () => root.padState("gateway") === "ok", ms: 6000, why: () => root.j(root.pad("gateway")) });
        world("pad.http.down", { http: "down" });
        step({ n: "pad.net.down", act: () => svc.testPad("net"), until: () => root.padState("net") === "fail", ms: 8000, why: () => root.j(root.pad("net")) });
        world("pad.http.back", { http: "online" });
        step({ n: "pad.net.back", act: () => svc.testPad("net"), until: () => root.padState("net") === "ok", ms: 8000, why: () => root.j(root.pad("net")) });

        // ---- airplane -----------------------------------------------------------------------------------------------------------------------------------------
        step({ n: "airplane.on", act: () => svc.setAirplane(true), until: () => svc.wifi.radioOn === false && svc.bt.powered === false && svc.airplane.on === true, ms: 8000, tm: "airplaneOn", why: () => root.j([svc.wifi.radioOn, svc.bt.powered, svc.airplane]) });
        step({ n: "airplane.off.gives.back", act: () => svc.setAirplane(false), until: () => svc.wifi.radioOn === true && svc.bt.powered === true && svc.airplane.on === false, ms: 8000, tm: "airplaneOff", why: () => root.j([svc.wifi.radioOn, svc.bt.powered, svc.airplane]) });

        // ---- the regulatory country, asked again --------------------------------------------------------------------------------------------------------------
        step({ n: "reg.file.written", act: () => root.send({ write: "stub/iw_reg.txt", text: "global\ncountry 00: DFS-UNSET\n\tNOT-USED\n\nphy#0 (self-managed)\ncountry NL: DFS-UNSET\n" }), wait: 300 });
        step({ n: "reg.refresh", act: () => svc.refresh(), until: () => svc.wifi.country === "NL", ms: 5000, tm: "regRefresh", why: () => svc.wifi.country });

        // ---- the helper stayed small and quiet ----------------------------------------------------------------------------------------------------------------
        step({ n: "helper.rss", act: () => { root.rssN = root.send({ rss: true }); }, until: () => root.ans(root.rssN) !== null, ms: 4000, why: () => "no answer" });
        step({ n: "helper.rss.small", check: () => { const kb = root.ans(root.rssN).kb; console.log("AI info helperRssKb " + kb); return kb > 0 && kb < 150000; }, why: () => root.j(root.ans(root.rssN)) });
        step({ n: "helper.still.up", check: () => svc.helper.state === "up", why: () => root.j(svc.helper) });
        step({ n: "wifi.publications", check: () => { console.log("AI info wifiPublications " + root.wifiPubs + " serial " + svc.serial); return true; } });

        root.steps = S;
        ticker.start();
    }
}
