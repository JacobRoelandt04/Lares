.pragma library

// =============================================================================
// AerialMockData.js -- the mock's raw states: what the helper + Quickshell.Bluetooth would have said in each named scenario.
// Pure (the clock comes in); AerialMock folds the result with AerialModel.compose(), exactly as the service folds the real machine.
// =============================================================================

var SCENARIOS = ["home", "crowd", "airplane", "hotspot", "vpn", "portal", "pairing", "earbuds", "nowifi", "errors"];

function rng(seed) {
    var s = 0;
    for (var i = 0; i < seed.length; i++) s = (s * 31 + seed.charCodeAt(i)) >>> 0;
    s = s || 1;
    return function () { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

var SEC = {
    open: { flags: 0, wpa: 0, rsn: 0 }, wpa2: { flags: 1, wpa: 0, rsn: 0x108 }, wpa3: { flags: 1, wpa: 0, rsn: 0x408 },
    "wpa2/3": { flags: 1, wpa: 0, rsn: 0x508 }, eap: { flags: 1, wpa: 0, rsn: 0x208 }
};

var _apSeq = 0;
function ap(bssid, ssid, freq, strength, sec) {
    var f = SEC[sec] || SEC.wpa2;
    _apSeq++;
    return { path: "/mock/ap/" + _apSeq, bssid: bssid, ssid: ssid, ssidHex: "", freq: freq, width: freq > 5000 ? 80 : 20, strength: strength, maxBitrate: freq > 5000 ? 1201000 : 286000,
             flags: f.flags, wpaFlags: f.wpa, rsnFlags: f.rsn, lastSeen: 0, lastSeenMs: 0, mode: 2 };
}
function mac(n) {
    var h = function (x) { return ("0" + (x & 255).toString(16)).slice(-2).toUpperCase(); };
    return "02:" + h(n >> 16) + ":" + h(n >> 8) + ":" + h(n) + ":" + h(n * 7) + ":" + h(n * 13);
}
function profile(uuid, name, ssid, security, o) {
    return Object.assign({ path: "/mock/p/" + uuid, uuid: uuid, id: name, type: "802-11-wireless", ssid: ssid, mode: "infrastructure", security: security, autoconnect: true, priority: 0,
                           timestamp: 1763500000, hidden: false, ip4method: "auto", metered: "unknown", macPolicy: "default", band: "", bssid: "", eap: null }, o || {});
}

var NAMES = ["Home-5G", "Saved-Network-123456", "homenet-ABC12-AP", "Phone-Hotspot", "eduroam", "Cafe-Free", "AndroidAP_4821", "FRITZ!Box 7590", "Orange-2A4F", "DIRECT-roku-381",
             "Hotel Lobby", "Station-Guest", "Linksys00382", "NETGEAR-5G", "VOO-884321", "TP-Link_9F2C", "BELL123", "Xiaomi_Hub", "ZyXEL-AX", "Library", "Guest", "ASUS_5G", "iPhone van Tom",
             "SM-G991B", "Livebox-7B10", "SFR_WiFi", "WiFi-Repeater", "MyRepublic", "Starlink", "Tesla Service", "Printer-HP", "Chromecast-71"];

function tunnel(state) {
    return { path: "/mock/a/p", uuid: "u-proton", id: "ProtonVPN NL#799", type: "wireguard", devices: ["proton0"], state: state === undefined ? 2 : state, vpn: true, default4: false, default6: false, specific: "", proton: true, killswitch: false };
}

function catalog() {
    function sv(cc, n, load) { return { name: cc + "#" + n, load: load, features: n % 3 === 0 ? 4 : 0, status: 1 }; }
    function city(cc, name, lat, lon, base) { return { name: name, lat: lat, lon: lon, servers: [sv(cc, base, 30 + (base * 7) % 50), sv(cc, base + 1, 20 + (base * 11) % 60), sv(cc, base + 2, 40)] }; }
    return { tier: 2, countries: [
        { code: "NL", name: "Netherlands", lat: 52.1, lon: 5.3, servers: 9, minLoad: 30, features: 12, cities: [city("NL", "Amsterdam", 52.37, 4.9, 799), city("NL", "Rotterdam", 51.92, 4.48, 803), city("NL", "Utrecht", 52.09, 5.12, 811)] },
        { code: "CH", name: "Switzerland", lat: 46.8, lon: 8.2, servers: 6, minLoad: 22, features: 3, cities: [city("CH", "Zurich", 47.37, 8.54, 110), city("CH", "Geneva", 46.2, 6.14, 120)] },
        { code: "US", name: "United States", lat: 39.8, lon: -98.6, servers: 9, minLoad: 35, features: 12, cities: [city("US", "New York", 40.7, -74, 501), city("US", "Los Angeles", 34.05, -118.2, 520), city("US", "Chicago", 41.9, -87.6, 540)] },
        { code: "JP", name: "Japan", lat: 36.2, lon: 138.2, servers: 3, minLoad: 41, features: 4, cities: [city("JP", "Tokyo", 35.68, 139.69, 90)] },
        { code: "BR", name: "Brazil", lat: -14.2, lon: -51.9, servers: 3, minLoad: 28, features: 0, cities: [city("BR", "Sao Paulo", -23.55, -46.63, 70)] }] };
}

function usageState(nowMs) {
    var days = {}, labels = { "Home-5G": "Home-5G", "wired:enp46s0": "Cable (enp46s0)", eduroam: "eduroam", "Cafe-Free": "Cafe-Free" };
    var r = rng("usage");
    function key(ms, k) { var d = new Date(ms); var p = function (n) { return (n < 10 ? "0" : "") + n; }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }
    var d0 = new Date(nowMs);
    for (var i = 1; i < 30; i++) {
        var d = new Date(d0.getFullYear(), d0.getMonth(), d0.getDate() - i);
        var dk = key(d.getTime());
        days[dk] = { "Home-5G": Math.round(r() * 3e9), eduroam: r() < 0.3 ? Math.round(r() * 8e8) : 0 };
        if (r() < 0.2) days[dk]["Cafe-Free"] = Math.round(r() * 2e8);
    }
    return { days: days, labels: labels, last: null };
}

// The raw state of a scenario. `o`: { nowMs }.
function scenario(name, o) {
    var nowMs = o.nowMs;
    var R = {
        wifiSnap: { device: { iface: "wlp47s0", hwAddress: "02:00:00:AA:BB:01", permHwAddress: "02:00:00:AA:BB:01", driver: "iwlwifi", firmware: "86.fb5c9aeb.0 ty-a0-gf-a0-86.ucode", country: "BE", powersave: true }, aps: [], activeAp: "", scanning: false, lastScan: -1, lastScanMs: nowMs - 4000, radioOn: true, hardwareEnabled: true },
        devices: [{ path: "/mock/d/w", iface: "wlp47s0", type: "wifi", driver: "iwlwifi", state: "activated", stateCode: 100, hwAddress: "02:00:00:AA:BB:01", permHwAddress: "02:00:00:AA:BB:01", managed: true, carrier: null, speed: 0, activeConnection: "", ip4: null, ip6: null },
                  { path: "/mock/d/e", iface: "enp46s0", type: "ethernet", driver: "r8169", state: "unavailable", stateCode: 20, hwAddress: "02:00:00:AA:BB:02", permHwAddress: "02:00:00:AA:BB:02", managed: true, carrier: false, speed: 0, activeConnection: "", ip4: null, ip6: null },
                  { path: "/mock/d/p", iface: "proton0", type: "wireguard", driver: "wireguard", state: "unmanaged", stateCode: 10, managed: false, carrier: null, speed: 0, ip4: null, ip6: null },
                  { path: "/mock/d/k", iface: "docker0", type: "bridge", driver: "bridge", state: "unmanaged", stateCode: 10, managed: false, carrier: null, speed: 0, ip4: null, ip6: null }],
        active: [], profiles: [], nm: { running: true, state: 70, primary: "", primaryReal: "", connectivity: 4, wirelessEnabled: true, wirelessHardwareEnabled: true, version: "1.58.1" },
        link: null, dbm: 0, trust: {}, prevBands: {}, overrides: {}, activeSince: {}, bootMs: nowMs - 3600000, nowMs: nowMs, dnsmasq: true, clients: [],
        proton: { installed: true, signedIn: "yes", config: { "Kill Switch": "off", NetShield: "Malware only", IPv6: "on", "Custom DNS": "off" }, status: {}, failed: false },
        catalog: null, pads: {}, portal: { present: false, url: "" }, btAdapter: { name: "laptop-share", enabled: true, state: "Enabled", discoverable: false, discovering: false, address: "02:00:00:AA:BB:03" },
        btDevices: [], btParts: {}, btSeen: {}, btSearchUntilMs: 0, btVisibleUntilMs: 0, btPrompt: null, btRfkill: { soft: false, hard: false }, btProfiles: {}, autoTunnel: true, waiting: ""
    };
    var profs = [
        profile("u-home", "Home-5G", "Home-5G", "wpa2", { priority: 10, timestamp: Math.round(nowMs / 1000) - 600 }),
        profile("u-prox", "Saved-Network-123456", "Saved-Network-123456", "wpa2", { timestamp: 1760000000 }),
        profile("u-prox1", "Saved-Network-123456 1", "Saved-Network-123456", "wpa2", { timestamp: 1750000000 }),
        profile("u-edu", "eduroam", "eduroam", "eap", { timestamp: 1762000000, eap: { method: "peap", phase2: "mschapv2", identity: "student@uni.example", anonymousIdentity: "", caCert: "", domain: "", systemCaCerts: false } }),
        profile("u-red", "Phone-Hotspot", "Phone-Hotspot", "wpa2", { timestamp: 1758000000, metered: "yes" }),
        profile("u-hs", "Hotspot", "laptop-share", "wpa2", { mode: "ap", autoconnect: false, band: "bg", timestamp: 1740000000 }),
        { path: "/mock/p/u-wired", uuid: "u-wired", id: "Wired connection 1", type: "802-3-ethernet", ssid: "", mode: "", security: "", autoconnect: true, priority: 0, timestamp: 1750000000, hidden: false, ip4method: "auto", metered: "unknown", macPolicy: "default", band: "", bssid: "", eap: null }
    ];
    R.profiles = profs;
    R.trust = { "u-home": true, "u-prox": true, "u-prox1": true, "u-edu": true, "u-red": true, "u-hs": true, "u-wired": true };
    R.catalog = null;

    var seen = [];
    function add(ssid, i, freq, strength, sec) { R.wifiSnap.aps.push(ap(mac(i * 101 + freq), ssid, freq, strength, sec)); }
    function homeAp() { add("Home-5G", 1, 5180, 78, "wpa2"); add("Home-5G", 1, 2437, 61, "wpa2"); }
    function around() {
        add("Saved-Network-123456", 2, 2412, 52, "wpa2"); add("eduroam", 3, 5500, 44, "eap"); add("homenet-ABC12-AP", 4, 2462, 38, "wpa2");
        add("Cafe-Free", 5, 2437, 66, "open"); add("FRITZ!Box 7590", 6, 5745, 30, "wpa2/3"); add("DIRECT-roku-381", 7, 2412, 24, "wpa2");
    }
    function connectHome(extraActive) {
        R.active = [{ path: "/mock/a/1", uuid: "u-home", id: "Home-5G", type: "802-11-wireless", devices: ["wlp47s0"], state: "activated", vpn: false, default4: true, default6: false, specific: "", proton: false, killswitch: false }].concat(extraActive || []);
        R.wifiSnap.activeAp = R.wifiSnap.aps[0].bssid;
        R.devices[0].ip4 = { addresses: [{ address: "192.168.1.42", prefix: 24 }], gateway: "192.168.1.1", dns: ["192.168.1.1", "9.9.9.9"] };
        R.devices[0].ip6 = { addresses: [{ address: "2001:db8::42", prefix: 64 }], gateway: "", dns: [] };
        R.link = { iface: "wlp47s0", standard: "he", dbm: -54, rxMbps: 1201, txMbps: 960 };
        R.dbm = -54;
        R.activeSince["u-home"] = nowMs - 25 * 60000;
        R.pads = { gateway: { state: "ok", detail: "192.168.1.1", ms: 3 }, dns: { state: "ok", detail: "9.9.9.9", ms: 14 }, net: { state: "ok", detail: "online", ms: 136 } };
    }

    switch (name) {
    case "crowd": {
        var r = rng("crowd");
        for (var i = 0; i < 32; i++) {
            var nm = NAMES[i % NAMES.length] + (i >= NAMES.length ? "-" + i : "");
            var secs = ["wpa2", "wpa2", "wpa3", "open", "wpa2/3", "eap"];
            var sec = secs[Math.floor(r() * secs.length)];
            var st = Math.round(15 + r() * 80);
            if (r() < 0.45) { add(nm, i, 2412 + 25 * Math.floor(r() * 3), st, sec); add(nm, i + 50, r() < 0.2 ? 5955 : 5180 + 20 * Math.floor(r() * 8), Math.max(5, st - Math.round(r() * 25)), sec); }
            else add(nm, i, r() < 0.5 ? 2437 : 5240, st, sec);
        }
        add("", 90, 5200, 33, "wpa2"); add("", 91, 2462, 21, "wpa2");
        break;
    }
    case "airplane":
        R.nm.wirelessEnabled = false; R.btAdapter.enabled = false; R.btAdapter.state = "Disabled";
        R.wifiSnap.radioOn = false;
        break;
    case "nowifi":
        R.wifiSnap = { device: null, aps: [], activeAp: "", scanning: false, lastScan: -1, lastScanMs: 0, radioOn: false, hardwareEnabled: true };
        R.devices = R.devices.filter(function (d) { return d.type !== "wifi"; });
        R.btAdapter = null;
        break;
    default:
        homeAp(); around();
    }
    if (name === "home" || name === "vpn" || name === "hotspot" || name === "errors" || name === "earbuds" || name === "pairing")
        connectHome(name === "vpn" ? [tunnel(2)] : []);
    if (name === "errors")
        R.pads.dns = { state: "fail", detail: "no answer", ms: 0 };
    if (name === "vpn") {
        R.activeSince["u-proton"] = nowMs - 4 * 60000;
        R.proton.status = { state: "connected", server: { name: "NL#799", city: "Amsterdam", country: "Netherlands", via: "" }, load: 48, protocol: "wireguard" };
        R.catalog = null;
    }
    if (name === "portal") {
        add("Hotel Lobby", 8, 2437, 70, "open");
        R.wifiSnap.aps = R.wifiSnap.aps.filter(function (a) { return a.ssid !== "Cafe-Free"; });
        add("Cafe-Free", 5, 2437, 72, "open");
        R.profiles.push(profile("u-cafe", "Cafe-Free", "Cafe-Free", "open", { timestamp: Math.round(nowMs / 1000) }));
        R.active = [{ path: "/mock/a/2", uuid: "u-cafe", id: "Cafe-Free", type: "802-11-wireless", devices: ["wlp47s0"], state: "activated", vpn: false, default4: true, default6: false, specific: "", proton: false, killswitch: false }];
        var cafe = R.wifiSnap.aps.filter(function (a) { return a.ssid === "Cafe-Free"; })[0];
        R.wifiSnap.activeAp = cafe.bssid;
        R.devices[0].ip4 = { addresses: [{ address: "10.20.0.55", prefix: 22 }], gateway: "10.20.0.1", dns: ["10.20.0.1"] };
        R.link = { iface: "wlp47s0", standard: "ac", dbm: -48, rxMbps: 433, txMbps: 433 };
        R.dbm = -48;
        R.activeSince["u-cafe"] = nowMs - 20000;
        R.pads = { gateway: { state: "ok", detail: "10.20.0.1", ms: 4 }, dns: { state: "ok", detail: "10.20.0.1", ms: 20 }, net: { state: "warn", detail: "Log in first", ms: 90 } };
        R.portal = { present: true, url: "http://captive.example/login" };
    }
    if (name === "hotspot") {
        R.active = [{ path: "/mock/a/3", uuid: "u-hs", id: "Hotspot", type: "802-11-wireless", devices: ["wlp47s0"], state: "activated", vpn: false, default4: false, default6: false, specific: "", proton: false, killswitch: false }];
        R.wifiSnap.activeAp = "";
        R.clients = [{ mac: "02:11:22:33:44:55", ip: "10.42.0.12", name: "pixel-8", dbm: -43 }, { mac: "02:11:22:33:44:66", ip: "10.42.0.31", name: "tablet", dbm: -61 }];
        R.devices[1].state = "activated"; R.devices[1].stateCode = 100; R.devices[1].carrier = true; R.devices[1].speed = 1000;
        R.devices[1].ip4 = { addresses: [{ address: "192.168.0.8", prefix: 24 }], gateway: "192.168.0.1", dns: ["192.168.0.1"] };
        R.active.push({ path: "/mock/a/4", uuid: "u-wired", id: "Wired connection 1", type: "802-3-ethernet", devices: ["enp46s0"], state: "activated", vpn: false, default4: true, default6: false, specific: "", proton: false, killswitch: false });
        R.devices[0].ip4 = { addresses: [{ address: "10.42.0.1", prefix: 24 }], gateway: "", dns: [] };
    }
    if (name === "earbuds") {
        R.btDevices = [btDev("AA:BB:CC:00:00:01", "Earbuds", "audio-headset", { connected: true, paired: true, trusted: true, batteryAvailable: true, battery: 74 }),
                       btDev("AA:BB:CC:00:00:02", "Pixel 8", "phone", { paired: true }), btDev("AA:BB:CC:00:00:03", "MX Master 3", "input-mouse", { paired: true })];
        R.btParts = { "AA:BB:CC:00:00:01": { left: { pct: 72, charging: false }, right: { pct: 76, charging: false }, case: { pct: 41, charging: true } } };
        R.btProfiles = { "AA:BB:CC:00:00:01": { active: "a2dp-sink", available: ["a2dp-sink", "headset-head-unit"], codec: "aac" } };
    }
    if (name === "pairing") {
        R.btDevices = [btDev("AA:BB:CC:00:00:10", "Pixel 9", "phone", { pairing: true }), btDev("AA:BB:CC:00:00:02", "Pixel 8", "phone", { paired: true })];
        R.btSeen = { "AA:BB:CC:00:00:10": true };
        R.btPrompt = { rid: 1, address: "AA:BB:CC:00:00:10", kind: "confirm", code: "483 291" };
    }
    if (name === "home" || name === "crowd" || name === "vpn" || name === "hotspot" || name === "portal" || name === "errors") {
        R.btDevices = [btDev("AA:BB:CC:00:00:01", "Earbuds", "audio-headset", { paired: true, batteryAvailable: false }), btDev("AA:BB:CC:00:00:02", "Pixel 8", "phone", { paired: true })];
    }
    return R;
}

function btDev(address, name, icon, o) {
    return Object.assign({ address: address, name: name, deviceName: name, icon: icon, connected: false, paired: false, bonded: false, trusted: false, blocked: false, pairing: false, battery: 0, batteryAvailable: false }, o || {});
}
