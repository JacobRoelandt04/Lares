pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "../../common/system"
import "../bar"
import "AerialModel.js" as Model

// =============================================================================
// AerialService.qml -- aerial's live data layer (contract docs/contracts/aerial.md; the twin is AerialMock.qml).
//
// ONE PER SHELL. `live` defaults FALSE (a host that forgets cannot reach the machine): nothing runs until it is true -- no helper,
// no timer, no read of the machine.
//
// WHERE EACH FACT COMES FROM
//   Wi-Fi, wired, hotspot, Proton's connection, profiles   the helper (tools/aerial/aerial-helper, SupervisedStream, JSON lines);
//   Bluetooth adapter + devices                            Quickshell.Bluetooth (`btSource`, injectable); parts via UPower
//                                                          (BtBatteryParts); the pairing agent is the helper's, asked for while the
//                                                          popup is open or a pairing runs;
//   dBm, rates, usage                                      /proc/net/wireless + /proc/net/dev by FileView on ONE beat (1 s while the
//                                                          popup is open or `ratesWatched`, 60 s otherwise and then usage only), never a fork;
//   trust, usage                                           $XDG_STATE_HOME/lares/aerial/{trust,usage}.json (AerialState);
//   config                                                 config/aerial.jsonc (ConfigFile).
// Every fact is folded by AerialModel.compose() from ONE raw state (`_raw`), so the facts are a function of what arrived, and the
// mock builds them the same way. A fact is replaced whole when its JSON changed; `serial` is bumped LAST, once per publication.
//
// THE RULES THAT LIVE HERE (the pure ones are in AerialModel.js)
//   - every intent that fails answers `failed(id, text)` AND lands in `errors` on the part it belongs to (AerialModel.partOf);
//   - trust: the first run (no trust.json) trusts every profile that exists; afterwards a new profile is Public until marked;
//   - the auto-tunnel raises Proton on a Public network once NET passes, WAITING for a portal (never while a login page is up);
//   - airplane = AirplaneMemory's semantics: both radios down -> give back what was taken; else take both and remember;
//   - low battery: an OSD `btLow` at 20 % and 10 %, once per crossing per device.
// =============================================================================
Item {
    id: root

    // ---- the contract's properties ---------------------------------------------------------------------------------------
    property bool live: false
    property bool popupOpen: false
    property real serial: 0
    property var helper: ({ state: "off", error: "" })
    property var wifi: ({ present: false, iface: "", mac: "", permMac: "", driver: "", firmware: "", country: "", radioOn: false, softBlocked: false, hardBlocked: false, scanning: false, lastScanMs: 0, powersave: false, networks: [], active: null, profiles: [] })
    property var wired: ({ jacks: [] })
    property var hotspot: ({ available: false, missing: "device", active: false, state: "off", uuid: "", ssid: "", band: "", hasPassword: true, clients: [], uplink: "none" })
    property var bt: ({ present: false, powered: false, softBlocked: false, hardBlocked: false, discoverable: false, visibleUntilMs: 0, discovering: false, searchUntilMs: 0, name: "", address: "", devices: [], prompt: null })
    property var proton: ({ installed: false, signedIn: "unknown", locked: false, state: "down", server: null, sinceMs: 0, killSwitch: "off", netshield: "off", ipv6: false, customDns: "", autoTunnel: true, waiting: "", fastest: false })
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

    // ---- the host's / a test's knobs ---------------------------------------------------------------------------------------
    // Rates are wanted on a 1 s beat even with the popup shut (the bar's traffic figures).
    property bool ratesWatched: false
    property var helperCommand: ["setpriv", "--pdeathsig", "TERM", "--", "python3", "-I", RepoRoot.dir + "/tools/aerial/aerial-helper"]
    // The Bluetooth source: { defaultAdapter, devices } as Quickshell.Bluetooth has them; a probe hands in a fake.
    property var btSource: Bluetooth
    property var btPartsOverride: null
    property bool upowerEnabled: true
    property string procWirelessPath: "/proc/net/wireless"
    property string procNetDevPath: "/proc/net/dev"
    property string procUptimePath: "/proc/uptime"
    property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/aerial"
    property string configPath: RepoRoot.dir + "/config/aerial.jsonc"
    property string protonPath: "/usr/bin/protonvpn"
    property string protonCachePath: (Quickshell.env("HOME") || "") + "/.cache/Proton/VPN/serverlist.json"
    property string dnsmasqPath: "/usr/bin/dnsmasq"
    property var openCommand: ["xdg-open"]
    property var rfkillCommand: ["rfkill", "unblock", "bluetooth"]
    property var pactlCommand: ["pactl"]
    property var statCommand: ["stat", "-c", "%Y"]
    property int commandTimeoutMs: 15000
    property int scanEveryMs: 20000
    property int stationsEveryMs: 4000
    property int btConnectTimeoutMs: 20000
    property int btPairTimeoutMs: 90000

    // ---- raw state: what arrived ---------------------------------------------------------------------------------------
    property var _raw: ({
        wifiSnap: null, devices: [], active: [], profiles: [], nm: {}, link: null, dbm: 0, trust: {}, prevBands: {}, overrides: {},
        activeSince: {}, bootMs: 0, nowMs: 0, dnsmasq: true, clients: [], proton: { installed: false, signedIn: "unknown", config: {}, status: {}, failed: false, fastestAsk: false, fastestServer: "" },
        catalog: null, pads: {}, portal: { present: false, url: "" }, btAdapter: null, btDevices: [], btParts: {}, btSeen: {},
        btSearchUntilMs: 0, btVisibleUntilMs: 0, btPrompt: null, btHelper: null, btRfkill: { soft: false, hard: false }, btProfiles: {},
        autoTunnel: true, waiting: ""
    })
    property var _facts: null
    property var _json: ({})
    property var _usageState: Model.usageNew()
    property var _trustMap: ({})
    property bool _trustFirstRun: false
    property bool _trustReady: false
    property bool _loaded: false
    property bool _helperUp: false
    property int _nextId: 1
    property var _pending: ({})
    property string _connSig: ""
    // A pad that failed is asked again by itself (a lost ping is not a dead gateway): first after `padRetryFirstMs`, then every `padRetryEveryMs`,
    // while it still fails on the same connection; the published pad stays `fail` meanwhile (the helper's `testing` for a quiet re-test is not shown).
    property int padRetryFirstMs: 20000
    property int padRetryEveryMs: 60000
    property var _quiet: ({})
    property string _retestSig: ""
    property int _retestRuns: 0
    property bool _retestBusy: false
    property string _linkAskedSig: ""
    property var _lowState: ({})
    property var _taken: null
    property string _suppressKey: ""
    property string _autoKey: ""
    property bool _autoPending: false
    property bool _catalogAsked: false
    property real _protonCacheMtime: 0
    property var _lastBeat: null
    property real _lastBeatMs: 0
    property real _lastUsageWrite: 0
    property string _usageDay: ""
    property string _usageKey: ""
    property bool _usageDirty: false
    property bool _speedConfirmed: false
    property var _btWatch: ({})
    property bool _agentOn: false
    property bool _scanWhenPresent: false

    function _now(): real { return Date.now(); }

    // =========================================================================
    //  Publication
    // =========================================================================
    function _set(name: string, value: var): bool {
        const j = JSON.stringify(value);
        if (root._json[name] === j)
            return false;
        root._json[name] = j;
        root[name] = value;
        return true;
    }

    // Fold the raw state and publish every fact that changed; serial last.
    function _recompute(): void {
        if (!root.live)
            return;
        const raw = root._raw;
        raw.nowMs = root._now();
        raw.trust = root._trustMap;
        raw.trustAbsent = root.config.newNetworks === "trusted";
        raw.autoTunnel = root.config.autoTunnel === true;
        raw.btParts = root.btPartsOverride !== null ? root.btPartsOverride : root._upowerParts();
        const f = Model.compose(raw);
        root._facts = f;
        raw.prevBands = f.bands;
        let ch = false;
        ch = root._set("wifi", f.wifi) || ch;
        ch = root._set("wired", f.wired) || ch;
        ch = root._set("hotspot", f.hotspot) || ch;
        ch = root._set("health", f.health) || ch;
        ch = root._set("proton", f.proton) || ch;
        ch = root._set("bt", f.bt) || ch;
        const key = Model.currentNetworkKey(f);
        ch = root._set("usage", Model.usageFacts(root._usageState, raw.nowMs, key)) || ch;
        ch = root._set("airplane", root._airplaneFact(f)) || ch;
        const pruned = Model.errorsPrune(root.errors, f);
        if (pruned !== root.errors)
            ch = root._set("errors", pruned) || ch;
        if (root._scanWhenPresent && f.wifi.present && root.popupOpen) {
            root._scanWhenPresent = false;
            if (!f.hotspot.active)
                root.scan();
        }
        root._afterFacts(f, key);
        root._noteFastest(f);
        if (ch)
            root.serial = root.serial + 1;
    }

    Timer {
        id: coalesce
        interval: 0
        onTriggered: root._recompute()
    }
    function _schedule(): void {
        if (root.live)
            coalesce.restart();
    }

    function _airplaneFact(f: var): var {
        const down = !f.wifi.radioOn && !f.bt.powered;
        return { on: root._taken !== null && down, remembered: root._taken !== null ? { wifi: root._taken.wifi, bt: root._taken.bt } : { wifi: false, bt: false } };
    }

    // What follows a publication: the connection changed (pads, link, usage key), the low battery, the auto-tunnel.
    function _afterFacts(f: var, key: string): void {
        // the address is part of the connection: NetworkManager says "activated" a turn before the device snapshot carries it, and the pads
        // (the gateway above all) are only worth asking once there is one
        const sig = Model.currentNetworkKey(f) + "|" + (f.wifi.active ? f.wifi.active.uuid + f.wifi.active.bssid + f.wifi.active.ip4 : "") + "|" + f.wired.jacks.filter(j => j.connected).map(j => j.iface + j.uuid + j.ip4).join(",");
        const changed = sig !== root._connSig;
        if (changed) {
            root._connSig = sig;
            root._retestStop();
            root._raw.pads = {};
            root._raw.portal = { present: false, url: "" };
            root._raw.link = null;
            root._connectionChanged(f, key);
        }
        if (f.wifi.active && f.wifi.active.uuid !== "" && root._linkAskedSig !== sig && f.wifi.active.bssid !== "") {
            root._linkAskedSig = sig;
            root._send("iw_link", { iface: f.wifi.iface }, "iw_link", "", null);
        }
        // the Bluetooth watchers (a connect / pair that never lands)
        root._btCheckWatch(f.bt);
        // low battery
        const lb = Model.lowBattery(root._lowState, f.bt.devices, root.config.btLow);
        root._lowState = lb.state;
        for (let i = 0; i < lb.events.length; i++)
            root.osd("btLow", { address: lb.events[i].address, name: lb.events[i].name, battery: lb.events[i].battery });
        root._retestArm();
        if (changed) {
            // THIS turn's facts still carry the PREVIOUS connection's pads (a "net ok" of the trusted network you just left): the auto-tunnel
            // judges the next turn, on facts folded without them
            root._schedule();
            return;
        }
        root._evalAuto(f, key);
    }

    function _connectionChanged(f: var, key: string): void {
        const addr = f.wifi.active ? f.wifi.active.ip4 !== "" : f.wired.jacks.some(j => j.connected && j.ip4 !== "");
        if (root.popupOpen && addr)
            root.testPad("all");
        // a tunnel that came up after an auto-raise says so once
        if (key === "")
            root._autoKey = "";
    }

    // =========================================================================
    //  The helper
    // =========================================================================
    SupervisedStream {
        id: stream
        enabled: root.live
        command: root.helperCommand
        stdinEnabled: true
        what: "AerialService: the network helper"
        onLine: text => root._onLine(text)
        onErrorLine: text => root._helperErr = text
        onExited: (code, expected) => {
            root._helperUp = false;
            root._failAllPending("the network helper stopped");
            if (!expected && root.live)
                root.helper = { state: "failed", error: root._helperErr !== "" ? root._helperErr : "the network helper exited (" + code + ")" };
        }
    }
    property string _helperErr: ""

    onLiveChanged: {
        if (root.live) {
            root.helper = { state: "starting", error: "" };
            root._goLive();
        } else {
            root._helperUp = false;
            root._retestStop();
            root.helper = { state: "off", error: "" };
        }
    }

    function _goLive(): void {
        if (root._loaded) {
            root._schedule();
            return;
        }
        root._loaded = true;
        configFile.reload();
        root._applyConfig(configFile.text());
        // usage
        root._usageState = Model.usageFromJson(usageFile.read());
        // trust: a missing file is the first run
        const t = Model.trustFromJson(trustFile.read());
        root._trustFirstRun = t === null;
        root._trustMap = t === null ? ({}) : t;
        root._trustReady = !root._trustFirstRun;
        // the server of the last fastest pick (a tunnel up after a restart is still that pick while its name is)
        try {
            const vj = JSON.parse(vpnFile.read() || "{}");
            if (vj && typeof vj.fastestServer === "string")
                root._raw.proton = Object.assign({}, root._raw.proton, { fastestServer: vj.fastestServer });
        } catch (e) {
        }
        // boot time (for NM's boottime stamps)
        const up = parseFloat(String(uptimeFile.text()).split(" ")[0]);
        if (isFinite(up))
            root._raw.bootMs = root._now() - up * 1000;
        protonCheck.running = true;
        dnsmasqCheck.running = true;
        root._rebuildBt();
        beat.restart();
        root._tick();
        root._schedule();
    }

    Process {
        id: dnsmasqCheck
        command: ["test", "-x", root.dnsmasqPath]
        running: false
        onExited: code => {
            root._raw.dnsmasq = code === 0;
            root._schedule();
        }
    }

    function _onLine(text: string): void {
        if (text.trim() === "")
            return;
        let m = null;
        try {
            m = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (!m || typeof m !== "object")
            return;
        const raw = root._raw;
        switch (m.t) {
        case "hello":
            root._helperUp = true;
            root.helper = { state: "up", error: "" };
            raw.proton = Object.assign({}, raw.proton, { locked: false });    // a new helper finds out for itself
            root._helperHello();
            break;
        case "wifi": raw.wifiSnap = m; break;
        // `devices` / `active` / `profiles` are arrays: the helper's line carries them as "v"
        case "devices": raw.devices = Model.arrOf(m.v); root._watchConnect(); break;
        case "active": raw.active = Model.arrOf(m.v); root._noteActiveSince(); break;
        case "profiles": raw.profiles = Model.arrOf(m.v); root._noteProfiles(m.complete !== false); break;
        case "nm": raw.nm = m; break;
        case "link": raw.link = m; break;
        // the hotspot's clients (iw station dump + dnsmasq's leases), asked only while the hotspot is up and the popup open
        case "stations":
            if (root.hotspot.active && String(m.iface) === root.wifi.iface)
                raw.clients = Model.arrOf(m.v).map(c => ({ mac: String(c.mac || ""), ip: String(c.ip || ""), name: String(c.name || ""), dbm: typeof c.dbm === "number" ? c.dbm : 0 }));
            break;
        // BlueZ's own facts Quickshell lacks (adapter address, the hard block, a device's RSSI): merged by _rebuildBt
        case "bt": raw.btHelper = m; root._rebuildBt(); return;
        // the regulatory country rides in the wifi snapshot's device; this line only says it was read again
        case "reg": return;
        case "agent":
            if (m.kind === "cancel") {
                raw.btPrompt = null;
                break;
            }
            raw.btPrompt = { rid: m.rid, address: String(m.device || ""), kind: String(m.kind || "confirm"), code: String(m.code === undefined ? "" : m.code) };
            break;
        case "agent_done":
            raw.btPrompt = null;
            break;
        case "keyring":
            // Proton's sign-in is in the keyring: what the helper did not ask while it was locked is asked once it is open
            raw.proton = Object.assign({}, raw.proton, { locked: m.locked === true });
            if (m.locked !== true)
                root._askProton();
            break;
        case "proton": root._onProton(m); break;
        case "proton_config": raw.proton = Object.assign({}, raw.proton, { config: m, failed: raw.proton.failed }); break;
        case "catalog": root._onCatalog(m); return;
        case "pad":
            if (root._quiet[m.id] === true) {
                // a quiet re-test of a failed pad: its `testing` is not shown (the LED and the glyph would flicker); the answer replaces the fail
                if (m.state === "testing")
                    return;
                delete root._quiet[m.id];
            }
            raw.pads = Object.assign({}, raw.pads, { [m.id]: { state: m.state, detail: m.detail, ms: m.ms, atMs: root._now() } });
            break;
        case "portal": raw.portal = { present: m.present === true, url: String(m.url || "") }; break;
        case "speed": root._onSpeed(m); return;
        case "reply": root._onReply(m); return;
        case "log":
            if (m.level === "error")
                console.warn("aerial helper: " + m.text);
            return;
        default:
            return;
        }
        root._schedule();
    }

    function _helperHello(): void {
        if (root.popupOpen)
            root._openedWork();
        root._askProton();
    }

    // =========================================================================
    //  Commands: an id, a pending reply, a timeout, and failure with a part
    // =========================================================================
    // cb(reply|null): called on the reply (ok or not) or on a timeout (null).
    function _send(cmd: string, args: var, intent: string, arg: string, cb: var): int {
        if (!root.live)
            return 0;
        if (!root._helperUp) {
            if (intent !== "" && intent !== "iw_link")
                root._fail(intent, arg, "The network helper is not running.");
            if (cb)
                cb({ ok: false, error: "The network helper is not running." });
            return 0;
        }
        const id = root._nextId++;
        const msg = Object.assign({ id: id, cmd: cmd }, args || {});
        const longer = cmd === "proton" || cmd === "speed" || cmd === "add_activate" || cmd === "activate";
        root._pending[id] = { intent: intent, arg: arg, cb: cb, cmd: cmd, deadline: root._now() + (cmd === "speed" ? 180000 : longer ? root.commandTimeoutMs * 4 : root.commandTimeoutMs) };
        stream.write(JSON.stringify(msg) + "\n");
        sweep.running = true;
        return id;
    }

    function _onReply(m: var): void {
        const p = root._pending[m.id];
        if (!p)
            return;
        delete root._pending[m.id];
        if (m.ok !== true && p.intent !== "")
            root._fail(p.intent, p.arg, String(m.error || "failed"));
        if (p.cb)
            p.cb(m);
        root._schedule();
    }

    Timer {
        id: sweep
        interval: 1000
        repeat: true
        onTriggered: {
            const now = root._now();
            let left = 0;
            for (const id in root._pending) {
                const p = root._pending[id];
                if (now >= p.deadline) {
                    delete root._pending[id];
                    if (p.intent !== "")
                        root._fail(p.intent, p.arg, "The network helper did not answer (" + p.cmd + ").");
                    if (p.cb)
                        p.cb(null);
                } else
                    left++;
            }
            if (left === 0)
                sweep.running = false;
        }
    }

    function _failAllPending(why: string): void {
        const ps = root._pending;
        root._pending = ({});
        for (const id in ps) {
            if (ps[id].intent !== "")
                root._fail(ps[id].intent, ps[id].arg, why);
            if (ps[id].cb)
                ps[id].cb({ ok: false, error: why });
        }
    }

    function _fail(intent: string, arg: string, text: string): void {
        if (!root.live)
            return;
        const rec = Model.errorRecord(intent, arg, text, root._now());
        root.errors = Model.errorsPush(root.errors, rec);
        root._json.errors = JSON.stringify(root.errors);
        root.failed(rec.id, text);
        toastsItem.post(rec);
        root.cue(rec.part);
        root.serial = root.serial + 1;
    }

    // =========================================================================
    //  The beat: /proc/net/wireless and /proc/net/dev, no fork
    // =========================================================================
    FileView {
        id: wirelessFile
        path: root.procWirelessPath
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }
    FileView {
        id: netdevFile
        path: root.procNetDevPath
        blockLoading: true
        blockAllReads: true
        printErrors: false
        watchChanges: false
    }
    FileView {
        id: uptimeFile
        path: root.procUptimePath
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    readonly property bool _fast: root.popupOpen || root.ratesWatched
    Timer {
        id: beat
        interval: root._fast ? 1000 : 60000
        repeat: true
        running: root.live
        onTriggered: root._tick()
    }
    on_FastChanged: {
        if (root.live)
            root._tick();
    }

    function _tick(): void {
        if (!root.live)
            return;
        const now = root._now();
        let dirty = false;
        let changed = false;
        wirelessFile.reload();
        netdevFile.reload();
        const f = root._facts;
        const iface = f ? f.rateIface : "";
        // dBm of the Wi-Fi interface
        const wl = Model.parseProcWireless(wirelessFile.text());
        const wi = f ? f.wifi.iface : "";
        const dbm = wi !== "" && wl[wi] !== undefined ? wl[wi] : 0;
        if (dbm !== root._raw.dbm) {
            root._raw.dbm = dbm;
            dirty = true;
        }
        const dev = Model.parseProcNetDev(netdevFile.text());
        const cur = iface !== "" ? dev[iface] : null;
        // rates (only on the fast beat)
        if (root._fast) {
            const prev = root._lastBeat;
            const r = cur && prev && prev.iface === iface ? Model.rateBps(prev.c, cur, now - root._lastBeatMs) : { rxBps: 0, txBps: 0 };
            changed = root._set("rates", { iface: iface, rxBps: r.rxBps, txBps: r.txBps, atMs: now }) || changed;
        }
        // a read that came back empty (a file caught mid-write) keeps the last counters: the next beat still has something to subtract from
        if (cur)
            root._lastBeat = { iface: iface, c: cur };
        else if (iface === "")
            root._lastBeat = null;
        root._lastBeatMs = now;
        // usage: the physical interface's counters, attributed to the active network's key
        if (root.config.usage.enabled && f) {
            const key = Model.currentNetworkKey(f);
            const before = root._usageState;
            const sample = { iface: iface, rx: cur ? cur.rx : 0, tx: cur ? cur.tx : 0, key: iface !== "" ? key : "", label: key !== "" ? Model.currentNetworkLabel(key, f) : "" };
            if (cur) {
                root._usageState = Model.usageSample(before, sample, now);
                const day = Model.dayKey(now);
                if (JSON.stringify(root._usageState.days) !== JSON.stringify(before.days))
                    root._usageDirty = true;
                if (day !== root._usageDay || key !== root._usageKey)
                    root._usageNeedsWrite();
                root._usageDay = day;
                root._usageKey = key;
                if (root._usageDirty && now - root._lastUsageWrite >= 300000)
                    root._usageNeedsWrite();
                changed = root._set("usage", Model.usageFacts(root._usageState, now, key)) || changed;
            }
        }
        if (dirty)
            root._schedule();
        else if (changed)
            root.serial = root.serial + 1;
    }

    function _usageNeedsWrite(): void {
        if (!root._usageDirty)
            return;
        root._usageDirty = false;
        root._lastUsageWrite = root._now();
        usageFile.write(Model.usageToJson(root._usageState));
        usageFile.flush();
    }

    AerialState {
        id: usageFile
        path: root.stateDir + "/usage.json"
    }
    // The server Proton's own pick landed on (`{ "fastestServer": "NL#799" }`): kept so the globe still says "fastest" after a restart.
    AerialState {
        id: vpnFile
        path: root.stateDir + "/vpn.json"
    }
    AerialState {
        id: trustFile
        path: root.stateDir + "/trust.json"
    }

    // =========================================================================
    //  Trust and profiles
    // =========================================================================
    function _noteProfiles(complete: bool): void {
        // the first run seeds from the FIRST COMPLETE list (the helper says `complete: false` until every saved profile has answered),
        // EMPTY or not: a non-empty partial list left late profiles Public, and waiting for a non-empty one made the first network ever
        // joined on a machine with none Trusted (the test bed's runs). A line without the flag (an older helper, a stub) counts as complete.
        if (root._trustFirstRun && !root._trustReady && complete) {
            root._trustMap = Model.trustSeed(root._raw.profiles);
            root._trustReady = true;
            trustFile.write(Model.trustToJson(root._trustMap));
            trustFile.flush();
        }
    }
    function _noteActiveSince(): void {
        const m = {};
        const now = root._now();
        const act = root._raw.active;
        for (let i = 0; i < act.length; i++) {
            const st = act[i].state;
            if (st === 2 || st === "activated")
                m[act[i].uuid] = root._raw.activeSince[act[i].uuid] || now;
        }
        root._raw.activeSince = m;
    }
    function setTrusted(uuidOrKey: string, on: bool): void {
        let uuids = [uuidOrKey];
        const nets = root.wifi.networks;
        for (let i = 0; i < nets.length; i++)
            if (nets[i].key === uuidOrKey && nets[i].profileUuids.length > 0)
                uuids = nets[i].profileUuids;
        root._trustMap = Model.trustSet(root._trustMap, uuids, on === true, root.config.newNetworks === "trusted");
        trustFile.write(Model.trustToJson(root._trustMap));
        trustFile.flush();
        root._recompute();
    }

    // =========================================================================
    //  Config
    // =========================================================================
    ConfigFile {
        id: configFile
        path: root.configPath
        onLoaded: root._applyConfig(configFile.text())
        onLoadFailed: root._applyConfig("")
    }
    property string _configText: "\u0000"
    function _applyConfig(txt: string): void {
        if (txt === root._configText)
            return;
        root._configText = txt;
        let raw = null;
        if (txt.trim() !== "") {
            try {
                raw = JSON.parse(JsonComments.strip(txt));
            } catch (e) {
                console.warn("aerial.jsonc does not parse (" + e.message + "); the last good version is kept");
                return;
            }
        }
        const c = Model.configFrom(raw, w => console.warn(w));
        root._set("config", c);
        root._schedule();
    }

    // =========================================================================
    //  Proton
    // =========================================================================
    Process {
        id: protonCheck
        command: ["test", "-x", root.protonPath]
        running: false
        onExited: code => {
            root._raw.proton = Object.assign({}, root._raw.proton, { installed: code === 0 });
            root._schedule();
            if (code === 0)
                root._askProton();
        }
    }
    function _askProton(): void {
        if (!root._helperUp || !root._raw.proton.installed)
            return;
        // a signed-in CLI answers `status`; a signed-out one answers with words about signing in
        root._send("proton", { action: "status", args: {} }, "", "", r => {
            if (!r)
                return;
            const why = String(r.error || "");
            root._raw.proton = Object.assign({}, root._raw.proton, { signedIn: r.ok === true ? "yes" : /sign|log ?in|logged|credential|authenticat/i.test(why) ? "no" : root._raw.proton.signedIn });
            root._schedule();
        });
        root._send("proton", { action: "config", args: {} }, "", "", null);
    }
    function _onProton(m: var): void {
        // NetworkManager's connection is the truth for up / down; this is the CLI's own words (server, load, protocol)
        root._raw.proton = Object.assign({}, root._raw.proton, { status: m });
    }
    function _onCatalog(m: var): void {
        root._raw.catalog = Model.catalogFact(m, root.catalog.serial + 1);
        root._set("catalog", root._raw.catalog);
        root._protonCacheMtime = typeof m.mtime === "number" ? m.mtime : root._protonCacheMtime;
        root._recompute();
        root.serial = root.serial + 1;
    }
    Process {
        id: cacheStat
        command: root.statCommand.concat([root.protonCachePath])
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const t = parseFloat(this.text);
                if (isFinite(t) && (!root._catalogAsked || t !== root._protonCacheMtime)) {
                    root._catalogAsked = true;
                    root._protonCacheMtime = t;
                    root._send("catalog", { path: root.protonCachePath }, "", "", null);
                }
            }
        }
    }

    function _currentNet(f: var): var {
        if (!f)
            return null;
        if (f.wifi.active) {
            const a = f.wifi.active;
            let trusted = Model.trustedOf(root._trustMap, a.uuid, root.config.newNetworks === "trusted");
            const nets = f.wifi.networks;
            for (let i = 0; i < nets.length; i++)
                if (nets[i].key === a.key)
                    trusted = nets[i].trusted || trusted;
            let metered = false;
            const ps = root._raw.profiles;
            for (let j = 0; j < ps.length; j++)
                if (ps[j].uuid === a.uuid)
                    metered = ps[j].metered === "yes" || ps[j].metered === 1;
            return { key: a.key, uuid: a.uuid, trusted: trusted, metered: metered };
        }
        for (let k = 0; k < f.wired.jacks.length; k++)
            if (f.wired.jacks[k].connected)
                return { key: "wired:" + f.wired.jacks[k].iface, uuid: f.wired.jacks[k].uuid, trusted: Model.trustedOf(root._trustMap, f.wired.jacks[k].uuid, root.config.newNetworks === "trusted"), metered: false };
        return null;
    }

    function _evalAuto(f: var, key: string): void {
        const net = root._currentNet(f);
        let netPad = "unknown";
        for (let i = 0; i < f.health.pads.length; i++)
            if (f.health.pads[i].id === "net")
                netPad = f.health.pads[i].state;
        const decision = Model.autoTunnelDecision({
            enabled: root.config.autoTunnel === true,
            installed: f.proton.installed, signedIn: f.proton.signedIn,
            // aerial.jsonc autoTunnelOn "wifi": a cable is no network for it
            hasNetwork: net !== null && root._trustReady && !(root.config.autoTunnelOn === "wifi" && net.key.indexOf("wired:") === 0), trusted: net ? net.trusted : true,
            netPad: netPad, portal: f.health.portal.present, protonState: f.proton.state,
            suppressed: net !== null && root._suppressKey === net.key
        });
        const waiting = Model.waitingOf(decision);
        if (waiting !== root._raw.waiting) {
            root._raw.waiting = waiting;
            root._set("proton", Model.buildProton(Object.assign({}, root._raw, { active: root._raw.active, nowMs: root._now(), waiting: waiting })));
            root.serial = root.serial + 1;
        }
        if (decision === "raise" && net && root._autoKey !== net.key && root._helperUp) {
            root._autoKey = net.key;
            root._autoPending = true;
            root.vpnConnect(root.config.autoTunnelTo === "fastest" ? {} : { country: root.config.autoTunnelTo });
        }
        if (f.proton.state === "up" && root._autoPending) {
            root._autoPending = false;
            root.osd("autoTunnel", { country: f.proton.server ? f.proton.server.country : "" });
        }
    }

    // =========================================================================
    //  The speed test
    // =========================================================================
    function _onSpeed(m: var): void {
        const phase = String(m.phase || "");
        if (phase === "cancelled") {
            root._set("speed", { state: "idle", liveMbps: 0, result: root.speed.result, refused: "" });
            root.serial = root.serial + 1;
            return;
        }
        const st = phase === "latency" || phase === "down" || phase === "up" || phase === "done" || phase === "failed" ? phase : root.speed.state;
        let result = root.speed.result;
        if (m.result && typeof m.result === "object")
            result = { downMbps: Number(m.result.downMbps || 0), upMbps: Number(m.result.upMbps || 0), latencyMs: Number(m.result.latencyMs || 0), jitterMs: Number(m.result.jitterMs || 0), colo: String(m.result.colo || ""), bytes: Number(m.result.bytes || 0), atMs: root._now() };
        root._set("speed", { state: st, liveMbps: Number(m.liveMbps || 0), result: result, refused: "" });
        if (st === "failed")
            root._fail("runSpeedTest", "", String(m.error || (m.result && m.result.error) || "The speed test failed."));
        root.serial = root.serial + 1;
    }
    function armSpeedTest(): void {
        const net = root._currentNet(root._facts);
        root._speedConfirmed = false;
        root._set("speed", { state: "armed", liveMbps: 0, result: root.speed.result, refused: Model.speedGate(net, false) });
        root.serial = root.serial + 1;
    }
    function runSpeedTest(): void {
        const s = root.speed.state;
        if (s !== "armed") {
            root.armSpeedTest();
            return;
        }
        if (root.speed.refused !== "" && !root._speedConfirmed) {
            // the second click on a refused display is the confirmation; the third runs it
            root._speedConfirmed = true;
            root._set("speed", { state: "armed", liveMbps: 0, result: root.speed.result, refused: root.speed.refused });
            root.serial = root.serial + 1;
            return;
        }
        root._set("speed", { state: "latency", liveMbps: 0, result: null, refused: "" });
        root._send("speed", { action: "run", capBytes: Math.round(root.config.speedTest.capMB * 1024 * 1024) }, "runSpeedTest", "", null);
        root.serial = root.serial + 1;
    }
    function cancelSpeedTest(): void {
        root._send("speed", { action: "cancel" }, "", "", null);
        root._set("speed", { state: "idle", liveMbps: 0, result: root.speed.result, refused: "" });
        root.serial = root.serial + 1;
    }

    // =========================================================================
    //  Opening and closing the popup
    // =========================================================================
    onPopupOpenChanged: {
        if (!root.live)
            return;
        if (root.popupOpen)
            root._openedWork();
        else
            root._closedWork();
        root._tick();
    }

    function _openedWork(): void {
        if (!root._helperUp)
            return;
        root._wantAgent(true);
        // the helper has said hello, but NetworkManager may not be read yet: with no Wi-Fi device a scan is asked for when it appears
        if (!root.hotspot.active) {
            if (root.wifi.present)
                root.scan();
            else
                root._scanWhenPresent = true;
        }
        root.testPad("all");
        root._askProton();
        cacheStat.running = false;
        cacheStat.running = true;
        root._btProfilesRefresh();
        scanTimer.restart();
    }
    function _closedWork(): void {
        scanTimer.stop();
        if (root.bt.devices.every(d => !d.pairing))
            root._wantAgent(false);
        const a = root._btAdapter();
        if (a && a.discovering === true) {
            a.discovering = false;
            searchStop.stop();
            root._raw.btSearchUntilMs = 0;
            root._rebuildBt();
        }
        if (root.speed.state === "armed")
            root._set("speed", { state: "idle", liveMbps: 0, result: root.speed.result, refused: "" });
    }
    Timer {
        id: scanTimer
        interval: root.scanEveryMs
        repeat: true
        onTriggered: {
            if (!root.hotspot.active)
                root.scan();
        }
    }

    function _wantAgent(on: bool): void {
        if (root._agentOn === on)
            return;
        root._agentOn = on;
        root._send("agent", { on: on }, "", "", null);
        if (!on) {
            root._raw.btPrompt = null;
            root._schedule();
        }
    }

    // =========================================================================
    //  Wi-Fi intents
    // =========================================================================
    function _netOf(key: string): var {
        const nets = root.wifi.networks;
        for (let i = 0; i < nets.length; i++)
            if (nets[i].key === key)
                return nets[i];
        return null;
    }
    function _profileOf(uuid: string): var {
        const ps = root._raw.profiles;
        for (let i = 0; i < ps.length; i++)
            if (ps[i].uuid === uuid)
                return ps[i];
        return null;
    }
    function _override(key: string, o: var): void {
        const ov = Object.assign({}, root._raw.overrides);
        if (o === null)
            delete ov[key];
        else
            ov[key] = o;
        root._raw.overrides = ov;
        root._schedule();
    }

    function scan(): void {
        root._send("scan", {}, "scan", "", null);
    }

    // NetworkManager accepts an activation and fails it later (the helper's reply says ok): the attempt is watched on the Wi-Fi device,
    // which walks prepare .. need-auth and then fails with a reason (`no-secrets` for a wrong password).
    property var _connWatch: null
    function _wifiDevice(): var {
        const ds = root._raw.devices;
        for (let i = 0; i < ds.length; i++)
            if (ds[i].type === "wifi" && ds[i].iface === root.wifi.iface)
                return ds[i];
        return null;
    }
    function _stateCodeOf(d: var): int {
        return typeof d.stateCode === "number" ? d.stateCode : 0;
    }
    function _watchConnect(): void {
        const w = root._connWatch;
        if (!w)
            return;
        if (root._now() > w.deadline) {
            root._connWatch = null;
            return;
        }
        const wd = root._wifiDevice();
        if (!wd)
            return;
        const st = root._stateCodeOf(wd);
        if (st === 60)
            w.sawAuth = true;
        if (st >= 40 && st < 100) {
            w.progress = true;
            return;
        }
        if (st === 100) {
            root._connWatch = null;
            return;
        }
        // failed (120), or back to disconnected / unavailable after the attempt had begun (NetworkManager goes through `failed` in a
        // turn, which a snapshot may miss); a user-requested end is not a failure
        const ended = (st === 120 && (w.progress || w.from !== 120)) || (w.progress && (st === 30 || st === 20));
        if (!ended || String(wd.stateReason) === "user-requested")
            return;
        root._connWatch = null;
        const why = Model.activationFailText(wd.stateReason, w.sawAuth);
        root._override(w.key, { state: "failed", failReason: why });
        root._fail("connect", w.key, why);
    }
    function connect(key: string, opts: var): void {
        const o = opts || {};
        const wd0 = root._wifiDevice();
        root._connWatch = { key: key, from: wd0 ? root._stateCodeOf(wd0) : 0, progress: false, sawAuth: false, deadline: root._now() + 90000 };
        const net = root._netOf(key);
        if (!net) {
            root._connWatch = null;
            root._fail("connect", key, "That network is not in range any more.");
            return;
        }
        const iface = root.wifi.iface;
        let bssid = "";
        for (let i = 0; i < net.aps.length; i++)
            if (bssid === "" || net.aps[i].signal > 0 && net.aps[i].active)
                bssid = net.aps[i].bssid;
        const done = r => {
            if (r && r.ok === true) {
                root._override(key, null);
                return;
            }
            root._connWatch = null;
            const why = r ? String(r.error || "failed") : "The network helper did not answer.";
            root._override(key, { state: /secret|password|psk|auth|key/i.test(why) ? "needsSecret" : "failed", failReason: why });
        };
        const uuid = o.profileUuid || (net.profileUuids.length > 0 ? net.profileUuids[0] : "");
        if (net.known && uuid !== "") {
            const patch = {};
            if (o.password && o.password !== "")
                patch.psk = o.password;
            if (o.eap && (o.eap.password || o.eap.identity || o.eap.anonymousIdentity))
                patch.eap = { password: o.eap.password || "", identity: o.eap.identity || "", anonymousIdentity: o.eap.anonymousIdentity || "" };
            if (Object.keys(patch).length > 0)
                root._send("update", { uuid: uuid, patch: patch }, "connect", key, r => {
                    if (r && r.ok === true)
                        root._send("activate", { uuid: uuid, iface: iface, ap: bssid }, "connect", key, done);
                    else
                        done(r);
                });
            else
                root._send("activate", { uuid: uuid, iface: iface, ap: bssid }, "connect", key, done);
            return;
        }
        const ssid = net.hidden ? String(o.hiddenSsid || "") : net.ssid;
        if (ssid === "") {
            root._connWatch = null;
            root._fail("connect", key, "A hidden network needs its name.");
            return;
        }
        if (net.security !== "open" && net.security !== "owe" && !o.password && !o.eap) {
            root._connWatch = null;
            root._override(key, { state: "needsSecret", failReason: "A password is needed." });
            return;
        }
        root._send("add_activate", { ssid: ssid, security: net.security, psk: o.password || "", eap: o.eap || null, hidden: net.hidden, iface: iface, bssid: bssid }, "connect", key, done);
    }
    function disconnect(): void {
        const a = root.wifi.active;
        if (!a) {
            root._fail("disconnect", "", "No network is connected.");
            return;
        }
        root._connWatch = null;
        // the device's Disconnect: NetworkManager joins nothing else until asked (a deactivation let its policy autoconnect another
        // saved network at once -- the test bed's fourth run)
        root._send("disconnect_device", { iface: root.wifi.iface }, "disconnect", "", null);
    }
    function forget(uuid: string): void {
        root._send("delete", { uuid: uuid }, "forget", uuid, r => {
            if (r && r.ok === true && root._trustMap[uuid] === true) {
                root._trustMap = Model.trustSet(root._trustMap, [uuid], false);
                trustFile.write(Model.trustToJson(root._trustMap));
                trustFile.flush();
            }
        });
    }
    function setRadio(on: bool): void {
        root._send("wifi_enabled", { on: on === true }, "setRadio", "", null);
    }
    function setAutoconnect(uuid: string, on: bool): void {
        root._send("update", { uuid: uuid, patch: { autoconnect: on === true } }, "setAutoconnect", uuid, null);
    }
    function setPriority(uuid: string, n: int): void {
        root._send("update", { uuid: uuid, patch: { priority: n } }, "setPriority", uuid, null);
    }
    function revealSecret(uuid: string): void {
        root._send("secrets", { uuid: uuid }, "revealSecret", uuid, r => {
            if (r && r.ok === true)
                root.secret(uuid, String(r.data && r.data.psk !== undefined ? r.data.psk : ""));
        });
    }
    function updateProfile(uuid: string, patch: var): void {
        root._send("update", { uuid: uuid, patch: patch || {} }, "updateProfile", uuid, null);
    }
    function mergeDoubles(keepUuid: string, dropUuids: var): void {
        const drops = [];
        for (let i = 0; i < dropUuids.length; i++)
            if (dropUuids[i] !== keepUuid)
                drops.push(dropUuids[i]);
        for (let j = 0; j < drops.length; j++)
            root._send("delete", { uuid: drops[j] }, "mergeDoubles", keepUuid, null);
    }
    function addNetwork(ssid: string, security: string, password: string): void {
        root._send("add_activate", { ssid: ssid, security: security, psk: password || "", hidden: true, iface: root.wifi.iface }, "addNetwork", ssid, null);
    }
    function setPowersave(on: bool): void {
        const a = root.wifi.active;
        if (!a) {
            root._fail("setPowersave", "", "Connect to a network first: power saving is set on its profile.");
            return;
        }
        root._send("update", { uuid: a.uuid, patch: { powersave: on === true ? 3 : 2 } }, "setPowersave", "", null);
    }

    // ---- wired
    function connectWired(iface: string): void {
        let uuid = "";
        const ps = root._raw.profiles;
        for (let i = 0; i < ps.length; i++)
            if ((ps[i].type === "802-3-ethernet" || ps[i].type === "ethernet") && uuid === "")
                uuid = ps[i].uuid;
        if (uuid === "") {
            root._fail("connectWired", iface, "No wired profile is saved.");
            return;
        }
        root._send("activate", { uuid: uuid, iface: iface }, "connectWired", iface, null);
    }
    function disconnectWired(iface: string): void {
        const js = root.wired.jacks;
        for (let i = 0; i < js.length; i++)
            if (js[i].iface === iface && js[i].uuid !== "") {
                root._send("deactivate", { uuid: js[i].uuid }, "disconnectWired", iface, null);
                return;
            }
        root._fail("disconnectWired", iface, "That cable is not connected.");
    }

    // ---- hotspot
    function startHotspot(): void {
        const h = root.hotspot;
        if (!h.available) {
            root._fail("startHotspot", "", h.missing === "dnsmasq" ? "The hotspot needs dnsmasq, which is not installed." : "There is no Wi-Fi device to share from.");
            return;
        }
        root._send("hotspot", { on: true, uuid: h.uuid }, "startHotspot", "", null);
    }
    function stopHotspot(): void {
        root._send("hotspot", { on: false, uuid: root.hotspot.uuid }, "stopHotspot", "", null);
    }
    function configureHotspot(o: var): void {
        // saved without starting it: the existing hotspot profile, or a new one
        root._send("hotspot_config", { uuid: root.hotspot.uuid, ssid: o.ssid, psk: o.password, band: o.band }, "configureHotspot", "", null);
    }
    Timer {
        id: stationsTimer
        interval: root.stationsEveryMs
        repeat: true
        triggeredOnStart: true
        running: root.live && root._helperUp && root.popupOpen && root.hotspot.active
        onTriggered: {
            const i = root.wifi.iface;
            if (i !== "")
                root._send("stations", { iface: i }, "", "", null);
        }
        onRunningChanged: {
            if (!stationsTimer.running && root._raw.clients.length > 0) {
                root._raw.clients = [];
                root._schedule();
            }
        }
    }

    // =========================================================================
    //  Bluetooth (Quickshell.Bluetooth, the helper's agent, UPower parts)
    // =========================================================================
    function _btAdapter(): var {
        return root.live && root.btSource ? root.btSource.defaultAdapter : null;
    }
    function _btDeviceList(): var {
        const m = root.live && root.btSource ? root.btSource.devices : null;
        if (!m)
            return [];
        return typeof m.values === "function" ? m : m.values;      // a JS array has a values() method; the real model's `values` is a list
    }
    function _adapterState(a: var): string {
        return typeof a.state === "string" ? a.state : BluetoothAdapterState.toString(a.state);
    }
    function _btFind(address: string): var {
        const list = root._btDeviceList();
        for (let i = 0; i < list.length; i++)
            if (list[i] && String(list[i].address).toUpperCase() === String(address).toUpperCase())
                return list[i];
        return null;
    }

    Instantiator {
        model: root.live ? root._btDeviceList() : []
        onObjectAdded: root._btSchedule()
        onObjectRemoved: root._btSchedule()
        delegate: QtObject {
            id: dw
            required property var modelData
            readonly property Connections _c: Connections {
                target: dw.modelData
                ignoreUnknownSignals: true
                function onConnectedChanged() { root._btSchedule(); }
                function onPairedChanged() { root._btSchedule(); }
                function onBondedChanged() { root._btSchedule(); }
                function onPairingChanged() { root._btSchedule(); }
                function onTrustedChanged() { root._btSchedule(); }
                function onBlockedChanged() { root._btSchedule(); }
                function onNameChanged() { root._btSchedule(); }
                function onIconChanged() { root._btSchedule(); }
                function onBatteryChanged() { root._btSchedule(); }
                function onBatteryAvailableChanged() { root._btSchedule(); }
            }
        }
    }
    Connections {
        target: root.live ? root.btSource : null
        ignoreUnknownSignals: true
        function onDefaultAdapterChanged() { root._btSchedule(); }
        function onDevicesChanged() { root._btSchedule(); }
    }
    Connections {
        target: root.live ? root._btAdapter() : null
        ignoreUnknownSignals: true
        function onEnabledChanged() { root._btSchedule(); }
        function onStateChanged() { root._btSchedule(); }
        function onDiscoverableChanged() { root._btSchedule(); }
        function onDiscoveringChanged() { root._btSchedule(); }
        function onNameChanged() { root._btSchedule(); }
    }
    Timer {
        id: btCoalesce
        interval: 0
        onTriggered: root._rebuildBt()
    }
    function _btSchedule(): void {
        if (root.live)
            btCoalesce.restart();
    }
    // insurance only, and only while the popup is open
    Timer {
        interval: 750
        repeat: true
        running: root.live && root.popupOpen
        onTriggered: root._rebuildBt()
    }

    function _rebuildBt(): void {
        if (!root.live)
            return;
        const a = root._btAdapter();
        const raw = root._raw;
        const hb = raw.btHelper && raw.btHelper.present === true ? raw.btHelper : null;
        raw.btAdapter = a ? { name: a.name, enabled: a.enabled === true, state: root._adapterState(a), discoverable: a.discoverable === true, discovering: a.discovering === true, address: a.address ? String(a.address) : (hb ? String(hb.address || "") : "") } : null;
        raw.btRfkill = hb ? { soft: hb.softBlocked === true, hard: hb.hardBlocked === true } : { soft: false, hard: false };
        const rssi = {};
        if (hb)
            for (let r = 0; r < hb.devices.length; r++)
                if (typeof hb.devices[r].rssi === "number")
                    rssi[String(hb.devices[r].address).toUpperCase()] = hb.devices[r].rssi;
        const list = root._btDeviceList();
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const d = list[i];
            if (!d)
                continue;
            out.push({ address: d.address, name: d.name, deviceName: d.deviceName, icon: d.icon, connected: d.connected, paired: d.paired, bonded: d.bonded, trusted: d.trusted, blocked: d.blocked, pairing: d.pairing, battery: Number(d.battery) * 100, batteryAvailable: d.batteryAvailable, rssi: rssi[String(d.address).toUpperCase()] || 0 });
        }
        raw.btDevices = out;
        raw.btSeen = Model.btSeenNext(raw.btSeen, out, raw.btAdapter !== null && raw.btAdapter.discovering === true);
        const now = root._now();
        // deadlines: the figures are gone at their time; the radio's own timer ends the discoverable window
        if (raw.btSearchUntilMs > 0 && raw.btSearchUntilMs <= now)
            raw.btSearchUntilMs = 0;
        if (raw.btVisibleUntilMs > 0 && raw.btVisibleUntilMs <= now)
            raw.btVisibleUntilMs = 0;
        root._schedule();
    }
    // The first connected device builds UPower's view, never before (BtBatteryParts' own rule).
    readonly property bool _btAnyConnected: root.bt.devices.some(d => d.connected)
    Loader {
        id: partsLoader
        active: root.live && root.upowerEnabled && root.btPartsOverride === null && root._btAnyConnected
        sourceComponent: BtBatteryParts {}
    }
    function _upowerParts(): var {
        return partsLoader.item ? partsLoader.item.byAddr : ({});
    }
    Connections {
        target: partsLoader.item
        ignoreUnknownSignals: true
        function onByAddrChanged() { root._schedule(); }
    }

    function _btWatchAdd(address: string, kind: string, why: string): void {
        const w = Object.assign({}, root._btWatch);
        w[address] = { kind: kind, deadline: root._now() + (kind === "pair" ? root.btPairTimeoutMs : root.btConnectTimeoutMs), why: why };
        root._btWatch = w;
        btWatchTimer.running = true;
    }
    function _btCheckWatch(bt: var): void {
        const w = root._btWatch;
        let changed = false;
        const out = {};
        for (const addr in w) {
            let met = false;
            for (let i = 0; i < bt.devices.length; i++)
                if (bt.devices[i].address === addr)
                    met = w[addr].kind === "pair" ? bt.devices[i].paired && !bt.devices[i].pairing : bt.devices[i].connected;
            if (met)
                changed = true;
            else
                out[addr] = w[addr];
        }
        if (changed)
            root._btWatch = out;
    }
    Timer {
        id: btWatchTimer
        interval: 1000
        repeat: true
        onTriggered: {
            const now = root._now();
            const w = root._btWatch;
            const out = {};
            let n = 0;
            for (const addr in w) {
                if (now < w[addr].deadline) {
                    out[addr] = w[addr];
                    n++;
                    continue;
                }
                if (w[addr].kind === "pair") {
                    const d = root._btFind(addr);
                    if (d)
                        d.cancelPair();
                    root._fail("btPair", addr, "Pairing timed out.");
                } else
                    root._fail(w[addr].kind === "connect" ? "btConnect" : "btPair", addr, "Could not connect.");   // the toast's title names the device (AerialModel), the address is no help
            }
            root._btWatch = out;
            if (n === 0)
                btWatchTimer.running = false;
        }
    }

    function _btAct(intent: string, address: string, fn: var): var {
        const d = root._btFind(address);
        if (!d) {
            root._fail(intent, address, "That device is gone.");
            return null;
        }
        fn(d);
        root._btSchedule();
        return d;
    }

    function setBtPowered(on: bool): void {
        const a = root._btAdapter();
        if (!a) {
            root._fail("setBtPowered", "", "There is no Bluetooth adapter.");
            return;
        }
        if (on && root._adapterState(a).toLowerCase() === "blocked") {
            unblock.running = true;
            unblock.pendingOn = true;
            return;
        }
        a.enabled = on === true;
        root._btSchedule();
    }
    Process {
        id: unblock
        property bool pendingOn: false
        command: root.rfkillCommand
        running: false
        onExited: code => {
            const a = root._btAdapter();
            if (code !== 0) {
                root._fail("setBtPowered", "", "rfkill could not unblock Bluetooth (exit " + code + ").");
                return;
            }
            if (a && unblock.pendingOn)
                a.enabled = true;
            root._btSchedule();
        }
    }

    function btSearch(): void {
        const a = root._btAdapter();
        if (!a || a.enabled !== true) {
            root._fail("btSearch", "", a ? "Bluetooth is off." : "There is no Bluetooth adapter.");
            return;
        }
        root._raw.btSeen = ({});
        a.discovering = true;
        root._raw.btSearchUntilMs = root._now() + root.config.searchSeconds * 1000;
        searchStop.interval = root.config.searchSeconds * 1000;
        searchStop.restart();
        root._rebuildBt();
    }
    // the search ended early by the user (round 6: SCAN a second time stops it), or by its own time
    function btStopSearch(): void {
        searchStop.stop();
        const a = root._btAdapter();
        if (a)
            a.discovering = false;
        root._raw.btSearchUntilMs = 0;
        root._rebuildBt();
    }
    Timer {
        id: searchStop
        onTriggered: root.btStopSearch()
    }
    function btVisible(): void {
        const a = root._btAdapter();
        if (!a || a.enabled !== true) {
            root._fail("btVisible", "", a ? "Bluetooth is off." : "There is no Bluetooth adapter.");
            return;
        }
        a.pairable = true;
        a.discoverableTimeout = root.config.visibleSeconds;
        a.discoverable = true;
        root._raw.btVisibleUntilMs = root._now() + root.config.visibleSeconds * 1000;
        visibleStop.interval = root.config.visibleSeconds * 1000;
        visibleStop.restart();
        root._wantAgent(true);
        root._rebuildBt();
    }
    // visible to others no longer: ended early by the user (round 6: BEACON a second time), or by its own time
    function btHide(): void {
        visibleStop.stop();
        const a = root._btAdapter();
        if (a)
            a.discoverable = false;
        root._raw.btVisibleUntilMs = 0;
        if (!root.popupOpen)
            root._wantAgent(false);
        root._rebuildBt();
    }
    Timer {
        id: visibleStop
        onTriggered: root.btHide()
    }
    function btConnect(a: string): void {
        if (root._btAct("btConnect", a, d => d.connect()))
            root._btWatchAdd(String(a).toUpperCase(), "connect", "");
    }
    function btDisconnect(a: string): void { root._btAct("btDisconnect", a, d => d.disconnect()); }
    function btPair(a: string): void {
        root._wantAgent(true);
        const ad = root._btAdapter();
        if (root._btAct("btPair", a, d => {
            if (ad && !ad.pairable)
                ad.pairable = true;
            d.pair();
        }))
            root._btWatchAdd(String(a).toUpperCase(), "pair", "");
    }
    function btCancelPair(a: string): void {
        root._btAct("btCancelPair", a, d => d.cancelPair());
        const w = Object.assign({}, root._btWatch);
        delete w[String(a).toUpperCase()];
        root._btWatch = w;
        root._raw.btPrompt = null;
    }
    function btTrust(a: string, on: bool): void { root._btAct("btTrust", a, d => { d.trusted = on === true; }); }
    function btBlock(a: string, on: bool): void { root._btAct("btBlock", a, d => { d.blocked = on === true; }); }
    function btForget(a: string): void { root._btAct("btForget", a, d => d.forget()); }
    function btRename(a: string, name: string): void { root._btAct("btRename", a, d => { d.name = name; }); }
    function btAnswer(rid: var, accept: bool, value: var): void {
        root._send("agent_reply", { rid: rid, accept: accept === true, value: value === undefined ? null : value }, "btAnswer", root._raw.btPrompt ? root._raw.btPrompt.address : "", null);
        root._raw.btPrompt = null;
        root._schedule();
    }

    // The audio profile (A2DP / HFP): pactl's cards, read while the popup is open and a device is connected.
    function _cardOf(address: string): string { return "bluez_card." + String(address).toUpperCase().replace(/:/g, "_"); }
    Process {
        id: cardsProc
        command: root.pactlCommand.concat(["-f", "json", "list", "cards"])
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                let cards = [];
                try {
                    cards = JSON.parse(this.text);
                } catch (e) {
                    return;
                }
                const m = {};
                for (let i = 0; i < cards.length; i++) {
                    const mm = /^bluez_card\.([0-9A-F_]{17})$/i.exec(String(cards[i].name || ""));
                    if (!mm)
                        continue;
                    const avail = [];
                    const ps = cards[i].profiles || {};
                    for (const p in ps)
                        if (ps[p].available !== false && p !== "off")
                            avail.push(p);
                    m[mm[1].replace(/_/g, ":").toUpperCase()] = { active: String(cards[i].active_profile || ""), available: avail, codec: String((cards[i].properties || {})["api.bluez5.codec"] || "") };
                }
                root._raw.btProfiles = m;
                root._schedule();
            }
        }
    }
    function _btProfilesRefresh(): void {
        if (!root.live || !root._btAnyConnected)
            return;
        cardsProc.running = false;
        cardsProc.running = true;
    }
    on_BtAnyConnectedChanged: {
        if (root.popupOpen)
            root._btProfilesRefresh();
    }
    function btSetProfile(a: string, profile: string): void {
        setProfileProc.address = a;
        setProfileProc.command = root.pactlCommand.concat(["set-card-profile", root._cardOf(a), profile]);
        setProfileProc.running = true;
    }
    Process {
        id: setProfileProc
        property string address: ""
        running: false
        onExited: code => {
            if (code !== 0)
                root._fail("btSetProfile", setProfileProc.address, "The audio profile could not be changed (pactl exit " + code + ").");
            else
                root._btProfilesRefresh();
        }
    }

    // =========================================================================
    //  VPN
    // =========================================================================
    function vpnConnect(o: var): void {
        const p = root.proton;
        if (!p.installed) {
            root._fail("vpnConnect", "", "ProtonVPN is not installed.");
            return;
        }
        if (p.signedIn === "no") {
            root._fail("vpnConnect", "", "ProtonVPN is not signed in.");
            return;
        }
        const raw = root._raw;
        // Proton's own pick: no country, city or server named (`securecore`, `p2p` and `tor` are filters of Proton's own pick, `random` is a pick of ours)
        const fast = !(o && (o.country || o.city || o.server || o.random));
        root._fastestReplied = false;
        root._fastestFrom = root._protonUuid();
        raw.proton = Object.assign({}, raw.proton, { failed: false, fastestAsk: fast });
        if (!fast)
            root._setFastestServer("");
        root._send("proton", { action: "connect", args: o || {} }, "vpnConnect", "", r => {
            if (!r || r.ok !== true) {
                root._raw.proton = Object.assign({}, root._raw.proton, { failed: true, fastestAsk: false });
                root._autoPending = false;
            } else {
                root._fastestReplied = true;
                root._recompute();
            }
            root._schedule();
        });
    }
    // The server a fastest pick landed on is learnt when the connect has ANSWERED (the CLI has exited: NetworkManager's connection is the new one)
    // and the tunnel is up; from then the name says it (`fastestAsk` only bridges the connect).
    property bool _fastestReplied: false
    property string _fastestFrom: ""
    // the uuid of the Proton connection NetworkManager holds now ("" none): a switch is learnt only once it is ANOTHER connection (the old tunnel may
    // still be up when the CLI answers)
    function _protonUuid(): string {
        const act = root._raw.active;
        let u = "";
        for (let i = 0; i < act.length; i++)
            if (Model.isProtonConn(act[i]))
                u = String(act[i].uuid);
        return u;
    }
    function _noteFastest(f: var): void {
        const p = root._raw.proton;
        if (p.fastestAsk !== true || !root._fastestReplied || f.proton.state !== "up" || !f.proton.server || (root._fastestFrom !== "" && root._protonUuid() === root._fastestFrom))
            return;
        root._fastestReplied = false;
        root._raw.proton = Object.assign({}, p, { fastestAsk: false });
        root._setFastestServer(f.proton.server.name);
        root._schedule();
    }
    function _setFastestServer(name: string): void {
        const p = root._raw.proton;
        if (p.fastestServer === name)
            return;
        root._raw.proton = Object.assign({}, p, { fastestServer: name });
        vpnFile.write(JSON.stringify({ fastestServer: name }));
        root._schedule();
    }
    function vpnDisconnect(): void {
        // a tunnel the user drops is not raised again on this network by the auto-tunnel
        const net = root._currentNet(root._facts);
        if (net)
            root._suppressKey = net.key;
        root._raw.proton = Object.assign({}, root._raw.proton, { fastestAsk: false });
        root._setFastestServer("");
        // `protonvpn disconnect` exits 1 though it worked: only NetworkManager's state is the answer
        root._send("proton", { action: "disconnect", args: {} }, "", "", null);
    }
    function vpnSet(key: string, value: var): void {
        root._send("proton", { action: "set", args: { key: key, value: value } }, "vpnSet", key, r => {
            if (r && r.ok === true)
                root._askProton();
        });
    }
    function setAutoTunnel(on: bool): void {
        configFile.reload();
        const next = Model.setConfigBool(configFile.text(), "autoTunnel", on === true);
        configFile.setText(next);
        root._applyConfig(next);
    }
    function refreshCatalog(): void {
        root._send("catalog", { path: root.protonCachePath }, "refreshCatalog", "", null);
    }

    // =========================================================================
    //  Health, portal, airplane, misc
    // =========================================================================
    // ---- the quiet re-test of a failed pad ---------------------------------------------------------------------------------------
    readonly property var _tested: ["gateway", "dns", "net"]
    function _failingPads(): var {
        const pads = root._raw.pads;
        for (let i = 0; i < root._tested.length; i++)
            if (pads[root._tested[i]] && pads[root._tested[i]].state === "fail")
                return root._tested.slice(i);   // from the first fail on: the helper stops at a fail, the later pads never ran
        return [];
    }
    function _retestArm(): void {
        if (!root.live || !root._helperUp || root._retestBusy || padRetry.running || root._failingPads().length === 0)
            return;
        root._retestSig = root._connSig;
        padRetry.interval = root._retestRuns === 0 ? root.padRetryFirstMs : root.padRetryEveryMs;
        padRetry.start();
    }
    function _retestStop(): void {
        padRetry.stop();
        root._retestRuns = 0;
        root._retestBusy = false;
        root._quiet = ({});
    }
    function _retestFire(): void {
        if (!root.live || !root._helperUp || root._retestSig !== root._connSig)
            return;
        const ids = root._failingPads();
        if (ids.length === 0)
            return;
        root._retestRuns = root._retestRuns + 1;
        root._retestBusy = true;
        const q = {};
        for (let i = 0; i < ids.length; i++)
            q[ids[i]] = true;
        root._quiet = q;
        root._retestRun(ids, root._connSig);
    }
    function _retestRun(ids: var, sig: string): void {
        root._send("pad", { pad: ids[0], url: root.config.portalCheckUrl }, "", ids[0], r => {
            if (sig !== root._connSig || !root.live || !root._retestBusy)
                return;
            const res = r && r.ok === true && r.data && r.data.results && r.data.results.length > 0 ? r.data.results[0] : null;
            if (res && res.state !== "fail" && ids.length > 1) {
                root._retestRun(ids.slice(1), sig);
                return;
            }
            root._quiet = ({});
            root._retestBusy = false;
            if (res && res.state !== "fail" && root._failingPads().length === 0)
                root._retestRuns = 0;
            root._schedule();
        });
    }
    Timer {
        id: padRetry
        repeat: false
        onTriggered: root._retestFire()
    }

    function testPad(id: string): void {
        if (!root.live)
            return;
        const ids = id === "all" ? ["gateway", "dns", "net"] : [id];
        for (let q = 0; q < ids.length; q++)
            delete root._quiet[ids[q]];
        const pads = Object.assign({}, root._raw.pads);
        for (let i = 0; i < ids.length; i++) {
            if (ids[i] === "link" || ids[i] === "addr")
                continue;
            pads[ids[i]] = { state: "testing", detail: "", ms: 0, atMs: root._now() };
            root._send("pad", { pad: ids[i], url: root.config.portalCheckUrl }, "testPad", ids[i], null);
        }
        root._raw.pads = pads;
        root._schedule();
    }
    function openPortal(): void {
        const url = root.health.portal.url !== "" ? root.health.portal.url : root.config.portalCheckUrl;
        opener.command = root.openCommand.concat([url]);
        opener.running = true;
    }
    Process {
        id: opener
        running: false
        onExited: code => {
            if (code !== 0)
                root._fail("openPortal", "", "The login page could not be opened.");
        }
    }

    function setAirplane(on: bool): void {
        if (on === true) {
            if (root._taken === null)
                root._taken = { wifi: root.wifi.radioOn, bt: root.bt.powered };
            root.setRadio(false);
            if (root.bt.present)
                root.setBtPowered(false);
        } else {
            const was = root._taken !== null ? root._taken : { wifi: root.wifi.present, bt: root.bt.present };
            root._taken = null;
            root.setRadio(was.wifi);
            if (root.bt.present)
                root.setBtPowered(was.bt);
        }
        root._schedule();
    }

    function dismissError(id: string): void {
        root._set("errors", Model.errorsDismiss(root.errors, id));
        root.serial = root.serial + 1;
    }
    function touch(): void {
        root._tick();
        root._schedule();
    }
    function refresh(): void {
        root._send("reg", {}, "", "", null);
        root._rebuildBt();
        root._tick();
        if (root.popupOpen) {
            root.scan();
            root.testPad("all");
        }
    }

    Component.onCompleted: {
        if (root.live)
            root._goLive();
    }
}
