.pragma library

// =============================================================================
// AerialModel.js -- the pure logic of aerial's data layer (node-testable: tools/dev/aerial_model_cases.js).
//
// What lives here: MEMBERS (contract docs/contracts/aerial.md section 2), the fold of the helper's snapshots (`wifi`, `devices`,
// `active`, `profiles`, `nm`, `link`) into the facts (`wifi`, `wired`, `hotspot`, `proton`, `bt`, `health`), signal bands with
// hysteresis, security from flags, Bluetooth kinds / rings / battery / the low-battery rule, usage arithmetic, the auto-tunnel
// rule, the speed-test gate and the error records. AerialService and AerialMock both call `compose()`, so the two build the SAME
// shapes from the same raw state; neither holds a rule of its own.
//
// Everything takes its inputs (the clock included: `nowMs`, `bootMs`) and returns a fresh plain object; nothing is mutated in place.
// =============================================================================

var MEMBERS = {
    props: ["live", "popupOpen", "serial", "helper", "wifi", "wired", "hotspot", "bt", "proton", "catalog", "health", "rates",
            "usage", "speed", "airplane", "errors", "config"],
    signals: ["osd", "secret", "failed", "cue"],
    intents: ["scan", "connect", "disconnect", "forget", "setRadio", "setAutoconnect", "setPriority", "revealSecret",
              "updateProfile", "mergeDoubles", "addNetwork", "setTrusted", "setPowersave",
              "connectWired", "disconnectWired", "startHotspot", "stopHotspot", "configureHotspot",
              "setBtPowered", "btSearch", "btVisible", "btConnect", "btDisconnect", "btPair", "btCancelPair", "btTrust", "btBlock",
              "btForget", "btRename", "btSetProfile", "btAnswer",
              "vpnConnect", "vpnDisconnect", "vpnSet", "setAutoTunnel", "refreshCatalog",
              "testPad", "openPortal", "armSpeedTest", "runSpeedTest", "cancelSpeedTest", "setAirplane", "dismissError", "touch", "refresh"]
};

// The members a probe wants and an object lacks (`name in obj` is true for a QML property, signal and function alike).
function missingMembers(obj) {
    var out = [];
    var all = MEMBERS.props.concat(MEMBERS.signals, MEMBERS.intents);
    for (var i = 0; i < all.length; i++)
        if (!(all[i] in obj))
            out.push(all[i]);
    return out;
}

var DEFAULT_CONFIG = {
    autoTunnel: true,
    searchSeconds: 30,
    visibleSeconds: 180,
    speedTest: { capMB: 200 },
    portalCheckUrl: "http://ping.archlinux.org/nm-check.txt",
    usage: { enabled: true },
    look: { secondarySide: "start" },
    autoTunnelTo: "fastest",
    autoTunnelOn: "any",
    newNetworks: "public",
    bar: { traffic: true, trafficFromMbps: 10 },
    btLow: [20, 10],
    sounds: true
};

// The parsed config.jsonc over the defaults; a wrong type keeps the default (the loader warns once per key).
function configFrom(raw, warn) {
    var c = JSON.parse(JSON.stringify(DEFAULT_CONFIG));
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return c;
    function num(v, lo, hi) { return typeof v === "number" && isFinite(v) && v >= lo && v <= hi; }
    function bad(k, why) { if (warn) warn("aerial.jsonc: " + k + " " + why + "; the default stands"); }
    if ("autoTunnel" in raw) { if (typeof raw.autoTunnel === "boolean") c.autoTunnel = raw.autoTunnel; else bad("autoTunnel", "must be true or false"); }
    if ("searchSeconds" in raw) { if (num(raw.searchSeconds, 5, 600)) c.searchSeconds = raw.searchSeconds; else bad("searchSeconds", "must be 5..600"); }
    if ("visibleSeconds" in raw) { if (num(raw.visibleSeconds, 10, 3600)) c.visibleSeconds = raw.visibleSeconds; else bad("visibleSeconds", "must be 10..3600"); }
    if (raw.speedTest && typeof raw.speedTest === "object") {
        if ("capMB" in raw.speedTest) { if (num(raw.speedTest.capMB, 1, 5000)) c.speedTest.capMB = raw.speedTest.capMB; else bad("speedTest.capMB", "must be 1..5000"); }
    }
    if ("portalCheckUrl" in raw) { if (typeof raw.portalCheckUrl === "string" && /^https?:\/\//.test(raw.portalCheckUrl)) c.portalCheckUrl = raw.portalCheckUrl; else bad("portalCheckUrl", "must be an http(s) URL"); }
    if (raw.usage && typeof raw.usage === "object" && typeof raw.usage.enabled === "boolean")
        c.usage.enabled = raw.usage.enabled;
    if (raw.look && typeof raw.look === "object" && (raw.look.secondarySide === "far" || raw.look.secondarySide === "start" || raw.look.secondarySide === "end"))
        c.look.secondarySide = raw.look.secondarySide;
    else if (raw.look && typeof raw.look === "object" && "secondarySide" in raw.look)
        bad("look.secondarySide", "must be \"start\", \"end\" or \"far\"");
    if ("autoTunnelTo" in raw) { if (typeof raw.autoTunnelTo === "string" && /^(fastest|[A-Z]{2})$/.test(raw.autoTunnelTo)) c.autoTunnelTo = raw.autoTunnelTo; else bad("autoTunnelTo", "must be \"fastest\" or a country's two capitals"); }
    if ("autoTunnelOn" in raw) { if (raw.autoTunnelOn === "any" || raw.autoTunnelOn === "wifi") c.autoTunnelOn = raw.autoTunnelOn; else bad("autoTunnelOn", "must be \"any\" or \"wifi\""); }
    if ("newNetworks" in raw) { if (raw.newNetworks === "public" || raw.newNetworks === "trusted") c.newNetworks = raw.newNetworks; else bad("newNetworks", "must be \"public\" or \"trusted\""); }
    if (raw.bar && typeof raw.bar === "object") {
        if ("traffic" in raw.bar) { if (typeof raw.bar.traffic === "boolean") c.bar.traffic = raw.bar.traffic; else bad("bar.traffic", "must be true or false"); }
        if ("trafficFromMbps" in raw.bar) { if (num(raw.bar.trafficFromMbps, 1, 999)) c.bar.trafficFromMbps = raw.bar.trafficFromMbps; else bad("bar.trafficFromMbps", "must be 1..999"); }
    }
    if ("btLow" in raw) {
        if (Array.isArray(raw.btLow) && raw.btLow.length <= 4 && raw.btLow.every(function (v) { return num(v, 1, 50) && Math.floor(v) === v; }))
            c.btLow = raw.btLow.slice();
        else
            bad("btLow", "must be a list of at most four whole numbers 1..50");
    }
    if ("sounds" in raw) { if (typeof raw.sounds === "boolean") c.sounds = raw.sounds; else bad("sounds", "must be true or false"); }
    return c;
}

// ------------------------------------------------------------------------------------------------ small helpers
function _arr(x) {
    // A list wrapper handed over by QML is not an Array.isArray array (CLAUDE.md): copy by length.
    if (!x || typeof x.length !== "number" || typeof x === "string")
        return [];
    var out = [];
    for (var i = 0; i < x.length; i++)
        out.push(x[i]);
    return out;
}
function arrOf(x) { return _arr(x); }
function _str(x) { return typeof x === "string" ? x : (x === null || x === undefined ? "" : String(x)); }
function _num(x, d) { return typeof x === "number" && isFinite(x) ? x : (d === undefined ? 0 : d); }
function _obj(x) { return x && typeof x === "object" ? x : {}; }

// NM's boottime clocks (AccessPoint.LastSeen in seconds, Device.LastScan in ms) -> epoch ms; a value already an epoch passes.
function _fromBoot(v, unit, bootMs) {
    v = _num(v, 0);
    if (v <= 0)
        return 0;
    var ms = v * unit;
    if (ms > 1e12)
        return ms;
    return bootMs > 0 ? bootMs + ms : 0;
}

// ------------------------------------------------------------------------------------------------ bands, channels, security
function bandOf(freqMhz) {
    var f = _num(freqMhz, 0);
    if (f >= 2400 && f < 2500) return "2.4";
    if (f >= 4900 && f < 5900) return "5";
    if (f >= 5925 && f <= 7125) return "6";
    return "";
}

function channelOf(freqMhz) {
    var f = _num(freqMhz, 0);
    var b = bandOf(f);
    if (b === "2.4") return f === 2484 ? 14 : Math.round((f - 2407) / 5);
    if (b === "5") return Math.round((f - 5000) / 5);
    if (b === "6") return f === 5935 ? 2 : Math.round((f - 5950) / 5);
    return 0;
}

// NM's 802.11 security flags (NM_802_11_AP_SEC_*): KEY_MGMT_PSK 0x100, _802_1X 0x200, _SAE 0x400, _OWE 0x800, _OWE_TM 0x1000, _EAP_SUITE_B_192 0x2000.
function securityOf(flags, wpaFlags, rsnFlags) {
    var w = _num(wpaFlags, 0), r = _num(rsnFlags, 0), all = w | r;
    if (all === 0)
        return (_num(flags, 0) & 1) ? "wep" : "open";
    if (all & (0x200 | 0x2000))
        return "eap";
    var psk = (all & 0x100) !== 0, sae = (all & 0x400) !== 0;
    if (psk && sae) return "wpa2/3";
    if (sae) return "wpa3";
    if (psk) return "wpa2";
    if (all & (0x800 | 0x1000)) return "owe";
    return "wpa2";
}

// How "secure" one is, to pick the one a name is shown with when its APs disagree (a transition-mode name).
var _SEC_RANK = { open: 0, owe: 1, wep: 2, wpa2: 3, "wpa2/3": 4, wpa3: 5, eap: 6 };

// A profile's key-management word (the helper's `security`) -> the same vocabulary.
function profileSecurity(s) {
    s = _str(s).toLowerCase();
    if (s === "" || s === "none" || s === "open") return "open";
    if (s === "wpa-eap" || s === "ieee8021x" || s === "eap") return "eap";
    if (s === "sae" || s === "wpa3") return "wpa3";
    if (s === "owe") return "owe";
    if (s === "wep" || s === "static") return "wep";
    if (s === "wpa-psk-sae" || s === "wpa2/3") return "wpa2/3";
    return "wpa2";
}

function standardOf(word, band) {
    var s = _str(word).toLowerCase();
    if (s === "") return "";
    var six = (band === "6");
    if (/eht|wi-?fi ?7/.test(s)) return "Wi-Fi 7";
    if (/\bhe\b|ax|wi-?fi ?6|^6$|^he/.test(s) || s.indexOf("6e") >= 0)
        return six ? "Wi-Fi 6E" : "Wi-Fi 6";
    if (/vht|\bac\b|wi-?fi ?5|^5$/.test(s)) return "Wi-Fi 5";
    if (/\bht\b|\bn\b|wi-?fi ?4|^4$/.test(s)) return "Wi-Fi 4";
    return "";
}

// ------------------------------------------------------------------------------------------------ signal bands with hysteresis
// Band b covers [BAND_MIN[b], BAND_MIN[b-1]). A network changes band only when it is clearly inside the next one (HYST points past
// the edge), so a noisy signal around an edge keeps its band. `prev` is the band it had (undefined for a network seen the first time).
var BAND_MIN = [70, 50, 30, 0];
var HYST = 6;

function signalBandOf(signal, prev) {
    var s = _num(signal, 0);
    var b = 3;
    if (prev !== 0 && prev !== 1 && prev !== 2 && prev !== 3) {
        while (b > 0 && s >= BAND_MIN[b - 1]) b--;
        return b;
    }
    b = prev;
    while (b > 0 && s >= BAND_MIN[b - 1] + HYST) b--;
    while (b < 3 && s < BAND_MIN[b] - HYST) b++;
    return b;
}

// ------------------------------------------------------------------------------------------------ NM states
function _activeState(s) {
    if (typeof s === "number") return ["unknown", "activating", "activated", "deactivating", "deactivated"][s] || "unknown";
    s = _str(s).toLowerCase();
    return s;
}
function _netState(s) {
    var a = _activeState(s);
    return a === "activated" ? "connected" : a === "activating" ? "connecting" : a === "deactivating" ? "disconnecting" : "idle";
}

// ------------------------------------------------------------------------------------------------ IP configs
function _addrPart(a) {
    if (a && typeof a === "object")
        return { ip: _str(a.address), prefix: _num(a.prefix, 0) };
    var s = _str(a), i = s.indexOf("/");
    return i < 0 ? { ip: s, prefix: 0 } : { ip: s.substring(0, i), prefix: _num(parseInt(s.substring(i + 1), 10), 0) };
}

// The helper's `ip4` (any of {address, prefix, gateway, dns} / {addresses: [...], gateway, nameservers}) -> one shape.
function ipOf(x) {
    var out = { ip: "", prefix: 0, gateway: "", dns: [] };
    if (!x || typeof x !== "object")
        return out;
    var list = _arr(x.addresses);
    var first = x.address !== undefined && x.address !== null ? x.address : (list.length ? list[0] : "");
    var p = _addrPart(first);
    out.ip = p.ip;
    out.prefix = p.prefix || _num(x.prefix, 0);
    out.gateway = _str(x.gateway);
    out.dns = _arr(x.dns !== undefined ? x.dns : x.nameservers).map(function (d) { return _str(d && typeof d === "object" ? d.address : d); }).filter(function (d) { return d !== ""; });
    return out;
}
function _ip6List(x) {
    if (!x) return [];
    var src = typeof x.length === "number" && typeof x !== "string" ? _arr(x) : _arr(x.addresses);
    return src.map(function (a) { return _addrPart(a).ip; }).filter(function (a) { return a !== ""; });
}

// ------------------------------------------------------------------------------------------------ interfaces that are never the network
function isVirtualIface(name) {
    return /^(lo|docker|br-|veth|virbr|vboxnet|vmnet|tun|tap|wg|proton|pvpn|ipv6leak|p2p-dev|dummy|ifb)/.test(_str(name));
}

// Proton's dummy connections hold the PRIMARY for ~0.8 s on every connect (S0): they are never the network.
function isKillswitch(a) {
    var id = _str(a && a.id), devs = _arr(a && a.devices);
    if (/^pvpn-killswitch/.test(id)) return true;
    for (var i = 0; i < devs.length; i++)
        if (/^(pvpnksintrf|ipv6leakintrf)/.test(_str(devs[i]))) return true;
    return false;
}

// Proton's tunnel: an active wireguard connection named "ProtonVPN *" on proton0.
function isProtonConn(a) {
    if (!a || isKillswitch(a)) return false;
    if (_str(a.type) !== "wireguard" && _str(a.type) !== "wireguard-proton") return false;
    if (!/^ProtonVPN /i.test(_str(a.id))) return false;
    var devs = _arr(a.devices);
    return devs.length === 0 || devs.indexOf("proton0") >= 0;
}

function _isWifiType(t) { t = _str(t); return t === "802-11-wireless" || t === "wifi"; }
function _isWiredType(t) { t = _str(t); return t === "802-3-ethernet" || t === "ethernet"; }

// The physical device carrying the active non-VPN default connection; "" when none. Routing is by policy (S0), so the main table's
// default route alone is not read: an active connection that is not a tunnel, not a dummy, holds the default and is on a real link.
function carryingIface(active, devices) {
    var act = _arr(active), devs = _arr(devices);
    function physical(name) {
        for (var i = 0; i < devs.length; i++)
            if (devs[i].iface === name) return (devs[i].type === "wifi" || devs[i].type === "ethernet") && !isVirtualIface(name);
        return false;
    }
    var fallback = "";
    for (var i = 0; i < act.length; i++) {
        var a = act[i];
        if (a.vpn === true || isKillswitch(a) || isProtonConn(a) || _activeState(a.state) !== "activated")
            continue;
        var ds = _arr(a.devices);
        for (var j = 0; j < ds.length; j++) {
            if (!physical(ds[j])) continue;
            if (a.default4 === true || a.default6 === true) return ds[j];
            if (fallback === "") fallback = ds[j];
        }
    }
    return fallback;
}

// ------------------------------------------------------------------------------------------------ trust
// The map is uuid -> true. Absent = Public. The first run (no file) trusts every profile that exists; afterwards a new one is Public --
// unless aerial.jsonc says new networks are trusted (`absent` true): then absent is Trusted, and a profile marked Public is kept as false.
function trustedOf(map, uuid, absent) {
    if (!!map && (map[uuid] === true || map[uuid] === false))
        return map[uuid];
    return absent === true;
}
function trustSeed(profiles) {
    var m = {};
    var ps = _arr(profiles);
    for (var i = 0; i < ps.length; i++)
        if (ps[i].uuid) m[ps[i].uuid] = true;
    return m;
}
function trustSet(map, uuids, on, absent) {
    var m = {};
    for (var k in map) if (map[k] === true || map[k] === false) m[k] = map[k];
    for (var i = 0; i < uuids.length; i++) {
        if (on === (absent === true)) delete m[uuids[i]]; else m[uuids[i]] = on;
    }
    return m;
}
function trustFromJson(text) {
    if (!text || String(text).trim() === "") return null;
    try {
        var o = JSON.parse(text);
        if (!o || typeof o !== "object" || Array.isArray(o)) return null;
        var src = o.trusted && typeof o.trusted === "object" ? o.trusted : {};
        var m = {};
        for (var k in src) if (src[k] === true || src[k] === false) m[k] = src[k];
        return m;
    } catch (e) {
        return null;
    }
}
function trustToJson(map) {
    return JSON.stringify({ version: 1, trusted: map }, null, 1) + "\n";
}

// ------------------------------------------------------------------------------------------------ Wi-Fi
function _apFold(a, activeApPath, activeBssid, bootMs) {
    var f = _num(a.freq, 0);
    var band = bandOf(f);
    var bssid = _str(a.bssid).toUpperCase();
    return {
        bssid: bssid,
        freqMhz: f,
        channel: channelOf(f),
        band: band,
        widthMhz: _num(a.width, 20),
        signal: Math.max(0, Math.min(100, Math.round(_num(a.strength, 0)))),
        maxRateMbps: Math.round(_num(a.maxBitrate, 0) / 1000),     // NM: kbit/s
        lastSeenMs: _num(a.lastSeenMs, 0) > 0 ? a.lastSeenMs : _fromBoot(a.lastSeen, 1000, bootMs),
        active: (activeApPath !== "" && a.path === activeApPath) || (activeBssid !== "" && bssid === activeBssid),
        _sec: securityOf(a.flags, a.wpaFlags, a.rsnFlags),
        _ssid: _str(a.ssid)
    };
}

// Profiles of the wifi type, folded to the contract's Profile (+ internal `mode`).
function foldProfiles(profiles, trust, scannedSsids, trustAbsent) {
    var ps = _arr(profiles).filter(function (p) { return _isWifiType(p.type); });
    var scanned = {};
    for (var s in (scannedSsids || {})) scanned[s] = true;
    var out = ps.map(function (p) {
        var doubles = [];
        for (var i = 0; i < ps.length; i++)
            if (ps[i].uuid !== p.uuid && _str(ps[i].ssid) === _str(p.ssid) && _str(ps[i].mode || "infrastructure") === _str(p.mode || "infrastructure"))
                doubles.push(ps[i].uuid);
        return {
            uuid: _str(p.uuid), name: _str(p.id), ssid: _str(p.ssid), security: profileSecurity(p.security),
            autoconnect: p.autoconnect !== false, priority: _num(p.autoconnectPriority !== undefined ? p.autoconnectPriority : p.priority, 0),
            lastUsedMs: _num(p.timestamp, 0) * 1000, hidden: p.hidden === true,
            inRange: scanned[_str(p.ssid)] === true, trusted: trustedOf(trust, p.uuid, trustAbsent), doubles: doubles,
            ap: _str(p.mode) === "ap",
            // the profile's own settings, as the helper reads them (no secrets): the panels prefill their pages from these
            ip4method: _str(p.ip4method), metered: _str(p.metered) || "unknown", macPolicy: _str(p.macPolicy) || "default",
            band: _str(p.band), bssid: _str(p.bssid), powersave: _num(p.powersave, 0),
            eap: p.eap ? { method: _str(p.eap.method), phase2: _str(p.eap.phase2), identity: _str(p.eap.identity),
                           anonymousIdentity: _str(p.eap.anonymousIdentity), caCert: _str(p.eap.caCert), domain: _str(p.eap.domain),
                           systemCaCerts: p.eap.systemCaCerts === true } : null
        };
    });
    return out;
}

// The wifi fact. `s`: { wifiSnap, devices, active, profiles, nm, link, dbm, trust, prevBands, overrides, activeSince, bootMs, nowMs, hotspotSsids }.
function buildWifi(s) {
    var snap = _obj(s.wifiSnap), nm = _obj(s.nm), bootMs = _num(s.bootMs, 0);
    var dev = _obj(snap.device);
    var devs = _arr(s.devices);
    var wd = null;
    for (var di = 0; di < devs.length; di++)
        if (devs[di].type === "wifi" && !isVirtualIface(devs[di].iface) && (wd === null || devs[di].iface === dev.iface)) wd = devs[di];
    var iface = _str(dev.iface) || (wd ? _str(wd.iface) : "");
    var present = iface !== "";
    var nowMs = _num(s.nowMs, 0);

    var activeApPath = _str(snap.activeAp);
    // the helper's `activeAp` is the active AP's BSSID; a D-Bus path (a probe's fixture) matches by path
    var activeBssid = (/^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/.test(_str(snap.activeBssid || snap.activeAp)) ? _str(snap.activeBssid || snap.activeAp) : "").toUpperCase();
    if (activeBssid !== "") activeApPath = "";
    var aps = _arr(snap.aps).map(function (a) { return _apFold(a, activeApPath, activeBssid, bootMs); });
    // an AP that fills only the path of the active one: its bssid is the active bssid
    var scanned = {};
    // group: one Net per SSID; a hidden AP is its own
    var groups = {}, order = [];
    for (var i = 0; i < aps.length; i++) {
        var ap = aps[i];
        var key = ap._ssid !== "" ? ap._ssid : "hidden:" + ap.bssid;
        if (!groups[key]) { groups[key] = []; order.push(key); }
        groups[key].push(ap);
        if (ap._ssid !== "") scanned[ap._ssid] = true;
    }
    order.sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0; });

    var profiles = foldProfiles(s.profiles, s.trust, scanned, s.trustAbsent === true);
    var bySsid = {};
    for (var pi = 0; pi < profiles.length; pi++) {
        if (profiles[pi].ap) continue;
        (bySsid[profiles[pi].ssid] = bySsid[profiles[pi].ssid] || []).push(profiles[pi]);
    }
    var hotspotSsids = {};
    for (var hi = 0; hi < profiles.length; hi++) if (profiles[hi].ap) hotspotSsids[profiles[hi].ssid] = true;

    // the active wifi connection (infrastructure only: an AP-mode one is the hotspot)
    var act = _arr(s.active), activeConn = null;
    var apUuids = {};
    for (var xi = 0; xi < profiles.length; xi++) if (profiles[xi].ap) apUuids[profiles[xi].uuid] = true;
    for (var ai = 0; ai < act.length; ai++) {
        var a0 = act[ai];
        if (!_isWifiType(a0.type) || apUuids[a0.uuid] || isKillswitch(a0)) continue;
        var st = _activeState(a0.state);
        if (st === "activated" || st === "activating") { if (!activeConn || st === "activated") activeConn = a0; }
    }
    var ov = _obj(s.overrides), prevBands = _obj(s.prevBands);
    var nets = order.map(function (key) {
        var list = groups[key].slice().sort(function (a, b) { return a.bssid < b.bssid ? -1 : a.bssid > b.bssid ? 1 : 0; });
        var best = list[0];
        var secBest = list[0]._sec;
        for (var k = 0; k < list.length; k++) {
            if (list[k].signal > best.signal) best = list[k];
            if ((_SEC_RANK[list[k]._sec] || 0) > (_SEC_RANK[secBest] || 0)) secBest = list[k]._sec;
        }
        var bands = [];
        ["2.4", "5", "6"].forEach(function (b) { if (list.some(function (x) { return x.band === b; })) bands.push(b); });
        var ssid = list[0]._ssid;
        var profs = ssid !== "" ? (bySsid[ssid] || []) : [];
        var uuids = profs.map(function (p) { return p.uuid; });
        var st = "idle";
        if (activeConn && (uuids.indexOf(activeConn.uuid) >= 0 || list.some(function (x) { return x.active; })))
            st = _netState(activeConn.state);
        var o = ov[key];
        var failReason = "";
        if (st === "idle" && o && (o.state === "needsSecret" || o.state === "failed")) { st = o.state; failReason = _str(o.failReason); }
        return {
            key: key, ssid: ssid, hidden: ssid === "", security: secBest, bands: bands, bestBand: best.band,
            signal: best.signal, signalBand: signalBandOf(best.signal, prevBands[key]),
            aps: list.map(function (x) { return { bssid: x.bssid, freqMhz: x.freqMhz, channel: x.channel, band: x.band, widthMhz: x.widthMhz,
                                                   signal: x.signal, maxRateMbps: x.maxRateMbps, lastSeenMs: x.lastSeenMs, active: x.active }; }),
            known: profs.length > 0, profileUuids: uuids, connected: st === "connected", state: st, failReason: failReason,
            trusted: profs.length > 0 && profs.every(function (p) { return p.trusted; }),
            ownHotspot: ssid !== "" && hotspotSsids[ssid] === true
        };
    });

    // Active
    var active = null;
    if (activeConn && present) {
        var link = _obj(s.link);
        var net = null;
        for (var ni = 0; ni < nets.length; ni++)
            if (nets[ni].profileUuids.indexOf(activeConn.uuid) >= 0 || nets[ni].aps.some(function (x) { return x.active; })) { net = nets[ni]; if (net.profileUuids.indexOf(activeConn.uuid) >= 0) break; }
        var apAct = null;
        if (net) for (var q = 0; q < net.aps.length; q++) if (net.aps[q].active) apAct = net.aps[q];
        if (!apAct && net) apAct = net.aps.length ? net.aps.slice().sort(function (a, b) { return b.signal - a.signal; })[0] : null;
        var ip = ipOf(wd ? wd.ip4 : null);
        var actProfile = null;
        for (var ap2 = 0; ap2 < profiles.length; ap2++) if (profiles[ap2].uuid === activeConn.uuid) actProfile = profiles[ap2];
        var band = apAct ? apAct.band : "";
        var rate = _num(link.rxMbps, 0) || _num(link.txMbps, 0);
        active = {
            key: net ? net.key : (actProfile ? actProfile.ssid : _str(activeConn.id)),
            ssid: net ? net.ssid : (actProfile ? actProfile.ssid : _str(activeConn.id)),
            uuid: _str(activeConn.uuid), bssid: apAct ? apAct.bssid : "", band: band,
            channel: apAct ? apAct.channel : 0, widthMhz: apAct ? apAct.widthMhz : 0,
            standard: standardOf(link.standard, band),
            dbm: _num(s.dbm, 0) || _num(link.dbm, 0), rateMbps: Math.round(rate),
            ip4: ip.ip, prefix4: ip.prefix, gateway4: ip.gateway, ip6: _ip6List(wd ? wd.ip6 : null), dns: ip.dns,
            mac: _str(wd ? wd.hwAddress : dev.hwAddress), sinceMs: _num(_obj(s.activeSince)[activeConn.uuid], 0)
        };
    }

    return {
        present: present, iface: iface, mac: _str(dev.hwAddress || (wd && wd.hwAddress)), permMac: _str(dev.permHwAddress || (wd && wd.permHwAddress)),
        driver: _str(dev.driver || (wd && wd.driver)), firmware: _str(dev.firmware), country: _str(dev.country),
        radioOn: present && nm.wirelessEnabled !== false, softBlocked: nm.wirelessEnabled === false,
        hardBlocked: nm.wirelessHardwareEnabled === false || (nm.wirelessHardwareEnabled === undefined && snap.hardwareEnabled === false),
        scanning: snap.scanning === true, lastScanMs: _num(snap.lastScanMs, 0) > 0 ? snap.lastScanMs : _fromBoot(snap.lastScan, 1, bootMs), powersave: dev.powersave === true || dev.powersave === 3,
        networks: nets, active: active,
        profiles: profiles.map(function (p) { return { uuid: p.uuid, name: p.name, ssid: p.ssid, security: p.security, autoconnect: p.autoconnect,
                                                       priority: p.priority, lastUsedMs: p.lastUsedMs, hidden: p.hidden, inRange: p.inRange,
                                                       trusted: p.trusted, doubles: p.doubles }; })
    };
}

// key -> band of every net, to hand back as the next `prevBands`.
function bandsOf(wifi) {
    var m = {};
    var nets = _arr(wifi && wifi.networks);
    for (var i = 0; i < nets.length; i++) m[nets[i].key] = nets[i].signalBand;
    return m;
}

// ------------------------------------------------------------------------------------------------ wired
function _devState(n) {
    if (typeof n === "string") n = ({ unmanaged: 10, unavailable: 20, disconnected: 30, prepare: 40, config: 50, "need-auth": 60, "ip-config": 70, "ip-check": 80, secondaries: 90, activated: 100, deactivating: 110, failed: 120 })[n.toLowerCase()];
    n = _num(n, 0);
    if (n >= 120) return "failed";
    if (n === 100) return "connected";
    if (n >= 40 && n < 100) return "connecting";
    if (n === 110) return "disconnecting";
    if (n === 30) return "disconnected";
    if (n === 20) return "unavailable";
    if (n === 10) return "unmanaged";
    return "unavailable";
}

function _isUsbEthernet(d) {
    return /^(cdc_|rndis|ipheth|r8152|asix|ax88|smsc|lan78|usbnet|aqc111)/.test(_str(d.driver)) || d.usb === true;
}

function buildWired(s) {
    var devs = _arr(s.devices), act = _arr(s.active);
    var jacks = [];
    for (var i = 0; i < devs.length; i++) {
        var d = devs[i];
        if (d.type !== "ethernet" || isVirtualIface(d.iface)) continue;
        var conn = null;
        for (var j = 0; j < act.length; j++)
            if (_isWiredType(act[j].type) && _arr(act[j].devices).indexOf(d.iface) >= 0 && _activeState(act[j].state) !== "deactivated") conn = act[j];
        var ip = ipOf(d.ip4);
        var st = _devState(d.state);
        jacks.push({
            iface: _str(d.iface), kind: _isUsbEthernet(d) ? "usb" : "rj45", carrier: d.carrier === true,
            speedMbps: _num(d.speed, 0), state: st, connected: st === "connected" && conn !== null,
            uuid: conn ? _str(conn.uuid) : "", ip4: ip.ip, prefix4: ip.prefix, gateway4: ip.gateway, dns: ip.dns, mac: _str(d.hwAddress)
        });
    }
    jacks.sort(function (a, b) { return a.iface < b.iface ? -1 : a.iface > b.iface ? 1 : 0; });
    return { jacks: jacks };
}

// ------------------------------------------------------------------------------------------------ hotspot
function buildHotspot(s, wifi, wired) {
    var profiles = _arr(s.profiles).filter(function (p) { return _isWifiType(p.type) && _str(p.mode) === "ap"; });
    var act = _arr(s.active);
    var prof = profiles.length ? profiles[0] : null;
    var on = null;
    for (var i = 0; i < act.length; i++)
        for (var j = 0; j < profiles.length; j++)
            if (act[i].uuid === profiles[j].uuid && _activeState(act[i].state) !== "deactivated") { on = act[i]; prof = profiles[j]; }
    var missing = !wifi.present ? "device" : (s.dnsmasq === false ? "dnsmasq" : "");
    var state = on ? (_activeState(on.state) === "activated" ? "active" : _activeState(on.state) === "activating" ? "starting" : "stopping") : "off";
    var cable = _arr(wired && wired.jacks).some(function (j) { return j.connected; });
    return {
        available: missing === "", missing: missing, active: on !== null && _activeState(on.state) === "activated", state: state,
        uuid: prof ? _str(prof.uuid) : "", ssid: prof ? _str(prof.ssid) : "", band: prof ? _str(prof.band) : "",
        hasPassword: prof ? profileSecurity(prof.security) !== "open" : true,
        clients: _arr(s.clients).map(function (c) { return { mac: _str(c.mac), ip: _str(c.ip), name: _str(c.name), dbm: _num(c.dbm, 0) }; }),
        uplink: cable ? "cable" : "none"
    };
}

// ------------------------------------------------------------------------------------------------ Proton
var FEATURE_BITS = [[1, "secure-core"], [2, "tor"], [4, "p2p"], [8, "streaming"], [16, "ipv6"]];
function featureNames(x) {
    if (typeof x === "number") return FEATURE_BITS.filter(function (b) { return (x & b[0]) !== 0; }).map(function (b) { return b[1]; });
    return _arr(x).map(_str);
}

// The catalog fact from the helper's `catalog` message.
function catalogFact(msg, serial) {
    var m = _obj(msg);
    var cs = _arr(m.countries).map(function (c) {
        return {
            code: _str(c.code), name: _str(c.name), lat: _num(c.lat, 0), lon: _num(c.lon, 0), servers: _num(c.servers, 0),
            minLoad: _num(c.minLoad, 0), features: featureNames(c.features),
            cities: _arr(c.cities).map(function (ci) {
                return { name: _str(ci.name), lat: _num(ci.lat, 0), lon: _num(ci.lon, 0),
                         servers: _arr(ci.servers).map(function (sv) { return { name: _str(sv.name), load: _num(sv.load, 0), features: featureNames(sv.features), status: sv.status === undefined ? 1 : sv.status }; }) };
            })
        };
    });
    return { serial: _num(serial, 0), tier: _num(m.tier, 0), countries: cs };
}

function serverInfo(catalog, name) {
    var cs = _arr(catalog && catalog.countries);
    for (var i = 0; i < cs.length; i++)
        for (var j = 0; j < cs[i].cities.length; j++)
            for (var k = 0; k < cs[i].cities[j].servers.length; k++)
                if (cs[i].cities[j].servers[k].name === name)
                    return { country: cs[i].code, city: cs[i].cities[j].name, load: cs[i].cities[j].servers[k].load, features: cs[i].cities[j].servers[k].features };
    return null;
}

// `protonvpn config list` prints its own labels ("Kill Switch", "NetShield", "IPv6", "Custom DNS"): keys compared without case,
// spaces or dashes, values read by their words.
function protonConfig(raw) {
    var out = { killSwitch: "off", netshield: "off", ipv6: false, customDns: "" };
    var o = _obj(raw);
    for (var k in o) {
        var key = k.toLowerCase().replace(/[^a-z0-9]/g, "");
        var v = _str(o[k]).trim();
        var w = v.toLowerCase().replace(/[^a-z0-9]+/g, "-");
        if (key === "killswitch") out.killSwitch = (w === "standard" || w === "on" || w === "enabled" || w === "true") ? "standard" : "off";
        else if (key === "netshield") out.netshield = /ads|tracker|full/.test(w) ? "malware-ads-trackers" : /malware/.test(w) ? "malware-only" : "off";
        else if (key === "ipv6") out.ipv6 = (w === "on" || w === "true" || w === "enabled" || o[k] === true);
        else if (key === "customdns") out.customDns = (w === "" || w === "off" || w === "none" || w === "disabled" || w === "false") ? "" : v;
    }
    return out;
}

// The exit country of a Proton server name from its own prefix: "NL#799" -> "NL", secure core "IS-NL#1" (entry-exit) -> "NL", "NL-FREE#133" -> "NL".
function countryOfName(name) {
    var parts = _str(name).split("#")[0].split("-");
    for (var i = parts.length - 1; i >= 0; i--)
        if (/^[A-Z]{2}$/.test(parts[i])) return parts[i];
    return "";
}

// s.proton: { installed, signedIn, locked, config, status, failed, fastestAsk, fastestServer }, s.active, s.catalog, s.autoTunnel, s.waiting.
function buildProton(s) {
    var p = _obj(s.proton), cfg = protonConfig(p.config), st = _obj(p.status);
    var act = _arr(s.active);
    var conn = null;
    for (var i = 0; i < act.length; i++) if (isProtonConn(act[i])) conn = act[i];
    var state = "down";
    if (conn) {
        var a = _activeState(conn.state);
        state = a === "activated" ? "up" : a === "activating" ? "connecting" : a === "deactivating" ? "disconnecting" : "down";
    }
    if (state === "down" && p.failed === true) state = "failed";
    var server = null;
    if (conn) {
        // The ACTIVE CONNECTION's id says which server the tunnel is on; the CLI's last words (the helper emits them only when a connect / status
        // child EXITS, after NetworkManager has already switched) are about it only when they name the same server -- else they are the
        // previous tunnel's, and the catalogue, then the name's own prefix, answer.
        var sv = st.server && typeof st.server === "object" ? st.server : null;
        var name = _str(conn.id).replace(/^ProtonVPN /i, "") || (sv ? _str(sv.name) : _str(st.server));
        var said = sv ? _str(sv.name) : _str(st.server);
        var same = said === "" || said === name;
        var info = serverInfo(s.catalog, name);
        server = {
            name: name, country: info ? info.country : same ? _str(sv ? sv.country : st.country) || countryOfName(name) : countryOfName(name),
            city: info ? info.city : same ? _str(sv ? sv.city : st.city) : "",
            load: info ? info.load : same ? _num(st.load, 0) : 0, protocol: (same ? _str(st.protocol) : "") || "wireguard", features: info ? info.features : []
        };
    }
    var fastestName = _str(p.fastestServer);
    // the tunnel was asked for with Proton's own pick: while that connect is out (`fastestAsk`), then by the name it landed on (`fastestServer`)
    var fastest = !!server && (p.fastestAsk === true || (fastestName !== "" && server.name === fastestName));
    var ks = cfg.killSwitch, ns = cfg.netshield;
    return {
        installed: p.installed === true, signedIn: p.signedIn === "yes" || p.signedIn === "no" ? p.signedIn : "unknown", locked: p.locked === true, state: state,
        server: server, sinceMs: conn ? _num(_obj(s.activeSince)[conn.uuid], 0) : 0,
        killSwitch: ks, netshield: ns, ipv6: cfg.ipv6, customDns: cfg.customDns,
        autoTunnel: s.autoTunnel === true, waiting: _str(s.waiting), fastest: fastest
    };
}

// ------------------------------------------------------------------------------------------------ the auto-tunnel rule
// Inputs: { enabled, installed, signedIn, hasNetwork, trusted, netPad: "unknown"|"testing"|"ok"|"warn"|"fail", portal: bool,
//           protonState, suppressed }. -> "raise" | "wait-portal" | "wait-link" | "none".
function autoTunnelDecision(i) {
    if (!i || i.enabled !== true || i.installed !== true || i.signedIn !== "yes") return "none";
    if (i.hasNetwork !== true || i.trusted === true || i.suppressed === true) return "none";
    if (i.protonState === "up" || i.protonState === "connecting" || i.protonState === "disconnecting") return "none";
    if (i.portal === true || i.netPad === "warn") return "wait-portal";      // a login page is up: no tunnel before the login
    if (i.netPad === "ok") return "raise";
    return "wait-link";                                                      // unknown / testing / fail: no verified internet yet
}
function waitingOf(decision) {
    return decision === "wait-portal" ? "portal" : decision === "wait-link" ? "link" : "";
}

// ------------------------------------------------------------------------------------------------ the speed-test gate
// "" (allowed), "public" or "metered" -- unless the user confirmed.
function speedGate(net, confirmed) {
    if (confirmed === true) return "";
    if (!net) return "";
    if (net.metered === true) return "metered";
    if (net.trusted === false) return "public";
    return "";
}

// ------------------------------------------------------------------------------------------------ a connection that did not come up
// NetworkManager accepts an activation and fails it LATER (the request's reply says ok): the device walks prepare .. need-auth, then
// fails with a reason (`no-secrets` after a wrong password). `sawAuth`: the device asked for secrets while this attempt ran.
function activationFailText(reason, sawAuth) {
    reason = _str(reason);
    if (sawAuth === true || reason === "no-secrets") return "The password was not accepted.";
    switch (reason) {
    case "supplicant-timeout": case "supplicant-disconnect": return "The network did not answer.";
    case "dhcp-start-failed": case "dhcp-error": case "dhcp-failed": case "ip-config-unavailable": case "ip-config-expired":
        return "The network did not hand out an address.";
    case "supplicant-failed": case "supplicant-config-failed": return "The Wi-Fi driver refused the connection.";
    }
    return "The connection could not be made.";
}

// ------------------------------------------------------------------------------------------------ pads (health)
var PAD_IDS = ["link", "addr", "gateway", "dns", "net"];
function _pad(id, state, detail, ms, at) { return { id: id, state: state, detail: detail || "", atMs: at || 0, ms: ms || 0 }; }

// LINK and ADDR are free facts (an active network; an address); GATEWAY, DNS and NET are the helper's tests (`pads`: id -> record).
function buildHealth(s, wifi, wired) {
    var helperPads = _obj(s.pads), nowMs = _num(s.nowMs, 0);
    var up = wifi.active !== null || _arr(wired.jacks).some(function (j) { return j.connected; });
    var ip = wifi.active ? wifi.active.ip4 : "";
    if (!ip) { var js = _arr(wired.jacks); for (var i = 0; i < js.length; i++) if (js[i].connected && js[i].ip4) ip = js[i].ip4; }
    var pads = PAD_IDS.map(function (id) {
        if (id === "link") return _pad(id, up ? "ok" : "fail", up ? "link is up" : "no network", 0, nowMs);
        if (id === "addr") return _pad(id, !up ? "unknown" : (ip ? "ok" : "fail"), ip ? ip : (up ? "no address" : ""), 0, nowMs);
        var h = helperPads[id];
        if (!up) return _pad(id, "unknown", "", 0, 0);
        return h ? _pad(id, _str(h.state) || "unknown", _str(h.detail), _num(h.ms, 0), _num(h.atMs, nowMs)) : _pad(id, "unknown", "", 0, 0);
    });
    var portal = _obj(s.portal);
    return { pads: pads, portal: { present: portal.present === true, url: _str(portal.url) } };
}

// ------------------------------------------------------------------------------------------------ Bluetooth
function kindOf(icon, name) {
    var i = _str(icon).toLowerCase(), n = _str(name).toLowerCase();
    if (/bud|airpod|earbud|earphone|pods\b/.test(n) || /earbud/.test(i)) return "earbuds";
    if (i.indexOf("headset") >= 0 || i.indexOf("headphone") >= 0) return "headset";
    if (i.indexOf("speaker") >= 0 || i === "audio-card" || i.indexOf("audio-") === 0) return "speaker";
    if (i.indexOf("phone") >= 0) return "phone";
    if (i.indexOf("computer") >= 0 || i.indexOf("laptop") >= 0) return "computer";
    if (i.indexOf("mouse") >= 0) return "mouse";
    if (i.indexOf("keyboard") >= 0) return "keyboard";
    if (i.indexOf("gaming") >= 0 || i.indexOf("joystick") >= 0 || i.indexOf("gamepad") >= 0) return "gamepad";
    if (i.indexOf("watch") >= 0) return "watch";
    return "generic";
}

function _part(p) { return p && isFinite(p.pct) ? { pct: Math.max(0, Math.min(100, Number(p.pct))), charging: !!p.charging } : null; }

// One device's battery: { pct, parts, charging } or null. The same rules as the bar's stripe (BtBattery.js): earbuds = the lower bud,
// the case never counts for the figure, a device that reports only a case reports nothing; only UPower knows charging.
function btBattery(d, upowerParts) {
    var u = upowerParts && d.address ? upowerParts[String(d.address).toUpperCase()] : null;
    var l = u ? _part(u.left) : null, r = u ? _part(u.right) : null, c = u ? _part(u.case) : null, m = u ? _part(u.main) : null;
    var parts = (l || r || c) ? { left: l ? l.pct : -1, right: r ? r.pct : -1, case: c ? c.pct : -1, charging: !!((l && l.charging) || (r && r.charging) || (c && c.charging)) } : null;
    var fig = null;
    if (l || r) fig = (l && r) ? (r.pct < l.pct ? r : l) : (l || r);
    else if (d.batteryAvailable === true) fig = { pct: Math.max(0, Math.min(100, Number(d.battery) || 0)), charging: m ? m.charging : false };
    else if (m) fig = m;
    return { pct: fig ? Math.round(fig.pct) : -1, charging: fig ? fig.charging : false, parts: parts };
}

// s: { btAdapter, btDevices, btParts, btSeen, btSearchUntilMs, btVisibleUntilMs, btPrompt, btRfkill: {soft, hard}, btProfiles, nowMs }.
function buildBt(s) {
    var ad = s.btAdapter;
    var rf = _obj(s.btRfkill), seen = _obj(s.btSeen), prof = _obj(s.btProfiles);
    var present = !!ad;
    var devs = [];
    var src = _arr(s.btDevices);
    for (var i = 0; i < src.length; i++) {
        var d = src[i];
        var addr = _str(d.address).toUpperCase();
        var paired = d.paired === true || d.bonded === true;
        var connected = d.connected === true;
        if (!connected && !paired && seen[addr] !== true && d.pairing !== true) continue;     // a stranger BlueZ remembers is not on the rings
        var b = btBattery(d, s.btParts);
        devs.push({
            address: addr, name: _str(d.name || d.deviceName) || addr, kind: kindOf(d.icon, d.name || d.deviceName),
            ring: connected ? "inner" : paired ? "middle" : "outer", connected: connected, paired: paired, trusted: d.trusted === true,
            blocked: d.blocked === true, pairing: d.pairing === true, battery: connected || b.pct >= 0 ? b.pct : -1, parts: b.parts,
            rssi: _num(d.rssi, 0), profile: connected && prof[addr] ? prof[addr] : null
        });
    }
    devs.sort(function (a, b) { return a.address < b.address ? -1 : a.address > b.address ? 1 : 0; });
    var nowMs = _num(s.nowMs, 0);
    var searchUntil = _num(s.btSearchUntilMs, 0), visUntil = _num(s.btVisibleUntilMs, 0);
    return {
        present: present, powered: present && ad.enabled === true, softBlocked: rf.soft === true || (present && ad.state === "Blocked") || (present && ad.state === "blocked"),
        hardBlocked: rf.hard === true,
        discoverable: present && ad.discoverable === true, visibleUntilMs: visUntil > nowMs ? visUntil : 0,
        discovering: present && ad.discovering === true, searchUntilMs: searchUntil > nowMs ? searchUntil : 0,
        name: present ? _str(ad.name) : "", address: present ? _str(ad.address) : "", devices: devs, prompt: s.btPrompt || null
    };
}

// The unpaired addresses to remember as "seen while searching": every unpaired device present while discovering.
function btSeenNext(seen, devices, discovering) {
    var m = {};
    for (var k in _obj(seen)) m[k] = true;
    if (!discovering) return m;
    var ds = _arr(devices);
    for (var i = 0; i < ds.length; i++)
        if (!(ds[i].paired === true || ds[i].bonded === true || ds[i].connected === true)) m[_str(ds[i].address).toUpperCase()] = true;
    return m;
}

// Low battery: at each of `levels` (aerial.jsonc btLow, 20 % and 10 % by default), once per crossing per device -- the deepest level crossed,
// the ones above it counted as told -- re-armed 5 points above the highest, never while charging. state: addr -> { told: [levels] }.
// Returns { state, events: [{ address, name, battery, level }] }.
function lowBattery(state, devices, levels) {
    var lv = (levels === undefined ? [20, 10] : _arr(levels)).slice().sort(function (a, b) { return b - a; });
    var st = {};
    for (var k in _obj(state)) st[k] = { told: _arr(state[k].told).slice() };
    var events = [];
    if (lv.length === 0) return { state: st, events: events };
    var ds = _arr(devices);
    for (var i = 0; i < ds.length; i++) {
        var d = ds[i];
        var e = st[d.address] || (st[d.address] = { told: [] });
        var pct = d.battery;
        if (!d.connected || typeof pct !== "number" || pct < 0) continue;
        if (pct > lv[0] + 5) { e.told = []; continue; }
        var charging = d.parts && d.parts.charging === true;
        if (charging) continue;
        var deepest = -1;
        for (var j = 0; j < lv.length; j++)
            if (pct <= lv[j]) deepest = lv[j];
        if (deepest < 0 || e.told.indexOf(deepest) >= 0) continue;
        e.told = lv.filter(function (l) { return l >= deepest; });
        events.push({ address: d.address, name: d.name, battery: pct, level: deepest });
    }
    return { state: st, events: events };
}

// ------------------------------------------------------------------------------------------------ everything folded at once
function compose(s) {
    var wifi = buildWifi(s);
    var wired = buildWired(s);
    var hotspot = buildHotspot(s, wifi, wired);
    var health = buildHealth(s, wifi, wired);
    var proton = buildProton(s);
    var bt = buildBt(s);
    return { wifi: wifi, wired: wired, hotspot: hotspot, health: health, proton: proton, bt: bt, bands: bandsOf(wifi),
             rateIface: carryingIface(s.active, s.devices) };
}

// What the service attributes usage to: the active network's key ("wired:<iface>" for a cable), "" when there is none.
function currentNetworkKey(facts) {
    if (facts.wifi.active) return facts.wifi.active.key;
    var js = facts.wired.jacks;
    for (var i = 0; i < js.length; i++) if (js[i].connected) return "wired:" + js[i].iface;
    return "";
}
function currentNetworkLabel(key, facts) {
    if (key.indexOf("wired:") === 0) return "Cable (" + key.substring(6) + ")";
    return key.indexOf("hidden:") === 0 ? "Hidden network" : key;
}

// ------------------------------------------------------------------------------------------------ usage
function pad2(n) { return (n < 10 ? "0" : "") + n; }
// The LOCAL date of an instant, "YYYY-MM-DD". Day steps are `new Date(y, m, d + k)`, never + 86400000 (DST days are 23 / 25 h).
function dayKey(ms) {
    var d = new Date(ms);
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate());
}
function dayKeyBack(ms, k) {
    var d = new Date(ms);
    var e = new Date(d.getFullYear(), d.getMonth(), d.getDate() - k);
    return e.getFullYear() + "-" + pad2(e.getMonth() + 1) + "-" + pad2(e.getDate());
}
var USAGE_KEEP_DAYS = 31;    // 30 shown; one more so the calendar month's first day survives its 31st

function usageNew() { return { days: {}, labels: {}, last: null }; }

// A counter that went backwards (a reboot, an interface reset) counts from 0: the bytes since it was reset.
function counterDelta(prev, cur) {
    if (!(isFinite(prev) && isFinite(cur))) return 0;
    return cur >= prev ? cur - prev : cur;
}

// One sample of the PHYSICAL interface's counters. The bytes since the last sample belong to the network that was active DURING that
// interval (the previous sample's key); the first sample after a start (or on another interface) is a baseline and counts nothing.
// sample: { iface, rx, tx, key, label }. Returns a new state.
function usageSample(state, sample, nowMs) {
    var st = { days: {}, labels: {}, last: null };
    for (var d in state.days) { st.days[d] = {}; for (var k in state.days[d]) st.days[d][k] = state.days[d][k]; }
    for (var l in state.labels) st.labels[l] = state.labels[l];
    var prev = state.last;
    if (sample.key && sample.label) st.labels[sample.key] = sample.label;
    if (prev && prev.iface === sample.iface && prev.key) {
        var delta = counterDelta(prev.rx, sample.rx) + counterDelta(prev.tx, sample.tx);
        if (delta > 0) {
            var dk = dayKey(nowMs);
            st.days[dk] = st.days[dk] || {};
            st.days[dk][prev.key] = (st.days[dk][prev.key] || 0) + delta;
        }
    }
    st.last = { iface: sample.iface, rx: sample.rx, tx: sample.tx, key: sample.key || "" };
    var cutoff = dayKeyBack(nowMs, USAGE_KEEP_DAYS - 1);
    for (var day in st.days) if (day < cutoff) delete st.days[day];
    return st;
}

// The usage fact. `currentKey`: the active network's key.
function usageFacts(state, nowMs, currentKey) {
    var today = dayKey(nowMs), month = today.substring(0, 7);
    var days = [], todayBytes = 0, monthBytes = 0, byKey = {};
    function sum(o) { var t = 0; for (var k in o) t += o[k]; return t; }
    for (var i = 29; i >= 0; i--) {
        var dk = dayKeyBack(nowMs, i);
        days.push({ day: dk, bytes: state.days[dk] ? sum(state.days[dk]) : 0 });
    }
    for (var d in state.days) {
        var inMonth = d.substring(0, 7) === month;
        for (var k in state.days[d]) {
            var e = byKey[k] || (byKey[k] = { key: k, label: state.labels[k] || k, today: 0, month: 0 });
            if (d === today) e.today += state.days[d][k];
            if (inMonth) e.month += state.days[d][k];
        }
        if (d === today) todayBytes = sum(state.days[d]);
        if (inMonth) monthBytes += sum(state.days[d]);
    }
    var list = [];
    for (var kk in byKey) list.push(byKey[kk]);
    list.sort(function (a, b) { return b.month - a.month || (a.key < b.key ? -1 : 1); });
    return { todayBytes: todayBytes, monthBytes: monthBytes, current: { key: currentKey || "", bytes: currentKey && byKey[currentKey] ? byKey[currentKey].today : 0 },
             byNetwork: list, days: days };
}

function usageToJson(state) {
    return JSON.stringify({ version: 1, days: state.days, labels: state.labels }, null, 1) + "\n";
}
// A file that does not parse is an empty record; counters are never stored (a restart is a new baseline).
function usageFromJson(text) {
    var st = usageNew();
    if (!text || String(text).trim() === "") return st;
    try {
        var o = JSON.parse(text);
        if (!o || typeof o !== "object") return st;
        var days = _obj(o.days), labels = _obj(o.labels);
        for (var d in days) {
            if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || typeof days[d] !== "object") continue;
            st.days[d] = {};
            for (var k in days[d]) if (typeof days[d][k] === "number" && isFinite(days[d][k]) && days[d][k] >= 0) st.days[d][k] = days[d][k];
        }
        for (var l in labels) if (typeof labels[l] === "string") st.labels[l] = labels[l];
    } catch (e) { /* an empty record */ }
    return st;
}

// ------------------------------------------------------------------------------------------------ /proc readers
// /proc/net/wireless: "iface: status link level noise ..." -> { iface: dBm }. `level` is dBm (a trailing dot marks the driver's unit).
function parseProcWireless(text) {
    var out = {};
    var lines = _str(text).split("\n");
    for (var i = 2; i < lines.length; i++) {
        var m = /^\s*([^:\s]+):\s+\S+\s+\S+\s+(-?\d+)\.?/.exec(lines[i]);
        if (m) out[m[1]] = parseInt(m[2], 10);
    }
    return out;
}
// /proc/net/dev -> { iface: { rx, tx } } (bytes).
function parseProcNetDev(text) {
    var out = {};
    var lines = _str(text).split("\n");
    for (var i = 2; i < lines.length; i++) {
        var m = /^\s*([^:\s]+):\s*(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)/.exec(lines[i]);
        if (m) out[m[1]] = { rx: parseInt(m[2], 10), tx: parseInt(m[3], 10) };
    }
    return out;
}
// Bytes per second from two counter reads (a backwards counter counts from 0).
function rateBps(prev, cur, dtMs) {
    if (!prev || !cur || !(dtMs > 0)) return { rxBps: 0, txBps: 0 };
    return { rxBps: Math.round(counterDelta(prev.rx, cur.rx) * 1000 / dtMs), txBps: Math.round(counterDelta(prev.tx, cur.tx) * 1000 / dtMs) };
}

// ------------------------------------------------------------------------------------------------ errors
// The part each intent's failure is pinned to (a scene part id, contract section 2) and the way out.
function partOf(intent, arg) {
    arg = _str(arg);
    switch (intent) {
    case "scan": case "disconnect": return "label";
    case "connect": return arg !== "" ? "net:" + arg : "label";
    case "setRadio": case "setPowersave": return "dip.wifi";
    case "setBtPowered": return "dip.bt";
    case "btSearch": return "bt.scan";
    case "btVisible": return "beacon";
    case "btConnect": case "btDisconnect": case "btPair": case "btCancelPair": case "btTrust": case "btBlock": case "btForget": case "btRename":
    case "btSetProfile": case "btAnswer": return arg !== "" ? "bt:" + arg : "bt.scan";
    case "forget": case "setAutoconnect": case "setPriority": case "revealSecret": case "updateProfile": case "mergeDoubles": case "addNetwork": case "setTrusted": return "mem";
    case "connectWired": case "disconnectWired": return "jack";
    case "startHotspot": case "stopHotspot": case "configureHotspot": return "hotspot";
    case "vpnConnect": case "vpnDisconnect": case "vpnSet": case "setAutoTunnel": case "refreshCatalog": return "globe";
    case "testPad": return arg !== "" && arg !== "all" ? "pad." + arg : "pad.net";
    case "openPortal": return "pad.net";
    case "armSpeedTest": case "runSpeedTest": case "cancelSpeedTest": return "rates";
    case "setAirplane": return "screw";
    }
    return "label";
}
var WAYS = {
    "dip.wifi": "Check the Wi-Fi switch, or run rfkill unblock wifi.",
    "dip.bt": "Unblock Bluetooth (rfkill unblock bluetooth) and try again.",
    "globe": "Open the Proton app once to sign in, or try another server.",
    "hotspot": "Install dnsmasq, then start the hotspot again.",
    "jack": "Check the cable, then plug it in again.",
    "screw": "Try again; the radios keep their last state.",
    "pad.net": "Open the login page, or check the connection.",
    "rates": "Try the test again later."
};
function wayOf(part) {
    if (WAYS[part]) return WAYS[part];
    if (part.indexOf("net:") === 0) return "Check the password and try again.";
    if (part.indexOf("bt:") === 0) return "Bring the device close and try again.";
    return "Try again.";
}
function errorRecord(intent, arg, text, nowMs) {
    var part = partOf(intent, arg);
    return { id: intent + ":" + _str(arg), part: part, text: _str(text), way: wayOf(part), sinceMs: nowMs };
}
// A new list: the record replaces one of the same id, else it is appended.
function errorsPush(errors, rec) {
    var out = _arr(errors).filter(function (e) { return e.id !== rec.id; });
    out.push(rec);
    return out;
}
function errorsDismiss(errors, id) {
    return _arr(errors).filter(function (e) { return e.id !== id; });
}
// An error stays until acted on or its cause is gone: the part's fact says it is fine now.
function errorsPrune(errors, facts) {
    var es = _arr(errors);
    var keep = es.filter(function (e) {
        var p = e.part;
        if (p.indexOf("net:") === 0) {
            var nets = _arr(facts.wifi && facts.wifi.networks);
            var n = null;
            for (var i = 0; i < nets.length; i++) if (nets[i].key === p.substring(4)) n = nets[i];
            return n !== null && !n.connected;
        }
        if (p.indexOf("bt:") === 0) {
            var devs = _arr(facts.bt && facts.bt.devices);
            for (var j = 0; j < devs.length; j++) if (devs[j].address === p.substring(3)) return !devs[j].connected || e.id.indexOf("btConnect") < 0 ? true : false;
            return false;
        }
        if (p.indexOf("pad.") === 0) {
            var pads = _arr(facts.health && facts.health.pads);
            for (var k = 0; k < pads.length; k++) if ("pad." + pads[k].id === p) return pads[k].state !== "ok";
            return true;
        }
        if (p === "globe") return !(facts.proton && facts.proton.state === "up" && e.id.indexOf("vpnConnect") === 0);
        if (p === "hotspot") return !(facts.hotspot && facts.hotspot.active && e.id.indexOf("startHotspot") === 0);
        if (p === "dip.wifi") return !(facts.wifi && facts.wifi.radioOn && e.id.indexOf("setRadio") === 0);
        if (p === "dip.bt") return !(facts.bt && facts.bt.powered && e.id.indexOf("setBtPowered") === 0);
        return true;
    });
    return keep.length === es.length ? errors : keep;
}

// ------------------------------------------------------------------------------------------------ an error as a toast
// What the notification says for one record: { key, title, body, action: ""|"portal" }. Pure: the facts decide the way out
// (a login page that is up offers its button; a signed-out Proton names the command). One KEY per error id, so a repeat REPLACES.
var PART_TITLES = {
    "label": "Network", "screw": "Airplane mode", "dip.wifi": "Wi-Fi switch", "dip.bt": "Bluetooth switch", "mem": "Saved networks",
    "jack": "Cable", "bt.scan": "Bluetooth", "beacon": "Bluetooth visibility", "rates": "Speed test", "usage": "Data use",
    "globe": "VPN", "hotspot": "Hotspot", "pad.net": "Connection test"
};
function toastKey(id) { return "fail-" + _str(id); }
function toastWords(rec, facts) {
    var part = _str(rec.part), text = _str(rec.text), way = _str(rec.way);
    var title = PART_TITLES[part] || "Network";
    var action = "";
    if (part.indexOf("net:") === 0) {
        title = "Could not join " + part.substring(4).replace(/^hidden:/, "hidden network ");
    } else if (part.indexOf("bt:") === 0) {
        var devs = _arr(facts && facts.bt && facts.bt.devices), name = part.substring(3);
        for (var i = 0; i < devs.length; i++) if (devs[i].address === name && _str(devs[i].name) !== "") name = devs[i].name;
        title = "Bluetooth: " + name;
    } else if (part.indexOf("pad.") === 0 && part !== "pad.net") {
        title = "Connection test";
    }
    if (part === "pad.net" && _str(rec.id).indexOf("openPortal") !== 0 && facts && facts.health && facts.health.portal && facts.health.portal.present === true)
        action = "portal";
    if (part === "globe" && /not signed in/i.test(text))
        way = "Run `protonvpn signin` in a terminal, then try again.";
    else if (part === "globe" && /not installed/i.test(text))
        way = "Install the ProtonVPN command line tool (protonvpn), then try again.";
    return { key: toastKey(rec.id), title: title, body: way !== "" ? text + " " + way : text, action: action };
}

// ------------------------------------------------------------------------------------------------ writing one switch into a hand-edited config
// `"key": true|false` in the text of config/aerial.jsonc, comments and layout kept; a missing key is inserted after the first `{`.
function setConfigBool(text, key, value) {
    var t = _str(text);
    var v = value === true ? "true" : "false";
    var re = new RegExp('("' + key + '"\\s*:\\s*)(true|false)');
    if (re.test(t))
        return t.replace(re, "$1" + v);
    var i = t.indexOf("{");
    if (i < 0)
        return "{\n    \"" + key + "\": " + v + "\n}\n";
    var rest = t.substring(i + 1);
    var more = /^[\s]*(\/\/[^\n]*\n[\s]*|\/\*[\s\S]*?\*\/[\s]*)*\}/.test(rest) ? "" : ",";
    return t.substring(0, i + 1) + "\n    \"" + key + "\": " + v + more + t.substring(i + 1);
}
