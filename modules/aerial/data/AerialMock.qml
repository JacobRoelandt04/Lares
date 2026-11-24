pragma ComponentBehavior: Bound

import QtQuick
import "AerialModel.js" as Model
import "AerialMockData.js" as Data

// =============================================================================
// AerialMock.qml -- the mock twin of AerialService (same members, contract docs/contracts/aerial.md section 2; a probe fails on any
// one missing). It NEVER touches the machine: no process, no file, no bus. A scenario is a raw state (AerialMockData.js) folded by
// AerialModel.compose() exactly as the service folds the real machine; every intent is simulated on that state after `settleMs`.
//
// SCENARIOS  home crowd airplane hotspot vpn portal pairing earbuds nowifi errors    (`scenario`; changing it rebuilds the state)
// KNOBS      drift (dB of signal wander per scan tick; 0 = still), trafficMbps (the carrying link's rate), scanPeriodMs, settleMs (the
//            time a simulated intent takes), failNext ("" | "any" | an intent's name: that intent fails once with a stated reason)
// `live` (default false) switches the simulation on: timers run only while it is true.
// =============================================================================
Item {
    id: root

    property bool live: false
    property bool popupOpen: false
    property real serial: 0
    property var helper: ({ state: "off", error: "" })
    property var wifi: ({ present: false, networks: [], active: null, profiles: [] })
    property var wired: ({ jacks: [] })
    property var hotspot: ({ available: false, missing: "device", active: false, state: "off", uuid: "", ssid: "", band: "", hasPassword: true, clients: [], uplink: "none" })
    property var bt: ({ present: false, powered: false, devices: [], prompt: null })
    property var proton: ({ installed: false, signedIn: "unknown", state: "down", server: null, fastest: false })
    property var catalog: ({ serial: 0, tier: 0, countries: [] })
    property var health: ({ pads: [], portal: { present: false, url: "" } })
    property var rates: ({ iface: "", rxBps: 0, txBps: 0, atMs: 0 })
    property var usage: ({ todayBytes: 0, monthBytes: 0, current: { key: "", bytes: 0 }, byNetwork: [], days: [] })
    property var speed: ({ state: "idle", liveMbps: 0, result: null, refused: "" })
    property var airplane: ({ on: false, remembered: { wifi: false, bt: false } })
    property var errors: []
    property var config: Model.configFrom(null)
    // The shell's DesktopNotifier for the errors' toasts (null: none are told).
    property var notifier: null
    readonly property var toasts: toastsItem
    AerialToasts {
        id: toastsItem
        notifier: root.notifier
        host: root
        onOpenRequested: root.openRequested()
    }
    // A click on one of the network's toasts: the shell opens the popup on the focused screen (ShellServices' routing).
    signal openRequested
    onErrorsChanged: toastsItem.sync(root.errors)

    signal osd(string kind, var payload)
    signal secret(string uuid, string text)
    signal failed(string id, string text)
    // ONE short physical cue for the part an error names (the label shakes, a DIP springs back): fires for EVERY failure, also
    // a repeat whose toast stays quiet. A moment, never a fact: nothing of an error persists in the popup (the toast says it).
    signal cue(string part)

    // ---- the knobs
    property string scenario: "home"
    property real drift: 0
    property real trafficMbps: 25
    property int scanPeriodMs: 4000
    property string failNext: ""
    property int settleMs: 700

    // ---- internals
    property var _raw: null
    property var _json: ({})
    property var _taken: null
    property var _lowState: ({})
    property var _usageState: Model.usageNew()
    property var _queue: []
    property bool _speedConfirmed: false
    property var _tick: 0

    function _now(): real { return Date.now(); }

    function _set(name: string, value: var): bool {
        const j = JSON.stringify(value);
        if (root._json[name] === j)
            return false;
        root._json[name] = j;
        root[name] = value;
        return true;
    }

    function load(name: string): void {
        root._raw = Data.scenario(name, { nowMs: root._now() });
        root._raw.catalog = Model.catalogFact(Data.catalog(), 1);
        root._usageState = Data.usageState(root._now());
        root._taken = name === "airplane" ? { wifi: true, bt: true } : null;
        root._lowState = ({});
        root._queue = [];
        root._speedConfirmed = false;
        root._json = ({});
        root._set("errors", name === "errors" ? [
            Model.errorRecord("connect", "Cafe-Free", "The password was not accepted.", root._now() - 5000),
            Model.errorRecord("vpnConnect", "", "ProtonVPN did not answer.", root._now() - 9000),
            Model.errorRecord("testPad", "dns", "The name server did not answer.", root._now() - 3000)] : []);
        root._set("speed", { state: "idle", liveMbps: 0, result: null, refused: "" });
        root._set("helper", { state: root.live ? "up" : "off", error: "" });
        root._set("catalog", root._raw.catalog);
        root._recompute();
    }

    onScenarioChanged: root.load(root.scenario)
    onLiveChanged: {
        root._set("helper", { state: root.live ? "up" : "off", error: "" });
        if (root.live)
            root._recompute();
    }
    Component.onCompleted: root.load(root.scenario)

    function _recompute(): void {
        if (!root._raw)
            return;
        const raw = root._raw;
        raw.nowMs = root._now();
        raw.autoTunnel = root.config.autoTunnel === true;
        const f = Model.compose(raw);
        raw.prevBands = f.bands;
        let ch = false;
        ch = root._set("wifi", f.wifi) || ch;
        ch = root._set("wired", f.wired) || ch;
        ch = root._set("hotspot", f.hotspot) || ch;
        ch = root._set("health", f.health) || ch;
        ch = root._set("proton", f.proton) || ch;
        ch = root._set("bt", f.bt) || ch;
        ch = root._set("config", root.config) || ch;
        const key = Model.currentNetworkKey(f);
        ch = root._set("usage", Model.usageFacts(root._usageState, raw.nowMs, key)) || ch;
        ch = root._set("airplane", { on: root._taken !== null && !f.wifi.radioOn && !f.bt.powered, remembered: root._taken !== null ? { wifi: root._taken.wifi, bt: root._taken.bt } : { wifi: false, bt: false } }) || ch;
        const pruned = Model.errorsPrune(root.errors, f);
        if (pruned !== root.errors)
            ch = root._set("errors", pruned) || ch;
        root._rateTo(f);
        // low battery
        const lb = Model.lowBattery(root._lowState, f.bt.devices, root.config ? root.config.btLow : undefined);
        root._lowState = lb.state;
        for (let i = 0; i < lb.events.length; i++)
            root.osd("btLow", { address: lb.events[i].address, name: lb.events[i].name, battery: lb.events[i].battery });
        root._autoTunnel(f);
        if (ch)
            root.serial = root.serial + 1;
    }

    function _rateTo(f: var): void {
        const iface = f.rateIface;
        const bps = iface === "" ? 0 : Math.round(root.trafficMbps * 125000);
        root._set("rates", { iface: iface, rxBps: bps, txBps: Math.round(bps / 6), atMs: root._now() });
    }

    // The auto-tunnel rule, as the service has it (the mock raises the tunnel itself on a Public network once NET passes).
    function _autoTunnel(f: var): void {
        const a = f.wifi.active;
        let net = a ? root._netOf(a.key) : null;
        const pad = f.health.pads[4].state;
        const d = Model.autoTunnelDecision({ enabled: root.config.autoTunnel === true, installed: f.proton.installed, signedIn: f.proton.signedIn, hasNetwork: a !== null,
                                             trusted: net ? net.trusted : true, netPad: pad, portal: f.health.portal.present, protonState: f.proton.state, suppressed: false });
        const w = Model.waitingOf(d);
        if (w !== root._raw.waiting) {
            root._raw.waiting = w;
            root._set("proton", Model.buildProton(Object.assign({}, root._raw, { waiting: w })));
        }
        if (d === "raise" && root._raw._autoFor !== a.key) {
            root._raw._autoFor = a.key;
            root.vpnConnect({ country: "NL" });
            root.osd("autoTunnel", { country: "NL" });
        }
    }

    // ---- simulated time -------------------------------------------------------------------------------------------------------------------
    function _later(fn: var, ms: int): void {
        root._queue = root._queue.concat([{ at: root._now() + ms, fn: fn }]);
        pump.running = root.live;
    }
    Timer {
        id: pump
        interval: 50
        repeat: true
        onTriggered: {
            const now = root._now();
            const due = root._queue.filter(q => q.at <= now);
            root._queue = root._queue.filter(q => q.at > now);
            for (let i = 0; i < due.length; i++)
                due[i].fn();
            if (root._queue.length === 0)
                pump.running = false;
        }
    }
    // the scan beat: signals wander, a scan lands
    Timer {
        interval: Math.max(250, root.scanPeriodMs)
        repeat: true
        running: root.live
        onTriggered: {
            root._tick++;
            if (root.drift > 0 && root._raw) {
                const aps = root._raw.wifiSnap.aps;
                for (let i = 0; i < aps.length; i++)
                    aps[i].strength = Math.max(3, Math.min(99, Math.round(aps[i].strength + (Math.sin(root._tick * 1.7 + i * 2.3) + Math.cos(root._tick * 0.9 + i)) * root.drift)));
                root._raw.wifiSnap.lastScanMs = root._now();
                if (root._raw.link)
                    root._raw.dbm = -90 + Math.round(aps.length ? aps[0].strength / 2 : 0);
                root._recompute();
            }
        }
    }
    Timer {
        interval: 1000
        repeat: true
        running: root.live && root._raw !== null
        onTriggered: {
            const f = Model.compose(root._raw);
            root._rateTo(f);
            const bytes = Math.round(root.trafficMbps * 125000 * 1.17);
            const key = Model.currentNetworkKey(f);
            if (key !== "") {
                const dk = Model.dayKey(root._now());
                const u = JSON.parse(JSON.stringify(root._usageState));
                u.days[dk] = u.days[dk] || {};
                u.days[dk][key] = (u.days[dk][key] || 0) + bytes;
                root._usageState = u;
                root._set("usage", Model.usageFacts(u, root._now(), key));
            }
            root.serial = root.serial + 1;
        }
    }

    // ---- failure injection ----------------------------------------------------------------------------------------------------------------
    function _gate(intent: string, arg: string): bool {
        if (root.failNext === "" || (root.failNext !== "any" && root.failNext !== intent))
            return true;
        root.failNext = "";
        root._fail(intent, arg, "Simulated failure (the failNext knob).");
        return false;
    }
    function _fail(intent: string, arg: string, text: string): void {
        const rec = Model.errorRecord(intent, arg, text, root._now());
        root._set("errors", Model.errorsPush(root.errors, rec));
        root.failed(rec.id, text);
        toastsItem.post(rec);
        root.cue(rec.part);
        root.serial = root.serial + 1;
    }
    function _after(fn: var): void {
        root._later(() => {
            fn();
            root._recompute();
        }, root.settleMs);
    }

    // ---- Wi-Fi ---------------------------------------------------------------------------------------------------------------------------
    function _netOf(key: string): var {
        const nets = root.wifi.networks;
        for (let i = 0; i < nets.length; i++)
            if (nets[i].key === key)
                return nets[i];
        return null;
    }
    function _profile(uuid: string): var {
        const ps = root._raw.profiles;
        for (let i = 0; i < ps.length; i++)
            if (ps[i].uuid === uuid)
                return ps[i];
        return null;
    }
    function _setActive(uuid: string, id: string, type: string, devs: var, state: string, def: bool): void {
        const keep = root._raw.active.filter(a => a.uuid !== uuid && (type === "802-11-wireless" ? a.type !== "802-11-wireless" : true));
        keep.push({ path: "/mock/a/" + uuid, uuid: uuid, id: id, type: type, devices: devs, state: state, vpn: false, default4: def, default6: false, specific: "", proton: false, killswitch: false });
        root._raw.active = keep;
    }

    function scan(): void {
        if (!root._gate("scan", ""))
            return;
        const s = root._raw.wifiSnap;
        s.scanning = true;
        root._recompute();
        root._after(() => {
            s.scanning = false;
            s.lastScanMs = root._now();
        });
    }
    function connect(key: string, opts: var): void {
        const o = opts || {};
        if (!root._gate("connect", key))
            return;
        const net = root._netOf(key);
        if (!net) {
            root._fail("connect", key, "That network is not in range any more.");
            return;
        }
        const raw = root._raw;
        let uuid = o.profileUuid || (net.profileUuids.length ? net.profileUuids[0] : "");
        if (!net.known && net.security !== "open" && net.security !== "owe" && !o.password && !o.eap) {
            const ov = Object.assign({}, raw.overrides);
            ov[key] = { state: "needsSecret", failReason: "A password is needed." };
            raw.overrides = ov;
            root._recompute();
            return;
        }
        if (o.password === "wrong") {
            root._after(() => {
                const ov = Object.assign({}, raw.overrides);
                ov[key] = { state: "needsSecret", failReason: "The password was not accepted." };
                raw.overrides = ov;
                raw.active = raw.active.filter(a => a.type !== "802-11-wireless");
            });
            root._fail("connect", key, "The password was not accepted.");
            return;
        }
        if (uuid === "") {
            uuid = "u-" + key.replace(/[^A-Za-z0-9]/g, "").toLowerCase();
            raw.profiles = raw.profiles.concat([{ path: "/mock/p/" + uuid, uuid: uuid, id: net.ssid || o.hiddenSsid || key, type: "802-11-wireless", ssid: net.ssid || o.hiddenSsid || "", mode: "infrastructure", security: net.security === "wpa2/3" ? "wpa2" : net.security,
                                                 autoconnect: true, priority: 0, timestamp: Math.round(root._now() / 1000), hidden: net.hidden, ip4method: "auto", metered: "unknown", macPolicy: "default", band: "", bssid: "", eap: o.eap || null }]);
        }
        const ov = Object.assign({}, raw.overrides);
        delete ov[key];
        raw.overrides = ov;
        const prof = root._profile(uuid);
        root._setActive(uuid, prof ? prof.id : key, "802-11-wireless", ["wlp47s0"], "activating", true);
        const best = net.aps.slice().sort((a, b) => b.signal - a.signal)[0];
        raw.wifiSnap.activeAp = best ? best.bssid : "";
        root._recompute();
        root._after(() => {
            root._setActive(uuid, prof ? prof.id : key, "802-11-wireless", ["wlp47s0"], "activated", true);
            raw.activeSince[uuid] = root._now();
            raw.devices[0].ip4 = { addresses: [{ address: "192.168.7." + (20 + (key.length % 200)), prefix: 24 }], gateway: "192.168.7.1", dns: ["192.168.7.1"] };
            raw.link = { iface: "wlp47s0", standard: "he", dbm: -55, rxMbps: 600, txMbps: 480 };
            raw.dbm = -55;
            raw.pads = { gateway: { state: "ok", detail: "192.168.7.1", ms: 4 }, dns: { state: "ok", detail: "192.168.7.1", ms: 18 }, net: { state: net.security === "open" && !net.known ? "warn" : "ok", detail: net.security === "open" && !net.known ? "Log in first" : "online", ms: 120 } };
            if (net.security === "open" && !net.known)
                raw.portal = { present: true, url: "http://captive.example/login" };
        });
    }
    function disconnect(): void {
        if (!root._gate("disconnect", ""))
            return;
        const raw = root._raw;
        raw.active = raw.active.filter(a => a.type !== "802-11-wireless" || a.uuid === "u-hs");
        raw.wifiSnap.activeAp = "";
        raw.pads = {};
        raw.portal = { present: false, url: "" };
        root._recompute();
    }
    function forget(uuid: string): void {
        if (!root._gate("forget", uuid))
            return;
        root._raw.profiles = root._raw.profiles.filter(p => p.uuid !== uuid);
        root._raw.active = root._raw.active.filter(a => a.uuid !== uuid);
        root._recompute();
    }
    function setRadio(on: bool): void {
        if (!root._gate("setRadio", ""))
            return;
        const raw = root._raw;
        raw.nm = Object.assign({}, raw.nm, { wirelessEnabled: on === true });
        raw.wifiSnap.radioOn = on === true;
        if (!on) {
            raw.active = raw.active.filter(a => a.type !== "802-11-wireless");
            raw.wifiSnap.activeAp = "";
        }
        root._recompute();
    }
    function setAutoconnect(uuid: string, on: bool): void {
        const p = root._profile(uuid);
        if (p && root._gate("setAutoconnect", uuid))
            root._raw.profiles = root._raw.profiles.map(q => q.uuid === uuid ? Object.assign({}, q, { autoconnect: on === true }) : q);
        root._recompute();
    }
    function setPriority(uuid: string, n: int): void {
        if (root._gate("setPriority", uuid))
            root._raw.profiles = root._raw.profiles.map(q => q.uuid === uuid ? Object.assign({}, q, { priority: n }) : q);
        root._recompute();
    }
    function revealSecret(uuid: string): void {
        if (root._gate("revealSecret", uuid))
            root.secret(uuid, "correct-horse-battery-staple");
    }
    function updateProfile(uuid: string, patch: var): void {
        if (!root._gate("updateProfile", uuid))
            return;
        root._raw.profiles = root._raw.profiles.map(q => q.uuid === uuid ? Object.assign({}, q, patch && patch.metered ? { metered: patch.metered } : {}, patch && patch.mac ? { macPolicy: patch.mac } : {}, patch && patch.band !== undefined ? { band: patch.band } : {}) : q);
        root._recompute();
    }
    function mergeDoubles(keepUuid: string, dropUuids: var): void {
        if (!root._gate("mergeDoubles", keepUuid))
            return;
        const drops = [];
        for (let i = 0; i < dropUuids.length; i++)
            drops.push(dropUuids[i]);
        root._raw.profiles = root._raw.profiles.filter(p => drops.indexOf(p.uuid) < 0 || p.uuid === keepUuid);
        root._recompute();
    }
    function addNetwork(ssid: string, security: string, password: string): void {
        if (!root._gate("addNetwork", ssid))
            return;
        const uuid = "u-add-" + ssid.replace(/[^A-Za-z0-9]/g, "").toLowerCase();
        root._raw.profiles = root._raw.profiles.concat([{ path: "/mock/p/" + uuid, uuid: uuid, id: ssid, type: "802-11-wireless", ssid: ssid, mode: "infrastructure", security: security, autoconnect: true, priority: 0, timestamp: Math.round(root._now() / 1000), hidden: true, ip4method: "auto", metered: "unknown", macPolicy: "default", band: "", bssid: "", eap: null }]);
        root._recompute();
    }
    function setTrusted(uuidOrKey: string, on: bool): void {
        let uuids = [uuidOrKey];
        const n = root._netOf(uuidOrKey);
        if (n && n.profileUuids.length)
            uuids = n.profileUuids;
        root._raw.trust = Model.trustSet(root._raw.trust, uuids, on === true);
        root._recompute();
    }
    function setPowersave(on: bool): void {
        if (!root._gate("setPowersave", ""))
            return;
        root._raw.wifiSnap.device.powersave = on === true;
        root._recompute();
    }

    // ---- wired / hotspot -----------------------------------------------------------------------------------------------------------------
    function connectWired(iface: string): void {
        if (!root._gate("connectWired", iface))
            return;
        const raw = root._raw;
        const d = raw.devices.filter(x => x.iface === iface)[0];
        if (!d || d.carrier !== true) {
            root._fail("connectWired", iface, "No cable is plugged in.");
            return;
        }
        root._setActive("u-wired", "Wired connection 1", "802-3-ethernet", [iface], "activating", true);
        root._recompute();
        root._after(() => {
            root._setActive("u-wired", "Wired connection 1", "802-3-ethernet", [iface], "activated", true);
            d.state = "activated";
            d.stateCode = 100;
            d.ip4 = { addresses: [{ address: "192.168.0.8", prefix: 24 }], gateway: "192.168.0.1", dns: ["192.168.0.1"] };
        });
    }
    function disconnectWired(iface: string): void {
        if (!root._gate("disconnectWired", iface))
            return;
        root._raw.active = root._raw.active.filter(a => a.type !== "802-3-ethernet");
        const d = root._raw.devices.filter(x => x.iface === iface)[0];
        if (d) {
            d.state = "disconnected";
            d.stateCode = 30;
        }
        root._recompute();
    }
    function startHotspot(): void {
        if (!root._gate("startHotspot", ""))
            return;
        if (!root.hotspot.available) {
            root._fail("startHotspot", "", root.hotspot.missing === "dnsmasq" ? "The hotspot needs dnsmasq, which is not installed." : "There is no Wi-Fi device to share from.");
            return;
        }
        root._setActive("u-hs", "Hotspot", "802-11-wireless", ["wlp47s0"], "activating", false);
        root._recompute();
        root._after(() => {
            root._setActive("u-hs", "Hotspot", "802-11-wireless", ["wlp47s0"], "activated", false);
            root._raw.clients = [];
        });
    }
    function stopHotspot(): void {
        if (!root._gate("stopHotspot", ""))
            return;
        root._raw.active = root._raw.active.filter(a => a.uuid !== "u-hs");
        root._raw.clients = [];
        root._recompute();
    }
    function configureHotspot(o: var): void {
        if (!root._gate("configureHotspot", ""))
            return;
        root._raw.profiles = root._raw.profiles.map(p => p.mode === "ap" ? Object.assign({}, p, o.ssid ? { ssid: o.ssid, id: o.ssid } : {}, o.band ? { band: o.band } : {}) : p);
        root._recompute();
    }

    // ---- Bluetooth -----------------------------------------------------------------------------------------------------------------------
    function _btMap(address: string, fn: var): void {
        root._raw.btDevices = root._raw.btDevices.map(d => d.address === address ? fn(Object.assign({}, d)) : d);
        root._recompute();
    }
    function setBtPowered(on: bool): void {
        if (!root._gate("setBtPowered", "") || !root._raw.btAdapter)
            return;
        root._raw.btAdapter = Object.assign({}, root._raw.btAdapter, { enabled: on === true, state: on ? "Enabled" : "Disabled", discovering: on ? root._raw.btAdapter.discovering : false });
        if (!on)
            root._raw.btDevices = root._raw.btDevices.map(d => Object.assign({}, d, { connected: false }));
        root._recompute();
    }
    // (each search / visibility carries a serial: the end a former one scheduled does not end a later one)
    property int _searchSerial: 0
    property int _visibleSerial: 0
    function btStopSearch(): void {
        const raw = root._raw;
        if (!raw.btAdapter)
            return;
        root._searchSerial++;
        raw.btAdapter = Object.assign({}, raw.btAdapter, { discovering: false });
        raw.btSearchUntilMs = 0;
        root._recompute();
    }
    function btHide(): void {
        const raw = root._raw;
        if (!raw.btAdapter)
            return;
        root._visibleSerial++;
        raw.btAdapter = Object.assign({}, raw.btAdapter, { discoverable: false });
        raw.btVisibleUntilMs = 0;
        root._recompute();
    }
    function btSearch(): void {
        if (!root._gate("btSearch", "") || !root._raw.btAdapter)
            return;
        const raw = root._raw, serial = ++root._searchSerial;
        raw.btAdapter = Object.assign({}, raw.btAdapter, { discovering: true });
        raw.btSearchUntilMs = root._now() + root.config.searchSeconds * 1000;
        raw.btSeen = ({});
        root._recompute();
        const found = [["AA:BB:CC:00:01:01", "JBL Flip 6", "audio-card"], ["AA:BB:CC:00:01:02", "Galaxy Watch", "watch"], ["AA:BB:CC:00:01:03", "Magic Keyboard", "input-keyboard"], ["AA:BB:CC:00:01:04", "Unknown device", ""]];
        for (let i = 0; i < found.length; i++)
            root._later(() => {
                if (!raw.btAdapter.discovering || serial !== root._searchSerial)
                    return;
                raw.btDevices = raw.btDevices.concat([Data.btDev(found[i][0], found[i][1], found[i][2], {})]);
                raw.btSeen = Object.assign({}, raw.btSeen, { [found[i][0]]: true });
                root._recompute();
            }, root.settleMs * (i + 1));
        root._later(() => {
            if (serial !== root._searchSerial)
                return;
            raw.btAdapter = Object.assign({}, raw.btAdapter, { discovering: false });
            raw.btSearchUntilMs = 0;
            root._recompute();
        }, root.config.searchSeconds * 1000);
    }
    function btVisible(): void {
        if (!root._gate("btVisible", "") || !root._raw.btAdapter)
            return;
        const raw = root._raw, serial = ++root._visibleSerial;
        raw.btAdapter = Object.assign({}, raw.btAdapter, { discoverable: true });
        raw.btVisibleUntilMs = root._now() + root.config.visibleSeconds * 1000;
        root._recompute();
        root._later(() => {
            if (serial !== root._visibleSerial)
                return;
            raw.btAdapter = Object.assign({}, raw.btAdapter, { discoverable: false });
            raw.btVisibleUntilMs = 0;
            root._recompute();
        }, root.config.visibleSeconds * 1000);
    }
    function btConnect(a: string): void {
        if (!root._gate("btConnect", a))
            return;
        root._after(() => root._btMap(a, d => Object.assign(d, { connected: true, paired: true })));
    }
    function btDisconnect(a: string): void {
        if (root._gate("btDisconnect", a))
            root._btMap(a, d => Object.assign(d, { connected: false }));
    }
    function btPair(a: string): void {
        if (!root._gate("btPair", a))
            return;
        root._btMap(a, d => Object.assign(d, { pairing: true }));
        root._raw.btPrompt = { rid: 7, address: a, kind: "confirm", code: "123 456" };
        root._recompute();
    }
    function btCancelPair(a: string): void {
        root._raw.btPrompt = null;
        root._btMap(a, d => Object.assign(d, { pairing: false }));
    }
    function btTrust(a: string, on: bool): void { root._btMap(a, d => Object.assign(d, { trusted: on === true })); }
    function btBlock(a: string, on: bool): void { root._btMap(a, d => Object.assign(d, { blocked: on === true, connected: on ? false : d.connected })); }
    function btForget(a: string): void {
        root._raw.btDevices = root._raw.btDevices.filter(d => d.address !== a);
        root._recompute();
    }
    function btRename(a: string, name: string): void { root._btMap(a, d => Object.assign(d, { name: name })); }
    function btSetProfile(a: string, profile: string): void {
        const m = Object.assign({}, root._raw.btProfiles);
        if (m[a])
            m[a] = Object.assign({}, m[a], { active: profile });
        root._raw.btProfiles = m;
        root._recompute();
    }
    function btAnswer(rid: var, accept: bool, value: var): void {
        const p = root._raw.btPrompt;
        root._raw.btPrompt = null;
        if (p) {
            if (accept === true)
                root._btMap(p.address, d => Object.assign(d, { pairing: false, paired: true, connected: true }));
            else
                root._btMap(p.address, d => Object.assign(d, { pairing: false }));
        }
        root._recompute();
    }

    // ---- VPN -----------------------------------------------------------------------------------------------------------------------------
    // (what the last connect was asked with: a probe reads it)
    property var lastVpnArgs: null
    function vpnConnect(o: var): void {
        root.lastVpnArgs = o || {};
        if (!root._gate("vpnConnect", ""))
            return;
        // a country Proton does not know is refused in Proton's own words (the real tool's answer to `--country fastest`)
        const asked = o && o.country ? String(o.country) : "";
        if (asked !== "" && root.catalog.countries.length > 0 && !root.catalog.countries.some(c => c.code === asked)) {
            root._fail("vpnConnect", "", "Error: Invalid country name '" + asked + "'. Please use a valid country name.");
            return;
        }
        const raw = root._raw;
        const cc = (o && o.country) || "NL";
        const server = cc + "#" + (o && o.server ? String(o.server).replace(/\D/g, "") : "799");
        const t = Data.tunnel(1);
        t.id = "ProtonVPN " + server;
        // Proton's own pick (no country, city, server or `random` named): the fact the globe reads to toggle
        const fast = !(o && (o.country || o.city || o.server || o.random));
        raw.proton = Object.assign({}, raw.proton, { fastestAsk: fast });
        if (!fast)
            raw.proton.fastestServer = "";
        // the real order: the old tunnel goes, the new connection activates, and the CLI's own words (server, load) land LAST, so for a while
        // the status still names the PREVIOUS server beside the new connection
        raw.active = raw.active.filter(a => !a.proton).concat([t]);
        root._recompute();
        root._after(() => {
            t.state = "activated";
            raw.active = raw.active.filter(a => !a.proton).concat([Object.assign({}, t, { state: "activated" })]);
            raw.activeSince["u-proton"] = root._now();
        });
        root._later(() => {
            raw.proton.status = { state: "connected", server: { name: server, city: "", country: "", via: "" }, load: 48, protocol: "wireguard" };
            if (fast)
                raw.proton = Object.assign({}, raw.proton, { fastestAsk: false, fastestServer: server });
            root._recompute();
        }, root.settleMs * 2 + 100);
    }
    function vpnDisconnect(): void {
        if (!root._gate("vpnDisconnect", ""))
            return;
        root._raw.active = root._raw.active.filter(a => !a.proton);
        root._raw.proton = Object.assign({}, root._raw.proton, { fastestAsk: false, fastestServer: "" });
        root._raw._autoFor = root.wifi.active ? root.wifi.active.key : "";
        root._recompute();
    }
    function vpnSet(key: string, value: var): void {
        if (!root._gate("vpnSet", key))
            return;
        const labels = { killSwitch: "Kill Switch", netshield: "NetShield", ipv6: "IPv6", customDns: "Custom DNS" };
        const k = labels[key] || key;
        root._raw.proton = Object.assign({}, root._raw.proton, { config: Object.assign({}, root._raw.proton.config, { [k]: String(value) }) });
        root._recompute();
    }
    function setAutoTunnel(on: bool): void {
        root.config = Model.configFrom({ autoTunnel: on === true });
        root._recompute();
    }
    function refreshCatalog(): void {
        root._raw.catalog = Model.catalogFact(Data.catalog(), root.catalog.serial + 1);
        root._set("catalog", root._raw.catalog);
        root._recompute();
    }

    // ---- health / speed / misc -----------------------------------------------------------------------------------------------------------
    function testPad(id: string): void {
        if (!root._gate("testPad", id))
            return;
        const ids = id === "all" ? ["gateway", "dns", "net"] : [id];
        const raw = root._raw;
        const before = Object.assign({}, raw.pads);
        for (let i = 0; i < ids.length; i++)
            if (ids[i] !== "link" && ids[i] !== "addr")
                raw.pads = Object.assign({}, raw.pads, { [ids[i]]: { state: "testing", detail: "", ms: 0 } });
        root._recompute();
        root._after(() => {
            const p = Object.assign({}, raw.pads);
            for (let i = 0; i < ids.length; i++) {
                if (ids[i] === "link" || ids[i] === "addr")
                    continue;
                const was = before[ids[i]];
                p[ids[i]] = ids[i] === "net" && raw.portal.present ? { state: "warn", detail: "Log in first", ms: 90 } : (was && was.state !== "testing" ? was : { state: "ok", detail: "", ms: 12 });
            }
            raw.pads = p;
        });
    }
    function openPortal(): void {
        const raw = root._raw;
        root._after(() => {
            raw.portal = { present: false, url: "" };
            raw.pads = Object.assign({}, raw.pads, { net: { state: "ok", detail: "online", ms: 120 } });
        });
    }
    function armSpeedTest(): void {
        const a = root.wifi.active;
        const n = a ? root._netOf(a.key) : null;
        const p = a ? root._profile(a.uuid) : null;
        root._speedConfirmed = false;
        root._set("speed", { state: "armed", liveMbps: 0, result: root.speed.result, refused: Model.speedGate(n ? { trusted: n.trusted, metered: p ? p.metered === "yes" : false } : null, false) });
        root.serial = root.serial + 1;
    }
    function runSpeedTest(): void {
        if (root.speed.state !== "armed") {
            root.armSpeedTest();
            return;
        }
        if (root.speed.refused !== "" && !root._speedConfirmed) {
            root._speedConfirmed = true;
            return;
        }
        if (!root._gate("runSpeedTest", ""))
            return;
        const step = (state, mbps, ms) => root._later(() => {
            if (root.speed.state === "idle")
                return;
            root._set("speed", { state: state, liveMbps: mbps, result: state === "done" ? { downMbps: 412.6, upMbps: 38.2, latencyMs: 11.4, jitterMs: 1.8, colo: "BRU", bytes: 150000000, atMs: root._now() } : null, refused: "" });
            root.serial = root.serial + 1;
        }, ms);
        root._set("speed", { state: "latency", liveMbps: 0, result: null, refused: "" });
        step("down", 180, root.settleMs);
        step("down", 410, root.settleMs * 2);
        step("up", 36, root.settleMs * 3);
        step("done", 0, root.settleMs * 4);
        root.serial = root.serial + 1;
    }
    function cancelSpeedTest(): void {
        root._set("speed", { state: "idle", liveMbps: 0, result: root.speed.result, refused: "" });
        root.serial = root.serial + 1;
    }
    function setAirplane(on: bool): void {
        if (!root._gate("setAirplane", ""))
            return;
        if (on === true) {
            if (root._taken === null)
                root._taken = { wifi: root.wifi.radioOn, bt: root.bt.powered };
            root.setRadio(false);
            root.setBtPowered(false);
        } else {
            const was = root._taken !== null ? root._taken : { wifi: root.wifi.present, bt: root.bt.present === true };
            root._taken = null;
            root.setRadio(was.wifi);
            root.setBtPowered(was.bt);
        }
    }
    function dismissError(id: string): void {
        root._set("errors", Model.errorsDismiss(root.errors, id));
        root.serial = root.serial + 1;
    }
    function touch(): void { root._recompute(); }
    function refresh(): void {
        root._raw.wifiSnap.lastScanMs = root._now();
        root._recompute();
    }
}
