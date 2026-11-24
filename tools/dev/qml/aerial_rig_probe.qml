pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/aerial/data"

// =============================================================================
// aerial_rig_probe.qml -- the REAL AerialService (live) on the REAL tools/aerial/aerial-helper, pointed at the test bed's REAL
// NetworkManager (private bus /run/lares-rig/bus; tools/aerial/rig). Run by tools/dev/aerial_rig_probe.sh once the rig is up; never
// started bare: with no AR_RUN it says SKIPPED and quits. The integration probe's sequencer and its checks' shape
// (tools/dev/qml/aerial_integration_probe.qml), a real world instead of the fake one. The rig's own switches: the portal file, the phone's
// wpa_cli, the access points' hostapd_cli -- all reachable as the user.
//
// One `AR <check> PASS|FAIL  detail` line per check, `AR time <name> <ms>`, then `AR DONE PASS|FAIL`. Step shape as in the integration probe.
// =============================================================================
ShellRoot {
    id: root

    readonly property string run: Quickshell.env("AR_RUN") || ""
    readonly property string out: Quickshell.env("AR_OUT") || ""
    readonly property string repo: Quickshell.env("AR_ROOT") || ""
    readonly property string client: Quickshell.env("AR_CLIENT") || ""
    readonly property string phone: Quickshell.env("AR_PHONE") || ""
    readonly property string apA: Quickshell.env("AR_APA") || ""
    readonly property string apB: Quickshell.env("AR_APB") || ""
    readonly property bool armed: root.run !== "" && root.out !== "" && root.repo !== "" && root.client !== ""
    property bool ok: true

    function j(v) { return JSON.stringify(v); }
    function check(name, pass, detail) {
        console.log("AR " + name + " " + (pass ? "PASS" : "FAIL") + "  " + (pass ? "" : detail));
        if (!pass)
            root.ok = false;
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }
    function finish() {
        console.log("AR DONE " + (root.ok ? "PASS" : "FAIL"));
        quitTimer.start();
    }

    // ---- the rig's own switches ---------------------------------------------------------------------------------------------------------
    FileView { id: portalFile; path: root.run + "/portal"; blockWrites: true; printErrors: false; atomicWrites: false }   // user-owned, written IN PLACE
    FileView { id: argvFile; path: root.out + "/stub/argv.log"; blockLoading: true; blockAllReads: true; printErrors: false; watchChanges: false }
    function armPortal(on) { portalFile.setText(on ? "portal\n" : "online\n"); }
    function lines(file) {
        file.reload();
        return file.text().split("\n").filter(l => l.trim() !== "");
    }
    function argvCount(word) { return root.lines(argvFile).filter(l => JSON.parse(l)[0] === word).length; }
    // one-shot children: the portal's login, the phone's join, an access point's switch
    property int exits: 0
    Process { id: toolProc; onExited: root.exits++ }
    function tool(argv) { toolProc.command = argv; toolProc.running = true; }

    // ---- the Bluetooth source: the rig has no Bluetooth; the service needs a source to exist ---------------------------------------------------
    QtObject { id: fakeAdapter; property string name: "laptop"; property bool enabled: true; property string state: "Enabled"; property bool discoverable: false; property real discoverableTimeout: 0; property bool discovering: false; property bool pairable: false }
    QtObject { id: fakeBt; property var defaultAdapter: fakeAdapter; property var devices: [] }

    property var osds: []
    AerialService {
        id: svc
        live: false
        helperCommand: ["setpriv", "--pdeathsig", "TERM", "--", "python3", "-I", root.repo + "/tools/aerial/aerial-helper", "--bus-address", "unix:path=" + root.run + "/bus",
                        "--check-url", "http://10.77.0.1:8080/nm-check.txt"]
        btSource: fakeBt
        upowerEnabled: false
        procWirelessPath: root.run + "/pub/wireless"
        procNetDevPath: root.run + "/pub/net_dev"
        stateDir: root.out + "/state/lares/aerial"
        configPath: root.out + "/config/aerial.jsonc"
        protonPath: "/usr/bin/true"
        dnsmasqPath: "/usr/bin/dnsmasq"
        protonCachePath: root.out + "/serverlist.json"
        openCommand: ["true"]
        rfkillCommand: ["true"]
        pactlCommand: ["true"]
        commandTimeoutMs: 20000
        scanEveryMs: 60000
        stationsEveryMs: 1000
        onOsd: (kind, payload) => root.osds = root.osds.concat([{ kind: kind, payload: payload }])
    }

    // ---- the sequencer (as the integration probe's) ----------------------------------------------------------------------------------------------
    property var steps: []
    property int stepAt: 0
    property bool stepStarted: false
    property real stepT0: 0
    Timer { id: ticker; interval: 50; repeat: true; onTriggered: root.tick() }
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
                        console.log("AR time " + s.tm + " " + (now - root.stepT0));
                } else if (now - root.stepT0 > (s.ms || 20000)) {
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

    function net(key) {
        const ns = svc.wifi.networks;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].key === key)
                return ns[i];
        return null;
    }
    function hiddenNet() {
        const ns = svc.wifi.networks;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].hidden)
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
    function onNet(ssid) { return svc.wifi.active !== null && svc.wifi.active.ssid === ssid && svc.wifi.active.ip4 !== "" && svc.wifi.active.ip4.indexOf("10.77.0.") === 0; }

    property string roamFrom: ""
    property int roamChan: 0
    property int exitsBefore: 0
    property int connectsBefore: 0

    Component.onCompleted: {
        if (!root.armed) {
            console.log("AR DONE SKIPPED (not armed: no AR_RUN / AR_OUT / AR_ROOT / AR_CLIENT; this file is run by tools/dev/aerial_rig_probe.sh)");
            quitTimer.start();
            return;
        }
        const S = [];
        function step(o) { S.push(o); }

        // ---- the service on the rig's real NetworkManager ----------------------------------------------------------------------------------
        step({ n: "start.facts", act: () => { root.armPortal(false); svc.live = true; svc.popupOpen = true; },
            until: () => svc.helper.state === "up" && svc.wifi.present && svc.wifi.iface === root.client && root.net("rig-open") !== null && root.net("rig-wpa2") !== null && root.net("rig-wpa3") !== null && root.net("rig-eap") !== null && root.hiddenNet() !== null,
            ms: 90000, tm: "startToFacts", why: () => root.j(svc.helper) + " present=" + svc.wifi.present + " iface=" + svc.wifi.iface + " want " + root.client + " nets=" + root.j(svc.wifi.networks.map(n => n.key)) });
        step({ n: "scan.securities", check: () => root.net("rig-open").security === "open" && root.net("rig-wpa2").security === "wpa2" && root.net("rig-wpa3").security === "wpa3" && root.net("rig-eap").security === "eap" && root.hiddenNet().ssid === "",
            why: () => root.j(svc.wifi.networks.map(n => [n.key, n.security])) });
        step({ n: "scan.one.name.on.two.radios", check: () => root.net("rig-wpa2").aps.length === 2 && root.net("rig-wpa2").aps[0].bssid !== root.net("rig-wpa2").aps[1].bssid, why: () => root.j(root.net("rig-wpa2").aps) });
        step({ n: "card.facts", check: () => svc.wifi.driver === "mac80211_hwsim" && /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/i.test(svc.wifi.mac), why: () => root.j([svc.wifi.driver, svc.wifi.mac]) });
        step({ n: "no.errors.so.far", check: () => svc.errors.length === 0, why: () => root.j(svc.errors) });

        // ---- an open network behind a portal: the NET pad amber, the auto-tunnel waits, the login, green, the tunnel -----------------------------
        step({ n: "portal.armed", act: () => root.armPortal(true), wait: 300 });
        step({ n: "open.joins", act: () => svc.connect("rig-open"), until: () => root.onNet("rig-open") && root.net("rig-open").known, ms: 60000, tm: "joinOpen", why: () => root.j([svc.wifi.active, root.net("rig-open"), svc.errors]) });
        step({ n: "open.profile.is.public", check: () => root.net("rig-open").trusted === false, why: () => root.j(root.net("rig-open")) });
        step({ n: "pads.gateway.ok", until: () => root.padState("gateway") === "ok", ms: 30000, why: () => root.j(svc.health.pads) });
        step({ n: "pad.net.amber.behind.the.portal", act: () => svc.testPad("net"), until: () => root.padState("net") === "warn" && svc.health.portal.present === true, ms: 30000, why: () => root.j([svc.health.pads, svc.health.portal]) });
        step({ n: "auto.tunnel.waits.for.the.portal", until: () => svc.proton.waiting === "portal", ms: 15000, why: () => root.j(svc.proton) });
        step({ n: "auto.tunnel.not.raised.yet", wait: 2000, check: () => root.argvCount("connect") === 0 && svc.proton.state === "down", why: () => root.j([svc.proton.state, root.argvCount("connect")]) });
        step({ n: "portal.login", act: () => root.tool(["curl", "-s", "-o", "/dev/null", "-X", "POST", "http://10.77.0.1:8080/login"]), until: () => root.exits >= 1, ms: 10000, why: () => "curl did not exit" });
        step({ n: "pad.net.green.after.the.login", act: () => svc.testPad("net"), until: () => root.padState("net") === "ok", ms: 30000, why: () => root.j(svc.health.pads) });
        step({ n: "auto.tunnel.raises.after.the.login", until: () => svc.proton.state === "up" && svc.proton.server !== null, ms: 40000, tm: "autoTunnel", why: () => root.j([svc.proton, svc.health.pads, root.argvCount("connect")]) });
        step({ n: "auto.tunnel.once", check: () => root.osdCount("autoTunnel") === 1 && root.argvCount("connect") === 1 && svc.proton.waiting === "", why: () => root.j([root.osds, root.argvCount("connect"), svc.proton.waiting]) });

        // ---- WPA2: a wrong password, then the right one on the same profile ---------------------------------------------------------------------
        step({ n: "wpa2.wrong.password.fails", act: () => svc.connect("rig-wpa2", { password: "not-the-password" }),
            until: () => root.net("rig-wpa2").state === "failed" || root.net("rig-wpa2").state === "needsSecret", ms: 90000, tm: "wrongPassword", why: () => root.j([root.net("rig-wpa2"), svc.errors]) });
        step({ n: "wpa2.wrong.password.says.so", check: () => /password|secret|auth/i.test(root.net("rig-wpa2").failReason + " " + root.j(root.errFor("net:rig-wpa2"))), why: () => root.j([root.net("rig-wpa2").failReason, svc.errors]) });
        step({ n: "wpa2.joins.with.the.password", act: () => svc.connect("rig-wpa2", { password: "rig-pass-wpa2" }), until: () => root.onNet("rig-wpa2"), ms: 60000, tm: "joinWpa2", why: () => root.j([svc.wifi.active, root.net("rig-wpa2"), svc.errors]) });

        // ---- roaming between the two radios of rig-wpa2: the one we are on goes away (hostapd_cli disable), the other takes over -----------------
        step({ n: "roam.away", act: () => {
            root.roamFrom = svc.wifi.active.bssid;
            root.roamChan = svc.wifi.active.channel;
            root.tool(["hostapd_cli", "-p", root.run + "/hostapd", "-i", root.roamChan === 1 ? root.apA : root.apB, "disable"]);
        }, until: () => root.onNet("rig-wpa2") && svc.wifi.active.bssid !== root.roamFrom && svc.wifi.active.bssid !== "", ms: 90000, tm: "roam", why: () => root.j([root.roamFrom, root.roamChan, svc.wifi.active, root.net("rig-wpa2")]) });
        step({ n: "roam.back", act: () => root.tool(["hostapd_cli", "-p", root.run + "/hostapd", "-i", root.roamChan === 1 ? root.apA : root.apB, "enable"]), until: () => root.net("rig-wpa2").aps.length === 2, ms: 60000, why: () => root.j(root.net("rig-wpa2").aps) });

        // ---- WPA3-SAE, a hidden network, 802.1X with the rig's CA (PEAP, then TTLS) ----------------------------------------------------------------
        step({ n: "wpa3.joins", act: () => svc.connect("rig-wpa3", { password: "rig-pass-wpa3" }), until: () => root.onNet("rig-wpa3"), ms: 60000, tm: "joinWpa3", why: () => root.j([svc.wifi.active, root.net("rig-wpa3"), svc.errors]) });
        step({ n: "hidden.joins.by.its.name", act: () => svc.connect(root.hiddenNet().key, { hiddenSsid: "rig-hidden", password: "rig-pass-hidden" }), until: () => root.onNet("rig-hidden"), ms: 60000, tm: "joinHidden", why: () => root.j([svc.wifi.active, svc.errors]) });
        step({ n: "peap.joins", act: () => svc.connect("rig-eap", { eap: { method: "peap", phase2: "mschapv2", identity: "rig-user", anonymousIdentity: "anonymous", password: "rig-pass-eap", caCert: root.run + "/ca.pem" } }),
            until: () => root.onNet("rig-eap"), ms: 60000, tm: "joinPeap", why: () => root.j([svc.wifi.active, root.net("rig-eap"), svc.errors]) });
        step({ n: "peap.forgotten", act: () => svc.forget(root.prof("rig-eap").uuid), until: () => root.prof("rig-eap") === null && svc.wifi.active === null, ms: 20000, why: () => root.j([svc.wifi.profiles.map(p => p.name), svc.wifi.active]) });
        step({ n: "ttls.joins", act: () => svc.connect("rig-eap", { eap: { method: "ttls", phase2: "mschapv2", identity: "rig-user", anonymousIdentity: "anonymous", password: "rig-pass-eap", caCert: root.run + "/ca.pem" } }),
            until: () => root.onNet("rig-eap"), ms: 60000, tm: "joinTtls", why: () => root.j([svc.wifi.active, root.net("rig-eap"), svc.errors]) });
        step({ n: "dbm.and.rates.come.from.the.rig", until: () => svc.wifi.active !== null && svc.rates.iface === root.client, ms: 10000, why: () => root.j([svc.wifi.active && svc.wifi.active.dbm, svc.rates]) });

        // ---- the hotspot on the client radio, the phone joins it ---------------------------------------------------------------------------------
        step({ n: "hotspot.disconnect.first", act: () => svc.disconnect(), until: () => svc.wifi.active === null, ms: 20000, why: () => root.j(svc.wifi.active) });
        step({ n: "hotspot.configure", act: () => svc.configureHotspot({ ssid: "lares-spot", password: "hotspot-pass-1", band: "bg" }), until: () => svc.hotspot.uuid !== "" && svc.hotspot.ssid === "lares-spot", ms: 20000, why: () => root.j([svc.hotspot, svc.errors]) });
        step({ n: "hotspot.starts", act: () => svc.startHotspot(), until: () => svc.hotspot.active === true, ms: 60000, tm: "hotspotStart", why: () => root.j([svc.hotspot, svc.errors]) });
        step({ n: "hotspot.phone.joins", act: () => { root.exitsBefore = root.exits; root.tool(["bash", root.out + "/phone_join.sh", "lares-spot", "hotspot-pass-1"]); },
            until: () => svc.hotspot.clients.length >= 1, ms: 90000, tm: "hotspotClient", why: () => root.j([svc.hotspot.clients, svc.errors]) });
        step({ n: "hotspot.stops", act: () => svc.stopHotspot(), until: () => svc.hotspot.active === false && svc.hotspot.clients.length === 0, ms: 30000, why: () => root.j(svc.hotspot) });

        // ---- airplane on the rig's NetworkManager (its rfkill is masked: the safety snapshot afterwards proves the real card did not move) ---------
        step({ n: "airplane.on", act: () => svc.setAirplane(true), until: () => svc.wifi.radioOn === false && svc.airplane.on === true, ms: 30000, why: () => root.j([svc.wifi.radioOn, svc.airplane]) });
        step({ n: "airplane.off", act: () => svc.setAirplane(false), until: () => svc.wifi.radioOn === true && svc.airplane.on === false, ms: 30000, why: () => root.j([svc.wifi.radioOn, svc.airplane]) });
        step({ n: "helper.still.up", check: () => svc.helper.state === "up", why: () => root.j(svc.helper) });

        root.steps = S;
        ticker.start();
    }
}
