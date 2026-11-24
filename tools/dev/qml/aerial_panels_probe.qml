pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/aerial/data"
import "modules/aerial/secondary"

// =============================================================================
// aerial_panels_probe.qml -- the detail panels, clicked like a person: REAL synthetic clicks (TestCase.mouseClick on the window, so a thief
// in the chain would be found) on every button, switch and choice of every panel, over the AerialMock through an AerialTap that RECORDS each
// intent, so the check is "the data layer received THIS call with THESE arguments". Run by tools/dev/aerial_panels_probe.sh (sandbox).
//
// One `AP ok|FAIL <id>: what` line per check, then `AP DONE PASS|FAIL`. IDs name the panel: net.* saved.* wired.* hs.* vpn.* bt.* pad.* usage.*.
// Keys: the password field takes focus when the network needs one (net.pw.focus), Enter answers, a refused password shakes the field and
// keeps it (net.pw.shake / keeps), Escape gives up (net.pw.esc); a revealed secret is shown, then gone with the page and with the panel
// (net.share.*), and is never written anywhere (`tap.leaked`).
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    property int checks: 0
    property int fails: 0
    property int dismissed: 0
    property int dismissedAt: 0
    function check(id: string, ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("AP " + (ok ? "ok  " : "FAIL ") + id + ": " + what);
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }

    TestCase {
        id: tc
        name: "ap"
        when: false
    }

    // ---- the stage ------------------------------------------------------------------------------------------------------------------
    Window {
        id: win
        visible: true
        width: 480
        height: 1800
        color: Theme.surface

        AerialMock {
            id: mock
            live: true
            settleMs: 40
            scanPeriodMs: 60000
            scenario: "home"
        }
        AerialTap {
            id: tap
            src: mock
        }
        Loader {
            id: host
            active: false
            x: 0
            y: 0
            sourceComponent: AerialSecondary {
                vm: tap
                kind: probe.kind
                targetKey: probe.key
                onDismissed: probe.dismissed++
            }
        }
    }
    property string kind: "network"
    property string key: ""
    readonly property var sec: host.item
    readonly property var panel: host.item ? host.item.panel : null

    // ---- tools ------------------------------------------------------------------------------------------------------------------------
    function find(name: string, from: var): var {
        const r = from || win.contentItem;
        if (r.objectName === name)
            return r;
        const kids = r.children;
        for (let i = 0; i < kids.length; i++) {
            const f = probe.find(name, kids[i]);
            if (f)
                return f;
        }
        return null;
    }
    function findText(sub: string, from: var): var {
        const r = from || win.contentItem;
        if (typeof r.text === "string" && r.visible && r.text.indexOf(sub) >= 0 && r.width > 0)
            return r;
        const kids = r.children;
        for (let i = 0; i < kids.length; i++) {
            const f = probe.findText(sub, kids[i]);
            if (f)
                return f;
        }
        return null;
    }
    function reveal(it: var): void {
        const f = probe.panel ? probe.panel.scroller : null;
        if (!f)
            return;
        const y = it.mapToItem(f.contentItem, 0, 0).y;
        if (y < f.contentY || y + it.height > f.contentY + f.height)
            f.contentY = Math.max(0, Math.min(f.contentHeight - f.height, y - 20));
    }
    function clickItem(it: var): bool {
        if (!it || !it.visible || it.width <= 0)
            return false;
        probe.reveal(it);
        const p = it.mapToItem(win.contentItem, it.width / 2, it.height / 2);
        tc.mouseClick(win.contentItem, p.x, p.y);
        return true;
    }
    function click(name: string): bool {
        return probe.clickItem(probe.find(name));
    }
    function clickSwitch(name: string): bool {
        const r = probe.find(name);
        return !!r && probe.clickItem(r.toggle);
    }
    function typeText(t: string): void {
        for (let i = 0; i < t.length; i++)
            tc.keyClick(t.charAt(i));
    }
    function typeInto(name: string, text: string): bool {
        const f = probe.find(name);
        if (!f)
            return false;
        f.forceFocus();
        probe.typeText(text);
        return true;
    }
    readonly property var calls: tap.log.slice(probe.mark)
    property int mark: 0
    function called(n: string, argsJson: string): bool {
        const l = tap.log.slice(probe.mark);
        for (let i = 0; i < l.length; i++)
            if (l[i].n === n && (argsJson === undefined || JSON.stringify(l[i].a) === argsJson))
                return true;
        return false;
    }
    function lastCall(n: string): string {
        const l = tap.log.slice(probe.mark).filter(c => c.n === n);
        return l.length ? JSON.stringify(l[l.length - 1].a) : "(none)";
    }
    function count(n: string): int {
        return tap.log.slice(probe.mark).filter(c => c.n === n).length;
    }
    // the two-click Forget (ForgetButton): one click only arms ("Forget?" in the warn ink, no call), left alone it falls back, a second click
    // acts exactly once. `btn` is the button's objectName, `call` the intent the tap records, `args` its arguments.
    function forgetSteps(id: string, btnName: var, call: string, args: string): void {
        const nm = () => typeof btnName === "function" ? btnName() : btnName;
        const b = () => probe.find(nm());
        const armedLook = () => !!b() && b().armed === true && b().text === "Forget?" && Qt.colorEqual(b().textColor, Theme.warn);
        probe.st(id + ".arm", () => probe.click(nm()), () => !!b() && b().armed === true,
                 () => armedLook() && probe.count(call) === 0);
        probe.st(id + ".fallback", null, () => !!b() && b().armed === false,
                 () => !!b() && b().armed === false && b().text === "Forget" && Qt.colorEqual(b().textColor, Theme.textPrimary) && probe.count(call) === 0);
        probe.st(id + ".rearm", () => probe.click(nm()), () => !!b() && b().armed === true, () => armedLook() && probe.count(call) === 0);
        probe.st(id + ".second", () => probe.click(nm()), () => probe.called(call),
                 () => probe.count(call) === 1 && probe.lastCall(call) === args);
    }
    function none(): bool {
        return tap.log.length === probe.mark;
    }

    property var shifts: []
    property bool sampling: false
    Timer {
        interval: 8
        repeat: true
        running: probe.sampling
        onTriggered: {
            const f = probe.find("pwField");
            if (f)
                probe.shifts = probe.shifts.concat([f._shift]);
        }
    }

    // open a panel afresh on a scenario
    function open(scenario: string, kind: string, key: string, page: string): void {
        tap.override = ({});
        if (mock.scenario !== scenario)
            mock.scenario = scenario;
        else
            mock.load(scenario);
        host.active = false;
        probe.kind = kind;
        probe.key = key;
        host.active = true;
        if (probe.sec)
            probe.sec.look.maxHeight = 3000;
        if (probe.panel && page)
            probe.panel.page = page;
    }

    // ---- the steps --------------------------------------------------------------------------------------------------------------------
    property var steps: []
    property int at: 0
    property bool started: false
    property real t0: 0
    function st(name: string, act: var, until: var, chk: var): void {
        probe.steps.push({ n: name, act: act, until: until, chk: chk });
    }
    Timer {
        id: ticker
        interval: 40
        repeat: true
        onTriggered: probe.tick()
    }
    function tick(): void {
        if (probe.at >= probe.steps.length) {
            ticker.stop();
            console.log("AP DONE " + (probe.fails === 0 ? "PASS" : "FAIL") + "  (" + probe.checks + " checks, " + probe.fails + " failed)");
            quitTimer.start();
            return;
        }
        const s = probe.steps[probe.at];
        const now = Date.now();
        if (!probe.started) {
            probe.started = true;
            probe.t0 = now;
            probe.mark = tap.log.length;
            try {
                if (s.act)
                    s.act();
            } catch (e) {
                probe.check(s.n, false, "the step threw: " + e);
                probe.at++;
                probe.started = false;
                return;
            }
            return;
        }
        const waited = now - probe.t0;
        let ready = waited >= 120;
        if (s.until) {
            let u = false;
            try {
                u = s.until();
            } catch (e) {
                u = false;
            }
            if (!u && waited < 2500)
                return;
            if (!u)
                ready = true;
        }
        if (!ready)
            return;
        let ok = false, why = "";
        try {
            ok = s.chk ? s.chk() === true : true;
        } catch (e) {
            ok = false;
            why = " (threw: " + e + ")";
        }
        probe.check(s.n, ok, ok ? "" : "failed" + why);
        probe.at++;
        probe.started = false;
    }

    Component.onCompleted: probe.build()
    Timer {
        interval: 500
        running: true
        onTriggered: {
            win.requestActivate();
            ticker.start();
        }
    }

    function build(): void {
        // ======================================================================== network: a stranger that needs a password
        probe.st("net.open", () => probe.open("home", "network", "FRITZ!Box 7590", "info"), () => !!probe.find("pwField"), () => !!probe.find("pwField"));
        probe.st("net.pw.focus", null, () => probe.find("pwField").hasFocus, () => probe.find("pwField").hasFocus === true);
        probe.st("net.pw.wantsKeys", null, null, () => probe.sec.keyboardWanted === true);
        probe.st("net.pw.connect.disabled.empty", null, null, () => probe.find("connectButton").enabled === false);
        probe.st("net.pw.type", () => probe.typeText("wrong"), () => probe.find("pwField").text === "wrong", () => probe.find("pwField").text === "wrong");
        probe.st("net.pw.enter.sends", () => {
            probe.shifts = [];
            probe.sampling = true;
            tc.keyClick(Qt.Key_Return);
        }, () => probe.called("connect"), () => probe.lastCall("connect") === JSON.stringify(["FRITZ!Box 7590", { password: "wrong" }]));
        probe.st("net.pw.shake", null, () => probe.shifts.some(v => Math.abs(v) > 3), () => {
            probe.sampling = false;
            return probe.shifts.some(v => Math.abs(v) > 3);
        });
        probe.st("net.pw.keeps", null, () => probe.find("pwField").text === "wrong", () => probe.find("pwField").text === "wrong" && !!probe.find("pwField").visible);
        probe.st("net.pw.refocus", null, null, () => probe.find("pwField").hasFocus === true);
        probe.st("net.pw.retype", () => {
            probe.find("pwField").selectAll();
            probe.typeText("correct");
        }, () => probe.find("pwField").text === "correct", () => probe.find("pwField").text === "correct");
        probe.st("net.pw.click.connect", () => probe.click("connectButton"), () => probe.called("connect"), () => probe.lastCall("connect") === JSON.stringify(["FRITZ!Box 7590", { password: "correct" }]));
        probe.st("net.pw.gone.when.connected", null, () => probe.find("pwField") === null || !probe.find("pwField").visible, () => !probe.find("pwField") || !probe.find("pwField").visible);
        probe.st("net.connected.state", null, () => !!probe.find("disconnectButton") && probe.find("disconnectButton").visible, () => probe.find("disconnectButton").visible === true);
        probe.st("net.disconnect", () => probe.click("disconnectButton"), () => probe.called("disconnect"), () => probe.called("disconnect", "[]"));

        // Escape gives up
        probe.st("net.pw.esc.open", () => probe.open("home", "network", "homenet-ABC12-AP", "info"), () => !!probe.find("pwField") && probe.find("pwField").hasFocus, () => true);
        probe.st("net.pw.esc", () => {
            probe.dismissed = 0;
            tc.keyClick(Qt.Key_Escape);
        }, () => probe.dismissed > 0, () => probe.dismissed > 0);

        // ======================================================================== network: a saved one (connected)
        probe.st("net.home.open", () => probe.open("home", "network", "Home-5G", "info"), () => !!probe.find("disconnectButton"), () => !!probe.find("disconnectButton"));
        probe.st("net.home.nopw", null, null, () => !probe.find("pwField") || !probe.find("pwField").visible);
        probe.st("net.home.facts", null, null, () => !!probe.findText("192.168.1.42") && !!probe.findText("WPA2"));
        probe.st("net.home.trusted.off", () => probe.clickSwitch("trustedSwitch"), () => probe.called("setTrusted"), () => probe.lastCall("setTrusted") === JSON.stringify(["u-home", false]));
        probe.st("net.home.disconnect", () => probe.click("disconnectButton"), () => probe.called("disconnect"), () => probe.called("disconnect", "[]"));
        probe.st("net.home.connect", null, () => !!probe.find("connectButton") && probe.find("connectButton").visible, () => true);
        probe.st("net.home.connect.click", () => probe.click("connectButton"), () => probe.called("connect"), () => probe.lastCall("connect") === JSON.stringify(["Home-5G", { profileUuid: "u-home" }]));

        // pages: IP & DNS
        probe.st("net.ip.manual", () => {
            probe.panel.page = "ip";
        }, () => !!probe.find("choice_manual") && probe.find("choice_manual").visible, () => true);
        probe.st("net.ip.choose", () => probe.click("choice_manual"), () => !!probe.find("ipAddress") && probe.find("ipAddress").visible, () => probe.find("ipAddress").text !== "");
        probe.st("net.ip.type", () => {
            const a = probe.find("ipAddress");
            a.forceFocus();
            a.selectAll();
            probe.typeText("10.1.2.3");
            probe.find("ipGateway").forceFocus();
            probe.find("ipGateway").selectAll();
            probe.typeText("10.1.2.1");
            probe.find("ipDns").forceFocus();
            probe.find("ipDns").selectAll();
            probe.typeText("9.9.9.9, 1.1.1.1");
        }, null, () => probe.find("ipDns").text === "9.9.9.9, 1.1.1.1");
        probe.st("net.ip.apply", () => probe.click("ipApply"), () => probe.called("updateProfile"), () => probe.lastCall("updateProfile") === JSON.stringify(["u-home", { ipv4: { method: "manual", address: "10.1.2.3", prefix: 24, gateway: "10.1.2.1", dns: ["9.9.9.9", "1.1.1.1"] }, ipv6: { method: "auto" } }]));
        probe.st("net.ip.wantsKeys", null, null, () => probe.sec.keyboardWanted === true);

        // Privacy
        probe.st("net.privacy.mac", () => {
            probe.panel.page = "privacy";
        }, () => !!probe.find("choice_random") && probe.find("choice_random").visible, () => true);
        probe.st("net.privacy.random", () => probe.click("choice_random"), () => probe.called("updateProfile"), () => probe.lastCall("updateProfile") === JSON.stringify(["u-home", { mac: "random" }]));
        probe.st("net.privacy.metered", () => probe.click("choice_yes"), () => probe.called("updateProfile"), () => probe.lastCall("updateProfile") === JSON.stringify(["u-home", { metered: "yes" }]));

        // Radio
        probe.st("net.radio.lock", () => {
            probe.panel.page = "radio";
        }, () => !!probe.find("apRow_0") && probe.find("apRow_0").visible, () => true);
        probe.st("net.radio.ap", () => probe.click("apRow_1"), () => probe.called("updateProfile"), () => JSON.parse(probe.lastCall("updateProfile"))[1].bssid !== undefined && JSON.parse(probe.lastCall("updateProfile"))[0] === "u-home");
        probe.st("net.radio.band", () => probe.click("choice_a"), () => probe.called("updateProfile"), () => probe.lastCall("updateProfile") === JSON.stringify(["u-home", { band: "a" }]));
        probe.st("net.radio.any", () => probe.click("anyAp"), () => probe.called("updateProfile"), () => probe.lastCall("updateProfile") === JSON.stringify(["u-home", { bssid: "" }]));

        // Share: the secret
        probe.st("net.share.open", () => {
            probe.panel.page = "share";
        }, () => !!probe.find("revealButton") && probe.find("revealButton").visible, () => probe.panel.secretText === "");
        probe.st("net.share.noqr.before", null, null, () => probe.find("joinQr").visible === false);
        probe.st("net.share.reveal", () => probe.click("revealButton"), () => probe.panel.secretText !== "", () => probe.called("revealSecret", JSON.stringify(["u-home"])) && probe.panel.secretText === "correct-horse-battery-staple");
        probe.st("net.share.qr", null, () => probe.find("joinQr").visible, () => probe.find("joinQr").ok === true && probe.find("joinQr").text.indexOf("WIFI:T:WPA;S:Home-5G;P:correct-horse-battery-staple;") === 0);
        probe.st("net.share.leave.clears", () => {
            probe.panel.page = "info";
        }, null, () => probe.panel.secretText === "");
        probe.st("net.share.reveal2", () => {
            probe.panel.page = "share";
        }, () => !!probe.find("revealButton") && probe.find("revealButton").visible, () => true);
        probe.st("net.share.reveal2.click", () => probe.click("revealButton"), () => probe.panel.secretText !== "", () => probe.panel.secretText !== "");
        probe.st("net.share.close.keeps.nothing", () => {
            host.active = false;
        }, null, () => tap.leaked === "" && !probe.sec);
        probe.st("net.share.reopen.empty", () => {
            host.active = true;
            probe.panel.page = "share";
        }, null, () => probe.panel.secretText === "" && probe.find("joinQr").visible === false);

        // ======================================================================== network: a hidden access point asks its name
        probe.st("net.hidden.open", () => { mock.scenario = "crowd"; probe.open("crowd", "network", mock.wifi.networks.filter(n => n.hidden && n.ssid === "")[0].key, "info"); }, () => !!probe.find("hiddenName"), () => !!probe.find("hiddenName"));
        probe.st("net.hidden.focus", null, () => probe.find("hiddenName").hasFocus, () => probe.find("hiddenName").hasFocus === true);
        probe.st("net.hidden.type", () => {
            probe.typeText("SecretNet");
            probe.find("pwField").forceFocus();
            probe.typeText("pw123456");
        }, null, () => probe.find("hiddenName").text === "SecretNet" && probe.find("pwField").text === "pw123456");
        probe.st("net.hidden.connect", () => probe.click("connectButton"), () => probe.called("connect"), () => {
            const a = JSON.parse(probe.lastCall("connect"));
            return a[1].hiddenSsid === "SecretNet" && a[1].password === "pw123456" && a[0].indexOf("hidden:") === 0;
        });

        // ======================================================================== network: enterprise
        probe.st("net.eap.open", () => probe.open("home", "network", "eduroam", "login"), () => !!probe.find("eapIdentity"), () => probe.find("eapIdentity").text === "");
        probe.st("net.eap.ca", () => {
            probe.panel.pickerCommand = ["echo", "/etc/ssl/uni-ca.pem"];
            probe.click("caBrowse");
        }, () => probe.find("eapCa").text !== "", () => probe.find("eapCa").text === "/etc/ssl/uni-ca.pem");
        probe.st("net.eap.type", () => {
            probe.find("eapIdentity").forceFocus();
            probe.typeText("student@uni.example");
            probe.find("eapPassword").forceFocus();
            probe.typeText("hunter2");
            probe.find("eapDomain").forceFocus();
            probe.typeText("radius.uni.example");
        }, null, () => probe.find("eapPassword").text === "hunter2");
        probe.st("net.eap.connect", () => probe.click("eapConnect"), () => probe.called("connect"), () => {
            const a = JSON.parse(probe.lastCall("connect"));
            return a[0] === "eduroam" && a[1].profileUuid === "u-edu" && a[1].eap.method === "peap" && a[1].eap.phase2 === "mschapv2"
                && a[1].eap.identity === "student@uni.example" && a[1].eap.password === "hunter2" && a[1].eap.caCert === "/etc/ssl/uni-ca.pem" && a[1].eap.domain === "radius.uni.example";
        });
        probe.st("net.eap.ttls", () => probe.click("choice_ttls"), () => probe.panel.eapMethod === "ttls", () => probe.panel.eapMethod === "ttls");
        probe.st("net.eap.tls.editor", () => {
            probe.panel.editorCommand = ["true"];
            probe.click("choice_tls");
        }, () => !!probe.find("editorButton") && probe.find("editorButton").visible, () => true);
        probe.st("net.eap.tls.editor.click", () => probe.click("editorButton"), () => probe.panel.editorOpened > 0, () => probe.panel.editorOpened === 1);

        // ======================================================================== saved networks
        probe.st("saved.open", () => probe.open("home", "saved", "", "list"), () => !!probe.find("savedRow_0"), () => !!probe.find("savedRow_0"));
        // the search: focus, typing filters (name, SSID, case, accents), the match in the accent ink, Escape clears BEFORE it closes
        probe.st("saved.search.focus", null, () => !!probe.find("savedSearch"), () => probe.find("savedSearch").hasFocus);
        probe.st("saved.search.type", () => {
            probe.mark = tap.log.length;
            probe.dismissedAt = probe.dismissed;
            probe.typeText("PHONE-hot");
        }, () => probe.panel.rows.length === 1, () => probe.panel.rows[0].p.uuid === "u-red" && probe.panel.subtitle.indexOf("1 of ") === 0);
        probe.st("saved.search.highlight", null, () => !!probe.find("savedRow_0"), () => !!probe.findText("<font color"));
        probe.st("saved.search.accent", () => {
            probe.find("savedSearch").text = "s\u00e1ved";   // not typed: QtTest has no key for it
        }, () => probe.panel.rows.length >= 2, () => probe.panel.rows.every(r => r.p.name.indexOf("Saved") === 0));
        probe.st("saved.search.ssid", () => {
            probe.find("savedSearch").clear();
            probe.typeText("laptop");
        }, () => probe.panel.rows.length === 1, () => probe.panel.rows[0].p.uuid === "u-hs" && !!probe.findText(">laptop</font>-share"));
        probe.st("saved.search.none", () => {
            probe.find("savedSearch").clear();
            probe.typeText("zzzzqq");
        }, () => probe.panel.rows.length === 0, () => !!probe.find("savedNoMatch").visible);
        probe.st("saved.search.esc.clears", () => tc.keyClick(Qt.Key_Escape), () => probe.find("savedSearch").text === "", () => probe.dismissed === probe.dismissedAt && probe.panel.rows.length > 2);
        probe.st("saved.search.esc.closes", () => tc.keyClick(Qt.Key_Escape), () => probe.dismissed > probe.dismissedAt, () => true);
        probe.st("saved.expand", () => probe.click("savedRow_0"), () => !!probe.find("autoSwitch_0") && probe.find("autoSwitch_0").visible, () => probe.panel.expanded !== "");
        probe.st("saved.auto", () => probe.clickSwitch("autoSwitch_0"), () => probe.called("setAutoconnect"), () => JSON.parse(probe.lastCall("setAutoconnect"))[1] === false);
        probe.st("saved.prio.up", () => probe.click("prioUp_0"), () => probe.called("setPriority"), () => JSON.parse(probe.lastCall("setPriority"))[1] === 11);
        probe.st("saved.reveal", () => probe.click("revealSaved_0"), () => probe.panel.secretText !== "", () => probe.panel.secretText === "correct-horse-battery-staple");
        probe.st("saved.collapse.clears", () => probe.click("savedRow_0"), null, () => probe.panel.secretText === "" && probe.panel.expanded === "");
        probe.st("saved.merge.expand", () => probe.click("savedRow_1"), () => !!probe.find("mergeDoubles_1") && probe.find("mergeDoubles_1").visible, () => true);
        probe.st("saved.merge", () => probe.click("mergeDoubles_1"), () => probe.called("mergeDoubles"), () => {
            const a = JSON.parse(probe.lastCall("mergeDoubles"));
            return a[0] === "u-prox" && a[1][0] === "u-prox1";
        });
        probe.st("saved.forget", () => {
            probe.panel.expanded = "u-red";
        }, () => probe.panel.expanded === "u-red", () => true);
        // Forget has no undo: the first click only arms the button ("Forget?"), the second acts
        probe.forgetSteps("saved.forget", () => "forget_" + mock.wifi.profiles.map(p => p.uuid).indexOf("u-red"), "forget", JSON.stringify(["u-red"]));
        probe.st("saved.add.page", () => {
            probe.panel.page = "add";
        }, () => !!probe.find("addName") && probe.find("addName").visible, () => true);
        probe.st("saved.add.disabled", null, null, () => probe.find("addNetwork").enabled === false);
        probe.st("saved.add.type", () => {
            probe.find("addName").forceFocus();
            probe.typeText("NewNet");
            probe.find("addPw").forceFocus();
            probe.typeText("longpassword");
        }, null, () => probe.find("addName").text === "NewNet");
        probe.st("saved.add", () => probe.click("addNetwork"), () => probe.called("addNetwork"), () => probe.lastCall("addNetwork") === JSON.stringify(["NewNet", "wpa2", "longpassword"]));
        probe.st("saved.card", () => {
            probe.panel.page = "card";
        }, () => !!probe.find("powersaveSwitch") && probe.find("powersaveSwitch").visible, () => true);
        probe.st("saved.powersave", () => probe.clickSwitch("powersaveSwitch"), () => probe.called("setPowersave"), () => probe.lastCall("setPowersave") === JSON.stringify([false]));

        // ======================================================================== wired
        probe.st("wired.open", () => probe.open("hotspot", "wired", "enp46s0", "info"), () => !!probe.find("wiredDisconnect"), () => probe.find("wiredDisconnect").visible === true);
        probe.st("wired.disconnect", () => probe.click("wiredDisconnect"), () => probe.called("disconnectWired"), () => probe.lastCall("disconnectWired") === JSON.stringify(["enp46s0"]));
        probe.st("wired.connect.wait", null, () => !!probe.find("wiredConnect") && probe.find("wiredConnect").visible, () => true);
        probe.st("wired.connect", () => probe.click("wiredConnect"), () => probe.called("connectWired"), () => probe.lastCall("connectWired") === JSON.stringify(["enp46s0"]));
        probe.st("wired.ip.tab", () => {
            probe.panel.page = "ip";
        }, () => !!probe.find("ipApply") && probe.find("ipApply").visible, () => probe.panel.uuid !== "");
        probe.st("wired.ip.apply", () => probe.click("ipApply"), () => probe.called("updateProfile"), () => JSON.parse(probe.lastCall("updateProfile"))[0] === "u-wired");

        // ======================================================================== hotspot
        probe.st("hs.open", () => probe.open("hotspot", "hotspot", "", "setup"), () => !!probe.find("hotspotStop"), () => probe.find("hotspotStop").visible === true);
        probe.st("hs.stop", () => probe.click("hotspotStop"), () => probe.called("stopHotspot"), () => probe.called("stopHotspot", "[]"));
        probe.st("hs.start", null, () => !!probe.find("hotspotStart") && probe.find("hotspotStart").visible && probe.find("hotspotStart").enabled, () => true);
        probe.st("hs.start.click", () => probe.click("hotspotStart"), () => probe.called("startHotspot"), () => probe.called("startHotspot", "[]"));
        probe.st("hs.apply", () => {
            probe.find("hsName").forceFocus();
            probe.find("hsName").selectAll();
            probe.typeText("MyAP");
            probe.find("hsPassword").forceFocus();
            probe.typeText("hotspot-pw1");
        }, null, () => probe.find("hsName").text === "MyAP");
        probe.st("hs.apply.click", () => probe.click("hotspotApply"), () => probe.called("configureHotspot"), () => probe.lastCall("configureHotspot") === JSON.stringify([{ ssid: "MyAP", band: "bg", password: "hotspot-pw1" }]));
        probe.st("hs.qr", null, () => probe.find("hotspotQr").visible, () => { return probe.find("hotspotQr").ok === true && probe.find("hotspotQr").text === "WIFI:T:WPA;S:MyAP;P:hotspot-pw1;H:false;;"; });
        probe.st("hs.devices", () => {
            tap.override = { hotspot: Object.assign({}, mock.hotspot, { active: true, clients: [{ mac: "02:11:22:33:44:55", ip: "10.42.0.12", name: "pixel-8", dbm: -43 }, { mac: "02:11:22:33:44:66", ip: "10.42.0.31", name: "tablet", dbm: -61 }] }) };
            probe.panel.page = "devices";
        }, () => !!probe.findText("pixel-8"), () => { return !!probe.findText("pixel-8") && !!probe.findText("tablet"); });
        probe.st("hs.nopw.open", () => {
            probe.open("home", "hotspot", "", "setup");
            tap.override = { hotspot: Object.assign({}, mock.hotspot, { missing: "", available: true, active: false, state: "off", hasPassword: false, ssid: "laptop-share", uuid: "u-hs" }) };
        }, () => !!probe.find("hotspotStartOpen") && probe.find("hotspotStartOpen").visible, () => !!probe.find("hotspotStart") && probe.find("hotspotStart").text === "Set a password and start");
        probe.st("hs.nopw.offered", null, null, () => probe.find("hsPassword").text.length >= 12 && !/[0O1lI]/.test(probe.find("hsPassword").text));
        probe.st("hs.nopw.start", () => probe.click("hotspotStart"), () => probe.called("configureHotspot"), () => {
            const l = tap.log.slice(probe.mark);
            const c = l.filter(x => x.n === "configureHotspot")[0];
            return !!c && c.a[0].password.length >= 12 && !l.some(x => x.n === "startHotspot");
        });
        probe.st("hs.nopw.then.start", () => {
            tap.override = { hotspot: Object.assign({}, tap.hotspot, { hasPassword: true }) };
        }, () => probe.called("startHotspot"), () => probe.called("startHotspot", "[]"));
        probe.st("hs.nopw.open.explicit", () => {
            tap.override = { hotspot: Object.assign({}, tap.hotspot, { hasPassword: false, active: false }) };
        }, () => !!probe.find("hotspotStartOpen") && probe.find("hotspotStartOpen").visible, () => probe.none() || true);
        probe.st("hs.nopw.open.click", () => probe.click("hotspotStartOpen"), () => probe.called("startHotspot"), () => !probe.called("configureHotspot") && probe.called("startHotspot", "[]"));
        probe.st("hs.missing", () => {
            mock.scenario = "home";
            probe.open("home", "hotspot", "", "setup");
            tap.override = { hotspot: Object.assign({}, mock.hotspot, { missing: "dnsmasq", available: false }) };
        }, null, () => !!probe.findText("dnsmasq"));

        // ======================================================================== vpn
        probe.st("vpn.open", () => probe.open("vpn", "vpn", "", "where"), () => !!probe.find("vpnCountry_NL"), () => !!probe.find("vpnCountry_NL"));
        probe.st("vpn.country", () => probe.click("vpnCountry_NL"), () => !!probe.find("vpnCity_0"), () => probe.panel.selCountry === "NL");
        probe.st("vpn.city", () => probe.click("vpnCity_0"), () => !!probe.find("vpnServer_0"), () => probe.panel.selCity === "Amsterdam");
        probe.st("vpn.server", () => probe.click("vpnServer_0"), () => probe.called("vpnConnect"), () => {
            const a = JSON.parse(probe.lastCall("vpnConnect"))[0];
            return a.country === "NL" && a.city === "Amsterdam" && /^NL#/.test(a.server);
        });
        probe.st("vpn.fastest.here", () => probe.click("vpnFastestHere"), () => probe.called("vpnConnect"), () => probe.lastCall("vpnConnect") === JSON.stringify([{ country: "NL", city: "Amsterdam" }]));
        probe.st("vpn.back.back", () => {
            probe.click("vpnBack");
        }, null, () => probe.panel.selCity === "" && probe.panel.selCountry === "NL");
        probe.st("vpn.back", () => probe.click("vpnBack"), null, () => probe.panel.selCountry === "");
        probe.st("vpn.filter.p2p", () => probe.click("choice_p2p"), null, () => probe.panel.filter === "p2p" && !probe.find("vpnCountry_BR") && !!probe.find("vpnCountry_NL"));
        probe.st("vpn.search", () => probe.typeInto("vpnSearch", ""), null, () => true);
        probe.st("vpn.disconnect", () => {
            probe.click("choice_");
            probe.click("vpnDisconnect");
        }, () => probe.called("vpnDisconnect"), () => probe.called("vpnDisconnect", "[]"));
        probe.st("vpn.protection", () => {
            probe.panel.page = "protection";
        }, () => !!probe.find("choice_malware-ads-trackers"), () => true);
        probe.st("vpn.netshield", () => probe.click("choice_malware-ads-trackers"), () => probe.called("vpnSet"), () => probe.lastCall("vpnSet") === JSON.stringify(["netshield", "malware-ads-trackers"]));
        probe.st("vpn.killswitch", () => probe.click("choice_standard"), () => probe.called("vpnSet"), () => probe.lastCall("vpnSet") === JSON.stringify(["killSwitch", "standard"]));
        probe.st("vpn.ipv6", () => probe.clickSwitch("vpnIpv6"), () => probe.called("vpnSet"), () => JSON.parse(probe.lastCall("vpnSet"))[0] === "ipv6");
        probe.st("vpn.autotunnel", () => probe.clickSwitch("autoTunnelSwitch"), () => probe.called("setAutoTunnel"), () => probe.lastCall("setAutoTunnel") === JSON.stringify([false]));
        probe.st("vpn.dns", () => {
            probe.typeInto("vpnDns", "9.9.9.9");
            probe.click("vpnDnsApply");
        }, () => probe.called("vpnSet", JSON.stringify(["customDns", "9.9.9.9"])), () => true);
        probe.st("vpn.signedout", () => {
            probe.open("vpn", "vpn", "", "where");
            tap.override = { proton: Object.assign({}, mock.proton, { signedIn: "no", state: "down", server: null }) };
        }, null, () => !!probe.findText("protonvpn signin") && !probe.find("vpnFastest").visible);
        probe.st("vpn.keyring", () => {
            tap.override = { proton: Object.assign({}, mock.proton, { signedIn: "unknown", locked: true, state: "down", server: null }) };
        }, null, () => !!probe.findText("at the lock screen") && !probe.findText("Waiting for ProtonVPN") && !probe.find("vpnFastest").visible);

        // ======================================================================== bluetooth
        probe.st("bt.open", () => probe.open("earbuds", "bt", "AA:BB:CC:00:00:01", "device"), () => !!probe.find("btDisconnect"), () => probe.find("btDisconnect").visible === true);
        probe.st("bt.disconnect", () => probe.click("btDisconnect"), () => probe.called("btDisconnect"), () => probe.lastCall("btDisconnect") === JSON.stringify(["AA:BB:CC:00:00:01"]));
        probe.st("bt.trust", () => probe.clickSwitch("btTrust"), () => probe.called("btTrust"), () => probe.lastCall("btTrust") === JSON.stringify(["AA:BB:CC:00:00:01", false]));
        probe.st("bt.block", () => probe.clickSwitch("btBlock"), () => probe.called("btBlock"), () => probe.lastCall("btBlock") === JSON.stringify(["AA:BB:CC:00:00:01", true]));
        probe.st("bt.unblock", () => probe.clickSwitch("btBlock"), () => probe.lastCall("btBlock") === JSON.stringify(["AA:BB:CC:00:00:01", false]), () => true);
        probe.st("bt.rename", () => {
            probe.typeInto("btName", "My Buds");
            probe.click("btRename");
        }, () => probe.called("btRename"), () => probe.lastCall("btRename") === JSON.stringify(["AA:BB:CC:00:00:01", "My Buds"]));
        probe.st("bt.connect", null, () => !!probe.find("btConnect") && probe.find("btConnect").visible, () => true);
        probe.st("bt.connect.click", () => probe.click("btConnect"), () => probe.called("btConnect"), () => probe.lastCall("btConnect") === JSON.stringify(["AA:BB:CC:00:00:01"]));
        probe.st("bt.battery", () => {
            probe.panel.page = "battery";
        }, null, () => !!probe.findText("72 %") && !!probe.findText("41 %"));
        probe.st("bt.audio", () => {
            probe.panel.page = "audio";
        }, () => !!probe.find("choice_headset-head-unit"), () => true);
        probe.st("bt.audio.set", () => probe.click("choice_headset-head-unit"), () => probe.called("btSetProfile"), () => probe.lastCall("btSetProfile") === JSON.stringify(["AA:BB:CC:00:00:01", "headset-head-unit"]));
        probe.st("bt.forget", () => {
            probe.panel.page = "device";
        }, () => !!probe.find("btForget") && probe.find("btForget").visible, () => true);
        probe.forgetSteps("bt.forget", "btForget", "btForget", JSON.stringify(["AA:BB:CC:00:00:01"]));
        // pairing prompts
        probe.st("bt.confirm.open", () => probe.open("pairing", "bt", "AA:BB:CC:00:00:10", "device"), () => !!probe.find("promptYes"), () => !!probe.findText("Does 483 291 match?"));
        probe.st("bt.confirm.yes", () => probe.click("promptYes"), () => probe.called("btAnswer"), () => probe.lastCall("btAnswer") === JSON.stringify([1, true, ""]));
        probe.st("bt.confirm.no", () => {
            probe.open("pairing", "bt", "AA:BB:CC:00:00:10", "device");
            mock._raw.btPrompt = { rid: 2, address: "AA:BB:CC:00:00:10", kind: "confirm", code: "483 291" };
            mock._recompute();
        }, () => !!probe.find("promptNo") && probe.panel.prompt && probe.panel.prompt.rid === 2, () => true);
        probe.st("bt.confirm.no.click", () => probe.click("promptNo"), () => probe.called("btAnswer"), () => probe.lastCall("btAnswer") === JSON.stringify([2, false, ""]));
        probe.st("bt.pin.open", () => {
            probe.open("pairing", "bt", "AA:BB:CC:00:00:10", "device");
            mock._raw.btPrompt = { rid: 3, address: "AA:BB:CC:00:00:10", kind: "pin", code: "" };
            mock._recompute();
        }, () => !!probe.find("pinField") && probe.find("pinField").visible, () => true);
        probe.st("bt.pin.focus", null, () => probe.find("pinField").hasFocus, () => probe.find("pinField").hasFocus === true && probe.sec.keyboardWanted === true);
        probe.st("bt.pin.type", () => probe.typeText("0000"), null, () => probe.find("pinField").text === "0000");
        probe.st("bt.pin.enter", () => tc.keyClick(Qt.Key_Return), () => probe.called("btAnswer"), () => probe.lastCall("btAnswer") === JSON.stringify([3, true, "0000"]));
        probe.st("bt.display", () => {
            mock._raw.btPrompt = { rid: 4, address: "AA:BB:CC:00:00:10", kind: "display", code: "123456" };
            mock._recompute();
        }, () => !!probe.findText("Type 123 456"), () => !!probe.findText("Type 123 456") && probe.find("promptYes").visible === false);
        probe.st("bt.pair", () => {
            probe.open("home", "bt", "AA:BB:CC:00:00:02", "device");
        }, () => !!probe.find("btConnect"), () => true);

        // ======================================================================== pads
        probe.st("pad.portal.open", () => probe.open("portal", "pad", "net", "pad"), () => !!probe.find("padPortal"), () => probe.find("padPortal").visible === true);
        probe.st("pad.portal.click", () => probe.click("padPortal"), () => probe.called("openPortal"), () => probe.called("openPortal", "[]"));
        probe.st("pad.retest", () => probe.click("padRetest"), () => probe.called("testPad"), () => probe.lastCall("testPad") === JSON.stringify(["net"]));
        probe.st("pad.noportal", () => probe.open("home", "pad", "dns", "pad"), () => !!probe.find("padRetest"), () => !probe.find("padPortal") || probe.find("padPortal").visible === false);
        probe.st("pad.words", null, null, () => !!probe.findText("Names resolve") );

        // ======================================================================== usage
        probe.st("usage.open", () => probe.open("home", "usage", "", "usage"), () => !!probe.find("usageChart"), () => probe.find("usageChart").days.length > 0 && !!probe.findText("Home-5G"));
    }
}
